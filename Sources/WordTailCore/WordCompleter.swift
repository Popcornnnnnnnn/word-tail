import AppKit
import Foundation

public struct CompletionMatch: Equatable {
    public let prefix: String
    public let fullWord: String
    public let suffix: String
    public let previousWord: String?

    public init(prefix: String, fullWord: String, suffix: String, previousWord: String? = nil) {
        self.prefix = prefix
        self.fullWord = fullWord
        self.suffix = suffix
        self.previousWord = previousWord
    }

    public static func == (lhs: CompletionMatch, rhs: CompletionMatch) -> Bool {
        lhs.prefix == rhs.prefix && lhs.fullWord == rhs.fullWord && lhs.suffix == rhs.suffix
    }
}

public protocol SpellCompleting {
    func completions(forPartialWordRange range: NSRange, in string: String, language: String) -> [String]
}

public struct SystemSpellCompleter: SpellCompleting {
    public init() {}

    public func completions(forPartialWordRange range: NSRange, in string: String, language: String) -> [String] {
        NSSpellChecker.shared.completions(
            forPartialWordRange: range,
            in: string,
            language: language,
            inSpellDocumentWithTag: 0
        ) ?? []
    }
}

public final class WordCompleter {
    private static let allowedTrailingChars = Set(" \t\n\r.,;:!?)]}\"'”’")
    private static let allowedLeadingBoundaryChars = Set(" \t([{\"'“‘")

    private let spellCompleter: SpellCompleting
    private let historyStore: UserHistoryStore
    public weak var habitTracker: TypingHabitTracker?
    public var minimumPrefixLength: Int
    public var minimumSuffixLength: Int
    public var enableTechLexicon: Bool

    public init(
        spellCompleter: SpellCompleting = SystemSpellCompleter(),
        historyStore: UserHistoryStore = UserHistoryStore(),
        habitTracker: TypingHabitTracker? = nil,
        minimumPrefixLength: Int = 2,
        minimumSuffixLength: Int = 2,
        enableTechLexicon: Bool = true
    ) {
        self.spellCompleter = spellCompleter
        self.historyStore = historyStore
        self.habitTracker = habitTracker
        self.minimumPrefixLength = minimumPrefixLength
        self.minimumSuffixLength = minimumSuffixLength
        self.enableTechLexicon = enableTechLexicon
    }

    /// Returns true only when appending a trailing space after `Tab` will not create a duplicate space
    /// or put an unwanted space immediately before punctuation like `.` or `,`.
    public static func shouldAppendTrailingSpace(charAfterCursor: Character?) -> Bool {
        guard let after = charAfterCursor else { return true }
        return after == "\n" || after == "\r"
    }

    public func complete(
        textBeforeCursor: String,
        charAfterCursor: Character? = nil,
        bundleID: String? = nil
    ) -> CompletionMatch? {
        candidates(
            textBeforeCursor: textBeforeCursor,
            charAfterCursor: charAfterCursor,
            bundleID: bundleID,
            limit: 1
        ).first
    }

