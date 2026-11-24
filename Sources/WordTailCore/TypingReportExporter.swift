import Foundation

// These existing models live in another file and store only immutable Sendable values.
extension AppActivitySummary: @unchecked Sendable {}
extension RankedCountItem: @unchecked Sendable {}

public struct TypingWrappedSummary: Equatable, Sendable {
    public let rangeLabel: String
    public let generatedAt: Date
    public let totalKeystrokes: Int
    public let totalClicks: Int
    public let charactersSaved: Int
    public let tabsAccepted: Int
    public let averageBurstWPM: Int
    public let peakBurstWPM: Int
    public let romanSharePercent: Double
    public let cjkSharePercent: Double
    public let leftHandPercent: Double
    public let rightHandPercent: Double
    public let mouseDistanceMeters: Double
    public let scrollDistanceMeters: Double
    public let peakKPS: Int
    public let peakHour: Int?
    public let topApps: [AppActivitySummary]
    public let topShortcuts: [RankedCountItem]
    public let topTypoTraps: [TypoTrapEntry]

    public var marathonsEquivalent: Double {
        mouseDistanceMeters / KeyStatsAggregateSnapshot.marathonMeters
    }

    public var everestsEquivalent: Double {
        scrollDistanceMeters / KeyStatsAggregateSnapshot.everestMeters
    }
}

public enum TypingReportExporter {
    /// The range describes KeyStats. Completion, speed, and typo metrics retain the supplied insights scope.
    public static func summarize(
        keyStats: KeyStatsAggregateSnapshot,
        insights: TypingInsightsSnapshot,
        now: Date = Date()
    ) -> TypingWrappedSummary {
        let layouts = shares(keyStats.romanKeyPresses, keyStats.nonRomanKeyPresses)
        let hands = shares(keyStats.leftHandPresses, keyStats.rightHandPresses)
        let hourlyKeys = keyStats.hourlyKeys.prefix(24)
        let peakHour = hourlyKeys.max().flatMap { $0 > 0 ? hourlyKeys.firstIndex(of: $0) : nil }

        return TypingWrappedSummary(
            rangeLabel: keyStats.range.rawValue,
            generatedAt: now,
            totalKeystrokes: keyStats.totalKeyPresses,
            totalClicks: keyStats.totalClicks,
            charactersSaved: insights.charactersSaved,
            tabsAccepted: insights.tabsAccepted,
            averageBurstWPM: insights.averageBurstWPM,
            peakBurstWPM: insights.peakBurstWPM,
            romanSharePercent: layouts.first,
            cjkSharePercent: layouts.second,
            leftHandPercent: hands.first,
            rightHandPercent: hands.second,
            mouseDistanceMeters: keyStats.mouseDistanceMeters,
            scrollDistanceMeters: keyStats.scrollDistanceMeters,
            peakKPS: keyStats.peakKPS,
            peakHour: peakHour,
            topApps: keyStats.topApps,
            topShortcuts: keyStats.topShortcuts,
            topTypoTraps: insights.typoTraps
        )
    }

    public static func csv(dailyPoints: [DailyActivityPoint], appSummaries: [AppActivitySummary]) -> Data {
        var rows = ["record_type,key,label,keystrokes,clicks,mouse_meters,scroll_meters,characters_saved"]
        rows.reserveCapacity(1 + dailyPoints.count + appSummaries.count)

        // Daily points have no savings count, and per-app summaries have no mouse distance.
        for day in dailyPoints {
            rows.append(csvRow(
                type: "daily", key: day.dateKey, label: day.dateKey,
                numbers: [String(day.keyPresses), String(day.clicks), String(day.mouseDistanceMeters),
                          String(day.scrollDistanceMeters), ""]
            ))
        }
        for app in appSummaries {
            rows.append(csvRow(
                type: "app", key: app.bundleID, label: app.displayName,
                numbers: [String(app.keyPresses), String(app.clicks), "",
                          String(app.scrollMeters), String(app.charactersSaved)]
            ))
        }

        return Data((rows.joined(separator: "\r\n") + "\r\n").utf8)
    }

