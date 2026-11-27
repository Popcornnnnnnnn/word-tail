import Foundation
import XCTest
@testable import WordTailCore

final class VerticalOffsetStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: VerticalOffsetStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "WordTailVerticalOffsetTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        store = VerticalOffsetStore(defaults: defaults)
    }

    override func tearDown() {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
            let prefsURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences", isDirectory: true)
                .appendingPathComponent("\(suiteName).plist")
            try? FileManager.default.removeItem(at: prefsURL)
        }
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsWhenUnset() {
        XCTAssertEqual(store.globalOffset, 0.70, accuracy: 1e-9)
        XCTAssertEqual(store.effectiveOffset(forBundleID: nil), 0.70, accuracy: 1e-9)
        XCTAssertEqual(store.effectiveOffset(forBundleID: "com.example.unknown"), 0.70, accuracy: 1e-9)
        XCTAssertNil(store.customOffset(forBundleID: "com.example.unknown"))

        XCTAssertEqual(store.customOffset(forBundleID: "com.google.antigravity") ?? .nan, 0.45, accuracy: 1e-9)
        XCTAssertEqual(store.effectiveOffset(forBundleID: "com.google.antigravity"), 0.45, accuracy: 1e-9)
        XCTAssertEqual(store.customOffset(forBundleID: "com.openai.codex") ?? .nan, 0.70, accuracy: 1e-9)
        XCTAssertEqual(store.effectiveOffset(forBundleID: "com.openai.codex"), 0.70, accuracy: 1e-9)
    }

    func testSanitizeClampingSteppingAndSpecialValues() {
        XCTAssertEqual(VerticalOffsetStore.sanitize(-8.25), -5.0, accuracy: 1e-9)
        XCTAssertEqual(VerticalOffsetStore.sanitize(7.40), 5.0, accuracy: 1e-9)
        XCTAssertEqual(VerticalOffsetStore.sanitize(0.123), 0.10, accuracy: 1e-9)
        XCTAssertEqual(VerticalOffsetStore.sanitize(0.126), 0.15, accuracy: 1e-9)
        XCTAssertEqual(VerticalOffsetStore.sanitize(-0.126), -0.15, accuracy: 1e-9)

        let zeroNormalized = VerticalOffsetStore.sanitize(-0.001)
        XCTAssertEqual(zeroNormalized, 0.0, accuracy: 1e-9)
        XCTAssertEqual(zeroNormalized.sign, .plus)

        let negZeroNormalized = VerticalOffsetStore.sanitize(-0.0)
        XCTAssertEqual(negZeroNormalized, 0.0, accuracy: 1e-9)
        XCTAssertEqual(negZeroNormalized.sign, .plus)

        XCTAssertEqual(VerticalOffsetStore.sanitize(.nan), 0.70, accuracy: 1e-9)
        XCTAssertEqual(VerticalOffsetStore.sanitize(.infinity), 0.70, accuracy: 1e-9)
        XCTAssertEqual(VerticalOffsetStore.sanitize(-.infinity), 0.70, accuracy: 1e-9)
    }

    func testNudgePreservesRangeBeyondTwoAndAvoidsFloatDrift() {
        let chrome = "com.google.Chrome"
        store.setOffset(-2.50, forBundleID: chrome)
        XCTAssertEqual(store.effectiveOffset(forBundleID: chrome), -2.50, accuracy: 1e-9)

        // Previously menu bar popover clamped to [-2.0, +2.0], snapping -2.50 to -2.00 on nudge.
        let nudgedPastTwo = store.nudge(forBundleID: chrome, delta: -0.05)
        XCTAssertEqual(nudgedPastTwo, -2.55, accuracy: 1e-9)
        XCTAssertEqual(store.effectiveOffset(forBundleID: chrome), -2.55, accuracy: 1e-9)

        // Repeated +/-0.10 and +/-0.05 nudges must stay exact to 0.05 increments without IEEE 754 drift.
        store.setOffset(0.0, forBundleID: chrome)
        for _ in 0..<20 {
            store.nudge(forBundleID: chrome, delta: 0.10)
        }
        XCTAssertEqual(store.effectiveOffset(forBundleID: chrome), 2.00, accuracy: 1e-9)

        for _ in 0..<40 {
            store.nudge(forBundleID: chrome, delta: -0.05)
        }
        let backAtZero = store.effectiveOffset(forBundleID: chrome)
        XCTAssertEqual(backAtZero, 0.0, accuracy: 1e-9)
        XCTAssertEqual(backAtZero.sign, .plus)

        // Clamp at bounds [-5.0, +5.0]
        store.setOffset(-4.95, forBundleID: chrome)
        XCTAssertEqual(store.nudge(forBundleID: chrome, delta: -0.20), -5.0, accuracy: 1e-9)

        store.setOffset(4.95, forBundleID: chrome)
        XCTAssertEqual(store.nudge(forBundleID: chrome, delta: 0.20), 5.0, accuracy: 1e-9)
    }

    func testMalformedEntryInPerAppDictionaryDoesNotWipeValidEntries() {
        defaults.set(
            [
                "com.google.Chrome": -1.15,
                "com.broken.string": "not-a-number",
                "com.broken.bool": true,
                "com.integer.one": 1,
                "com.integer.zero": 0,
                "com.openai.codex": NSNumber(value: -0.05)
            ] as [String: Any],
            forKey: VerticalOffsetStore.perAppOffsetsDefaultsKey
        )

        let saved = store.savedPerAppOffsets()
        XCTAssertEqual(saved["com.google.Chrome"] ?? .nan, -1.15, accuracy: 1e-9)
        XCTAssertEqual(saved["com.openai.codex"] ?? .nan, -0.05, accuracy: 1e-9)
        XCTAssertEqual(saved["com.integer.one"] ?? .nan, 1.0, accuracy: 1e-9)
        XCTAssertEqual(saved["com.integer.zero"] ?? .nan, 0.0, accuracy: 1e-9)
        XCTAssertNil(saved["com.broken.string"])
        XCTAssertNil(saved["com.broken.bool"])

        store.setOffset(0.25, forBundleID: "com.apple.Notes")
        let afterWrite = store.savedPerAppOffsets()
        XCTAssertEqual(afterWrite["com.google.Chrome"] ?? .nan, -1.15, accuracy: 1e-9)
        XCTAssertEqual(afterWrite["com.openai.codex"] ?? .nan, -0.05, accuracy: 1e-9)
        XCTAssertEqual(afterWrite["com.apple.Notes"] ?? .nan, 0.25, accuracy: 1e-9)
    }

    func testRemoveOrResetRestoresBuiltInAndGlobalFallbacks() {
        store.globalOffset = -0.10
        XCTAssertEqual(store.globalOffset, -0.10, accuracy: 1e-9)

        // Built-in app override -> removing resets to built-in default (0.45), not global (-0.10).
        store.setOffset(-0.10, forBundleID: "com.google.antigravity")
        XCTAssertEqual(store.effectiveOffset(forBundleID: "com.google.antigravity"), -0.10, accuracy: 1e-9)
        store.removeOrReset(bundleID: "com.google.antigravity")
        XCTAssertEqual(store.effectiveOffset(forBundleID: "com.google.antigravity"), 0.45, accuracy: 1e-9)
        XCTAssertNil(store.savedPerAppOffsets()["com.google.antigravity"])

        // Custom app override -> removing falls back to current global offset (-0.10).
        store.setOffset(-1.15, forBundleID: "com.google.Chrome")
        XCTAssertEqual(store.effectiveOffset(forBundleID: "com.google.Chrome"), -1.15, accuracy: 1e-9)
        store.removeOrReset(bundleID: "com.google.Chrome")
        XCTAssertEqual(store.effectiveOffset(forBundleID: "com.google.Chrome"), -0.10, accuracy: 1e-9)
        XCTAssertNil(store.mergedAppOffsets()["com.google.Chrome"])

        // Global reset restores ScreenGeometry.defaultVerticalOffset (0.70).
        XCTAssertEqual(store.resetGlobalOffset(), 0.70, accuracy: 1e-9)
        XCTAssertEqual(store.effectiveOffset(forBundleID: "com.google.Chrome"), 0.70, accuracy: 1e-9)
    }

    func testAtomicJSONPersistenceAndReload() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerticalOffsetJSONTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }
        let jsonURL = tempDir.appendingPathComponent("vertical_offsets.json")

        let writer = VerticalOffsetStore(fileURL: jsonURL, defaults: defaults)
        writer.globalOffset = -0.10
        writer.setOffset(-1.15, forBundleID: "com.google.Chrome")
        writer.setOffset(-0.20, forBundleID: "com.t3tools.t3code", displayKey: "ext:4c2d-71e9-878270033@2x")

        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))

        let isolatedSuite = "WordTailVerticalOffsetReload-\(UUID().uuidString)"
        let freshDefaults = try XCTUnwrap(UserDefaults(suiteName: isolatedSuite))
        addTeardownBlock { freshDefaults.removePersistentDomain(forName: isolatedSuite) }

        let reader = VerticalOffsetStore(fileURL: jsonURL, defaults: freshDefaults)
        XCTAssertEqual(reader.globalOffset, -0.10, accuracy: 1e-9)
        XCTAssertEqual(reader.effectiveOffset(forBundleID: "com.google.Chrome"), -1.15, accuracy: 1e-9)
        XCTAssertEqual(
            reader.effectiveOffset(forBundleID: "com.t3tools.t3code", displayKey: "ext:4c2d-71e9-878270033@2x"),
            -0.20,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            reader.effectiveOffset(forBundleID: "com.t3tools.t3code", displayKey: "builtin:0610-a05f@2x"),
            -0.10,
            accuracy: 1e-9
        )
    }

    func testOneTimeMigrationFromUserDefaultsSkipsMalformedEntries() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerticalOffsetMigrateTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }
        let jsonURL = tempDir.appendingPathComponent("vertical_offsets.json")

        defaults.set(-0.10, forKey: VerticalOffsetStore.globalOffsetDefaultsKey)
        defaults.set(
            [
                "com.google.Chrome": -1.15,
                "com.broken.string": "not-a-number",
                "com.broken.bool": true
            ] as [String: Any],
            forKey: VerticalOffsetStore.perAppOffsetsDefaultsKey
        )

        let migrated = VerticalOffsetStore(fileURL: jsonURL, defaults: defaults)
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
        XCTAssertEqual(migrated.globalOffset, -0.10, accuracy: 1e-9)
        XCTAssertEqual(migrated.savedPerAppOffsets(), ["com.google.Chrome": -1.15])

        // Wipe defaults and reload from JSON; valid values survive and re-mirror back to defaults.
        defaults.removePersistentDomain(forName: suiteName)
        let reloaded = VerticalOffsetStore(fileURL: jsonURL, defaults: defaults)
        XCTAssertEqual(reloaded.globalOffset, -0.10, accuracy: 1e-9)
        XCTAssertEqual(reloaded.effectiveOffset(forBundleID: "com.google.Chrome"), -1.15, accuracy: 1e-9)
        XCTAssertEqual(defaults.double(forKey: VerticalOffsetStore.globalOffsetDefaultsKey), -0.10, accuracy: 1e-9)
    }

    func testDisplayKeyGenerationAndScopedKeyParsing() {
        XCTAssertEqual(
            VerticalOffsetStore.displayKey(
                isBuiltin: true, vendor: 0x0610, model: 0xa05f, serial: 4_251_086_178,
                localizedName: "Built-in Retina Display", scale: 2.0
            ),
            "builtin:0610-a05f@2x"
        )
        XCTAssertEqual(
            VerticalOffsetStore.displayKey(
                isBuiltin: false, vendor: 0x4c2d, model: 0x71e9, serial: 878_270_033,
                localizedName: "LS27B61x", scale: 2.0
            ),
            "ext:4c2d-71e9-878270033@2x"
        )
        XCTAssertEqual(
            VerticalOffsetStore.displayKey(
                isBuiltin: false, vendor: 0x4c2d, model: 0x71e9, serial: 0,
                localizedName: "Dell", scale: 1.5
            ),
            "ext:4c2d-71e9@1.5x"
        )
        XCTAssertEqual(
            VerticalOffsetStore.displayKey(
                isBuiltin: false, vendor: 0, model: 0, serial: 0,
                localizedName: "Virtual Display (2)", scale: 2.0
            ),
            "display:virtual-display-2@2x"
        )

        let scoped = VerticalOffsetStore.displayScopedKey(
            bundleID: "com.t3tools.t3code",
            displayKey: "ext:4c2d-71e9-878270033@2x"
        )
        let parsed = VerticalOffsetStore.parseDisplayScopedKey(scoped)
        XCTAssertEqual(parsed?.bundleID, "com.t3tools.t3code")
        XCTAssertEqual(parsed?.displayKey, "ext:4c2d-71e9-878270033@2x")
        XCTAssertNil(VerticalOffsetStore.parseDisplayScopedKey("noat"))
        XCTAssertNil(VerticalOffsetStore.parseDisplayScopedKey("@2x"))
        XCTAssertNil(VerticalOffsetStore.parseDisplayScopedKey("bundle@"))
    }

    func testPerDisplayFallbackChainAndReset() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerticalOffsetDisplayTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }
        let displayStore = VerticalOffsetStore(
            fileURL: tempDir.appendingPathComponent("vertical_offsets.json"),
            defaults: defaults
        )

        displayStore.globalOffset = -0.10
        displayStore.setOffset(-1.15, forBundleID: "com.google.Chrome")
        displayStore.setOffset(-1.35, forBundleID: "com.google.Chrome", displayKey: "ext")
        displayStore.setOffset(0.20, forBundleID: "com.google.antigravity", displayKey: "ext")

        XCTAssertEqual(displayStore.effectiveOffset(forBundleID: "com.google.Chrome", displayKey: "ext"), -1.35, accuracy: 1e-9)
        XCTAssertEqual(displayStore.effectiveOffset(forBundleID: "com.google.Chrome", displayKey: "builtin"), -1.15, accuracy: 1e-9)
        XCTAssertEqual(displayStore.effectiveOffset(forBundleID: "com.google.antigravity", displayKey: "ext"), 0.20, accuracy: 1e-9)
        XCTAssertEqual(displayStore.effectiveOffset(forBundleID: "com.google.antigravity", displayKey: "builtin"), 0.45, accuracy: 1e-9)
        XCTAssertEqual(displayStore.effectiveOffset(forBundleID: "com.example.other", displayKey: "ext"), -0.10, accuracy: 1e-9)
        XCTAssertTrue(displayStore.hasDisplaySpecificOverride(forBundleID: "com.google.Chrome", displayKey: "ext"))

        displayStore.removeOrReset(bundleID: "com.google.Chrome", displayKey: "ext")
        XCTAssertFalse(displayStore.hasDisplaySpecificOverride(forBundleID: "com.google.Chrome", displayKey: "ext"))
        XCTAssertEqual(displayStore.effectiveOffset(forBundleID: "com.google.Chrome", displayKey: "ext"), -1.15, accuracy: 1e-9)
    }

    func testLWWShardMergeAndTombstones() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerticalOffsetLWWTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }

        let suiteB = "WordTailVerticalOffsetLWWB-\(UUID().uuidString)"
        let defaultsB = try XCTUnwrap(UserDefaults(suiteName: suiteB))
        addTeardownBlock { defaultsB.removePersistentDomain(forName: suiteB) }

        let storeA = VerticalOffsetStore(fileURL: tempDir.appendingPathComponent("a.json"), defaults: defaults)
        let storeB = VerticalOffsetStore(fileURL: tempDir.appendingPathComponent("b.json"), defaults: defaultsB)

        storeA.globalOffset = -0.10
        storeA.setOffset(-1.15, forBundleID: "com.google.Chrome")
        storeA.setOffset(0.30, forBundleID: "com.apple.Notes")

        Thread.sleep(forTimeInterval: 0.01)
        storeB.setOffset(-0.20, forBundleID: "com.t3tools.t3code", displayKey: "ext:4c2d-71e9@2x")
        storeB.setOffset(-0.90, forBundleID: "com.google.Chrome")
        // Initial sync A -> B so B gets Notes, then B deletes Notes newer.
        XCTAssertTrue(storeB.applyRemoteShards(["a": storeA.exportLocalShard()]))
        XCTAssertEqual(storeB.effectiveOffset(forBundleID: "com.apple.Notes"), 0.30, accuracy: 1e-9)
        XCTAssertEqual(storeB.effectiveOffset(forBundleID: "com.google.Chrome"), -0.90, accuracy: 1e-9)

        Thread.sleep(forTimeInterval: 0.01)
        storeB.removeOrReset(bundleID: "com.apple.Notes")

        XCTAssertTrue(storeA.applyRemoteShards(["b": storeB.exportLocalShard()]))
        XCTAssertEqual(storeA.effectiveOffset(forBundleID: "com.google.Chrome"), -0.90, accuracy: 1e-9)
        XCTAssertEqual(storeA.effectiveOffset(forBundleID: "com.t3tools.t3code", displayKey: "ext:4c2d-71e9@2x"), -0.20, accuracy: 1e-9)
        XCTAssertNil(storeA.savedPerAppOffsets()["com.apple.Notes"])
        XCTAssertEqual(storeA.effectiveOffset(forBundleID: "com.apple.Notes"), -0.10, accuracy: 1e-9)
    }

    func testCalibrationTargetResolverFinderGuard() {
        let t3 = CalibrationAppInfo(
            name: "T3 Code",
            bundleID: "com.t3tools.t3code",
            displayKey: "ext:4c2d-71e9-878270033@2x",
            displayName: "LS27B61x"
        )
        let finder = CalibrationAppInfo(name: "Finder", bundleID: "com.apple.finder")
        let chrome = CalibrationAppInfo(name: "Google Chrome", bundleID: "com.google.Chrome")
        let selfApp = CalibrationAppInfo(name: "WordTail", bundleID: "app.wordtail.macos")

        XCTAssertEqual(
            VerticalOffsetStore.resolveCalibrationTarget(
                focusedApp: finder,
                focusedElementIsEditableText: false,
                frontmostApp: finder,
                recentTypedApp: t3,
                lastNonFinderApp: chrome,
                selfBundleID: "app.wordtail.macos"
            ),
            t3
        )

        XCTAssertEqual(
            VerticalOffsetStore.resolveCalibrationTarget(
                focusedApp: finder,
                focusedElementIsEditableText: false,
                frontmostApp: finder,
                recentTypedApp: nil,
                lastNonFinderApp: chrome,
                selfBundleID: "app.wordtail.macos"
            ),
            chrome
        )

        XCTAssertEqual(
            VerticalOffsetStore.resolveCalibrationTarget(
                focusedApp: finder,
                focusedElementIsEditableText: true,
                frontmostApp: finder,
                recentTypedApp: t3,
                lastNonFinderApp: chrome,
                selfBundleID: "app.wordtail.macos"
            ),
            finder
        )

        let frontT3NoDisplay = CalibrationAppInfo(name: "T3 Code", bundleID: "com.t3tools.t3code")
        XCTAssertEqual(
            VerticalOffsetStore.resolveCalibrationTarget(
                focusedApp: selfApp,
                focusedElementIsEditableText: true,
                frontmostApp: frontT3NoDisplay,
                recentTypedApp: t3,
                lastNonFinderApp: chrome,
                selfBundleID: "app.wordtail.macos"
            ),
            t3
        )
    }
}
