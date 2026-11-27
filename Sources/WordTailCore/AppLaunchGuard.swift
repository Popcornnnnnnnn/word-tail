import Darwin
import Foundation

/// Parsed command-line action for the `WordTail` executable.
public enum AppCLIAction: Equatable, Sendable {
    case showHelp
    case showVersion
    case importKeyStats
    case exportShowcaseImages(outputDirectory: String)
    case invalidUsage(String)
    case launchGUI(openSettings: Bool, background: Bool)
}

/// Pure, testable launch, bundle-identity, and auto-updater guard helpers.
public enum AppLaunchGuard {
    public static let expectedBundleIdentifier = "app.wordtail.macos"
    public static let reopenSettingsNotificationName = Notification.Name("app.wordtail.macos.reopenSettings")

    public static let helpText = """
        WordTail — Zero-LLM inline ghost-text autocomplete for macOS

        Usage: WordTail [options]

        Options:
          --open-settings                 Open the Settings window on launch (or focus running instance)
          --background                    Launch silently in the menu bar without opening Settings
          --import-keystats               Import KeyStats JSON history into WordTail and exit
          --export-showcase-images <dir>  Render documentation showcase screenshots to <dir> and exit
          -v, --version                   Print version information and exit
          -h, --help                      Show this help message and exit
        """

    /// Parses CLI arguments before AppKit/NSApplication startup.
    /// Unknown flags (such as macOS LaunchServices `-psn_*` or `-AppleLanguages`) are ignored for GUI launch.
    public static func parseCLIAction(arguments: [String]) -> AppCLIAction {
        let args = Array(arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            return .showHelp
        }
        if args.contains("--version") || args.contains("-v") {
            return .showVersion
        }
        if args.contains("--import-keystats") {
            return .importKeyStats
        }
        if let flagIdx = args.firstIndex(of: "--export-showcase-images") {
            let valueIdx = flagIdx + 1
            if valueIdx < args.count {
                let candidate = args[valueIdx]
                if !candidate.isEmpty && !candidate.hasPrefix("-") {
                    return .exportShowcaseImages(outputDirectory: candidate)
                }
            }
            return .invalidUsage("Missing output directory for --export-showcase-images.")
        }
        return .launchGUI(
            openSettings: args.contains("--open-settings"),
            background: args.contains("--background")
        )
    }

    /// Returns true only when running from a signed/packaged `.app` bundle with WordTail's bundle ID and version.
    public static func isBundledApp(
        bundleURL: URL,
        bundleIdentifier: String?,
        shortVersion: String?
    ) -> Bool {
        guard bundleURL.standardizedFileURL.pathExtension.lowercased() == "app" else {
            return false
        }
        guard bundleIdentifier == expectedBundleIdentifier else {
            return false
        }
        guard let trimmedVersion = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedVersion.isEmpty else {
            return false
        }
        return true
    }

    /// Resolves the `.app` bundle URL eligible for self-replacement during auto-update.
    /// Returns `nil` for unbundled development binaries instead of falling back to `/Applications/WordTail.app`.
    public static func resolveAutoUpdateTargetBundleURL(
        bundleURL: URL,
        bundleIdentifier: String?,
        shortVersion: String?
    ) -> URL? {
        let standardized = bundleURL.standardizedFileURL
        guard isBundledApp(
            bundleURL: standardized,
            bundleIdentifier: bundleIdentifier,
            shortVersion: shortVersion
        ) else {
            return nil
        }
        return standardized
    }