    public static func markdownReport(summary: TypingWrappedSummary, dailyPoints: [DailyActivityPoint]) -> String {
        let peakHour = summary.peakHour.map { String(format: "%02d:00", $0) } ?? "No activity"
        var lines = [
            "# WordTail Typing Wrapped",
            "",
            "**KeyStats range:** \(markdownText(summary.rangeLabel))  ",
            "**Generated:** \(ISO8601DateFormatter().string(from: summary.generatedAt))",
            "",
            "## Summary",
            "",
            "Completion, burst speed, and typo trap figures use the scope of the typing insights.",
            "",
            "- **Keystrokes:** \(summary.totalKeystrokes)",
            "- **Clicks:** \(summary.totalClicks)",
            "- **Characters saved:** \(summary.charactersSaved)",
            "- **Tabs accepted:** \(summary.tabsAccepted)",
            "- **Burst speed:** \(summary.averageBurstWPM) WPM average, \(summary.peakBurstWPM) WPM peak",
            "- **Keyboard layout:** \(decimal(summary.romanSharePercent))% Roman, \(decimal(summary.cjkSharePercent))% CJK",
            "- **Hand balance:** \(decimal(summary.leftHandPercent))% left, \(decimal(summary.rightHandPercent))% right",
            "- **Mouse distance:** \(decimal(summary.mouseDistanceMeters)) m (\(decimal(summary.marathonsEquivalent)) marathons)",
            "- **Scroll distance:** \(decimal(summary.scrollDistanceMeters)) m (\(decimal(summary.everestsEquivalent)) Everests)",
            "- **Peak keystrokes per second:** \(summary.peakKPS)",
            "- **Peak hour:** \(peakHour)",
            "",
            "## Top Apps",
            "",
            "| App | Keystrokes | Clicks | Characters saved |",
            "| --- | ---: | ---: | ---: |"
        ]
        if summary.topApps.isEmpty {
            lines.append("| No app activity | | | |")
        }
        for app in summary.topApps {
            lines.append("| \(markdownText(app.displayName)) | \(app.keyPresses) | \(app.clicks) | \(app.charactersSaved) |")
        }

        lines += ["", "## Top Shortcuts", ""]
        if summary.topShortcuts.isEmpty {
            lines.append("No shortcuts recorded.")
        }
        for shortcut in summary.topShortcuts {
            lines.append("- \(markdownText(shortcut.label)) · \(shortcut.count)")
        }

        lines += ["", "## Top Typo Traps", ""]
        if summary.topTypoTraps.isEmpty {
            lines.append("No typo traps recorded.")
        }
        for trap in summary.topTypoTraps {
            lines.append("- \(markdownText(trap.commonMistype)) → \(markdownText(trap.word)) · \(trap.count)")
        }

        lines += [
            "", "## Daily Trend", "",
            "| Date | Keystrokes | Clicks | Mouse (m) | Scroll (m) |",
            "| --- | ---: | ---: | ---: | ---: |"
        ]
        if dailyPoints.isEmpty {
            lines.append("| No daily activity | | | | |")
        }
        for day in dailyPoints {
            lines.append(
                "| \(markdownText(day.dateKey)) | \(day.keyPresses) | \(day.clicks) | \(decimal(day.mouseDistanceMeters)) | \(decimal(day.scrollDistanceMeters)) |"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func shares(_ first: Int, _ second: Int) -> (first: Double, second: Double) {
        let total = Double(first) + Double(second)
        guard total > 0 else { return (0, 0) }
        return (Double(first) / total * 100, Double(second) / total * 100)
    }

    private static func csvRow(type: String, key: String, label: String, numbers: [String]) -> String {
        ([type, key, label].map(csvText) + numbers).joined(separator: ",")
    }

    private static func csvText(_ value: String) -> String {
        let prefix = value.unicodeScalars.first { scalar in
            scalar == "\t" || scalar == "\r" || !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        let dangerous = prefix.map { "=+-@\t\r".unicodeScalars.contains($0) } ?? false
        let safe = dangerous ? "'" + value : value
        let quotedCharacters = "\",\r\n\t".unicodeScalars
        guard safe.unicodeScalars.contains(where: quotedCharacters.contains) else { return safe }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func markdownText(_ value: String) -> String {
        let singleLine = value.split(whereSeparator: \.isNewline).joined(separator: " ")
        let escapedHTML = singleLine
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return escapedHTML.map { "\\|`[]*_~".contains($0) ? "\\\($0)" : String($0) }.joined()
    }
}
