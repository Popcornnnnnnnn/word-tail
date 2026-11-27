import AppKit
import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import WordTailCore

final class VisualBaselineAlignerTests: XCTestCase {
    func testSampleWordExtraction() {
        XCTAssertEqual(
            VisualBaselineAligner.extractSampleWord(from: "Hello world"),
            VisualSampleWord(text: "world", trailingSpaceCount: 0)
        )
        XCTAssertEqual(
            VisualBaselineAligner.extractSampleWord(from: "some "),
            VisualSampleWord(text: "some", trailingSpaceCount: 1)
        )
        XCTAssertEqual(
            VisualBaselineAligner.extractSampleWord(from: "some  "),
            VisualSampleWord(text: "some", trailingSpaceCount: 2)
        )
        XCTAssertNil(VisualBaselineAligner.extractSampleWord(from: "some   "))

        XCTAssertEqual(
            VisualBaselineAligner.extractSampleWord(from: "internationalization"),
            VisualSampleWord(text: "nalization", trailingSpaceCount: 0)
        )
        XCTAssertEqual(
            VisualBaselineAligner.extractSampleWord(from: "previous line\nth"),
            VisualSampleWord(text: "th", trailingSpaceCount: 0)
        )
        XCTAssertEqual(
            VisualBaselineAligner.extractSampleWord(from: "typing"),
            VisualSampleWord(text: "typing", trailingSpaceCount: 0)
        )

        // Rejects empty, newline-only, non-ASCII, punctuation, or <2 non-descender characters.
        XCTAssertNil(VisualBaselineAligner.extractSampleWord(from: ""))
        XCTAssertNil(VisualBaselineAligner.extractSampleWord(from: "previous line\n"))
        XCTAssertNil(VisualBaselineAligner.extractSampleWord(from: "a"))
        XCTAssertNil(VisualBaselineAligner.extractSampleWord(from: "pg"))
        XCTAssertNil(VisualBaselineAligner.extractSampleWord(from: "gyq"))
        XCTAssertNil(VisualBaselineAligner.extractSampleWord(from: "你好世界"))
        XCTAssertNil(VisualBaselineAligner.extractSampleWord(from: "hello..."))
    }

    func testCropPlanPrimaryAndNegativeYSecondaryDisplay() throws {
        let font = NSFont.systemFont(ofSize: 14)
        let primaryHeight: CGFloat = 1117
        let sample = VisualSampleWord(text: "some", trailingSpaceCount: 0)

        // 1. Primary display (positive Quartz Y)
        let primaryFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let rawPrimary = CGRect(x: 520.0, y: 817.0, width: 8.0, height: 16.0)
        let predCocoaPrimary: CGFloat = 287.35 // Quartz Y = 1117 - 287.35 = 829.65
        let planPrimary = try XCTUnwrap(
            VisualBaselineAligner.computeCropPlan(
                rawAXRect: rawPrimary,
                primaryScreenHeight: primaryHeight,
                predictedBaselineCocoaY: predCocoaPrimary,
                font: font,
                sample: sample,
                displayFrameQuartz: primaryFrame
            )
        )
        XCTAssertLessThan(planPrimary.displayLocalRect.maxX, rawPrimary.maxX)
        XCTAssertEqual(
            planPrimary.cropTopQuartzY + planPrimary.predictedBaselineFromTopPt,
            primaryHeight - predCocoaPrimary,
            accuracy: 1e-5
        )

        // 2. External display positioned ABOVE primary (negative Quartz Y!)
        let extFrame = CGRect(x: 946, y: -1152, width: 2048, height: 1152)
        let rawExt = CGRect(x: 1500.0, y: -420.0, width: 7.0, height: 16.0)
        let predCocoaExt: CGFloat = 1524.65 // Quartz Y = 1117 - 1524.65 = -407.65
        let planExt = try XCTUnwrap(
            VisualBaselineAligner.computeCropPlan(
                rawAXRect: rawExt,
                primaryScreenHeight: primaryHeight,
                predictedBaselineCocoaY: predCocoaExt,
                font: font,
                sample: sample,
                displayFrameQuartz: extFrame
            )
        )
        XCTAssertGreaterThanOrEqual(planExt.displayLocalRect.minX, 0)
        XCTAssertGreaterThanOrEqual(planExt.displayLocalRect.minY, 0)
        XCTAssertLessThanOrEqual(planExt.displayLocalRect.maxX, extFrame.width)
        XCTAssertLessThanOrEqual(planExt.displayLocalRect.maxY, extFrame.height)
        XCTAssertEqual(
            planExt.cropTopQuartzY + planExt.predictedBaselineFromTopPt,
            primaryHeight - predCocoaExt,
            accuracy: 1e-5
        )
    }

