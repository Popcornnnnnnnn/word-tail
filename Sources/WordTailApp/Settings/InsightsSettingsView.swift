import SwiftUI
import WordTailCore

struct InsightsSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
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

            HStack(alignment: .top, spacing: 10) {
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
