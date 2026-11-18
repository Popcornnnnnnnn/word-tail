# WordTail

**Zero-LLM, single-word inline ghost-text autocomplete for macOS.**

WordTail renders subtle inline gray completions (`kn` + gray `ow`) right at your cursor across macOS apps—Chrome, Electron apps, AI chat interfaces, Slack, WeChat, and native Cocoa apps—and completes **only the current English word** when you press `Tab`.

- **Zero LLM, ~3 ms latency, ~350 KB app bundle:** Powered by macOS's native grammar-aware `NSSpellChecker`, a curated **180+ CS/AI English lexicon**, and your personal accepted-word history. No gigabyte model downloads, no GPU drain, no chatty multi-sentence hallucinations.
- **Built for bilingual & technical typists:** Automatically stays silent whenever you switch to a non-Roman input method (Chinese Pinyin, Rime, Doubao, Japanese, Korean), focus a password field (`SecureEventInput` / `AXSecureTextField`), or edit code buffers inside IDEs and terminals.
- **Sub-Retina-pixel baseline calibration:** Linear-inspired settings UI with live in-place preview and independent per-application vertical baseline sliders (`0.05 pt` precision).

---

## Shortcuts

| Shortcut | Action |
| --- | --- |
| `Tab` | Accept current word completion (with optional smart trailing space) |
| `⌥ ]` / `⌥ [` | Cycle next / previous single-word candidate |
| `Esc` | Dismiss visible ghost completion |
| `⌃ ⌥ W` | Toggle WordTail Active / Paused globally |
| `⌘ ,` | Open WordTail Settings |
| `⌘ W` | Close window (keeps WordTail autocomplete active in background) |
| `⌘ Q` | Quit WordTail |

---

## Features

- **Universal Caret Engine (`AXUIElement` + `AXTextMarker`):**
  - Supports both standard AppKit character ranges (`AXSelectedTextRange` / `AXBoundsForRange`) and WebKit/Chromium/Electron rich `contenteditable` editors (`AXSelectedTextMarkerRange` / `AXBoundsForTextMarkerRange`).
  - Automatically wakes lazy Chromium & Electron accessibility trees while skipping Monaco code-editor tabs so `Tab` in code files keeps indenting/completing code.
- **Smart Context & Prose Guards:**
  - Grammar-aware ranking (`"I kn"` → `know`, `"She kn"` → `knows`, `"quantitative inv"` → `investment`).
  - Automatically ignores URLs, file paths, emails, CLI flags (`--flag`), `snake_case` identifiers, and mid-word cursor positions.
  - Optional **Insert Space After Tab** setting with automatic punctuation/space deduplication.
- **Personal & Technical Dictionary:**
  - Built-in software engineering, AI, and quantitative vocabulary (`TypeScript`, `Kubernetes`, `PyTorch`, `quantization`, `idempotent`, etc.).
  - Pin custom words or let WordTail automatically prioritize words you accept with `Tab`.

---

## Requirements

- **macOS 14.0 (Sonoma)** or later (Apple Silicon or Intel)
- **Swift 5.10+** / Xcode Command Line Tools (to build from source)

---

## Build & Install

```bash
git clone https://github.com/Popcornnnnnnnn/word-tail.git
cd word-tail

# Run unit tests
swift test

# Build release bundle and install to /Applications/WordTail.app
./scripts/build_app.sh --install
open /Applications/WordTail.app
```

On first launch, grant **Accessibility** (and **Input Monitoring** if prompted) under **System Settings → Privacy & Security**. WordTail detects permission approval automatically within 1.5 seconds—no restart required.

---

## Project Structure

- `Sources/WordTailCore/`
  - `WordCompleter.swift` — Context-aware single-word completion, case adaptation, and token guards
  - `TechLexicon.swift` — Curated CS, AI, and quantitative English lexicon
  - `UserHistoryStore.swift` — Local accepted-word frequency counter and custom pinned dictionary
  - `InputGuard.swift` — Roman keyboard layout check, `SecureEventInput` guard, and IDE/terminal exclusions
  - `ScreenGeometry.swift` — Quartz-to-Cocoa baseline geometry
- `Sources/WordTailApp/`
  - `AXCaretContext.swift` — Multi-path macOS Accessibility & Chromium/Electron `AXTextMarker` caret reader
  - `GhostOverlayWindow.swift` — Click-through `NSPanel` with CoreText sub-Retina-pixel vertical interpolation
  - `TypingEngine.swift` — Non-blocking `CGEventTap`, candidate cycling, and clipboard-free tagged Unicode injection
  - `SettingsWindowController.swift` — Linear-style macOS settings window
  - `AppDelegate.swift` — Menu bar status item and `SMAppService` Login Item registration

---

## License

Released under the [MIT License](LICENSE).
