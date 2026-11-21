import AppKit
import SwiftUI
import WordTailCore

enum PopoverHistoryMetric: String, CaseIterable, Identifiable {
    case keys = "Keys"
    case clicks = "Clicks"
    case movement = "Movement"
    case scroll = "Scroll"

    var id: String { rawValue }
}

enum PopoverHistoryStyle: String, CaseIterable, Identifiable {
    case line = "Line"
    case bar = "Bar"

    var id: String { rawValue }
}

@MainActor
final class MenuBarPopoverViewModel: ObservableObject {
    @Published var today: KeyStatsAggregateSnapshot = KeyStatsAggregateSnapshot(range: .today, deviceScope: .allDevices)
    @Published var historySynced: KeyStatsAggregateSnapshot = KeyStatsAggregateSnapshot(range: .days7, deviceScope: .allDevices)
    @Published var historyThisMac: KeyStatsAggregateSnapshot = KeyStatsAggregateSnapshot(range: .days7, deviceScope: .thisMac)
    @Published var rates: (currentKPS: Int, currentCPS: Int, peakKPS: Int, peakCPS: Int) = (0, 0, 0, 0)

    @Published var isEnabled: Bool = true
    @Published var hasAccessibility: Bool = true
    @Published var brandIcon: NSImage? = nil

    @Published var activeAppName: String = ""
    @Published var activeAppBundleID: String = ""
    @Published var activeAppIcon: NSImage = NSImage()
    @Published var activeAppDefaultExcluded: Bool = false
    @Published var activeAppUserDisabled: Bool = false
    @Published var activeAppVerticalAdjustment: CGFloat = 0.70

    @Published var availableRelease: AvailableRelease? = nil
    @Published var isCheckingUpdates: Bool = false
    @Published var isInstallingUpdate: Bool = false

    @Published var historyRange: StatsTimeRange = .days7 {
        didSet {
            guard !isStaticShowcase else { return }
            refreshHistorySnapshots()
        }
    }
    @Published var historyMetric: PopoverHistoryMetric = .keys
    @Published var historyStyle: PopoverHistoryStyle = .line

    let isStaticShowcase: Bool

    private weak var engine: TypingEngine?
    private weak var inputGuard: InputGuard?
    private weak var autoUpdater: AutoUpdateManager?

    var onToggleEnabled: () -> Void = {}
    var onGrantAccessibility: () -> Void = {}
    var onToggleAppDisabled: (String) -> Void = { _ in }
    var onAdjustAppBaseline: (String, CGFloat) -> Void = { _, _ in }
    var onOpenSettingsSection: (SettingsSection?, StatsTimeRange?) -> Void = { _, _ in }
    var onCheckForUpdates: () -> Void = {}
    var onInstallRelease: (AvailableRelease) -> Void = { _ in }
    var onQuit: () -> Void = {}

    init(
        engine: TypingEngine? = nil,
        inputGuard: InputGuard? = nil,
        autoUpdater: AutoUpdateManager? = nil,
        isStaticShowcase: Bool = false
    ) {
        self.engine = engine
        self.inputGuard = inputGuard
        self.autoUpdater = autoUpdater
        self.isStaticShowcase = isStaticShowcase
    }

    static func makeShowcase(
        today: KeyStatsAggregateSnapshot,
        historySynced: KeyStatsAggregateSnapshot,
        historyThisMac: KeyStatsAggregateSnapshot,
        activeAppName: String,
        activeAppBundleID: String,
        activeAppIcon: NSImage,
        brandIcon: NSImage? = nil
    ) -> MenuBarPopoverViewModel {
        let vm = MenuBarPopoverViewModel(isStaticShowcase: true)
        vm.today = today
        vm.historySynced = historySynced
        vm.historyThisMac = historyThisMac
        vm.rates = (0, 0, today.peakKPS, today.peakCPS)
        vm.isEnabled = true
        vm.hasAccessibility = true
        vm.brandIcon = brandIcon
        vm.activeAppName = activeAppName
        vm.activeAppBundleID = activeAppBundleID
        vm.activeAppIcon = activeAppIcon
        vm.activeAppDefaultExcluded = false
        vm.activeAppUserDisabled = false
        vm.activeAppVerticalAdjustment = 0.70
        return vm
    }

    func refresh(activeApp: (name: String, bundleID: String)?) {
        guard !isStaticShowcase, let engine else { return }

        today = engine.keyStatsStore.snapshot(for: .today, deviceScope: .allDevices)
        refreshHistorySnapshots()
        rates = engine.keyStatsStore.currentRatesSnapshot()

        isEnabled = engine.isEnabled
        hasAccessibility = AXIsProcessTrusted() && engine.isTapActive

        if let activeApp, !activeApp.bundleID.isEmpty {
            activeAppName = activeApp.name
            activeAppBundleID = activeApp.bundleID
            activeAppIcon = SettingsViewModel.appIcon(forBundleID: activeApp.bundleID)
            activeAppDefaultExcluded = InputGuard.defaultExcludedBundleIDs.contains(activeApp.bundleID)
            activeAppUserDisabled = inputGuard?.userDisabledBundleIDs.contains(activeApp.bundleID) ?? false
            activeAppVerticalAdjustment = engine.verticalAdjustment(forBundleID: activeApp.bundleID)
        } else {
            activeAppName = ""
            activeAppBundleID = ""
            activeAppIcon = NSImage()
            activeAppDefaultExcluded = false
            activeAppUserDisabled = false
            activeAppVerticalAdjustment = 0.70
        }

        if let autoUpdater {
            availableRelease = autoUpdater.availableRelease
            isCheckingUpdates = autoUpdater.isChecking
            isInstallingUpdate = autoUpdater.isInstalling
        }
    }

