import Foundation

// MARK: - Keys

public struct KeyChord: Equatable, CustomStringConvertible {
    public var modifiers: Set<String>   // cmd, shift, alt, ctrl, fn
    public var key: String              // normalized lower-case name: "a", "enter", "esc", "tab", "up", "f5", "rightcmd"
    public var description: String { (modifiers.sorted() + [key]).joined(separator: "+") }
    public init(modifiers: Set<String>, key: String) { self.modifiers = modifiers; self.key = key }

    static let modAliases = ["cmd": "cmd", "command": "cmd", "⌘": "cmd", "shift": "shift", "⇧": "shift",
                             "alt": "alt", "opt": "alt", "option": "alt", "⌥": "alt",
                             "ctrl": "ctrl", "control": "ctrl", "⌃": "ctrl", "fn": "fn"]
    static let keyAliases = ["return": "enter", "escape": "esc", "bksp": "backspace", "del": "delete",
                             "pgup": "pageup", "pgdn": "pagedown", "space": "space", "spc": "space"]

    /// "cmd+shift+t" → one chord. A bare "+" key is written "plus".
    public static func parse(_ s: String) throws -> KeyChord {
        let parts = s.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last, !last.isEmpty else { throw ExprError("empty key in '\(s)'") }
        var mods = Set<String>()
        for p in parts.dropLast() {
            guard let m = modAliases[p] else { throw ExprError("unknown modifier '\(p)' in '\(s)'") }
            mods.insert(m)
        }
        var key = keyAliases[last] ?? last
        if key == "plus" { key = "+" }
        return KeyChord(modifiers: mods, key: key)
    }

    /// "esc esc" or "cmd+k up" → a sequence of chords.
    public static func parseSequence(_ s: String) throws -> [KeyChord] {
        try s.split(separator: " ").map { try parse(String($0)) }
    }
}

// MARK: - Actions

public enum Activation: String { case hold, toggle, oneshot, `switch`, modal }

public enum Target: String { case pane, app }

