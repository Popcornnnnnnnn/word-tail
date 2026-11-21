import Foundation
import Darwin

public struct DeviceSyncEnvelope: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var deviceID: String
    public var deviceModel: String
    public var legacyKeyStatsDeviceID: String?
    public var updatedAt: Date
    public var history: UserHistoryStore.SyncShard
    public var corrections: AdaptiveCorrectionStore.SyncShard
    public var phrases: PhrasePredictor.SyncShard
    public var insights: TypingHabitTracker.SyncShard
    public var keyStatsDays: [String: DailyKeyStatsRecord]

    public init(
        schemaVersion: Int = 1,
        deviceID: String,
        deviceModel: String,
        legacyKeyStatsDeviceID: String? = nil,
        updatedAt: Date = Date(),
        history: UserHistoryStore.SyncShard,
        corrections: AdaptiveCorrectionStore.SyncShard,
        phrases: PhrasePredictor.SyncShard,
        insights: TypingHabitTracker.SyncShard,
        keyStatsDays: [String: DailyKeyStatsRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.deviceModel = deviceModel
        self.legacyKeyStatsDeviceID = legacyKeyStatsDeviceID
        self.updatedAt = updatedAt
        self.history = history
        self.corrections = corrections
        self.phrases = phrases
        self.insights = insights
        self.keyStatsDays = keyStatsDays
    }
}

public struct SyncPeerSummary: Identifiable, Equatable, Sendable {
    public var id: String { deviceID }
    public let deviceID: String
    public let deviceModel: String
    public let updatedAt: Date

    public init(deviceID: String, deviceModel: String, updatedAt: Date) {
        self.deviceID = deviceID
        self.deviceModel = deviceModel
        self.updatedAt = updatedAt
    }
}

public struct SyncStatusSnapshot: Equatable, Sendable {
    public let isEnabled: Bool
    public let folderPath: String?
    public let isICloudDrive: Bool
    public let deviceID: String
    public let peers: [SyncPeerSummary]
    public let lastSyncedAt: Date?
    public let lastError: String?

    public var syncedPeerCount: Int { peers.count }

    public init(
        isEnabled: Bool,
        folderPath: String?,
        isICloudDrive: Bool,
        deviceID: String,
        peers: [SyncPeerSummary],
        lastSyncedAt: Date?,
        lastError: String?
    ) {
        self.isEnabled = isEnabled
        self.folderPath = folderPath
        self.isICloudDrive = isICloudDrive
        self.deviceID = deviceID
        self.peers = peers
        self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError
    }
}

/// Conflict-free multi-device sync coordinator using per-device JSON shards in iCloud Drive or any synced folder.
///
/// Each Mac writes ONLY its own local delta shard (`devices/<deviceID>.json`), while merging all peer shards
/// in memory and applying Last-Write-Wins tombstones for custom words, rules, mutes, and phrases.
/// Per-app display calibration offsets stay strictly local to each Mac.
public final class SyncEngine {
    public static let enabledDefaultsKey = "WordTailSyncEnabled"
    public static let folderPathDefaultsKey = "WordTailSyncFolderPath"
    public static let deviceIDDefaultsKey = "WordTailSyncDeviceID"

    private struct PeerCache: Codable {
        let folderPath: String
        let envelopes: [String: DeviceSyncEnvelope]
    }

    private let historyStore: UserHistoryStore
    private let adaptiveStore: AdaptiveCorrectionStore
    private let phrasePredictor: PhrasePredictor
    private let habitTracker: TypingHabitTracker
    private let keyStatsStore: KeyStatsStore
    private let defaults: UserDefaults
    private let localCacheURL: URL
    private let queue = DispatchQueue(label: "app.wordtail.macos.sync", qos: .utility)

    public let deviceID: String
    public let deviceModel: String

    private var isEnabledFlag: Bool
    private var folderPathValue: String?
    private var lastSyncedAtValue: Date?
    private var lastErrorValue: String?
    private var knownPeers: [SyncPeerSummary] = []

