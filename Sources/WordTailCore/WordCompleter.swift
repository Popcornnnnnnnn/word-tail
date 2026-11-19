import AppKit
import Foundation

public struct CompletionMatch: Equatable {
    public let prefix: String
    public let fullWord: String
    public let suffix: String
    public let previousWord: String?
    public let replacementDeleteCount: Int

    public var isTypoCorrection: Bool {
        replacementDeleteCount > 0
    }

    public init(
        prefix: String,
        fullWord: String,
        suffix: String,
        previousWord: String? = nil,
        replacementDeleteCount: Int = 0
    ) {
        self.prefix = prefix
        self.fullWord = fullWord
        self.suffix = suffix
        self.previousWord = previousWord
        self.replacementDeleteCount = replacementDeleteCount
    }

    public static func == (lhs: CompletionMatch, rhs: CompletionMatch) -> Bool {
        lhs.prefix == rhs.prefix
            && lhs.fullWord == rhs.fullWord
            && lhs.suffix == rhs.suffix
            && lhs.replacementDeleteCount == rhs.replacementDeleteCount
    }
}

public protocol SpellCompleting {
    func completions(forPartialWordRange range: NSRange, in string: String, language: String) -> [String]
    func correction(forWord word: String) -> String?
}

public extension SpellCompleting {
    func correction(forWord word: String) -> String? { nil }
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

    public func correction(forWord word: String) -> String? {
        let ns = word as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let misspelled = NSSpellChecker.shared.checkSpelling(
            of: word,
            startingAt: 0,
            language: "en_US",
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        guard misspelled.location != NSNotFound else { return nil }
        return NSSpellChecker.shared.correction(
            forWordRange: fullRange,
            in: word,
            language: "en_US",
            inSpellDocumentWithTag: 0
        )
    }
}

public final class WordCompleter {
    private static let allowedTrailingChars = Set(" \t\n\r.,;:!?)]}\"'”’")
    private static let allowedLeadingBoundaryChars = Set(" \t([{\"'“‘")

    private let spellCompleter: SpellCompleting
    private let historyStore: UserHistoryStore
    public weak var habitTracker: TypingHabitTracker?
    public var adaptiveStore: AdaptiveCorrectionStore?
    public var minimumPrefixLength: Int
    public var minimumSuffixLength: Int
    public var enableTechLexicon: Bool
    public var enableInlineTypoFix: Bool

    public init(
        spellCompleter: SpellCompleting = SystemSpellCompleter(),
        historyStore: UserHistoryStore = UserHistoryStore(),
        habitTracker: TypingHabitTracker? = nil,
        adaptiveStore: AdaptiveCorrectionStore? = nil,
        minimumPrefixLength: Int = 2,
        minimumSuffixLength: Int = 2,
        enableTechLexicon: Bool = true,
        enableInlineTypoFix: Bool = true
    ) {
        self.spellCompleter = spellCompleter
        self.historyStore = historyStore
        self.habitTracker = habitTracker
        self.adaptiveStore = adaptiveStore
        self.minimumPrefixLength = minimumPrefixLength
        self.minimumSuffixLength = minimumSuffixLength
        self.enableTechLexicon = enableTechLexicon
        self.enableInlineTypoFix = enableInlineTypoFix
    }

    /// Returns true only when appending a trailing space after `Tab` will not create a duplicate space
    /// or put an unwanted space immediately before punctuation like `.` or `,`.
    public static func shouldAppendTrailingSpace(charAfterCursor: Character?) -> Bool {
        guard let after = charAfterCursor else { return true }
        return after == "\n" || after == "\r"
    }

    /// Decides whether `Tab` acceptance should append a space:
    /// - Always appends a separating space if the cursor is pressed directly against the front of a following word (`"just al|behind"` -> `"just also |behind"`).
    /// - Otherwise honors `appendSpacePreference` while avoiding duplicate spaces before existing spaces/punctuation.
    public static func shouldAppendSpaceOnTab(charAfterCursor: Character?, appendSpacePreference: Bool) -> Bool {
        if let after = charAfterCursor, isASCIILetter(after) {
            return true
        }
        guard appendSpacePreference else { return false }
        return shouldAppendTrailingSpace(charAfterCursor: charAfterCursor)
    }

    public func complete(
        textBeforeCursor: String,
        charAfterCursor: Character? = nil,
        textAfterCursorOnLine: String? = nil,
        bundleID: String? = nil
    ) -> CompletionMatch? {
        candidates(
            textBeforeCursor: textBeforeCursor,
            charAfterCursor: charAfterCursor,
            textAfterCursorOnLine: textAfterCursorOnLine,
            bundleID: bundleID,
            limit: 1
        ).first
    }

