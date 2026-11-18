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

public final class UserHistoryStore {
    private static let customScoreSentinel = 10_000

    private let fileURL: URL
    private let customURL: URL
    private let queue = DispatchQueue(label: "app.wordtail.macos.history", qos: .utility)
    private var counts: [String: Int] = [:]
    private var customWords: Set<String> = [] // preserves original case if desired, keyed lowercase in lookups
    private var customCasing: [String: String] = [:]

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            self.customURL = fileURL.deletingLastPathComponent().appendingPathComponent("custom_words.json")
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("WordTail", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("accepted_words.json")
            self.customURL = dir.appendingPathComponent("custom_words.json")
        }
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
    }

    public func count(for word: String) -> Int {
        let lower = word.lowercased()
        return queue.sync {
            let base = counts[lower, default: 0]
            return customWords.contains(lower) ? (Self.customScoreSentinel + base) : base
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

    public func removeWord(_ word: String) {
        let lower = word.lowercased()
        queue.sync {
            counts.removeValue(forKey: lower)
            customWords.remove(lower)
            customCasing.removeValue(forKey: lower)
            persistCountsSnapshot(counts)
            persistCustomSnapshot(Array(customCasing.values).sorted())
        }
    }

    public func clearAll() {
        queue.sync {
            counts.removeAll()
            customWords.removeAll()
            customCasing.removeAll()
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: customURL)
        }
    }

    public func matchingWords(forPrefix prefix: String) -> [(word: String, count: Int)] {
        let lowerPrefix = prefix.lowercased()
        return queue.sync {
            let allKeys = Set(counts.keys).union(customWords)
            return allKeys.compactMap { key in
                guard key.hasPrefix(lowerPrefix), key.count > lowerPrefix.count else {
                    return nil
                }
                let score = (customWords.contains(key) ? Self.customScoreSentinel : 0) + counts[key, default: 0]
                guard score > 0 else { return nil }
                return (customCasing[key] ?? key, score)
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.word < rhs.word
            }
        }
    }

    public func recordAcceptance(of word: String, persistAsync: Bool = true) {
        let key = word.lowercased()
        guard key.count >= 3 else { return }

        if persistAsync {
            queue.async {
                self.counts[key, default: 0] += 1
                self.persistCountsSnapshot(self.counts)
            }
        } else {
            queue.sync {
                self.counts[key, default: 0] += 1
                self.persistCountsSnapshot(self.counts)
            }
        }
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
}
