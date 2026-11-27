export const title = "WordTail AdaptiveCorrectionStore Undo-Mute and Tombstone";

export const colors = {
  active: "teal",
  custom: "blue",
  muted: "tan",
  broken: "pink",
};

const breaks = (v) => {
  const unmutedTwo = v.ruleState !== "custom" && v.undoCount >= 2 && v.ruleState !== "muted";
  const staleRemoteMute = v.tombstoneDeleted && v.undoCount < 2 && v.ruleState === "muted";
  return { unmutedTwo, staleRemoteMute };
};

export const state = (v) => {
  const b = breaks(v);
  if (b.unmutedTwo) {
    return `Unmuted after ${v.undoCount} undos`;
  }
  if (b.staleRemoteMute) {
    return "Tombstone failed to block stale remote mute";
  }
  if (v.ruleState === "custom") {
    return v.undoCount === 0 ? "Custom rule active" : `Custom rule (undos=${v.undoCount})`;
  }
  if (v.ruleState === "muted") {
    return "Trigger muted";
  }
  const tomb = v.tombstoneDeleted ? " [tombstone]" : "";
  const remote = v.remoteStaleUndos ? " [remoteUndos]" : "";
  return `Default rule (undos=${v.undoCount})${tomb}${remote}`;
};

export const group = (v) => {
  const b = breaks(v);
  if (b.unmutedTwo || b.staleRemoteMute) return "broken";
  if (v.ruleState === "custom") return "custom";
  if (v.ruleState === "muted") return "muted";
  return "active";
};

export const step = (action, from, to) => {
  switch (action) {
    case "SyncRemoteUndos":
      return "sync remote peer undos";
    case "RecordUndo":
      return "undo auto-correct (Backspace)";
    case "AddCustomRule":
      return "add custom rule";
    case "RemoveOrUnmute":
      return "remove rule or unmute";
    case "Done":
      return null;
    default:
      return action;
  }
};