    public func candidates(
        textBeforeCursor: String,
        charAfterCursor: Character? = nil,
        textAfterCursorOnLine: String? = nil,
        bundleID: String? = nil,
        limit: Int = 5
    ) -> [CompletionMatch] {
        guard limit > 0 else { return [] }

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

        let effectiveCharAfter = charAfterCursor ?? textAfterCursorOnLine?.first
        if let after = effectiveCharAfter, !Self.allowedTrailingChars.contains(after) {
            // Allow mid-sentence insertion directly against the start of an existing word ("just al|behind" or "to kn|the")
            // ONLY when `trailingWord` is a complete standalone word AND `prefix + trailingWord` is NOT a single valid word!
            guard Self.isASCIILetter(after),
                  let afterLine = textAfterCursorOnLine,
                  Self.isInsertingBeforeSeparateWord(prefix: prefix, afterSlice: afterLine) else {
                return []
            }
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

        // Surface explicit custom shorthand / graduated learned rules at #1 whenever their exact trigger is typed!
        if enableInlineTypoFix,
           let customFix = adaptiveStore?.customOrLearnedReplacement(for: lowerPrefix) {
            let adaptedCustom = ObviousTypoCorrector.adaptCase(of: customFix, toTyped: prefix)
            let diff = ObviousTypoCorrector.minimalDiff(from: prefix, to: adaptedCustom)
            if diff.deleteCount > 0 || !diff.insertText.isEmpty {
                let customMatch = CompletionMatch(
                    prefix: prefix,
                    fullWord: adaptedCustom,
                    suffix: diff.insertText,
                    previousWord: prevWord,
                    replacementDeleteCount: diff.deleteCount
                )
                if combined.isEmpty {
                    return [customMatch]
                }
                let rankedRest = combined.enumerated().sorted { lhs, rhs in
                    let lScore = contextualPriority(for: lhs.element, previousWord: prevWord, bundleID: bundleID)
                    let rScore = contextualPriority(for: rhs.element, previousWord: prevWord, bundleID: bundleID)
                    if lScore != rScore { return lScore > rScore }
                    return lhs.offset < rhs.offset
                }
                let restMatches = rankedRest.prefix(max(0, limit - 1)).map { entry in
                    CompletionMatch(prefix: prefix, fullWord: entry.element, suffix: String(entry.element.dropFirst(prefix.count)), previousWord: prevWord)
                }
                return [customMatch] + restMatches
            }
        }

        if combined.isEmpty {
            // Fallback: Inline Typo Correction (`→ word` on Tab) when no valid prefix completions exist!
            if enableInlineTypoFix,
               let corrected = ObviousTypoCorrector.inlineTabCorrection(
                   forPrefix: prefix,
                   adaptiveStore: adaptiveStore,
                   habitTracker: habitTracker,
                   historyStore: historyStore,
                   spellCompleter: spellCompleter
               ) {
                let diff = ObviousTypoCorrector.minimalDiff(from: prefix, to: corrected)
                guard diff.deleteCount > 0 else { return [] }
                return [
                    CompletionMatch(
                        prefix: prefix,
                        fullWord: corrected,
                        suffix: diff.insertText,
                        previousWord: prevWord,
                        replacementDeleteCount: diff.deleteCount
                    )
                ]
            }
            return []
        }

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

    private static func isInsertingBeforeSeparateWord(prefix: String, afterSlice: String) -> Bool {
        let trailingLetters = String(afterSlice.prefix(while: { isASCIILetter($0) || $0 == "'" })).lowercased()
        guard !trailingLetters.isEmpty else { return false }

        // If `prefix + trailingLetters` forms a valid single English word (e.g. "kn" + "ow" = "know", "comp" + "uter" = "computer"),
        // the cursor is inside a single word—do NOT suggest!
        let glued = (prefix + trailingLetters).lowercased()
        if TypingHabitTracker.defaultValidEnglishWordCheck(glued) || TechLexicon.wordSet.contains(glued) {
            return false
        }

        // Only allow if `trailingLetters` itself is already a valid standalone English word ("the", "behind", "in", "to", etc.)!
        return ObviousTypoCorrector.validShortEnglishWords.contains(trailingLetters)
            || TypingHabitTracker.defaultValidEnglishWordCheck(trailingLetters)
            || TechLexicon.wordSet.contains(trailingLetters)
    }

    private static func isASCIILetter(_ ch: Character) -> Bool {
        guard let ascii = ch.asciiValue else { return false }
        return (ascii >= 65 && ascii <= 90) || (ascii >= 97 && ascii <= 122)
    }
}
