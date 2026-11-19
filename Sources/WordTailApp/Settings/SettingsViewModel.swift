import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import WordTailCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case calibration = "Calibration"
    case keyStats = "KeyStats"
    case insights = "Insights"
    case dictionary = "Dictionary"
    case preferences = "Preferences"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .calibration: return "slider.horizontal.3"
        case .keyStats: return "keyboard"
        case .insights: return "chart.bar.xaxis"
        case .dictionary: return "character.book.closed"
        case .preferences: return "switch.2"
        }
    }
}

struct AppOffsetItem: Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let displayName: String
    let icon: NSImage
    var offset: Double
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
    @Published var keyStats: KeyStatsAggregateSnapshot = KeyStatsAggregateSnapshot()
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

    private var isRefreshing = false

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
        if let autoUpdater {
            self.autoCheckUpdates = autoUpdater.autoCheckEnabled
            self.availableRelease = autoUpdater.availableRelease
            self.isCheckingUpdates = autoUpdater.isChecking
            self.isInstallingUpdate = autoUpdater.isInstalling
            self.updateStatusText = autoUpdater.statusMessage
        } else {
            self.updateStatusText = "Current version v\(AutoUpdateManager.currentAppVersion())"
        }
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
        showcaseAppIcons: [String: NSImage] = [:]
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
        self.keyStats = keyStats
        self.showcaseAppIcons = showcaseAppIcons
    }

    func refresh(currentApp: (name: String, bundleID: String)?) {
        guard let engine, !isStaticShowcase else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        isEnabled = engine.isEnabled
        isTrusted = AXIsProcessTrusted() && engine.isTapActive
        globalOffset = Double(engine.globalVerticalAdjustment)
        ghostOpacity = Double(engine.ghostOpacity)
        appendSpaceOnAccept = engine.appendSpaceOnAccept
        autoCorrectOnSpace = engine.autoCorrectOnSpace
        autoCapitalizeSentences = engine.autoCapitalizeSentences
        enablePhrasePrediction = engine.enablePhrasePrediction
        enableHabitLearning = engine.enableHabitLearning
        enableKeyStatsTracking = engine.enableKeyStatsTracking
        showMenuBarKeyCount = engine.showMenuBarKeyCount
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
        keyStats = engine.keyStatsStore.snapshot(for: keyStatsRange)
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
        }

        let savedDict = (UserDefaults.standard.dictionary(forKey: "WordTailPerAppVerticalOffsets") as? [String: Double]) ?? [:]
        var merged: [String: Double] = [:]
        for (bid, val) in ScreenGeometry.builtInAppVerticalOffsets {
            merged[bid] = Double(val)
        }
        for (bid, val) in savedDict {
            merged[bid] = val
        }

        appOffsets = merged.map { bid, val in
            AppOffsetItem(
                bundleID: bid,
                displayName: Self.friendlyAppTitle(bundleID: bid, rawName: runningNames[bid] ?? Self.appName(forBundleID: bid)),
                icon: Self.appIcon(forBundleID: bid),
                offset: val
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

    func refreshInsights() {
        guard let engine, !isStaticShowcase else { return }
        insights = engine.insightsSnapshot()
        learnedBigrams = engine.topBigrams(limit: 8)
        keyStats = engine.keyStatsStore.snapshot(for: keyStatsRange)
    }

    func clearInsights() {
        guard let engine, !isStaticShowcase else { return }
        engine.clearInsightsAndContextualHabits()
        insights = engine.insightsSnapshot()
        learnedBigrams = []
        phraseEntries = engine.phrasePredictor.allEntries()
    }

    func refreshKeyStats() {
        guard let engine, !isStaticShowcase else { return }
        keyStats = engine.keyStatsStore.snapshot(for: keyStatsRange)
    }

    func clearKeyStats() {
        guard let engine, !isStaticShowcase else { return }
        engine.keyStatsStore.clearAll()
        keyStats = engine.keyStatsStore.snapshot(for: keyStatsRange)
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
            _ = try? engine.keyStatsStore.importJSONData(data, merge: true)
            refreshKeyStats()
            onStateChange()
        }
    }

    func resolvedAppIcon(bundleID: String) -> NSImage {
        if let custom = showcaseAppIcons[bundleID] {
            return custom
        }
        return Self.appIcon(forBundleID: bundleID)
    }

    func updateOffset(for bundleID: String, to newValue: Double) {
        let clamped = min(max((newValue * 20).rounded() / 20.0, -5.0), 5.0)
        if let idx = appOffsets.firstIndex(where: { $0.bundleID == bundleID }) {
            appOffsets[idx].offset = clamped
        }
        engine?.setVerticalAdjustment(CGFloat(clamped), forBundleID: bundleID)
    }

    func setGlobalOffsetClamped(_ newValue: Double) {
        globalOffset = min(max((newValue * 20).rounded() / 20.0, -5.0), 5.0)
    }

    func addAppOverride(bundleID: String) {
        guard let engine else { return }
        let startOffset = Double(engine.verticalAdjustment(forBundleID: bundleID))
        engine.setVerticalAdjustment(CGFloat(startOffset), forBundleID: bundleID)
        refresh(currentApp: nil)
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
        if let builtIn = ScreenGeometry.builtInAppVerticalOffsets[bundleID] {
            updateOffset(for: bundleID, to: Double(builtIn))
        } else {
            engine?.setVerticalAdjustment(nil, forBundleID: bundleID)
            appOffsets.removeAll { $0.bundleID == bundleID }
            refresh(currentApp: nil)
        }
    }

    func resetGlobalOffset() {
        globalOffset = Double(ScreenGeometry.defaultVerticalOffset)
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
            return "Off · Syncs dictionary, rules, phrases, Insights & KeyStats across Macs"
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
        let snap = engine.syncEngine.statusSnapshot()
        syncStatus = snap
        syncEnabled = snap.isEnabled
        vocabularyEntries = engine.vocabularyEntries()
        phraseEntries = engine.phrasePredictor.allEntries()
        correctionRules = engine.adaptiveStore.allEntries()
        insights = engine.insightsSnapshot()
        learnedBigrams = engine.topBigrams(limit: 8)
        keyStats = engine.keyStatsStore.snapshot(for: keyStatsRange)
        if let autoUpdater {
            autoCheckUpdates = autoUpdater.autoCheckEnabled
            availableRelease = autoUpdater.availableRelease
            isCheckingUpdates = autoUpdater.isChecking
            isInstallingUpdate = autoUpdater.isInstalling
            updateStatusText = autoUpdater.statusMessage
        }
    }

    @MainActor
    func checkForUpdatesClicked() {
        autoUpdater?.checkForUpdates(userInitiated: true)
    }

    @MainActor
    func installAvailableUpdateClicked() {
        if let rel = availableRelease {
            autoUpdater?.installReleaseNow(rel)
        } else {
            autoUpdater?.promptAndInstallCurrentRelease()
        }
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
        keyStats = engine.keyStatsStore.snapshot(for: keyStatsRange)
        isRefreshing = false
        onStateChange()
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