    func refreshHistorySnapshots() {
        guard !isStaticShowcase, let engine else { return }
        historySynced = engine.keyStatsStore.snapshot(for: historyRange, deviceScope: .allDevices)
        historyThisMac = engine.keyStatsStore.snapshot(for: historyRange, deviceScope: .thisMac)
    }
}

@MainActor
final class MenuBarPopoverController: NSObject, NSPopoverDelegate {
    private let popover: NSPopover
    private let hostingController: NSHostingController<MenuBarPopoverView>
    private let viewModel: MenuBarPopoverViewModel
    private let activeAppProvider: () -> (name: String, bundleID: String)?
    private var liveRefreshTimer: Timer?
    private var lastClosedUptime: TimeInterval = 0

    init(
        engine: TypingEngine,
        inputGuard: InputGuard,
        autoUpdater: AutoUpdateManager,
        activeAppProvider: @escaping () -> (name: String, bundleID: String)?,
        onToggleEnabled: @escaping () -> Void,
        onGrantAccessibility: @escaping () -> Void,
        onToggleAppDisabled: @escaping (String) -> Void,
        onAdjustAppBaseline: @escaping (String, CGFloat) -> Void,
        onOpenSettingsSection: @escaping (SettingsSection?, StatsTimeRange?) -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onInstallRelease: @escaping (AvailableRelease) -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.activeAppProvider = activeAppProvider
        let vm = MenuBarPopoverViewModel(engine: engine, inputGuard: inputGuard, autoUpdater: autoUpdater)
        self.viewModel = vm

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        self.popover = popover

        let rootView = MenuBarPopoverView(vm: vm) { [weak popover] in
            popover?.performClose(nil)
        }
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = .preferredContentSize
        self.hostingController = hosting
        popover.contentViewController = hosting

        super.init()
        popover.delegate = self

        vm.onToggleEnabled = onToggleEnabled
        vm.onGrantAccessibility = onGrantAccessibility
        vm.onToggleAppDisabled = onToggleAppDisabled
        vm.onAdjustAppBaseline = onAdjustAppBaseline
        vm.onOpenSettingsSection = onOpenSettingsSection
        vm.onCheckForUpdates = onCheckForUpdates
        vm.onInstallRelease = onInstallRelease
        vm.onQuit = onQuit
    }

    var isShown: Bool {
        popover.isShown
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // AppKit's transient monitor dismisses an open popover right before statusItem.button's
        // action fires on the same click; skip immediate reopen within 80ms of closing.
        if ProcessInfo.processInfo.systemUptime - lastClosedUptime < 0.08 {
            return
        }
        viewModel.refresh(activeApp: activeAppProvider())
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    func refreshIfShown() {
        guard popover.isShown else { return }
        viewModel.refresh(activeApp: activeAppProvider())
    }

    func popoverWillShow(_ notification: Notification) {
        viewModel.refresh(activeApp: activeAppProvider())
        startLiveRefreshTimer()
    }

    func popoverDidClose(_ notification: Notification) {
        lastClosedUptime = ProcessInfo.processInfo.systemUptime
        stopLiveRefreshTimer()
    }

    private func startLiveRefreshTimer() {
        liveRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshIfShown()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveRefreshTimer = timer
    }

    private func stopLiveRefreshTimer() {
        liveRefreshTimer?.invalidate()
        liveRefreshTimer = nil
    }
}

// MARK: - SwiftUI Popover View (Pure Liquid Glass)

struct MenuBarPopoverView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: MenuBarPopoverViewModel
    var onClosePopover: () -> Void = {}

    @State private var showRateDetail: Bool = false
    @State private var hoveredTrendIndex: Int? = nil
    @State private var hoveredAppRow: Bool = false

    private var systemBlue: Color {
        Color(nsColor: .systemBlue)
    }

