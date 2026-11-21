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
        activeAppIcon: NSImage
    ) -> MenuBarPopoverViewModel {
        let vm = MenuBarPopoverViewModel(isStaticShowcase: true)
        vm.today = today
        vm.historySynced = historySynced
        vm.historyThisMac = historyThisMac
        vm.rates = (0, 0, today.peakKPS, today.peakCPS)
        vm.isEnabled = true
        vm.hasAccessibility = true
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

// MARK: - SwiftUI Popover View

struct MenuBarPopoverView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: MenuBarPopoverViewModel
    var onClosePopover: () -> Void = {}

    @State private var showRateDetail: Bool = false
    @State private var hoveredTrendIndex: Int? = nil

    private var blueAccent: Color {
        Color(red: 0.14, green: 0.49, blue: 0.92)
    }

    private var orangeAccent: Color {
        Color(red: 0.93, green: 0.56, blue: 0.16)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8.5) {
            headerSection
            if showRateDetail {
                liveRateDetailStrip
            }
            activeAppBar

            thinDivider
            todayStatsSection
            thinDivider
            keyBreakdownSection
            thinDivider
            historySection
            thinDivider
            footerToolbar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 360)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 8) {
            Text("WordTail")
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(Color.primary)

            liveSpeedPill

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
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(orangeAccent, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                LinearSwitch(isOn: Binding(
                    get: { vm.isEnabled },
                    set: { _ in vm.onToggleEnabled() }
                ))
                .help(vm.isEnabled ? "Inline completions enabled (Option+Escape to toggle)" : "Inline completions paused")
            }
        }
    }

    private var liveSpeedPill: some View {
        let liveActive = vm.rates.currentKPS > 0 || vm.rates.currentCPS > 0
        let text: String = liveActive
            ? "\(vm.rates.currentKPS)/\(vm.rates.peakKPS) · \(vm.rates.currentCPS)/\(vm.rates.peakCPS)"
            : "\(vm.rates.peakKPS) · \(vm.rates.peakCPS)"

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                showRateDetail.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(liveActive ? blueAccent : Color(red: 0.92, green: 0.65, blue: 0.12))
                Text(text)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(liveActive ? blueAccent : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.06))
            )
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(scheme == .dark ? 0.14 : 0.08), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .help("Live KPS / CPS (click for details)")
    }

    private var liveRateDetailStrip: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("Keys:")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.secondary)
                Text("\(vm.rates.currentKPS) KPS")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(blueAccent)
                Text("(Peak \(vm.rates.peakKPS))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Text("Clicks:")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.secondary)
                Text("\(vm.rates.currentCPS) CPS")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(orangeAccent)
                Text("(Peak \(vm.rates.peakCPS))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.045))
        )
    }

    // MARK: - Active-App Bar

    private var activeAppBar: some View {
        HStack(spacing: 7) {
            if !vm.activeAppBundleID.isEmpty {
                Button {
                    onClosePopover()
                    vm.onOpenSettingsSection(.calibration, nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(nsImage: vm.activeAppIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                        Text(vm.activeAppName)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .buttonStyle(.plain)
                .help("Open Calibration & Per-App Settings")
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                    Text("No active app")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.secondary)
                }
            }

            Spacer(minLength: 4)

            if !vm.activeAppBundleID.isEmpty {
                if vm.activeAppDefaultExcluded {
                    Text("Excluded IDE")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.06))
                        )
                } else {
                    HStack(spacing: 6) {
                        PopoverMiniSwitch(isOn: Binding(
                            get: { !vm.activeAppUserDisabled },
                            set: { _ in vm.onToggleAppDisabled(vm.activeAppBundleID) }
                        ))
                        .help(vm.activeAppUserDisabled ? "Enable WordTail in \(vm.activeAppName)" : "Disable WordTail in \(vm.activeAppName)")

                        HStack(spacing: 2) {
                            tinyStepButton(symbol: "minus", help: "Nudge baseline down (-0.05)") {
                                vm.onAdjustAppBaseline(vm.activeAppBundleID, -0.05)
                            }
                            Text(String(format: "%+.2f", vm.activeAppVerticalAdjustment))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(Color.secondary)
                                .frame(width: 34, alignment: .center)
                            tinyStepButton(symbol: "plus", help: "Nudge baseline up (+0.05)") {
                                vm.onAdjustAppBaseline(vm.activeAppBundleID, +0.05)
                            }
                        }
                        .padding(.horizontal, 3)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05))
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(scheme == .dark ? 0.07 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(scheme == .dark ? 0.10 : 0.06), lineWidth: 0.8)
        )
    }

    private func tinyStepButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.primary)
                .frame(width: 15, height: 15)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Today Stats

    private var todayStatsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 20, height: 18)
                    Text("Key Presses")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary)
                }
                Spacer()
                Text(formattedInteger(vm.today.totalKeyPresses))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(blueAccent)
            }

            HStack(spacing: 14) {
                clickStatPair(
                    highlight: .left,
                    label: "Left Clicks",
                    value: vm.today.leftClicks
                )
                clickStatPair(
                    highlight: .right,
                    label: "Right Clicks",
                    value: vm.today.rightClicks
                )
            }

            if vm.today.sideBackClicks > 0 || vm.today.sideForwardClicks > 0 {
                HStack(spacing: 14) {
                    clickStatPair(
                        highlight: .sideBack,
                        label: "Side Back Clicks",
                        value: vm.today.sideBackClicks
                    )
                    clickStatPair(
                        highlight: .sideForward,
                        label: "Side Forward Clicks",
                        value: vm.today.sideForwardClicks
                    )
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    distanceBadge(symbol: "arrow.left.and.right")
                    Text("Mouse Distance")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary)
                }
                Spacer()
                Text(KeyStatsAggregateSnapshot.formatDistance(vm.today.mouseDistanceMeters))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(blueAccent)
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    distanceBadge(symbol: "arrow.up.and.down")
                    Text("Scroll Distance")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary)
                }
                Spacer()
                Text(KeyStatsAggregateSnapshot.formatScrollPx(vm.today.scrollDistancePx))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(blueAccent)
            }
        }
    }

    private func clickStatPair(highlight: MiniMouseHighlight, label: String, value: Int) -> some View {
        HStack(spacing: 6) {
            MiniMouseGlyph(highlight: highlight, accent: blueAccent)
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Spacer(minLength: 4)
            Text(formattedInteger(value))
                .font(.system(size: 13.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(blueAccent)
        }
        .frame(maxWidth: .infinity)
    }

    private func distanceBadge(symbol: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(scheme == .dark ? 0.24 : 0.45))
                .frame(width: 20, height: 18)
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Key Breakdown

    private var keyBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Key Breakdown")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Spacer()
                popoverActionPill(title: "Heatmap") {
                    onClosePopover()
                    vm.onOpenSettingsSection(.keyStats, nil)
                }
            }

            let items = Array(vm.today.topKeys.prefix(15))
            if items.isEmpty {
                Text("Start typing to populate today's top 15 keys.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.secondary)
                    .padding(.vertical, 8)
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
        let leadingPad: CGFloat = columnIndex == 0 ? 0 : 8
        let trailingPad: CGFloat = columnIndex == 2 ? 0 : 8

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(slice.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    keycapLabel(compactKeyDisplay(item.label))
                    Spacer(minLength: 2)
                    Text(formattedInteger(item.count))
                        .font(.system(size: 11.5, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
                .frame(height: 18)
            }
        }
        .padding(.leading, leadingPad)
        .padding(.trailing, trailingPad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verticalColumnRule: some View {
        Rectangle()
            .fill(Color.primary.opacity(scheme == .dark ? 0.12 : 0.08))
            .frame(width: 1, height: 104)
    }

    private func keycapLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(Color.primary.opacity(scheme == .dark ? 0.13 : 0.075))
            )
    }

    // MARK: - History Section

    private var historySection: some View {
        let totalText = formattedHistoryTotal(snapshot: vm.historySynced, metric: vm.historyMetric)

        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("History")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Spacer()
                popoverActionPill(title: "Hourly Trends") {
                    onClosePopover()
                    vm.onOpenSettingsSection(.keyStats, .today)
                }
            }

            PopoverSegmentedBar(
                options: [("Last 7 Days", StatsTimeRange.days7), ("Last 30 Days", StatsTimeRange.days30)],
                selection: $vm.historyRange
            )

            PopoverSegmentedBar(
                options: [
                    ("Keys", PopoverHistoryMetric.keys),
                    ("Clicks", PopoverHistoryMetric.clicks),
                    ("Movement", PopoverHistoryMetric.movement),
                    ("Scroll", PopoverHistoryMetric.scroll)
                ],
                selection: $vm.historyMetric
            )

            PopoverSegmentedBar(
                options: [("Line", PopoverHistoryStyle.line), ("Bar", PopoverHistoryStyle.bar)],
                selection: $vm.historyStyle
            )

            PopoverHistoryChartCard(
                synced: vm.historySynced,
                thisMac: vm.historyThisMac,
                metric: vm.historyMetric,
                style: vm.historyStyle,
                blueColor: blueAccent,
                orangeColor: orangeAccent,
                hoveredIndex: $hoveredTrendIndex
            )

            Text("Total: \(totalText)")
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.secondary)
        }
    }

    // MARK: - Footer Toolbar

    private var footerToolbar: some View {
        HStack(spacing: 8) {
            footerIconButton(symbol: "gearshape", help: "Preferences") {
                onClosePopover()
                vm.onOpenSettingsSection(.preferences, nil)
            }
            footerIconButton(symbol: "square.grid.2x2", help: "App Statistics") {
                onClosePopover()
                vm.onOpenSettingsSection(.keyStats, nil)
            }
            footerIconButton(symbol: "chart.bar.fill", help: "All-Time Stats") {
                onClosePopover()
                vm.onOpenSettingsSection(.keyStats, .allTime)
            }

            Spacer(minLength: 4)

            if vm.isInstallingUpdate {
                popoverActionPill(title: "Updating...", accentFill: true, disabled: true) {}
            } else if let release = vm.availableRelease {
                popoverActionPill(title: "Update v\(release.version)", accentFill: true) {
                    onClosePopover()
                    vm.onInstallRelease(release)
                }
            } else if vm.isCheckingUpdates {
                popoverActionPill(title: "Checking...", disabled: true) {}
            } else {
                popoverActionPill(title: "Update Now") {
                    onClosePopover()
                    vm.onCheckForUpdates()
                }
            }

            popoverActionPill(title: "Quit") {
                vm.onQuit()
            }
        }
    }

    private func footerIconButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func popoverActionPill(
        title: String,
        accentFill: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(accentFill ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(accentFill ? blueAccent : Color.primary.opacity(scheme == .dark ? 0.12 : 0.065))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .stroke(
                            accentFill ? blueAccent.opacity(0.6) : Color.primary.opacity(scheme == .dark ? 0.14 : 0.08),
                            lineWidth: 0.8
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1.0)
    }

    private var thinDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(scheme == .dark ? 0.12 : 0.08))
            .frame(height: 1)
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

