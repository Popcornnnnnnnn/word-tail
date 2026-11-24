import SwiftUI
import WordTailCore

struct ProDomainPackItem: Identifiable, Equatable {
    let id: String
    let name: String
    let tagline: String
    let wordCount: Int
    var isEnabled: Bool
    let isCustom: Bool
}

struct ProSnippetItem: Identifiable, Equatable {
    let id: String
    let trigger: String
    let title: String
    let previewBody: String
    let appScopeLabel: String
    var isEnabled: Bool
    let isBuiltIn: Bool
}

struct ProAppProfileItem: Identifiable, Equatable {
    let id: String
    let bundleID: String
    let displayName: String
    let presetTitle: String
    let summary: String
}

struct WordTailProUIState {
    var entitlementState: ProEntitlementState
    var hasUsedTrial: Bool
    var statusMessage: String?
    var isErrorStatus: Bool
    var licenseKeyDraft: String
    var packs: [ProDomainPackItem]
    var snippets: [ProSnippetItem]
    var newSnippetTrigger: String
    var newSnippetTitle: String
    var newSnippetBody: String
    var profiles: [ProAppProfileItem]
    var bilingualCompletionEnabled: Bool
    var bilingualSpacingEnabled: Bool
    var activeProfileTargetName: String? = nil
    var wrappedSummary: TypingWrappedSummary
    var posterAspect: WrappedPosterAspect
    var posterColorScheme: ColorScheme
}

enum ProWritingPreset: String, CaseIterable, Identifiable {
    case coding = "Coding"
    case prose = "Prose"
    case bilingual = "Bilingual"

    var id: Self { self }
}

struct ProSettingsCallbacks {
    var activateLicense: (String) -> Void
    var startTrial: () -> Void
    var deactivateLicense: () -> Void
    var setPackEnabled: (String, Bool) -> Void
    var importPack: () -> Void
    var exportPacks: () -> Void
    var exportCustomPack: (String) -> Void
    var addSnippet: (_ trigger: String, _ title: String, _ body: String) -> Void
    var setSnippetEnabled: (String, Bool) -> Void
    var deleteSnippet: (String) -> Void
    var applyProfilePreset: (ProWritingPreset) -> Void
    var deleteProfile: (String) -> Void
    var exportPoster: (WrappedPosterAspect, ColorScheme) -> Void
    var exportCSV: () -> Void
    var exportMarkdown: () -> Void
}