    private var warmOrange: Color {
        Color(red: 0.93, green: 0.55, blue: 0.14)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            headerSection
            if showRateDetail {
                liveRateDetailStrip
            }
            activeAppBar
            todayStatsSection
            keyBreakdownSection
            historySection
            footerSection
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 356)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 8) {
            Text("WordTail")
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(Color.primary)

            PopoverPeakSpeedPill(
                peakKPS: vm.rates.peakKPS,
                peakCPS: vm.rates.peakCPS,
                isExpanded: showRateDetail,
                amberColor: warmOrange
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showRateDetail.toggle()
                }
            }

            Spacer(minLength: 4)

            if !vm.hasAccessibility {
                Button {
                    onClosePopover()
                    vm.onGrantAccessibility()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text("Grant Access")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(warmOrange, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                PopoverBlueSwitch(isOn: Binding(
                    get: { vm.isEnabled },
                    set: { _ in vm.onToggleEnabled() }
                ), activeColor: systemBlue)
                .help(vm.isEnabled ? "Inline completions enabled (Option+Escape to toggle)" : "Inline completions paused")
            }
        }
    }

    private var liveRateDetailStrip: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Text("Live:")
                    .foregroundStyle(Color.secondary)
                Text("\(vm.rates.currentKPS) KPS")
                    .fontWeight(.semibold)
                    .foregroundStyle(systemBlue)
                Text("·")
                    .foregroundStyle(Color.secondary)
                Text("\(vm.rates.currentCPS) CPS")
                    .fontWeight(.semibold)
                    .foregroundStyle(warmOrange)
            }
            Spacer(minLength: 4)
            Text("Peak \(vm.rates.peakKPS) · \(vm.rates.peakCPS)")
                .foregroundStyle(Color.secondary)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.045))
        )
    }

    // MARK: - Whisper-Quiet Active-App Strip

    private var activeAppBar: some View {
        HStack(spacing: 8) {
            if !vm.activeAppBundleID.isEmpty {
                Button {
                    onClosePopover()
                    vm.onOpenSettingsSection(.calibration, nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(nsImage: vm.activeAppIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 15, height: 15)
                            .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                        Text(vm.activeAppName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(hoveredAppRow ? systemBlue : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredAppRow = $0 }
                .help("Open Calibration & Per-App Settings")
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                    Text("No active app")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                }
            }

            Spacer(minLength: 4)

            if !vm.activeAppBundleID.isEmpty {
                if vm.activeAppDefaultExcluded {
                    Text("Excluded IDE")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.secondary)
                } else {
                    HStack(spacing: 7) {
                        PopoverMiniSwitch(isOn: Binding(
                            get: { !vm.activeAppUserDisabled },
                            set: { _ in vm.onToggleAppDisabled(vm.activeAppBundleID) }
                        ), activeColor: systemBlue)
                        .help(vm.activeAppUserDisabled ? "Enable WordTail in \(vm.activeAppName)" : "Disable WordTail in \(vm.activeAppName)")

                        HStack(spacing: 2) {
                            PopoverStepperGlyphButton(symbol: "minus", help: "Nudge baseline down (-0.05)", accent: systemBlue) {
                                vm.onAdjustAppBaseline(vm.activeAppBundleID, -0.05)
                            }
                            Text(String(format: "%+.2f", vm.activeAppVerticalAdjustment))
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(Color.secondary)
                                .frame(width: 38, alignment: .center)
                            PopoverStepperGlyphButton(symbol: "plus", help: "Nudge baseline up (+0.05)", accent: systemBlue) {
                                vm.onAdjustAppBaseline(vm.activeAppBundleID, +0.05)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4.5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(scheme == .dark ? 0.075 : 0.045))
        )
    }

    // MARK: - Today Stats (Floating Directly on Liquid Glass)

    private var todayStatsSection: some View {
        VStack(alignment: .leading, spacing: 9.5) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 20, height: 18)
                    Text("Key Presses")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.primary)
                }
                Spacer()
                Text(formattedInteger(vm.today.totalKeyPresses))
                    .font(.system(size: 14.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(systemBlue)
            }

            HStack(spacing: 14) {
                clickStatRow(highlight: .left, label: "Left Clicks", value: vm.today.leftClicks)
                clickStatRow(highlight: .right, label: "Right Clicks", value: vm.today.rightClicks)
            }

            if vm.today.sideBackClicks > 0 || vm.today.sideForwardClicks > 0 {
                HStack(spacing: 14) {
                    clickStatRow(highlight: .sideBack, label: "Side Back", value: vm.today.sideBackClicks)
                    clickStatRow(highlight: .sideForward, label: "Side Forward", value: vm.today.sideForwardClicks)
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    slateDistanceBadge(symbol: "arrow.left.and.right")
                    Text("Mouse Distance")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.primary)
                }
                Spacer()
                Text(KeyStatsAggregateSnapshot.formatDistance(vm.today.mouseDistanceMeters))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(systemBlue)
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    slateDistanceBadge(symbol: "arrow.up.and.down")
                    Text("Scroll Distance")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.primary)
                }
                Spacer()
                Text(KeyStatsAggregateSnapshot.formatScrollPx(vm.today.scrollDistancePx))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(systemBlue)
            }
        }
    }

    private func clickStatRow(highlight: GlassMouseHighlight, label: String, value: Int) -> some View {
        HStack(spacing: 7) {
            GlassMouseIcon(highlight: highlight, accent: systemBlue)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(formattedInteger(value))
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(systemBlue)
        }
        .frame(maxWidth: .infinity)
    }

    private func slateDistanceBadge(symbol: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                .fill(Color.primary.opacity(scheme == .dark ? 0.28 : 0.46))
                .frame(width: 20, height: 20)
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Key Breakdown (Floating Directly on Glass)

    private var keyBreakdownSection: some View {
        let items = Array(vm.today.topKeys.prefix(15))

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("Key Breakdown")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Spacer()
                PopoverGlassPillButton(title: "Heatmap") {
                    onClosePopover()
                    vm.onOpenSettingsSection(.keyStats, nil)
                }
            }

            if items.isEmpty {
                Text("Start typing to populate today's top 15 keys.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
                    .padding(.vertical, 6)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    keyBreakdownColumn(items: items, columnIndex: 0)
                    verticalColumnRule
                    keyBreakdownColumn(items: items, columnIndex: 1)
                    verticalColumnRule
                    keyBreakdownColumn(items: items, columnIndex: 2)
                }
            }
        }
    }

    private func keyBreakdownColumn(items: [RankedCountItem], columnIndex: Int) -> some View {
        let start = columnIndex * 5
        let end = min(items.count, start + 5)
        let slice: [RankedCountItem] = start < end ? Array(items[start..<end]) : []
        let leadingPad: CGFloat = columnIndex == 0 ? 0 : 6
        let trailingPad: CGFloat = columnIndex == 2 ? 0 : 6

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(slice.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 3) {
                    neutralKeycapLabel(compactKeyDisplay(item.label))
                    Spacer(minLength: 3)
                    Text(formattedInteger(item.count))
                        .font(.system(size: 12, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(height: 20.5)
            }
        }
        .padding(.leading, leadingPad)
        .padding(.trailing, trailingPad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verticalColumnRule: some View {
        Rectangle()
            .fill(Color.primary.opacity(scheme == .dark ? 0.14 : 0.10))
            .frame(width: 0.5, height: 118)
    }

    private func neutralKeycapLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5.5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(scheme == .dark ? 0.13 : 0.065))
            )
    }

    // MARK: - History (Native Blue Segmented Controls + Open Glass Chart)

    private var historySection: some View {
        let totalText = formattedHistoryTotal(snapshot: vm.historySynced, metric: vm.historyMetric)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("History")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Spacer()
                PopoverGlassPillButton(title: "Hourly Trends") {
                    onClosePopover()
                    vm.onOpenSettingsSection(.keyStats, .today)
                }
            }

            PopoverBlueSegmentBar(
                options: [("Last 7 Days", StatsTimeRange.days7), ("Last 30 Days", StatsTimeRange.days30)],
                selection: $vm.historyRange,
                activeBlue: systemBlue
            )

            PopoverBlueSegmentBar(
                options: [
                    ("Keys", PopoverHistoryMetric.keys),
                    ("Clicks", PopoverHistoryMetric.clicks),
                    ("Movement", PopoverHistoryMetric.movement),
                    ("Scroll", PopoverHistoryMetric.scroll)
                ],
                selection: $vm.historyMetric,
                activeBlue: systemBlue
            )

            PopoverBlueSegmentBar(
                options: [("Line", PopoverHistoryStyle.line), ("Bar", PopoverHistoryStyle.bar)],
                selection: $vm.historyStyle,
                activeBlue: systemBlue
            )

            PopoverOpenChartView(
                synced: vm.historySynced,
                thisMac: vm.historyThisMac,
                metric: vm.historyMetric,
                style: vm.historyStyle,
                blueColor: systemBlue,
                orangeColor: warmOrange,
                hoveredIndex: $hoveredTrendIndex
            )
            .padding(.top, 2)

            Text("Total: \(totalText)")
                .font(.system(size: 12.5, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(Color.secondary)
        }
    }

    // MARK: - Footer Toolbar

    private var footerSection: some View {
        VStack(spacing: 10) {
            Rectangle()
                .fill(Color.primary.opacity(scheme == .dark ? 0.11 : 0.08))
                .frame(height: 0.75)

            HStack(spacing: 8) {
                PopoverBareIconButton(symbol: "gearshape", help: "Preferences") {
                    onClosePopover()
                    vm.onOpenSettingsSection(.preferences, nil)
                }
                PopoverBareIconButton(symbol: "square.grid.2x2", help: "App Statistics") {
                    onClosePopover()
                    vm.onOpenSettingsSection(.keyStats, nil)
                }
                PopoverBareIconButton(symbol: "chart.bar.fill", help: "All-Time Stats") {
                    onClosePopover()
                    vm.onOpenSettingsSection(.keyStats, .allTime)
                }

                Spacer(minLength: 4)

                if vm.isInstallingUpdate {
                    PopoverGlassPillButton(title: "Updating...", accentColor: systemBlue, disabled: true) {}
                } else if let release = vm.availableRelease {
                    PopoverGlassPillButton(title: "Update v\(release.version)", accentColor: systemBlue) {
                        onClosePopover()
                        vm.onInstallRelease(release)
                    }
                } else if vm.isCheckingUpdates {
                    PopoverGlassPillButton(title: "Checking...", disabled: true) {}
                } else {
                    PopoverGlassPillButton(title: "Update Now") {
                        onClosePopover()
                        vm.onCheckForUpdates()
                    }
                }

                PopoverGlassPillButton(title: "Quit") {
                    vm.onQuit()
                }
            }
        }
    }

    // MARK: - Formatting Helpers

    private func formattedInteger(_ value: Int) -> String {
        Self.decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formattedHistoryTotal(snapshot: KeyStatsAggregateSnapshot, metric: PopoverHistoryMetric) -> String {
        switch metric {
        case .keys:
            return KeyStatsAggregateSnapshot.formatCompactCount(snapshot.totalKeyPresses)
        case .clicks:
            return KeyStatsAggregateSnapshot.formatCompactCount(snapshot.totalClicks)
        case .movement:
            return KeyStatsAggregateSnapshot.formatDistance(snapshot.mouseDistanceMeters)
        case .scroll:
            return KeyStatsAggregateSnapshot.formatScrollPx(snapshot.scrollDistancePx)
        }
    }

    private func compactKeyDisplay(_ raw: String) -> String {
        switch raw {
        case "Delete": return "⌫"
        case "ForwardDelete": return "⌦"
        case "Return": return "↩"
        case "Tab": return "⇥"
        case "Escape": return "⎋"
        case "CapsLock": return "⇪"
        case "UpArrow": return "↑"
        case "DownArrow": return "↓"
        case "LeftArrow": return "←"
        case "RightArrow": return "→"
        case "LeftShift": return "⇧"
        case "RightShift": return "R⇧"
        case "LeftCmd": return "⌘"
        case "RightCmd": return "R⌘"
        case "LeftOpt": return "⌥"
        case "RightOpt": return "R⌥"
        case "LeftCtrl": return "⌃"
        case "RightCtrl": return "R⌃"
        default: return raw
        }
    }

    private static let decimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()
}

