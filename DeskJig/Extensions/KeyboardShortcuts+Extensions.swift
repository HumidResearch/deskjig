//
//  KeyboardShortcuts+Extensions.swift
//  DeskJig
//

import KeyboardShortcuts
import Foundation
import DeskJigShared

extension KeyboardShortcuts.Name {
    static let showWorkspaceView = Self(
        "showWorkspaceView",
        default: .init(.k, modifiers: [.command])
    )
    static let quickSwitch = Self(
        "quickSwitch",
        default: .init(.w, modifiers: [.command, .shift])
    )
    static let moveWindowUp = Self(
        "moveWindowUp",
        default: .init(.upArrow, modifiers: [.control, .option])
    )
    static let moveWindowDown = Self(
        "moveWindowDown",
        default: .init(.downArrow, modifiers: [.control, .option])
    )
    static let moveWindowLeft = Self(
        "moveWindowLeft",
        default: .init(.leftArrow, modifiers: [.control, .option])
    )
    static let moveWindowRight = Self(
        "moveWindowRight",
        default: .init(.rightArrow, modifiers: [.control, .option])
    )
    static let moveWindowToLeftHalf = Self(
        "moveWindowToLeftHalf",
        default: .init(.leftArrow, modifiers: [.control, .command])
    )
    static let moveWindowToRightHalf = Self(
        "moveWindowToRightHalf",
        default: .init(.rightArrow, modifiers: [.control, .command])
    )
    static let moveWindowToTopHalf = Self(
        "moveWindowToTopHalf",
        default: .init(.upArrow, modifiers: [.control, .command])
    )
    static let moveWindowToBottomHalf = Self(
        "moveWindowToBottomHalf",
        default: .init(.downArrow, modifiers: [.control, .command])
    )
    static let moveWindowToLeftThird = Self("moveWindowToLeftThird")
    static let moveWindowToCenterThird = Self("moveWindowToCenterThird")
    static let moveWindowToRightThird = Self("moveWindowToRightThird")
    static let moveWindowToTopLeftQuarter = Self("moveWindowToTopLeftQuarter")
    static let moveWindowToTopRightQuarter = Self("moveWindowToTopRightQuarter")
    static let moveWindowToBottomLeftQuarter = Self("moveWindowToBottomLeftQuarter")
    static let moveWindowToBottomRightQuarter = Self("moveWindowToBottomRightQuarter")
    static let hideApp = Self(
        "hideApp",
        default: .init(.h, modifiers: [.command])
    )
    static let hideAllApps = Self(
        "hideAllApps",
        default: .init(.h, modifiers: [.command, .option])
    )
    static let showAllApps = Self(
        "showAllApps",
        default: .init(.h, modifiers: [.command, .option, .shift])
    )
    static let centerWindow = Self(
        "centerWindow",
        default: .init(.c, modifiers: [.control, .option])
    )
    static let maximizeWindow = Self(
        "maximizeWindow",
        default: .init(.m, modifiers: [.control, .option])
    )

    // Dynamic workspace shortcuts
    /// Creates a KeyboardShortcuts.Name for a specific workspace
    static func workspace(_ id: UUID) -> Self {
        Self("workspace_\(id.uuidString)")
    }
}

// MARK: - Workspace Keyboard Shortcut Conversion

extension WorkspaceKeyboardShortcut {
    /// Creates a WorkspaceKeyboardShortcut from a KeyboardShortcuts.Shortcut
    init?(from shortcut: KeyboardShortcuts.Shortcut) {
        // Convert Carbon key code to string representation
        guard let key = shortcut.key else { return nil }
        let keyString = key.stringValue

        // Convert modifiers to string array
        var modifierStrings: [String] = []
        if shortcut.modifiers.contains(.command) {
            modifierStrings.append("command")
        }
        if shortcut.modifiers.contains(.option) {
            modifierStrings.append("option")
        }
        if shortcut.modifiers.contains(.control) {
            modifierStrings.append("control")
        }
        if shortcut.modifiers.contains(.shift) {
            modifierStrings.append("shift")
        }

        self.init(key: keyString, modifiers: modifierStrings)
    }

    /// Converts to a KeyboardShortcuts.Shortcut
    func toShortcut() -> KeyboardShortcuts.Shortcut? {
        // Convert string to Carbon key code
        guard let carbonKey = KeyboardShortcuts.Key(stringValue: key) else {
            return nil
        }

        // Convert modifier strings to NSEvent.ModifierFlags
        var modifiers: NSEvent.ModifierFlags = []
        for modifier in self.modifiers {
            switch modifier.lowercased() {
            case "command":
                modifiers.insert(.command)
            case "option":
                modifiers.insert(.option)
            case "control":
                modifiers.insert(.control)
            case "shift":
                modifiers.insert(.shift)
            default:
                break
            }
        }

        return KeyboardShortcuts.Shortcut(carbonKey, modifiers: modifiers)
    }
}