    /// Formats the `--version` output for either a packaged `.app` bundle or an unbundled development binary.
    public static func formatVersionLine(
        bundleURL: URL,
        bundleIdentifier: String?,
        shortVersion: String?,
        buildVersion: String?
    ) -> String {
        guard isBundledApp(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            shortVersion: shortVersion
        ),
        let trimmedVersion = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return "WordTail (development build)"
        }
        if let trimmedBuild = buildVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedBuild.isEmpty {
            return "WordTail \(trimmedVersion) (\(trimmedBuild))"
        }
        return "WordTail \(trimmedVersion)"
    }

    /// Detached POSIX shell script run by AutoUpdateManager to swap the `.app` bundle and relaunch cleanly.
    /// Arguments: `$1` = updater process PID, `$2` = staged app path, `$3` = target app path, `$4` = staging root.
    public static let swapAndRelaunchScript = #"""
        PID="$1"
        SRC="$2"
        DST="${3%/}"
        STAGE="$4"
        TARGET_BIN="${DST}/Contents/MacOS/WordTail"

        wait_for_pid() {
            target_pid="$1"
            max_ticks="$2"
            ticks=0
            while kill -0 "$target_pid" 2>/dev/null && [ "$ticks" -lt "$max_ticks" ]; do
                sleep 0.2
                ticks=$((ticks + 1))
            done
            ! kill -0 "$target_pid" 2>/dev/null
        }

        if ! wait_for_pid "$PID" 40; then
            kill -TERM "$PID" 2>/dev/null || true
            if ! wait_for_pid "$PID" 15; then
                rm -rf "$STAGE"
                exit 1
            fi
        fi

        for other_pid in $(pgrep -x WordTail 2>/dev/null || true); do
            if [ "$other_pid" = "$PID" ]; then
                continue
            fi
            other_comm="$(ps -o comm= -p "$other_pid" 2>/dev/null | sed 's/^[[:space:]]*//')"
            if [ "$other_comm" = "$TARGET_BIN" ]; then
                kill -TERM "$other_pid" 2>/dev/null || true
                if ! wait_for_pid "$other_pid" 25; then
                    rm -rf "$STAGE"
                    exit 1
                fi
            fi
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
            sleep 0.3
            open "$DST" --args --open-settings
            exit 0
        else
            if [ -d "$BACKUP" ]; then
                mv "$BACKUP" "$DST"
            fi
            rm -rf "$STAGE"
            exit 1
        fi
        """#
}

/// Exclusive non-blocking advisory file lock with `O_CLOEXEC` to enforce a single GUI instance.
@_silgen_name("flock")
private func posixFlock(_ fd: Int32, _ operation: Int32) -> Int32

public final class SingleInstanceLock {
    public enum AcquireResult {
        case acquired(SingleInstanceLock)
        case alreadyRunning
        case unavailable(Int32)
    }

    public static var defaultLockURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("WordTail", isDirectory: true)
            .appendingPathComponent("instance.lock")
    }

    private var fileDescriptor: Int32
    public let lockURL: URL

    private init(fileDescriptor: Int32, lockURL: URL) {
        self.fileDescriptor = fileDescriptor
        self.lockURL = lockURL
    }

    deinit {
        release()
    }

    /// Acquires an exclusive `flock` on `lockURL`. Opened with `O_CLOEXEC` so child processes never inherit it.
    public static func acquire(lockURL: URL = defaultLockURL) -> AcquireResult {
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            // Fall through to open(), which will report the concrete errno if directory creation failed.
        }

        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        if fd < 0 {
            return .unavailable(errno)
        }

        if posixFlock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            Darwin.close(fd)
            return err == EWOULDBLOCK ? .alreadyRunning : .unavailable(err)
        }

        _ = Darwin.ftruncate(fd, 0)
        let pidLine = "\(ProcessInfo.processInfo.processIdentifier)\n"
        pidLine.withCString { ptr in
            _ = Darwin.write(fd, ptr, strlen(ptr))
        }
        return .acquired(SingleInstanceLock(fileDescriptor: fd, lockURL: lockURL))
    }

    /// Explicitly unlocks and closes the underlying file descriptor. Safe to call multiple times.
    public func release() {
        guard fileDescriptor >= 0 else { return }
        _ = posixFlock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }
}