// MARK: - Custom Controls & Mouse Glyphs

private struct PopoverBlueSwitch: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var isOn: Bool
    let activeColor: Color

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.78)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? activeColor : Color.primary.opacity(scheme == .dark ? 0.22 : 0.16))
                    .frame(width: 32, height: 18)

                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 0.5)
                    .frame(width: 14, height: 14)
                    .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PopoverMiniSwitch: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var isOn: Bool
    let activeColor: Color

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.78)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? activeColor : Color.primary.opacity(scheme == .dark ? 0.22 : 0.16))
                    .frame(width: 26, height: 15)

                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.16), radius: 0.8, x: 0, y: 0.5)
                    .frame(width: 11, height: 11)
                    .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PopoverPeakSpeedPill: View {
    @Environment(\.colorScheme) private var scheme
    let peakKPS: Int
    let peakCPS: Int
    let isExpanded: Bool
    let amberColor: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(amberColor)
                Text("\(peakKPS) · \(peakCPS)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(isExpanded || hovered ? (scheme == .dark ? 0.16 : 0.10) : (scheme == .dark ? 0.10 : 0.055)))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Today's peak KPS · CPS (click for live rate)")
    }
}

private struct PopoverStepperGlyphButton: View {
    @Environment(\.colorScheme) private var scheme
    let symbol: String
    let help: String
    let accent: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(hovered ? accent : Color.secondary)
                .frame(width: 16, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hovered ? Color.primary.opacity(scheme == .dark ? 0.14 : 0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

private struct PopoverGlassPillButton: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var accentColor: Color? = nil
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let fg: Color = accentColor != nil ? .white : Color.primary
        let bg: Color = {
            if let accentColor {
                return accentColor
            }
            let baseAlpha = scheme == .dark ? 0.12 : 0.068
            let hoverAlpha = scheme == .dark ? 0.19 : 0.115
            return Color.primary.opacity(hovered ? hoverAlpha : baseAlpha)
        }()

        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(fg)
                .padding(.horizontal, 11)
                .frame(height: 25)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(bg)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1.0)
        .onHover { hovered = $0 }
    }
}

