import AppKit
import Foundation

public struct CompletionMatch: Equatable {
    public let prefix: String
    public let fullWord: String
    public let suffix: String

    public init(prefix: String, fullWord: String, suffix: String) {
        self.prefix = prefix
        self.fullWord = fullWord
        self.suffix = suffix
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
    public var minimumPrefixLength: Int
    public var minimumSuffixLength: Int
    public var enableTechLexicon: Bool

    public init(
        spellCompleter: SpellCompleting = SystemSpellCompleter(),
        historyStore: UserHistoryStore = UserHistoryStore(),
        minimumPrefixLength: Int = 2,
        minimumSuffixLength: Int = 2,
        enableTechLexicon: Bool = true
    ) {
        self.spellCompleter = spellCompleter
        self.historyStore = historyStore
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

    public func complete(textBeforeCursor: String, charAfterCursor: Character? = nil) -> CompletionMatch? {
        candidates(textBeforeCursor: textBeforeCursor, charAfterCursor: charAfterCursor, limit: 1).first
    }

    public func candidates(
        textBeforeCursor: String,
        charAfterCursor: Character? = nil,
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

        let nsLine = line as NSString
        let prefixNSLength = (prefix as NSString).length
        let nsRange = NSRange(location: nsLine.length - prefixNSLength, length: prefixNSLength)

        let historyCandidates = historyStore.matchingWords(forPrefix: prefix).map(\.word)
        let systemCandidates = spellCompleter.completions(
            forPartialWordRange: nsRange,
            in: line,
            language: "en_US"
        )
        let lowerPrefix = prefix.lowercased()
        let techCandidates = enableTechLexicon
            ? TechLexicon.words.filter { $0.hasPrefix(lowerPrefix) }
            : []

        // Order: user custom/accepted words -> macOS grammar-ranked completions -> curated Tech/AI lexicon fallback.
        var seen = Set<String>()
        var combined: [String] = []
        for raw in historyCandidates + systemCandidates + techCandidates {
            guard let adapted = adaptCandidate(raw, toPrefix: prefix) else { continue }
            let key = adapted.lowercased()
            if seen.insert(key).inserted {
                combined.append(adapted)
            }
        }

        guard !combined.isEmpty else { return [] }

        // Stable-boost any candidate previously accepted or pinned by the user; keep natural order otherwise.
        let ranked = combined.enumerated().sorted { lhs, rhs in
            let lCount = historyStore.count(for: lhs.element)
            let rCount = historyStore.count(for: rhs.element)
            if lCount != rCount {
                return lCount > rCount
            }
            return lhs.offset < rhs.offset
        }

        return ranked.prefix(limit).map { entry in
            let full = entry.element
            let suffix = String(full.dropFirst(prefix.count))
            return CompletionMatch(prefix: prefix, fullWord: full, suffix: suffix)
        }
    }

    private func adaptCandidate(_ candidate: String, toPrefix prefix: String) -> String? {
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
            // Allow custom user words (e.g. "TypeScript") to adapt to lowercase prefix ("typesc" -> "ript") ONLY if lowercase matches,
            // while still blocking random proper nouns from NSSpellChecker when typing lowercase prose.
            if candidate.hasPrefix(prefix) {
                adapted = candidate
            } else if historyStore.count(for: candidate) > 0 {
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