public indirect enum Action: Equatable {
    case keys([KeyChord])
    case text(String)
    case tmux([String])
    case exec([String])
    case open(String)
    case shortcut(String)
    case menu([String])
    case script(String)
    case prompt(String)
    case layer(String, Activation, timeout: Double?)
    case agent(String)              // built-in agent actions: next_waiting, visit
    case mode(String)               // next | prev
    case setState(String, Value)
    case toast(String)
    case wait(Double)
    case seq([Action])
    case legend(String)             // show (while held) | pin
    case picker(String)             // open a picker (knob scrolls, ▶ commits, ⏸ cancels)
    case search(String)             // open a picker with a search box: type or dictate (hold ●) to filter
    case answer(Int)                // pick option N of the agent's question
    case window(String)             // next | prev window of the frontmost app (Accessibility, layout-independent)
    case input(String, Action)      // ask for text (dictate with ●), then run the action with {input}

    static let keysNames = ["keys", "text", "tmux", "exec", "open", "shortcut", "menu", "script", "prompt",
                            "layer", "agent", "mode", "set", "toast", "wait", "seq", "legend", "picker", "answer", "window", "input", "search"]

    /// Parse the single action key present in a binding table. Returns nil if none.
    public static func parse(_ t: [String: Value], ctx: String) throws -> Action? {
        let present = keysNames.filter { t[$0] != nil }
        if present.isEmpty { return nil }
        if present.count > 1 { throw ExprError("\(ctx): more than one action (\(present.joined(separator: ", ")))") }
        let k = present[0], v = t[k]!
        func str() throws -> String {
            guard let s = v.string else { throw ExprError("\(ctx): '\(k)' must be a string") }
            return s
        }
        func list() throws -> [String] {
            if let a = v.array {
                let s = a.compactMap { $0.string ?? ($0.number.map { Value.number($0).description }) }
                guard s.count == a.count else { throw ExprError("\(ctx): '\(k)' must be a list of strings") }
                return s
            }
            if let s = v.string { return splitArgs(s) }
            throw ExprError("\(ctx): '\(k)' must be a string or a list")
        }
        switch k {
        case "keys": return .keys(try KeyChord.parseSequence(try str()))
        case "text": return .text(try str())
        case "tmux": return .tmux(try list())
        case "exec":
            guard v.array != nil else { throw ExprError("\(ctx): 'exec' must be a list (program + arguments)") }
            return .exec(try list())
        case "open": return .open(try str())
        case "shortcut": return .shortcut(try str())
        case "menu":
            guard let a = v.array?.compactMap(\.string), !a.isEmpty else { throw ExprError("\(ctx): 'menu' must be a list of menu titles") }
            return .menu(a)
        case "script": return .script(try str())
        case "prompt": return .prompt(try str())
        case "layer":
            let act = try t["activate"]?.string.map {
                guard let a = Activation(rawValue: $0) else { throw ExprError("\(ctx): unknown activate '\($0)'") }
                return a
            } ?? .toggle
            return .layer(try str(), act, timeout: t["timeout"].flatMap(parseDuration))
        case "agent": return .agent(try str())
        case "mode": return .mode(try str())
        case "set":
            guard let tt = v.table, tt.count == 1, let (key, val) = tt.first else { throw ExprError("\(ctx): 'set' must be { key = value }") }
            return .setState(key, val)
        case "toast": return .toast(try str())
        case "picker": return .picker(try str())
        case "search": return .search(try str())
        case "input":
            guard let rt = t["run"]?.table, let then = try Action.parse(rt, ctx: "\(ctx).run") else {
                throw ExprError("\(ctx): input needs run = { <action using {input}> }")
            }
            return .input(try str(), then)
        case "window":
            let s = try str()
            guard s == "next" || s == "prev" else { throw ExprError("\(ctx): window must be \"next\" or \"prev\"") }
            return .window(s)
        case "answer":
            guard let n = v.int, n >= 1 else { throw ExprError("\(ctx): answer must be an option number") }
            return .answer(n)
        case "legend":
            let s = try str()
            guard s == "show" || s == "pin" else { throw ExprError("\(ctx): legend must be \"show\" or \"pin\"") }
            return .legend(s)
        case "wait":
            guard let d = parseDuration(v) else { throw ExprError("\(ctx): bad duration") }
            return .wait(d)
        case "seq":
            guard let a = v.array else { throw ExprError("\(ctx): 'seq' must be a list of actions") }
            return .seq(try a.enumerated().map { i, item in
                guard let it = item.table, let act = try Action.parse(it, ctx: "\(ctx).seq[\(i)]") else {
                    throw ExprError("\(ctx).seq[\(i)]: not an action")
                }
                return act
            })
        default: return nil
        }
    }
}

/// "500ms", "1.5s", "2m", or a bare number of seconds.
public func parseDuration(_ v: Value) -> Double? {
    if let n = v.number { return n }
    guard var s = v.string?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
    var mult = 1.0
    if s.hasSuffix("ms") { mult = 0.001; s.removeLast(2) }
    else if s.hasSuffix("s") { s.removeLast() }
    else if s.hasSuffix("m") { mult = 60; s.removeLast() }
    return Double(s).map { $0 * mult }
}

/// Split "a b 'c d'" into ["a", "b", "c d"] — for tmux strings only; exec requires a list.
public func splitArgs(_ s: String) -> [String] {
    var out: [String] = [], cur = "", quote: Character? = nil, has = false
    for c in s {
        if let q = quote { if c == q { quote = nil } else { cur.append(c) }; continue }
        if c == "'" || c == "\"" { quote = c; has = true; continue }
        if c == " " { if has || !cur.isEmpty { out.append(cur); cur = ""; has = false }; continue }
        cur.append(c)
    }
    if has || !cur.isEmpty { out.append(cur) }
    return out
}

