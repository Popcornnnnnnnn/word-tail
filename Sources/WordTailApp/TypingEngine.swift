import AppKit
import ApplicationServices
import Carbon.HIToolbox
import WordTailCore

final class TypingEngine {
    static let injectedEventTag: Int64 = 0x5754_4149 // "WTAI"

    private let completer: WordCompleter
    private let historyStore: UserHistoryStore
    private let habitTracker: TypingHabitTracker
    let adaptiveStore: AdaptiveCorrectionStore
    let phrasePredictor: PhrasePredictor
    let keyStatsStore: KeyStatsStore
    let syncEngine: SyncEngine
    private let inputGuard: InputGuard
    private let axContext = AXCaretContext()
    private let overlay = GhostOverlayWindow()
    private let stateLock = NSRecursiveLock()

    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private let tapRunLoopReady = DispatchSemaphore(value: 0)
    private var tapKeepAlivePort: Port?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var telemetryTap: CFMachPort?
    private var telemetryRunLoopSource: CFRunLoopSource?
    private(set) var tapTimeoutRecoveryCount: Int = 0
    private var debounceWorkItem: DispatchWorkItem?
    private var rollingBuffer: String = ""
    private var lastCapturedLineText: String?
    private var lastCapturedDocumentStart: Bool = false
    private var lastObservedBundleID: String?
    private var lastObservedAppName: String?
    private var lastKnownRomanLayout: Bool = InputGuard.isCurrentInputSourceRomanKeyboardLayout()

    private struct PendingSpaceUndo {
        let originalWord: String
        let replacedWith: String
        let delimiter: String
    }
    private var pendingSpaceUndo: PendingSpaceUndo?
    private var suppressedWordOnce: String?

    private var activeCandidates: [CompletionMatch] = []
    private var activeCandidateIndex: Int = 0
    private var activeSnapshot: CaretSnapshot?
    private var activeBundleID: String?
    private var activeAppName: String?

    private struct PinnedLiveSample {
        let bundleID: String
        let match: CompletionMatch
        let hasTextAfterOnLine: Bool
        let lineSpacingBias: LineSpacingBias
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

