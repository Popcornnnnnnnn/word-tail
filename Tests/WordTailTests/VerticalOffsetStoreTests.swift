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
}
