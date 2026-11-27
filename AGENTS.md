# WordTail Working Agreement

Read [README.md](README.md) and [Package.swift](Package.swift) before making substantial changes.

## Standard Build & Test Gate

Run unit tests before committing or opening a PR:

```sh
swift test
```

Release app bundles (`./scripts/build_app.sh`) must only be built or installed from a clean committed SHA.

## Major-Update Formal State-Machine Check

Before finalizing a major update or any change touching keystroke interception, ghost overlay lifecycle, HID injection, auto-correct undo/mute rules, or multi-device sync (`Sources/WordTailApp/TypingEngine.swift`, `Sources/WordTailApp/GhostOverlayWindow.swift`, `Sources/WordTailCore/ObviousTypoCorrector.swift`, `Sources/WordTailCore/SyncEngine.swift`):

1. Run `.agents/skills/verify-typing-and-mute-state/SKILL.md` (mirrored at `.claude/skills/verify-typing-and-mute-state/SKILL.md`).
2. If covered files changed past the skill's recorded `sync_commit`, update the TLA+ models under `formal/` using `maintain-formal-verification-skill` before trusting a pass, and write `statechart` outputs under `/tmp` only.
3. Replay every counterexample against `WordTailCore` or the live `TypingEngine` event-tap flow to separate real bugs from model drift.

## Privacy & Open-Source Boundaries

- MIT public repository: never commit user telemetry, personal typing histories, secrets, or machine-specific paths.
