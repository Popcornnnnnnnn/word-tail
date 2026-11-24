import AppKit
import SwiftUI
import WordTailCore

public enum WrappedPosterAspect: String, CaseIterable, Identifiable, Sendable {
    case portrait3x4 = "3:4 Poster"
    case landscape16x9 = "16:9 Widescreen"

    public var id: String { rawValue }

    var pointSize: CGSize {
        switch self {
        case .portrait3x4: CGSize(width: 600, height: 800)
        case .landscape16x9: CGSize(width: 600, height: 337.5)
        }
    }
}

struct WrappedPosterView: View {
    @Environment(\.colorScheme) private var scheme
    let summary: TypingWrappedSummary
    let aspect: WrappedPosterAspect

    private var isPortrait: Bool { aspect == .portrait3x4 }
    private var gap: CGFloat { isPortrait ? 16 : 8 }
    private var inset: CGFloat { isPortrait ? 32 : 18 }

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            header
            heroStats
            HStack(spacing: gap) {
                shareBar("Roman", summary.romanSharePercent, "CJK", summary.cjkSharePercent)
                shareBar("Left hand", summary.leftHandPercent, "Right hand", summary.rightHandPercent)
            }
            HStack(spacing: gap) {
                distance("Mouse Marathons", meters: summary.mouseDistanceMeters, equivalent: summary.marathonsEquivalent)
                distance("Scroll Everests", meters: summary.scrollDistanceMeters, equivalent: summary.everestsEquivalent)
            }
            rankedLists
        }
        .padding(inset)
        .frame(width: aspect.pointSize.width, height: aspect.pointSize.height)
        .background {
            LinearGradient(
                colors: [LinearUI.accent.opacity(scheme == .dark ? 0.22 : 0.10), LinearUI.windowBg(scheme)],
                startPoint: .topLeading,
                endPoint: .center
            )
            .background(LinearUI.windowBg(scheme))
        }
    }

    @MainActor
    static func renderPNG(
        summary: TypingWrappedSummary,
        aspect: WrappedPosterAspect,
        colorScheme: ColorScheme
    ) -> Data? {
        let renderer = ImageRenderer(content: WrappedPosterView(summary: summary, aspect: aspect)
            .environment(\.colorScheme, colorScheme))
        renderer.proposedSize = ProposedViewSize(aspect.pointSize)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: isPortrait ? 7 : 4) {
            Text("WORDTAIL TYPING WRAPPED · ZERO-LLM LOCAL STUDIO")
                .font(.system(size: isPortrait ? 12 : 9, weight: .bold, design: .monospaced))
                .tracking(isPortrait ? 1.25 : 0.9)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline) {
                Text("KeyStats · \(summary.rangeLabel)")
                    .font(.system(size: isPortrait ? 42 : 26, weight: .bold))
                Spacer()
                LinearKbd(label: summary.generatedAt.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    private var heroStats: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: gap), count: isPortrait ? 2 : 4)
        return LazyVGrid(columns: columns, spacing: gap) {
            statistic("Keystrokes", summary.totalKeystrokes.formatted(), highlighted: true)
            statistic("Characters saved", summary.charactersSaved.formatted())
            statistic("Tabs accepted", summary.tabsAccepted.formatted())
            statistic("Avg. burst WPM", summary.averageBurstWPM.formatted())
        }
    }

    private func statistic(_ label: String, _ value: String, highlighted: Bool = false) -> some View {
        panel(height: isPortrait ? 88 : 54) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: isPortrait ? 36 : 22, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(highlighted ? LinearUI.accent : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(label)
                    .font(.system(size: isPortrait ? 13 : 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func shareBar(_ leadingLabel: String, _ leading: Double, _ trailingLabel: String, _ trailing: Double) -> some View {
        panel(height: isPortrait ? 64 : 43) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(leadingLabel) \(percent(leading))")
                    Spacer(minLength: 4)
                    Text("\(trailingLabel) \(percent(trailing))")
                }
                .font(.system(size: isPortrait ? 12 : 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)

                GeometryReader { geometry in
                    let filled = leading + trailing > 0
                    let fraction = CGFloat(min(max(leading / 100, 0), 1))
                    ZStack(alignment: .leading) {
                        Rectangle().fill(filled ? LinearUI.positive : LinearUI.subtleFill(scheme))
                        Rectangle().fill(LinearUI.accent).frame(width: geometry.size.width * fraction)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: isPortrait ? 7 : 5)
                .accessibilityHidden(true)
            }
        }
    }

    private func distance(_ title: String, meters: Double, equivalent: Double) -> some View {
        panel(height: isPortrait ? 66 : 48) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: isPortrait ? 13 : 10, weight: .semibold))
                Text("\(equivalent.formatted(.number.precision(.fractionLength(2))))× · \(KeyStatsAggregateSnapshot.formatDistance(meters))")
                    .font(.system(size: isPortrait ? 16 : 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }

    private var rankedLists: some View {
        let layout = isPortrait ? AnyLayout(VStackLayout(spacing: gap)) : AnyLayout(HStackLayout(spacing: gap))
        return layout {
            rankedList("Top Apps", isEmpty: summary.topApps.isEmpty, emptyText: "No app activity") {
                ForEach(summary.topApps.prefix(isPortrait ? 4 : 3)) { app in
                    rankedRow(app.displayName, value: "\((app.keyPresses + app.clicks).formatted()) actions")
                }
            }
            rankedList("Top Typo Traps Rescued", isEmpty: summary.topTypoTraps.isEmpty, emptyText: "No typo traps recorded") {
                ForEach(summary.topTypoTraps.prefix(isPortrait ? 4 : 3)) { trap in
                    rankedRow("\(trap.commonMistype) → \(trap.word)", value: "\(trap.count.formatted())×")
                }
            }
        }
    }

    private func rankedList<Rows: View>(
        _ title: String,
        isEmpty: Bool,
        emptyText: String,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        panel(height: isPortrait ? 116 : 80, alignment: .topLeading) {
            VStack(alignment: .leading, spacing: isPortrait ? 4 : 3) {
                Text(title)
                    .font(.system(size: isPortrait ? 14 : 11, weight: .semibold))
                if isEmpty {
                    Text(emptyText)
                        .font(.system(size: isPortrait ? 12 : 10))
                        .foregroundStyle(.secondary)
                } else {
                    rows()
                }
            }
        }
    }

    private func rankedRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .font(.system(size: isPortrait ? 12 : 10))
    }

    private func panel<Content: View>(
        height: CGFloat,
        alignment: Alignment = .leading,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(isPortrait ? 12 : 8)
            .frame(maxWidth: .infinity, alignment: alignment)
            .frame(height: height, alignment: alignment)
            .background(LinearUI.cardBg(scheme), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(LinearUI.hairline(scheme))
            }
    }

    private func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0...1)))
    }
}