    public init(
        historyStore: UserHistoryStore,
        adaptiveStore: AdaptiveCorrectionStore,
        phrasePredictor: PhrasePredictor,
        habitTracker: TypingHabitTracker,
        keyStatsStore: KeyStatsStore,
        defaults: UserDefaults = .standard,
        overrideDeviceID: String? = nil,
        localCacheURL: URL? = nil
    ) {
        self.historyStore = historyStore
        self.adaptiveStore = adaptiveStore
        self.phrasePredictor = phrasePredictor
        self.habitTracker = habitTracker
        self.keyStatsStore = keyStatsStore
        self.defaults = defaults
        self.deviceModel = Self.hardwareModelIdentifier()

        if let overrideDeviceID {
            self.deviceID = overrideDeviceID
        } else if let saved = defaults.string(forKey: Self.deviceIDDefaultsKey), !saved.isEmpty {
            self.deviceID = saved
        } else {
            let fresh = UUID().uuidString.lowercased()
            defaults.set(fresh, forKey: Self.deviceIDDefaultsKey)
            self.deviceID = fresh
        }

        if let localCacheURL {
            self.localCacheURL = localCacheURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("WordTail", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.localCacheURL = dir.appendingPathComponent("remote_sync_cache.json")
        }

        self.isEnabledFlag = defaults.bool(forKey: Self.enabledDefaultsKey)
        self.folderPathValue = defaults.string(forKey: Self.folderPathDefaultsKey)

        if isEnabledFlag, let folderPathValue {
            loadCachedPeersSynchronously(for: folderPathValue)
        }
    }

    /// Returns `~/Library/Mobile Documents/com~apple~CloudDocs/WordTail` if iCloud Drive is signed in on this Mac.
    public static func defaultICloudDriveFolderURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloudDocs = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cloudDocs.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return cloudDocs.appendingPathComponent("WordTail", isDirectory: true)
    }

    public static func isICloudDrivePath(_ path: String?) -> Bool {
        guard let path else { return false }
        return path.contains("/Mobile Documents/com~apple~CloudDocs")
    }

    public func statusSnapshot() -> SyncStatusSnapshot {
        queue.sync {
            makeStatusLocked()
        }
    }

    /// Enables sync with iCloud Drive (if available) or a custom folder URL, and runs an immediate sync pass.
    @discardableResult
    public func enableSync(folderURL: URL) -> SyncStatusSnapshot {
        let standardized = folderURL.standardizedFileURL.path
        return queue.sync {
            if standardized != folderPathValue {
                knownPeers = []
                lastSyncedAtValue = nil
                applyPeerEnvelopes([:])
            }
            folderPathValue = standardized
            isEnabledFlag = true
            lastErrorValue = nil
            defaults.set(standardized, forKey: Self.folderPathDefaultsKey)
            defaults.set(true, forKey: Self.enabledDefaultsKey)
            return performSyncLocked()
        }
    }

    /// Disables multi-device sync and detaches remote peer shards while keeping all local typing data intact.
    @discardableResult
    public func disableSync() -> SyncStatusSnapshot {
        queue.sync {
            isEnabledFlag = false
            lastErrorValue = nil
            knownPeers = []
            defaults.set(false, forKey: Self.enabledDefaultsKey)
            applyPeerEnvelopes([:])
            try? FileManager.default.removeItem(at: localCacheURL)
            return makeStatusLocked()
        }
    }

    /// Runs a synchronous sync cycle on `SyncEngine`'s background queue (safe to call from background or termination).
    @discardableResult
    public func syncNow() -> SyncStatusSnapshot {
        queue.sync {
            guard isEnabledFlag else { return makeStatusLocked() }
            return performSyncLocked()
        }
    }

    /// Runs an asynchronous sync cycle and invokes `completion` on the main queue.
    public func syncAsync(completion: (@Sendable (SyncStatusSnapshot) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let snap: SyncStatusSnapshot
            if self.isEnabledFlag {
                snap = self.performSyncLocked()
            } else {
                snap = self.makeStatusLocked()
            }
            if let completion {
                DispatchQueue.main.async {
                    completion(snap)
                }
            }
        }
    }

    // MARK: - Core Sync Cycle

