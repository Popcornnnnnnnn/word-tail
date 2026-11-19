import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import WordTailCore

// MARK: - Linear Design Tokens

private enum LinearUI {
    static let accent = Color(red: 0.37, green: 0.42, blue: 0.89) // Linear Indigo (#5E6AD2)

    static func windowBg(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.067, green: 0.071, blue: 0.086)
            : Color(red: 0.976, green: 0.976, blue: 0.982)
    }

    static func sidebarBg(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.055, green: 0.059, blue: 0.071)
            : Color(red: 0.953, green: 0.955, blue: 0.965)
    }

    static func cardBg(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.094, green: 0.098, blue: 0.118)
            : Color.white
    }

    static func subtleFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.055)
            : Color.black.opacity(0.04)
    }

    static func hoverFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.085)
            : Color.black.opacity(0.065)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.075)
    }

    static func controlBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.11)
    }
}

// MARK: - Models & ViewModel

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

    private var isRefreshing = false

    init(
        engine: TypingEngine,
        currentApp: (name: String, bundleID: String)?,
        onStateChange: @escaping () -> Void
    ) {
        self.engine = engine
        self.onStateChange = onStateChange
        self.isStaticShowcase = false
        self.isEnabled = engine.isEnabled
        self.globalOffset = Double(engine.globalVerticalAdjustment)
        self.ghostOpacity = Double(engine.ghostOpacity)
        self.appendSpaceOnAccept = engine.appendSpaceOnAccept
        self.autoCorrectOnSpace = engine.autoCorrectOnSpace
        self.autoCapitalizeSentences = engine.autoCapitalizeSentences
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
        correctionRules = engine.adaptiveStore.allEntries()
        insights = engine.insightsSnapshot()
        learnedBigrams = engine.topBigrams(limit: 8)
        keyStats = engine.keyStatsStore.snapshot(for: keyStatsRange)

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
    }

    func removeVocabularyWord(_ word: String) {
        guard let engine else { return }
        engine.removeVocabularyWord(word)
        vocabularyEntries = engine.vocabularyEntries()
    }

    func clearLearnedVocabulary() {
        guard let engine else { return }
        engine.clearLearnedWords()
        vocabularyEntries = []
        correctionRules = []
        learnedBigrams = []
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
    }

    func removeCorrectionRule(_ trigger: String) {
        guard let engine else { return }
        engine.adaptiveStore.removeRuleOrUnmute(trigger: trigger)
        correctionRules = engine.adaptiveStore.allEntries()
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
        // Also include Dock-less launcher / menu-bar apps in /Applications (e.g. Raycast),
        // while excluding system XPC services and helper apps nested inside frameworks/bundles.
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

// MARK: - Linear Micro-Components

private struct LinearCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(LinearUI.cardBg(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(LinearUI.hairline(scheme), lineWidth: 1)
        )
    }
}

private struct LinearSectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.88))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LinearKbd: View {
    @Environment(\.colorScheme) private var scheme
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(LinearUI.subtleFill(scheme), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(LinearUI.controlBorder(scheme), lineWidth: 1)
            )
    }
}

private struct LinearSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.78)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? LinearUI.accent : Color.primary.opacity(0.16))
                    .frame(width: 30, height: 17)
                Circle()
                    .fill(Color.white)
                    .frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 0.5)
                    .padding(2)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct LinearSlider: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var value: Double
    let range: ClosedRange<Double>
    var showZeroTick: Bool = true

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let span = range.upperBound - range.lowerBound
            let progress = min(max((value - range.lowerBound) / span, 0), 1)
            let zeroProgress = min(max((0.0 - range.lowerBound) / span, 0), 1)
            let thumbX = progress * w
            let zeroX = zeroProgress * w

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.09))
                    .frame(height: 3)

                if showZeroTick && range.contains(0) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.22))
                        .frame(width: 1, height: 7)
                        .offset(x: zeroX - 0.5)
                }

                if showZeroTick && range.contains(0) {
                    let fillStart = min(zeroX, thumbX)
                    let fillW = max(1, abs(thumbX - zeroX))
                    Capsule(style: .continuous)
                        .fill(LinearUI.accent)
                        .frame(width: fillW, height: 3)
                        .offset(x: fillStart)
                } else {
                    Capsule(style: .continuous)
                        .fill(LinearUI.accent)
                        .frame(width: max(3, thumbX), height: 3)
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(scheme == .dark ? 0.35 : 0.18), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                    .offset(x: thumbX - 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let frac = min(max(drag.location.x / w, 0), 1)
                        let raw = range.lowerBound + frac * span
                        value = (raw * 20).rounded() / 20.0
                    }
            )
        }
        .frame(height: 18)
    }
}

