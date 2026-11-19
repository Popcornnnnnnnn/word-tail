import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import WordTailCore

private struct MockSpellCompleter: SpellCompleting {
    let handler: (String, String) -> [String]

    func completions(forPartialWordRange range: NSRange, in string: String, language: String) -> [String] {
        let prefix = (string as NSString).substring(with: range)
        return handler(prefix, string)
    }
}

final class WordCompleterTests: XCTestCase {
    private func makeTempHistory() -> UserHistoryStore {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordTailTests-\(UUID().uuidString)", isDirectory: true)
        return UserHistoryStore(fileURL: tempDir.appendingPathComponent("accepted.json"))
    }

    func testRealSystemSpellCompleterGrammarAndSingleWord() {
        let completer = WordCompleter(historyStore: makeTempHistory())

        let match1 = completer.complete(textBeforeCursor: "I major in computer science and I kn")
        XCTAssertEqual(match1, CompletionMatch(prefix: "kn", fullWord: "know", suffix: "ow"))

        let match2 = completer.complete(textBeforeCursor: "She kn")
        XCTAssertEqual(match2, CompletionMatch(prefix: "kn", fullWord: "knows", suffix: "ows"))

        let match3 = completer.complete(textBeforeCursor: "quantitative inv")
        XCTAssertEqual(match3?.prefix, "inv")
        XCTAssertTrue(["investment", "investing", "investor", "investors"].contains(match3?.fullWord))
    }

    func testCandidateCyclingReturnsMultipleSingleWordMatches() {
        let completer = WordCompleter(historyStore: makeTempHistory())
        let list = completer.candidates(textBeforeCursor: "Let us study quantit", limit: 5)
        XCTAssertGreaterThanOrEqual(list.count, 2)
        XCTAssertTrue(list.contains(where: { $0.fullWord == "quantitative" }))
    }

    func testTechLexiconAndCustomPinnedVocabulary() {
        let history = makeTempHistory()
        let emptySpell = MockSpellCompleter { _, _ in [] }
        let completer = WordCompleter(spellCompleter: emptySpell, historyStore: history, enableTechLexicon: true)

        // Built-in Tech/AI lexicon matches "typescr" -> "typescript"
        let ts = completer.complete(textBeforeCursor: "migrate to typescr")
        XCTAssertEqual(ts, CompletionMatch(prefix: "typescr", fullWord: "typescript", suffix: "ipt"))

        // Custom pinned word always ranks #1 and adapts cleanly to both TitleCase and lowercase prefixes
        XCTAssertTrue(history.addCustomWord("OpenBot", persistAsync: false))
        XCTAssertEqual(
            completer.complete(textBeforeCursor: "launch OpenB"),
            CompletionMatch(prefix: "OpenB", fullWord: "OpenBot", suffix: "ot")
        )
        XCTAssertEqual(
            completer.complete(textBeforeCursor: "launch openb"),
            CompletionMatch(prefix: "openb", fullWord: "openbot", suffix: "ot")
        )
    }

    func testSmartTrailingSpaceGuard() {
        XCTAssertTrue(WordCompleter.shouldAppendTrailingSpace(charAfterCursor: nil))
        XCTAssertTrue(WordCompleter.shouldAppendTrailingSpace(charAfterCursor: "\n"))
        XCTAssertFalse(WordCompleter.shouldAppendTrailingSpace(charAfterCursor: " "))
        XCTAssertFalse(WordCompleter.shouldAppendTrailingSpace(charAfterCursor: "."))
        XCTAssertFalse(WordCompleter.shouldAppendTrailingSpace(charAfterCursor: ","))
    }

    func testCasePreservationForSentenceStartAndAllCaps() {
        let mock = MockSpellCompleter { _, _ in ["quantitative", "quantity"] }
        let completer = WordCompleter(spellCompleter: mock, historyStore: makeTempHistory())

        let titleMatch = completer.complete(textBeforeCursor: "Quantit")
        XCTAssertEqual(titleMatch, CompletionMatch(prefix: "Quantit", fullWord: "Quantitative", suffix: "ative"))

        let capsMatch = completer.complete(textBeforeCursor: "QUANTIT")
        XCTAssertEqual(capsMatch, CompletionMatch(prefix: "QUANTIT", fullWord: "QUANTITATIVE", suffix: "ATIVE"))
    }

    func testWordBoundaryPreventsMidWordOverlap() {
        let completer = WordCompleter(historyStore: makeTempHistory())

        XCTAssertNil(completer.complete(textBeforeCursor: "I kn", charAfterCursor: "o"))

        let beforePeriod = completer.complete(textBeforeCursor: "I kn", charAfterCursor: ".")
        XCTAssertEqual(beforePeriod?.suffix, "ow")
    }