    private func performSyncLocked() -> SyncStatusSnapshot {
        guard let rawPath = folderPathValue, !rawPath.isEmpty else {
            lastErrorValue = "Choose a sync folder or enable iCloud Drive first."
            return makeStatusLocked()
        }

        let rootURL = URL(fileURLWithPath: rawPath, isDirectory: true)
        let devicesDir = rootURL.appendingPathComponent("devices", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: devicesDir, withIntermediateDirectories: true)
        } catch {
            lastErrorValue = "Cannot access sync folder: \(error.localizedDescription)"
            return makeStatusLocked()
        }

        // 1. Flush pending in-memory KeyStats before exporting/merging
        keyStatsStore.flushNow()

        // 2. Discover peer device files & trigger download of any evicted `.icloud` placeholders
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: devicesDir,
            includingPropertiesForKeys: [.isRegularFileKey, .ubiquitousItemDownloadingStatusKey],
            options: []
        )) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var remoteEnvelopes = loadCachedEnvelopeMapLocked(for: rawPath)

        for itemURL in entries {
            let fileName = itemURL.lastPathComponent
            // Trigger background hydration for evicted iCloud Drive files (e.g. `.<uuid>.json.icloud`)
            if fileName.hasPrefix(".") && fileName.hasSuffix(".icloud") {
                try? FileManager.default.startDownloadingUbiquitousItem(at: itemURL)
                continue
            }
            guard itemURL.pathExtension.lowercased() == "json" else { continue }
            let stem = itemURL.deletingPathExtension().lastPathComponent
            guard stem != deviceID else { continue }

            // Request hydration if iCloud Drive marks it not-yet-downloaded
            try? FileManager.default.startDownloadingUbiquitousItem(at: itemURL)

            if let data = readCoordinatedData(at: itemURL),
               let env = try? decoder.decode(DeviceSyncEnvelope.self, from: data),
               env.deviceID != deviceID {
                remoteEnvelopes[env.deviceID] = env
            }
        }

        // 3. Apply all remote peer shards (merges additive stats + reconciles LWW custom words/rules/phrases)
        applyPeerEnvelopes(remoteEnvelopes)
        saveCachedEnvelopeMapLocked(remoteEnvelopes, for: rawPath)

        // 4. Export THIS Mac's local shard (including reconciled LWW custom rule/word/phrase metadata)
        let now = Date()
        let localEnvelope = DeviceSyncEnvelope(
            schemaVersion: 1,
            deviceID: deviceID,
            deviceModel: deviceModel,
            legacyKeyStatsDeviceID: keyStatsStore.localLegacyKeyStatsDeviceID(),
            updatedAt: now,
            history: historyStore.exportLocalShard(),
            corrections: adaptiveStore.exportLocalShard(),
            phrases: phrasePredictor.exportLocalShard(),
            insights: habitTracker.exportLocalShard(),
            keyStatsDays: keyStatsStore.exportLocalDaysShard()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let myFileURL = devicesDir.appendingPathComponent("\(deviceID).json")

        do {
            let encoded = try encoder.encode(localEnvelope)
            try writeCoordinatedData(encoded, to: myFileURL)
            lastSyncedAtValue = now
            lastErrorValue = nil
        } catch {
            lastErrorValue = "Failed writing sync shard: \(error.localizedDescription)"
        }

        knownPeers = remoteEnvelopes.values
            .map { SyncPeerSummary(deviceID: $0.deviceID, deviceModel: $0.deviceModel, updatedAt: $0.updatedAt) }
            .sorted { $0.updatedAt > $1.updatedAt }

        return makeStatusLocked()
    }

    private func applyPeerEnvelopes(_ envelopes: [String: DeviceSyncEnvelope]) {
        var historyShards: [String: UserHistoryStore.SyncShard] = [:]
        var correctionShards: [String: AdaptiveCorrectionStore.SyncShard] = [:]
        var phraseShards: [String: PhrasePredictor.SyncShard] = [:]
        var insightShards: [String: TypingHabitTracker.SyncShard] = [:]
        var keyStatsShards: [String: [String: DailyKeyStatsRecord]] = [:]
        var claimedLegacyIDs = Set<String>()

        for (peerID, env) in envelopes where peerID != deviceID {
            historyShards[peerID] = env.history
            correctionShards[peerID] = env.corrections
            phraseShards[peerID] = env.phrases
            insightShards[peerID] = env.insights
            keyStatsShards[peerID] = env.keyStatsDays
            if let legacyID = env.legacyKeyStatsDeviceID, !legacyID.isEmpty {
                claimedLegacyIDs.insert(legacyID)
            }
        }

        historyStore.applyRemoteShards(historyShards)
        adaptiveStore.applyRemoteShards(correctionShards)
        phrasePredictor.applyRemoteShards(phraseShards)
        habitTracker.applyRemoteShards(insightShards)
        keyStatsStore.applyRemoteDeviceDays(keyStatsShards, claimedLegacyDeviceIDs: claimedLegacyIDs)
    }

    // MARK: - File Coordination & Local Cache

    private func readCoordinatedData(at url: URL) -> Data? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var result: Data?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { readURL in
            result = try? Data(contentsOf: readURL)
        }
        if result == nil, coordError != nil {
            result = try? Data(contentsOf: url)
        }
        return result
    }

    private func writeCoordinatedData(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let writeError { throw writeError }
        if let coordError { throw coordError }
    }

    private func loadCachedPeersSynchronously(for folderPath: String) {
        let cached = loadCachedEnvelopeMapLocked(for: folderPath)
        guard !cached.isEmpty else { return }
        applyPeerEnvelopes(cached)
        knownPeers = cached.values
            .map { SyncPeerSummary(deviceID: $0.deviceID, deviceModel: $0.deviceModel, updatedAt: $0.updatedAt) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func loadCachedEnvelopeMapLocked(for folderPath: String) -> [String: DeviceSyncEnvelope] {
        guard let data = try? Data(contentsOf: localCacheURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Older caches did not record their source folder. Rebuild them from the selected folder.
        guard let cache = try? decoder.decode(PeerCache.self, from: data),
              cache.folderPath == folderPath else {
            return [:]
        }
        return cache.envelopes
    }

    private func saveCachedEnvelopeMapLocked(_ map: [String: DeviceSyncEnvelope], for folderPath: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let cache = PeerCache(folderPath: folderPath, envelopes: map)
        if let data = try? encoder.encode(cache) {
            try? data.write(to: localCacheURL, options: .atomic)
        }
    }

    private func makeStatusLocked() -> SyncStatusSnapshot {
        SyncStatusSnapshot(
            isEnabled: isEnabledFlag,
            folderPath: folderPathValue,
            isICloudDrive: Self.isICloudDrivePath(folderPathValue),
            deviceID: deviceID,
            peers: knownPeers,
            lastSyncedAt: lastSyncedAtValue,
            lastError: lastErrorValue
        )
    }

    private static func hardwareModelIdentifier() -> String {
        var size: Int = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            return "Mac"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return "Mac"
        }
        return String(cString: buffer)
    }
}

public enum VersionComparator {
    /// Normalizes a tag/version string like `"v0.6.1"` -> `"0.6.1"`.
    public static func normalizedVersionString(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        if let dashIdx = trimmed.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            trimmed = String(trimmed[..<dashIdx])
        }
        return trimmed
    }

    /// Returns `true` strictly when `remote` has a higher semantic version than `current`.
    public static func isNewer(remote rawRemote: String, current rawCurrent: String) -> Bool {
        let remoteParts = parseComponents(rawRemote)
        let currentParts = parseComponents(rawCurrent)
        guard !remoteParts.isEmpty else { return false }
        let count = max(remoteParts.count, currentParts.count)
        for idx in 0..<count {
            let r = idx < remoteParts.count ? remoteParts[idx] : 0
            let c = idx < currentParts.count ? currentParts[idx] : 0
            if r != c {
                return r > c
            }
        }
        return false
    }

    private static func parseComponents(_ raw: String) -> [Int] {
        let clean = normalizedVersionString(raw)
        let parts = clean.split(separator: ".")
        var nums: [Int] = []
        for p in parts {
            guard let val = Int(p) else { return [] }
            nums.append(val)
        }
        return nums
    }
}

