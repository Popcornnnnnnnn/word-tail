import SwiftUI
import WordTailCore

struct DictionarySettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Personal & Technical Dictionary")
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                LinearSectionHeader(title: "Built-In Lexicon")

                LinearCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Software Engineering & AI Vocabulary")
                                .font(.system(size: 13, weight: .medium))
                            Text("Includes 180+ CS, AI, and quantitative terms (TypeScript, PyTorch, Kubernetes…)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        LinearSwitch(isOn: $vm.enableTechLexicon)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LinearSectionHeader(
                    title: "Learnable Auto-Correct & Shorthand Rules",
                    subtitle: "Built-in contractions (im → I'm, dont → don't) + rules auto-learned from your repairs and ⌫ undos."
                )

                LinearCard {
                    HStack(spacing: 8) {
                        TextField("Trigger (e.g. tmr)", text: $vm.newRuleTrigger)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, design: .monospaced))
                            .frame(width: 135)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        TextField("Replacement (e.g. tomorrow)", text: $vm.newRuleReplacement)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .onSubmit {
                                vm.submitNewCorrectionRule()
                            }
                        LinearActionButton(title: "Add Rule", icon: nil) {
                            vm.submitNewCorrectionRule()
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 42)

                    ForEach(vm.correctionRules.prefix(25)) { rule in
                        Rectangle()
                            .fill(LinearUI.hairline(scheme))
                            .frame(height: 1)
                            .padding(.leading, 12)

                        HStack(spacing: 8) {
                            Text(rule.trigger)
                                .font(.system(size: 12, design: .monospaced))
                                .strikethrough(rule.source == .muted, color: .secondary)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(rule.replacement)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(rule.source == .muted ? .secondary : .primary)
                            LinearKbd(label: rule.source.rawValue)
                            Spacer()
                            if rule.count > 0 && rule.source == .learned {
                                Text("\(rule.count)×")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            LinearIconButton(
                                symbol: "xmark",
                                helpText: rule.source == .muted ? "Unmute trigger" : "Remove rule"
                            ) {
                                vm.removeCorrectionRule(rule.trigger)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 35)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LinearSectionHeader(
                    title: "Pinned & Learned Phrases",
                    subtitle: "Triggers after 2–3 anchor words; Tab accepts full phrase, ⌥→ accepts 1 word."
                )

                LinearCard {
                    HStack(spacing: 8) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("Pin custom 3–10 word phrase (e.g. as far as I'm concerned)…", text: $vm.newCustomPhraseInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .onSubmit {
                                vm.submitNewCustomPhrase()
                            }
                        LinearActionButton(title: "Pin", icon: nil) {
                            vm.submitNewCustomPhrase()
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 42)

                    if !vm.phraseEntries.isEmpty {
                        ForEach(vm.phraseEntries.prefix(30)) { item in
                            Rectangle()
                                .fill(LinearUI.hairline(scheme))
                                .frame(height: 1)
                                .padding(.leading, 12)

                            HStack(spacing: 6) {
                                Text(item.anchor)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                Text(item.continuation)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(LinearUI.accent)
                                LinearKbd(label: item.source.rawValue)
                                Spacer()
                                if item.count > 0 {
                                    Text("\(item.count)×")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                }
                                LinearIconButton(symbol: "xmark", helpText: "Remove phrase") {
                                    vm.removePhraseEntry(item)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    LinearSectionHeader(
                        title: "Custom & Learned Words",
                        subtitle: "Pinned words always rank first when their prefix matches."
                    )
                    Spacer()
                    if !vm.vocabularyEntries.isEmpty || !vm.phraseEntries.isEmpty || !vm.correctionRules.isEmpty {
                        LinearActionButton(title: "Clear All", icon: "trash") {
                            vm.clearLearnedVocabulary()
                        }
                    }
                }

                LinearCard {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        TextField("Add custom English word (e.g. Antigravity, ColleagueName)…", text: $vm.newCustomWordInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .onSubmit {
                                vm.submitNewCustomWord()
                            }
                        LinearActionButton(title: "Add", icon: nil) {
                            vm.submitNewCustomWord()
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 42)

                    if !vm.vocabularyEntries.isEmpty {
                        ForEach(vm.vocabularyEntries.prefix(40)) { entry in
                            Rectangle()
                                .fill(LinearUI.hairline(scheme))
                                .frame(height: 1)
                                .padding(.leading, 12)

                            HStack(spacing: 8) {
                                Text(entry.word)
                                    .font(.system(size: 12.5, weight: .medium))
                                if entry.isCustom {
                                    LinearKbd(label: "Pinned")
                                }
                                Spacer()
                                if entry.count > 0 {
                                    Text("\(entry.count)×")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                LinearIconButton(symbol: "xmark", helpText: "Remove word") {
                                    vm.removeVocabularyWord(entry.word)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                        }
                    }
                }
            }
        }
    }
}
