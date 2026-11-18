import AppKit
import Foundation

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
let delegate = AppDelegate()
app.delegate = delegate
app.run()