// MARK: - Custom Mouse Icon

private enum MiniMouseHighlight {
    case left, right, sideBack, sideForward
}

private struct MiniMouseGlyph: View {
    @Environment(\.colorScheme) private var scheme
    let highlight: MiniMouseHighlight
    let accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(Color.primary.opacity(scheme == .dark ? 0.16 : 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .stroke(Color.primary.opacity(scheme == .dark ? 0.28 : 0.22), lineWidth: 0.8)
                )

            switch highlight {
            case .left:
                Path { p in
                    p.move(to: CGPoint(x: 1, y: 7))
                    p.addLine(to: CGPoint(x: 1, y: 3))
                    p.addQuadCurve(to: CGPoint(x: 6, y: 1), control: CGPoint(x: 1, y: 1))
                    p.addLine(to: CGPoint(x: 6, y: 7))
                    p.closeSubpath()
                }
                .fill(accent)
            case .right:
                Path { p in
                    p.move(to: CGPoint(x: 6, y: 7))
                    p.addLine(to: CGPoint(x: 6, y: 1))
                    p.addQuadCurve(to: CGPoint(x: 11, y: 3), control: CGPoint(x: 11, y: 1))
                    p.addLine(to: CGPoint(x: 11, y: 7))
                    p.closeSubpath()
                }
                .fill(accent)
            case .sideBack:
                RoundedRectangle(cornerRadius: 1)
                    .fill(accent)
                    .frame(width: 2.4, height: 5)
                    .offset(x: -4.2, y: 1.5)
            case .sideForward:
                RoundedRectangle(cornerRadius: 1)
                    .fill(accent)
                    .frame(width: 2.4, height: 5)
                    .offset(x: -4.2, y: -2.2)
            }
        }
        .frame(width: 12, height: 15)
    }
}

