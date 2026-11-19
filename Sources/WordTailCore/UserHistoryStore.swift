import Foundation

public struct VocabularyEntry: Identifiable, Equatable {
    public var id: String { word }
    public let word: String
    public let count: Int
    public let isCustom: Bool

    public init(word: String, count: Int, isCustom: Bool) {
        self.word = word
        self.count = count
        self.isCustom = isCustom
    }
}

public struct BigramHabitEntry: Identifiable, Equatable {
    public var id: String { "\(previousWord)->\(word)" }
    public let previousWord: String
    public let word: String
    public let count: Int

    public init(previousWord: String, word: String, count: Int) {
        self.previousWord = previousWord
        self.word = word
        self.count = count
    }
}

public final class UserHistoryStore {
    private static let customScoreSentinel = 100_000
    private static let bigramWeight = 25
    private static let appAffinityWeight = 6
    private static let globalAcceptWeight = 3

    private let fileURL: URL
    private let customURL: URL
    private let bigramsURL: URL
    private let appVocabURL: URL

    private let queue = DispatchQueue(label: "app.wordtail.macos.history", qos: .utility)
    private var counts: [String: Int] = [:]
    private var customWords: Set<String> = []
    private var customCasing: [String: String] = [:]
    private var bigrams: [String: [String: Int]] = [:]
    private var appVocabulary: [String: [String: Int]] = [:]

