import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit.hidsystem

public enum KeyHand: Sendable {
    case left
    case right
    case neutral
}

public struct KeySpec: Equatable, Sendable {
    public let id: String
    public let label: String
    public let widthWeight: Double
    public let hand: KeyHand

    public init(id: String, label: String, widthWeight: Double = 1.0, hand: KeyHand) {
        self.id = id
        self.label = label
        self.widthWeight = widthWeight
        self.hand = hand
    }
}

public enum KeyCodeMapper {
    private static let leftControlMask = UInt64(NX_DEVICELCTLKEYMASK)
    private static let rightControlMask = UInt64(NX_DEVICERCTLKEYMASK)
    private static let leftShiftMask = UInt64(NX_DEVICELSHIFTKEYMASK)
    private static let rightShiftMask = UInt64(NX_DEVICERSHIFTKEYMASK)
    private static let leftCommandMask = UInt64(NX_DEVICELCMDKEYMASK)
    private static let rightCommandMask = UInt64(NX_DEVICERCMDKEYMASK)
    private static let leftOptionMask = UInt64(NX_DEVICELALTKEYMASK)
    private static let rightOptionMask = UInt64(NX_DEVICERALTKEYMASK)

    /// Standard 6-row MacBook ANSI keyboard layout for rendering the interactive Keyboard Heatmap.
    public static let ansiRows: [[KeySpec]] = [
        [
            KeySpec(id: "Esc", label: "esc", widthWeight: 1.35, hand: .left),
            KeySpec(id: "F1", label: "F1", hand: .left),
            KeySpec(id: "F2", label: "F2", hand: .left),
            KeySpec(id: "F3", label: "F3", hand: .left),
            KeySpec(id: "F4", label: "F4", hand: .left),
            KeySpec(id: "F5", label: "F5", hand: .left),
            KeySpec(id: "F6", label: "F6", hand: .right),
            KeySpec(id: "F7", label: "F7", hand: .right),
            KeySpec(id: "F8", label: "F8", hand: .right),
            KeySpec(id: "F9", label: "F9", hand: .right),
            KeySpec(id: "F10", label: "F10", hand: .right),
            KeySpec(id: "F11", label: "F11", hand: .right),
            KeySpec(id: "F12", label: "F12", hand: .right),
            KeySpec(id: "ForwardDelete", label: "⌦", widthWeight: 1.15, hand: .right)
        ],
        [
            KeySpec(id: "`", label: "`", hand: .left),
            KeySpec(id: "1", label: "1", hand: .left),
            KeySpec(id: "2", label: "2", hand: .left),
            KeySpec(id: "3", label: "3", hand: .left),
            KeySpec(id: "4", label: "4", hand: .left),
            KeySpec(id: "5", label: "5", hand: .left),
            KeySpec(id: "6", label: "6", hand: .right),
            KeySpec(id: "7", label: "7", hand: .right),
            KeySpec(id: "8", label: "8", hand: .right),
            KeySpec(id: "9", label: "9", hand: .right),
            KeySpec(id: "0", label: "0", hand: .right),
            KeySpec(id: "-", label: "-", hand: .right),
            KeySpec(id: "=", label: "=", hand: .right),
            KeySpec(id: "Delete", label: "⌫", widthWeight: 1.5, hand: .right)
        ],
        [
            KeySpec(id: "Tab", label: "⇥", widthWeight: 1.5, hand: .left),
            KeySpec(id: "Q", label: "Q", hand: .left),
            KeySpec(id: "W", label: "W", hand: .left),
            KeySpec(id: "E", label: "E", hand: .left),
            KeySpec(id: "R", label: "R", hand: .left),
            KeySpec(id: "T", label: "T", hand: .left),
            KeySpec(id: "Y", label: "Y", hand: .right),
            KeySpec(id: "U", label: "U", hand: .right),
            KeySpec(id: "I", label: "I", hand: .right),
            KeySpec(id: "O", label: "O", hand: .right),
            KeySpec(id: "P", label: "P", hand: .right),
            KeySpec(id: "[", label: "[", hand: .right),
            KeySpec(id: "]", label: "]", hand: .right),
            KeySpec(id: "\\", label: "\\", hand: .right)
        ],
        [
            KeySpec(id: "CapsLock", label: "⇪", widthWeight: 1.75, hand: .left),
            KeySpec(id: "A", label: "A", hand: .left),
            KeySpec(id: "S", label: "S", hand: .left),
            KeySpec(id: "D", label: "D", hand: .left),
            KeySpec(id: "F", label: "F", hand: .left),
            KeySpec(id: "G", label: "G", hand: .left),
            KeySpec(id: "H", label: "H", hand: .right),
            KeySpec(id: "J", label: "J", hand: .right),
            KeySpec(id: "K", label: "K", hand: .right),
            KeySpec(id: "L", label: "L", hand: .right),
            KeySpec(id: ";", label: ";", hand: .right),
            KeySpec(id: "'", label: "'", hand: .right),
            KeySpec(id: "Return", label: "↩", widthWeight: 1.75, hand: .right)
        ],
        [
            KeySpec(id: "LeftShift", label: "⇧", widthWeight: 2.25, hand: .left),
            KeySpec(id: "Z", label: "Z", hand: .left),
            KeySpec(id: "X", label: "X", hand: .left),
            KeySpec(id: "C", label: "C", hand: .left),
            KeySpec(id: "V", label: "V", hand: .left),
            KeySpec(id: "B", label: "B", hand: .left),
            KeySpec(id: "N", label: "N", hand: .right),
            KeySpec(id: "M", label: "M", hand: .right),
            KeySpec(id: ",", label: ",", hand: .right),
            KeySpec(id: ".", label: ".", hand: .right),
            KeySpec(id: "/", label: "/", hand: .right),
            KeySpec(id: "RightShift", label: "⇧", widthWeight: 2.25, hand: .right)
        ],
        [
            KeySpec(id: "Fn", label: "fn", widthWeight: 1.0, hand: .left),
            KeySpec(id: "Ctrl", label: "⌃", widthWeight: 1.0, hand: .left),
            KeySpec(id: "LeftOption", label: "⌥", widthWeight: 1.0, hand: .left),
            KeySpec(id: "LeftCmd", label: "⌘", widthWeight: 1.25, hand: .left),
            KeySpec(id: "Space", label: "space", widthWeight: 5.0, hand: .neutral),
            KeySpec(id: "RightCmd", label: "⌘", widthWeight: 1.25, hand: .right),
            KeySpec(id: "RightOption", label: "⌥", widthWeight: 1.0, hand: .right),
            KeySpec(id: "Left", label: "←", widthWeight: 0.95, hand: .right),
            KeySpec(id: "Up", label: "↑", widthWeight: 0.95, hand: .right),
            KeySpec(id: "Down", label: "↓", widthWeight: 0.95, hand: .right),
            KeySpec(id: "Right", label: "→", widthWeight: 0.95, hand: .right)
        ]
    ]