// MARK: - Segmented Pill Bar

private struct PopoverSegmentedBar<Option: Hashable>: View {
    @Environment(\.colorScheme) private var scheme
    let options: [(label: String, value: Option)]
    @Binding var selection: Option

    private let activeBlue = Color(red: 0.14, green: 0.49, blue: 0.92)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, item in
                let isSelected = item.value == selection
                let prevSelected = index > 0 && options[index - 1].value == selection
                let sepOpacity: Double = (isSelected || prevSelected) ? 0.0 : (scheme == .dark ? 0.18 : 0.12)

                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(sepOpacity))
                        .frame(width: 1, height: 12)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        selection = item.value
                    }
                } label: {
                    Text(item.label)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
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

private struct PopoverMiniSwitch: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.78)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? LinearUI.accent : Color.primary.opacity(scheme == .dark ? 0.22 : 0.16))
                    .frame(width: 28, height: 16)

                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.16), radius: 1, x: 0, y: 0.5)
                    .frame(width: 12, height: 12)
                    .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dual-Series Monotonic History Chart

private struct PopoverHistoryChartCard: View {
    @Environment(\.colorScheme) private var scheme
    let synced: KeyStatsAggregateSnapshot
    let thisMac: KeyStatsAggregateSnapshot
    let metric: PopoverHistoryMetric
    let style: PopoverHistoryStyle
    let blueColor: Color
    let orangeColor: Color
    @Binding var hoveredIndex: Int?

