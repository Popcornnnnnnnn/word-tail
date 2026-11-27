\* TLA+ specification of WordTail's CGEventTap + DispatchQueue.main.async
\* ghost overlay dismissal and HID injection pipeline.
\*
\* Code mapping:
\*   - TypeWord / TypeNextChar:     Sources/WordTailApp/TypingEngine.swift (handleCGEvent L1509-1589)
\*   - ShowGhost:                   Sources/WordTailApp/TypingEngine.swift (evaluateAndRenderPrediction) &
\*                                  Sources/WordTailApp/GhostOverlayWindow.swift (show)
\*   - MoveCursor / DrainDismiss:   Sources/WordTailApp/TypingEngine.swift (handleCGEvent L900-914, L991-998, L1358-1363)
\*   - PressTab / PressSpaceFix:    Sources/WordTailApp/TypingEngine.swift (handleCGEvent L1001-1240, L1379-1499)
\*   - DrainInject:                 Sources/WordTailApp/TypingEngine.swift (injectBackspaces, injectUnicodeString)
\*   - PressUndo:                   Sources/WordTailApp/TypingEngine.swift (pendingSpaceUndo L1280-1312)

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
    /\ cursorMoved' = TRUE
    /\ pendingUndo' = FALSE
    /\ pendingDismiss' = "clear_buf"
    /\ UNCHANGED <<editor, buf, overlay, pendingInject, staleInjected, typedAfterMove>>

PressTab ==
    /\ overlay = "visible"
    /\ pendingInject = "none"
    /\ overlay' = "hidden"
    /\ buf' = "corrected"
    /\ pendingInject' = "tab_accept"
    /\ staleInjected' = cursorMoved
    /\ UNCHANGED <<editor, pendingUndo, pendingDismiss, cursorMoved, typedAfterMove>>

PressSpaceFix ==
    /\ buf = "word"
    /\ ~cursorMoved
    /\ pendingInject = "none"
    /\ pendingDismiss = "none"
    /\ overlay' = "hidden"
    /\ buf' = "corrected"
    /\ pendingUndo' = TRUE
    /\ pendingInject' = "space_fix"
    /\ UNCHANGED <<editor, pendingDismiss, cursorMoved, staleInjected, typedAfterMove>>

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
