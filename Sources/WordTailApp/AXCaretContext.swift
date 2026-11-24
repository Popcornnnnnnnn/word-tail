import AppKit
import ApplicationServices
import Darwin
import WordTailCore

struct CaretSnapshot {
    let textBeforeCursor: String
    let charAfterCursor: Character?
    let textAfterOnLine: String
    let hasTextAfterOnLine: Bool
    let isAtDocumentStart: Bool
    let isFallbackText: Bool
    let isGlyphWidthZeroOnPrevChar: Bool
    let lineSpacingBias: LineSpacingBias
    let placement: BaselinePlacement
    let font: NSFont
    let rawAXRect: CGRect
    let primaryScreenHeight: CGFloat
    let focusedElement: AXUIElement?
    let caretLocation: Int?
}

struct VerifiedSnippetDestination {
    let element: AXUIElement
    let caretLocation: Int?
}

final class AXCaretContext {
    /// Strict per-IPC messaging cap (`50 ms` instead of macOS's `6.0 s` default) so a stalled target app
    /// can never block accessibility queries or keystroke delivery.
    private static let axIPCDeadlineSeconds: Float = 0.05

    private let stateLock = NSLock()
    private var configuredPIDs = Set<pid_t>()
    private var chromiumEnhancedPIDs = Set<pid_t>()
    private var bundleChromiumCache: [String: Bool] = [:]
    private var helperPIDCache: [pid_t: (pids: [pid_t], timestamp: CFAbsoluteTime)] = [:]
    private var _lastDebugSummary: String = "No keystroke captured yet"

