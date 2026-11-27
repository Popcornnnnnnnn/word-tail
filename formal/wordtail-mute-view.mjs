export const title = "WordTail AdaptiveCorrectionStore Undo-Mute and Tombstone";

export const colors = {
  active: "teal",
  custom: "blue",
  muted: "tan",
  broken: "pink",
};

export const state = (v) => {
  if (v.ruleState !== "custom" && v.undoCount >= 2 && v.ruleState !== "muted") {
    return `Unmuted after ${v.undoCount} undos (tombstone blocks mute!)`;
  }
  if (v.ruleState === "custom") {
    return v.undoCount === 0 ? "Custom rule active" : `Custom rule (undos=${v.undoCount})`;
  }
  if (v.ruleState === "muted") {
    return "Trigger muted";
  }
  const tomb = v.tombstoneDeleted ? " [isDeleted tombstone]" : "";
  return `Default rule (undos=${v.undoCount})${tomb}`;
};

export const group = (v) => {
  if (v.ruleState !== "custom" && v.undoCount >= 2 && v.ruleState !== "muted") return "broken";
  if (v.ruleState === "custom") return "custom";
  if (v.ruleState === "muted") return "muted";
  return "active";
};

export const step = (action, from, to) => {
  switch (action) {
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