    var autoCorrectOnSpace: Bool {
        get {
            if UserDefaults.standard.object(forKey: "WordTailAutoCorrectOnSpace") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "WordTailAutoCorrectOnSpace")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "WordTailAutoCorrectOnSpace")
            completer.enableInlineTypoFix = newValue
            if !newValue {
                stateLock.lock()
                pendingSpaceUndo = nil
                stateLock.unlock()
            }
        }
    }

    var autoCapitalizeSentences: Bool {
        get {
            if UserDefaults.standard.object(forKey: "WordTailAutoCapitalizeSentences") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "WordTailAutoCapitalizeSentences")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "WordTailAutoCapitalizeSentences")
            if !newValue {
                stateLock.lock()
                pendingSpaceUndo = nil
                stateLock.unlock()
            }
        }
    }

    var enablePhrasePrediction: Bool {
        get {
            if UserDefaults.standard.object(forKey: "WordTailEnablePhrasePrediction") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "WordTailEnablePhrasePrediction")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "WordTailEnablePhrasePrediction")
            completer.enablePhrasePrediction = newValue
            if !newValue {
                phrasePredictor.resetSentenceWindow()
            }
        }
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
        adaptiveStore.clearAll()
        phrasePredictor.clearAll()
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
                phrasePredictor.resetSentenceWindow()
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
        phrasePredictor.clearLearnedOnly()
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
        if syncEngine.statusSnapshot().isEnabled {
            _ = syncEngine.syncNow()
        }
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
        adaptiveStore: AdaptiveCorrectionStore = AdaptiveCorrectionStore(),
        phrasePredictor: PhrasePredictor = PhrasePredictor(),
        keyStatsStore: KeyStatsStore = KeyStatsStore(),
        inputGuard: InputGuard
    ) {
        self.completer = completer
        self.historyStore = historyStore
        self.habitTracker = habitTracker
        self.adaptiveStore = adaptiveStore
        self.phrasePredictor = phrasePredictor
        self.keyStatsStore = keyStatsStore
        self.syncEngine = SyncEngine(
            historyStore: historyStore,
            adaptiveStore: adaptiveStore,
            phrasePredictor: phrasePredictor,
            habitTracker: habitTracker,
            keyStatsStore: keyStatsStore
        )
        self.inputGuard = inputGuard
        completer.habitTracker = habitTracker
        completer.adaptiveStore = adaptiveStore
        completer.phrasePredictor = phrasePredictor
        if UserDefaults.standard.object(forKey: "WordTailAutoCorrectOnSpace") != nil {
            completer.enableInlineTypoFix = UserDefaults.standard.bool(forKey: "WordTailAutoCorrectOnSpace")
        }
        if UserDefaults.standard.object(forKey: "WordTailEnablePhrasePrediction") != nil {
            completer.enablePhrasePrediction = UserDefaults.standard.bool(forKey: "WordTailEnablePhrasePrediction")
        }
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

    private func ensureDedicatedTapRunLoop() -> CFRunLoop {
        stateLock.lock()
        if let existing = tapRunLoop {
            stateLock.unlock()
            return existing
        }
        let thread = Thread { [weak self] in
            let rl = RunLoop.current
            let port = Port()
            rl.add(port, forMode: .common)
            if let self {
                self.stateLock.lock()
                self.tapKeepAlivePort = port
                self.tapRunLoop = CFRunLoopGetCurrent()
                self.stateLock.unlock()
                self.tapRunLoopReady.signal()
            }
            CFRunLoopRun()
        }
        thread.name = "app.wordtail.macos.eventtap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        stateLock.unlock()

        thread.start()
        _ = tapRunLoopReady.wait(timeout: .now() + 2.0)

        stateLock.lock()
        let resolved: CFRunLoop = tapRunLoop ?? CFRunLoopGetMain()
        stateLock.unlock()
        return resolved
    }

    @discardableResult
    func start() -> Bool {
        let telemetryRunLoop = ensureDedicatedTapRunLoop()
        startPassiveTelemetryTapIfNeeded(on: telemetryRunLoop)

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
        // Keep active key tap on CFRunLoopGetMain() so Carbon HIToolbox (`TIS*`), AppKit (`NSSpellChecker`, `NSPanel`),
        // and `NSWorkspace` always execute on `com.apple.main-thread` (while `50ms` AX timeouts + background telemetryTap prevent stalls).
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        warmUpRunningFrontApps()
        return CGEvent.tapIsEnabled(tap: tap)
    }

    private func warmUpRunningFrontApps() {
        let bridge = enableChromiumBridge
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for app in apps {
                self.axContext.warmUpApplication(app, enableChromiumBridge: bridge)
            }
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
    private func startPassiveTelemetryTapIfNeeded(on targetRunLoop: CFRunLoop) {
        if let tTap = telemetryTap {
            CGEvent.tapEnable(tap: tTap, enable: true)
            return
        }

        let eventTypes: [CGEventType] = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .scrollWheel
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { mask, eventType in
            mask | (CGEventMask(1) << eventType.rawValue)
        }

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
        CFRunLoopAddSource(targetRunLoop, src, .commonModes)
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

        stateLock.lock()
        let bid = activeBundleID ?? lastObservedBundleID
        let appName = activeAppName ?? lastObservedAppName
        let romanLayout = lastKnownRomanLayout
        stateLock.unlock()

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
                isRomanLayout: romanLayout,
                appBundleID: bid,
                appName: appName
            )

        case .flagsChanged:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            keyStatsStore.recordFlagsChanged(
                keyCode: keyCode,
                rawFlags: event.flags.rawValue,
                isSecureInput: IsSecureEventInputEnabled(),
                isRomanLayout: romanLayout,
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
            self.stateLock.lock()
            self.lastLiveSample = nil
            self.lastObservedBundleID = app?.bundleIdentifier
            self.lastObservedAppName = app?.localizedName
            self.activeBundleID = app?.bundleIdentifier
            self.activeAppName = app?.localizedName
            self.stateLock.unlock()
            self.habitTracker.resetSessionContext()
            self.phrasePredictor.resetSentenceWindow()
            self.dismissOverlay(clearBuffer: true)
            if let app {
                let bridge = self.enableChromiumBridge
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.axContext.warmUpApplication(app, enableChromiumBridge: bridge)
                }
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let nowRoman = InputGuard.isCurrentInputSourceRomanKeyboardLayout()
            self.stateLock.lock()
            let changed = (nowRoman != self.lastKnownRomanLayout)
            if changed {
                self.lastKnownRomanLayout = nowRoman
            }
            self.stateLock.unlock()
            if changed && self.enableHabitLearning {
                self.habitTracker.recordIMESwitch()
            }
            self.phrasePredictor.resetSentenceWindow()
            self.dismissOverlay(clearBuffer: true)
        }
    }

    private func handleCGEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stateLock.lock()
            tapTimeoutRecoveryCount += 1
            let count = tapTimeoutRecoveryCount
            stateLock.unlock()
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            axContext.recordOverlayOutcome("tapRecovered=\(count)")
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.injectedEventTag {
            return Unmanaged.passUnretained(event)
        }

        stateLock.lock()
        defer { stateLock.unlock() }

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
                    self.phrasePredictor.resetSentenceWindow()
                }
                self.stateLock.lock()
                self.lastLiveSample = nil
                self.stateLock.unlock()
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
            pendingSpaceUndo = nil
            let delta = (keyCode == kVK_ANSI_RightBracket) ? 1 : -1
            let count = activeCandidates.count
            activeCandidateIndex = (activeCandidateIndex + delta + count) % count
            if let snapshot = activeSnapshot {
                let chosen = activeCandidates[activeCandidateIndex]
                overlay.show(
                    match: chosen,
                    placement: snapshot.placement,
                    rawAXRect: snapshot.rawAXRect,
                    primaryScreenHeight: snapshot.primaryScreenHeight,
                    hasTextAfterOnLine: snapshot.hasTextAfterOnLine,
                    font: snapshot.font,
                    opacity: ghostOpacity
                )
            }
            return nil
        }

        // Partial 1-word acceptance for multi-word phrases: Option + Right Arrow (`⌥ →`)
        if overlay.isVisible,
           let match = overlay.currentMatch,
           !match.isTypoCorrection,
           match.suffix.contains(" "),
           keyCode == kVK_RightArrow,
           flags.contains(.maskAlternate),
           !flags.contains(.maskCommand),
           !flags.contains(.maskControl),
           !flags.contains(.maskShift) {
            pendingSpaceUndo = nil
            suppressedWordOnce = nil
            debounceWorkItem?.cancel()
            let (acceptedChunk, _) = PhrasePredictor.splitFirstWord(of: match.suffix)
            let completedFirstWord = match.prefix + acceptedChunk.trimmingCharacters(in: .whitespaces)
            let acceptedBundle = activeBundleID ?? lastObservedBundleID
            let acceptedAppName = activeAppName ?? lastObservedAppName

            overlay.hide()
            activeCandidates.removeAll(keepingCapacity: true)
            activeSnapshot = nil

            rollingBuffer.append(acceptedChunk)
            if rollingBuffer.count > 80 {
                rollingBuffer = String(rollingBuffer.suffix(80))
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.injectUnicodeString(acceptedChunk)
                if self.enableKeyStatsTracking {
                    self.keyStatsStore.recordWordTailCompletion(
                        charsSaved: max(1, acceptedChunk.count),
                        appBundleID: acceptedBundle,
                        appName: acceptedAppName
                    )
                }
                self.recordPhraseWordIfValid(completedFirstWord, endedSentence: false)
                self.schedulePredictionQuery()
            }
            return nil
        }

        let hasCommandOrCtrlOrOption = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
        if hasCommandOrCtrlOrOption {
            pendingSpaceUndo = nil
            DispatchQueue.main.async { [weak self] in
                self?.dismissOverlay(clearBuffer: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Tab while ghost text is visible -> swallow Tab and inject suffix or minimal-diff typo replacement!
        if keyCode == kVK_Tab, !flags.contains(.maskShift), overlay.isVisible,
           let match = overlay.currentMatch {
            pendingSpaceUndo = nil
            suppressedWordOnce = nil
            debounceWorkItem?.cancel()
            let charAfter = activeSnapshot?.charAfterCursor
            let prevWord = match.previousWord
            let acceptedBundle = activeBundleID ?? lastObservedBundleID
            let acceptedAppName = activeAppName ?? lastObservedAppName
            let shouldAddSpace = WordCompleter.shouldAppendSpaceOnTab(
                charAfterCursor: charAfter,
                appendSpacePreference: appendSpaceOnAccept
            )
            var resolvedFullWord = match.fullWord
            var deleteCount = match.replacementDeleteCount
            var rawInsertSuffix = match.suffix

            // Upgrade Tab-accepted lowercase/Title-case proper nouns/brands ("imess" / "Imess" -> "iMessage", "tailsc" -> "Tailscale")
            // AND sentence-start / numbered-list-start completions ("1. quant" -> "1. Quantitative") cleanly!
            let prefixIsAllCaps = match.prefix.count >= 2 && match.prefix.allSatisfy({ !$0.isLetter || $0.isUppercase })
            if !match.isTypoCorrection,
               !match.fullWord.contains(" "),
               !prefixIsAllCaps {
                let lowerFull = match.fullWord.lowercased()
                if autoCorrectOnSpace,
                   !adaptiveStore.isMuted(lowerFull),
                   let cased = (match.prefix == match.prefix.lowercased() ? historyStore.customPinnedCasing(for: lowerFull) : nil)
                    ?? ObviousTypoCorrector.canonicalBrandCasing[lowerFull]
                    ?? (match.prefix == match.prefix.lowercased() ? ObviousTypoCorrector.dictionaryProperNounCasing(forLowerWord: lowerFull) : nil),
                   cased != match.fullWord {
                    let diff = ObviousTypoCorrector.minimalDiff(from: match.prefix, to: cased)
                    resolvedFullWord = cased
                    deleteCount = diff.deleteCount
                    rawInsertSuffix = diff.insertText
                } else if autoCapitalizeSentences,
                          match.prefix == match.prefix.lowercased(),
                          let first = resolvedFullWord.first,
                          first.isLowercase,
                          !resolvedFullWord.dropFirst().contains(where: \.isUppercase),
                          !ObviousTypoCorrector.cliCommandWords.contains(lowerFull),
                          !ObviousTypoCorrector.nonCapitalizedAcronyms.contains(lowerFull) {
                    let liveBefore = activeSnapshot?.textBeforeCursor
                    let tabContext = liveBefore.flatMap {
                        ObviousTypoCorrector.sentenceContext(
                            forWord: match.prefix,
                            liveContext: $0,
                            bufferedContext: rollingBuffer
                        )
                    } ?? rollingBuffer
                    if ObviousTypoCorrector.isWordAtSentenceStart(
                        word: match.prefix,
                        inContextBeforeCursor: tabContext,
                        isAtDocumentStart: activeSnapshot?.isAtDocumentStart ?? false
                    ) {
                        let cased = resolvedFullWord.prefix(1).uppercased() + resolvedFullWord.dropFirst()
                        let diff = ObviousTypoCorrector.minimalDiff(from: match.prefix, to: cased)
                        resolvedFullWord = cased
                        deleteCount = diff.deleteCount
                        rawInsertSuffix = diff.insertText
                    }
                }
            }

            let textToInsert = shouldAddSpace ? (rawInsertSuffix + " ") : rawInsertSuffix

            overlay.hide()
            activeCandidates.removeAll(keepingCapacity: true)
            activeSnapshot = nil

            if deleteCount > 0 {
                rollingBuffer = String(rollingBuffer.dropLast(min(rollingBuffer.count, deleteCount)))
            }
            rollingBuffer.append(textToInsert)
            if rollingBuffer.count > 80 {
                rollingBuffer = String(rollingBuffer.suffix(80))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if deleteCount > 0 {
                    self.injectBackspaces(count: deleteCount)
                }
                self.injectUnicodeString(textToInsert)
                if self.enableKeyStatsTracking {
                    self.keyStatsStore.recordWordTailCompletion(
                        charsSaved: max(1, textToInsert.count - deleteCount),
                        appBundleID: acceptedBundle,
                        appName: acceptedAppName
                    )
                }
                let learnContext = self.enableHabitLearning
                if learnContext && match.isTypoCorrection {
                    self.adaptiveStore.recordObservedCorrection(mistype: match.prefix, corrected: resolvedFullWord)
                }
                let outcome = learnContext
                    ? self.habitTracker.recordTabAccepted(
                        fullWord: resolvedFullWord,
                        insertedText: textToInsert,
                        previousWordFromContext: prevWord,
                        bundleID: acceptedBundle
                    )
                    : nil
                if !resolvedFullWord.contains(" ") {
                    self.historyStore.recordAcceptance(
                        of: resolvedFullWord,
                        previousWord: learnContext ? (outcome?.previousWord ?? prevWord) : nil,
                        bundleID: learnContext ? acceptedBundle : nil
                    )
                    if shouldAddSpace {
                        self.recordPhraseWordIfValid(resolvedFullWord, endedSentence: false)
                        if self.enablePhrasePrediction {
                            self.schedulePredictionQuery()
                        }
                    }
                } else {
                    self.phrasePredictor.resetSentenceWindow()
                }
            }
            return nil
        }

        // Esc while ghost text is visible -> swallow Esc and dismiss ghost text only.
        if keyCode == kVK_Escape, overlay.isVisible {
            pendingSpaceUndo = nil
            overlay.hide()
            activeCandidates.removeAll(keepingCapacity: true)
            activeSnapshot = nil
            return nil
        }

        // Backspace -> first handle modifier deletes (⌥⌫ word / ⌘⌫ line), then 1-press Undo, otherwise normal 1-char delete!
        if keyCode == kVK_Delete {
            if flags.contains(.maskCommand) || flags.contains(.maskAlternate) || flags.contains(.maskControl) {
                pendingSpaceUndo = nil
                suppressedWordOnce = nil
                overlay.hide()
                activeCandidates.removeAll(keepingCapacity: true)
                activeSnapshot = nil
                if flags.contains(.maskCommand) {
                    if let nl = rollingBuffer.lastIndex(of: "\n") {
                        rollingBuffer = String(rollingBuffer[...nl])
                    } else {
                        rollingBuffer.removeAll(keepingCapacity: true)
                    }
                } else {
                    while let last = rollingBuffer.last, last == " " || last == "\t" {
                        rollingBuffer.removeLast()
                    }
                    while let last = rollingBuffer.last, !last.isWhitespace {
                        rollingBuffer.removeLast()
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    self?.habitTracker.resetSessionContext()
                    self?.schedulePredictionQuery()
                }
                return Unmanaged.passUnretained(event)
            }

            if let undo = pendingSpaceUndo {
                pendingSpaceUndo = nil
                let baseTrigger = undo.originalWord.hasSuffix(".") ? String(undo.originalWord.dropLast()) : undo.originalWord
                suppressedWordOnce = baseTrigger
                let currentEditorSpan = undo.replacedWith + undo.delimiter
                let diff = ObviousTypoCorrector.minimalDiff(from: currentEditorSpan, to: undo.originalWord)
                let dropLen = min(rollingBuffer.count, currentEditorSpan.count)
                rollingBuffer = String(rollingBuffer.dropLast(dropLen)) + undo.originalWord
                if rollingBuffer.count > 80 {
                    rollingBuffer = String(rollingBuffer.suffix(80))
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let origNorm = ObviousTypoCorrector.normalizeApostrophes(baseTrigger).lowercased()
                    let repBase = undo.replacedWith.hasSuffix(".") ? String(undo.replacedWith.dropLast()) : undo.replacedWith
                    let repNorm = ObviousTypoCorrector.normalizeApostrophes(repBase).lowercased()
                    let isSubstantiveWordOrBrandRule = (origNorm != repNorm)
                        || ObviousTypoCorrector.canonicalBrandCasing[origNorm] != nil
                        || self.historyStore.customPinnedCasing(for: origNorm) != nil
                        || ObviousTypoCorrector.dictionaryProperNounCasing(forLowerWord: origNorm) != nil
                    if self.enableHabitLearning && isSubstantiveWordOrBrandRule {
                        self.adaptiveStore.recordUndo(forTrigger: baseTrigger)
                    }
                    if diff.deleteCount > 0 {
                        self.injectBackspaces(count: diff.deleteCount)
                    }
                    if !diff.insertText.isEmpty {
                        self.injectUnicodeString(diff.insertText)
                    }
                    self.schedulePredictionQuery()
                }
                return nil
            }

            overlay.hide()
            activeCandidates.removeAll(keepingCapacity: true)
            activeSnapshot = nil
            if !rollingBuffer.isEmpty {
                rollingBuffer.removeLast()
            }
            if enableHabitLearning {
                let capturedBid = activeBundleID ?? lastObservedBundleID
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let bid = capturedBid ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
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
            pendingSpaceUndo = nil
            suppressedWordOnce = nil
            if keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter {
                debounceWorkItem?.cancel()
                overlay.hide()
                activeCandidates.removeAll(keepingCapacity: true)
                activeSnapshot = nil
                let wordBeforeReturn = ObviousTypoCorrector.extractTrailingStandaloneWord(from: rollingBuffer)
                rollingBuffer = ObviousTypoCorrector.sentenceContextAfterReturn(rollingBuffer)
                lastCapturedLineText = nil
                lastCapturedDocumentStart = false
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let w = wordBeforeReturn {
                        self.recordPhraseWordIfValid(w, endedSentence: true)
                    } else {
                        self.phrasePredictor.resetSentenceWindow()
                    }
                    self.habitTracker.resetSessionContext()
                }
                return Unmanaged.passUnretained(event)
            }
            DispatchQueue.main.async { [weak self] in
                self?.habitTracker.resetSessionContext()
                self?.phrasePredictor.resetSentenceWindow()
                self?.dismissOverlay(clearBuffer: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let typedUnicode = Self.unicodeString(from: event)
        let boundaryTriggerDelimiter: String? = {
            if keyCode == kVK_Space && !flags.contains(.maskShift) {
                return " "
            }
            if let s = typedUnicode, s == "," || s == "!" || s == "?" || s == ";" {
                return s
            }
            return nil
        }()

        // Space or clause/sentence punctuation (`,`, `!`, `?`, `;`, plus `<word>.` + Space) ->
        // check high-confidence auto-correction ("im," -> "I'm,", "teh " -> "the ") and sentence-start capitalization ("wow," -> "Wow,")!
        if let delim = boundaryTriggerDelimiter {
            pendingSpaceUndo = nil
            let bid = activeBundleID ?? lastObservedBundleID
            if bid != Bundle.main.bundleIdentifier,
               (autoCorrectOnSpace || autoCapitalizeSentences),
               inputGuard.shouldAllowPrediction(frontmostBundleID: bid, cachedRomanLayout: lastKnownRomanLayout),
               let target = ObviousTypoCorrector.extractPunctuationOrSpaceTarget(
                   rollingBuffer: rollingBuffer,
                   typedDelimiter: delim
               ) {
                let typedWord = target.word
                let wasJustUndone = (suppressedWordOnce == typedWord)
                suppressedWordOnce = nil

                if !wasJustUndone {
                    let lineCtx: String?
                    let isDocStart: Bool
                    let sliceAtZero: Bool
                    if ObviousTypoCorrector.needsLiveSentenceContextOnSpace(
                        forWord: typedWord,
                        rollingBuffer: target.bufferUpToWord,
                        autoCorrectTypos: autoCorrectOnSpace,
                        autoCapitalizeSentences: autoCapitalizeSentences,
                        adaptiveStore: adaptiveStore
                    ) {
                        let expectedInEditor = target.existingTrailingDot ? (typedWord + ".") : typedWord
                        let liveInspect = axContext.inspectLiveSentenceContext(
                            targetApp: nil,
                            expectedTrailingWord: expectedInEditor,
                            enableChromiumBridge: enableChromiumBridge
                        )
                        if let rawLive = liveInspect.context {
                            let strippedLive = target.existingTrailingDot && rawLive.hasSuffix(".")
                                ? String(rawLive.dropLast())
                                : rawLive
                            isDocStart = target.existingTrailingDot
                                ? (liveInspect.sliceStartsAtDocumentZero && AXCaretContext.isCurrentWordAtVeryStartOfDocument(fullTextBeforeCursor: strippedLive))
                                : liveInspect.isAtDocumentStart
                            sliceAtZero = liveInspect.sliceStartsAtDocumentZero
                            lineCtx = isDocStart
                                ? strippedLive
                                : ObviousTypoCorrector.sentenceContext(
                                    forWord: typedWord,
                                    liveContext: strippedLive,
                                    bufferedContext: target.bufferUpToWord
                                )
                        } else {
                            lineCtx = resolvedLineContextForWord(typedWord, bufferUpToWord: target.bufferUpToWord)
                            isDocStart = lastCapturedDocumentStart
                            sliceAtZero = false
                        }
                    } else {
                        lineCtx = target.bufferUpToWord
                        isDocStart = false
                        sliceAtZero = false
                    }

                    if let transform = ObviousTypoCorrector.evaluateSpaceTransform(
                        forWord: typedWord,
                        lineContextIncludingWord: lineCtx,
                        isAtDocumentStart: isDocStart,
                        sliceStartsAtDocumentZero: sliceAtZero,
                        autoCorrectTypos: autoCorrectOnSpace,
                        autoCapitalizeSentences: autoCapitalizeSentences,
                        adaptiveStore: adaptiveStore,
                        habitTracker: habitTracker,
                        historyStore: historyStore
                    ) {
                        debounceWorkItem?.cancel()
                        overlay.hide()
                        activeCandidates.removeAll(keepingCapacity: true)
                        activeSnapshot = nil
                        lastCapturedDocumentStart = false

                        let srcSpanInEditor = target.existingTrailingDot ? (transform.replacedSourceSpan + ".") : transform.replacedSourceSpan
                        let replacementInEditor = target.existingTrailingDot ? (transform.replacementText + ".") : transform.replacementText
                        let outDelim = target.outputDelimiter

                        let diff = ObviousTypoCorrector.minimalDiff(from: srcSpanInEditor, to: replacementInEditor)
                        rollingBuffer = String(rollingBuffer.dropLast(min(rollingBuffer.count, srcSpanInEditor.count))) + replacementInEditor + outDelim
                        if rollingBuffer.count > 80 {
                            rollingBuffer = String(rollingBuffer.suffix(80))
                        }
                        if let lineCtx,
                           ObviousTypoCorrector.normalizeApostrophes(lineCtx).lowercased().hasSuffix(
                               ObviousTypoCorrector.normalizeApostrophes(transform.replacedSourceSpan).lowercased()
                           ) {
                            lastCapturedLineText = String(lineCtx.dropLast(transform.replacedSourceSpan.count)) + replacementInEditor + outDelim
                        }
                        pendingSpaceUndo = PendingSpaceUndo(
                            originalWord: srcSpanInEditor,
                            replacedWith: replacementInEditor,
                            delimiter: outDelim
                        )

                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            if diff.deleteCount > 0 {
                                self.injectBackspaces(count: diff.deleteCount)
                            }
                            self.injectUnicodeString(diff.insertText + outDelim)
                            if self.enableHabitLearning {
                                if let completed = self.habitTracker.recordTypedCharacters(outDelim, bundleID: bid) {
                                    self.historyStore.recordNaturalWordUsage(
                                        word: completed.word,
                                        previousWord: completed.previousWord,
                                        bundleID: completed.bundleID
                                    )
                                }
                                let ended = outDelim.contains(".") || outDelim == "!" || outDelim == "?" || outDelim == ";"
                                self.recordPhraseWordIfValid(transform.replacementText, endedSentence: ended)
                            }
                            if outDelim == " " && self.enablePhrasePrediction {
                                self.schedulePredictionQuery()
                            }
                        }
                        return nil
                    }
                }
            } else {
                suppressedWordOnce = nil
            }
        } else {
            pendingSpaceUndo = nil
            suppressedWordOnce = nil
        }

        if let typed = typedUnicode, !typed.isEmpty {
            let firstTypedChar = typed.first
            let isPhraseBoundaryChar = firstTypedChar.map { " ,.!?;:\n\r".contains($0) } ?? false
            let wordBeforeBoundary = isPhraseBoundaryChar
                ? ObviousTypoCorrector.extractTrailingStandaloneWord(from: rollingBuffer)
                : nil

            rollingBuffer.append(typed)
            if rollingBuffer.count > 80 {
                rollingBuffer = String(rollingBuffer.suffix(80))
            }

            if enableHabitLearning {
                let capturedBid = activeBundleID ?? lastObservedBundleID
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let bid = capturedBid ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    guard bid != Bundle.main.bundleIdentifier,
                          self.inputGuard.shouldAllowPrediction(frontmostBundleID: bid) else {
                        return
                    }
                    if let completed = self.habitTracker.recordTypedCharacters(typed, bundleID: bid) {
                        if let mistype = completed.detectedTypoMistype {
                            self.adaptiveStore.recordObservedCorrection(mistype: mistype, corrected: completed.word)
                        }
                        self.historyStore.recordNaturalWordUsage(
                            word: completed.word,
                            previousWord: completed.previousWord,
                            bundleID: completed.bundleID
                        )
                    }
                    if let ch = firstTypedChar {
                        if isPhraseBoundaryChar {
                            let ended = ".!?;:\n\r".contains(ch)
                            if let w = wordBeforeBoundary {
                                self.recordPhraseWordIfValid(w, endedSentence: ended)
                            } else if ended {
                                self.phrasePredictor.resetSentenceWindow()
                            }
                        } else if "/\\@_".contains(ch) {
                            self.phrasePredictor.resetSentenceWindow()
                        }
                    }
                }
            }

            if let last = typed.last, (last.isLetter && last.isASCII) || last == "'" || last == "’" {
                // Immediately hide the previous character's overlay so a newly typed glyph never renders underneath stale ghost text!
                overlay.hide()
                activeCandidates.removeAll(keepingCapacity: true)
                activeSnapshot = nil
                if rollingBuffer.count == 1 && lastCapturedLineText == nil {
                    DispatchQueue.main.async { [weak self] in
                        self?.primeLineContextSnapshot()
                    }
                }
                schedulePredictionQuery()
            } else if typed == " " && enablePhrasePrediction {
                overlay.hide()
                activeCandidates.removeAll(keepingCapacity: true)
                activeSnapshot = nil
                schedulePredictionQuery()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.dismissOverlay(clearBuffer: false)
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func recordPhraseWordIfValid(_ rawText: String, endedSentence: Bool) {
        guard enableHabitLearning && enablePhrasePrediction else { return }
        let parts = rawText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return }

        for (idx, token) in parts.enumerated() {
            let clean = token.trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:\"'()[]{}"))
            let lower = clean.lowercased()
            let isValid: Bool
            if clean.count <= 2 {
                isValid = ObviousTypoCorrector.validShortEnglishWords.contains(lower)
            } else {
                isValid = historyStore.isCustomWord(clean)
                    || TypingHabitTracker.defaultValidEnglishWordCheck(clean)
                    || clean.contains("'")
            }
            if isValid {
                let isLast = (idx == parts.count - 1)
                phrasePredictor.observeCompletedWord(clean, endedSentence: isLast && endedSentence)
            } else {
                phrasePredictor.resetSentenceWindow()
                return
            }
        }
    }

    private func schedulePredictionQuery(delayMs: Int = 16, retryCount: Int = 0) {
        stateLock.lock()
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.evaluateAndRenderPrediction(retryCount: retryCount)
        }
        debounceWorkItem = item
        stateLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: item)
    }

    private func primeLineContextSnapshot() {
        let targetApp = axContext.effectiveFocusedApplication()
        let frontBundle = targetApp?.bundleIdentifier
        guard frontBundle != Bundle.main.bundleIdentifier,
              inputGuard.shouldAllowPrediction(frontmostBundleID: frontBundle) else {
            return
        }
        stateLock.lock()
        let fallbackBuf = rollingBuffer
        stateLock.unlock()
        if let snap = axContext.capture(
            targetApp: targetApp,
            fallbackBuffer: fallbackBuf,
            enableChromiumBridge: enableChromiumBridge,
            verticalAdjustment: verticalAdjustment(forBundleID: frontBundle)
        ) {
            stateLock.lock()
            lastCapturedLineText = snap.textBeforeCursor
            lastCapturedDocumentStart = snap.isAtDocumentStart
            stateLock.unlock()
        }
    }

    private func evaluateAndRenderPrediction(retryCount: Int = 0) {
        let targetApp = axContext.effectiveFocusedApplication()
        let frontBundle = targetApp?.bundleIdentifier
        if frontBundle == Bundle.main.bundleIdentifier {
            overlay.hide()
            return
        }
        stateLock.lock()
        activeBundleID = frontBundle
        activeAppName = targetApp?.localizedName
        let fallbackBuf = rollingBuffer
        stateLock.unlock()
        guard inputGuard.shouldAllowPrediction(frontmostBundleID: frontBundle) else {
            overlay.hide()
            return
        }

        guard let snapshot = axContext.capture(
            targetApp: targetApp,
            fallbackBuffer: fallbackBuf,
            enableChromiumBridge: enableChromiumBridge,
            verticalAdjustment: verticalAdjustment(forBundleID: frontBundle)
        ) else {
            overlay.hide()
            if retryCount < 2 {
                schedulePredictionQuery(delayMs: 18, retryCount: retryCount + 1)
            }
            return
        }

        stateLock.lock()
        let currentBuf = rollingBuffer
        stateLock.unlock()

        // Guard against Electron/Chromium async frame lag (e.g. user typed "What", but at t=16ms AX still reports "Wha"
        // or reports zero glyph width for 't' before layout commits—which would otherwise draw "tever"/"ever" over 't'!):
        let isStaleText = ObviousTypoCorrector.isSnapshotBehindRollingBuffer(
            snapshotText: snapshot.textBeforeCursor,
            isFallbackText: snapshot.isFallbackText,
            rollingBuffer: currentBuf
        )
        if isStaleText || (snapshot.isGlyphWidthZeroOnPrevChar && retryCount < 3) {
            overlay.hide()
            if retryCount < 4 {
                schedulePredictionQuery(delayMs: 18, retryCount: retryCount + 1)
                return
            }
            if isStaleText {
                let snapWord = ObviousTypoCorrector.extractTrailingStandaloneWord(from: snapshot.textBeforeCursor)?.lowercased()
                let bufWord = ObviousTypoCorrector.extractTrailingStandaloneWord(from: currentBuf)?.lowercased()
                if snapWord != bufWord {
                    axContext.recordOverlayOutcome("shown=no(staleAX)")
                    return
                }
            }
        }

        let matches = completer.candidates(
            textBeforeCursor: snapshot.textBeforeCursor,
            charAfterCursor: snapshot.charAfterCursor,
            textAfterCursorOnLine: snapshot.textAfterOnLine,
            bundleID: frontBundle,
            limit: 5
        )
        guard let first = matches.first else {
            axContext.recordOverlayOutcome("shown=no")
            stateLock.lock()
            lastCapturedLineText = snapshot.textBeforeCursor
            lastCapturedDocumentStart = snapshot.isAtDocumentStart
            activeCandidates.removeAll(keepingCapacity: true)
            activeSnapshot = nil
            stateLock.unlock()
            overlay.hide()
            return
        }

        stateLock.lock()
        lastCapturedLineText = snapshot.textBeforeCursor
        lastCapturedDocumentStart = snapshot.isAtDocumentStart
        activeCandidates = matches
        activeCandidateIndex = 0
        activeSnapshot = snapshot
        if let frontBundle {
            lastLiveSample = PinnedLiveSample(
                bundleID: frontBundle,
                match: first,
                hasTextAfterOnLine: snapshot.hasTextAfterOnLine,
                lineSpacingBias: snapshot.lineSpacingBias,
                rawAXRect: snapshot.rawAXRect,
                primaryScreenHeight: snapshot.primaryScreenHeight,
                font: snapshot.font
            )
        }
        stateLock.unlock()

        if enableHabitLearning {
            habitTracker.recordSuggestionShownOncePerWord()
        }

        axContext.recordOverlayOutcome(String(
            format: "shown=yes(len=%d,n=%d,x=%.0f,y=%.0f,mid=%d)",
            first.suffix.count, matches.count, snapshot.placement.anchorX, snapshot.placement.baselineY,
            snapshot.hasTextAfterOnLine ? 1 : 0
        ))

        overlay.show(
            match: first,
            placement: snapshot.placement,
            rawAXRect: snapshot.rawAXRect,
            primaryScreenHeight: snapshot.primaryScreenHeight,
            hasTextAfterOnLine: snapshot.hasTextAfterOnLine,
            font: snapshot.font,
            opacity: ghostOpacity
        )
    }

    func refreshPinnedOverlayIfVisible() {
        stateLock.lock()
        let sample = lastLiveSample
        stateLock.unlock()
        guard let sample else { return }
        let offset = verticalAdjustment(forBundleID: sample.bundleID)
        let placement = ScreenGeometry.baselinePlacement(
            forAXCharRect: sample.rawAXRect,
            primaryScreenHeight: sample.primaryScreenHeight,
            font: sample.font,
            verticalAdjustment: offset,
            lineSpacingBias: sample.lineSpacingBias
        )
        overlay.show(
            match: sample.match,
            placement: placement,
            rawAXRect: sample.rawAXRect,
            primaryScreenHeight: sample.primaryScreenHeight,
            hasTextAfterOnLine: sample.hasTextAfterOnLine,
            font: sample.font,
            opacity: ghostOpacity
        )
    }

    private func dismissOverlay(clearBuffer: Bool) {
        stateLock.lock()
        debounceWorkItem?.cancel()
        activeCandidates.removeAll(keepingCapacity: true)
        activeSnapshot = nil
        if clearBuffer {
            rollingBuffer.removeAll(keepingCapacity: true)
            lastCapturedLineText = nil
            lastCapturedDocumentStart = false
            pendingSpaceUndo = nil
            suppressedWordOnce = nil
        }
        stateLock.unlock()
        overlay.hide()
    }

    /// Reconstructs the current line's text up to and including `typedWord`, accounting for fast keystroke rollover
    /// where `Space` arrives a few milliseconds before the last character's 16ms debounced AX snapshot.
    private func resolvedLineContextForWord(_ typedWord: String, bufferUpToWord: String) -> String? {
        if bufferUpToWord.contains("\n") || bufferUpToWord.contains(".") || bufferUpToWord.contains("!") || bufferUpToWord.contains("?") || bufferUpToWord.contains(")") {
            return bufferUpToWord
        }
        guard let snap = lastCapturedLineText else {
            return nil
        }
        let lowerSnap = ObviousTypoCorrector.normalizeApostrophes(snap).lowercased()
        let lowerWord = ObviousTypoCorrector.normalizeApostrophes(typedWord).lowercased()
        if lowerSnap.hasSuffix(lowerWord) {
            return String(snap.dropLast(typedWord.count)) + typedWord
        }
        // Check partial prefix overlap (e.g. snap ended with "hell" right before "o" + Space completed "hello")
        let maxOverlap = min(snap.count, typedWord.count - 1)
        if maxOverlap >= 1 {
            for k in stride(from: maxOverlap, through: 1, by: -1) {
                let wordPrefix = String(lowerWord.prefix(k))
                if lowerSnap.hasSuffix(wordPrefix) {
                    let beforeWord = String(snap.dropLast(k))
                    let boundaryOK = beforeWord.isEmpty || " \t\n\r([{\"'“‘".contains(beforeWord.last!)
                    if boundaryOK {
                        return beforeWord + typedWord
                    }
                }
            }
        }
        if snap.trimmingCharacters(in: .whitespaces).isEmpty {
            return snap + typedWord
        }
        return nil
    }

    private func injectBackspaces(count: Int) {
        guard count > 0, let src = CGEventSource(stateID: .hidSystemState) else { return }
        let vkDelete = CGKeyCode(kVK_Delete)
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: vkDelete, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: vkDelete, keyDown: false) else {
                continue
            }
            down.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventTag)
            up.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventTag)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
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
