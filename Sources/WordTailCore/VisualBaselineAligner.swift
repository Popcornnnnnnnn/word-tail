import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Identifies a single visual text line within a focused element/app/display/font/scroll state
/// for sub-pixel baseline caching.
public struct VisualLineKey: Hashable, Sendable {
    public let bundleID: String
    public let displayKey: String
    public let elementHash: UInt
    public let axLineYInt: Int
    public let axHeightInt: Int
    public let fontSizeQuarter: Int
    public let scrollGeneration: UInt64

    public init(
        bundleID: String,
        displayKey: String,
        elementHash: UInt = 0,
        axLineY: CGFloat,
        axHeight: CGFloat,
        fontSize: CGFloat,
        scrollGeneration: UInt64
    ) {
        self.bundleID = bundleID
        self.displayKey = displayKey
        self.elementHash = elementHash
        self.axLineYInt = Int(axLineY.rounded())
        self.axHeightInt = Int(axHeight.rounded())
        self.fontSizeQuarter = Int((fontSize * 4.0).rounded())
        self.scrollGeneration = scrollGeneration
    }
}

/// Buckets learned baseline residuals across lines for an app + display + font size combination,
/// so frame 1 on a new line already starts visually close before its per-line micro-crop completes.
public struct VisualPriorKey: Hashable, Sendable {
    public let bundleID: String
    public let displayKey: String
    public let fontSizeQuarter: Int

    public init(bundleID: String, displayKey: String, fontSize: CGFloat) {
        self.bundleID = bundleID
        self.displayKey = displayKey
        self.fontSizeQuarter = Int((fontSize * 4.0).rounded())
    }
}

public struct VisualSampleWord: Equatable, Sendable {
    public let text: String
    public let trailingSpaceCount: Int

    public init(text: String, trailingSpaceCount: Int) {
        self.text = text
        self.trailingSpaceCount = trailingSpaceCount
    }
}

public struct VisualCropPlan: Equatable, Sendable {
    /// Display-local Quartz coordinates (`+y` down from display top-left) for `SCStreamConfiguration.sourceRect`.
    public let displayLocalRect: CGRect
    /// Global Quartz Y coordinate of pixel row `0` at the top edge of the cropped image.
    public let cropTopQuartzY: CGFloat
    /// Exact predicted baseline position in points measured downward from the top edge of the crop.
    public let predictedBaselineFromTopPt: CGFloat
    /// The typed ASCII word segment expected inside this crop.
    public let sampleText: String

    public init(
        displayLocalRect: CGRect,
        cropTopQuartzY: CGFloat,
        predictedBaselineFromTopPt: CGFloat,
        sampleText: String
    ) {
        self.displayLocalRect = displayLocalRect
        self.cropTopQuartzY = cropTopQuartzY
        self.predictedBaselineFromTopPt = predictedBaselineFromTopPt
        self.sampleText = sampleText
    }
}

public struct VisualBaselineMeasurement: Equatable, Sendable {
    /// Measured vertical displacement in Quartz points (`+` = real text sits LOWER on screen than predicted,
    /// `-` = real text sits HIGHER on screen than predicted).
    public let deltaQuartzY: CGFloat
    /// Normalized 1D profile correlation score (`0...1`) of the coarse line lock.
    public let confidence: Double

    public init(deltaQuartzY: CGFloat, confidence: Double) {
        self.deltaQuartzY = deltaQuartzY
        self.confidence = confidence
    }
}

public struct VisualBaselineResolution: Equatable, Sendable {
    public let baselineCocoaY: CGFloat
    public let isLineLocked: Bool
    public let usedLearnedPrior: Bool

    public init(baselineCocoaY: CGFloat, isLineLocked: Bool, usedLearnedPrior: Bool) {
        self.baselineCocoaY = baselineCocoaY
        self.isLineLocked = isLineLocked
        self.usedLearnedPrior = usedLearnedPrior
    }
}

/// Pure, allocation-light sub-pixel baseline alignment engine operating on tiny in-memory micro-crops
/// immediately left of the caret.
public enum VisualBaselineAligner {
    public static let maxAllowedShiftPt: CGFloat = 4.25
    /// Hard sanity cap on total residual between any visual lock and the unadjusted AX baseline.
    public static let maxTotalResidualFromRawPt: CGFloat = 5.0
    public static let maxManualSearchHintPt: CGFloat = 3.0
    public static let baselineQuantizationStepPt: CGFloat = 0.05

    private static let descenderChars: Set<Character> = ["g", "j", "p", "q", "y"]