    private static let handByKeyID: [String: KeyHand] = {
        var map: [String: KeyHand] = [:]
        for row in ansiRows {
            for spec in row {
                map[spec.id] = spec.hand
            }
        }
        return map
    }()

    public static let ansiKeyIDs: Set<String> = {
        var set = Set<String>()
        for row in ansiRows {
            for spec in row {
                set.insert(spec.id)
            }
        }
        return set
    }()

    public static let recognizedKeyIDs: Set<String> = ansiKeyIDs.union([
        "Home", "End", "PageUp", "PageDown", "F13", "F14", "F15"
    ])

    private static let shiftLegends: [String: String] = [
        "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
        "6": "^", "7": "&", "8": "*", "9": "(", "0": ")", "-": "_",
        "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"",
        ",": "<", ".": ">", "/": "?"
    ]

    public static func shiftLegend(forKeyID keyID: String) -> String? {
        shiftLegends[keyID]
    }

    public static func hand(forKeyID keyID: String) -> KeyHand {
        handByKeyID[keyID] ?? .neutral
    }

    public static func keyName(forKeyCode keyCode: Int) -> String? {
        switch keyCode {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0, kVK_ANSI_Keypad0: return "0"
        case kVK_ANSI_1, kVK_ANSI_Keypad1: return "1"
        case kVK_ANSI_2, kVK_ANSI_Keypad2: return "2"
        case kVK_ANSI_3, kVK_ANSI_Keypad3: return "3"
        case kVK_ANSI_4, kVK_ANSI_Keypad4: return "4"
        case kVK_ANSI_5, kVK_ANSI_Keypad5: return "5"
        case kVK_ANSI_6, kVK_ANSI_Keypad6: return "6"
        case kVK_ANSI_7, kVK_ANSI_Keypad7: return "7"
        case kVK_ANSI_8, kVK_ANSI_Keypad8: return "8"
        case kVK_ANSI_9, kVK_ANSI_Keypad9: return "9"
        case kVK_ANSI_Grave: return "`"
        case kVK_ANSI_Minus, kVK_ANSI_KeypadMinus: return "-"
        case kVK_ANSI_Equal, kVK_ANSI_KeypadEquals: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period, kVK_ANSI_KeypadDecimal: return "."
        case kVK_ANSI_Slash, kVK_ANSI_KeypadDivide: return "/"
        case kVK_Space: return "Space"
        case kVK_Tab: return "Tab"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "Return"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "ForwardDelete"
        case kVK_Escape: return "Esc"
        case kVK_CapsLock: return "CapsLock"
        case kVK_LeftArrow: return "Left"
        case kVK_RightArrow: return "Right"
        case kVK_UpArrow: return "Up"
        case kVK_DownArrow: return "Down"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "PageUp"
        case kVK_PageDown: return "PageDown"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case 55: return "LeftCmd"
        case 54: return "RightCmd"
        case 56: return "LeftShift"
        case 60: return "RightShift"
        case 58: return "LeftOption"
        case 61: return "RightOption"
        case 59, 62: return "Ctrl"
        case 63, 179: return "Fn"
        default: return nil
        }
    }

