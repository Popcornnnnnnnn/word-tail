import SwiftUI

struct PreferencesSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Preferences")
                .font(.system(size: 16, weight: .semibold))

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
                LinearSectionHeader(title: "Appearance & Shortcuts")

                LinearCard {
                    HStack(spacing: 12) {
                        Text("Ghost Text Opacity")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        LinearSlider(value: $vm.ghostOpacity, range: 0.18...0.68, showZeroTick: false)
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

                    Rectangle()
                        .fill(LinearUI.hairline(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)

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