extension KeyboardShortcuts.Key {
    /// String representation of the key
    var stringValue: String {
        // Common key mappings
        switch self.rawValue {
        case 0: return "a"
        case 1: return "s"
        case 2: return "d"
        case 3: return "f"
        case 4: return "h"
        case 5: return "g"
        case 6: return "z"
        case 7: return "x"
        case 8: return "c"
        case 9: return "v"
        case 11: return "b"
        case 12: return "q"
        case 13: return "w"
        case 14: return "e"
        case 15: return "r"
        case 16: return "y"
        case 17: return "t"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "equals"
        case 25: return "9"
        case 26: return "7"
        case 27: return "minus"
        case 28: return "8"
        case 29: return "0"
        case 30: return "rightBracket"
        case 31: return "o"
        case 32: return "u"
        case 33: return "leftBracket"
        case 34: return "i"
        case 35: return "p"
        case 36: return "return"
        case 37: return "l"
        case 38: return "j"
        case 39: return "quote"
        case 40: return "k"
        case 41: return "semicolon"
        case 42: return "backslash"
        case 43: return "comma"
        case 44: return "slash"
        case 45: return "n"
        case 46: return "m"
        case 47: return "period"
        case 48: return "tab"
        case 49: return "space"
        case 50: return "grave"
        case 51: return "delete"
        case 53: return "escape"
        case 123: return "leftArrow"
        case 124: return "rightArrow"
        case 125: return "downArrow"
        case 126: return "upArrow"
        default: return "key\(self.rawValue)"
        }
    }

    /// Creates a Key from a string value
    init?(stringValue: String) {
        switch stringValue.lowercased() {
        case "a": self = .init(rawValue: 0)
        case "s": self = .init(rawValue: 1)
        case "d": self = .init(rawValue: 2)
        case "f": self = .init(rawValue: 3)
        case "h": self = .init(rawValue: 4)
        case "g": self = .init(rawValue: 5)
        case "z": self = .init(rawValue: 6)
        case "x": self = .init(rawValue: 7)
        case "c": self = .init(rawValue: 8)
        case "v": self = .init(rawValue: 9)
        case "b": self = .init(rawValue: 11)
        case "q": self = .init(rawValue: 12)
        case "w": self = .init(rawValue: 13)
        case "e": self = .init(rawValue: 14)
        case "r": self = .init(rawValue: 15)
        case "y": self = .init(rawValue: 16)
        case "t": self = .init(rawValue: 17)
        case "1": self = .init(rawValue: 18)
        case "2": self = .init(rawValue: 19)
        case "3": self = .init(rawValue: 20)
        case "4": self = .init(rawValue: 21)
        case "6": self = .init(rawValue: 22)
        case "5": self = .init(rawValue: 23)
        case "equals", "=": self = .init(rawValue: 24)
        case "9": self = .init(rawValue: 25)
        case "7": self = .init(rawValue: 26)
        case "minus", "-": self = .init(rawValue: 27)
        case "8": self = .init(rawValue: 28)
        case "0": self = .init(rawValue: 29)
        case "rightbracket", "]": self = .init(rawValue: 30)
        case "o": self = .init(rawValue: 31)
        case "u": self = .init(rawValue: 32)
        case "leftbracket", "[": self = .init(rawValue: 33)
        case "i": self = .init(rawValue: 34)
        case "p": self = .init(rawValue: 35)
        case "return", "enter": self = .init(rawValue: 36)
        case "l": self = .init(rawValue: 37)
        case "j": self = .init(rawValue: 38)
        case "quote", "'": self = .init(rawValue: 39)
        case "k": self = .init(rawValue: 40)
        case "semicolon", ";": self = .init(rawValue: 41)
        case "backslash", "\\": self = .init(rawValue: 42)
        case "comma", ",": self = .init(rawValue: 43)
        case "slash", "/": self = .init(rawValue: 44)
        case "n": self = .init(rawValue: 45)
        case "m": self = .init(rawValue: 46)
        case "period", ".": self = .init(rawValue: 47)
        case "tab": self = .init(rawValue: 48)
        case "space": self = .init(rawValue: 49)
        case "grave", "`": self = .init(rawValue: 50)
        case "delete", "backspace": self = .init(rawValue: 51)
        case "escape", "esc": self = .init(rawValue: 53)
        case "leftarrow", "left": self = .init(rawValue: 123)
        case "rightarrow", "right": self = .init(rawValue: 124)
        case "downarrow", "down": self = .init(rawValue: 125)
        case "uparrow", "up": self = .init(rawValue: 126)
        default:
            // Try to parse "key123" format
            if stringValue.hasPrefix("key"), let rawValue = Int(stringValue.dropFirst(3)) {
                self = .init(rawValue: rawValue)
            } else {
                return nil
            }
        }
    }
}