// MARK: - Bindings, looks, layers

public struct LookRule: Equatable {
    public var condition: Expr?
    public var color: String?
    public var blink: Bool
    public var label: String?
}

public struct Look: Equatable { public var rules: [LookRule] }

public struct Binding: Equatable {
    public var label: String?
    public var color: String?
    public var look: String?
    public var params: [String: Value]   // e.g. win = 2 for built-in looks
    public var action: Action?
    public var hold: Action?             // when set, a short press runs `action`, a long press runs `hold`
    public var confirmHold: Bool         // action only runs after holding confirm_hold_ms
    public var passthrough: KeyChord?    // mirror press/release to this key
    public var cw: Action?
    public var ccw: Action?
    public var accel: Bool
    public var target: Target?
    public var description: String?
    public var then: String?             // enter this modal layer after the action
    public var thenSteps = 1             // …and leave it after this many exit presses
    public var condition: Expr?          // binding only applies while this is true
    public var sound: String?            // sound name ("" = silent); default comes from the colour category
    public var holdTime: Double?         // seconds before `hold` fires (default: timing.hold)
    public var with: [String: Action] = [:]   // chords: while control X is held, this press runs with[X] instead
    public var step = 1                  // knobs: turn units per move (higher = less sensitive)
    public var whenEmpty: [Binding] = [] // window pads (win = N): the binding used while window N doesn't exist (0 or 1)

    static let reserved: Set<String> = ["label", "color", "look", "hold", "confirm", "passthrough", "cw", "ccw",
                                        "repeat", "to", "activate", "timeout", "desc", "win", "then", "then_steps", "if", "sound", "hold_time", "empty", "with", "step"]

    /// An empty binding (used to run picker commits through the normal planner).
    public static func parseBare() -> Binding {
        Binding(label: nil, color: nil, look: nil, params: [:], action: nil, hold: nil, confirmHold: false,
                passthrough: nil, cw: nil, ccw: nil, accel: false, target: nil, description: nil)
    }

    public static func parse(_ v: Value, ctx: String) throws -> Binding {
        guard let t = v.table else { throw ExprError("\(ctx): binding must be a table") }
        var b = Binding(label: t["label"]?.string, color: t["color"]?.string, look: t["look"]?.string,
                        params: [:], action: nil, hold: nil, confirmHold: t["confirm"]?.string == "hold",
                        passthrough: nil, cw: nil, ccw: nil, accel: t["repeat"]?.string == "accel",
                        target: t["to"]?.string.flatMap(Target.init(rawValue:)), description: t["desc"]?.string)
        b.then = t["then"]?.string
        b.sound = t["sound"]?.string
        b.holdTime = t["hold_time"].flatMap(parseDuration)
        b.step = max(1, t["step"]?.int ?? 1)
        for (held, v) in t["with"]?.table ?? [:] {
            guard let at = v.table, let a = try Action.parse(at, ctx: "\(ctx).with.\(held)") else {
                throw ExprError("\(ctx): with.\(held) must be { <action> }")
            }
            b.with[held] = a
        }
        b.thenSteps = t["then_steps"]?.int ?? 1
        if let c = t["if"]?.string { b.condition = try Expr.parse(c) }
        if let w = t["win"] { b.params["win"] = w }
        if let e = t["empty"] {
            guard t["win"] != nil else { throw ExprError("\(ctx): empty = { … } needs win = N") }
            b.whenEmpty = [try Binding.parse(e, ctx: "\(ctx).empty")]
        }
        if let c = t["confirm"]?.string, c != "hold" { throw ExprError("\(ctx): confirm must be \"hold\" in phase 1") }
        if let p = t["passthrough"]?.string { b.passthrough = try KeyChord.parse(p) }
        // knob shorthand: keys = { cw = "down", ccw = "up" }
        if let kt = t["keys"]?.table {
            if let cw = kt["cw"]?.string { b.cw = .keys(try KeyChord.parseSequence(cw)) }
            if let ccw = kt["ccw"]?.string { b.ccw = .keys(try KeyChord.parseSequence(ccw)) }
            var rest = t; rest["keys"] = nil
            b.action = try Action.parse(rest, ctx: ctx)
        } else {
            b.action = try Action.parse(t, ctx: ctx)
        }
        if let cw = t["cw"] {
            guard let ct = cw.table else { throw ExprError("\(ctx).cw must be an action table") }
            b.cw = try Action.parse(ct, ctx: "\(ctx).cw")
        }
        if let ccw = t["ccw"] {
            guard let ct = ccw.table else { throw ExprError("\(ctx).ccw must be an action table") }
            b.ccw = try Action.parse(ct, ctx: "\(ctx).ccw")
        }
        if let h = t["hold"] {
            guard let ht = h.table, let a = try Action.parse(ht, ctx: "\(ctx).hold") else {
                throw ExprError("\(ctx).hold must be an action table")
            }
            b.hold = a
        }
        return b
    }
}

