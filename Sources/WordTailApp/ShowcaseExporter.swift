import AppKit
import SwiftUI
import WordTailCore

enum ShowcaseExporter {
    @MainActor
    static func exportAll(to outputDirPath: String) throws {
        let outDir = URL(fileURLWithPath: outputDirPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // Ensure crisp light appearance for clean, high-contrast GitHub README presentation
        NSApp.appearance = NSAppearance(named: .aqua)

        let sampleBuckets: [HourlyTypingBucket] = [
            HourlyTypingBucket(hour: 0, typedLetters: 90, backspaces: 9, burstCharacters: 75, burstSeconds: 15),
            HourlyTypingBucket(hour: 1, typedLetters: 35, backspaces: 4, burstCharacters: 30, burstSeconds: 7),
            HourlyTypingBucket(hour: 2, typedLetters: 0),
            HourlyTypingBucket(hour: 3, typedLetters: 0),
            HourlyTypingBucket(hour: 4, typedLetters: 0),
            HourlyTypingBucket(hour: 5, typedLetters: 0),
            HourlyTypingBucket(hour: 6, typedLetters: 0),
            HourlyTypingBucket(hour: 7, typedLetters: 45, backspaces: 2, burstCharacters: 40, burstSeconds: 7.2),
            HourlyTypingBucket(hour: 8, typedLetters: 180, backspaces: 6, burstCharacters: 160, burstSeconds: 26),
            HourlyTypingBucket(hour: 9, typedLetters: 410, backspaces: 11, burstCharacters: 360, burstSeconds: 54),
            HourlyTypingBucket(hour: 10, typedLetters: 620, backspaces: 15, burstCharacters: 540, burstSeconds: 79),
            HourlyTypingBucket(hour: 11, typedLetters: 530, backspaces: 16, burstCharacters: 470, burstSeconds: 72),
            HourlyTypingBucket(hour: 12, typedLetters: 140, backspaces: 5, burstCharacters: 110, burstSeconds: 18),
            HourlyTypingBucket(hour: 13, typedLetters: 310, backspaces: 10, burstCharacters: 270, burstSeconds: 43),
            HourlyTypingBucket(hour: 14, typedLetters: 580, backspaces: 18, burstCharacters: 500, burstSeconds: 75),
            HourlyTypingBucket(hour: 15, typedLetters: 640, backspaces: 19, burstCharacters: 560, burstSeconds: 82),
            HourlyTypingBucket(hour: 16, typedLetters: 490, backspaces: 17, burstCharacters: 420, burstSeconds: 66),
            HourlyTypingBucket(hour: 17, typedLetters: 290, backspaces: 11, burstCharacters: 240, burstSeconds: 39),
            HourlyTypingBucket(hour: 18, typedLetters: 120, backspaces: 5, burstCharacters: 95, burstSeconds: 16),
            HourlyTypingBucket(hour: 19, typedLetters: 210, backspaces: 8, burstCharacters: 180, burstSeconds: 30),
            HourlyTypingBucket(hour: 20, typedLetters: 380, backspaces: 15, burstCharacters: 320, burstSeconds: 52),
            HourlyTypingBucket(hour: 21, typedLetters: 420, backspaces: 19, burstCharacters: 350, burstSeconds: 58),
            HourlyTypingBucket(hour: 22, typedLetters: 310, backspaces: 24, burstCharacters: 260, burstSeconds: 47),
            HourlyTypingBucket(hour: 23, typedLetters: 220, backspaces: 21, burstCharacters: 185, burstSeconds: 35)
        ]

        let sampleInsights = TypingInsightsSnapshot(
            tabsAccepted: 618,
            charactersSaved: 3_420,
            suggestionsShown: 1_490,
            totalTypedLetters: 5_985,
            totalBackspaces: 235,
            averageBurstWPM: 76,
            peakBurstWPM: 98,
            imeSwitches: 84,
            hourlyBuckets: sampleBuckets,
            typoTraps: [
                TypoTrapEntry(word: "definitely", commonMistype: "definately", count: 7),
                TypoTrapEntry(word: "receive", commonMistype: "recieve", count: 5),
                TypoTrapEntry(word: "separate", commonMistype: "seperate", count: 4),
                TypoTrapEntry(word: "asynchronous", commonMistype: "asyncronous", count: 3)
            ],
            fillerHabits: [
                FillerHabitEntry(word: "actually", count: 14),
                FillerHabitEntry(word: "basically", count: 9)
            ],
            topSavedWords: [
                SavedWordEntry(word: "implementation", charsSaved: 168),
                SavedWordEntry(word: "quantitative", charsSaved: 132)
            ]
        )

        let sampleBigrams: [BigramHabitEntry] = [
            BigramHabitEntry(previousWord: "pull", word: "request", count: 12),
            BigramHabitEntry(previousWord: "feature", word: "flag", count: 8),
            BigramHabitEntry(previousWord: "command", word: "line", count: 6)
        ]

        let sampleApps: [AppOffsetItem] = [
            AppOffsetItem(
                bundleID: "com.openai.codex",
                displayName: "Codex (ChatGPT)",
                icon: srgbIcon(forBundleID: "com.openai.codex"),
                offset: 0.70
            ),
            AppOffsetItem(
                bundleID: "com.google.Chrome",
                displayName: "Google Chrome",
                icon: srgbIcon(forBundleID: "com.google.Chrome"),
                offset: 0.55
            ),
            AppOffsetItem(
                bundleID: "com.apple.Notes",
                displayName: "Notes",
                icon: srgbIcon(forBundleID: "com.apple.Notes"),
                offset: 0.70
            ),
            AppOffsetItem(
                bundleID: "com.raycast.macos",
                displayName: "Raycast",
                icon: srgbIcon(forBundleID: "com.raycast.macos"),
                offset: 0.50
            )
        ]

        let sampleVocab: [VocabularyEntry] = [
            VocabularyEntry(word: "TypeScript", count: 19, isCustom: true),
            VocabularyEntry(word: "idempotent", count: 14, isCustom: false),
            VocabularyEntry(word: "quantitative", count: 11, isCustom: false)
        ]

        let sampleHeatmap: [String: Int] = [
            "Space": 4_120, "E": 2_890, "T": 2_210, "A": 1_980, "O": 1_840, "I": 1_790, "N": 1_720,
            "S": 1_640, "R": 1_590, "L": 1_240, "D": 1_090, "C": 1_040, "U": 890, "M": 780,
            "P": 740, "F": 620, "G": 590, "W": 560, "Y": 540, "B": 480, "V": 390, "K": 360,
            "Delete": 1_310, "Return": 860, "Tab": 640, "LeftCmd": 980, "LeftShift": 870, "RightShift": 290,
            "LeftOption": 310, "Ctrl": 240, "Esc": 210, ".": 420, ",": 380, "/": 190, "-": 210,
            "1": 140, "2": 180, "3": 120, "Left": 240, "Right": 280, "Up": 190, "Down": 260, "Fn": 150
        ]

        let sampleCalDays: [CalendarActivityDay] = (0..<98).map { idx in
            let wave = ((idx * 17 + 11) % 29)
            let weekendDip = (idx % 7 == 5 || idx % 7 == 6) ? 0.35 : 1.0
            let keys = wave < 3 ? 0 : Int(Double(1_800 + wave * 290) * weekendDip)
            let clicks = keys == 0 ? 0 : max(80, keys / 7)
            return CalendarActivityDay(dateKey: String(format: "2026-%02d-%02d", 8 + (idx / 30), 1 + (idx % 28)), keyPresses: keys, clicks: clicks)
        }

        let appIconsMap: [String: NSImage] = [
            "com.openai.codex": srgbIcon(forBundleID: "com.openai.codex"),
            "com.google.Chrome": srgbIcon(forBundleID: "com.google.Chrome"),
            "com.apple.Notes": srgbIcon(forBundleID: "com.apple.Notes"),
            "com.raycast.macos": srgbIcon(forBundleID: "com.raycast.macos"),
            "com.apple.Safari": srgbIcon(forBundleID: "com.apple.Safari"),
            "com.apple.Terminal": srgbIcon(forBundleID: "com.apple.Terminal"),
            "com.apple.MobileSMS": srgbIcon(forBundleID: "com.apple.MobileSMS"),
            "com.apple.mail": srgbIcon(forBundleID: "com.apple.mail"),
            "com.apple.finder": srgbIcon(forBundleID: "com.apple.finder"),
            "com.apple.iCal": srgbIcon(forBundleID: "com.apple.iCal"),
            "com.apple.Music": srgbIcon(forBundleID: "com.apple.Music"),
            "com.apple.Preview": srgbIcon(forBundleID: "com.apple.Preview")
        ]

        let sampleTrend: [DailyActivityPoint] = [
            DailyActivityPoint(dateKey: "2026-11-15", keyPresses: 3_420, clicks: 510, mouseDistanceMeters: 1_180, scrollDistanceMeters: 420, scrollDistancePx: 148_200),
            DailyActivityPoint(dateKey: "2026-11-16", keyPresses: 6_810, clicks: 940, mouseDistanceMeters: 2_390, scrollDistanceMeters: 980, scrollDistancePx: 324_600),
            DailyActivityPoint(dateKey: "2026-11-17", keyPresses: 8_940, clicks: 1_240, mouseDistanceMeters: 3_120, scrollDistanceMeters: 1_310, scrollDistancePx: 412_800),
            DailyActivityPoint(dateKey: "2026-11-18", keyPresses: 7_290, clicks: 1_010, mouseDistanceMeters: 2_480, scrollDistanceMeters: 1_120, scrollDistancePx: 298_400),
            DailyActivityPoint(dateKey: "2026-11-19", keyPresses: 8_640, clicks: 1_180, mouseDistanceMeters: 2_840, scrollDistanceMeters: 1_260, scrollDistancePx: 492_000),
            DailyActivityPoint(dateKey: "2026-11-20", keyPresses: 4_810, clicks: 720, mouseDistanceMeters: 1_640, scrollDistanceMeters: 780, scrollDistancePx: 356_900),
            DailyActivityPoint(dateKey: "2026-11-21", keyPresses: 2_770, clicks: 540, mouseDistanceMeters: 1_170, scrollDistanceMeters: 540, scrollDistancePx: 405_300)
        ]

        let sampleKeyStats = KeyStatsAggregateSnapshot(
            range: .days7,
            deviceScope: .allDevices,
            deviceCount: 2,
            totalKeyPresses: 42_680,
            totalClicks: 6_140,
            leftClicks: 5_290,
            rightClicks: 710,
            otherClicks: 140,
            mouseDistanceMeters: 14_820,
            scrollDistanceMeters: 6_410,
            peakKPS: 13,
            peakCPS: 6,
            backspacePresses: 1_890,
            leftHandPresses: 22_190,
            rightHandPresses: 20_490,
            romanKeyPresses: 29_020,
            nonRomanKeyPresses: 13_660,
            activeDays: 7,
            maxDailyKeys: 8_940,
            firstActiveDateKey: "2026-08-30",
            lastActiveDateKey: "2026-11-21",
            currentStreakDays: 14,
            longestStreakDays: 28,
            activeKeyCount: sampleHeatmap.count,
            keyHeatmap: sampleHeatmap,
            topShortcuts: [
                RankedCountItem(label: "⌘C", count: 312),
                RankedCountItem(label: "⌘V", count: 289),
                RankedCountItem(label: "⌘S", count: 194),
                RankedCountItem(label: "⌘Z", count: 118)
            ],
            topKeys: [
                RankedCountItem(label: "Space", count: 4_120),
                RankedCountItem(label: "E", count: 2_890),
                RankedCountItem(label: "T", count: 2_210),
                RankedCountItem(label: "A", count: 1_980),
                RankedCountItem(label: "O", count: 1_840)
            ],
            topApps: [
                AppActivitySummary(bundleID: "com.openai.codex", displayName: "Codex (ChatGPT)", keyPresses: 14_820, clicks: 1_940, scrollMeters: 2_180, scrollPx: 1_420_000, charactersSaved: 1_420, keyHeatmap: sampleHeatmap),
                AppActivitySummary(bundleID: "com.google.Chrome", displayName: "Google Chrome", keyPresses: 11_340, clicks: 2_310, scrollMeters: 2_690, scrollPx: 2_690_000, charactersSaved: 980, keyHeatmap: sampleHeatmap),
                AppActivitySummary(bundleID: "com.raycast.macos", displayName: "Raycast", keyPresses: 6_490, clicks: 420, scrollMeters: 380, scrollPx: 380_000, charactersSaved: 460),
                AppActivitySummary(bundleID: "com.apple.Notes", displayName: "Notes", keyPresses: 5_810, clicks: 760, scrollMeters: 640, scrollPx: 640_000, charactersSaved: 560),
                AppActivitySummary(bundleID: "com.apple.Safari", displayName: "Safari", keyPresses: 4_220, clicks: 710, scrollMeters: 520, scrollPx: 520_000, charactersSaved: 210)
            ],
            dailyTrend: sampleTrend,
            calendarDays: sampleCalDays
        )

        let windowShotSize = NSSize(width: 1016, height: 726)

        // 1. Hero inline-ghost banner
        try renderSwiftUIViewToPNG(
            ShowcaseHeroBanner(),
            size: NSSize(width: 860, height: 390),
            to: outDir.appendingPathComponent("hero-inline-ghost.png")
        )

        // 2. KeyStats & Keyboard Heatmap window screenshot
        let keyStatsVM = SettingsViewModel(
            showcaseSection: .keyStats,
            appOffsets: sampleApps,
            insights: sampleInsights,
            bigrams: sampleBigrams,
            vocabulary: sampleVocab,
            keyStats: sampleKeyStats,
            showcaseAppIcons: appIconsMap
        )
        try renderSwiftUIViewToPNG(
            MacWindowFrameBackdrop(size: windowShotSize) {
                SettingsView(vm: keyStatsVM)
            },
            size: windowShotSize,
            to: outDir.appendingPathComponent("keystats-window.png")
        )

        // 3. Insights window screenshot
        let insightsVM = SettingsViewModel(
            showcaseSection: .insights,
            appOffsets: sampleApps,
            insights: sampleInsights,
            bigrams: sampleBigrams,
            vocabulary: sampleVocab,
            keyStats: sampleKeyStats,
            showcaseAppIcons: appIconsMap
        )
        try renderSwiftUIViewToPNG(
            MacWindowFrameBackdrop(size: windowShotSize) {
                SettingsView(vm: insightsVM)
            },
            size: windowShotSize,
            to: outDir.appendingPathComponent("insights-window.png")
        )

        // 4. Calibration window screenshot
        let calibrationVM = SettingsViewModel(
            showcaseSection: .calibration,
            appOffsets: sampleApps,
            insights: sampleInsights,
            bigrams: sampleBigrams,
            vocabulary: sampleVocab,
            keyStats: sampleKeyStats,
            showcaseAppIcons: appIconsMap
        )
        try renderSwiftUIViewToPNG(
            MacWindowFrameBackdrop(size: windowShotSize) {
                SettingsView(vm: calibrationVM)
            },
            size: windowShotSize,
            to: outDir.appendingPathComponent("calibration-window.png")
        )

        // 5. Full-page App Statistics window screenshot
        let sampleAllTimeAppStats = KeyStatsAggregateSnapshot(
            range: .allTime,
            deviceScope: .allDevices,
            deviceCount: 2,
            totalKeyPresses: 801_552,
            totalClicks: 147_518,
            topApps: [
                AppActivitySummary(bundleID: "com.openai.codex", displayName: "Codex (ChatGPT)", keyPresses: 213_795, clicks: 33_660, scrollMeters: 1_445, scrollPx: 5_461_300, charactersSaved: 2_840),
                AppActivitySummary(bundleID: "com.apple.Safari", displayName: "Safari", keyPresses: 184_768, clicks: 10_951, scrollMeters: 839, scrollPx: 3_170_700, charactersSaved: 1_190),
                AppActivitySummary(bundleID: "com.apple.Terminal", displayName: "Terminal", keyPresses: 120_970, clicks: 7_872, scrollMeters: 788, scrollPx: 2_979_000, charactersSaved: 420),
                AppActivitySummary(bundleID: "com.google.Chrome", displayName: "Google Chrome", keyPresses: 109_378, clicks: 73_987, scrollMeters: 4_850, scrollPx: 18_331_400, charactersSaved: 1_890),
                AppActivitySummary(bundleID: "com.raycast.macos", displayName: "Raycast", keyPresses: 56_808, clicks: 5_946, scrollMeters: 287, scrollPx: 1_086_200, charactersSaved: 680),
                AppActivitySummary(bundleID: "com.apple.Notes", displayName: "Notes", keyPresses: 36_319, clicks: 2_660, scrollMeters: 162, scrollPx: 614_300, charactersSaved: 910),
                AppActivitySummary(bundleID: "com.apple.MobileSMS", displayName: "Messages", keyPresses: 21_372, clicks: 2_233, scrollMeters: 237, scrollPx: 895_100, charactersSaved: 540),
                AppActivitySummary(bundleID: "com.apple.mail", displayName: "Mail", keyPresses: 18_497, clicks: 1_206, scrollMeters: 211, scrollPx: 798_200, charactersSaved: 480),
                AppActivitySummary(bundleID: "com.apple.finder", displayName: "Finder", keyPresses: 14_453, clicks: 7_507, scrollMeters: 603, scrollPx: 2_279_000, charactersSaved: 110),
                AppActivitySummary(bundleID: "com.apple.iCal", displayName: "Calendar", keyPresses: 9_162, clicks: 1_357, scrollMeters: 103, scrollPx: 388_900, charactersSaved: 60),
                AppActivitySummary(bundleID: "com.apple.Music", displayName: "Music", keyPresses: 8_292, clicks: 645, scrollMeters: 58, scrollPx: 219_400, charactersSaved: 30),
                AppActivitySummary(bundleID: "com.apple.Preview", displayName: "Preview", keyPresses: 7_738, clicks: 495, scrollMeters: 14, scrollPx: 53_100, charactersSaved: 20)
            ]
        )
        let appStatsVM = SettingsViewModel(
            showcaseSection: .appStats,
            appOffsets: sampleApps,
            insights: sampleInsights,
            bigrams: sampleBigrams,
            vocabulary: sampleVocab,
            keyStats: sampleAllTimeAppStats,
            showcaseAppIcons: appIconsMap
        )
        try renderSwiftUIViewToPNG(
            MacWindowFrameBackdrop(size: windowShotSize) {
                SettingsView(vm: appStatsVM)
            },
            size: windowShotSize,
            to: outDir.appendingPathComponent("appstats-window.png")
        )

        // 5. Menu Bar Popover showcase screenshot (440 x 740)
        let popoverTodayTopKeys: [RankedCountItem] = [
            RankedCountItem(label: "Delete", count: 2_132),
            RankedCountItem(label: "Space", count: 1_075),
            RankedCountItem(label: "E", count: 788),
            RankedCountItem(label: "A", count: 782),
            RankedCountItem(label: "T", count: 573),
            RankedCountItem(label: "N", count: 545),
            RankedCountItem(label: "I", count: 527),
            RankedCountItem(label: "O", count: 521),
            RankedCountItem(label: "S", count: 457),
            RankedCountItem(label: "H", count: 453),
            RankedCountItem(label: "C", count: 281),
            RankedCountItem(label: "R", count: 262),
            RankedCountItem(label: "U", count: 260),
            RankedCountItem(label: "L", count: 248),
            RankedCountItem(label: "D", count: 241)
        ]
        let samplePopoverToday = KeyStatsAggregateSnapshot(
            range: .today,
            deviceScope: .allDevices,
            deviceCount: 2,
            totalKeyPresses: 11_758,
            totalClicks: 3_021,
            leftClicks: 2_963,
            rightClicks: 28,
            otherClicks: 30,
            sideBackClicks: 30,
            sideForwardClicks: 0,
            mouseDistanceMeters: 1_070,
            scrollDistanceMeters: 107.2,
            scrollDistancePx: 405_300,
            peakKPS: 24,
            peakCPS: 6,
            topKeys: popoverTodayTopKeys
        )
        let syncedPopoverTrend: [DailyActivityPoint] = [
            DailyActivityPoint(dateKey: "2026-11-15", keyPresses: 28_400, clicks: 4_120, mouseDistanceMeters: 1_450, scrollDistanceMeters: 120, scrollDistancePx: 452_000),
            DailyActivityPoint(dateKey: "2026-11-16", keyPresses: 29_100, clicks: 4_380, mouseDistanceMeters: 1_510, scrollDistanceMeters: 132, scrollDistancePx: 498_000),
            DailyActivityPoint(dateKey: "2026-11-17", keyPresses: 21_400, clicks: 3_190, mouseDistanceMeters: 1_120, scrollDistanceMeters: 94, scrollDistancePx: 355_000),
            DailyActivityPoint(dateKey: "2026-11-18", keyPresses: 20_800, clicks: 2_980, mouseDistanceMeters: 1_060, scrollDistanceMeters: 88, scrollDistancePx: 332_000),
            DailyActivityPoint(dateKey: "2026-11-19", keyPresses: 40_800, clicks: 5_840, mouseDistanceMeters: 2_180, scrollDistanceMeters: 185, scrollDistancePx: 699_000),
            DailyActivityPoint(dateKey: "2026-11-20", keyPresses: 31_600, clicks: 4_410, mouseDistanceMeters: 1_620, scrollDistanceMeters: 141, scrollDistancePx: 532_000),
            DailyActivityPoint(dateKey: "2026-11-21", keyPresses: 18_700, clicks: 3_021, mouseDistanceMeters: 1_070, scrollDistanceMeters: 107.2, scrollDistancePx: 405_300)
        ]
        let localPopoverTrend: [DailyActivityPoint] = [
            DailyActivityPoint(dateKey: "2026-11-15", keyPresses: 28_400, clicks: 4_120, mouseDistanceMeters: 1_450, scrollDistanceMeters: 120, scrollDistancePx: 452_000),
            DailyActivityPoint(dateKey: "2026-11-16", keyPresses: 29_100, clicks: 4_380, mouseDistanceMeters: 1_510, scrollDistanceMeters: 132, scrollDistancePx: 498_000),
            DailyActivityPoint(dateKey: "2026-11-17", keyPresses: 21_400, clicks: 3_190, mouseDistanceMeters: 1_120, scrollDistanceMeters: 94, scrollDistancePx: 355_000),
            DailyActivityPoint(dateKey: "2026-11-18", keyPresses: 20_800, clicks: 2_980, mouseDistanceMeters: 1_060, scrollDistanceMeters: 88, scrollDistancePx: 332_000),
            DailyActivityPoint(dateKey: "2026-11-19", keyPresses: 33_200, clicks: 4_760, mouseDistanceMeters: 1_740, scrollDistanceMeters: 146, scrollDistancePx: 551_000),
            DailyActivityPoint(dateKey: "2026-11-20", keyPresses: 23_900, clicks: 3_320, mouseDistanceMeters: 1_240, scrollDistanceMeters: 109, scrollDistancePx: 411_000),
            DailyActivityPoint(dateKey: "2026-11-21", keyPresses: 11_758, clicks: 3_021, mouseDistanceMeters: 1_070, scrollDistanceMeters: 107.2, scrollDistancePx: 405_300)
        ]
        let popoverSynced = KeyStatsAggregateSnapshot(
            range: .days7,
            deviceScope: .allDevices,
            deviceCount: 2,
            totalKeyPresses: 190_800,
            totalClicks: 27_941,
            mouseDistanceMeters: 10_010,
            scrollDistanceMeters: 867.2,
            scrollDistancePx: 3_274_300,
            dailyTrend: syncedPopoverTrend
        )
        let popoverThisMac = KeyStatsAggregateSnapshot(
            range: .days7,
            deviceScope: .thisMac,
            deviceCount: 1,
            totalKeyPresses: 168_558,
            totalClicks: 25_771,
            mouseDistanceMeters: 9_170,
            scrollDistanceMeters: 788.2,
            scrollDistancePx: 2_976_300,
            dailyTrend: localPopoverTrend
        )
        let popoverVM = MenuBarPopoverViewModel.makeShowcase(
            today: samplePopoverToday,
            historySynced: popoverSynced,
            historyThisMac: popoverThisMac,
            activeAppName: "Codex (ChatGPT)",
            activeAppBundleID: "com.openai.codex",
            activeAppIcon: srgbIcon(forBundleID: "com.openai.codex"),
            brandIcon: srgbIcon(forBundleID: "app.wordtail.macos")
        )
        let popoverShotSize = NSSize(width: 436, height: 760)
        try renderSwiftUIViewToPNG(
            PopoverShowcaseBackdrop(size: popoverShotSize, isDark: false) {
                MenuBarPopoverView(vm: popoverVM)
            },
            size: popoverShotSize,
            colorScheme: .light,
            to: outDir.appendingPathComponent("menubar-popover.png")
        )

        // 6. Dark Mode Menu Bar Popover showcase screenshot (448 x 700)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try renderSwiftUIViewToPNG(
            PopoverShowcaseBackdrop(size: popoverShotSize, isDark: true) {
                MenuBarPopoverView(vm: popoverVM)
            },
            size: popoverShotSize,
            colorScheme: .dark,
            to: outDir.appendingPathComponent("menubar-popover-dark.png")
        )
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    private static func srgbIcon(forBundleID bundleID: String) -> NSImage {
        let src = SettingsViewModel.appIcon(forBundleID: bundleID)
        let px = 64
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: px,
                  height: px,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: srgb,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return src
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        src.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return src }
        return NSImage(cgImage: cg, size: NSSize(width: 32, height: 32))
    }

