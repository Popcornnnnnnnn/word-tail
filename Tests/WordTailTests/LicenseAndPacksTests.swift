import CryptoKit
import Foundation
import XCTest
import WordTailCore

final class LicenseAndPacksTests: XCTestCase {
    private let payload = ProLicensePayload(
        email: "reader@example.com",
        issuedAt: 1_763_540_000,
        licenseID: "test-license"
    )

    func testLicenseRoundTripPersistsAcrossManagers() throws {
        let defaults = try isolatedDefaults()
        let signingKey = Curve25519.Signing.PrivateKey()
        let key = try LicenseManager.sign(payload: payload, privateKey: signingKey)
        let groups = key.split(separator: "-")
        XCTAssertEqual(groups.first, "WTPRO")
        XCTAssertTrue(groups.dropFirst().dropLast().allSatisfy { $0.count == 5 })
        XCTAssertTrue(key.dropFirst(6).utf8.allSatisfy { (65...90).contains($0) || (50...55).contains($0) || $0 == 45 })
        XCTAssertEqual(LicenseManager.loadDefaultPublicKey().rawRepresentation.count, 32)

        let manager = LicenseManager(publicKey: signingKey.publicKey, defaults: defaults)
        XCTAssertEqual(manager.entitlementState, .free)
        XCTAssertEqual(try manager.activate(licenseKey: key).get(), payload)
        XCTAssertEqual(manager.activeLicenseKey, key)
        XCTAssertEqual(manager.entitlementState, .licensed(payload))
        XCTAssertFalse(manager.startLocalTrial())
        XCTAssertFalse(manager.hasUsedTrial)

        let managerAfterRestart = LicenseManager(publicKey: signingKey.publicKey, defaults: defaults)
        XCTAssertEqual(managerAfterRestart.entitlementState, .licensed(payload))
        managerAfterRestart.deactivateLicense()
        XCTAssertNil(manager.activeLicenseKey)
        XCTAssertEqual(manager.entitlementState, .free)

        let body = groups.dropFirst().joined(separator: " \t-\n")
        XCTAssertEqual(try manager.activate(licenseKey: "  WTPRO-" + body + "\n").get(), payload)
    }

    func testTamperedSignatureAndWrongPublicKeyAreRejected() throws {
        let defaults = try isolatedDefaults()
        let signingKey = Curve25519.Signing.PrivateKey()
        let manager = LicenseManager(publicKey: signingKey.publicKey, defaults: defaults)
        let key = try LicenseManager.sign(payload: payload, privateKey: signingKey)
        XCTAssertEqual(try manager.activate(licenseKey: key).get(), payload)

        var groups = key.split(separator: "-").map(String.init)
        let signatureGroup = groups.count - 2
        groups[signatureGroup] = flippingFirstSymbol(in: groups[signatureGroup])
        XCTAssertEqual(manager.activate(licenseKey: groups.joined(separator: "-")), .failure(.invalidSignature))
        XCTAssertEqual(manager.activeLicenseKey, key)

        let wrongKey = Curve25519.Signing.PrivateKey().publicKey
        let otherManager = LicenseManager(publicKey: wrongKey, defaults: defaults)
        XCTAssertEqual(otherManager.activate(licenseKey: key), .failure(.invalidSignature))
        XCTAssertNil(otherManager.activeLicenseKey)
        XCTAssertEqual(otherManager.entitlementState, .free)
    }