    public init(fileURL: URL? = nil) {
        let dir: URL
        if let fileURL {
            dir = fileURL.deletingLastPathComponent()
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = appSupport.appendingPathComponent("WordTail", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("accepted_words.json")
        }
        self.customURL = dir.appendingPathComponent("custom_words.json")
        self.bigramsURL = dir.appendingPathComponent("word_bigrams.json")
        self.appVocabURL = dir.appendingPathComponent("app_vocabulary.json")
        loadSynchronously()
    }

    private func loadSynchronously() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            counts = decoded
        }
        if let customData = try? Data(contentsOf: customURL),
           let list = try? JSONDecoder().decode([String].self, from: customData) {
            for raw in list {
                let lower = raw.lowercased()
                customWords.insert(lower)
                customCasing[lower] = raw
            }
        }
        if let bigramData = try? Data(contentsOf: bigramsURL),
           let decoded = try? JSONDecoder().decode([String: [String: Int]].self, from: bigramData) {
            bigrams = decoded
        }
        if let appData = try? Data(contentsOf: appVocabURL),
           let decoded = try? JSONDecoder().decode([String: [String: Int]].self, from: appData) {
            appVocabulary = decoded
        }
    }

    public func count(for word: String) -> Int {
        let lower = word.lowercased()
        return queue.sync {
            let base = counts[lower, default: 0]
            return customWords.contains(lower) ? (Self.customScoreSentinel + base) : base
        }
    }

    /// Returns the user's pinned casing when a custom word was added with intentional capitalization (e.g. "Tailscale", "WordTail").
    public func customPinnedCasing(for word: String) -> String? {
        let lower = word.lowercased()
        return queue.sync {
            guard customWords.contains(lower), let cased = customCasing[lower], cased != lower else {
                return nil
            }
            return cased
        }
    }

    /// Computes contextual relevance combining pinned words, personal 2-word bigrams, per-app vocabulary, and global frequency.
    public func contextualScore(
        for word: String,
        previousWord: String? = nil,
        bundleID: String? = nil
    ) -> Int {
        let lower = word.lowercased()
        let prevLower = previousWord?.lowercased()
        return queue.sync {
            var score = counts[lower, default: 0] * Self.globalAcceptWeight
            if customWords.contains(lower) {
                score += Self.customScoreSentinel
            }
            if let prevLower, let nextMap = bigrams[prevLower], let pairCount = nextMap[lower] {
                score += pairCount * Self.bigramWeight
            }
            if let bundleID, let appMap = appVocabulary[bundleID], let appCount = appMap[lower] {
                score += appCount * Self.appAffinityWeight
            }
            return score
        }
    }

    public var learnedWordsCount: Int {
        queue.sync {
            Set(counts.keys).union(customWords).count
        }
    }

    public func allEntries() -> [VocabularyEntry] {
        queue.sync {
            let allKeys = Set(counts.keys).union(customWords)
            return allKeys.map { key in
                let isCustom = customWords.contains(key)
                let display = customCasing[key] ?? key
                return VocabularyEntry(
                    word: display,
                    count: counts[key, default: 0],
                    isCustom: isCustom
                )
            }
            .sorted { lhs, rhs in
                if lhs.isCustom != rhs.isCustom { return lhs.isCustom && !rhs.isCustom }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.word.localizedCaseInsensitiveCompare(rhs.word) == .orderedAscending
            }
        }
    }

    public func topBigrams(limit: Int = 10) -> [BigramHabitEntry] {
        queue.sync {
            var flattened: [BigramHabitEntry] = []
            for (prev, nextDict) in bigrams {
                for (next, cnt) in nextDict where cnt > 0 {
                    flattened.append(BigramHabitEntry(previousWord: prev, word: next, count: cnt))
                }
            }
            return Array(flattened.sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                if lhs.previousWord != rhs.previousWord { return lhs.previousWord < rhs.previousWord }
                return lhs.word < rhs.word
            }.prefix(limit))
        }
    }

    @discardableResult
    public func addCustomWord(_ rawWord: String, persistAsync: Bool = true) -> Bool {
        let trimmed = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3,
              trimmed.allSatisfy({ ($0.isASCII && $0.isLetter) || $0 == "'" }) else {
            return false
        }
        let lower = trimmed.lowercased()

        let work = {
            self.customWords.insert(lower)
            self.customCasing[lower] = trimmed
            self.persistCustomSnapshot(Array(self.customCasing.values).sorted())
        }

        if persistAsync {
            queue.async(execute: work)
        } else {
            queue.sync(execute: work)
        }
        return true
    }

    public func isCustomWord(_ word: String) -> Bool {
        let lower = word.lowercased()
        return queue.sync { customWords.contains(lower) }
    }

    public func removeWord(_ word: String) {
        let lower = word.lowercased()
        queue.sync {
            counts.removeValue(forKey: lower)
            customWords.remove(lower)
            customCasing.removeValue(forKey: lower)
            bigrams.removeValue(forKey: lower)
            for key in Array(bigrams.keys) {
                bigrams[key]?.removeValue(forKey: lower)
                if bigrams[key]?.isEmpty == true {
                    bigrams.removeValue(forKey: key)
                }
            }
            for bid in Array(appVocabulary.keys) {
                appVocabulary[bid]?.removeValue(forKey: lower)
            }
            persistCountsSnapshot(counts)
            persistCustomSnapshot(Array(customCasing.values).sorted())
            persistBigramsSnapshot(bigrams)
            persistAppVocabSnapshot(appVocabulary)
        }
    }

    public func clearAll() {
        queue.sync {
            counts.removeAll()
            customWords.removeAll()
            customCasing.removeAll()
            bigrams.removeAll()
            appVocabulary.removeAll()
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: customURL)
            try? FileManager.default.removeItem(at: bigramsURL)
            try? FileManager.default.removeItem(at: appVocabURL)
        }
    }

    public func clearContextualHabitsOnly() {
        queue.sync {
            bigrams.removeAll()
            appVocabulary.removeAll()
            try? FileManager.default.removeItem(at: bigramsURL)
            try? FileManager.default.removeItem(at: appVocabURL)
        }
    }

    public func matchingWords(
        forPrefix prefix: String,
        previousWord: String? = nil,
        bundleID: String? = nil
    ) -> [(word: String, score: Int)] {
        let lowerPrefix = prefix.lowercased()
        let prevLower = previousWord?.lowercased()
        return queue.sync {
            var candidateKeys = Set(counts.keys).union(customWords)
            if let prevLower, let nextMap = bigrams[prevLower] {
                candidateKeys.formUnion(nextMap.keys)
            }
            if let bundleID, let appMap = appVocabulary[bundleID] {
                candidateKeys.formUnion(appMap.keys)
            }

            return candidateKeys.compactMap { key in
                guard key.hasPrefix(lowerPrefix), key.count > lowerPrefix.count else {
                    return nil
                }
                var score = counts[key, default: 0] * Self.globalAcceptWeight
                if customWords.contains(key) {
                    score += Self.customScoreSentinel
                }
                if let prevLower, let pairCount = bigrams[prevLower]?[key] {
                    score += pairCount * Self.bigramWeight
                }
                if let bundleID, let appCount = appVocabulary[bundleID]?[key] {
                    score += appCount * Self.appAffinityWeight
                }
                guard score > 0 else { return nil }
                return (customCasing[key] ?? key, score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.word < rhs.word
            }
        }
    }

    public func recordAcceptance(
        of word: String,
        previousWord: String? = nil,
        bundleID: String? = nil,
        persistAsync: Bool = true
    ) {
        let key = word.lowercased()
        guard key.count >= 3 else { return }
        let prevKey = previousWord?.lowercased()

        let work = {
            self.counts[key, default: 0] += 1
            if let prevKey, prevKey.count >= 2, prevKey != key {
                self.recordBigramLocked(previous: prevKey, word: key)
            }
            if let bundleID, !bundleID.isEmpty {
                self.recordAppWordLocked(bundleID: bundleID, word: key)
            }
            self.persistCountsSnapshot(self.counts)
            self.persistBigramsSnapshot(self.bigrams)
            self.persistAppVocabSnapshot(self.appVocabulary)
        }

        if persistAsync {
            queue.async(execute: work)
        } else {
            queue.sync(execute: work)
        }
    }

    /// Passively learns 2-word collocations and per-app vocabulary from naturally completed English words
    /// without inflating explicit `Tab`-accepted word counts.
    public func recordNaturalWordUsage(
        word: String,
        previousWord: String?,
        bundleID: String?,
        persistAsync: Bool = true
    ) {
        let key = word.lowercased()
        guard key.count >= 3 else { return }
        let prevKey = previousWord?.lowercased()
        guard (prevKey != nil && prevKey!.count >= 2) || (bundleID != nil && !bundleID!.isEmpty) else {
            return
        }

        let work = {
            var changedBigrams = false
            var changedApps = false
            if let prevKey, prevKey.count >= 2, prevKey != key {
                self.recordBigramLocked(previous: prevKey, word: key)
                changedBigrams = true
            }
            if let bundleID, !bundleID.isEmpty {
                self.recordAppWordLocked(bundleID: bundleID, word: key)
                changedApps = true
            }
            if changedBigrams {
                self.persistBigramsSnapshot(self.bigrams)
            }
            if changedApps {
                self.persistAppVocabSnapshot(self.appVocabulary)
            }
        }

        if persistAsync {
            queue.async(execute: work)
        } else {
            queue.sync(execute: work)
        }
    }

    private func recordBigramLocked(previous: String, word: String) {
        var bucket = bigrams[previous] ?? [:]
        bucket[word, default: 0] += 1
        if bucket.count > 10 {
            let trimmed = bucket.sorted { $0.value > $1.value }.prefix(8)
            bucket = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key, $0.value) })
        }
        bigrams[previous] = bucket
        if bigrams.count > 650 {
            let topPrev = bigrams
                .map { (key: $0.key, total: $0.value.values.reduce(0, +)) }
                .sorted { $0.total > $1.total }
                .prefix(500)
            let keepKeys = Set(topPrev.map(\.key))
            bigrams = bigrams.filter { keepKeys.contains($0.key) }
        }
    }

    private func recordAppWordLocked(bundleID: String, word: String) {
        var bucket = appVocabulary[bundleID] ?? [:]
        bucket[word, default: 0] += 1
        if bucket.count > 180 {
            let trimmed = bucket.sorted { $0.value > $1.value }.prefix(140)
            bucket = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key, $0.value) })
        }
        appVocabulary[bundleID] = bucket
    }

    private func persistCountsSnapshot(_ snapshot: [String: Int]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func persistCustomSnapshot(_ snapshot: [String]) {
        let dir = customURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: customURL, options: .atomic)
        }
    }

    private func persistBigramsSnapshot(_ snapshot: [String: [String: Int]]) {
        let dir = bigramsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: bigramsURL, options: .atomic)
        }
    }

    private func persistAppVocabSnapshot(_ snapshot: [String: [String: Int]]) {
        let dir = appVocabURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: appVocabURL, options: .atomic)
        }
    }
}
