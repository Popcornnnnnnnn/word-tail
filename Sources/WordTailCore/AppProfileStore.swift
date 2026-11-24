import Foundation

public enum AppProfilePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case casualChat
    case formalDocs
    case engineeringChat
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .casualChat: return "Casual Chat"
        case .formalDocs: return "Formal Docs"
        case .engineeringChat: return "Engineering Chat"
        case .custom: return "Custom"
        }
    }

    public static func recommended(forBundleID bundleID: String) -> Self? {
        switch bundleID.lowercased() {
        case "com.tencent.xinwechat", "com.tinyspeck.slackmacgap": return .casualChat
        case "com.apple.mail", "notion.id": return .formalDocs
        case "com.openai.codex", "com.todesktop.230313mzl4w4u92": return .engineeringChat
        default: return nil
        }
    }
}

public struct AppWritingProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: String { bundleID }
    public var bundleID: String
    public var displayName: String
    public var preset: AppProfilePreset
    public var autoCapitalizeSentences: Bool?
    public var autoCorrectOnSpace: Bool?
    public var enablePhrasePrediction: Bool?
    public var bilingualSpacingOverride: Bool?
    public var enabledDomainPackIDs: [String]?
    public var updatedAt: TimeInterval
    public var isDeleted: Bool

    public init(
        bundleID: String,
        displayName: String,
        preset: AppProfilePreset = .custom,
        autoCapitalizeSentences: Bool? = nil,
        autoCorrectOnSpace: Bool? = nil,
        enablePhrasePrediction: Bool? = nil,
        bilingualSpacingOverride: Bool? = nil,
        enabledDomainPackIDs: [String]? = nil,
        updatedAt: TimeInterval = 0,
        isDeleted: Bool = false
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.preset = preset
        self.autoCapitalizeSentences = autoCapitalizeSentences
        self.autoCorrectOnSpace = autoCorrectOnSpace
        self.enablePhrasePrediction = enablePhrasePrediction
        self.bilingualSpacingOverride = bilingualSpacingOverride
        self.enabledDomainPackIDs = enabledDomainPackIDs
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }

    public static func starter(forBundleID bundleID: String, displayName: String) -> Self? {
        guard let preset = AppProfilePreset.recommended(forBundleID: bundleID) else { return nil }
        var profile = Self(bundleID: bundleID, displayName: displayName)
        profile.apply(preset)
        return profile
    }

    fileprivate mutating func apply(_ preset: AppProfilePreset) {
        self.preset = preset
        switch preset {
        case .casualChat:
            autoCapitalizeSentences = false
            autoCorrectOnSpace = false
            enablePhrasePrediction = true
            bilingualSpacingOverride = true
            enabledDomainPackIDs = nil
        case .formalDocs:
            autoCapitalizeSentences = true
            autoCorrectOnSpace = true
            enablePhrasePrediction = true
            bilingualSpacingOverride = nil
            enabledDomainPackIDs = nil
        case .engineeringChat:
            autoCapitalizeSentences = false
            autoCorrectOnSpace = false
            enablePhrasePrediction = false
            bilingualSpacingOverride = nil
            enabledDomainPackIDs = ["systems_cloud", "ai_quant"]
        case .custom:
            break
        }
    }
}

public final class AppProfileStore {
    public struct SyncShard: Codable, Equatable, Sendable {
        public var profiles: [String: AppWritingProfile]

        public init(profiles: [String: AppWritingProfile] = [:]) {
            self.profiles = profiles
        }
    }

    private let queue = DispatchQueue(label: "app.wordtail.macos.app-profiles")
    private let directoryURL: URL
    private let fileURL: URL
    private var records: [String: AppWritingProfile]

    public init(directoryURL: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = directoryURL ?? appSupport.appendingPathComponent("WordTail", isDirectory: true)
        self.directoryURL = directory
        fileURL = directory.appendingPathComponent("app_profiles.json")
        records = (try? JSONDecoder().decode([String: AppWritingProfile].self, from: Data(contentsOf: fileURL))) ?? [:]
    }

    public var profiles: [AppWritingProfile] {
        queue.sync { records.values.filter { !$0.isDeleted }.sorted { $0.bundleID < $1.bundleID } }
    }

    public func profile(forBundleID bundleID: String) -> AppWritingProfile? {
        queue.sync {
            guard let profile = records[bundleID], !profile.isDeleted else { return nil }
            return profile
        }
    }

    @discardableResult
    public func upsert(_ profile: AppWritingProfile) -> Bool {
        queue.sync { saveLocal(profile) }
    }

    @discardableResult
    public func delete(bundleID: String) -> Bool {
        queue.sync {
            var profile = records[bundleID] ?? AppWritingProfile(bundleID: bundleID, displayName: bundleID)
            guard !profile.isDeleted else { return true }
            profile.isDeleted = true
            return saveLocal(profile)
        }
    }

    @discardableResult
    public func applyPreset(_ preset: AppProfilePreset, toBundleID bundleID: String, displayName: String) -> Bool {
        queue.sync {
            var profile = records[bundleID] ?? AppWritingProfile(bundleID: bundleID, displayName: displayName)
            profile.displayName = displayName
            profile.isDeleted = false
            profile.apply(preset)
            return saveLocal(profile)
        }
    }

    public func exportLocalShard() -> SyncShard {
        queue.sync { SyncShard(profiles: records) }
    }

    @discardableResult
    public func applyRemoteShards(_ shards: [String: SyncShard]) -> Bool {
        queue.sync {
            var next = records
            for shard in shards.values {
                for (bundleID, profile) in shard.profiles {
                    guard !bundleID.isEmpty, profile.bundleID == bundleID, profile.updatedAt.isFinite else { continue }
                    if let existing = next[bundleID], !Self.isNewer(profile, than: existing) { continue }
                    next[bundleID] = profile
                }
            }
            return next == records || save(next)
        }
    }

    private static func isNewer(_ incoming: AppWritingProfile, than existing: AppWritingProfile) -> Bool {
        if incoming.updatedAt != existing.updatedAt { return incoming.updatedAt > existing.updatedAt }
        if incoming.isDeleted != existing.isDeleted { return incoming.isDeleted }
        guard incoming != existing else { return false }
        // Break clock ties consistently regardless of peer arrival order.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let left = try? encoder.encode(existing), let right = try? encoder.encode(incoming) else { return false }
        return left.lexicographicallyPrecedes(right)
    }

    private func saveLocal(_ profile: AppWritingProfile) -> Bool {
        guard !profile.bundleID.isEmpty else { return false }
        var updated = profile
        let previous = records[profile.bundleID]?.updatedAt ?? 0
        updated.updatedAt = max(Date().timeIntervalSince1970, previous.nextUp)
        var next = records
        next[updated.bundleID] = updated
        return save(next)
    }

    private func save(_ next: [String: AppWritingProfile]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
            records = next
            return true
        } catch {
            return false
        }
    }
}
