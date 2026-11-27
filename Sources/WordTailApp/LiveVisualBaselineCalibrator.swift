import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import WordTailCore

struct VisualLockStatusSnapshot: Equatable {
    let hasPermission: Bool
    let lockedLineCount: Int
    let lastAppName: String?
    let lastDeltaPt: CGFloat?
    let lastConfidence: Double?
    let lastLockedAt: Date?
    let lastError: String?
}

struct VisualLineLockResult {
    let lineKey: VisualLineKey
    let lockedBaselineCocoaY: CGFloat
    let deltaQuartzY: CGFloat
    let confidence: Double
}

/// Coordinates on-demand, per-line ScreenCaptureKit micro-crops in memory—scoped strictly to the
/// verified target application on its containing display—so WordTail can lock inline ghost text onto
/// the host app's exact rendered baseline without blocking keystrokes or capturing unrelated apps.
final class LiveVisualBaselineCalibrator: @unchecked Sendable {
    private struct ShareableInventory {
        let displays: [SCDisplay]
        let applications: [SCRunningApplication]
        let loadedAt: CFAbsoluteTime
    }

    private struct ResolvedAppDisplayTarget {
        let frameQuartz: CGRect
        let filter: SCContentFilter
        let scale: CGFloat
    }

    private struct CaptureRequest {
        let generation: UInt64
        let lineKey: VisualLineKey
        let priorKey: VisualPriorKey
        let targetBundleID: String
        let targetPID: pid_t
        let appName: String
        let rawAXRect: CGRect
        let primaryScreenHeight: CGFloat
        let rawBaselineCocoaY: CGFloat
        let predictedBaselineCocoaY: CGFloat
        let font: NSFont
        let sample: VisualSampleWord
        let preflightCheck: @MainActor () -> Bool
    }

    private let cache = VisualBaselineCache()
    private let stateLock = NSLock()

    private var inventory: ShareableInventory?
    private var captureGeneration: UInt64 = 0
    private var isCaptureInFlight: Bool = false
    private var pendingRequest: CaptureRequest?
    private var captureErrorCooldownUntil: CFAbsoluteTime = 0

    private var lockedLineCount: Int = 0
    private var lastAppName: String?
    private var lastDeltaPt: CGFloat?
    private var lastConfidence: Double?
    private var lastLockedAt: Date?
    private var lastError: String?
    private var screenObserver: NSObjectProtocol?

    var onStatusChanged: (() -> Void)?
    /// Delivered on the main thread whenever a fresh, generation-valid line lock completes.
    var onLineLocked: ((VisualLineLockResult) -> Void)?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateDisplayCache()
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    var hasScreenCapturePermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func statusSnapshot() -> VisualLockStatusSnapshot {
        let permitted = CGPreflightScreenCaptureAccess()
        return stateLock.withLock {
            VisualLockStatusSnapshot(
                hasPermission: permitted,
                lockedLineCount: lockedLineCount,
                lastAppName: lastAppName,
                lastDeltaPt: lastDeltaPt,
                lastConfidence: lastConfidence,
                lastLockedAt: lastLockedAt,
                lastError: permitted ? lastError : nil
            )
        }
    }

    func resolveInitialBaseline(
        lineKey: VisualLineKey,
        priorKey: VisualPriorKey,
        rawBaselineCocoaY: CGFloat,
        fallbackBaselineCocoaY: CGFloat,
        currentCaretX: CGFloat
    ) -> VisualBaselineResolution {
        cache.resolveInitialBaseline(
            lineKey: lineKey,
            priorKey: priorKey,
            rawBaselineCocoaY: rawBaselineCocoaY,
            fallbackBaselineCocoaY: fallbackBaselineCocoaY,
            currentCaretX: currentCaretX
        )
    }

    /// Invalidates all queued and in-flight captures (e.g. on toggle-off, focus switch, click, or reset).
    func invalidateInFlightCaptures() {
        stateLock.withLock {
            captureGeneration &+= 1
            pendingRequest = nil
        }
    }

    func invalidateDisplayCache() {
        stateLock.withLock {
            captureGeneration &+= 1
            pendingRequest = nil
            inventory = nil
            cache.clearLines()
        }
    }

