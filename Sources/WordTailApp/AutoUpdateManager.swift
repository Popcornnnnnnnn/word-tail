import AppKit
import Foundation
import SwiftUI
import WordTailCore

struct AvailableRelease: Equatable, Sendable {
    let tagName: String
    let version: String
    let htmlURL: URL
    let zipAssetURL: URL
    let assetName: String
    let releaseNotes: String
}

/// Checks GitHub Releases for new WordTail versions, prompts before updating, verifies Apple code signature,
/// and atomically swaps `/Applications/WordTail.app` + relaunches.
@MainActor
final class AutoUpdateManager: ObservableObject {
    static let autoCheckDefaultsKey = "WordTailAutoCheckUpdates"
    static let lastPromptedTagDefaultsKey = "WordTailLastPromptedReleaseTag"
    static let latestReleaseEndpoint = URL(string: "https://api.github.com/repos/Popcornnnnnnnn/word-tail/releases/latest")!
    nonisolated static let expectedBundleID = "app.wordtail.macos"

    @Published var autoCheckEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckEnabled, forKey: Self.autoCheckDefaultsKey)
            rescheduleBackgroundTimer()
        }
    }

    @Published private(set) var availableRelease: AvailableRelease? {
        didSet {
            if availableRelease != oldValue {
                updateWindow?.close()
                updateWindow = nil
            }
        }
    }
    @Published private(set) var isChecking: Bool = false
    @Published private(set) var isInstalling: Bool = false
    @Published private(set) var statusMessage: String = "" {
        didSet {
            updateWindowState.progress = isInstalling ? statusMessage : nil
        }
    }

    var onBeforeTerminateForUpdate: (() -> Void)?
    var onUpdateStateChanged: (() -> Void)?

    private var periodicTimer: Timer?
    private var initialCheckScheduled = false
    private let updateWindowState = UpdateWindowState()
    private var updateWindow: NSWindow?

    init() {
        if UserDefaults.standard.object(forKey: Self.autoCheckDefaultsKey) == nil {
            self.autoCheckEnabled = true
        } else {
            self.autoCheckEnabled = UserDefaults.standard.bool(forKey: Self.autoCheckDefaultsKey)
        }
        self.statusMessage = "Current version v\(Self.currentAppVersion())"
    }

    var currentVersion: String {
        Self.currentAppVersion()
    }

    static func currentAppVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.6.0"
    }

    func startLifecycle() {
        rescheduleBackgroundTimer()
        guard autoCheckEnabled, !initialCheckScheduled else { return }
        initialCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self, self.autoCheckEnabled else { return }
            self.checkForUpdates(userInitiated: false)
        }
    }

    private func rescheduleBackgroundTimer() {
        periodicTimer?.invalidate()
        periodicTimer = nil
        guard autoCheckEnabled else { return }
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 6.0 * 3600.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.autoCheckEnabled else { return }
                self.checkForUpdates(userInitiated: false)
            }
        }
    }

    func checkForUpdates(userInitiated: Bool) {
        if isInstalling {
            if userInitiated {
                showUpdateWindow()
            }
            return
        }
        guard !isChecking else { return }
        isChecking = true
        statusMessage = "Checking GitHub Releases…"
        onUpdateStateChanged?()

        let currentVer = currentVersion
        Task {
            defer {
                isChecking = false
                onUpdateStateChanged?()
            }

            do {
                var request = URLRequest(url: Self.latestReleaseEndpoint)
                request.timeoutInterval = 15
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("WordTail/\(currentVer)", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard !isInstalling else { return }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    statusMessage = "Could not check updates right now"
                    if userInitiated {
                        showInfoAlert(
                            title: "Update Check Failed",
                            message: "GitHub Releases could not be reached right now. Please try again in a moment."
                        )
                    }
                    return
                }

                let payload = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
                guard !payload.draft, !payload.prerelease else {
                    availableRelease = nil
                    statusMessage = "Up to date (v\(currentVer))"
                    if userInitiated {
                        showUpToDateAlert(version: currentVer)
                    }
                    return
                }

                let remoteVer = VersionComparator.normalizedVersionString(payload.tagName)
                guard VersionComparator.isNewer(remote: remoteVer, current: currentVer),
                      let zipAsset = payload.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }),
                      let zipURL = URL(string: zipAsset.browserDownloadURL),
                      let pageURL = URL(string: payload.htmlURL) else {
                    availableRelease = nil
                    statusMessage = "Up to date (v\(currentVer))"
                    if userInitiated {
                        showUpToDateAlert(version: currentVer)
                    }
                    return
                }

                let release = AvailableRelease(
                    tagName: payload.tagName,
                    version: remoteVer,
                    htmlURL: pageURL,
                    zipAssetURL: zipURL,
                    assetName: zipAsset.name,
                    releaseNotes: payload.body ?? ""
                )
                availableRelease = release
                statusMessage = "Update available: v\(release.version)"
                onUpdateStateChanged?()

                let lastPrompted = UserDefaults.standard.string(forKey: Self.lastPromptedTagDefaultsKey)
                if userInitiated || lastPrompted != release.tagName {
                    UserDefaults.standard.set(release.tagName, forKey: Self.lastPromptedTagDefaultsKey)
                    promptForUpdate(release)
                }
            } catch {
                guard !isInstalling else { return }
                statusMessage = "Update check failed"
                if userInitiated {
                    showInfoAlert(
                        title: "Update Check Failed",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    func promptAndInstallCurrentRelease() {
        guard let release = availableRelease else {
            checkForUpdates(userInitiated: true)
            return
        }
        promptForUpdate(release)
    }

    func installReleaseNow(_ release: AvailableRelease) {
        guard !isInstalling else { return }
        guard let targetAppURL = Self.resolveTargetAppBundleURL() else {
            showInfoAlert(
                title: "Cannot Auto-Replace Development Binary",
                message: "Install WordTail.app in /Applications first so automatic updates have an app bundle to update."
            )
            return
        }

        let parentDir = targetAppURL.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parentDir) else {
            NSWorkspace.shared.open(release.htmlURL)
            showInfoAlert(
                title: "Administrator Permission Needed",
                message: "\(parentDir) is not writable by the current macOS account. Opened the release page in your browser instead."
            )
            return
        }

        isInstalling = true
        statusMessage = "Downloading WordTail v\(release.version)…"
        onUpdateStateChanged?()

        let runningBundleURL = Bundle.main.bundleURL.standardizedFileURL
        Task {
            do {
                let stageRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .appendingPathComponent("WordTailUpdate-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: stageRoot, withIntermediateDirectories: true)

                let (downloadedTempURL, response) = try await URLSession.shared.download(from: release.zipAssetURL)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    try? FileManager.default.removeItem(at: stageRoot)
                    throw UpdateError.downloadFailed
                }

                let zipPath = stageRoot.appendingPathComponent("WordTail-update.zip")
                try FileManager.default.moveItem(at: downloadedTempURL, to: zipPath)

                statusMessage = "Verifying signature & installing…"
                onUpdateStateChanged?()

                let extractedAppURL = try await Task.detached(priority: .userInitiated) {
                    try Self.unpackAndVerifySignedApp(
                        zipURL: zipPath,
                        stageRoot: stageRoot,
                        runningBundleURL: runningBundleURL
                    )
                }.value

                onBeforeTerminateForUpdate?()
                try Self.spawnDetachedSwapAndRelaunch(
                    currentPID: ProcessInfo.processInfo.processIdentifier,
                    stagedAppURL: extractedAppURL,
                    targetAppURL: targetAppURL,
                    stageRoot: stageRoot
                )

                NSApplication.shared.terminate(nil)
            } catch {
                isInstalling = false
                statusMessage = "Update failed: \(error.localizedDescription)"
                onUpdateStateChanged?()
                showInfoAlert(
                    title: "Update Could Not Be Installed",
                    message: "\(error.localizedDescription)\n\nYou can also download v\(release.version) manually from GitHub Releases."
                )
            }
        }
    }

    // MARK: - Update Presentation

    private func promptForUpdate(_ release: AvailableRelease) {
        if updateWindow == nil {
            let view = UpdateWindowView(
                currentVersion: currentVersion,
                availableVersion: release.version,
                icon: NSApp.applicationIconImage,
                release: release.htmlURL,
                markdown: release.releaseNotes,
                state: updateWindowState,
                dismiss: { [weak self] in self?.updateWindow?.close() },
                install: { [weak self] in self?.installReleaseNow(release) }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable]
            window.title = "Software Update"
            window.isReleasedWhenClosed = false
            window.center()
            updateWindow = window
        }
        showUpdateWindow()
    }

    private func showUpdateWindow() {
        NSApp.activate(ignoringOtherApps: true)
        updateWindow?.makeKeyAndOrderFront(nil)
    }

    private func showUpToDateAlert(version: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "WordTail is up to date"
        alert.informativeText = "WordTail v\(version) is currently the newest version available."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showInfoAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Unpacking, Code Signature Verification, & Atomic Swap

    private enum UpdateError: LocalizedError {
        case downloadFailed
        case unpackFailed
        case missingAppBundle
        case invalidCodeSignature(String)
        case untrustedSigner(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed:
                return "Failed to download the release archive from GitHub."
            case .unpackFailed:
                return "Failed to unpack the downloaded update archive."
            case .missingAppBundle:
                return "Downloaded archive did not contain WordTail.app."
            case .invalidCodeSignature(let detail):
                return "Code signature verification failed (\(detail))."
            case .untrustedSigner(let detail):
                return "Downloaded app signer could not be verified (\(detail))."
            }
        }
    }

    private nonisolated static func resolveTargetAppBundleURL() -> URL? {
        let mainURL = Bundle.main.bundleURL.standardizedFileURL
        if mainURL.pathExtension == "app" {
            return mainURL
        }
        let standardApps = URL(fileURLWithPath: "/Applications/WordTail.app")
        if FileManager.default.fileExists(atPath: standardApps.path) {
            return standardApps
        }
        return nil
    }

    private nonisolated static func unpackAndVerifySignedApp(
        zipURL: URL,
        stageRoot: URL,
        runningBundleURL: URL
    ) throws -> URL {
        let extractDir = stageRoot.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let dittoRes = runProcess(executable: "/usr/bin/ditto", arguments: ["-x", "-k", zipURL.path, extractDir.path])
        guard dittoRes.exitCode == 0 else {
            throw UpdateError.unpackFailed
        }

        let directApp = extractDir.appendingPathComponent("WordTail.app", isDirectory: true)
        let candidateApp: URL
        if FileManager.default.fileExists(atPath: directApp.path) {
            candidateApp = directApp
        } else if let found = (try? FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) {
            candidateApp = found
        } else {
            throw UpdateError.missingAppBundle
        }

        // 1. Strict cryptographic bundle integrity check
        let verifyRes = runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", candidateApp.path]
        )
        guard verifyRes.exitCode == 0 else {
            let msg = verifyRes.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.invalidCodeSignature(msg.isEmpty ? "exit \(verifyRes.exitCode)" : msg)
        }

        // 2. Inspect bundle identifier & Apple certificate authority / TeamIdentifier match
        let candidateMeta = inspectCodesignMetadata(appURL: candidateApp)
        guard candidateMeta.bundleID == expectedBundleID else {
            throw UpdateError.untrustedSigner("unexpected bundle ID \(candidateMeta.bundleID ?? "unknown")")
        }

        if runningBundleURL.pathExtension == "app" {
            let currentMeta = inspectCodesignMetadata(appURL: runningBundleURL)
            if let currentTeam = currentMeta.teamID, currentTeam != "not set", !currentTeam.isEmpty {
                guard candidateMeta.teamID == currentTeam else {
                    throw UpdateError.untrustedSigner("TeamIdentifier mismatch")
                }
                return candidateApp
            }
        }

        // Fallback when upgrading from a local ad-hoc build: require Apple-rooted Developer ID signature
        let hasDeveloperID = candidateMeta.authorities.contains { $0.hasPrefix("Developer ID Application:") }
        let hasAppleRoot = candidateMeta.authorities.contains { $0 == "Apple Root CA" }
        guard hasDeveloperID && hasAppleRoot else {
            throw UpdateError.untrustedSigner("Update must be signed with Developer ID Application")
        }

        return candidateApp
    }

    private nonisolated static func inspectCodesignMetadata(appURL: URL) -> (bundleID: String?, teamID: String?, authorities: [String]) {
        let res = runProcess(executable: "/usr/bin/codesign", arguments: ["-dv", "--verbose=4", appURL.path])
        let combined = res.stderr + "\n" + res.stdout
        var bundleID: String?
        var teamID: String?
        var authorities: [String] = []
        for rawLine in combined.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("Identifier=") {
                bundleID = String(line.dropFirst("Identifier=".count))
            } else if line.hasPrefix("TeamIdentifier=") {
                teamID = String(line.dropFirst("TeamIdentifier=".count))
            } else if line.hasPrefix("Authority=") {
                authorities.append(String(line.dropFirst("Authority=".count)))
            }
        }
        return (bundleID, teamID, authorities)
    }

    private nonisolated static func runProcess(executable: String, arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        let outStr = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (proc.terminationStatus, outStr, errStr)
    }

    private nonisolated static func spawnDetachedSwapAndRelaunch(
        currentPID: Int32,
        stagedAppURL: URL,
        targetAppURL: URL,
        stageRoot: URL
    ) throws {
        let script = """
        PID="$1"
        SRC="$2"
        DST="$3"
        STAGE="$4"
        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 60 ]; do
            sleep 0.2
            i=$((i + 1))
        done
        BACKUP="${DST}.backup"
        rm -rf "$BACKUP"
        if [ -d "$DST" ]; then
            if ! mv "$DST" "$BACKUP"; then
                rm -rf "$STAGE"
                exit 1
            fi
        fi
        if mv "$SRC" "$DST"; then
            rm -rf "$BACKUP" "$STAGE"
            sleep 0.25
            open -n "$DST" --args --open-settings
            exit 0
        else
            if [ -d "$BACKUP" ]; then
                mv "$BACKUP" "$DST"
            fi
            rm -rf "$STAGE"
            exit 1
        fi
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [
            "-c",
            script,
            "wordtail-updater",
            String(currentPID),
            stagedAppURL.path,
            targetAppURL.path,
            stageRoot.path
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }

    // MARK: - GitHub API Schema

    private struct GitHubReleaseResponse: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case draft
            case prerelease
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}
