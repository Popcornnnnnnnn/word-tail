\* TLA+ specification of WordTail's CGEventTap synchronous overlay dismissal
\* and HID injection pipeline.
\*
\* Code mapping (verified against Sources/WordTailApp/TypingEngine.swift):
\*   - TypeWord / TypeNextChar: Sources/WordTailApp/TypingEngine.swift (handleCGEvent)
\*   - ShowGhost:               Sources/WordTailApp/TypingEngine.swift (evaluateAndRenderPrediction) &
\*                              Sources/WordTailApp/GhostOverlayWindow.swift (show)
\*   - MoveCursor:              Sources/WordTailApp/TypingEngine.swift (synchronous dismissOverlay on click/nav/shortcut)
\*   - PressTab / PressSpaceFix / PressUndo:
\*                              Sources/WordTailApp/TypingEngine.swift (synchronous tapPostEvent(proxy) injection)

---- MODULE WordTailTyping ----
EXTENDS Naturals

VARIABLES
    editor,         \* "empty", "word", "word_x", "corrected", "corrupted"
    buf,            \* "empty", "word", "word_x", "corrected"
    overlay,        \* "hidden", "visible"
    pendingUndo,    \* BOOLEAN
    pendingDismiss, \* "none", "clear_buf"
    pendingInject,  \* "none", "space_fix", "tab_accept"
    cursorMoved,    \* BOOLEAN
    staleInjected,  \* BOOLEAN
    typedAfterMove  \* BOOLEAN

vars == <<editor, buf, overlay, pendingUndo, pendingDismiss, pendingInject, cursorMoved, staleInjected, typedAfterMove>>

Init ==
    /\ editor = "empty"
    /\ buf = "empty"
    /\ overlay = "hidden"
    /\ pendingUndo = FALSE
    /\ pendingDismiss = "none"
    /\ pendingInject = "none"
    /\ cursorMoved = FALSE
    /\ staleInjected = FALSE
    /\ typedAfterMove = FALSE

TypeWord ==
    /\ editor = "empty"
    /\ buf = "empty"
    /\ editor' = "word"
    /\ buf' = "word"
    /\ UNCHANGED <<overlay, pendingUndo, pendingDismiss, pendingInject, cursorMoved, staleInjected, typedAfterMove>>

ShowGhost ==
    /\ editor = "word"
    /\ buf = "word"
    /\ overlay = "hidden"
    /\ pendingDismiss = "none"
    /\ pendingInject = "none"
    /\ overlay' = "visible"
    /\ UNCHANGED <<editor, buf, pendingUndo, pendingDismiss, pendingInject, cursorMoved, staleInjected, typedAfterMove>>

MoveCursor ==
    /\ editor = "word"
    /\ buf = "word"
    /\ ~cursorMoved
    /\ pendingInject = "none"
    /\ pendingDismiss = "none"
    \* Synchronous dismissOverlay(clearBuffer: true) inside handleCGEvent before passing the event through.
    /\ overlay' = "hidden"
    /\ buf' = "empty"
    /\ cursorMoved' = TRUE
    /\ pendingUndo' = FALSE
    /\ UNCHANGED <<editor, pendingDismiss, pendingInject, staleInjected, typedAfterMove>>

PressTab ==
    /\ overlay = "visible"
    /\ pendingInject = "none"
    \* Synchronous tapPostEvent(proxy) before swallowing the Tab event.
    /\ overlay' = "hidden"
    /\ buf' = "corrected"
    /\ editor' = IF cursorMoved THEN "corrupted" ELSE "corrected"
    /\ staleInjected' = cursorMoved
    /\ UNCHANGED <<pendingUndo, pendingDismiss, pendingInject, cursorMoved, typedAfterMove>>

PressSpaceFix ==
    /\ buf = "word"
    /\ ~cursorMoved
    /\ pendingInject = "none"
    /\ pendingDismiss = "none"
    \* Synchronous tapPostEvent(proxy) before swallowing the Space/punctuation event.
    /\ overlay' = "hidden"
    /\ buf' = "corrected"
    /\ editor' = "corrected"
    /\ pendingUndo' = TRUE
    /\ UNCHANGED <<pendingDismiss, pendingInject, cursorMoved, staleInjected, typedAfterMove>>

TypeNextChar ==
    \/ /\ pendingInject \in {"space_fix", "tab_accept"}
       /\ editor = "word"
       /\ editor' = "word_x"
       /\ pendingUndo' = FALSE
       /\ UNCHANGED <<buf, overlay, pendingDismiss, pendingInject, cursorMoved, staleInjected, typedAfterMove>>
    \/ /\ pendingDismiss = "clear_buf"
       /\ pendingInject = "none"
       /\ editor = "word"
       /\ cursorMoved
       /\ ~typedAfterMove
       /\ editor' = "word_x"
       /\ buf' = "word_x"
       /\ typedAfterMove' = TRUE
       /\ cursorMoved' = FALSE
       /\ UNCHANGED <<overlay, pendingUndo, pendingDismiss, pendingInject, staleInjected>>
    \/ /\ pendingDismiss = "none"
       /\ pendingInject = "none"
       /\ ~typedAfterMove
       /\ ((editor = "word" /\ cursorMoved) \/ editor = "corrected")
       /\ editor' = "word_x"
       /\ buf' = "word_x"
       /\ pendingUndo' = FALSE
       /\ cursorMoved' = FALSE
       /\ typedAfterMove' = TRUE
       /\ UNCHANGED <<overlay, pendingDismiss, pendingInject, staleInjected>>

DrainDismiss ==
    /\ pendingDismiss = "clear_buf"
    /\ overlay' = "hidden"
    /\ buf' = "empty"
    /\ pendingDismiss' = "none"
    /\ pendingUndo' = FALSE
    /\ UNCHANGED <<editor, pendingInject, cursorMoved, staleInjected, typedAfterMove>>

DrainInject ==
    /\ pendingInject \in {"space_fix", "tab_accept"}
    /\ editor' = IF (pendingInject = "tab_accept" /\ staleInjected) \/ editor /= "word"
                 THEN "corrupted"
                 ELSE "corrected"
    /\ pendingInject' = "none"
    /\ UNCHANGED <<buf, overlay, pendingUndo, pendingDismiss, cursorMoved, staleInjected, typedAfterMove>>

PressUndo ==
    /\ pendingUndo
    /\ pendingInject = "none"
    /\ pendingDismiss = "none"
    /\ editor = "corrected"
    /\ editor' = "word"
    /\ buf' = "word"
    /\ pendingUndo' = FALSE
    /\ UNCHANGED <<overlay, pendingDismiss, pendingInject, cursorMoved, staleInjected, typedAfterMove>>

Done ==
    /\ pendingDismiss = "none"
    /\ pendingInject = "none"
    /\ (editor \in {"corrected", "corrupted", "word_x"} \/ (editor = "word" /\ buf = "empty"))
    /\ UNCHANGED vars

Next ==
    \/ TypeWord
    \/ ShowGhost
    \/ MoveCursor
    \/ PressTab
    \/ PressSpaceFix
    \/ TypeNextChar
    \/ DrainDismiss
    \/ DrainInject
    \/ PressUndo
    \/ Done

NoCorruptedEditorText ==
    editor /= "corrupted"

NoStaleTabAccept ==
    ~staleInjected

BufferMatchesEditorWhenIdle ==
    (pendingDismiss = "none" /\ pendingInject = "none" /\ ~cursorMoved /\ editor /= "corrupted")
        => (buf = editor)

====
