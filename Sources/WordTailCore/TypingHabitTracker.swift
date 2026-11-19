import AppKit
import Foundation

public struct HourlyTypingBucket: Codable, Equatable, Identifiable {
    public var id: Int { hour }
    public let hour: Int
    public var typedLetters: Int
    public var backspaces: Int
    public var burstCharacters: Int
    public var burstSeconds: Double

    public init(
        hour: Int,
        typedLetters: Int = 0,
        backspaces: Int = 0,
        burstCharacters: Int = 0,
        burstSeconds: Double = 0
    ) {
        self.hour = hour
        self.typedLetters = typedLetters
        self.backspaces = backspaces
        self.burstCharacters = burstCharacters
        self.burstSeconds = burstSeconds
    }

    public var averageWPM: Int {
        guard burstSeconds >= 2.0, burstCharacters >= 10 else { return 0 }
        let wpm = (Double(burstCharacters) / 5.0) / (burstSeconds / 60.0)
        return Int(min(max(wpm.rounded(), 0), 240))
    }

    public var backspaceRate: Double {
        let total = typedLetters + backspaces
        guard total > 0 else { return 0 }
        return Double(backspaces) / Double(total)
    }
}

public struct TypoTrapEntry: Codable, Equatable, Identifiable {
    public var id: String { word }
    public let word: String
    public var commonMistype: String
    public var count: Int

    public init(word: String, commonMistype: String, count: Int) {
        self.word = word
        self.commonMistype = commonMistype
        self.count = count
    }
}

public struct FillerHabitEntry: Equatable, Identifiable {
    public var id: String { word }
    public let word: String
    public let count: Int

    public init(word: String, count: Int) {
        self.word = word
        self.count = count
    }
}

public struct SavedWordEntry: Equatable, Identifiable {
    public var id: String { word }
    public let word: String
    public let charsSaved: Int

    public init(word: String, charsSaved: Int) {
        self.word = word
        self.charsSaved = charsSaved
    }
}

public struct TypingInsightsSnapshot: Equatable {
    public let tabsAccepted: Int
    public let charactersSaved: Int
    public let suggestionsShown: Int
    public let totalTypedLetters: Int
    public let totalBackspaces: Int
    public let averageBurstWPM: Int
    public let peakBurstWPM: Int
    public let imeSwitches: Int
    public let hourlyBuckets: [HourlyTypingBucket]
    public let typoTraps: [TypoTrapEntry]
    public let fillerHabits: [FillerHabitEntry]
    public let topSavedWords: [SavedWordEntry]

    public init(
        tabsAccepted: Int = 0,
        charactersSaved: Int = 0,
        suggestionsShown: Int = 0,
        totalTypedLetters: Int = 0,
        totalBackspaces: Int = 0,
        averageBurstWPM: Int = 0,
        peakBurstWPM: Int = 0,
        imeSwitches: Int = 0,
        hourlyBuckets: [HourlyTypingBucket] = (0..<24).map { HourlyTypingBucket(hour: $0) },
        typoTraps: [TypoTrapEntry] = [],
        fillerHabits: [FillerHabitEntry] = [],
        topSavedWords: [SavedWordEntry] = []
    ) {
        self.tabsAccepted = tabsAccepted
        self.charactersSaved = charactersSaved
        self.suggestionsShown = suggestionsShown
        self.totalTypedLetters = totalTypedLetters
        self.totalBackspaces = totalBackspaces
        self.averageBurstWPM = averageBurstWPM
        self.peakBurstWPM = peakBurstWPM
        self.imeSwitches = imeSwitches
        self.hourlyBuckets = hourlyBuckets
        self.typoTraps = typoTraps
        self.fillerHabits = fillerHabits
        self.topSavedWords = topSavedWords
    }

    public var hitRatePercent: Int {
        guard suggestionsShown > 0 else { return 0 }
        return Int(min(100, ((Double(tabsAccepted) / Double(suggestionsShown)) * 100.0).rounded()))
    }

    public var cleanAccuracyPercent: Double {
        let total = totalTypedLetters + totalBackspaces
        guard total > 0 else { return 100.0 }
        let clean = Double(totalTypedLetters) / Double(total) * 100.0
        return (clean * 10).rounded() / 10.0
    }

    public var estimatedSecondsSaved: Int {
        // Conservative ~5.5 keystrokes/sec average prose speed (~66 WPM) -> ~0.18s per saved char + Tab overhead
        guard charactersSaved > 0 else { return 0 }
        return max(1, Int((Double(charactersSaved) * 0.18).rounded()))
    }
}

