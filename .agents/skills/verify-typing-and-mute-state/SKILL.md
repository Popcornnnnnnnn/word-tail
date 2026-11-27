---
name: verify-typing-and-mute-state
description: Formally verify WordTail TypingEngine overlay/HID injection concurrency and AdaptiveCorrectionStore undo-mute/tombstone invariants with TLA+ and TLC. Run during any major update or when changing TypingEngine.swift, GhostOverlayWindow.swift, ObviousTypoCorrector.swift, or SyncEngine.swift.
---

# Verify WordTail Typing and Undo-Mute State Machines

Checks two TLA+ models covering WordTail's highest-risk stateful subsystems:
1. `formal/WordTailTyping.tla` — synchronous `CGEventTap` decisions racing with `DispatchQueue.main.async` overlay dismissals and HID key injection.
2. `formal/WordTailMute.tla` — `AdaptiveCorrectionStore` undo counting, custom rule overrides, and `isDeleted` sync tombstones.

## Coverage & Sync Record

- `sync_commit`: `52c182b`
- **Covered files & symbols:**
  - `Sources/WordTailApp/TypingEngine.swift`: `handleCGEvent`, `dismissOverlay`, `evaluateAndRenderPrediction`, `injectBackspaces`, `injectUnicodeString`
  - `Sources/WordTailApp/GhostOverlayWindow.swift`: `show`, `hide`, `isVisible`
  - `Sources/WordTailCore/ObviousTypoCorrector.swift`: `AdaptiveCorrectionStore.isMutedLocked`, `recordUndo`, `addCustomRule`, `removeRuleOrUnmute`
- **Check for code drift since last sync:**
  ```sh
  git diff 52c182b..HEAD -- \
    Sources/WordTailApp/TypingEngine.swift \
    Sources/WordTailApp/GhostOverlayWindow.swift \
    Sources/WordTailCore/ObviousTypoCorrector.swift
  ```

If covered files changed after `sync_commit`, follow the installed `maintain-formal-verification-skill` before interpreting a pass. Only move `sync_commit` forward after confirming both TLA+ models describe `HEAD` and pass a mutation check.

## Verified Properties (Invariants)

### `WordTailTyping`
1. **`BufferMatchesEditorWhenIdle`:** When no async dismiss or HID injection is queued and the cursor has not moved, `rollingBuffer` matches the editor text.
2. **`NoCorruptedEditorText`:** Queued HID backspaces and Unicode string insertions never arrive out of order after subsequent keystrokes or stale overlay state.
3. **`NoStaleTabAccept`:** Pressing `Tab` after a click/arrow/modifier navigation never triggers an injection for the dismissed suggestion.

### `WordTailMute`
4. **`TwoUndosAlwaysMute`:** Recording 2 Backspace undos against a non-custom trigger always mutes it.

## Bounds, Assumptions & Out-of-Scope

- **Bounds:** `WordTailTyping` models a single `"teh"` token + 1 cursor move / Tab / Space-fix / immediate next-character window; `WordTailMute` bounds `undoCount` to `0..2` for one trigger key.
- **Out of scope:** Multi-peer iCloud shard merging (`SyncEngine.swift`), AXUIElement caret geometry (`AXCaretContext.swift`, `ScreenGeometry.swift`), completion ranking, and lexicon matching.

## Known Baseline Findings at `52c182b`

- **`WordTailTyping` (26 states / 42 transitions):** `NoDeadlock` holds; all 3 async-dispatch invariants break in 4 steps because `handleCGEvent` passes regular keystrokes synchronously while scheduling `dismissOverlay(clearBuffer: true)` and HID injection asynchronously onto `DispatchQueue.main`. Code audit also notes that `TypingEngine.swift:991-998` intercepts `Command`/`Control`/`Option` before `L1252-1278`, shadowing the `⌥⌫`/`⌘⌫` buffer-trimming handler.
- **`WordTailMute` (9 states / 19 transitions):** `NoDeadlock` holds; `TwoUndosAlwaysMute` breaks in 4 steps (`AddCustomRule` or mute -> `RemoveOrUnmute` -> 2× `RecordUndo`) and is live-reproducible in `WordTailCore`: `removeRuleOrUnmute` writes `syncRecords[key].isDeleted = true`, and `isMutedLocked` returns `false` early on `isDeleted == true` before checking `totalUndos >= muteUndoThreshold`.

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
