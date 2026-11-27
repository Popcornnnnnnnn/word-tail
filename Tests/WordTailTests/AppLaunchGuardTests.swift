import Darwin
import Foundation
import XCTest
@testable import WordTailCore

final class AppLaunchGuardTests: XCTestCase {
    func testCLIArgumentParsing() {
        XCTAssertEqual(AppLaunchGuard.parseCLIAction(arguments: ["WordTail", "--help"]), .showHelp)
        XCTAssertEqual(AppLaunchGuard.parseCLIAction(arguments: ["WordTail", "-h"]), .showHelp)
        XCTAssertEqual(AppLaunchGuard.parseCLIAction(arguments: ["WordTail", "--version"]), .showVersion)
        XCTAssertEqual(AppLaunchGuard.parseCLIAction(arguments: ["WordTail", "-v"]), .showVersion)
        XCTAssertEqual(AppLaunchGuard.parseCLIAction(arguments: ["WordTail", "--import-keystats"]), .importKeyStats)
        XCTAssertEqual(
            AppLaunchGuard.parseCLIAction(arguments: ["WordTail", "--export-showcase-images", "/tmp/out"]),
            .exportShowcaseImages(outputDirectory: "/tmp/out")
        )
        XCTAssertEqual(
            AppLaunchGuard.parseCLIAction(arguments: ["WordTail", "--export-showcase-images"]),
            .invalidUsage("Missing output directory for --export-showcase-images.")
        )
        XCTAssertEqual(
            AppLaunchGuard.parseCLIAction(arguments: ["WordTail", "--export-showcase-images", "--background"]),
            .invalidUsage("Missing output directory for --export-showcase-images.")
        )
        XCTAssertEqual(
            AppLaunchGuard.parseCLIAction(arguments: ["WordTail"]),
            .launchGUI(openSettings: false, background: false)
        )
        XCTAssertEqual(
            AppLaunchGuard.parseCLIAction(arguments: ["WordTail", "--open-settings"]),
            .launchGUI(openSettings: true, background: false)
        )
        XCTAssertEqual(
            AppLaunchGuard.parseCLIAction(arguments: ["WordTail", "--background"]),
            .launchGUI(openSettings: false, background: true)
        )
        XCTAssertEqual(
            AppLaunchGuard.parseCLIAction(arguments: ["WordTail", "--open-settings", "--background"]),
            .launchGUI(openSettings: true, background: true)
        )
        XCTAssertEqual(
            AppLaunchGuard.parseCLIAction(arguments: ["WordTail", "-psn_0_12345"]),
            .launchGUI(openSettings: false, background: false)
        )
    }

    func testBundledAppAndAutoUpdateTargetResolution() {
        let appURL = URL(fileURLWithPath: "/Applications/WordTail.app")
        XCTAssertTrue(
            AppLaunchGuard.isBundledApp(
                bundleURL: appURL,
                bundleIdentifier: "app.wordtail.macos",
                shortVersion: "0.9.2"
            )
        )
        XCTAssertEqual(
            AppLaunchGuard.resolveAutoUpdateTargetBundleURL(
                bundleURL: appURL,
                bundleIdentifier: "app.wordtail.macos",
                shortVersion: "0.9.2"
            ),
            appURL.standardizedFileURL
        )
        XCTAssertEqual(
            AppLaunchGuard.formatVersionLine(
                bundleURL: appURL,
                bundleIdentifier: "app.wordtail.macos",
                shortVersion: "0.9.2",
                buildVersion: "35"
            ),
            "WordTail 0.9.2 (35)"
        )
        XCTAssertEqual(
            AppLaunchGuard.formatVersionLine(
                bundleURL: appURL,
                bundleIdentifier: "app.wordtail.macos",
                shortVersion: "0.9.2",
                buildVersion: nil
            ),
            "WordTail 0.9.2"
        )

        let devDirURL = URL(fileURLWithPath: "/tmp/word-tail/.build/release")
        XCTAssertFalse(
            AppLaunchGuard.isBundledApp(
                bundleURL: devDirURL,
                bundleIdentifier: nil,
                shortVersion: nil
            )
        )
        XCTAssertNil(
            AppLaunchGuard.resolveAutoUpdateTargetBundleURL(
                bundleURL: devDirURL,
                bundleIdentifier: nil,
                shortVersion: nil
            )
        )
        XCTAssertEqual(
            AppLaunchGuard.formatVersionLine(
                bundleURL: devDirURL,
                bundleIdentifier: nil,
                shortVersion: nil,
                buildVersion: nil
            ),
            "WordTail (development build)"
        )

        XCTAssertFalse(
            AppLaunchGuard.isBundledApp(
                bundleURL: appURL,
                bundleIdentifier: "com.example.other",
                shortVersion: "0.9.2"
            )
        )
        XCTAssertNil(
            AppLaunchGuard.resolveAutoUpdateTargetBundleURL(
                bundleURL: appURL,
                bundleIdentifier: "com.example.other",
                shortVersion: "0.9.2"
            )
        )

        XCTAssertFalse(
            AppLaunchGuard.isBundledApp(
                bundleURL: appURL,
                bundleIdentifier: "app.wordtail.macos",
                shortVersion: "   "
            )
        )
        XCTAssertNil(
            AppLaunchGuard.resolveAutoUpdateTargetBundleURL(
                bundleURL: appURL,
                bundleIdentifier: "app.wordtail.macos",
                shortVersion: "   "
            )
        )
    }

