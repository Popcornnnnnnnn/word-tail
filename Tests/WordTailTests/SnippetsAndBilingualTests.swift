import Foundation
import XCTest
@testable import WordTailCore

final class SnippetsAndBilingualTests: XCTestCase {
    func testTriggerRequiresAnExplicitDelimiter() {
        for trigger in [";date", "//sig", ":ok", "!go", "@me", "#tag", "\\sig", ";" + String(repeating: "a", count: 23)] {
            XCTAssertTrue(SnippetStore.isValidTrigger(trigger), trigger)
        }
        for trigger in ["", "date", ";", "$date", ";with space", ";with\ttab", ";with\nline", ";with\u{00A0}space",
                        ";" + String(repeating: "a", count: 24)] {
            XCTAssertFalse(SnippetStore.isValidTrigger(trigger), trigger)
        }
    }

    func testMatchRequiresATriggerAtTheEndWithASafeBoundary() {
        let store = SnippetStore(directoryURL: temporaryDirectory())
        XCTAssertEqual(Set(store.snippets.map(\.trigger)), [";date", ";iso", ";time", ";meet", ";pr", ";clip"])
        for text in ["https://foo.com;date", "abc;date", ";date extra", " ;date "] {
            XCTAssertNil(store.match(textBeforeCursor: text, bundleID: nil), text)
        }
        for text in [";date", " ;date", "notes ;date", "\n;date", "notes\r\n;date", ";;date"] {
            let match = store.match(textBeforeCursor: text, bundleID: nil)
            XCTAssertEqual(match?.trigger, ";date", text)
            XCTAssertEqual(match?.deleteCount, 5, text)
        }
    }

    func testMatchPrefersTheLongestEligibleTrigger() {
        let store = SnippetStore(directoryURL: temporaryDirectory())
        XCTAssertTrue(store.addOrUpdateSnippet(TextSnippet(trigger: "/sig", title: "Short", body: "Short")))
        XCTAssertTrue(store.addOrUpdateSnippet(TextSnippet(trigger: "//sig", title: "Long", body: "Long")))
        XCTAssertEqual(store.match(textBeforeCursor: " //sig", bundleID: nil)?.expandedText, "Long")
        XCTAssertNil(store.match(textBeforeCursor: " /sig!", bundleID: nil))
    }

