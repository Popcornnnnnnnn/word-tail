import Foundation
import XCTest
@testable import WordTailCore

final class SyncEngineTests: XCTestCase {
    func testPeerCacheBelongsToTheSelectedFolder() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        let suiteName = "WordTailSyncTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let originalFolder = root.appendingPathComponent("original", isDirectory: true)
        let originalDevices = originalFolder.appendingPathComponent("devices", isDirectory: true)
        try files.createDirectory(at: originalDevices, withIntermediateDirectories: true)
        let nextFolder = root.appendingPathComponent("next", isDirectory: true)
        let statsFile = root.appendingPathComponent("local-stats.json")
        let fixedDate = Date(timeIntervalSince1970: 1_763_540_000)

        func makeEngine(stats: KeyStatsStore) -> SyncEngine {
            SyncEngine(
                historyStore: UserHistoryStore(fileURL: root.appendingPathComponent("accepted_words.json")),
                adaptiveStore: AdaptiveCorrectionStore(fileURL: root.appendingPathComponent("adaptive_corrections.json")),
                phrasePredictor: PhrasePredictor(fileURL: root.appendingPathComponent("learned_phrases.json")),
                habitTracker: TypingHabitTracker(fileURL: root.appendingPathComponent("typing_insights.json")),
                keyStatsStore: stats,
                defaults: defaults,
                overrideDeviceID: "local",
                localCacheURL: root.appendingPathComponent("remote_sync_cache.json")
            )
        }

        let stats = KeyStatsStore(fileURL: statsFile, nowProvider: { fixedDate })
        let peerStats = KeyStatsStore(fileURL: root.appendingPathComponent("peer-stats.json"), nowProvider: { fixedDate })
        for store in [stats, peerStats] {
            store.recordKeyDown(
                keyCode: 0, rawFlags: 0, isAutoRepeat: false, isSecureInput: false, isRomanLayout: true,
                appBundleID: "com.apple.Notes", appName: "Notes"
            )
            store.flushNow()
        }
        let peerEnvelope = DeviceSyncEnvelope(
            deviceID: "peer", deviceModel: "Mac", history: .init(), corrections: .init(),
            phrases: .init(), insights: .init(), keyStatsDays: peerStats.exportLocalDaysShard()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let peerFile = originalDevices.appendingPathComponent("peer.json")
        let peerData = try encoder.encode(peerEnvelope)
        try peerData.write(to: peerFile)

        XCTAssertEqual(makeEngine(stats: stats).enableSync(folderURL: originalFolder).syncedPeerCount, 1)
        XCTAssertEqual(stats.snapshot(for: .today).totalKeyPresses, 2)

        // Simulate a peer file that is temporarily unavailable while the original folder stays selected.
        try files.removeItem(at: peerFile)
        let restartedStats = KeyStatsStore(fileURL: statsFile, nowProvider: { fixedDate })
        let restarted = makeEngine(stats: restartedStats)
        XCTAssertEqual(restarted.statusSnapshot().syncedPeerCount, 1)
        XCTAssertEqual(restarted.syncNow().syncedPeerCount, 1)
        XCTAssertEqual(restartedStats.snapshot(for: .today).totalKeyPresses, 2)

        // A failed switch must detach old peers even though the cache file has not been rewritten.
        try Data().write(to: nextFolder)
        let failedSwitch = restarted.enableSync(folderURL: nextFolder)
        XCTAssertNotNil(failedSwitch.lastError)
        XCTAssertNil(failedSwitch.lastSyncedAt)
        XCTAssertEqual(failedSwitch.syncedPeerCount, 0)
        XCTAssertEqual(restartedStats.snapshot(for: .today).totalKeyPresses, 1)

        let switchedStats = KeyStatsStore(fileURL: statsFile, nowProvider: { fixedDate })
        let afterSwitch = makeEngine(stats: switchedStats)
        XCTAssertEqual(afterSwitch.statusSnapshot().syncedPeerCount, 0)
        XCTAssertEqual(switchedStats.snapshot(for: .today).totalKeyPresses, 1)

        try files.removeItem(at: nextFolder)
        let retry = afterSwitch.syncNow()
        XCTAssertNil(retry.lastError)
        XCTAssertEqual(retry.syncedPeerCount, 0)
        XCTAssertEqual(switchedStats.snapshot(for: .today).totalKeyPresses, 1)

        try peerData.write(to: peerFile)
        XCTAssertEqual(afterSwitch.enableSync(folderURL: originalFolder).syncedPeerCount, 1)
        XCTAssertEqual(afterSwitch.enableSync(folderURL: nextFolder).syncedPeerCount, 0)
        XCTAssertEqual(switchedStats.snapshot(for: .today).totalKeyPresses, 1)
    }
}