    func testSingleInstanceLockEnforcesExclusivityAndUsesCloseOnExec() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLaunchGuardLockTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }
        let lockURL = tempDir.appendingPathComponent("instance.lock")

        let firstLock: SingleInstanceLock
        switch SingleInstanceLock.acquire(lockURL: lockURL) {
        case .acquired(let lock):
            firstLock = lock
        case .alreadyRunning:
            XCTFail("Expected first lock acquisition to succeed, got alreadyRunning")
            return
        case .unavailable(let err):
            XCTFail("Expected first lock acquisition to succeed, got errno \(err)")
            return
        }

        switch SingleInstanceLock.acquire(lockURL: lockURL) {
        case .alreadyRunning:
            break
        case .acquired(let unexpected):
            unexpected.release()
            XCTFail("Second lock acquisition should return .alreadyRunning while first lock is held")
        case .unavailable(let err):
            XCTFail("Unexpected lock error \(err)")
        }

        // Spawn a child while holding the lock, release in parent, and verify O_CLOEXEC kept the child from holding flock.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "sleep 1"]
        try child.run()
        addTeardownBlock {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }

        firstLock.release()

        switch SingleInstanceLock.acquire(lockURL: lockURL) {
        case .acquired(let reacquired):
            XCTAssertTrue(child.isRunning, "Child should still be alive when reacquire succeeds via O_CLOEXEC")
            reacquired.release()
        case .alreadyRunning:
            XCTFail("Lock should not stay held by child process (missing O_CLOEXEC)")
        case .unavailable(let err):
            XCTFail("Unexpected lock reacquire error \(err)")
        }

        if child.isRunning {
            child.terminate()
            child.waitUntilExit()
        }
    }

    func testSwapAndRelaunchScriptStructureAndSandboxExecution() throws {
        let script = AppLaunchGuard.swapAndRelaunchScript
        XCTAssertFalse(script.contains("open -n"), "Updater must never launch a second instance with open -n")
        XCTAssertTrue(script.contains("TARGET_BIN"))
        XCTAssertTrue(script.contains("open \"$DST\" --args --open-settings"))

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLaunchGuardSwapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let binDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
        let stageDir = tempRoot.appendingPathComponent("stage", isDirectory: true)
        let stagedApp = stageDir.appendingPathComponent("WordTail.app", isDirectory: true)
        let appsDir = tempRoot.appendingPathComponent("Applications", isDirectory: true)
        let targetApp = appsDir.appendingPathComponent("WordTail.app", isDirectory: true)
        let openArgsFile = tempRoot.appendingPathComponent("open_args.txt")

        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: stagedApp.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: targetApp.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )

        try Data("new".utf8).write(to: stagedApp.appendingPathComponent("Contents/MacOS/version.txt"))
        try Data("old".utf8).write(to: targetApp.appendingPathComponent("Contents/MacOS/version.txt"))

        let fakeOpen = binDir.appendingPathComponent("open")
        let fakeOpenScript = """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(openArgsFile.path)"
            """
        try Data(fakeOpenScript.utf8).write(to: fakeOpen)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpen.path)

        let dummyProc = Process()
        dummyProc.executableURL = URL(fileURLWithPath: "/bin/sh")
        dummyProc.arguments = ["-c", "sleep 0.4"]
        try dummyProc.run()

        let updaterProc = Process()
        updaterProc.executableURL = URL(fileURLWithPath: "/bin/sh")
        updaterProc.arguments = [
            "-c",
            script,
            "wordtail-updater",
            String(dummyProc.processIdentifier),
            stagedApp.path,
            targetApp.path,
            stageDir.path
        ]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(binDir.path):\(env["PATH"] ?? "/usr/bin:/bin")"
        updaterProc.environment = env
        try updaterProc.run()
        updaterProc.waitUntilExit()
        dummyProc.waitUntilExit()

        XCTAssertEqual(updaterProc.terminationStatus, 0)
        XCTAssertFalse(dummyProc.isRunning)

        let installedMarker = try String(
            contentsOf: targetApp.appendingPathComponent("Contents/MacOS/version.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(installedMarker, "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetApp.path + ".backup"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stageDir.path))

        let recordedArgs = try String(contentsOf: openArgsFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(recordedArgs, [targetApp.path, "--args", "--open-settings"])
    }
}
