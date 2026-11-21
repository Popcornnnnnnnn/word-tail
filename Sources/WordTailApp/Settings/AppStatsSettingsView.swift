import AppKit
import SwiftUI
import WordTailCore

private enum AppStatsSortMetric {
    case app
    case keys
    case clicks
    case scroll
}

struct AppStatsSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: SettingsViewModel

    @State private var sortMetric: AppStatsSortMetric = .keys
    @State private var sortAscending: Bool = false
    @State private var searchText: String = ""
    @State private var hoveredBundleID: String? = nil

    private var filteredAndSortedApps: [AppActivitySummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [AppActivitySummary]
        if query.isEmpty {
            base = vm.keyStats.topApps
        } else {
            base = vm.keyStats.topApps.filter {
                $0.displayName.localizedCaseInsensitiveContains(query)
                    || $0.bundleID.localizedCaseInsensitiveContains(query)
            }
        }

        return base.sorted { lhs, rhs in
            let asc = sortAscending
            switch sortMetric {
            case .app:
                let cmp = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if cmp != .orderedSame {
                    return asc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                }
            case .keys:
                if lhs.keyPresses != rhs.keyPresses {
                    return asc ? (lhs.keyPresses < rhs.keyPresses) : (lhs.keyPresses > rhs.keyPresses)
                }
            case .clicks:
                if lhs.clicks != rhs.clicks {
                    return asc ? (lhs.clicks < rhs.clicks) : (lhs.clicks > rhs.clicks)
                }
            case .scroll:
                if lhs.scrollPx != rhs.scrollPx {
                    return asc ? (lhs.scrollPx < rhs.scrollPx) : (lhs.scrollPx > rhs.scrollPx)
                }
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    var body: some View {
        let apps = filteredAndSortedApps
        let maxKeys = max(1, apps.map(\.keyPresses).max() ?? 1)
        let maxClicks = max(1, apps.map(\.clicks).max() ?? 1)
        let maxScroll = max(1.0, apps.map(\.scrollPx).max() ?? 1.0)

        let totalKeys = apps.reduce(0) { $0 + $1.keyPresses }
        let totalClicks = apps.reduce(0) { $0 + $1.clicks }
        let totalScrollPx = apps.reduce(0.0) { $0 + $1.scrollPx }
        let isFiltering = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("App Statistics")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)

                    let summaryBase = "\(formattedInteger(totalKeys)) keys · \(formattedInteger(totalClicks)) clicks · \(KeyStatsAggregateSnapshot.formatScrollKPx(totalScrollPx)) scroll"
                    Text(isFiltering ? "\(summaryBase) · \(apps.count)/\(vm.keyStats.topApps.count)" : summaryBase)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if vm.keyStats.deviceCount > 1 {
                    LinearSegmentedChoices(
                        options: [("All Macs", StatsDeviceScope.allDevices), ("This Mac", StatsDeviceScope.thisMac)],
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

                if !vm.isStaticShowcase {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        TextField("Search apps…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(width: 146, height: 26)
                    .background(LinearUI.subtleFill(scheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(LinearUI.controlBorder(scheme), lineWidth: 1)
                    )
                }
            }

            LinearCard {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        sortHeaderButton("App", metric: .app, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        sortHeaderButton("Keys", metric: .keys, alignment: .trailing)
                            .frame(width: 142, alignment: .trailing)

                        sortHeaderButton("Clicks", metric: .clicks, alignment: .trailing)
                            .frame(width: 122, alignment: .trailing)

                        sortHeaderButton("Scroll", metric: .scroll, alignment: .trailing)
                            .frame(width: 144, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(LinearUI.subtleFill(scheme))

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)

                    if apps.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 20))
                                .foregroundStyle(.tertiary)
                            Text(vm.keyStats.topApps.isEmpty ? "No per-app activity recorded for this range yet." : "No matching applications.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else if vm.isStaticShowcase {
                        VStack(spacing: 0) {
                            rowsList(apps: apps, maxKeys: maxKeys, maxClicks: maxClicks, maxScroll: maxScroll)
                        }
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0.0),
                                    .init(color: .black, location: 0.88),
                                    .init(color: .clear, location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    } else {
                        ScrollEdgeFadeContainer(showsIndicators: false, topFadeHeight: 10, bottomFadeHeight: 22) {
                            LazyVStack(spacing: 0) {
                                rowsList(apps: apps, maxKeys: maxKeys, maxClicks: maxClicks, maxScroll: maxScroll)
                            }
                            .padding(.bottom, 8)
                            .animation(
                                .spring(response: 0.36, dampingFraction: 0.86),
                                value: "\(vm.keyStatsRange.rawValue)-\(vm.keyStatsDeviceScope.rawValue)-\(sortMetric)-\(sortAscending)-\(searchText)"
                            )
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func rowsList(
        apps: [AppActivitySummary],
        maxKeys: Int,
        maxClicks: Int,
        maxScroll: Double
    ) -> some View {
        ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
            let isHovered = hoveredBundleID == app.bundleID

            if index > 0 {
                Rectangle()
                    .fill(LinearUI.hairline(scheme))
                    .frame(height: 1)
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(nsImage: vm.resolvedAppIcon(bundleID: app.bundleID))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                    Text(app.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                AppCompactMetricCell(
                    fraction: Double(app.keyPresses) / Double(maxKeys),
                    color: LinearUI.accent,
                    label: formattedInteger(app.keyPresses),
                    labelWidth: 68
                )
                .frame(width: 142)

                AppCompactMetricCell(
                    fraction: Double(app.clicks) / Double(maxClicks),
                    color: LinearUI.positive,
                    label: formattedInteger(app.clicks),
                    labelWidth: 58
                )
                .frame(width: 122)

                AppCompactMetricCell(
                    fraction: app.scrollPx / maxScroll,
                    color: LinearUI.warning,
                    label: KeyStatsAggregateSnapshot.formatScrollKPx(app.scrollPx),
                    labelWidth: 76
                )
                .frame(width: 144)
            }
            .padding(.horizontal, 12)
            .frame(height: 29)
            .background(isHovered ? LinearUI.hoverFill(scheme) : Color.clear)
            .contentShape(Rectangle())
            .onHover { inside in
                hoveredBundleID = inside ? app.bundleID : (hoveredBundleID == app.bundleID ? nil : hoveredBundleID)
            }
        }
    }

    private func sortHeaderButton(
        _ title: String,
        metric: AppStatsSortMetric,
        alignment: Alignment
    ) -> some View {
        let active = (sortMetric == metric)
        let arrow = active ? (sortAscending ? " ↑" : " ↓") : ""

        return Button {
            if sortMetric == metric {
                sortAscending.toggle()
            } else {
                sortMetric = metric
                sortAscending = (metric == .app)
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

    private func formattedInteger(_ value: Int) -> String {
        Self.decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let decimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()
}

// MARK: - Compact Linear Metric Cell

private struct AppCompactMetricCell: View {
    @Environment(\.colorScheme) private var scheme
    let fraction: Double
    let color: Color
    let label: String
    let labelWidth: CGFloat

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        HStack(spacing: 7) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(LinearUI.subtleFill(scheme))
                    if clamped > 0 {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(color.opacity(0.84))
                            .frame(width: max(3, geo.size.width * CGFloat(clamped)))
                    }
                }
            }
            .frame(height: 5)

            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: labelWidth, alignment: .trailing)
        }
    }
}