public struct WordCompletionOutcome: Equatable {
    public let word: String
    public let previousWord: String?
    public let bundleID: String?
    public let detectedTypoMistype: String?
}

/// Privacy-preserving local habit tracker.
/// Stores ONLY aggregate counters, hourly speed/accuracy buckets, and dictionary-verified single words—never raw sentences.
public final class TypingHabitTracker {
    public static let trackedFillerWords: Set<String> = [
        "actually", "basically", "literally", "honestly", "probably",
        "definitely", "simply", "really", "essentially", "perhaps", "maybe", "obviously"
    ]

    private struct PersistedState: Codable {
        var tabsAccepted: Int = 0
        var charactersSaved: Int = 0
        var suggestionsShown: Int = 0
        var totalTypedLetters: Int = 0
        var totalBackspaces: Int = 0
        var totalBurstCharacters: Int = 0
        var totalBurstSeconds: Double = 0
        var peakBurstWPM: Int = 0
        var imeSwitches: Int = 0
        var hourlyBuckets: [HourlyTypingBucket] = (0..<24).map { HourlyTypingBucket(hour: $0) }
        var typoTraps: [String: TypoTrapEntry] = [:]
        var fillerCounts: [String: Int] = [:]
        var savedByWord: [String: Int] = [:]
    }

    private let fileURL: URL
    private let nowProvider: () -> Date
    private let validWordChecker: (String) -> Bool
    private let queue = DispatchQueue(label: "app.wordtail.macos.habits", qos: .utility)

    private var state = PersistedState()

    // Ephemeral in-progress word & burst tracking (never persisted to disk)
    private var inProgressChars: String = ""
    private var peakBeforeBackspace: String?
    private var backspacesInCurrentWord: Int = 0
    private var shownOpportunityForCurrentWord: Bool = false

    private var lastCompletedWord: String?
    private var lastCompletedWordTime: TimeInterval = 0
    private var lastCompletedBundleID: String?
    private var recentInvalidWord: (token: String, time: TimeInterval, sawBackspaceAfter: Bool)?

    private var burstStartTime: TimeInterval?
    private var lastBurstKeyTime: TimeInterval?
    private var burstChars: Int = 0
    private var keystrokesSinceFlush: Int = 0