    func testCorruptedPrefixBase32AndLengthHeaderAreRejected() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let manager = LicenseManager(publicKey: signingKey.publicKey, defaults: try isolatedDefaults())
        let key = try LicenseManager.sign(payload: payload, privateKey: signingKey)
        let body = String(key.dropFirst(6))
        XCTAssertEqual(manager.activate(licenseKey: "BAD-" + body), .failure(.invalidFormat))
        XCTAssertEqual(manager.activate(licenseKey: "WTPRO-!" + body.dropFirst()), .failure(.invalidEncoding))
        XCTAssertEqual(manager.activate(licenseKey: "WTPRO-" + flippingFirstSymbol(in: body)), .failure(.invalidFormat))
        XCTAssertNil(manager.activeLicenseKey)
    }

    func testSignedPayloadMustUseSupportedVersionAndTier() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let manager = LicenseManager(publicKey: signingKey.publicKey, defaults: try isolatedDefaults())
        var invalid = payload
        invalid.version = 2
        let unknownVersion = try LicenseManager.sign(payload: invalid, privateKey: signingKey)
        XCTAssertEqual(manager.activate(licenseKey: unknownVersion), .failure(.unsupportedVersion))

        invalid.version = 1
        invalid.tier = "free"
        let wrongTier = try LicenseManager.sign(payload: invalid, privateKey: signingKey)
        XCTAssertEqual(manager.activate(licenseKey: wrongTier), .failure(.invalidPayload))
        XCTAssertEqual(manager.entitlementState, .free)
    }

    func testTrialDecaysAndCannotRestartAfterExpiry() throws {
        let defaults = try isolatedDefaults()
        let signingKey = Curve25519.Signing.PrivateKey()
        let start = Date(timeIntervalSince1970: 1_763_540_000)
        let expiry = start.addingTimeInterval(14 * 86_400)
        var now = start
        func makeManager() -> LicenseManager {
            LicenseManager(publicKey: signingKey.publicKey, defaults: defaults, keyPrefix: "TestTrial", nowProvider: { now })
        }

        let manager = makeManager()
        XCTAssertEqual(manager.entitlementState, .free)
        XCTAssertFalse(manager.hasUsedTrial)
        XCTAssertTrue(manager.startLocalTrial())
        XCTAssertTrue(manager.hasUsedTrial)
        XCTAssertFalse(manager.startLocalTrial())
        XCTAssertEqual(manager.entitlementState, .trial(daysRemaining: 14, expiresAt: expiry))

        now = start.addingTimeInterval(3 * 86_400 + 60)
        XCTAssertEqual(makeManager().entitlementState, .trial(daysRemaining: 11, expiresAt: expiry))
        now = expiry.addingTimeInterval(-1)
        XCTAssertEqual(manager.entitlementState, .trial(daysRemaining: 1, expiresAt: expiry))
        now = expiry
        XCTAssertEqual(manager.entitlementState, .free)
        XCTAssertTrue(makeManager().hasUsedTrial)
        XCTAssertFalse(makeManager().startLocalTrial())
    }

    func testLicenseOverridesTrialWithoutResettingIt() throws {
        let defaults = try isolatedDefaults()
        let signingKey = Curve25519.Signing.PrivateKey()
        let start = Date(timeIntervalSince1970: 1_763_540_000)
        var now = start
        let manager = LicenseManager(publicKey: signingKey.publicKey, defaults: defaults, nowProvider: { now })
        XCTAssertTrue(manager.startLocalTrial())

        let key = try LicenseManager.sign(payload: payload, privateKey: signingKey)
        XCTAssertEqual(try manager.activate(licenseKey: key).get(), payload)
        XCTAssertEqual(manager.entitlementState, .licensed(payload))
        XCTAssertTrue(manager.hasUsedTrial)

        now = start.addingTimeInterval(2 * 86_400)
        manager.deactivateLicense()
        XCTAssertEqual(manager.entitlementState, .trial(daysRemaining: 12, expiresAt: start.addingTimeInterval(14 * 86_400)))
        XCTAssertFalse(manager.startLocalTrial())
    }

    func testSixBuiltInPacksHaveCleanDistinctWords() {
        let packs = DomainLexiconPack.builtInPacks
        XCTAssertEqual(packs.map(\.id), ["ai_quant", "systems_cloud", "product_exec", "academic_science", "finance_legal", "medical_bio"])
        var unique = Set<String>()
        for pack in packs {
            XCTAssertGreaterThanOrEqual(pack.words.count, 190)
            for word in pack.words {
                XCTAssertGreaterThanOrEqual(word.count, 4, word)
                XCTAssertTrue(word.utf8.allSatisfy { (97...122).contains($0) }, word)
                XCTAssertTrue(unique.insert(word).inserted, "Duplicate word: \(word)")
            }
        }
        XCTAssertGreaterThanOrEqual(unique.count, 1_000)
    }

    func testPrefixMatchingSelectsEnabledAndOverrideBuckets() throws {
        let directory = try isolatedDirectory()
        let store = DomainPackStore(directoryURL: directory)
        XCTAssertEqual(store.matching(lowercasedPrefix: "quant"), [])
        XCTAssertTrue(store.setEnabledPackIDs(["ai_quant", "unknown", "ai_quant"]))
        XCTAssertEqual(store.enabledPackIDs, ["ai_quant"])
        let aiPack = try XCTUnwrap(DomainLexiconPack.builtInPacks.first)
        for prefix in ["q", "quant", "ve", "neuro"] {
            XCTAssertEqual(store.matching(lowercasedPrefix: prefix), aiPack.words.filter { $0.hasPrefix(prefix) })
        }
        XCTAssertEqual(store.matching(lowercasedPrefix: ""), [])
        XCTAssertEqual(store.matching(lowercasedPrefix: "kube", overrideEnabledPackIDs: ["systems_cloud"]), ["kubelet", "kubernetes"])
        XCTAssertEqual(store.matching(lowercasedPrefix: "quant", overrideEnabledPackIDs: []), [])

        let config = try Data(contentsOf: directory.appendingPathComponent("domain_packs_config.json"))
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: config), ["ai_quant"])
        XCTAssertEqual(DomainPackStore(directoryURL: directory).enabledPackIDs, ["ai_quant"])
    }

    func testCustomPackSanitizationAndJSONRoundTrip() throws {
        let directory = try isolatedDirectory()
        let store = DomainPackStore(directoryURL: directory)
        let input = CustomDomainPack(
            id: " ../My Pack! ", name: " My Vocabulary ",
            words: ["  Quokka\n", "QUOKKA", "Quarantine", "cat", "résumé", "doc2", "two words", "dash-word"],
            updatedAt: 10
        )
        let pack = try store.importCustomPack(data: JSONEncoder().encode(input))
        XCTAssertEqual(pack.id, "my-pack")
        XCTAssertEqual(pack.name, "My Vocabulary")
        XCTAssertEqual(pack.words, ["quokka", "quarantine"])
        XCTAssertGreaterThan(pack.updatedAt, input.updatedAt)
        XCTAssertEqual(store.matching(lowercasedPrefix: "qu"), pack.words)
        XCTAssertEqual(store.matching(lowercasedPrefix: "quo", overrideEnabledPackIDs: ["my-pack"]), ["quokka"])

        let exported = try store.exportCustomPackJSON(id: pack.id)
        XCTAssertEqual(try JSONDecoder().decode(CustomDomainPack.self, from: exported), pack)
        let restored = DomainPackStore(directoryURL: try isolatedDirectory())
        let reimported = try restored.importCustomPack(data: exported)
        XCTAssertEqual(reimported.id, pack.id)
        XCTAssertEqual(reimported.name, pack.name)
        XCTAssertEqual(reimported.words, pack.words)
        XCTAssertEqual(DomainPackStore(directoryURL: directory).customPacks, [pack])

        let reserved = CustomDomainPack(id: "AI_QUANT", name: "Reserved", words: ["quokka"])
        XCTAssertThrowsError(try store.importCustomPack(data: JSONEncoder().encode(reserved))) {
            XCTAssertEqual($0 as? DomainPackStore.ImportError, .invalidPack)
        }
    }

    func testCustomPackImportCapsFileAndWordCounts() throws {
        let store = DomainPackStore(directoryURL: try isolatedDirectory())
        XCTAssertThrowsError(try store.importCustomPack(data: Data(count: 513 * 1_024))) {
            XCTAssertEqual($0 as? DomainPackStore.ImportError, .fileTooLarge)
        }
        let words = (0...5_000).map { number in
            "word" + String(decoding: [number / 676, number / 26 % 26, number % 26].map { UInt8(97 + $0) }, as: UTF8.self)
        }
        let input = CustomDomainPack(id: "large", name: "Large Pack", words: words)
        let pack = try store.importCustomPack(data: JSONEncoder().encode(input))
        XCTAssertEqual(pack.words, Array(words.prefix(5_000)))
    }

    func testDomainPackSyncMergesEnabledListAndIndividualPacksByTimestamp() throws {
        let directory = try isolatedDirectory()
        let store = DomainPackStore(directoryURL: directory)
        XCTAssertTrue(store.setEnabledPackIDs(["ai_quant"]))
        let input = CustomDomainPack(id: "local", name: "Local", words: ["quokka"])
        let local = try store.importCustomPack(data: JSONEncoder().encode(input))
        let start = store.exportSyncShard()

        let newer = CustomDomainPack(id: local.id, name: "Remote", words: ["quetzal"], updatedAt: local.updatedAt + 1)
        let disjoint = CustomDomainPack(id: "peer", name: "Peer", words: ["quince"], updatedAt: local.updatedAt)
        let remote = DomainPackStore.SyncShard(enabledPackIDs: ["systems_cloud"], customPacks: [newer], updatedAt: start.updatedAt + 1)
        let stale = DomainPackStore.SyncShard(enabledPackIDs: ["finance_legal"], customPacks: [local, disjoint], updatedAt: start.updatedAt - 1)
        XCTAssertTrue(store.applyRemoteShards(["peer": remote, "stale": stale]))
        XCTAssertTrue(store.applyRemoteShards(["stale": stale]))
        XCTAssertEqual(store.enabledPackIDs, ["systems_cloud"])
        XCTAssertEqual(store.customPacks, [newer, disjoint])
        XCTAssertEqual(store.matching(lowercasedPrefix: "qu"), ["queuing", "quetzal", "quince"])
        XCTAssertEqual(DomainPackStore(directoryURL: directory).exportSyncShard(), store.exportSyncShard())
    }

    func testAppProfileCRUDAndPresetPersistence() throws {
        let directory = try isolatedDirectory()
        let store = AppProfileStore(directoryURL: directory)
        let bundleID = "com.example.editor"
        XCTAssertNil(store.profile(forBundleID: bundleID))
        XCTAssertTrue(store.upsert(AppWritingProfile(bundleID: bundleID, displayName: "Editor", enablePhrasePrediction: false)))
        XCTAssertEqual(store.profiles.map(\.id), [bundleID])
        XCTAssertEqual(store.profile(forBundleID: bundleID)?.enablePhrasePrediction, false)
        XCTAssertNil(store.profile(forBundleID: bundleID)?.autoCorrectOnSpace)

        XCTAssertTrue(store.applyPreset(.formalDocs, toBundleID: bundleID, displayName: "Document Editor"))
        let formal = try XCTUnwrap(store.profile(forBundleID: bundleID))
        XCTAssertEqual(formal.displayName, "Document Editor")
        XCTAssertEqual(formal.preset, .formalDocs)
        XCTAssertEqual(formal.autoCapitalizeSentences, true)
        XCTAssertEqual(formal.autoCorrectOnSpace, true)
        XCTAssertEqual(formal.enablePhrasePrediction, true)
        XCTAssertEqual(AppProfileStore(directoryURL: directory).profiles, [formal])

        XCTAssertTrue(store.applyPreset(.custom, toBundleID: bundleID, displayName: formal.displayName))
        let custom = try XCTUnwrap(store.profile(forBundleID: bundleID))
        XCTAssertEqual(custom.preset, .custom)
        XCTAssertEqual(custom.autoCorrectOnSpace, formal.autoCorrectOnSpace)
        XCTAssertTrue(store.delete(bundleID: bundleID))
        XCTAssertEqual(store.profiles, [])
        XCTAssertNil(AppProfileStore(directoryURL: directory).profile(forBundleID: bundleID))
        XCTAssertEqual(store.exportLocalShard().profiles[bundleID]?.isDeleted, true)
    }

    func testAppProfileStarterPresetsMatchKnownBundleIDs() throws {
        let expected: [(String, AppProfilePreset)] = [
            ("com.tencent.xinWeChat", .casualChat), ("com.tinyspeck.slackmacgap", .casualChat),
            ("com.apple.mail", .formalDocs), ("notion.id", .formalDocs),
            ("com.openai.codex", .engineeringChat), ("com.todesktop.230313mzl4w4u92", .engineeringChat)
        ]
        for (bundleID, preset) in expected {
            XCTAssertEqual(AppProfilePreset.recommended(forBundleID: bundleID), preset)
            let starter = try XCTUnwrap(AppWritingProfile.starter(forBundleID: bundleID, displayName: "Example"))
            XCTAssertEqual(starter.bundleID, bundleID)
            XCTAssertEqual(starter.displayName, "Example")
            XCTAssertEqual(starter.preset, preset)
        }
        let engineering = AppWritingProfile.starter(forBundleID: "com.openai.codex", displayName: "Codex")
        XCTAssertEqual(engineering?.enabledDomainPackIDs, ["systems_cloud", "ai_quant"])
        XCTAssertNil(AppWritingProfile.starter(forBundleID: "unknown", displayName: "Unknown"))
    }

    func testAppProfileSyncPreservesNewerTombstoneAndAllowsNewEdit() throws {
        let directory = try isolatedDirectory()
        let store = AppProfileStore(directoryURL: directory)
        let bundleID = "com.example.chat"
        XCTAssertTrue(store.applyPreset(.casualChat, toBundleID: bundleID, displayName: "Chat"))
        let local = try XCTUnwrap(store.profile(forBundleID: bundleID))

        var deleted = local
        deleted.updatedAt += 10
        deleted.isDeleted = true
        var tied = local
        tied.updatedAt = deleted.updatedAt
        let unrelated = AppWritingProfile(bundleID: "com.example.mail", displayName: "Mail", updatedAt: 1)
        XCTAssertTrue(store.applyRemoteShards([
            "newer": .init(profiles: [bundleID: deleted, unrelated.id: unrelated]),
            "tie": .init(profiles: [bundleID: tied]),
            "older": .init(profiles: [bundleID: local])
        ]))
        let restarted = AppProfileStore(directoryURL: directory)
        XCTAssertTrue(restarted.applyRemoteShards(["tie": .init(profiles: [bundleID: tied])]))
        XCTAssertEqual(restarted.profiles, [unrelated])
        XCTAssertEqual(restarted.exportLocalShard().profiles[bundleID], deleted)

        XCTAssertTrue(restarted.applyPreset(.engineeringChat, toBundleID: bundleID, displayName: "Chat"))
        let recreated = try XCTUnwrap(restarted.profile(forBundleID: bundleID))
        XCTAssertGreaterThan(recreated.updatedAt, deleted.updatedAt)
        XCTAssertTrue(restarted.applyRemoteShards(["newer": .init(profiles: [bundleID: deleted])]))
        XCTAssertEqual(restarted.profile(forBundleID: bundleID), recreated)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "WordTailLicenseAndPacksTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func isolatedDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func flippingFirstSymbol(in base32: String) -> String {
        (base32.first == "A" ? "B" : "A") + base32.dropFirst()
    }
}