    func testSubpixelBaselineMeasurementAcrossFontsThemesAndClutter() throws {
        let refFont = NSFont.systemFont(ofSize: 14)
        let testFonts: [(String, NSFont)] = [
            ("SF Pro 14", NSFont.systemFont(ofSize: 14)),
            ("Helvetica Neue 14", NSFont(name: "Helvetica Neue", size: 14) ?? refFont),
            ("Menlo 13.5", NSFont(name: "Menlo", size: 13.5) ?? refFont),
            ("Avenir Next 14", NSFont(name: "Avenir Next", size: 14) ?? refFont)
        ]
        let words = ["some", "typing", "Hello", "always"]
        let shifts: [CGFloat] = [-1.75, -0.50, -0.25, 0.0, 0.35, 0.75, 1.50]

        var totalErr = 0.0
        var sfErr = 0.0
        var sfCount = 0
        var totalCount = 0

        for (name, hostFont) in testFonts {
            for word in words {
                for shift in shifts {
                    for dark in [false, true] {
                        let img = renderSyntheticStrip(
                            text: word,
                            hostFont: hostFont,
                            cropWidthPt: 92,
                            cropHeightPt: 26,
                            scale: 2.0,
                            predictedBaselineFromTopPt: 17.0,
                            trueDeltaQuartzY: shift,
                            darkMode: dark,
                            addNeighborLines: true,
                            addCursor: true
                        )
                        let result = try XCTUnwrap(
                            VisualBaselineAligner.measureBaselineDeltaQuartzY(
                                capturedImage: img,
                                sampleText: word,
                                referenceFont: refFont,
                                scale: 2.0,
                                predictedBaselineFromTopPt: 17.0
                            ),
                            "Expected lock for \(name) word=\(word) shift=\(shift) dark=\(dark)"
                        )
                        let err = abs(Double(result.deltaQuartzY - shift))
                        totalErr += err
                        totalCount += 1
                        if name == "SF Pro 14" {
                            sfErr += err
                            sfCount += 1
                        }
                        XCTAssertLessThan(
                            err,
                            0.35,
                            "Excessive error for \(name) word=\(word) shift=\(shift) dark=\(dark): got \(result.deltaQuartzY)"
                        )
                    }
                }
            }
        }

        XCTAssertLessThan(sfErr / Double(sfCount), 0.06)
        XCTAssertLessThan(totalErr / Double(totalCount), 0.12)

        // Verify Quartz -> Cocoa sign conversion & 0.05 pt quantization:
        // Screen text 0.37 pt LOWER (+0.37 Quartz) -> Cocoa baseline must move DOWN by -0.35 pt.
        XCTAssertEqual(
            VisualBaselineAligner.lockedCocoaBaselineY(predictedBaselineCocoaY: 300.0, deltaQuartzY: 0.37),
            299.65,
            accuracy: 1e-6
        )
        // Screen text 0.48 pt HIGHER (-0.48 Quartz) -> Cocoa baseline must move UP by +0.50 pt.
        XCTAssertEqual(
            VisualBaselineAligner.lockedCocoaBaselineY(predictedBaselineCocoaY: 300.0, deltaQuartzY: -0.48),
            300.50,
            accuracy: 1e-6
        )
    }

