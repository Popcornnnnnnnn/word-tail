import AppKit
import ApplicationServices
import CoreServices
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
        applyDockVisibilityPreference()
        setupMainMenu()

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

        // Open main window on interactive launch (or when --open-settings is passed),
        // unless launched silently at login or with --background.
        let silentLaunch = CommandLine.arguments.contains("--background")
            || (wasLaunchedAsLoginItem() && !CommandLine.arguments.contains("--open-settings"))
        if !silentLaunch {
            DispatchQueue.main.async { [weak self] in
                self?.openSettingsClicked()
            }
        }
    }

    private func wasLaunchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else {
            return false
        }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Standard macOS behavior: clicking the Dock icon or launching WordTail from Spotlight/Finder
    /// when no window is visible re-opens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsClicked()
        return true
    }

    /// Standard macOS background-capable app behavior: closing the window (⌘W / red button)
    /// keeps WordTail's autocomplete engine running until the user quits (⌘Q).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func applyDockVisibilityPreference() {
        let showDock: Bool
        if UserDefaults.standard.object(forKey: "WordTailShowDockIcon") == nil {
            showDock = true
        } else {
            showDock = UserDefaults.standard.bool(forKey: "WordTailShowDockIcon")
        }
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 1. Application Menu ("WordTail")
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let aboutItem = NSMenuItem(
            title: "About WordTail",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let prefsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsClicked),
            keyEquivalent: ","
        )
        prefsItem.target = self
        appMenu.addItem(prefsItem)
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())

        appMenu.addItem(NSMenuItem(
            title: "Hide WordTail",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit WordTail",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)

        // 2. Edit Menu (enables standard ⌘Z, ⌘X, ⌘C, ⌘V, ⌘A in text fields)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        // 3. Window Menu (enables standard ⌘W, ⌘M, Zoom, Bring All to Front)
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu

        windowMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func ensureLoginItemRegisteredOnFirstInstall() {
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
                let upItem = NSMenuItem(title: "Nudge Higher (+0.10 pt)", action: #selector(nudgeCurrentAppHigher(_:)), keyEquivalent: "")
                upItem.target = self
                upItem.representedObject = targetApp.bundleID
                nudgeMenu.addItem(upItem)

                let downItem = NSMenuItem(title: "Nudge Lower (-0.10 pt)", action: #selector(nudgeCurrentAppLower(_:)), keyEquivalent: "")
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

        let openWindowItem = NSMenuItem(
            title: "Open WordTail Window…",
            action: #selector(openSettingsClicked),
            keyEquivalent: ","
        )
        openWindowItem.target = self
        menu.addItem(openWindowItem)

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
        engine.setVerticalAdjustment(cur + 0.10, forBundleID: bundleID)
    }

    @objc private func nudgeCurrentAppLower(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        let cur = engine.verticalAdjustment(forBundleID: bundleID)
        engine.setVerticalAdjustment(cur - 0.10, forBundleID: bundleID)
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
