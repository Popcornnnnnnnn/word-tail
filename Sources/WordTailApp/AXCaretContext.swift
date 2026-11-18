import AppKit
import ApplicationServices
import Darwin
import WordTailCore

struct CaretSnapshot {
    let textBeforeCursor: String
    let charAfterCursor: Character?
    let placement: BaselinePlacement
    let font: NSFont
    let rawAXRect: CGRect
    let primaryScreenHeight: CGFloat
}

final class AXCaretContext {
    private var configuredPIDs = Set<pid_t>()
    private var chromiumEnhancedPIDs = Set<pid_t>()
    private var bundleChromiumCache: [String: Bool] = [:]
    private(set) var lastDebugSummary: String = "No keystroke captured yet"

    private static let chromiumBundleIDPrefixes = [
        "com.google.antigravity",
        "com.openai.codex",
        "com.openai.chat",
        "com.google.Chrome",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "ai.browseros",
        "com.browseros"
    ]

    /// Proactively wakes up Electron/Chromium/Aperitif accessibility trees when an app activates,
    /// so the tree is already warm before the user's first keystroke.
    func warmUpApplication(_ app: NSRunningApplication, enableChromiumBridge: Bool) {
        guard AXIsProcessTrusted() else { return }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? ""
        let isChromium = isChromiumBackedApp(app: app, bundleID: bundleID)
        enableAccessibilityOnPID(pid, enableChromiumEnhanced: enableChromiumBridge && isChromium)

        if enableChromiumBridge && isChromium, let bundleURL = app.bundleURL {
            for childPID in helperPIDsInsideBundle(bundlePath: bundleURL.path, mainPID: pid) {
                enableAccessibilityOnPID(childPID, enableChromiumEnhanced: true)
            }
        }
    }