public enum LayerKind: String { case base, temporary, modal }

public struct When: Equatable {
    public var apps: [String]
    public var tmuxCmd: [String]
    public var window: String?
    /// tmux_cmd = ["*"] matches any tmux pane; a named command is more specific.
    public var specificity: Int {
        (apps.isEmpty ? 0 : 1) + (tmuxCmd.isEmpty ? 0 : (tmuxCmd == ["*"] ? 1 : 3)) + (window == nil ? 0 : 1)
    }
    public var usesTmux: Bool { !tmuxCmd.isEmpty }
}

public struct Layer {
    public var id: String
    public var name: String
    public var kind: LayerKind
    public var color: String
    public var extends: String?
    public var priority: Int
    public var when: When?
    public var bindings: [String: Binding]
    public var shift: [String: Binding]
    public var looks: [String: Look]
    public var dir: URL
    public var file: String
    public var auto: Expr?               // modal layers: active while this is true (e.g. the agent asks)
    public var exit: [String] = []       // modal layers: controls that count down `steps`, then end the layer
    public var cancel: [String] = []     // modal layers: controls that end it at once
    public var steps = 1
    public var timeout: Double?
}

extension Layer {
    static let reservedKeys: Set<String> = ["name", "kind", "color", "extends", "priority", "when", "shift", "looks", "agent", "id", "auto", "exit", "steps", "timeout", "cancel"]

    public static func parse(_ t: [String: Value], id: String, dir: URL, file: String) throws -> Layer {
        func err(_ m: String) -> ConfigError { ConfigError(file: file, m) }
        let kindStr = t["kind"]?.string ?? (t["when"] != nil || id == "default" ? "base" : "temporary")
        guard let kind = LayerKind(rawValue: kindStr) else { throw err("unknown kind '\(kindStr)'") }
        var when: When?
        if let w = t["when"]?.table {
            when = When(apps: w["app"]?.stringList ?? [], tmuxCmd: w["tmux_cmd"]?.stringList ?? [], window: w["window"]?.string)
        }
        var bindings: [String: Binding] = [:], shift: [String: Binding] = [:], looks: [String: Look] = [:]
        do {
            for (k, v) in t where !reservedKeys.contains(k) {
                bindings[k] = try Binding.parse(v, ctx: k)
            }
            for (k, v) in t["shift"]?.table ?? [:] { shift[k] = try Binding.parse(v, ctx: "shift.\(k)") }
            for (name, v) in t["looks"]?.table ?? [:] {
                guard let rules = v["rules"]?.array else { throw ExprError("looks.\(name) needs rules = [...]") }
                looks[name] = Look(rules: try rules.map { r in
                    guard let rt = r.table else { throw ExprError("looks.\(name): rule must be a table") }
                    return LookRule(condition: try rt["if"]?.string.map(Expr.parse), color: rt["color"]?.string,
                                    blink: rt["blink"]?.bool ?? false, label: rt["label"]?.string)
                })
            }
        } catch let e as ExprError { throw err(e.description) }
        var l = Layer(id: id, name: t["name"]?.string ?? id, kind: kind, color: t["color"]?.string ?? "#888888",
                      extends: t["extends"]?.string, priority: t["priority"]?.int ?? 0, when: when,
                      bindings: bindings, shift: shift, looks: looks, dir: dir, file: file)
        do { l.auto = try t["auto"]?.string.map(Expr.parse) } catch let e as ExprError { throw err("auto: \(e)") }
        l.exit = t["exit"]?.stringList ?? []
        l.cancel = t["cancel"]?.stringList ?? []
        l.steps = t["steps"]?.int ?? 1
        l.timeout = t["timeout"].flatMap(parseDuration)
        return l
    }
}

