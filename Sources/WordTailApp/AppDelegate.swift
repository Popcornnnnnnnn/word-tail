import AppKit
import ApplicationServices
import CoreServices
import ServiceManagement
import WordTailCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let historyStore = UserHistoryStore()
    private let phrasePredictor = PhrasePredictor()
    private let keyStatsStore = KeyStatsStore()
    private lazy var habitTracker = TypingHabitTracker(validWordChecker: { [weak self] word in
        if self?.historyStore.isCustomWord(word) == true {
            return true
        }
        return TypingHabitTracker.defaultValidEnglishWordCheck(word)
    })
    private let inputGuard = InputGuard()
    private lazy var completer = WordCompleter(
        historyStore: historyStore,
        habitTracker: habitTracker,
        phrasePredictor: phrasePredictor
    )
    private lazy var engine = TypingEngine(
        completer: completer,
        historyStore: historyStore,
        habitTracker: habitTracker,
        phrasePredictor: phrasePredictor,
        keyStatsStore: keyStatsStore,
        inputGuard: inputGuard
    )
    private let autoUpdater = AutoUpdateManager()

    private var permissionPollTimer: Timer?
    private var menuBarCounterTimer: Timer?
    private var syncTimer: Timer?
    private var lastObservedApp: (name: String, bundleID: String)?
    private var settingsWindowController: SettingsWindowController?
    private var statusBarContextMenu: NSMenu?
    private var popoverController: MenuBarPopoverController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockVisibilityPreference()
        setupMainMenu()

        engine.onStateChanged = { [weak self] in
            self?.updateStatusIcon()
            self?.settingsWindowController?.refreshUpdateAndSyncStatus()
            self?.popoverController?.refreshIfShown()
        }
        autoUpdater.onBeforeTerminateForUpdate = { [weak self] in
            self?.engine.flushAllTelemetry()
        }
        autoUpdater.onUpdateStateChanged = { [weak self] in
            self?.settingsWindowController?.refreshUpdateAndSyncStatus()
            self?.popoverController?.refreshIfShown()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.engine.isTapActive {
                    self.attemptStartEngine(promptIfNeeded: false)
                }
                self.updateStatusIcon()
                self.settingsWindowController?.refreshUpdateAndSyncStatus()
            }
        }
        ensureLoginItemRegisteredOnFirstInstall()
        setupBackgroundSyncAndUpdates()

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
            let name = app.localizedName ?? bundleID
            MainActor.assumeIsolated {
                self?.lastObservedApp = (name, bundleID)
            }
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

    func applicationWillTerminate(_ notification: Notification) {
        engine.flushAllTelemetry()
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

        let checkUpdatesMainItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesClicked),
            keyEquivalent: ""
        )
        checkUpdatesMainItem.target = self
        appMenu.addItem(checkUpdatesMainItem)
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
        statusBarContextMenu = menu

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseUp])
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let trusted = AXIsProcessTrusted() && engine.isTapActive
        if !trusted {
            if let warn = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "WordTail Needs Permission") {
                warn.isTemplate = true
                button.image = warn
                button.title = ""
                button.appearsDisabled = false
                return
            }
        }
        button.image = Self.makeMenuBarIcon()
        button.imagePosition = engine.showMenuBarKeyCount ? .imageLeft : .imageOnly
        if engine.showMenuBarKeyCount {
            let counts = keyStatsStore.todayMenuBarCounts()
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            button.title = " " + KeyStatsAggregateSnapshot.formatCompactCount(counts.keys)
            ensureMenuBarCounterTimerRunning()
        } else {
            button.title = ""
            menuBarCounterTimer?.invalidate()
            menuBarCounterTimer = nil
        }
        button.appearsDisabled = !engine.isEnabled
    }

    private func ensureMenuBarCounterTimerRunning() {
        guard menuBarCounterTimer == nil else { return }
        menuBarCounterTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.engine.showMenuBarKeyCount, let button = self.statusItem.button else { return }
                let counts = self.keyStatsStore.todayMenuBarCounts()
                button.title = " " + KeyStatsAggregateSnapshot.formatCompactCount(counts.keys)
            }
        }
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
        if promptIfNeeded && !AXIsProcessTrusted() {
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
            settingsWindowController?.refreshUpdateAndSyncStatus()
        } else if permissionPollTimer == nil {
            permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if AXIsProcessTrusted() && self.engine.start() {
                        self.permissionPollTimer?.invalidate()
                        self.permissionPollTimer = nil
                        self.updateStatusIcon()
                        self.settingsWindowController?.refreshUpdateAndSyncStatus()
                    }
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

        if engine.enableKeyStatsTracking {
            let today = keyStatsStore.todayMenuBarCounts()
            let statsSummary = NSMenuItem(
                title: "Today: \(KeyStatsAggregateSnapshot.formatCompactCount(today.keys)) keys · \(KeyStatsAggregateSnapshot.formatCompactCount(today.clicks)) clicks",
                action: #selector(openKeyStatsClicked),
                keyEquivalent: ""
            )
            statsSummary.target = self
            menu.addItem(statsSummary)
        }

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

        if let release = autoUpdater.availableRelease {
            let installItem = NSMenuItem(
                title: "⬆ Update to v\(release.version) & Restart…",
                action: #selector(installAvailableUpdateClicked),
                keyEquivalent: ""
            )
            installItem.target = self
            menu.addItem(installItem)
        }

        let openKeyStatsItem = NSMenuItem(
            title: "KeyStats & Heatmap…",
            action: #selector(openKeyStatsClicked),
            keyEquivalent: ""
        )
        openKeyStatsItem.target = self
        menu.addItem(openKeyStatsItem)

        let openWindowItem = NSMenuItem(
            title: "Open WordTail Window…",
            action: #selector(openSettingsClicked),
            keyEquivalent: ","
        )
        openWindowItem.target = self
        menu.addItem(openWindowItem)

        let checkUpdatesStatusItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesClicked),
            keyEquivalent: ""
        )
        checkUpdatesStatusItem.target = self
        menu.addItem(checkUpdatesStatusItem)

        let quitItem = NSMenuItem(
            title: "Quit WordTail",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func setupBackgroundSyncAndUpdates() {
        autoUpdater.startLifecycle()

        if engine.syncEngine.statusSnapshot().isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.runBackgroundSyncPass()
            }
        }

        syncTimer = Timer.scheduledTimer(withTimeInterval: 45.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runBackgroundSyncPass()
            }
        }
    }

    private func runBackgroundSyncPass() {
        guard engine.syncEngine.statusSnapshot().isEnabled else { return }
        engine.syncEngine.syncAsync { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusIcon()
                self?.settingsWindowController?.refreshUpdateAndSyncStatus()
            }
        }
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

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isContextTrigger = (event?.type == .rightMouseUp)
            || (event?.modifierFlags.contains(.control) == true)

        if isContextTrigger, let menu = statusBarContextMenu {
            popoverController?.close()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
            return
        }

        ensurePopoverController().toggle(relativeTo: sender)
    }

    private func ensurePopoverController() -> MenuBarPopoverController {
        if let existing = popoverController {
            return existing
        }
        let controller = MenuBarPopoverController(
            engine: engine,
            inputGuard: inputGuard,
            autoUpdater: autoUpdater,
            activeAppProvider: { [weak self] in self?.currentTargetApp() },
            onToggleEnabled: { [weak self] in
                self?.toggleEnabled()
            },
            onGrantAccessibility: { [weak self] in
                self?.requestPermissionsClicked()
            },
            onToggleAppDisabled: { [weak self] bundleID in
                guard let self else { return }
                self.inputGuard.toggleUserDisabled(bundleID: bundleID)
                self.updateStatusIcon()
                self.popoverController?.refreshIfShown()
            },
            onAdjustAppBaseline: { [weak self] bundleID, delta in
                guard let self else { return }
                let current = self.engine.verticalAdjustment(forBundleID: bundleID)
                let next = ((current + delta) * 100.0).rounded() / 100.0
                let clamped = max(-2.0, min(2.0, next))
                self.engine.setVerticalAdjustment(clamped, forBundleID: bundleID)
                self.popoverController?.refreshIfShown()
            },
            onOpenSettingsSection: { [weak self] section, range in
                self?.presentMainWindow(section: section, keyStatsRange: range)
            },
            onCheckForUpdates: { [weak self] in
                self?.autoUpdater.checkForUpdates(userInitiated: true)
            },
            onInstallRelease: { [weak self] release in
                self?.autoUpdater.installReleaseNow(release)
            },
            onQuit: { [weak self] in
                self?.quitClicked()
            }
        )
        popoverController = controller
        return controller
    }

    @objc private func openSettingsClicked() {
        presentMainWindow(section: nil)
    }

    @objc private func openKeyStatsClicked() {
        presentMainWindow(section: .keyStats)
    }

    @objc private func checkForUpdatesClicked() {
        autoUpdater.checkForUpdates(userInitiated: true)
    }

    @objc private func installAvailableUpdateClicked() {
        autoUpdater.promptAndInstallCurrentRelease()
    }

    private func presentMainWindow(section: SettingsSection?, keyStatsRange: StatsTimeRange? = nil) {
        let target = currentTargetApp()
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                engine: engine,
                autoUpdater: autoUpdater,
                currentApp: target,
                onStateChange: { [weak self] in self?.updateStatusIcon() }
            )
        }
        settingsWindowController?.present(for: target, selectSection: section, keyStatsRange: keyStatsRange)
    }

    @objc private func quitClicked() {
        engine.flushAllTelemetry()
        engine.stop()
        NSApplication.shared.terminate(nil)
    }
}
