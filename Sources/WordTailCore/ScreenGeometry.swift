import AppKit
import CoreGraphics
import Foundation

public enum LineSpacingBias: Equatable, Sendable {
    /// AppKit / Cocoa: extra line spacing expands downward from glyph top.
    case bottomAdded
    /// WebKit (`WKWebView` / Safari / Catalyst WebView): line 2+ `selectionRect` expands upward into inter-line leading while `maxY` stays anchored to glyph bottom.
    case topAdded
    /// Chromium / Blink / Electron: CSS `line-height` distributes extra half-leading symmetrically above and below glyphs.
    case symmetric
}

public struct BaselinePlacement: Equatable {
    public let anchorX: CGFloat
    public let baselineY: CGFloat

    public init(anchorX: CGFloat, baselineY: CGFloat) {
        self.anchorX = anchorX
        self.baselineY = baselineY
    }
}

public enum ScreenGeometry {
    /// Default upward calibration (+0.70pt, ideal for Codex/Chrome), with per-app overrides where needed.
    public static let defaultVerticalOffset: CGFloat = 0.70

    public static let builtInAppVerticalOffsets: [String: CGFloat] = [
        "com.google.antigravity": 0.45,
        "com.openai.codex": 0.70
    ]

    public static func defaultVerticalOffset(forBundleID bundleID: String?) -> CGFloat {
        guard let bundleID, let custom = builtInAppVerticalOffsets[bundleID] else {
            return defaultVerticalOffset
        }
        return custom
    }

    /// Computes exact Cocoa screen X (right edge of typed character) and Cocoa screen baseline Y
    /// from a Quartz `AXBoundsForRange` / `AXBoundsForTextMarkerRange` character rect.
    public static func baselinePlacement(
        forAXCharRect axRect: CGRect,
        primaryScreenHeight: CGFloat,
        font: NSFont,
        verticalAdjustment: CGFloat = defaultVerticalOffset,
        lineSpacingBias: LineSpacingBias = .bottomAdded
    ) -> BaselinePlacement {
        let anchorX = axRect.origin.x + axRect.size.width
        let axTopY = primaryScreenHeight - axRect.origin.y
        let axBottomY = primaryScreenHeight - (axRect.origin.y + axRect.size.height)

        let baselineFromBottom = axBottomY - font.descender
        let baselineFromTop = axTopY - font.ascender
        let rawBaseline: CGFloat
        switch lineSpacingBias {
        case .bottomAdded:
            rawBaseline = max(baselineFromBottom, baselineFromTop)
        case .topAdded:
            rawBaseline = baselineFromBottom
        case .symmetric:
            rawBaseline = (baselineFromTop + baselineFromBottom) * 0.5
        }
        return BaselinePlacement(
            anchorX: anchorX,
            baselineY: rawBaseline + verticalAdjustment
        )
    }

    /// Estimates matching AppKit font point size from a web/AX glyph box height when `AXFont` metadata is absent.
    /// Quantized to `0.25 pt` steps so minor box-height changes do not produce abrupt `1.0 pt` jumps.
    public static func estimatedFontSize(forLineHeight height: CGFloat) -> CGFloat {
        let raw = ((height * 0.80) * 4.0).rounded() / 4.0
        return min(max(raw, 11.0), 28.0)
    }

    /// Extracts the font closest to the caret from an Accessibility attributed string,
    /// scanning backwards so leading object-replacement (`\u{FFFC}`) attachments in rich
    /// Chromium/ProseMirror editors do not hide the actual character's `AXFont`.
    public static func extractAXFont(from attrStr: NSAttributedString) -> NSFont? {
        guard attrStr.length > 0 else { return nil }
        var index = attrStr.length - 1
        while index >= 0 {
            var effectiveRange = NSRange(location: 0, length: 0)
            let attrs = attrStr.attributes(at: index, effectiveRange: &effectiveRange)
            if let nsFont = attrs[.font] as? NSFont {
                return nsFont
            }
            if let fontDict = attrs[NSAttributedString.Key("AXFont")] as? [String: Any],
               let num = fontDict["AXFontSize"] as? NSNumber {
                let size = CGFloat(num.doubleValue)
                if size >= 9, size <= 36 {
                    if let name = fontDict["AXFontName"] as? String,
                       !name.hasPrefix("."),
                       let namedFont = NSFont(name: name, size: size) {
                        return namedFont
                    }
                    return NSFont.systemFont(ofSize: size)
                }
            }
            index = effectiveRange.location - 1
        }
        return nil
    }

    /// Resolves a stable hardware display descriptor for an `NSScreen`.
    public static func displayDescriptor(for screen: NSScreen) -> DisplayDescriptor {
        let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let key: String
        if screenNumber != 0 {
            key = VerticalOffsetStore.displayKey(
                isBuiltin: CGDisplayIsBuiltin(screenNumber) != 0,
                vendor: CGDisplayVendorNumber(screenNumber),
                model: CGDisplayModelNumber(screenNumber),
                serial: CGDisplaySerialNumber(screenNumber),
                localizedName: screen.localizedName,
                scale: Double(screen.backingScaleFactor)
            )
        } else {
            key = VerticalOffsetStore.displayKey(
                isBuiltin: false,
                vendor: 0,
                model: 0,
                serial: 0,
                localizedName: screen.localizedName,
                scale: Double(screen.backingScaleFactor)
            )
        }
        return DisplayDescriptor(key: key, name: screen.localizedName)
    }

    /// Returns all currently connected displays in `NSScreen.screens` order, deduplicated by display key.
    public static func connectedDisplays() -> [DisplayDescriptor] {
        var result: [DisplayDescriptor] = []
        var seen = Set<String>()
        for screen in NSScreen.screens {
            let desc = displayDescriptor(for: screen)
            if seen.insert(desc.key).inserted {
                result.append(desc)
            }
        }
        return result
    }

    /// Resolves the display descriptor containing a Cocoa screen point, falling back to nearest or main screen.
    public static func displayDescriptor(forCocoaPoint point: NSPoint) -> DisplayDescriptor? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        if let hit = screens.first(where: { $0.frame.contains(point) }) {
            return displayDescriptor(for: hit)
        }
        if let nearest = screens.min(by: { a, b in
            squaredDistance(from: point, to: a.frame) < squaredDistance(from: point, to: b.frame)
        }) {
            return displayDescriptor(for: nearest)
        }
        return (NSScreen.main ?? screens.first).map(displayDescriptor(for:))
    }

    /// Resolves the display descriptor for a Quartz Accessibility bounding rect.
    public static func displayDescriptor(forAXRect axRect: CGRect, primaryScreenHeight: CGFloat) -> DisplayDescriptor? {
        let cocoaPoint = NSPoint(x: axRect.midX, y: primaryScreenHeight - axRect.midY)
        return displayDescriptor(forCocoaPoint: cocoaPoint)
    }

    private static func squaredDistance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx: CGFloat
        if point.x < rect.minX {
            dx = rect.minX - point.x
        } else if point.x > rect.maxX {
            dx = point.x - rect.maxX
        } else {
            dx = 0
        }
        let dy: CGFloat
        if point.y < rect.minY {
            dy = rect.minY - point.y
        } else if point.y > rect.maxY {
            dy = point.y - rect.maxY
        } else {
            dy = 0
        }
        return dx * dx + dy * dy
    }
}
