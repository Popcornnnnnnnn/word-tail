import AppKit
import SwiftUI

enum LinearUI {
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

struct LinearCard<Content: View>: View {
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

struct LinearSectionHeader: View {
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

struct LinearKbd: View {
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

struct LinearSwitch: View {
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

struct LinearSlider: View {
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

struct LinearOffsetStepper: View {
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

struct LinearActionButton: View {
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

private struct ScrollFadeOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollFadeContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Softly fades the top and bottom edges of a scroll view only while clipped content extends beyond them.
struct ScrollEdgeFadeContainer<Content: View>: View {
    var showsIndicators: Bool = true
    var topFadeHeight: CGFloat = 16
    var bottomFadeHeight: CGFloat = 26
    @ViewBuilder let content: () -> Content

    @State private var topOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        let topFadeOpacity = min(1.0, max(0.0, topOffset / 14.0))
        let remaining = contentHeight - (topOffset + viewportHeight)
        let bottomFadeOpacity = contentHeight > viewportHeight + 4
            ? min(1.0, max(0.0, remaining / 16.0))
            : 0.0
        let topStop = viewportHeight > 0 ? min(0.20, topFadeHeight / viewportHeight) : 0.001
        let bottomStop = viewportHeight > 0 ? max(topStop + 0.01, min(0.999, 1.0 - bottomFadeHeight / viewportHeight)) : 0.999

        GeometryReader { outer in
            ScrollView(.vertical, showsIndicators: showsIndicators) {
                content()
                    .background(
                        GeometryReader { inner in
                            Color.clear
                                .preference(
                                    key: ScrollFadeOffsetKey.self,
                                    value: max(0, -inner.frame(in: .named("ScrollEdgeFadeSpace")).minY)
                                )
                                .preference(
                                    key: ScrollFadeContentHeightKey.self,
                                    value: inner.size.height
                                )
                        }
                    )
            }
            .coordinateSpace(name: "ScrollEdgeFadeSpace")
            .onPreferenceChange(ScrollFadeOffsetKey.self) { val in
                if abs(val - topOffset) > 0.5 { topOffset = val }
            }
            .onPreferenceChange(ScrollFadeContentHeightKey.self) { val in
                if abs(val - contentHeight) > 0.5 { contentHeight = val }
            }
            .onAppear {
                viewportHeight = outer.size.height
            }
            .onChange(of: outer.size.height) { _, newVal in
                viewportHeight = newVal
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(1.0 - topFadeOpacity), location: 0.0),
                        .init(color: .black, location: max(0.001, topStop)),
                        .init(color: .black, location: min(0.999, bottomStop)),
                        .init(color: .black.opacity(1.0 - bottomFadeOpacity), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }
}

struct LinearSegmentedChoices<T: Hashable>: View {
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

struct LinearIconButton: View {
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

struct LinearMetricTile: View {
    @Environment(\.colorScheme) private var scheme
    let label: String
    let value: String
    let subtitle: String
    var icon: String? = nil
    var accentColor: Color = LinearUI.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 20, height: 20)
                        .background(accentColor.opacity(scheme == .dark ? 0.16 : 0.11), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                Text(label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LinearUI.cardBg(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(LinearUI.hairline(scheme), lineWidth: 1)
        )
    }
}

struct SidebarRow: View {
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