    public func candidates(
        textBeforeCursor: String,
        charAfterCursor: Character? = nil,
        bundleID: String? = nil,
        limit: Int = 5
    ) -> [CompletionMatch] {
        guard limit > 0 else { return [] }
        if let after = charAfterCursor, !Self.allowedTrailingChars.contains(after) {
            return []
        }

        guard let rawLastLine = textBeforeCursor.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last else {
            return []
        }
        let line = String(rawLastLine.suffix(80))
        guard !line.isEmpty else { return [] }

        let chars = Array(line)
        var wordStart = chars.count
        while wordStart > 0 {
            let ch = chars[wordStart - 1]
            if Self.isASCIILetter(ch) {
                wordStart -= 1
            } else if ch == "'" && wordStart >= 2 && Self.isASCIILetter(chars[wordStart - 2]) {
                wordStart -= 1
            } else {
                break
            }
        }

        // Ignore URLs, paths, emails, flags, domains, and snake_case identifiers.
        if wordStart > 0 {
            let boundary = chars[wordStart - 1]
            if !Self.allowedLeadingBoundaryChars.contains(boundary) {
                return []
            }
        }

        let prefix = String(chars[wordStart..<chars.count])
        let letterCount = prefix.filter(Self.isASCIILetter).count
        guard letterCount >= minimumPrefixLength else {
            return []
        }

        let prevWord = Self.extractImmediatePreviousWord(chars: chars, beforeIndex: wordStart)

        let nsLine = line as NSString
        let prefixNSLength = (prefix as NSString).length
        let nsRange = NSRange(location: nsLine.length - prefixNSLength, length: prefixNSLength)

        let historyCandidates = historyStore.matchingWords(
            forPrefix: prefix,
            previousWord: prevWord,
            bundleID: bundleID
        ).map(\.word)
        let systemCandidates = spellCompleter.completions(
            forPartialWordRange: nsRange,
            in: line,
            language: "en_US"
        )
        let lowerPrefix = prefix.lowercased()
        let techCandidates = enableTechLexicon
            ? TechLexicon.words.filter { $0.hasPrefix(lowerPrefix) }
            : []

        // Order: user contextual/pinned words -> macOS grammar-ranked completions -> curated Tech/AI lexicon fallback.
        var seen = Set<String>()
        var combined: [String] = []
        for raw in historyCandidates + systemCandidates + techCandidates {
            guard let adapted = adaptCandidate(raw, toPrefix: prefix, previousWord: prevWord, bundleID: bundleID) else {
                continue
            }
            let key = adapted.lowercased()
            if seen.insert(key).inserted {
                combined.append(adapted)
            }
        }

        guard !combined.isEmpty else { return [] }

        // Contextual ranking: custom pinned -> personal bigrams -> per-app vocabulary -> typo-trap rescue -> global accepts -> system grammar order.
        let ranked = combined.enumerated().sorted { lhs, rhs in
            let lScore = contextualPriority(for: lhs.element, previousWord: prevWord, bundleID: bundleID)
            let rScore = contextualPriority(for: rhs.element, previousWord: prevWord, bundleID: bundleID)
            if lScore != rScore {
                return lScore > rScore
            }
            return lhs.offset < rhs.offset
        }

        return ranked.prefix(limit).map { entry in
            let full = entry.element
            let suffix = String(full.dropFirst(prefix.count))
            return CompletionMatch(prefix: prefix, fullWord: full, suffix: suffix, previousWord: prevWord)
        }
    }

    private func contextualPriority(for word: String, previousWord: String?, bundleID: String?) -> Int {
        let base = historyStore.contextualScore(for: word, previousWord: previousWord, bundleID: bundleID)
        let trapCount = habitTracker?.typoBoostCount(for: word) ?? 0
        return base + (trapCount * 10)
    }

    public static func extractImmediatePreviousWord(chars: [Character], beforeIndex wordStart: Int) -> String? {
        var idx = wordStart
        var sawWhitespace = false
        while idx > 0 && (chars[idx - 1] == " " || chars[idx - 1] == "\t") {
            sawWhitespace = true
            idx -= 1
        }
        guard sawWhitespace, idx > 0 else { return nil }
        // Do not cross sentence boundaries (e.g. "done. re" should not treat "done" as previous word).
        let prevEnd = idx
        while idx > 0 {
            let ch = chars[idx - 1]
            if isASCIILetter(ch) || (ch == "'" && idx >= 2 && isASCIILetter(chars[idx - 2])) {
                idx -= 1
            } else {
                break
            }
        }
        guard prevEnd - idx >= 2 else { return nil }
        if idx > 0 {
            let lead = chars[idx - 1]
            if !allowedLeadingBoundaryChars.contains(lead) {
                return nil
            }
        }
        return String(chars[idx..<prevEnd]).lowercased()
    }

    private func adaptCandidate(
        _ candidate: String,
        toPrefix prefix: String,
        previousWord: String?,
        bundleID: String?
    ) -> String? {
        guard candidate.count >= prefix.count + minimumSuffixLength else { return nil }
        guard candidate.allSatisfy({ Self.isASCIILetter($0) || $0 == "'" }) else { return nil }

        if !prefix.contains("'") && candidate.lowercased().hasSuffix("'s") {
            return nil
        }
        guard candidate.lowercased().hasPrefix(prefix.lowercased()) else { return nil }

        let adapted: String
        if prefix.count >= 2 && prefix.allSatisfy({ !$0.isLetter || $0.isUppercase }) {
            adapted = candidate.uppercased()
        } else if let first = prefix.first, first.isUppercase, prefix.dropFirst().allSatisfy({ !$0.isLetter || $0.isLowercase }) {
            adapted = candidate.prefix(1).uppercased() + candidate.dropFirst()
        } else {
            if candidate.hasPrefix(prefix) {
                adapted = candidate
            } else if historyStore.contextualScore(for: candidate, previousWord: previousWord, bundleID: bundleID) > 0 {
                adapted = prefix + candidate.dropFirst(prefix.count)
            } else {
                return nil
            }
        }

        let suffix = adapted.dropFirst(prefix.count)
        guard suffix.count >= minimumSuffixLength else { return nil }
        return adapted
    }

    private static func isASCIILetter(_ ch: Character) -> Bool {
        guard let ascii = ch.asciiValue else { return false }
        return (ascii >= 65 && ascii <= 90) || (ascii >= 97 && ascii <= 122)
    }
}