private struct PopoverBareIconButton: View {
    @Environment(\.colorScheme) private var scheme
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(hovered ? Color.primary : Color.primary.opacity(0.82))
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovered ? Color.primary.opacity(scheme == .dark ? 0.14 : 0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

private enum GlassMouseHighlight {
    case left, right, sideBack, sideForward
}

private struct GlassMouseIcon: View {
    @Environment(\.colorScheme) private var scheme
    let highlight: GlassMouseHighlight
    let accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.86))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.primary.opacity(scheme == .dark ? 0.22 : 0.14), lineWidth: 0.7)
                )

            switch highlight {
            case .left:
                Path { p in
                    p.move(to: CGPoint(x: 1, y: 7.5))
                    p.addLine(to: CGPoint(x: 1, y: 3))
                    p.addQuadCurve(to: CGPoint(x: 6, y: 1), control: CGPoint(x: 1, y: 1))
                    p.addLine(to: CGPoint(x: 6, y: 7.5))
                    p.closeSubpath()
                }
                .fill(accent.opacity(0.82))
            case .right:
                Path { p in
                    p.move(to: CGPoint(x: 6, y: 7.5))
                    p.addLine(to: CGPoint(x: 6, y: 1))
                    p.addQuadCurve(to: CGPoint(x: 11, y: 3), control: CGPoint(x: 11, y: 1))
                    p.addLine(to: CGPoint(x: 11, y: 7.5))
                    p.closeSubpath()
                }
                .fill(accent.opacity(0.82))
            case .sideBack:
                RoundedRectangle(cornerRadius: 1)
                    .fill(accent)
                    .frame(width: 2.3, height: 5)
                    .offset(x: -4.2, y: 1.5)
            case .sideForward:
                RoundedRectangle(cornerRadius: 1)
                    .fill(accent)
                    .frame(width: 2.3, height: 5)
                    .offset(x: -4.2, y: -2.2)
            }
        }
        .frame(width: 12, height: 16)
    }
}

