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
        XCTAssertEqual(match3, CompletionMatch(prefix: "inv", fullWord: "investment", suffix: "estment"))
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
}