// MARK: - App config

public struct Settings {
    public var device: String = "m-vave-smc-pad"
    public var roles: [String: String] = [:]
    public var padBankB = "shift"          // what pad bank B means: "shift" (each layer's [shift]) or "default"
    public var colors: [String: String] = Settings.defaultColors
    public var holdMs: Double = 450
    public var confirmHoldMs: Double = 1000
    public var legendHoldMs: Double = 250    // hold ▶ this long to show the legend (shorter than other holds)
    public var legendPinSeconds: Double = 8
    public var passthroughLimitSeconds: Double = 300
    public var legendPosition: String = "bottom-right"
    public var legendScale: Double = 1.0
    public var reducedMotion = false
    public var accelThreshold = 3
    public var ledMode = "live"            // live (groups + agent status) | groups (no status) | off
    public var ledBrightness = 1.0         // pads in general
    public var ledWindowBrightness = 0.3   // window pads other than the current one (current = full)
    public var ledNightScale = 0.3         // menu › Dim pad lights (night) multiplies every level by this
    /// Pad light colours by key: colour categories, agent statuses, modes. Distinct hues, no purple/pink or blue/indigo pairs.
    public var ledColors: [String: String] = [
        // 7 clearly separate hues only: red, green, blue, yellow, cyan, magenta, white
        "nav": "#0000ff", "act": "#ffff00", "new": "#00ff00", "skill": "#ff00ff", "danger": "#ff0000", "sys": "#00ffff",
        "ok": "#00ff00", "warn": "#ffff00", "voice": "#ff0000", "off": "#000000",
        "drum": "#000000",   // drums on empty window pads stay dark, so a dark pad still means "no window"
        "unknown": "#0000ff", "idle": "#ffffff", "working": "#00ffff", "needs_approval": "#ff00ff",
        "needs_input": "#ffff00", "done_unread": "#00ff00", "error": "#ff0000", "compacting": "#00ffff",
        "mode_default": "#ffffff", "mode_acceptEdits": "#ffff00", "mode_plan": "#0000ff",
        "mode_auto": "#ff00ff", "mode_bypassPermissions": "#ff0000", "mode_dontAsk": "#ff0000",
    ]
    public var soundsEnabled = true
    public var soundVolume = 0.25
    public var drumCurve = 0.5             // velocity → drum loudness: 1 = linear, lower = soft hits play louder
    public var drumFloor = 0.55            // loudness of the softest hit (0–1)
    public var drumFull = 48.0             // the velocity that already counts as a full hit (the SMC-PAD rarely sends > 40)
    /// Sound names: colour categories (a binding's group) and named sounds bindings refer to with sound = "name".
    /// Values are macOS system sounds (Tink, Pop, …), a file path, or "" for silence.
    public var sounds: [String: String] = [
        "nav": "click@0.6", "act": "Pop", "skill": "Bottle", "danger": "Basso", "sys": "click@0.6",
        "ok": "", "warn": "", "voice": "",
        "new": "Hero", "mode": "Purr", "picker": "Morse", "select": "Pop", "error": "Funk",
        "scroll": "tick@0.5", "cancel": "Blow",
    ]

