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
    let licenseManager: LicenseManager
    let domainPackStore: DomainPackStore
    let appProfileStore: AppProfileStore
    let snippetStore: SnippetStore
    let verticalOffsetStore: VerticalOffsetStore
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
    var onCalibrationChanged: (() -> Void)?

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

    var globalVerticalAdjustment: CGFloat {
        get {
            CGFloat(verticalOffsetStore.globalOffset)
        }
        set {
            verticalOffsetStore.globalOffset = Double(newValue)
            refreshPinnedOverlayIfVisible()
            notifyCalibrationChanged()
        }
    }

    func customVerticalAdjustment(forBundleID bundleID: String) -> CGFloat? {
        verticalOffsetStore.customOffset(forBundleID: bundleID).map { CGFloat($0) }
    }

    func verticalAdjustment(forBundleID bundleID: String?) -> CGFloat {
        CGFloat(verticalOffsetStore.effectiveOffset(forBundleID: bundleID))
    }

    func setVerticalAdjustment(_ value: CGFloat?, forBundleID bundleID: String) {
        verticalOffsetStore.setOffset(value.map(Double.init), forBundleID: bundleID)
        refreshPinnedOverlayIfVisible()
        notifyCalibrationChanged()
    }

    @discardableResult
    func nudgeVerticalAdjustment(forBundleID bundleID: String, delta: Double) -> CGFloat {
        let updated = verticalOffsetStore.nudge(forBundleID: bundleID, delta: delta)
        refreshPinnedOverlayIfVisible()
        notifyCalibrationChanged()
        return CGFloat(updated)
    }

    private func notifyCalibrationChanged() {
        if Thread.isMainThread {
            onCalibrationChanged?()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onCalibrationChanged?()
            }
        }
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

    var showMenuBarClickCount: Bool {
        get { UserDefaults.standard.bool(forKey: "WordTailShowMenuBarClickCount") }
        set {
            UserDefaults.standard.set(newValue, forKey: "WordTailShowMenuBarClickCount")
            onStateChanged?()
        }
    }

    var enableDynamicMenuBarColor: Bool {
        get { UserDefaults.standard.bool(forKey: "WordTailDynamicMenuBarColor") }
        set {
            UserDefaults.standard.set(newValue, forKey: "WordTailDynamicMenuBarColor")
            onStateChanged?()
        }
    }

    var dynamicMenuBarColorStyle: String {
        get { UserDefaults.standard.string(forKey: "WordTailDynamicMenuBarColorStyle") ?? "dot" }
        set {
            UserDefaults.standard.set(newValue, forKey: "WordTailDynamicMenuBarColorStyle")
            onStateChanged?()
        }
    }

    var dynamicMenuBarWindowSeconds: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "WordTailDynamicMenuBarWindowSeconds")
            return stored > 0 ? stored : 30
        }
        set {
            UserDefaults.standard.set(max(10, min(60, newValue)), forKey: "WordTailDynamicMenuBarWindowSeconds")
            onStateChanged?()
        }
    }

    var mouseCalibrationFactor: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: "WordTailMouseCalibrationFactor")
            return stored > 0 ? stored : 1.0
        }
        set {
            let clamped = max(0.1, min(10.0, newValue))
            UserDefaults.standard.set(clamped, forKey: "WordTailMouseCalibrationFactor")
            keyStatsStore.mouseCalibrationFactor = clamped
            onStateChanged?()
        }
    }

    var enableMilestoneNotifications: Bool {
        get { UserDefaults.standard.bool(forKey: "WordTailMilestoneNotifications") }
        set {
            UserDefaults.standard.set(newValue, forKey: "WordTailMilestoneNotifications")
            onStateChanged?()
        }
    }

    var milestoneKeyThreshold: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "WordTailMilestoneKeyThreshold")
            return stored >= 1_000 ? stored : 10_000
        }
        set {
            UserDefaults.standard.set(max(1_000, newValue), forKey: "WordTailMilestoneKeyThreshold")
        }
    }

    var milestoneClickThreshold: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "WordTailMilestoneClickThreshold")
            return stored >= 200 ? stored : 2_000
        }
        set {
            UserDefaults.standard.set(max(200, newValue), forKey: "WordTailMilestoneClickThreshold")
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

    var lastObservedTargetApp: (name: String, bundleID: String)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let bid = activeBundleID ?? lastObservedBundleID
        guard let bid,
              bid != Bundle.main.bundleIdentifier,
              !InputGuard.defaultExcludedBundleIDs.contains(bid) else {
            return nil
        }
        let name = (bid == activeBundleID ? activeAppName : lastObservedAppName) ?? SettingsViewModel.appName(forBundleID: bid)
        return (name: name, bundleID: bid)
    }

    func effectiveFocusedTargetApp() -> (name: String, bundleID: String)? {
        guard let app = axContext.effectiveFocusedApplication(),
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else {
            return nil
        }
        return (name: app.localizedName ?? bundleID, bundleID: bundleID)
    }

    var bilingualCompletionEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "WordTailProBilingualCompletion") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "WordTailProBilingualCompletion")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "WordTailProBilingualCompletion")
            syncCompleterProState()
        }
    }

    var bilingualSpacingEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "WordTailProBilingualSpacing") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "WordTailProBilingualSpacing")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "WordTailProBilingualSpacing")
            syncCompleterProState()
        }
    }

    func isStudioFeatureUnlocked(_ feature: WordTailProFeature) -> Bool {
        !WordTailReleasePolicy.monetizationEnabled || licenseManager.isUnlocked(feature)
    }

    private func activeWritingProfile(forBundleID bundleID: String?) -> AppWritingProfile? {
        guard isStudioFeatureUnlocked(.appWritingProfiles),
              let bundleID, !bundleID.isEmpty else {
            return nil
        }
        return appProfileStore.profile(forBundleID: bundleID)
    }

    private func effectiveAutoCorrectOnSpace(bundleID: String?) -> Bool {
        activeWritingProfile(forBundleID: bundleID)?.autoCorrectOnSpace ?? autoCorrectOnSpace
    }

    private func effectiveAutoCapitalizeSentences(bundleID: String?) -> Bool {
        activeWritingProfile(forBundleID: bundleID)?.autoCapitalizeSentences ?? autoCapitalizeSentences
    }

    private func effectivePhrasePrediction(bundleID: String?) -> Bool {
        activeWritingProfile(forBundleID: bundleID)?.enablePhrasePrediction ?? enablePhrasePrediction
    }

    private func effectiveBilingualSpacing(bundleID: String?) -> Bool {
        guard isStudioFeatureUnlocked(.bilingualSpacing) else { return false }
        return activeWritingProfile(forBundleID: bundleID)?.bilingualSpacingOverride ?? bilingualSpacingEnabled
    }

    func syncCompleterProState() {
        completer.domainLexiconProvider = { [weak self] lowerPrefix, bundleID in
            guard let self, self.isStudioFeatureUnlocked(.domainLexiconPacks) else { return [] }
            let overrideIDs = self.activeWritingProfile(forBundleID: bundleID)?.enabledDomainPackIDs
            return self.domainPackStore.matching(lowercasedPrefix: lowerPrefix, overrideEnabledPackIDs: overrideIDs)
        }
        completer.snippetMatcher = { [weak self] textBeforeCursor, bundleID in
            guard let self, self.isStudioFeatureUnlocked(.snippetStudio) else { return nil }
            return self.snippetStore.match(
                textBeforeCursor: textBeforeCursor,
                bundleID: bundleID
            )
        }
        completer.bilingualCompletionEnabled = isStudioFeatureUnlocked(.bilingualSpacing) && bilingualCompletionEnabled
        completer.bilingualCompletionProvider = { [weak self] in
            guard let self else { return false }
            return self.isStudioFeatureUnlocked(.bilingualSpacing) && self.bilingualCompletionEnabled
        }
        completer.bilingualSpacingProvider = { [weak self] bundleID in
            self?.effectiveBilingualSpacing(bundleID: bundleID) ?? false
        }
        completer.inlineTypoFixProvider = { [weak self] bundleID in
            self?.effectiveAutoCorrectOnSpace(bundleID: bundleID) ?? true
        }
        completer.phrasePredictionProvider = { [weak self] bundleID in
            self?.effectivePhrasePrediction(bundleID: bundleID) ?? true
        }
    }

    init(
        completer: WordCompleter,
        historyStore: UserHistoryStore,
        habitTracker: TypingHabitTracker = TypingHabitTracker(),
        adaptiveStore: AdaptiveCorrectionStore = AdaptiveCorrectionStore(),
        phrasePredictor: PhrasePredictor = PhrasePredictor(),
        keyStatsStore: KeyStatsStore = KeyStatsStore(),
        inputGuard: InputGuard,
        licenseManager: LicenseManager = LicenseManager(),
        domainPackStore: DomainPackStore = DomainPackStore(),
        appProfileStore: AppProfileStore = AppProfileStore(),
        snippetStore: SnippetStore = SnippetStore(),
        verticalOffsetStore: VerticalOffsetStore = VerticalOffsetStore()
    ) {
        self.completer = completer
        self.historyStore = historyStore
        self.habitTracker = habitTracker
        self.adaptiveStore = adaptiveStore
        self.phrasePredictor = phrasePredictor
        self.keyStatsStore = keyStatsStore
        self.licenseManager = licenseManager
        self.domainPackStore = domainPackStore
        self.appProfileStore = appProfileStore
        self.snippetStore = snippetStore
        self.verticalOffsetStore = verticalOffsetStore
        self.syncEngine = SyncEngine(
            historyStore: historyStore,
            adaptiveStore: adaptiveStore,
            phrasePredictor: phrasePredictor,
            habitTracker: habitTracker,
            keyStatsStore: keyStatsStore,
            domainPackStore: domainPackStore,
            appProfileStore: appProfileStore,
            snippetStore: snippetStore
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
        let storedCal = UserDefaults.standard.double(forKey: "WordTailMouseCalibrationFactor")
        keyStatsStore.mouseCalibrationFactor = storedCal > 0 ? storedCal : 1.0
        if UserDefaults.standard.object(forKey: "WordTailEnableTechLexicon") != nil {
            completer.enableTechLexicon = UserDefaults.standard.bool(forKey: "WordTailEnableTechLexicon")
        }
        syncCompleterProState()
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
            let nowRoman = InputGuard.isCurrentInputSourceRomanKeyboardLayout()
            self.stateLock.lock()
            self.lastLiveSample = nil
            self.lastObservedBundleID = app?.bundleIdentifier
            self.lastObservedAppName = app?.localizedName
            self.activeBundleID = app?.bundleIdentifier
            self.activeAppName = app?.localizedName
            self.lastKnownRomanLayout = nowRoman
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
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
                let isClick = (type != .scrollWheel)
                lastLiveSample = nil
                dismissOverlay(clearBuffer: isClick)
                if isClick {
                    DispatchQueue.main.async { [weak self] in
                        self?.habitTracker.resetSessionContext()
                        self?.phrasePredictor.resetSentenceWindow()
                    }
                }
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
           !match.isSnippet,
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

            injectUnicodeString(acceptedChunk, proxy: proxy)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
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
        if hasCommandOrCtrlOrOption && keyCode != kVK_Delete {
            pendingSpaceUndo = nil
            dismissOverlay(clearBuffer: true)
            return Unmanaged.passUnretained(event)
        }

        // Tab while ghost text is visible -> swallow Tab and inject suffix, snippet expansion, or minimal-diff typo replacement!
        if keyCode == kVK_Tab, !flags.contains(.maskShift), overlay.isVisible,
           let match = overlay.currentMatch {
            pendingSpaceUndo = nil
            suppressedWordOnce = nil
            debounceWorkItem?.cancel()
            let charAfter = activeSnapshot?.charAfterCursor
            let prevWord = match.previousWord
            let acceptedBundle = activeBundleID ?? lastObservedBundleID
            let acceptedAppName = activeAppName ?? lastObservedAppName

            if match.isSnippet {
                let capturedSnapshot = activeSnapshot
                let trigger = match.prefix
                let deleteCount = match.replacementDeleteCount
                let expectedCharAfter = activeSnapshot?.charAfterCursor
                let bridgeEnabled = enableChromiumBridge
                let capturedSnippetID = match.snippetID
                let capturedSnippetUpdatedAt = match.snippetUpdatedAt

                overlay.hide()
                activeCandidates.removeAll(keepingCapacity: true)
                activeSnapshot = nil
                rollingBuffer.removeAll(keepingCapacity: true)
                lastCapturedLineText = nil

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.isStudioFeatureUnlocked(.snippetStudio) else {
                        return
                    }

                    // Expand snippet & read clipboard before destination verification so pasteboard IPC
                    // never opens a stale focus/caret race window before AX checks or HID typing.
                    let liveMatch: SnippetMatch?
                    if let capturedSnippetID {
                        liveMatch = self.snippetStore.expandSnippet(
                            id: capturedSnippetID,
                            expectedUpdatedAt: capturedSnippetUpdatedAt,
                            bundleID: acceptedBundle,
                            now: Date(),
                            clipboardTextProvider: { NSPasteboard.general.string(forType: .string) }
                        )
                    } else {
                        liveMatch = self.snippetStore.match(
                            textBeforeCursor: trigger,
                            bundleID: acceptedBundle,
                            now: Date(),
                            clipboardTextProvider: { NSPasteboard.general.string(forType: .string) }
                        )
                    }
                    guard let liveMatch else { return }

                    let resolvedText = liveMatch.expandedText
                        .replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n")
                    guard !resolvedText.isEmpty else {
                        return
                    }
                    let resolvedBackSteps = liveMatch.cursorBackSteps

                    guard let verified = self.axContext.verifyDestinationStillMatches(
                        snapshot: capturedSnapshot,
                        expectedBundleID: acceptedBundle,
                        expectedTrigger: trigger,
                        expectedCharAfter: expectedCharAfter,
                        enableChromiumBridge: bridgeEnabled
                    ) else {
                        return
                    }

                    let replaceOutcome: AXSnippetReplaceOutcome
                    if let caretLoc = verified.caretLocation {
                        replaceOutcome = self.axContext.replaceRangeViaAX(
                            element: verified.element,
                            caretLocation: caretLoc,
                            trigger: trigger,
                            replacement: resolvedText,
                            cursorBackSteps: resolvedBackSteps,
                            enableChromiumBridge: bridgeEnabled
                        )
                    } else {
                        replaceOutcome = .unattempted
                    }

                    switch replaceOutcome {
                    case .applied:
                        break
                    case .uncertain:
                        return
                    case .unattempted:
                        guard !resolvedText.contains("\n"),
                              resolvedText.count <= 512,
                              resolvedBackSteps <= 256 else {
                            return
                        }
                        if deleteCount > 0 {
                            self.injectBackspaces(count: deleteCount)
                        }
                        self.injectUnicodeString(resolvedText)
                        if resolvedBackSteps > 0 {
                            self.injectLeftArrows(count: resolvedBackSteps)
                        }
                    }

                    let netSaved = max(1, resolvedText.count - deleteCount)
                    if self.enableKeyStatsTracking {
                        self.keyStatsStore.recordWordTailCompletion(
                            charsSaved: netSaved,
                            appBundleID: acceptedBundle,
                            appName: acceptedAppName
                        )
                    }
                    if self.enableHabitLearning {
                        self.habitTracker.recordSnippetAccepted(charsSaved: netSaved)
                    }
                    self.phrasePredictor.resetSentenceWindow()
                }
                return nil
            }

            let allowAutoCorrect = effectiveAutoCorrectOnSpace(bundleID: acceptedBundle)
            let allowAutoCap = effectiveAutoCapitalizeSentences(bundleID: acceptedBundle)
            let allowPhrasePred = effectivePhrasePrediction(bundleID: acceptedBundle)
            let shouldAddSpace = BilingualSpacingGuard.needsTrailingSpace(
                charAfterCursor: charAfter,
                appendSpacePreference: appendSpaceOnAccept,
                bilingualSpacingEnabled: effectiveBilingualSpacing(bundleID: acceptedBundle)
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
                if allowAutoCorrect,
                   !adaptiveStore.isMuted(lowerFull),
                   let cased = (match.prefix == match.prefix.lowercased() ? historyStore.customPinnedCasing(for: lowerFull) : nil)
                    ?? ObviousTypoCorrector.canonicalBrandCasing[lowerFull]
                    ?? (match.prefix == match.prefix.lowercased() ? ObviousTypoCorrector.dictionaryProperNounCasing(forLowerWord: lowerFull) : nil),
                   cased != match.fullWord {
                    let diff = ObviousTypoCorrector.minimalDiff(from: match.prefix, to: cased)
                    resolvedFullWord = cased
                    deleteCount = diff.deleteCount
                    rawInsertSuffix = diff.insertText
                } else if allowAutoCap,
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

            if match.needsLeadingSpace, !match.prefix.isEmpty {
                deleteCount = match.prefix.count
                rawInsertSuffix = " " + resolvedFullWord
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
            if deleteCount > 0 {
                injectBackspaces(count: deleteCount, proxy: proxy)
            }
            injectUnicodeString(textToInsert, proxy: proxy)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
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
                        bundleID: acceptedBundle,
                        charsSavedOverride: max(1, textToInsert.count - deleteCount)
                    )
                    : nil
                if !resolvedFullWord.contains(" ") {
                    self.historyStore.recordAcceptance(
                        of: resolvedFullWord,
                        previousWord: learnContext ? (outcome?.previousWord ?? prevWord) : nil,
                        bundleID: learnContext ? acceptedBundle : nil
                    )
                    if shouldAddSpace {
                        self.recordPhraseWordIfValid(resolvedFullWord, endedSentence: false, bundleID: acceptedBundle)
                        if allowPhrasePred {
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
                if diff.deleteCount > 0 {
                    injectBackspaces(count: diff.deleteCount, proxy: proxy)
                }
                if !diff.insertText.isEmpty {
                    injectUnicodeString(diff.insertText, proxy: proxy)
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
            dismissOverlay(clearBuffer: true)
            DispatchQueue.main.async { [weak self] in
                self?.habitTracker.resetSessionContext()
                self?.phrasePredictor.resetSentenceWindow()
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
            let allowAutoCorrect = effectiveAutoCorrectOnSpace(bundleID: bid)
            let allowAutoCap = effectiveAutoCapitalizeSentences(bundleID: bid)
            let allowPhrasePred = effectivePhrasePrediction(bundleID: bid)
            if bid != Bundle.main.bundleIdentifier,
               (allowAutoCorrect || allowAutoCap),
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
                        autoCorrectTypos: allowAutoCorrect,
                        autoCapitalizeSentences: allowAutoCap,
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
                        autoCorrectTypos: allowAutoCorrect,
                        autoCapitalizeSentences: allowAutoCap,
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

                        if diff.deleteCount > 0 {
                            injectBackspaces(count: diff.deleteCount, proxy: proxy)
                        }
                        injectUnicodeString(diff.insertText + outDelim, proxy: proxy)

                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            if self.enableHabitLearning {
                                if let completed = self.habitTracker.recordTypedCharacters(outDelim, bundleID: bid) {
                                    self.historyStore.recordNaturalWordUsage(
                                        word: completed.word,
                                        previousWord: completed.previousWord,
                                        bundleID: completed.bundleID
                                    )
                                }
                                let ended = outDelim.contains(".") || outDelim == "!" || outDelim == "?" || outDelim == ";"
                                self.recordPhraseWordIfValid(transform.replacementText, endedSentence: ended, bundleID: bid)
                            }
                            if outDelim == " " && allowPhrasePred {
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
                                self.recordPhraseWordIfValid(w, endedSentence: ended, bundleID: bid)
                            } else if ended {
                                self.phrasePredictor.resetSentenceWindow()
                            }
                        } else if "/\\@_".contains(ch) {
                            self.phrasePredictor.resetSentenceWindow()
                        }
                    }
                }
            }

            let activeBid = activeBundleID ?? lastObservedBundleID
            let shouldTriggerSnippetKey: Bool
            if isStudioFeatureUnlocked(.snippetStudio),
               let lastChar = typed.last,
               !lastChar.isWhitespace {
                let trailingToken = rollingBuffer.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
                shouldTriggerSnippetKey = SnippetStore.isValidTrigger(trailingToken)
            } else {
                shouldTriggerSnippetKey = false
            }

            if let last = typed.last, (last.isLetter && last.isASCII) || last == "'" || last == "’" || shouldTriggerSnippetKey {
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
            } else if typed == " " && effectivePhrasePrediction(bundleID: activeBid) {
                overlay.hide()
                activeCandidates.removeAll(keepingCapacity: true)
                activeSnapshot = nil
                schedulePredictionQuery()
            } else {
                dismissOverlay(clearBuffer: false)
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func recordPhraseWordIfValid(_ rawText: String, endedSentence: Bool, bundleID: String? = nil) {
        let targetBundle = bundleID ?? activeBundleID ?? lastObservedBundleID
        guard enableHabitLearning && effectivePhrasePrediction(bundleID: targetBundle) else { return }
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
        let nowRoman = InputGuard.isCurrentInputSourceRomanKeyboardLayout()
        stateLock.lock()
        lastKnownRomanLayout = nowRoman
        let fallbackBuf = rollingBuffer
        stateLock.unlock()
        guard frontBundle != Bundle.main.bundleIdentifier,
              inputGuard.shouldAllowPrediction(frontmostBundleID: frontBundle, cachedRomanLayout: nowRoman) else {
            return
        }
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
        let nowRoman = InputGuard.isCurrentInputSourceRomanKeyboardLayout()
        stateLock.lock()
        activeBundleID = frontBundle
        activeAppName = targetApp?.localizedName
        lastKnownRomanLayout = nowRoman
        let fallbackBuf = rollingBuffer
        stateLock.unlock()
        guard inputGuard.shouldAllowPrediction(frontmostBundleID: frontBundle, cachedRomanLayout: nowRoman) else {
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

        let rawMatches = completer.candidates(
            textBeforeCursor: snapshot.textBeforeCursor,
            charAfterCursor: snapshot.charAfterCursor,
            textAfterCursorOnLine: snapshot.textAfterOnLine,
            bundleID: frontBundle,
            limit: 5
        )
        let matches = rawMatches.filter { match in
            if snapshot.caretLocation == nil,
               match.isSnippet,
               match.suffix.contains("\n") || match.suffix.contains("\r") {
                return false
            }
            return true
        }
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

    private func injectBackspaces(count: Int, proxy: CGEventTapProxy? = nil) {
        guard count > 0, let src = CGEventSource(stateID: .hidSystemState) else { return }
        let vkDelete = CGKeyCode(kVK_Delete)
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: vkDelete, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: vkDelete, keyDown: false) else {
                continue
            }
            down.flags = []
            up.flags = []
            down.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventTag)
            up.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventTag)
            if let proxy {
                down.tapPostEvent(proxy)
                up.tapPostEvent(proxy)
            } else {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    private func injectUnicodeString(_ text: String, proxy: CGEventTapProxy? = nil) {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty,
              let src = CGEventSource(stateID: .hidSystemState) else {
            return
        }

        var offset = 0
        while offset < utf16.count {
            var end = min(utf16.count, offset + 16)
            if end < utf16.count, (0xD800...0xDBFF).contains(utf16[end - 1]) {
                end -= 1
            }
            if end == offset {
                end = min(utf16.count, offset + 2)
            }
            let chunk = Array(utf16[offset..<end])
            offset = end
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else {
                continue
            }
            down.flags = []
            up.flags = []
            down.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventTag)
            up.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventTag)
            chunk.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
            }
            if let proxy {
                down.tapPostEvent(proxy)
                up.tapPostEvent(proxy)
            } else {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    private func injectLeftArrows(count: Int, proxy: CGEventTapProxy? = nil) {
        guard count > 0, let src = CGEventSource(stateID: .hidSystemState) else { return }
        let vkLeft = CGKeyCode(kVK_LeftArrow)
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: vkLeft, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: vkLeft, keyDown: false) else {
                continue
            }
            down.flags = []
            up.flags = []
            down.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventTag)
            up.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventTag)
            if let proxy {
                down.tapPostEvent(proxy)
                up.tapPostEvent(proxy)
            } else {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }
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