    func testRejectsBlankAndSolidBlockImages() {
        let refFont = NSFont.systemFont(ofSize: 14)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!

        // 1. Blank background (no ink)
        let blankCtx = CGContext(
            data: nil, width: 180, height: 52,
            bitsPerComponent: 8, bytesPerRow: 180 * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        blankCtx.setFillColor(NSColor.white.cgColor)
        blankCtx.fill(CGRect(x: 0, y: 0, width: 180, height: 52))
        XCTAssertNil(
            VisualBaselineAligner.measureBaselineDeltaQuartzY(
                capturedImage: blankCtx.makeImage()!,
                sampleText: "some",
                referenceFont: refFont,
                scale: 2.0,
                predictedBaselineFromTopPt: 17.0
            )
        )

        // 2. Solid full-height UI bar / block (touches top and bottom edges)
        let blockCtx = CGContext(
            data: nil, width: 180, height: 52,
            bitsPerComponent: 8, bytesPerRow: 180 * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        blockCtx.setFillColor(NSColor.white.cgColor)
        blockCtx.fill(CGRect(x: 0, y: 0, width: 180, height: 52))
        blockCtx.setFillColor(NSColor.black.cgColor)
        blockCtx.fill(CGRect(x: 30, y: 0, width: 80, height: 52))
        XCTAssertNil(
            VisualBaselineAligner.measureBaselineDeltaQuartzY(
                capturedImage: blockCtx.makeImage()!,
                sampleText: "some",
                referenceFont: refFont,
                scale: 2.0,
                predictedBaselineFromTopPt: 17.0
            )
        )
    }

    func testRejectsUnderlineAndSpellcheckSquiggleFalseShifts() {
        let refFont = NSFont.systemFont(ofSize: 14)
        for dark in [false, true] {
            for word in ["some", "hello", "typing"] {
                let underlined = renderSyntheticStrip(
                    text: word,
                    hostFont: refFont,
                    cropWidthPt: 92,
                    cropHeightPt: 26,
                    scale: 2.0,
                    predictedBaselineFromTopPt: 17.0,
                    trueDeltaQuartzY: 0.0,
                    darkMode: dark,
                    addNeighborLines: false,
                    addCursor: false,
                    addUnderlineOffsetPt: 1.5,
                    underlineColor: NSColor.systemRed
                )
                if let res = VisualBaselineAligner.measureBaselineDeltaQuartzY(
                    capturedImage: underlined,
                    sampleText: word,
                    referenceFont: refFont,
                    scale: 2.0,
                    predictedBaselineFromTopPt: 17.0
                ) {
                    // Either reject as ambiguous/cluttered OR stay accurate within 0.25 pt (never lock onto the +1.5 pt underline!).
                    XCTAssertLessThan(
                        abs(Double(res.deltaQuartzY)),
                        0.25,
                        "Underline caused false shift for word=\(word) dark=\(dark): \(res.deltaQuartzY)"
                    )
                }
            }
        }
    }

    func testShortWordsDescendersTightLineSpacingAndShortCaret() throws {
        let refFont = NSFont.systemFont(ofSize: 14)
        let cases: [(word: String, shift: CGFloat, tight: Bool)] = [
            ("th", 0.35, false),
            ("in", -0.50, true),
            ("apply", 0.50, false),
            ("pigs", -0.35, true),
            ("some", 0.25, true)
        ]

        for c in cases {
            let img = renderSyntheticStrip(
                text: c.word,
                hostFont: refFont,
                cropWidthPt: 88,
                cropHeightPt: 26,
                scale: 2.0,
                predictedBaselineFromTopPt: 17.0,
                trueDeltaQuartzY: c.shift,
                darkMode: true,
                addNeighborLines: true,
                neighborLineMultiplier: c.tight ? 1.25 : 1.45,
                addCursor: true
            )
            let res = try XCTUnwrap(
                VisualBaselineAligner.measureBaselineDeltaQuartzY(
                    capturedImage: img,
                    sampleText: c.word,
                    referenceFont: refFont,
                    scale: 2.0,
                    predictedBaselineFromTopPt: 17.0
                ),
                "Expected lock for word=\(c.word) shift=\(c.shift) tight=\(c.tight)"
            )
            XCTAssertLessThan(
                abs(Double(res.deltaQuartzY - c.shift)),
                0.25,
                "Inaccurate lock for word=\(c.word) shift=\(c.shift) tight=\(c.tight): got \(res.deltaQuartzY)"
            )
        }
    }

    func testSearchAnchorManualHintAndResidualEnvelopeRejection() {
        let cache = VisualBaselineCache()
        let priorKey = VisualPriorKey(bundleID: "com.example.app", displayKey: "builtin@2x", fontSize: 14.0)
        let lineKey = VisualLineKey(
            bundleID: "com.example.app",
            displayKey: "builtin@2x",
            elementHash: 42,
            axLineY: 500,
            axHeight: 16,
            fontSize: 14,
            scrollGeneration: 1
        )

        // Cold search uses plausible manual offset up to ±3.0 pt as hint.
        let coldRes = VisualBaselineResolution(baselineCocoaY: 302.0, isLineLocked: false, usedLearnedPrior: false)
        XCTAssertEqual(
            VisualBaselineAligner.measurementSearchAnchorCocoaY(
                resolution: coldRes,
                rawBaselineCocoaY: 300.0,
                fallbackBaselineCocoaY: 302.0
            ),
            302.0,
            accuracy: 1e-6
        )
        XCTAssertEqual(
            VisualBaselineAligner.measurementSearchAnchorCocoaY(
                resolution: coldRes,
                rawBaselineCocoaY: 300.0,
                fallbackBaselineCocoaY: 304.5
            ),
            303.0,
            accuracy: 1e-6
        )

        // Final residual > ±5.0 pt from raw AX must be rejected before entering line cache or priors.
        XCTAssertFalse(
            cache.recordLock(
                lineKey: lineKey,
                priorKey: priorKey,
                lockedBaselineCocoaY: 306.0,
                rawBaselineCocoaY: 300.0,
                caretX: 200.0,
                now: 10.0
            )
        )
        XCTAssertNil(cache.learnedPriorResidual(for: priorKey))
    }

    func testLineCacheElementHashIsolationSoftWrapAndFailureExpiry() {
        let cache = VisualBaselineCache()
        let priorKey = VisualPriorKey(bundleID: "com.t3tools.t3code", displayKey: "ext:4c2d@2x", fontSize: 14.0)
        let fieldA = VisualLineKey(
            bundleID: "com.t3tools.t3code",
            displayKey: "ext:4c2d@2x",
            elementHash: 101,
            axLineY: 817.0,
            axHeight: 16.0,
            fontSize: 14.0,
            scrollGeneration: 1
        )
        let fieldB = VisualLineKey(
            bundleID: "com.t3tools.t3code",
            displayKey: "ext:4c2d@2x",
            elementHash: 202,
            axLineY: 817.0,
            axHeight: 16.0,
            fontSize: 14.0,
            scrollGeneration: 1
        )

        XCTAssertTrue(
            cache.recordLock(
                lineKey: fieldA,
                priorKey: priorKey,
                lockedBaselineCocoaY: 299.60,
                rawBaselineCocoaY: 300.0,
                caretX: 220.0,
                now: 100.0
            )
        )

        // Different focused element at the same Y does NOT reuse fieldA's line lock, though it inherits the prior.
        let resB = cache.resolveInitialBaseline(
            lineKey: fieldB,
            priorKey: priorKey,
            rawBaselineCocoaY: 300.0,
            fallbackBaselineCocoaY: 300.70,
            currentCaretX: 220.0,
            now: 101.0
        )
        XCTAssertFalse(resB.isLineLocked)
        XCTAssertTrue(resB.usedLearnedPrior)

        // Small 6 pt left move (1-char backspace) stays locked; 24 pt left jump (soft wrap) invalidates.
        XCTAssertTrue(
            cache.resolveInitialBaseline(
                lineKey: fieldA,
                priorKey: priorKey,
                rawBaselineCocoaY: 300.0,
                fallbackBaselineCocoaY: 300.70,
                currentCaretX: 214.0,
                now: 102.0
            ).isLineLocked
        )
        XCTAssertFalse(
            cache.resolveInitialBaseline(
                lineKey: fieldA,
                priorKey: priorKey,
                rawBaselineCocoaY: 300.0,
                fallbackBaselineCocoaY: 300.70,
                currentCaretX: 196.0,
                now: 103.0
            ).isLineLocked
        )

        // Failure suppression expires after 12 seconds so transient glitches recover.
        cache.recordFailure(for: fieldB, caretX: 100.0, now: 200.0)
        cache.recordFailure(for: fieldB, caretX: 120.0, now: 201.0)
        cache.recordFailure(for: fieldB, caretX: 140.0, now: 202.0)
        XCTAssertFalse(cache.shouldAttemptCapture(for: fieldB, currentCaretX: 160.0, now: 205.0))
        XCTAssertTrue(cache.shouldAttemptCapture(for: fieldB, currentCaretX: 160.0, now: 215.0))
    }

    func testLineCacheSoftWrapInvalidationAndPriorMedian() {
        let cache = VisualBaselineCache()
        let priorKey = VisualPriorKey(bundleID: "com.t3tools.t3code", displayKey: "ext:4c2d@2x", fontSize: 14.0)
        let line1 = VisualLineKey(
            bundleID: "com.t3tools.t3code",
            displayKey: "ext:4c2d@2x",
            axLineY: 817.0,
            axHeight: 16.0,
            fontSize: 14.0,
            scrollGeneration: 1
        )

        // Cold state uses fallback baseline.
        let cold = cache.resolveInitialBaseline(
            lineKey: line1,
            priorKey: priorKey,
            rawBaselineCocoaY: 300.0,
            fallbackBaselineCocoaY: 300.70,
            currentCaretX: 200.0,
            now: 100.0
        )
        XCTAssertEqual(cold, VisualBaselineResolution(baselineCocoaY: 300.70, isLineLocked: false, usedLearnedPrior: false))

        // Record line 1 lock at 299.60 (residual = -0.40 relative to raw 300.0).
        cache.recordLock(
            lineKey: line1,
            priorKey: priorKey,
            lockedBaselineCocoaY: 299.60,
            rawBaselineCocoaY: 300.0,
            caretX: 220.0,
            now: 100.1
        )

        // Typing further right on the same line hits cache directly (0 ms!).
        let hit = cache.resolveInitialBaseline(
            lineKey: line1,
            priorKey: priorKey,
            rawBaselineCocoaY: 300.0,
            fallbackBaselineCocoaY: 300.70,
            currentCaretX: 260.0,
            now: 101.0
        )
        XCTAssertEqual(hit, VisualBaselineResolution(baselineCocoaY: 299.60, isLineLocked: true, usedLearnedPrior: false))
        XCTAssertFalse(cache.shouldAttemptCapture(for: line1, currentCaretX: 260.0, now: 101.0))

        // Caret wraps sharply left on the same Y (auto-scrolling fixed-height composer) -> invalidates line & uses prior!
        let wrapped = cache.resolveInitialBaseline(
            lineKey: line1,
            priorKey: priorKey,
            rawBaselineCocoaY: 300.0,
            fallbackBaselineCocoaY: 300.70,
            currentCaretX: 120.0,
            now: 102.0
        )
        XCTAssertEqual(wrapped, VisualBaselineResolution(baselineCocoaY: 299.60, isLineLocked: false, usedLearnedPrior: true))
        XCTAssertTrue(cache.shouldAttemptCapture(for: line1, currentCaretX: 120.0, now: 102.0))

        // Median prior resists an outlier sample (-0.40, -0.35, +1.20 -> median -0.35).
        let line2 = VisualLineKey(bundleID: "com.t3tools.t3code", displayKey: "ext:4c2d@2x", axLineY: 837.0, axHeight: 16.0, fontSize: 14.0, scrollGeneration: 1)
        let line3 = VisualLineKey(bundleID: "com.t3tools.t3code", displayKey: "ext:4c2d@2x", axLineY: 857.0, axHeight: 16.0, fontSize: 14.0, scrollGeneration: 1)
        cache.recordLock(lineKey: line2, priorKey: priorKey, lockedBaselineCocoaY: 279.65, rawBaselineCocoaY: 280.0, caretX: 150.0, now: 103.0)
        cache.recordLock(lineKey: line3, priorKey: priorKey, lockedBaselineCocoaY: 261.20, rawBaselineCocoaY: 260.0, caretX: 150.0, now: 104.0)
        XCTAssertEqual(cache.learnedPriorResidual(for: priorKey) ?? .nan, -0.35, accuracy: 1e-6)

        // Failure backoff throttles immediate retries on the same position, allows retry after moving or cooldown, and caps at 3.
        let badLine = VisualLineKey(bundleID: "com.t3tools.t3code", displayKey: "ext:4c2d@2x", axLineY: 900.0, axHeight: 16.0, fontSize: 14.0, scrollGeneration: 2)
        cache.recordFailure(for: badLine, caretX: 100.0, now: 200.0)
        XCTAssertFalse(cache.shouldAttemptCapture(for: badLine, currentCaretX: 104.0, now: 200.1))
        XCTAssertTrue(cache.shouldAttemptCapture(for: badLine, currentCaretX: 120.0, now: 200.1))
        XCTAssertTrue(cache.shouldAttemptCapture(for: badLine, currentCaretX: 104.0, now: 201.0))
        cache.recordFailure(for: badLine, caretX: 120.0, now: 201.0)
        cache.recordFailure(for: badLine, caretX: 140.0, now: 202.0)
        XCTAssertFalse(cache.shouldAttemptCapture(for: badLine, currentCaretX: 200.0, now: 210.0))
    }

    // MARK: - Synthetic Strip Renderer

    private func renderSyntheticStrip(
        text: String,
        hostFont: NSFont,
        cropWidthPt: CGFloat,
        cropHeightPt: CGFloat,
        scale: CGFloat,
        predictedBaselineFromTopPt: CGFloat,
        trueDeltaQuartzY: CGFloat,
        darkMode: Bool,
        addNeighborLines: Bool,
        neighborLineMultiplier: CGFloat = 1.45,
        addCursor: Bool,
        addUnderlineOffsetPt: CGFloat? = nil,
        underlineColor: NSColor? = nil
    ) -> CGImage {
        let pxW = Int((cropWidthPt * scale).rounded())
        let pxH = Int((cropHeightPt * scale).rounded())
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: pxW * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.scaleBy(x: scale, y: scale)

        let bg: NSColor = darkMode
            ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
            : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1)
        let fg: NSColor = darkMode
            ? NSColor(srgbRed: 0.90, green: 0.91, blue: 0.93, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)
        ctx.setFillColor(bg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: cropWidthPt, height: cropHeightPt))

        let actualBaselineFromTop = predictedBaselineFromTopPt + trueDeltaQuartzY
        let actualBaselineCG = cropHeightPt - actualBaselineFromTop
        let snappedCG = (actualBaselineCG * scale).rounded() / scale
        let subDelta = actualBaselineCG - snappedCG

        let textCtx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: pxW * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        textCtx.scaleBy(x: scale, y: scale)
        textCtx.setShouldSmoothFonts(true)
        textCtx.setAllowsFontSubpixelPositioning(true)
        textCtx.setShouldSubpixelPositionFonts(true)

        let attr = NSAttributedString(string: text, attributes: [.font: hostFont, .foregroundColor: fg])
        let line = CTLineCreateWithAttributedString(attr)
        let textW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let textX = max(2.0, cropWidthPt - textW - 4.0)

        textCtx.textMatrix = .identity
        textCtx.textPosition = CGPoint(x: textX, y: snappedCG)
        CTLineDraw(line, textCtx)

        if addNeighborLines {
            let lineStep = hostFont.pointSize * neighborLineMultiplier
            let above = CTLineCreateWithAttributedString(
                NSAttributedString(string: "pgqyjp", attributes: [.font: hostFont, .foregroundColor: fg])
            )
            textCtx.textPosition = CGPoint(x: textX, y: snappedCG + lineStep)
            CTLineDraw(above, textCtx)
            let below = CTLineCreateWithAttributedString(
                NSAttributedString(string: "THKBLd", attributes: [.font: hostFont, .foregroundColor: fg])
            )
            textCtx.textPosition = CGPoint(x: textX, y: snappedCG - lineStep)
            CTLineDraw(below, textCtx)
        }

        if let textImg = textCtx.makeImage() {
            ctx.interpolationQuality = .high
            ctx.draw(textImg, in: CGRect(x: 0, y: subDelta, width: cropWidthPt, height: cropHeightPt))
        }

        if let underlineOffset = addUnderlineOffsetPt {
            ctx.setFillColor((underlineColor ?? fg).cgColor)
            ctx.fill(CGRect(
                x: textX,
                y: actualBaselineCG - underlineOffset - 1.0,
                width: textW,
                height: 1.2
            ))
        }

        if addCursor {
            ctx.setFillColor(fg.cgColor)
            ctx.fill(CGRect(
                x: cropWidthPt - 2.0,
                y: actualBaselineCG + hostFont.descender,
                width: 1.5,
                height: hostFont.ascender - hostFont.descender
            ))
        }

        return ctx.makeImage()!
    }
}
