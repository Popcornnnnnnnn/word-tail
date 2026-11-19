import AppKit
import CoreText
import WordTailCore

enum GhostDisplayMode: Equatable {
    case inlineSuffix(String)
    case inlineTypoFix(String) // e.g. " → definitely"
    case floatingPillAbove(prefix: String, fullWord: String, isTypoFix: Bool)
}

final class GhostTextView: NSView {
    var mode: GhostDisplayMode = .inlineSuffix("") {
        didSet { needsDisplay = true }
    }
    var font: NSFont = .systemFont(ofSize: 15) {
        didSet { needsDisplay = true }
    }
    var baselineYInView: CGFloat = 6 {
        didSet { needsDisplay = true }
    }
    var anchorXInView: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    var ghostOpacity: CGFloat = 0.38 {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        switch mode {
        case .inlineSuffix(let suffix):
            guard !suffix.isEmpty else { return }
            let color = NSColor.labelColor.withAlphaComponent(ghostOpacity)
            drawSubpixelBaselineText(suffix, color: color, in: ctx)

        case .inlineTypoFix(let correctedWord):
            guard !correctedWord.isEmpty else { return }
            let accent = NSColor(red: 0.37, green: 0.42, blue: 0.89, alpha: min(0.88, ghostOpacity + 0.34))
            drawSubpixelBaselineText(" → \(correctedWord)", color: accent, in: ctx)

        case .floatingPillAbove(let prefix, let fullWord, let isTypoFix):
            drawFloatingPill(prefix: prefix, fullWord: fullWord, isTypoFix: isTypoFix)
        }
    }

    private func drawFloatingPill(prefix: String, fullWord: String, isTypoFix: Bool) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDark
            ? NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.96)
            : NSColor(calibratedRed: 0.99, green: 0.99, blue: 1.0, alpha: 0.97)
        let borderColor = isDark
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.13)
        let indigo = NSColor(red: 0.37, green: 0.42, blue: 0.89, alpha: 1.0)

        let pillRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: pillRect, xRadius: 5.5, yRadius: 5.5)
        bgColor.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = 1.0
        path.stroke()

        let attr = Self.makePillAttributedString(
            prefix: prefix,
            fullWord: fullWord,
            isTypoFix: isTypoFix,
            isDark: isDark,
            accentColor: indigo
        )
        let textSize = attr.size()
        let textPoint = NSPoint(
            x: pillRect.minX + 7.5,
            y: pillRect.midY - textSize.height / 2.0
        )
        attr.draw(at: textPoint)
    }

    static func makePillAttributedString(
        prefix: String,
        fullWord: String,
        isTypoFix: Bool,
        isDark: Bool,
        accentColor: NSColor
    ) -> NSAttributedString {
        let regularFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        let boldFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let kbdFont = NSFont.systemFont(ofSize: 10.0, weight: .medium)

        let muted = isDark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.48)
        let subtle = isDark ? NSColor.white.withAlphaComponent(0.38) : NSColor.black.withAlphaComponent(0.35)

        let out = NSMutableAttributedString()
        if isTypoFix || !fullWord.lowercased().hasPrefix(prefix.lowercased()) {
            out.append(NSAttributedString(string: "→ ", attributes: [.font: regularFont, .foregroundColor: muted]))
            out.append(NSAttributedString(string: fullWord, attributes: [.font: boldFont, .foregroundColor: accentColor]))
        } else {
            let tail = String(fullWord.dropFirst(prefix.count))
            out.append(NSAttributedString(string: prefix, attributes: [.font: regularFont, .foregroundColor: muted]))
            out.append(NSAttributedString(string: tail, attributes: [.font: boldFont, .foregroundColor: accentColor]))
        }
        out.append(NSAttributedString(string: "  ⇥", attributes: [.font: kbdFont, .foregroundColor: subtle]))
        return out
    }

    private func drawSubpixelBaselineText(_ text: String, color: NSColor, in ctx: CGContext) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let snappedY = (baselineYInView * scale).rounded() / scale
        let subpixelDeltaY = baselineYInView - snappedY

        let attrStr = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color
            ]
        )
        let line = CTLineCreateWithAttributedString(attrStr)

        if abs(subpixelDeltaY) < 0.02 {
            ctx.saveGState()
            ctx.setShouldSmoothFonts(true)
            ctx.setAllowsFontSubpixelPositioning(true)
            ctx.setShouldSubpixelPositionFonts(true)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: anchorXInView, y: snappedY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
            return
        }

        let pxW = max(1, Int(ceil(bounds.width * scale)))
        let pxH = max(1, Int(ceil(bounds.height * scale)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let offscreen = CGContext(
                  data: nil,
                  width: pxW,
                  height: pxH,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return
        }

        offscreen.scaleBy(x: scale, y: scale)
        offscreen.setShouldSmoothFonts(true)
        offscreen.setAllowsFontSubpixelPositioning(true)
        offscreen.setShouldSubpixelPositionFonts(true)
        offscreen.textMatrix = .identity
        offscreen.textPosition = CGPoint(x: anchorXInView, y: snappedY)
        CTLineDraw(line, offscreen)

        guard let cgImg = offscreen.makeImage() else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(
            cgImg,
            in: CGRect(
                x: 0,
                y: subpixelDeltaY,
                width: CGFloat(pxW) / scale,
                height: CGFloat(pxH) / scale
            )
        )
        ctx.restoreGState()
    }
}

