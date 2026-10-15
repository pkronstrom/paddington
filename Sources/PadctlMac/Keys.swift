import ApplicationServices
import Carbon.HIToolbox
import Foundation
import PadctlCore

/// Synthetic keyboard events (needs Accessibility permission).
public enum Keyboard {
    static let codes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "backspace": kVK_Delete, "delete": kVK_ForwardDelete,
        "esc": kVK_Escape, "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "comma": kVK_ANSI_Comma, ",": kVK_ANSI_Comma,
        "period": kVK_ANSI_Period, ".": kVK_ANSI_Period, "slash": kVK_ANSI_Slash, "/": kVK_ANSI_Slash,
        "minus": kVK_ANSI_Minus, "-": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "=": kVK_ANSI_Equal,
        "grave": kVK_ANSI_Grave, "`": kVK_ANSI_Grave, "semicolon": kVK_ANSI_Semicolon, ";": kVK_ANSI_Semicolon,
        "quote": kVK_ANSI_Quote, "'": kVK_ANSI_Quote, "backslash": kVK_ANSI_Backslash, "\\": kVK_ANSI_Backslash,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7,
        "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        // modifier keys themselves (for passthrough holds)
        "rightcmd": kVK_RightCommand, "cmd": kVK_Command, "leftcmd": kVK_Command,
        "rightalt": kVK_RightOption, "alt": kVK_Option, "rightshift": kVK_RightShift, "shift": kVK_Shift,
        "rightctrl": kVK_RightControl, "ctrl": kVK_Control, "fn": kVK_Function,
    ]

    static let modifierKeyFlags: [String: CGEventFlags] = [
        "rightcmd": .maskCommand, "cmd": .maskCommand, "leftcmd": .maskCommand,
        "rightalt": .maskAlternate, "alt": .maskAlternate, "rightshift": .maskShift, "shift": .maskShift,
        "rightctrl": .maskControl, "ctrl": .maskControl, "fn": .maskSecondaryFn,
    ]

    static func flags(_ mods: Set<String>) -> CGEventFlags {
        var f = CGEventFlags()
        if mods.contains("cmd") { f.insert(.maskCommand) }
        if mods.contains("shift") { f.insert(.maskShift) }
        if mods.contains("alt") { f.insert(.maskAlternate) }
        if mods.contains("ctrl") { f.insert(.maskControl) }
        if mods.contains("fn") { f.insert(.maskSecondaryFn) }
        return f
    }

    public static func isKnown(_ k: KeyChord) -> Bool { resolve(k) != nil }

    /// Modifier flags padctl currently holds down (passthrough), so other synthetic keys don't drop them.
    static var heldFlags = CGEventFlags()

    /// Character keys resolve through the *current* keyboard layout (so "+" or "[" work on a Finnish
    /// layout too); named keys (enter, esc, arrows, F-keys, modifiers) use fixed key codes.
    static let charNames: [String: Character] = ["plus": "+", "minus": "-", "equal": "=", "comma": ",", "period": ".",
                                                 "slash": "/", "grave": "`", "semicolon": ";", "quote": "'", "backslash": "\\"]
    static let layoutLock = NSLock()
    static var layoutId = ""
    static var layoutMap: [Character: (CGKeyCode, CGEventFlags)] = [:]

    static func resolve(_ k: KeyChord) -> (CGKeyCode, CGEventFlags)? {
        let ch: Character? = charNames[k.key] ?? (k.key.count == 1 ? Character(k.key) : nil)
        if let ch, let hit = layoutLookup(ch) { return hit }
        return codes[k.key].map { (CGKeyCode($0), CGEventFlags()) }
    }

    /// The current layout's id and key-layout data. Text Input Sources may only be read on the main
    /// thread (macOS kills the app otherwise), and keys are sent from the executor's queue.
    static func currentLayout() -> (id: String, data: Data?, kbd: UInt32)? {
        let read = { () -> (id: String, data: Data?, kbd: UInt32)? in
            guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
            let id = TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
                .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? ""
            let data = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
                .map { Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue() as Data }
            return (id, data, UInt32(LMGetKbdType()))
        }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    static func layoutLookup(_ ch: Character) -> (CGKeyCode, CGEventFlags)? {
        guard let (id, layoutData, kbd) = currentLayout() else { return nil }
        layoutLock.lock(); defer { layoutLock.unlock() }
        if id != layoutId {
            layoutId = id; layoutMap = [:]
            guard let data = layoutData else { return nil }
            data.withUnsafeBytes { raw in
                guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
                let states: [(UInt32, CGEventFlags)] = [(0, []), (UInt32(shiftKey >> 8), .maskShift),
                                                        (UInt32(optionKey >> 8), .maskAlternate),
                                                        (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate])]
                for (mods, flags) in states {
                    for code in 0..<128 {
                        var dead: UInt32 = 0, len = 0
                        var chars = [UniChar](repeating: 0, count: 4)
                        UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), mods, kbd,
                                       OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                        guard len == 1, let s = String(utf16CodeUnits: chars, count: 1).first else { continue }
                        if layoutMap[s] == nil { layoutMap[s] = (CGKeyCode(code), flags) }
                    }
                }
            }
        }
        return layoutMap[ch]
    }

    public static func press(_ k: KeyChord) throws {
        // a bare modifier ("alt", "rightcmd") is a tap of that modifier key: flagsChanged down + up
        if k.modifiers.isEmpty, modifierKeyFlags[k.key] != nil {
            try modifierEvent(k, down: true); usleep(15_000); try modifierEvent(k, down: false); return
        }
        guard let (code, extra) = resolve(k) else { throw KeyError("unknown key '\(k.key)'") }
        let src = CGEventSource(stateID: .hidSystemState)
        let f = flags(k.modifiers).union(heldFlags).union(extra)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = f
            e.post(tap: .cghidEventTap)
        }
    }

    /// Hold a key down (modifier keys produce flagsChanged events, like a real keyboard).
    public static func down(_ k: KeyChord) throws { try modifierEvent(k, down: true) }
    public static func up(_ k: KeyChord) throws { try modifierEvent(k, down: false) }

    static func modifierEvent(_ k: KeyChord, down: Bool) throws {
        guard let code = codes[k.key] else { throw KeyError("unknown key '\(k.key)'") }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down) else { return }
        if let mf = modifierKeyFlags[k.key] {
            if down { heldFlags.insert(mf) } else { heldFlags.remove(mf) }
            e.type = .flagsChanged
            // device-dependent bits distinguish right from left modifiers
            var raw = heldFlags.rawValue
            if down {
                switch k.key {
                case "rightcmd": raw |= 0x10
                case "cmd", "leftcmd": raw |= 0x08
                case "rightalt": raw |= 0x40
                case "alt": raw |= 0x20
                case "rightshift": raw |= 0x04
                case "shift": raw |= 0x02
                case "rightctrl": raw |= 0x2000
                case "ctrl": raw |= 0x01
                default: break
                }
            }
            e.flags = CGEventFlags(rawValue: raw)
        } else {
            e.flags = flags(k.modifiers).union(heldFlags)
        }
        e.post(tap: .cghidEventTap)
    }

    /// Type text as Unicode, in chunks (CGEvent caps the string length per event).
    public static func type(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.offset > 0 { try? press(KeyChord(modifiers: [], key: "enter")) }
            let utf16 = Array(String(line.element).utf16)
            var i = 0
            while i < utf16.count {
                let chunk = Array(utf16[i..<min(i + 16, utf16.count)])
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                    chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                    e.post(tap: .cghidEventTap)
                }
                i += 16
            }
        }
    }

    /// tmux key name for `send-keys` (without -l).
    public static func tmuxName(_ k: KeyChord) -> String? {
        let base: String
        switch k.key {
        case "enter": base = "Enter"
        case "esc": base = "Escape"
        case "tab": base = k.modifiers == ["shift"] ? "BTab" : "Tab"
        case "space": base = "Space"
        case "backspace": base = "BSpace"
        case "delete": base = "DC"
        case "up": base = "Up"
        case "down": base = "Down"
        case "left": base = "Left"
        case "right": base = "Right"
        case "home": base = "Home"
        case "end": base = "End"
        case "pageup": base = "PPage"
        case "pagedown": base = "NPage"
        case let f where f.hasPrefix("f") && Int(f.dropFirst()) != nil: base = f.uppercased()
        case "comma": base = ","
        case "period": base = "."
        case "minus": base = "-"
        case "equal": base = "="
        case "slash": base = "/"
        case "grave": base = "`"
        default:
            guard k.key.count == 1 else { return nil }
            base = k.key
        }
        if base == "BTab" { return base }
        var prefix = ""
        if k.modifiers.contains("ctrl") { prefix += "C-" }
        if k.modifiers.contains("alt") { prefix += "M-" }
        if k.modifiers.contains("shift") && base.count > 1 { prefix += "S-" }
        if k.modifiers.contains("cmd") { return nil }   // terminals don't receive ⌘ chords
        let key = k.modifiers.contains("shift") && base.count == 1 ? base.uppercased() : base
        return prefix + key
    }
}

public struct KeyError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}