struct ProSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var state: WordTailProUIState
    let callbacks: ProSettingsCallbacks
    var isStaticShowcase: Bool = false

    private let checkoutPlaceholder = URL(string: "https://popcornnn.xyz")!
    private let macros = ["{date}", "{time}", "{iso}", "{clipboard}", "{cursor}"]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("WordTail Pro")
                .font(.system(size: 16, weight: .semibold))

            licenseSection
            packSection.disabled(!isProUnlocked)
            snippetSection.disabled(!isProUnlocked)
            profileSection.disabled(!isProUnlocked)
            reportsSection
        }
    }

    private var isProUnlocked: Bool {
        switch state.entitlementState {
        case .free: false
        case .trial, .licensed: true
        }
    }

    private var entitlementBadge: (label: String, color: Color) {
        switch state.entitlementState {
        case .free: ("MIT Core Free Forever", LinearUI.positive)
        case .trial(let days, _): ("14-Day Trial Active · \(days) \(days == 1 ? "day" : "days") left", LinearUI.accent)
        case .licensed: ("Pro Licensed", LinearUI.positive)
        }
    }

    private var licenseSection: some View {
        section(
            "WordTail Pro Collector License & 14-Day Free Trial",
            subtitle: "Try all Pro features locally for 14 days. No card required."
        ) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Text(entitlementBadge.label)
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(entitlementBadge.color.opacity(0.14), in: Capsule())
                        .overlay { Capsule().strokeBorder(entitlementBadge.color.opacity(0.35)) }
                    Spacer(minLength: 8)
                    if let status = state.statusMessage {
                        Text(status)
                            .font(.system(size: 11.5))
                            .foregroundStyle(state.isErrorStatus ? LinearUI.warning : Color.secondary)
                            .lineLimit(1)
                    }
                }

                if case .licensed(let license) = state.entitlementState {
                    HStack {
                        Text(license.email)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        LinearActionButton(title: "Deactivate", icon: nil, action: callbacks.deactivateLicense)
                    }
                } else {
                    HStack(spacing: 8) {
                        linearInputField(
                            "WTPRO-…",
                            text: $state.licenseKeyDraft,
                            monospaced: true,
                            accessibilityLabel: "License key",
                            onSubmit: activateLicense
                        )
                        LinearActionButton(title: "Activate", icon: "key", action: activateLicense)
                            .disabled(state.licenseKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if case .free = state.entitlementState {
                        if state.hasUsedTrial {
                            Text("Your free trial has already been used.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        } else {
                            LinearActionButton(
                                title: "Start 14-Day Free Trial", icon: "clock", action: callbacks.startTrial
                            )
                        }
                    }

                    HStack(spacing: 14) {
                        externalLinkButton("Get Pro Key (Creem · International / Alipay)", url: checkoutPlaceholder)
                        externalLinkButton("获取 Pro 激活码（面包多）", url: checkoutPlaceholder)
                    }
                    .font(.system(size: 11.5))
                }
            }
            .padding(10)
        }
    }

    private var packSection: some View {
        section("Domain Vocabulary Packs", subtitle: "Six built-in packs plus custom .wordtailpack files.") {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 6
            ) {
                ForEach(state.packs) { pack in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(pack.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .lineLimit(1)
                                Text("\(pack.wordCount.formatted()) words")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                if pack.isCustom { LinearKbd(label: "Custom") }
                            }
                            Text(pack.tagline)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if pack.isCustom {
                            LinearIconButton(symbol: "tray.and.arrow.up", helpText: "Export \(pack.name)") {
                                callbacks.exportCustomPack(pack.id)
                            }
                        }
                        LinearSwitch(isOn: Binding(
                            get: { state.packs.first { $0.id == pack.id }?.isEnabled ?? pack.isEnabled },
                            set: { callbacks.setPackEnabled(pack.id, $0) }
                        ))
                        .disabled(pack.isCustom)
                        .help(pack.isCustom ? "Imported custom packs remain active while Pro is unlocked" : "Enable \(pack.name)")
                        .accessibilityLabel(pack.name)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(LinearUI.subtleFill(scheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(LinearUI.hairline(scheme))
                    }
                }
            }
            .padding(10)

            rowDivider
            HStack(spacing: 8) {
                LinearActionButton(title: "Import .wordtailpack", icon: "tray.and.arrow.down", action: callbacks.importPack)
                LinearActionButton(title: "Export", icon: "tray.and.arrow.up", action: callbacks.exportPacks)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var snippetSection: some View {
        section("Snippet Studio & Macros") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    linearInputField(
                        "Trigger (e.g. ;sig)",
                        text: $state.newSnippetTrigger,
                        monospaced: true
                    )
                    .frame(width: 148)
                    linearInputField("Title", text: $state.newSnippetTitle)
                }
                linearInputField(
                    "Body with {date} and {cursor}",
                    text: $state.newSnippetBody,
                    multiline: true
                )
                HStack(spacing: 5) {
                    ForEach(macros, id: \.self) { LinearKbd(label: $0) }
                    Spacer()
                    LinearActionButton(title: "Add Snippet", icon: "plus") {
                        callbacks.addSnippet(state.newSnippetTrigger, state.newSnippetTitle, state.newSnippetBody)
                    }
                    .disabled(state.newSnippetTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || state.newSnippetTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || state.newSnippetBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .font(.system(size: 12.5))
            .padding(10)

            ForEach(state.snippets) { snippet in
                rowDivider
                HStack(spacing: 8) {
                    LinearKbd(label: snippet.trigger)
                    rowLabel(snippet.title, subtitle: snippet.previewBody)
                        .lineLimit(1)
                    Spacer()
                    LinearKbd(label: snippet.appScopeLabel)
                    LinearSwitch(isOn: Binding(
                        get: { state.snippets.first { $0.id == snippet.id }?.isEnabled ?? snippet.isEnabled },
                        set: { callbacks.setSnippetEnabled(snippet.id, $0) }
                    ))
                    .accessibilityLabel(snippet.title)
                    if snippet.isBuiltIn {
                        LinearKbd(label: "Built-in")
                    } else {
                        LinearIconButton(symbol: "trash", helpText: "Delete \(snippet.title)") {
                            callbacks.deleteSnippet(snippet.id)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
    }

    private var profileSection: some View {
        section("Per-App Writing Profiles & Bilingual CJK–English") {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.activeProfileTargetName.map { "Target app: \($0)" } ?? "Switch to an external app first so WordTail detects which app to configure.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(ProWritingPreset.allCases) { preset in
                        LinearActionButton(title: preset.rawValue, icon: nil) {
                            callbacks.applyProfilePreset(preset)
                        }
                        .disabled(state.activeProfileTargetName == nil)
                        .help(state.activeProfileTargetName.map { "Apply the \(preset.rawValue) writing preset to \($0)" } ?? "Detect a target app first")
                    }
                    Spacer()
                }
            }
            .padding(14)

            ForEach(state.profiles) { profile in
                rowDivider
                HStack(spacing: 8) {
                    rowLabel(profile.displayName, subtitle: profile.summary)
                        .help(profile.bundleID)
                    Spacer()
                    LinearKbd(label: profile.presetTitle)
                    LinearIconButton(symbol: "xmark", helpText: "Use global settings for \(profile.displayName)") {
                        callbacks.deleteProfile(profile.bundleID)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }

            rowDivider
            switchRow(
                "Bilingual CJK Boundaries",
                subtitle: "Allow English suggestions next to CJK text.",
                isOn: $state.bilingualCompletionEnabled
            )
            rowDivider
            switchRow(
                "PanGu Smart Spacing",
                subtitle: "Add spaces between CJK text and English on acceptance.",
                isOn: $state.bilingualSpacingEnabled
            )
        }
    }

    private var reportsSection: some View {
        section("Typing Wrapped & Analytics Exports") {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        aspectPicker
                        themePicker
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        aspectPicker
                        themePicker
                    }
                }

                posterPreview

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        posterButtons
                        reportButtons
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        posterButtons
                        reportButtons
                    }
                }
                .disabled(!isProUnlocked)
            }
            .padding(14)
        }
    }

    private var aspectPicker: some View {
        LinearSegmentedChoices(
            options: WrappedPosterAspect.allCases.map { ($0.rawValue, $0) },
            selection: $state.posterAspect
        )
        .accessibilityLabel("Poster aspect ratio")
    }

    private var themePicker: some View {
        LinearSegmentedChoices(options: [("Light", .light), ("Dark", .dark)], selection: $state.posterColorScheme)
            .accessibilityLabel("Poster appearance")
    }

    private var posterPreview: some View {
        let size = state.posterAspect.pointSize
        return GeometryReader { geometry in
            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
            WrappedPosterView(summary: state.wrappedSummary, aspect: state.posterAspect)
                .environment(\.colorScheme, state.posterColorScheme)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(LinearUI.hairline(scheme)) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: state.posterAspect == .portrait3x4 ? 320 : 200)
    }

    private var posterButtons: some View {
        HStack(spacing: 8) {
            LinearActionButton(title: "Export 3:4 PNG", icon: "photo") {
                callbacks.exportPoster(.portrait3x4, state.posterColorScheme)
            }
            LinearActionButton(title: "Export 16:9 PNG", icon: "photo") {
                callbacks.exportPoster(.landscape16x9, state.posterColorScheme)
            }
        }
    }

    private var reportButtons: some View {
        HStack(spacing: 8) {
            LinearActionButton(title: "Export CSV", icon: "tablecells", action: callbacks.exportCSV)
            LinearActionButton(title: "Export Markdown", icon: "doc.plaintext", action: callbacks.exportMarkdown)
        }
    }

    private func activateLicense() {
        let key = state.licenseKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { callbacks.activateLicense(key) }
    }

    private func section<Content: View>(
        _ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LinearSectionHeader(title: title, subtitle: subtitle)
            LinearCard { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func switchRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            rowLabel(title, subtitle: subtitle)
            Spacer()
            LinearSwitch(isOn: isOn)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func rowLabel(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(LinearUI.hairline(scheme))
            .frame(height: 1)
            .padding(.leading, 14)
    }

    @ViewBuilder
    private func linearInputField(
        _ placeholder: String,
        text: Binding<String>,
        monospaced: Bool = false,
        multiline: Bool = false,
        accessibilityLabel: String? = nil,
        onSubmit: (() -> Void)? = nil
    ) -> some View {
        let font: Font = monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12.5)
        Group {
            if isStaticShowcase {
                let value = text.wrappedValue
                Text(value.isEmpty ? placeholder : value)
                    .font(font)
                    .foregroundStyle(value.isEmpty ? Color.secondary.opacity(0.7) : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(multiline ? 3 : 1)
            } else if multiline {
                TextField(placeholder, text: text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(font)
                    .lineLimit(2...5)
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(font)
                    .onSubmit { onSubmit?() }
            }
        }
        .accessibilityLabel(accessibilityLabel ?? placeholder)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(LinearUI.subtleFill(scheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(LinearUI.controlBorder(scheme))
        }
    }

    private func externalLinkButton(_ title: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(LinearUI.accent)
        }
        .buttonStyle(.plain)
    }
}
