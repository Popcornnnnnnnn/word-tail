import SwiftUI
import WordTailCore

struct KeyStatsSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
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

            VStack(alignment: .leading, spacing: 6) {
                ANSIKeyboardHeatmapView(
                    heatmap: ks.keyHeatmap,
                    totalKeys: ks.totalKeyPresses,
                    englishPercent: ks.englishKeyPercent
                )
            }

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
