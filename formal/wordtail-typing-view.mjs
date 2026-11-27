export const title = "WordTail TypingEngine Synchronous Overlay and HID Injection";

export const colors = {
  idle: "blue",
  typing: "teal",
  queued: "yellow",
  settled: "tan",
  broken: "pink",
};

const breaks = (v) => {
  const corrupt = v.editor === "corrupted";
  const stale = v.staleInjected;
  const mismatch =
    v.pendingDismiss === "none" &&
    v.pendingInject === "none" &&
    !v.cursorMoved &&
    v.editor !== "corrupted" &&
    v.buf !== v.editor;
  return { corrupt, stale, mismatch };
};

export const state = (v) => {
  const b = breaks(v);
  if (b.corrupt && b.stale) return "Corrupted editor from stale Tab";
  if (b.corrupt) return "Corrupted editor from async race";
  if (b.stale) return "Stale Tab injection queued after cursor move";
  if (b.mismatch) return "Rolling buffer wiped while editor has text";

  if (v.editor === "empty") return "Empty editor";
  if (v.pendingInject === "tab_accept" && v.editor === "word_x") {
    return "Char typed before Tab injection ran";
  }
  if (v.pendingInject === "space_fix" && v.editor === "word_x") {
    return "Char typed before Space fix ran";
  }
  if (v.pendingInject === "tab_accept") return "Tab swallowed, injection queued";
  if (v.pendingInject === "space_fix") return "Space auto-fix queued";
  if (v.pendingDismiss === "clear_buf") {
    if (v.typedAfterMove) return "Typed new char before dismiss drained";
    return v.overlay === "visible"
      ? "Cursor moved (ghost still visible, dismiss queued)"
      : "Cursor moved (dismiss queued)";
  }
  if (v.editor === "corrected") return "Text corrected cleanly";
  if (v.editor === "word_x") return "New char typed cleanly";
  if (v.buf === "empty" && v.editor === "word") return "Cursor moved and buffer cleared";
  return v.overlay === "visible" ? "Word typed, ghost visible" : "Word typed, ghost hidden";
};

export const group = (v) => {
  const b = breaks(v);
  if (b.corrupt || b.stale || b.mismatch) return "broken";
  if (v.editor === "empty") return "idle";
  if (v.pendingInject !== "none" || v.pendingDismiss !== "none") return "queued";
  if (v.editor === "corrected" || v.editor === "word_x" || v.buf === "empty") return "settled";
  return "typing";
};

export const step = (action, from, to) => {
  switch (action) {
    case "TypeWord":
      return "type 'teh'";
    case "ShowGhost":
      return "show ghost suffix";
    case "MoveCursor":
      return "click / arrow / shortcut";
    case "PressTab":
      return "press Tab (sync tapPostEvent)";
    case "PressSpaceFix":
      return "press Space (sync auto-fix)";
    case "TypeNextChar":
      return "type next char";
    case "DrainDismiss":
      return "main queue runs dismiss";
    case "DrainInject":
      return "main queue injects HID keys";
    case "PressUndo":
      return "press Backspace (sync undo)";
    case "Done":
      return null;
    default:
      return action;
  }
};
