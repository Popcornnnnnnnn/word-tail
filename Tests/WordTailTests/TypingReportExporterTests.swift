import Foundation
import XCTest
import WordTailCore

final class TypingReportExporterTests: XCTestCase {
    private let generatedAt = Date(timeIntervalSince1970: 0)

    func testEmptySummaryHasZeroSharesAndNoPeakHour() {
        let summary = TypingReportExporter.summarize(
            keyStats: KeyStatsAggregateSnapshot(),
            insights: TypingInsightsSnapshot(),
            now: generatedAt
        )

        XCTAssertEqual(summary.rangeLabel, "Today")
        XCTAssertEqual(summary.generatedAt, generatedAt)
        XCTAssertEqual(summary.totalKeystrokes, 0)
        XCTAssertEqual(summary.totalClicks, 0)
        XCTAssertEqual(summary.charactersSaved, 0)
        XCTAssertEqual(summary.tabsAccepted, 0)
        XCTAssertEqual(summary.averageBurstWPM, 0)
        XCTAssertEqual(summary.peakBurstWPM, 0)
        XCTAssertEqual(summary.romanSharePercent, 0)
        XCTAssertEqual(summary.cjkSharePercent, 0)
        XCTAssertEqual(summary.leftHandPercent, 0)
        XCTAssertEqual(summary.rightHandPercent, 0)
        XCTAssertEqual(summary.marathonsEquivalent, 0)
        XCTAssertEqual(summary.everestsEquivalent, 0)
        XCTAssertEqual(summary.peakKPS, 0)
        XCTAssertNil(summary.peakHour)
        XCTAssertTrue(summary.topApps.isEmpty)
        XCTAssertTrue(summary.topShortcuts.isEmpty)
        XCTAssertTrue(summary.topTypoTraps.isEmpty)
    }

    func testSummaryUsesMeasuredSharesInsightsAndRankings() {
        let app = makeApp(key: "com.example.editor", label: "Editor")
        let shortcut = RankedCountItem(label: "⌘S", count: 9)
        let typo = TypoTrapEntry(word: "receive", commonMistype: "recieve", count: 3)
        var hours = Array(repeating: 0, count: 24)
        hours[0] = 10
        hours[9] = 40
        hours[18] = 40
        let keyStats = KeyStatsAggregateSnapshot(
            range: .days7,
            totalKeyPresses: 120,
            totalClicks: 15,
            mouseDistanceMeters: 84_390,
            scrollDistanceMeters: 4_424.43,
            peakKPS: 12,
            leftHandPresses: 1,
            rightHandPresses: 2,
            romanKeyPresses: 81,
            nonRomanKeyPresses: 27,
            topShortcuts: [shortcut],
            topApps: [app],
            hourlyKeys: hours
        )
        let insights = TypingInsightsSnapshot(
            tabsAccepted: 12, charactersSaved: 45, averageBurstWPM: 52, peakBurstWPM: 86, typoTraps: [typo]
        )
        let summary = TypingReportExporter.summarize(keyStats: keyStats, insights: insights, now: generatedAt)

        XCTAssertEqual(summary.rangeLabel, "7 Days")
        XCTAssertEqual(summary.generatedAt, generatedAt)
        XCTAssertEqual(summary.totalKeystrokes, 120)
        XCTAssertEqual(summary.totalClicks, 15)
        XCTAssertEqual(summary.charactersSaved, 45)
        XCTAssertEqual(summary.tabsAccepted, 12)
        XCTAssertEqual(summary.averageBurstWPM, 52)
        XCTAssertEqual(summary.peakBurstWPM, 86)
        XCTAssertEqual(summary.romanSharePercent, 75)
        XCTAssertEqual(summary.cjkSharePercent, 25)
        XCTAssertEqual(summary.leftHandPercent, 100.0 / 3, accuracy: 0.000_001)
        XCTAssertEqual(summary.rightHandPercent, 200.0 / 3, accuracy: 0.000_001)
        XCTAssertEqual(summary.mouseDistanceMeters, 84_390)
        XCTAssertEqual(summary.scrollDistanceMeters, 4_424.43)
        XCTAssertEqual(summary.marathonsEquivalent, 2)
        XCTAssertEqual(summary.everestsEquivalent, 0.5)
        XCTAssertEqual(summary.peakKPS, 12)
        XCTAssertEqual(summary.peakHour, 9)
        XCTAssertEqual(summary.topApps, [app])
        XCTAssertEqual(summary.topShortcuts, [shortcut])
        XCTAssertEqual(summary.topTypoTraps, [typo])
    }

    func testCSVUsesCRLFRowsAndQuotesSpecialText() {
        let day = DailyActivityPoint(
            dateKey: "2026-11-24", keyPresses: 11, clicks: 3, mouseDistanceMeters: 1.25, scrollDistanceMeters: 0.5
        )
        let app = makeApp(key: "com.example,editor", label: "Editor \"Pro\"\r\nNotes\nMore")
        let data = TypingReportExporter.csv(dailyPoints: [day], appSummaries: [app])

        let expected = "record_type,key,label,keystrokes,clicks,mouse_meters,scroll_meters,characters_saved\r\n"
            + "daily,2026-11-24,2026-11-24,11,3,1.25,0.5,\r\n"
            + "app,\"com.example,editor\",\"Editor \"\"Pro\"\"\r\nNotes\nMore\",90,4,,2.5,18\r\n"
        XCTAssertEqual(String(decoding: data, as: UTF8.self), expected)
    }

