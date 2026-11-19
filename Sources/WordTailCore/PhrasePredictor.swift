import Foundation

public enum PhraseRuleSource: String, Codable, Equatable, Sendable {
    case custom = "Pinned"
    case learned = "Learned"
}

public struct PhraseEntry: Identifiable, Equatable, Sendable {
    public var id: String { "\(source.rawValue):\(anchor)->\(continuation)" }
    public let anchor: String
    public let continuation: String
    public let count: Int
    public let source: PhraseRuleSource

    public var fullPhrase: String { "\(anchor) \(continuation)" }

    public init(anchor: String, continuation: String, count: Int, source: PhraseRuleSource) {
        self.anchor = anchor
        self.continuation = continuation
        self.count = count
        self.source = source
    }
}

/// Conservative, zero-LLM multi-word phrase predictor combining:
/// 1. Curated high-certainty English idioms (2–3 anchor words required, never generic prepositions like "in the").
/// 2. Privacy-preserving learned personal n-grams (one-off sequences stay in RAM only; persists at >= 2x, activates at >= 3x & >= 50% consistency).
/// 3. User-pinned custom phrases.
public final class PhrasePredictor {
    public static let graduationCount = 3
    public static let graduationConfidence = 0.50

    /// Generic function-word pairs that are too ambiguous on their own to auto-suggest a multi-word learned phrase
    /// unless 3 anchor words lock in the context.
    private static let genericTwoWordAnchors: Set<String> = [
        "in the", "of the", "to the", "on the", "for the", "with the", "at the", "from the", "by the",
        "in a", "of a", "to a", "on a", "for a", "with a", "is a", "was a", "as a",
        "and the", "and a", "and i", "but i", "so i", "if i", "when i", "that i",
        "it is", "it was", "this is", "that is", "there is", "there are", "we can", "you can", "i can",
        "i have", "i am", "i was", "i will", "he is", "she is", "they are", "we are"
    ]

    /// Curated high-certainty English idioms & conversational connectors keyed by lowercase 2–3 word anchors.
    public static let builtInIdioms: [String: [String]] = [
        // Classic multi-word idioms & framing phrases
        "as far": ["as I'm concerned", "as I know", "as possible"],
        "as far as": ["I'm concerned", "I know", "possible"],
        "as far as i'm": ["concerned"],
        "as far as im": ["concerned"],
        "as far as i": ["know", "can tell"],
        "on the other": ["hand"],
        "at the same": ["time"],
        "at the end of": ["the day"],
        "in the middle": ["of"],
        "in the first": ["place"],
        "in the long": ["run", "term"],
        "in the short": ["term"],
        "in the meantime": [],
        "for the most": ["part"],
        "for the time": ["being"],
        "as a matter": ["of fact"],
        "as a matter of": ["fact"],
        "as a result": ["of"],
        "in order": ["to"],
        "in terms": ["of"],
        "in addition": ["to"],
        "in spite": ["of"],
        "in front": ["of"],
        "on top": ["of"],
        "out of the": ["box"],
        "under the": ["hood"],
        "behind the": ["scenes"],
        "state of the": ["art"],
        "point of": ["view"],
        "rule of": ["thumb"],
        "pros and": ["cons"],
        "trial and": ["error"],
        "step by": ["step"],
        "side by": ["side"],
        "one by": ["one"],
        "little by": ["little"],
        "more and": ["more"],
        "more or": ["less"],
        "sooner or": ["later"],
        "whether or": ["not"],
        "first of": ["all"],
        "last but": ["not least"],
        "last but not": ["least"],
        "all of a": ["sudden"],
        "from time": ["to time"],
        "from time to": ["time"],
        "once in a": ["while"],
        "as soon": ["as possible"],
        "as soon as": ["possible"],
        "as well": ["as"],
        "as long": ["as"],
        "with respect": ["to"],
        "with regard": ["to"],
        "when it comes": ["to"],
        "keep in": ["mind"],
        "bear in": ["mind"],
        "make sure": ["that", "to"],
        "to be": ["honest", "fair", "clear"],
        "by the": ["way"],
        "so far": ["so good"],

        // High-utility work, engineering & async communication phrases
        "looking forward": ["to", "to hearing from you", "to it"],
        "looking forward to": ["hearing from you", "it"],
        "feel free": ["to"],
        "feel free to": ["let me know", "reach out"],
        "let me": ["know", "check"],
        "let me know": ["if you", "what you think"],
        "please let me": ["know"],
        "thank you": ["so much", "for"],
        "thanks for": ["letting me know", "your help"],
        "take a": ["look", "look at"],
        "take a look": ["at"],
        "one more": ["thing"],
        "makes sense": ["to me"],
        "sounds good": ["to me"],
        "works for": ["me"],
        "happy to": ["help"],
        "i'd like": ["to"],
        "i would like": ["to"],
        "supposed to": ["be"],
        "turns out": ["that"]
    ]