    /// Chooses the search anchor for a new line: uses the learned prior if available,
    /// otherwise clamps the user's manual fallback offset to a safe hint window (`±3.0 pt`) around raw AX.
    public static func measurementSearchAnchorCocoaY(
        resolution: VisualBaselineResolution,
        rawBaselineCocoaY: CGFloat,
        fallbackBaselineCocoaY: CGFloat
    ) -> CGFloat {
        if resolution.usedLearnedPrior {
            return resolution.baselineCocoaY
        }
        let manualDelta = fallbackBaselineCocoaY - rawBaselineCocoaY
        guard manualDelta.isFinite else { return rawBaselineCocoaY }
        let clampedHint = min(max(manualDelta, -maxManualSearchHintPt), maxManualSearchHintPt)
        return rawBaselineCocoaY + clampedHint
    }

    /// Validates that a locked baseline remains within the global sanity envelope relative to raw AX.
    public static func isWithinRawResidualEnvelope(
        lockedBaselineCocoaY: CGFloat,
        rawBaselineCocoaY: CGFloat
    ) -> Bool {
        guard lockedBaselineCocoaY.isFinite, rawBaselineCocoaY.isFinite else { return false }
        return abs(lockedBaselineCocoaY - rawBaselineCocoaY) <= maxTotalResidualFromRawPt
    }

    /// Extracts a clean trailing ASCII word segment on the current line suitable for baseline cliff alignment.
    /// Requires at least 2 non-descender alphanumeric characters so the typographic baseline drop is crisp.
    public static func extractSampleWord(from textBeforeCursor: String) -> VisualSampleWord? {
        guard !textBeforeCursor.isEmpty else { return nil }
        let lineSlice: Substring
        if let nl = textBeforeCursor.lastIndex(where: { $0 == "\n" || $0 == "\r" }) {
            lineSlice = textBeforeCursor[textBeforeCursor.index(after: nl)...]
        } else {
            lineSlice = textBeforeCursor[...]
        }
        guard !lineSlice.isEmpty else { return nil }

        var end = lineSlice.endIndex
        var trailingSpaces = 0
        while end > lineSlice.startIndex {
            let prev = lineSlice.index(before: end)
            if lineSlice[prev] == " " {
                trailingSpaces += 1
                if trailingSpaces > 2 {
                    return nil
                }
                end = prev
            } else {
                break
            }
        }
        guard end > lineSlice.startIndex else { return nil }

        var start = end
        while start > lineSlice.startIndex {
            let prev = lineSlice.index(before: start)
            let ch = lineSlice[prev]
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                start = prev
            } else {
                break
            }
        }
        guard start < end else { return nil }

        let rawWord = String(lineSlice[start..<end])
        let sample = rawWord.count > 10 ? String(rawWord.suffix(10)) : rawWord
        guard sample.count >= 2 else { return nil }

        let nonDescenderCount = sample.reduce(into: 0) { count, ch in
            let lower = Character(ch.lowercased())
            if !descenderChars.contains(lower) {
                count += 1
            }
        }
        guard nonDescenderCount >= 2 else { return nil }

