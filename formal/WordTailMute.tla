\* TLA+ specification of WordTail's AdaptiveCorrectionStore undo-mute
\* and sync tombstone interaction.
\*
\* Code mapping:
\*   - Sources/WordTailCore/ObviousTypoCorrector.swift (AdaptiveCorrectionStore):
\*     * isMutedLocked      (L236-248)
\*     * recordUndo         (L349-373)
\*     * addCustomRule      (L376-402)
\*     * removeRuleOrUnmute (L404-422)

---- MODULE WordTailMute ----
EXTENDS Naturals

VARIABLES
    ruleState,         \* "default", "custom", "muted"
    undoCount,         \* 0..2
    tombstoneDeleted,  \* BOOLEAN (syncRecords[key].isDeleted)
    remoteStaleUndos   \* BOOLEAN (stale peer undo counts merged during sync)

vars == <<ruleState, undoCount, tombstoneDeleted, remoteStaleUndos>>

Init ==
    /\ ruleState = "default"
    /\ undoCount = 0
    /\ tombstoneDeleted = FALSE
    /\ remoteStaleUndos = FALSE

SyncRemoteUndos ==
    /\ ~remoteStaleUndos
    /\ ruleState = "default"
    /\ remoteStaleUndos' = TRUE
    /\ ruleState' = IF ~tombstoneDeleted THEN "muted" ELSE ruleState
    /\ UNCHANGED <<undoCount, tombstoneDeleted>>

RecordUndo ==
    /\ undoCount < 2
    /\ LET newCount == undoCount + 1
           nowMuted ==
               \/ ruleState = "muted"
               \/ (ruleState /= "custom" /\ (newCount >= 2 \/ (~tombstoneDeleted /\ remoteStaleUndos)))
       IN /\ undoCount' = newCount
          /\ ruleState' = IF nowMuted THEN "muted" ELSE ruleState
          /\ tombstoneDeleted' = IF nowMuted THEN FALSE ELSE tombstoneDeleted
          /\ UNCHANGED remoteStaleUndos

AddCustomRule ==
    /\ ruleState /= "custom"
    /\ ruleState' = "custom"
    /\ undoCount' = 0
    /\ tombstoneDeleted' = FALSE
    /\ UNCHANGED remoteStaleUndos

RemoveOrUnmute ==
    /\ ruleState \in {"custom", "muted"}
    /\ ruleState' = "default"
    /\ undoCount' = 0
    /\ tombstoneDeleted' = TRUE
    /\ UNCHANGED remoteStaleUndos

Done ==
    /\ (undoCount = 2 \/ ruleState = "muted")
    /\ UNCHANGED vars

Next ==
    \/ SyncRemoteUndos
    \/ RecordUndo
    \/ AddCustomRule
    \/ RemoveOrUnmute
    \/ Done

TwoUndosAlwaysMute ==
    (ruleState /= "custom" /\ undoCount >= 2) => (ruleState = "muted")

TombstoneBlocksStaleRemoteMute ==
    (tombstoneDeleted /\ undoCount < 2) => (ruleState /= "muted")

====
