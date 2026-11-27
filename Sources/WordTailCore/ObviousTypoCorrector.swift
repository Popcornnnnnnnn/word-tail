import AppKit
import Foundation

public struct MinimalDiffEdit: Equatable, Sendable {
    public let deleteCount: Int
    public let insertText: String

    public init(deleteCount: Int, insertText: String) {
        self.deleteCount = deleteCount
        self.insertText = insertText
    }
}

public struct SpaceTransformResult: Equatable, Sendable {
    public let replacedSourceSpan: String
    public let replacementText: String

    public init(replacedSourceSpan: String, replacementText: String) {
        self.replacedSourceSpan = replacedSourceSpan
        self.replacementText = replacementText
    }
}

public enum CorrectionRuleSource: String, Codable, Equatable, Sendable {
    case custom = "Custom"
    case learned = "Learned"
    case muted = "Muted"
}

public struct CorrectionRuleEntry: Identifiable, Equatable, Sendable {
    public var id: String { "\(source.rawValue):\(trigger)" }
    public let trigger: String
    public let replacement: String
    public let count: Int
    public let source: CorrectionRuleSource

    public init(trigger: String, replacement: String, count: Int, source: CorrectionRuleSource) {
        self.trigger = trigger
        self.replacement = replacement
        self.count = count
        self.source = source
    }
}

/// Persistent, self-learning store for user shorthand rules, auto-learned typo pairs, and undo-muted triggers.
public final class AdaptiveCorrectionStore {
    public struct RuleSyncRecord: Codable, Equatable, Sendable {
        public var replacement: String?
        public var isMuted: Bool
        public var isDeleted: Bool
        public var updatedAt: TimeInterval

        public init(replacement: String?, isMuted: Bool, isDeleted: Bool, updatedAt: TimeInterval) {
            self.replacement = replacement
            self.isMuted = isMuted
            self.isDeleted = isDeleted
            self.updatedAt = updatedAt
        }
    }

    public struct SyncShard: Codable, Equatable, Sendable {
        public var syncRecords: [String: RuleSyncRecord] = [:]
        public var candidatePairs: [String: [String: Int]] = [:]
        public var undoCounts: [String: Int] = [:]

        public init() {}
    }

    private struct PersistedData: Codable {
        var customRules: [String: String] = [:]          // user-defined trigger -> replacement
        var candidatePairs: [String: [String: Int]] = [:] // observed mistype -> target -> count (graduates at >= 2)
        var undoCounts: [String: Int] = [:]               // trigger -> number of Backspace undos (mutes at >= 2)
        var mutedTriggers: Set<String> = []
        var syncRecords: [String: RuleSyncRecord]? = [:]
    }

    public static let graduationThreshold = 2
    public static let muteUndoThreshold = 2