    public static func activePhysicalModifierKeys(rawFlags: UInt64, keyCode: Int) -> [String] {
        let flags = CGEventFlags(rawValue: rawFlags)
        var mods: [String] = []

        if rawFlags & leftControlMask != 0 || rawFlags & rightControlMask != 0 || flags.contains(.maskControl) {
            mods.append("Ctrl")
        }
        if rawFlags & leftOptionMask != 0 {
            mods.append("LeftOption")
        } else if rawFlags & rightOptionMask != 0 {
            mods.append("RightOption")
        } else if flags.contains(.maskAlternate) {
            mods.append("LeftOption")
        }

        if rawFlags & leftShiftMask != 0 {
            mods.append("LeftShift")
        } else if rawFlags & rightShiftMask != 0 {
            mods.append("RightShift")
        } else if flags.contains(.maskShift) {
            mods.append("LeftShift")
        }

        if rawFlags & leftCommandMask != 0 {
            mods.append("LeftCmd")
        } else if rawFlags & rightCommandMask != 0 {
            mods.append("RightCmd")
        } else if flags.contains(.maskCommand) {
            mods.append("LeftCmd")
        }

        let isArrowOrNav = (123...126).contains(keyCode) || [115, 116, 119, 121, 117, 63, 179].contains(keyCode)
        if flags.contains(.maskSecondaryFn) && !isArrowOrNav {
            mods.append("Fn")
        }
        return mods
    }

    /// Formats chord shortcuts such as `⌘C`, `⇧⌘P`, `⌃C`, `⌥Space` (nil for ordinary typing or plain Shift+Letter).
    public static func formattedShortcut(baseKey: String, rawFlags: UInt64) -> String? {
        let flags = CGEventFlags(rawValue: rawFlags)
        let hasCtrl = flags.contains(.maskControl)
        let hasOpt = flags.contains(.maskAlternate)
        let hasCmd = flags.contains(.maskCommand)
        let hasShift = flags.contains(.maskShift)

        // Plain Shift + printable key is normal uppercase/punctuation typing, not a shortcut.
        guard hasCmd || hasCtrl || hasOpt else { return nil }
        let modifierIDs: Set<String> = ["LeftCmd", "RightCmd", "LeftShift", "RightShift", "LeftOption", "RightOption", "Ctrl", "Fn"]
        guard !modifierIDs.contains(baseKey) else { return nil }

        var symbols = ""
        if hasCtrl { symbols += "⌃" }
        if hasOpt { symbols += "⌥" }
        if hasShift { symbols += "⇧" }
        if hasCmd { symbols += "⌘" }
        return symbols + prettyKeyLabel(baseKey)
    }