    public static let defaultColors = [
        "nav": "#4dabf7", "act": "#ffa94d", "skill": "#b197fc", "voice": "#ff6b6b", "ok": "#51cf66",
        "warn": "#fcc419", "danger": "#fa5252", "sys": "#66d9e8", "off": "#3a3a3a", "new": "#51cf66", "drum": "#868e96",
        // agent statuses
        "unknown": "#4dabf7", "idle": "#dee2e6", "working": "#339af0", "needs_approval": "#ff922b",
        "needs_input": "#fcc419", "done_unread": "#51cf66", "error": "#fa5252", "compacting": "#9775fa",
        // permission modes
        "mode_default": "#868e96", "mode_acceptEdits": "#fcc419", "mode_plan": "#4dabf7",
        "mode_auto": "#b197fc", "mode_bypassPermissions": "#fa5252", "mode_dontAsk": "#fa5252",
    ]

    public static func parse(_ t: [String: Value]) -> Settings {
        var s = Settings()
        if let d = t["device"]?.string { s.device = d }
        for (k, v) in t["roles"]?.table ?? [:] { if let n = v.string, !n.isEmpty { s.roles[k] = n } }
        if let b = t["banks"]?.table?["pad_b"]?.string { s.padBankB = b }
        for (k, v) in t["colors"]?.table ?? [:] { if let n = v.string { s.colors[k] = n } }
        let tm = t["timing"]?.table ?? [:]
        if let v = tm["hold"].flatMap(parseDuration) { s.holdMs = v * 1000 }
        if let v = tm["confirm_hold"].flatMap(parseDuration) { s.confirmHoldMs = v * 1000 }
        if let v = tm["legend_hold"].flatMap(parseDuration) { s.legendHoldMs = v * 1000 }
        if let v = tm["legend_pin"].flatMap(parseDuration) { s.legendPinSeconds = v }
        if let v = tm["passthrough_limit"].flatMap(parseDuration) { s.passthroughLimitSeconds = v }
        if let l = t["led"]?.table {
            if let m = l["mode"]?.string { s.ledMode = m }
            if let b = l["brightness"]?.number { s.ledBrightness = max(0, min(1, b)) }
            if let b = l["window_brightness"]?.number { s.ledWindowBrightness = max(0, min(1, b)) }
            if let b = l["night"]?.number { s.ledNightScale = max(0, min(1, b)) }
            for (k, v) in l where !["mode", "brightness", "window_brightness", "night"].contains(k) { if let c = v.string { s.ledColors[k] = c } }
        }
        if let sn = t["sounds"]?.table {
            if let b = sn["enabled"]?.bool { s.soundsEnabled = b }
            if let v = sn["volume"]?.number { s.soundVolume = max(0, min(1, v)) }
            if let v = sn["drum_curve"]?.number { s.drumCurve = max(0.05, min(2, v)) }
            if let v = sn["drum_floor"]?.number { s.drumFloor = max(0, min(1, v)) }
            if let v = sn["drum_full"]?.number { s.drumFull = max(1, min(127, v)) }
            for (k, v) in sn where k != "enabled" && k != "volume" { if let n = v.string { s.sounds[k] = n } }
        }
        let lg = t["legend"]?.table ?? [:]
        if let v = lg["position"]?.string { s.legendPosition = v }
        if let v = lg["scale"]?.number { s.legendScale = v }
        if let v = lg["reduced_motion"]?.bool { s.reducedMotion = v }
        return s
    }

    public func color(_ name: String?) -> String? {
        guard let name else { return nil }
        if name.hasPrefix("#") { return name }
        return colors[name]
    }
}