    private let fileURL: URL
    private let queue = DispatchQueue(label: "app.wordtail.macos.corrections", qos: .utility)
    private var state = PersistedData()
    private var remoteShards: [String: SyncShard] = [:]

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("WordTail", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("adaptive_corrections.json")
        }
        loadSynchronously()
    }

    private func loadSynchronously() {
        guard let data = try? Data(contentsOf: fileURL),
              var decoded = try? JSONDecoder().decode(PersistedData.self, from: data) else {
            return
        }
        var records = decoded.syncRecords ?? [:]
        for (trig, rep) in decoded.customRules where records[trig] == nil {
            records[trig] = RuleSyncRecord(replacement: rep, isMuted: false, isDeleted: false, updatedAt: 1)
        }
        for muted in decoded.mutedTriggers where records[muted] == nil {
            records[muted] = RuleSyncRecord(replacement: nil, isMuted: true, isDeleted: false, updatedAt: 1)
        }
        decoded.syncRecords = records
        state = decoded
        if sanitizeLegacyFalseMutesAndPairsLocked() {
            persistLocked()
        }
    }

    /// Cleans up legacy false-positive mutes on normal English sentence-starter words (like `"can"`, `"what"`, `"that"`, `"i"`, `"git is"`)
    /// that accumulated when a user pressed Backspace after sentence-start capitalization, plus accidental fragment pairs shadowing `unambiguousTypos`.
    private func sanitizeLegacyFalseMutesAndPairsLocked() -> Bool {
        var dirty = false
        var records = state.syncRecords ?? [:]
        let now = Date().timeIntervalSince1970

        for (mistype, targetMap) in state.candidatePairs {
            let cleanedTargets = targetMap.filter { target, _ in
                !Self.isOverBackspacedFragment(mistype: mistype, corrected: target)
            }
            if cleanedTargets.count != targetMap.count {
                if cleanedTargets.isEmpty {
                    state.candidatePairs.removeValue(forKey: mistype)
                    // If `mistype` was muted solely because this bogus over-backspaced fragment (e.g. "wnat" -> "ant") fired, unmute it!
                    if state.mutedTriggers.contains(mistype) && state.customRules[mistype] == nil {
                        state.mutedTriggers.remove(mistype)
                        state.undoCounts.removeValue(forKey: mistype)
                        records[mistype] = RuleSyncRecord(replacement: nil, isMuted: false, isDeleted: true, updatedAt: now)
                    }
                } else {
                    state.candidatePairs[mistype] = cleanedTargets
                }
                dirty = true
            }
        }

        let allUndoOrMutedKeys = Set(state.undoCounts.keys).union(state.mutedTriggers)
        for key in allUndoOrMutedKeys {
            guard state.customRules[key] == nil,
                  ObviousTypoCorrector.unambiguousTypos[key] == nil,
                  ObviousTypoCorrector.canonicalBrandCasing[key] == nil,
                  state.candidatePairs[key] == nil else {
                continue
            }
            let isPlainSentenceWord = key == "i"
                || key.contains(" ")
                || TypingHabitTracker.defaultValidEnglishWordCheck(key)
            if isPlainSentenceWord {
                let wasMuted = state.mutedTriggers.remove(key) != nil
                state.undoCounts.removeValue(forKey: key)
                if wasMuted {
                    records[key] = RuleSyncRecord(replacement: nil, isMuted: false, isDeleted: true, updatedAt: now)
                }
                dirty = true
            }
        }

        if dirty {
            state.syncRecords = records
        }
        return dirty
    }

    public func exportLocalShard() -> SyncShard {
        queue.sync {
            var shard = SyncShard()
            shard.syncRecords = state.syncRecords ?? [:]
            shard.candidatePairs = state.candidatePairs
            shard.undoCounts = state.undoCounts
            return shard
        }
    }

    public func applyRemoteShards(_ shards: [String: SyncShard]) {
        queue.sync {
            remoteShards = shards
            var records = state.syncRecords ?? [:]
            var changed = false

            for shard in shards.values {
                for (rawKey, remoteRec) in shard.syncRecords {
                    let key = rawKey.lowercased()
                    let localUpdated = records[key]?.updatedAt ?? 0
                    if remoteRec.updatedAt > localUpdated {
                        records[key] = remoteRec
                        if remoteRec.isDeleted {
                            state.customRules.removeValue(forKey: key)
                            state.mutedTriggers.remove(key)
                            state.undoCounts.removeValue(forKey: key)
                            state.candidatePairs.removeValue(forKey: key)
                        } else if remoteRec.isMuted {
                            state.customRules.removeValue(forKey: key)
                            state.mutedTriggers.insert(key)
                        } else if let rep = remoteRec.replacement {
                            state.mutedTriggers.remove(key)
                            state.undoCounts.removeValue(forKey: key)
                            state.customRules[key] = rep
                        }
                        changed = true
                    }
                }
            }

            if changed {
                state.syncRecords = records
                persistLocked()
            }
        }
    }

    private func mergedCandidatePairsLocked() -> [String: [String: Int]] {
        guard !remoteShards.isEmpty else { return state.candidatePairs }
        let records = state.syncRecords ?? [:]
        var merged = state.candidatePairs
        for shard in remoteShards.values {
            for (mistype, targetMap) in shard.candidatePairs {
                if records[mistype]?.isDeleted == true && state.candidatePairs[mistype] == nil {
                    continue
                }
                var cur = merged[mistype] ?? [:]
                for (target, c) in targetMap {
                    cur[target, default: 0] += c
                }
                merged[mistype] = cur
            }
        }
        return merged
    }

    private func isMutedLocked(_ key: String) -> Bool {
        if state.mutedTriggers.contains(key) { return true }
        if state.customRules[key] != nil { return false }
        let localUndos = state.undoCounts[key, default: 0]
        if state.syncRecords?[key]?.isDeleted == true {
            return localUndos >= Self.muteUndoThreshold
        }
        var totalUndos = localUndos
        for shard in remoteShards.values {
            totalUndos += shard.undoCounts[key, default: 0]
        }
        return totalUndos >= Self.muteUndoThreshold
    }

    public func isMuted(_ rawTrigger: String) -> Bool {
        let key = rawTrigger.lowercased()
        return queue.sync { isMutedLocked(key) }
    }

    public func customOrLearnedReplacement(for rawTrigger: String) -> String? {
        let key = rawTrigger.lowercased()
        return queue.sync {
            if let custom = state.customRules[key] {
                return custom
            }
            if isMutedLocked(key) {
                return nil
            }
            let mergedPairs = mergedCandidatePairsLocked()
            if let targets = mergedPairs[key],
               let best = targets.max(by: { $0.value < $1.value }),
               best.value >= Self.graduationThreshold {
                return best.key
            }
            return nil
        }
    }

    /// Returns a matching custom or learned rule when `typedPrefix` matches either the full trigger or a `>= 4`-char prefix of a mistype.
    public func inlineCandidate(forTypedPrefix rawPrefix: String) -> String? {
        let lower = rawPrefix.lowercased()
        return queue.sync {
            if let custom = state.customRules[lower] {
                return custom
            }
            guard !isMutedLocked(lower) else { return nil }
            let mergedPairs = mergedCandidatePairsLocked()
            if let targets = mergedPairs[lower],
               let best = targets.max(by: { $0.value < $1.value }),
               best.value >= 1 {
                return best.key
            }
            guard lower.count >= 4 else { return nil }
            var foundTargets = Set<String>()
            for (mistype, targetMap) in mergedPairs where mistype.hasPrefix(lower) && !isMutedLocked(mistype) {
                if let best = targetMap.max(by: { $0.value < $1.value }), best.value >= 1, !best.key.lowercased().hasPrefix(lower) {
                    foundTargets.insert(best.key)
                }
            }
            return foundTargets.count == 1 ? foundTargets.first : nil
        }
    }

    /// Detects when the user accidentally pressed Backspace one extra time (deleting the initial letter of a word,
    /// e.g. typing `"wnat"`, deleting all 4 chars instead of 3, and typing `"ant"` when they meant `"want"`, or `"waht"` -> `"hat"` for `"what"`).
    private static func isOverBackspacedFragment(mistype: String, corrected: String) -> Bool {
        let lowerMistype = mistype.lowercased()
        let lowerCorrected = corrected.lowercased()
        guard lowerMistype.count >= 3, lowerCorrected.count >= 2,
              let firstChar = lowerMistype.first else {
            return false
        }
        let reconstructed = String(firstChar) + lowerCorrected
        guard reconstructed != lowerCorrected,
              TypingHabitTracker.defaultValidEnglishWordCheck(reconstructed) else {
            return false
        }
        return ObviousTypoCorrector.damerauLevenshtein(lowerMistype, reconstructed) <= 1
    }

    /// Records a user correction observation (from Backspace repair or explicit `Tab` on a typo fix).
    /// Once observed `>= 2` times, it automatically activates on `Space`!
    public func recordObservedCorrection(mistype rawMistype: String, corrected rawCorrected: String, persistAsync: Bool = true) {
        let mistype = rawMistype.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let corrected = rawCorrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mistype.count >= 2, mistype.count <= 24,
              corrected.count >= 2, corrected.count <= 32,
              mistype != corrected.lowercased(),
              !Self.isOverBackspacedFragment(mistype: mistype, corrected: corrected),
              !ObviousTypoCorrector.developerSafeWords.contains(mistype),
              !TypingHabitTracker.defaultValidEnglishWordCheck(mistype) else {
            return
        }

        let work = {
            guard !self.isMutedLocked(mistype) else { return }
            var map = self.state.candidatePairs[mistype] ?? [:]
            map[corrected, default: 0] += 1
            self.state.candidatePairs[mistype] = map
            if self.state.candidatePairs.count > 250 {
                let sorted = self.state.candidatePairs.sorted {
                    ($0.value.values.max() ?? 0) > ($1.value.values.max() ?? 0)
                }.prefix(180)
                self.state.candidatePairs = Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0.value) })
            }
            self.persistLocked()
        }
        if persistAsync { queue.async(execute: work) } else { queue.sync(execute: work) }
    }

    /// Records that the user pressed `Backspace` right after `Space` auto-corrected `rawTrigger`.
    /// After `2` undos, `rawTrigger` is automatically muted so WordTail never re-corrects it behind the user's back!
    @discardableResult
    public func recordUndo(forTrigger rawTrigger: String, persistAsync: Bool = true) -> Bool {
        let key = rawTrigger.lowercased()
        return queue.sync {
            state.undoCounts[key, default: 0] += 1
            let nowMuted = isMutedLocked(key)
            if nowMuted {
                state.mutedTriggers.insert(key)
                var records = state.syncRecords ?? [:]
                records[key] = RuleSyncRecord(
                    replacement: nil,
                    isMuted: true,
                    isDeleted: false,
                    updatedAt: Date().timeIntervalSince1970
                )
                state.syncRecords = records
            }
            if persistAsync {
                let snap = state
                queue.async { [weak self] in self?.writeSnapshot(snap) }
            } else {
                persistLocked()
            }
            return nowMuted
        }
    }

    @discardableResult
    public func addCustomRule(trigger rawTrigger: String, replacement rawReplacement: String, persistAsync: Bool = true) -> Bool {
        let trigger = rawTrigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let replacement = rawReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trigger.count >= 2, trigger.count <= 24,
              replacement.count >= 1, replacement.count <= 48,
              trigger != replacement.lowercased(),
              trigger.allSatisfy({ ($0.isASCII && $0.isLetter) || $0 == "'" }) else {
            return false
        }
        let now = Date().timeIntervalSince1970
        let work = {
            self.state.mutedTriggers.remove(trigger)
            self.state.undoCounts.removeValue(forKey: trigger)
            self.state.customRules[trigger] = replacement
            var records = self.state.syncRecords ?? [:]
            records[trigger] = RuleSyncRecord(
                replacement: replacement,
                isMuted: false,
                isDeleted: false,
                updatedAt: now
            )
            self.state.syncRecords = records
            self.persistLocked()
        }
        if persistAsync { queue.async(execute: work) } else { queue.sync(execute: work) }
        return true
    }

    public func removeRuleOrUnmute(trigger rawTrigger: String) {
        let key = rawTrigger.lowercased()
        let now = Date().timeIntervalSince1970
        queue.sync {
            state.customRules.removeValue(forKey: key)
            state.candidatePairs.removeValue(forKey: key)
            state.mutedTriggers.remove(key)
            state.undoCounts.removeValue(forKey: key)
            var records = state.syncRecords ?? [:]
            records[key] = RuleSyncRecord(
                replacement: nil,
                isMuted: false,
                isDeleted: true,
                updatedAt: now
            )
            state.syncRecords = records
            persistLocked()
        }
    }

    public func allEntries() -> [CorrectionRuleEntry] {
        queue.sync {
            let mergedPairs = mergedCandidatePairsLocked()
            var list: [CorrectionRuleEntry] = []
            for (trig, rep) in state.customRules {
                list.append(CorrectionRuleEntry(trigger: trig, replacement: rep, count: 0, source: .custom))
            }
            for (trig, targetMap) in mergedPairs where state.customRules[trig] == nil && !isMutedLocked(trig) {
                if let best = targetMap.max(by: { $0.value < $1.value }), best.value >= Self.graduationThreshold {
                    list.append(CorrectionRuleEntry(trigger: trig, replacement: best.key, count: best.value, source: .learned))
                }
            }
            var mutedSet = state.mutedTriggers
            for shard in remoteShards.values {
                for trig in shard.undoCounts.keys where isMutedLocked(trig) {
                    mutedSet.insert(trig)
                }
            }
            for muted in mutedSet where state.customRules[muted] == nil {
                let origTarget = ObviousTypoCorrector.unambiguousTypos[muted]
                    ?? mergedPairs[muted]?.max(by: { $0.value < $1.value })?.key
                    ?? "auto-fix"
                var totalUndos = state.undoCounts[muted, default: 0]
                for shard in remoteShards.values {
                    totalUndos += shard.undoCounts[muted, default: 0]
                }
                list.append(CorrectionRuleEntry(trigger: muted, replacement: origTarget, count: max(2, totalUndos), source: .muted))
            }
            return list.sorted { lhs, rhs in
                if lhs.source != rhs.source {
                    let order: [CorrectionRuleSource: Int] = [.custom: 0, .learned: 1, .muted: 2]
                    return (order[lhs.source] ?? 9) < (order[rhs.source] ?? 9)
                }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.trigger < rhs.trigger
            }
        }
    }

    public func clearAll() {
        queue.sync {
            state = PersistedData()
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func persistLocked() {
        writeSnapshot(state)
    }

    private func writeSnapshot(_ snap: PersistedData) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

public enum ObviousTypoCorrector {
    /// Non-English developer identifiers, CLI binaries, and file formats that should never be auto-corrected or capitalized.
    public static let developerSafeWords: Set<String> = [
        "repo", "repos", "init", "inits", "config", "configs", "cfg", "env", "envs",
        "arg", "args", "kwarg", "kwargs", "param", "params", "async", "impl", "impls",
        "util", "utils", "auth", "authn", "authz", "oauth", "jwt", "sso", "rbac", "cors",
        "kubectl", "helm", "docker", "podman", "orbstack", "pytest", "pydantic", "fastapi",
        "uvicorn", "gunicorn", "celery", "numpy", "scipy", "pandas", "polars",
        "vite", "pnpm", "npm", "npx", "deno", "esbuild", "webpack", "eslint",
        "nvim", "vim", "neovim", "tmux", "zellij", "zsh", "bash", "ghostty", "iterm",
        "macos", "ios", "ipados", "watchos", "tvos", "xcode", "swiftc", "swiftui", "appkit",
        "uikit", "webkit", "coretext", "coregraphics", "avfoundation", "xctest",
        "wechat", "feishu", "lark", "dingtalk", "doubao", "bilibili", "xiaohongshu", "taobao",
        "raycast", "alfred", "codex", "claude", "gemini", "chatgpt", "deepseek", "qwen", "llama",
        "llm", "llms", "vlm", "rag", "lora", "qlora", "gguf", "mlx", "cuda", "mps",
        "gpu", "gpus", "cpu", "cpus", "npu", "tpu", "ram", "vram", "ssd", "nvme",
        "api", "apis", "rpc", "grpc", "graphql", "url", "urls", "uri", "uris",
        "json", "jsonl", "yaml", "yml", "toml", "xml", "csv", "tsv", "parquet", "protobuf",
        "sql", "nosql", "sqlite", "postgres", "mysql", "redis", "kafka", "clickhouse", "supabase",
        "cli", "sdk", "sdks", "ide", "ides", "gui", "tui", "ui", "ux", "dx", "id", "ids",
        "pr", "prs", "mr", "mrs", "ci", "cd", "cicd", "devops", "sre",
        "ssh", "tls", "mtls", "ssl", "http", "https", "tcp", "udp", "quic", "dns", "ip", "vpc",
        "aws", "gcp", "azure", "cloudflare", "vercel", "netlify", "railway", "k8s",
        "wasm", "wasi", "simd", "rgba", "srgb", "utf", "ascii", "regex", "regexp", "cron",
        "sudo", "chmod", "chown", "grep", "ripgrep", "awk", "sed", "curl", "wget", "jq", "yq",
        "brew", "git", "diffs", "worktree", "subagent", "subagents",
        "ls", "cp", "mv", "rm", "mkdir", "cmake", "python", "python3", "cargo", "gh",
        "todo", "todos", "fixme", "noop", "bool", "int", "uint", "str", "dict", "vec",
        "idx", "len", "prev", "curr", "src", "dst", "tmp", "temp", "dir", "dirs", "pkg", "pkgs",
        "dev", "devs", "prod", "stg", "qa", "perf", "spec", "specs", "docs", "readme",
        "wip", "poc", "mvp", "kpi", "okr", "eta", "fyi", "tbh", "imo", "imho", "afaik", "lgtm",
        "pls", "plz", "thx", "nvm", "idk", "ikr", "smh", "lmao", "hodl", "saas", "paas", "iaas",
        "onnx", "uuid", "uids", "conf", "confs", "sync", "awesun", "todesk", "rustdesk", "anydesk", "tailscale",
        "keystat", "keystats", "wordtail", "nihao", "xie", "xiexie", "shanghai", "beijing", "shenzhen",
        "iphone", "ipad", "airpods", "imac", "macbook", "imessage", "imessages", "icloud", "facetime",
        "airdrop", "airplay", "airtag", "airtags", "carplay", "ebay"
    ]

    /// Unambiguous proper nouns, mixed-case brands, platforms, tools, and places auto-cased on Space/punctuation/Tab
    /// (excludes words that also serve as common lowercase English words like "apple", "swift", "slack", "linear", "may", "march").
    public static let canonicalBrandCasing: [String: String] = [
        // Apple & OS ecosystems
        "macos": "macOS",
        "ios": "iOS",
        "ipados": "iPadOS",
        "watchos": "watchOS",
        "tvos": "tvOS",
        "visionos": "visionOS",
        "iphone": "iPhone",
        "iphones": "iPhones",
        "ipad": "iPad",
        "ipads": "iPads",
        "imac": "iMac",
        "imacs": "iMacs",
        "imessage": "iMessage",
        "imessages": "iMessages",
        "icloud": "iCloud",
        "facetime": "FaceTime",
        "airpods": "AirPods",
        "airdrop": "AirDrop",
        "airplay": "AirPlay",
        "airtag": "AirTag",
        "airtags": "AirTags",
        "carplay": "CarPlay",
        "macbook": "MacBook",
        "macbooks": "MacBooks",
        "xcode": "Xcode",
        "testflight": "TestFlight",
        "swiftui": "SwiftUI",
        "appkit": "AppKit",
        "uikit": "UIKit",
        "webkit": "WebKit",
        "coretext": "CoreText",
        "coredata": "CoreData",
        "coreml": "CoreML",
        "coregraphics": "CoreGraphics",
        "homekit": "HomeKit",
        "cloudkit": "CloudKit",
        "storekit": "StoreKit",
        "healthkit": "HealthKit",
        "arkit": "ARKit",
        "applescript": "AppleScript",
        "linux": "Linux",
        "ubuntu": "Ubuntu",
        "debian": "Debian",
        "fedora": "Fedora",
        "nixos": "NixOS",
        "freebsd": "FreeBSD",
        "android": "Android",

        // Networking, Cloud, Infra & Dev Tools ("Tailscale", "WireGuard", "Cloudflare", ...)
        "tailscale": "Tailscale",
        "wireguard": "WireGuard",
        "cloudflare": "Cloudflare",
        "supabase": "Supabase",
        "vercel": "Vercel",
        "netlify": "Netlify",
        "digitalocean": "DigitalOcean",
        "datadog": "Datadog",
        "grafana": "Grafana",
        "kubernetes": "Kubernetes",
        "orbstack": "OrbStack",
        "proxmox": "Proxmox",
        "synology": "Synology",
        "openwrt": "OpenWrt",
        "github": "GitHub",
        "gitlab": "GitLab",
        "bitbucket": "Bitbucket",
        "figma": "Figma",
        "raycast": "Raycast",
        "ghostty": "Ghostty",
        "alacritty": "Alacritty",
        "wezterm": "WezTerm",
        "hammerspoon": "Hammerspoon",
        "karabiner": "Karabiner",
        "homebrew": "Homebrew",
        "jetbrains": "JetBrains",

        // AI, Languages, Frameworks & Databases
        "chatgpt": "ChatGPT",
        "openai": "OpenAI",
        "anthropic": "Anthropic",
        "claude": "Claude",
        "deepmind": "DeepMind",
        "gemini": "Gemini",
        "deepseek": "DeepSeek",
        "qwen": "Qwen",
        "perplexity": "Perplexity",
        "midjourney": "Midjourney",
        "google": "Google",
        "microsoft": "Microsoft",
        "nvidia": "Nvidia",
        "javascript": "JavaScript",
        "typescript": "TypeScript",
        "pytorch": "PyTorch",
        "tensorflow": "TensorFlow",
        "postgresql": "PostgreSQL",
        "mysql": "MySQL",
        "sqlite": "SQLite",
        "mongodb": "MongoDB",
        "clickhouse": "ClickHouse",
        "redis": "Redis",
        "graphql": "GraphQL",
        "fastapi": "FastAPI",
        "pydantic": "Pydantic",
        "langchain": "LangChain",

        // Apps, Services, Languages & Major Cities
        "wechat": "WeChat",
        "feishu": "Feishu",
        "dingtalk": "DingTalk",
        "doubao": "Doubao",
        "bilibili": "Bilibili",
        "xiaohongshu": "Xiaohongshu",
        "taobao": "Taobao",
        "todesk": "ToDesk",
        "rustdesk": "RustDesk",
        "anydesk": "AnyDesk",
        "youtube": "YouTube",
        "linkedin": "LinkedIn",
        "reddit": "Reddit",
        "telegram": "Telegram",
        "whatsapp": "WhatsApp",
        "spotify": "Spotify",
        "netflix": "Netflix",
        "instagram": "Instagram",
        "tiktok": "TikTok",
        "wikipedia": "Wikipedia",
        "bluetooth": "Bluetooth",
        "ebay": "eBay",
        "wordtail": "WordTail",
        "english": "English",
        "shanghai": "Shanghai",
        "beijing": "Beijing",
        "shenzhen": "Shenzhen",
        "hangzhou": "Hangzhou",
        "guangzhou": "Guangzhou"
    ]

    /// Dual CLI/prose command binaries that stay lowercase on the 1st Space (`"git status"`),
    /// and retroactively capitalize on the 2nd Space when followed by an English prose verb (`"git is "` -> `"Git is "`).
    public static let cliCommandWords: Set<String> = [
        "git", "docker", "podman", "kubectl", "helm", "brew", "cargo", "rustup",
        "npm", "pnpm", "npx", "yarn", "bun", "deno", "vite", "webpack", "esbuild", "eslint",
        "python", "python3", "pip", "pip3", "uv", "pytest", "uvicorn", "gunicorn",
        "swiftc", "xcodebuild", "cmake", "ninja",
        "ls", "cd", "cp", "mv", "rm", "mkdir", "rmdir",
        "sudo", "chmod", "chown", "ps", "pkill", "htop", "lsof",
        "grep", "rg", "ripgrep", "awk", "sed", "xargs", "jq", "yq",
        "curl", "wget", "ssh", "scp", "rsync", "tar", "unzip", "ditto",
        "tmux", "zellij", "vim", "nvim", "neovim", "zsh", "bash", "gh"
    ]

    /// Lowercase acronyms & shorthand tokens that should not be half-capitalized to TitleCase ("Api", "Json", "Tbh") on Space.
    public static let nonCapitalizedAcronyms: Set<String> = [
        "api", "apis", "rpc", "grpc", "url", "urls", "uri", "uris",
        "json", "jsonl", "yaml", "yml", "toml", "xml", "csv", "tsv",
        "sql", "nosql", "cli", "sdk", "sdks", "ide", "ides", "gui", "tui", "ui", "ux", "dx", "id", "ids",
        "pr", "prs", "mr", "mrs", "ci", "cd", "cicd", "sre",
        "tls", "mtls", "ssl", "http", "https", "tcp", "udp", "quic", "dns", "ip", "vpc",
        "aws", "gcp", "k8s", "wasm", "wasi", "simd", "rgba", "srgb", "utf", "ascii",
        "llm", "llms", "vlm", "rag", "gguf", "mlx", "gpu", "gpus", "cpu", "cpus", "npu", "tpu", "ram", "vram", "ssd", "nvme",
        "jwt", "sso", "rbac", "cors", "wip", "poc", "mvp", "kpi", "okr", "eta",
        "fyi", "tbh", "imo", "imho", "afaik", "lgtm", "pls", "plz", "thx", "nvm", "idk", "ikr", "smh", "lmao",
        "saas", "paas", "iaas", "uuid", "uids", "cfg", "env", "envs", "arg", "args", "kwarg", "kwargs"
    ]

    /// English verbs, modals, and adverbs that unambiguously mark `<cliWord> <word2>` as an English sentence (`"Git is"`, `"Docker has"`).
    public static let proseSecondWordTriggers: Set<String> = [
        "is", "isn't", "are", "aren't", "was", "wasn't", "were", "weren't",
        "has", "hasn't", "have", "haven't", "had", "hadn't",
        "can", "can't", "cannot", "could", "couldn't",
        "will", "won't", "would", "wouldn't", "should", "shouldn't",
        "shall", "may", "might", "must", "mustn't",
        "does", "doesn't", "did", "didn't",
        "works", "worked", "makes", "made", "helps", "helped", "keeps", "kept", "lets",
        "uses", "used", "needs", "needed", "seems", "seemed", "looks", "feels",
        "becomes", "became", "supports", "supported", "allows", "allowed",
        "provides", "requires", "handles", "stores", "runs", "ran",
        "fails", "failed", "crashes", "crashed", "breaks", "broke",
        "takes", "took", "gives", "gave", "comes", "came", "goes", "went",
        "also", "still", "really", "actually", "always", "never", "just", "only", "already", "often", "usually"
    ]

    /// Valid 1- and 2-letter English words (rejected by `>= 3`-char spellcheckers, but valid sentence starters & standalone words).
    public static let validShortEnglishWords: Set<String> = [
        "a", "i", "ah", "am", "an", "as", "at", "be", "by", "do", "eh", "go", "he", "hi", "hm",
        "if", "in", "is", "it", "me", "my", "no", "of", "oh", "ok", "on", "or",
        "so", "to", "uh", "um", "up", "us", "we", "yo"
    ]

    private static let nonSentenceEndingAbbreviations: Set<String> = [
        "e.g", "i.e", "etc", "vs", "mr", "mrs", "ms", "dr", "prof", "sr", "jr",
        "st", "ave", "inc", "ltd", "co", "corp", "fig", "eq", "vol", "no", "ch", "cf", "al"
    ]

    /// Comprehensive built-in dictionary of contractions, joined-word slips, transpositions, and misspellings.
    public static let unambiguousTypos: [String: String] = [
        // Product names that the system spell checker may not recognize.
        "chtagpt": "ChatGPT", "chatgtp": "ChatGPT", "chagpt": "ChatGPT",
        "chtgpt": "ChatGPT", "chatgptt": "ChatGPT", "chatgbt": "ChatGPT", "chatgp": "ChatGPT",
        "opneai": "OpenAI", "openia": "OpenAI",
        "githbu": "GitHub", "gihub": "GitHub",
        "airpdos": "AirPods", "macobok": "MacBook",
        "raycsat": "Raycast",
        "javasript": "JavaScript", "javascirpt": "JavaScript", "typesript": "TypeScript",
        "kubernets": "Kubernetes",

        // First-person contractions & capitalization patterns ("im" -> "I'm", "ive" -> "I've", "i'll" -> "I'll")
        "im": "I'm",
        "i'm": "I'm",
        "ive": "I've",
        "i've": "I've",
        "i'll": "I'll",
        "i'd": "I'd",
        "id'": "I'd",

        // High-frequency apostrophe contractions
        "dont": "don't",
        "doesnt": "doesn't",
        "didnt": "didn't",
        "isnt": "isn't",
        "arent": "aren't",
        "wasnt": "wasn't",
        "werent": "weren't",
        "wont": "won't",
        "cant": "can't",
        "couldnt": "couldn't",
        "wouldnt": "wouldn't",
        "shouldnt": "shouldn't",
        "mustnt": "mustn't",
        "havent": "haven't",
        "hasnt": "hasn't",
        "hadnt": "hadn't",
        "thats": "that's",
        "whats": "what's",
        "whos": "who's",
        "wheres": "where's",
        "heres": "here's",
        "theres": "there's",
        "hows": "how's",
        "whens": "when's",
        "whys": "why's",
        "youre": "you're",
        "youve": "you've",
        "youll": "you'll",
        "youd": "you'd",
        "theyre": "they're",
        "theyve": "they've",
        "theyll": "they'll",
        "theyd": "they'd",
        "weve": "we've",
        "hes": "he's",
        "shes": "she's",
        "itll": "it'll",
        "aint": "ain't",
        "yall": "y'all",

        // Joined two-word slips ("alot" -> "a lot", "thankyou" -> "thank you")
        "alot": "a lot",
        "atleast": "at least",
        "aswell": "as well",
        "infact": "in fact",
        "incase": "in case",
        "noone": "no one",
        "thankyou": "thank you",
        "eachother": "each other",
        "evenif": "even if",
        "ofcourse": "of course",
        "bytheway": "by the way",

        // High-frequency transpositions & fast-typing slips
        "aslo": "also", "alos": "also",
        "similat": "similar", "similiar": "similar", "simlar": "similar",
        "teh": "the", "hte": "the", "thge": "the",
        "taht": "that", "thta": "that",
        "adn": "and", "nad": "and", "anbd": "and", "cna": "can",
        "wiht": "with", "iwth": "with", "wtih": "with",
        "thier": "their", "theri": "their",
        "abotu": "about", "baout": "about", "abuot": "about",
        "knwo": "know", "konw": "know", "kno": "know", "nkow": "know",
        "jsut": "just", "jstu": "just",
        "liek": "like", "liuke": "like",
        "tahn": "than", "thna": "than",
        "chekc": "check", "chek": "check", "checkign": "checking",
        "yuo": "you", "yoru": "your", "yuor": "your",
        "waht": "what", "hwat": "what",
        "whcih": "which", "whihc": "which", "wich": "which",
        "woudl": "would", "owuld": "would",
        "coudl": "could", "oculd": "could",
        "shoudl": "should", "shuold": "should", "shoud": "should",
        "firts": "first", "fisrt": "first",
        "agian": "again", "agin": "again",
        "beacuse": "because", "becuase": "because", "becasue": "because", "beause": "because", "cuz": "because",
        "ahve": "have", "hvae": "have", "haev": "have",
        "tihs": "this", "htis": "this",
        "fomr": "from", "frmo": "from",
        "peopel": "people", "poeple": "people",
        "workd": "world", "wolrd": "world", "worls": "world",
        "thign": "thing", "hting": "thing", "thigns": "things", "tihngs": "things",
        "otehr": "other", "ohter": "other",
        "verison": "version", "vresion": "version",
        "probelm": "problem", "porblem": "problem", "problme": "problem", "problms": "problems", "probelms": "problems",
        "sentance": "sentence", "sentances": "sentences",
        "pattren": "pattern", "parttern": "pattern", "partterns": "patterns",
        "slef": "self", "esle": "else", "ture": "true", "flase": "false", "fasle": "false",
        "retrun": "return", "reutrn": "return",
        "chnage": "change", "chaneg": "change", "chnages": "changes",
        "updateing": "updating", "createing": "creating", "deleteing": "deleting",
        "makeing": "making", "takeing": "taking", "comming": "coming", "writting": "writing", "begining": "beginning",
        "runing": "running", "stoping": "stopping", "geting": "getting", "puting": "putting", "seting": "setting",

        "actaul": "actual", "artcile": "article", "defualt": "default",
        "descripiton": "description", "exmaple": "example", "exmple": "example",
        "feautre": "feature", "fitler": "filter", "mesage": "message", "messsage": "message",
        "reqeust": "request", "resposne": "response", "typign": "typing",
        "upate": "update", "uploda": "upload",

        // Classic English misspellings
        "autocorect": "autocorrect", "autoocorrect": "autocorrect",
        "capitlaize": "capitalize", "capitilize": "capitalize", "capitlization": "capitalization",
        "mispell": "misspell", "mispelled": "misspelled", "mispelling": "misspelling",
        "instalation": "installation", "throughtout": "throughout", "seperat": "separate",
        "definately": "definitely", "definatly": "definitely", "definetly": "definitely", "definitly": "definitely",
        "recieve": "receive", "recieved": "received", "recieving": "receiving", "recevie": "receive",
        "seperate": "separate", "seperated": "separated", "seperately": "separately", "seperating": "separating",
        "occured": "occurred", "occuring": "occurring", "occurence": "occurrence", "ocurred": "occurred",
        "untill": "until",
        "wierd": "weird",
        "acheive": "achieve", "acheived": "achieved", "acheiving": "achieving",
        "beleive": "believe", "beleived": "believed", "belive": "believe",
        "calender": "calendar",
        "accomodate": "accommodate", "acommodate": "accommodate",
        "enviroment": "environment", "enviroments": "environments", "enviornment": "environment",
        "goverment": "government",
        "neccessary": "necessary", "necesary": "necessary", "nessecary": "necessary",
        "tommorow": "tomorrow", "tomorow": "tomorrow", "tmrw": "tomorrow",
        "immediatly": "immediately", "imediately": "immediately",
        "embarass": "embarrass", "embarassing": "embarrassing",
        "existance": "existence",
        "apparentely": "apparently", "aparently": "apparently",
        "basicly": "basically", "basicaly": "basically",
        "actualy": "actually", "actaully": "actually", "acutally": "actually",
        "probaly": "probably", "probalby": "probably", "porbably": "probably",
        "honsetly": "honestly",
        "realy": "really", "relaly": "really",
        "finaly": "finally", "fianlly": "finally",
        "usally": "usually", "usualy": "usually",
        "truely": "truly",
        "arguement": "argument", "arguements": "arguments",
        "independant": "independent",
        "maintainance": "maintenance", "maintenence": "maintenance",
        "noticable": "noticeable",
        "persistant": "persistent",
        "priviledge": "privilege",
        "recomend": "recommend", "recomended": "recommended", "reccommend": "recommend",
        "refered": "referred", "refering": "referring",
        "succesful": "successful", "succesfully": "successfully", "successfull": "successful",
        "suprise": "surprise", "suprised": "surprised",
        "collegue": "colleague", "collegues": "colleagues",
        "knowlege": "knowledge",
        "langauge": "language", "lanugage": "language",
        "lenght": "length", "widht": "width", "heigth": "height", "strnegth": "strength",
        "buisness": "business", "busines": "business",
        "questionaire": "questionnaire", "oppurtunity": "opportunity", "opprotunity": "opportunity",
        "diffrent": "different", "diferent": "different", "intresting": "interesting", "intersting": "interesting",

        // Common CS & technical prose misspellings
        "algoritm": "algorithm", "algoritms": "algorithms",
        "asychronous": "asynchronous", "asyncronous": "asynchronous", "syncronous": "synchronous",
        "parrallel": "parallel", "paralell": "parallel",
        "configuraiton": "configuration", "implementaiton": "implementation",
        "documentaiton": "documentation", "autentication": "authentication", "authorizaiton": "authorization",
        "reporsitory": "repository", "dependancy": "dependency", "dependancies": "dependencies",
        "dependecy": "dependency", "paramter": "parameter",
        "performace": "performance", "compatability": "compatibility",
        "availibility": "availability", "reproducable": "reproducible", "herustic": "heuristic",
        "architecure": "architecture", "infrastruture": "infrastructure", "optmize": "optimize", "optmization": "optimization",
        "imesage": "iMessage", "imessgae": "iMessage", "imeesage": "iMessage"
    ]

    /// Computes minimal backspace + suffix edit between `source` and `target` so the editor only replaces
    /// the diverging tail (`"definately"` -> `"definitely"` deletes 5 chars `"ately"` and inserts `"itely"`).
    public static func minimalDiff(from source: String, to target: String) -> MinimalDiffEdit {
        let sChars = Array(source)
        let tChars = Array(target)
        var common = 0
        let limit = min(sChars.count, tChars.count)
        while common < limit && sChars[common] == tChars[common] {
            common += 1
        }
        let deleteCount = sChars.count - common
        let insertText = String(tChars[common..<tChars.count])
        return MinimalDiffEdit(deleteCount: deleteCount, insertText: insertText)
    }

    public static func isApostrophe(_ ch: Character) -> Bool {
        ch == "'" || ch == "’"
    }

    public static func normalizeApostrophes(_ text: String) -> String {
        text.contains("’") ? text.replacingOccurrences(of: "’", with: "'") : text
    }

    public static func isValidSentenceStarterWord(
        _ rawWord: String,
        validWordChecker: (String) -> Bool = TypingHabitTracker.defaultValidEnglishWordCheck
    ) -> Bool {
        let lower = normalizeApostrophes(rawWord).lowercased()
        guard !lower.isEmpty else { return false }
        if validShortEnglishWords.contains(lower)
            || validWordChecker(lower)
            || TechLexicon.wordSet.contains(lower) {
            return true
        }
        // Contractions & possessives ("this's", "that's", "don't", "doesn't", "today's", "that'll"):
        // Validate the base stem BEFORE the apostrophe instead of deleting "'" into invalid "thiss"/"todays"!
        if lower.contains("'") {
            for clitic in ["'s", "'d", "'ll", "'re", "'ve", "'m"] where lower.hasSuffix(clitic) {
                let stem = String(lower.dropLast(clitic.count))
                if validShortEnglishWords.contains(stem)
                    || validWordChecker(stem)
                    || TechLexicon.wordSet.contains(stem) {
                    return true
                }
            }
            if lower.hasSuffix("n't") {
                let stem = String(lower.dropLast(3))
                if validShortEnglishWords.contains(stem) || validWordChecker(stem) {
                    return true
                }
            }
        }
        return false
    }

    /// Unified `Space`-key transformation returning either a 1-word edit (`"im"` -> `"I'm"`, `"macos"` -> `"macOS"`, `"repo"` -> `"Repo"`)
    /// or a 2-word CLI-to-prose sentence-start promotion (`"git is"` -> `"Git is"`).
    public static func evaluateSpaceTransform(
        forWord word: String,
        lineContextIncludingWord: String?,
        isAtDocumentStart: Bool = false,
        sliceStartsAtDocumentZero: Bool = false,
        autoCorrectTypos: Bool,
        autoCapitalizeSentences: Bool,
        adaptiveStore: AdaptiveCorrectionStore? = nil,
        habitTracker: TypingHabitTracker?,
        historyStore: UserHistoryStore?,
        validWordChecker: (String) -> Bool = TypingHabitTracker.defaultValidEnglishWordCheck
    ) -> SpaceTransformResult? {
        guard !word.isEmpty, word.count <= 24 else { return nil }
        guard word.allSatisfy({ ($0.isASCII && $0.isLetter) || isApostrophe($0) }) else { return nil }

        let lower = normalizeApostrophes(word).lowercased()
        guard !hasProtectedCasing(word, lower: lower) else { return nil }

        let atSentenceStart = isWordAtSentenceStart(
            word: word,
            inContextBeforeCursor: lineContextIncludingWord,
            isAtDocumentStart: isAtDocumentStart,
            sliceStartsAtDocumentZero: sliceStartsAtDocumentZero
        )

        // 1. User's explicit custom shorthand rules ALWAYS take priority
        if autoCorrectTypos, let customOrLearned = adaptiveStore?.customOrLearnedReplacement(for: lower) {
            var res = adaptCase(of: customOrLearned, toTyped: word)
            if autoCapitalizeSentences && atSentenceStart,
               let f = res.first, f.isLowercase,
               !res.dropFirst().contains(where: \.isUppercase) {
                res = res.prefix(1).uppercased() + res.dropFirst()
            }
            return res != word ? SpaceTransformResult(replacedSourceSpan: word, replacementText: res) : nil
        }

        // Respect triggers the user muted by undoing with Backspace twice (for spelling/brand substitutions ONLY;
        // normal sentence-start capitalization in Step 4 still applies to valid English words!).
        let isSpellingMuted = (adaptiveStore?.isMuted(lower) == true)

        var working = word

        if !isSpellingMuted {
            // 2. User-pinned capitalized dictionary words & canonical proper nouns/brands
            //    ("imessage" / "Imessage" -> "iMessage", "tailscale" -> "Tailscale", "macos" / "Macos" -> "macOS")
            if autoCorrectTypos {
                if word == lower, let pinnedCased = historyStore?.customPinnedCasing(for: lower) {
                    working = pinnedCased
                } else if let brand = canonicalBrandCasing[lower] {
                    working = brand
                }
            }
            if working == word && !developerSafeWords.contains(lower) {
                // 3. Context-aware "lets" -> "Let's" + typo/contraction auto-correction
                if autoCorrectTypos && lower == "lets" && atSentenceStart {
                    working = "Let's"
                } else if autoCorrectTypos,
                          let typoFixed = spaceAutoCorrection(
                              forWord: working,
                              adaptiveStore: adaptiveStore,
                              habitTracker: habitTracker,
                              historyStore: historyStore
                          ) {
                    working = typoFixed
                }
            }
        }

        // 4. Sentence-start capitalization + standalone "i" -> "I"
        //    - CLI commands (`git`, `docker`, `python`) stay lowercase on the 1st Space so `"git status"` isn't altered!
        //    - Mixed-case brands (`macOS`, `iPhone`) keep their lowercase leading letter (`!working.dropFirst().contains(where: \.isUppercase)`).
        //    - Prose-friendly tech nouns (`repo`, `docs`, `claude`, `codex`) DO capitalize at sentence start!
        if autoCapitalizeSentences {
            if working == "i" {
                working = "I"
            } else if !(lower == "lets" && isSpellingMuted),
                      let first = working.first,
                      first.isLowercase,
                      !working.dropFirst().contains(where: \.isUppercase),
                      atSentenceStart,
                      !cliCommandWords.contains(lower),
                      !nonCapitalizedAcronyms.contains(lower) {
                let firstWordPart = String(working.split(separator: " ").first ?? Substring(working))
                let isRealOrTechNoun = (working != word)
                    || developerSafeWords.contains(lower)
                    || isValidSentenceStarterWord(firstWordPart, validWordChecker: validWordChecker)
                if isRealOrTechNoun {
                    working = working.prefix(1).uppercased() + working.dropFirst()
                }
            }
        }

        // 5. Smart 2nd-word CLI -> Prose promotion (`"git is "` -> `"Git is "`, `"docker isnt "` -> `"Docker isn't "`):
        if autoCapitalizeSentences,
           let ctx = lineContextIncludingWord,
           let promoted = evaluateDeferredCliSentencePromotion(
               secondWordTyped: word,
               secondWordResolved: working,
               lineContextIncludingSecondWord: ctx,
               sliceStartsAtDocumentZero: sliceStartsAtDocumentZero || isAtDocumentStart,
               adaptiveStore: adaptiveStore
           ) {
            return promoted
        }

        return working != word ? SpaceTransformResult(replacedSourceSpan: word, replacementText: working) : nil
    }

    public static func spaceReplacement(
        forWord word: String,
        lineContextIncludingWord: String?,
        isAtDocumentStart: Bool = false,
        sliceStartsAtDocumentZero: Bool = false,
        autoCorrectTypos: Bool,
        autoCapitalizeSentences: Bool,
        adaptiveStore: AdaptiveCorrectionStore? = nil,
        habitTracker: TypingHabitTracker?,
        historyStore: UserHistoryStore?,
        validWordChecker: (String) -> Bool = TypingHabitTracker.defaultValidEnglishWordCheck
    ) -> String? {
        evaluateSpaceTransform(
            forWord: word,
            lineContextIncludingWord: lineContextIncludingWord,
            isAtDocumentStart: isAtDocumentStart,
            sliceStartsAtDocumentZero: sliceStartsAtDocumentZero,
            autoCorrectTypos: autoCorrectTypos,
            autoCapitalizeSentences: autoCapitalizeSentences,
            adaptiveStore: adaptiveStore,
            habitTracker: habitTracker,
            historyStore: historyStore,
            validWordChecker: validWordChecker
        )?.replacementText
    }

    private static func evaluateDeferredCliSentencePromotion(
        secondWordTyped: String,
        secondWordResolved: String,
        lineContextIncludingSecondWord context: String,
        sliceStartsAtDocumentZero: Bool,
        adaptiveStore: AdaptiveCorrectionStore?
    ) -> SpaceTransformResult? {
        let resolvedNorm = normalizeApostrophes(secondWordResolved).lowercased()
        guard proseSecondWordTriggers.contains(resolvedNorm) else { return nil }
        guard normalizeApostrophes(context).lowercased().hasSuffix(normalizeApostrophes(secondWordTyped).lowercased()) else {
            return nil
        }

        let beforeSecond = String(context.dropLast(secondWordTyped.count))
        let chars = Array(beforeSecond)
        var spaceStart = chars.count
        while spaceStart > 0 && isHorizontalSpace(chars[spaceStart - 1]) {
            spaceStart -= 1
        }
        let spaceCount = chars.count - spaceStart
        guard spaceCount >= 1 && spaceCount <= 2, spaceStart > 0 else { return nil }

        var cliStart = spaceStart
        while cliStart > 0 && chars[cliStart - 1].isASCII && (chars[cliStart - 1].isLetter || chars[cliStart - 1].isNumber) {
            cliStart -= 1
        }
        guard cliStart < spaceStart else { return nil }

        let cliWord = String(chars[cliStart..<spaceStart])
        // Only promote if typed all-lowercase as a known dual CLI/prose word and not muted
        guard cliWord == cliWord.lowercased(),
              cliCommandWords.contains(cliWord),
              adaptiveStore?.isMuted(cliWord) != true else {
            return nil
        }

        let contextUpToCli = String(chars[0..<spaceStart])
        let beforeCli = String(chars[0..<cliStart])
        let allowedDocZeroPrefix = CharacterSet(charactersIn: " \t\u{00A0}\u{202F}\u{2007}\"'“‘([")
        let cliIsAtDocStart = sliceStartsAtDocumentZero
            && beforeCli.unicodeScalars.allSatisfy { allowedDocZeroPrefix.contains($0) }

        guard isWordAtSentenceStart(
            word: cliWord,
            inContextBeforeCursor: contextUpToCli,
            isAtDocumentStart: cliIsAtDocStart,
            sliceStartsAtDocumentZero: sliceStartsAtDocumentZero
        ) else {
            return nil
        }

        let spaces = String(chars[spaceStart..<chars.count])
        let promotedCli = cliWord.prefix(1).uppercased() + cliWord.dropFirst()
        return SpaceTransformResult(
            replacedSourceSpan: cliWord + spaces + secondWordTyped,
            replacementText: promotedCli + spaces + secondWordResolved
        )
    }

    /// Fast O(1) pre-check deciding whether `Space` needs a synchronous live Accessibility read to resolve sentence-start capitalization.
    public static func needsLiveSentenceContextOnSpace(
        forWord word: String,
        rollingBuffer: String,
        autoCorrectTypos: Bool,
        autoCapitalizeSentences: Bool,
        adaptiveStore: AdaptiveCorrectionStore? = nil
    ) -> Bool {
        guard !word.isEmpty, word.count <= 24 else { return false }
        guard word.allSatisfy({ ($0.isASCII && $0.isLetter) || isApostrophe($0) }) else { return false }
        if word.dropFirst().contains(where: \.isUppercase) { return false }
        if word.count >= 2 && word.allSatisfy({ !$0.isLetter || $0.isUppercase }) { return false }

        let lower = normalizeApostrophes(word).lowercased()
        if lower == "i" || canonicalBrandCasing[lower] != nil || (autoCorrectTypos && isCanonicalBrandTypo(lower)) {
            return false // Built-in brand casing and standalone "I" do not depend on sentence position.
        }

        // Check if `<cliWord> <word>` might need live doc-start verification for 2nd-word CLI->Prose promotion ("git is ")!
        if autoCapitalizeSentences, mayNeedLiveCliPromotionCheck(secondWord: word, inBuffer: rollingBuffer) {
            return true
        }

        if !autoCapitalizeSentences && !(autoCorrectTypos && lower == "lets") {
            return false
        }
        if let first = word.first, first.isUppercase {
            return false
        }
        if adaptiveStore?.customOrLearnedReplacement(for: lower) == nil {
            if (!autoCapitalizeSentences && adaptiveStore?.isMuted(lower) == true)
                || cliCommandWords.contains(lower)
                || nonCapitalizedAcronyms.contains(lower) {
                return false
            }
        }
        if hasConfirmedMidSentencePredecessor(forWord: word, inBuffer: rollingBuffer) {
            return false
        }
        return true
    }

    private static func mayNeedLiveCliPromotionCheck(secondWord: String, inBuffer buffer: String) -> Bool {
        let lowerSecond = normalizeApostrophes(secondWord).lowercased()
        let effectiveSecond = unambiguousTypos[lowerSecond]?.lowercased() ?? lowerSecond
        guard proseSecondWordTriggers.contains(effectiveSecond) else { return false }
        guard normalizeApostrophes(buffer).lowercased().hasSuffix(lowerSecond) else { return false }

        let beforeSecond = String(buffer.dropLast(secondWord.count)).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard let prevWord = extractTrailingStandaloneWord(from: beforeSecond) else { return false }
        guard prevWord == prevWord.lowercased(), cliCommandWords.contains(prevWord) else { return false }

        // If `buffer` ALREADY proves `prevWord` is mid-sentence ("I think git is"), no live AX query is needed!
        if hasConfirmedMidSentencePredecessor(forWord: prevWord, inBuffer: beforeSecond) {
            return false
        }
        return true
    }

    public static func hasConfirmedMidSentencePredecessor(forWord word: String, inBuffer buffer: String) -> Bool {
        let normBuf = normalizeApostrophes(buffer).lowercased()
        let normWord = normalizeApostrophes(word).lowercased()
        guard normBuf.count > normWord.count + 1,
              normBuf.hasSuffix(normWord) else {
            return false
        }
        let chars = Array(buffer.dropLast(word.count))
        var i = chars.count
        var sawHorizontalSpace = false
        while i > 0 && isHorizontalSpace(chars[i - 1]) {
            sawHorizontalSpace = true
            i -= 1
        }
        guard sawHorizontalSpace, i > 0 else { return false }
        let prev = chars[i - 1]
        // Preceded immediately by a normal word character or comma/semicolon -> guaranteed NOT after `.`, `!`, `?`, or doc start!
        return (prev.isASCII && prev.isLetter) || prev == "," || prev == ";" || prev == ":"
    }

    /// Returns true ONLY when:
    /// 1. `isAtDocumentStart` is true (the very first word at index 0 of the entire text field), OR
    /// 2. Preceding text before `word` ends with sentence-ending punctuation (`.`, `!`, `?`) followed by whitespace/newline, OR
    /// 3. Preceding text on the current line is a line-leading numbered list marker (`"1. "`, `"2. "`, `"10. "`, `"1) "`, `"\t1.\t"`).
    /// Soft-wrapped visual lines and plain line breaks (`\n`) without `.`, `!`, `?`, or a numbered list prefix NEVER trigger capitalization.
    public static func isWordAtSentenceStart(
        word: String,
        inContextBeforeCursor context: String?,
        isAtDocumentStart: Bool = false,
        sliceStartsAtDocumentZero: Bool = false
    ) -> Bool {
        if isAtDocumentStart {
            return true
        }
        guard let context, !context.isEmpty else {
            return false
        }
        guard normalizeApostrophes(context).lowercased().hasSuffix(normalizeApostrophes(word).lowercased()) else {
            return false
        }

        let prefixBeforeWord = String(context.dropLast(word.count))
        if hasSentenceEndingPunctuation(before: prefixBeforeWord) {
            return true
        }
        return isLineLeadingNumberedListPrefix(
            prefixBeforeWord,
            fullContextLength: context.count,
            sliceStartsAtDocumentZero: sliceStartsAtDocumentZero
        )
    }

    public static func sentenceContextAfterReturn(_ buffer: String) -> String {
        let prefix = String(buffer.suffix(79)) + "\n"
        return hasSentenceEndingPunctuation(before: prefix) ? prefix : "\n"
    }

    private static func isHorizontalSpace(_ ch: Character) -> Bool {
        ch == " " || ch == "\t" || ch == "\u{00A0}" || ch == "\u{202F}" || ch == "\u{2007}"
    }

    /// Normalizes raw Accessibility strings: converts `\u{FFFC}` attachment/block markers into newline boundaries
    /// (preventing `"All done.\u{FFFC}also"` from collapsing into `"All done.also"`), normalizes non-breaking spaces
    /// (`\u{00A0}`, `\u{202F}`, `\u{2007}`) to ASCII space, and strips zero-width joiners.
    public static func cleanAccessibilityText(_ raw: String) -> String {
        var out = raw
        if out.contains("\u{FFFC}") {
            out = out.replacingOccurrences(of: "\u{FFFC}", with: "\n")
        }
        if out.contains("\u{00A0}") {
            out = out.replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        if out.contains("\u{202F}") {
            out = out.replacingOccurrences(of: "\u{202F}", with: " ")
        }
        if out.contains("\u{2007}") {
            out = out.replacingOccurrences(of: "\u{2007}", with: " ")
        }
        if out.contains("\u{200B}") {
            out = out.replacingOccurrences(of: "\u{200B}", with: "")
        }
        if out.contains("\u{FEFF}") {
            out = out.replacingOccurrences(of: "\u{FEFF}", with: "")
        }
        return out
    }

    /// Returns true when `fullSlice` may be missing a block/paragraph newline before `word` or before a
    /// numbered list marker leading into `word` (e.g., `"...suggestions.1. there"`, `"...suggestions.there"`, `"All done.also"`).
    public static func mayNeedParagraphBoundaryReconciliation(
        inFullSlice fullSlice: String,
        forWord word: String?
    ) -> Bool {
        guard let word, !word.isEmpty,
              fullSlice.count > word.count,
              normalizeApostrophes(fullSlice).lowercased().hasSuffix(normalizeApostrophes(word).lowercased()) else {
            return false
        }
        let before = String(fullSlice.dropLast(word.count))
        if before.last?.isWhitespace != true {
            return true
        }
        if let split = splitTrailingNumberedListMarker(from: before, requireTrailingSpace: true),
           !isEmptyOrEndsWithNewlineIgnoringHorizontalSpaces(split.beforeMarker),
           split.beforeMarker.last?.isWhitespace != true
            || isTightlyAttachedAfterBlockText(trimTrailingHorizontalSpaces(split.beforeMarker)) {
            return true
        }
        return false
    }

    /// Rich `contenteditable` editors (`<p>All done.</p><p>also</p>` or `<p>...suggestions.</p><ol><li>there</li></ol>`)
    /// sometimes omit `\n` in `AXStringForTextMarkerRange([docStart, end])` (`"All done.also"`, `"...suggestions.1. there"`,
    /// `"...suggestions.1.there"`, `"...suggestions.there"`), while `AXParagraphTextMarkerRangeForTextMarker` confirms the
    /// current block starts at `firstWord` or at a numbered list item leading into `firstWord`.
    /// Injects the missing paragraph newline (and normalized list marker when needed).
    public static func reconcileParagraphBoundaryInFullSlice(
        fullSlice: String,
        paragraphSlice: String?,
        firstWord: String?
    ) -> String {
        guard let firstWord, !firstWord.isEmpty,
              let paragraphSlice,
              normalizeApostrophes(fullSlice).lowercased().hasSuffix(normalizeApostrophes(firstWord).lowercased()),
              fullSlice.count >= firstWord.count else {
            return fullSlice
        }
        let before = String(fullSlice.dropLast(firstWord.count))
        let trailingWord = String(fullSlice.suffix(firstWord.count))

        if let listItem = parseLeadingNumberedListItem(paragraphSlice, expectedWord: firstWord) {
            if let split = splitTrailingNumberedListMarker(from: before, requireTrailingSpace: false),
               trimTrailingHorizontalSpaces(split.marker) == listItem.digitsAndPunct {
                let outMarker = split.marker.last.map(isHorizontalSpace) == true ? split.marker : listItem.normalizedMarker
                if isEmptyOrEndsWithNewlineIgnoringHorizontalSpaces(split.beforeMarker) {
                    return split.beforeMarker + outMarker + trailingWord
                }
                return split.beforeMarker + "\n" + outMarker + trailingWord
            }
            if before.isEmpty || before.last?.isNewline == true {
                return before + listItem.normalizedMarker + trailingWord
            }
            return before + "\n" + listItem.normalizedMarker + trailingWord
        }

        guard fullSlice.count > firstWord.count,
              containsOnlyWord(firstWord, in: paragraphSlice) else {
            return fullSlice
        }
        if before.last?.isNewline == true {
            return fullSlice
        }
        if let split = splitTrailingNumberedListMarker(from: before, requireTrailingSpace: true) {
            if isEmptyOrEndsWithNewlineIgnoringHorizontalSpaces(split.beforeMarker) {
                return fullSlice
            }
            return split.beforeMarker + "\n" + split.marker + trailingWord
        }
        if let split = splitTrailingNumberedListMarker(from: before, requireTrailingSpace: false) {
            if isEmptyOrEndsWithNewlineIgnoringHorizontalSpaces(split.beforeMarker) {
                return split.beforeMarker + split.marker + " " + trailingWord
            }
            if isTightlyAttachedAfterBlockText(split.beforeMarker) {
                return split.beforeMarker + "\n" + split.marker + " " + trailingWord
            }
        }
        guard let lastBefore = before.last, !lastBefore.isWhitespace else {
            return fullSlice
        }
        return before + "\n" + trailingWord
    }

    /// A paragraph-scoped editor response needs earlier text only for its first word.
    public static func sentenceContext(
        forFirstWord word: String,
        paragraphPrefix: String,
        readPreviousTail: () -> String?
    ) -> String? {
        guard containsOnlyWord(word, in: paragraphPrefix),
              let previousTail = readPreviousTail()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !previousTail.isEmpty else {
            return nil
        }
        if isStandaloneNumberedListMarker(previousTail) {
            return "\n" + previousTail + " " + paragraphPrefix
        }
        if let split = splitTrailingNumberedListMarker(from: previousTail, requireTrailingSpace: false) {
            if isEmptyOrEndsWithNewlineIgnoringHorizontalSpaces(split.beforeMarker) {
                return split.beforeMarker + split.marker + " " + paragraphPrefix
            }
            if isTightlyAttachedAfterBlockText(split.beforeMarker) {
                return split.beforeMarker + "\n" + split.marker + " " + paragraphPrefix
            }
        }
        return previousTail + "\n" + paragraphPrefix
    }

    /// Rich editors can report only the current paragraph (or strip `"1. "` / `"\n"` around `<ol><li>` list items).
    /// Recover a preceding sentence ending or numbered-list marker when the live context and typed buffer agree on the first word.
    public static func sentenceContext(
        forWord word: String,
        liveContext: String,
        bufferedContext: String
    ) -> String {
        if isWordAtSentenceStart(word: word, inContextBeforeCursor: liveContext) {
            return liveContext
        }
        guard let lastLineSub = bufferedContext.split(whereSeparator: \.isNewline).last else {
            return liveContext
        }
        let lastLine = String(lastLineSub)
        guard containsOnlyWordOrNumberedListItem(word, inLine: lastLine),
              isWordAtSentenceStart(word: word, inContextBeforeCursor: bufferedContext) else {
            return liveContext
        }
        if containsOnlyWord(word, in: liveContext) {
            return bufferedContext
        }
        if bufferedContext.contains(where: \.isNewline),
           matchesFlattenedParagraphBreak(
               word: word,
               lastLine: lastLine,
               liveContext: liveContext,
               bufferedContext: bufferedContext
           ) {
            return bufferedContext
        }
        return liveContext
    }

    private static func matchesFlattenedParagraphBreak(
        word: String,
        lastLine: String,
        liveContext: String,
        bufferedContext: String
    ) -> Bool {
        guard let lastNL = bufferedContext.lastIndex(where: { $0.isNewline }) else {
            return false
        }
        let liveNorm = normalizeApostrophes(cleanAccessibilityText(liveContext)).lowercased()
        let wordNorm = normalizeApostrophes(cleanAccessibilityText(word)).lowercased()
        let lastLineRawNorm = normalizeApostrophes(cleanAccessibilityText(lastLine)).lowercased()
        let lastLineTrimmed = String(lastLineRawNorm.drop(while: isHorizontalSpace))

        var rawBeforeNL = String(bufferedContext[..<lastNL])
        while rawBeforeNL.last?.isNewline == true {
            rawBeforeNL.removeLast()
        }
        let beforeNewlineNorm = normalizeApostrophes(cleanAccessibilityText(rawBeforeNL))
            .lowercased()
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")

        func matchesBeforePrefix(_ liveBefore: String, bufferedBefore: String) -> Bool {
            let a = liveBefore
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
            guard !bufferedBefore.isEmpty else { return false }
            if !a.isEmpty && (a.hasSuffix(bufferedBefore) || bufferedBefore.hasSuffix(a)) {
                return true
            }
            let aTrimmed = trimTrailingHorizontalSpaces(a)
            let bTrimmed = trimTrailingHorizontalSpaces(bufferedBefore)
            guard !aTrimmed.isEmpty && !bTrimmed.isEmpty else { return false }
            return aTrimmed.hasSuffix(bTrimmed) || bTrimmed.hasSuffix(aTrimmed)
        }

        let listItem = parseLeadingNumberedListItem(lastLine, expectedWord: word)
        let isBufferNumberedListLine = (listItem != nil)
        let tightListSuffix = listItem.map { $0.digitsAndPunct.lowercased() + wordNorm }

        // 1. AX preserved `"1. there"` (or current line) but dropped `\n` before it (`"...suggestions.1. there"`).
        if liveNorm.hasSuffix(lastLineTrimmed) {
            let liveBefore = String(liveNorm.dropLast(lastLineTrimmed.count))
            if !liveBefore.isEmpty,
               liveBefore.last?.isWhitespace != true,
               matchesBeforePrefix(liveBefore, bufferedBefore: beforeNewlineNorm)
                || (beforeNewlineNorm.isEmpty && isBufferNumberedListLine) {
                return true
            }
        }

        // 2. AX dropped `"1. "` into `<ol><li>` (leaving `"Heading\nthere"`), or dropped both `\n` and `"1. "` (`"...suggestions.there"`, `"Headingthere"`).
        //    Skip when `liveNorm` ends with a spaceless marker (`"1.there"`), which belongs to check 3 so `"See item 1.below"` isn't misread.
        if liveNorm.hasSuffix(wordNorm),
           tightListSuffix.map({ !liveNorm.hasSuffix($0) }) ?? true {
            let liveBefore = String(liveNorm.dropLast(wordNorm.count))
            let isGluedWithoutWhitespace = (liveBefore.last?.isWhitespace != true)
            let isAtNewLineBoundary = isEmptyOrEndsWithNewlineIgnoringHorizontalSpaces(liveBefore)
            if (isGluedWithoutWhitespace
                && (matchesBeforePrefix(liveBefore, bufferedBefore: beforeNewlineNorm)
                    || (beforeNewlineNorm.isEmpty && isBufferNumberedListLine && !liveBefore.isEmpty)))
                || (isBufferNumberedListLine
                    && !liveBefore.isEmpty
                    && isAtNewLineBoundary
                    && (beforeNewlineNorm.isEmpty || matchesBeforePrefix(liveBefore, bufferedBefore: beforeNewlineNorm))) {
                return true
            }
        }

        // 3. AX kept `"1."` without space and dropped `\n` (`"...suggestions.1.there"`).
        if let tightListSuffix, liveNorm.hasSuffix(tightListSuffix) {
            let liveBefore = String(liveNorm.dropLast(tightListSuffix.count))
            if !liveBefore.isEmpty,
               liveBefore.last?.isWhitespace != true,
               matchesBeforePrefix(liveBefore, bufferedBefore: beforeNewlineNorm)
                || beforeNewlineNorm.isEmpty {
                return true
            }
        }

        return false
    }

    private static func splitTrailingNumberedListMarker(
        from prefix: String,
        requireTrailingSpace: Bool
    ) -> (beforeMarker: String, marker: String)? {
        let chars = Array(prefix)
        var idx = chars.count
        while idx > 0 && isHorizontalSpace(chars[idx - 1]) {
            idx -= 1
        }
        if requireTrailingSpace && idx == chars.count {
            return nil
        }
        guard idx > 0, chars[idx - 1] == "." || chars[idx - 1] == ")" else {
            return nil
        }
        let punctIdx = idx - 1
        var digitStart = punctIdx
        while digitStart > 0 && chars[digitStart - 1].isASCII && chars[digitStart - 1].isNumber {
            digitStart -= 1
        }
        let digitCount = punctIdx - digitStart
        guard digitCount >= 1 && digitCount <= 4 else {
            return nil
        }
        return (
            beforeMarker: String(chars[0..<digitStart]),
            marker: String(chars[digitStart..<chars.count])
        )
    }

    private static func parseLeadingNumberedListItem(
        _ text: String,
        expectedWord: String
    ) -> (digitsAndPunct: String, normalizedMarker: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(trimmed)
        var idx = 0
        while idx < chars.count && chars[idx].isASCII && chars[idx].isNumber {
            idx += 1
        }
        guard idx >= 1 && idx <= 4, idx < chars.count else {
            return nil
        }
        let punct = chars[idx]
        guard punct == "." || punct == ")" else {
            return nil
        }
        idx += 1
        let digitsAndPunct = String(chars[0..<idx])
        let spaceStart = idx
        while idx < chars.count && isHorizontalSpace(chars[idx]) {
            idx += 1
        }
        guard idx > spaceStart else {
            return nil
        }
        let remainder = String(chars[idx..<chars.count])
        guard normalizeApostrophes(remainder).lowercased() == normalizeApostrophes(expectedWord).lowercased() else {
            return nil
        }
        return (digitsAndPunct: digitsAndPunct, normalizedMarker: digitsAndPunct + " ")
    }

    private static func trimTrailingHorizontalSpaces(_ text: String) -> String {
        var out = text
        while let last = out.last, isHorizontalSpace(last) {
            out.removeLast()
        }
        return out
    }

    private static func isEmptyOrEndsWithNewlineIgnoringHorizontalSpaces(_ text: String) -> Bool {
        let trimmed = trimTrailingHorizontalSpaces(text)
        return trimmed.isEmpty || trimmed.last?.isNewline == true
    }

    private static func isTightlyAttachedAfterBlockText(_ beforeMarker: String) -> Bool {
        guard let last = beforeMarker.last,
              !last.isWhitespace,
              !last.isLetter,
              !last.isNumber else {
            return false
        }
        if last == "." {
            if let charBeforeDot = beforeMarker.dropLast().last, charBeforeDot.isASCII && charBeforeDot.isNumber {
                return false
            }
        }
        return true
    }

    private static func containsOnlyWord(_ word: String, in text: String) -> Bool {
        let normalizedText = normalizeApostrophes(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return normalizedText.lowercased() == normalizeApostrophes(word).lowercased()
    }

    private static func containsOnlyWordOrNumberedListItem(_ word: String, inLine line: String) -> Bool {
        if containsOnlyWord(word, in: line) {
            return true
        }
        let normLine = normalizeApostrophes(line)
        let normWord = normalizeApostrophes(word)
        guard normLine.lowercased().hasSuffix(normWord.lowercased()) else { return false }
        let beforeWord = String(line.dropLast(word.count))
        return isLineLeadingNumberedListPrefix(beforeWord, fullContextLength: line.count, sliceStartsAtDocumentZero: true)
    }

    private static func isStandaloneNumberedListMarker(_ token: String) -> Bool {
        guard let last = token.last, last == "." || last == ")" else { return false }
        let digits = token.dropLast()
        return !digits.isEmpty && digits.count <= 4 && digits.allSatisfy({ $0.isASCII && $0.isNumber })
    }

    private static func isLineLeadingNumberedListPrefix(
        _ prefixBeforeWord: String,
        fullContextLength: Int,
        sliceStartsAtDocumentZero: Bool
    ) -> Bool {
        let linePrefix: Substring
        if let lastNL = prefixBeforeWord.lastIndex(where: { $0.isNewline }) {
            linePrefix = prefixBeforeWord[prefixBeforeWord.index(after: lastNL)...]
        } else if sliceStartsAtDocumentZero || fullContextLength < 120 {
            linePrefix = prefixBeforeWord[...]
        } else {
            return false
        }

        let chars = Array(linePrefix)
        var idx = 0
        while idx < chars.count && isHorizontalSpace(chars[idx]) {
            idx += 1
        }
        let digitStart = idx
        while idx < chars.count && chars[idx].isASCII && chars[idx].isNumber {
            idx += 1
        }
        let digitCount = idx - digitStart
        guard digitCount >= 1 && digitCount <= 4, idx < chars.count else {
            return false
        }
        let marker = chars[idx]
        guard marker == "." || marker == ")" else {
            return false
        }
        idx += 1
        let spaceStart = idx
        while idx < chars.count && isHorizontalSpace(chars[idx]) {
            idx += 1
        }
        return idx == chars.count && idx > spaceStart
    }

    private static func hasSentenceEndingPunctuation(before prefixBeforeWord: String) -> Bool {
        // Must have at least one whitespace/newline separator after the sentence-ending punctuation
        guard let lastRaw = prefixBeforeWord.last, lastRaw.isWhitespace else {
            return false
        }

        // Strip trailing Unicode whitespace (including NBSP `\u{00A0}`) and closing quotes/brackets after `.`, `!`, `?`
        let closingWrappers: Set<Character> = ["\"", "'", "”", "’", ")", "]"]
        var endIdx = prefixBeforeWord.endIndex
        while endIdx > prefixBeforeWord.startIndex {
            let prevIdx = prefixBeforeWord.index(before: endIdx)
            let ch = prefixBeforeWord[prevIdx]
            if ch.isWhitespace || closingWrappers.contains(ch) {
                endIdx = prevIdx
            } else {
                break
            }
        }
        let strippedRight = prefixBeforeWord[..<endIdx]
        guard let punct = strippedRight.last, punct == "." || punct == "!" || punct == "?" else {
            return false
        }

        if punct == "!" || punct == "?" {
            return true
        }

        let beforeDot = String(strippedRight.dropLast())
        guard let charBeforeDot = beforeDot.last, charBeforeDot.isLetter else {
            return false
        }

        let tokenChars = Array(beforeDot)
        var tokenStart = tokenChars.count
        while tokenStart > 0 && (tokenChars[tokenStart - 1].isLetter || tokenChars[tokenStart - 1] == ".") {
            tokenStart -= 1
        }
        let prevToken = String(tokenChars[tokenStart..<tokenChars.count]).lowercased()
        if prevToken.count <= 1 || nonSentenceEndingAbbreviations.contains(prevToken) {
            return false
        }
        return true
    }

    public static func spaceAutoCorrection(
        forWord word: String,
        adaptiveStore: AdaptiveCorrectionStore? = nil,
        habitTracker: TypingHabitTracker?,
        historyStore: UserHistoryStore?,
        spellCompleter: SpellCompleting = SystemSpellCompleter()
    ) -> String? {
        let lower = word.lowercased()
        if adaptiveStore?.isMuted(lower) == true {
            return nil
        }
        if let customOrLearned = adaptiveStore?.customOrLearnedReplacement(for: lower) {
            return adaptCase(of: customOrLearned, toTyped: word)
        }
        if word == lower, let pinnedCased = historyStore?.customPinnedCasing(for: lower) {
            return pinnedCased
        }
        if !(word.count >= 2 && word.allSatisfy({ !$0.isLetter || $0.isUppercase })),
           let brand = canonicalBrandCasing[lower],
           brand != word {
            return brand
        }

        guard isEligibleTypoToken(word, minLength: 2, historyStore: historyStore) else {
            return nil
        }

        if let fixed = unambiguousTypos[lower] {
            return adaptCase(of: fixed, toTyped: word)
        }

        // Apple dictionary capitalization-only proper nouns ("monday" -> "Monday", "california" -> "California", "tokyo" -> "Tokyo", "chinese" -> "Chinese")
        if word == lower, let dictProper = dictionaryProperNounCasing(forLowerWord: lower) {
            return dictProper
        }

        if let personalFix = habitTracker?.learnedAutoFix(forMistype: lower),
           !developerSafeWords.contains(lower),
           !TypingHabitTracker.defaultValidEnglishWordCheck(lower) {
            return adaptCase(of: personalFix, toTyped: word)
        }

        // General single-edit QWERTY / transposition / missing-letter spell-checker fallback on Space
        // (catches any obvious slip like "similat" -> "similar", "aslo" -> "also", "checkign" -> "checking"
        // while keeping 3-letter acronyms, 4-letter non-transpositions like "vite"/"cuda", and proper nouns like "awesun" untouched!)
        if lower.count >= 4,
           !TypingHabitTracker.defaultValidEnglishWordCheck(lower),
           let spellFixed = conservativeSpaceSpellFix(forLowerWord: lower, spellCompleter: spellCompleter) {
            return adaptCase(of: spellFixed, toTyped: word)
        }

        return nil
    }

    private static let properNounLock = NSLock()
    private static var properNounCache: [String: String?] = [:]

    /// Detects unambiguous proper nouns in macOS `NSSpellChecker` that are invalid in lowercase (`monday`, `january`,
    /// `california`, `tokyo`, `london`, `chinese`, `microsoft`) while valid when TitleCased (`Monday`, `January`, `California`).
    /// Words with valid lowercase meanings (`may`, `march`, `apple`, `swift`) are automatically excluded.
    public static func dictionaryProperNounCasing(forLowerWord lower: String) -> String? {
        guard lower.count >= 4, lower.count <= 24,
              lower.allSatisfy({ $0.isASCII && $0.isLetter }),
              !cliCommandWords.contains(lower),
              !nonCapitalizedAcronyms.contains(lower),
              !developerSafeWords.contains(lower),
              !TypingHabitTracker.defaultValidEnglishWordCheck(lower) else {
            return nil
        }

        properNounLock.lock()
        if let cached = properNounCache[lower] {
            properNounLock.unlock()
            return cached
        }
        properNounLock.unlock()

        let cap = lower.prefix(1).uppercased() + lower.dropFirst()
        let miss = NSSpellChecker.shared.checkSpelling(
            of: cap,
            startingAt: 0,
            language: "en_US",
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        let resolved: String? = (miss.location == NSNotFound) ? cap : nil

        properNounLock.lock()
        if properNounCache.count >= 512 {
            properNounCache.removeAll(keepingCapacity: true)
        }
        properNounCache[lower] = resolved
        properNounLock.unlock()
        return resolved
    }

    /// Detects when an Accessibility text snapshot (`"Wha"`) is lagging 1+ keystrokes behind `rollingBuffer` (`"What"`),
    /// preventing Electron/Chromium async frame lag from drawing `"Wha" -> "tever"` directly over an already-painted `'t'`!
    public static func isSnapshotBehindRollingBuffer(
        snapshotText: String,
        isFallbackText: Bool,
        rollingBuffer: String
    ) -> Bool {
        if isFallbackText {
            return false
        }
        guard let lastLineSub = rollingBuffer.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last else {
            return false
        }
        let recentExpected = String(lastLineSub.suffix(12))
        guard !recentExpected.isEmpty else { return false }

        let normSnap = normalizeQuotes(snapshotText).lowercased()
        let normExpected = normalizeQuotes(recentExpected).lowercased()
        return !normSnap.hasSuffix(normExpected)
    }

    private static func normalizeQuotes(_ text: String) -> String {
        var out = text
        if out.contains("’") || out.contains("‘") {
            out = out.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        }
        if out.contains("“") || out.contains("”") {
            out = out.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        }
        return out
    }

    private static let qwertyNeighbors: [Character: Set<Character>] = [
        "q": ["w", "a"],
        "w": ["q", "e", "a", "s"],
        "e": ["w", "r", "s", "d"],
        "r": ["e", "t", "d", "f"],
        "t": ["r", "y", "f", "g"],
        "y": ["t", "u", "g", "h"],
        "u": ["y", "i", "h", "j"],
        "i": ["u", "o", "j", "k"],
        "o": ["i", "p", "k", "l"],
        "p": ["o", "l"],
        "a": ["q", "w", "s", "z"],
        "s": ["w", "e", "a", "d", "z", "x"],
        "d": ["e", "r", "s", "f", "x", "c"],
        "f": ["r", "t", "d", "g", "c", "v"],
        "g": ["t", "y", "f", "h", "v", "b"],
        "h": ["y", "u", "g", "j", "b", "n"],
        "j": ["u", "i", "h", "k", "n", "m"],
        "k": ["i", "o", "j", "l", "m"],
        "l": ["o", "p", "k"],
        "z": ["a", "s", "x"],
        "x": ["z", "s", "d", "c"],
        "c": ["x", "d", "f", "v"],
        "v": ["c", "f", "g", "b"],
        "b": ["v", "g", "h", "n"],
        "n": ["b", "h", "j", "m"],
        "m": ["n", "j", "k"]
    ]

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
    private static let spaceSpellLock = NSLock()
    private static var spaceSpellCache: [String: String?] = [:]

    private static func conservativeSpaceSpellFix(
        forLowerWord lower: String,
        spellCompleter: SpellCompleting
    ) -> String? {
        let isSystem = spellCompleter is SystemSpellCompleter
        if isSystem {
            spaceSpellLock.lock()
            if let hit = spaceSpellCache[lower] {
                spaceSpellLock.unlock()
                return hit
            }
            spaceSpellLock.unlock()
        }

        let resolved: String? = {
            guard let raw = spellCompleter.correction(forWord: lower),
                  let first = raw.first,
                  first.isLowercase, // ignore proper-noun suggestions ("Verizon", "Oslo")
                  raw.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                return nil
            }
            let cand = raw.lowercased()
            guard cand != lower, isSafeSingleEditSpaceTypo(typed: lower, candidate: cand) else {
                return nil
            }
            return cand
        }()

        if isSystem {
            spaceSpellLock.lock()
            if spaceSpellCache.count >= 512 {
                spaceSpellCache.removeAll(keepingCapacity: true)
            }
            spaceSpellCache[lower] = resolved
            spaceSpellLock.unlock()
        }
        return resolved
    }

    public static func isSafeSingleEditSpaceTypo(typed: String, candidate: String) -> Bool {
        let ac = Array(typed)
        let bc = Array(candidate)

        // 1. Single adjacent transposition on >= 4-letter words ("aslo" -> "also", "liek" -> "like", "checkign" -> "checking")
        if ac.count == bc.count, ac.count >= 4 {
            var diffs: [Int] = []
            for i in 0..<ac.count where ac[i] != bc[i] {
                diffs.append(i)
                if diffs.count > 2 { break }
            }
            if diffs.count == 2,
               diffs[1] == diffs[0] + 1,
               ac[diffs[0]] == bc[diffs[1]],
               ac[diffs[1]] == bc[diffs[0]] {
                return true
            }
        }

        // 2. >= 5-letter single QWERTY neighbor substitution ("similat" -> "similar", "hellp" -> "hello")
        //    or >= 6-letter vowel slip ("sentance" -> "sentence"), keeping the first letter anchored!
        guard ac.count >= 5, bc.count >= 5, ac.first == bc.first else {
            return false
        }

        if ac.count == bc.count {
            var diffIdx: Int? = nil
            for i in 1..<ac.count where ac[i] != bc[i] {
                if diffIdx != nil { return false }
                diffIdx = i
            }
            guard let idx = diffIdx else { return false }
            if qwertyNeighbors[ac[idx]]?.contains(bc[idx]) == true {
                return true
            }
            if ac.count >= 6 && vowels.contains(ac[idx]) && vowels.contains(bc[idx]) {
                return true
            }
            return false
        }

        // 3. >= 5-letter single missing or extra repeated/interior character ("problms" -> "problems", "optmize" -> "optimize")
        if abs(ac.count - bc.count) == 1 {
            let shorter = ac.count < bc.count ? ac : bc
            let longer = ac.count < bc.count ? bc : ac
            var i = 0, j = 0, skipped = false
            while i < shorter.count && j < longer.count {
                if shorter[i] == longer[j] {
                    i += 1
                    j += 1
                } else if !skipped {
                    skipped = true
                    j += 1
                } else {
                    return false
                }
            }
            return true
        }

        return false
    }

    /// Inline `Tab` ghost fix (`→ word`) used when normal prefix completion returns zero matches.
    public static func inlineTabCorrection(
        forPrefix prefix: String,
        adaptiveStore: AdaptiveCorrectionStore? = nil,
        habitTracker: TypingHabitTracker?,
        historyStore: UserHistoryStore?,
        spellCompleter: SpellCompleting
    ) -> String? {
        let lower = prefix.lowercased()
        if let customOrLearned = adaptiveStore?.inlineCandidate(forTypedPrefix: lower) {
            return adaptCase(of: customOrLearned, toTyped: prefix)
        }
        guard adaptiveStore?.isMuted(lower) != true else { return nil }
        if prefix == lower, let brand = canonicalBrandCasing[lower] {
            return brand
        }
        guard isEligibleTypoToken(prefix, minLength: 2, historyStore: historyStore) else {
            return nil
        }

        // 1. Exact unambiguous typo / contraction match ("im" -> "I'm", "teh" -> "the", "definately" -> "definitely")
        if let exact = unambiguousTypos[lower] {
            return adaptCase(of: exact, toTyped: prefix)
        }

        // 2. Personal typo traps (`count >= 1`)
        if let personal = habitTracker?.matchingTypoTrapCorrection(forTypedPrefix: lower) {
            return adaptCase(of: personal, toTyped: prefix)
        }

        // 3. Prefix (`>= 4` chars) of an unambiguous typo ("definatel" -> "definitely", "reciev" -> "receive")
        if lower.count >= 4 {
            let matches = unambiguousTypos.filter { $0.key.hasPrefix(lower) }
            let distinctTargets = Set(matches.values)
            if distinctTargets.count == 1, let singleTarget = distinctTargets.first, singleTarget != lower {
                return adaptCase(of: singleTarget, toTyped: prefix)
            }
        }

        // 4. Conservative spell-checker fallback (`>= 4`-letter adjacent transpositions like "aslo" -> "also",
        //    or `>= 5`-letter misspelled tokens with Damerau-Levenshtein <= 2)
        if lower.count >= 4,
           let raw = spellCompleter.correction(forWord: lower),
           let first = raw.first,
           first.isLowercase,
           raw.allSatisfy({ ($0.isASCII && $0.isLetter) || $0 == "'" }) {
            let candidate = raw.lowercased()
            if lower.count == 4 {
                if isSafeSingleEditSpaceTypo(typed: lower, candidate: candidate) {
                    return adaptCase(of: candidate, toTyped: prefix)
                }
            } else if candidate.count >= 4,
                      candidate != lower,
                      candidate.first == lower.first,
                      damerauLevenshtein(lower, candidate) <= 2 {
                return adaptCase(of: candidate, toTyped: prefix)
            }
        }

        return nil
    }

    public struct BoundaryTransformTarget: Equatable, Sendable {
        public let word: String
        public let bufferUpToWord: String
        public let existingTrailingDot: Bool
        public let outputDelimiter: String
    }

    /// Resolves whether a typed delimiter (`Space`, `,`, `!`, `?`, `;`, or `Space` right after `<word>.`)
    /// completes a standalone prose word eligible for auto-correction / sentence-start capitalization.
    /// Keeps filenames/domains (`notes.md`, `github.com`, `e.g.`) untouched by waiting for `Space` after `.`.
    public static func extractPunctuationOrSpaceTarget(
        rollingBuffer: String,
        typedDelimiter: String
    ) -> BoundaryTransformTarget? {
        if typedDelimiter == " " {
            if let word = extractTrailingStandaloneWord(from: rollingBuffer) {
                return BoundaryTransformTarget(
                    word: word,
                    bufferUpToWord: rollingBuffer,
                    existingTrailingDot: false,
                    outputDelimiter: " "
                )
            }
            if rollingBuffer.hasSuffix("."), !rollingBuffer.hasSuffix("..") {
                let withoutDot = String(rollingBuffer.dropLast())
                if let word = extractTrailingStandaloneWord(from: withoutDot) {
                    return BoundaryTransformTarget(
                        word: word,
                        bufferUpToWord: withoutDot,
                        existingTrailingDot: true,
                        outputDelimiter: " "
                    )
                }
            }
            return nil
        }

        if typedDelimiter == "," || typedDelimiter == "!" || typedDelimiter == "?" || typedDelimiter == ";" {
            if let word = extractTrailingStandaloneWord(from: rollingBuffer) {
                return BoundaryTransformTarget(
                    word: word,
                    bufferUpToWord: rollingBuffer,
                    existingTrailingDot: false,
                    outputDelimiter: typedDelimiter
                )
            }
        }
        return nil
    }

    public static func extractTrailingStandaloneWord(from buffer: String) -> String? {
        guard !buffer.isEmpty else { return nil }
        let chars = Array(buffer)
        var start = chars.count
        while start > 0 {
            let ch = chars[start - 1]
            if (ch.isASCII && ch.isLetter) || (isApostrophe(ch) && start >= 2 && chars[start - 2].isASCII && chars[start - 2].isLetter) {
                start -= 1
            } else {
                break
            }
        }
        guard start < chars.count else { return nil }
        if start > 0 {
            let boundary = chars[start - 1]
            let allowedLeading: Set<Character> = [" ", "\t", "\u{00A0}", "\u{202F}", "\u{2007}", "\n", "\r", "(", "[", "{", "\"", "'", "“", "‘"]
            guard allowedLeading.contains(boundary) else { return nil }
        }
        return String(chars[start..<chars.count])
    }

    private static func isEligibleTypoToken(_ token: String, minLength: Int, historyStore: UserHistoryStore?) -> Bool {
        guard token.count >= minLength, token.count <= 24 else { return false }
        guard token.allSatisfy({ ($0.isASCII && $0.isLetter) || isApostrophe($0) }) else { return false }

        let lower = normalizeApostrophes(token).lowercased()
        guard !hasProtectedCasing(token, lower: lower) else { return false }

        if developerSafeWords.contains(lower) || TechLexicon.wordSet.contains(lower) {
            return false
        }
        if let historyStore, historyStore.count(for: lower) > 0 {
            return false
        }
        return true
    }

    private static func hasProtectedCasing(_ token: String, lower: String) -> Bool {
        (token.dropFirst().contains(where: \.isUppercase)
            || (token.count >= 2 && token.allSatisfy({ !$0.isLetter || $0.isUppercase })))
            && !isCanonicalBrandTypo(lower)
    }

    private static func isCanonicalBrandTypo(_ lower: String) -> Bool {
        guard let replacement = unambiguousTypos[lower] else { return false }
        return canonicalBrandCasing[replacement.lowercased()] == replacement
    }

    public static func adaptCase(of target: String, toTyped typed: String) -> String {
        // Preserve canonical capitalization like "I'm" / "I've" / "I'll"
        if target.hasPrefix("I'") || target == "I" {
            return target
        }
        if let first = typed.first, first.isUppercase, typed.dropFirst().allSatisfy({ !$0.isLetter || $0.isLowercase }) {
            return target.prefix(1).uppercased() + target.dropFirst()
        }
        return target
    }

    public static func damerauLevenshtein(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        let n = a.count
        let m = b.count
        if n == 0 { return m }
        if m == 0 { return n }
        if abs(n - m) > 3 { return abs(n - m) }

        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }

        for i in 1...n {
            for j in 1...m {
                let cost = (a[i - 1] == b[j - 1]) ? 0 : 1
                d[i][j] = min(
                    d[i - 1][j] + 1,
                    min(d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                )
                if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[n][m]
    }
}
