import CoreGraphics
import Foundation

public enum StatsTimeRange: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case days7 = "7 Days"
    case days30 = "30 Days"
    case allTime = "All Time"

    public var id: String { rawValue }
}

public enum StatsDeviceScope: String, CaseIterable, Identifiable, Sendable {
    case allDevices = "All Devices"
    case thisMac = "This Mac"

    public var id: String { rawValue }
}

public struct DailyActivityPoint: Identifiable, Equatable, Sendable {
    public var id: String { dateKey }
    public let dateKey: String
    public let keyPresses: Int
    public let clicks: Int
    public let mouseDistanceMeters: Double
    public let scrollDistanceMeters: Double
    public let scrollDistancePx: Double

    public init(
        dateKey: String,
        keyPresses: Int,
        clicks: Int,
        mouseDistanceMeters: Double,
        scrollDistanceMeters: Double,
        scrollDistancePx: Double = 0
    ) {
        self.dateKey = dateKey
        self.keyPresses = keyPresses
        self.clicks = clicks
        self.mouseDistanceMeters = mouseDistanceMeters
        self.scrollDistanceMeters = scrollDistanceMeters
        self.scrollDistancePx = scrollDistancePx
    }
}

public struct KeyStatsImportReport: Equatable, Sendable {
    public let localDaysImported: Int
    public let hourlyBucketsImported: Int
    public let peerDevicesImported: Int
    public let peerDaysImported: Int
    public let totalKeysAfterImport: Int
    public let totalActiveDaysAfterImport: Int

    public init(
        localDaysImported: Int,
        hourlyBucketsImported: Int,
        peerDevicesImported: Int,
        peerDaysImported: Int,
        totalKeysAfterImport: Int,
        totalActiveDaysAfterImport: Int
    ) {
        self.localDaysImported = localDaysImported
        self.hourlyBucketsImported = hourlyBucketsImported
        self.peerDevicesImported = peerDevicesImported
        self.peerDaysImported = peerDaysImported
        self.totalKeysAfterImport = totalKeysAfterImport
        self.totalActiveDaysAfterImport = totalActiveDaysAfterImport
    }
}

public enum MouseButtonKind: Sendable {
    case left
    case right
    case middle
    case sideBack
    case sideForward
}

public struct AppActivityRecord: Codable, Equatable, Sendable {
    public var bundleID: String
    public var displayName: String
    public var keyPresses: Int
    public var leftClicks: Int
    public var rightClicks: Int
    public var otherClicks: Int
    public var scrollDistancePx: Double
    public var tabsAccepted: Int
    public var charactersSaved: Int
    public var keyHeatmapCounts: [String: Int]?

    public init(
        bundleID: String,
        displayName: String,
        keyPresses: Int = 0,
        leftClicks: Int = 0,
        rightClicks: Int = 0,
        otherClicks: Int = 0,
        scrollDistancePx: Double = 0,
        tabsAccepted: Int = 0,
        charactersSaved: Int = 0,
        keyHeatmapCounts: [String: Int]? = nil
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.keyPresses = keyPresses
        self.leftClicks = leftClicks
        self.rightClicks = rightClicks
        self.otherClicks = otherClicks
        self.scrollDistancePx = scrollDistancePx
        self.tabsAccepted = tabsAccepted
        self.charactersSaved = charactersSaved
        self.keyHeatmapCounts = keyHeatmapCounts
    }

    public var totalClicks: Int {
        leftClicks + rightClicks + otherClicks
    }
}

public struct DailyKeyStatsRecord: Codable, Equatable, Sendable {
    public var dateKey: String // "YYYY-MM-DD" in local calendar
    public var keyPresses: Int
    public var autoRepeatPresses: Int
    public var romanKeyPresses: Int
    public var nonRomanKeyPresses: Int
    public var backspacePresses: Int
    public var leftHandPresses: Int
    public var rightHandPresses: Int
    public var keyHeatmapCounts: [String: Int]
    public var shortcutCounts: [String: Int]
    public var leftClicks: Int
    public var rightClicks: Int
    public var middleClicks: Int
    public var sideBackClicks: Int
    public var sideForwardClicks: Int
    public var mouseDistancePx: Double
    public var scrollDistancePx: Double
    public var peakKPS: Int
    public var peakCPS: Int
    public var tabsAccepted: Int
    public var charactersSaved: Int
    public var hourlyKeys: [Int]
    public var hourlyClicks: [Int]
    public var appStats: [String: AppActivityRecord]

    public init(dateKey: String) {
        self.dateKey = dateKey
        self.keyPresses = 0
        self.autoRepeatPresses = 0
        self.romanKeyPresses = 0
        self.nonRomanKeyPresses = 0
        self.backspacePresses = 0
        self.leftHandPresses = 0
        self.rightHandPresses = 0
        self.keyHeatmapCounts = [:]
        self.shortcutCounts = [:]
        self.leftClicks = 0
        self.rightClicks = 0
        self.middleClicks = 0
        self.sideBackClicks = 0
        self.sideForwardClicks = 0
        self.mouseDistancePx = 0
        self.scrollDistancePx = 0
        self.peakKPS = 0
        self.peakCPS = 0
        self.tabsAccepted = 0
        self.charactersSaved = 0
        self.hourlyKeys = Array(repeating: 0, count: 24)
        self.hourlyClicks = Array(repeating: 0, count: 24)
        self.appStats = [:]
    }

    public var totalClicks: Int {
        leftClicks + rightClicks + middleClicks + sideBackClicks + sideForwardClicks
    }
}

public struct AppActivitySummary: Identifiable, Equatable {
    public var id: String { bundleID }
    public let bundleID: String
    public let displayName: String
    public let keyPresses: Int
    public let clicks: Int
    public let scrollMeters: Double
    public let scrollPx: Double
    public let charactersSaved: Int
    public let keyHeatmap: [String: Int]

    public init(
        bundleID: String,
        displayName: String,
        keyPresses: Int,
        clicks: Int,
        scrollMeters: Double,
        scrollPx: Double = 0,
        charactersSaved: Int,
        keyHeatmap: [String: Int] = [:]
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.keyPresses = keyPresses
        self.clicks = clicks
        self.scrollMeters = scrollMeters
        self.scrollPx = scrollPx
        self.charactersSaved = charactersSaved
        self.keyHeatmap = keyHeatmap
    }
}

public struct RankedCountItem: Identifiable, Equatable {
    public var id: String { label }
    public let label: String
    public let count: Int

    public init(label: String, count: Int) {
        self.label = label
        self.count = count
    }
}

public struct CalendarActivityDay: Identifiable, Equatable {
    public var id: String { dateKey }
    public let dateKey: String
    public let keyPresses: Int
    public let clicks: Int

    public var totalActions: Int { keyPresses + clicks }

    public init(dateKey: String, keyPresses: Int, clicks: Int) {
        self.dateKey = dateKey
        self.keyPresses = keyPresses
        self.clicks = clicks
    }
}

public struct KeyStatsAggregateSnapshot: Equatable {
    public static let metersPerPixel: Double = 0.000264583
    public static let marathonMeters: Double = 42_195.0
    public static let everestMeters: Double = 8_848.86

    public let range: StatsTimeRange
    public let deviceScope: StatsDeviceScope
    public let deviceCount: Int
    public let totalKeyPresses: Int
    public let totalClicks: Int
    public let leftClicks: Int
    public let rightClicks: Int
    public let otherClicks: Int
    public let middleClicks: Int
    public let sideBackClicks: Int
    public let sideForwardClicks: Int
    public let mouseDistanceMeters: Double
    public let scrollDistanceMeters: Double
    public let scrollDistancePx: Double
    public let peakKPS: Int
    public let peakCPS: Int
    public let backspacePresses: Int
    public let leftHandPresses: Int
    public let rightHandPresses: Int
    public let romanKeyPresses: Int
    public let nonRomanKeyPresses: Int
    public let activeDays: Int
    public let maxDailyKeys: Int
    public let firstActiveDateKey: String?
    public let lastActiveDateKey: String?
    public let currentStreakDays: Int
    public let longestStreakDays: Int
    public let activeKeyCount: Int
    public let keyHeatmap: [String: Int]
    public let topShortcuts: [RankedCountItem]
    public let topKeys: [RankedCountItem]
    public let topApps: [AppActivitySummary]
    public let hourlyKeys: [Int]
    public let hourlyClicks: [Int]
    public let dailyTrend: [DailyActivityPoint]
    public let calendarDays: [CalendarActivityDay]

