\* TLA+ specification of WordTail's AdaptiveCorrectionStore undo-mute
\* and sync tombstone interaction.
\*
\* Code mapping:
\*   - Sources/WordTailCore/ObviousTypoCorrector.swift (AdaptiveCorrectionStore):
\*     * isMutedLocked      (L236-245)
\*     * recordUndo         (L346-370)
\*     * addCustomRule      (L373-399)
\*     * removeRuleOrUnmute (L401-419)

---- MODULE WordTailMute ----
EXTENDS Naturals

VARIABLES
    ruleState,         \* "default", "custom", "muted"
    undoCount,         \* 0..2
    tombstoneDeleted   \* BOOLEAN (syncRecords[key].isDeleted)

vars == <<ruleState, undoCount, tombstoneDeleted>>

Init ==
    /\ ruleState = "default"
    /\ undoCount = 0
    /\ tombstoneDeleted = FALSE

RecordUndo ==
    /\ undoCount < 2
    /\ LET newCount == undoCount + 1
           nowMuted ==
               \/ ruleState = "muted"
               \/ (~(ruleState = "custom") /\ ~tombstoneDeleted /\ newCount >= 2)
       IN /\ undoCount' = newCount
          /\ ruleState' = IF nowMuted THEN "muted" ELSE ruleState
          /\ tombstoneDeleted' = IF nowMuted THEN FALSE ELSE tombstoneDeleted

AddCustomRule ==
    /\ ruleState /= "custom"
    /\ ruleState' = "custom"
    /\ undoCount' = 0
    /\ tombstoneDeleted' = FALSE

RemoveOrUnmute ==
    /\ ruleState \in {"custom", "muted"}
    /\ ruleState' = "default"
    /\ undoCount' = 0
    /\ tombstoneDeleted' = TRUE

Done ==
    /\ (undoCount = 2 \/ ruleState = "muted")
    /\ UNCHANGED vars

Next ==
    \/ RecordUndo
    \/ AddCustomRule
    \/ RemoveOrUnmute
    \/ Done

TwoUndosAlwaysMute ==
    (ruleState /= "custom" /\ undoCount >= 2) => (ruleState = "muted")

====