private struct LinearOffsetStepper: View {
    @Environment(\.colorScheme) private var scheme
    let value: Double
    let onChange: (Double) -> Void

    @State private var hoverMinus = false
    @State private var hoverPlus = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                let step = NSEvent.modifierFlags.contains(.option) ? 0.50 : 0.10
                onChange(value - step)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 23, height: 24)
                    .background(hoverMinus ? LinearUI.hoverFill(scheme) : .clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoverMinus = $0 }
            .help("Lower 0.10 pt (⌥ Option-click for 0.50 pt)")

            Rectangle()
                .fill(LinearUI.hairline(scheme))
                .frame(width: 1, height: 14)

            Text(String(format: "%+.2f", value))
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.88))
                .frame(width: 50, height: 24)

            Rectangle()
                .fill(LinearUI.hairline(scheme))
                .frame(width: 1, height: 14)

            Button {
                let step = NSEvent.modifierFlags.contains(.option) ? 0.50 : 0.10
                onChange(value + step)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 23, height: 24)
                    .background(hoverPlus ? LinearUI.hoverFill(scheme) : .clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoverPlus = $0 }
            .help("Raise 0.10 pt (⌥ Option-click for 0.50 pt)")
        }
        .background(LinearUI.subtleFill(scheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(LinearUI.controlBorder(scheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct LinearActionButton: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let icon: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 9)
            .frame(height: 25)
            .background(hovered ? LinearUI.hoverFill(scheme) : LinearUI.subtleFill(scheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(LinearUI.controlBorder(scheme), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct LinearSegmentedChoices<T: Hashable>: View {
    @Environment(\.colorScheme) private var scheme
    let options: [(label: String, value: T)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let active = (selection == opt.value)
                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        selection = opt.value
                    }
                } label: {
                    Text(opt.label)
                        .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(active ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(
                            active
                                ? (scheme == .dark ? Color.white.opacity(0.14) : Color.white)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                        .shadow(color: active ? .black.opacity(scheme == .dark ? 0 : 0.06) : .clear, radius: 1, x: 0, y: 0.5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .fixedSize()
        .background(LinearUI.subtleFill(scheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(LinearUI.hairline(scheme), lineWidth: 1)
        )
    }
}

private struct LinearIconButton: View {
    @Environment(\.colorScheme) private var scheme
    let symbol: String
    let helpText: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovered ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background(hovered ? LinearUI.hoverFill(scheme) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(helpText)
    }
}

// MARK: - Main Linear Settings View

struct SettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: SettingsViewModel
    @State private var showAddAppPopover = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(LinearUI.hairline(scheme))
                .frame(width: 1)
            detailPane
        }
        .frame(width: 740, height: 548)
        .background(LinearUI.windowBg(scheme))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 38)

            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text("WordTail")
                        .font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 4) {
                        Circle()
                            .fill(vm.isTrusted ? (vm.isEnabled ? Color.green : Color.secondary) : Color.orange)
                            .frame(width: 5.5, height: 5.5)
                        Text(!vm.isTrusted ? "Needs Access" : (vm.isEnabled ? "Active" : "Paused"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)

            VStack(spacing: 3) {
                ForEach(SettingsSection.allCases) { section in
                    SidebarRow(
                        title: section.rawValue,
                        symbol: section.symbol,
                        isSelected: vm.selectedSection == section
                    ) {
                        if section == .insights {
                            vm.refreshInsights()
                        } else if section == .keyStats {
                            vm.refreshKeyStats()
                        }
                        vm.selectedSection = section
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            if !vm.isTrusted {
                Button {
                    vm.openAccessibilitySettings()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Grant Access")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 27)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            Rectangle()
                .fill(LinearUI.hairline(scheme))
                .frame(height: 1)

            HStack {
                Text("Enabled")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                LinearSwitch(isOn: $vm.isEnabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 172)
        .background(LinearUI.sidebarBg(scheme))
    }

    // MARK: Right Content Pane

    @ViewBuilder
    private var detailPane: some View {
        let content = VStack(alignment: .leading, spacing: 20) {
            switch vm.selectedSection {
            case .calibration:
                calibrationContent
            case .keyStats:
                keyStatsContent
            case .insights:
                insightsContent
            case .dictionary:
                dictionaryContent
            case .preferences:
                preferencesContent
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 24)

        if vm.isStaticShowcase {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Calibration Section

    private var calibrationContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Baseline Calibration")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("Leave a ghost word visible in an app to move it live")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                LinearCard {
                    HStack(spacing: 0) {
                        Text("PREVIEW")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, 12)

                        Text("I major in computer science and I kn")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.primary)

                        Rectangle()
                            .fill(LinearUI.accent)
                            .frame(width: 1.5, height: 15)

                        Text(vm.appendSpaceOnAccept ? "ow␣" : "ow")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Color.primary.opacity(vm.ghostOpacity))
                            .offset(y: CGFloat(-(vm.globalOffset - 0.70)))

                        Spacer()

                        LinearKbd(label: "⇥ Tab")
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LinearSectionHeader(
                    title: "Global Default",
                    subtitle: "Used for apps without a custom override below."
                )

                LinearCard {
                    HStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(LinearUI.subtleFill(scheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                        Text("All Other Apps")
                            .font(.system(size: 13, weight: .medium))

                        Spacer()

                                LinearSlider(value: $vm.globalOffset, range: -4.0...4.0)
                            .frame(width: 118)

                        LinearOffsetStepper(
                            value: vm.globalOffset,
                            onChange: { vm.setGlobalOffsetClamped($0) }
                        )

                        LinearIconButton(
                            symbol: "arrow.counterclockwise",
                            helpText: "Reset Global Default (+0.70 pt)"
                        ) {
                            vm.resetGlobalOffset()
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 46)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    LinearSectionHeader(
                        title: "Application Overrides",
                        subtitle: "Independent vertical baseline per app. ⌥-click −/+ for 0.50 pt steps."
                    )
                    Spacer()

                    HStack(spacing: 6) {
                        if !vm.availableAppsToAdd.isEmpty {
                            if vm.isStaticShowcase {
                                LinearActionButton(title: "Add Open App", icon: "plus") {}
                            } else {
                                LinearActionButton(title: "Add Open App", icon: "plus") {
                                    showAddAppPopover.toggle()
                                }
                                .popover(isPresented: $showAddAppPopover, arrowEdge: .bottom) {
                                    ScrollView(.vertical, showsIndicators: true) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            ForEach(vm.availableAppsToAdd) { app in
                                                Button {
                                                    vm.addAppOverride(bundleID: app.bundleID)
                                                    showAddAppPopover = false
                                                } label: {
                                                    HStack(spacing: 8) {
                                                        Image(nsImage: app.icon)
                                                            .resizable()
                                                            .frame(width: 18, height: 18)
                                                        Text(app.name)
                                                            .font(.system(size: 12.5))
                                                            .foregroundStyle(.primary)
                                                        Spacer()
                                                    }
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 5)
                                                    .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(6)
                                    }
                                    .frame(minWidth: 205, maxHeight: 320)
                                }
                            }
                        }

                        LinearActionButton(title: "Browse…", icon: "folder") {
                            vm.chooseApplicationFromDisk()
                        }
                    }
                }

                LinearCard {
                    ForEach(Array(vm.appOffsets.enumerated()), id: \.element.id) { idx, item in
                        if idx > 0 {
                            Rectangle()
                                .fill(LinearUI.hairline(scheme))
                                .frame(height: 1)
                                .padding(.leading, 46)
                        }

                        HStack(spacing: 10) {
                            Image(nsImage: item.icon)
                                .resizable()
                                .frame(width: 24, height: 24)

                            Text(item.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)

                            Spacer()

                            LinearSlider(
                                value: Binding(
                                    get: { item.offset },
                                    set: { vm.updateOffset(for: item.bundleID, to: $0) }
                                ),
                                range: -4.0...4.0
                            )
                            .frame(width: 118)

                            LinearOffsetStepper(
                                value: item.offset,
                                onChange: { vm.updateOffset(for: item.bundleID, to: $0) }
                            )

                            let isBuiltIn = ScreenGeometry.builtInAppVerticalOffsets[item.bundleID] != nil
                            LinearIconButton(
                                symbol: isBuiltIn ? "arrow.counterclockwise" : "xmark",
                                helpText: isBuiltIn ? "Reset default" : "Remove override"
                            ) {
                                vm.removeOrResetApp(bundleID: item.bundleID)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 46)
                    }
                }
            }
        }
    }

    // MARK: KeyStats Section

    private var keyStatsContent: some View {
        let ks = vm.keyStats
        return VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("KeyStats")
                        .font(.system(size: 16, weight: .semibold))
                    Text("100% local activity")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()

                LinearSegmentedChoices(
                    options: [
                        ("Today", StatsTimeRange.today),
                        ("7D", StatsTimeRange.days7),
                        ("30D", StatsTimeRange.days30),
                        ("All", StatsTimeRange.allTime)
                    ],
                    selection: $vm.keyStatsRange
                )

                LinearActionButton(title: "Import", icon: "square.and.arrow.down") {
                    vm.importKeyStatsJSON()
                }
                LinearActionButton(title: "Export", icon: "square.and.arrow.up") {
                    vm.exportKeyStatsJSON()
                }
            }

            // 4 Hardware KPI Cards
            HStack(spacing: 8) {
                LinearMetricTile(
                    label: "KEYSTROKES",
                    value: KeyStatsAggregateSnapshot.formatCompactCount(ks.totalKeyPresses),
                    subtitle: "\(ks.peakKPS) KPS · \(ks.leftHandPercent):\(100 - ks.leftHandPercent) L/R"
                )
                LinearMetricTile(
                    label: "CLICKS & STYLE",
                    value: KeyStatsAggregateSnapshot.formatCompactCount(ks.totalClicks),
                    subtitle: "\(ks.inputStyleLabel) · \(String(format: "%.1f", ks.keyToClickRatio)):1 K/C"
                )
                LinearMetricTile(
                    label: "MOUSE TRAVEL",
                    value: KeyStatsAggregateSnapshot.formatDistance(ks.mouseDistanceMeters),
                    subtitle: String(format: "%.2f Marathons", ks.marathonsEquivalent)
                )
                LinearMetricTile(
                    label: "SCROLL TRAVEL",
                    value: KeyStatsAggregateSnapshot.formatDistance(ks.scrollDistanceMeters),
                    subtitle: String(format: "%.2f Everests", ks.everestsEquivalent)
                )
            }

            // Interactive 65-Key MacBook ANSI Keyboard Heatmap
            VStack(alignment: .leading, spacing: 6) {
                ANSIKeyboardHeatmapView(
                    heatmap: ks.keyHeatmap,
                    totalKeys: ks.totalKeyPresses,
                    englishPercent: ks.englishKeyPercent
                )
            }

            // Bottom 2-Column Breakdown: Per-App Activity + Shortcuts & Calendar Heatmap
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    LinearSectionHeader(
                        title: "App Activity",
                        subtitle: "Keys, clicks & scroll across all apps"
                    )

                    LinearCard {
                        if ks.topApps.isEmpty {
                            Text("App activity appears automatically as you type, click, and scroll.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        } else {
                            ForEach(Array(ks.topApps.prefix(5).enumerated()), id: \.element.id) { idx, app in
                                if idx > 0 {
                                    Rectangle()
                                        .fill(LinearUI.hairline(scheme))
                                        .frame(height: 1)
                                        .padding(.leading, 36)
                                }
                                HStack(spacing: 8) {
                                    Image(nsImage: vm.resolvedAppIcon(bundleID: app.bundleID))
                                        .resizable()
                                        .frame(width: 18, height: 18)
                                    Text(app.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(KeyStatsAggregateSnapshot.formatCompactCount(app.keyPresses)) · \(KeyStatsAggregateSnapshot.formatCompactCount(app.clicks))c")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 31)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        LinearSectionHeader(
                            title: "Shortcuts & 14-Week Activity",
                            subtitle: "\(ks.activeDays) active day\(ks.activeDays == 1 ? "" : "s") · Max \(KeyStatsAggregateSnapshot.formatCompactCount(ks.maxDailyKeys)) keys/day"
                        )
                        Spacer()
                        if ks.totalKeyPresses > 0 || ks.totalClicks > 0 {
                            LinearIconButton(symbol: "trash", helpText: "Reset KeyStats history") {
                                vm.clearKeyStats()
                            }
                        }
                    }

                    LinearCard {
                        CalendarContributionGrid(days: ks.calendarDays)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 8)

                        if !ks.topShortcuts.isEmpty {
                            Rectangle()
                                .fill(LinearUI.hairline(scheme))
                                .frame(height: 1)

                            HStack(spacing: 5) {
                                ForEach(ks.topShortcuts.prefix(4)) { item in
                                    HStack(spacing: 2.5) {
                                        LinearKbd(label: item.label)
                                        Text("\(KeyStatsAggregateSnapshot.formatCompactCount(item.count))")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .fixedSize()
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Insights Section

    private var insightsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Typing Insights")
                        .font(.system(size: 16, weight: .semibold))
                    HStack(spacing: 5) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("100% local aggregate counters · Zero sentences or raw text logged")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if vm.insights.totalTypedLetters > 0 || vm.insights.tabsAccepted > 0 || !vm.learnedBigrams.isEmpty {
                    LinearActionButton(title: "Reset", icon: "arrow.counterclockwise") {
                        vm.clearInsights()
                    }
                }
            }

            // 4 Compact KPI Tiles
            HStack(spacing: 8) {
                let savedTimeLabel: String = {
                    let secs = vm.insights.estimatedSecondsSaved
                    if secs >= 60 {
                        return "~\(secs / 60)m · \(vm.insights.tabsAccepted) Tabs"
                    }
                    return secs > 0 ? "~\(secs)s · \(vm.insights.tabsAccepted) Tabs" : "\(vm.insights.tabsAccepted) Tabs"
                }()
                LinearMetricTile(
                    label: "CHARS SAVED",
                    value: "\(vm.insights.charactersSaved)",
                    subtitle: savedTimeLabel
                )
                LinearMetricTile(
                    label: "TAB HIT RATE",
                    value: "\(vm.insights.hitRatePercent)%",
                    subtitle: "\(vm.insights.tabsAccepted) of \(vm.insights.suggestionsShown)"
                )
                LinearMetricTile(
                    label: "BURST SPEED",
                    value: vm.insights.averageBurstWPM > 0 ? "\(vm.insights.averageBurstWPM) WPM" : "—",
                    subtitle: vm.insights.peakBurstWPM > 0 ? "Peak \(vm.insights.peakBurstWPM) WPM" : "English prose"
                )
                LinearMetricTile(
                    label: "ACCURACY",
                    value: String(format: "%.1f%%", vm.insights.cleanAccuracyPercent),
                    subtitle: "\(vm.insights.imeSwitches) IME switches"
                )
            }

            // 24-Hour Rhythm Card
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    LinearSectionHeader(title: "24-Hour Typing Rhythm")
                    Spacer()
                    Text(hourlySummaryCaption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                LinearCard {
                    HourlyRhythmChart(buckets: vm.insights.hourlyBuckets)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
            }

            // Two Side-by-Side Habit Cards
            HStack(alignment: .top, spacing: 10) {
                // Personal Typo Traps
                VStack(alignment: .leading, spacing: 7) {
                    LinearSectionHeader(
                        title: "Personal Typo Traps",
                        subtitle: "Backspace-corrected words (auto-boosted)"
                    )

                    LinearCard {
                        if vm.insights.typoTraps.isEmpty {
                            Text("Words you repeatedly mistype and backspace will appear here—and get boosted automatically.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        } else {
                            ForEach(Array(vm.insights.typoTraps.prefix(5).enumerated()), id: \.element.id) { idx, trap in
                                if idx > 0 {
                                    Rectangle()
                                        .fill(LinearUI.hairline(scheme))
                                        .frame(height: 1)
                                        .padding(.leading, 12)
                                }
                                HStack(spacing: 6) {
                                    Text(trap.commonMistype)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .strikethrough(true, color: .secondary)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                    Text(trap.word)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(trap.count)×")
                                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                // Learned Word Pairs & Crutches
                VStack(alignment: .leading, spacing: 7) {
                    LinearSectionHeader(
                        title: "Word Pairs & Prose Crutches",
                        subtitle: "Learned 2-word habits & filler frequency"
                    )

                    LinearCard {
                        if vm.learnedBigrams.isEmpty && vm.insights.fillerHabits.isEmpty {
                            Text("Common 2-word collocations (e.g. pull → request) and filler words build as you write.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        } else {
                            let pairs = Array(vm.learnedBigrams.prefix(3))
                            ForEach(Array(pairs.enumerated()), id: \.element.id) { idx, pair in
                                if idx > 0 {
                                    Rectangle()
                                        .fill(LinearUI.hairline(scheme))
                                        .frame(height: 1)
                                        .padding(.leading, 12)
                                }
                                HStack(spacing: 5) {
                                    Text(pair.previousWord)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 8.5, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                    Text(pair.word)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(LinearUI.accent)
                                    Spacer()
                                    Text("\(pair.count)×")
                                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 31)
                            }

                            let fillers = Array(vm.insights.fillerHabits.prefix(pairs.isEmpty ? 4 : 2))
                            ForEach(Array(fillers.enumerated()), id: \.element.id) { fIdx, filler in
                                if !pairs.isEmpty || fIdx > 0 {
                                    Rectangle()
                                        .fill(LinearUI.hairline(scheme))
                                        .frame(height: 1)
                                        .padding(.leading, 12)
                                }
                                HStack(spacing: 6) {
                                    Text("“\(filler.word)”")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(.primary.opacity(0.85))
                                    LinearKbd(label: "Filler")
                                    Spacer()
                                    Text("\(filler.count)×")
                                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 31)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var hourlySummaryCaption: String {
        let activeHours = vm.insights.hourlyBuckets.filter { $0.typedLetters >= 25 }
        guard !activeHours.isEmpty else {
            return "Builds automatically as you type in English"
        }
        var parts: [String] = []
        if let fastest = activeHours.filter({ $0.averageWPM > 0 }).max(by: { $0.averageWPM < $1.averageWPM }) {
            parts.append(String(format: "Peak %02d:00 (%d WPM)", fastest.hour, fastest.averageWPM))
        }
        if let roughest = activeHours.filter({ $0.backspaces >= 3 }).max(by: { $0.backspaceRate < $1.backspaceRate }) {
            parts.append(String(format: "Most edits %02d:00 (%.1f%%)", roughest.hour, roughest.backspaceRate * 100.0))
        }
        return parts.isEmpty ? "Active across \(activeHours.count)h" : parts.joined(separator: " · ")
    }

    // MARK: Dictionary Section

    private var dictionaryContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Personal & Technical Dictionary")
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                LinearSectionHeader(title: "Built-In Lexicon")

                LinearCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Software Engineering & AI Vocabulary")
                                .font(.system(size: 13, weight: .medium))
                            Text("Includes 180+ CS, AI, and quantitative terms (TypeScript, PyTorch, Kubernetes…)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.enableTechLexicon)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LinearSectionHeader(
                    title: "Learnable Auto-Correct & Shorthand Rules",
                    subtitle: "Built-in contractions (im → I'm, dont → don't) + rules auto-learned from your repairs and ⌫ undos."
                )

                LinearCard {
                    HStack(spacing: 8) {
                        TextField("Trigger (e.g. tmr)", text: $vm.newRuleTrigger)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, design: .monospaced))
                            .frame(width: 135)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        TextField("Replacement (e.g. tomorrow)", text: $vm.newRuleReplacement)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .onSubmit {
                                vm.submitNewCorrectionRule()
                            }
                        LinearActionButton(title: "Add Rule", icon: nil) {
                            vm.submitNewCorrectionRule()
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 42)

                    ForEach(vm.correctionRules.prefix(25)) { rule in
                        Rectangle()
                            .fill(LinearUI.hairline(scheme))
                            .frame(height: 1)
                            .padding(.leading, 12)

                        HStack(spacing: 8) {
                            Text(rule.trigger)
                                .font(.system(size: 12, design: .monospaced))
                                .strikethrough(rule.source == .muted, color: .secondary)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(rule.replacement)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(rule.source == .muted ? .secondary : .primary)
                            LinearKbd(label: rule.source.rawValue)
                            Spacer()
                            if rule.count > 0 && rule.source == .learned {
                                Text("\(rule.count)×")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            LinearIconButton(
                                symbol: "xmark",
                                helpText: rule.source == .muted ? "Unmute trigger" : "Remove rule"
                            ) {
                                vm.removeCorrectionRule(rule.trigger)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 35)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    LinearSectionHeader(
                        title: "Custom & Learned Words",
                        subtitle: "Pinned words always rank first when their prefix matches."
                    )
                    Spacer()
                    if !vm.vocabularyEntries.isEmpty {
                        LinearActionButton(title: "Clear All", icon: "trash") {
                            vm.clearLearnedVocabulary()
                        }
                    }
                }

                LinearCard {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        TextField("Add custom English word (e.g. Antigravity, ColleagueName)…", text: $vm.newCustomWordInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .onSubmit {
                                vm.submitNewCustomWord()
                            }
                        LinearActionButton(title: "Add", icon: nil) {
                            vm.submitNewCustomWord()
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 42)

                    if !vm.vocabularyEntries.isEmpty {
                        ForEach(vm.vocabularyEntries.prefix(40)) { entry in
                            Rectangle()
                                .fill(LinearUI.hairline(scheme))
                                .frame(height: 1)
                                .padding(.leading, 12)

                            HStack(spacing: 8) {
                                Text(entry.word)
                                    .font(.system(size: 12.5, weight: .medium))
                                if entry.isCustom {
                                    LinearKbd(label: "Pinned")
                                }
                                Spacer()
                                if entry.count > 0 {
                                    Text("\(entry.count)×")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                LinearIconButton(symbol: "xmark", helpText: "Remove word") {
                                    vm.removeVocabularyWord(entry.word)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                        }
                    }
                }
            }
        }
    }

    // MARK: Preferences Section

    private var preferencesContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Preferences")
                .font(.system(size: 16, weight: .semibold))

            // Acceptance & Rules
            VStack(alignment: .leading, spacing: 8) {
                LinearSectionHeader(title: "Typing & Acceptance")

                LinearCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Insert Space After Tab")
                                .font(.system(size: 13, weight: .medium))
                            Text("Appends a trailing space on Tab (skips automatically before punctuation)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.appendSpaceOnAccept)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Auto-Correct Typos & Contractions")
                                .font(.system(size: 13, weight: .medium))
                            Text("Fixes obvious typos & patterns (im → I'm, teh → the) on Tab/Space; ⌫ undoes & learns")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.autoCorrectOnSpace)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Auto-Capitalize Sentences")
                                .font(.system(size: 13, weight: .medium))
                            Text("Capitalizes sentence starts and standalone “I” on Space (skips CLI commands)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.autoCapitalizeSentences)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Learn Word Habits & Insights")
                                .font(.system(size: 13, weight: .medium))
                            Text("Learns 2-word pairs, per-app vocabulary, typo traps, and local speed stats")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.enableHabitLearning)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Minimum Typed Letters")
                                .font(.system(size: 13, weight: .medium))
                            Text("Characters required before showing a completion")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSegmentedChoices(
                            options: [("2", 2), ("3", 3), ("4", 4)],
                            selection: $vm.minPrefix
                        )
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Minimum Remaining Suffix")
                                .font(.system(size: 13, weight: .medium))
                            Text("Skip trivial 1-character endings when set to 2+")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSegmentedChoices(
                            options: [("1", 1), ("2", 2), ("3", 3)],
                            selection: $vm.minSuffix
                        )
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                }
            }

            // Appearance & Shortcuts
            VStack(alignment: .leading, spacing: 8) {
                LinearSectionHeader(title: "Appearance & Shortcuts")

                LinearCard {
                    HStack(spacing: 12) {
                        Text("Ghost Text Opacity")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        LinearSlider(value: $vm.ghostOpacity, range: 0.18...0.68, showZeroTick: false)
                            .frame(width: 150)
                        Text("\(Int((vm.ghostOpacity * 100).rounded()))%")
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                        LinearIconButton(symbol: "arrow.counterclockwise", helpText: "Reset opacity (38%)") {
                            vm.resetOpacity()
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        Text("Cycle Alternative Word Candidates")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            LinearKbd(label: "⌥ [")
                            LinearKbd(label: "⌥ ]")
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        HStack(spacing: 8) {
                            Text("Global Pause / Resume Shortcut")
                                .font(.system(size: 13, weight: .medium))
                            LinearKbd(label: "⌃ ⌥ W")
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.enableGlobalHotkey)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Show Today’s Keystrokes in Menu Bar")
                                .font(.system(size: 13, weight: .medium))
                            Text("Displays a compact live counter (e.g. 4.2k) beside the menu bar icon")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.showMenuBarKeyCount)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                }
            }

            // System
            VStack(alignment: .leading, spacing: 8) {
                LinearSectionHeader(title: "System")

                LinearCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Enable KeyStats Hardware Telemetry")
                                .font(.system(size: 13, weight: .medium))
                            Text("Counts keys, clicks, mouse & scroll distance, and per-app totals locally")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.enableKeyStatsTracking)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Show Icon in Dock & App Switcher")
                                .font(.system(size: 13, weight: .medium))
                            Text("Turn off if you prefer running in the top menu bar only")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.showDockIcon)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Launch at Login")
                                .font(.system(size: 13, weight: .medium))
                            Text("Start WordTail automatically when you sign in to macOS")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.launchAtLogin)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Browser & Electron Bridge")
                                .font(.system(size: 13, weight: .medium))
                            Text("Wakes accessibility trees in Chrome, Codex, and Antigravity")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.chromiumBridge)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                }
            }
        }
    }
}

private struct LinearMetricTile: View {
    @Environment(\.colorScheme) private var scheme
    let label: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(LinearUI.cardBg(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(LinearUI.hairline(scheme), lineWidth: 1)
        )
    }
}

private struct HourlyRhythmChart: View {
    @Environment(\.colorScheme) private var scheme
    let buckets: [HourlyTypingBucket]

    var body: some View {
        let maxLetters = max(40, buckets.map(\.typedLetters).max() ?? 40)
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(buckets) { bucket in
                    let ratio = CGFloat(bucket.typedLetters) / CGFloat(maxLetters)
                    let barH = bucket.typedLetters == 0 ? 3.0 : max(6.0, ratio * 48.0)
                    let highError = bucket.typedLetters >= 35 && bucket.backspaceRate >= 0.075

                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(
                                bucket.typedLetters == 0
                                    ? LinearUI.subtleFill(scheme)
                                    : (highError ? Color.orange.opacity(0.85) : LinearUI.accent.opacity(0.85))
                            )
                            .frame(height: barH)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50, maxHeight: 50, alignment: .bottom)
                    .help(
                        bucket.typedLetters > 0
                            ? String(
                                format: "%02d:00 — %d chars, %d WPM, %.1f%% backspace",
                                bucket.hour, bucket.typedLetters, bucket.averageWPM, bucket.backspaceRate * 100.0
                            )
                            : String(format: "%02d:00 — No English typing", bucket.hour)
                    )
                }
            }

            HStack {
                Text("00:00")
                Spacer()
                Text("06:00")
                Spacer()
                Text("12:00")
                Spacer()
                Text("18:00")
                Spacer()
                Text("23:00")
            }
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
    }
}

private struct ANSIKeyboardHeatmapView: View {
    @Environment(\.colorScheme) private var scheme
    let heatmap: [String: Int]
    let totalKeys: Int
    let englishPercent: Int
    @State private var hoveredKey: KeySpec?

    var body: some View {
        let maxCount = max(1, heatmap.values.max() ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                LinearSectionHeader(title: "Keyboard Heatmap")
                Spacer()
                if let key = hoveredKey {
                    let count = heatmap[key.id, default: 0]
                    let pct = totalKeys > 0 ? Double(count) / Double(totalKeys) * 100.0 : 0
                    Text("\(key.id): \(count) presses (\(String(format: "%.1f%%", pct)))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(LinearUI.accent)
                } else {
                    Text("\(englishPercent)% Roman · \(100 - englishPercent)% CJK/IME")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            LinearCard {
                VStack(spacing: 3.5) {
                    ForEach(Array(KeyCodeMapper.ansiRows.enumerated()), id: \.offset) { rowIdx, row in
                        GeometryReader { geo in
                            let spacing: CGFloat = 3.5
                            let totalWeight = row.reduce(0.0) { $0 + $1.widthWeight }
                            let usableW = max(10, geo.size.width - spacing * CGFloat(max(0, row.count - 1)))

                            HStack(spacing: spacing) {
                                ForEach(row, id: \.id) { spec in
                                    let count = heatmap[spec.id, default: 0]
                                    let intensity = count > 0
                                        ? min(1.0, max(0.14, sqrt(Double(count) / Double(maxCount))))
                                        : 0.0
                                    let keyW = usableW * CGFloat(spec.widthWeight / totalWeight)

                                    ZStack {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(
                                                count == 0
                                                    ? LinearUI.subtleFill(scheme)
                                                    : LinearUI.accent.opacity(intensity)
                                            )
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .stroke(
                                                hoveredKey?.id == spec.id
                                                    ? LinearUI.accent
                                                    : LinearUI.hairline(scheme),
                                                lineWidth: 1
                                            )
                                        Text(spec.label)
                                            .font(.system(size: rowIdx == 0 ? 8.5 : 9.5, weight: count > 0 ? .semibold : .regular, design: .rounded))
                                            .foregroundStyle(
                                                intensity >= 0.52
                                                    ? Color.white
                                                    : Color.primary.opacity(count > 0 ? 0.88 : 0.55)
                                            )
                                    }
                                    .frame(width: keyW, height: rowIdx == 0 ? 17 : 22)
                                    .onHover { inside in
                                        if inside {
                                            hoveredKey = spec
                                        } else if hoveredKey?.id == spec.id {
                                            hoveredKey = nil
                                        }
                                    }
                                }
                            }
                        }
                        .frame(height: rowIdx == 0 ? 17 : 22)
                    }
                }
                .padding(10)
            }
        }
    }
}

private struct CalendarContributionGrid: View {
    @Environment(\.colorScheme) private var scheme
    let days: [CalendarActivityDay]

    var body: some View {
        let padded = days.count >= 98 ? Array(days.suffix(98)) : days
        let maxActions = max(50, padded.map(\.totalActions).max() ?? 50)
        let weeks = stride(from: 0, to: padded.count, by: 7).map { start in
            Array(padded[start..<min(start + 7, padded.count)])
        }

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3.5) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 3.5) {
                        ForEach(week) { day in
                            let ratio = Double(day.totalActions) / Double(maxActions)
                            let alpha = day.totalActions == 0 ? 0.0 : min(0.95, max(0.20, sqrt(ratio)))
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(day.totalActions == 0 ? LinearUI.subtleFill(scheme) : LinearUI.accent.opacity(alpha))
                                .frame(width: 8.5, height: 8.5)
                                .help("\(day.dateKey): \(day.keyPresses) keys · \(day.clicks) clicks")
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 4) {
                Text("14 weeks")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Less")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                ForEach([0.0, 0.25, 0.55, 0.90], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(level == 0 ? LinearUI.subtleFill(scheme) : LinearUI.accent.opacity(level))
                        .frame(width: 7, height: 7)
                }
                Text("More")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct SidebarRow: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? LinearUI.accent : .secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                isSelected
                    ? LinearUI.hoverFill(scheme)
                    : (hovered ? LinearUI.subtleFill(scheme) : Color.clear),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Window Controller

final class SettingsWindowController: NSWindowController {
    private var viewModel: SettingsViewModel!

    init(
        engine: TypingEngine,
        currentApp: (name: String, bundleID: String)?,
        onStateChange: @escaping () -> Void
    ) {
        super.init(window: nil)
        self.viewModel = SettingsViewModel(
            engine: engine,
            currentApp: currentApp,
            onStateChange: onStateChange
        )
        let hostingController = NSHostingController(rootView: SettingsView(vm: viewModel))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "WordTail"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.level = .normal
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(for currentApp: (name: String, bundleID: String)?, selectSection: SettingsSection? = nil) {
        viewModel.refresh(currentApp: currentApp)
        if let selectSection {
            viewModel.selectedSection = selectSection
        }
        showWindow(nil)
        window?.level = .normal
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