    public init(
        fileURL: URL? = nil,
        nowProvider: @escaping () -> Date = Date.init,
        validWordChecker: ((String) -> Bool)? = nil
    ) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("WordTail", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("typing_insights.json")
        }
        self.nowProvider = nowProvider
        self.validWordChecker = validWordChecker ?? Self.defaultValidEnglishWordCheck
        loadSynchronously()
    }

    public static func defaultValidEnglishWordCheck(_ rawWord: String) -> Bool {
        let lower = rawWord.lowercased()
        guard lower.count >= 3, lower.count <= 28,
              lower.allSatisfy({ ($0.isASCII && $0.isLetter) || $0 == "'" }) else {
            return false
        }
        if TechLexicon.wordSet.contains(lower) {
            return true
        }
        let range = NSSpellChecker.shared.checkSpelling(
            of: lower,
            startingAt: 0,
            language: "en_US",
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return range.location == NSNotFound
    }

    private func loadSynchronously() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }
        state = decoded
        if state.hourlyBuckets.count != 24 {
            state.hourlyBuckets = (0..<24).map { HourlyTypingBucket(hour: $0) }
        }
    }

    public func typoBoostCount(for word: String) -> Int {
        let lower = word.lowercased()
        return queue.sync {
            state.typoTraps[lower]?.count ?? 0
        }
    }

    /// Returns the learned clean word if the user has repeatedly mistyped `mistype` (`count >= 2`).
    public func learnedAutoFix(forMistype mistype: String) -> String? {
        let lower = mistype.lowercased()
        return queue.sync {
            let match = state.typoTraps.values
                .filter { $0.count >= 2 && $0.commonMistype == lower && $0.word != lower }
                .max(by: { $0.count < $1.count })
            return match?.word
        }
    }

    /// Returns the learned clean word for an inline `Tab` hint when `typedPrefix` matches or starts a recorded mistype.
    public func matchingTypoTrapCorrection(forTypedPrefix typedPrefix: String) -> String? {
        let lower = typedPrefix.lowercased()
        guard lower.count >= 3 else { return nil }
        return queue.sync {
            if let exact = state.typoTraps.values
                .filter({ $0.commonMistype == lower && $0.word != lower })
                .max(by: { $0.count < $1.count }) {
                return exact.word
            }
            guard lower.count >= 4 else { return nil }
            let prefixMatches = state.typoTraps.values.filter {
                $0.commonMistype.hasPrefix(lower) && !$0.word.hasPrefix(lower)
            }
            let distinct = Set(prefixMatches.map(\.word))
            return distinct.count == 1 ? distinct.first : nil
        }
    }

    public func snapshot() -> TypingInsightsSnapshot {
        queue.sync {
            let avgWPM: Int
            if state.totalBurstSeconds >= 2.5, state.totalBurstCharacters >= 12 {
                let raw = (Double(state.totalBurstCharacters) / 5.0) / (state.totalBurstSeconds / 60.0)
                avgWPM = Int(min(max(raw.rounded(), 0), 240))
            } else {
                avgWPM = 0
            }

            let traps = state.typoTraps.values
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    return lhs.word < rhs.word
                }
                .prefix(12)

            let fillers = state.fillerCounts
                .map { FillerHabitEntry(word: $0.key, count: $0.value) }
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    return lhs.word < rhs.word
                }
                .prefix(8)

            let saved = state.savedByWord
                .map { SavedWordEntry(word: $0.key, charsSaved: $0.value) }
                .sorted { lhs, rhs in
                    if lhs.charsSaved != rhs.charsSaved { return lhs.charsSaved > rhs.charsSaved }
                    return lhs.word < rhs.word
                }
                .prefix(8)

            return TypingInsightsSnapshot(
                tabsAccepted: state.tabsAccepted,
                charactersSaved: state.charactersSaved,
                suggestionsShown: state.suggestionsShown,
                totalTypedLetters: state.totalTypedLetters,
                totalBackspaces: state.totalBackspaces,
                averageBurstWPM: avgWPM,
                peakBurstWPM: state.peakBurstWPM,
                imeSwitches: state.imeSwitches,
                hourlyBuckets: state.hourlyBuckets,
                typoTraps: Array(traps),
                fillerHabits: Array(fillers),
                topSavedWords: Array(saved)
            )
        }
    }

    public func recordSuggestionShownOncePerWord() {
        queue.sync {
            guard !shownOpportunityForCurrentWord else { return }
            shownOpportunityForCurrentWord = true
            state.suggestionsShown += 1
        }
    }

    public func recordIMESwitch(persistAsync: Bool = true) {
        let work = {
            self.flushActiveBurstLocked()
            self.resetCurrentWordLocked(clearLastWord: true)
            self.state.imeSwitches += 1
            self.persistLocked()
        }
        if persistAsync { queue.async(execute: work) } else { queue.sync(execute: work) }
    }

    public func resetSessionContext() {
        queue.sync {
            flushActiveBurstLocked()
            resetCurrentWordLocked(clearLastWord: true)
        }
    }

    public func recordBackspace() {
        let now = nowProvider().timeIntervalSince1970
        let hour = Calendar.current.component(.hour, from: nowProvider())
        queue.sync {
            state.totalBackspaces += 1
            if hour >= 0 && hour < 24 {
                state.hourlyBuckets[hour].backspaces += 1
            }
            if inProgressChars.count >= 3 {
                if let existingPeak = peakBeforeBackspace {
                    if inProgressChars.count > existingPeak.count {
                        peakBeforeBackspace = inProgressChars
                    }
                } else {
                    peakBeforeBackspace = inProgressChars
                }
            }
            if !inProgressChars.isEmpty {
                inProgressChars.removeLast()
                backspacesInCurrentWord += 1
            } else if var recent = recentInvalidWord, now - recent.time <= 4.0 {
                recent.sawBackspaceAfter = true
                recentInvalidWord = recent
            }
            lastBurstKeyTime = now
        }
    }

    /// Records a typed string (`1+` chars) and returns a `WordCompletionOutcome` whenever a clean word finishes at a delimiter.
    @discardableResult
    public func recordTypedCharacters(
        _ text: String,
        bundleID: String?,
        persistAsync: Bool = true
    ) -> WordCompletionOutcome? {
        let date = nowProvider()
        let now = date.timeIntervalSince1970
        let hour = Calendar.current.component(.hour, from: date)

        return queue.sync {
            var completedOutcome: WordCompletionOutcome?
            for ch in text {
                if (ch.isASCII && ch.isLetter) || (ch == "'" && !inProgressChars.isEmpty) {
                    inProgressChars.append(ch)
                    state.totalTypedLetters += 1
                    if hour >= 0 && hour < 24 {
                        state.hourlyBuckets[hour].typedLetters += 1
                    }
                    advanceBurstLocked(at: now, hour: hour)
                } else if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ".,;:!?)".contains(ch) {
                    advanceBurstLocked(at: now, hour: hour)
                    let isSoftSpace = (ch == " ")
                    if let outcome = finalizeWordLocked(at: now, bundleID: bundleID, keepChainAlive: isSoftSpace) {
                        completedOutcome = outcome
                    }
                } else {
                    // Digits, slashes, underscores, etc. -> discard as code/URL/identifier
                    resetCurrentWordLocked(clearLastWord: true)
                }
            }

            keystrokesSinceFlush += 1
            if completedOutcome != nil || keystrokesSinceFlush >= 25 {
                keystrokesSinceFlush = 0
                if persistAsync {
                    let snapshot = state
                    queue.async { [weak self] in
                        self?.writeSnapshot(snapshot)
                    }
                } else {
                    persistLocked()
                }
            }
            return completedOutcome
        }
    }

    @discardableResult
    public func recordTabAccepted(
        fullWord: String,
        insertedText: String,
        previousWordFromContext: String?,
        bundleID: String?,
        persistAsync: Bool = true
    ) -> WordCompletionOutcome {
        let now = nowProvider().timeIntervalSince1970
        return queue.sync {
            let lower = fullWord.lowercased()
            let savedCount = insertedText.count
            state.tabsAccepted += 1
            state.charactersSaved += savedCount
            if !shownOpportunityForCurrentWord {
                state.suggestionsShown += 1
            }
            if validWordChecker(lower) {
                state.savedByWord[lower, default: 0] += savedCount
                if state.savedByWord.count > 200 {
                    pruneTopDictionary(&state.savedByWord, limit: 150)
                }
                if Self.trackedFillerWords.contains(lower) {
                    state.fillerCounts[lower, default: 0] += 1
                }
            }

            let resolvedPrev = previousWordFromContext?.lowercased()
                ?? ((now - lastCompletedWordTime <= 6.0 && lastCompletedBundleID == bundleID) ? lastCompletedWord : nil)

            let mistype = detectMistypeLocked(forFinalLowerWord: lower, at: now)

            resetCurrentWordLocked(clearLastWord: false)
            if validWordChecker(lower) {
                lastCompletedWord = lower
                lastCompletedWordTime = now
                lastCompletedBundleID = bundleID
            } else {
                lastCompletedWord = nil
            }

            if persistAsync {
                let snapshot = state
                queue.async { [weak self] in
                    self?.writeSnapshot(snapshot)
                }
            } else {
                persistLocked()
            }

            return WordCompletionOutcome(
                word: lower,
                previousWord: resolvedPrev,
                bundleID: bundleID,
                detectedTypoMistype: mistype
            )
        }
    }

    public func clearAll() {
        queue.sync {
            state = PersistedState()
            inProgressChars = ""
            peakBeforeBackspace = nil
            backspacesInCurrentWord = 0
            shownOpportunityForCurrentWord = false
            lastCompletedWord = nil
            burstStartTime = nil
            lastBurstKeyTime = nil
            burstChars = 0
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Internal Helpers

    private func advanceBurstLocked(at now: TimeInterval, hour: Int) {
        if let last = lastBurstKeyTime, now - last <= 2.0 {
            burstChars += 1
            lastBurstKeyTime = now
        } else {
            flushActiveBurstLocked(currentHourFallback: hour)
            burstStartTime = now
            lastBurstKeyTime = now
            burstChars = 1
        }
    }

    private func flushActiveBurstLocked(currentHourFallback: Int? = nil) {
        defer {
            burstStartTime = nil
            lastBurstKeyTime = nil
            burstChars = 0
        }
        guard let start = burstStartTime,
              let end = lastBurstKeyTime,
              end > start else {
            return
        }
        let duration = end - start
        guard duration >= 2.2, burstChars >= 12 else { return }
        let wpm = (Double(burstChars) / 5.0) / (duration / 60.0)
        guard wpm >= 15.0 && wpm <= 230.0 else { return }

        state.totalBurstCharacters += burstChars
        state.totalBurstSeconds += duration
        let roundedWPM = Int(wpm.rounded())
        if roundedWPM > state.peakBurstWPM {
            state.peakBurstWPM = roundedWPM
        }
        let hour = currentHourFallback ?? Calendar.current.component(.hour, from: Date(timeIntervalSince1970: end))
        if hour >= 0 && hour < 24 {
            state.hourlyBuckets[hour].burstCharacters += burstChars
            state.hourlyBuckets[hour].burstSeconds += duration
        }
    }

    private func finalizeWordLocked(
        at now: TimeInterval,
        bundleID: String?,
        keepChainAlive: Bool
    ) -> WordCompletionOutcome? {
        let candidate = inProgressChars.lowercased()
        defer {
            inProgressChars = ""
            peakBeforeBackspace = nil
            backspacesInCurrentWord = 0
            shownOpportunityForCurrentWord = false
            if !keepChainAlive {
                lastCompletedWord = nil
            }
        }

        guard candidate.count >= 3, validWordChecker(candidate) else {
            if candidate.count >= 3 && candidate.count <= 22 && candidate.allSatisfy({ $0.isASCII && $0.isLetter }) {
                recentInvalidWord = (token: candidate, time: now, sawBackspaceAfter: false)
            } else {
                recentInvalidWord = nil
            }
            lastCompletedWord = nil
            return nil
        }

        if Self.trackedFillerWords.contains(candidate) {
            state.fillerCounts[candidate, default: 0] += 1
        }

        let prev: String?
        if let last = lastCompletedWord,
           now - lastCompletedWordTime <= 6.0,
           lastCompletedBundleID == bundleID,
           last != candidate {
            prev = last
        } else {
            prev = nil
        }

        var mistype = detectMistypeLocked(forFinalLowerWord: candidate, at: now)
        if mistype == nil,
           let recent = recentInvalidWord,
           recent.sawBackspaceAfter,
           now - recent.time <= 5.0,
           recent.token != candidate,
           ObviousTypoCorrector.damerauLevenshtein(recent.token, candidate) <= 2 {
            recordTypoTrapEntryLocked(finalWord: candidate, rawMistype: recent.token)
            mistype = recent.token
        }
        recentInvalidWord = nil

        if keepChainAlive {
            lastCompletedWord = candidate
            lastCompletedWordTime = now
            lastCompletedBundleID = bundleID
        } else {
            lastCompletedWord = nil
        }

        return WordCompletionOutcome(
            word: candidate,
            previousWord: prev,
            bundleID: bundleID,
            detectedTypoMistype: mistype
        )
    }

    private func detectMistypeLocked(forFinalLowerWord finalWord: String, at now: TimeInterval) -> String? {
        guard backspacesInCurrentWord >= 1,
              finalWord.count >= 3,
              let rawPeak = peakBeforeBackspace?.lowercased(),
              rawPeak.count >= 3,
              rawPeak != finalWord,
              !finalWord.hasPrefix(rawPeak),
              abs(rawPeak.count - finalWord.count) <= 4,
              (rawPeak.prefix(2) == finalWord.prefix(2) || ObviousTypoCorrector.damerauLevenshtein(rawPeak, finalWord) <= 2),
              validWordChecker(finalWord) else {
            return nil
        }

        recordTypoTrapEntryLocked(finalWord: finalWord, rawMistype: rawPeak)
        return rawPeak
    }

    private func recordTypoTrapEntryLocked(finalWord: String, rawMistype: String) {
        if var existing = state.typoTraps[finalWord] {
            existing.count += 1
            existing.commonMistype = rawMistype
            state.typoTraps[finalWord] = existing
        } else {
            state.typoTraps[finalWord] = TypoTrapEntry(word: finalWord, commonMistype: rawMistype, count: 1)
            if state.typoTraps.count > 120 {
                let keep = state.typoTraps.values
                    .sorted { $0.count > $1.count }
                    .prefix(90)
                state.typoTraps = Dictionary(uniqueKeysWithValues: keep.map { ($0.word, $0) })
            }
        }
    }

    private func resetCurrentWordLocked(clearLastWord: Bool) {
        inProgressChars = ""
        peakBeforeBackspace = nil
        backspacesInCurrentWord = 0
        shownOpportunityForCurrentWord = false
        if clearLastWord {
            lastCompletedWord = nil
        }
    }

    private func pruneTopDictionary(_ dict: inout [String: Int], limit: Int) {
        let top = dict.sorted { $0.value > $1.value }.prefix(limit)
        dict = Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) })
    }

    private func persistLocked() {
        writeSnapshot(state)
    }

    private func writeSnapshot(_ snapshot: PersistedState) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
