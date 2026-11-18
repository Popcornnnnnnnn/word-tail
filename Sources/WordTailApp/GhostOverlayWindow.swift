import AppKit
import CoreText
import WordTailCore

final class GhostTextView: NSView {
    var suffix: String = "" {
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
        guard !suffix.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        // CoreText quantizes vertical textPosition to physical pixels (1/scale = 0.5pt on 2x Retina).
        // Snap CoreText baseline to an exact Retina pixel for crisp stems, then shift by the sub-Retina remainder via high-quality CGImage interpolation!
        let snappedY = (baselineYInView * scale).rounded() / scale
        let subpixelDeltaY = baselineYInView - snappedY

        let attrStr = NSAttributedString(
            string: suffix,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(ghostOpacity)
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

    private(set) var currentSuffix: String?
    private(set) var currentFullWord: String?

    var isVisible: Bool {
        panel.isVisible && currentSuffix != nil
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
        suffix: String,
        fullWord: String,
        placement: BaselinePlacement,
        font: NSFont,
        opacity: CGFloat = 0.38
    ) {
        currentSuffix = suffix
        currentFullWord = fullWord
        ghostView.font = font
        ghostView.ghostOpacity = opacity
        ghostView.suffix = suffix

        let attrStr = NSAttributedString(string: suffix, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attrStr)
        let typographicWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))

        let descenderPad = ceil(max(-font.descender, 4.0)) + 6.0
        let ascenderPad = ceil(max(font.ascender, 12.0)) + 7.0
        let width = ceil(typographicWidth) + 8.0
        let height = descenderPad + ascenderPad

        let exactPanelX = placement.anchorX
        let exactPanelY = placement.baselineY - descenderPad
        let intPanelX = floor(exactPanelX)
        let intPanelY = floor(exactPanelY)

        ghostView.anchorXInView = exactPanelX - intPanelX
        ghostView.baselineYInView = descenderPad + (exactPanelY - intPanelY)

        let frame = NSRect(
            x: intPanelX,
            y: intPanelY,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
        ghostView.needsDisplay = true
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        currentSuffix = nil
        currentFullWord = nil
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }
}
