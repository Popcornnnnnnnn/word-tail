import AppKit
import Darwin
import Foundation
import WordTailCore

switch AppLaunchGuard.parseCLIAction(arguments: CommandLine.arguments) {
case .showHelp:
    print(AppLaunchGuard.helpText)
    exit(0)

case .showVersion:
    print(
        AppLaunchGuard.formatVersionLine(
            bundleURL: Bundle.main.bundleURL,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            shortVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            buildVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        )
    )
    exit(0)

case .invalidUsage(let message):
    fputs("\(message)\n\n\(AppLaunchGuard.helpText)\n", stderr)
    exit(2)

case .importKeyStats:
    let store = KeyStatsStore()
    do {
        let report = try store.importFromInstalledKeyStats(includeSyncedPeers: true)
        print(
            """
            Imported KeyStats data into WordTail successfully:
              localDaysImported=\(report.localDaysImported)
              hourlyBucketsImported=\(report.hourlyBucketsImported)
              peerDevicesImported=\(report.peerDevicesImported)
              peerDaysImported=\(report.peerDaysImported)
              totalKeysAfterImport=\(report.totalKeysAfterImport)
              totalActiveDaysAfterImport=\(report.totalActiveDaysAfterImport)
            """
        )
        exit(0)
    } catch {
        fputs("KeyStats import failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

case .exportShowcaseImages(let targetDir):
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated {
        do {
            try ShowcaseExporter.exportAll(to: targetDir)
            exit(0)
        } catch {
            fputs("Showcase export failed: \(error)\n", stderr)
            exit(1)
        }
    }

case .launchGUI(let openSettings, let background):
    let currentPID = ProcessInfo.processInfo.processIdentifier

    func liveOtherRunningApps() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: AppLaunchGuard.expectedBundleIdentifier)
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated && Darwin.kill($0.processIdentifier, 0) == 0 }
    }

    func notifyExistingInstance(_ runningApps: [NSRunningApplication]) {
        guard !background || openSettings else { return }
        if let existing = runningApps.first {
            existing.activate()
        }
        DistributedNotificationCenter.default().postNotificationName(
            AppLaunchGuard.reopenSettingsNotificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    let otherRunningApps = liveOtherRunningApps()
    if !otherRunningApps.isEmpty {
        notifyExistingInstance(otherRunningApps)
        exit(0)
    }

    let instanceLock: SingleInstanceLock?
    switch SingleInstanceLock.acquire() {
    case .acquired(let lock):
        instanceLock = lock
    case .alreadyRunning:
        notifyExistingInstance(liveOtherRunningApps())
        exit(0)
    case .unavailable:
        instanceLock = nil
    }

    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated { AppDelegate(instanceLock: instanceLock) }
    app.delegate = delegate
    app.run()
}