    /// Resolves the application that actually owns keyboard focus—handling non-activating floating
    /// panels such as Raycast or Spotlight even when another app remains `frontmostApplication`.
    func effectiveFocusedApplication() -> NSRunningApplication? {
        if AXIsProcessTrusted() {
            let sys = AXUIElementCreateSystemWide()
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
               let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
                var pid: pid_t = 0
                if AXUIElementGetPid(ref as! AXUIElement, &pid) == .success,
                   pid > 0,
                   let ownerApp = NSRunningApplication(processIdentifier: pid),
                   Self.isStandaloneApplicationBundle(ownerApp) {
                    return ownerApp
                }
            }
        }
        return NSWorkspace.shared.frontmostApplication
    }

    static func isStandaloneApplicationBundle(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL, url.pathExtension == "app" else { return false }
        let path = url.path
        return !path.contains(".app/Contents/") && !path.contains(".framework/")
    }

    func capture(
        targetApp: NSRunningApplication? = nil,
        fallbackBuffer: String,
        enableChromiumBridge: Bool,
        verticalAdjustment: CGFloat = ScreenGeometry.defaultVerticalOffset
    ) -> CaretSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        guard let app = targetApp ?? effectiveFocusedApplication() else { return nil }

        warmUpApplication(app, enableChromiumBridge: enableChromiumBridge)

        guard let element = resolveFocusedTextElement(app: app, enableChromiumBridge: enableChromiumBridge) else {
            recordStatus("app=\(app.bundleIdentifier ?? "?") pid=\(app.processIdentifier) element=nil")
            return nil
        }

        let elemRole = copyStringAttribute(element, attribute: kAXRoleAttribute as String) ?? "?"
        let roleDesc = copyStringAttribute(element, attribute: kAXRoleDescriptionAttribute as String) ?? ""
        let axDesc = copyStringAttribute(element, attribute: kAXDescriptionAttribute as String) ?? ""

        // Skip Monaco code editor buffers (e.g. inside Antigravity / VS Code) so Tab in code files keeps code indentation/IntelliSense,
        // while still completing prose inside Antigravity's AI Chat input box!
        if axDesc.localizedCaseInsensitiveContains("Editor content") ||
           roleDesc.localizedCaseInsensitiveContains("editor content") {
            recordStatus("app=\(app.bundleIdentifier ?? "?") role=\(elemRole) skipped=codeEditor")
            return nil
        }

        // Also ensure the PID owning the focused element itself (e.g. Codex Aperitif helper) is awakened.
        var ownerPID: pid_t = 0
        if AXUIElementGetPid(element, &ownerPID) == .success, ownerPID > 0, ownerPID != app.processIdentifier {
            let isChromium = isChromiumBackedApp(app: app, bundleID: app.bundleIdentifier ?? "")
            enableAccessibilityOnPID(ownerPID, enableChromiumEnhanced: enableChromiumBridge && isChromium)
        }

        // Never run in password fields or active IME preedit (Chinese Pinyin / Doubao composition).
        if elemRole == (kAXSecureTextFieldSubrole as String) || elemRole == "AXSecureTextField" {
            recordStatus("app=\(app.bundleIdentifier ?? "?") role=\(elemRole) skipped=secure")
            return nil
        }
        if let subrole = copyStringAttribute(element, attribute: kAXSubroleAttribute as String),
           subrole == (kAXSecureTextFieldSubrole as String) {
            return nil
        }
        if hasActiveMarkedText(element) {
            return nil
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080

        // Path 1: Standard character-range AX API (NSTextView, NSTextField, standard inputs).
        if let selectedRange = copySelectedRange(element) {
            guard selectedRange.length == 0 else { return nil }

            var textBefore = fallbackBuffer
            var charAfter: Character? = nil

            if let fullValue = copyStringAttribute(element, attribute: kAXValueAttribute as String),
               !fullValue.isEmpty {
                let ns = fullValue as NSString
                if selectedRange.location <= ns.length {
                    let windowStart = max(0, selectedRange.location - 80)
                    let beforeLen = selectedRange.location - windowStart
                    if beforeLen > 0 {
                        let candidate = ns.substring(with: NSRange(location: windowStart, length: beforeLen))
                        // Keep fallbackBuffer if AXValue only contains object-replacement chars.
                        if candidate.contains(where: { $0.isASCII && $0.isLetter }) {
                            textBefore = candidate
                        }
                    }

                    if selectedRange.location < ns.length {
                        let afterStr = ns.substring(with: NSRange(location: selectedRange.location, length: 1))
                        charAfter = afterStr.first
                    }
                }
            }

            if !textBefore.isEmpty,
               let (axRect, font) = characterRectAndFont(element: element, caretLocation: selectedRange.location) {
                let placement = ScreenGeometry.baselinePlacement(
                    forAXCharRect: axRect,
                    primaryScreenHeight: primaryHeight,
                    font: font,
                    verticalAdjustment: verticalAdjustment
                )
                recordStatus(String(
                    format: "app=%@ pid=%d->%d role=%@ path=range rect=(%.1fx%.1f) font=%.1f",
                    app.bundleIdentifier ?? "?", app.processIdentifier, ownerPID, elemRole,
                    axRect.width, axRect.height, font.pointSize
                ))
                return CaretSnapshot(
                    textBeforeCursor: textBefore,
                    charAfterCursor: charAfter,
                    placement: placement,
                    font: font,
                    rawAXRect: axRect,
                    primaryScreenHeight: primaryHeight
                )
            }
        }

        // Path 2: WebKit / Chromium / Codex / Electron contenteditable TextMarker API.
        if let markerSnapshot = captureViaTextMarkers(
            element: element,
            fallbackBuffer: fallbackBuffer,
            primaryHeight: primaryHeight,
            verticalAdjustment: verticalAdjustment
        ) {
            recordStatus(String(
                format: "app=%@ pid=%d->%d role=%@ path=marker rect=(%.1fx%.1f) font=%.1f after=%@",
                app.bundleIdentifier ?? "?", app.processIdentifier, ownerPID, elemRole,
                markerSnapshot.rawAXRect.width, markerSnapshot.rawAXRect.height,
                markerSnapshot.font.pointSize,
                markerSnapshot.charAfterCursor.map { $0.isWhitespace ? "ws" : ($0.isLetter ? "letter" : "punct") } ?? "nil"
            ))
            return markerSnapshot
        }

        var attrNamesRef: CFArray?
        _ = AXUIElementCopyAttributeNames(element, &attrNamesRef)
        let attrCount = (attrNamesRef as? [String])?.count ?? 0

        // If an Electron/Chromium app restarted or spawned a fresh webview before AX woke up,
        // clear the PID cache and re-trigger AXManualAccessibility + AXEnhancedUserInterface immediately.
        let bundleID = app.bundleIdentifier ?? ""
        if isChromiumBackedApp(app: app, bundleID: bundleID) {
            configuredPIDs.remove(app.processIdentifier)
            chromiumEnhancedPIDs.remove(app.processIdentifier)
            enableAccessibilityOnPID(app.processIdentifier, enableChromiumEnhanced: enableChromiumBridge)
            if ownerPID > 0 && ownerPID != app.processIdentifier {
                configuredPIDs.remove(ownerPID)
                chromiumEnhancedPIDs.remove(ownerPID)
                enableAccessibilityOnPID(ownerPID, enableChromiumEnhanced: enableChromiumBridge)
            }
        }

        recordStatus("app=\(bundleID.isEmpty ? "?" : bundleID) pid=\(app.processIdentifier)->\(ownerPID) role=\(elemRole) attrs=\(attrCount) bounds=nil mDiag=\(lastMarkerDiag)")
        return nil
    }

    private func enableAccessibilityOnPID(_ pid: pid_t, enableChromiumEnhanced: Bool) {
        let axApp = AXUIElementCreateApplication(pid)
        if !configuredPIDs.contains(pid) {
            if AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
                configuredPIDs.insert(pid)
            }
        }
        if enableChromiumEnhanced && !chromiumEnhancedPIDs.contains(pid) {
            if AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success {
                chromiumEnhancedPIDs.insert(pid)
            }
        }
    }

    private func isChromiumBackedApp(app: NSRunningApplication, bundleID: String) -> Bool {
        if Self.chromiumBundleIDPrefixes.contains(where: { bundleID.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        let cacheKey = bundleID.isEmpty ? (app.bundleURL?.path ?? "\(app.processIdentifier)") : bundleID
        if let cached = bundleChromiumCache[cacheKey] {
            return cached
        }
        var detected = false
        if let frameworksURL = app.bundleURL?.appendingPathComponent("Contents/Frameworks", isDirectory: true),
           let entries = try? FileManager.default.contentsOfDirectory(atPath: frameworksURL.path) {
            detected = entries.contains { name in
                name.localizedCaseInsensitiveContains("Chromium") ||
                name.localizedCaseInsensitiveContains("Electron Framework") ||
                name.localizedCaseInsensitiveContains("Codex Framework") ||
                name.localizedCaseInsensitiveContains("Cef")
            }
        }
        bundleChromiumCache[cacheKey] = detected
        return detected
    }

    private func helperPIDsInsideBundle(bundlePath: String, mainPID: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 2048)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<pid_t>.stride

        var matches: [pid_t] = []
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for i in 0..<min(count, pids.count) {
            let pid = pids[i]
            guard pid > 0, pid != mainPID else { continue }
            let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard len > 0 else { continue }
            let path = String(cString: pathBuffer)
            if path.hasPrefix(bundlePath) && !path.contains("Renderer") && !path.contains("crashpad") {
                matches.append(pid)
            }
        }
        return matches
    }

    private func resolveFocusedTextElement(app: NSRunningApplication, enableChromiumBridge: Bool) -> AXUIElement? {
        // 1. System-wide query traverses AXRemoteUIElement bridges into helper processes (like Codex Aperitif).
        let sys = AXUIElementCreateSystemWide()
        var sysRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &sysRef) == .success,
           let sysRef, CFGetTypeID(sysRef) == AXUIElementGetTypeID() {
            let drilled = drillFocusedChildIfNeeded(sysRef as! AXUIElement)
            if isUsableFocusedElement(drilled) {
                return drilled
            }
        }

        // 2. Main app PID query.
        if let el = focusedElement(forPID: app.processIdentifier) {
            let drilled = drillFocusedChildIfNeeded(el)
            if isUsableFocusedElement(drilled) {
                return drilled
            }
        }

        // 3. Multi-process embedded browser host fallback (e.g. ChatGPT.app -> Codex (Aperitif).app).
        if enableChromiumBridge, let bundleURL = app.bundleURL {
            for helperPID in helperPIDsInsideBundle(bundlePath: bundleURL.path, mainPID: app.processIdentifier) {
                if let el = focusedElement(forPID: helperPID) {
                    let drilled = drillFocusedChildIfNeeded(el)
                    if isUsableFocusedElement(drilled) {
                        return drilled
                    }
                }
            }
        }

        // Return best-effort element even if role is generic.
        if let sysRef, CFGetTypeID(sysRef) == AXUIElementGetTypeID() {
            return drillFocusedChildIfNeeded(sysRef as! AXUIElement)
        }
        return focusedElement(forPID: app.processIdentifier)
    }

    private func focusedElement(forPID pid: pid_t) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
           let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            return (ref as! AXUIElement)
        }
        return nil
    }

    private func drillFocusedChildIfNeeded(_ start: AXUIElement) -> AXUIElement {
        var current = start
        let containerRoles: Set<String> = ["AXApplication", "AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXWebArea"]
        for _ in 0..<4 {
            let role = copyStringAttribute(current, attribute: kAXRoleAttribute as String) ?? ""
            guard containerRoles.contains(role) else { break }
            var childRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXFocusedUIElementAttribute as CFString, &childRef) == .success,
                  let childRef, CFGetTypeID(childRef) == AXUIElementGetTypeID() else {
                break
            }
            let child = childRef as! AXUIElement
            if CFEqual(child, current) { break }
            current = child
        }
        return current
    }

    private func isUsableFocusedElement(_ element: AXUIElement) -> Bool {
        if copySelectedRange(element) != nil { return true }
        var markerRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRef) == .success,
           markerRef != nil {
            return true
        }
        return false
    }

    private func hasActiveMarkedText(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXMarkedTextRange" as CFString, &ref) == .success,
           let ref, CFGetTypeID(ref) == AXValueGetTypeID() {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(ref as! AXValue, .cfRange, &range), range.length > 0 {
                return true
            }
        }
        return false
    }

    private func copySelectedRange(_ element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private func characterRectAndFont(element: AXUIElement, caretLocation: Int) -> (CGRect, NSFont)? {
        var resolvedRect: CGRect?
        if caretLocation > 0, let prevRect = boundsForRange(element, location: caretLocation - 1, length: 1),
           Self.isValidCaretRect(prevRect) {
            resolvedRect = prevRect
        } else if let caretRect = boundsForRange(element, location: caretLocation, length: 0),
                  Self.isValidCaretRect(caretRect) {
            resolvedRect = caretRect
        }

        guard let rect = resolvedRect else { return nil }

        if caretLocation > 0, let axFont = fontForRange(element, location: caretLocation - 1, length: 1) {
            return (rect, axFont)
        }

        let estimatedSize = ScreenGeometry.estimatedFontSize(forLineHeight: rect.height)
        return (rect, NSFont.systemFont(ofSize: estimatedSize))
    }

    private func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var cfRange = CFRange(location: location, length: length)
        guard let rangeVal = AXValueCreate(.cfRange, &cfRange) else { return nil }

        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeVal,
            &ref
        ) == .success, let ref, CFGetTypeID(ref) == AXValueGetTypeID() else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(ref as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private func fontForRange(_ element: AXUIElement, location: Int, length: Int) -> NSFont? {
        var cfRange = CFRange(location: location, length: length)
        guard let rangeVal = AXValueCreate(.cfRange, &cfRange) else { return nil }

        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXAttributedStringForRangeParameterizedAttribute as CFString,
            rangeVal,
            &ref
        ) == .success, let attrStr = ref as? NSAttributedString else {
            return nil
        }
        return extractFont(from: attrStr)
    }

    private var lastMarkerDiag: String = "none"

    private func captureViaTextMarkers(
        element: AXUIElement,
        fallbackBuffer: String,
        primaryHeight: CGFloat,
        verticalAdjustment: CGFloat
    ) -> CaretSnapshot? {
        var markerRangeRef: CFTypeRef?
        let mrErr = AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextMarkerRange" as CFString,
            &markerRangeRef
        )
        guard mrErr == .success, let markerRangeRef else {
            lastMarkerDiag = "noSelMarker(\(mrErr.rawValue))"
            return nil
        }

        // Ensure selection is collapsed (not highlighted text).
        var lenRef: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXLengthForTextMarkerRange" as CFString,
            markerRangeRef,
            &lenRef
        ) == .success, let num = lenRef as? NSNumber, num.intValue > 0 {
            lastMarkerDiag = "nonEmptySel(\(num.intValue))"
            return nil
        }

        let markerRange = markerRangeRef as! AXTextMarkerRange
        let endMarker = AXTextMarkerRangeCopyEndMarker(markerRange)

        // Prefer 1-character range immediately preceding the caret ([prevMarker, endMarker]),
        // because WebKit/Blink often returns (0,0,0,0) for collapsed zero-length marker ranges!
        var resolvedRect: CGRect?
        var resolvedFont: NSFont?

        var prevMarkerRef: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXPreviousTextMarkerForTextMarker" as CFString,
            endMarker,
            &prevMarkerRef
        ) == .success, let prevMarkerRef {
            let pair = [prevMarkerRef, endMarker] as CFArray
            var prevRangeRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                "AXTextMarkerRangeForUnorderedTextMarkers" as CFString,
                pair,
                &prevRangeRef
            ) == .success, let prevRangeRef {
                if let rect = boundsForTextMarkerRange(element: element, markerRange: prevRangeRef),
                   Self.isValidCaretRect(rect) {
                    resolvedRect = rect
                }
                resolvedFont = fontForTextMarkerRange(element: element, markerRange: prevRangeRef)
            }
        }

        // Fallback to collapsed caret marker range if preceding-char range wasn't available.
        var rawCandidateRect = CGRect.zero
        if resolvedRect == nil,
           let collapsedRect = boundsForTextMarkerRange(element: element, markerRange: markerRangeRef) {
            rawCandidateRect = collapsedRect
            if Self.isValidCaretRect(collapsedRect) {
                resolvedRect = collapsedRect
            }
        }

        guard let axRect = resolvedRect else {
            lastMarkerDiag = String(format: "badBounds(%.1fx%.1f@%.0f,%.0f)", rawCandidateRect.width, rawCandidateRect.height, rawCandidateRect.origin.x, rawCandidateRect.origin.y)
            return nil
        }

        // Scope textBefore and charAfter strictly to the current visual line inside `element`
        // so Chromium never walks out of the end of a chat box into adjacent toolbar buttons!
        var textBefore = fallbackBuffer
        var charAfter: Character? = nil

        var lineRangeRef: CFTypeRef?
        let hasLineRange = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXLineTextMarkerRangeForTextMarker" as CFString,
            endMarker,
            &lineRangeRef
        ) == .success && lineRangeRef != nil

        if hasLineRange, let lineRangeRef {
            let lineMarkerRange = lineRangeRef as! AXTextMarkerRange
            let lineStart = AXTextMarkerRangeCopyStartMarker(lineMarkerRange)
            let lineEnd = AXTextMarkerRangeCopyEndMarker(lineMarkerRange)

            if !CFEqual(lineStart, endMarker) {
                let beforePair = [lineStart, endMarker] as CFArray
                var beforeRangeRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element,
                    "AXTextMarkerRangeForUnorderedTextMarkers" as CFString,
                    beforePair,
                    &beforeRangeRef
                ) == .success, let beforeRangeRef,
                   let beforeStr = stringForTextMarkerRange(element: element, markerRange: beforeRangeRef),
                   beforeStr.contains(where: { $0.isASCII && $0.isLetter }) {
                    textBefore = String(beforeStr.suffix(80))
                }
            }

            if !CFEqual(endMarker, lineEnd) {
                let afterPair = [endMarker, lineEnd] as CFArray
                var afterRangeRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element,
                    "AXTextMarkerRangeForUnorderedTextMarkers" as CFString,
                    afterPair,
                    &afterRangeRef
                ) == .success, let afterRangeRef,
                   let afterStr = stringForTextMarkerRange(element: element, markerRange: afterRangeRef),
                   !afterStr.isEmpty {
                    charAfter = afterStr.first
                }
            }
        } else {
            // Fallback when AXLineTextMarkerRangeForTextMarker is unavailable:
            // only accept AXNextTextMarkerForTextMarker if it belongs to the exact same leaf AXUIElement!
            var curLeafRef: CFTypeRef?
            var nextMarkerRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                "AXUIElementForTextMarker" as CFString,
                endMarker,
                &curLeafRef
            ) == .success, let curLeafRef,
               AXUIElementCopyParameterizedAttributeValue(
                element,
                "AXNextTextMarkerForTextMarker" as CFString,
                endMarker,
                &nextMarkerRef
               ) == .success, let nextMarkerRef {
                var nextLeafRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element,
                    "AXUIElementForTextMarker" as CFString,
                    nextMarkerRef,
                    &nextLeafRef
                ) == .success, let nextLeafRef, CFEqual(curLeafRef, nextLeafRef) {
                    let nextPair = [endMarker, nextMarkerRef] as CFArray
                    var nextRangeRef: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(
                        element,
                        "AXTextMarkerRangeForUnorderedTextMarkers" as CFString,
                        nextPair,
                        &nextRangeRef
                    ) == .success, let nextRangeRef,
                       let nextStr = stringForTextMarkerRange(element: element, markerRange: nextRangeRef) {
                        charAfter = nextStr.first
                    }
                }
            }
        }

        guard !textBefore.isEmpty else { return nil }

        let font = resolvedFont ?? NSFont.systemFont(ofSize: ScreenGeometry.estimatedFontSize(forLineHeight: axRect.height))
        let placement = ScreenGeometry.baselinePlacement(
            forAXCharRect: axRect,
            primaryScreenHeight: primaryHeight,
            font: font,
            verticalAdjustment: verticalAdjustment
        )
        return CaretSnapshot(
            textBeforeCursor: textBefore,
            charAfterCursor: charAfter,
            placement: placement,
            font: font,
            rawAXRect: axRect,
            primaryScreenHeight: primaryHeight
        )
    }

    private func boundsForTextMarkerRange(element: AXUIElement, markerRange: CFTypeRef) -> CGRect? {
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXBoundsForTextMarkerRange" as CFString,
            markerRange,
            &boundsRef
        ) == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private func stringForTextMarkerRange(element: AXUIElement, markerRange: CFTypeRef) -> String? {
        var strRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXStringForTextMarkerRange" as CFString,
            markerRange,
            &strRef
        ) == .success else {
            return nil
        }
        return strRef as? String
    }

    private func fontForTextMarkerRange(element: AXUIElement, markerRange: CFTypeRef) -> NSFont? {
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXAttributedStringForTextMarkerRange" as CFString,
            markerRange,
            &ref
        ) == .success, let attrStr = ref as? NSAttributedString else {
            return nil
        }
        return extractFont(from: attrStr)
    }

    private func extractFont(from attrStr: NSAttributedString) -> NSFont? {
        guard attrStr.length > 0 else { return nil }
        let attrs = attrStr.attributes(at: 0, effectiveRange: nil)
        if let nsFont = attrs[.font] as? NSFont {
            return nsFont
        }
        if let fontDict = attrs[NSAttributedString.Key("AXFont")] as? [String: Any],
           let num = fontDict["AXFontSize"] as? NSNumber {
            let size = CGFloat(num.doubleValue)
            guard size >= 9, size <= 36 else { return nil }
            if let name = fontDict["AXFontName"] as? String,
               !name.hasPrefix("."),
               let namedFont = NSFont(name: name, size: size) {
                return namedFont
            }
            return NSFont.systemFont(ofSize: size)
        }
        return nil
    }

    private func copyStringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    func recordOverlayOutcome(_ outcome: String) {
        recordStatus("\(lastDebugSummary) \(outcome)")
    }

    private func recordStatus(_ status: String) {
        lastDebugSummary = status
    }

    private static func isValidCaretRect(_ rect: CGRect) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else {
            return false
        }
        if rect.origin.x == 0 && rect.origin.y == 0 {
            return false
        }
        return rect.height >= 9 && rect.height <= 56 && rect.width >= 0 && rect.width <= 80
    }
}
