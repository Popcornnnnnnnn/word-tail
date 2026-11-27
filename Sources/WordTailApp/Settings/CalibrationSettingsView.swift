import SwiftUI
import WordTailCore

struct CalibrationSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: SettingsViewModel
    @State private var showAddAppPopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Baseline Calibration")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("Leave a ghost word visible in an app to move it live")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

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
                            .offset(y: CGFloat(-(vm.globalOffset - 0.70)))

                        Spacer()

                        LinearKbd(label: "⇥ Tab")
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LinearSectionHeader(
                    title: "Global Default",
                    subtitle: "Used for apps without a custom override below."
                )

                LinearCard {
                    HStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(LinearUI.subtleFill(scheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                        Text("All Other Apps")
                            .font(.system(size: 13, weight: .medium))

                        Spacer()

                        LinearSlider(value: $vm.globalOffset, range: VerticalOffsetStore.sliderRange)
                            .frame(width: 118)

                        LinearOffsetStepper(
                            value: vm.globalOffset,
                            onChange: { vm.setGlobalOffsetClamped($0) }
                        )

                        LinearIconButton(
                            symbol: "arrow.counterclockwise",
                            helpText: "Reset Global Default (+0.70 pt)"
                        ) {
                            vm.resetGlobalOffset()
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 46)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    LinearSectionHeader(
                        title: "Application Overrides",
                        subtitle: "Independent vertical baseline per app. ⌥-click −/+ for 0.50 pt steps."
                    )
                    Spacer()

                    HStack(spacing: 6) {
                        if !vm.availableAppsToAdd.isEmpty {
                            if vm.isStaticShowcase {
                                LinearActionButton(title: "Add Open App", icon: "plus") {}
                            } else {
                                LinearActionButton(title: "Add Open App", icon: "plus") {
                                    showAddAppPopover.toggle()
                                }
                                .popover(isPresented: $showAddAppPopover, arrowEdge: .bottom) {
                                    ScrollView(.vertical, showsIndicators: true) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            ForEach(vm.availableAppsToAdd) { app in
                                                LinearPopoverMenuItem(
                                                    title: app.name,
                                                    nsImage: app.icon
                                                ) {
                                                    vm.addAppOverride(bundleID: app.bundleID)
                                                    showAddAppPopover = false
                                                }
                                            }
                                        }
                                        .padding(6)
                                    }
                                    .frame(minWidth: 205, maxHeight: 320)
                                }
                            }
                        }

                        LinearActionButton(title: "Browse…", icon: "folder") {
                            vm.chooseApplicationFromDisk()
                        }
                    }
                }

                LinearCard {
                    if vm.connectedDisplays.count > 1 || vm.selectedDisplayKey != nil {
                        HStack(spacing: 8) {
                            Text("Display")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            LinearSegmentedChoices(
                                options: [(label: "All Displays", value: Optional<String>.none)]
                                    + vm.connectedDisplays.map { (label: $0.name, value: Optional($0.key)) },
                                selection: $vm.selectedDisplayKey
                            )
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                        Rectangle()
                            .fill(LinearUI.hairline(scheme))
                            .frame(height: 1)
                    }

                    ForEach(Array(vm.appOffsets.enumerated()), id: \.element.id) { idx, item in
                        if idx > 0 {
                            Rectangle()
                                .fill(LinearUI.hairline(scheme))
                                .frame(height: 1)
                                .padding(.leading, 46)
                        }

                        HStack(spacing: 10) {
                            Image(nsImage: item.icon)
                                .resizable()
                                .frame(width: 24, height: 24)

                            Text(item.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)

                            if vm.selectedDisplayKey != nil {
                                Text(item.isDisplaySpecificOverride ? "Display" : "Inherited")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(item.isDisplaySpecificOverride ? LinearUI.accent : .secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(LinearUI.subtleFill(scheme), in: Capsule())
                            } else if item.hasPerDisplayOverrides {
                                Text("Per-display")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(LinearUI.subtleFill(scheme), in: Capsule())
                            }

                            Spacer()

                            LinearSlider(
                                value: Binding(
                                    get: { item.offset },
                                    set: { vm.updateOffset(for: item.bundleID, to: $0) }
                                ),
                                range: VerticalOffsetStore.sliderRange
                            )
                            .frame(width: 118)

                            LinearOffsetStepper(
                                value: item.offset,
                                onChange: { vm.updateOffset(for: item.bundleID, to: $0) }
                            )

                            if vm.selectedDisplayKey != nil {
                                LinearIconButton(
                                    symbol: "arrow.counterclockwise",
                                    helpText: item.isDisplaySpecificOverride ? "Reset to All Displays" : "Inherits All Displays"
                                ) {
                                    vm.removeOrResetApp(bundleID: item.bundleID)
                                }
                                .disabled(!item.isDisplaySpecificOverride)
                                .opacity(item.isDisplaySpecificOverride ? 1.0 : 0.35)
                            } else {
                                let isBuiltIn = ScreenGeometry.builtInAppVerticalOffsets[item.bundleID] != nil
                                LinearIconButton(
                                    symbol: isBuiltIn ? "arrow.counterclockwise" : "xmark",
                                    helpText: isBuiltIn ? "Reset default" : "Remove override"
                                ) {
                                    vm.removeOrResetApp(bundleID: item.bundleID)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 46)
                    }
                }
            }
        }
    }
}
