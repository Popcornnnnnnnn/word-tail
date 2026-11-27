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

    func testLegacyV1PeerCompatibilityAndProShardRoundTrip() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("WordTailProSync-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let suiteA = "WordTailProSyncA-\(UUID().uuidString)"
        let suiteB = "WordTailProSyncB-\(UUID().uuidString)"
        let defaultsA = try XCTUnwrap(UserDefaults(suiteName: suiteA))
        let defaultsB = try XCTUnwrap(UserDefaults(suiteName: suiteB))
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }

        let syncFolder = root.appendingPathComponent("sync", isDirectory: true)
        let devicesDir = syncFolder.appendingPathComponent("devices", isDirectory: true)
        try fm.createDirectory(at: devicesDir, withIntermediateDirectories: true)

        // Legacy v0.8.3 envelope JSON without Pro fields (`domainPacks`, `appProfiles`, `snippets`)
        let legacyEnv = DeviceSyncEnvelope(
            schemaVersion: 1,
            deviceID: "legacy-mac",
            deviceModel: "Mac14,2",
            updatedAt: Date(timeIntervalSince1970: 1_763_540_000),
            history: .init(),
            corrections: .init(),
            phrases: .init(),
            insights: .init(),
            keyStatsDays: [:]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodedLegacy = try encoder.encode(legacyEnv)
        var jsonObj = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedLegacy) as? [String: Any])
        jsonObj.removeValue(forKey: "domainPacks")
        jsonObj.removeValue(forKey: "appProfiles")
        jsonObj.removeValue(forKey: "snippets")
        let legacyData = try JSONSerialization.data(withJSONObject: jsonObj)
        try legacyData.write(to: devicesDir.appendingPathComponent("legacy-mac.json"))

        let macADir = root.appendingPathComponent("macA", isDirectory: true)
        let macBDir = root.appendingPathComponent("macB", isDirectory: true)
        let packsA = DomainPackStore(directoryURL: macADir)
        let profilesA = AppProfileStore(directoryURL: macADir)
        let snippetsA = SnippetStore(directoryURL: macADir)
        XCTAssertTrue(packsA.setEnabledPackIDs(["medical_bio"]))
        XCTAssertTrue(profilesA.applyPreset(.engineeringChat, toBundleID: "com.openai.codex", displayName: "Codex"))
        XCTAssertTrue(snippetsA.addOrUpdateSnippet(TextSnippet(id: ";sig", trigger: ";sig", title: "Signature", body: "Cheers")))

        let packsB = DomainPackStore(directoryURL: macBDir)
        let profilesB = AppProfileStore(directoryURL: macBDir)
        let snippetsB = SnippetStore(directoryURL: macBDir)

        let engineA = SyncEngine(
            historyStore: UserHistoryStore(fileURL: macADir.appendingPathComponent("accepted.json")),
            adaptiveStore: AdaptiveCorrectionStore(fileURL: macADir.appendingPathComponent("adaptive.json")),
            phrasePredictor: PhrasePredictor(fileURL: macADir.appendingPathComponent("phrases.json")),
            habitTracker: TypingHabitTracker(fileURL: macADir.appendingPathComponent("insights.json")),
            keyStatsStore: KeyStatsStore(fileURL: macADir.appendingPathComponent("stats.json")),
            domainPackStore: packsA,
            appProfileStore: profilesA,
            snippetStore: snippetsA,
            defaults: defaultsA,
            overrideDeviceID: "mac-a",
            localCacheURL: macADir.appendingPathComponent("cache.json")
        )
        let engineB = SyncEngine(
            historyStore: UserHistoryStore(fileURL: macBDir.appendingPathComponent("accepted.json")),
            adaptiveStore: AdaptiveCorrectionStore(fileURL: macBDir.appendingPathComponent("adaptive.json")),
            phrasePredictor: PhrasePredictor(fileURL: macBDir.appendingPathComponent("phrases.json")),
            habitTracker: TypingHabitTracker(fileURL: macBDir.appendingPathComponent("insights.json")),
            keyStatsStore: KeyStatsStore(fileURL: macBDir.appendingPathComponent("stats.json")),
            domainPackStore: packsB,
            appProfileStore: profilesB,
            snippetStore: snippetsB,
            defaults: defaultsB,
            overrideDeviceID: "mac-b",
            localCacheURL: macBDir.appendingPathComponent("cache.json")
        )

        XCTAssertEqual(engineA.enableSync(folderURL: syncFolder).syncedPeerCount, 1) // legacy-mac decoded
        XCTAssertEqual(engineB.enableSync(folderURL: syncFolder).syncedPeerCount, 2) // legacy-mac + mac-a

        XCTAssertEqual(packsB.enabledPackIDs, ["medical_bio"])
        XCTAssertEqual(profilesB.profile(forBundleID: "com.openai.codex")?.preset, .engineeringChat)
        XCTAssertEqual(snippetsB.match(textBeforeCursor: ";sig", bundleID: nil)?.expandedText, "Cheers")

        // Detach/failed folder switch on Mac B must preserve local Pro stores
        let invalidFolder = root.appendingPathComponent("not-a-directory")
        try Data().write(to: invalidFolder)
        let detached = engineB.enableSync(folderURL: invalidFolder)
        XCTAssertNotNil(detached.lastError)
        XCTAssertEqual(packsB.enabledPackIDs, ["medical_bio"])
        XCTAssertEqual(profilesB.profile(forBundleID: "com.openai.codex")?.preset, .engineeringChat)
        XCTAssertEqual(snippetsB.match(textBeforeCursor: ";sig", bundleID: nil)?.expandedText, "Cheers")
    }

    func testVerticalOffsetsSyncAcrossPeersAndLegacyCompatibility() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("WordTailCalSync-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let suiteA = "WordTailCalSyncA-\(UUID().uuidString)"
        let suiteB = "WordTailCalSyncB-\(UUID().uuidString)"
        let defaultsA = try XCTUnwrap(UserDefaults(suiteName: suiteA))
        let defaultsB = try XCTUnwrap(UserDefaults(suiteName: suiteB))
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }

        let syncFolder = root.appendingPathComponent("sync", isDirectory: true)
        let devicesDir = syncFolder.appendingPathComponent("devices", isDirectory: true)
        try fm.createDirectory(at: devicesDir, withIntermediateDirectories: true)

        // Legacy v0.9.2 peer envelope without `verticalOffsets` must still decode cleanly.
        let legacyEnv = DeviceSyncEnvelope(
            schemaVersion: 1,
            deviceID: "legacy-v092",
            deviceModel: "Mac14,15",
            updatedAt: Date(timeIntervalSince1970: 1_763_540_000),
            history: .init(),
            corrections: .init(),
            phrases: .init(),
            insights: .init(),
            keyStatsDays: [:]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodedLegacy = try encoder.encode(legacyEnv)
        var jsonObj = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedLegacy) as? [String: Any])
        jsonObj.removeValue(forKey: "verticalOffsets")
        try JSONSerialization.data(withJSONObject: jsonObj)
            .write(to: devicesDir.appendingPathComponent("legacy-v092.json"))

        let macADir = root.appendingPathComponent("macA", isDirectory: true)
        let macBDir = root.appendingPathComponent("macB", isDirectory: true)
        let offsetsA = VerticalOffsetStore(fileURL: macADir.appendingPathComponent("vertical_offsets.json"), defaults: defaultsA)
        let offsetsB = VerticalOffsetStore(fileURL: macBDir.appendingPathComponent("vertical_offsets.json"), defaults: defaultsB)

        offsetsB.setOffset(0.40, forBundleID: "com.apple.Notes")
        Thread.sleep(forTimeInterval: 0.01)

        offsetsA.globalOffset = -0.10
        offsetsA.setOffset(-1.15, forBundleID: "com.google.Chrome")
        offsetsA.setOffset(-0.20, forBundleID: "com.t3tools.t3code", displayKey: "ext:4c2d-71e9-878270033@2x")
        offsetsA.setOffset(0.10, forBundleID: "com.apple.Notes")
        Thread.sleep(forTimeInterval: 0.01)
        offsetsA.removeOrReset(bundleID: "com.apple.Notes")

        let engineA = SyncEngine(
            historyStore: UserHistoryStore(fileURL: macADir.appendingPathComponent("accepted.json")),
            adaptiveStore: AdaptiveCorrectionStore(fileURL: macADir.appendingPathComponent("adaptive.json")),
            phrasePredictor: PhrasePredictor(fileURL: macADir.appendingPathComponent("phrases.json")),
            habitTracker: TypingHabitTracker(fileURL: macADir.appendingPathComponent("insights.json")),
            keyStatsStore: KeyStatsStore(fileURL: macADir.appendingPathComponent("stats.json")),
            defaults: defaultsA,
            overrideDeviceID: "mac-a",
            localCacheURL: macADir.appendingPathComponent("cache.json"),
            verticalOffsetStore: offsetsA
        )
        let engineB = SyncEngine(
            historyStore: UserHistoryStore(fileURL: macBDir.appendingPathComponent("accepted.json")),
            adaptiveStore: AdaptiveCorrectionStore(fileURL: macBDir.appendingPathComponent("adaptive.json")),
            phrasePredictor: PhrasePredictor(fileURL: macBDir.appendingPathComponent("phrases.json")),
            habitTracker: TypingHabitTracker(fileURL: macBDir.appendingPathComponent("insights.json")),
            keyStatsStore: KeyStatsStore(fileURL: macBDir.appendingPathComponent("stats.json")),
            defaults: defaultsB,
            overrideDeviceID: "mac-b",
            localCacheURL: macBDir.appendingPathComponent("cache.json"),
            verticalOffsetStore: offsetsB
        )

        XCTAssertEqual(engineA.enableSync(folderURL: syncFolder).syncedPeerCount, 1)
        XCTAssertEqual(engineB.enableSync(folderURL: syncFolder).syncedPeerCount, 2)

        XCTAssertEqual(offsetsB.globalOffset, -0.10, accuracy: 1e-9)
        XCTAssertEqual(offsetsB.effectiveOffset(forBundleID: "com.google.Chrome"), -1.15, accuracy: 1e-9)
        XCTAssertEqual(
            offsetsB.effectiveOffset(forBundleID: "com.t3tools.t3code", displayKey: "ext:4c2d-71e9-878270033@2x"),
            -0.20,
            accuracy: 1e-9
        )
        XCTAssertNil(offsetsB.savedPerAppOffsets()["com.apple.Notes"])
        XCTAssertEqual(offsetsB.effectiveOffset(forBundleID: "com.apple.Notes"), -0.10, accuracy: 1e-9)
    }
}