    var lastDebugSummary: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastDebugSummary
    }

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
            AXUIElementSetMessagingTimeout(sys, Self.axIPCDeadlineSeconds)
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
        let appBundleID = app.bundleIdentifier ?? ""
        let isChromium = isChromiumBackedApp(app: app, bundleID: appBundleID)
        let isWebKit = isWebKitTextElement(element, isChromium: isChromium)
        let spacingBias: LineSpacingBias = isWebKit ? .topAdded : .bottomAdded

        // Path 1: Standard character-range AX API (NSTextView, NSTextField, standard inputs).
        if let selectedRange = copySelectedRange(element) {
            guard selectedRange.length == 0 else { return nil }

            var textBefore = fallbackBuffer
            var usedFallbackText = true
            var charAfter: Character? = nil
            var textAfterOnLine = ""
            var hasTextAfterOnLine = false
            var isAtDocumentStart = false

            let windowStart = max(0, selectedRange.location - 120)
            let beforeLen = selectedRange.location - windowStart
            let probedBefore = beforeLen > 0 ? stringForRange(element, location: windowStart, length: beforeLen) : nil

            // Fast O(1) path: read only the 120-char window around the caret via kAXStringForRangeParameterizedAttribute
            // so 50,000-character Notes/Mail/TextEdit drafts never copy the entire document on every keystroke!
            if beforeLen == 0 || probedBefore != nil {
                if let slice = probedBefore {
                    if slice.contains(where: { $0.isASCII && $0.isLetter }) {
                        textBefore = slice
                        usedFallbackText = false
                    }
                    if windowStart == 0 {
                        isAtDocumentStart = Self.isCurrentWordAtVeryStartOfDocument(fullTextBeforeCursor: slice)
                    }
                } else {
                    isAtDocumentStart = true
                    usedFallbackText = false
                }

                let totalCount = numberOfCharacters(element)
                let remaining = totalCount.map { max(0, $0 - selectedRange.location) } ?? 64
                let lookahead = min(64, remaining)
                if lookahead > 0, let afterSlice = stringForRange(element, location: selectedRange.location, length: lookahead), !afterSlice.isEmpty {
                    charAfter = afterSlice.first
                    textAfterOnLine = String(afterSlice.prefix(while: { !$0.isNewline }))
                    hasTextAfterOnLine = Self.lineHasVisibleTextAfterCaret(afterSlice)
                } else if beforeLen == 0,
                          let fullValue = copyStringAttribute(element, attribute: kAXValueAttribute as String),
                          !fullValue.isEmpty {
                    let afterSlice = String(fullValue.prefix(64))
                    charAfter = afterSlice.first
                    textAfterOnLine = String(afterSlice.prefix(while: { !$0.isNewline }))
                    hasTextAfterOnLine = Self.lineHasVisibleTextAfterCaret(afterSlice)
                }
            } else if let fullValue = copyStringAttribute(element, attribute: kAXValueAttribute as String),
                      !fullValue.isEmpty {
                let ns = fullValue as NSString
                if selectedRange.location <= ns.length {
                    if beforeLen > 0 {
                        let candidate = ns.substring(with: NSRange(location: windowStart, length: beforeLen))
                        if candidate.contains(where: { $0.isASCII && $0.isLetter }) {
                            textBefore = candidate
                            usedFallbackText = false
                        }
                    }

                    if windowStart == 0 {
                        let fullPrefix = ns.substring(with: NSRange(location: 0, length: selectedRange.location))
                        isAtDocumentStart = Self.isCurrentWordAtVeryStartOfDocument(fullTextBeforeCursor: fullPrefix)
                    }

                    if selectedRange.location < ns.length {
                        let lookaheadLen = min(64, ns.length - selectedRange.location)
                        let afterSlice = ns.substring(with: NSRange(location: selectedRange.location, length: lookaheadLen))
                        charAfter = afterSlice.first
                        textAfterOnLine = String(afterSlice.prefix(while: { !$0.isNewline }))
                        hasTextAfterOnLine = Self.lineHasVisibleTextAfterCaret(afterSlice)
                    }
                }
            }

            if !textBefore.isEmpty,
               let (axRect, font, prevCharWasZeroWidth) = characterRectAndFont(
                   element: element,
                   caretLocation: selectedRange.location,
                   isWebKit: isWebKit
               ) {
                let placement = ScreenGeometry.baselinePlacement(
                    forAXCharRect: axRect,
                    primaryScreenHeight: primaryHeight,
                    font: font,
                    verticalAdjustment: verticalAdjustment,
                    lineSpacingBias: spacingBias
                )
                let endsWithLetter = textBefore.last.map { $0.isASCII && $0.isLetter } ?? false
                recordStatus(String(
                    format: "app=%@ pid=%d->%d role=%@ path=range bias=%@ rect=(%.1fx%.1f) font=%.1f mid=%d doc0=%d",
                    app.bundleIdentifier ?? "?", app.processIdentifier, ownerPID, elemRole,
                    isWebKit ? "top" : "bot",
                    axRect.width, axRect.height, font.pointSize, hasTextAfterOnLine ? 1 : 0, isAtDocumentStart ? 1 : 0
                ))
                return CaretSnapshot(
                    textBeforeCursor: textBefore,
                    charAfterCursor: charAfter,
                    textAfterOnLine: textAfterOnLine,
                    hasTextAfterOnLine: hasTextAfterOnLine,
                    isAtDocumentStart: isAtDocumentStart,
                    isFallbackText: usedFallbackText,
                    isGlyphWidthZeroOnPrevChar: prevCharWasZeroWidth && endsWithLetter,
                    lineSpacingBias: spacingBias,
                    placement: placement,
                    font: font,
                    rawAXRect: axRect,
                    primaryScreenHeight: primaryHeight,
                    focusedElement: element,
                    caretLocation: selectedRange.location
                )
            }
        }

        // Path 2: WebKit / Chromium / Codex / Electron contenteditable TextMarker API.
        if let markerSnapshot = captureViaTextMarkers(
            element: element,
            fallbackBuffer: fallbackBuffer,
            primaryHeight: primaryHeight,
            verticalAdjustment: verticalAdjustment,
            lineSpacingBias: spacingBias
        ) {
            recordStatus(String(
                format: "app=%@ pid=%d->%d role=%@ path=marker bias=%@ rect=(%.1fx%.1f) font=%.1f after=%@",
                app.bundleIdentifier ?? "?", app.processIdentifier, ownerPID, elemRole,
                isWebKit ? "top" : "bot",
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
            stateLock.lock()
            configuredPIDs.remove(app.processIdentifier)
            chromiumEnhancedPIDs.remove(app.processIdentifier)
            if ownerPID > 0 && ownerPID != app.processIdentifier {
                configuredPIDs.remove(ownerPID)
                chromiumEnhancedPIDs.remove(ownerPID)
            }
            stateLock.unlock()
            enableAccessibilityOnPID(app.processIdentifier, enableChromiumEnhanced: enableChromiumBridge)
            if ownerPID > 0 && ownerPID != app.processIdentifier {
                enableAccessibilityOnPID(ownerPID, enableChromiumEnhanced: enableChromiumBridge)
            }
        }

        recordStatus("app=\(bundleID.isEmpty ? "?" : bundleID) pid=\(app.processIdentifier)->\(ownerPID) role=\(elemRole) attrs=\(attrCount) bounds=nil mDiag=\(lastMarkerDiag)")
        return nil
    }

    private func enableAccessibilityOnPID(_ pid: pid_t, enableChromiumEnhanced: Bool) {
        stateLock.lock()
        let needsManual = !configuredPIDs.contains(pid)
        let needsChromium = enableChromiumEnhanced && !chromiumEnhancedPIDs.contains(pid)
        stateLock.unlock()
        guard needsManual || needsChromium else { return }

        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, Self.axIPCDeadlineSeconds)
        if needsManual {
            if AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
                stateLock.lock()
                configuredPIDs.insert(pid)
                stateLock.unlock()
            }
        }
        if needsChromium {
            if AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success {
                stateLock.lock()
                chromiumEnhancedPIDs.insert(pid)
                stateLock.unlock()
            }
        }
    }

    private func isChromiumBackedApp(app: NSRunningApplication, bundleID: String) -> Bool {
        if Self.chromiumBundleIDPrefixes.contains(where: { bundleID.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        let cacheKey = bundleID.isEmpty ? (app.bundleURL?.path ?? "\(app.processIdentifier)") : bundleID
        stateLock.lock()
        if let cached = bundleChromiumCache[cacheKey] {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()
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
        stateLock.lock()
        bundleChromiumCache[cacheKey] = detected
        stateLock.unlock()
        return detected
    }

    private func helperPIDsInsideBundle(bundlePath: String, mainPID: pid_t) -> [pid_t] {
        let now = CFAbsoluteTimeGetCurrent()
        stateLock.lock()
        if let cached = helperPIDCache[mainPID], now - cached.timestamp <= 10.0 {
            stateLock.unlock()
            return cached.pids
        }
        stateLock.unlock()

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
        stateLock.lock()
        helperPIDCache[mainPID] = (matches, now)
        stateLock.unlock()
        return matches
    }

    private func resolveFocusedTextElement(app: NSRunningApplication, enableChromiumBridge: Bool) -> AXUIElement? {
        // 1. System-wide query traverses AXRemoteUIElement bridges into helper processes (like Codex Aperitif).
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, Self.axIPCDeadlineSeconds)
        var sysRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &sysRef) == .success,
           let sysRef, CFGetTypeID(sysRef) == AXUIElementGetTypeID() {
            let el = sysRef as! AXUIElement
            AXUIElementSetMessagingTimeout(el, Self.axIPCDeadlineSeconds)
            let drilled = drillFocusedChildIfNeeded(el)
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
            let el = sysRef as! AXUIElement
            AXUIElementSetMessagingTimeout(el, Self.axIPCDeadlineSeconds)
            return drillFocusedChildIfNeeded(el)
        }
        return focusedElement(forPID: app.processIdentifier)
    }

    private func focusedElement(forPID pid: pid_t) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, Self.axIPCDeadlineSeconds)
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
           let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let el = ref as! AXUIElement
            AXUIElementSetMessagingTimeout(el, Self.axIPCDeadlineSeconds)
            return el
        }
        return nil
    }

    private func drillFocusedChildIfNeeded(_ start: AXUIElement) -> AXUIElement {
        var current = start
        AXUIElementSetMessagingTimeout(current, Self.axIPCDeadlineSeconds)
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
            AXUIElementSetMessagingTimeout(child, Self.axIPCDeadlineSeconds)
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

    private func isWebKitTextElement(_ element: AXUIElement, isChromium: Bool) -> Bool {
        guard !isChromium else { return false }
        var attrNamesRef: CFArray?
        guard AXUIElementCopyAttributeNames(element, &attrNamesRef) == .success,
              let names = attrNamesRef as? [String] else {
            return false
        }
        return names.contains("AXTextInputMarkedTextMarkerRange")
            || names.contains("AXPerformsOwnTextStitching")
    }

    static func resolveCaretRect(
        prevCharRect: CGRect?,
        caretRect: CGRect?
    ) -> (rect: CGRect, prevCharZeroWidth: Bool)? {
        let validPrev = prevCharRect.flatMap { isValidCaretRect($0) ? $0 : nil }
        let validCaret = caretRect.flatMap { isValidCaretRect($0) ? $0 : nil }

        if var prev = validPrev {
            if let caret = validCaret {
                if caret.origin.y > prev.origin.y + 6 && caret.width <= 6 {
                    // Caret wrapped onto a new visual line while the preceding whitespace/newline stayed above.
                    return (caret, false)
                }
                if abs(caret.origin.y - prev.origin.y) < 6,
                   caret.origin.x > prev.maxX,
                   (caret.origin.x - prev.maxX) <= 18 {
                    prev.size.width = caret.origin.x - prev.origin.x
                }
            }
            return (prev, prev.width < 1.5)
        }
        if let caret = validCaret {
            return (caret, false)
        }
        return nil
    }

    private func characterRectAndFont(element: AXUIElement, caretLocation: Int, isWebKit: Bool) -> (CGRect, NSFont, Bool)? {
        let prevCandidate = caretLocation > 0 ? boundsForRange(element, location: caretLocation - 1, length: 1) : nil
        let caretCandidate = boundsForRange(element, location: caretLocation, length: 0)
        guard let (rect, prevCharZeroWidth) = Self.resolveCaretRect(prevCharRect: prevCandidate, caretRect: caretCandidate) else {
            return nil
        }

        if caretLocation > 0, let axFont = fontForRange(element, location: caretLocation - 1, length: 1) {
            return (rect, axFont, prevCharZeroWidth)
        }

        var fontBoxHeight = rect.height
        if isWebKit && rect.height > 20 && caretLocation > 0,
           let line1Rect = boundsForRange(element, location: 0, length: 1),
           Self.isValidCaretRect(line1Rect),
           (10.0...(rect.height - 1.0)).contains(line1Rect.height) {
            fontBoxHeight = line1Rect.height
        }

        let estimatedSize = ScreenGeometry.estimatedFontSize(forLineHeight: fontBoxHeight)
        return (rect, NSFont.systemFont(ofSize: estimatedSize), prevCharZeroWidth)
    }

    private func stringForRange(_ element: AXUIElement, location: Int, length: Int) -> String? {
        guard location >= 0, length > 0 else { return nil }
        var cfRange = CFRange(location: location, length: length)
        guard let rangeVal = AXValueCreate(.cfRange, &cfRange) else { return nil }

        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeVal,
            &ref
        ) == .success, let str = ref as? String else {
            return nil
        }
        return str
    }

    private func numberOfCharacters(_ element: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &ref
        ) == .success, let num = ref as? NSNumber else {
            return nil
        }
        return num.intValue
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
        verticalAdjustment: CGFloat,
        lineSpacingBias: LineSpacingBias
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
        var prevCandidate: CGRect?
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
                prevCandidate = boundsForTextMarkerRange(element: element, markerRange: prevRangeRef)
                resolvedFont = fontForTextMarkerRange(element: element, markerRange: prevRangeRef)
            }
        }

        let collapsedCandidate = boundsForTextMarkerRange(element: element, markerRange: markerRangeRef)
        let rawCandidateRect = collapsedCandidate ?? .zero
        guard let (axRect, prevCharZeroWidth) = Self.resolveCaretRect(
            prevCharRect: prevCandidate,
            caretRect: collapsedCandidate
        ) else {
            lastMarkerDiag = String(format: "badBounds(%.1fx%.1f@%.0f,%.0f)", rawCandidateRect.width, rawCandidateRect.height, rawCandidateRect.origin.x, rawCandidateRect.origin.y)
            return nil
        }

        // Scope textBefore and charAfter strictly to the current visual line inside `element`
        // so Chromium never walks out of the end of a chat box into adjacent toolbar buttons!
        var textBefore = fallbackBuffer
        var usedFallbackText = true
        var charAfter: Character? = nil
        var textAfterOnLine = ""
        var hasTextAfterOnLine = false
        var isAtDocumentStart = false

        // 1. O(1) bounded prefix + document-start check across soft-wrapped lines (never copies giant documents):
        if let resolved = readBoundedMarkerContext(element: element, endMarker: endMarker) {
            if resolved.prefix.contains(where: { $0.isASCII && $0.isLetter }) {
                textBefore = resolved.prefix
                usedFallbackText = false
            } else if resolved.prefix.isEmpty && resolved.isAtDocumentStart {
                usedFallbackText = false
            }
            isAtDocumentStart = resolved.isAtDocumentStart
        }

        // 2. Scope `charAfter` and `textAfterOnLine` strictly to the current visual line inside `element`
        // so Chromium never walks out of the end of a chat box into adjacent toolbar buttons!
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

            if usedFallbackText && !CFEqual(lineStart, endMarker) {
                if let beforeRangeRef = makeMarkerRange(element: element, start: lineStart, end: endMarker),
                   let beforeStr = stringForTextMarkerRange(element: element, markerRange: beforeRangeRef),
                   beforeStr.contains(where: { $0.isASCII && $0.isLetter }) {
                    textBefore = String(beforeStr.suffix(80))
                    usedFallbackText = false
                }
            }

            if !CFEqual(endMarker, lineEnd) {
                if let afterRangeRef = makeMarkerRange(element: element, start: endMarker, end: lineEnd),
                   let afterStr = stringForTextMarkerRange(element: element, markerRange: afterRangeRef),
                   !afterStr.isEmpty {
                    charAfter = afterStr.first
                    textAfterOnLine = String(afterStr.prefix(while: { !$0.isNewline }))
                    hasTextAfterOnLine = Self.lineHasVisibleTextAfterCaret(afterStr)
                }
            }
        } else {
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
                    if let nextRangeRef = makeMarkerRange(element: element, start: endMarker, end: nextMarkerRef),
                       let nextStr = stringForTextMarkerRange(element: element, markerRange: nextRangeRef) {
                        charAfter = nextStr.first
                        textAfterOnLine = String(nextStr.prefix(while: { !$0.isNewline }))
                        hasTextAfterOnLine = Self.lineHasVisibleTextAfterCaret(nextStr)
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
            verticalAdjustment: verticalAdjustment,
            lineSpacingBias: lineSpacingBias
        )
        let endsWithLetter = textBefore.last.map { $0.isASCII && $0.isLetter } ?? false
        return CaretSnapshot(
            textBeforeCursor: textBefore,
            charAfterCursor: charAfter,
            textAfterOnLine: textAfterOnLine,
            hasTextAfterOnLine: hasTextAfterOnLine,
            isAtDocumentStart: isAtDocumentStart,
            isFallbackText: usedFallbackText,
            isGlyphWidthZeroOnPrevChar: prevCharZeroWidth && endsWithLetter,
            lineSpacingBias: lineSpacingBias,
            placement: placement,
            font: font,
            rawAXRect: axRect,
            primaryScreenHeight: primaryHeight,
            focusedElement: element,
            caretLocation: nil
        )
    }

    func verifyDestinationStillMatches(
        snapshot: CaretSnapshot?,
        expectedBundleID: String?,
        expectedTrigger: String,
        expectedCharAfter: Character?,
        enableChromiumBridge: Bool
    ) -> VerifiedSnippetDestination? {
        guard AXIsProcessTrusted(),
              let snapshot,
              let expectedElem = snapshot.focusedElement,
              let app = effectiveFocusedApplication(),
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }
        if let expectedBundleID, app.bundleIdentifier != expectedBundleID {
            return nil
        }
        guard let element = resolveFocusedTextElement(app: app, enableChromiumBridge: enableChromiumBridge),
              CFEqual(element, expectedElem) else {
            return nil
        }

        if let expectedLoc = snapshot.caretLocation {
            guard let curRange = copySelectedRange(element),
                  curRange.length == 0,
                  curRange.location == expectedLoc else {
                return nil
            }
            let triggerUTF16Len = (expectedTrigger as NSString).length
            guard curRange.location >= triggerUTF16Len else { return nil }
            let actualTrigger: String? = stringForRange(
                element,
                location: curRange.location - triggerUTF16Len,
                length: triggerUTF16Len
            ) ?? copyStringAttribute(element, attribute: kAXValueAttribute as String).flatMap { fullValue in
                let ns = fullValue as NSString
                guard curRange.location <= ns.length else { return nil }
                return ns.substring(with: NSRange(location: curRange.location - triggerUTF16Len, length: triggerUTF16Len))
            }
            if let actualTrigger {
                guard actualTrigger == expectedTrigger else { return nil }
            } else if !snapshot.isFallbackText {
                return nil
            }
            if let expectedCharAfter,
               let afterNow = stringForRange(element, location: curRange.location, length: 1)?.first,
               afterNow != expectedCharAfter {
                return nil
            }
            return VerifiedSnippetDestination(element: element, caretLocation: curRange.location)
        }

        if let selectedRange = copySelectedRange(element), selectedRange.length != 0 {
            return nil
        }
        if let recheck = capture(
            targetApp: app,
            fallbackBuffer: expectedTrigger,
            enableChromiumBridge: enableChromiumBridge,
            verticalAdjustment: 0
        ) {
            guard let recheckElem = recheck.focusedElement, CFEqual(recheckElem, expectedElem) else {
                return nil
            }
            if !recheck.isFallbackText {
                guard recheck.textBeforeCursor.hasSuffix(expectedTrigger) else { return nil }
                if recheck.charAfterCursor != expectedCharAfter { return nil }
            }
        }
        return VerifiedSnippetDestination(element: element, caretLocation: nil)
    }

    func replaceRangeViaAX(
        element: AXUIElement,
        caretLocation: Int,
        trigger: String,
        replacement: String,
        cursorBackSteps: Int
    ) -> Bool {
        let triggerUTF16Count = (trigger as NSString).length
        guard caretLocation >= triggerUTF16Count else { return false }

        let startLoc = caretLocation - triggerUTF16Count
        var replaceRange = CFRange(location: startLoc, length: triggerUTF16Count)
        guard let replaceRangeVal = AXValueCreate(.cfRange, &replaceRange),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, replaceRangeVal) == .success else {
            return false
        }

        if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, replacement as CFString) != .success {
            var restoreRange = CFRange(location: caretLocation, length: 0)
            if let restoreVal = AXValueCreate(.cfRange, &restoreRange) {
                _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, restoreVal)
            }
            return false
        }

        let replacementUTF16Len = (replacement as NSString).length
        if let verified = stringForRange(element, location: startLoc, length: replacementUTF16Len),
           verified != replacement {
            return false
        }

        let targetCharCount = max(0, replacement.count - cursorBackSteps)
        let finalUTF16Offset = (String(replacement.prefix(targetCharCount)) as NSString).length
        var finalRange = CFRange(location: startLoc + finalUTF16Offset, length: 0)
        if let finalVal = AXValueCreate(.cfRange, &finalRange) {
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, finalVal)
        }
        return true
    }

    /// Live lightweight inspection called on `Space` so even 1- or 2-letter sentence starters ("do ", "in ", "we ")
    /// typed faster than 16ms have exact ground-truth document-start & period context without race conditions.
    func inspectLiveSentenceContext(
        targetApp: NSRunningApplication?,
        expectedTrailingWord: String,
        enableChromiumBridge: Bool
    ) -> (context: String?, isAtDocumentStart: Bool, sliceStartsAtDocumentZero: Bool) {
        guard AXIsProcessTrusted(),
              let app = targetApp ?? effectiveFocusedApplication(),
              let element = resolveFocusedTextElement(app: app, enableChromiumBridge: enableChromiumBridge) else {
            return (nil, false, false)
        }

        let expectedNorm = ObviousTypoCorrector.normalizeApostrophes(expectedTrailingWord).lowercased()

        // 1. Standard O(1) windowed AXStringForRange + AXSelectedTextRange (with AXValue fallback)
        if let selectedRange = copySelectedRange(element), selectedRange.length == 0 {
            let windowStart = max(0, selectedRange.location - 120)
            let beforeLen = selectedRange.location - windowStart
            if beforeLen > 0, let slice = stringForRange(element, location: windowStart, length: beforeLen),
               ObviousTypoCorrector.normalizeApostrophes(slice).lowercased().hasSuffix(expectedNorm) {
                let docStart = (windowStart == 0) && Self.isCurrentWordAtVeryStartOfDocument(fullTextBeforeCursor: slice)
                return (slice, docStart, windowStart == 0)
            }
            if let fullValue = copyStringAttribute(element, attribute: kAXValueAttribute as String), !fullValue.isEmpty {
                let ns = fullValue as NSString
                if selectedRange.location <= ns.length {
                    let slice = ns.substring(with: NSRange(location: windowStart, length: beforeLen))
                    if ObviousTypoCorrector.normalizeApostrophes(slice).lowercased().hasSuffix(expectedNorm) {
                        let docStart = (windowStart == 0) && Self.isCurrentWordAtVeryStartOfDocument(fullTextBeforeCursor: slice)
                        return (slice, docStart, windowStart == 0)
                    }
                }
            }
        }

        // 2. WebKit / Chromium / Electron O(1) bounded AXTextMarker read
        var markerRangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRangeRef) == .success,
           let markerRangeRef {
            let endMarker = AXTextMarkerRangeCopyEndMarker(markerRangeRef as! AXTextMarkerRange)
            if let resolved = readBoundedMarkerContext(
                element: element, endMarker: endMarker, sentenceBoundaryWord: expectedTrailingWord
            ),
               ObviousTypoCorrector.normalizeApostrophes(resolved.prefix).lowercased().hasSuffix(expectedNorm) {
                return (resolved.prefix, resolved.isAtDocumentStart, resolved.sliceStartsAtDocumentZero)
            }
        }

        return (nil, false, false)
    }

    /// Reads up to 120 trailing characters before `endMarker` + exact `isAtDocumentStart` in O(1):
    /// - Short inputs (`<= 240` chars from `AXStartTextMarker`): copies `[AXStartTextMarker, endMarker]` directly.
    /// - Long drafts (`> 240` chars, or `AXWebArea` contenteditable): `isAtDocumentStart` is `false` when `len > 240`,
    ///   and reads only the current logical paragraph (`AXParagraphTextMarkerRangeForTextMarker`, bounded to `<= 2000` chars)
    ///   so soft-wrapped lines keep full sentence context without ever copying large documents!
    private func readBoundedMarkerContext(
        element: AXUIElement,
        endMarker: AXTextMarker,
        sentenceBoundaryWord: String? = nil
    ) -> (prefix: String, isAtDocumentStart: Bool, sliceStartsAtDocumentZero: Bool)? {
        let role = copyStringAttribute(element, attribute: kAXRoleAttribute as String) ?? ""
        var confirmedPastDocStart = false

        if role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox" {
            var startMarkerRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXStartTextMarker" as CFString, &startMarkerRef) == .success,
               let startMarkerRef {
                if CFEqual(startMarkerRef, endMarker) {
                    return ("", true, true)
                }
                if let fullRange = makeMarkerRange(element: element, start: startMarkerRef, end: endMarker) {
                    var lenRef: CFTypeRef?
                    let hasLen = AXUIElementCopyParameterizedAttributeValue(
                        element,
                        "AXLengthForTextMarkerRange" as CFString,
                        fullRange,
                        &lenRef
                    ) == .success
                    let charLen = (lenRef as? NSNumber)?.intValue ?? 0

                    if !hasLen || charLen <= 240 {
                        if let raw = stringForTextMarkerRange(element: element, markerRange: fullRange) {
                            var cleaned = ObviousTypoCorrector.cleanAccessibilityText(raw)
                            if cleaned.count <= 300 {
                                // When a rich `contenteditable` editor (`<p>All done.</p><p>also</p>`) omits `\n` in `fullRange`
                                // (`"All done.also"`), verify against `AXParagraphTextMarkerRangeForTextMarker` so paragraph breaks stay intact!
                                if let sentenceBoundaryWord,
                                   cleaned.count > sentenceBoundaryWord.count {
                                    let before = cleaned.dropLast(min(cleaned.count, sentenceBoundaryWord.count))
                                    if before.last?.isWhitespace != true {
                                        let paraPrefix = currentParagraphPrefix(element: element, endMarker: endMarker)
                                        cleaned = ObviousTypoCorrector.reconcileParagraphBoundaryInFullSlice(
                                            fullSlice: cleaned,
                                            paragraphSlice: paraPrefix,
                                            firstWord: sentenceBoundaryWord
                                        )
                                    }
                                }
                                let docStart = Self.isCurrentWordAtVeryStartOfDocument(fullTextBeforeCursor: cleaned)
                                return (String(cleaned.suffix(120)), docStart, cleaned.count <= 120)
                            }
                        }
                    }
                    if hasLen && charLen > 240 {
                        confirmedPastDocStart = true
                    }
                }
            }
        }

        // Paragraph-scoped read for long drafts (> 240 chars) or AXWebArea rich editors:
        var paraRangeRef: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXParagraphTextMarkerRangeForTextMarker" as CFString,
            endMarker,
            &paraRangeRef
        ) == .success, let paraRangeRef {
            let paraRange = paraRangeRef as! AXTextMarkerRange
            let paraStart = AXTextMarkerRangeCopyStartMarker(paraRange)
            if !CFEqual(paraStart, endMarker),
               let paraPairRange = makeMarkerRange(element: element, start: paraStart, end: endMarker) {
                var pLenRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element,
                    "AXLengthForTextMarkerRange" as CFString,
                    paraPairRange,
                    &pLenRef
                ) == .success, let pNum = pLenRef as? NSNumber, pNum.intValue > 2000 {
                    // Extremely long single paragraph (> 2000 chars without newline): fall back to current visual line
                    return nil
                }
                if let rawPara = stringForTextMarkerRange(element: element, markerRange: paraPairRange) {
                    let cleaned = ObviousTypoCorrector.cleanAccessibilityText(rawPara)
                    if let sentenceBoundaryWord,
                       let withPrevious = ObviousTypoCorrector.sentenceContext(
                           forFirstWord: sentenceBoundaryWord,
                           paragraphPrefix: cleaned,
                           readPreviousTail: { previousParagraphTail(element: element, before: paraStart) }
                       ) {
                        return (withPrevious, false, false)
                    }
                    var docStart = false
                    var startsAtZero = false
                    if !confirmedPastDocStart {
                        var prevBeforePara: CFTypeRef?
                        let hasEarlier = AXUIElementCopyParameterizedAttributeValue(
                            element,
                            "AXPreviousTextMarkerForTextMarker" as CFString,
                            paraStart,
                            &prevBeforePara
                        ) == .success && prevBeforePara != nil
                        if !hasEarlier {
                            docStart = Self.isCurrentWordAtVeryStartOfDocument(fullTextBeforeCursor: cleaned)
                            startsAtZero = (cleaned.count <= 120)
                        }
                    }
                    return (String(cleaned.suffix(120)), docStart, startsAtZero)
                }
            }
        }

        return nil
    }

    private func currentParagraphPrefix(element: AXUIElement, endMarker: AXTextMarker) -> String? {
        var paraRangeRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXParagraphTextMarkerRangeForTextMarker" as CFString,
            endMarker,
            &paraRangeRef
        ) == .success, let paraRangeRef else {
            return nil
        }
        let paraStart = AXTextMarkerRangeCopyStartMarker(paraRangeRef as! AXTextMarkerRange)
        guard !CFEqual(paraStart, endMarker),
              let pair = makeMarkerRange(element: element, start: paraStart, end: endMarker),
              let str = stringForTextMarkerRange(element: element, markerRange: pair) else {
            return nil
        }
        return ObviousTypoCorrector.cleanAccessibilityText(str)
    }

    private func previousParagraphTail(element: AXUIElement, before paragraphStart: AXTextMarker) -> String? {
        if let direct = readTailBeforeParagraph(on: element, before: paragraphStart) {
            return direct
        }
        // Rich block editors (ProseMirror, Lexical, Notion) may focus a per-paragraph child `AXGroup` where
        // `AXStartTextMarker == paragraphStart`; climb to the editable container if present.
        var editableRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &editableRef) == .success,
           let editableRef, CFGetTypeID(editableRef) == AXUIElementGetTypeID() {
            let ancestor = editableRef as! AXUIElement
            if !CFEqual(ancestor, element) {
                AXUIElementSetMessagingTimeout(ancestor, Self.axIPCDeadlineSeconds)
                if let fromEditable = readTailBeforeParagraph(on: ancestor, before: paragraphStart) {
                    return fromEditable
                }
            }
        }
        var current = element
        for _ in 0..<2 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as String as CFString, &parentRef) == .success,
                  let parentRef, CFGetTypeID(parentRef) == AXUIElementGetTypeID() else {
                break
            }
            let parent = parentRef as! AXUIElement
            if CFEqual(parent, current) { break }
            AXUIElementSetMessagingTimeout(parent, Self.axIPCDeadlineSeconds)
            let pRole = copyStringAttribute(parent, attribute: kAXRoleAttribute as String) ?? ""
            guard pRole != "AXWindow" && pRole != "AXApplication" && pRole != "AXScrollArea" else { break }
            if let found = readTailBeforeParagraph(on: parent, before: paragraphStart) {
                return found
            }
            current = parent
        }
        return nil
    }

    private func readTailBeforeParagraph(on container: AXUIElement, before paragraphStart: AXTextMarker) -> String? {
        var documentStart: CFTypeRef?
        guard AXUIElementCopyAttributeValue(container, "AXStartTextMarker" as CFString, &documentStart) == .success,
              let documentStart, !CFEqual(documentStart, paragraphStart) else {
            return nil
        }

        // 1. Prefer reading the preceding paragraph via `AXPreviousTextMarkerForTextMarker` + `AXParagraphTextMarkerRangeForTextMarker`
        var prevMarker: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            container, "AXPreviousTextMarkerForTextMarker" as CFString, paragraphStart, &prevMarker
        ) == .success, var probeMarker = prevMarker, !CFEqual(probeMarker, paragraphStart) {
            for _ in 0..<2 {
                var prevParaRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    container, "AXParagraphTextMarkerRangeForTextMarker" as CFString, probeMarker, &prevParaRef
                ) == .success, let prevParaRef {
                    let prevParaStart = AXTextMarkerRangeCopyStartMarker(prevParaRef as! AXTextMarkerRange)
                    if !CFEqual(prevParaStart, paragraphStart),
                       let spanRange = makeMarkerRange(element: container, start: prevParaStart, end: paragraphStart) {
                        var lenRef: CFTypeRef?
                        let lenOK = AXUIElementCopyParameterizedAttributeValue(
                            container, "AXLengthForTextMarkerRange" as CFString, spanRange, &lenRef
                        ) == .success
                        let spanLen = (lenRef as? NSNumber)?.intValue ?? 0
                        if lenOK && (1...300).contains(spanLen),
                           let raw = stringForTextMarkerRange(element: container, markerRange: spanRange) {
                            let cleaned = ObviousTypoCorrector.cleanAccessibilityText(raw)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !cleaned.isEmpty {
                                return String(cleaned.suffix(120))
                            }
                        }
                    }
                }
                var earlierRef: CFTypeRef?
                guard AXUIElementCopyParameterizedAttributeValue(
                    container, "AXPreviousTextMarkerForTextMarker" as CFString, probeMarker, &earlierRef
                ) == .success, let earlierRef, !CFEqual(earlierRef, probeMarker) else {
                    break
                }
                probeMarker = earlierRef
            }
        }

        // 2. Fallback: step back to previous word start (verifying `previousWord` stays inside `container` via length >= 0,
        //    avoiding `CFEqual` false negatives caused by WebKit/Blink text-marker affinity metadata!)
        var previousWord: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            container, "AXPreviousWordStartTextMarkerForTextMarker" as CFString, paragraphStart, &previousWord
        ) == .success, let previousWord, !CFEqual(previousWord, paragraphStart),
              let startRange = makeMarkerRange(element: container, start: documentStart, end: previousWord) else {
            return nil
        }
        var prefixLenRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            container, "AXLengthForTextMarkerRange" as CFString, startRange, &prefixLenRef
        ) == .success, let prefixLen = (prefixLenRef as? NSNumber)?.intValue, prefixLen >= 0,
              let tailRange = makeMarkerRange(element: container, start: previousWord, end: paragraphStart) else {
            return nil
        }
        var lengthRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            container, "AXLengthForTextMarkerRange" as CFString, tailRange, &lengthRef
        ) == .success, let length = (lengthRef as? NSNumber)?.intValue, (1...120).contains(length),
              let raw = stringForTextMarkerRange(element: container, markerRange: tailRange) else {
            return nil
        }
        return ObviousTypoCorrector.cleanAccessibilityText(raw)
    }

    private func makeMarkerRange(element: AXUIElement, start: CFTypeRef, end: CFTypeRef) -> CFTypeRef? {
        let pair = [start, end] as CFArray
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXTextMarkerRangeForUnorderedTextMarkers" as CFString,
            pair,
            &rangeRef
        ) == .success else {
            return nil
        }
        return rangeRef
    }

    /// Returns true ONLY if `fullTextBeforeCursor` contains nothing before the current trailing ASCII word
    /// (except optional leading spaces or opening quotes at index 0—NO newlines, NO earlier words!).
    static func isCurrentWordAtVeryStartOfDocument(fullTextBeforeCursor: String) -> Bool {
        let chars = Array(fullTextBeforeCursor)
        var wordStart = chars.count
        while wordStart > 0 {
            let ch = chars[wordStart - 1]
            if (ch.isASCII && ch.isLetter)
                || (ObviousTypoCorrector.isApostrophe(ch) && wordStart >= 2 && chars[wordStart - 2].isASCII && chars[wordStart - 2].isLetter) {
                wordStart -= 1
            } else {
                break
            }
        }
        guard wordStart < chars.count else { return false }
        let beforeWord = String(chars[0..<wordStart])
        // Only allow spaces, tabs, or opening quote/paren at the very start of the input box (never newlines or earlier words!)
        let allowedLeadingAtIndexZero = CharacterSet(charactersIn: " \t\"'“‘([")
        return beforeWord.unicodeScalars.allSatisfy { allowedLeadingAtIndexZero.contains($0) }
    }

    private static func lineHasVisibleTextAfterCaret(_ slice: String) -> Bool {
        let sameLine = slice.prefix(while: { !$0.isNewline })
        return sameLine.contains { ch in
            !ch.isWhitespace && ch != "\u{FFFC}" && ch != "\u{200B}" && ch != "\u{FEFF}"
        }
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
        stateLock.lock()
        _lastDebugSummary = "\(_lastDebugSummary) \(outcome)"
        stateLock.unlock()
    }

    private func recordStatus(_ status: String) {
        stateLock.lock()
        _lastDebugSummary = status
        stateLock.unlock()
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