    func testCSVDefusesFormulasInKeysAndLabels() {
        let cases = [
            ("=SUM(1)", "'=SUM(1)"),
            ("+1", "'+1"),
            ("-1", "'-1"),
            ("@lookup", "'@lookup"),
            ("\tplain", "\"'\tplain\""),
            ("\rplain", "\"'\rplain\""),
            ("\r\nplain", "\"'\r\nplain\""),
            ("  =SUM(1)", "'  =SUM(1)"),
            (" \tplain", "\"' \tplain\""),
            ("AB-123", "AB-123")
        ]
        for (input, escaped) in cases {
            let app = makeApp(key: input, label: input)
            let data = TypingReportExporter.csv(dailyPoints: [], appSummaries: [app])
            XCTAssertTrue(String(decoding: data, as: UTF8.self).hasSuffix("app,\(escaped),\(escaped),90,4,,2.5,18\r\n"))
        }

        let day = DailyActivityPoint(dateKey: "@day", keyPresses: 0, clicks: 0, mouseDistanceMeters: 0, scrollDistanceMeters: 0)
        let data = TypingReportExporter.csv(dailyPoints: [day], appSummaries: [])
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasSuffix("daily,'@day,'@day,0,0,0.0,0.0,\r\n"))
    }

    func testMarkdownIncludesSummaryRankingsAndDailyTrend() {
        let day = DailyActivityPoint(
            dateKey: "2026-11-24", keyPresses: 90, clicks: 4, mouseDistanceMeters: 1.25, scrollDistanceMeters: 2.5
        )
        let keyStats = KeyStatsAggregateSnapshot(
            totalKeyPresses: 90,
            topShortcuts: [RankedCountItem(label: "⌘S", count: 5)],
            topApps: [makeApp(key: "com.example.editor", label: "Editor | Notes\nPro")]
        )
        let insights = TypingInsightsSnapshot(
            averageBurstWPM: 55,
            peakBurstWPM: 97,
            typoTraps: [TypoTrapEntry(word: "the", commonMistype: "teh", count: 4)]
        )
        let summary = TypingReportExporter.summarize(keyStats: keyStats, insights: insights, now: generatedAt)
        let report = TypingReportExporter.markdownReport(summary: summary, dailyPoints: [day])

        for heading in ["# WordTail Typing Wrapped", "## Summary", "## Top Apps", "## Top Shortcuts", "## Top Typo Traps", "## Daily Trend"] {
            XCTAssertTrue(report.split(separator: "\n").contains(Substring(heading)), "Missing \(heading)")
        }
        XCTAssertTrue(report.contains("1970-01-01T00:00:00Z"))
        XCTAssertTrue(report.contains("55 WPM average, 97 WPM peak"))
        XCTAssertTrue(report.contains("| Editor \\| Notes Pro | 90 | 4 | 18 |"))
        XCTAssertTrue(report.contains("- ⌘S · 5"))
        XCTAssertTrue(report.contains("- teh → the · 4"))
        XCTAssertTrue(report.contains("| 2026-11-24 | 90 | 4 | 1.25 | 2.50 |"))
        XCTAssertTrue(report.contains("Non-Roman"))
    }

    func testAllTimeReportSnapshotRemovesAppPreviewCap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WordTailReportCap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = KeyStatsStore(fileURL: dir.appendingPathComponent("stats.json"))
        for idx in 0..<205 {
            store.recordKeyDown(
                keyCode: 0,
                rawFlags: 0,
                isAutoRepeat: false,
                isSecureInput: false,
                isRomanLayout: true,
                appBundleID: String(format: "com.example.app%03d", idx),
                appName: "App \(idx)"
            )
        }
        store.flushNow()

        XCTAssertEqual(store.snapshot(for: .allTime, deviceScope: .allDevices).topApps.count, 200)
        XCTAssertEqual(store.allTimeReportSnapshot(deviceScope: .allDevices).topApps.count, 205)

        // Mouse-only / scroll-only day appears in uncapped all-time report dailyTrend even with 0 keys/clicks
        let mouseOnlyStore = KeyStatsStore(
            fileURL: dir.appendingPathComponent("mouse-only-stats.json"),
            nowProvider: { Date(timeIntervalSince1970: 1_763_626_400) }
        )
        mouseOnlyStore.recordMouseMove(to: CGPoint(x: 0, y: 0))
        mouseOnlyStore.recordMouseMove(to: CGPoint(x: 400, y: 0))
        mouseOnlyStore.flushNow()
        let reportSnap = mouseOnlyStore.allTimeReportSnapshot(deviceScope: .allDevices)
        XCTAssertEqual(reportSnap.dailyTrend.count, 1)
        XCTAssertEqual(reportSnap.dailyTrend.first?.keyPresses, 0)
        XCTAssertGreaterThan(reportSnap.dailyTrend.first?.mouseDistanceMeters ?? 0, 0)

        // charsSavedOverride credits net characters saved rather than rewritten prefix + spacing length
        let tracker = TypingHabitTracker(fileURL: dir.appendingPathComponent("insights.json"))
        _ = tracker.recordTabAccepted(
            fullWord: "algorithm",
            insertedText: " algorithm ",
            previousWordFromContext: nil,
            bundleID: "com.apple.Notes",
            persistAsync: false,
            charsSavedOverride: 5
        )
        XCTAssertEqual(tracker.snapshot().charactersSaved, 5)
    }

    private func makeApp(key: String, label: String) -> AppActivitySummary {
        AppActivitySummary(bundleID: key, displayName: label, keyPresses: 90, clicks: 4, scrollMeters: 2.5, charactersSaved: 18)
    }
}
