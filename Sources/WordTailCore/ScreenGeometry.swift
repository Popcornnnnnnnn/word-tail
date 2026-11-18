import AppKit
import CoreGraphics
import Foundation

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
        verticalAdjustment: CGFloat = defaultVerticalOffset
    ) -> BaselinePlacement {
        let anchorX = axRect.origin.x + axRect.size.width
        let axTopY = primaryScreenHeight - axRect.origin.y
        let axBottomY = primaryScreenHeight - (axRect.origin.y + axRect.size.height)

        let baselineFromBottom = axBottomY - font.descender
        let baselineFromTop = axTopY - font.ascender
        return BaselinePlacement(
            anchorX: anchorX,
            baselineY: max(baselineFromBottom, baselineFromTop) + verticalAdjustment
        )
    }

    /// Estimates matching AppKit font point size from a web/AX glyph box height when `AXFont` metadata is absent.
    public static func estimatedFontSize(forLineHeight height: CGFloat) -> CGFloat {
        let raw = round(height * 0.80)
        return min(max(raw, 11.0), 28.0)
    }
}
