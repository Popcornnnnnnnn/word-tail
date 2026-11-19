import AppKit
import ApplicationServices
import Carbon.HIToolbox
import WordTailCore

final class TypingEngine {
    static let injectedEventTag: Int64 = 0x5754_4149 // "WTAI"

    private let completer: WordCompleter
    private let historyStore: UserHistoryStore
    private let habitTracker: TypingHabitTracker
    let keyStatsStore: KeyStatsStore
    private let inputGuard: InputGuard
    private let axContext = AXCaretContext()
    private let overlay = GhostOverlayWindow()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var telemetryTap: CFMachPort?
    private var telemetryRunLoopSource: CFRunLoopSource?
    private var debounceWorkItem: DispatchWorkItem?
    private var rollingBuffer: String = ""
    private var lastObservedBundleID: String?
    private var lastObservedAppName: String?
    private var lastKnownRomanLayout: Bool = InputGuard.isCurrentInputSourceRomanKeyboardLayout()

    private var activeCandidates: [CompletionMatch] = []
    private var activeCandidateIndex: Int = 0
    private var activeSnapshot: CaretSnapshot?
    private var activeBundleID: String?
    private var activeAppName: String?

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

    var enableHabitLearning: Bool {
        get {
            if UserDefaults.standard.object(forKey: "WordTailEnableHabitLearning") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "WordTailEnableHabitLearning")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "WordTailEnableHabitLearning")
            if !newValue {
                habitTracker.resetSessionContext()
            }
        }
    }

    func insightsSnapshot() -> TypingInsightsSnapshot {
        habitTracker.snapshot()
    }

    func topBigrams(limit: Int = 8) -> [BigramHabitEntry] {
        historyStore.topBigrams(limit: limit)
    }

    func clearInsightsAndContextualHabits() {
        habitTracker.clearAll()
        historyStore.clearContextualHabitsOnly()
    }

    var enableKeyStatsTracking: Bool {
        get {
            if UserDefaults.standard.object(forKey: "WordTailEnableKeyStats") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "WordTailEnableKeyStats")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "WordTailEnableKeyStats")
        }
    }

    var showMenuBarKeyCount: Bool {
        get { UserDefaults.standard.bool(forKey: "WordTailShowMenuBarKeyCount") }
        set {
            UserDefaults.standard.set(newValue, forKey: "WordTailShowMenuBarKeyCount")
            onStateChanged?()
        }
    }

    func flushAllTelemetry() {
        keyStatsStore.flushNow()
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
        habitTracker: TypingHabitTracker = TypingHabitTracker(),
        keyStatsStore: KeyStatsStore = KeyStatsStore(),
        inputGuard: InputGuard
    ) {
        self.completer = completer
        self.historyStore = historyStore
        self.habitTracker = habitTracker
        self.keyStatsStore = keyStatsStore
        self.inputGuard = inputGuard
        completer.habitTracker = habitTracker
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            self.lastObservedBundleID = front.bundleIdentifier
            self.lastObservedAppName = front.localizedName
        }
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
        startPassiveTelemetryTapIfNeeded()

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
        keyStatsStore.flushNow()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let tTap = telemetryTap {
            CGEvent.tapEnable(tap: tTap, enable: false)
        }
    }

    /// Separate `.listenOnly` passive tap for KeyStats telemetry (mouse distance, scroll, clicks, modifiers, key heatmap)
    /// so high-frequency 120Hz–1000Hz mouse movements never wait on the active key-interception tap.
    private func startPassiveTelemetryTapIfNeeded() {
        if let tTap = telemetryTap {
            CGEvent.tapEnable(tap: tTap, enable: true)
            return
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<TypingEngine>.fromOpaque(refcon).takeUnretainedValue()
                engine.handlePassiveTelemetryEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            return
        }

        telemetryTap = tTap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tTap, 0)
        telemetryRunLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tTap, enable: true)
    }

    private func handlePassiveTelemetryEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tTap = telemetryTap {
                CGEvent.tapEnable(tap: tTap, enable: true)
            }
            return
        }
        guard enableKeyStatsTracking else { return }
        if event.getIntegerValueField(.eventSourceUserData) == Self.injectedEventTag {
            return
        }

        let bid = activeBundleID ?? lastObservedBundleID
        let appName = activeAppName ?? lastObservedAppName

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            keyStatsStore.recordMouseMove(to: event.location)

        case .leftMouseDown:
            keyStatsStore.recordMouseClick(button: .left, appBundleID: bid, appName: appName)

        case .rightMouseDown:
            keyStatsStore.recordMouseClick(button: .right, appBundleID: bid, appName: appName)

        case .otherMouseDown:
            let btnNum = event.getIntegerValueField(.mouseEventButtonNumber)
            let kind: MouseButtonKind
            switch btnNum {
            case 3: kind = .sideBack
            case 4: kind = .sideForward
            default: kind = .middle
            }
            keyStatsStore.recordMouseClick(button: kind, appBundleID: bid, appName: appName)

        case .scrollWheel:
            let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            let fallbackDY = dy == 0 ? event.getDoubleValueField(.scrollWheelEventDeltaAxis1) * 10.0 : dy
            let fallbackDX = dx == 0 ? event.getDoubleValueField(.scrollWheelEventDeltaAxis2) * 10.0 : dx
            keyStatsStore.recordScroll(deltaX: fallbackDX, deltaY: fallbackDY, appBundleID: bid, appName: appName)

        case .keyDown:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let autoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            keyStatsStore.recordKeyDown(
                keyCode: keyCode,
                rawFlags: event.flags.rawValue,
                isAutoRepeat: autoRepeat,
                isSecureInput: IsSecureEventInputEnabled(),
                isRomanLayout: lastKnownRomanLayout,
                appBundleID: bid,
                appName: appName
            )

        case .flagsChanged:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            keyStatsStore.recordFlagsChanged(
                keyCode: keyCode,
                rawFlags: event.flags.rawValue,
                isSecureInput: IsSecureEventInputEnabled(),
                isRomanLayout: lastKnownRomanLayout,
                appBundleID: bid,
                appName: appName
            )

        default:
            break
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
            self.lastObservedBundleID = app?.bundleIdentifier
            self.lastObservedAppName = app?.localizedName
            self.activeBundleID = app?.bundleIdentifier
            self.activeAppName = app?.localizedName
            self.habitTracker.resetSessionContext()
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
            guard let self else { return }
            let nowRoman = InputGuard.isCurrentInputSourceRomanKeyboardLayout()
            if nowRoman != self.lastKnownRomanLayout {
                self.lastKnownRomanLayout = nowRoman
                if self.enableHabitLearning {
                    self.habitTracker.recordIMESwitch()
                }
            }
            self.dismissOverlay(clearBuffer: true)
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
                if isClick {
                    self.habitTracker.resetSessionContext()
                }
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
            let prevWord = (activeCandidateIndex < activeCandidates.count)
                ? activeCandidates[activeCandidateIndex].previousWord
                : nil
            let acceptedBundle = activeBundleID ?? lastObservedBundleID
            let acceptedAppName = activeAppName ?? lastObservedAppName
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
                guard let self else { return }
                self.injectUnicodeString(textToInsert)
                if self.enableKeyStatsTracking {
                    self.keyStatsStore.recordWordTailCompletion(
                        charsSaved: textToInsert.count,
                        appBundleID: acceptedBundle,
                        appName: acceptedAppName
                    )
                }
                let learnContext = self.enableHabitLearning
                let outcome = learnContext
                    ? self.habitTracker.recordTabAccepted(
                        fullWord: fullWord,
                        insertedText: textToInsert,
                        previousWordFromContext: prevWord,
                        bundleID: acceptedBundle
                    )
                    : nil
                self.historyStore.recordAcceptance(
                    of: fullWord,
                    previousWord: learnContext ? (outcome?.previousWord ?? prevWord) : nil,
                    bundleID: learnContext ? acceptedBundle : nil
                )
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
            if enableHabitLearning {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let bid = self.activeBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    if bid != Bundle.main.bundleIdentifier && self.inputGuard.shouldAllowPrediction(frontmostBundleID: bid) {
                        self.habitTracker.recordBackspace()
                    }
                }
            }
            schedulePredictionQuery()
            return Unmanaged.passUnretained(event)
        }

        // Navigation / Return / Tab (without suggestion) -> clear buffer and hide.
        if Self.navigationKeyCodes.contains(keyCode) {
            DispatchQueue.main.async { [weak self] in
                self?.habitTracker.resetSessionContext()
                self?.dismissOverlay(clearBuffer: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if let typed = Self.unicodeString(from: event), !typed.isEmpty {
            rollingBuffer.append(typed)
            if rollingBuffer.count > 80 {
                rollingBuffer = String(rollingBuffer.suffix(80))
            }

            if enableHabitLearning {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let bid = self.activeBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    guard bid != Bundle.main.bundleIdentifier,
                          self.inputGuard.shouldAllowPrediction(frontmostBundleID: bid) else {
                        return
                    }
                    if let completed = self.habitTracker.recordTypedCharacters(typed, bundleID: bid) {
                        self.historyStore.recordNaturalWordUsage(
                            word: completed.word,
                            previousWord: completed.previousWord,
                            bundleID: completed.bundleID
                        )
                    }
                }
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
        activeBundleID = frontBundle
        activeAppName = targetApp?.localizedName
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
            bundleID: frontBundle,
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
        if enableHabitLearning {
            habitTracker.recordSuggestionShownOncePerWord()
        }

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
