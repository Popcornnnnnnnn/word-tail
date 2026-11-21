import SwiftUI
import WordTailCore

enum HeatmapTheme: String, CaseIterable, Identifiable {
    case indigo = "Indigo"
    case blue = "Blue"
    case warm = "Warm"
    case spectrum = "Spectrum"
    case green = "Green"
    case teal = "Teal"
    case rose = "Rose"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .indigo: return LinearUI.accent
        case .blue: return Color(red: 0.14, green: 0.49, blue: 0.92)
        case .warm: return Color(red: 0.92, green: 0.32, blue: 0.14)
        case .spectrum: return Color(red: 0.92, green: 0.28, blue: 0.22)
        case .green: return Color(red: 0.16, green: 0.66, blue: 0.35)
        case .teal: return Color(red: 0.08, green: 0.62, blue: 0.66)
        case .rose: return Color(red: 0.86, green: 0.24, blue: 0.46)
        }
    }

    private var stops: [(r: Double, g: Double, b: Double)] {
        switch self {
        case .indigo:
            return [(0.74, 0.77, 0.98), (0.37, 0.42, 0.89), (0.24, 0.27, 0.72)]
        case .blue:
            return [(0.68, 0.85, 0.99), (0.14, 0.49, 0.92), (0.04, 0.30, 0.72)]
        case .warm:
            return [(0.99, 0.84, 0.42), (0.96, 0.52, 0.16), (0.85, 0.18, 0.16)]
        case .spectrum:
            return [(0.22, 0.56, 0.96), (0.20, 0.78, 0.68), (0.96, 0.76, 0.20), (0.90, 0.22, 0.20)]
        case .green:
            return [(0.68, 0.90, 0.74), (0.16, 0.66, 0.35), (0.08, 0.44, 0.22)]
        case .teal:
            return [(0.64, 0.90, 0.90), (0.08, 0.62, 0.66), (0.04, 0.42, 0.48)]
        case .rose:
            return [(0.98, 0.76, 0.84), (0.86, 0.24, 0.46), (0.64, 0.10, 0.30)]
        }
    }

    func rgb(forIntensity t: Double, scheme: ColorScheme) -> (r: Double, g: Double, b: Double) {
        let clamped = max(0.0, min(1.0, t))
        let list = stops
        let scaled = clamped * Double(list.count - 1)
        let idx = min(list.count - 2, max(0, Int(floor(scaled))))
        let localT = scaled - Double(idx)
        let a = list[idx]
        let b = list[idx + 1]
        let rawR = a.r + (b.r - a.r) * localT
        let rawG = a.g + (b.g - a.g) * localT
        let rawB = a.b + (b.b - a.b) * localT
        if scheme == .dark {
            // Lift dark-mode luminance slightly at lower intensities so keycaps read vividly on charcoal.
            let mix = 0.22 + 0.78 * clamped
            return (0.18 + (rawR - 0.18) * mix, 0.19 + (rawG - 0.19) * mix, 0.22 + (rawB - 0.22) * mix)
        }
        return (rawR, rawG, rawB)
    }

    func heatColor(forIntensity t: Double, scheme: ColorScheme) -> Color {
        let c = rgb(forIntensity: t, scheme: scheme)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    func needsLightText(intensity t: Double, scheme: ColorScheme) -> Bool {
        let c = rgb(forIntensity: t, scheme: scheme)
        let luminance = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
        return luminance < 0.58
    }
}

private enum TrendMetric: String, CaseIterable, Identifiable {
    case keys = "Keys"
    case clicks = "Clicks"
    case mouse = "Mouse"
    case scroll = "Scroll"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .keys: return LinearUI.accent
        case .clicks: return LinearUI.positive
        case .mouse: return LinearUI.blue
        case .scroll: return LinearUI.warning
        }
    }
}

private enum TrendStyle: String, CaseIterable, Identifiable {
    case line = "Line"
    case bar = "Bar"

    var id: String { rawValue }
}

private enum AppSortMetric {
    case name
    case keys
    case clicks
    case scroll
}

