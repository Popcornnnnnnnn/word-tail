import AppKit
import SwiftUI
import WordTailCore

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
        .frame(
            minWidth: vm.isStaticShowcase ? 940 : 780,
            idealWidth: 940,
            maxWidth: vm.isStaticShowcase ? 940 : .infinity,
            minHeight: vm.isStaticShowcase ? 650 : 560,
            idealHeight: 650,
            maxHeight: vm.isStaticShowcase ? 650 : .infinity
        )
        .background(LinearUI.windowBg(scheme))
        .sheet(isPresented: $vm.showingMouseCalibrationSheet) {
            MouseCalibrationSheet(vm: vm)
        }
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
                            .fill(vm.isTrusted ? (vm.isEnabled ? LinearUI.positive : Color.secondary) : LinearUI.warning)
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
                        if section == .calibration {
                            vm.refreshCalibrationOffsets()
                        } else if section == .insights {
                            vm.refreshInsights()
                        } else if section == .keyStats || section == .appStats {
                            vm.refreshKeyStats()
                        } else if section == .pro {
                            vm.refreshProUI()
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
                    .background(LinearUI.warning, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
            if let release = vm.availableRelease {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LinearUI.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("WordTail v\(release.version) is available")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(vm.isInstallingUpdate ? "Downloading, verifying signature & restarting…" : "Signed update ready to download and restart automatically.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        vm.reviewAvailableUpdateClicked()
                    } label: {
                        Text(vm.isInstallingUpdate ? "Updating…" : "Review Update…")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .frame(height: 26)
                            .background(LinearUI.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isInstallingUpdate)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(LinearUI.accent.opacity(scheme == .dark ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LinearUI.accent.opacity(0.32), lineWidth: 1)
                )
            }

            switch vm.selectedSection {
            case .calibration:
                CalibrationSettingsView(vm: vm)
            case .keyStats:
                KeyStatsSettingsView(vm: vm)
            case .appStats:
                AppStatsSettingsView(vm: vm)
            case .insights:
                InsightsSettingsView(vm: vm)
            case .dictionary:
                DictionarySettingsView(vm: vm)
            case .preferences:
                PreferencesSettingsView(vm: vm)
            case .pro:
                ProSettingsView(
                    state: $vm.proUI,
                    callbacks: vm.proCallbacks,
                    isStaticShowcase: vm.isStaticShowcase
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, vm.selectedSection == .appStats ? 12 : 24)

        if vm.isStaticShowcase {
            Color.clear
                .overlay(alignment: .topLeading) {
                    content
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else if vm.selectedSection == .appStats {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollEdgeFadeContainer(showsIndicators: false, topFadeHeight: 12, bottomFadeHeight: 20) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private var viewModel: SettingsViewModel!

    init(
        engine: TypingEngine,
        autoUpdater: AutoUpdateManager,
        currentApp: (name: String, bundleID: String)?,
        onStateChange: @escaping () -> Void
    ) {
        super.init(window: nil)
        self.viewModel = SettingsViewModel(
            engine: engine,
            autoUpdater: autoUpdater,
            currentApp: currentApp,
            onStateChange: onStateChange
        )
        let hostingController = NSHostingController(rootView: SettingsView(vm: viewModel))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "WordTail"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 940, height: 650))
        window.minSize = NSSize(width: 780, height: 560)
        window.level = .normal
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.viewModel.refreshUpdateAndSyncStatus()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(
        for currentApp: (name: String, bundleID: String)?,
        selectSection: SettingsSection? = nil,
        keyStatsRange: StatsTimeRange? = nil,
        selectDisplayKey: String? = nil
    ) {
        if let selectDisplayKey {
            viewModel.selectedDisplayKey = selectDisplayKey
        }
        viewModel.refresh(currentApp: currentApp)
        if let selectSection {
            viewModel.selectedSection = selectSection
        }
        if let keyStatsRange, viewModel.keyStatsRange != keyStatsRange {
            viewModel.keyStatsRange = keyStatsRange
        }
        showWindow(nil)
        window?.level = .normal
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshUpdateAndSyncStatus() {
        viewModel.refreshUpdateAndSyncStatus()
    }

    func refreshCalibrationOffsets() {
        viewModel.refreshCalibrationOffsets()
    }
}
