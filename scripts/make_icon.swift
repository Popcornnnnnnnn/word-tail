import AppKit

let outIconset = CommandLine.arguments[1]
try? FileManager.default.removeItem(atPath: outIconset)
try FileManager.default.createDirectory(atPath: outIconset, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    let s = CGFloat(pixelSize)
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS squircle inset (~10% margin)
    let pad = s * 0.095
    let rect = NSRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let radius = rect.width * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Subtle dark slate gradient background
    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.21, alpha: 1.0),
        NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.13, alpha: 1.0)
    ])!
    grad.draw(in: path, angle: -90)

    // Subtle top inner rim highlight
    NSColor(calibratedWhite: 1.0, alpha: 0.12).setStroke()
    path.lineWidth = max(1.0, s * 0.012)
    path.stroke()

    // Draw "kn" (crisp white) + cursor bar (electric blue) + "ow" (muted ghost gray)
    let fontSize = s * 0.30
    let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    let typedAttrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white
    ]
    let ghostAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.34)
    ]

    let typedStr = "kn" as NSString
    let ghostStr = "ow" as NSString
    let typedSize = typedStr.size(withAttributes: typedAttrs)
    let ghostSize = ghostStr.size(withAttributes: ghostAttrs)
    let barW = max(2.0, s * 0.022)
    let gap = s * 0.012

    let totalW = typedSize.width + gap + barW + gap + ghostSize.width
    let startX = (s - totalW) / 2.0
    let textY = (s - typedSize.height) / 2.0

    typedStr.draw(at: NSPoint(x: startX, y: textY), withAttributes: typedAttrs)

    // Cursor beam
    let barX = startX + typedSize.width + gap
    let barH = fontSize * 1.12
    let barY = (s - barH) / 2.0
    let barPath = NSBezierPath(roundedRect: NSRect(x: barX, y: barY, width: barW, height: barH), xRadius: barW / 2, yRadius: barW / 2)
    NSColor(calibratedRed: 0.28, green: 0.62, blue: 1.0, alpha: 1.0).setFill()
    barPath.fill()

    ghostStr.draw(at: NSPoint(x: barX + barW + gap, y: textY), withAttributes: ghostAttrs)

    ctx.flush()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, px) in specs {
    let url = URL(fileURLWithPath: outIconset).appendingPathComponent(name)
    try renderIcon(pixelSize: px).write(to: url)
}