    func clearLines(forBundleID bundleID: String? = nil) {
        stateLock.withLock {
            captureGeneration &+= 1
            if let bundleID {
                if pendingRequest?.lineKey.bundleID == bundleID {
                    pendingRequest = nil
                }
            } else {
                pendingRequest = nil
            }
            cache.clearLines(forBundleID: bundleID)
        }
    }

    func resetAllLearnedState() {
        stateLock.withLock {
            captureGeneration &+= 1
            pendingRequest = nil
            lockedLineCount = 0
            lastAppName = nil
            lastDeltaPt = nil
            lastConfidence = nil
            lastLockedAt = nil
            lastError = nil
            captureErrorCooldownUntil = 0
            cache.clearAll()
        }
        notifyStatusChanged()
    }

    /// Requests a non-blocking, coalesced micro-crop lock for a newly visited text line.
    /// Never prompts for permission on its own; silently returns if Screen Recording is not granted.
    func requestLineLockIfNeeded(
        lineKey: VisualLineKey,
        priorKey: VisualPriorKey,
        targetBundleID: String,
        targetPID: pid_t,
        appName: String,
        textBeforeCursor: String,
        rawAXRect: CGRect,
        primaryScreenHeight: CGFloat,
        rawBaselineCocoaY: CGFloat,
        predictedBaselineCocoaY: CGFloat,
        font: NSFont,
        preflightCheck: @escaping @MainActor () -> Bool
    ) {
        guard CGPreflightScreenCaptureAccess() else { return }
        guard let sample = VisualBaselineAligner.extractSampleWord(from: textBeforeCursor) else {
            return
        }
        guard cache.shouldAttemptCapture(for: lineKey, currentCaretX: rawAXRect.maxX) else {
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let launchNow: CaptureRequest? = stateLock.withLock {
            if now < captureErrorCooldownUntil {
                return nil
            }
            let req = CaptureRequest(
                generation: captureGeneration,
                lineKey: lineKey,
                priorKey: priorKey,
                targetBundleID: targetBundleID,
                targetPID: targetPID,
                appName: appName,
                rawAXRect: rawAXRect,
                primaryScreenHeight: primaryScreenHeight,
                rawBaselineCocoaY: rawBaselineCocoaY,
                predictedBaselineCocoaY: predictedBaselineCocoaY,
                font: font,
                sample: sample,
                preflightCheck: preflightCheck
            )
            if isCaptureInFlight {
                pendingRequest = req
                return nil
            }
            isCaptureInFlight = true
            return req
        }

        if let launchNow {
            launchCapture(launchNow)
        }
    }

    private func launchCapture(_ request: CaptureRequest) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.performCapture(request)
            self.finishAndDrainNext()
        }
    }

    private func finishAndDrainNext() {
        while true {
            let now = CFAbsoluteTimeGetCurrent()
            let next: CaptureRequest? = stateLock.withLock {
                guard let queued = pendingRequest else {
                    isCaptureInFlight = false
                    return nil
                }
                pendingRequest = nil
                if now < captureErrorCooldownUntil || queued.generation != captureGeneration {
                    isCaptureInFlight = false
                    return nil
                }
                return queued
            }

            guard let next else { return }
            if cache.shouldAttemptCapture(for: next.lineKey, currentCaretX: next.rawAXRect.maxX) {
                launchCapture(next)
                return
            }
        }
    }

    private func isGenerationCurrent(_ generation: UInt64) -> Bool {
        stateLock.withLock {
            generation == captureGeneration
        }
    }

    private func performCapture(_ request: CaptureRequest) async {
        guard isGenerationCurrent(request.generation),
              CGPreflightScreenCaptureAccess() else {
            return
        }

        guard let target = await resolveAppDisplayTarget(
            forAXRect: request.rawAXRect,
            targetBundleID: request.targetBundleID,
            targetPID: request.targetPID
        ) else {
            return
        }

        guard let plan = VisualBaselineAligner.computeCropPlan(
            rawAXRect: request.rawAXRect,
            primaryScreenHeight: request.primaryScreenHeight,
            predictedBaselineCocoaY: request.predictedBaselineCocoaY,
            font: request.font,
            sample: request.sample,
            displayFrameQuartz: target.frameQuartz
        ) else {
            return
        }

        let cfg = SCStreamConfiguration()
        cfg.sourceRect = plan.displayLocalRect
        cfg.width = max(1, Int((plan.displayLocalRect.width * target.scale).rounded()))
        cfg.height = max(1, Int((plan.displayLocalRect.height * target.scale).rounded()))
        cfg.scalesToFit = false
        cfg.showsCursor = false
        cfg.captureResolution = .best

        // Validate consent, TCC permission, focused app/PID, and non-secure input AND submit the capture
        // synchronously inside the same non-suspending MainActor turn so nothing can interleave before submission.
        let captured: CGImage?
        do {
            captured = try await captureOnMainActorIfStillValid(
                generation: request.generation,
                preflightCheck: request.preflightCheck,
                filter: target.filter,
                configuration: cfg
            )
        } catch {
            let nsErr = error as NSError
            recordCaptureError(nsErr.localizedDescription, invalidateInventory: true)
            return
        }
        guard let captured, isGenerationCurrent(request.generation) else {
            return
        }

        guard let measurement = VisualBaselineAligner.measureBaselineDeltaQuartzY(
            capturedImage: captured,
            sampleText: plan.sampleText,
            referenceFont: request.font,
            scale: target.scale,
            predictedBaselineFromTopPt: plan.predictedBaselineFromTopPt
        ) else {
            commitFailureIfGenerationCurrent(
                generation: request.generation,
                lineKey: request.lineKey,
                caretX: request.rawAXRect.maxX
            )
            return
        }

        let lockedCocoaY = VisualBaselineAligner.lockedCocoaBaselineY(
            predictedBaselineCocoaY: request.predictedBaselineCocoaY,
            deltaQuartzY: measurement.deltaQuartzY
        )

        // Final check right before atomically committing to cache, status, and overlay.
        let stillSafeBeforeCommit = await MainActor.run {
            request.preflightCheck()
        }
        guard stillSafeBeforeCommit else { return }

        guard commitLockIfGenerationCurrent(
            generation: request.generation,
            lineKey: request.lineKey,
            priorKey: request.priorKey,
            appName: request.appName,
            lockedBaselineCocoaY: lockedCocoaY,
            rawBaselineCocoaY: request.rawBaselineCocoaY,
            caretX: request.rawAXRect.maxX,
            confidence: measurement.confidence
        ) else {
            return
        }

        let result = VisualLineLockResult(
            lineKey: request.lineKey,
            lockedBaselineCocoaY: lockedCocoaY,
            deltaQuartzY: measurement.deltaQuartzY,
            confidence: measurement.confidence
        )
        let requestGen = request.generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isGenerationCurrent(requestGen) else { return }
            self.onLineLocked?(result)
        }
        notifyStatusChanged()
    }

    @MainActor
    private func captureOnMainActorIfStillValid(
        generation: UInt64,
        preflightCheck: @MainActor () -> Bool,
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage? {
        guard isGenerationCurrent(generation),
              CGPreflightScreenCaptureAccess(),
              preflightCheck() else {
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: image)
                }
            }
        }
    }

    private func commitFailureIfGenerationCurrent(
        generation: UInt64,
        lineKey: VisualLineKey,
        caretX: CGFloat
    ) {
        stateLock.withLock {
            guard generation == captureGeneration else { return }
            cache.recordFailure(for: lineKey, caretX: caretX)
        }
    }

    private func commitLockIfGenerationCurrent(
        generation: UInt64,
        lineKey: VisualLineKey,
        priorKey: VisualPriorKey,
        appName: String,
        lockedBaselineCocoaY: CGFloat,
        rawBaselineCocoaY: CGFloat,
        caretX: CGFloat,
        confidence: Double
    ) -> Bool {
        stateLock.withLock {
            guard generation == captureGeneration else { return false }
            guard cache.recordLock(
                lineKey: lineKey,
                priorKey: priorKey,
                lockedBaselineCocoaY: lockedBaselineCocoaY,
                rawBaselineCocoaY: rawBaselineCocoaY,
                caretX: caretX
            ) else {
                return false
            }
            lockedLineCount += 1
            lastAppName = appName
            lastDeltaPt = lockedBaselineCocoaY - rawBaselineCocoaY
            lastConfidence = confidence
            lastLockedAt = Date()
            lastError = nil
            return true
        }
    }

    private func readInventory() -> (inventory: ShareableInventory?, age: CFAbsoluteTime) {
        let now = CFAbsoluteTimeGetCurrent()
        return stateLock.withLock {
            guard let inv = inventory else { return (nil, .infinity) }
            return (inv, now - inv.loadedAt)
        }
    }

    private func storeInventory(_ inv: ShareableInventory) {
        stateLock.withLock {
            inventory = inv
            lastError = nil
        }
    }

    private func recordCaptureError(_ message: String, invalidateInventory: Bool) {
        stateLock.withLock {
            if invalidateInventory {
                inventory = nil
            }
            captureErrorCooldownUntil = CFAbsoluteTimeGetCurrent() + 5.0
            lastError = message
        }
        notifyStatusChanged()
    }

    /// Resolves an app-scoped `SCContentFilter(display:including:exceptingWindows:)` capturing ONLY
    /// the verified target application on the display containing `axRect`—excluding WordTail and all other apps.
    private func resolveAppDisplayTarget(
        forAXRect axRect: CGRect,
        targetBundleID: String,
        targetPID: pid_t
    ) async -> ResolvedAppDisplayTarget? {
        let probePoint = CGPoint(x: axRect.midX, y: axRect.midY)
        let (cached, age) = readInventory()
        if let cached, age <= 60.0,
           let target = buildTarget(from: cached, probePoint: probePoint, targetBundleID: targetBundleID, targetPID: targetPID) {
            return target
        }

        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let fresh = ShareableInventory(
                displays: content.displays,
                applications: content.applications,
                loadedAt: CFAbsoluteTimeGetCurrent()
            )
            storeInventory(fresh)
            return buildTarget(from: fresh, probePoint: probePoint, targetBundleID: targetBundleID, targetPID: targetPID)
        } catch {
            let nsErr = error as NSError
            recordCaptureError(nsErr.localizedDescription, invalidateInventory: false)
            return nil
        }
    }

    private func buildTarget(
        from inv: ShareableInventory,
        probePoint: CGPoint,
        targetBundleID: String,
        targetPID: pid_t
    ) -> ResolvedAppDisplayTarget? {
        guard let disp = pickDisplay(from: inv.displays, containing: probePoint) else {
            return nil
        }
        let selfBundleID = Bundle.main.bundleIdentifier
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let matchingApps = inv.applications.filter { app in
            if app.processID == selfPID { return false }
            if let selfBundleID, !selfBundleID.isEmpty, app.bundleIdentifier == selfBundleID {
                return false
            }
            return app.processID == targetPID && app.bundleIdentifier == targetBundleID
        }
        guard !matchingApps.isEmpty else { return nil }

        let filter = SCContentFilter(
            display: disp,
            including: matchingApps,
            exceptingWindows: []
        )
        let scale = max(1.0, CGFloat(filter.pointPixelScale))
        return ResolvedAppDisplayTarget(
            frameQuartz: disp.frame,
            filter: filter,
            scale: scale
        )
    }

    private func pickDisplay(from displays: [SCDisplay], containing point: CGPoint) -> SCDisplay? {
        if let exact = displays.first(where: { $0.frame.contains(point) }) {
            return exact
        }
        return displays.min { a, b in
            squaredDistance(from: point, to: a.frame) < squaredDistance(from: point, to: b.frame)
        }
    }

    private func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx: CGFloat = point.x < rect.minX ? (rect.minX - point.x) : (point.x > rect.maxX ? (point.x - rect.maxX) : 0)
        let dy: CGFloat = point.y < rect.minY ? (rect.minY - point.y) : (point.y > rect.maxY ? (point.y - rect.maxY) : 0)
        return dx * dx + dy * dy
    }

    private func notifyStatusChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?()
        }
    }
}