final class GhostOverlayWindow {
    private let panel: NSPanel
    private let ghostView: GhostTextView

    private(set) var currentMatch: CompletionMatch?

    var isVisible: Bool {
        panel.isVisible && currentMatch != nil
    }

    init() {
        ghostView = GhostTextView(frame: .zero)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 24),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = ghostView
    }

    func show(
        match: CompletionMatch,
        placement: BaselinePlacement,
        rawAXRect: CGRect,
        primaryScreenHeight: CGFloat,
        hasTextAfterOnLine: Bool,
        font: NSFont,
        opacity: CGFloat = 0.38
    ) {
        currentMatch = match
        ghostView.font = font
        ghostView.ghostOpacity = opacity

        // Mid-sentence insertion: float a crisp Linear micro-pill just above the caret so zero existing words are covered!
        if hasTextAfterOnLine {
            panel.hasShadow = true
            let mode = GhostDisplayMode.floatingPillAbove(
                prefix: match.prefix,
                fullWord: match.fullWord,
                isTypoFix: match.isTypoCorrection
            )
            ghostView.mode = mode

            let sampleAttr = GhostTextView.makePillAttributedString(
                prefix: match.prefix,
                fullWord: match.fullWord,
                isTypoFix: match.isTypoCorrection,
                isDark: false,
                accentColor: .systemBlue
            )
            let pillW = ceil(sampleAttr.size().width) + 18.0
            let pillH: CGFloat = 24.0

            let lineTopCocoaY = primaryScreenHeight - rawAXRect.origin.y
            let lineBottomCocoaY = primaryScreenHeight - (rawAXRect.origin.y + rawAXRect.height)
            let screenTop = NSScreen.screens.first(where: {
                $0.frame.contains(NSPoint(x: placement.anchorX, y: lineTopCocoaY))
            })?.visibleFrame.maxY ?? primaryScreenHeight

            var pillOriginY = floor(lineTopCocoaY + 3.0)
            if pillOriginY + pillH > screenTop - 4.0 {
                pillOriginY = floor(lineBottomCocoaY - pillH - 3.0)
            }
            let pillOriginX = floor(max(4.0, placement.anchorX - 6.0))

            let frame = NSRect(x: pillOriginX, y: pillOriginY, width: pillW, height: pillH)
            ghostView.frame = NSRect(origin: .zero, size: frame.size)
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            return
        }

        panel.hasShadow = false
        let displayText: String
        if match.isTypoCorrection {
            displayText = " → \(match.fullWord)"
            ghostView.mode = .inlineTypoFix(match.fullWord)
        } else {
            displayText = match.suffix
            ghostView.mode = .inlineSuffix(match.suffix)
        }

        let attrStr = NSAttributedString(string: displayText, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attrStr)
        let typographicWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))

        let descenderPad = ceil(max(-font.descender, 4.0)) + 6.0
        let ascenderPad = ceil(max(font.ascender, 12.0)) + 7.0
        let width = ceil(typographicWidth) + 10.0
        let height = descenderPad + ascenderPad

        let exactPanelX = placement.anchorX
        let exactPanelY = placement.baselineY - descenderPad
        let intPanelX = floor(exactPanelX)
        let intPanelY = floor(exactPanelY)

        ghostView.anchorXInView = exactPanelX - intPanelX
        ghostView.baselineYInView = descenderPad + (exactPanelY - intPanelY)

        let frame = NSRect(x: intPanelX, y: intPanelY, width: width, height: height)
        ghostView.frame = NSRect(origin: .zero, size: frame.size)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        currentMatch = nil
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }
}