    public init(
        range: StatsTimeRange = .today,
        deviceScope: StatsDeviceScope = .allDevices,
        deviceCount: Int = 1,
        totalKeyPresses: Int = 0,
        totalClicks: Int = 0,
        leftClicks: Int = 0,
        rightClicks: Int = 0,
        otherClicks: Int = 0,
        middleClicks: Int = 0,
        sideBackClicks: Int = 0,
        sideForwardClicks: Int = 0,
        mouseDistanceMeters: Double = 0,
        scrollDistanceMeters: Double = 0,
        scrollDistancePx: Double = 0,
        peakKPS: Int = 0,
        peakCPS: Int = 0,
        backspacePresses: Int = 0,
        leftHandPresses: Int = 0,
        rightHandPresses: Int = 0,
        romanKeyPresses: Int = 0,
        nonRomanKeyPresses: Int = 0,
        activeDays: Int = 0,
        maxDailyKeys: Int = 0,
        firstActiveDateKey: String? = nil,
        lastActiveDateKey: String? = nil,
        currentStreakDays: Int = 0,
        longestStreakDays: Int = 0,
        activeKeyCount: Int = 0,
        keyHeatmap: [String: Int] = [:],
        topShortcuts: [RankedCountItem] = [],
        topKeys: [RankedCountItem] = [],
        topApps: [AppActivitySummary] = [],
        hourlyKeys: [Int] = Array(repeating: 0, count: 24),
        hourlyClicks: [Int] = Array(repeating: 0, count: 24),
        dailyTrend: [DailyActivityPoint] = [],
        calendarDays: [CalendarActivityDay] = []
    ) {
        self.range = range
        self.deviceScope = deviceScope
        self.deviceCount = deviceCount
        self.totalKeyPresses = totalKeyPresses
        self.totalClicks = totalClicks
        self.leftClicks = leftClicks
        self.rightClicks = rightClicks
        self.otherClicks = otherClicks
        self.middleClicks = middleClicks
        self.sideBackClicks = sideBackClicks
        self.sideForwardClicks = sideForwardClicks
        self.mouseDistanceMeters = mouseDistanceMeters
        self.scrollDistanceMeters = scrollDistanceMeters
        self.scrollDistancePx = scrollDistancePx
        self.peakKPS = peakKPS
        self.peakCPS = peakCPS
        self.backspacePresses = backspacePresses
        self.leftHandPresses = leftHandPresses
        self.rightHandPresses = rightHandPresses
        self.romanKeyPresses = romanKeyPresses
        self.nonRomanKeyPresses = nonRomanKeyPresses
        self.activeDays = activeDays
        self.maxDailyKeys = maxDailyKeys
        self.firstActiveDateKey = firstActiveDateKey
        self.lastActiveDateKey = lastActiveDateKey
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.activeKeyCount = activeKeyCount
        self.keyHeatmap = keyHeatmap
        self.topShortcuts = topShortcuts
        self.topKeys = topKeys
        self.topApps = topApps
        self.hourlyKeys = hourlyKeys
        self.hourlyClicks = hourlyClicks
        self.dailyTrend = dailyTrend
        self.calendarDays = calendarDays
    }

    public var marathonsEquivalent: Double {
        mouseDistanceMeters / Self.marathonMeters
    }

    public var everestsEquivalent: Double {
        scrollDistanceMeters / Self.everestMeters
    }

    public var correctionRatePercent: Double {
        guard totalKeyPresses > 0 else { return 0 }
        return (Double(backspacePresses) / Double(totalKeyPresses) * 1000.0).rounded() / 10.0
    }

    public var keyToClickRatio: Double {
        guard totalClicks > 0 else { return Double(totalKeyPresses) }
        return (Double(totalKeyPresses) / Double(totalClicks) * 10.0).rounded() / 10.0
    }

    public var inputStyleLabel: String {
        if totalKeyPresses == 0 && totalClicks == 0 { return "Idle" }
        if totalClicks == 0 || Double(totalKeyPresses) / Double(max(1, totalClicks)) >= 5.5 {
            return "Hacker"
        }
        if Double(totalKeyPresses) / Double(max(1, totalClicks)) <= 1.6 {
            return "Pointer"
        }
        return "Balanced"
    }

    public var leftHandPercent: Int {
        let sum = leftHandPresses + rightHandPresses
        guard sum > 0 else { return 50 }
        return Int((Double(leftHandPresses) / Double(sum) * 100.0).rounded())
    }

    public var englishKeyPercent: Int {
        let sum = romanKeyPresses + nonRomanKeyPresses
        guard sum > 0 else { return 100 }
        return Int((Double(romanKeyPresses) / Double(sum) * 100.0).rounded())
    }

    public static func formatCompactCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.2fM", Double(n) / 1_000_000.0)
        } else if n >= 10_000 {
            return String(format: "%.1fk", Double(n) / 1_000.0)
        } else if n >= 1_000 {
            return String(format: "%.2fk", Double(n) / 1_000.0)
        }
        return "\(n)"
    }

    public static func formatDistance(_ meters: Double) -> String {
        if meters >= 1_000.0 {
            return String(format: "%.2f km", meters / 1_000.0)
        }
        return String(format: "%.1f m", meters)
    }

    public static func formatScrollPx(_ px: Double) -> String {
        if px >= 1_000_000.0 {
            return String(format: "%.2f MPx", px / 1_000_000.0)
        } else if px >= 1_000.0 {
            return String(format: "%.1f kPx", px / 1_000.0)
        }
        return "\(max(0, Int(px.rounded()))) px"
    }

    private static let kPxDecimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    public static func formatScrollKPx(_ px: Double) -> String {
        if px < 1_000.0 {
            return "\(max(0, Int(px.rounded()))) px"
        }
        let kpx = px / 1_000.0
        let formatted = kPxDecimalFormatter.string(from: NSNumber(value: kpx)) ?? String(format: "%.1f", kpx)
        return "\(formatted) kPx"
    }
}

/// Complete local KeyStats-grade telemetry archive with daily time-series, per-key heatmaps,
/// mouse/scroll distance, per-app breakdown, JSON export, and `debugtheworldbot/keyStats` import support.
public final class KeyStatsStore {
    public struct NativeExportArchive: Codable {
        public let schema: String
        public let version: Int
        public let exportedAt: Date
        public let days: [String: DailyKeyStatsRecord]
        public let importedPeerDays: [String: [String: DailyKeyStatsRecord]]?
        public let legacyKeyStatsDeviceID: String?

        public init(
            schema: String,
            version: Int,
            exportedAt: Date,
            days: [String: DailyKeyStatsRecord],
            importedPeerDays: [String: [String: DailyKeyStatsRecord]]? = nil,
            legacyKeyStatsDeviceID: String? = nil
        ) {
            self.schema = schema
            self.version = version
            self.exportedAt = exportedAt
            self.days = days
            self.importedPeerDays = importedPeerDays
            self.legacyKeyStatsDeviceID = legacyKeyStatsDeviceID
        }
    }

    // Compatible decoders for importing existing `debugtheworldbot/keyStats` exports & installed local store
    private struct ExternalKeyStatsPayload: Decodable {
        struct ExtApp: Decodable {
            var bundleId: String?
            var displayName: String?
            var keyPresses: Int?
            var keyPressCounts: [String: Int]?
            var leftClicks: Int?
            var rightClicks: Int?
            var sideBackClicks: Int?
            var sideForwardClicks: Int?
            var otherClicks: Int?
            var scrollDistance: Double?
        }
        struct ExtDay: Decodable {
            var date: Date?
            var keyPresses: Int?
            var keyPressCounts: [String: Int]?
            var leftClicks: Int?
            var rightClicks: Int?
            var middleClicks: Int?
            var sideBackClicks: Int?
            var sideForwardClicks: Int?
            var mouseDistance: Double?
            var scrollDistance: Double?
            var peakKPS: Double?
            var peakCPS: Double?
            var appStats: [String: ExtApp]?
        }
        var version: Int?
        var currentStats: ExtDay?
        var history: [String: ExtDay]?
    }

    private struct ExternalHourlyStatsPayload: Decodable {
        struct Bucket: Decodable {
            var keys: Int?
            var clicks: Int?
        }
        var timeZoneIdentifier: String?
        var buckets: [String: Bucket]?
    }

    private struct ExternalSyncCachePayload: Decodable {
        struct Shard: Decodable {
            var snapshot: Snapshot?
        }
        struct Snapshot: Decodable {
            var deviceId: String?
            var localDay: String?
            var keyPresses: Int?
            var keyPressCounts: [String: Int]?
            var clicks: [String: Int]?
        }
        var shards: [String: Shard]?
    }

    private let fileURL: URL
    private let nowProvider: () -> Date
    private let queue = DispatchQueue(label: "app.wordtail.macos.keystats", qos: .utility)

    private var days: [String: DailyKeyStatsRecord] = [:]
    private var remoteDaysByDevice: [String: [String: DailyKeyStatsRecord]] = [:]
    private var importedPeerDaysByDevice: [String: [String: DailyKeyStatsRecord]] = [:]
    private var legacyKeyStatsDeviceID: String?
    private var claimedRemoteLegacyDeviceIDs: Set<String> = []
    private var modifierTracker = StandaloneModifierTapTracker()
    private var lastMousePoint: CGPoint?
    private var recentKeyTimestamps: [TimeInterval] = []
    private var recentClickTimestamps: [TimeInterval] = []
    private var isDirty: Bool = false
    private var lastDiskFlushTime: TimeInterval = 0

