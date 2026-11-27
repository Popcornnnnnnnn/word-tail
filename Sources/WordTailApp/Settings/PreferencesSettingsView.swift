import SwiftUI

struct PreferencesSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Preferences")
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                LinearSectionHeader(title: "Alignment & Appearance")

                LinearCard {
                    HStack(spacing: 0) {
                        Text("PREVIEW")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, 12)

                        Text("I major in computer science and I kn")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.primary)

                        Rectangle()
                            .fill(LinearUI.accent)
                            .frame(width: 1.5, height: 15)

                        Text(vm.appendSpaceOnAccept ? "ow␣" : "ow")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Color.primary.opacity(vm.ghostOpacity))

                        Spacer()

                        LinearKbd(label: "⇥ Tab")
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack(spacing: 10) {
                        let isAlignedReady = vm.hasScreenCapturePermission && vm.visualLockError == nil
                        Image(systemName: "viewfinder")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isAlignedReady ? LinearUI.accent : LinearUI.warning)
                            .frame(width: 24, height: 24)
                            .background(
                                (isAlignedReady ? LinearUI.accent : LinearUI.warning).opacity(scheme == .dark ? 0.16 : 0.11),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Automatic Sub-Pixel Baseline Lock")
                                .font(.system(size: 13, weight: .medium))
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(isAlignedReady ? LinearUI.positive : LinearUI.warning)
                                    .frame(width: 5.5, height: 5.5)
                                Text(vm.visualLockStatusText)
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }

                        Spacer()

                        if !vm.hasScreenCapturePermission {
                            LinearActionButton(title: "Grant Access…", icon: "lock.open") {
                                vm.requestScreenCapturePermissionAndOpenSettings()
                            }
                        } else if vm.visualLockLockedLines > 0 {
                            LinearIconButton(
                                symbol: "arrow.counterclockwise",
                                helpText: "Clear learned per-app visual priors and line cache"
                            ) {
                                vm.resetVisualBaselineCalibration()
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack(spacing: 12) {
                        Text("Ghost Text Opacity")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        LinearSlider(value: $vm.ghostOpacity, range: 0.18...0.68, showZeroTick: false, step: 0.01)
                            .frame(width: 150)
                        Text("\(Int((vm.ghostOpacity * 100).rounded()))%")
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                        LinearIconButton(symbol: "arrow.counterclockwise", helpText: "Reset opacity (38%)") {
                            vm.resetOpacity()
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LinearSectionHeader(title: "Multi-Device Sync & Updates")

                LinearCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Multi-Device Sync")
                                    .font(.system(size: 13, weight: .medium))
                                Text(vm.syncSubtitleText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(vm.syncStatus.lastError == nil ? Color.secondary : Color.orange)
                                    .lineLimit(1)
                            }
                            Spacer()
                            LinearSwitch(isOn: $vm.syncEnabled)
                        }

                        HStack(spacing: 6) {
                            if vm.hasICloudDriveAvailable {
                                LinearActionButton(
                                    title: vm.syncStatus.isICloudDrive && vm.syncEnabled ? "Using iCloud Drive" : "Use iCloud Drive",
                                    icon: "icloud"
                                ) {
                                    vm.useICloudDriveSync()
                                }
                            }
                            LinearActionButton(title: "Choose Folder…", icon: "folder") {
                                vm.chooseCustomSyncFolder()
                            }
                            if vm.syncEnabled {
                                LinearActionButton(
                                    title: vm.isSyncingNow ? "Syncing…" : "Sync Now",
                                    icon: "arrow.triangle.2.circlepath"
                                ) {
                                    vm.syncNowClicked()
                                }
                                if vm.syncStatus.folderPath != nil {
                                    LinearIconButton(symbol: "arrow.up.forward.app", helpText: "Show sync folder in Finder") {
                                        vm.revealSyncFolderInFinder()
                                    }
                                }
                            }
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Automatic Update Checks")
                                .font(.system(size: 13, weight: .medium))
                            Text(vm.updateStatusText.isEmpty ? "Checks GitHub Releases and prompts before restarting" : vm.updateStatusText)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if vm.availableRelease != nil {
                            LinearActionButton(
                                title: vm.isInstallingUpdate ? "Updating…" : "Review Update…",
                                icon: "arrow.down.circle"
                            ) {
                                vm.reviewAvailableUpdateClicked()
                            }
                        } else {
                            LinearActionButton(
                                title: vm.isCheckingUpdates ? "Checking…" : "Check Now",
                                icon: "arrow.clockwise"
                            ) {
                                vm.checkForUpdatesClicked()
                            }
                        }
                        LinearSwitch(isOn: $vm.autoCheckUpdates)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LinearSectionHeader(title: "Typing & Acceptance")

                LinearCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Insert Space After Tab")
                                .font(.system(size: 13, weight: .medium))
                            Text("Appends a trailing space on Tab (skips automatically before punctuation)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.appendSpaceOnAccept)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Auto-Correct Typos & Contractions")
                                .font(.system(size: 13, weight: .medium))
                            Text("Fixes obvious typos & patterns (im → I'm, teh → the) on Tab/Space; ⌫ undoes & learns")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.autoCorrectOnSpace)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Auto-Capitalize Sentences")
                                .font(.system(size: 13, weight: .medium))
                            Text("Capitalizes sentence starts and standalone “I” on Space (skips CLI commands)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.autoCapitalizeSentences)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Conservative Phrase Prediction")
                                .font(.system(size: 13, weight: .medium))
                            Text("Suggests fixed idioms (as far → as I'm concerned) & 3× repeated personal phrases")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.enablePhrasePrediction)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Learn Word Habits & Insights")
                                .font(.system(size: 13, weight: .medium))
                            Text("Learns 2-word pairs, per-app vocabulary, typo traps, and local speed stats")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.enableHabitLearning)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Minimum Typed Letters")
                                .font(.system(size: 13, weight: .medium))
                            Text("Characters required before showing a completion")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSegmentedChoices(
                            options: [("2", 2), ("3", 3), ("4", 4)],
                            selection: $vm.minPrefix
                        )
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Minimum Remaining Suffix")
                                .font(.system(size: 13, weight: .medium))
                            Text("Skip trivial 1-character endings when set to 2+")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSegmentedChoices(
                            options: [("1", 1), ("2", 2), ("3", 3)],
                            selection: $vm.minSuffix
                        )
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LinearSectionHeader(title: "Shortcuts & Menu Bar")

                LinearCard {
                    HStack {
                        Text("Accept 1 Word of Multi-Word Phrase")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        LinearKbd(label: "⌥ →")
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        Text("Cycle Alternative Word Candidates")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            LinearKbd(label: "⌥ [")
                            LinearKbd(label: "⌥ ]")
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        HStack(spacing: 8) {
                            Text("Global Pause / Resume Shortcut")
                                .font(.system(size: 13, weight: .medium))
                            LinearKbd(label: "⌃ ⌥ W")
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.enableGlobalHotkey)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Show Today’s Keystrokes in Menu Bar")
                                .font(.system(size: 13, weight: .medium))
                            Text("Displays a compact live counter (e.g. 4.2k) beside the menu bar icon")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.showMenuBarKeyCount)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Show Today’s Clicks in Menu Bar")
                                .font(.system(size: 13, weight: .medium))
                            Text("Shows a compact click total (e.g. 4.2k · 910) beside the icon")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.showMenuBarClickCount)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Dynamic Activity Color")
                                .font(.system(size: 13, weight: .medium))
                            Text("Colors the menu bar icon or status dot by live APM (80 / 160 / 240+)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.enableDynamicMenuBarColor)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)

                    if vm.enableDynamicMenuBarColor {
                        Rectangle()
                            .fill(LinearUI.hairline(scheme))
                            .frame(height: 1)
                            .padding(.leading, 14)

                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Indicator Style & Window")
                                    .font(.system(size: 12.5, weight: .medium))
                                Text("Green 80+ · Orange 160+ · Red 240+ APM")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            LinearSegmentedChoices(
                                options: [
                                    (label: "Status Dot", value: "dot"),
                                    (label: "Tint Icon", value: "icon")
                                ],
                                selection: $vm.dynamicMenuBarColorStyle
                            )
                            LinearSegmentedChoices(
                                options: [
                                    (label: "15s", value: 15),
                                    (label: "30s", value: 30),
                                    (label: "60s", value: 60)
                                ],
                                selection: $vm.dynamicMenuBarWindowSeconds
                            )
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LinearSectionHeader(title: "System")

                LinearCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Enable KeyStats Hardware Telemetry")
                                .font(.system(size: 13, weight: .medium))
                            Text("Counts keys, clicks, mouse & scroll distance, and per-app totals locally")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.enableKeyStatsTracking)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Mouse Distance Calibration")
                                .font(.system(size: 13, weight: .medium))
                            Text("Adjusts physical meter scale using a measured 10 cm drag · Current: \(String(format: "%.2f×", vm.mouseCalibrationFactor))")
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if abs(vm.mouseCalibrationFactor - 1.0) > 0.01 {
                            LinearActionButton(title: "Reset", icon: "arrow.counterclockwise") {
                                vm.resetMouseCalibrationFactor()
                            }
                        }
                        LinearActionButton(title: "Calibrate 10 cm…", icon: "ruler") {
                            vm.showingMouseCalibrationSheet = true
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Daily Milestone Notifications")
                                .font(.system(size: 13, weight: .medium))
                            Text("Notifies once per day when you reach your keystroke or click goal")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.enableMilestoneNotifications)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)

                    if vm.enableMilestoneNotifications {
                        Rectangle()
                            .fill(LinearUI.hairline(scheme))
                            .frame(height: 1)
                            .padding(.leading, 14)

                        HStack {
                            Text("Keystroke Goal")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            LinearSegmentedChoices(
                                options: [
                                    (label: "5k", value: 5_000),
                                    (label: "10k", value: 10_000),
                                    (label: "25k", value: 25_000),
                                    (label: "50k", value: 50_000)
                                ],
                                selection: $vm.milestoneKeyThreshold
                            )
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 44)

                        Rectangle()
                            .fill(LinearUI.hairline(scheme))
                            .frame(height: 1)
                            .padding(.leading, 14)

                        HStack {
                            Text("Click Goal")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            LinearSegmentedChoices(
                                options: [
                                    (label: "1k", value: 1_000),
                                    (label: "2k", value: 2_000),
                                    (label: "5k", value: 5_000)
                                ],
                                selection: $vm.milestoneClickThreshold
                            )
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                    }

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Show Icon in Dock & App Switcher")
                                .font(.system(size: 13, weight: .medium))
                            Text("Turn off if you prefer running in the top menu bar only")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.showDockIcon)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Launch at Login")
                                .font(.system(size: 13, weight: .medium))
                            Text("Start WordTail automatically when you sign in to macOS")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.launchAtLogin)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Browser & Electron Bridge")
                                .font(.system(size: 13, weight: .medium))
                            Text("Wakes accessibility trees in Chrome, Codex, and Antigravity")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.chromiumBridge)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                }
            }
        }
    }
}