// MARK: - Segmented Pill Bar

private struct PopoverBlueSegmentBar<Option: Hashable>: View {
    @Environment(\.colorScheme) private var scheme
    let options: [(label: String, value: Option)]
    @Binding var selection: Option
    let activeBlue: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, item in
                let isSelected = (item.value == selection)
                let prevSelected = index > 0 && (options[index - 1].value == selection)
                let sepOpacity: Double = (isSelected || prevSelected) ? 0.0 : (scheme == .dark ? 0.18 : 0.13)

                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(sepOpacity))
                        .frame(width: 0.5, height: 12)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        selection = item.value
                    }
                } label: {
                    Text(item.label)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? activeBlue : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                .fill(Color.primary.opacity(scheme == .dark ? 0.11 : 0.065))
        )
    }
}

// MARK: - Open Glass Dual-Series Chart

private struct PopoverOpenChartView: View {
    @Environment(\.colorScheme) private var scheme
    let synced: KeyStatsAggregateSnapshot
    let thisMac: KeyStatsAggregateSnapshot
    let metric: PopoverHistoryMetric
    let style: PopoverHistoryStyle
    let blueColor: Color
    let orangeColor: Color
    @Binding var hoveredIndex: Int?

    // 356 outer - 32 outer pad - 38 yAxis - 6 gap = 280
    private let yAxisWidth: CGFloat = 38
    private let plotWidth: CGFloat = 280
    private let plotHeight: CGFloat = 94

    private var showThisMac: Bool {
        synced.deviceCount > 1
    }

    var body: some View {
        let syncedPoints = synced.dailyTrend
        let localByDate = Dictionary(uniqueKeysWithValues: thisMac.dailyTrend.map { ($0.dateKey, $0) })

        let syncedValues = syncedPoints.map { metricValue(for: $0) }
        let localValues = syncedPoints.map { pt in
            metricValue(for: localByDate[pt.dateKey])
        }

        let rawMax = max(
            1.0,
            max(syncedValues.max() ?? 1.0, showThisMac ? (localValues.max() ?? 0.0) : 0.0)
        )
        let yMax = niceAxisMax(rawMax)

        return VStack(alignment: .leading, spacing: 5) {
            chartTopLegendBar(
                points: syncedPoints,
                syncedValues: syncedValues,
                localValues: localValues
            )

            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing) {
                    Text(formatAxisValue(yMax))
                    Spacer()
                    Text(formatAxisValue(yMax * 0.5))
                    Spacer()
                    Text("0")
                }
                .font(.system(size: 10, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(Color.secondary)
                .frame(width: yAxisWidth, height: plotHeight, alignment: .trailing)

                Canvas { context, size in
                    drawGridAndAxes(in: &context, size: size)
                    guard !syncedPoints.isEmpty else { return }

                    switch style {
                    case .line:
                        if showThisMac {
                            drawSmoothSeries(
                                in: &context,
                                size: size,
                                values: localValues,
                                yMax: yMax,
                                color: orangeColor,
                                dashed: true,
                                hoveredIdx: hoveredIndex
                            )
                        }
                        drawSmoothSeries(
                            in: &context,
                            size: size,
                            values: syncedValues,
                            yMax: yMax,
                            color: blueColor,
                            dashed: false,
                            hoveredIdx: hoveredIndex
                        )
                    case .bar:
                        drawBarSeries(
                            in: &context,
                            size: size,
                            syncedValues: syncedValues,
                            localValues: localValues,
                            yMax: yMax,
                            showLocal: showThisMac,
                            hoveredIdx: hoveredIndex
                        )
                    }
                }
                .frame(width: plotWidth, height: plotHeight)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard !syncedPoints.isEmpty else {
                            hoveredIndex = nil
                            return
                        }
                        let count = syncedPoints.count
                        if count == 1 {
                            hoveredIndex = 0
                        } else {
                            let usableW = max(1.0, plotWidth - 12.0)
                            let norm = max(0.0, min(1.0, (location.x - 6.0) / usableW))
                            let idx = Int((norm * Double(count - 1)).rounded())
                            hoveredIndex = max(0, min(count - 1, idx))
                        }
                    case .ended:
                        hoveredIndex = nil
                    }
                }
            }

