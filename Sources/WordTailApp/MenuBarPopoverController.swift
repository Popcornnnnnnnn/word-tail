import AppKit
import SwiftUI
import WordTailCore

enum PopoverHistoryMetric: String, CaseIterable, Identifiable {
    case keys = "Keys"
    case clicks = "Clicks"
    case movement = "Mouse"
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

// MARK: - Popover Visual Tokens

private enum PopoverPalette {
    static let emerald = Color(red: 0.16, green: 0.66, blue: 0.38)
    static let amber = Color(red: 0.91, green: 0.56, blue: 0.16)

    static func cardFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.065) : Color.white.opacity(0.62)
    }

    static func elevatedPillFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.94)
    }

    static func trackFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.055)
    }

    static func cardBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.075)
    }

    static func divider(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.07)
    }
}

// MARK: - SwiftUI Popover View

struct MenuBarPopoverView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: MenuBarPopoverViewModel
    var onClosePopover: () -> Void = {}

    @State private var showRateDetail: Bool = false
    @State private var hoveredTrendIndex: Int? = nil
    @State private var hoveredAppRow: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8.5) {
            headerSection
            if showRateDetail {
                liveRateDetailStrip
            }
            activeAppBar
            todayStatsSection
            keyBreakdownSection
            historySection
            footerToolbar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 368)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(nsImage: vm.brandIcon ?? NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(PopoverPalette.cardBorder(scheme), lineWidth: 0.7)
                    )

                Text("WordTail")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.primary)

                Circle()
                    .fill(!vm.hasAccessibility ? Color.orange : (vm.isEnabled ? PopoverPalette.emerald : Color.secondary))
                    .frame(width: 5.5, height: 5.5)
                    .help(!vm.hasAccessibility ? "Accessibility required" : (vm.isEnabled ? "Inline completion active" : "Paused"))
            }

            liveSpeedPill

            Spacer(minLength: 4)

            if !vm.hasAccessibility {
                Button {
                    onClosePopover()
                    vm.onGrantAccessibility()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("Grant Access")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(PopoverPalette.amber, in: Capsule())
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

        return PopoverSpeedPillButton(
            text: text,
            liveActive: liveActive,
            isExpanded: showRateDetail
        ) {
            withAnimation(.easeInOut(duration: 0.16)) {
                showRateDetail.toggle()
            }
        }
    }

    private var liveRateDetailStrip: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Text("Keys:")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.secondary)
                Text("\(vm.rates.currentKPS) KPS")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LinearUI.accent)
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
                    .foregroundStyle(PopoverPalette.amber)
                Text("(Peak \(vm.rates.peakCPS))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(PopoverPalette.cardFill(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(PopoverPalette.cardBorder(scheme), lineWidth: 0.8)
        )
    }

    // MARK: - Active-App Bar

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
                            .frame(width: 16, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                        Text(vm.activeAppName)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(hoveredAppRow ? LinearUI.accent : Color.primary)
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
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.secondary)
                }
            }

            Spacer(minLength: 4)

            if !vm.activeAppBundleID.isEmpty {
                if vm.activeAppDefaultExcluded {
                    Text("IDE Excluded")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(PopoverPalette.trackFill(scheme))
                        )
                } else {
                    HStack(spacing: 7) {
                        PopoverMiniSwitch(isOn: Binding(
                            get: { !vm.activeAppUserDisabled },
                            set: { _ in vm.onToggleAppDisabled(vm.activeAppBundleID) }
                        ))
                        .help(vm.activeAppUserDisabled ? "Enable WordTail in \(vm.activeAppName)" : "Disable WordTail in \(vm.activeAppName)")

                        HStack(spacing: 0) {
                            PopoverStepperIconButton(symbol: "minus", help: "Nudge baseline down (-0.05)") {
                                vm.onAdjustAppBaseline(vm.activeAppBundleID, -0.05)
                            }
                            Rectangle()
                                .fill(PopoverPalette.divider(scheme))
                                .frame(width: 1, height: 11)
                            Text(String(format: "%+.2f", vm.activeAppVerticalAdjustment))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(Color.secondary)
                                .frame(width: 36, alignment: .center)
                            Rectangle()
                                .fill(PopoverPalette.divider(scheme))
                                .frame(width: 1, height: 11)
                            PopoverStepperIconButton(symbol: "plus", help: "Nudge baseline up (+0.05)") {
                                vm.onAdjustAppBaseline(vm.activeAppBundleID, +0.05)
                            }
                        }
                        .frame(height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .fill(PopoverPalette.trackFill(scheme))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .stroke(PopoverPalette.cardBorder(scheme), lineWidth: 0.75)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5.5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(PopoverPalette.cardFill(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(PopoverPalette.cardBorder(scheme), lineWidth: 0.8)
        )
    }

    // MARK: - Today Stats (2-Tier Bento Grid)

    private var todayStatsSection: some View {
        let sideSum = vm.today.sideBackClicks + vm.today.sideForwardClicks
        let clicksSubtitle: String = sideSum > 0
            ? "L \(formattedInteger(vm.today.leftClicks)) · R \(formattedInteger(vm.today.rightClicks)) · Side \(formattedInteger(sideSum))"
            : "L \(formattedInteger(vm.today.leftClicks)) · R \(formattedInteger(vm.today.rightClicks))"
        let clicksTooltip = "Left: \(formattedInteger(vm.today.leftClicks)) · Right: \(formattedInteger(vm.today.rightClicks)) · Side Back: \(formattedInteger(vm.today.sideBackClicks)) · Side Forward: \(formattedInteger(vm.today.sideForwardClicks))"
        let keysSubtitle = vm.rates.currentKPS > 0
            ? "Live \(vm.rates.currentKPS) KPS · Peak \(vm.rates.peakKPS)"
            : "Peak \(vm.rates.peakKPS) KPS · \(vm.rates.peakCPS) CPS"

        return VStack(spacing: 7) {
            HStack(spacing: 7) {
                bentoHeroCard(
                    icon: "keyboard",
                    accent: LinearUI.accent,
                    label: "KEYSTROKES",
                    value: formattedInteger(vm.today.totalKeyPresses),
                    subtitle: keysSubtitle
                )
                bentoHeroCard(
                    icon: "computermouse",
                    accent: PopoverPalette.emerald,
                    label: "CLICKS",
                    value: formattedInteger(vm.today.totalClicks),
                    subtitle: clicksSubtitle
                )
                .help(clicksTooltip)
            }

            HStack(spacing: 7) {
                compactDistancePill(
                    icon: "arrow.left.and.right",
                    accent: LinearUI.accent,
                    label: "Mouse",
                    value: KeyStatsAggregateSnapshot.formatDistance(vm.today.mouseDistanceMeters)
                )
                compactDistancePill(
                    icon: "arrow.up.and.down",
                    accent: PopoverPalette.amber,
                    label: "Scroll",
                    value: KeyStatsAggregateSnapshot.formatScrollPx(vm.today.scrollDistancePx)
                )
            }
        }
    }

    private func bentoHeroCard(
        icon: String,
        accent: Color,
        label: String,
        value: String,
        subtitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                iconBadge(symbol: icon, accent: accent)
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.55)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }

            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(PopoverPalette.cardFill(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(PopoverPalette.cardBorder(scheme), lineWidth: 0.8)
        )
    }

    private func compactDistancePill(
        icon: String,
        accent: Color,
        label: String,
        value: String
    ) -> some View {
        HStack(spacing: 6) {
            iconBadge(symbol: icon, accent: accent)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(PopoverPalette.cardFill(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(PopoverPalette.cardBorder(scheme), lineWidth: 0.8)
        )
    }

    private func iconBadge(symbol: String, accent: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(accent.opacity(scheme == .dark ? 0.22 : 0.13))
                .frame(width: 18, height: 18)
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(accent)
        }
    }

    // MARK: - Key Breakdown

    private var keyBreakdownSection: some View {
        let items = Array(vm.today.topKeys.prefix(15))
        let maxCount = max(1, items.first?.count ?? 1)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text("Top Keys")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Spacer()
                PopoverGhostPill(title: "Heatmap ↗") {
                    onClosePopover()
                    vm.onOpenSettingsSection(.keyStats, nil)
                }
            }

            Group {
                if items.isEmpty {
                    Text("Start typing to populate today's top 15 keys.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 10)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        keyBreakdownColumn(items: items, maxCount: maxCount, columnIndex: 0)
                        verticalColumnRule
                        keyBreakdownColumn(items: items, maxCount: maxCount, columnIndex: 1)
                        verticalColumnRule
                        keyBreakdownColumn(items: items, maxCount: maxCount, columnIndex: 2)
                    }
                    .padding(8)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(PopoverPalette.cardFill(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(PopoverPalette.cardBorder(scheme), lineWidth: 0.8)
            )
        }
    }

    private func keyBreakdownColumn(items: [RankedCountItem], maxCount: Int, columnIndex: Int) -> some View {
        let start = columnIndex * 5
        let end = min(items.count, start + 5)
        let slice: [RankedCountItem] = start < end ? Array(items[start..<end]) : []
        let leadingPad: CGFloat = columnIndex == 0 ? 0 : 8
        let trailingPad: CGFloat = columnIndex == 2 ? 0 : 8

        return VStack(alignment: .leading, spacing: 3.5) {
            ForEach(Array(slice.enumerated()), id: \.offset) { _, item in
                let isHot = Double(item.count) / Double(maxCount) >= 0.45
                HStack(spacing: 4) {
                    keycapLabel(compactKeyDisplay(item.label), isHot: isHot)
                    Spacer(minLength: 2)
                    Text(formattedInteger(item.count))
                        .font(.system(size: 11, weight: isHot ? .medium : .regular))
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
                .frame(height: 17)
            }
        }
        .padding(.leading, leadingPad)
        .padding(.trailing, trailingPad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verticalColumnRule: some View {
        Rectangle()
            .fill(PopoverPalette.divider(scheme))
            .frame(width: 1, height: 98)
    }

    private func keycapLabel(_ text: String, isHot: Bool) -> some View {
        let fill: Color = isHot
            ? LinearUI.accent.opacity(scheme == .dark ? 0.28 : 0.14)
            : Color.primary.opacity(scheme == .dark ? 0.11 : 0.055)
        let stroke: Color = isHot
            ? LinearUI.accent.opacity(scheme == .dark ? 0.45 : 0.30)
            : Color.primary.opacity(scheme == .dark ? 0.15 : 0.09)
        let fg: Color = isHot ? LinearUI.accent : Color.primary

        return Text(text)
            .font(.system(size: 10.5, weight: isHot ? .semibold : .medium, design: .rounded))
            .foregroundStyle(fg)
            .lineLimit(1)
            .padding(.horizontal, 5.5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .stroke(stroke, lineWidth: 0.75)
            )
    }

    // MARK: - History Section

    private var historySection: some View {
        let totalText = formattedHistoryTotal(snapshot: vm.historySynced, metric: vm.historyMetric)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Activity")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)

                Spacer(minLength: 4)

                PopoverCompactSegment(
                    options: [("7D", StatsTimeRange.days7), ("30D", StatsTimeRange.days30)],
                    selection: $vm.historyRange
                )

                PopoverStyleIconToggle(selection: $vm.historyStyle)

                PopoverGhostPill(title: "Hourly ↗") {
                    onClosePopover()
                    vm.onOpenSettingsSection(.keyStats, .today)
                }
            }

            PopoverHistoryChartCard(
                synced: vm.historySynced,
                thisMac: vm.historyThisMac,
                metric: $vm.historyMetric,
                style: vm.historyStyle,
                totalText: totalText,
                accentColor: LinearUI.accent,
                amberColor: PopoverPalette.amber,
                hoveredIndex: $hoveredTrendIndex
            )
        }
    }

    // MARK: - Footer Toolbar

    private var footerToolbar: some View {
        HStack(spacing: 6) {
            PopoverFooterIconButton(symbol: "gearshape", help: "Preferences") {
                onClosePopover()
                vm.onOpenSettingsSection(.preferences, nil)
            }
            PopoverFooterIconButton(symbol: "square.grid.2x2", help: "App Statistics") {
                onClosePopover()
                vm.onOpenSettingsSection(.keyStats, nil)
            }
            PopoverFooterIconButton(symbol: "chart.bar.fill", help: "All-Time Stats") {
                onClosePopover()
                vm.onOpenSettingsSection(.keyStats, .allTime)
            }

            Spacer(minLength: 4)

            if vm.isInstallingUpdate {
                PopoverFooterActionButton(title: "Updating...", accentFill: true, disabled: true) {}
            } else if let release = vm.availableRelease {
                PopoverFooterActionButton(title: "Update v\(release.version)", accentFill: true) {
                    onClosePopover()
                    vm.onInstallRelease(release)
                }
            } else if vm.isCheckingUpdates {
                PopoverFooterActionButton(title: "Checking...", disabled: true) {}
            } else {
                PopoverFooterActionButton(title: "Update Now") {
                    onClosePopover()
                    vm.onCheckForUpdates()
                }
            }

            PopoverFooterActionButton(title: "Quit") {
                vm.onQuit()
            }
        }
        .padding(.top, 1)
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

// MARK: - Interactive Popover Controls

private struct PopoverSpeedPillButton: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    let liveActive: Bool
    let isExpanded: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3.5) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(liveActive ? LinearUI.accent : PopoverPalette.amber)
                Text(text)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(liveActive ? LinearUI.accent : Color.secondary)
            }
            .padding(.horizontal, 7.5)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isExpanded
                          ? LinearUI.accent.opacity(scheme == .dark ? 0.20 : 0.12)
                          : (hovered ? PopoverPalette.elevatedPillFill(scheme) : PopoverPalette.cardFill(scheme)))
            )
            .overlay(
                Capsule()
                    .stroke(isExpanded ? LinearUI.accent.opacity(0.45) : PopoverPalette.cardBorder(scheme), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Live KPS / CPS (click for details)")
    }
}

private struct PopoverStepperIconButton: View {
    @Environment(\.colorScheme) private var scheme
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovered ? LinearUI.accent : Color.primary)
                .frame(width: 19, height: 18)
                .background(hovered ? Color.primary.opacity(scheme == .dark ? 0.12 : 0.06) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

private struct PopoverGhostPill: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(hovered ? LinearUI.accent : Color.secondary)
                .padding(.horizontal, 7.5)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovered ? PopoverPalette.elevatedPillFill(scheme) : PopoverPalette.cardFill(scheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(PopoverPalette.cardBorder(scheme), lineWidth: 0.75)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct PopoverFooterIconButton: View {
    @Environment(\.colorScheme) private var scheme
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hovered ? Color.primary : Color.secondary)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(hovered ? PopoverPalette.elevatedPillFill(scheme) : PopoverPalette.cardFill(scheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .stroke(PopoverPalette.cardBorder(scheme), lineWidth: 0.75)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

private struct PopoverFooterActionButton: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var accentFill: Bool = false
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let fg: Color = accentFill ? Color.white : Color.primary
        let bg: Color = accentFill
            ? LinearUI.accent
            : (hovered ? PopoverPalette.elevatedPillFill(scheme) : PopoverPalette.cardFill(scheme))
        let border: Color = accentFill
            ? LinearUI.accent.opacity(0.8)
            : PopoverPalette.cardBorder(scheme)

        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(fg)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(bg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .stroke(border, lineWidth: 0.75)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1.0)
        .onHover { hovered = $0 }
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

// MARK: - Elevated Segmented Controls

private struct PopoverCompactSegment<Option: Hashable>: View {
    @Environment(\.colorScheme) private var scheme
    let options: [(label: String, value: Option)]
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, item in
                let active = item.value == selection
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        selection = item.value
                    }
                } label: {
                    Text(item.label)
                        .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(active ? PopoverPalette.elevatedPillFill(scheme) : Color.clear)
                                .shadow(color: active ? .black.opacity(scheme == .dark ? 0.22 : 0.08) : .clear, radius: 1, x: 0, y: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                .fill(PopoverPalette.trackFill(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                .stroke(PopoverPalette.cardBorder(scheme), lineWidth: 0.6)
        )
    }
}

private struct PopoverStyleIconToggle: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var selection: PopoverHistoryStyle

    var body: some View {
        HStack(spacing: 1) {
            iconButton(style: .line, symbol: "chart.xyaxis.line", help: "Smooth Line")
            iconButton(style: .bar, symbol: "chart.bar.fill", help: "Bar Chart")
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                .fill(PopoverPalette.trackFill(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                .stroke(PopoverPalette.cardBorder(scheme), lineWidth: 0.6)
        )
    }

    private func iconButton(style: PopoverHistoryStyle, symbol: String, help: String) -> some View {
        let active = (selection == style)
        return Button {
            withAnimation(.easeInOut(duration: 0.14)) {
                selection = style
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? LinearUI.accent : Color.secondary)
                .frame(width: 21, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(active ? PopoverPalette.elevatedPillFill(scheme) : Color.clear)
                        .shadow(color: active ? .black.opacity(scheme == .dark ? 0.22 : 0.08) : .clear, radius: 1, x: 0, y: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Dual-Series Monotonic History Chart

private struct PopoverHistoryChartCard: View {
    @Environment(\.colorScheme) private var scheme
    let synced: KeyStatsAggregateSnapshot
    let thisMac: KeyStatsAggregateSnapshot
    @Binding var metric: PopoverHistoryMetric
    let style: PopoverHistoryStyle
    let totalText: String
    let accentColor: Color
    let amberColor: Color
    @Binding var hoveredIndex: Int?

    // 368 outer - 28 outer pad - 20 card pad - 36 yAxis - 6 gap = 278
    private let yAxisWidth: CGFloat = 36
    private let plotWidth: CGFloat = 278
    private let plotHeight: CGFloat = 92

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

        return VStack(alignment: .leading, spacing: 6) {
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

                Canvas { context, size in
                    drawGridAndBaseline(in: &context, size: size)
                    guard !syncedPoints.isEmpty else { return }

                    switch style {
                    case .line:
                        if showThisMac {
                            drawSmoothSeries(
                                in: &context,
                                size: size,
                                values: localValues,
                                yMax: yMax,
                                color: amberColor,
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
                            color: accentColor,
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
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.leading, yAxisWidth + 6)
            .padding(.trailing, 2)

            Rectangle()
                .fill(PopoverPalette.divider(scheme))
                .frame(height: 1)

            HStack {
                Text("Total: \(totalText)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
                Spacer()
                Text(showThisMac ? "\(synced.deviceCount) Macs synced" : "This Mac")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PopoverPalette.cardFill(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(PopoverPalette.cardBorder(scheme), lineWidth: 0.8)
        )
    }

    private func chartTopBar(
        points: [DailyActivityPoint],
        syncedValues: [Double],
        localValues: [Double]
    ) -> some View {
        HStack(spacing: 6) {
            PopoverCompactSegment(
                options: PopoverHistoryMetric.allCases.map { ($0.rawValue, $0) },
                selection: $metric
            )

            Spacer(minLength: 4)

            if let idx = hoveredIndex, idx >= 0, idx < points.count {
                let dLabel = shortDateLabel(points[idx].dateKey)
                HStack(spacing: 4) {
                    Text(dLabel)
                        .foregroundStyle(Color.secondary)
                    Text(formatMetricTooltip(syncedValues[idx]))
                        .foregroundStyle(accentColor)
                    if showThisMac {
                        Text("/ \(formatMetricTooltip(localValues[idx]))")
                            .foregroundStyle(amberColor)
                    }
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .lineLimit(1)
            } else {
                HStack(spacing: 8) {
                    HStack(spacing: 3.5) {
                        Capsule()
                            .fill(accentColor)
                            .frame(width: 9, height: 2)
                        Text("All")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary)
                    }

                    if showThisMac {
                        HStack(spacing: 3.5) {
                            HStack(spacing: 1.5) {
                                Rectangle().fill(amberColor).frame(width: 2.5, height: 2)
                                Rectangle().fill(amberColor).frame(width: 2.5, height: 2)
                                Rectangle().fill(amberColor).frame(width: 2.5, height: 2)
                            }
                            Text("Mac")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Drawing

    private func drawGridAndBaseline(in context: inout GraphicsContext, size: CGSize) {
        let topY: CGFloat = 6
        let bottomY: CGFloat = size.height - 4
        let midY: CGFloat = (topY + bottomY) * 0.5
        let gridColor = Color.primary.opacity(scheme == .dark ? 0.11 : 0.08)
        let baselineColor = Color.primary.opacity(scheme == .dark ? 0.20 : 0.16)

        for y in [topY, midY] {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(gridColor), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
        }

        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: bottomY))
        baseline.addLine(to: CGPoint(x: size.width, y: bottomY))
        context.stroke(baseline, with: .color(baselineColor), lineWidth: 0.9)
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
            context.stroke(crosshair, with: .color(color.opacity(0.32)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
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
                        Gradient(colors: [color.opacity(0.20), color.opacity(0.01)]),
                        startPoint: CGPoint(x: 0, y: 6),
                        endPoint: CGPoint(x: 0, y: size.height - 4)
                    )
                )
            }

            let strokeStyle = StrokeStyle(
                lineWidth: dashed ? 1.6 : 1.9,
                lineCap: .round,
                lineJoin: .round,
                dash: dashed ? [4, 2.5] : []
            )
            context.stroke(curve, with: .color(color), style: strokeStyle)
        }

        let haloColor = scheme == .dark
            ? Color(red: 0.14, green: 0.15, blue: 0.18)
            : Color.white
        let showAllDots = pts.count <= 14
        for (idx, p) in pts.enumerated() {
            let isHovered = (hoveredIdx == idx)
            guard showAllDots || isHovered else { continue }
            let r: CGFloat = isHovered ? 3.6 : (dashed ? 2.1 : 2.5)
            let dotRect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            let ellipse = Path(ellipseIn: dotRect)
            context.stroke(ellipse, with: .color(haloColor.opacity(0.95)), lineWidth: 1.5)
            context.fill(ellipse, with: .color(color))
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
                context.fill(Path(roundedRect: syncedRect, cornerRadius: 2), with: .color(accentColor.opacity(highlightBoost)))
                context.fill(Path(roundedRect: localRect, cornerRadius: 2), with: .color(amberColor.opacity(highlightBoost)))
            } else {
                let barW = max(2.5, min(16.0, slotW * 0.56))
                let rect = CGRect(x: centerX - barW * 0.5, y: bottomY - sH, width: barW, height: sH)
                let alpha = (hoveredIdx == idx) ? 1.0 : 0.88
                context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(accentColor.opacity(alpha)))
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