    func testIgnoresURLsPathsFlagsAndSnakeCase() {
        let completer = WordCompleter(historyStore: makeTempHistory())

        XCTAssertNil(completer.complete(textBeforeCursor: "https://git"))
        XCTAssertNil(completer.complete(textBeforeCursor: "/usr/lo"))
        XCTAssertNil(completer.complete(textBeforeCursor: "--ver"))
        XCTAssertNil(completer.complete(textBeforeCursor: "user_na"))
        XCTAssertNil(completer.complete(textBeforeCursor: "alice@gm"))
    }

    func testSkipsPossessiveAndSingleCharSuffixes() {
        let mock = MockSpellCompleter { _, _ in ["knows", "colleague's", "colleague"] }
        let completer = WordCompleter(spellCompleter: mock, historyStore: makeTempHistory(), enableTechLexicon: false)

        let shortMock = MockSpellCompleter { _, _ in ["knows"] }
        let shortCompleter = WordCompleter(spellCompleter: shortMock, historyStore: makeTempHistory(), enableTechLexicon: false)
        XCTAssertNil(shortCompleter.complete(textBeforeCursor: "know"))

        let match = completer.complete(textBeforeCursor: "my colleag")
        XCTAssertEqual(match, CompletionMatch(prefix: "colleag", fullWord: "colleague", suffix: "ue"))
    }

    func testPersonalHistoryBoostOverridesDefaultOrder() {
        let history = makeTempHistory()
        let completer = WordCompleter(historyStore: history)

        let initial = completer.complete(textBeforeCursor: "Let us study quantit")
        XCTAssertNotNil(initial)
        XCTAssertNotEqual(initial?.fullWord, "quantitative")

        history.recordAcceptance(of: "quantitative", persistAsync: false)
        let boosted = completer.complete(textBeforeCursor: "Let us study quantit")
        XCTAssertEqual(boosted, CompletionMatch(prefix: "quantit", fullWord: "quantitative", suffix: "ative"))
    }

    func testScreenGeometryBaselineInvariantUnderBottomLineSpacing() {
        let font = NSFont.systemFont(ofSize: 14)
        let glyphH = font.ascender - font.descender
        let exactRect = CGRect(x: 300, y: 200, width: 9, height: glyphH)
        let spacedRect = CGRect(x: 300, y: 200, width: 9, height: 24)

        let pExact = ScreenGeometry.baselinePlacement(forAXCharRect: exactRect, primaryScreenHeight: 1080, font: font)
        let pSpaced = ScreenGeometry.baselinePlacement(forAXCharRect: spacedRect, primaryScreenHeight: 1080, font: font)
        XCTAssertEqual(pExact.anchorX, 309)
        XCTAssertEqual(pExact.baselineY, pSpaced.baselineY, accuracy: 0.01)

        let tightChromiumRect = CGRect(x: 300, y: 200, width: 9, height: 14)
        let pTight = ScreenGeometry.baselinePlacement(forAXCharRect: tightChromiumRect, primaryScreenHeight: 1080, font: font)
        XCTAssertGreaterThan(pTight.baselineY, 1080 - 200 - font.ascender)
    }

    func testPersonalBigramsAndSentenceBoundaryIsolation() {
        let history = makeTempHistory()
        let mock = MockSpellCompleter { _, _ in ["really", "recent", "request", "reason"] }
        let completer = WordCompleter(spellCompleter: mock, historyStore: history, enableTechLexicon: false)

        // Default order before learning bigram
        XCTAssertEqual(completer.complete(textBeforeCursor: "pull re")?.fullWord, "really")

        // Learn "pull -> request" passively from natural typing
        history.recordNaturalWordUsage(word: "request", previousWord: "pull", bundleID: "com.openai.codex", persistAsync: false)

        // After "pull ", "re" ranks "request" #1!
        let bigramMatch = completer.complete(textBeforeCursor: "open a pull re")
        XCTAssertEqual(bigramMatch, CompletionMatch(prefix: "re", fullWord: "request", suffix: "quest"))
        XCTAssertEqual(bigramMatch?.previousWord, "pull")

        // Sentence boundary ("pull. re") must NOT trigger the "pull" bigram
        XCTAssertEqual(completer.complete(textBeforeCursor: "push and pull. re")?.fullWord, "really")
    }

    func testPerAppVocabularyAffinitySeparatesCodeChatFromMail() {
        let history = makeTempHistory()
        let mock = MockSpellCompleter { _, _ in ["impact", "important", "implementation"] }
        let completer = WordCompleter(spellCompleter: mock, historyStore: history, enableTechLexicon: false)

        history.recordAcceptance(of: "implementation", previousWord: nil, bundleID: "com.openai.codex", persistAsync: false)
        history.recordAcceptance(of: "important", previousWord: nil, bundleID: "com.apple.mail", persistAsync: false)

        XCTAssertEqual(
            completer.complete(textBeforeCursor: "check the imp", bundleID: "com.openai.codex")?.fullWord,
            "implementation"
        )
        XCTAssertEqual(
            completer.complete(textBeforeCursor: "check the imp", bundleID: "com.apple.mail")?.fullWord,
            "important"
        )
    }

