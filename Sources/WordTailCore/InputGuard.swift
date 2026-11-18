import AppKit
import Carbon.HIToolbox
import Foundation

public final class InputGuard {
    public static let defaultExcludedBundleIDs: Set<String> = [
        // Terminals
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        // Code editors & IDEs (already have native Tab code completion)
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.apple.dt.Xcode",
        "dev.zed.Zed",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        // Credential managers
        "com.1password.1password",
        "com.apple.keychainaccess",
        "com.bitwarden.desktop"
    ]

    private let defaults: UserDefaults
    private let disabledAppsKey = "WordTailDisabledBundleIDs"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var userDisabledBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: disabledAppsKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: disabledAppsKey) }
    }

    public func isBundleDisabled(_ bundleID: String) -> Bool {
        Self.defaultExcludedBundleIDs.contains(bundleID) || userDisabledBundleIDs.contains(bundleID)
    }

    public func toggleUserDisabled(bundleID: String) {
        var current = userDisabledBundleIDs
        if current.contains(bundleID) {
            current.remove(bundleID)
        } else {
            current.insert(bundleID)
        }
        userDisabledBundleIDs = current
    }

    /// Returns true only when:
    /// 1. Password / Secure Event Input is NOT active
    /// 2. Active keyboard input source is an ASCII/Roman keyboard layout (not Chinese Pinyin / Doubao IME)
    /// 3. Frontmost app is not excluded
    public func shouldAllowPrediction(frontmostBundleID: String?) -> Bool {
        if IsSecureEventInputEnabled() {
            return false
        }
        if let bundleID = frontmostBundleID, isBundleDisabled(bundleID) {
            return false
        }
        return Self.isCurrentInputSourceRomanKeyboardLayout()
    }

    public static func isCurrentInputSourceRomanKeyboardLayout() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return false
        }
        if let typePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) {
            let type = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue()
            if type != kTISTypeKeyboardLayout {
                // Chinese Pinyin, Doubao IME, Rime, etc. use kTISTypeKeyboardInputMode or kTISTypeInputMethod
                return false
            }
        }
        if let asciiPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) {
            let isASCII = Unmanaged<CFBoolean>.fromOpaque(asciiPtr).takeUnretainedValue()
            return CFBooleanGetValue(isASCII)
        }
        return true
    }
}