    func testDateTimeWeekdayAndClipboardMacros() throws {
        let calendar = Calendar(identifier: .gregorian)
        let localDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 11, day: 26, hour: 14, minute: 5)))
        let expanded = SnippetStore.expand(
            body: "{date}|{date:yyyy/MM/dd}|{time}|{weekday}|{clipboard}",
            now: localDate,
            clipboardText: "copied {cursor}\ntext"
        )
        XCTAssertEqual(expanded.text, "2024-11-26|2024/11/26|14:05|Tuesday|copied {cursor}\ntext")
        XCTAssertEqual(expanded.cursorBackSteps, 0)
        XCTAssertEqual(SnippetStore.expand(body: "[{clipboard}]").text, "[]")
        XCTAssertEqual(SnippetStore.expand(body: "[{clipboard}]", clipboardText: "").text, "[]")
        XCTAssertEqual(
            SnippetStore.expand(body: "{date:}|{date:yyyy 'missing quote}|{date:yyyy J}|{unknown}", now: localDate).text,
            "{date:}|{date:yyyy 'missing quote}|{date:yyyy J}|{unknown}"
        )
        XCTAssertEqual(SnippetStore.expand(body: "{date:yyyy 'year'}", now: localDate).text, "2024 year")
    }

    func testISODateTimeOmitsFractionalSeconds() throws {
        let iso = "2024-11-26T14:05:06Z"
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: iso)).addingTimeInterval(0.25)
        XCTAssertEqual(SnippetStore.expand(body: "{iso}", now: date).text, iso)
    }

    func testCursorCountsExpandedGraphemesAfterFirstMarker() {
        let store = SnippetStore(directoryURL: temporaryDirectory())
        let snippet = TextSnippet(trigger: ";reply", title: "Reply", body: "Hi {cursor}👩🏽‍💻\r\n{clipboard}{cursor}🙂")
        XCTAssertTrue(store.addOrUpdateSnippet(snippet))

        let match = store.match(textBeforeCursor: "Notes ;reply", bundleID: nil, clipboardText: "e\u{0301}")
        XCTAssertEqual(match?.expandedText, "Hi 👩🏽‍💻\r\ne\u{0301}🙂")
        XCTAssertEqual(match?.cursorBackSteps, 4)
        XCTAssertEqual(SnippetStore.expand(body: "end{cursor}{cursor}").cursorBackSteps, 0)
    }

    func testScopedAndDisabledSnippetsDoNotMatchOutsideTheirRules() {
        let store = SnippetStore(directoryURL: temporaryDirectory())
        let app = "com.apple.Notes"
        let snippet = TextSnippet(trigger: ";sig", title: "Signature", body: "Thanks!", scopedBundleIDs: [app])
        XCTAssertTrue(store.addOrUpdateSnippet(snippet))
        XCTAssertFalse(store.addOrUpdateSnippet(TextSnippet(trigger: "sig", title: "Invalid", body: "Invalid")))
        XCTAssertNil(store.match(textBeforeCursor: ";sig", bundleID: nil))
        XCTAssertNil(store.match(textBeforeCursor: ";sig", bundleID: "com.apple.mail"))
        XCTAssertEqual(store.match(textBeforeCursor: ";sig", bundleID: app)?.expandedText, "Thanks!")
        XCTAssertTrue(store.toggleSnippet(id: snippet.id, isEnabled: false))
        XCTAssertNil(store.match(textBeforeCursor: ";sig", bundleID: app))
        XCTAssertTrue(store.toggleSnippet(id: snippet.id, isEnabled: true))
        XCTAssertNotNil(store.match(textBeforeCursor: ";sig", bundleID: app))
    }

    func testJSONRoundTripPreservesEditedAndDeletedStarterRecords() throws {
        let sourceURL = temporaryDirectory()
        let source = SnippetStore(directoryURL: sourceURL)
        var edited = try XCTUnwrap(source.snippets.first { $0.trigger == ";date" })
        edited.body = "{date:yyyy/MM/dd}"
        XCTAssertTrue(source.addOrUpdateSnippet(edited))
        let deleted = try XCTUnwrap(source.snippets.first { $0.trigger == ";iso" })
        XCTAssertTrue(source.deleteSnippet(id: deleted.id))
        let custom = TextSnippet(trigger: ":ok", title: "Acknowledgment", body: "Got it.", isEnabled: false)
        XCTAssertTrue(source.addOrUpdateSnippet(custom))

        let archive = try source.exportJSON()
        let targetURL = temporaryDirectory()
        let target = SnippetStore(directoryURL: targetURL)
        XCTAssertEqual(try target.importJSON(archive), 3)
        XCTAssertEqual(try target.importJSON(archive), 0)
        XCTAssertEqual(try target.exportJSON(), archive)
        for directory in [sourceURL, targetURL] {
            let reloaded = SnippetStore(directoryURL: directory)
            XCTAssertEqual(reloaded.exportLocalShard(), source.exportLocalShard())
            XCTAssertNil(reloaded.match(textBeforeCursor: ";iso", bundleID: nil))
            XCTAssertNil(reloaded.match(textBeforeCursor: ":ok", bundleID: nil))
            XCTAssertEqual(reloaded.match(textBeforeCursor: ";date", bundleID: nil)?.snippet.body, edited.body)
        }
    }

    func testShardMergePreservesTheNewestTombstoneAcrossReloads() throws {
        let directory = temporaryDirectory()
        let store = SnippetStore(directoryURL: directory)
        var edit = try XCTUnwrap(store.snippets.first { $0.trigger == ";date" })
        edit.body = "Updated"
        edit.updatedAt = 10
        let editShard = SnippetStore.SyncShard(records: [edit.id: edit])
        store.applyRemoteShards(["editor": editShard])
        XCTAssertEqual(store.match(textBeforeCursor: ";date", bundleID: nil)?.expandedText, "Updated")

        var tombstone = edit
        tombstone.updatedAt = 20
        tombstone.isDeleted = true
        store.applyRemoteShards(["editor": editShard, "deleter": .init(records: [edit.id: tombstone])])
        let reloaded = SnippetStore(directoryURL: directory)
        reloaded.applyRemoteShards(["editor": editShard])
        XCTAssertEqual(reloaded.exportLocalShard().records[edit.id], tombstone)
        XCTAssertNil(reloaded.match(textBeforeCursor: ";date", bundleID: nil))

        edit.updatedAt = 21
        reloaded.applyRemoteShards(["editor": .init(records: [edit.id: edit])])
        XCTAssertEqual(reloaded.match(textBeforeCursor: ";date", bundleID: nil)?.expandedText, "Updated")
    }

    func testCJKCharacterAndPunctuationClassification() {
        for character: Character in ["中", "\u{3400}", "\u{F900}", "ひ", "カ", "か\u{3099}", "한"] {
            XCTAssertTrue(BilingualSpacingGuard.isCJKCharacter(character), String(character))
        }
        for character in "，。！？；：、（）【】《》「」『』“”‘’・〜＃［｝" {
            XCTAssertTrue(BilingualSpacingGuard.isCJKPunctuation(character), String(character))
        }
        for character: Character in ["中", "カ", "한", "Ａ", "３", ",", "a"] {
            XCTAssertFalse(BilingualSpacingGuard.isCJKPunctuation(character), String(character))
        }
        XCTAssertFalse(BilingualSpacingGuard.isCJKCharacter("a"))
    }

    func testBilingualLeadingBoundaryAndSpacing() throws {
        let boundary = try XCTUnwrap("使用algor".dropLast("algor".count).last)
        XCTAssertTrue(BilingualSpacingGuard.shouldAllowLeadingBoundary(boundary, bilingualEnabled: true))
        XCTAssertFalse(BilingualSpacingGuard.shouldAllowLeadingBoundary(boundary, bilingualEnabled: false))
        XCTAssertTrue(BilingualSpacingGuard.shouldAllowLeadingBoundary("，", bilingualEnabled: true))
        XCTAssertFalse(BilingualSpacingGuard.shouldAllowLeadingBoundary("，", bilingualEnabled: false))
        XCTAssertTrue(BilingualSpacingGuard.shouldAllowLeadingBoundary("(", bilingualEnabled: false))
        XCTAssertFalse(BilingualSpacingGuard.shouldAllowLeadingBoundary("/", bilingualEnabled: true))
        XCTAssertTrue(BilingualSpacingGuard.needsLeadingSpace(beforeWordStartBoundary: boundary, bilingualSpacingEnabled: true))
        XCTAssertFalse(BilingualSpacingGuard.needsLeadingSpace(beforeWordStartBoundary: boundary, bilingualSpacingEnabled: false))
        for punctuation: Character in ["，", "・", "“"] {
            XCTAssertFalse(BilingualSpacingGuard.needsLeadingSpace(beforeWordStartBoundary: punctuation, bilingualSpacingEnabled: true))
        }
        XCTAssertFalse(BilingualSpacingGuard.needsLeadingSpace(beforeWordStartBoundary: nil, bilingualSpacingEnabled: true))
    }

    func testBilingualTrailingSpacingAndExistingPreference() {
        XCTAssertTrue(BilingualSpacingGuard.needsTrailingSpace(
            charAfterCursor: "文字".first, appendSpacePreference: false, bilingualSpacingEnabled: true
        ))
        XCTAssertFalse(BilingualSpacingGuard.needsTrailingSpace(
            charAfterCursor: "文字".first, appendSpacePreference: true, bilingualSpacingEnabled: false
        ))
        for character: Character in ["，", "。", "！", "・", " ", "."] {
            for bilingualEnabled in [false, true] {
                XCTAssertFalse(BilingualSpacingGuard.needsTrailingSpace(
                    charAfterCursor: character, appendSpacePreference: true, bilingualSpacingEnabled: bilingualEnabled
                ))
            }
        }
        XCTAssertTrue(BilingualSpacingGuard.needsTrailingSpace(
            charAfterCursor: "a", appendSpacePreference: false, bilingualSpacingEnabled: false
        ))
        for character: Character? in [nil, "\n", "\r"] {
            XCTAssertTrue(BilingualSpacingGuard.needsTrailingSpace(
                charAfterCursor: character, appendSpacePreference: true, bilingualSpacingEnabled: true
            ))
            XCTAssertFalse(BilingualSpacingGuard.needsTrailingSpace(
                charAfterCursor: character, appendSpacePreference: false, bilingualSpacingEnabled: true
            ))
        }
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
