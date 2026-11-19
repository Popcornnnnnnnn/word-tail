import CoreGraphics
import Foundation

public enum StatsTimeRange: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case days7 = "7 Days"
    case days30 = "30 Days"
    case allTime = "All Time"

    public var id: String { rawValue }
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

    public init(
        bundleID: String,
        displayName: String,
        keyPresses: Int = 0,
        leftClicks: Int = 0,
        rightClicks: Int = 0,
        otherClicks: Int = 0,
        scrollDistancePx: Double = 0,
        tabsAccepted: Int = 0,
        charactersSaved: Int = 0
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
    public let charactersSaved: Int

    public init(
        bundleID: String,
        displayName: String,
        keyPresses: Int,
        clicks: Int,
        scrollMeters: Double,
        charactersSaved: Int
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.keyPresses = keyPresses
        self.clicks = clicks
        self.scrollMeters = scrollMeters
        self.charactersSaved = charactersSaved
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
    public let totalKeyPresses: Int
    public let totalClicks: Int
    public let leftClicks: Int
    public let rightClicks: Int
    public let otherClicks: Int
    public let mouseDistanceMeters: Double
    public let scrollDistanceMeters: Double
    public let peakKPS: Int
    public let peakCPS: Int
    public let backspacePresses: Int
    public let leftHandPresses: Int
    public let rightHandPresses: Int
    public let romanKeyPresses: Int
    public let nonRomanKeyPresses: Int
    public let activeDays: Int
    public let maxDailyKeys: Int
    public let keyHeatmap: [String: Int]
    public let topShortcuts: [RankedCountItem]
    public let topKeys: [RankedCountItem]
    public let topApps: [AppActivitySummary]
    public let hourlyKeys: [Int]
    public let hourlyClicks: [Int]
    public let calendarDays: [CalendarActivityDay]

    public init(
        range: StatsTimeRange = .today,
        totalKeyPresses: Int = 0,
        totalClicks: Int = 0,
        leftClicks: Int = 0,
        rightClicks: Int = 0,
        otherClicks: Int = 0,
        mouseDistanceMeters: Double = 0,
        scrollDistanceMeters: Double = 0,
        peakKPS: Int = 0,
        peakCPS: Int = 0,
        backspacePresses: Int = 0,
        leftHandPresses: Int = 0,
        rightHandPresses: Int = 0,
        romanKeyPresses: Int = 0,
        nonRomanKeyPresses: Int = 0,
        activeDays: Int = 0,
        maxDailyKeys: Int = 0,
        keyHeatmap: [String: Int] = [:],
        topShortcuts: [RankedCountItem] = [],
        topKeys: [RankedCountItem] = [],
        topApps: [AppActivitySummary] = [],
        hourlyKeys: [Int] = Array(repeating: 0, count: 24),
        hourlyClicks: [Int] = Array(repeating: 0, count: 24),
        calendarDays: [CalendarActivityDay] = []
    ) {
        self.range = range
        self.totalKeyPresses = totalKeyPresses
        self.totalClicks = totalClicks
        self.leftClicks = leftClicks
        self.rightClicks = rightClicks
        self.otherClicks = otherClicks
        self.mouseDistanceMeters = mouseDistanceMeters
        self.scrollDistanceMeters = scrollDistanceMeters
        self.peakKPS = peakKPS
        self.peakCPS = peakCPS
        self.backspacePresses = backspacePresses
        self.leftHandPresses = leftHandPresses
        self.rightHandPresses = rightHandPresses
        self.romanKeyPresses = romanKeyPresses
        self.nonRomanKeyPresses = nonRomanKeyPresses
        self.activeDays = activeDays
        self.maxDailyKeys = maxDailyKeys
        self.keyHeatmap = keyHeatmap
        self.topShortcuts = topShortcuts
        self.topKeys = topKeys
        self.topApps = topApps
        self.hourlyKeys = hourlyKeys
        self.hourlyClicks = hourlyClicks
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
}

/// Complete local KeyStats-grade telemetry archive with daily time-series, per-key heatmaps,
/// mouse/scroll distance, per-app breakdown, JSON export, and `debugtheworldbot/keyStats` import support.
public final class KeyStatsStore {
    public struct NativeExportArchive: Codable {
        public let schema: String
        public let version: Int
        public let exportedAt: Date
        public let days: [String: DailyKeyStatsRecord]
    }

    // Compatible decoder for importing existing `debugtheworldbot/keyStats` JSON backups!
    private struct ExternalKeyStatsPayload: Decodable {
        struct ExtApp: Decodable {
            var bundleId: String?
            var displayName: String?
            var keyPresses: Int?
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

    private let fileURL: URL
    private let nowProvider: () -> Date
    private let queue = DispatchQueue(label: "app.wordtail.macos.keystats", qos: .utility)

    private var days: [String: DailyKeyStatsRecord] = [:]
    private var remoteDaysByDevice: [String: [String: DailyKeyStatsRecord]] = [:]
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

            // Never record individual key identities while SecureEventInput (password field) is active!
            if !isSecureInput, let baseKey = KeyCodeMapper.keyName(forKeyCode: keyCode) {
                if baseKey == "Delete" || baseKey == "ForwardDelete" {
                    record.backspacePresses += 1
                }

                let activeMods = KeyCodeMapper.activePhysicalModifierKeys(rawFlags: rawFlags, keyCode: keyCode)
                for modKey in activeMods {
                    record.keyHeatmapCounts[modKey, default: 0] += 1
                    self.incrementHandLocked(for: modKey, in: &record)
                }
                record.keyHeatmapCounts[baseKey, default: 0] += 1
                self.incrementHandLocked(for: baseKey, in: &record)

                if let shortcut = KeyCodeMapper.formattedShortcut(baseKey: baseKey, rawFlags: rawFlags) {
                    record.shortcutCounts[shortcut, default: 0] += 1
                }
            }

            if let bid = appBundleID, !bid.isEmpty {
                var app = record.appStats[bid] ?? AppActivityRecord(bundleID: bid, displayName: appName ?? bid)
                if let appName, !appName.isEmpty { app.displayName = appName }
                app.keyPresses += 1
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

    // MARK: - Multi-Device Sync Shards

    public func exportLocalDaysShard() -> [String: DailyKeyStatsRecord] {
        queue.sync { days }
    }

    public func applyRemoteDeviceDays(_ shards: [String: [String: DailyKeyStatsRecord]]) {
        queue.sync {
            remoteDaysByDevice = shards
        }
    }

    private func mergedDayLocked(forKey key: String) -> DailyKeyStatsRecord? {
        var acc = days[key]
        for deviceDays in remoteDaysByDevice.values {
            if let remoteDay = deviceDays[key] {
                acc = Self.mergeDay(existing: acc, incoming: remoteDay)
            }
        }
        return acc
    }

    private func allKnownDayKeysLocked() -> [String] {
        var keys = Set(days.keys)
        for deviceDays in remoteDaysByDevice.values {
            keys.formUnion(deviceDays.keys)
        }
        return Array(keys)
    }

    // MARK: - Queries & Aggregation

    public func todayMenuBarCounts() -> (keys: Int, clicks: Int) {
        let (todayKey, _) = Self.dayKeyAndHour(for: nowProvider())
        return queue.sync {
            guard let rec = mergedDayLocked(forKey: todayKey) else { return (0, 0) }
            return (rec.keyPresses, rec.totalClicks)
        }
    }

    public func snapshot(for range: StatsTimeRange) -> KeyStatsAggregateSnapshot {
        let nowDate = nowProvider()
        return queue.sync {
            let includedKeys = filteredDayKeysLocked(for: range, referenceDate: nowDate)

            var totalKeys = 0
            var leftClicks = 0
            var rightClicks = 0
            var otherClicks = 0
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
                guard let day = mergedDayLocked(forKey: key) else { continue }
                if day.keyPresses > 0 || day.totalClicks > 0 {
                    activeDays += 1
                }
                if day.keyPresses > maxDailyKeys {
                    maxDailyKeys = day.keyPresses
                }
                totalKeys += day.keyPresses
                leftClicks += day.leftClicks
                rightClicks += day.rightClicks
                otherClicks += day.middleClicks + day.sideBackClicks + day.sideForwardClicks
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
                    mergedApps[bid] = agg
                }
            }

            let topShortcutItems = shortcuts
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(8)
                .map { RankedCountItem(label: $0.key, count: $0.value) }

            let topKeyItems = heatmap
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(8)
                .map { RankedCountItem(label: KeyCodeMapper.prettyKeyLabel($0.key), count: $0.value) }

            let topAppItems = mergedApps.values
                .filter { $0.keyPresses > 0 || $0.totalClicks > 0 || $0.scrollDistancePx > 0 }
                .sorted {
                    let lScore = $0.keyPresses + $0.totalClicks
                    let rScore = $1.keyPresses + $1.totalClicks
                    if lScore != rScore { return lScore > rScore }
                    return $0.displayName < $1.displayName
                }
                .prefix(12)
                .map {
                    AppActivitySummary(
                        bundleID: $0.bundleID,
                        displayName: $0.displayName,
                        keyPresses: $0.keyPresses,
                        clicks: $0.totalClicks,
                        scrollMeters: $0.scrollDistancePx * KeyStatsAggregateSnapshot.metersPerPixel,
                        charactersSaved: $0.charactersSaved
                    )
                }

            // Build 14-week (98-day) chronological calendar heatmap ending today
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: nowDate)
            var calDays: [CalendarActivityDay] = []
            calDays.reserveCapacity(98)
            for offset in stride(from: -97, through: 0, by: 1) {
                if let d = calendar.date(byAdding: .day, value: offset, to: startOfToday) {
                    let (k, _) = Self.dayKeyAndHour(for: d)
                    let rec = mergedDayLocked(forKey: k)
                    calDays.append(CalendarActivityDay(
                        dateKey: k,
                        keyPresses: rec?.keyPresses ?? 0,
                        clicks: rec?.totalClicks ?? 0
                    ))
                }
            }

            return KeyStatsAggregateSnapshot(
                range: range,
                totalKeyPresses: totalKeys,
                totalClicks: leftClicks + rightClicks + otherClicks,
                leftClicks: leftClicks,
                rightClicks: rightClicks,
                otherClicks: otherClicks,
                mouseDistanceMeters: mousePx * KeyStatsAggregateSnapshot.metersPerPixel,
                scrollDistanceMeters: scrollPx * KeyStatsAggregateSnapshot.metersPerPixel,
                peakKPS: peakKPS,
                peakCPS: peakCPS,
                backspacePresses: backspaces,
                leftHandPresses: leftHand,
                rightHandPresses: rightHand,
                romanKeyPresses: romanKeys,
                nonRomanKeyPresses: nonRomanKeys,
                activeDays: activeDays,
                maxDailyKeys: maxDailyKeys,
                keyHeatmap: heatmap,
                topShortcuts: Array(topShortcutItems),
                topKeys: Array(topKeyItems),
                topApps: Array(topAppItems),
                hourlyKeys: hourlyKeys,
                hourlyClicks: hourlyClicks,
                calendarDays: calDays
            )
        }
    }

    // MARK: - Export / Import / Reset

    public func exportJSONData() throws -> Data {
        try queue.sync {
            let archive = NativeExportArchive(
                schema: "app.wordtail.keystats",
                version: 1,
                exportedAt: nowProvider(),
                days: days
            )
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
                if !merge { days.removeAll() }
                for (dayKey, incoming) in native.days {
                    days[dayKey] = merge ? Self.mergeDay(existing: days[dayKey], incoming: incoming) : incoming
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
                            importedMap[normalizedKey] = Self.convertExternalDay(extDay, dateKey: normalizedKey)
                        }
                    }
                    if let cur = ext.currentStats {
                        let curKey = Self.normalizeExternalDayKey("", fallbackDate: cur.date ?? nowProvider())
                        if importedMap[curKey] == nil {
                            importedMap[curKey] = Self.convertExternalDay(cur, dateKey: curKey)
                        }
                    }
                    for (k, incoming) in importedMap {
                        days[k] = merge ? Self.mergeDay(existing: days[k], incoming: incoming) : incoming
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
            modifierTracker.reset()
            lastMousePoint = nil
            recentKeyTimestamps.removeAll()
            recentClickTimestamps.removeAll()
            isDirty = false
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Private Helpers

    private func filteredDayKeysLocked(for range: StatsTimeRange, referenceDate: Date) -> [String] {
        switch range {
        case .today:
            let (todayKey, _) = Self.dayKeyAndHour(for: referenceDate)
            return [todayKey]
        case .days7:
            return Self.recentDayKeys(count: 7, referenceDate: referenceDate)
        case .days30:
            return Self.recentDayKeys(count: 30, referenceDate: referenceDate)
        case .allTime:
            return allKnownDayKeysLocked()
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

    private func flushSynchronouslyLocked(nowTs: TimeInterval? = nil) {
        lastDiskFlushTime = nowTs ?? nowProvider().timeIntervalSince1970
        isDirty = false
        let archive = NativeExportArchive(
            schema: "app.wordtail.keystats",
            version: 1,
            exportedAt: nowProvider(),
            days: days
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(archive) {
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func dayKeyAndHour(for date: Date) -> (String, Int) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
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

        if let rawKeyMap = ext.keyPressCounts {
            for (rawCombo, count) in rawKeyMap where count > 0 {
                let parts = rawCombo.split(separator: "+").map(String.init)
                for p in parts {
                    let norm = normalizeExternalKeyID(p)
                    rec.keyHeatmapCounts[norm, default: 0] += count
                    if norm == "Delete" || norm == "ForwardDelete" {
                        rec.backspacePresses += count
                    }
                    switch KeyCodeMapper.hand(forKeyID: norm) {
                    case .left: rec.leftHandPresses += count
                    case .right: rec.rightHandPresses += count
                    case .neutral: break
                    }
                }
                if parts.count >= 2, let base = parts.last {
                    let hasCmd = parts.contains { $0.contains("Cmd") }
                    let hasOpt = parts.contains { $0.contains("Option") }
                    let hasCtrl = parts.contains { $0 == "Ctrl" }
                    let hasShift = parts.contains { $0.contains("Shift") }
                    if hasCmd || hasOpt || hasCtrl {
                        var s = ""
                        if hasCtrl { s += "⌃" }
                        if hasOpt { s += "⌥" }
                        if hasShift { s += "⇧" }
                        if hasCmd { s += "⌘" }
                        s += KeyCodeMapper.prettyKeyLabel(normalizeExternalKeyID(base))
                        rec.shortcutCounts[s, default: 0] += count
                    }
                }
            }
        }

        if let extApps = ext.appStats {
            for (bid, a) in extApps {
                let cleanID = a.bundleId ?? bid
                rec.appStats[cleanID] = AppActivityRecord(
                    bundleID: cleanID,
                    displayName: a.displayName ?? cleanID,
                    keyPresses: a.keyPresses ?? 0,
                    leftClicks: a.leftClicks ?? 0,
                    rightClicks: a.rightClicks ?? 0,
                    otherClicks: (a.sideBackClicks ?? 0) + (a.sideForwardClicks ?? 0) + (a.otherClicks ?? 0),
                    scrollDistancePx: a.scrollDistance ?? 0
                )
            }
        }
        return rec
    }

    private static func normalizeExternalKeyID(_ raw: String) -> String {
        switch raw {
        case "Cmd": return "LeftCmd"
        case "Shift": return "LeftShift"
        case "Option": return "LeftOption"
        case "Backspace": return "Delete"
        default: return raw
        }
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
            acc.appStats[bid] = cur
        }
        return acc
    }
}