    private let yAxisWidth: CGFloat = 38
    private let plotWidth: CGFloat = 270
    private let plotHeight: CGFloat = 86

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
            chartTopBar(
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
                .font(.system(size: 9.5, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(Color.secondary)
                .frame(width: yAxisWidth, height: plotHeight, alignment: .trailing)

                ZStack {
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
                                    fillGradient: false,
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
                                fillGradient: true,
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
                .frame(width: plotWidth, height: plotHeight)
            }

            let ticks = xTickIndices(count: syncedPoints.count)
            HStack {
                ForEach(Array(ticks.enumerated()), id: \.offset) { pos, idx in
                    if pos > 0 {
                        Spacer(minLength: 0)
                    }
                    Text(shortDateLabel(syncedPoints[idx].dateKey))
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.leading, yAxisWidth + 6)
            .padding(.trailing, 2)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(scheme == .dark ? 0.11 : 0.065), lineWidth: 0.8)
        )
    }

    private func chartTopBar(
        points: [DailyActivityPoint],
        syncedValues: [Double],
        localValues: [Double]
    ) -> some View {
        HStack(spacing: 8) {
            if let idx = hoveredIndex, idx >= 0, idx < points.count {
                let dLabel = shortDateLabel(points[idx].dateKey)
                let syncedStr = formatMetricTooltip(syncedValues[idx])
                HStack(spacing: 5) {
                    Text(dLabel)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                    Text(syncedStr)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(blueColor)
                    if showThisMac {
                        Text("· Mac \(formatMetricTooltip(localValues[idx]))")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(orangeColor)
                    }
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(blueColor)
                        .frame(width: 11, height: 2)
                    Text("Synced total")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary)
                }

                if showThisMac {
                    HStack(spacing: 4) {
                        HStack(spacing: 1.5) {
                            Rectangle().fill(orangeColor).frame(width: 3, height: 2)
                            Rectangle().fill(orangeColor).frame(width: 3, height: 2)
                            Rectangle().fill(orangeColor).frame(width: 3, height: 2)
                        }
                        Text("This Mac")
                            .font(.system(size: 10))
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
        let midY: CGFloat = (topY + bottomY) * 0.5
        let gridColor = Color.primary.opacity(scheme == .dark ? 0.12 : 0.08)
        let axisColor = Color.primary.opacity(scheme == .dark ? 0.28 : 0.24)

        for y in [topY, midY] {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(gridColor), lineWidth: 0.75)
        }

        // Left Y axis & Bottom X axis
        var axes = Path()
        axes.move(to: CGPoint(x: 0.5, y: 0))
        axes.addLine(to: CGPoint(x: 0.5, y: bottomY))
        axes.addLine(to: CGPoint(x: size.width, y: bottomY))
        context.stroke(axes, with: .color(axisColor), lineWidth: 1.0)
    }

    private func drawSmoothSeries(
        in context: inout GraphicsContext,
        size: CGSize,
        values: [Double],
        yMax: Double,
        color: Color,
        dashed: Bool,
        fillGradient: Bool,
        hoveredIdx: Int?
    ) {
        let pts = plotPoints(values: values, size: size, yMax: yMax)
        guard !pts.isEmpty else { return }

        if let hi = hoveredIdx, hi >= 0, hi < pts.count, !dashed {
            var crosshair = Path()
            crosshair.move(to: CGPoint(x: pts[hi].x, y: 4))
            crosshair.addLine(to: CGPoint(x: pts[hi].x, y: size.height - 4))
            context.stroke(crosshair, with: .color(color.opacity(0.32)), lineWidth: 1)
        }

        if pts.count > 1 {
            let curve = monotonicCubicPath(points: pts, minY: 6, maxY: size.height - 4)

            if fillGradient {
                var area = curve
                area.addLine(to: CGPoint(x: pts.last!.x, y: size.height - 4))
                area.addLine(to: CGPoint(x: pts.first!.x, y: size.height - 4))
                area.closeSubpath()
                context.fill(
                    area,
                    with: .linearGradient(
                        Gradient(colors: [color.opacity(0.14), color.opacity(0.01)]),
                        startPoint: CGPoint(x: 0, y: 6),
                        endPoint: CGPoint(x: 0, y: size.height - 4)
                    )
                )
            }

            let strokeStyle = StrokeStyle(
                lineWidth: dashed ? 1.65 : 1.9,
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
            let r: CGFloat = isHovered ? 3.4 : (dashed ? 1.9 : 2.1)
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
                let barW = max(2.0, min(9.0, slotW * 0.34))
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
                context.fill(Path(roundedRect: syncedRect, cornerRadius: 1.5), with: .color(blueColor.opacity(highlightBoost)))
                context.fill(Path(roundedRect: localRect, cornerRadius: 1.5), with: .color(orangeColor.opacity(highlightBoost)))
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