    func testTypingHabitTrackerTypoTrapsBurstWPMAndPrivacyGuard() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordTailHabits-\(UUID().uuidString)", isDirectory: true)
        var simulatedTime = Date(timeIntervalSince1970: 1_700_000_000)
        let validSet: Set<String> = ["definitely", "receive", "actually", "pull", "request"]

        let tracker = TypingHabitTracker(
            fileURL: tempDir.appendingPathComponent("insights.json"),
            nowProvider: { simulatedTime },
            validWordChecker: { validSet.contains($0.lowercased()) }
        )
        let history = UserHistoryStore(fileURL: tempDir.appendingPathComponent("accepted.json"))
        let mock = MockSpellCompleter { _, _ in ["define", "definition", "definitely"] }
        let completer = WordCompleter(spellCompleter: mock, historyStore: history, habitTracker: tracker, enableTechLexicon: false)

        // 1. Simulate mistyping "definately", backspacing "ately", and finishing "definitely "
        for ch in "definately" {
            simulatedTime.addTimeInterval(0.14)
            tracker.recordTypedCharacters(String(ch), bundleID: "com.apple.Notes", persistAsync: false)
        }
        for _ in 0..<5 {
            simulatedTime.addTimeInterval(0.10)
            tracker.recordBackspace()
        }
        var lastOutcome: WordCompletionOutcome?
        for ch in "itely " {
            simulatedTime.addTimeInterval(0.14)
            if let out = tracker.recordTypedCharacters(String(ch), bundleID: "com.apple.Notes", persistAsync: false) {
                lastOutcome = out
            }
        }

        XCTAssertEqual(lastOutcome?.word, "definitely")
        XCTAssertEqual(lastOutcome?.detectedTypoMistype, "definately")

        // Typo trap automatically boosts "definitely" to #1 ahead of "define" / "definition"!
        XCTAssertEqual(completer.complete(textBeforeCursor: "I defi")?.fullWord, "definitely")

        // 2. Privacy check: non-dictionary / secret token mistypes must NEVER be stored
        for ch in "mySecretKey" {
            simulatedTime.addTimeInterval(0.12)
            tracker.recordTypedCharacters(String(ch), bundleID: "com.apple.Notes", persistAsync: false)
        }
        tracker.recordBackspace()
        let rejected = tracker.recordTypedCharacters("z ", bundleID: "com.apple.Notes", persistAsync: false)
        XCTAssertNil(rejected)

        // 3. Suggestion opportunity deduplication + Tab acceptance + IME switch
        tracker.recordSuggestionShownOncePerWord()
        tracker.recordSuggestionShownOncePerWord() // duplicate within same word stem ignored
        _ = tracker.recordTabAccepted(
            fullWord: "actually",
            insertedText: "ally ",
            previousWordFromContext: nil,
            bundleID: "com.apple.Notes",
            persistAsync: false
        )
        tracker.recordIMESwitch(persistAsync: false)

