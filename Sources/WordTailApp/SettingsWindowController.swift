import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(LinearUI.hairline(scheme))
                .frame(width: 1)
            detailPane
        }
        .frame(width: 740, height: 548)
        .background(LinearUI.windowBg(scheme))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 38)

            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text("WordTail")
                        .font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 4) {
                        Circle()
                            .fill(vm.isTrusted ? (vm.isEnabled ? Color.green : Color.secondary) : Color.orange)
                            .frame(width: 5.5, height: 5.5)
                        Text(!vm.isTrusted ? "Needs Access" : (vm.isEnabled ? "Active" : "Paused"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)

            VStack(spacing: 3) {
                ForEach(SettingsSection.allCases) { section in
                    SidebarRow(
                        title: section.rawValue,
                        symbol: section.symbol,
                        isSelected: vm.selectedSection == section
                    ) {
                        if section == .insights {
                            vm.refreshInsights()
                        } else if section == .keyStats {
                            vm.refreshKeyStats()
                        }
                        vm.selectedSection = section
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            if !vm.isTrusted {
                Button {
                    vm.openAccessibilitySettings()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Grant Access")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 27)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            Rectangle()
                .fill(LinearUI.hairline(scheme))
                .frame(height: 1)

            HStack {
                Text("Enabled")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                LinearSwitch(isOn: $vm.isEnabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 172)
        .background(LinearUI.sidebarBg(scheme))
    }

    @ViewBuilder
    private var detailPane: some View {
        let content = VStack(alignment: .leading, spacing: 20) {
            switch vm.selectedSection {
            case .calibration:
                CalibrationSettingsView(vm: vm)
            case .keyStats:
                KeyStatsSettingsView(vm: vm)
            case .insights:
                InsightsSettingsView(vm: vm)
            case .dictionary:
                DictionarySettingsView(vm: vm)
            case .preferences:
                PreferencesSettingsView(vm: vm)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 24)

        if vm.isStaticShowcase {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

final class SettingsWindowController: NSWindowController {
    private var viewModel: SettingsViewModel!

    init(
        engine: TypingEngine,
        currentApp: (name: String, bundleID: String)?,
        onStateChange: @escaping () -> Void
    ) {
        super.init(window: nil)
        self.viewModel = SettingsViewModel(
            engine: engine,
            currentApp: currentApp,
            onStateChange: onStateChange
        )
        let hostingController = NSHostingController(rootView: SettingsView(vm: viewModel))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "WordTail"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.level = .normal
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(for currentApp: (name: String, bundleID: String)?, selectSection: SettingsSection? = nil) {
        viewModel.refresh(currentApp: currentApp)
        if let selectSection {
            viewModel.selectedSection = selectSection
        }
        showWindow(nil)
        window?.level = .normal
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