struct KeyStatsSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: SettingsViewModel
    @AppStorage("WordTailHeatmapTheme") private var heatmapThemeRaw: String = HeatmapTheme.indigo.rawValue
    @State private var selectedHeatmapAppID: String? = nil
    @State private var showingDatePopover: Bool = false
    @State private var showImportPopover: Bool = false

    private var theme: HeatmapTheme {
        HeatmapTheme(rawValue: heatmapThemeRaw) ?? .indigo
    }

    var body: some View {
        let ks = vm.keyStats
        let appsWithHeatmap = ks.topApps.filter { !$0.keyHeatmap.isEmpty }
        let selectedApp = selectedHeatmapAppID.flatMap { bid in appsWithHeatmap.first { $0.bundleID == bid } }
        let effectiveHeatmap = selectedApp?.keyHeatmap ?? ks.keyHeatmap
        let effectiveTotalKeys = selectedApp?.keyPresses ?? ks.totalKeyPresses

        return VStack(alignment: .leading, spacing: 16) {
            headerBar(ks: ks)

            if vm.keyStatsRange == .today && !vm.isStaticShowcase {
                dayNavigatorStrip
            }

            kpiRow(ks: ks)

            ANSIKeyboardHeatmapView(
                heatmap: effectiveHeatmap,
                totalKeys: effectiveTotalKeys,
                englishPercent: ks.englishKeyPercent,
                theme: theme,
                themeSelection: Binding(
                    get: { theme },
                    set: { heatmapThemeRaw = $0.rawValue }
                ),
                appsWithHeatmap: appsWithHeatmap,
                selectedAppID: $selectedHeatmapAppID,
                isStaticShowcase: vm.isStaticShowcase
            )

            ActivityTrendChartCard(
                range: ks.range,
                hourlyKeys: ks.hourlyKeys,
                hourlyClicks: ks.hourlyClicks,
                hourlyBuckets: vm.hourlyTrendBuckets,
                hourlyRecent24h: $vm.hourlyRecent24Hours,
                busiestKeyHour: vm.busiestKeyHour,
                deviceCount: ks.deviceCount,
                deviceScope: ks.deviceScope,
                dailyTrend: ks.dailyTrend,
                isStaticShowcase: vm.isStaticShowcase
            )

            if !ks.topApps.isEmpty {
                AppStatisticsTableCard(
                    apps: ks.topApps,
                    resolvedIcon: { vm.resolvedAppIcon(bundleID: $0) },
                    onOpenFullAppStats: vm.isStaticShowcase ? nil : { vm.selectedSection = .appStats }
                )
            }

            HStack(alignment: .top, spacing: 12) {
                KeyBreakdownCard(topKeys: ks.topKeys)
                    .frame(maxWidth: .infinity)

                TopKeysDonutCard(topKeys: ks.topKeys, totalKeyPresses: ks.totalKeyPresses)
                    .frame(maxWidth: .infinity)
            }

            HStack(alignment: .top, spacing: 12) {
                ShortcutsAndProfileCard(ks: ks)
                    .frame(maxWidth: .infinity)

                LifetimeInsightsCard(
                    ks: ks,
                    mouseCalibrationFactor: vm.mouseCalibrationFactor,
                    onCalibrateMouse: vm.isStaticShowcase ? nil : { vm.showingMouseCalibrationSheet = true }
                )
                .frame(maxWidth: .infinity)
            }

            ActivityCalendarCard(
                days: ks.calendarDays,
                activeDays: ks.activeDays,
                maxDailyKeys: ks.maxDailyKeys,
                currentStreak: ks.currentStreakDays,
                longestStreak: ks.longestStreakDays,
                theme: theme,
                hasData: ks.totalKeyPresses > 0 || ks.totalClicks > 0,
                onResetToday: { vm.resetTodayKeyStats() },
                onClearAll: { vm.clearKeyStats() }
            )
        }
    }

    private var dayNavigatorStrip: some View {
        let bounds = vm.statsDateBounds
        let df: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return f
        }()

        return HStack(spacing: 6) {
            Text("Viewing day:")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Button {
                vm.stepStatsDate(byDays: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(LinearUI.subtleFill(scheme), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!vm.canStepStatsDateBackward)
            .opacity(vm.canStepStatsDateBackward ? 1 : 0.4)
            .help("Previous day")

            Button {
                showingDatePopover.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LinearUI.accent)
                    Text(vm.isSelectedDateToday ? "Today · \(df.string(from: vm.selectedStatsDate))" : df.string(from: vm.selectedStatsDate))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(LinearUI.subtleFill(scheme), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(LinearUI.controlBorder(scheme), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingDatePopover, arrowEdge: .bottom) {
                DatePicker(
                    "",
                    selection: $vm.selectedStatsDate,
                    in: bounds.earliest...bounds.latest,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(10)
            }

            Button {
                vm.stepStatsDate(byDays: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(LinearUI.subtleFill(scheme), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!vm.canStepStatsDateForward)
            .opacity(vm.canStepStatsDateForward ? 1 : 0.4)
            .help("Next day")

            if !vm.isSelectedDateToday {
                Button {
                    vm.resetStatsDateToToday()
                } label: {
                    Text("Jump to Today")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(LinearUI.accent)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(LinearUI.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func headerBar(ks: KeyStatsAggregateSnapshot) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("KeyStats")
                        .font(.system(size: 16, weight: .semibold))
                    if let msg = vm.keyStatsImportMessage {
                        Text(msg)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color(red: 0.16, green: 0.66, blue: 0.35))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(scheme == .dark ? 0.18 : 0.11), in: Capsule())
                    }
                }
                Text(headerSubtitle(ks: ks))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if ks.deviceCount > 1 {
                LinearSegmentedChoices(
                    options: [
                        ("All Macs", StatsDeviceScope.allDevices),
                        ("This Mac", StatsDeviceScope.thisMac)
                    ],
                    selection: $vm.keyStatsDeviceScope
                )
            }

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
                if vm.canImportFromInstalledKeyStats && !vm.isStaticShowcase {
                    showImportPopover.toggle()
                } else {
                    vm.importKeyStatsJSON()
                }
            }
            .popover(isPresented: $showImportPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    LinearPopoverMenuItem(
                        title: "Import from KeyStats.app",
                        icon: "arrow.down.doc"
                    ) {
                        showImportPopover = false
                        vm.importFromInstalledKeyStatsApp()
                    }
                    LinearPopoverMenuItem(
                        title: "Import JSON File…",
                        icon: "doc"
                    ) {
                        showImportPopover = false
                        vm.importKeyStatsJSON()
                    }
                }
                .padding(6)
                .frame(width: 215)
            }

            LinearActionButton(title: "Export", icon: "square.and.arrow.up") {
                vm.exportKeyStatsJSON()
            }
        }
    }

    private func headerSubtitle(ks: KeyStatsAggregateSnapshot) -> String {
        var parts: [String] = []
        if ks.range == .allTime, let first = ks.firstActiveDateKey, let last = ks.lastActiveDateKey {
            parts.append("\(first) – \(last)")
            parts.append("\(ks.activeDays) active days")
        } else if ks.activeDays > 0 && ks.range != .today {
            parts.append("\(ks.activeDays) active day\(ks.activeDays == 1 ? "" : "s")")
        } else {
            parts.append("100% local telemetry")
        }
        if ks.deviceCount > 1 && ks.deviceScope == .allDevices {
            parts.append("\(ks.deviceCount) devices merged")
        }
        return parts.joined(separator: " · ")
    }

    private func kpiRow(ks: KeyStatsAggregateSnapshot) -> some View {
        HStack(spacing: 9) {
            LinearMetricTile(
                label: "KEYSTROKES",
                value: formattedInt(ks.totalKeyPresses),
                subtitle: "Peak \(ks.peakKPS) KPS · \(ks.leftHandPercent):\(100 - ks.leftHandPercent) L/R",
                icon: "keyboard",
                accentColor: LinearUI.accent
            )
            LinearMetricTile(
                label: "MOUSE CLICKS",
                value: formattedInt(ks.totalClicks),
                subtitle: "\(ks.inputStyleLabel) · L \(formattedInt(ks.leftClicks)) · R \(formattedInt(ks.rightClicks))",
                icon: "cursorarrow.click",
                accentColor: LinearUI.positive
            )
            LinearMetricTile(
                label: "MOUSE TRAVEL",
                value: KeyStatsAggregateSnapshot.formatDistance(ks.mouseDistanceMeters),
                subtitle: String(format: "%.2f Marathons", ks.marathonsEquivalent),
                icon: "arrow.left.and.right",
                accentColor: LinearUI.blue
            )
            LinearMetricTile(
                label: "SCROLL TRAVEL",
                value: KeyStatsAggregateSnapshot.formatDistance(ks.scrollDistanceMeters),
                subtitle: String(format: "%.2f Everests", ks.everestsEquivalent),
                icon: "arrow.up.and.down",
                accentColor: LinearUI.warning
            )
        }
    }
}

// MARK: - KeyStats-Grade MacBook ANSI Keyboard Heatmap

private struct ANSIKeyboardHeatmapView: View {
    @Environment(\.colorScheme) private var scheme
    let heatmap: [String: Int]
    let totalKeys: Int
    let englishPercent: Int
    let theme: HeatmapTheme
    @Binding var themeSelection: HeatmapTheme
    let appsWithHeatmap: [AppActivitySummary]
    @Binding var selectedAppID: String?
    let isStaticShowcase: Bool

    @State private var hoveredKey: KeySpec?
    @State private var showAppFilterPopover: Bool = false

    var body: some View {
        let maxCount = max(1, KeyCodeMapper.ansiKeyIDs.map { heatmap[$0, default: 0] }.max() ?? 1)
        let activeKeys = KeyCodeMapper.ansiKeyIDs.reduce(0) { acc, id in acc + ((heatmap[id, default: 0] > 0) ? 1 : 0) }

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                LinearSectionHeader(title: "Keyboard Heatmap")

                if let key = hoveredKey {
                    let count = heatmap[key.id, default: 0]
                    let pct = totalKeys > 0 ? Double(count) / Double(totalKeys) * 100.0 : 0
                    Text("\(KeyCodeMapper.prettyKeyLabel(key.id)): \(formattedInt(count)) (\(String(format: "%.1f%%", pct)))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.color)
                } else {
                    Text("\(formattedInt(totalKeys)) keys · \(activeKeys) active keys")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !appsWithHeatmap.isEmpty {
                    let selectedName = selectedAppID.flatMap { bid in
                        appsWithHeatmap.first { $0.bundleID == bid }?.displayName
                    } ?? "All Apps"

                    Button {
                        guard !isStaticShowcase else { return }
                        showAppFilterPopover.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(selectedName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if !isStaticShowcase {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8.5, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(LinearUI.subtleFill(scheme), in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .stroke(LinearUI.controlBorder(scheme), lineWidth: 1)
                        )
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showAppFilterPopover, arrowEdge: .bottom) {
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 2) {
                                LinearPopoverMenuItem(
                                    title: "All Apps",
                                    icon: "square.grid.2x2",
                                    isSelected: selectedAppID == nil
                                ) {
                                    selectedAppID = nil
                                    showAppFilterPopover = false
                                }
                                Divider().padding(.vertical, 2)
                                ForEach(appsWithHeatmap.prefix(20)) { app in
                                    LinearPopoverMenuItem(
                                        title: app.displayName,
                                        detail: formattedInt(app.keyPresses),
                                        isSelected: selectedAppID == app.bundleID
                                    ) {
                                        selectedAppID = app.bundleID
                                        showAppFilterPopover = false
                                    }
                                }
                            }
                            .padding(6)
                        }
                        .frame(minWidth: 220, maxHeight: 320)
                    }
                }

                HStack(spacing: 4) {
                    ForEach(HeatmapTheme.allCases) { item in
                        Button {
                            themeSelection = item
                        } label: {
                            Circle()
                                .fill(item.color)
                                .frame(width: 10, height: 10)
                                .overlay(
                                    Circle()
                                        .stroke(theme == item ? Color.primary.opacity(0.65) : Color.clear, lineWidth: 1.5)
                                        .padding(-2)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("\(item.rawValue) theme")
                    }
                }
                .padding(.leading, 4)
            }

            LinearCard {
                VStack(spacing: 4) {
                    ForEach(0..<KeyCodeMapper.ansiRows.count, id: \.self) { rowIdx in
                        keyboardRow(rowIdx: rowIdx, maxCount: maxCount)
                    }

                    HStack(spacing: 6) {
                        Text("\(englishPercent)% Roman · \(100 - englishPercent)% CJK/IME")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        HeatScaleLegend(theme: theme)
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func keyboardRow(rowIdx: Int, maxCount: Int) -> some View {
        let row = KeyCodeMapper.ansiRows[rowIdx]
        let rowHeight: CGFloat = rowIdx == 0 ? 22 : 34

        if rowIdx == 5 {
            // Row 5 uses macOS inverted-T arrow cluster (`Left`, stacked `Up`/`Down`, `Right`)
            let leftSpecs = Array(row.prefix(7)) // Fn .. RightOption
            let arrowLeft = row[7]
            let arrowUp = row[8]
            let arrowDown = row[9]
            let arrowRight = row[10]
            let weights: [Double] = leftSpecs.map(\.widthWeight) + [arrowLeft.widthWeight, arrowUp.widthWeight, arrowRight.widthWeight]
            let colCount = weights.count

            GeometryReader { geo in
                let spacing: CGFloat = 3.5
                let totalWeight = weights.reduce(0, +)
                let usableW = max(10, geo.size.width - spacing * CGFloat(max(0, colCount - 1)))

                HStack(spacing: spacing) {
                    ForEach(leftSpecs, id: \.id) { spec in
                        keycapView(
                            spec: spec,
                            count: heatmap[spec.id, default: 0],
                            maxCount: maxCount,
                            width: usableW * CGFloat(spec.widthWeight / totalWeight),
                            height: rowHeight,
                            isFunctionRow: false,
                            isCompactHalfKey: false
                        )
                    }

                    keycapView(
                        spec: arrowLeft,
                        count: heatmap[arrowLeft.id, default: 0],
                        maxCount: maxCount,
                        width: usableW * CGFloat(arrowLeft.widthWeight / totalWeight),
                        height: rowHeight,
                        isFunctionRow: false,
                        isCompactHalfKey: false
                    )

                    let upDownW = usableW * CGFloat(arrowUp.widthWeight / totalWeight)
                    let halfH = (rowHeight - 2.0) / 2.0
                    VStack(spacing: 2) {
                        keycapView(
                            spec: arrowUp,
                            count: heatmap[arrowUp.id, default: 0],
                            maxCount: maxCount,
                            width: upDownW,
                            height: halfH,
                            isFunctionRow: false,
                            isCompactHalfKey: true
                        )
                        keycapView(
                            spec: arrowDown,
                            count: heatmap[arrowDown.id, default: 0],
                            maxCount: maxCount,
                            width: upDownW,
                            height: halfH,
                            isFunctionRow: false,
                            isCompactHalfKey: true
                        )
                    }

                    keycapView(
                        spec: arrowRight,
                        count: heatmap[arrowRight.id, default: 0],
                        maxCount: maxCount,
                        width: usableW * CGFloat(arrowRight.widthWeight / totalWeight),
                        height: rowHeight,
                        isFunctionRow: false,
                        isCompactHalfKey: false
                    )
                }
            }
            .frame(height: rowHeight)
        } else {
            GeometryReader { geo in
                let spacing: CGFloat = 3.5
                let totalWeight = row.reduce(0.0) { $0 + $1.widthWeight }
                let usableW = max(10, geo.size.width - spacing * CGFloat(max(0, row.count - 1)))

                HStack(spacing: spacing) {
                    ForEach(row, id: \.id) { spec in
                        let keyW = usableW * CGFloat(spec.widthWeight / totalWeight)
                        keycapView(
                            spec: spec,
                            count: heatmap[spec.id, default: 0],
                            maxCount: maxCount,
                            width: keyW,
                            height: rowHeight,
                            isFunctionRow: rowIdx == 0,
                            isCompactHalfKey: false
                        )
                    }
                }
            }
            .frame(height: rowHeight)
        }
    }

    @ViewBuilder
    private func keycapView(
        spec: KeySpec,
        count: Int,
        maxCount: Int,
        width: CGFloat,
        height: CGFloat,
        isFunctionRow: Bool,
        isCompactHalfKey: Bool
    ) -> some View {
        let intensity = count > 0 ? min(1.0, max(0.08, sqrt(Double(count) / Double(maxCount)))) : 0.0
        let fill: Color = count == 0 ? LinearUI.subtleFill(scheme) : theme.heatColor(forIntensity: intensity, scheme: scheme)
        let strongFill = count > 0 && theme.needsLightText(intensity: intensity, scheme: scheme)
        let primaryText: Color = strongFill ? .white : Color.primary.opacity(count > 0 ? 0.90 : 0.56)
        let secondaryText: Color = strongFill ? .white.opacity(0.76) : Color.primary.opacity(0.36)
        let isHovered = hoveredKey?.id == spec.id

        ZStack {
            RoundedRectangle(cornerRadius: isCompactHalfKey ? 4 : 5.5, style: .continuous)
                .fill(fill)
            RoundedRectangle(cornerRadius: isCompactHalfKey ? 4 : 5.5, style: .continuous)
                .stroke(
                    isHovered ? theme.color : LinearUI.hairline(scheme),
                    lineWidth: isHovered ? 1.5 : 1
                )

            if isCompactHalfKey {
                HStack(spacing: 2) {
                    Text(spec.label)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(primaryText)
                    if count > 0 {
                        Text(compactBadge(count))
                            .font(.system(size: 7, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(strongFill ? Color.white.opacity(0.9) : Color.primary.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 2)
            } else if isFunctionRow {
                HStack(spacing: 2) {
                    if count > 0 && width >= 30 {
                        Text(compactBadge(count))
                            .font(.system(size: 7, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(strongFill ? .white : primaryText)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(
                                strongFill ? Color.black.opacity(0.24) : Color.black.opacity(scheme == .dark ? 0.28 : 0.08),
                                in: Capsule()
                            )
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(spec.label)
                        .font(.system(size: 8.5, weight: count > 0 ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(primaryText)
                }
                .padding(.horizontal, 4)
            } else {
                // Standard full-height key: KeyStats top-left count badge + bottom-right key legend (with optional top-right shift symbol)
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 2) {
                        if count > 0 {
                            Text(compactBadge(count))
                                .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(strongFill ? Color.white : Color.primary.opacity(0.84))
                                .padding(.horizontal, 3.5)
                                .padding(.vertical, 0.5)
                                .background(
                                    strongFill
                                        ? Color.black.opacity(0.24)
                                        : Color.black.opacity(scheme == .dark ? 0.30 : 0.075),
                                    in: Capsule()
                                )
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let shift = KeyCodeMapper.shiftLegend(forKeyID: spec.id) {
                            Text(shift)
                                .font(.system(size: 8, weight: .regular, design: .rounded))
                                .foregroundStyle(secondaryText)
                        }
                    }

                    Spacer(minLength: 0)

                    HStack {
                        if spec.id == "Space" {
                            Spacer(minLength: 0)
                            Text(spec.label)
                                .font(.system(size: 10, weight: count > 0 ? .semibold : .regular, design: .rounded))
                                .foregroundStyle(primaryText)
                            Spacer(minLength: 0)
                        } else {
                            Spacer(minLength: 0)
                            Text(spec.label)
                                .font(.system(size: spec.label.count > 1 ? 9.5 : 10.5, weight: count > 0 ? .semibold : .medium, design: .rounded))
                                .foregroundStyle(primaryText)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredKey = spec
            } else if hoveredKey?.id == spec.id {
                hoveredKey = nil
            }
        }
    }

    private func compactBadge(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 10_000 {
            return "\(count / 1_000)k"
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }
}

// MARK: - Interactive Activity Trend Chart (Line / Bar across Hours or Days)

private struct ChartBucket: Identifiable {
    let id: String
    let axisLabel: String
    let detailLabel: String
    let value: Double
    let formattedValue: String
    var localValue: Double? = nil
    var formattedLocalValue: String? = nil
}

private struct ActivityTrendChartCard: View {
    @Environment(\.colorScheme) private var scheme
    let range: StatsTimeRange
    let hourlyKeys: [Int]
    let hourlyClicks: [Int]
    let hourlyBuckets: [HourlyTrendBucket]
    @Binding var hourlyRecent24h: Bool
    let busiestKeyHour: String?
    let deviceCount: Int
    let deviceScope: StatsDeviceScope
    let dailyTrend: [DailyActivityPoint]
    let isStaticShowcase: Bool

    @State private var metric: TrendMetric = .keys
    @State private var style: TrendStyle = .line
    @State private var hoveredIndex: Int?

    private let thisMacOrange = Color(red: 0.93, green: 0.55, blue: 0.14)

    private var availableMetrics: [(label: String, value: TrendMetric)] {
        if range == .today {
            return [("Keys", .keys), ("Clicks", .clicks)]
        }
        return [("Keys", .keys), ("Clicks", .clicks), ("Mouse", .mouse), ("Scroll", .scroll)]
    }

    private var effectiveMetric: TrendMetric {
        if range == .today && (metric == .mouse || metric == .scroll) {
            return .keys
        }
        return metric
    }

    private var showLocalComparison: Bool {
        range == .today && deviceCount > 1 && deviceScope == .allDevices && !hourlyBuckets.isEmpty
    }

    var body: some View {
        let activeMetric = effectiveMetric
        let buckets = buildBuckets(metric: activeMetric)
        let localMax = buckets.compactMap(\.localValue).max() ?? 0.0
        let maxVal = max(1.0, max(buckets.map(\.value).max() ?? 1.0, showLocalComparison ? localMax : 0.0))
        let peakBucket = buckets.max(by: { $0.value < $1.value })

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                LinearSectionHeader(title: range == .today ? (hourlyRecent24h ? "Last 24 Hours" : "24-Hour Activity") : "Activity Trend")

                if let idx = hoveredIndex, idx >= 0, idx < buckets.count {
                    let b = buckets[idx]
                    if showLocalComparison, let localStr = b.formattedLocalValue {
                        Text("\(b.detailLabel) · All \(b.formattedValue) · Mac \(localStr)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(activeMetric.color)
                    } else {
                        Text("\(b.detailLabel): \(b.formattedValue)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(activeMetric.color)
                    }
                } else if let peak = peakBucket, peak.value > 0 {
                    let prefix: String = {
                        if range == .today { return "Busiest" }
                        return (range == .allTime && dailyTrend.count > 65) ? "Weekly peak" : "Peak"
                    }()
                    Text("\(prefix): \(peak.detailLabel) (\(peak.formattedValue))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if showLocalComparison {
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Capsule().fill(activeMetric.color).frame(width: 9, height: 2)
                            Text("All").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 3.5) {
                            HStack(spacing: 1) {
                                Rectangle().fill(thisMacOrange).frame(width: 2.5, height: 2)
                                Rectangle().fill(thisMacOrange).frame(width: 2.5, height: 2)
                            }
                            Text("This Mac").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }

                if range == .today && !isStaticShowcase {
                    LinearSegmentedChoices(
                        options: [("By Date", false), ("Last 24h", true)],
                        selection: $hourlyRecent24h
                    )
                }

                LinearSegmentedChoices(
                    options: availableMetrics,
                    selection: Binding(
                        get: { activeMetric },
                        set: { metric = $0 }
                    )
                )

                LinearSegmentedChoices(
                    options: [("Line", TrendStyle.line), ("Bar", TrendStyle.bar)],
                    selection: $style
                )
            }

            LinearCard {
                VStack(spacing: 4) {
                    HStack(alignment: .top, spacing: 6) {
                        // Left Y-Axis Labels
                        VStack {
                            Text(formatMetricAxis(maxVal, metric: activeMetric))
                            Spacer()
                            Text(formatMetricAxis(maxVal / 2.0, metric: activeMetric))
                            Spacer()
                            Text("0")
                        }
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: 56, height: 102, alignment: .trailing)

                        GeometryReader { geo in
                            let w = max(1, geo.size.width)
                            let h = max(1, geo.size.height)

                            Canvas { context, size in
                                drawGrid(in: &context, size: size)
                                guard !buckets.isEmpty else { return }

                                if style == .bar {
                                    drawBars(
                                        in: &context,
                                        size: size,
                                        buckets: buckets,
                                        maxVal: maxVal,
                                        color: activeMetric.color,
                                        showLocalComparison: showLocalComparison
                                    )
                                } else {
                                    if showLocalComparison {
                                        let localVals = buckets.map { $0.localValue ?? 0 }
                                        drawSeriesCurve(
                                            in: &context,
                                            size: size,
                                            values: localVals,
                                            maxVal: maxVal,
                                            color: thisMacOrange,
                                            dashed: true,
                                            fillGradient: false
                                        )
                                    }
                                    drawSeriesCurve(
                                        in: &context,
                                        size: size,
                                        values: buckets.map(\.value),
                                        maxVal: maxVal,
                                        color: activeMetric.color,
                                        dashed: false,
                                        fillGradient: true
                                    )
                                }

                                if let hi = hoveredIndex, hi >= 0, hi < buckets.count {
                                    let x = xPosition(index: hi, count: buckets.count, width: size.width, isBar: style == .bar)
                                    let y = size.height - CGFloat(buckets[hi].value / maxVal) * (size.height - 8) - 4
                                    var guide = Path()
                                    guide.move(to: CGPoint(x: x, y: 0))
                                    guide.addLine(to: CGPoint(x: x, y: size.height))
                                    context.stroke(guide, with: .color(activeMetric.color.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                                    let dotRect = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
                                    context.fill(Path(ellipseIn: dotRect), with: .color(activeMetric.color))
                                    context.stroke(Path(ellipseIn: dotRect), with: .color(.white), lineWidth: 1.5)
                                }
                            }
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let loc):
                                    guard !buckets.isEmpty else { return }
                                    let idx = min(buckets.count - 1, max(0, Int((loc.x / w) * CGFloat(buckets.count))))
                                    hoveredIndex = idx
                                case .ended:
                                    hoveredIndex = nil
                                }
                            }
                            .frame(width: w, height: h)
                        }
                        .frame(height: 102)
                    }

                    // Bottom X-Axis Labels
                    HStack {
                        Spacer().frame(width: 62)
                        xAxisLabels(for: buckets)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func xAxisLabels(for buckets: [ChartBucket]) -> some View {
        if buckets.isEmpty {
            EmptyView()
        } else {
            let indices: [Int] = {
                if buckets.count <= 7 {
                    return Array(buckets.indices)
                }
                let step = max(1, (buckets.count - 1) / 4)
                var list: [Int] = []
                var i = 0
                while i < buckets.count {
                    list.append(i)
                    i += step
                }
                if list.last != buckets.count - 1 {
                    list.append(buckets.count - 1)
                }
                return list
            }()

            HStack {
                ForEach(Array(indices.enumerated()), id: \.offset) { pos, idx in
                    if pos > 0 { Spacer() }
                    Text(buckets[idx].axisLabel)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        let gridColor = Color.primary.opacity(scheme == .dark ? 0.08 : 0.07)
        let baselineColor = Color.primary.opacity(scheme == .dark ? 0.14 : 0.12)
        for frac in [CGFloat(0.04), 0.5] {
            let y = size.height * frac
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(gridColor), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        let baseY = size.height * 0.96
        var base = Path()
        base.move(to: CGPoint(x: 0, y: baseY))
        base.addLine(to: CGPoint(x: size.width, y: baseY))
        context.stroke(base, with: .color(baselineColor), lineWidth: 1)
    }

    private func drawBars(
        in context: inout GraphicsContext,
        size: CGSize,
        buckets: [ChartBucket],
        maxVal: Double,
        color: Color,
        showLocalComparison: Bool
    ) {
        let count = buckets.count
        let slotW = size.width / CGFloat(max(1, count))
        let usableH = max(4, size.height - 8)

        for (i, b) in buckets.enumerated() {
            if showLocalComparison {
                let pairW = max(2.0, min(12, slotW * 0.36))
                let centerX = CGFloat(i) * slotW + slotW / 2.0
                let sH = b.value <= 0 ? 1.5 : max(3.0, CGFloat(b.value / maxVal) * usableH)
                let lVal = b.localValue ?? 0
                let lH = lVal <= 0 ? 1.5 : max(3.0, CGFloat(lVal / maxVal) * usableH)

                let sRect = CGRect(x: centerX - pairW - 0.5, y: size.height - sH - 4, width: pairW, height: sH)
                let lRect = CGRect(x: centerX + 0.5, y: size.height - lH - 4, width: pairW, height: lH)
                let alpha = hoveredIndex == i ? 1.0 : 0.86
                context.fill(Path(roundedRect: sRect, cornerRadius: min(2.5, pairW / 2)), with: .color(color.opacity(alpha)))
                context.fill(Path(roundedRect: lRect, cornerRadius: min(2.5, pairW / 2)), with: .color(thisMacOrange.opacity(alpha)))
            } else {
                let barW = max(2.5, min(28, slotW * 0.66))
                let h = b.value <= 0 ? 2.0 : max(4.0, CGFloat(b.value / maxVal) * usableH)
                let x = CGFloat(i) * slotW + (slotW - barW) / 2.0
                let y = size.height - h - 4
                let rect = CGRect(x: x, y: y, width: barW, height: h)
                let radius = min(3.0, barW / 2.0)
                let fill = b.value <= 0 ? color.opacity(0.14) : (hoveredIndex == i ? color : color.opacity(0.84))
                context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(fill))
            }
        }
    }

    private func drawSeriesCurve(
        in context: inout GraphicsContext,
        size: CGSize,
        values: [Double],
        maxVal: Double,
        color: Color,
        dashed: Bool,
        fillGradient: Bool
    ) {
        let usableH = max(4, size.height - 8)
        let points: [CGPoint] = values.enumerated().map { idx, val in
            let x = xPosition(index: idx, count: values.count, width: size.width, isBar: false)
            let y = size.height - CGFloat(min(1.0, max(0.0, val / maxVal))) * usableH - 4
            return CGPoint(x: x, y: y)
        }
        guard !points.isEmpty else { return }

        if points.count == 1 {
            let p = points[0]
            context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(color))
            return
        }

        let linePath = monotonicSplinePath(points: points, minY: 4, maxY: size.height - 4)

        if fillGradient {
            var areaPath = linePath
            areaPath.addLine(to: CGPoint(x: points.last!.x, y: size.height - 4))
            areaPath.addLine(to: CGPoint(x: points.first!.x, y: size.height - 4))
            areaPath.closeSubpath()

            context.fill(
                areaPath,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.22), color.opacity(0.01)]),
                    startPoint: CGPoint(x: 0, y: 4),
                    endPoint: CGPoint(x: 0, y: size.height - 4)
                )
            )
        }

        let style = StrokeStyle(
            lineWidth: dashed ? 1.65 : 2.0,
            lineCap: .round,
            lineJoin: .round,
            dash: dashed ? [4, 2.5] : []
        )
        context.stroke(linePath, with: .color(color), style: style)

        if points.count <= 32 {
            let halo = LinearUI.cardBg(scheme)
            for p in points {
                let rad: CGFloat = dashed ? 2.2 : 3.0
                let r = CGRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2)
                let ellipse = Path(ellipseIn: r)
                context.stroke(ellipse, with: .color(halo), lineWidth: 1.4)
                context.fill(ellipse, with: .color(color))
            }
        }
    }

    private func monotonicSplinePath(points pts: [CGPoint], minY: CGFloat, maxY: CGFloat) -> Path {
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
            m[k] = (d[k - 1] * d[k] <= 0) ? 0 : (d[k - 1] + d[k]) * 0.5
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

    private func xPosition(index: Int, count: Int, width: CGFloat, isBar: Bool) -> CGFloat {
        guard count > 1 else { return width / 2.0 }
        if isBar {
            let slotW = width / CGFloat(count)
            return CGFloat(index) * slotW + slotW / 2.0
        }
        let pad: CGFloat = 6
        let usable = max(1, width - pad * 2)
        return pad + usable * CGFloat(index) / CGFloat(count - 1)
    }

    private func buildBuckets(metric: TrendMetric) -> [ChartBucket] {
        if range == .today {
            if !hourlyBuckets.isEmpty {
                return hourlyBuckets.map { hb in
                    let synced = metric == .clicks ? Double(hb.syncedClicks) : Double(hb.syncedKeys)
                    let local = metric == .clicks ? Double(hb.localClicks) : Double(hb.localKeys)
                    return ChartBucket(
                        id: hb.id,
                        axisLabel: hb.axisLabel,
                        detailLabel: hb.detailLabel,
                        value: synced,
                        formattedValue: formatMetricValue(synced, metric: metric),
                        localValue: local,
                        formattedLocalValue: formatMetricValue(local, metric: metric)
                    )
                }
            }
            return (0..<24).map { h in
                let raw = metric == .clicks
                    ? Double(h < hourlyClicks.count ? hourlyClicks[h] : 0)
                    : Double(h < hourlyKeys.count ? hourlyKeys[h] : 0)
                return ChartBucket(
                    id: "h\(h)",
                    axisLabel: String(format: "%02d:00", h),
                    detailLabel: String(format: "%02d:00", h),
                    value: raw,
                    formattedValue: formatMetricValue(raw, metric: metric)
                )
            }
        }

        // Aggregate large All-Time spans (> 65 days) into clean weekly buckets so bars and lines remain crisp
        if range == .allTime && dailyTrend.count > 65 {
            var weeks: [ChartBucket] = []
            for start in stride(from: 0, to: dailyTrend.count, by: 7) {
                let slice = dailyTrend[start..<min(start + 7, dailyTrend.count)]
                let sum = slice.reduce(0.0) { $0 + metricValue(for: $1, metric: metric) }
                let label = shortDateLabel(slice.first?.dateKey ?? "")
                let endLabel = shortDateLabel(slice.last?.dateKey ?? "")
                weeks.append(ChartBucket(
                    id: slice.first?.dateKey ?? "\(start)",
                    axisLabel: label,
                    detailLabel: label == endLabel ? label : "\(label)–\(endLabel)",
                    value: sum,
                    formattedValue: formatMetricValue(sum, metric: metric)
                ))
            }
            return weeks
        }

        return dailyTrend.map { day in
            let v = metricValue(for: day, metric: metric)
            let short = shortDateLabel(day.dateKey)
            return ChartBucket(
                id: day.dateKey,
                axisLabel: short,
                detailLabel: day.dateKey,
                value: v,
                formattedValue: formatMetricValue(v, metric: metric)
            )
        }
    }

    private func metricValue(for day: DailyActivityPoint, metric: TrendMetric) -> Double {
        switch metric {
        case .keys: return Double(day.keyPresses)
        case .clicks: return Double(day.clicks)
        case .mouse: return day.mouseDistanceMeters
        case .scroll: return day.scrollDistanceMeters
        }
    }

    private func formatMetricAxis(_ val: Double, metric: TrendMetric) -> String {
        switch metric {
        case .keys, .clicks:
            return formattedInt(Int(val.rounded()))
        case .mouse, .scroll:
            return val >= 1_000 ? String(format: "%.1fkm", val / 1_000.0) : String(format: "%.0fm", val)
        }
    }

    private func formatMetricValue(_ val: Double, metric: TrendMetric) -> String {
        switch metric {
        case .keys: return "\(formattedInt(Int(val.rounded()))) keys"
        case .clicks: return "\(formattedInt(Int(val.rounded()))) clicks"
        case .mouse, .scroll: return KeyStatsAggregateSnapshot.formatDistance(val)
        }
    }

    private func shortDateLabel(_ dateKey: String) -> String {
        let parts = dateKey.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else {
            return dateKey
        }
        return "\(m)/\(d)"
    }
}

// MARK: - Full-Width Sortable App Statistics Table (KeyStats Reference)

private struct AppStatisticsTableCard: View {
    @Environment(\.colorScheme) private var scheme
    let apps: [AppActivitySummary]
    let resolvedIcon: (String) -> NSImage
    var onOpenFullAppStats: (() -> Void)? = nil

    @State private var sortMetric: AppSortMetric = .keys
    @State private var sortAscending: Bool = false
    @State private var showAllApps: Bool = false

    private let keysBlue = LinearUI.accent
    private let clicksGreen = LinearUI.positive
    private let scrollOrange = LinearUI.warning

    var body: some View {
        let sorted = apps.sorted { lhs, rhs in
            let asc = sortAscending
            switch sortMetric {
            case .name:
                let cmp = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                return asc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
            case .keys:
                if lhs.keyPresses != rhs.keyPresses {
                    return asc ? (lhs.keyPresses < rhs.keyPresses) : (lhs.keyPresses > rhs.keyPresses)
                }
            case .clicks:
                if lhs.clicks != rhs.clicks {
                    return asc ? (lhs.clicks < rhs.clicks) : (lhs.clicks > rhs.clicks)
                }
            case .scroll:
                if lhs.scrollMeters != rhs.scrollMeters {
                    return asc ? (lhs.scrollMeters < rhs.scrollMeters) : (lhs.scrollMeters > rhs.scrollMeters)
                }
            }
            return lhs.displayName < rhs.displayName
        }

        let visible = showAllApps ? sorted : Array(sorted.prefix(8))
        let maxKeys = max(1, visible.map(\.keyPresses).max() ?? 1)
        let maxClicks = max(1, visible.map(\.clicks).max() ?? 1)
        let maxScroll = max(1.0, visible.map(\.scrollMeters).max() ?? 1.0)
        let totalKeys = apps.reduce(0) { $0 + $1.keyPresses }
        let totalClicks = apps.reduce(0) { $0 + $1.clicks }
        let totalScroll = apps.reduce(0.0) { $0 + $1.scrollMeters }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                LinearSectionHeader(
                    title: "App Statistics",
                    subtitle: "Total: \(formattedInt(totalKeys)) keys · \(formattedInt(totalClicks)) clicks · \(KeyStatsAggregateSnapshot.formatDistance(totalScroll)) scroll"
                )
                Spacer()
                HStack(spacing: 6) {
                    if let onOpenFullAppStats {
                        LinearActionButton(
                            title: "Full Page ↗",
                            icon: "square.grid.2x2"
                        ) {
                            onOpenFullAppStats()
                        }
                    }
                    if apps.count > 8 {
                        LinearActionButton(
                            title: showAllApps ? "Show Top 8" : "Show All (\(apps.count))",
                            icon: showAllApps ? "chevron.up" : "chevron.down"
                        ) {
                            showAllApps.toggle()
                        }
                    }
                }
            }

            LinearCard {
                HStack(spacing: 10) {
                    sortHeaderButton("App", metric: .name, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    sortHeaderButton("Keys", metric: .keys, alignment: .trailing)
                        .frame(width: 134, alignment: .trailing)
                    sortHeaderButton("Clicks", metric: .clicks, alignment: .trailing)
                        .frame(width: 118, alignment: .trailing)
                    sortHeaderButton("Scroll", metric: .scroll, alignment: .trailing)
                        .frame(width: 116, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(LinearUI.subtleFill(scheme))

                ForEach(Array(visible.enumerated()), id: \.element.id) { _, app in
                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)

                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(nsImage: resolvedIcon(app.bundleID))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(app.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        MetricProgressCell(
                            fraction: Double(app.keyPresses) / Double(maxKeys),
                            color: keysBlue,
                            label: formattedInt(app.keyPresses)
                        )
                        .frame(width: 134)

                        MetricProgressCell(
                            fraction: Double(app.clicks) / Double(maxClicks),
                            color: clicksGreen,
                            label: formattedInt(app.clicks)
                        )
                        .frame(width: 118)

                        MetricProgressCell(
                            fraction: app.scrollMeters / maxScroll,
                            color: scrollOrange,
                            label: app.scrollMeters > 0.05 ? KeyStatsAggregateSnapshot.formatDistance(app.scrollMeters) : "0 m"
                        )
                        .frame(width: 116)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 31)
                }
            }
        }
    }

    @ViewBuilder
    private func sortHeaderButton(_ title: String, metric: AppSortMetric, alignment: Alignment) -> some View {
        let active = (sortMetric == metric)
        let arrow = active ? (sortAscending ? " ↑" : " ↓") : ""
        Button {
            if sortMetric == metric {
                sortAscending.toggle()
            } else {
                sortMetric = metric
                sortAscending = (metric == .name)
            }
        } label: {
            Text(title + arrow)
                .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: alignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MetricProgressCell: View {
    @Environment(\.colorScheme) private var scheme
    let fraction: Double
    let color: Color
    let label: String

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(LinearUI.subtleFill(scheme))
                    if clamped > 0 {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(color.opacity(0.85))
                            .frame(width: max(3, geo.size.width * CGFloat(clamped)))
                    }
                }
            }
            .frame(height: 6)

            Text(label)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(minWidth: 58, alignment: .trailing)
        }
    }
}

// MARK: - Key Breakdown (3x5 Pill Grid) & Shortcuts / Profile

private struct KeyBreakdownCard: View {
    @Environment(\.colorScheme) private var scheme
    let topKeys: [RankedCountItem]

    var body: some View {
        let cols = 3
        let rows = 5
        let items = Array(topKeys.prefix(cols * rows))

        VStack(alignment: .leading, spacing: 6) {
            LinearSectionHeader(
                title: "Key Breakdown",
                subtitle: "Top 15 most pressed keys"
            )

            LinearCard {
                if items.isEmpty {
                    Text("Most used keys appear here as you type.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<cols, id: \.self) { colIdx in
                            if colIdx > 0 {
                                Rectangle()
                                    .fill(LinearUI.hairline(scheme))
                                    .frame(width: 1)
                                    .padding(.vertical, 8)
                            }
                            VStack(spacing: 0) {
                                ForEach(0..<rows, id: \.self) { rowIdx in
                                    let idx = colIdx * rows + rowIdx
                                    if idx < items.count {
                                        let item = items[idx]
                                        HStack(spacing: 5) {
                                            LinearKbd(label: item.label)
                                            Spacer(minLength: 2)
                                            Text(formattedInt(item.count))
                                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                                .monospacedDigit()
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 9)
                                        .frame(height: 28)
                                    } else {
                                        Spacer().frame(height: 28)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct ShortcutsAndProfileCard: View {
    @Environment(\.colorScheme) private var scheme
    let ks: KeyStatsAggregateSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LinearSectionHeader(
                title: "Shortcuts & Input Balance",
                subtitle: "Top key chords, L/R hand ratio & click mix"
            )

            LinearCard {
                VStack(alignment: .leading, spacing: 9) {
                    if ks.topShortcuts.isEmpty {
                        Text("Keyboard shortcuts (⌘C, ⌘V, ⌘W…) appear automatically.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 6) {
                            ForEach(ks.topShortcuts.prefix(6)) { item in
                                HStack(spacing: 5) {
                                    LinearKbd(label: item.label)
                                    Spacer(minLength: 2)
                                    Text(formattedInt(item.count))
                                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)

                    // Left / Right Hand Balance bar
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Left Hand \(ks.leftHandPercent)%")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Right Hand \(100 - ks.leftHandPercent)%")
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 10, weight: .medium))

                        GeometryReader { geo in
                            let leftFrac = CGFloat(min(max(ks.leftHandPercent, 5), 95)) / 100.0
                            HStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(LinearUI.accent.opacity(0.85))
                                    .frame(width: max(4, (geo.size.width - 2) * leftFrac))
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(Color(red: 0.16, green: 0.66, blue: 0.35).opacity(0.75))
                            }
                        }
                        .frame(height: 5)
                    }

                    // Left / Right Click Ratio bar
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Left Click \(ks.leftClickPercent)% (\(formattedInt(ks.leftClicks)))")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Right Click \(100 - ks.leftClickPercent)% (\(formattedInt(ks.rightClicks)))")
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 10, weight: .medium))

                        GeometryReader { geo in
                            let leftClickFrac = CGFloat(min(max(ks.leftClickPercent, 5), 95)) / 100.0
                            HStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(LinearUI.blue.opacity(0.85))
                                    .frame(width: max(4, (geo.size.width - 2) * leftClickFrac))
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(LinearUI.warning.opacity(0.78))
                            }
                        }
                        .frame(height: 5)
                    }

                    HStack(spacing: 12) {
                        Text("Backspaces: \(String(format: "%.1f%%", ks.correctionRatePercent))")
                        Spacer()
                        Text("Avg/day: \(ks.activeDays > 0 ? formattedInt(ks.totalKeyPresses / ks.activeDays) : "0")")
                        if ks.otherClicks > 0 {
                            Text("Side: \(formattedInt(ks.otherClicks))")
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }
}

// MARK: - Top Keys Share Donut & Lifetime Insights Cards

private struct TopKeysDonutCard: View {
    @Environment(\.colorScheme) private var scheme
    let topKeys: [RankedCountItem]
    let totalKeyPresses: Int

    @State private var hoveredSliceIndex: Int? = nil

    private struct Slice: Identifiable {
        let id: String
        let label: String
        let count: Int
        let share: Double
        let startAngle: Double
        let endAngle: Double
        let color: Color
    }

    private let palette: [Color] = [
        LinearUI.accent,
        Color(red: 0.14, green: 0.49, blue: 0.92),
        Color(red: 0.16, green: 0.66, blue: 0.35),
        Color(red: 0.08, green: 0.62, blue: 0.66),
        Color(red: 0.90, green: 0.48, blue: 0.14),
        Color(red: 0.86, green: 0.24, blue: 0.46),
        Color(red: 0.60, green: 0.42, blue: 0.86),
        Color.secondary.opacity(0.45)
    ]

    var body: some View {
        let slices = buildSlices()

        return VStack(alignment: .leading, spacing: 6) {
            LinearSectionHeader(
                title: "Key Share Distribution",
                subtitle: "Top 7 keys share of total strokes"
            )

            LinearCard {
                if slices.isEmpty {
                    Text("Key share distribution populates as you type.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    HStack(spacing: 14) {
                        ZStack {
                            Canvas { context, size in
                                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
                                let outerR = min(size.width, size.height) * 0.46
                                let innerR = outerR * 0.58

                                for (idx, s) in slices.enumerated() {
                                    let isHover = hoveredSliceIndex == idx
                                    let r = isHover ? outerR + 3.0 : outerR
                                    var path = Path()
                                    path.addArc(
                                        center: center,
                                        radius: r,
                                        startAngle: .degrees(s.startAngle),
                                        endAngle: .degrees(s.endAngle),
                                        clockwise: false
                                    )
                                    path.addArc(
                                        center: center,
                                        radius: innerR,
                                        startAngle: .degrees(s.endAngle),
                                        endAngle: .degrees(s.startAngle),
                                        clockwise: true
                                    )
                                    path.closeSubpath()
                                    context.fill(path, with: .color(s.color))
                                }
                            }
                            .frame(width: 114, height: 114)
                            .contentShape(Circle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let loc):
                                    let dx = loc.x - 57
                                    let dy = loc.y - 57
                                    let dist = hypot(dx, dy)
                                    guard dist >= 26 && dist <= 56 else {
                                        hoveredSliceIndex = nil
                                        return
                                    }
                                    var angle = atan2(dy, dx) * 180.0 / .pi
                                    if angle < -90 { angle += 360 }
                                    hoveredSliceIndex = slices.firstIndex { angle >= $0.startAngle && angle <= $0.endAngle }
                                case .ended:
                                    hoveredSliceIndex = nil
                                }
                            }

                            VStack(spacing: 1) {
                                if let hi = hoveredSliceIndex, hi >= 0, hi < slices.count {
                                    let s = slices[hi]
                                    Text(s.label)
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .lineLimit(1)
                                    Text(String(format: "%.1f%%", s.share * 100.0))
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(s.color)
                                } else {
                                    Text("Keys")
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Text(formattedInt(totalKeyPresses))
                                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.58)
                                }
                            }
                            .frame(width: 60)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(slices.enumerated()), id: \.element.id) { idx, s in
                                HStack(spacing: 5) {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(s.color)
                                        .frame(width: 8, height: 8)
                                    Text(s.label)
                                        .font(.system(size: 10.5, weight: hoveredSliceIndex == idx ? .semibold : .medium, design: .rounded))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(String(format: "%.0f%%", s.share * 100.0))
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    hoveredSliceIndex = inside ? idx : (hoveredSliceIndex == idx ? nil : hoveredSliceIndex)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func buildSlices() -> [Slice] {
        let top = Array(topKeys.prefix(7))
        let topSum = top.reduce(0) { $0 + $1.count }
        let total = max(totalKeyPresses, topSum)
        guard total > 0, !top.isEmpty else { return [] }

        var result: [Slice] = []
        var cursor = -90.0
        for (idx, item) in top.enumerated() {
            let share = Double(item.count) / Double(total)
            let span = share * 360.0
            result.append(Slice(
                id: item.id,
                label: item.label,
                count: item.count,
                share: share,
                startAngle: cursor,
                endAngle: cursor + span,
                color: palette[idx % palette.count]
            ))
            cursor += span
        }
        let remainder = max(0, total - topSum)
        if remainder > 0 {
            let share = Double(remainder) / Double(total)
            result.append(Slice(
                id: "other",
                label: "Other",
                count: remainder,
                share: share,
                startAngle: cursor,
                endAngle: 270.0,
                color: palette[7]
            ))
        }
        return result
    }
}

private struct LifetimeInsightsCard: View {
    @Environment(\.colorScheme) private var scheme
    let ks: KeyStatsAggregateSnapshot
    let mouseCalibrationFactor: Double
    var onCalibrateMouse: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                LinearSectionHeader(
                    title: "Activity Insights",
                    subtitle: "Peaks, style & physical distance benchmarks"
                )
                Spacer()
                if let onCalibrateMouse {
                    LinearActionButton(title: String(format: "Mouse %.2f×", mouseCalibrationFactor), icon: "ruler") {
                        onCalibrateMouse()
                    }
                    .help("Calibrate 10 cm mouse travel factor")
                }
            }

            LinearCard {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    insightCell(
                        icon: "sparkles",
                        accent: LinearUI.accent,
                        title: "Productivity Peak",
                        value: ks.peakWeekdayName ?? "—",
                        help: "Day of the week with highest average keys + clicks"
                    )
                    insightCell(
                        icon: "flame.fill",
                        accent: LinearUI.warning,
                        title: "Peak Day",
                        value: ks.maxDailyKeys > 0
                            ? "\(formattedInt(ks.maxDailyKeys)) (\(ks.peakDayDateKey?.suffix(5) ?? ""))"
                            : "—",
                        help: "Single highest keystroke day in this range"
                    )
                    insightCell(
                        icon: "figure.run",
                        accent: LinearUI.blue,
                        title: "Mouse Marathons",
                        value: String(format: "%.2f", ks.marathonsEquivalent),
                        help: "Equivalent to 42.195 km marathons"
                    )
                    insightCell(
                        icon: "mountain.2.fill",
                        accent: LinearUI.positive,
                        title: "Scroll Everests",
                        value: String(format: "%.2f", ks.everestsEquivalent),
                        help: "Equivalent to 8,848.86 m Everest ascents"
                    )
                    insightCell(
                        icon: "hand.tap.fill",
                        accent: Color(red: 0.08, green: 0.62, blue: 0.66),
                        title: "Input Style",
                        value: "\(ks.inputStyleLabel) (\(String(format: "%.1f", ks.keyToClickRatio)):1)",
                        help: "Keys-to-clicks ratio across selected period"
                    )
                    insightCell(
                        icon: "delete.left.fill",
                        accent: Color(red: 0.86, green: 0.24, blue: 0.46),
                        title: "Correction Rate",
                        value: String(format: "%.1f%%", ks.correctionRatePercent),
                        help: "Share of Delete/Backspace keys across keystrokes"
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    private func insightCell(icon: String, accent: Color, title: String, value: String, help: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 22, height: 22)
                .background(accent.opacity(scheme == .dark ? 0.18 : 0.11), in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
        .help(help)
    }
}

// MARK: - 53-Week Activity Calendar Heatmap (KeyStats Reference)

private struct ActivityCalendarCard: View {
    @Environment(\.colorScheme) private var scheme
    let days: [CalendarActivityDay]
    let activeDays: Int
    let maxDailyKeys: Int
    let currentStreak: Int
    let longestStreak: Int
    let theme: HeatmapTheme
    let hasData: Bool
    let onResetToday: () -> Void
    let onClearAll: () -> Void

    @State private var hoveredDay: CalendarActivityDay?
    @State private var showResetPopover: Bool = false

    var body: some View {
        let weeks = stride(from: 0, to: days.count, by: 7).map { start in
            Array(days[start..<min(start + 7, days.count)])
        }
        let maxActions = max(50, days.map(\.totalActions).max() ?? 50)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                LinearSectionHeader(
                    title: "Activity Heatmap",
                    subtitle: "\(activeDays) active days · Streak \(currentStreak)d (Best \(longestStreak)d) · Peak \(formattedInt(maxDailyKeys))/day"
                )
                Spacer()
                if let hovered = hoveredDay {
                    Text("\(hovered.dateKey) · \(formattedInt(hovered.keyPresses)) keys · \(formattedInt(hovered.clicks)) clicks")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.color)
                }
                if hasData {
                    LinearIconButton(
                        symbol: "arrow.counterclockwise",
                        helpText: "Reset Today or All KeyStats History"
                    ) {
                        showResetPopover.toggle()
                    }
                    .popover(isPresented: $showResetPopover, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            LinearPopoverMenuItem(
                                title: "Reset Today (This Mac)…",
                                icon: "clock.arrow.circlepath"
                            ) {
                                showResetPopover = false
                                onResetToday()
                            }
                            Divider().padding(.vertical, 2)
                            LinearPopoverMenuItem(
                                title: "Reset All History…",
                                icon: "trash",
                                isDestructive: true
                            ) {
                                showResetPopover = false
                                onClearAll()
                            }
                        }
                        .padding(6)
                        .frame(width: 215)
                    }
                }
            }

            LinearCard {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        let labelW: CGFloat = 26
                        let spacing: CGFloat = 2.5
                        let availW = max(120, geo.size.width - labelW - 4)
                        let fitWeeks = max(14, min(weeks.count, Int((availW + spacing) / (9.0 + spacing))))
                        let visibleWeeks = Array(weeks.suffix(fitWeeks))
                        let cell = max(7.5, min(11.0, floor((availW - spacing * CGFloat(max(0, visibleWeeks.count - 1))) / CGFloat(max(1, visibleWeeks.count)))))
                        let monthMarkers = computeMonthMarkers(weeks: visibleWeeks)

                        VStack(alignment: .leading, spacing: 3) {
                            // Month headers row
                            ZStack(alignment: .leading) {
                                Color.clear.frame(height: 12)
                                ForEach(monthMarkers, id: \.weekIndex) { marker in
                                    Text(marker.label)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                        .offset(x: labelW + CGFloat(marker.weekIndex) * (cell + spacing))
                                }
                            }

                            HStack(alignment: .top, spacing: 4) {
                                // Weekday row labels (Mon / Wed / Fri)
                                VStack(spacing: spacing) {
                                    ForEach(0..<7, id: \.self) { row in
                                        Text(row == 1 ? "Mon" : (row == 3 ? "Wed" : (row == 5 ? "Fri" : "")))
                                            .font(.system(size: 8.5))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: labelW - 4, height: cell, alignment: .trailing)
                                    }
                                }

                                HStack(alignment: .top, spacing: spacing) {
                                    ForEach(Array(visibleWeeks.enumerated()), id: \.offset) { _, week in
                                        VStack(spacing: spacing) {
                                            ForEach(week) { day in
                                                let ratio = Double(day.totalActions) / Double(maxActions)
                                                let alpha = day.totalActions == 0 ? 0.0 : min(0.95, max(0.22, sqrt(ratio)))
                                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                                    .fill(day.totalActions == 0 ? LinearUI.subtleFill(scheme) : theme.color.opacity(alpha))
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                                                            .stroke(hoveredDay?.id == day.id ? theme.color : Color.clear, lineWidth: 1)
                                                    )
                                                    .frame(width: cell, height: cell)
                                                    .contentShape(Rectangle())
                                                    .onHover { inside in
                                                        if inside {
                                                            hoveredDay = day
                                                        } else if hoveredDay?.id == day.id {
                                                            hoveredDay = nil
                                                        }
                                                    }
                                                    .help("\(day.dateKey): \(formattedInt(day.keyPresses)) keys · \(formattedInt(day.clicks)) clicks")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 102)

                    HStack {
                        Text("Past \(min(53, weeks.count)) weeks")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        HeatScaleLegend(theme: theme)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    private struct MonthMarker {
        let weekIndex: Int
        let label: String
    }

    private func computeMonthMarkers(weeks: [[CalendarActivityDay]]) -> [MonthMarker] {
        let shortMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        var markers: [MonthMarker] = []
        var lastMonth: Int?
        var lastPlacedIndex = -10

        for (wIdx, week) in weeks.enumerated() {
            guard let first = week.first else { continue }
            let parts = first.dateKey.split(separator: "-")
            guard parts.count == 3, let month = Int(parts[1]), month >= 1 && month <= 12 else { continue }
            if month != lastMonth {
                lastMonth = month
                if wIdx - lastPlacedIndex >= 3 {
                    markers.append(MonthMarker(weekIndex: wIdx, label: shortMonths[month - 1]))
                    lastPlacedIndex = wIdx
                }
            }
        }
        return markers
    }
}

private struct HeatScaleLegend: View {
    @Environment(\.colorScheme) private var scheme
    let theme: HeatmapTheme

    var body: some View {
        HStack(spacing: 3.5) {
            Text("Less")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            ForEach([0.0, 0.20, 0.45, 0.72, 1.0], id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(level == 0 ? LinearUI.subtleFill(scheme) : theme.heatColor(forIntensity: level, scheme: scheme))
                    .frame(width: 8, height: 8)
            }
            Text("More")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}

private let sharedDecimalFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = ","
    return f
}()

private func formattedInt(_ value: Int) -> String {
    sharedDecimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
}
