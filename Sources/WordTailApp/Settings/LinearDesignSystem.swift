import AppKit
import SwiftUI

enum LinearUI {
    static let accent = Color(red: 0.37, green: 0.42, blue: 0.89) // Linear Indigo (#5E6AD2)
    static let blue = Color(red: 0.25, green: 0.48, blue: 0.90)
    static let positive = Color(red: 0.17, green: 0.65, blue: 0.42)
    static let warning = Color(red: 0.86, green: 0.50, blue: 0.17)

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
        .shadow(color: scheme == .dark ? .clear : .black.opacity(0.025), radius: 1, x: 0, y: 0.5)
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
    var step: Double = 0.05

    @State private var isDragging: Bool = false
    @State private var dragRejected: Bool = false

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
                    .scaleEffect(isDragging ? 1.12 : 1.0)
                    .offset(x: thumbX - 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { drag in
                        if dragRejected { return }
                        if !isDragging {
                            let dx = abs(drag.translation.width)
                            let dy = abs(drag.translation.height)
                            if dy > dx * 1.2 {
                                dragRejected = true
                                return
                            }
                            isDragging = true
                        }
                        let frac = min(max(drag.location.x / w, 0), 1)
                        let raw = range.lowerBound + frac * span
                        let snapped = step > 0 ? (raw / step).rounded() * step : raw
                        let clamped = min(max(snapped, range.lowerBound), range.upperBound)
                        let cleaned = (clamped * 100.0).rounded() / 100.0
                        let next = cleaned == 0 ? 0.0 : cleaned
                        if abs(value - next) > 1e-6 {
                            value = next
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragRejected = false
                    }
            )
        }
        .frame(height: 18)
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
            .shadow(color: scheme == .dark ? .clear : .black.opacity(0.025), radius: 1, x: 0, y: 0.5)
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
                .tracking(-0.3)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(subtitle)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LinearUI.cardBg(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(LinearUI.hairline(scheme), lineWidth: 1)
        )
        .shadow(color: scheme == .dark ? .clear : .black.opacity(0.025), radius: 1, x: 0, y: 0.5)
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
        let fillColor: Color = {
            if isSelected {
                return scheme == .dark ? LinearUI.hoverFill(scheme) : LinearUI.cardBg(scheme)
            }
            return hovered ? LinearUI.subtleFill(scheme) : Color.clear
        }()

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
            .background(fillColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? LinearUI.hairline(scheme) : Color.clear, lineWidth: 1)
            )
            .shadow(
                color: (isSelected && scheme == .light) ? .black.opacity(0.035) : .clear,
                radius: 1,
                x: 0,
                y: 0.5
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

struct LinearPopoverMenuItem: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var icon: String? = nil
    var nsImage: NSImage? = nil
    var detail: String? = nil
    var isSelected: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        let fg: Color = {
            if isDestructive { return Color(red: 0.85, green: 0.26, blue: 0.24) }
            if isSelected { return LinearUI.accent }
            return .primary
        }()

        Button(action: action) {
            HStack(spacing: 8) {
                if let nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(isDestructive ? fg : (isSelected ? LinearUI.accent : .secondary))
                        .frame(width: 16)
                }

                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(fg)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LinearUI.accent)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                (hovered || isSelected) ? LinearUI.subtleFill(scheme) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
