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

    private var systemBlue: Color { Color(nsColor: .systemBlue) }
    private let clicksGreen = Color(red: 0.16, green: 0.78, blue: 0.34)
    private let scrollOrange = Color(red: 0.98, green: 0.54, blue: 0.11)

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

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("App Statistics")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.primary)
                Text("Counts keys, clicks, and scroll by app. No content is recorded.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
            }

            HStack(spacing: 10) {
                AppStatsBlueSegmentedBar(
                    options: [
                        ("Today", StatsTimeRange.today),
                        ("Last 7 Days", StatsTimeRange.days7),
                        ("Last 30 Days", StatsTimeRange.days30),
                        ("All Time", StatsTimeRange.allTime)
                    ],
                    selection: $vm.keyStatsRange,
                    activeBlue: systemBlue
                )

                Spacer(minLength: 6)

                if vm.keyStats.deviceCount > 1 {
                    LinearSegmentedChoices(
                        options: [("All Macs", StatsDeviceScope.allDevices), ("This Mac", StatsDeviceScope.thisMac)],
                        selection: $vm.keyStatsDeviceScope
                    )
                }

                if !vm.isStaticShowcase {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary)
                        TextField("Search apps…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(width: 148, height: 26)
                    .background(LinearUI.subtleFill(scheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(LinearUI.hairline(scheme), lineWidth: 1)
                    )
                }
            }

            HStack(spacing: 6) {
                Text("Total: \(formattedInteger(totalKeys)) keys | \(formattedInteger(totalClicks)) clicks | \(KeyStatsAggregateSnapshot.formatScrollKPx(totalScrollPx)) scroll")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)

                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("(\(apps.count) of \(vm.keyStats.topApps.count) apps)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.secondary)
                }
            }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    sortHeaderButton("App", metric: .app, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)

                    columnDivider

                    sortHeaderButton("Keys", metric: .keys, alignment: .center)
                        .frame(width: 162, alignment: .center)

                    columnDivider

                    sortHeaderButton("Clicks", metric: .clicks, alignment: .center)
                        .frame(width: 152, alignment: .center)

                    columnDivider

                    sortHeaderButton("Scroll", metric: .scroll, alignment: .center)
                        .frame(width: 166, alignment: .center)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)

                Rectangle()
                    .fill(LinearUI.hairline(scheme))
                    .frame(height: 0.75)

                if apps.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                        Text(vm.keyStats.topApps.isEmpty ? "No per-app activity recorded for this range yet." : "No matching applications.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 36)
                } else if vm.isStaticShowcase {
                    VStack(spacing: 2) {
                        rowsList(apps: apps, maxKeys: maxKeys, maxClicks: maxClicks, maxScroll: maxScroll)
                    }
                    .padding(.top, 4)
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
                    ScrollEdgeFadeContainer(showsIndicators: true, topFadeHeight: 14, bottomFadeHeight: 28) {
                        LazyVStack(spacing: 2) {
                            rowsList(apps: apps, maxKeys: maxKeys, maxClicks: maxClicks, maxScroll: maxScroll)
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 12)
                        .animation(
                            .spring(response: 0.36, dampingFraction: 0.86),
                            value: "\(vm.keyStatsRange.rawValue)-\(vm.keyStatsDeviceScope.rawValue)-\(sortMetric)-\(sortAscending)-\(searchText)"
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            let evenRow = (index % 2 == 0)
            let rowBg: Color = {
                if isHovered {
                    return Color.primary.opacity(scheme == .dark ? 0.095 : 0.065)
                }
                if evenRow {
                    return Color.primary.opacity(scheme == .dark ? 0.055 : 0.038)
                }
                return Color.clear
            }()

            HStack(spacing: 8) {
                HStack(spacing: 9) {
                    Image(nsImage: vm.resolvedAppIcon(bundleID: app.bundleID))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(app.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)

                // Invisible 0.5pt spacer to keep column geometry aligned with headers
                Spacer().frame(width: 0.5)

                AppMetricSmartBar(
                    hasValue: app.keyPresses > 0,
                    fraction: Double(app.keyPresses) / Double(maxKeys),
                    color: systemBlue,
                    text: formattedInteger(app.keyPresses),
                    trackWidth: 150
                )
                .frame(width: 162, alignment: .leading)

                Spacer().frame(width: 0.5)

                AppMetricSmartBar(
                    hasValue: app.clicks > 0,
                    fraction: Double(app.clicks) / Double(maxClicks),
                    color: clicksGreen,
                    text: formattedInteger(app.clicks),
                    trackWidth: 140
                )
                .frame(width: 152, alignment: .leading)

                Spacer().frame(width: 0.5)

                AppMetricSmartBar(
                    hasValue: app.scrollPx > 0.5,
                    fraction: app.scrollPx / maxScroll,
                    color: scrollOrange,
                    text: KeyStatsAggregateSnapshot.formatScrollKPx(app.scrollPx),
                    trackWidth: 154
                )
                .frame(width: 166, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowBg)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hoveredBundleID = inside ? app.bundleID : (hoveredBundleID == app.bundleID ? nil : hoveredBundleID)
            }
        }
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(scheme == .dark ? 0.14 : 0.10))
            .frame(width: 0.5, height: 15)
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
                .font(.system(size: 12, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Color.primary : Color.secondary)
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

// MARK: - Smart Inside/Outside Metric Bar

private struct AppMetricSmartBar: View {
    let hasValue: Bool
    let fraction: Double
    let color: Color
    let text: String
    let trackWidth: CGFloat

    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)

    var body: some View {
        let measuredW = ceil(NSAttributedString(string: text, attributes: [.font: Self.labelFont]).size().width)
        let rawBarW: CGFloat = hasValue ? max(4.0, trackWidth * CGFloat(max(0.0, min(1.0, fraction)))) : 0
        let fitsInside = hasValue && (rawBarW >= measuredW + 14.0 || (rawBarW + 7.0 + measuredW > trackWidth))

        ZStack(alignment: .leading) {
            if !hasValue {
                Text(text)
                    .font(.system(size: 11.5, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
            } else if fitsInside {
                let barW = min(trackWidth, max(rawBarW, measuredW + 14.0))
                ZStack(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(color)
                        .frame(width: barW, height: 22)
                    Text(text)
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                        .padding(.trailing, 7)
                }
            } else {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: min(6, rawBarW * 0.5), style: .continuous)
                        .fill(color)
                        .frame(width: rawBarW, height: 22)
                    Text(text)
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(width: trackWidth + 12, height: 22, alignment: .leading)
    }
}

// MARK: - Range Segmented Pill

private struct AppStatsBlueSegmentedBar<Option: Hashable>: View {
    @Environment(\.colorScheme) private var scheme
    let options: [(label: String, value: Option)]
    @Binding var selection: Option
    let activeBlue: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, item in
                let active = (item.value == selection)
                let prevActive = index > 0 && (options[index - 1].value == selection)
                let sepOpacity: Double = (active || prevActive) ? 0.0 : (scheme == .dark ? 0.18 : 0.13)

                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(sepOpacity))
                        .frame(width: 0.5, height: 13)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        selection = item.value
                    }
                } label: {
                    Text(item.label)
                        .font(.system(size: 12, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? Color.white : Color.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 13)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(active ? activeBlue : Color.clear)
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