    @MainActor
    private static func renderSwiftUIViewToPNG<V: View>(
        _ view: V,
        size: NSSize,
        colorScheme: ColorScheme = .light,
        to url: URL
    ) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, colorScheme))
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.isOpaque = true
        guard let rawCG = renderer.cgImage,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: rawCG.width,
                  height: rawCG.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: srgb,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw NSError(domain: "ShowcaseExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create sRGB context"])
        }
        ctx.draw(rawCG, in: CGRect(x: 0, y: 0, width: rawCG.width, height: rawCG.height))
        guard let srgbCG = ctx.makeImage() else {
            throw NSError(domain: "ShowcaseExporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to render sRGB image"])
        }
        let bitmap = NSBitmapImageRep(cgImage: srgbCG)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ShowcaseExporter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
        }
        try png.write(to: url, options: .atomic)
    }
}

private struct MacWindowFrameBackdrop<Content: View>: View {
    var size: NSSize = NSSize(width: 816, height: 622)
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.91, green: 0.93, blue: 0.98),
                    Color(red: 0.95, green: 0.95, blue: 0.98),
                    Color(red: 0.89, green: 0.92, blue: 0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            ZStack(alignment: .topLeading) {
                content
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.16), radius: 22, x: 0, y: 12)

                // macOS traffic light window controls
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 0.99, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 12, height: 12)
                }
                .padding(.leading, 16)
                .padding(.top, 14)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct PopoverShowcaseBackdrop<Content: View>: View {
    var size: NSSize = NSSize(width: 436, height: 760)
    var isDark: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            LinearGradient(
                colors: isDark
                    ? [
                        Color(red: 0.08, green: 0.11, blue: 0.18),
                        Color(red: 0.12, green: 0.14, blue: 0.24),
                        Color(red: 0.07, green: 0.09, blue: 0.16)
                    ]
                    : [
                        Color(red: 0.56, green: 0.79, blue: 0.94),
                        Color(red: 0.72, green: 0.87, blue: 0.96),
                        Color(red: 0.50, green: 0.73, blue: 0.89)
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill((isDark ? Color(red: 0.37, green: 0.42, blue: 0.89) : Color.white).opacity(isDark ? 0.24 : 0.35))
                .frame(width: 280, height: 280)
                .blur(radius: 44)
                .offset(x: -40, y: -120)

            content
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isDark
                              ? Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.84)
                              : Color.white.opacity(0.78))
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke((isDark ? Color.white.opacity(0.16) : Color.white.opacity(0.65)), lineWidth: 1)
                )
                .shadow(color: .black.opacity(isDark ? 0.44 : 0.20), radius: 22, x: 0, y: 10)
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct ShowcaseHeroBanner: View {
    private let indigo = Color(red: 0.37, green: 0.42, blue: 0.89)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.065, green: 0.072, blue: 0.095),
                    Color(red: 0.105, green: 0.118, blue: 0.165)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("WordTail for macOS")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Zero-LLM · ~3 ms single-word inline ghost autocomplete · Habit-aware")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()

                    HStack(spacing: 6) {
                        HeroPill(text: "Zero LLM")
                        HeroPill(text: "~400 KB")
                        HeroPill(text: "100% Local")
                    }
                }

                // Simulated focused editor cards
                VStack(spacing: 12) {
                    HeroTypingRow(
                        contextTag: "AI Chat / Prose",
                        typedBefore: "Let's open a pull re",
                        ghostSuffix: "quest ",
                        note: "Personal bigram learned: pull → request"
                    )
                    HeroTypingRow(
                        contextTag: "Technical Docs",
                        typedBefore: "Keep the webhook handler idemp",
                        ghostSuffix: "otent ",
                        note: "180+ CS/AI lexicon + per-app vocabulary"
                    )
                    HStack(spacing: 12) {
                        Text("Bilingual Guard")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.65))
                            .frame(width: 105, alignment: .leading)

                        Text("今天下午讨论架构设计")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.white.opacity(0.92))

                        Spacer()

                        Text("Pinyin / CJK IME active — stays 100% silent")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.green.opacity(0.9))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 50)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
                }

                HStack {
                    Text("Works across Chrome, Codex, Antigravity, Raycast, Slack, Mail & Notes")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.52))
                    Spacer()
                    Text("⇥ Tab to accept · ⌥ [ / ] to cycle · Esc to dismiss")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .padding(34)
        }
        .frame(width: 860, height: 390)
    }
}

private struct HeroPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.09), in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}

private struct HeroTypingRow: View {
    let contextTag: String
    let typedBefore: String
    let ghostSuffix: String
    let note: String

    var body: some View {
        HStack(spacing: 12) {
            Text(contextTag)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 105, alignment: .leading)

            HStack(spacing: 0) {
                Text(typedBefore)
                    .font(.system(size: 14.5))
                    .foregroundStyle(.white.opacity(0.95))
                Rectangle()
                    .fill(Color(red: 0.46, green: 0.52, blue: 0.98))
                    .frame(width: 1.8, height: 17)
                Text(ghostSuffix)
                    .font(.system(size: 14.5))
                    .foregroundStyle(.white.opacity(0.36))
            }

            Spacer()

            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.52))

            Text("⇥ Tab")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}