    public var mouseCalibrationFactor: Double = 1.0

    public init(
        fileURL: URL? = nil,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("WordTail", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("keystats_history.json")
        }
        self.nowProvider = nowProvider
        loadSynchronously()
    }

    private func loadSynchronously() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let archive = try? decoder.decode(NativeExportArchive.self, from: data) {
            days = archive.days
            importedPeerDaysByDevice = archive.importedPeerDays ?? [:]
            legacyKeyStatsDeviceID = archive.legacyKeyStatsDeviceID
        } else if let rawDays = try? JSONDecoder().decode([String: DailyKeyStatsRecord].self, from: data) {
            days = rawDays
        }
    }

    // MARK: - Event Recording

    public func recordKeyDown(
        keyCode: Int,
        rawFlags: UInt64,
        isAutoRepeat: Bool,
        isSecureInput: Bool,
        isRomanLayout: Bool,
        appBundleID: String?,
        appName: String?
    ) {
        let nowDate = nowProvider()
        let nowTs = nowDate.timeIntervalSince1970
        queue.async {
            let (dayKey, hour) = Self.dayKeyAndHour(for: nowDate)
            var record = self.days[dayKey] ?? DailyKeyStatsRecord(dateKey: dayKey)

            self.modifierTracker.consumeChordModifiers(rawFlags: rawFlags, keyCode: keyCode)

            if isAutoRepeat {
                record.autoRepeatPresses += 1
                self.days[dayKey] = record
                self.markDirtyAndMaybeFlushLocked(nowTs: nowTs)
                return
            }

            record.keyPresses += 1
            if hour >= 0 && hour < 24 {
                record.hourlyKeys[hour] += 1
            }
            if isRomanLayout {
                record.romanKeyPresses += 1
            } else {
                record.nonRomanKeyPresses += 1
            }

            // Sliding 1.0s peak KPS
            self.recentKeyTimestamps.append(nowTs)
            self.recentKeyTimestamps.removeAll { nowTs - $0 > 1.0 }
            if self.recentKeyTimestamps.count > record.peakKPS {
                record.peakKPS = self.recentKeyTimestamps.count
            }

            var recordedKeysForApp: [String] = []
            // Never record individual key identities while SecureEventInput (password field) is active!
            if !isSecureInput, let baseKey = KeyCodeMapper.keyName(forKeyCode: keyCode) {
                if baseKey == "Delete" || baseKey == "ForwardDelete" {
                    record.backspacePresses += 1
                }

                let activeMods = KeyCodeMapper.activePhysicalModifierKeys(rawFlags: rawFlags, keyCode: keyCode)
                for modKey in activeMods {
                    record.keyHeatmapCounts[modKey, default: 0] += 1
                    self.incrementHandLocked(for: modKey, in: &record)
                    recordedKeysForApp.append(modKey)
                }
                record.keyHeatmapCounts[baseKey, default: 0] += 1
                self.incrementHandLocked(for: baseKey, in: &record)
                recordedKeysForApp.append(baseKey)

                if let shortcut = KeyCodeMapper.formattedShortcut(baseKey: baseKey, rawFlags: rawFlags) {
                    record.shortcutCounts[shortcut, default: 0] += 1
                }
            }

            if let bid = appBundleID, !bid.isEmpty {
                var app = record.appStats[bid] ?? AppActivityRecord(bundleID: bid, displayName: appName ?? bid)
                if let appName, !appName.isEmpty { app.displayName = appName }
                app.keyPresses += 1
                if !recordedKeysForApp.isEmpty {
                    var appHeatmap = app.keyHeatmapCounts ?? [:]
                    for k in recordedKeysForApp {
                        appHeatmap[k, default: 0] += 1
                    }
                    app.keyHeatmapCounts = appHeatmap
                }
                record.appStats[bid] = app
            }

            self.days[dayKey] = record
            self.markDirtyAndMaybeFlushLocked(nowTs: nowTs)
        }
    }

    public func recordFlagsChanged(
        keyCode: Int,
        rawFlags: UInt64,
        isSecureInput: Bool,
        isRomanLayout: Bool,
        appBundleID: String?,
        appName: String?
    ) {
        let nowDate = nowProvider()
        let nowTs = nowDate.timeIntervalSince1970
        queue.async {
            guard let standaloneMod = self.modifierTracker.handleFlagsChanged(keyCode: keyCode, rawFlags: rawFlags) else {
                return
            }
            let (dayKey, hour) = Self.dayKeyAndHour(for: nowDate)
            var record = self.days[dayKey] ?? DailyKeyStatsRecord(dateKey: dayKey)
            record.keyPresses += 1
            if hour >= 0 && hour < 24 {
                record.hourlyKeys[hour] += 1
            }
            if isRomanLayout {
                record.romanKeyPresses += 1
            } else {
                record.nonRomanKeyPresses += 1
            }
            if !isSecureInput {
                record.keyHeatmapCounts[standaloneMod, default: 0] += 1
                self.incrementHandLocked(for: standaloneMod, in: &record)
            }
            if let bid = appBundleID, !bid.isEmpty {
                var app = record.appStats[bid] ?? AppActivityRecord(bundleID: bid, displayName: appName ?? bid)
                if let appName, !appName.isEmpty { app.displayName = appName }
                app.keyPresses += 1
                if !isSecureInput {
                    var appHeatmap = app.keyHeatmapCounts ?? [:]
                    appHeatmap[standaloneMod, default: 0] += 1
                    app.keyHeatmapCounts = appHeatmap
                }
                record.appStats[bid] = app
            }
            self.days[dayKey] = record
            self.markDirtyAndMaybeFlushLocked(nowTs: nowTs)
        }
    }

    public func recordMouseClick(
        button: MouseButtonKind,
        appBundleID: String?,
        appName: String?
    ) {
        let nowDate = nowProvider()
        let nowTs = nowDate.timeIntervalSince1970
        queue.async {
            let (dayKey, hour) = Self.dayKeyAndHour(for: nowDate)
            var record = self.days[dayKey] ?? DailyKeyStatsRecord(dateKey: dayKey)

            switch button {
            case .left: record.leftClicks += 1
            case .right: record.rightClicks += 1
            case .middle: record.middleClicks += 1
            case .sideBack: record.sideBackClicks += 1
            case .sideForward: record.sideForwardClicks += 1
            }

            if hour >= 0 && hour < 24 {
                record.hourlyClicks[hour] += 1
            }

            self.recentClickTimestamps.append(nowTs)
            self.recentClickTimestamps.removeAll { nowTs - $0 > 1.0 }
            if self.recentClickTimestamps.count > record.peakCPS {
                record.peakCPS = self.recentClickTimestamps.count
            }

            if let bid = appBundleID, !bid.isEmpty {
                var app = record.appStats[bid] ?? AppActivityRecord(bundleID: bid, displayName: appName ?? bid)
                if let appName, !appName.isEmpty { app.displayName = appName }
                switch button {
                case .left: app.leftClicks += 1
                case .right: app.rightClicks += 1
                case .middle, .sideBack, .sideForward: app.otherClicks += 1
                }
                record.appStats[bid] = app
            }

            self.days[dayKey] = record
            self.markDirtyAndMaybeFlushLocked(nowTs: nowTs)
        }
    }

    public func recordMouseMove(to location: CGPoint) {
        let nowDate = nowProvider()
        let nowTs = nowDate.timeIntervalSince1970
        queue.async {
            defer { self.lastMousePoint = location }
            guard let prev = self.lastMousePoint else { return }
            let dx = Double(location.x - prev.x)
            let dy = Double(location.y - prev.y)
            let dist = hypot(dx, dy)
            // Ignore zero movement and multi-display cursor warps (> 900 px in a single tick)
            guard dist > 0.2 && dist < 900.0 else { return }

            let (dayKey, _) = Self.dayKeyAndHour(for: nowDate)
            var record = self.days[dayKey] ?? DailyKeyStatsRecord(dateKey: dayKey)
            record.mouseDistancePx += dist * self.mouseCalibrationFactor
            self.days[dayKey] = record
            self.markDirtyAndMaybeFlushLocked(nowTs: nowTs)
        }
    }

    public func recordScroll(deltaX: Double, deltaY: Double, appBundleID: String?, appName: String?) {
        let mag = hypot(deltaX, deltaY)
        guard mag > 0.1 && mag < 10_000.0 else { return }
        let nowDate = nowProvider()
        let nowTs = nowDate.timeIntervalSince1970
        queue.async {
            let (dayKey, _) = Self.dayKeyAndHour(for: nowDate)
            var record = self.days[dayKey] ?? DailyKeyStatsRecord(dateKey: dayKey)
            record.scrollDistancePx += mag
            if let bid = appBundleID, !bid.isEmpty {
                var app = record.appStats[bid] ?? AppActivityRecord(bundleID: bid, displayName: appName ?? bid)
                if let appName, !appName.isEmpty { app.displayName = appName }
                app.scrollDistancePx += mag
                record.appStats[bid] = app
            }
            self.days[dayKey] = record
            self.markDirtyAndMaybeFlushLocked(nowTs: nowTs)
        }
    }

    public func recordWordTailCompletion(charsSaved: Int, appBundleID: String?, appName: String?) {
        let nowDate = nowProvider()
        let nowTs = nowDate.timeIntervalSince1970
        queue.async {
            let (dayKey, _) = Self.dayKeyAndHour(for: nowDate)
            var record = self.days[dayKey] ?? DailyKeyStatsRecord(dateKey: dayKey)
            record.tabsAccepted += 1
            record.charactersSaved += max(0, charsSaved)
            if let bid = appBundleID, !bid.isEmpty {
                var app = record.appStats[bid] ?? AppActivityRecord(bundleID: bid, displayName: appName ?? bid)
                if let appName, !appName.isEmpty { app.displayName = appName }
                app.tabsAccepted += 1
                app.charactersSaved += max(0, charsSaved)
                record.appStats[bid] = app
            }
            self.days[dayKey] = record
            self.markDirtyAndMaybeFlushLocked(nowTs: nowTs)
        }
    }

    // MARK: - Multi-Device Sync Shards & Installed KeyStats Deduplication

    public func localLegacyKeyStatsDeviceID() -> String? {
        queue.sync { legacyKeyStatsDeviceID }
    }

    public func exportLocalDaysShard() -> [String: DailyKeyStatsRecord] {
        queue.sync { days }
    }

    public func applyRemoteDeviceDays(
        _ shards: [String: [String: DailyKeyStatsRecord]],
        claimedLegacyDeviceIDs: Set<String> = []
    ) {
        queue.sync {
            remoteDaysByDevice = shards
            claimedRemoteLegacyDeviceIDs = claimedLegacyDeviceIDs
        }
    }

    private func activeImportedPeerDevicesLocked() -> [String: [String: DailyKeyStatsRecord]] {
        let claimedLower = Set(claimedRemoteLegacyDeviceIDs.map { $0.lowercased() })
        let localLegacyLower = legacyKeyStatsDeviceID?.lowercased()
        return importedPeerDaysByDevice.filter { peerID, _ in
            let lower = peerID.lowercased()
            return !claimedLower.contains(lower) && lower != localLegacyLower
        }
    }

    private func mergedDayLocked(forKey key: String, scope: StatsDeviceScope = .allDevices) -> DailyKeyStatsRecord? {
        var acc = days[key]
        guard scope == .allDevices else { return acc }

        for deviceDays in remoteDaysByDevice.values {
            if let remoteDay = deviceDays[key] {
                acc = Self.mergeDay(existing: acc, incoming: remoteDay)
            }
        }
        for deviceDays in activeImportedPeerDevicesLocked().values {
            if let importedPeerDay = deviceDays[key] {
                acc = Self.mergeDay(existing: acc, incoming: importedPeerDay)
            }
        }
        return acc
    }

    private func allKnownDayKeysLocked(scope: StatsDeviceScope = .allDevices) -> [String] {
        var keys = Set(days.keys)
        guard scope == .allDevices else { return Array(keys) }

        for deviceDays in remoteDaysByDevice.values {
            keys.formUnion(deviceDays.keys)
        }
        for deviceDays in activeImportedPeerDevicesLocked().values {
            keys.formUnion(deviceDays.keys)
        }
        return Array(keys)
    }

    // MARK: - Queries & Aggregation

    public func todayMenuBarCounts() -> (keys: Int, clicks: Int) {
        let (todayKey, _) = Self.dayKeyAndHour(for: nowProvider())
        return queue.sync {
            guard let rec = mergedDayLocked(forKey: todayKey, scope: .allDevices) else { return (0, 0) }
            return (rec.keyPresses, rec.totalClicks)
        }
    }

    public func currentRatesSnapshot() -> (currentKPS: Int, currentCPS: Int, peakKPS: Int, peakCPS: Int) {
        let nowDate = nowProvider()
        let nowTs = nowDate.timeIntervalSince1970
        let (todayKey, _) = Self.dayKeyAndHour(for: nowDate)
        return queue.sync {
            recentKeyTimestamps.removeAll { nowTs - $0 > 1.0 }
            recentClickTimestamps.removeAll { nowTs - $0 > 1.0 }
            let liveKPS = recentKeyTimestamps.count
            let liveCPS = recentClickTimestamps.count
            let todayMerged = mergedDayLocked(forKey: todayKey, scope: .allDevices)
            let peakKPS = max(liveKPS, todayMerged?.peakKPS ?? 0)
            let peakCPS = max(liveCPS, todayMerged?.peakCPS ?? 0)
            return (liveKPS, liveCPS, peakKPS, peakCPS)
        }
    }

    public func snapshot(
        for range: StatsTimeRange,
        deviceScope: StatsDeviceScope = .allDevices
    ) -> KeyStatsAggregateSnapshot {
        let nowDate = nowProvider()
        return queue.sync {
            let includedKeys = filteredDayKeysLocked(for: range, scope: deviceScope, referenceDate: nowDate)

            var totalKeys = 0
            var leftClicks = 0
            var rightClicks = 0
            var middleClicks = 0
            var sideBackClicks = 0
            var sideForwardClicks = 0
            var mousePx: Double = 0
            var scrollPx: Double = 0
            var peakKPS = 0
            var peakCPS = 0
            var backspaces = 0
            var leftHand = 0
            var rightHand = 0
            var romanKeys = 0
            var nonRomanKeys = 0
            var activeDays = 0
            var maxDailyKeys = 0
            var heatmap: [String: Int] = [:]
            var shortcuts: [String: Int] = [:]
            var hourlyKeys = Array(repeating: 0, count: 24)
            var hourlyClicks = Array(repeating: 0, count: 24)
            var mergedApps: [String: AppActivityRecord] = [:]

            for key in includedKeys {
                guard let day = mergedDayLocked(forKey: key, scope: deviceScope) else { continue }
                if day.keyPresses > 0 || day.totalClicks > 0 {
                    activeDays += 1
                }
                if day.keyPresses > maxDailyKeys {
                    maxDailyKeys = day.keyPresses
                }
                totalKeys += day.keyPresses
                leftClicks += day.leftClicks
                rightClicks += day.rightClicks
                middleClicks += day.middleClicks
                sideBackClicks += day.sideBackClicks
                sideForwardClicks += day.sideForwardClicks
                mousePx += day.mouseDistancePx
                scrollPx += day.scrollDistancePx
                peakKPS = max(peakKPS, day.peakKPS)
                peakCPS = max(peakCPS, day.peakCPS)
                backspaces += day.backspacePresses
                leftHand += day.leftHandPresses
                rightHand += day.rightHandPresses
                romanKeys += day.romanKeyPresses
                nonRomanKeys += day.nonRomanKeyPresses

                for (k, v) in day.keyHeatmapCounts {
                    heatmap[k, default: 0] += v
                }
                for (sc, v) in day.shortcutCounts {
                    shortcuts[sc, default: 0] += v
                }
                for h in 0..<min(24, day.hourlyKeys.count) {
                    hourlyKeys[h] += day.hourlyKeys[h]
                }
                for h in 0..<min(24, day.hourlyClicks.count) {
                    hourlyClicks[h] += day.hourlyClicks[h]
                }
                for (bid, app) in day.appStats {
                    var agg = mergedApps[bid] ?? AppActivityRecord(bundleID: bid, displayName: app.displayName)
                    if !app.displayName.isEmpty { agg.displayName = app.displayName }
                    agg.keyPresses += app.keyPresses
                    agg.leftClicks += app.leftClicks
                    agg.rightClicks += app.rightClicks
                    agg.otherClicks += app.otherClicks
                    agg.scrollDistancePx += app.scrollDistancePx
                    agg.tabsAccepted += app.tabsAccepted
                    agg.charactersSaved += app.charactersSaved
                    if let appHeat = app.keyHeatmapCounts, !appHeat.isEmpty {
                        var combined = agg.keyHeatmapCounts ?? [:]
                        for (hk, hv) in appHeat {
                            combined[hk, default: 0] += hv
                        }
                        agg.keyHeatmapCounts = combined
                    }
                    mergedApps[bid] = agg
                }
            }

            let topShortcutItems = shortcuts
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(8)
                .map { RankedCountItem(label: $0.key, count: $0.value) }

            let topKeyItems = heatmap
                .filter { $0.value > 0 && KeyCodeMapper.recognizedKeyIDs.contains($0.key) }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(15)
                .map { RankedCountItem(label: KeyCodeMapper.prettyKeyLabel($0.key), count: $0.value) }

            let topAppItems = mergedApps.values
                .filter { $0.keyPresses > 0 || $0.totalClicks > 0 || $0.scrollDistancePx > 0 }
                .sorted {
                    let lScore = $0.keyPresses + $0.totalClicks
                    let rScore = $1.keyPresses + $1.totalClicks
                    if lScore != rScore { return lScore > rScore }
                    return $0.displayName < $1.displayName
                }
                .prefix(200)
                .map {
                    AppActivitySummary(
                        bundleID: $0.bundleID,
                        displayName: $0.displayName,
                        keyPresses: $0.keyPresses,
                        clicks: $0.totalClicks,
                        scrollMeters: $0.scrollDistancePx * KeyStatsAggregateSnapshot.metersPerPixel,
                        scrollPx: $0.scrollDistancePx,
                        charactersSaved: $0.charactersSaved,
                        keyHeatmap: $0.keyHeatmapCounts ?? [:]
                    )
                }

            let allScopeKeys = allKnownDayKeysLocked(scope: deviceScope)
                .filter {
                    guard let d = mergedDayLocked(forKey: $0, scope: deviceScope) else { return false }
                    return d.keyPresses > 0 || d.totalClicks > 0
                }
                .sorted()
            let firstActiveKey = allScopeKeys.first
            let lastActiveKey = allScopeKeys.last
            let (currentStreak, longestStreak) = Self.computeStreaks(
                sortedActiveDayKeys: allScopeKeys,
                referenceDate: nowDate
            )

            // Build chronological daily trend points for the selected range
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: nowDate)
            let todayKey = Self.dayKeyAndHour(for: nowDate).0
            let trendKeys: [String]
            switch range {
            case .today:
                trendKeys = [todayKey]
            case .days7:
                trendKeys = Self.recentDayKeys(count: 7, referenceDate: nowDate).reversed()
            case .days30:
                trendKeys = Self.recentDayKeys(count: 30, referenceDate: nowDate).reversed()
            case .allTime:
                if let first = firstActiveKey {
                    trendKeys = Self.chronologicalDayKeys(from: first, to: todayKey, maxDays: 1095)
                } else {
                    trendKeys = [todayKey]
                }
            }
            let dailyTrendPoints = trendKeys.map { k in
                let rec = mergedDayLocked(forKey: k, scope: deviceScope)
                return DailyActivityPoint(
                    dateKey: k,
                    keyPresses: rec?.keyPresses ?? 0,
                    clicks: rec?.totalClicks ?? 0,
                    mouseDistanceMeters: (rec?.mouseDistancePx ?? 0) * KeyStatsAggregateSnapshot.metersPerPixel,
                    scrollDistanceMeters: (rec?.scrollDistancePx ?? 0) * KeyStatsAggregateSnapshot.metersPerPixel,
                    scrollDistancePx: rec?.scrollDistancePx ?? 0
                )
            }

            // Build Sunday-aligned 53-week calendar grid ending on today
            let todayWeekday = calendar.component(.weekday, from: startOfToday) // 1 = Sun ... 7 = Sat
            let calendarStartOffset = -(52 * 7 + max(0, todayWeekday - 1))
            var calDays: [CalendarActivityDay] = []
            calDays.reserveCapacity(abs(calendarStartOffset) + 1)
            for offset in stride(from: calendarStartOffset, through: 0, by: 1) {
                if let d = calendar.date(byAdding: .day, value: offset, to: startOfToday) {
                    let (k, _) = Self.dayKeyAndHour(for: d)
                    let rec = mergedDayLocked(forKey: k, scope: deviceScope)
                    calDays.append(CalendarActivityDay(
                        dateKey: k,
                        keyPresses: rec?.keyPresses ?? 0,
                        clicks: rec?.totalClicks ?? 0
                    ))
                }
            }

            let activeDevices = deviceScope == .thisMac
                ? 1
                : 1 + remoteDaysByDevice.count + activeImportedPeerDevicesLocked().count
            let activeAnsiKeys = KeyCodeMapper.ansiKeyIDs.reduce(0) { acc, id in
                acc + ((heatmap[id, default: 0] > 0) ? 1 : 0)
            }

            return KeyStatsAggregateSnapshot(
                range: range,
                deviceScope: deviceScope,
                deviceCount: activeDevices,
                totalKeyPresses: totalKeys,
                totalClicks: leftClicks + rightClicks + middleClicks + sideBackClicks + sideForwardClicks,
                leftClicks: leftClicks,
                rightClicks: rightClicks,
                otherClicks: middleClicks + sideBackClicks + sideForwardClicks,
                middleClicks: middleClicks,
                sideBackClicks: sideBackClicks,
                sideForwardClicks: sideForwardClicks,
                mouseDistanceMeters: mousePx * KeyStatsAggregateSnapshot.metersPerPixel,
                scrollDistanceMeters: scrollPx * KeyStatsAggregateSnapshot.metersPerPixel,
                scrollDistancePx: scrollPx,
                peakKPS: peakKPS,
                peakCPS: peakCPS,
                backspacePresses: backspaces,
                leftHandPresses: leftHand,
                rightHandPresses: rightHand,
                romanKeyPresses: romanKeys,
                nonRomanKeyPresses: nonRomanKeys,
                activeDays: activeDays,
                maxDailyKeys: maxDailyKeys,
                firstActiveDateKey: firstActiveKey,
                lastActiveDateKey: lastActiveKey,
                currentStreakDays: currentStreak,
                longestStreakDays: longestStreak,
                activeKeyCount: activeAnsiKeys,
                keyHeatmap: heatmap,
                topShortcuts: Array(topShortcutItems),
                topKeys: Array(topKeyItems),
                topApps: Array(topAppItems),
                hourlyKeys: hourlyKeys,
                hourlyClicks: hourlyClicks,
                dailyTrend: dailyTrendPoints,
                calendarDays: calDays
            )
        }
    }

    // MARK: - Installed KeyStats.app Discovery & Import

    public static func defaultInstalledKeyStatsPaths() -> (plistURL: URL, syncCacheURL: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plistURL = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("com.keystats.app.plist")
        let syncCacheURL = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("KeyStats", isDirectory: true)
            .appendingPathComponent("sync-cache.json")
        return (plistURL, syncCacheURL)
    }

    public static func hasInstalledKeyStatsData(
        plistURL: URL? = nil,
        syncCacheURL: URL? = nil
    ) -> Bool {
        let defaults = defaultInstalledKeyStatsPaths()
        let plist = plistURL ?? defaults.plistURL
        let syncCache = syncCacheURL ?? defaults.syncCacheURL
        return FileManager.default.fileExists(atPath: plist.path)
            || FileManager.default.fileExists(atPath: syncCache.path)
    }

    /// Reads local KeyStats preferences (`dailyStatsHistory`, `dailyStats`, `hourlyStats.v1`) and
    /// optionally KeyStats's synced peer cache (`sync-cache.json`), reconciling overlapping calendar
    /// days cleanly via per-day max so no keystroke/click/distance is double-counted.
    @discardableResult
    public func importFromInstalledKeyStats(
        plistURL: URL? = nil,
        syncCacheURL: URL? = nil,
        includeSyncedPeers: Bool = true
    ) throws -> KeyStatsImportReport {
        let defaults = Self.defaultInstalledKeyStatsPaths()
        let plist = plistURL ?? defaults.plistURL
        let syncCache = syncCacheURL ?? defaults.syncCacheURL

        let plistExists = FileManager.default.fileExists(atPath: plist.path)
        let syncCacheExists = includeSyncedPeers && FileManager.default.fileExists(atPath: syncCache.path)
        guard plistExists || syncCacheExists else {
            throw NSError(
                domain: "KeyStatsStore",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No local KeyStats data found to import."]
            )
        }

        return try queue.sync {
            var localImportedMap: [String: DailyKeyStatsRecord] = [:]
            var detectedLocalDevID: String?
            var hourlyBucketsCount = 0

            if plistExists {
                let plistData = try Data(contentsOf: plist)
                guard let dict = try PropertyListSerialization.propertyList(
                    from: plistData,
                    options: [],
                    format: nil
                ) as? [String: Any] else {
                    throw NSError(
                        domain: "KeyStatsStore",
                        code: 422,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid KeyStats preferences property list."]
                    )
                }

                if let devID = dict["sync.installationDeviceId.v1"] as? String, !devID.isEmpty {
                    detectedLocalDevID = devID
                    legacyKeyStatsDeviceID = devID
                }

                // 1. Decode `dailyStatsHistory` JSON blob (Foundation Date encoding -> default decoder first)
                if let histData = dict["dailyStatsHistory"] as? Data {
                    for decoder in [JSONDecoder(), Self.makeFlexibleDateDecoder()] {
                        if let history = try? decoder.decode([String: ExternalKeyStatsPayload.ExtDay].self, from: histData) {
                            for (rawKey, extDay) in history {
                                let normalizedKey = Self.normalizeExternalDayKey(rawKey, fallbackDate: extDay.date)
                                let converted = Self.convertExternalDay(extDay, dateKey: normalizedKey)
                                localImportedMap[normalizedKey] = Self.reconcileSameDeviceDay(
                                    existing: localImportedMap[normalizedKey],
                                    incoming: converted
                                )
                            }
                            break
                        }
                    }
                }

                // 2. Decode live `dailyStats` JSON blob for today (reconciled so fresher day totals win)
                if let curData = dict["dailyStats"] as? Data {
                    for decoder in [JSONDecoder(), Self.makeFlexibleDateDecoder()] {
                        if let curDay = try? decoder.decode(ExternalKeyStatsPayload.ExtDay.self, from: curData) {
                            let curKey = Self.normalizeExternalDayKey("", fallbackDate: curDay.date ?? nowProvider())
                            let converted = Self.convertExternalDay(curDay, dateKey: curKey)
                            localImportedMap[curKey] = Self.reconcileSameDeviceDay(
                                existing: localImportedMap[curKey],
                                incoming: converted
                            )
                            break
                        }
                    }
                }

                // 3. Decode `hourlyStats.v1` JSON blob (Unix epoch seconds -> 24h buckets per day)
                if let hourlyData = dict["hourlyStats.v1"] as? Data,
                   let hourlyPayload = try? JSONDecoder().decode(ExternalHourlyStatsPayload.self, from: hourlyData),
                   let buckets = hourlyPayload.buckets {
                    var cal = Calendar(identifier: .gregorian)
                    if let tzID = hourlyPayload.timeZoneIdentifier, let tz = TimeZone(identifier: tzID) {
                        cal.timeZone = tz
                    }
                    for (tsKey, bucket) in buckets {
                        guard let unixSeconds = TimeInterval(tsKey) else { continue }
                        let date = Date(timeIntervalSince1970: unixSeconds)
                        let (dayKey, hour) = Self.dayKeyAndHour(for: date, calendar: cal)
                        guard hour >= 0 && hour < 24 else { continue }
                        let k = bucket.keys ?? 0
                        let c = bucket.clicks ?? 0
                        guard k > 0 || c > 0 else { continue }
                        var rec = localImportedMap[dayKey] ?? days[dayKey] ?? DailyKeyStatsRecord(dateKey: dayKey)
                        rec.hourlyKeys[hour] = max(rec.hourlyKeys[hour], k)
                        rec.hourlyClicks[hour] = max(rec.hourlyClicks[hour], c)
                        localImportedMap[dayKey] = rec
                        hourlyBucketsCount += 1
                    }
                }

                for (dayKey, incoming) in localImportedMap {
                    days[dayKey] = Self.reconcileSameDeviceDay(existing: days[dayKey], incoming: incoming)
                }
            }

            // 4. Decode KeyStats synced peer cache (`sync-cache.json`) without colliding with local device
            var peerDaysCount = 0
            var importedPeerIDs = Set<String>()
            if syncCacheExists,
               let cacheData = try? Data(contentsOf: syncCache),
               let cache = try? JSONDecoder().decode(ExternalSyncCachePayload.self, from: cacheData),
               let shards = cache.shards {
                for shard in shards.values {
                    guard let snap = shard.snapshot,
                          let rawPeerID = snap.deviceId,
                          !rawPeerID.isEmpty else {
                        continue
                    }
                    if let localDev = detectedLocalDevID ?? legacyKeyStatsDeviceID,
                       rawPeerID.caseInsensitiveCompare(localDev) == .orderedSame {
                        continue
                    }
                    guard let dayKey = snap.localDay,
                          dayKey.count == 10,
                          dayKey.filter({ $0 == "-" }).count == 2 else {
                        continue
                    }

                    let converted = Self.convertSyncCacheSnapshot(snap, dateKey: dayKey)
                    var deviceMap = importedPeerDaysByDevice[rawPeerID] ?? [:]
                    deviceMap[dayKey] = Self.reconcileSameDeviceDay(existing: deviceMap[dayKey], incoming: converted)
                    importedPeerDaysByDevice[rawPeerID] = deviceMap
                    importedPeerIDs.insert(rawPeerID)
                    peerDaysCount += 1
                }
            }

            flushSynchronouslyLocked()

            let allKeys = allKnownDayKeysLocked(scope: .allDevices)
            var totalKeys = 0
            var activeDayCount = 0
            for k in allKeys {
                if let rec = mergedDayLocked(forKey: k, scope: .allDevices),
                   rec.keyPresses > 0 || rec.totalClicks > 0 {
                    totalKeys += rec.keyPresses
                    activeDayCount += 1
                }
            }

            return KeyStatsImportReport(
                localDaysImported: localImportedMap.count,
                hourlyBucketsImported: hourlyBucketsCount,
                peerDevicesImported: importedPeerIDs.count,
                peerDaysImported: peerDaysCount,
                totalKeysAfterImport: totalKeys,
                totalActiveDaysAfterImport: activeDayCount
            )
        }
    }

    // MARK: - Export / Import / Reset

    public func exportJSONData() throws -> Data {
        try queue.sync {
            let archive = makeArchiveLocked()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(archive)
        }
    }

    /// Imports either a native WordTail KeyStats JSON archive OR an exported `debugtheworldbot/keyStats` JSON file!
    /// Returns the number of calendar days imported.
    @discardableResult
    public func importJSONData(_ data: Data, merge: Bool = true) throws -> Int {
        try queue.sync {
            let isoDecoder = JSONDecoder()
            isoDecoder.dateDecodingStrategy = .iso8601
            if let native = try? isoDecoder.decode(NativeExportArchive.self, from: data) {
                if !merge {
                    days.removeAll()
                    importedPeerDaysByDevice.removeAll()
                }
                for (dayKey, incoming) in native.days {
                    days[dayKey] = merge ? Self.mergeDay(existing: days[dayKey], incoming: incoming) : incoming
                }
                if let peers = native.importedPeerDays {
                    for (peerID, peerMap) in peers {
                        var existingPeerMap = importedPeerDaysByDevice[peerID] ?? [:]
                        for (dayKey, incoming) in peerMap {
                            existingPeerMap[dayKey] = merge
                                ? Self.reconcileSameDeviceDay(existing: existingPeerMap[dayKey], incoming: incoming)
                                : incoming
                        }
                        importedPeerDaysByDevice[peerID] = existingPeerMap
                    }
                }
                if legacyKeyStatsDeviceID == nil {
                    legacyKeyStatsDeviceID = native.legacyKeyStatsDeviceID
                }
                flushSynchronouslyLocked()
                return native.days.count
            }

            // Try decoding external `KeyStats` (`debugtheworldbot/keyStats`) export format (uses Foundation default or ISO8601 Date)
            for decoder in [Self.makeFlexibleDateDecoder(), JSONDecoder()] {
                if let ext = try? decoder.decode(ExternalKeyStatsPayload.self, from: data),
                   ext.history != nil || ext.currentStats != nil {
                    if !merge { days.removeAll() }
                    var importedMap: [String: DailyKeyStatsRecord] = [:]
                    if let history = ext.history {
                        for (rawKey, extDay) in history {
                            let normalizedKey = Self.normalizeExternalDayKey(rawKey, fallbackDate: extDay.date)
                            importedMap[normalizedKey] = Self.reconcileSameDeviceDay(
                                existing: importedMap[normalizedKey],
                                incoming: Self.convertExternalDay(extDay, dateKey: normalizedKey)
                            )
                        }
                    }
                    if let cur = ext.currentStats {
                        let curKey = Self.normalizeExternalDayKey("", fallbackDate: cur.date ?? nowProvider())
                        if importedMap[curKey] == nil {
                            importedMap[curKey] = Self.convertExternalDay(cur, dateKey: curKey)
                        }
                    }
                    for (k, incoming) in importedMap {
                        days[k] = merge ? Self.reconcileSameDeviceDay(existing: days[k], incoming: incoming) : incoming
                    }
                    flushSynchronouslyLocked()
                    return importedMap.count
                }
            }

            throw NSError(
                domain: "KeyStatsStore",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Unrecognized JSON format. Expected a WordTail or KeyStats export file."]
            )
        }
    }

    public func flushNow() {
        queue.sync {
            if isDirty {
                flushSynchronouslyLocked()
            }
        }
    }

    public func clearAll() {
        queue.sync {
            days.removeAll()
            importedPeerDaysByDevice.removeAll()
            legacyKeyStatsDeviceID = nil
            modifierTracker.reset()
            lastMousePoint = nil
            recentKeyTimestamps.removeAll()
            recentClickTimestamps.removeAll()
            isDirty = false
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Private Helpers

    private func filteredDayKeysLocked(
        for range: StatsTimeRange,
        scope: StatsDeviceScope,
        referenceDate: Date
    ) -> [String] {
        switch range {
        case .today:
            let (todayKey, _) = Self.dayKeyAndHour(for: referenceDate)
            return [todayKey]
        case .days7:
            return Self.recentDayKeys(count: 7, referenceDate: referenceDate)
        case .days30:
            return Self.recentDayKeys(count: 30, referenceDate: referenceDate)
        case .allTime:
            return allKnownDayKeysLocked(scope: scope)
        }
    }

    private func incrementHandLocked(for keyID: String, in record: inout DailyKeyStatsRecord) {
        switch KeyCodeMapper.hand(forKeyID: keyID) {
        case .left: record.leftHandPresses += 1
        case .right: record.rightHandPresses += 1
        case .neutral: break
        }
    }

    private func markDirtyAndMaybeFlushLocked(nowTs: TimeInterval) {
        isDirty = true
        if nowTs - lastDiskFlushTime >= 2.5 {
            flushSynchronouslyLocked(nowTs: nowTs)
        }
    }

    private func makeArchiveLocked() -> NativeExportArchive {
        NativeExportArchive(
            schema: "app.wordtail.keystats",
            version: 1,
            exportedAt: nowProvider(),
            days: days,
            importedPeerDays: importedPeerDaysByDevice.isEmpty ? nil : importedPeerDaysByDevice,
            legacyKeyStatsDeviceID: legacyKeyStatsDeviceID
        )
    }

    private func flushSynchronouslyLocked(nowTs: TimeInterval? = nil) {
        lastDiskFlushTime = nowTs ?? nowProvider().timeIntervalSince1970
        isDirty = false
        let archive = makeArchiveLocked()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(archive) {
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func dayKeyAndHour(for date: Date, calendar: Calendar = Calendar.current) -> (String, Int) {
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        let key = String(
            format: "%04d-%02d-%02d",
            comps.year ?? 1970,
            comps.month ?? 1,
            comps.day ?? 1
        )
        return (key, comps.hour ?? 0)
    }

    private static func recentDayKeys(count: Int, referenceDate: Date) -> [String] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: referenceDate)
        return (0..<count).compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return dayKeyAndHour(for: d).0
        }
    }

    private static func dayKeyFormatter() -> DateFormatter {
        let df = DateFormatter()
        df.calendar = Calendar.current
        df.timeZone = Calendar.current.timeZone
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }

    private static func chronologicalDayKeys(from startKey: String, to endKey: String, maxDays: Int) -> [String] {
        let df = dayKeyFormatter()
        let cal = Calendar.current
        guard let startDate = df.date(from: startKey),
              let endDate = df.date(from: endKey),
              startDate <= endDate else {
            return [endKey]
        }
        let s = cal.startOfDay(for: startDate)
        let e = cal.startOfDay(for: endDate)
        let diff = cal.dateComponents([.day], from: s, to: e).day ?? 0
        let count = min(maxDays, max(0, diff))
        let effectiveStart = cal.date(byAdding: .day, value: -count, to: e) ?? s
        return (0...count).compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: offset, to: effectiveStart) else { return nil }
            return dayKeyAndHour(for: d).0
        }
    }

    private static func computeStreaks(sortedActiveDayKeys: [String], referenceDate: Date) -> (current: Int, longest: Int) {
        guard !sortedActiveDayKeys.isEmpty else { return (0, 0) }
        let df = dayKeyFormatter()
        let cal = Calendar.current
        let activeDates: [Date] = sortedActiveDayKeys.compactMap { df.date(from: $0).map { cal.startOfDay(for: $0) } }
        guard !activeDates.isEmpty else { return (0, 0) }

        var longest = 1
        var run = 1
        for idx in 1..<activeDates.count {
            let delta = cal.dateComponents([.day], from: activeDates[idx - 1], to: activeDates[idx]).day ?? 0
            if delta == 1 {
                run += 1
                if run > longest { longest = run }
            } else if delta > 1 {
                run = 1
            }
        }

        let today = cal.startOfDay(for: referenceDate)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)
        let activeSet = Set(activeDates)
        var current = 0
        var cursor: Date?
        if activeSet.contains(today) {
            cursor = today
        } else if let yesterday, activeSet.contains(yesterday) {
            cursor = yesterday
        }
        while let d = cursor, activeSet.contains(d) {
            current += 1
            cursor = cal.date(byAdding: .day, value: -1, to: d)
        }
        return (current, longest)
    }

    private static func makeFlexibleDateDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func normalizeExternalDayKey(_ raw: String, fallbackDate: Date?) -> String {
        if raw.count == 10, raw.filter({ $0 == "-" }).count == 2 {
            return raw
        }
        return dayKeyAndHour(for: fallbackDate ?? Date()).0
    }

    private struct NormalizedKeyAggregate {
        var heatmap: [String: Int] = [:]
        var shortcuts: [String: Int] = [:]
        var backspaces: Int = 0
        var leftHand: Int = 0
        var rightHand: Int = 0
    }

    private static func aggregateExternalKeyCounts(_ rawKeyMap: [String: Int]?) -> NormalizedKeyAggregate {
        var agg = NormalizedKeyAggregate()
        guard let rawKeyMap else { return agg }

        for (rawCombo, count) in rawKeyMap where count > 0 {
            let parts = rawCombo.split(separator: "+").map(String.init)
            var normalizedParts: [String] = []
            normalizedParts.reserveCapacity(parts.count)

            for p in parts {
                guard let norm = normalizeExternalKeyID(p) else { continue }
                normalizedParts.append(norm)
                agg.heatmap[norm, default: 0] += count
                if norm == "Delete" || norm == "ForwardDelete" {
                    agg.backspaces += count
                }
                switch KeyCodeMapper.hand(forKeyID: norm) {
                case .left: agg.leftHand += count
                case .right: agg.rightHand += count
                case .neutral: break
                }
            }

            if parts.count >= 2, let lastPart = parts.last, let baseNorm = normalizeExternalKeyID(lastPart) {
                let hasCmd = parts.contains { $0.contains("Cmd") || $0.contains("Win") }
                let hasOpt = parts.contains { $0.contains("Option") || $0.contains("Alt") }
                let hasCtrl = parts.contains { $0.contains("Ctrl") }
                let hasShift = parts.contains { $0.contains("Shift") }
                if hasCmd || hasOpt || hasCtrl {
                    var s = ""
                    if hasCtrl { s += "⌃" }
                    if hasOpt { s += "⌥" }
                    if hasShift { s += "⇧" }
                    if hasCmd { s += "⌘" }
                    s += KeyCodeMapper.prettyKeyLabel(baseNorm)
                    agg.shortcuts[s, default: 0] += count
                }
            }
        }
        return agg
    }

    private static func convertExternalDay(_ ext: ExternalKeyStatsPayload.ExtDay, dateKey: String) -> DailyKeyStatsRecord {
        var rec = DailyKeyStatsRecord(dateKey: dateKey)
        rec.keyPresses = ext.keyPresses ?? 0
        rec.romanKeyPresses = rec.keyPresses
        rec.leftClicks = ext.leftClicks ?? 0
        rec.rightClicks = ext.rightClicks ?? 0
        rec.middleClicks = ext.middleClicks ?? 0
        rec.sideBackClicks = ext.sideBackClicks ?? 0
        rec.sideForwardClicks = ext.sideForwardClicks ?? 0
        rec.mouseDistancePx = ext.mouseDistance ?? 0
        rec.scrollDistancePx = ext.scrollDistance ?? 0
        rec.peakKPS = Int(ext.peakKPS ?? 0)
        rec.peakCPS = Int(ext.peakCPS ?? 0)

        let keyAgg = aggregateExternalKeyCounts(ext.keyPressCounts)
        rec.keyHeatmapCounts = keyAgg.heatmap
        rec.shortcutCounts = keyAgg.shortcuts
        rec.backspacePresses = keyAgg.backspaces
        rec.leftHandPresses = keyAgg.leftHand
        rec.rightHandPresses = keyAgg.rightHand

        if let extApps = ext.appStats {
            for (bid, a) in extApps {
                let cleanID = a.bundleId ?? bid
                let appKeyAgg = aggregateExternalKeyCounts(a.keyPressCounts)
                rec.appStats[cleanID] = AppActivityRecord(
                    bundleID: cleanID,
                    displayName: a.displayName ?? cleanID,
                    keyPresses: a.keyPresses ?? 0,
                    leftClicks: a.leftClicks ?? 0,
                    rightClicks: a.rightClicks ?? 0,
                    otherClicks: (a.sideBackClicks ?? 0) + (a.sideForwardClicks ?? 0) + (a.otherClicks ?? 0),
                    scrollDistancePx: a.scrollDistance ?? 0,
                    keyHeatmapCounts: appKeyAgg.heatmap.isEmpty ? nil : appKeyAgg.heatmap
                )
            }
        }
        return rec
    }

    private static func convertSyncCacheSnapshot(
        _ snap: ExternalSyncCachePayload.Snapshot,
        dateKey: String
    ) -> DailyKeyStatsRecord {
        var rec = DailyKeyStatsRecord(dateKey: dateKey)
        rec.keyPresses = snap.keyPresses ?? 0
        rec.romanKeyPresses = rec.keyPresses
        if let clicks = snap.clicks {
            rec.leftClicks = clicks["left"] ?? 0
            rec.rightClicks = clicks["right"] ?? 0
            rec.middleClicks = clicks["middle"] ?? 0
            rec.sideBackClicks = clicks["sideBack"] ?? 0
            rec.sideForwardClicks = clicks["sideForward"] ?? 0
        }
        let keyAgg = aggregateExternalKeyCounts(snap.keyPressCounts)
        rec.keyHeatmapCounts = keyAgg.heatmap
        rec.shortcutCounts = keyAgg.shortcuts
        rec.backspacePresses = keyAgg.backspaces
        rec.leftHandPresses = keyAgg.leftHand
        rec.rightHandPresses = keyAgg.rightHand
        return rec
    }

    private static func normalizeExternalKeyID(_ raw: String) -> String? {
        let mapped: String
        switch raw {
        case "Cmd", "LWin", "Win": mapped = "LeftCmd"
        case "RWin": mapped = "RightCmd"
        case "Shift", "LShift": mapped = "LeftShift"
        case "RShift": mapped = "RightShift"
        case "Option", "LAlt", "Alt": mapped = "LeftOption"
        case "RAlt": mapped = "RightOption"
        case "LCtrl", "RCtrl": mapped = "Ctrl"
        case "Backspace": mapped = "Delete"
        case "Del": mapped = "ForwardDelete"
        case "Enter": mapped = "Return"
        case "Escape": mapped = "Esc"
        case "，": mapped = ","
        case "。": mapped = "."
        default:
            if raw.count == 1, let ch = raw.first, ch >= "a" && ch <= "z" {
                mapped = raw.uppercased()
            } else {
                mapped = raw
            }
        }
        return KeyCodeMapper.recognizedKeyIDs.contains(mapped) ? mapped : nil
    }

    /// Reconciles two records collected on the SAME device on the same day (e.g. KeyStats.app + WordTail)
    /// without double-counting overlapping keystrokes/clicks/distances, while preserving WordTail-specific
    /// telemetry (Roman vs CJK layout ratio, Tabs accepted, chars saved).
    private static func reconcileSameDeviceDay(
        existing: DailyKeyStatsRecord?,
        incoming: DailyKeyStatsRecord
    ) -> DailyKeyStatsRecord {
        guard var acc = existing else { return incoming }

        let prevRomanTotal = acc.romanKeyPresses + acc.nonRomanKeyPresses
        let newTotalKeys = max(acc.keyPresses, incoming.keyPresses)
        acc.keyPresses = newTotalKeys
        acc.autoRepeatPresses = max(acc.autoRepeatPresses, incoming.autoRepeatPresses)

        if prevRomanTotal > 0 && incoming.nonRomanKeyPresses == 0 && newTotalKeys > 0 {
            let ratio = Double(acc.romanKeyPresses) / Double(prevRomanTotal)
            acc.romanKeyPresses = min(newTotalKeys, Int((Double(newTotalKeys) * ratio).rounded()))
            acc.nonRomanKeyPresses = max(0, newTotalKeys - acc.romanKeyPresses)
        } else {
            acc.romanKeyPresses = max(acc.romanKeyPresses, incoming.romanKeyPresses)
            acc.nonRomanKeyPresses = max(acc.nonRomanKeyPresses, incoming.nonRomanKeyPresses)
        }

        acc.backspacePresses = max(acc.backspacePresses, incoming.backspacePresses)
        acc.leftHandPresses = max(acc.leftHandPresses, incoming.leftHandPresses)
        acc.rightHandPresses = max(acc.rightHandPresses, incoming.rightHandPresses)
        acc.leftClicks = max(acc.leftClicks, incoming.leftClicks)
        acc.rightClicks = max(acc.rightClicks, incoming.rightClicks)
        acc.middleClicks = max(acc.middleClicks, incoming.middleClicks)
        acc.sideBackClicks = max(acc.sideBackClicks, incoming.sideBackClicks)
        acc.sideForwardClicks = max(acc.sideForwardClicks, incoming.sideForwardClicks)
        acc.mouseDistancePx = max(acc.mouseDistancePx, incoming.mouseDistancePx)
        acc.scrollDistancePx = max(acc.scrollDistancePx, incoming.scrollDistancePx)
        acc.peakKPS = max(acc.peakKPS, incoming.peakKPS)
        acc.peakCPS = max(acc.peakCPS, incoming.peakCPS)
        acc.tabsAccepted = max(acc.tabsAccepted, incoming.tabsAccepted)
        acc.charactersSaved = max(acc.charactersSaved, incoming.charactersSaved)

        for (k, v) in incoming.keyHeatmapCounts {
            acc.keyHeatmapCounts[k] = max(acc.keyHeatmapCounts[k, default: 0], v)
        }
        for (k, v) in incoming.shortcutCounts {
            acc.shortcutCounts[k] = max(acc.shortcutCounts[k, default: 0], v)
        }
        for h in 0..<24 {
            let eK = h < acc.hourlyKeys.count ? acc.hourlyKeys[h] : 0
            let iK = h < incoming.hourlyKeys.count ? incoming.hourlyKeys[h] : 0
            if h < acc.hourlyKeys.count { acc.hourlyKeys[h] = max(eK, iK) }
            let eC = h < acc.hourlyClicks.count ? acc.hourlyClicks[h] : 0
            let iC = h < incoming.hourlyClicks.count ? incoming.hourlyClicks[h] : 0
            if h < acc.hourlyClicks.count { acc.hourlyClicks[h] = max(eC, iC) }
        }
        for (bid, app) in incoming.appStats {
            var cur = acc.appStats[bid] ?? AppActivityRecord(bundleID: bid, displayName: app.displayName)
            if !app.displayName.isEmpty && (cur.displayName.isEmpty || cur.displayName == bid) {
                cur.displayName = app.displayName
            }
            cur.keyPresses = max(cur.keyPresses, app.keyPresses)
            cur.leftClicks = max(cur.leftClicks, app.leftClicks)
            cur.rightClicks = max(cur.rightClicks, app.rightClicks)
            cur.otherClicks = max(cur.otherClicks, app.otherClicks)
            cur.scrollDistancePx = max(cur.scrollDistancePx, app.scrollDistancePx)
            cur.tabsAccepted = max(cur.tabsAccepted, app.tabsAccepted)
            cur.charactersSaved = max(cur.charactersSaved, app.charactersSaved)
            if let appHeat = app.keyHeatmapCounts, !appHeat.isEmpty {
                var mergedHeat = cur.keyHeatmapCounts ?? [:]
                for (hk, hv) in appHeat {
                    mergedHeat[hk] = max(mergedHeat[hk, default: 0], hv)
                }
                cur.keyHeatmapCounts = mergedHeat
            }
            acc.appStats[bid] = cur
        }
        return acc
    }

    private static func mergeDay(existing: DailyKeyStatsRecord?, incoming: DailyKeyStatsRecord) -> DailyKeyStatsRecord {
        guard var acc = existing else { return incoming }
        acc.keyPresses += incoming.keyPresses
        acc.autoRepeatPresses += incoming.autoRepeatPresses
        acc.romanKeyPresses += incoming.romanKeyPresses
        acc.nonRomanKeyPresses += incoming.nonRomanKeyPresses
        acc.backspacePresses += incoming.backspacePresses
        acc.leftHandPresses += incoming.leftHandPresses
        acc.rightHandPresses += incoming.rightHandPresses
        acc.leftClicks += incoming.leftClicks
        acc.rightClicks += incoming.rightClicks
        acc.middleClicks += incoming.middleClicks
        acc.sideBackClicks += incoming.sideBackClicks
        acc.sideForwardClicks += incoming.sideForwardClicks
        acc.mouseDistancePx += incoming.mouseDistancePx
        acc.scrollDistancePx += incoming.scrollDistancePx
        acc.peakKPS = max(acc.peakKPS, incoming.peakKPS)
        acc.peakCPS = max(acc.peakCPS, incoming.peakCPS)
        acc.tabsAccepted += incoming.tabsAccepted
        acc.charactersSaved += incoming.charactersSaved

        for (k, v) in incoming.keyHeatmapCounts {
            acc.keyHeatmapCounts[k, default: 0] += v
        }
        for (k, v) in incoming.shortcutCounts {
            acc.shortcutCounts[k, default: 0] += v
        }
        for h in 0..<24 {
            if h < incoming.hourlyKeys.count { acc.hourlyKeys[h] += incoming.hourlyKeys[h] }
            if h < incoming.hourlyClicks.count { acc.hourlyClicks[h] += incoming.hourlyClicks[h] }
        }
        for (bid, app) in incoming.appStats {
            var cur = acc.appStats[bid] ?? AppActivityRecord(bundleID: bid, displayName: app.displayName)
            if !app.displayName.isEmpty { cur.displayName = app.displayName }
            cur.keyPresses += app.keyPresses
            cur.leftClicks += app.leftClicks
            cur.rightClicks += app.rightClicks
            cur.otherClicks += app.otherClicks
            cur.scrollDistancePx += app.scrollDistancePx
            cur.tabsAccepted += app.tabsAccepted
            cur.charactersSaved += app.charactersSaved
            if let appHeat = app.keyHeatmapCounts, !appHeat.isEmpty {
                var mergedHeat = cur.keyHeatmapCounts ?? [:]
                for (hk, hv) in appHeat {
                    mergedHeat[hk, default: 0] += hv
                }
                cur.keyHeatmapCounts = mergedHeat
            }
            acc.appStats[bid] = cur
        }
        return acc
    }
}
