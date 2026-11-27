import Foundation
import XCTest
@testable import WordTailCore

final class AdaptiveMuteRegressionTests: XCTestCase {
    func testReMutingWorksAfterCustomRuleRemoval() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("WordTailMuteReg-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let store = AdaptiveCorrectionStore(fileURL: root.appendingPathComponent("adaptive.json"))
        XCTAssertTrue(store.addCustomRule(trigger: "teh", replacement: "the", persistAsync: false))
        store.removeRuleOrUnmute(trigger: "teh")
        XCTAssertFalse(store.isMuted("teh"))

        XCTAssertFalse(store.recordUndo(forTrigger: "teh", persistAsync: false))
        XCTAssertTrue(store.recordUndo(forTrigger: "teh", persistAsync: false))
        XCTAssertTrue(store.isMuted("teh"))

        let shard = store.exportLocalShard()
        let rec = try XCTUnwrap(shard.syncRecords["teh"])
        XCTAssertTrue(rec.isMuted)
        XCTAssertFalse(rec.isDeleted)
    }

    func testUnmuteIgnoresStaleRemoteUndosUntilTwoFreshLocalUndos() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("WordTailRemoteMute-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let store = AdaptiveCorrectionStore(fileURL: root.appendingPathComponent("adaptive.json"))
        var peerShard = AdaptiveCorrectionStore.SyncShard()
        peerShard.undoCounts["teh"] = 2
        peerShard.syncRecords["teh"] = AdaptiveCorrectionStore.RuleSyncRecord(
            replacement: nil,
            isMuted: true,
            isDeleted: false,
            updatedAt: 100
        )
        store.applyRemoteShards(["peer-mac": peerShard])
        XCTAssertTrue(store.isMuted("teh"))

        // Local unmute sets an isDeleted tombstone that must block stale peer undoCounts.
        store.removeRuleOrUnmute(trigger: "teh")
        XCTAssertFalse(store.isMuted("teh"))

        // 1st fresh local undo keeps it unmuted despite peer's undoCounts == 2.
        XCTAssertFalse(store.recordUndo(forTrigger: "teh", persistAsync: false))
        XCTAssertFalse(store.isMuted("teh"))

        // 2nd fresh local undo re-mutes and clears the tombstone.
        XCTAssertTrue(store.recordUndo(forTrigger: "teh", persistAsync: false))
        XCTAssertTrue(store.isMuted("teh"))
        let rec = try XCTUnwrap(store.exportLocalShard().syncRecords["teh"])
        XCTAssertTrue(rec.isMuted)
        XCTAssertFalse(rec.isDeleted)
    }

    func testReMuteAfterUnmutePropagatesAcrossSyncEngine() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("WordTailMuteSync-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let syncFolder = root.appendingPathComponent("sync", isDirectory: true)
        let macADir = root.appendingPathComponent("macA", isDirectory: true)
        let macBDir = root.appendingPathComponent("macB", isDirectory: true)
        try fm.createDirectory(at: macADir, withIntermediateDirectories: true)
        try fm.createDirectory(at: macBDir, withIntermediateDirectories: true)

        let suiteA = "WordTailMuteSyncA-\(UUID().uuidString)"
        let suiteB = "WordTailMuteSyncB-\(UUID().uuidString)"
        let defaultsA = try XCTUnwrap(UserDefaults(suiteName: suiteA))
        let defaultsB = try XCTUnwrap(UserDefaults(suiteName: suiteB))
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }

        let corrA = AdaptiveCorrectionStore(fileURL: macADir.appendingPathComponent("adaptive.json"))
        let corrB = AdaptiveCorrectionStore(fileURL: macBDir.appendingPathComponent("adaptive.json"))

        let engineA = SyncEngine(
            historyStore: UserHistoryStore(fileURL: macADir.appendingPathComponent("history.json")),
            adaptiveStore: corrA,
            phrasePredictor: PhrasePredictor(fileURL: macADir.appendingPathComponent("phrases.json")),
            habitTracker: TypingHabitTracker(fileURL: macADir.appendingPathComponent("insights.json")),
            keyStatsStore: KeyStatsStore(fileURL: macADir.appendingPathComponent("stats.json")),
            defaults: defaultsA,
            overrideDeviceID: "mac-a",
            localCacheURL: macADir.appendingPathComponent("cache.json")
        )
        let engineB = SyncEngine(
            historyStore: UserHistoryStore(fileURL: macBDir.appendingPathComponent("history.json")),
            adaptiveStore: corrB,
            phrasePredictor: PhrasePredictor(fileURL: macBDir.appendingPathComponent("phrases.json")),
            habitTracker: TypingHabitTracker(fileURL: macBDir.appendingPathComponent("insights.json")),
            keyStatsStore: KeyStatsStore(fileURL: macBDir.appendingPathComponent("stats.json")),
            defaults: defaultsB,
            overrideDeviceID: "mac-b",
            localCacheURL: macBDir.appendingPathComponent("cache.json")
        )

        // Mac A mutes, syncs to Mac B, Mac B unmutes, then Mac B re-mutes with 2 fresh undos and syncs back.
        _ = corrA.recordUndo(forTrigger: "teh", persistAsync: false)
        _ = corrA.recordUndo(forTrigger: "teh", persistAsync: false)
        _ = engineA.enableSync(folderURL: syncFolder)
        _ = engineB.enableSync(folderURL: syncFolder)
        XCTAssertTrue(corrB.isMuted("teh"))

        corrB.removeRuleOrUnmute(trigger: "teh")
        _ = engineB.syncNow()
        _ = engineA.syncNow()
        XCTAssertFalse(corrA.isMuted("teh"))
        XCTAssertFalse(corrB.isMuted("teh"))

        XCTAssertFalse(corrB.recordUndo(forTrigger: "teh", persistAsync: false))
        XCTAssertTrue(corrB.recordUndo(forTrigger: "teh", persistAsync: false))
        _ = engineB.syncNow()
        _ = engineA.syncNow()
        XCTAssertTrue(corrA.isMuted("teh"))
    }
}
