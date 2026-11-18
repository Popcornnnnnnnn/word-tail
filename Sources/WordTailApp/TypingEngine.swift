import AppKit
import ApplicationServices
import Carbon.HIToolbox
import WordTailCore

final class TypingEngine {
    static let injectedEventTag: Int64 = 0x5754_4149 // "WTAI"

    private let completer: WordCompleter
    private let historyStore: UserHistoryStore
    private let inputGuard: InputGuard
    private let axContext = AXCaretContext()
    private let overlay = GhostOverlayWindow()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var debounceWorkItem: DispatchWorkItem?
    private var rollingBuffer: String = ""

    private var activeCandidates: [CompletionMatch] = []
    private var activeCandidateIndex: Int = 0
    private var activeSnapshot: CaretSnapshot?

    private struct PinnedLiveSample {
        let bundleID: String
        let suffix: String
        let fullWord: String
        let rawAXRect: CGRect
        let primaryScreenHeight: CGFloat
        let font: NSFont
    }
    private var lastLiveSample: PinnedLiveSample?

    var onStateChanged: (() -> Void)?

    var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "WordTailIsEnabled") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "WordTailIsEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "WordTailIsEnabled")
            if !newValue {
                dismissOverlay(clearBuffer: true)
            }
            onStateChanged?()
        }
    }

    private let globalOffsetKey = "WordTailGlobalVerticalOffset"
    private let perAppOffsetKey = "WordTailPerAppVerticalOffsets"

    var globalVerticalAdjustment: CGFloat {
        get {
            if UserDefaults.standard.object(forKey: globalOffsetKey) == nil {
                return ScreenGeometry.defaultVerticalOffset
            }
            return CGFloat(UserDefaults.standard.double(forKey: globalOffsetKey))
        }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: globalOffsetKey)
            refreshPinnedOverlayIfVisible()
        }
    }

    func customVerticalAdjustment(forBundleID bundleID: String) -> CGFloat? {
        if let dict = UserDefaults.standard.dictionary(forKey: perAppOffsetKey) as? [String: Double],
           let val = dict[bundleID] {
            return CGFloat(val)
        }
        if let builtIn = ScreenGeometry.builtInAppVerticalOffsets[bundleID] {
            return builtIn
        }
        return nil
    }

    func verticalAdjustment(forBundleID bundleID: String?) -> CGFloat {
        if let bundleID, let custom = customVerticalAdjustment(forBundleID: bundleID) {
            return custom
        }
        return globalVerticalAdjustment
    }

    func setVerticalAdjustment(_ value: CGFloat?, forBundleID bundleID: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: perAppOffsetKey) as? [String: Double]) ?? [:]
        if let value {
            dict[bundleID] = Double(value)
        } else {
            dict.removeValue(forKey: bundleID)
        }
        UserDefaults.standard.set(dict, forKey: perAppOffsetKey)
        refreshPinnedOverlayIfVisible()
    }

    var minimumPrefixLength: Int {
        get { completer.minimumPrefixLength }
        set {
            completer.minimumPrefixLength = newValue
            UserDefaults.standard.set(newValue, forKey: "WordTailMinPrefix")
        }
    }

    var minimumSuffixLength: Int {
        get { completer.minimumSuffixLength }
        set {
            completer.minimumSuffixLength = newValue
            UserDefaults.standard.set(newValue, forKey: "WordTailMinSuffix")
        }
    }

    var appendSpaceOnAccept: Bool {
        get { UserDefaults.standard.bool(forKey: "WordTailAppendSpaceOnAccept") }
        set { UserDefaults.standard.set(newValue, forKey: "WordTailAppendSpaceOnAccept") }
    }

    var enableTechLexicon: Bool {
        get { completer.enableTechLexicon }
        set {
            completer.enableTechLexicon = newValue
            UserDefaults.standard.set(newValue, forKey: "WordTailEnableTechLexicon")
        }
    }

    var enableGlobalHotkey: Bool {
        get {
            if UserDefaults.standard.object(forKey: "WordTailEnableGlobalHotkey") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "WordTailEnableGlobalHotkey")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "WordTailEnableGlobalHotkey")
        }
    }

    var ghostOpacity: CGFloat {
        get {
            if UserDefaults.standard.object(forKey: "WordTailGhostOpacity") == nil {
                return 0.38
            }
            return CGFloat(UserDefaults.standard.double(forKey: "WordTailGhostOpacity"))
        }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: "WordTailGhostOpacity")
            refreshPinnedOverlayIfVisible()
        }
    }

    var learnedWordsCount: Int {
        historyStore.learnedWordsCount
    }

    func vocabularyEntries() -> [VocabularyEntry] {
        historyStore.allEntries()
    }

    @discardableResult
    func addCustomWord(_ word: String) -> Bool {
        historyStore.addCustomWord(word, persistAsync: false)
    }

    func removeVocabularyWord(_ word: String) {
        historyStore.removeWord(word)
    }

    func clearLearnedWords() {
        historyStore.clearAll()
    }

    var enableChromiumBridge: Bool {
        get {
            if UserDefaults.standard.object(forKey: "WordTailChromiumBridge") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "WordTailChromiumBridge")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "WordTailChromiumBridge")
        }
    }

    init(
        completer: WordCompleter,
        historyStore: UserHistoryStore,
        inputGuard: InputGuard
    ) {
        self.completer = completer
        self.historyStore = historyStore
        self.inputGuard = inputGuard
        if UserDefaults.standard.object(forKey: "WordTailMinPrefix") != nil {
            completer.minimumPrefixLength = max(2, UserDefaults.standard.integer(forKey: "WordTailMinPrefix"))
        }
        if UserDefaults.standard.object(forKey: "WordTailMinSuffix") != nil {
            completer.minimumSuffixLength = max(1, UserDefaults.standard.integer(forKey: "WordTailMinSuffix"))
        }
        if UserDefaults.standard.object(forKey: "WordTailEnableTechLexicon") != nil {
            completer.enableTechLexicon = UserDefaults.standard.bool(forKey: "WordTailEnableTechLexicon")
        }
        observeWorkspaceNotifications()
    }

    var lastDebugSummary: String {
        axContext.lastDebugSummary
    }

    var isTapActive: Bool {
        if let tap = eventTap {
            return CGEvent.tapIsEnabled(tap: tap)
        }
        return false
    }

    @discardableResult
    func start() -> Bool {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            warmUpRunningFrontApps()
            return CGEvent.tapIsEnabled(tap: tap)
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<TypingEngine>.fromOpaque(refcon).takeUnretainedValue()
                return engine.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        warmUpRunningFrontApps()
        return CGEvent.tapIsEnabled(tap: tap)
    }

    private func warmUpRunningFrontApps() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            axContext.warmUpApplication(app, enableChromiumBridge: enableChromiumBridge)
        }
    }

    func stop() {
        dismissOverlay(clearBuffer: true)
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    private func observeWorkspaceNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == Bundle.main.bundleIdentifier {
                return
            }
            self.lastLiveSample = nil
            self.dismissOverlay(clearBuffer: true)
            if let app {
                self.axContext.warmUpApplication(app, enableChromiumBridge: self.enableChromiumBridge)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.dismissOverlay(clearBuffer: true)
        }
    }

    private func handleCGEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.injectedEventTag {
            return Unmanaged.passUnretained(event)
        }

        // Global toggle hotkey: Control + Option + W
        if type == .keyDown {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            if enableGlobalHotkey,
               keyCode == kVK_ANSI_W,
               flags.contains(.maskControl),
               flags.contains(.maskAlternate),
               !flags.contains(.maskCommand),
               !flags.contains(.maskShift) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isEnabled.toggle()
                }
                return nil
            }
        }

        guard isEnabled else {
            return Unmanaged.passUnretained(event)
        }

        if type != .keyDown {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
                    return
                }
                let isClick = (type != .scrollWheel)
                self.lastLiveSample = nil
                self.dismissOverlay(clearBuffer: isClick)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Candidate cycling while ghost word is visible: Option + ] (next) / Option + [ (previous)
        if overlay.isVisible,
           activeCandidates.count > 1,
           flags.contains(.maskAlternate),
           !flags.contains(.maskCommand),
           !flags.contains(.maskControl),
           (keyCode == kVK_ANSI_RightBracket || keyCode == kVK_ANSI_LeftBracket) {
            let delta = (keyCode == kVK_ANSI_RightBracket) ? 1 : -1
            let count = activeCandidates.count
            activeCandidateIndex = (activeCandidateIndex + delta + count) % count
            if let snapshot = activeSnapshot {
                let chosen = activeCandidates[activeCandidateIndex]
                overlay.show(
                    suffix: chosen.suffix,
                    fullWord: chosen.fullWord,
                    placement: snapshot.placement,
                    font: snapshot.font,
                    opacity: ghostOpacity
                )
            }
            return nil
        }

        let hasCommandOrCtrlOrOption = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
        if hasCommandOrCtrlOrOption {
            DispatchQueue.main.async { [weak self] in
                self?.dismissOverlay(clearBuffer: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Tab while ghost text is visible -> swallow Tab and inject the remaining word suffix (+ optional trailing space)!
        if keyCode == kVK_Tab, !flags.contains(.maskShift), overlay.isVisible,
           let suffix = overlay.currentSuffix, let fullWord = overlay.currentFullWord {
            debounceWorkItem?.cancel()
            let charAfter = activeSnapshot?.charAfterCursor
            let shouldAddSpace = appendSpaceOnAccept && WordCompleter.shouldAppendTrailingSpace(charAfterCursor: charAfter)
            let textToInsert = shouldAddSpace ? (suffix + " ") : suffix

            overlay.hide()
            activeCandidates.removeAll(keepingCapacity: true)
            activeSnapshot = nil

            rollingBuffer.append(textToInsert)
            if rollingBuffer.count > 80 {
                rollingBuffer = String(rollingBuffer.suffix(80))
            }
            DispatchQueue.main.async { [weak self] in
                self?.injectUnicodeString(textToInsert)
                self?.historyStore.recordAcceptance(of: fullWord)
            }
            return nil
        }

        // Esc while ghost text is visible -> swallow Esc and dismiss ghost text only.
        if keyCode == kVK_Escape, overlay.isVisible {
            overlay.hide()
            activeCandidates.removeAll(keepingCapacity: true)
            activeSnapshot = nil
            return nil
        }

        // Backspace -> trim rolling buffer and re-query or hide.
        if keyCode == kVK_Delete {
            if !rollingBuffer.isEmpty {
                rollingBuffer.removeLast()
            }
            schedulePredictionQuery()
            return Unmanaged.passUnretained(event)
        }

        // Navigation / Return / Tab (without suggestion) -> clear buffer and hide.
        if Self.navigationKeyCodes.contains(keyCode) {
            DispatchQueue.main.async { [weak self] in
                self?.dismissOverlay(clearBuffer: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if let typed = Self.unicodeString(from: event), !typed.isEmpty {
            rollingBuffer.append(typed)
            if rollingBuffer.count > 80 {
                rollingBuffer = String(rollingBuffer.suffix(80))
            }

            if let last = typed.last, (last.isLetter && last.isASCII) || last == "'" {
                schedulePredictionQuery()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.dismissOverlay(clearBuffer: false)
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func schedulePredictionQuery() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.evaluateAndRenderPrediction()
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16), execute: item)
    }

    private func evaluateAndRenderPrediction() {
        let targetApp = axContext.effectiveFocusedApplication()
        let frontBundle = targetApp?.bundleIdentifier
        if frontBundle == Bundle.main.bundleIdentifier {
            overlay.hide()
            return
        }
        guard inputGuard.shouldAllowPrediction(frontmostBundleID: frontBundle) else {
            overlay.hide()
            return
        }

        guard let snapshot = axContext.capture(
            targetApp: targetApp,
            fallbackBuffer: rollingBuffer,
            enableChromiumBridge: enableChromiumBridge,
            verticalAdjustment: verticalAdjustment(forBundleID: frontBundle)
        ) else {
            overlay.hide()
            return
        }

        let matches = completer.candidates(
            textBeforeCursor: snapshot.textBeforeCursor,
            charAfterCursor: snapshot.charAfterCursor,
            limit: 5
        )
        guard let first = matches.first else {
            axContext.recordOverlayOutcome("shown=no")
            activeCandidates.removeAll(keepingCapacity: true)
            activeSnapshot = nil
            overlay.hide()
            return
        }

        activeCandidates = matches
        activeCandidateIndex = 0
        activeSnapshot = snapshot

        axContext.recordOverlayOutcome(String(
            format: "shown=yes(len=%d,n=%d,x=%.0f,y=%.0f)",
            first.suffix.count, matches.count, snapshot.placement.anchorX, snapshot.placement.baselineY
        ))

        if let frontBundle {
            lastLiveSample = PinnedLiveSample(
                bundleID: frontBundle,
                suffix: first.suffix,
                fullWord: first.fullWord,
                rawAXRect: snapshot.rawAXRect,
                primaryScreenHeight: snapshot.primaryScreenHeight,
                font: snapshot.font
            )
        }

        overlay.show(
            suffix: first.suffix,
            fullWord: first.fullWord,
            placement: snapshot.placement,
            font: snapshot.font,
            opacity: ghostOpacity
        )
    }

    func refreshPinnedOverlayIfVisible() {
        guard let sample = lastLiveSample else { return }
        let offset = verticalAdjustment(forBundleID: sample.bundleID)
        let placement = ScreenGeometry.baselinePlacement(
            forAXCharRect: sample.rawAXRect,
            primaryScreenHeight: sample.primaryScreenHeight,
            font: sample.font,
            verticalAdjustment: offset
        )
        overlay.show(
            suffix: sample.suffix,
            fullWord: sample.fullWord,
            placement: placement,
            font: sample.font,
            opacity: ghostOpacity
        )
    }

    private func dismissOverlay(clearBuffer: Bool) {
        debounceWorkItem?.cancel()
        overlay.hide()
        activeCandidates.removeAll(keepingCapacity: true)
        activeSnapshot = nil
        if clearBuffer {
            rollingBuffer.removeAll(keepingCapacity: true)
        }
    }

    private func injectUnicodeString(_ text: String) {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty,
              let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else {
            return
        }

        down.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventTag)

        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func unicodeString(from event: CGEvent) -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    private static let navigationKeyCodes: Set<Int> = [
        kVK_Return,
        kVK_ANSI_KeypadEnter,
        kVK_Tab,
        kVK_Escape,
        kVK_LeftArrow,
        kVK_RightArrow,
        kVK_UpArrow,
        kVK_DownArrow,
        kVK_Home,
        kVK_End,
        kVK_PageUp,
        kVK_PageDown
    ]
}