        return VisualSampleWord(text: sample, trailingSpaceCount: trailingSpaces)
    }

    /// Computes a tight, integer-aligned display-local micro-crop strictly to the left of the caret
    /// while preserving exact sub-pixel baseline coordinates.
    public static func computeCropPlan(
        rawAXRect: CGRect,
        primaryScreenHeight: CGFloat,
        predictedBaselineCocoaY: CGFloat,
        font: NSFont,
        sample: VisualSampleWord,
        displayFrameQuartz: CGRect
    ) -> VisualCropPlan? {
        guard displayFrameQuartz.width >= 64,
              displayFrameQuartz.height >= 64,
              rawAXRect.origin.x.isFinite,
              rawAXRect.origin.y.isFinite,
              predictedBaselineCocoaY.isFinite,
              font.pointSize >= 9,
              font.pointSize <= 36 else {
            return nil
        }

        let predictedBaselineQuartzY = primaryScreenHeight - predictedBaselineCocoaY

        let sampleAttr = NSAttributedString(string: sample.text, attributes: [.font: font])
        let sampleLine = CTLineCreateWithAttributedString(sampleAttr)
        let sampleWidthPt = CGFloat(CTLineGetTypographicBounds(sampleLine, nil, nil, nil))

        let spaceWidthPt: CGFloat
        if sample.trailingSpaceCount > 0 {
            let spaceLine = CTLineCreateWithAttributedString(NSAttributedString(string: " ", attributes: [.font: font]))
            spaceWidthPt = CGFloat(CTLineGetTypographicBounds(spaceLine, nil, nil, nil)) * CGFloat(sample.trailingSpaceCount)
        } else {
            spaceWidthPt = 0
        }

        // Leave only a 1.0 pt caret clearance margin so we do not slice into the rightmost typed glyph,
        // while still stripping any thin vertical caret spike inside the image analyzer.
        let caretMarginPt: CGFloat = 1.0
        let rightEdgeQuartzX = rawAXRect.maxX - caretMarginPt - spaceWidthPt
        let desiredWidthPt = min(max(ceil(sampleWidthPt) + 6.0, 20.0), 108.0)
        let rawLeftQuartzX = rightEdgeQuartzX - desiredWidthPt

        let ascenderSpan = max(font.ascender, font.pointSize * 0.78)
        let descenderSpan = max(-font.descender, font.pointSize * 0.24)
        let padAbove = min(6.5, max(4.5, font.pointSize * 0.35))
        let padBelow = min(6.5, max(4.5, font.pointSize * 0.35))

        let rawTopQuartzY = predictedBaselineQuartzY - ascenderSpan - padAbove
        let rawBottomQuartzY = predictedBaselineQuartzY + descenderSpan + padBelow

        // Convert to display-local integer points and clamp inside display bounds.
        let dispOriginX = displayFrameQuartz.origin.x
        let dispOriginY = displayFrameQuartz.origin.y
        let dispW = displayFrameQuartz.width
        let dispH = displayFrameQuartz.height

        let localMinX = max(0, min(dispW, floor(rawLeftQuartzX - dispOriginX)))
        let localMaxX = max(0, min(dispW, ceil(rightEdgeQuartzX - dispOriginX)))
        let localMinY = max(0, min(dispH, floor(rawTopQuartzY - dispOriginY)))
        let localMaxY = max(0, min(dispH, ceil(rawBottomQuartzY - dispOriginY)))

        let localW = localMaxX - localMinX
        let localH = localMaxY - localMinY
        guard localW >= 16, localH >= 14 else { return nil }

        let localRect = CGRect(x: localMinX, y: localMinY, width: localW, height: localH)
        let cropTopQuartzY = dispOriginY + localMinY
        let predictedBaselineFromTopPt = predictedBaselineQuartzY - cropTopQuartzY
        guard predictedBaselineFromTopPt >= 6.0,
              predictedBaselineFromTopPt <= localH - 4.0 else {
            return nil
        }

        return VisualCropPlan(
            displayLocalRect: localRect,
            cropTopQuartzY: cropTopQuartzY,
            predictedBaselineFromTopPt: predictedBaselineFromTopPt,
            sampleText: sample.text
        )
    }

    /// Converts a measured Quartz Y shift (`+` = lower on screen) into the locked Cocoa screen baseline Y
    /// (`+` = higher on screen), quantized to `0.05 pt` to prevent sub-pixel jitter.
    public static func lockedCocoaBaselineY(
        predictedBaselineCocoaY: CGFloat,
        deltaQuartzY: CGFloat
    ) -> CGFloat {
        let exact = predictedBaselineCocoaY - deltaQuartzY
        let step = baselineQuantizationStepPt
        return (exact / step).rounded() * step
    }

    /// Measures the sub-pixel vertical shift (`deltaQuartzY`, `+` = real text is LOWER than predicted)
    /// between a captured micro-crop `CGImage` and WordTail's reference font rendering `sampleText`.
    ///
    /// Algorithm:
    /// 1. Context-owned bitmap extraction + component-wise histogram median background RGB.
    /// 2. Perceptual ink projection rejecting full-height borders AND thin right-edge cursor bars,
    ///    isolating the main contiguous ink band from tight neighboring lines.
    /// 3. Stage 1 (coarse lock): glyph-band normalized cross-correlation against an offscreen sub-pixel `CTLine` template.
    /// 4. Stage 2 (baseline-cliff lock): aligns the downward ink-drop peak (`P[y-1] - P[y+1]`) at the typographic baseline
    ///    with competing-peak rejection and lower-band / sub-baseline clutter verification so underlines and squiggles
    ///    cannot cause false locks.
    public static func measureBaselineDeltaQuartzY(
        capturedImage: CGImage,
        sampleText: String,
        referenceFont: NSFont,
        scale: CGFloat,
        predictedBaselineFromTopPt: CGFloat,
        maxShiftPt: CGFloat = maxAllowedShiftPt
    ) -> VisualBaselineMeasurement? {
        let w = capturedImage.width
        let h = capturedImage.height
        guard w >= 12, h >= 14, scale > 0, scale.isFinite, !sampleText.isEmpty else {
            return nil
        }

        // 1. Extract RGBA pixels using context-owned backing storage (safe pointer lifetime).
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: srgb,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.draw(capturedImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        let screenProfile: [Double]? = withExtendedLifetime(ctx) {
            guard let rawPtr = ctx.data else { return nil }
            let bytes = rawPtr.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = ctx.bytesPerRow

            var histR = [Int](repeating: 0, count: 256)
            var histG = [Int](repeating: 0, count: 256)
            var histB = [Int](repeating: 0, count: 256)
            let totalPx = w * h
            for y in 0..<h {
                let rowBase = y * bytesPerRow
                for x in 0..<w {
                    let i = rowBase + x * 4
                    histR[Int(bytes[i])] += 1
                    histG[Int(bytes[i + 1])] += 1
                    histB[Int(bytes[i + 2])] += 1
                }
            }
            let bgR = histogramMedian(histR, total: totalPx)
            let bgG = histogramMedian(histG, total: totalPx)
            let bgB = histogramMedian(histB, total: totalPx)

            var ink = [Double](repeating: 0, count: totalPx)
            var colActive = [Int](repeating: 0, count: w)
            var colLongestRun = [Int](repeating: 0, count: w)
            var colCurrentRun = [Int](repeating: 0, count: w)
            let activeDistThreshold = 14.0
            for y in 0..<h {
                let rowBase = y * bytesPerRow
                let rowOff = y * w
                for x in 0..<w {
                    let i = rowBase + x * 4
                    let dr = Double(bytes[i]) - bgR
                    let dg = Double(bytes[i + 1]) - bgG
                    let db = Double(bytes[i + 2]) - bgB
                    let dist = sqrt(0.299 * dr * dr + 0.587 * dg * dg + 0.114 * db * db)
                    ink[rowOff + x] = max(0.0, dist - 6.0)
                    if dist > activeDistThreshold {
                        colActive[x] += 1
                        colCurrentRun[x] += 1
                        if colCurrentRun[x] > colLongestRun[x] {
                            colLongestRun[x] = colCurrentRun[x]
                        }
                    } else {
                        colCurrentRun[x] = 0
                    }
                }
            }

            // Identify columns to ignore: full-height vertical dividers (>78% height) OR thin right-edge I-beam carets
            // (continuous vertical bar >= 85% of glyph height within the rightmost 4 pt of the crop).
            let maxAllowedColFill = Int(Double(h) * 0.78)
            let caretEdgeWidthPx = min(w, Int(ceil(4.0 * scale)))
            let caretMinRunPx = Int(floor(referenceFont.pointSize * 0.85 * scale))
            let maxCaretWidthPx = max(2, Int(ceil(2.0 * scale)))
            var ignoredCol = [Bool](repeating: false, count: w)
            for x in 0..<w where colActive[x] >= maxAllowedColFill {
                ignoredCol[x] = true
            }
            let edgeStart = max(0, w - caretEdgeWidthPx)
            var x = edgeStart
            while x < w {
                if colLongestRun[x] >= caretMinRunPx {
                    var runEnd = x
                    while runEnd + 1 < w && colLongestRun[runEnd + 1] >= caretMinRunPx {
                        runEnd += 1
                    }
                    let barWidth = runEnd - x + 1
                    if barWidth <= maxCaretWidthPx {
                        let leftClear = (x == 0) || (colLongestRun[x - 1] < caretMinRunPx / 2)
                        let rightClear = (runEnd == w - 1) || (colLongestRun[runEnd + 1] < caretMinRunPx / 2)
                        if leftClear && rightClear {
                            for cx in x...runEnd {
                                ignoredCol[cx] = true
                            }
                        }
                    }
                    x = runEnd + 1
                } else {
                    x += 1
                }
            }

            var profile = [Double](repeating: 0, count: h)
            for y in 0..<h {
                let rowOff = y * w
                var sum = 0.0
                for cx in 0..<w where !ignoredCol[cx] {
                    sum += ink[rowOff + cx]
                }
                profile[y] = sum
            }
            return profile
        }

        guard var screenProfile else { return nil }
        let maxRowVal = screenProfile.max() ?? 0
        guard maxRowVal > 150.0 else { return nil }

        // Isolate the main contiguous ink band around the predicted text body, zeroing out adjacent lines above/below.
        let activeThresh = maxRowVal * 0.06
        let centerRow = max(
            0,
            min(h - 1, Int(((predictedBaselineFromTopPt - referenceFont.xHeight * 0.5) * scale).rounded()))
        )
        let maxShiftPx = Int(ceil(maxShiftPt * scale))
        var seedRow: Int?
        for d in 0...maxShiftPx {
            if centerRow - d >= 0 && screenProfile[centerRow - d] >= activeThresh {
                seedRow = centerRow - d
                break
            }
            if centerRow + d < h && screenProfile[centerRow + d] >= activeThresh {
                seedRow = centerRow + d
                break
            }
        }
        guard let seed = seedRow else { return nil }

        let maxAboveSeedPx = Int(ceil((referenceFont.ascender + 4.0) * scale))
        let maxBelowSeedPx = Int(ceil((abs(referenceFont.descender) + 6.0) * scale))
        var bandTop = seed
        while bandTop > 0 {
            if screenProfile[bandTop - 1] >= activeThresh {
                bandTop -= 1
            } else if bandTop >= 2
                && screenProfile[bandTop - 2] >= activeThresh
                && (seed - bandTop) < maxAboveSeedPx {
                bandTop -= 1
            } else {
                break
            }
        }
        var bandBot = seed
        while bandBot < h - 1 {
            if screenProfile[bandBot + 1] >= activeThresh {
                bandBot += 1
            } else if bandBot + 2 < h
                && screenProfile[bandBot + 2] >= activeThresh
                && (bandBot - seed) < maxBelowSeedPx {
                bandBot += 1
            } else {
                break
            }
        }

        let bandHeightPt = CGFloat(bandBot - bandTop + 1) / scale
        guard bandHeightPt >= referenceFont.pointSize * 0.35,
              bandHeightPt <= referenceFont.pointSize * 2.35 else {
            return nil
        }
        if (bandTop == 0 && screenProfile[0] > maxRowVal * 0.35)
            || (bandBot == h - 1 && screenProfile[h - 1] > maxRowVal * 0.35) {
            return nil
        }

        for y in 0..<h {
            if y < max(0, bandTop - 1) || y > min(h - 1, bandBot + 1) {
                screenProfile[y] = 0
            }
        }

        // 4. Render sub-pixel reference template matching GhostOverlayWindow's exact CoreText rendering pipeline
        //    using context-owned backing storage (safe pointer lifetime).
        let attr = NSAttributedString(
            string: sampleText,
            attributes: [.font: referenceFont, .foregroundColor: NSColor.white]
        )
        let ctLine = CTLineCreateWithAttributedString(attr)
        let textW = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        let tmplW = max(16, Int(ceil((textW + 8.0) * scale)))
        let cropHeightPt = CGFloat(h) / scale
        let desiredCGY = cropHeightPt - predictedBaselineFromTopPt
        let snappedCGY = (desiredCGY * scale).rounded() / scale
        let subDeltaCGY = desiredCGY - snappedCGY

        guard let grayCS = CGColorSpace(name: CGColorSpace.linearGray),
              let rawCtx = CGContext(
                  data: nil,
                  width: tmplW,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: grayCS,
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              ),
              let outCtx = CGContext(
                  data: nil,
                  width: tmplW,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: grayCS,
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else {
            return nil
        }

        rawCtx.scaleBy(x: scale, y: scale)
        rawCtx.setShouldSmoothFonts(true)
        rawCtx.setAllowsFontSubpixelPositioning(true)
        rawCtx.setShouldSubpixelPositionFonts(true)
        rawCtx.textMatrix = .identity
        rawCtx.textPosition = CGPoint(x: 4.0, y: snappedCGY)
        CTLineDraw(ctLine, rawCtx)

        guard let rawImg = rawCtx.makeImage() else { return nil }
        outCtx.scaleBy(x: scale, y: scale)
        outCtx.interpolationQuality = .high
        outCtx.draw(
            rawImg,
            in: CGRect(x: 0, y: subDeltaCGY, width: CGFloat(tmplW) / scale, height: cropHeightPt)
        )

        let tmplProfile: [Double]? = withExtendedLifetime(outCtx) {
            guard let rawPtr = outCtx.data else { return nil }
            let bytes = rawPtr.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = outCtx.bytesPerRow
            var profile = [Double](repeating: 0, count: h)
            for y in 0..<h {
                let rowBase = y * bytesPerRow
                var sum = 0.0
                for x in 0..<tmplW {
                    sum += Double(bytes[rowBase + x])
                }
                profile[y] = sum
            }
            return profile
        }
        guard let tmplProfile else { return nil }

        // Determine the expected glyph band inside the template (padded ±2.5 pt) for focused correlation scoring.
        let tmplMax = tmplProfile.max() ?? 0
        guard tmplMax > 1.0 else { return nil }
        var tmplFirst = h - 1
        var tmplLast = 0
        for y in 0..<h where tmplProfile[y] > tmplMax * 0.03 {
            if y < tmplFirst { tmplFirst = y }
            if y > tmplLast { tmplLast = y }
        }
        guard tmplFirst <= tmplLast else { return nil }
        let scorePad = Int(ceil(2.5 * scale))
        let scoreLo = max(0, tmplFirst - scorePad)
        let scoreHi = min(h - 1, tmplLast + scorePad)

        // 5. Stage 1: Coarse glyph-band normalized cross-correlation (line verification + rough alignment).
        let minS = -maxShiftPx
        let maxS = maxShiftPx
        var bestCoarseShift = 0
        var bestCoarseCorr = -1.0
        for s in minS...maxS {
            let c = normalizedCorrelation(screenProfile, tmplProfile, shift: s, range: scoreLo...scoreHi)
            if c > bestCoarseCorr {
                bestCoarseCorr = c
                bestCoarseShift = s
            }
        }
        guard bestCoarseShift > minS,
              bestCoarseShift < maxS,
              bestCoarseCorr >= 0.72 else {
            return nil
        }

        // 6. Stage 2: Exact baseline-cliff sub-pixel lock (invariant to x-height differences across fonts),
        //    rejecting competing drops (e.g. underlines, spellcheck squiggles, or tight adjacent lines).
        let sampleHasDescenders = sampleText.contains { ch in
            descenderChars.contains(Character(ch.lowercased()))
        }
        let sDrop = downwardDrop(screenProfile)
        let tDrop = downwardDrop(tmplProfile)
        let predBasePx = Double(predictedBaselineFromTopPt * scale)
        let cliffHalfWindow = Int(ceil(1.85 * scale))
        let minCompetingSepPx = max(2, Int(ceil(1.0 * scale)))

        guard let tmplCliff = parabolicPeak(
            in: tDrop,
            approxCenter: predBasePx,
            halfWindow: cliffHalfWindow,
            rejectCompetingSeparationPx: nil
        ),
        let screenCliff = parabolicPeak(
            in: sDrop,
            approxCenter: predBasePx + Double(bestCoarseShift),
            halfWindow: cliffHalfWindow,
            rejectCompetingSeparationPx: sampleHasDescenders ? nil : minCompetingSepPx
        ) else {
            return nil
        }

        guard screenCliff.strength >= maxRowVal * 0.22 else { return nil }

        let cliffShiftPx = screenCliff.position - tmplCliff.position
        guard abs(cliffShiftPx - Double(bestCoarseShift)) <= Double(1.35 * scale) else {
            return nil
        }

        // 7. Sub-baseline clutter gate (rejects underlines / spellcheck squiggles below the baseline).
        let alignedShiftInt = Int(cliffShiftPx.rounded())
        let xHeightPx = max(4.0, Double(referenceFont.xHeight * scale))
        let lowerBandLo = max(0, Int(floor(predBasePx - xHeightPx * 0.60)))
        let lowerBandHi = min(h - 1, Int(ceil(predBasePx + max(Double(abs(referenceFont.descender)), 3.0) * Double(scale) + 1.5 * Double(scale))))
        if lowerBandLo < lowerBandHi {
            let lowerCorr = normalizedCorrelation(
                screenProfile,
                tmplProfile,
                shift: alignedShiftInt,
                range: lowerBandLo...lowerBandHi
            )
            if lowerCorr < 0.78 {
                return nil
            }
        }

        if !sampleHasDescenders {
            let screenBasePx = predBasePx + cliffShiftPx
            let bodyLo = max(0, Int(floor(screenBasePx - xHeightPx)))
            let bodyHi = min(h - 1, Int(floor(screenBasePx)))
            let subLo = max(0, Int(ceil(screenBasePx + 1.0 * Double(scale))))
            let subHi = min(h - 1, Int(ceil(screenBasePx + 3.5 * Double(scale))))
            if bodyLo <= bodyHi && subLo <= subHi {
                let bodyPeak = (bodyLo...bodyHi).map { screenProfile[$0] }.max() ?? 0
                let subPeak = (subLo...subHi).map { screenProfile[$0] }.max() ?? 0
                if bodyPeak > 0 && subPeak > bodyPeak * 0.28 {
                    return nil
                }
            }
        }

        let deltaPt = CGFloat(cliffShiftPx) / scale
        guard deltaPt.isFinite, abs(deltaPt) <= maxShiftPt else {
            return nil
        }

        return VisualBaselineMeasurement(deltaQuartzY: deltaPt, confidence: bestCoarseCorr)
    }

    private static func histogramMedian(_ hist: [Int], total: Int) -> Double {
        let half = total / 2
        var acc = 0
        for v in 0..<256 {
            acc += hist[v]
            if acc >= half {
                return Double(v)
            }
        }
        return 0
    }

    private static func normalizedCorrelation(
        _ a: [Double],
        _ b: [Double],
        shift: Int,
        range: ClosedRange<Int>
    ) -> Double {
        let h = a.count
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for y in range {
            let sy = y + shift
            guard sy >= 0 && sy < h else { continue }
            let av = a[sy]
            let bv = b[y]
            dot += av * bv
            normA += av * av
            normB += bv * bv
        }
        guard normA > 1e-6, normB > 1e-6 else { return -1.0 }
        return dot / sqrt(normA * normB)
    }

    private static func downwardDrop(_ profile: [Double]) -> [Double] {
        var drop = [Double](repeating: 0, count: profile.count)
        guard profile.count >= 3 else { return drop }
        for y in 1..<(profile.count - 1) {
            drop[y] = max(0.0, profile[y - 1] - profile[y + 1])
        }
        return drop
    }

    private static func parabolicPeak(
        in values: [Double],
        approxCenter: Double,
        halfWindow: Int,
        rejectCompetingSeparationPx: Int?
    ) -> (position: Double, strength: Double)? {
        let lo = max(1, Int(floor(approxCenter)) - halfWindow)
        let hi = min(values.count - 2, Int(ceil(approxCenter)) + halfWindow)
        guard lo <= hi else { return nil }

        var peakIdx = lo
        var peakVal = -1.0
        for y in lo...hi where values[y] > peakVal {
            peakVal = values[y]
            peakIdx = y
        }
        guard peakVal > 0 else { return nil }

        // Reject ambiguous multi-edge strips (e.g. a thick underline or squiggle creating a second strong cliff).
        if let minSep = rejectCompetingSeparationPx {
            for y in lo...hi {
                guard abs(y - peakIdx) >= minSep else { continue }
                let val = values[y]
                let isLocalMax = val >= values[y - 1] && val >= values[y + 1]
                if isLocalMax && val >= peakVal * 0.55 {
                    return nil
                }
            }
        }

        let y0 = values[peakIdx - 1]
        let y1 = values[peakIdx]
        let y2 = values[peakIdx + 1]
        let denom = y0 - 2.0 * y1 + y2
        var exact = Double(peakIdx)
        if abs(denom) > 1e-9 {
            let frac = 0.5 * (y0 - y2) / denom
            if abs(frac) <= 0.75 {
                exact += frac
            }
        }
        return (exact, peakVal)
    }
}

/// Thread-safe per-line sub-pixel lock cache plus rolling per-(app, display, fontSize) prior medians.
public final class VisualBaselineCache {
    private struct LineEntry {
        var lockedBaselineCocoaY: CGFloat
        var lastCaretX: CGFloat
        var updatedAt: CFAbsoluteTime
    }

    private struct FailureState {
        var count: Int
        var lastAttemptAt: CFAbsoluteTime
        var lastCaretX: CGFloat
    }

    private let lock = NSLock()
    private var lineEntries: [VisualLineKey: LineEntry] = [:]
    private var failureStates: [VisualLineKey: FailureState] = [:]
    private var priorSamples: [VisualPriorKey: [CGFloat]] = [:]

    private let maxLineEntries = 128
    private let maxFailureEntries = 128
    private let maxPriorBuckets = 64
    private let maxSamplesPerPrior = 7
    private let lineTTLSeconds: CFAbsoluteTime = 90.0
    private let failureTTLSeconds: CFAbsoluteTime = 12.0
    private let softWrapLeftJumpThresholdPt: CGFloat = 18.0
    private let maxFailuresPerLine = 3
    private let failureRetryCooldownSeconds: CFAbsoluteTime = 0.55

    public init() {}

    /// Resolves the best known Cocoa baseline Y for a line immediately (0 ms):
    /// 1. Exact per-line cache hit (unless caret wrapped left on the same Y, indicating auto-scroll wrap).
    /// 2. Learned median residual prior for `(bundleID, displayKey, fontSize)` applied onto `rawBaselineCocoaY`.
    /// 3. Existing fallback baseline (`rawBaselineCocoaY + manualOffset`).
    public func resolveInitialBaseline(
        lineKey: VisualLineKey,
        priorKey: VisualPriorKey,
        rawBaselineCocoaY: CGFloat,
        fallbackBaselineCocoaY: CGFloat,
        currentCaretX: CGFloat,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> VisualBaselineResolution {
        lock.lock()
        defer { lock.unlock() }

        if var entry = lineEntries[lineKey] {
            if now - entry.updatedAt > lineTTLSeconds
                || currentCaretX < entry.lastCaretX - softWrapLeftJumpThresholdPt {
                // Expired or caret jumped left on the same Y (soft-wrap auto-scroll in fixed-height composer).
                lineEntries.removeValue(forKey: lineKey)
                failureStates.removeValue(forKey: lineKey)
            } else {
                if currentCaretX > entry.lastCaretX {
                    entry.lastCaretX = currentCaretX
                    lineEntries[lineKey] = entry
                }
                return VisualBaselineResolution(
                    baselineCocoaY: entry.lockedBaselineCocoaY,
                    isLineLocked: true,
                    usedLearnedPrior: false
                )
            }
        }

        if let priorResidual = medianPriorLocked(for: priorKey) {
            let step = VisualBaselineAligner.baselineQuantizationStepPt
            let estimated = ((rawBaselineCocoaY + priorResidual) / step).rounded() * step
            return VisualBaselineResolution(
                baselineCocoaY: estimated,
                isLineLocked: false,
                usedLearnedPrior: true
            )
        }

        return VisualBaselineResolution(
            baselineCocoaY: fallbackBaselineCocoaY,
            isLineLocked: false,
            usedLearnedPrior: false
        )
    }

    public func shouldAttemptCapture(
        for lineKey: VisualLineKey,
        currentCaretX: CGFloat,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let entry = lineEntries[lineKey],
           now - entry.updatedAt <= lineTTLSeconds,
           currentCaretX >= entry.lastCaretX - softWrapLeftJumpThresholdPt {
            return false
        }
        if let failure = failureStates[lineKey] {
            if now - failure.lastAttemptAt > failureTTLSeconds {
                failureStates.removeValue(forKey: lineKey)
                return true
            }
            if failure.count >= maxFailuresPerLine {
                return false
            }
            let elapsed = now - failure.lastAttemptAt
            let movedFar = abs(currentCaretX - failure.lastCaretX) >= 14.0
            if elapsed < failureRetryCooldownSeconds && !movedFar {
                return false
            }
        }
        return true
    }

    /// Stores a verified visual baseline lock after validating it stays within the global raw-AX residual envelope.
    /// Returns `false` and records a failure if the residual exceeds `VisualBaselineAligner.maxTotalResidualFromRawPt`.
    @discardableResult
    public func recordLock(
        lineKey: VisualLineKey,
        priorKey: VisualPriorKey,
        lockedBaselineCocoaY: CGFloat,
        rawBaselineCocoaY: CGFloat,
        caretX: CGFloat,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Bool {
        guard VisualBaselineAligner.isWithinRawResidualEnvelope(
            lockedBaselineCocoaY: lockedBaselineCocoaY,
            rawBaselineCocoaY: rawBaselineCocoaY
        ) else {
            recordFailure(for: lineKey, caretX: caretX, now: now)
            return false
        }

        lock.lock()
        defer { lock.unlock() }

        if lineEntries.count >= maxLineEntries, lineEntries[lineKey] == nil {
            if let oldest = lineEntries.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
                lineEntries.removeValue(forKey: oldest)
            }
        }
        lineEntries[lineKey] = LineEntry(
            lockedBaselineCocoaY: lockedBaselineCocoaY,
            lastCaretX: caretX,
            updatedAt: now
        )
        failureStates.removeValue(forKey: lineKey)

        let residual = lockedBaselineCocoaY - rawBaselineCocoaY
        if priorSamples.count >= maxPriorBuckets, priorSamples[priorKey] == nil {
            if let firstKey = priorSamples.keys.first {
                priorSamples.removeValue(forKey: firstKey)
            }
        }
        var samples = priorSamples[priorKey] ?? []
        samples.append(residual)
        if samples.count > maxSamplesPerPrior {
            samples.removeFirst(samples.count - maxSamplesPerPrior)
        }
        priorSamples[priorKey] = samples
        return true
    }

    public func recordFailure(
        for lineKey: VisualLineKey,
        caretX: CGFloat,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        lock.lock()
        defer { lock.unlock() }

        if let existing = failureStates[lineKey], now - existing.lastAttemptAt > failureTTLSeconds {
            failureStates.removeValue(forKey: lineKey)
        }
        if failureStates.count >= maxFailureEntries, failureStates[lineKey] == nil {
            if let oldest = failureStates.min(by: { $0.value.lastAttemptAt < $1.value.lastAttemptAt })?.key {
                failureStates.removeValue(forKey: oldest)
            }
        }
        let nextCount = (failureStates[lineKey]?.count ?? 0) + 1
        failureStates[lineKey] = FailureState(
            count: nextCount,
            lastAttemptAt: now,
            lastCaretX: caretX
        )
    }

    public func clearLines(forBundleID bundleID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        if let bundleID {
            lineEntries = lineEntries.filter { $0.key.bundleID != bundleID }
            failureStates = failureStates.filter { $0.key.bundleID != bundleID }
        } else {
            lineEntries.removeAll(keepingCapacity: false)
            failureStates.removeAll(keepingCapacity: false)
        }
    }

    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        lineEntries.removeAll(keepingCapacity: false)
        failureStates.removeAll(keepingCapacity: false)
        priorSamples.removeAll(keepingCapacity: false)
    }

    public func learnedPriorResidual(for priorKey: VisualPriorKey) -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return medianPriorLocked(for: priorKey)
    }

    private func medianPriorLocked(for key: VisualPriorKey) -> CGFloat? {
        guard let samples = priorSamples[key], !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) * 0.5
    }
}