        let snap = tracker.snapshot()
        XCTAssertEqual(snap.typoTraps.count, 1)
        XCTAssertEqual(snap.typoTraps.first?.word, "definitely")
        XCTAssertEqual(snap.typoTraps.first?.commonMistype, "definately")
        XCTAssertEqual(snap.tabsAccepted, 1)
        XCTAssertEqual(snap.suggestionsShown, 1)
        XCTAssertEqual(snap.hitRatePercent, 100)
        XCTAssertEqual(snap.charactersSaved, 5)
        XCTAssertGreaterThan(snap.averageBurstWPM, 40)
        XCTAssertEqual(snap.imeSwitches, 1)
        XCTAssertTrue(snap.fillerHabits.contains(where: { $0.word == "actually" }))
    }

    func testKeyStatsStoreHardwareTelemetrySecurePrivacyAndExternalImport() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordTailKeyStats-\(UUID().uuidString)", isDirectory: true)
        let simulatedTime = Date(timeIntervalSince1970: 1_763_500_000)
        let store = KeyStatsStore(
            fileURL: tempDir.appendingPathComponent("keystats.json"),
            nowProvider: { simulatedTime }
        )

        // 1. Normal key press + Cmd+C shortcut + auto-repeat ignored in keyPresses
        store.recordKeyDown(
            keyCode: 8, // C
            rawFlags: CGEventFlags.maskCommand.rawValue,
            isAutoRepeat: false,
            isSecureInput: false,
            isRomanLayout: true,
            appBundleID: "com.openai.codex",
            appName: "Codex"
        )
        store.recordKeyDown(
            keyCode: 0, // A (auto-repeat)
            rawFlags: 0,
            isAutoRepeat: true,
            isSecureInput: false,
            isRomanLayout: true,
            appBundleID: "com.openai.codex",
            appName: "Codex"
        )

        // 2. Secure input (password field): counts total keystroke anonymously without leaking letter identity into heatmap!
        store.recordKeyDown(
            keyCode: 35, // P
            rawFlags: 0,
            isAutoRepeat: false,
            isSecureInput: true,
            isRomanLayout: true,
            appBundleID: "com.apple.Safari",
            appName: "Safari"
        )

        // 3. Mouse clicks, mouse movement, and scroll distance
        store.recordMouseClick(button: .left, appBundleID: "com.openai.codex", appName: "Codex")
        store.recordMouseMove(to: CGPoint(x: 100, y: 100))
        store.recordMouseMove(to: CGPoint(x: 500, y: 400)) // +500 px
        store.recordScroll(deltaX: 0, deltaY: 1000, appBundleID: "com.openai.codex", appName: "Codex")
        store.flushNow()

        let today = store.snapshot(for: .today)
        XCTAssertEqual(today.totalKeyPresses, 2)
        XCTAssertEqual(today.totalClicks, 1)
        XCTAssertEqual(today.keyHeatmap["C"], 1)
        XCTAssertNil(today.keyHeatmap["P"]) // password character never recorded in heatmap!
        XCTAssertEqual(today.topShortcuts.first, RankedCountItem(label: "⌘C", count: 1))
        XCTAssertGreaterThan(today.mouseDistanceMeters, 0.12)
        XCTAssertGreaterThan(today.scrollDistanceMeters, 0.25)

        // 4. Native export + external `debugtheworldbot/keyStats` JSON import compatibility
        let externalJSON = """
        {
          "version": 1,
          "history": {
            "2026-11-10": {
              "keyPresses": 3200,
              "keyPressCounts": { "Space": 600, "Cmd+V": 45, "Delete": 120 },
              "leftClicks": 410,
              "rightClicks": 30,
              "mouseDistance": 100000,
              "scrollDistance": 50000,
              "peakKPS": 11,
              "appStats": {
                "com.apple.Notes": {
                  "bundleId": "com.apple.Notes",
                  "displayName": "Notes",
                  "keyPresses": 1200,
                  "leftClicks": 90,
                  "scrollDistance": 8000
                }
              }
            }
          }
        }
        """.data(using: .utf8)!

        let importedDays = try store.importJSONData(externalJSON, merge: true)
        XCTAssertEqual(importedDays, 1)

        let allTime = store.snapshot(for: .allTime)
        XCTAssertEqual(allTime.totalKeyPresses, 3202)
        XCTAssertEqual(allTime.totalClicks, 441)
        XCTAssertTrue(allTime.topShortcuts.contains(RankedCountItem(label: "⌘V", count: 45)))
        XCTAssertTrue(allTime.topApps.contains(where: { $0.bundleID == "com.apple.Notes" && $0.keyPresses == 1200 }))
    }

    func testContractionsSentenceCapitalizationAndDeveloperSafeGuards() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordTailTypo-\(UUID().uuidString)", isDirectory: true)
        let adaptive = AdaptiveCorrectionStore(fileURL: tempDir.appendingPathComponent("adaptive.json"))
        let validWords: Set<String> = ["hello", "world", "next", "lets", "the", "know", "definitely"]

        // 1. Contractions & joined-word patterns ("im" -> "I'm", "dont" -> "don't", "alot" -> "a lot")
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "im",
                lineContextIncludingWord: "so im",
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: adaptive,
                habitTracker: nil,
                historyStore: nil,
                validWordChecker: { validWords.contains($0) }
            ),
            "I'm"
        )
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "dont",
                lineContextIncludingWord: "we dont",
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: adaptive,
                habitTracker: nil,
                historyStore: nil,
                validWordChecker: { validWords.contains($0) }
            ),
            "don't"
        )
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "alot",
                lineContextIncludingWord: "thanks alot",
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: adaptive,
                habitTracker: nil,
                historyStore: nil,
                validWordChecker: { validWords.contains($0) }
            ),
            "a lot"
        )

        // 2. Sentence-start capitalization (2-letter "do", "hello", after period) + standalone "i" + context-aware "lets" -> "Let's"
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "do",
                lineContextIncludingWord: "do",
                isAtDocumentStart: true,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: adaptive,
                habitTracker: nil,
                historyStore: nil
            ),
            "Do"
        )
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "hello",
                lineContextIncludingWord: "hello",
                isAtDocumentStart: true,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: adaptive,
                habitTracker: nil,
                historyStore: nil,
                validWordChecker: { validWords.contains($0) }
            ),
            "Hello"
        )
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "next",
                lineContextIncludingWord: "All done. next",
                isAtDocumentStart: false,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: adaptive,
                habitTracker: nil,
                historyStore: nil,
                validWordChecker: { validWords.contains($0) }
            ),
            "Next"
        )
        // Soft-wrapped line or plain newline WITHOUT period ("...behind the back of a word\nrather") must NEVER capitalize!
        XCTAssertNil(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "rather",
                lineContextIncludingWord: "just behind the back of a word\nrather",
                isAtDocumentStart: false,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: adaptive,
                habitTracker: nil,
                historyStore: nil,
                validWordChecker: { _ in true }
            )
        )
        XCTAssertNil(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "rather",
                lineContextIncludingWord: "just behind the back of a word rather",
                isAtDocumentStart: false,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: adaptive,
                habitTracker: nil,
                historyStore: nil,
                validWordChecker: { _ in true }
            )
        )
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "teh",
                lineContextIncludingWord: "teh",
                isAtDocumentStart: true,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: adaptive,
                habitTracker: nil,
                historyStore: nil,
                validWordChecker: { validWords.contains($0) }
            ),
            "The"
        )
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "i",
                lineContextIncludingWord: "think i",
                isAtDocumentStart: false,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: adaptive,
                habitTracker: nil,
                historyStore: nil,
                validWordChecker: { validWords.contains($0) }
            ),
            "I"
        )
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "lets",
                lineContextIncludingWord: "lets",
                isAtDocumentStart: true,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: adaptive,
                habitTracker: nil,
                historyStore: nil,
                validWordChecker: { validWords.contains($0) }
            ),
            "Let's"
        )
        // Mid-sentence "lets" ("it lets") must stay untouched!
        XCTAssertNil(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "lets",
                lineContextIncludingWord: "it lets",
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: adaptive,
                habitTracker: nil,
                historyStore: nil,
                validWordChecker: { validWords.contains($0) }
            )
        )

        // 3. Abbreviations ("e.g. "), mid-sentence words, CLI commands ("git"), and camelCase ("macOS") stay untouched!
        XCTAssertNil(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "next",
                lineContextIncludingWord: "see e.g. next",
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: adaptive,
                habitTracker: nil,
                historyStore: nil,
                validWordChecker: { validWords.contains($0) }
            )
        )
        XCTAssertNil(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "git",
                lineContextIncludingWord: "git",
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: adaptive,
                habitTracker: nil,
                historyStore: nil,
                validWordChecker: { _ in true }
            )
        )
        XCTAssertNil(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "macOS",
                lineContextIncludingWord: "macOS",
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: adaptive,
                habitTracker: nil,
                historyStore: nil,
                validWordChecker: { _ in true }
            )
        )
    }

    func testLearnableAutoCorrectPositiveGraduationNegativeUndoMutingAndInlineTabFix() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordTailLearn-\(UUID().uuidString)", isDirectory: true)
        let adaptive = AdaptiveCorrectionStore(fileURL: tempDir.appendingPathComponent("adaptive.json"))
        let history = UserHistoryStore(fileURL: tempDir.appendingPathComponent("accepted.json"))
        let emptySpell = MockSpellCompleter { _, _ in [] }
        let completer = WordCompleter(
            spellCompleter: emptySpell,
            historyStore: history,
            adaptiveStore: adaptive,
            enableTechLexicon: false,
            enableInlineTypoFix: true
        )

        // 1. Inline Tab fix catches partial/full mistypes ("definatel" -> "definitely") with minimal-diff edit!
        let inlineFix = completer.complete(textBeforeCursor: "I definatel")
        XCTAssertEqual(inlineFix?.fullWord, "definitely")
        XCTAssertEqual(inlineFix?.isTypoCorrection, true)
        XCTAssertEqual(inlineFix?.replacementDeleteCount, 4) // deletes "atel"
        XCTAssertEqual(inlineFix?.suffix, "itely")           // inserts "itely"

        // 2. Positive self-learning: observing a multi-edit personal mistype ("fnctn" -> "function") twice graduates it to Space auto-correct!
        XCTAssertNil(ObviousTypoCorrector.spaceAutoCorrection(forWord: "fnctn", adaptiveStore: adaptive, habitTracker: nil, historyStore: history))
        adaptive.recordObservedCorrection(mistype: "fnctn", corrected: "function", persistAsync: false)
        adaptive.recordObservedCorrection(mistype: "fnctn", corrected: "function", persistAsync: false)
        XCTAssertEqual(
            ObviousTypoCorrector.spaceAutoCorrection(forWord: "fnctn", adaptiveStore: adaptive, habitTracker: nil, historyStore: history),
            "function"
        )

        // 3. Negative self-learning: undoing "cant" -> "can't" twice with Backspace mutes "cant" automatically!
        XCTAssertEqual(
            ObviousTypoCorrector.spaceAutoCorrection(forWord: "cant", adaptiveStore: adaptive, habitTracker: nil, historyStore: history),
            "can't"
        )
        XCTAssertFalse(adaptive.recordUndo(forTrigger: "cant", persistAsync: false))
        XCTAssertTrue(adaptive.recordUndo(forTrigger: "cant", persistAsync: false))
        XCTAssertNil(
            ObviousTypoCorrector.spaceAutoCorrection(forWord: "cant", adaptiveStore: adaptive, habitTracker: nil, historyStore: history)
        )

        // 4. Custom shorthand rule ("omw" -> "on my way") works on both Tab and Space
        XCTAssertTrue(adaptive.addCustomRule(trigger: "omw", replacement: "on my way", persistAsync: false))
        XCTAssertEqual(completer.complete(textBeforeCursor: "hey omw")?.fullWord, "on my way")
        XCTAssertEqual(
            ObviousTypoCorrector.spaceAutoCorrection(forWord: "omw", adaptiveStore: adaptive, habitTracker: nil, historyStore: history),
            "on my way"
        )
    }

    func testMidSentenceInsertionDirectlyAgainstFollowingWordWithoutRearSpace() {
        let completer = WordCompleter(historyStore: makeTempHistory())

        // Inserting "kn" directly against "the" ("I want to kn|the answer" — space in front, NO space in rear):
        let inserted = completer.complete(
            textBeforeCursor: "I want to kn",
            charAfterCursor: "t",
            textAfterCursorOnLine: "the answer"
        )
        XCTAssertEqual(inserted, CompletionMatch(prefix: "kn", fullWord: "know", suffix: "ow"))
        // Accepting with Tab must append a separating space before "the" even if appendSpacePreference is false!
        XCTAssertTrue(WordCompleter.shouldAppendSpaceOnTab(charAfterCursor: "t", appendSpacePreference: false))

        // Whereas cursor inside a single existing word ("I kn|ow") must STILL stay silent!
        let insideSingleWord = completer.complete(
            textBeforeCursor: "I kn",
            charAfterCursor: "o",
            textAfterCursorOnLine: "ow"
        )
        XCTAssertNil(insideSingleWord)
    }

    func testConservativeMultiWordPhraseIdiomsLearningPrivacyAndPartialWordSplit() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordTailPhrases-\(UUID().uuidString)", isDirectory: true)
        let phraseFile = tempDir.appendingPathComponent("learned_phrases.json")
        let predictor = PhrasePredictor(fileURL: phraseFile)
        let completer = WordCompleter(
            historyStore: makeTempHistory(),
            phrasePredictor: predictor,
            enablePhrasePrediction: true
        )

        // 1. Built-in high-certainty idioms after Space ("as far " -> "as I'm concerned", "on the other " -> "hand")
        let asFar = completer.candidates(textBeforeCursor: "as far ", limit: 3)
        XCTAssertEqual(asFar.first, CompletionMatch(prefix: "", fullWord: "as I'm concerned", suffix: "as I'm concerned"))
        XCTAssertTrue(asFar.map(\.fullWord).contains("as I know"))

        // Mid-word 1-letter continuation ("as far a" -> "as I'm concerned")
        let asFarMid = completer.complete(textBeforeCursor: "as far a")
        XCTAssertEqual(asFarMid, CompletionMatch(prefix: "a", fullWord: "as I'm concerned", suffix: "s I'm concerned"))

        // Partial 1-word acceptance (`⌥ →`) splits cleanly word-by-word!
        let step1 = PhrasePredictor.splitFirstWord(of: "as I'm concerned")
        XCTAssertEqual(step1.acceptedChunk, "as ")
        XCTAssertEqual(step1.remainingPhrase, "I'm concerned")
        let step2 = PhrasePredictor.splitFirstWord(of: step1.remainingPhrase ?? "")
        XCTAssertEqual(step2.acceptedChunk, "I'm ")
        XCTAssertEqual(step2.remainingPhrase, "concerned")

        // 2. Conservative guardrails: generic "in the ", sentence boundary "Hello. far ", and URL "https://as far " stay silent!
        XCTAssertNil(completer.complete(textBeforeCursor: "in the "))
        XCTAssertNil(completer.complete(textBeforeCursor: "Hello. far "))
        XCTAssertNil(completer.complete(textBeforeCursor: "https://as far "))

        // 3. Privacy & self-learning:
        //    - 1st time typing a personal phrase ("in my humble opinion") stays in RAM probation ONLY (no disk file created)!
        for (idx, w) in ["in", "my", "humble", "opinion"].enumerated() {
            predictor.observeCompletedWord(w, endedSentence: idx == 3, persistAsync: false)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: phraseFile.path))
        XCTAssertNil(completer.complete(textBeforeCursor: "in my "))

        //    - 2nd time promotes to disk (`count == 2`), still conservative (waits for 3x)
        for (idx, w) in ["in", "my", "humble", "opinion"].enumerated() {
            predictor.observeCompletedWord(w, endedSentence: idx == 3, persistAsync: false)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: phraseFile.path))
        XCTAssertNil(completer.complete(textBeforeCursor: "in my "))

        //    - 3rd time (`count >= 3` & `confidence >= 50%`) activates conservative personal phrase prediction!
        for (idx, w) in ["in", "my", "humble", "opinion"].enumerated() {
            predictor.observeCompletedWord(w, endedSentence: idx == 3, persistAsync: false)
        }
        let learnedMatch = completer.complete(textBeforeCursor: "in my ")
        XCTAssertEqual(learnedMatch?.fullWord, "humble opinion")

        // 4. Custom pinned phrases work immediately!
        XCTAssertTrue(predictor.addCustomPhrase("happy to review this pull request", persistAsync: false))
        XCTAssertEqual(
            completer.complete(textBeforeCursor: "happy to ")?.fullWord,
            "review this pull request"
        )
    }

    func testRuntimeHotPathZeroIPCSpaceGateIndexedLexiconAndSpellCache() {
        // 1. Mid-sentence words preceded by `<word> ` or `<word>, ` skip synchronous AX IPC on Space!
        XCTAssertFalse(
            ObviousTypoCorrector.needsLiveSentenceContextOnSpace(
                forWord: "rather",
                rollingBuffer: "back of a word rather",
                autoCorrectTypos: true,
                autoCapitalizeSentences: true
            )
        )
        XCTAssertFalse(
            ObviousTypoCorrector.needsLiveSentenceContextOnSpace(
                forWord: "im",
                rollingBuffer: "well, im",
                autoCorrectTypos: true,
                autoCapitalizeSentences: true
            )
        )
        // Standalone "i" ("i" -> "I"), CLI safe words ("git"), and already-capitalized words also skip AX IPC!
        XCTAssertFalse(
            ObviousTypoCorrector.needsLiveSentenceContextOnSpace(
                forWord: "i",
                rollingBuffer: "i",
                autoCorrectTypos: true,
                autoCapitalizeSentences: true
            )
        )
        XCTAssertFalse(
            ObviousTypoCorrector.needsLiveSentenceContextOnSpace(
                forWord: "git",
                rollingBuffer: "git",
                autoCorrectTypos: true,
                autoCapitalizeSentences: true
            )
        )

        // 2. First word in fresh buffer ("do") or word right after period ("done. next") DOES request live sentence context!
        XCTAssertTrue(
            ObviousTypoCorrector.needsLiveSentenceContextOnSpace(
                forWord: "do",
                rollingBuffer: "do",
                autoCorrectTypos: true,
                autoCapitalizeSentences: true
            )
        )
        XCTAssertTrue(
            ObviousTypoCorrector.needsLiveSentenceContextOnSpace(
                forWord: "next",
                rollingBuffer: "done. next",
                autoCorrectTypos: true,
                autoCapitalizeSentences: true
            )
        )

        // 3. First-letter indexed TechLexicon & cached spellchecker return consistent results
        let qMatches = TechLexicon.matching(lowercasedPrefix: "quant")
        XCTAssertTrue(qMatches.contains("quantitative"))
        XCTAssertTrue(TypingHabitTracker.defaultValidEnglishWordCheck("sentence"))
        XCTAssertTrue(TypingHabitTracker.defaultValidEnglishWordCheck("sentence")) // cache hit
        XCTAssertFalse(TypingHabitTracker.defaultValidEnglishWordCheck("zzzzqwxk"))
        XCTAssertFalse(TypingHabitTracker.defaultValidEnglishWordCheck("zzzzqwxk")) // negative cache hit

        // 4. General QWERTY / transposition / missing-letter Space auto-correction:
        //    Fixes "aslo" -> "Also" (at sentence start) and "similat" -> "similar", while leaving brand/tech terms ("awesun", "vite", "cuda", "wip") untouched!
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "aslo",
                lineContextIncludingWord: "aslo",
                isAtDocumentStart: true,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: nil,
                habitTracker: nil,
                historyStore: nil
            ),
            "Also"
        )
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "similat",
                lineContextIncludingWord: "check if there any similat",
                isAtDocumentStart: false,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: nil,
                habitTracker: nil,
                historyStore: nil
            ),
            "similar"
        )
        XCTAssertEqual(
            ObviousTypoCorrector.spaceAutoCorrection(forWord: "functoin", adaptiveStore: nil, habitTracker: nil, historyStore: nil),
            "function"
        )
        XCTAssertNil(
            ObviousTypoCorrector.spaceAutoCorrection(forWord: "awesun", adaptiveStore: nil, habitTracker: nil, historyStore: nil)
        )
        XCTAssertNil(
            ObviousTypoCorrector.spaceAutoCorrection(forWord: "vite", adaptiveStore: nil, habitTracker: nil, historyStore: nil)
        )
        XCTAssertNil(
            ObviousTypoCorrector.spaceAutoCorrection(forWord: "cuda", adaptiveStore: nil, habitTracker: nil, historyStore: nil)
        )

        // 5. Contractions & possessives with typed ASCII `'` or Smart Quote `’` at sentence start ("This should be ok? this's" -> "This's")
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "this's",
                lineContextIncludingWord: "This should be ok? this's",
                isAtDocumentStart: false,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: nil,
                habitTracker: nil,
                historyStore: nil
            ),
            "This's"
        )
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "this's",
                lineContextIncludingWord: "This should be ok? this’s",
                isAtDocumentStart: false,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: nil,
                habitTracker: nil,
                historyStore: nil
            ),
            "This's"
        )
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "don't",
                lineContextIncludingWord: "don't",
                isAtDocumentStart: true,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: nil,
                habitTracker: nil,
                historyStore: nil
            ),
            "Don't"
        )
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "today's",
                lineContextIncludingWord: "Done! today's",
                isAtDocumentStart: false,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: nil,
                habitTracker: nil,
                historyStore: nil
            ),
            "Today's"
        )

        // 6. Smart 2nd-word CLI -> Prose promotion ("git status" stays lowercase, while "git is" -> "Git is"!)
        //    + Mixed-case brands ("macos" -> "macOS", "iphone" -> "iPhone") & prose tech nouns ("repo" -> "Repo")
        XCTAssertNil(
            ObviousTypoCorrector.evaluateSpaceTransform(
                forWord: "git",
                lineContextIncludingWord: "git",
                isAtDocumentStart: true,
                sliceStartsAtDocumentZero: true,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: nil,
                habitTracker: nil,
                historyStore: nil
            )
        )
        XCTAssertNil(
            ObviousTypoCorrector.evaluateSpaceTransform(
                forWord: "status",
                lineContextIncludingWord: "git status",
                isAtDocumentStart: false,
                sliceStartsAtDocumentZero: true,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: nil,
                habitTracker: nil,
                historyStore: nil
            )
        )
        XCTAssertEqual(
            ObviousTypoCorrector.evaluateSpaceTransform(
                forWord: "is",
                lineContextIncludingWord: "git is",
                isAtDocumentStart: false,
                sliceStartsAtDocumentZero: true,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: nil,
                habitTracker: nil,
                historyStore: nil
            ),
            SpaceTransformResult(replacedSourceSpan: "git is", replacementText: "Git is")
        )
        XCTAssertEqual(
            ObviousTypoCorrector.evaluateSpaceTransform(
                forWord: "isnt",
                lineContextIncludingWord: "Done. docker isnt",
                isAtDocumentStart: false,
                sliceStartsAtDocumentZero: false,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: nil,
                habitTracker: nil,
                historyStore: nil
            ),
            SpaceTransformResult(replacedSourceSpan: "docker isnt", replacementText: "Docker isn't")
        )
        // Mid-sentence "git is" ("because git is") stays lowercase!
        XCTAssertNil(
            ObviousTypoCorrector.evaluateSpaceTransform(
                forWord: "is",
                lineContextIncludingWord: "because git is",
                isAtDocumentStart: false,
                sliceStartsAtDocumentZero: true,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: nil,
                habitTracker: nil,
                historyStore: nil
            )
        )
        // Mixed-case brands ("macos" -> "macOS", "iphone" -> "iPhone") & prose tech nouns ("repo" -> "Repo")
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "macos",
                lineContextIncludingWord: "macos",
                isAtDocumentStart: true,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: nil,
                habitTracker: nil,
                historyStore: nil
            ),
            "macOS"
        )
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "iphone",
                lineContextIncludingWord: "my iphone",
                isAtDocumentStart: false,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: nil,
                habitTracker: nil,
                historyStore: nil
            ),
            "iPhone"
        )
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: "repo",
                lineContextIncludingWord: "repo",
                isAtDocumentStart: true,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: nil,
                habitTracker: nil,
                historyStore: nil
            ),
            "Repo"
        )

        // 7. Punctuation-delimited starters & contractions ("wow," -> "Wow,", "thanks!" -> "Thanks!", "yes. " -> "Yes. ", while "notes.md" & "e.g. " skip!)
        let commaTarget = ObviousTypoCorrector.extractPunctuationOrSpaceTarget(rollingBuffer: "wow", typedDelimiter: ",")
        XCTAssertEqual(commaTarget?.word, "wow")
        XCTAssertEqual(commaTarget?.outputDelimiter, ",")
        XCTAssertEqual(
            ObviousTypoCorrector.spaceReplacement(
                forWord: commaTarget!.word,
                lineContextIncludingWord: commaTarget!.bufferUpToWord,
                isAtDocumentStart: true,
                autoCorrectTypos: true,
                autoCapitalizeSentences: true,
                adaptiveStore: nil,
                habitTracker: nil,
                historyStore: nil
            ),
            "Wow"
        )

        let dotSpaceTarget = ObviousTypoCorrector.extractPunctuationOrSpaceTarget(rollingBuffer: "yes.", typedDelimiter: " ")
        XCTAssertEqual(dotSpaceTarget?.word, "yes")
        XCTAssertEqual(dotSpaceTarget?.existingTrailingDot, true)

        // Abbreviations ("e.g.") and domain/file dots ("notes.md.") are never extracted as standalone dot-space targets!
        XCTAssertNil(ObviousTypoCorrector.extractPunctuationOrSpaceTarget(rollingBuffer: "e.g.", typedDelimiter: " "))
        XCTAssertNil(ObviousTypoCorrector.extractPunctuationOrSpaceTarget(rollingBuffer: "notes.md", typedDelimiter: "."))
    }
}
