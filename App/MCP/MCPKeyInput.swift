import Foundation
import JetKVMProtocol

/// Key combo parsing and character-to-keycode mapping for MCP tool use.
/// All lookups use macOS Carbon virtual keycodes (`UInt16`) to match
/// what `Session.sendKeypress` expects.
enum MCPKeyInput {
    // Reverse of WebKeyMap: lowercase W3C code → macOS virtual keycode.
    // Built once at first use.
    static let webCodeToVirtualKey: [String: UInt16] = {
        var d: [String: UInt16] = [:]
        for (kc, code) in WebKeyMap.virtualKeyToWebCode {
            d[code.lowercased()] = kc
        }
        return d
    }()

    // Modifier word (lowercase) → left-side virtual keycode
    static let modifierWords: [String: UInt16] = [
        "ctrl": 0x3B, "control": 0x3B,
        "shift": 0x38,
        "alt": 0x3A, "option": 0x3A,
        "cmd": 0x37, "command": 0x37, "meta": 0x37, "win": 0x37, "super": 0x37,
    ]

    // Friendly name (lowercase) → lowercase W3C code for webCodeToVirtualKey lookup
    static let keyAliases: [String: String] = [
        "enter": "enter", "return": "enter",
        "space": "space",
        "tab": "tab",
        "backspace": "backspace",
        "delete": "delete", "del": "delete",
        "escape": "escape", "esc": "escape",
        "up": "arrowup", "arrowup": "arrowup",
        "down": "arrowdown", "arrowdown": "arrowdown",
        "left": "arrowleft", "arrowleft": "arrowleft",
        "right": "arrowright", "arrowright": "arrowright",
        "pageup": "pageup", "pgup": "pageup",
        "pagedown": "pagedown", "pgdn": "pagedown",
        "home": "home", "end": "end",
        "f1": "f1", "f2": "f2", "f3": "f3", "f4": "f4",
        "f5": "f5", "f6": "f6", "f7": "f7", "f8": "f8",
        "f9": "f9", "f10": "f10", "f11": "f11", "f12": "f12",
        "capslock": "capslock",
        "insert": "insert",
        "numlock": "numlock",
    ]

    /// Parse a combo string like "ctrl+c", "cmd+shift+s", "enter", "f5"
    /// into (modifiers, mainKey) as macOS virtual keycodes.
    /// For modifier-only combos (e.g. "shift") returns ([], shiftKeyCode).
    static func parseCombo(_ combo: String) throws -> (modifiers: [UInt16], key: UInt16) {
        let parts = combo.lowercased()
            .split(separator: "+", omittingEmptySubsequences: true)
            .map(String.init)
        var modifiers: [UInt16] = []
        var mainKey: UInt16? = nil

        for part in parts {
            if let mod = modifierWords[part] {
                if !modifiers.contains(mod) { modifiers.append(mod) }
            } else {
                let w3c = resolveKeyName(part)
                guard let kc = webCodeToVirtualKey[w3c] else {
                    throw MCPToolError.unknown("Unknown key '\(part)' in combo '\(combo)'")
                }
                mainKey = kc
            }
        }

        if let kc = mainKey { return (modifiers, kc) }
        // Modifier-only: treat first modifier as the key (e.g. "shift" alone)
        guard let first = modifiers.first else {
            throw MCPToolError.unknown("Empty key combo '\(combo)'")
        }
        return ([], first)
    }

    /// Normalize a key name part to a lowercase W3C code string.
    private static func resolveKeyName(_ part: String) -> String {
        if let alias = keyAliases[part] { return alias }
        // Single letter: "a" → "keya"
        if part.count == 1, let c = part.first, c.isLetter { return "key\(c)" }
        // Single digit: "1" → "digit1"
        if part.count == 1, let c = part.first, c.isNumber { return "digit\(c)" }
        return part
    }

    // US QWERTY: Character → (virtualKeyCode, needsShift).
    // Covers printable ASCII for use by the `type` tool.
    static let charKeyMap: [Character: (UInt16, Bool)] = {
        var m: [Character: (UInt16, Bool)] = [:]

        let letters: [(Character, UInt16)] = [
            ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04),
            ("g", 0x05), ("z", 0x06), ("x", 0x07), ("c", 0x08), ("v", 0x09),
            ("b", 0x0B), ("q", 0x0C), ("w", 0x0D), ("e", 0x0E), ("r", 0x0F),
            ("y", 0x10), ("t", 0x11), ("o", 0x1F), ("u", 0x20), ("i", 0x22),
            ("p", 0x23), ("l", 0x25), ("j", 0x26), ("k", 0x28), ("n", 0x2D),
            ("m", 0x2E),
        ]
        for (ch, kc) in letters {
            m[ch] = (kc, false)
            m[Character(ch.uppercased())] = (kc, true)
        }

        let digits: [(Character, UInt16)] = [
            ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15), ("6", 0x16),
            ("5", 0x17), ("9", 0x19), ("7", 0x1A), ("8", 0x1C), ("0", 0x1D),
        ]
        for (ch, kc) in digits { m[ch] = (kc, false) }

        let unshifted: [(Character, UInt16)] = [
            ("=", 0x18), ("-", 0x1B), ("]", 0x1E), ("[", 0x21), ("'", 0x27),
            (";", 0x29), ("\\", 0x2A), (",", 0x2B), ("/", 0x2C), (".", 0x2F),
            ("\t", 0x30), (" ", 0x31), ("`", 0x32), ("\r", 0x24), ("\n", 0x24),
        ]
        for (ch, kc) in unshifted { m[ch] = (kc, false) }

        let shifted: [(Character, UInt16)] = [
            ("!", 0x12), ("@", 0x13), ("#", 0x14), ("$", 0x15), ("^", 0x16),
            ("%", 0x17), ("(", 0x19), ("&", 0x1A), ("*", 0x1C), (")", 0x1D),
            ("+", 0x18), ("_", 0x1B), ("}", 0x1E), ("{", 0x21), ("\"", 0x27),
            (":", 0x29), ("|", 0x2A), ("<", 0x2B), ("?", 0x2C), (">", 0x2F),
            ("~", 0x32),
        ]
        for (ch, kc) in shifted { m[ch] = (kc, true) }

        return m
    }()
}
