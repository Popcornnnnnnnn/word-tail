import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import WordTailCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case calibration = "Calibration"
    case keyStats = "KeyStats"
    case appStats = "App Stats"
    case insights = "Insights"
    case dictionary = "Dictionary"
    case preferences = "Preferences"
    case pro = "Studio"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .calibration: return "slider.horizontal.3"
        case .keyStats: return "keyboard"
        case .appStats: return "square.grid.2x2"
        case .insights: return "chart.bar.xaxis"
        case .dictionary: return "character.book.closed"
        case .preferences: return "switch.2"
        case .pro: return "sparkles"
        }
    }
}

struct AppOffsetItem: Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let displayName: String
    let icon: NSImage
    var offset: Double
    var isDisplaySpecificOverride: Bool = false
    var hasPerDisplayOverrides: Bool = false
}

struct RunningAppChoice: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let icon: NSImage

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleID)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bundleID == rhs.bundleID
    }
}

final class SettingsViewModel: ObservableObject {
    private let engine: TypingEngine?
    private let autoUpdater: AutoUpdateManager?
    private let onStateChange: () -> Void
    let isStaticShowcase: Bool

    @Published var selectedSection: SettingsSection = .calibration

    @Published var isEnabled: Bool {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.isEnabled = isEnabled
            onStateChange()
        }
    }

    @Published var isTrusted: Bool = false

    @Published var globalOffset: Double {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.globalVerticalAdjustment = CGFloat(globalOffset)
        }
    }

    @Published var ghostOpacity: Double {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.ghostOpacity = CGFloat(ghostOpacity)
        }
    }

    @Published var appendSpaceOnAccept: Bool {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.appendSpaceOnAccept = appendSpaceOnAccept
        }
    }

    @Published var autoCorrectOnSpace: Bool {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.autoCorrectOnSpace = autoCorrectOnSpace
        }
    }

    @Published var autoCapitalizeSentences: Bool {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.autoCapitalizeSentences = autoCapitalizeSentences
        }
    }

    @Published var enablePhrasePrediction: Bool {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.enablePhrasePrediction = enablePhrasePrediction
        }
    }

    @Published var enableHabitLearning: Bool {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.enableHabitLearning = enableHabitLearning
        }
    }

    @Published var enableKeyStatsTracking: Bool {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.enableKeyStatsTracking = enableKeyStatsTracking
        }
    }

    @Published var showMenuBarKeyCount: Bool {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.showMenuBarKeyCount = showMenuBarKeyCount
            onStateChange()
        }
    }

    @Published var showMenuBarClickCount: Bool {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.showMenuBarClickCount = showMenuBarClickCount
            onStateChange()
        }
    }

    @Published var enableDynamicMenuBarColor: Bool {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.enableDynamicMenuBarColor = enableDynamicMenuBarColor
            onStateChange()
        }
    }

    @Published var dynamicMenuBarColorStyle: String {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.dynamicMenuBarColorStyle = dynamicMenuBarColorStyle
            onStateChange()
        }
    }

    @Published var dynamicMenuBarWindowSeconds: Int {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.dynamicMenuBarWindowSeconds = dynamicMenuBarWindowSeconds
            onStateChange()
        }
    }

    @Published var mouseCalibrationFactor: Double {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.mouseCalibrationFactor = mouseCalibrationFactor
        }
    }

    @Published var enableMilestoneNotifications: Bool {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.enableMilestoneNotifications = enableMilestoneNotifications
            onStateChange()
        }
    }

    @Published var milestoneKeyThreshold: Int {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.milestoneKeyThreshold = milestoneKeyThreshold
        }
    }

    @Published var milestoneClickThreshold: Int {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.milestoneClickThreshold = milestoneClickThreshold
        }
    }

    @Published var showingMouseCalibrationSheet: Bool = false

    @Published var enableTechLexicon: Bool {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.enableTechLexicon = enableTechLexicon
        }
    }

    @Published var enableGlobalHotkey: Bool {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.enableGlobalHotkey = enableGlobalHotkey
        }
    }

    @Published var appOffsets: [AppOffsetItem] = []
    @Published var availableAppsToAdd: [RunningAppChoice] = []
    @Published var connectedDisplays: [DisplayDescriptor] = []
    @Published var selectedDisplayKey: String? = nil {
        didSet {
            guard !isRefreshing, !isStaticShowcase, oldValue != selectedDisplayKey else { return }
            refreshCalibrationOffsets(forceReloadList: true)
        }
    }

    @Published var minPrefix: Int {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.minimumPrefixLength = minPrefix
        }
    }

    @Published var minSuffix: Int {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.minimumSuffixLength = minSuffix
        }
    }

    @Published var chromiumBridge: Bool {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            engine?.enableChromiumBridge = chromiumBridge
        }
    }

    @Published var showDockIcon: Bool {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            UserDefaults.standard.set(showDockIcon, forKey: "WordTailShowDockIcon")
            let windowToKeep = NSApp.windows.first { $0.title == "WordTail" }
            NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                windowToKeep?.makeKeyAndOrderFront(nil)
            }
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            UserDefaults.standard.set(true, forKey: "WordTailLoginItemUserConfigured")
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                isRefreshing = true
                launchAtLogin = (SMAppService.mainApp.status == .enabled)
                isRefreshing = false
            }
        }
    }

    @Published var vocabularyEntries: [VocabularyEntry] = []
    @Published var newCustomWordInput: String = ""
    @Published var phraseEntries: [PhraseEntry] = []
    @Published var newCustomPhraseInput: String = ""
    @Published var correctionRules: [CorrectionRuleEntry] = []
    @Published var newRuleTrigger: String = ""
    @Published var newRuleReplacement: String = ""
    @Published var insights: TypingInsightsSnapshot = TypingInsightsSnapshot()
    @Published var learnedBigrams: [BigramHabitEntry] = []
    @Published var keyStatsRange: StatsTimeRange = .today {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            refreshKeyStats()
        }
    }
    @Published var keyStatsDeviceScope: StatsDeviceScope = .allDevices {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            refreshKeyStats()
        }
    }
    @Published var keyStatsImportMessage: String? = nil
    @Published var keyStats: KeyStatsAggregateSnapshot = KeyStatsAggregateSnapshot()
    @Published var selectedStatsDate: Date = Calendar.current.startOfDay(for: Date()) {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            refreshKeyStats()
        }
    }
    @Published var hourlyRecent24Hours: Bool = false {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            refreshHourlyTrend()
        }
    }
    @Published var hourlyTrendBuckets: [HourlyTrendBucket] = []
    @Published var busiestKeyHour: String? = nil
    @Published var busiestClickHour: String? = nil
    @Published var showcaseAppIcons: [String: NSImage] = [:]

    @Published var syncStatus: SyncStatusSnapshot = SyncStatusSnapshot(
        isEnabled: false,
        folderPath: nil,
        isICloudDrive: false,
        deviceID: "",
        peers: [],
        lastSyncedAt: nil,
        lastError: nil
    )
    @Published var syncEnabled: Bool = false {
        didSet {
            guard !isRefreshing, !isStaticShowcase, let engine else { return }
            if syncEnabled {
                if let existingPath = syncStatus.folderPath, !existingPath.isEmpty {
                    applySyncResult(engine.syncEngine.enableSync(folderURL: URL(fileURLWithPath: existingPath, isDirectory: true)))
                } else if let icloudURL = SyncEngine.defaultICloudDriveFolderURL() {
                    applySyncResult(engine.syncEngine.enableSync(folderURL: icloudURL))
                } else {
                    chooseCustomSyncFolder()
                }
            } else {
                applySyncResult(engine.syncEngine.disableSync())
            }
        }
    }
    @Published var isSyncingNow: Bool = false

    @Published var autoCheckUpdates: Bool = true {
        didSet {
            guard !isRefreshing, !isStaticShowcase else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.autoUpdater?.autoCheckEnabled = self.autoCheckUpdates
            }
        }
    }
    @Published var availableRelease: AvailableRelease? = nil
    @Published var isCheckingUpdates: Bool = false
    @Published var isInstallingUpdate: Bool = false
    @Published var updateStatusText: String = ""
    @Published var proUI: WordTailProUIState {
        didSet {
            guard !isRefreshing, !isStaticShowcase, let engine else { return }
            if oldValue.bilingualCompletionEnabled != proUI.bilingualCompletionEnabled {
                engine.bilingualCompletionEnabled = proUI.bilingualCompletionEnabled
            }
            if oldValue.bilingualSpacingEnabled != proUI.bilingualSpacingEnabled {
                engine.bilingualSpacingEnabled = proUI.bilingualSpacingEnabled
            }
        }
    }
    var proCallbacks: ProSettingsCallbacks = SettingsViewModel.placeholderProCallbacks()

    private var isRefreshing = false
    private var lastTargetApp: (name: String, bundleID: String)?
    private var displayedProfileTarget: (name: String, bundleID: String)?

    @MainActor
    init(
        engine: TypingEngine,
        autoUpdater: AutoUpdateManager? = nil,
        currentApp: (name: String, bundleID: String)?,
        onStateChange: @escaping () -> Void
    ) {
        self.engine = engine
        self.autoUpdater = autoUpdater
        self.onStateChange = onStateChange
        self.isStaticShowcase = false
        self.isEnabled = engine.isEnabled
        self.globalOffset = Double(engine.globalVerticalAdjustment)
        self.ghostOpacity = Double(engine.ghostOpacity)
        self.appendSpaceOnAccept = engine.appendSpaceOnAccept
        self.autoCorrectOnSpace = engine.autoCorrectOnSpace
        self.autoCapitalizeSentences = engine.autoCapitalizeSentences
        self.enablePhrasePrediction = engine.enablePhrasePrediction
        self.enableHabitLearning = engine.enableHabitLearning
        self.enableKeyStatsTracking = engine.enableKeyStatsTracking
        self.showMenuBarKeyCount = engine.showMenuBarKeyCount
        self.showMenuBarClickCount = engine.showMenuBarClickCount
        self.enableDynamicMenuBarColor = engine.enableDynamicMenuBarColor
        self.dynamicMenuBarColorStyle = engine.dynamicMenuBarColorStyle
        self.dynamicMenuBarWindowSeconds = engine.dynamicMenuBarWindowSeconds
        self.mouseCalibrationFactor = engine.mouseCalibrationFactor
        self.enableMilestoneNotifications = engine.enableMilestoneNotifications
        self.milestoneKeyThreshold = engine.milestoneKeyThreshold
        self.milestoneClickThreshold = engine.milestoneClickThreshold
        self.enableTechLexicon = engine.enableTechLexicon
        self.enableGlobalHotkey = engine.enableGlobalHotkey
        self.minPrefix = engine.minimumPrefixLength
        self.minSuffix = engine.minimumSuffixLength
        self.chromiumBridge = engine.enableChromiumBridge
        if UserDefaults.standard.object(forKey: "WordTailShowDockIcon") == nil {
            self.showDockIcon = true
        } else {
            self.showDockIcon = UserDefaults.standard.bool(forKey: "WordTailShowDockIcon")
        }
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        let initialSync = engine.syncEngine.statusSnapshot()
        self.syncStatus = initialSync
        self.syncEnabled = initialSync.isEnabled
        self.proUI = Self.makeEmptyProUIState(
            bilingualCompletion: engine.bilingualCompletionEnabled,
            bilingualSpacing: engine.bilingualSpacingEnabled
        )
        if let autoUpdater {
            self.autoCheckUpdates = autoUpdater.autoCheckEnabled
            self.availableRelease = autoUpdater.availableRelease
            self.isCheckingUpdates = autoUpdater.isChecking
            self.isInstallingUpdate = autoUpdater.isInstalling
            self.updateStatusText = autoUpdater.statusMessage
        } else {
            self.updateStatusText = AutoUpdateManager.isBundledApp
                ? "Current version v\(AutoUpdateManager.currentAppVersion())"
                : "Development build"
        }
        self.proCallbacks = makeProCallbacks()
        refresh(currentApp: currentApp)
    }

    /// Isolated showcase initializer for generating documentation screenshots without touching user defaults or live state.
    init(
        showcaseSection: SettingsSection,
        appOffsets: [AppOffsetItem],
        insights: TypingInsightsSnapshot,
        bigrams: [BigramHabitEntry],
        vocabulary: [VocabularyEntry],
        keyStats: KeyStatsAggregateSnapshot = KeyStatsAggregateSnapshot(),
        hourlyTrendBuckets: [HourlyTrendBucket] = [],
        showcaseAppIcons: [String: NSImage] = [:],
        proUI: WordTailProUIState? = nil
    ) {
        self.engine = nil
        self.autoUpdater = nil
        self.onStateChange = {}
        self.isStaticShowcase = true
        self.selectedSection = showcaseSection
        self.isEnabled = true
        self.isTrusted = true
        self.globalOffset = 0.70
        self.ghostOpacity = 0.38
        self.appendSpaceOnAccept = true
        self.autoCorrectOnSpace = true
        self.autoCapitalizeSentences = true
        self.enablePhrasePrediction = true
        self.enableHabitLearning = true
        self.enableKeyStatsTracking = true
        self.showMenuBarKeyCount = true
        self.showMenuBarClickCount = true
        self.enableDynamicMenuBarColor = false
        self.dynamicMenuBarColorStyle = "dot"
        self.dynamicMenuBarWindowSeconds = 30
        self.mouseCalibrationFactor = 1.0
        self.enableMilestoneNotifications = false
        self.milestoneKeyThreshold = 10_000
        self.milestoneClickThreshold = 2_000
        self.enableTechLexicon = true
        self.enableGlobalHotkey = true
        self.minPrefix = 2
        self.minSuffix = 2
        self.chromiumBridge = true
        self.showDockIcon = true
        self.launchAtLogin = true
        self.appOffsets = appOffsets
        self.availableAppsToAdd = [
            RunningAppChoice(bundleID: "com.apple.mail", name: "Mail", icon: NSImage(size: NSSize(width: 18, height: 18)))
        ]
        self.insights = insights
        self.learnedBigrams = bigrams
        self.vocabularyEntries = vocabulary
        self.keyStatsRange = keyStats.range
        self.keyStatsDeviceScope = keyStats.deviceScope
        self.keyStats = keyStats
        self.hourlyTrendBuckets = hourlyTrendBuckets
        self.busiestKeyHour = hourlyTrendBuckets.max(by: { $0.syncedKeys < $1.syncedKeys })?.axisLabel
        self.busiestClickHour = hourlyTrendBuckets.max(by: { $0.syncedClicks < $1.syncedClicks })?.axisLabel
        self.showcaseAppIcons = showcaseAppIcons
        self.proUI = proUI ?? Self.makeEmptyProUIState(
            bilingualCompletion: true,
            bilingualSpacing: true,
            wrappedSummary: TypingReportExporter.summarize(keyStats: keyStats, insights: insights)
        )
    }

    func refresh(currentApp: (name: String, bundleID: String)?) {
        guard let engine, !isStaticShowcase else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        isEnabled = engine.isEnabled
        isTrusted = AXIsProcessTrusted() && engine.isTapActive
        ghostOpacity = Double(engine.ghostOpacity)
        appendSpaceOnAccept = engine.appendSpaceOnAccept
        autoCorrectOnSpace = engine.autoCorrectOnSpace
        autoCapitalizeSentences = engine.autoCapitalizeSentences
        enablePhrasePrediction = engine.enablePhrasePrediction
        enableHabitLearning = engine.enableHabitLearning
        enableKeyStatsTracking = engine.enableKeyStatsTracking
        showMenuBarKeyCount = engine.showMenuBarKeyCount
        showMenuBarClickCount = engine.showMenuBarClickCount
        enableDynamicMenuBarColor = engine.enableDynamicMenuBarColor
        dynamicMenuBarColorStyle = engine.dynamicMenuBarColorStyle
        dynamicMenuBarWindowSeconds = engine.dynamicMenuBarWindowSeconds
        mouseCalibrationFactor = engine.mouseCalibrationFactor
        enableMilestoneNotifications = engine.enableMilestoneNotifications
        milestoneKeyThreshold = engine.milestoneKeyThreshold
        milestoneClickThreshold = engine.milestoneClickThreshold
        enableTechLexicon = engine.enableTechLexicon
        enableGlobalHotkey = engine.enableGlobalHotkey
        minPrefix = engine.minimumPrefixLength
        minSuffix = engine.minimumSuffixLength
        chromiumBridge = engine.enableChromiumBridge
        if UserDefaults.standard.object(forKey: "WordTailShowDockIcon") == nil {
            showDockIcon = true
        } else {
            showDockIcon = UserDefaults.standard.bool(forKey: "WordTailShowDockIcon")
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        vocabularyEntries = engine.vocabularyEntries()
        phraseEntries = engine.phrasePredictor.allEntries()
        correctionRules = engine.adaptiveStore.allEntries()
        insights = engine.insightsSnapshot()
        learnedBigrams = engine.topBigrams(limit: 8)
        keyStats = keyStatsRange == .today
            ? engine.keyStatsStore.singleDaySnapshot(for: selectedStatsDate, deviceScope: keyStatsDeviceScope)
            : engine.keyStatsStore.snapshot(for: keyStatsRange, deviceScope: keyStatsDeviceScope)
        let hourly = engine.keyStatsStore.hourlyTrend(for: selectedStatsDate, recent24Hours: hourlyRecent24Hours)
        hourlyTrendBuckets = hourly.buckets
        busiestKeyHour = hourly.busiestKeyHour
        busiestClickHour = hourly.busiestClickHour
        let curSync = engine.syncEngine.statusSnapshot()
        syncStatus = curSync
        syncEnabled = curSync.isEnabled
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if let autoUpdater {
                    autoCheckUpdates = autoUpdater.autoCheckEnabled
                    availableRelease = autoUpdater.availableRelease
                    isCheckingUpdates = autoUpdater.isChecking
                    isInstallingUpdate = autoUpdater.isInstalling
                    updateStatusText = autoUpdater.statusMessage
                }
            }
        }

        syncCalibrationOffsetsLocked(forceReloadList: true, currentApp: currentApp)
        refreshProUI()
    }

    func refreshCalibrationOffsets(forceReloadList: Bool = false) {
        guard !isStaticShowcase, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        syncCalibrationOffsetsLocked(forceReloadList: forceReloadList)
    }

    private func syncCalibrationOffsetsLocked(
        forceReloadList: Bool,
        currentApp: (name: String, bundleID: String)? = nil
    ) {
        guard let engine, !isStaticShowcase else { return }

        var displays = ScreenGeometry.connectedDisplays()
        let activeDisplayKeys = Set(displays.map(\.key))
        for savedKey in engine.verticalOffsetStore.allSavedDisplayKeys().sorted() where !activeDisplayKeys.contains(savedKey) {
            displays.append(DisplayDescriptor(key: savedKey, name: Self.friendlyDisplayName(forKey: savedKey)))
        }
        if connectedDisplays != displays {
            connectedDisplays = displays
        }
        if let sel = selectedDisplayKey, !displays.contains(where: { $0.key == sel }) {
            selectedDisplayKey = nil
        }

        let nextGlobal = engine.verticalOffsetStore.globalOffset
        if abs(globalOffset - nextGlobal) > 0.0001 {
            globalOffset = nextGlobal
        }

        let merged = engine.verticalOffsetStore.mergedAppOffsets(forDisplayKey: selectedDisplayKey)
        if !forceReloadList,
           currentApp == nil,
           Set(appOffsets.map(\.bundleID)) == Set(merged.keys) {
            for idx in appOffsets.indices {
                let bid = appOffsets[idx].bundleID
                if let nextVal = merged[bid], abs(appOffsets[idx].offset - nextVal) > 0.0001 {
                    appOffsets[idx].offset = nextVal
                }
                let isSpecific = selectedDisplayKey.map {
                    engine.verticalOffsetStore.hasDisplaySpecificOverride(forBundleID: bid, displayKey: $0)
                } ?? false
                if appOffsets[idx].isDisplaySpecificOverride != isSpecific {
                    appOffsets[idx].isDisplaySpecificOverride = isSpecific
                }
                let hasAnyDisplay = engine.verticalOffsetStore.hasAnyDisplayOverride(forBundleID: bid)
                if appOffsets[idx].hasPerDisplayOverrides != hasAnyDisplay {
                    appOffsets[idx].hasPerDisplayOverrides = hasAnyDisplay
                }
            }
            return
        }

        reloadCalibrationAppsLocked(merged: merged, currentApp: currentApp)
    }

    private func reloadCalibrationAppsLocked(
        merged: [String: Double],
        currentApp: (name: String, bundleID: String)?
    ) {
        guard let engine else { return }
        var runningNames: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where Self.isUserFacingRunningApp(app) {
            guard let bid = app.bundleIdentifier,
                  bid != Bundle.main.bundleIdentifier,
                  !InputGuard.defaultExcludedBundleIDs.contains(bid) else {
                continue
            }
            runningNames[bid] = app.localizedName ?? Self.appName(forBundleID: bid)
        }
        if let currentApp,
           currentApp.bundleID != Bundle.main.bundleIdentifier,
           !InputGuard.defaultExcludedBundleIDs.contains(currentApp.bundleID) {
            runningNames[currentApp.bundleID] = currentApp.name
            lastTargetApp = currentApp
        }

        appOffsets = merged.map { bid, val in
            AppOffsetItem(
                bundleID: bid,
                displayName: Self.friendlyAppTitle(bundleID: bid, rawName: runningNames[bid] ?? Self.appName(forBundleID: bid)),
                icon: Self.appIcon(forBundleID: bid),
                offset: val,
                isDisplaySpecificOverride: selectedDisplayKey.map {
                    engine.verticalOffsetStore.hasDisplaySpecificOverride(forBundleID: bid, displayKey: $0)
                } ?? false,
                hasPerDisplayOverrides: engine.verticalOffsetStore.hasAnyDisplayOverride(forBundleID: bid)
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        let existingIDs = Set(appOffsets.map(\.bundleID))
        availableAppsToAdd = runningNames
            .filter { !existingIDs.contains($0.key) }
            .map {
                RunningAppChoice(
                    bundleID: $0.key,
                    name: Self.friendlyAppTitle(bundleID: $0.key, rawName: $0.value),
                    icon: Self.appIcon(forBundleID: $0.key)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func friendlyDisplayName(forKey key: String) -> String {
        if key.hasPrefix("builtin") {
            return "Built-in Display"
        }
        if key.hasPrefix("ext:") {
            return "External Display"
        }
        return key
    }

    func refreshInsights() {
        guard let engine, !isStaticShowcase else { return }
        insights = engine.insightsSnapshot()
        learnedBigrams = engine.topBigrams(limit: 8)
        keyStats = engine.keyStatsStore.snapshot(for: keyStatsRange, deviceScope: keyStatsDeviceScope)
    }

    func clearInsights() {
        guard let engine, !isStaticShowcase else { return }
        engine.clearInsightsAndContextualHabits()
        insights = engine.insightsSnapshot()
        learnedBigrams = []
        phraseEntries = engine.phrasePredictor.allEntries()
    }

    var canImportFromInstalledKeyStats: Bool {
        !isStaticShowcase && KeyStatsStore.hasInstalledKeyStatsData()
    }

    var showsStatsDevicePicker: Bool {
        keyStats.deviceCount > 1 || keyStatsDeviceScope == .thisMac
    }

    func refreshKeyStats() {
        guard let engine, !isStaticShowcase else { return }
        keyStats = keyStatsRange == .today
            ? engine.keyStatsStore.singleDaySnapshot(for: selectedStatsDate, deviceScope: keyStatsDeviceScope)
            : engine.keyStatsStore.snapshot(for: keyStatsRange, deviceScope: keyStatsDeviceScope)
        refreshHourlyTrend()
    }

    func refreshHourlyTrend() {
        guard let engine, !isStaticShowcase else { return }
        let res = engine.keyStatsStore.hourlyTrend(for: selectedStatsDate, recent24Hours: hourlyRecent24Hours)
        hourlyTrendBuckets = res.buckets
        busiestKeyHour = res.busiestKeyHour
        busiestClickHour = res.busiestClickHour
    }

    var statsDateBounds: (earliest: Date, latest: Date) {
        guard let engine else {
            let today = Calendar.current.startOfDay(for: Date())
            return (today, today)
        }
        return engine.keyStatsStore.availableDateBounds(scope: keyStatsDeviceScope)
    }

    var isSelectedDateToday: Bool {
        Calendar.current.isDateInToday(selectedStatsDate)
    }

    var canStepStatsDateBackward: Bool {
        let cal = Calendar.current
        let bounds = statsDateBounds
        return cal.startOfDay(for: selectedStatsDate) > cal.startOfDay(for: bounds.earliest)
    }

    var canStepStatsDateForward: Bool {
        let cal = Calendar.current
        let bounds = statsDateBounds
        return cal.startOfDay(for: selectedStatsDate) < cal.startOfDay(for: bounds.latest)
    }

    func stepStatsDate(byDays delta: Int) {
        let cal = Calendar.current
        let bounds = statsDateBounds
        let candidate = cal.date(byAdding: .day, value: delta, to: selectedStatsDate) ?? selectedStatsDate
        let clamped = max(bounds.earliest, min(bounds.latest, cal.startOfDay(for: candidate)))
        selectedStatsDate = clamped
    }

    func resetStatsDateToToday() {
        selectedStatsDate = Calendar.current.startOfDay(for: Date())
    }

    func beginMouseCalibration() {
        engine?.keyStatsStore.beginMouseCalibration()
    }

    func currentMouseCalibrationPixels() -> Double {
        engine?.keyStatsStore.currentMouseCalibrationPixels() ?? 0
    }

    func finishMouseCalibration() -> (pixels: Double, factor: Double)? {
        guard let result = engine?.keyStatsStore.finishMouseCalibration(knownMeters: 0.10) else {
            return nil
        }
        mouseCalibrationFactor = result.factor
        return result
    }

    func cancelMouseCalibration() {
        engine?.keyStatsStore.cancelMouseCalibration()
    }

    func resetMouseCalibrationFactor() {
        mouseCalibrationFactor = 1.0
    }

    func resetTodayKeyStats() {
        guard let engine, !isStaticShowcase else { return }
        let alert = NSAlert()
        alert.messageText = "Reset Today's Stats on This Mac?"
        alert.informativeText = "Only today's statistics recorded on this Mac will be cleared. Earlier days and synced peer devices remain intact."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset Today")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        engine.keyStatsStore.resetTodayLocal()
        keyStatsImportMessage = nil
        refreshKeyStats()
        onStateChange()
    }

    func clearKeyStats() {
        guard let engine, !isStaticShowcase else { return }
        let alert = NSAlert()
        alert.messageText = "Reset All KeyStats History?"
        alert.informativeText = "This clears local and imported KeyStats records from this Mac. Export a JSON backup first if you want to keep your history."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset History")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        engine.keyStatsStore.clearAll()
        keyStatsImportMessage = nil
        refreshKeyStats()
        onStateChange()
    }

    func exportKeyStatsJSON() {
        guard let engine, !isStaticShowcase else { return }
        engine.keyStatsStore.flushNow()
        let panel = NSSavePanel()
        panel.title = "Export KeyStats Data"
        panel.allowedContentTypes = [.json]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "wordtail-keystats-\(formatter.string(from: Date())).json"
        if panel.runModal() == .OK, let url = panel.url {
            if let data = try? engine.keyStatsStore.exportJSONData() {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func importKeyStatsJSON() {
        guard let engine, !isStaticShowcase else { return }
        let panel = NSOpenPanel()
        panel.title = "Import KeyStats or WordTail JSON"
        panel.message = "Supports both WordTail archives and KeyStats export JSON files."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            do {
                let count = try engine.keyStatsStore.importJSONData(data, merge: true)
                refreshKeyStats()
                keyStatsImportMessage = "Merged \(count) day\(count == 1 ? "" : "s") from JSON"
                pushSyncInBackgroundIfEnabled()
                onStateChange()
            } catch {
                keyStatsImportMessage = error.localizedDescription
            }
        }
    }

    func importFromInstalledKeyStatsApp() {
        guard let engine, !isStaticShowcase else { return }
        do {
            let report = try engine.keyStatsStore.importFromInstalledKeyStats(includeSyncedPeers: true)
            refreshKeyStats()
            if report.peerDaysImported > 0 {
                keyStatsImportMessage = "Merged \(report.localDaysImported) local days + \(report.peerDaysImported) synced peer days"
            } else {
                keyStatsImportMessage = "Merged \(report.localDaysImported) days from KeyStats.app"
            }
            pushSyncInBackgroundIfEnabled()
            onStateChange()
        } catch {
            keyStatsImportMessage = error.localizedDescription
        }
    }

    func resolvedAppIcon(bundleID: String) -> NSImage {
        if let custom = showcaseAppIcons[bundleID] {
            return custom
        }
        return Self.appIcon(forBundleID: bundleID)
    }

    func updateOffset(for bundleID: String, to newValue: Double) {
        let sanitized = VerticalOffsetStore.sanitize(newValue)
        if let idx = appOffsets.firstIndex(where: { $0.bundleID == bundleID }) {
            appOffsets[idx].offset = sanitized
            if selectedDisplayKey != nil {
                appOffsets[idx].isDisplaySpecificOverride = true
                appOffsets[idx].hasPerDisplayOverrides = true
            }
        }
        engine?.setVerticalAdjustment(CGFloat(sanitized), forBundleID: bundleID, displayKey: selectedDisplayKey)
    }

    func setGlobalOffsetClamped(_ newValue: Double) {
        globalOffset = VerticalOffsetStore.sanitize(newValue)
    }

    func addAppOverride(bundleID: String) {
        guard let engine else { return }
        let startOffset = Double(engine.verticalAdjustment(forBundleID: bundleID, displayKey: selectedDisplayKey))
        engine.setVerticalAdjustment(CGFloat(startOffset), forBundleID: bundleID, displayKey: selectedDisplayKey)
        refreshCalibrationOffsets(forceReloadList: true)
    }

    func chooseApplicationFromDisk() {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK,
           let url = panel.url,
           let bundle = Bundle(url: url),
           let bid = bundle.bundleIdentifier {
            addAppOverride(bundleID: bid)
        }
    }

    func removeOrResetApp(bundleID: String) {
        engine?.setVerticalAdjustment(nil, forBundleID: bundleID, displayKey: selectedDisplayKey)
        refreshCalibrationOffsets(forceReloadList: true)
    }

    func resetGlobalOffset() {
        globalOffset = VerticalOffsetStore.sanitize(Double(ScreenGeometry.defaultVerticalOffset))
    }

    func resetOpacity() {
        ghostOpacity = 0.38
    }

    func submitNewCustomWord() {
        guard let engine, engine.addCustomWord(newCustomWordInput) else { return }
        newCustomWordInput = ""
        vocabularyEntries = engine.vocabularyEntries()
        pushSyncInBackgroundIfEnabled()
    }

    func removeVocabularyWord(_ word: String) {
        guard let engine else { return }
        engine.removeVocabularyWord(word)
        vocabularyEntries = engine.vocabularyEntries()
        pushSyncInBackgroundIfEnabled()
    }

    func clearLearnedVocabulary() {
        guard let engine else { return }
        engine.clearLearnedWords()
        vocabularyEntries = []
        phraseEntries = []
        correctionRules = []
        learnedBigrams = []
        pushSyncInBackgroundIfEnabled()
    }

    func submitNewCustomPhrase() {
        guard let engine,
              engine.phrasePredictor.addCustomPhrase(newCustomPhraseInput, persistAsync: false) else {
            return
        }
        newCustomPhraseInput = ""
        phraseEntries = engine.phrasePredictor.allEntries()
        pushSyncInBackgroundIfEnabled()
    }

    func removePhraseEntry(_ entry: PhraseEntry) {
        guard let engine else { return }
        engine.phrasePredictor.removeEntry(entry)
        phraseEntries = engine.phrasePredictor.allEntries()
        pushSyncInBackgroundIfEnabled()
    }

    func submitNewCorrectionRule() {
        guard let engine,
              engine.adaptiveStore.addCustomRule(
                  trigger: newRuleTrigger,
                  replacement: newRuleReplacement,
                  persistAsync: false
              ) else {
            return
        }
        newRuleTrigger = ""
        newRuleReplacement = ""
        correctionRules = engine.adaptiveStore.allEntries()
        pushSyncInBackgroundIfEnabled()
    }

    func removeCorrectionRule(_ trigger: String) {
        guard let engine else { return }
        engine.adaptiveStore.removeRuleOrUnmute(trigger: trigger)
        correctionRules = engine.adaptiveStore.allEntries()
        pushSyncInBackgroundIfEnabled()
    }

    var hasICloudDriveAvailable: Bool {
        SyncEngine.defaultICloudDriveFolderURL() != nil
    }

    var syncSubtitleText: String {
        if let err = syncStatus.lastError, !err.isEmpty {
            return err
        }
        guard syncStatus.isEnabled else {
            return "Off · Syncs dictionary, rules, phrases, Pro packs/snippets/profiles, Insights & KeyStats across Macs"
        }
        let locLabel: String
        if syncStatus.isICloudDrive {
            locLabel = "iCloud Drive"
        } else if let path = syncStatus.folderPath {
            locLabel = (path as NSString).abbreviatingWithTildeInPath
        } else {
            locLabel = "Folder"
        }
        let peerPart: String
        if syncStatus.syncedPeerCount == 0 {
            peerPart = "1 Mac connected"
        } else {
            peerPart = "\(syncStatus.syncedPeerCount + 1) Macs merged"
        }
        if let last = syncStatus.lastSyncedAt {
            let tf = DateFormatter()
            tf.dateFormat = "HH:mm"
            return "\(locLabel) · \(peerPart) · Synced \(tf.string(from: last))"
        }
        return "\(locLabel) · \(peerPart)"
    }

    func useICloudDriveSync() {
        guard let engine, let url = SyncEngine.defaultICloudDriveFolderURL() else { return }
        applySyncResult(engine.syncEngine.enableSync(folderURL: url))
    }

    func chooseCustomSyncFolder() {
        guard let engine else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose WordTail Sync Folder"
        panel.message = "Pick an iCloud Drive, Dropbox, Syncthing, or shared folder to sync across your Macs."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let existing = syncStatus.folderPath {
            panel.directoryURL = URL(fileURLWithPath: existing, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            applySyncResult(engine.syncEngine.enableSync(folderURL: url))
        } else if syncStatus.folderPath == nil {
            isRefreshing = true
            syncEnabled = false
            isRefreshing = false
        }
    }

    func revealSyncFolderInFinder() {
        guard let path = syncStatus.folderPath, !path.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func syncNowClicked() {
        guard let engine, !isSyncingNow else { return }
        isSyncingNow = true
        engine.syncEngine.syncAsync { [weak self] snap in
            guard let self else { return }
            self.isSyncingNow = false
            self.applySyncResult(snap)
        }
    }

    @MainActor
    func refreshUpdateAndSyncStatus() {
        guard let engine, !isStaticShowcase else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        isEnabled = engine.isEnabled
        isTrusted = AXIsProcessTrusted() && engine.isTapActive
        let snap = engine.syncEngine.statusSnapshot()
        syncStatus = snap
        syncEnabled = snap.isEnabled
        vocabularyEntries = engine.vocabularyEntries()
        phraseEntries = engine.phrasePredictor.allEntries()
        correctionRules = engine.adaptiveStore.allEntries()
        insights = engine.insightsSnapshot()
        learnedBigrams = engine.topBigrams(limit: 8)
        keyStats = keyStatsRange == .today
            ? engine.keyStatsStore.singleDaySnapshot(for: selectedStatsDate, deviceScope: keyStatsDeviceScope)
            : engine.keyStatsStore.snapshot(for: keyStatsRange, deviceScope: keyStatsDeviceScope)
        let hourly = engine.keyStatsStore.hourlyTrend(for: selectedStatsDate, recent24Hours: hourlyRecent24Hours)
        hourlyTrendBuckets = hourly.buckets
        busiestKeyHour = hourly.busiestKeyHour
        busiestClickHour = hourly.busiestClickHour
        if let autoUpdater {
            autoCheckUpdates = autoUpdater.autoCheckEnabled
            availableRelease = autoUpdater.availableRelease
            isCheckingUpdates = autoUpdater.isChecking
            isInstallingUpdate = autoUpdater.isInstalling
            updateStatusText = autoUpdater.statusMessage
        }
        syncCalibrationOffsetsLocked(forceReloadList: false)
        refreshProUI()
    }

    private func syncDisplayedProfileTarget() {
        guard let engine, !isStaticShowcase else { return }
        if let targetApp = engine.lastObservedTargetApp ?? lastTargetApp {
            let friendlyName = Self.friendlyAppTitle(bundleID: targetApp.bundleID, rawName: targetApp.name)
            displayedProfileTarget = (name: friendlyName, bundleID: targetApp.bundleID)
            proUI.activeProfileTargetName = friendlyName
        } else {
            displayedProfileTarget = nil
            proUI.activeProfileTargetName = nil
        }
    }

    @MainActor
    func checkForUpdatesClicked() {
        autoUpdater?.checkForUpdates(userInitiated: true)
    }

    @MainActor
    func reviewAvailableUpdateClicked() {
        autoUpdater?.reviewAvailableUpdate()
    }

    private func applySyncResult(_ snap: SyncStatusSnapshot) {
        guard let engine else { return }
        isRefreshing = true
        syncStatus = snap
        syncEnabled = snap.isEnabled
        vocabularyEntries = engine.vocabularyEntries()
        phraseEntries = engine.phrasePredictor.allEntries()
        correctionRules = engine.adaptiveStore.allEntries()
        insights = engine.insightsSnapshot()
        learnedBigrams = engine.topBigrams(limit: 8)
        keyStats = keyStatsRange == .today
            ? engine.keyStatsStore.singleDaySnapshot(for: selectedStatsDate, deviceScope: keyStatsDeviceScope)
            : engine.keyStatsStore.snapshot(for: keyStatsRange, deviceScope: keyStatsDeviceScope)
        let hourly = engine.keyStatsStore.hourlyTrend(for: selectedStatsDate, recent24Hours: hourlyRecent24Hours)
        hourlyTrendBuckets = hourly.buckets
        busiestKeyHour = hourly.busiestKeyHour
        busiestClickHour = hourly.busiestClickHour
        syncCalibrationOffsetsLocked(forceReloadList: false)
        isRefreshing = false
        refreshProUI()
        onStateChange()
    }

    func refreshProUI(statusMessage: String? = nil, isError: Bool = false) {
        guard let engine, !isStaticShowcase else { return }
        let wasRefreshing = isRefreshing
        isRefreshing = true
        defer { isRefreshing = wasRefreshing }

        let enabledSet = Set(engine.domainPackStore.enabledPackIDs)
        let builtInItems = DomainLexiconPack.builtInPacks.map { pack in
            ProDomainPackItem(
                id: pack.id,
                name: pack.name,
                tagline: pack.tagline,
                wordCount: pack.words.count,
                isEnabled: enabledSet.contains(pack.id),
                isCustom: false
            )
        }
        let customItems = engine.domainPackStore.customPacks.map { custom in
            ProDomainPackItem(
                id: custom.id,
                name: custom.name,
                tagline: "Imported custom vocabulary pack",
                wordCount: custom.words.count,
                isEnabled: true,
                isCustom: true
            )
        }

        let starterSnippetIDs: Set<String> = [";date", ";iso", ";time", ";meet", ";pr", ";clip"]
        let snippetItems = engine.snippetStore.snippets.map { snippet in
            let scope: String
            if snippet.scopedBundleIDs.isEmpty {
                scope = "All Apps"
            } else if snippet.scopedBundleIDs.count == 1 {
                scope = Self.appName(forBundleID: snippet.scopedBundleIDs[0])
            } else {
                scope = "\(snippet.scopedBundleIDs.count) Apps"
            }
            return ProSnippetItem(
                id: snippet.id,
                trigger: snippet.trigger,
                title: snippet.title,
                previewBody: snippet.body.replacingOccurrences(of: "\n", with: " ↵ "),
                appScopeLabel: scope,
                isEnabled: snippet.isEnabled,
                isBuiltIn: starterSnippetIDs.contains(snippet.id)
            )
        }

        let profileItems = engine.appProfileStore.profiles.map { profile in
            ProAppProfileItem(
                id: profile.id,
                bundleID: profile.bundleID,
                displayName: Self.friendlyAppTitle(bundleID: profile.bundleID, rawName: profile.displayName),
                presetTitle: profile.preset.title,
                summary: Self.summarizeWritingProfile(profile)
            )
        }

        syncDisplayedProfileTarget()
        let allStats = engine.keyStatsStore.snapshot(for: .allTime, deviceScope: .allDevices)
        let allInsights = engine.insightsSnapshot()
        let wrapped = TypingReportExporter.summarize(keyStats: allStats, insights: allInsights)

        proUI.entitlementState = engine.licenseManager.entitlementState
        proUI.hasUsedTrial = engine.licenseManager.hasUsedTrial
        if let statusMessage {
            proUI.statusMessage = statusMessage
            proUI.isErrorStatus = isError
        }
        proUI.packs = builtInItems + customItems
        proUI.snippets = snippetItems
        proUI.profiles = profileItems
        proUI.bilingualCompletionEnabled = engine.bilingualCompletionEnabled
        proUI.bilingualSpacingEnabled = engine.bilingualSpacingEnabled
        proUI.wrappedSummary = wrapped
    }

    private func makeProCallbacks() -> ProSettingsCallbacks {
        ProSettingsCallbacks(
            activateLicense: { [weak self] rawKey in
                guard let self, let engine = self.engine else { return }
                switch engine.licenseManager.activate(licenseKey: rawKey) {
                case .success(let payload):
                    engine.syncCompleterProState()
                    self.proUI.licenseKeyDraft = ""
                    self.refreshProUI(statusMessage: "Activated Pro license for \(payload.email).")
                    self.onStateChange()
                case .failure(let error):
                    self.refreshProUI(statusMessage: error.localizedDescription, isError: true)
                }
            },
            startTrial: { [weak self] in
                guard let self, let engine = self.engine else { return }
                if engine.licenseManager.startLocalTrial() {
                    engine.syncCompleterProState()
                    self.refreshProUI(statusMessage: "14-day free trial started.")
                    self.onStateChange()
                } else {
                    self.refreshProUI(statusMessage: "Free trial is already used on this Mac.", isError: true)
                }
            },
            deactivateLicense: { [weak self] in
                guard let self, let engine = self.engine else { return }
                engine.licenseManager.deactivateLicense()
                engine.syncCompleterProState()
                self.refreshProUI(statusMessage: "License deactivated on this Mac.")
                self.onStateChange()
            },
            setPackEnabled: { [weak self] id, enabled in
                guard let self, let engine = self.engine else { return }
                var nextIDs = engine.domainPackStore.enabledPackIDs
                if enabled {
                    if !nextIDs.contains(id) { nextIDs.append(id) }
                } else {
                    nextIDs.removeAll { $0 == id }
                }
                guard engine.domainPackStore.setEnabledPackIDs(nextIDs) else {
                    self.refreshProUI(statusMessage: "Could not save domain pack settings.", isError: true)
                    return
                }
                engine.syncCompleterProState()
                self.refreshProUI()
                self.pushSyncInBackgroundIfEnabled()
            },
            importPack: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let engine = self.engine else { return }
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.allowedContentTypes = [
                        .json,
                        UTType(filenameExtension: "wordtailpack") ?? .json
                    ]
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    do {
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        let maxPackReadBytes = 512 * 1024 + 1
                        let data = try handle.read(upToCount: maxPackReadBytes) ?? Data()
                        let imported = try engine.domainPackStore.importCustomPack(data: data)
                        engine.syncCompleterProState()
                        self.refreshProUI(statusMessage: "Imported \"\(imported.name)\" (\(imported.words.count) words).")
                        self.pushSyncInBackgroundIfEnabled()
                    } catch {
                        self.refreshProUI(statusMessage: "Import failed: \(error.localizedDescription)", isError: true)
                    }
                }
            },
            exportPacks: { [weak self] in
                self?.exportPackPanel(packID: nil)
            },
            exportCustomPack: { [weak self] id in
                self?.exportPackPanel(packID: id)
            },
            addSnippet: { [weak self] rawTrigger, rawTitle, rawBody in
                guard let self, let engine = self.engine else { return }
                let trigger = rawTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard SnippetStore.isValidTrigger(trigger) else {
                    self.refreshProUI(
                        statusMessage: "Trigger must start with ; / : ! @ # \\ and be 2–24 non-space characters.",
                        isError: true
                    )
                    return
                }
                if engine.snippetStore.snippets.contains(where: { $0.trigger == trigger }) {
                    self.refreshProUI(
                        statusMessage: "A snippet for \(trigger) already exists.",
                        isError: true
                    )
                    return
                }
                let snippet = TextSnippet(trigger: trigger, title: title.isEmpty ? trigger : title, body: rawBody)
                if engine.snippetStore.addOrUpdateSnippet(snippet) {
                    self.proUI.newSnippetTrigger = ""
                    self.proUI.newSnippetTitle = ""
                    self.proUI.newSnippetBody = ""
                    self.refreshProUI(statusMessage: "Saved snippet \(trigger).")
                    self.pushSyncInBackgroundIfEnabled()
                } else {
                    self.refreshProUI(statusMessage: "Could not save snippet.", isError: true)
                }
            },
            setSnippetEnabled: { [weak self] id, isEnabled in
                guard let self, let engine = self.engine else { return }
                guard engine.snippetStore.toggleSnippet(id: id, isEnabled: isEnabled) else {
                    self.refreshProUI(statusMessage: "Failed updating snippet state.", isError: true)
                    return
                }
                self.refreshProUI()
                self.pushSyncInBackgroundIfEnabled()
            },
            deleteSnippet: { [weak self] id in
                guard let self, let engine = self.engine else { return }
                guard engine.snippetStore.deleteSnippet(id: id) else {
                    self.refreshProUI(statusMessage: "Failed deleting snippet.", isError: true)
                    return
                }
                self.refreshProUI(statusMessage: "Deleted snippet.")
                self.pushSyncInBackgroundIfEnabled()
            },
            applyProfilePreset: { [weak self] preset in
                guard let self, let engine = self.engine else { return }
                let mapped: AppProfilePreset = switch preset {
                case .coding: .engineeringChat
                case .prose: .formalDocs
                case .bilingual: .casualChat
                }
                guard let target = self.displayedProfileTarget else {
                    self.refreshProUI(
                        statusMessage: "Switch to another app briefly so WordTail detects the target app first.",
                        isError: true
                    )
                    return
                }
                guard engine.appProfileStore.applyPreset(mapped, toBundleID: target.bundleID, displayName: target.name) else {
                    self.refreshProUI(statusMessage: "Failed saving profile for \(target.name).", isError: true)
                    return
                }
                engine.syncCompleterProState()
                self.refreshProUI(statusMessage: "Applied \(mapped.title) profile to \(target.name).")
                self.pushSyncInBackgroundIfEnabled()
            },
            deleteProfile: { [weak self] bundleID in
                guard let self, let engine = self.engine else { return }
                guard engine.appProfileStore.delete(bundleID: bundleID) else {
                    self.refreshProUI(statusMessage: "Failed restoring global settings for \(bundleID).", isError: true)
                    return
                }
                engine.syncCompleterProState()
                self.refreshProUI(statusMessage: "Restored global settings for \(bundleID).")
                self.pushSyncInBackgroundIfEnabled()
            },
            exportPoster: { [weak self] aspect, colorScheme in
                Task { @MainActor [weak self] in
                    guard let self, let engine = self.engine else { return }
                    guard engine.isStudioFeatureUnlocked(.wrappedAndReports) else {
                        self.refreshProUI(statusMessage: "Activate Pro or start a trial to export posters.", isError: true)
                        return
                    }
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.png]
                    let ratioTag = aspect == .portrait3x4 ? "3x4" : "16x9"
                    let themeTag = colorScheme == .dark ? "Dark" : "Light"
                    panel.nameFieldStringValue = "WordTail-Wrapped-\(ratioTag)-\(themeTag).png"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    guard let data = WrappedPosterView.renderPNG(
                        summary: self.proUI.wrappedSummary,
                        aspect: aspect,
                        colorScheme: colorScheme
                    ) else {
                        self.refreshProUI(statusMessage: "Failed rendering Wrapped PNG.", isError: true)
                        return
                    }
                    do {
                        try data.write(to: url, options: .atomic)
                        self.refreshProUI(statusMessage: "Saved poster to \(url.lastPathComponent).")
                    } catch {
                        self.refreshProUI(statusMessage: "Export failed: \(error.localizedDescription)", isError: true)
                    }
                }
            },
            exportCSV: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let engine = self.engine else { return }
                    guard engine.isStudioFeatureUnlocked(.wrappedAndReports) else {
                        self.refreshProUI(statusMessage: "Activate Pro or start a trial to export CSV.", isError: true)
                        return
                    }
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.commaSeparatedText]
                    panel.nameFieldStringValue = "WordTail-Typing-Stats.csv"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    let reportSnap = engine.keyStatsStore.allTimeReportSnapshot(deviceScope: .allDevices)
                    let data = TypingReportExporter.csv(dailyPoints: reportSnap.dailyTrend, appSummaries: reportSnap.topApps)
                    do {
                        try data.write(to: url, options: .atomic)
                        self.refreshProUI(statusMessage: "Saved CSV to \(url.lastPathComponent).")
                    } catch {
                        self.refreshProUI(statusMessage: "Export failed: \(error.localizedDescription)", isError: true)
                    }
                }
            },
            exportMarkdown: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let engine = self.engine else { return }
                    guard engine.isStudioFeatureUnlocked(.wrappedAndReports) else {
                        self.refreshProUI(statusMessage: "Activate Pro or start a trial to export Markdown.", isError: true)
                        return
                    }
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.plainText]
                    panel.nameFieldStringValue = "WordTail-Typing-Wrapped.md"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    let reportSnap = engine.keyStatsStore.allTimeReportSnapshot(deviceScope: .allDevices)
                    let freshInsights = engine.insightsSnapshot()
                    let summary = TypingReportExporter.summarize(keyStats: reportSnap, insights: freshInsights)
                    let markdown = TypingReportExporter.markdownReport(
                        summary: summary,
                        dailyPoints: reportSnap.dailyTrend
                    )
                    do {
                        try Data(markdown.utf8).write(to: url, options: .atomic)
                        self.refreshProUI(statusMessage: "Saved Markdown to \(url.lastPathComponent).")
                    } catch {
                        self.refreshProUI(statusMessage: "Export failed: \(error.localizedDescription)", isError: true)
                    }
                }
            }
        )
    }

    private func exportPackPanel(packID: String?) {
        Task { @MainActor [weak self] in
            guard let self, let engine = self.engine else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "wordtailpack") ?? .json, .json]
            let targetCustom: CustomDomainPack? = packID.flatMap { id in
                engine.domainPackStore.customPacks.first(where: { $0.id == id })
            } ?? engine.domainPackStore.customPacks.first
            panel.nameFieldStringValue = "\(targetCustom?.id ?? "custom-domain-pack").wordtailpack"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                let data: Data
                let note: String
                if let targetCustom {
                    data = try engine.domainPackStore.exportCustomPackJSON(id: targetCustom.id)
                    note = "Exported \"\(targetCustom.name)\" to \(url.lastPathComponent)."
                } else {
                    let sample = CustomDomainPack(
                        id: "custom-team-pack",
                        name: "Custom Team Vocabulary",
                        words: Array((DomainLexiconPack.builtInPacks.first?.words ?? ["algorithm", "telemetry"]).prefix(20))
                    )
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    data = try encoder.encode(sample)
                    note = "Exported starter template \(url.lastPathComponent)."
                }
                try data.write(to: url, options: .atomic)
                self.refreshProUI(statusMessage: note)
            } catch {
                self.refreshProUI(statusMessage: "Export failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private static func summarizeWritingProfile(_ profile: AppWritingProfile) -> String {
        var parts: [String] = []
        if let cap = profile.autoCapitalizeSentences {
            parts.append(cap ? "Auto-Cap On" : "Auto-Cap Off")
        }
        if let fix = profile.autoCorrectOnSpace {
            parts.append(fix ? "Space-Fix On" : "Space-Fix Off")
        }
        if let phrase = profile.enablePhrasePrediction {
            parts.append(phrase ? "Phrases On" : "Phrases Off")
        }
        if let bi = profile.bilingualSpacingOverride {
            parts.append(bi ? "PanGu On" : "PanGu Off")
        }
        if let packs = profile.enabledDomainPackIDs, !packs.isEmpty {
            parts.append("\(packs.count) Pack(s)")
        }
        return parts.isEmpty ? "Inherits Global Rules" : parts.joined(separator: " · ")
    }

    private static func makeEmptyProUIState(
        bilingualCompletion: Bool,
        bilingualSpacing: Bool,
        wrappedSummary: TypingWrappedSummary = TypingReportExporter.summarize(
            keyStats: KeyStatsAggregateSnapshot(),
            insights: TypingInsightsSnapshot()
        )
    ) -> WordTailProUIState {
        WordTailProUIState(
            entitlementState: .free,
            hasUsedTrial: false,
            statusMessage: nil,
            isErrorStatus: false,
            licenseKeyDraft: "",
            packs: [],
            snippets: [],
            newSnippetTrigger: "",
            newSnippetTitle: "",
            newSnippetBody: "",
            profiles: [],
            bilingualCompletionEnabled: bilingualCompletion,
            bilingualSpacingEnabled: bilingualSpacing,
            wrappedSummary: wrappedSummary,
            posterAspect: .portrait3x4,
            posterColorScheme: .dark
        )
    }

    private static func placeholderProCallbacks() -> ProSettingsCallbacks {
        ProSettingsCallbacks(
            activateLicense: { _ in },
            startTrial: {},
            deactivateLicense: {},
            setPackEnabled: { _, _ in },
            importPack: {},
            exportPacks: {},
            exportCustomPack: { _ in },
            addSnippet: { _, _, _ in },
            setSnippetEnabled: { _, _ in },
            deleteSnippet: { _ in },
            applyProfilePreset: { _ in },
            deleteProfile: { _ in },
            exportPoster: { _, _ in },
            exportCSV: {},
            exportMarkdown: {}
        )
    }

    func pushSyncInBackgroundIfEnabled() {
        guard let engine, engine.syncEngine.statusSnapshot().isEnabled else { return }
        engine.syncEngine.syncAsync { [weak self] snap in
            self?.syncStatus = snap
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func friendlyAppTitle(bundleID: String, rawName: String) -> String {
        if bundleID == "com.openai.codex" && rawName == "ChatGPT" {
            return "Codex (ChatGPT)"
        }
        return rawName
    }

    static func appName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    static func isUserFacingRunningApp(_ app: NSRunningApplication) -> Bool {
        if app.activationPolicy == .regular {
            return true
        }
        guard app.activationPolicy == .accessory,
              let url = app.bundleURL,
              url.pathExtension == "app" else {
            return false
        }
        let path = url.path
        let inAppsFolder = path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        return inAppsFolder && !path.contains(".app/Contents/") && !path.contains(".framework/")
    }

    static func appIcon(forBundleID bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