    private struct PersistedData: Codable {
        var customPhrases: [String] = []
        var anchorTotals: [String: Int] = [:]
        var continuations: [String: [String: Int]] = [:] // only count >= 2 persisted for privacy!
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "app.wordtail.macos.phrases", qos: .utility)

    private var persisted = PersistedData()
    // Ephemeral RAM-only probation table for first-time sequences so one-off private sentences NEVER hit disk!
    private var probationAnchorTotals: [String: Int] = [:]
    private var probationContinuations: [String: [String: Int]] = [:]
    private var sentenceWindow: [String] = []

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("WordTail", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("learned_phrases.json")
        }
        loadSynchronously()
    }

    private func loadSynchronously() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PersistedData.self, from: data) else {
            return
        }
        persisted = decoded
    }

    // MARK: - Queries

    /// Predicts conservative multi-word continuations right after `Space` (`"as far "` -> `["as I'm concerned", ...]`).
    public func predictAfterSpace(precedingWords rawWords: [String], limit: Int = 3) -> [String] {
        guard rawWords.count >= 2, limit > 0 else { return [] }
        let lowerWords = rawWords.map { $0.lowercased() }
        let last2 = lowerWords.suffix(2).joined(separator: " ")
        let last3 = lowerWords.count >= 3 ? lowerWords.suffix(3).joined(separator: " ") : nil

        return queue.sync {
            var seen = Set<String>()
            var results: [String] = []

            func appendUnique(_ list: [String]) {
                for item in list where !item.isEmpty {
                    let key = item.lowercased()
                    if seen.insert(key).inserted {
                        results.append(item)
                    }
                }
            }

            // 1. User-pinned custom phrases (3-word anchor first, then 2-word anchor)
            if let last3 {
                appendUnique(matchingCustomContinuationsLocked(forAnchor: last3))
            }
            appendUnique(matchingCustomContinuationsLocked(forAnchor: last2))

            // 2. Self-learned personal phrases (`count >= 3` & `confidence >= 50%`)
            if let last3 {
                appendUnique(graduatedContinuationsLocked(forAnchor: last3, allowGeneric2Word: true))
            }
            appendUnique(graduatedContinuationsLocked(forAnchor: last2, allowGeneric2Word: false))

            // 3. Curated built-in English idioms (3-word anchor first, then 2-word anchor)
            if let last3, let idioms3 = Self.builtInIdioms[last3] {
                appendUnique(idioms3)
            }
            if let idioms2 = Self.builtInIdioms[last2] {
                appendUnique(idioms2)
            }

            return Array(results.prefix(limit))
        }
    }

    /// Predicts multi-word phrase continuations while mid-word (`"as far a"` -> `"as I'm concerned"`, `"as far as I'm conc"` -> `"concerned"`).
    public func predictMidWord(
        precedingWords rawWords: [String],
        currentPrefix: String,
        limit: Int = 2
    ) -> [String] {
        guard rawWords.count >= 2, !currentPrefix.isEmpty, limit > 0 else { return [] }
        let candidates = predictAfterSpace(precedingWords: rawWords, limit: 6)
        let lowerPrefix = currentPrefix.lowercased()
        var out: [String] = []
        for phrase in candidates {
            if phrase.lowercased().hasPrefix(lowerPrefix), phrase.count > currentPrefix.count + 1 {
                let adapted = currentPrefix + phrase.dropFirst(currentPrefix.count)
                out.append(adapted)
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// Extracts the first word (+ trailing space if more words remain) for partial `⌥ →` acceptance!
    /// Example: `"as I'm concerned"` -> `(acceptedChunk: "as ", remainingPhrase: "I'm concerned")`.
    public static func splitFirstWord(of phrase: String) -> (acceptedChunk: String, remainingPhrase: String?) {
        let trimmed = phrase.trimmingCharacters(in: .whitespaces)
        guard let spaceIdx = trimmed.firstIndex(of: " ") else {
            return (trimmed, nil)
        }
        let firstWord = String(trimmed[..<spaceIdx])
        let rest = String(trimmed[trimmed.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
        return (firstWord + " ", rest.isEmpty ? nil : rest)
    }

    // MARK: - Passive Sentence Learning & Custom Phrases

    public func resetSentenceWindow() {
        queue.async {
            self.sentenceWindow.removeAll(keepingCapacity: true)
        }
    }

    /// Records a completed word within the active sentence (called when a valid word finishes with a space,
    /// resetting automatically if `endedSentence` is true due to `.`, `!`, `?`, or `\n`).
    public func observeCompletedWord(_ rawWord: String, endedSentence: Bool, persistAsync: Bool = true) {
        let clean = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 1, clean.count <= 24,
              clean.allSatisfy({ ($0.isASCII && $0.isLetter) || $0 == "'" }) else {
            resetSentenceWindow()
            return
        }

        // Preserve canonical casing for "I" / "I'm" / "I've" / "I'll" / "I'd", lowercase normal words
        let normalized: String
        let lower = clean.lowercased()
        if lower == "i" {
            normalized = "I"
        } else if lower.hasPrefix("i'") {
            normalized = "I" + clean.dropFirst()
        } else {
            normalized = lower
        }

        let work = {
            self.sentenceWindow.append(normalized)
            if self.sentenceWindow.count > 6 {
                self.sentenceWindow.removeFirst(self.sentenceWindow.count - 6)
            }

            let n = self.sentenceWindow.count
            var promotedToDisk = false

            // Record 2-word anchor -> 1-word & 2-word continuations, plus 3-word anchor -> 1-word & 2-word continuations
            if n >= 3 {
                let anchor2 = self.sentenceWindow[(n - 3)..<(n - 1)].map { $0.lowercased() }.joined(separator: " ")
                let tail1 = self.sentenceWindow[n - 1]
                if self.incrementNGramLocked(anchor: anchor2, continuation: tail1) {
                    promotedToDisk = true
                }
            }
            if n >= 4 {
                let anchor2For2 = self.sentenceWindow[(n - 4)..<(n - 2)].map { $0.lowercased() }.joined(separator: " ")
                let tail2 = self.sentenceWindow[(n - 2)..<n].joined(separator: " ")
                if self.incrementNGramLocked(anchor: anchor2For2, continuation: tail2) {
                    promotedToDisk = true
                }

                let anchor3 = self.sentenceWindow[(n - 4)..<(n - 1)].map { $0.lowercased() }.joined(separator: " ")
                let tail3_1 = self.sentenceWindow[n - 1]
                if self.incrementNGramLocked(anchor: anchor3, continuation: tail3_1) {
                    promotedToDisk = true
                }
            }
            if n >= 5 {
                let anchor3For2 = self.sentenceWindow[(n - 5)..<(n - 2)].map { $0.lowercased() }.joined(separator: " ")
                let tail3_2 = self.sentenceWindow[(n - 2)..<n].joined(separator: " ")
                if self.incrementNGramLocked(anchor: anchor3For2, continuation: tail3_2) {
                    promotedToDisk = true
                }
            }

            if endedSentence {
                self.sentenceWindow.removeAll(keepingCapacity: true)
            }

            if promotedToDisk {
                self.persistLocked()
            }
        }

        if persistAsync {
            queue.async(execute: work)
        } else {
            queue.sync(execute: work)
        }
    }

    @discardableResult
    public func addCustomPhrase(_ rawPhrase: String, persistAsync: Bool = true) -> Bool {
        let tokens = rawPhrase
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard tokens.count >= 3, tokens.count <= 10,
              tokens.allSatisfy({ $0.allSatisfy({ ($0.isASCII && $0.isLetter) || $0 == "'" || $0 == "," }) }) else {
            return false
        }
        let normalized = tokens.joined(separator: " ")
        let work = {
            if !self.persisted.customPhrases.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
                self.persisted.customPhrases.append(normalized)
                self.persistLocked()
            }
        }
        if persistAsync { queue.async(execute: work) } else { queue.sync(execute: work) }
        return true
    }

    public func removeEntry(_ entry: PhraseEntry) {
        queue.sync {
            switch entry.source {
            case .custom:
                let full = entry.fullPhrase
                persisted.customPhrases.removeAll { $0.caseInsensitiveCompare(full) == .orderedSame }
            case .learned:
                persisted.continuations[entry.anchor]?.removeValue(forKey: entry.continuation)
                if persisted.continuations[entry.anchor]?.isEmpty == true {
                    persisted.continuations.removeValue(forKey: entry.anchor)
                }
            }
            persistLocked()
        }
    }

    public func allEntries() -> [PhraseEntry] {
        queue.sync {
            var list: [PhraseEntry] = []
            for phrase in persisted.customPhrases {
                let parts = phrase.split(separator: " ").map(String.init)
                if parts.count >= 3 {
                    let anchor = parts.prefix(2).joined(separator: " ")
                    let cont = parts.dropFirst(2).joined(separator: " ")
                    list.append(PhraseEntry(anchor: anchor, continuation: cont, count: 0, source: .custom))
                }
            }
            for (anchor, contMap) in persisted.continuations {
                let total = max(1, persisted.anchorTotals[anchor, default: 1])
                let is3Word = anchor.split(separator: " ").count >= 3
                if !is3Word && Self.genericTwoWordAnchors.contains(anchor) {
                    continue
                }
                for (cont, cnt) in contMap where cnt >= Self.graduationCount {
                    let conf = Double(cnt) / Double(total)
                    if conf >= Self.graduationConfidence {
                        list.append(PhraseEntry(anchor: anchor, continuation: cont, count: cnt, source: .learned))
                    }
                }
            }
            return list.sorted { lhs, rhs in
                if lhs.source != rhs.source { return lhs.source == .custom }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.fullPhrase.localizedCaseInsensitiveCompare(rhs.fullPhrase) == .orderedAscending
            }
        }
    }

    public func clearLearnedOnly() {
        queue.sync {
            persisted.anchorTotals.removeAll()
            persisted.continuations.removeAll()
            probationAnchorTotals.removeAll()
            probationContinuations.removeAll()
            sentenceWindow.removeAll()
            persistLocked()
        }
    }

    public func clearAll() {
        queue.sync {
            persisted = PersistedData()
            probationAnchorTotals.removeAll()
            probationContinuations.removeAll()
            sentenceWindow.removeAll()
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Helpers

    private func incrementNGramLocked(anchor: String, continuation: String) -> Bool {
        // Already persisted? Increment directly on persisted table.
        if var diskMap = persisted.continuations[anchor], let existing = diskMap[continuation] {
            diskMap[continuation] = existing + 1
            persisted.continuations[anchor] = diskMap
            persisted.anchorTotals[anchor, default: 0] += 1
            return true
        }

        // Otherwise update RAM-only probation table first; promote to disk ONLY once seen >= 2 times!
        probationAnchorTotals[anchor, default: 0] += 1
        var pMap = probationContinuations[anchor] ?? [:]
        let newCount = pMap[continuation, default: 0] + 1
        pMap[continuation] = newCount
        probationContinuations[anchor] = pMap

        if probationContinuations.count > 350 {
            let trimmed = probationContinuations.prefix(220)
            probationContinuations = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key, $0.value) })
        }

        if newCount >= 2 {
            var diskMap = persisted.continuations[anchor] ?? [:]
            diskMap[continuation] = newCount
            if diskMap.count > 6 {
                let top = diskMap.sorted { $0.value > $1.value }.prefix(5)
                diskMap = Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) })
            }
            persisted.continuations[anchor] = diskMap
            persisted.anchorTotals[anchor] = max(
                persisted.anchorTotals[anchor, default: 0] + 1,
                probationAnchorTotals[anchor, default: newCount]
            )
            if persisted.continuations.count > 400 {
                let topAnchors = persisted.continuations
                    .sorted { ($0.value.values.max() ?? 0) > ($1.value.values.max() ?? 0) }
                    .prefix(300)
                persisted.continuations = Dictionary(uniqueKeysWithValues: topAnchors.map { ($0.key, $0.value) })
            }
            return true
        }
        return false
    }

    private func matchingCustomContinuationsLocked(forAnchor anchor: String) -> [String] {
        let prefixWithSpace = anchor.lowercased() + " "
        var out: [String] = []
        for phrase in persisted.customPhrases {
            if phrase.lowercased().hasPrefix(prefixWithSpace) {
                let rem = String(phrase.dropFirst(prefixWithSpace.count))
                if !rem.isEmpty {
                    out.append(rem)
                }
            }
        }
        return out
    }

    private func graduatedContinuationsLocked(forAnchor anchor: String, allowGeneric2Word: Bool) -> [String] {
        if !allowGeneric2Word && Self.genericTwoWordAnchors.contains(anchor) {
            return []
        }
        guard let contMap = persisted.continuations[anchor] else { return [] }
        let total = max(1, persisted.anchorTotals[anchor, default: 1])

        // Prefer longer multi-word matches when counts are similar, sorted by count descending
        return contMap
            .filter { _, cnt in
                cnt >= Self.graduationCount && (Double(cnt) / Double(total)) >= Self.graduationConfidence
            }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.count > rhs.key.count
            }
            .map(\.key)
    }

    private func persistLocked() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
