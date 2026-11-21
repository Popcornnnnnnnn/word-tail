import AppKit
import Foundation
import WordTailCore

if CommandLine.arguments.contains("--import-keystats") {
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
}

if let flagIdx = CommandLine.arguments.firstIndex(of: "--export-showcase-images"),
   flagIdx + 1 < CommandLine.arguments.count {
    let targetDir = CommandLine.arguments[flagIdx + 1]
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
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
