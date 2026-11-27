---
name: verify-typing-and-mute-state
description: Formally verify WordTail TypingEngine overlay/HID injection concurrency and AdaptiveCorrectionStore undo-mute/tombstone invariants with TLA+ and TLC. Run during any major update or when changing TypingEngine.swift, GhostOverlayWindow.swift, ObviousTypoCorrector.swift, or SyncEngine.swift.
---

# Verify WordTail Typing and Undo-Mute State Machines

Checks two TLA+ models covering WordTail's highest-risk stateful subsystems:
1. `formal/WordTailTyping.tla` — synchronous `CGEventTap` overlay dismissal and `tapPostEvent(proxy)` HID key injection.
2. `formal/WordTailMute.tla` — `AdaptiveCorrectionStore` undo counting, custom rule overrides, and `isDeleted` sync tombstones.

## Coverage & Sync Record

- `sync_commit`: `ae1f994`
- **Covered files & symbols:**
  - `Sources/WordTailApp/TypingEngine.swift`: `handleCGEvent`, `dismissOverlay`, `evaluateAndRenderPrediction`, `injectBackspaces`, `injectUnicodeString`
  - `Sources/WordTailApp/GhostOverlayWindow.swift`: `show`, `hide`, `isVisible`, `repositionInlineBaseline`
  - `Sources/WordTailCore/ObviousTypoCorrector.swift`: `AdaptiveCorrectionStore.isMutedLocked`, `recordUndo`, `addCustomRule`, `removeRuleOrUnmute`
- **Check for code drift since last sync:**
  ```sh
  git diff ae1f994..HEAD -- \
    Sources/WordTailApp/TypingEngine.swift \
    Sources/WordTailApp/GhostOverlayWindow.swift \
    Sources/WordTailCore/ObviousTypoCorrector.swift
  ```

If covered files changed after `sync_commit`, follow the installed `maintain-formal-verification-skill` before interpreting a pass. Only move `sync_commit` forward after confirming both TLA+ models describe `HEAD` and pass a mutation check.

## Verified Properties (Invariants)

### `WordTailTyping`
1. **`BufferMatchesEditorWhenIdle`:** When no async dismiss or HID injection is queued and the cursor has not moved, `rollingBuffer` matches the editor text.
2. **`NoCorruptedEditorText`:** HID backspaces and Unicode string insertions never arrive out of order after subsequent keystrokes or stale overlay state.
3. **`NoStaleTabAccept`:** Pressing `Tab` after a click/arrow/modifier navigation never triggers an injection for the dismissed suggestion.

### `WordTailMute`
4. **`TwoUndosAlwaysMute`:** Recording 2 local Backspace undos against a non-custom trigger always mutes it, even when an `isDeleted` sync tombstone exists.
5. **`TombstoneBlocksStaleRemoteMute`:** An unmuted or deleted trigger with an `isDeleted` sync tombstone never re-mutes solely from stale remote peer undo counts before 2 fresh local undos occur.

## Bounds, Assumptions & Out-of-Scope

- **Bounds:** `WordTailTyping` models a single `"teh"` token + 1 cursor move / Tab / Space-fix / Backspace-undo / immediate next-character window; `WordTailMute` models `ruleState`, `undoCount` (`0..2`), `tombstoneDeleted`, and `remoteStaleUndos` for one trigger key.
- **Out of scope:** Multi-peer iCloud shard merging (`SyncEngine.swift`), AXUIElement caret geometry (`AXCaretContext.swift`, `ScreenGeometry.swift`), completion ranking, and lexicon matching.

## Verified Status at `ae1f994`

- **`WordTailTyping`:** TLC explores **7 states / 15 steps** (6 chart states, 9 arrows). `NoCorruptedEditorText`, `NoStaleTabAccept`, `BufferMatchesEditorWhenIdle`, and `NoDeadlock` all **hold** (`exit 0`). Re-verified after Live Per-Line Sub-Pixel Lock (`9d4cd6f`, `cbb4759`) and PR #12 (`ae1f994`): `Tab` / `⌥ →` acceptance additionally guards on `activeSnapshot != nil` and `GhostOverlayWindow.repositionInlineBaseline` never alters visibility or match state.
  - *Mutation proof:* Reverting `PressSpaceFix` to queue `pendingInject = "space_fix"` asynchronously fails `NoCorruptedEditorText` in 4 steps (`exit 1`).
- **`WordTailMute`:** TLC explores **16 states / 42 steps** (10 chart states, 26 arrows). `TwoUndosAlwaysMute`, `TombstoneBlocksStaleRemoteMute`, and `NoDeadlock` all **hold** (`exit 0`). No `AdaptiveCorrectionStore` mute/tombstone logic changed since `323f39f`.
  - *Mutation proof:* Reverting `RecordUndo` / `isMutedLocked` so `isDeleted` blocks local re-muting fails `TwoUndosAlwaysMute` in 4 steps (`exit 1`).
- **History:** Baseline async-dispatch and tombstone bugs discovered at `52c182b` (plus the shadowed `⌥⌫`/`⌘⌫` modifier check) were fixed in `323f39f` with `Tests/WordTailTests/AdaptiveMuteRegressionTests.swift`.

Treat any failure in these invariants or `NoDeadlock` as an immediate release blocker.

## How to Run

Run both specs with the installed `statechart` skill (writing output to fresh folders under `/tmp`, never inside the repository):

1. Typing model:
   - Model: `formal/WordTailTyping.tla`
   - Config: `formal/WordTailTyping.cfg`
   - View: `formal/wordtail-typing-view.mjs`
   - Output: `/tmp/wordtail-statechart-typing-<run>`
2. Undo-mute model:
   - Model: `formal/WordTailMute.tla`
   - Config: `formal/WordTailMute.cfg`
   - View: `formal/wordtail-mute-view.mjs`
   - Output: `/tmp/wordtail-statechart-mute-<run>`

*Contributor fallback (without the `statechart` skill):* run standard TLC (`java -cp tla2tools.jar tlc2.TLC -config formal/WordTailTyping.cfg formal/WordTailTyping.tla` and similarly for `WordTailMute`).

## Interpreting Results & Upkeep Rules

- **Never weaken an invariant** or shrink bounds solely to make TLC pass.
- **Replay every violation:** For `WordTailCore` findings, verify directly with a test or temporary Swift harness against `WordTailCore`; for `TypingEngine`, trace the exact `CGEventTap` vs `DispatchQueue.main` ordering against current code (or an event-tap harness). If a sequence cannot happen in real Swift execution, update the model rather than product code.
- **Separate changes:** Keep verification updates (`formal/`, this skill) in their own commit separate from product bug fixes.
