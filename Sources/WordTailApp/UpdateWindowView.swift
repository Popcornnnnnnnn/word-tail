import AppKit
import SwiftUI

@MainActor
final class UpdateWindowState: ObservableObject {
    @Published var progress: String?
}

struct UpdateWindowView: View {
    @Environment(\.colorScheme) private var scheme
    let currentVersion: String
    let availableVersion: String
    let icon: NSImage
    let release: URL
    @ObservedObject var state: UpdateWindowState
    let dismiss: () -> Void
    let install: () -> Void

    private let notes: [ReleaseNotesBlock]

    init(
        currentVersion: String,
        availableVersion: String,
        icon: NSImage,
        release: URL,
        markdown: String,
        state: UpdateWindowState,
        dismiss: @escaping () -> Void,
        install: @escaping () -> Void
    ) {
        self.currentVersion = currentVersion
        self.availableVersion = availableVersion
        self.icon = icon
        self.release = release
        self.state = state
        self.dismiss = dismiss
        self.install = install
        self.notes = ReleaseNotesBlock.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("WordTail update available")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)

                    HStack(spacing: 9) {
                        Text("Installed v\(currentVersion)")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text("Available v\(availableVersion)")
                            .fontWeight(.medium)
                    }
                    .font(.subheadline.monospacedDigit())
                }
            }

            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Release notes")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(notes.indices, id: \.self) { index in
                                noteRow(notes[index])
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    }
                    .frame(height: 204)
                    .background(LinearUI.cardBg(scheme), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(LinearUI.hairline(scheme))
                            .allowsHitTesting(false)
                    }
                }
            }

            HStack(spacing: 10) {
                if let progress = state.progress {
                    ProgressView().controlSize(.small)
                    Text(progress)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Close", action: dismiss)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Link(destination: release) {
                        HStack(spacing: 4) {
                            Text("View on GitHub")
                            Image(systemName: "arrow.up.right")
                                .imageScale(.small)
                                .accessibilityHidden(true)
                        }
                    }
                    Spacer()
                    Button("Later", action: dismiss)
                        .keyboardShortcut(.cancelAction)
                    Button("Update & Restart", action: install)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 536)
        .background(LinearUI.windowBg(scheme))
        .tint(LinearUI.accent)
    }

    private func noteRow(_ block: ReleaseNotesBlock) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let marker = block.marker {
                Text(marker)
                    .foregroundStyle(.secondary)
            }
            Text(block.text)
                .font(block.isHeading ? .callout.weight(.semibold) : .callout)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(max(0, block.listDepth - 1)) * 14)
    }
}

private struct ReleaseNotesBlock {
    var text: AttributedString
    var isHeading = false
    var marker: String?
    var listDepth = 0

    static func parse(_ markdown: String) -> [Self] {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let attributed = try? AttributedString(
            markdown: trimmed,
            options: .init(interpretedSyntax: .full)
        ), !attributed.characters.isEmpty else {
            return [Self(text: AttributedString(trimmed))]
        }

        var blocks: [Self] = []
        var previousBlock: Int?
        var seenListItems: Set<Int> = []
        for run in attributed.runs {
            let components = run.presentationIntent?.components ?? []
            let blockID = components.first?.identity ?? 0
            var text = AttributedString(attributed[run.range])
            text.presentationIntent = nil
            text.imageURL = nil
            if let url = run.link, !["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                text.link = nil
            }
            if case .codeBlock? = components.first?.kind {
                text.font = .callout.monospaced()
            } else if run.inlinePresentationIntent?.contains(.code) == true {
                text.font = .callout.monospaced()
            }

            if previousBlock == blockID {
                blocks[blocks.count - 1].text += text
                continue
            }

            var block = Self(text: text)
            for (index, component) in components.enumerated() {
                switch component.kind {
                case .header:
                    block.isHeading = true
                case .listItem(let ordinal):
                    if block.listDepth == 0, seenListItems.insert(component.identity).inserted {
                        if components.indices.contains(index + 1),
                           case .orderedList = components[index + 1].kind {
                            block.marker = "\(ordinal)."
                        } else {
                            block.marker = "•"
                        }
                    }
                    block.listDepth += 1
                default:
                    break
                }
            }

            blocks.append(block)
            previousBlock = blockID
        }
        return blocks
    }
}