    public static func prettyKeyLabel(_ keyID: String) -> String {
        switch keyID {
        case "Delete": return "⌫"
        case "ForwardDelete": return "⌦"
        case "Return": return "↩"
        case "Tab": return "⇥"
        case "Space": return "Space"
        case "Esc": return "⎋"
        case "Left": return "←"
        case "Right": return "→"
        case "Up": return "↑"
        case "Down": return "↓"
        case "LeftCmd", "RightCmd", "Cmd": return "⌘"
        case "LeftShift", "RightShift", "Shift": return "⇧"
        case "LeftOption", "RightOption", "Option": return "⌥"
        case "Ctrl": return "⌃"
        case "Fn": return "Fn"
        default: return keyID
        }
    }
}

/// Detects standalone modifier taps (e.g. tapping `Fn` or `LeftShift` to switch IME, or tapping `⌘`)
/// without double-counting modifiers used inside key chords like `⌘C`.
public struct StandaloneModifierTapTracker {
    private var armedModifiers: Set<String> = []

    public init() {}

    public mutating func consumeChordModifiers(rawFlags: UInt64, keyCode: Int) {
        for mod in KeyCodeMapper.activePhysicalModifierKeys(rawFlags: rawFlags, keyCode: keyCode) {
            armedModifiers.remove(mod)
        }
        let flags = CGEventFlags(rawValue: rawFlags)
        if flags.contains(.maskCommand) {
            armedModifiers.remove("LeftCmd")
            armedModifiers.remove("RightCmd")
        }
        if flags.contains(.maskShift) {
            armedModifiers.remove("LeftShift")
            armedModifiers.remove("RightShift")
        }
        if flags.contains(.maskAlternate) {
            armedModifiers.remove("LeftOption")
            armedModifiers.remove("RightOption")
        }
        if flags.contains(.maskControl) {
            armedModifiers.remove("Ctrl")
        }
        if flags.contains(.maskSecondaryFn) {
            armedModifiers.remove("Fn")
        }
    }

    public mutating func handleFlagsChanged(keyCode: Int, rawFlags: UInt64) -> String? {
        guard let keyID = KeyCodeMapper.keyName(forKeyCode: keyCode) else { return nil }
        let modifierSet: Set<String> = ["LeftCmd", "RightCmd", "LeftShift", "RightShift", "LeftOption", "RightOption", "Ctrl", "Fn"]
        guard modifierSet.contains(keyID) else { return nil }

        let currentlyHeld = isModifierCurrentlyPressed(keyID: keyID, rawFlags: rawFlags)
        if currentlyHeld {
            armedModifiers.insert(keyID)
            return nil
        } else if armedModifiers.remove(keyID) != nil {
            return keyID
        }
        return nil
    }

    public mutating func reset() {
        armedModifiers.removeAll()
    }

    private func isModifierCurrentlyPressed(keyID: String, rawFlags: UInt64) -> Bool {
        let flags = CGEventFlags(rawValue: rawFlags)
        switch keyID {
        case "LeftCmd":
            return (rawFlags & UInt64(NX_DEVICELCMDKEYMASK) != 0) || (flags.contains(.maskCommand) && (rawFlags & UInt64(NX_DEVICERCMDKEYMASK) == 0))
        case "RightCmd":
            return rawFlags & UInt64(NX_DEVICERCMDKEYMASK) != 0
        case "LeftShift":
            return (rawFlags & UInt64(NX_DEVICELSHIFTKEYMASK) != 0) || (flags.contains(.maskShift) && (rawFlags & UInt64(NX_DEVICERSHIFTKEYMASK) == 0))
        case "RightShift":
            return rawFlags & UInt64(NX_DEVICERSHIFTKEYMASK) != 0
        case "LeftOption":
            return (rawFlags & UInt64(NX_DEVICELALTKEYMASK) != 0) || (flags.contains(.maskAlternate) && (rawFlags & UInt64(NX_DEVICERALTKEYMASK) == 0))
        case "RightOption":
            return rawFlags & UInt64(NX_DEVICERALTKEYMASK) != 0
        case "Ctrl":
            return flags.contains(.maskControl)
        case "Fn":
            return flags.contains(.maskSecondaryFn)
        default:
            return false
        }
    }
}
