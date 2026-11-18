import AppKit
import ApplicationServices
import ServiceManagement
import WordTailCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let historyStore = UserHistoryStore()
    private let inputGuard = InputGuard()
    private lazy var completer = WordCompleter(historyStore: historyStore)
    private lazy var engine = TypingEngine(
        completer: completer,
        historyStore: historyStore,
        inputGuard: inputGuard
    )

    private var permissionPollTimer: Timer?
    private var lastObservedApp: (name: String, bundleID: String)?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.onStateChanged = { [weak self] in
            self?.updateStatusIcon()
        }
        ensureLoginItemRegisteredOnFirstInstall()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier else {
                return
            }
            self?.lastObservedApp = (app.localizedName ?? bundleID, bundleID)
        }

        if let front = NSWorkspace.shared.frontmostApplication,
           let bundleID = front.bundleIdentifier,
           bundleID != Bundle.main.bundleIdentifier {
            lastObservedApp = (front.localizedName ?? bundleID, bundleID)
        }

        setupStatusBar()
        attemptStartEngine(promptIfNeeded: true)

        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                self?.openSettingsClicked()
            }
        }
    }

    private func ensureLoginItemRegisteredOnFirstInstall() {
        // Auto-register as a macOS Login Item unless the user explicitly turned it off in Settings.
        let userConfigured = UserDefaults.standard.bool(forKey: "WordTailLoginItemUserConfigured")
        guard !userConfigured else { return }
        if Bundle.main.bundlePath.hasPrefix("/Applications/"),
           SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let trusted = AXIsProcessTrusted() && engine.isTapActive
        if !trusted {
            if let warn = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "WordTail Needs Permission") {
                warn.isTemplate = true
                button.image = warn
                button.appearsDisabled = false
                return
            }
        }
        button.image = Self.makeMenuBarIcon()
        button.appearsDisabled = !engine.isEnabled
    }

    private static func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            let leftAttr: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            let rightAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: NSColor.black.withAlphaComponent(0.38)
            ]

            let aStr = "a" as NSString
            let bStr = "b" as NSString
            let aSize = aStr.size(withAttributes: leftAttr)
            let bSize = bStr.size(withAttributes: rightAttr)

            let barW: CGFloat = 1.4
            let gap: CGFloat = 1.0
            let totalW = aSize.width + gap + barW + gap + bSize.width
            let startX = (rect.width - totalW) / 2.0
            let textY = (rect.height - aSize.height) / 2.0

            aStr.draw(at: NSPoint(x: startX, y: textY), withAttributes: leftAttr)

            let barRect = NSRect(
                x: startX + aSize.width + gap,
                y: (rect.height - 13.0) / 2.0,
                width: barW,
                height: 13.0
            )
            NSColor.black.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 0.7, yRadius: 0.7).fill()

            bStr.draw(at: NSPoint(x: barRect.maxX + gap, y: textY), withAttributes: rightAttr)
            return true
        }
        img.isTemplate = true
        return img
    }

    private func attemptStartEngine(promptIfNeeded: Bool) {
        if promptIfNeeded {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            if !CGPreflightListenEventAccess() {
                CGRequestListenEventAccess()
            }
        }

        if AXIsProcessTrusted() && engine.start() {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
            updateStatusIcon()
        } else if permissionPollTimer == nil {
            permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                if AXIsProcessTrusted() && self.engine.start() {
                    self.permissionPollTimer?.invalidate()
                    self.permissionPollTimer = nil
                    self.updateStatusIcon()
                }
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        let trusted = AXIsProcessTrusted() && engine.isTapActive
        let headerTitle = !trusted
            ? "Permissions Needed — Click to Grant…"
            : (engine.isEnabled ? "WordTail — Active" : "WordTail — Paused")
        let statusItemEntry = NSMenuItem(
            title: headerTitle,
            action: trusted ? nil : #selector(requestPermissionsClicked),
            keyEquivalent: ""
        )
        statusItemEntry.target = self
        statusItemEntry.isEnabled = !trusted
        menu.addItem(statusItemEntry)

        menu.addItem(.separator())

        let enabledItem = NSMenuItem(
            title: "Enable WordTail",
            action: #selector(toggleEnabled),
            keyEquivalent: "w"
        )
        enabledItem.keyEquivalentModifierMask = [.control, .option]
        enabledItem.target = self
        enabledItem.state = engine.isEnabled ? .on : .off
        menu.addItem(enabledItem)

        let spaceItem = NSMenuItem(
            title: "Insert Space After Tab",
            action: #selector(toggleAppendSpace),
            keyEquivalent: ""
        )
        spaceItem.target = self
        spaceItem.state = engine.appendSpaceOnAccept ? .on : .off
        menu.addItem(spaceItem)

        if let targetApp = currentTargetApp() {
            let isDefaultExcluded = InputGuard.defaultExcludedBundleIDs.contains(targetApp.bundleID)
            if isDefaultExcluded {
                let excludedItem = NSMenuItem(
                    title: "Auto-paused in \(targetApp.name) (IDE / Terminal)",
                    action: nil,
                    keyEquivalent: ""
                )
                excludedItem.isEnabled = false
                menu.addItem(excludedItem)
            } else {
                let isUserDisabled = inputGuard.userDisabledBundleIDs.contains(targetApp.bundleID)
                let appToggle = NSMenuItem(
                    title: "Enable in \(targetApp.name)",
                    action: #selector(toggleCurrentApp(_:)),
                    keyEquivalent: ""
                )
                appToggle.target = self
                appToggle.representedObject = targetApp.bundleID
                appToggle.state = isUserDisabled ? .off : .on
                let icon = SettingsViewModel.appIcon(forBundleID: targetApp.bundleID)
                icon.size = NSSize(width: 16, height: 16)
                appToggle.image = icon
                menu.addItem(appToggle)

                let curOffset = engine.verticalAdjustment(forBundleID: targetApp.bundleID)
                let nudgeMenu = NSMenu()
                let upItem = NSMenuItem(title: "Nudge Higher (+0.02 pt)", action: #selector(nudgeCurrentAppHigher(_:)), keyEquivalent: "")
                upItem.target = self
                upItem.representedObject = targetApp.bundleID
                nudgeMenu.addItem(upItem)

                let downItem = NSMenuItem(title: "Nudge Lower (-0.02 pt)", action: #selector(nudgeCurrentAppLower(_:)), keyEquivalent: "")
                downItem.target = self
                downItem.representedObject = targetApp.bundleID
                nudgeMenu.addItem(downItem)

                nudgeMenu.addItem(.separator())
                let openAppSettings = NSMenuItem(title: "All App Heights…", action: #selector(openSettingsClicked), keyEquivalent: "")
                openAppSettings.target = self
                nudgeMenu.addItem(openAppSettings)

                let heightItem = NSMenuItem(
                    title: String(format: "Height in %@: %+.2f pt", targetApp.name, curOffset),
                    action: nil,
                    keyEquivalent: ""
                )
                heightItem.submenu = nudgeMenu
                menu.addItem(heightItem)
            }
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsClicked),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "Quit WordTail",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func currentTargetApp() -> (name: String, bundleID: String)? {
        if let front = NSWorkspace.shared.frontmostApplication,
           let bundleID = front.bundleIdentifier,
           bundleID != Bundle.main.bundleIdentifier {
            return (front.localizedName ?? bundleID, bundleID)
        }
        return lastObservedApp
    }

    @objc private func requestPermissionsClicked() {
        attemptStartEngine(promptIfNeeded: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleEnabled() {
        engine.isEnabled.toggle()
        updateStatusIcon()
    }

    @objc private func toggleAppendSpace() {
        engine.appendSpaceOnAccept.toggle()
    }

    @objc private func toggleCurrentApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        inputGuard.toggleUserDisabled(bundleID: bundleID)
    }

    @objc private func nudgeCurrentAppHigher(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        let cur = engine.verticalAdjustment(forBundleID: bundleID)
        engine.setVerticalAdjustment(cur + 0.02, forBundleID: bundleID)
    }

    @objc private func nudgeCurrentAppLower(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        let cur = engine.verticalAdjustment(forBundleID: bundleID)
        engine.setVerticalAdjustment(cur - 0.02, forBundleID: bundleID)
    }

    @objc private func openSettingsClicked() {
        let target = currentTargetApp()
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                engine: engine,
                currentApp: target,
                onStateChange: { [weak self] in self?.updateStatusIcon() }
            )
        }
        settingsWindowController?.present(for: target)
    }

    @objc private func quitClicked() {
        engine.stop()
        NSApplication.shared.terminate(nil)
    }
}