            let ticks = xTickIndices(count: syncedPoints.count)
            HStack {
                ForEach(Array(ticks.enumerated()), id: \.offset) { pos, idx in
                    if pos > 0 {
                        Spacer(minLength: 0)
                    }
                    Text(shortDateLabel(syncedPoints[idx].dateKey))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.leading, yAxisWidth + 6)
            .padding(.trailing, 2)
        }
    }

    private func chartTopLegendBar(
        points: [DailyActivityPoint],
        syncedValues: [Double],
        localValues: [Double]
    ) -> some View {
        HStack(spacing: 8) {
            if let idx = hoveredIndex, idx >= 0, idx < points.count {
                let dLabel = shortDateLabel(points[idx].dateKey)
                HStack(spacing: 4) {
                    Text(dLabel)
                        .foregroundStyle(Color.secondary)
                    Text(formatMetricTooltip(syncedValues[idx]))
                        .foregroundStyle(blueColor)
                    if showThisMac {
                        Text("· Mac \(formatMetricTooltip(localValues[idx]))")
                            .foregroundStyle(orangeColor)
                    }
                }
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Capsule()
                        .fill(blueColor)
                        .frame(width: 10, height: 2)
                    Text("Synced total")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondary)
                }

                if showThisMac {
                    HStack(spacing: 4) {
                        HStack(spacing: 1.5) {
                            Rectangle().fill(orangeColor).frame(width: 2.5, height: 2)
                            Rectangle().fill(orangeColor).frame(width: 2.5, height: 2)
                            Rectangle().fill(orangeColor).frame(width: 2.5, height: 2)
                        }
                        Text("This Mac")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Drawing

    private func drawGridAndAxes(in context: inout GraphicsContext, size: CGSize) {
        let topY: CGFloat = 6
        let bottomY: CGFloat = size.height - 4
        let span = bottomY - topY
        let gridColor = Color.primary.opacity(scheme == .dark ? 0.11 : 0.09)
        let axisColor = Color.primary.opacity(scheme == .dark ? 0.30 : 0.26)

        for frac in [CGFloat(0.0), 0.25, 0.50, 0.75] {
            let y = topY + span * frac
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(gridColor), lineWidth: 0.6)
        }

        var axes = Path()
        axes.move(to: CGPoint(x: 0.5, y: 0))
        axes.addLine(to: CGPoint(x: 0.5, y: bottomY))
        axes.addLine(to: CGPoint(x: size.width, y: bottomY))
        context.stroke(axes, with: .color(axisColor), lineWidth: 0.9)
    }

    private func drawSmoothSeries(
        in context: inout GraphicsContext,
        size: CGSize,
        values: [Double],
        yMax: Double,
        color: Color,
        dashed: Bool,
        hoveredIdx: Int?
    ) {
        let pts = plotPoints(values: values, size: size, yMax: yMax)
        guard !pts.isEmpty else { return }

        if let hi = hoveredIdx, hi >= 0, hi < pts.count, !dashed {
            var crosshair = Path()
            crosshair.move(to: CGPoint(x: pts[hi].x, y: 4))
            crosshair.addLine(to: CGPoint(x: pts[hi].x, y: size.height - 4))
            context.stroke(crosshair, with: .color(color.opacity(0.32)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        if pts.count > 1 {
            let curve = monotonicCubicPath(points: pts, minY: 6, maxY: size.height - 4)
            let strokeStyle = StrokeStyle(
                lineWidth: dashed ? 1.7 : 1.9,
                lineCap: .round,
                lineJoin: .round,
                dash: dashed ? [4, 2.5] : []
            )
            context.stroke(curve, with: .color(color), style: strokeStyle)
        }

        let showAllDots = pts.count <= 14
        for (idx, p) in pts.enumerated() {
            let isHovered = (hoveredIdx == idx)
            guard showAllDots || isHovered else { continue }
            let r: CGFloat = isHovered ? 3.5 : 2.2
            let dotRect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: dotRect), with: .color(color))
        }
    }

    private func drawBarSeries(
        in context: inout GraphicsContext,
        size: CGSize,
        syncedValues: [Double],
        localValues: [Double],
        yMax: Double,
        showLocal: Bool,
        hoveredIdx: Int?
    ) {
        let count = syncedValues.count
        guard count > 0 else { return }

        let topY: CGFloat = 6
        let bottomY: CGFloat = size.height - 4
        let usableH = bottomY - topY
        let leftPad: CGFloat = 5
        let rightPad: CGFloat = 5
        let slotW = (size.width - leftPad - rightPad) / CGFloat(count)

        for idx in 0..<count {
            let centerX = leftPad + slotW * (CGFloat(idx) + 0.5)
            let sFrac = max(0, min(1, syncedValues[idx] / yMax))
            let sH = max(sFrac > 0 ? 1.5 : 0, usableH * CGFloat(sFrac))

            if showLocal {
                let barW = max(2.0, min(9.5, slotW * 0.34))
                let gap: CGFloat = max(1.0, slotW * 0.06)

                let lFrac = max(0, min(1, localValues[idx] / yMax))
                let lH = max(lFrac > 0 ? 1.5 : 0, usableH * CGFloat(lFrac))

                let syncedRect = CGRect(
                    x: centerX - gap * 0.5 - barW,
                    y: bottomY - sH,
                    width: barW,
                    height: sH
                )
                let localRect = CGRect(
                    x: centerX + gap * 0.5,
                    y: bottomY - lH,
                    width: barW,
                    height: lH
                )
                let highlightBoost = (hoveredIdx == idx) ? 1.0 : 0.88
                context.fill(Path(roundedRect: syncedRect, cornerRadius: 2), with: .color(blueColor.opacity(highlightBoost)))
                context.fill(Path(roundedRect: localRect, cornerRadius: 2), with: .color(orangeColor.opacity(highlightBoost)))
            } else {
                let barW = max(2.5, min(16.0, slotW * 0.56))
                let rect = CGRect(x: centerX - barW * 0.5, y: bottomY - sH, width: barW, height: sH)
                let alpha = (hoveredIdx == idx) ? 1.0 : 0.88
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(blueColor.opacity(alpha)))
            }
        }
    }

    private func plotPoints(values: [Double], size: CGSize, yMax: Double) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let leftPad: CGFloat = 6
        let rightPad: CGFloat = 6
        let topY: CGFloat = 6
        let bottomY: CGFloat = size.height - 4
        let usableW = max(1.0, size.width - leftPad - rightPad)
        let usableH = bottomY - topY

        return values.enumerated().map { idx, v in
            let x: CGFloat
            if values.count == 1 {
                x = leftPad + usableW * 0.5
            } else {
                x = leftPad + usableW * CGFloat(idx) / CGFloat(values.count - 1)
            }
            let frac = max(0.0, min(1.0, v / yMax))
            let y = bottomY - usableH * CGFloat(frac)
            return CGPoint(x: x, y: y)
        }
    }

    /// Fritsch-Carlson monotonic cubic Hermite spline so smoothed series never overshoot or dip below zero.
    private func monotonicCubicPath(points pts: [CGPoint], minY: CGFloat, maxY: CGFloat) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)

        let n = pts.count
        guard n > 1 else { return path }
        if n == 2 {
            path.addLine(to: pts[1])
            return path
        }

        var d = [Double](repeating: 0, count: n - 1)
        for k in 0..<(n - 1) {
            let dx = Double(pts[k + 1].x - pts[k].x)
            d[k] = dx > 1e-9 ? Double(pts[k + 1].y - pts[k].y) / dx : 0
        }

        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for k in 1..<(n - 1) {
            if d[k - 1] * d[k] <= 0 {
                m[k] = 0
            } else {
                m[k] = (d[k - 1] + d[k]) * 0.5
            }
        }

        for k in 0..<(n - 1) {
            if abs(d[k]) < 1e-9 {
                m[k] = 0
                m[k + 1] = 0
            } else {
                let alpha = m[k] / d[k]
                let beta = m[k + 1] / d[k]
                let sq = alpha * alpha + beta * beta
                if sq > 9.0 {
                    let tau = 3.0 / sqrt(sq)
                    m[k] = tau * alpha * d[k]
                    m[k + 1] = tau * beta * d[k]
                }
            }
        }

        for k in 0..<(n - 1) {
            let p0 = pts[k]
            let p1 = pts[k + 1]
            let dx = Double(p1.x - p0.x)
            let y1 = max(minY, min(maxY, p0.y + CGFloat(m[k] * dx / 3.0)))
            let y2 = max(minY, min(maxY, p1.y - CGFloat(m[k + 1] * dx / 3.0)))
            path.addCurve(
                to: p1,
                control1: CGPoint(x: p0.x + CGFloat(dx / 3.0), y: y1),
                control2: CGPoint(x: p1.x - CGFloat(dx / 3.0), y: y2)
            )
        }
        return path
    }

    // MARK: - Axis & Metric Helpers

    private func metricValue(for point: DailyActivityPoint?) -> Double {
        guard let point else { return 0 }
        switch metric {
        case .keys: return Double(point.keyPresses)
        case .clicks: return Double(point.clicks)
        case .movement: return point.mouseDistanceMeters
        case .scroll: return point.scrollDistancePx
        }
    }

    private func niceAxisMax(_ raw: Double) -> Double {
        if raw <= 10 { return max(1, ceil(raw)) }
        if raw >= 1_000 {
            return ceil((raw * 1.05) / 100.0) * 100.0
        }
        return ceil(raw * 1.05)
    }

    private func formatAxisValue(_ value: Double) -> String {
        switch metric {
        case .keys, .clicks:
            if value >= 1_000_000 {
                return String(format: "%.2fM", value / 1_000_000.0)
            } else if value >= 1_000 {
                return String(format: "%.1fk", value / 1_000.0)
            }
            return "\(Int(value.rounded()))"
        case .movement:
            return KeyStatsAggregateSnapshot.formatDistance(value)
        case .scroll:
            return KeyStatsAggregateSnapshot.formatScrollPx(value)
        }
    }

    private func formatMetricTooltip(_ value: Double) -> String {
        switch metric {
        case .keys, .clicks:
            return KeyStatsAggregateSnapshot.formatCompactCount(Int(value.rounded()))
        case .movement:
            return KeyStatsAggregateSnapshot.formatDistance(value)
        case .scroll:
            return KeyStatsAggregateSnapshot.formatScrollPx(value)
        }
    }

    private func xTickIndices(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        if count <= 4 { return Array(0..<count) }
        if count == 7 { return [0, 2, 4, 6] }
        return [0, count / 3, (2 * count) / 3, count - 1]
    }

    private func shortDateLabel(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else {
            return key
        }
        return "\(m)/\(d)"
    }
}
