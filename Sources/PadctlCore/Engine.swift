import Foundation

// MARK: - Plans (what the executor runs)

public enum PlanStep: Equatable {
    case keys([KeyChord])                       // synthetic keystrokes to the frontmost app
    case keyDown(KeyChord)
    case keyUp(KeyChord)
    case typeText(String)                       // synthetic typing to the frontmost app
    case tmuxKeys(pane: String, [KeyChord])
    case tmuxText(pane: String, String)
    case tmux([String])
    case focusPane(String)                      // switch the focused client to this pane
    case exec([String], cwd: String?)
    case open(String)
    case shortcut(String)
    case menu([String])
    case script(String, env: [String: String])
    case setState(String, Value)
    case toast(String)
    case wait(Double)
    case setMode(pane: String, target: String)   // closed loop: read the mode line, Shift+Tab until it matches
    case cycleWindow(next: Bool)                  // frontmost app's windows
    case openApp(String)                          // bring to front / launch, like a Dock click (bundle id or name)
    case focusWindow(String)                      // a window of any app ("pid␟index␟title")
    case pressButton([String])                    // the front app's button by name (Accessibility)
    case cycleTab(next: Bool)                     // browser tabs, wrapping at the ends
}

public struct Plan: Equatable {
    public var steps: [PlanStep]
    public var pane: String?          // target pane captured at press time; revalidated before each step
    public var agentSession: String?
    public var label: String
    public var sound: String? = nil     // sound key or name, resolved by the app
}

public enum EngineOutput: Equatable {
    case plan(Plan)
    case legend(LegendCommand)
    case redraw
    case input(InputRequest)
    case search                     // a picker with a search box opened: the app shows a text field for it
    case dictate                    // start hands-free dictation (the app taps the talk key)
}

/// The app asks the user for text, then hands it back with `Engine.submitInput`.
public struct InputRequest: Equatable {
    public var prompt: String
    public var action: Action
    public var layer: String
}

public enum LegendCommand: Equatable { case showHeld, hideHeld, togglePin }

public struct Appearance: Equatable {
    public var label: String
    public var color: String?
    public var blink: Bool
    public var bound: Bool
    public var detail: String
    public var selected = false
    public var altLabel = ""        // the label in the other shift state (shown small and grey)
    public var key: String?         // colour key for pad lights: category, agent status or mode
    public var windowSlot = false   // a slot pad (a window, an app): dimmer unless it's the current one
    public var note = ""            // a short status under the label (window pads: what the agent is doing)
}

public struct StackEntry: Equatable {
    public var layer: String
    public var activation: Activation
    public var expires: Double?
    public var trigger: String
    public var started: Double
    public var timeout: Double?
    public var remaining = 1
}

// MARK: - Built-in looks

public enum Looks {
    public static let builtins: Set<String> = ["agent_status", "waiting", "agent_working", "agent_mode", "current_window", "context_meter", "attention", "choice", "agent_slot"]

    /// Context fill → colour key: below 50 % calm, 50–80 % warn, above 80 % danger. Unknown: the binding's own colour.
    static func contextKey(_ snap: Snapshot) -> String? {
        guard let c = snap["agent.context"].number else { return nil }
        return c >= 80 ? "danger" : (c >= 50 ? "warn" : "ok")
    }

    /// Colour key (category / status / mode) a built-in look resolves to, for pad lights.
    static func builtinKey(_ name: String, binding: Binding, snapshot: Snapshot) -> String? {
        switch name {
        case "agent_status":
            if let w = binding.params["win"]?.int {
                if snapshot["win.\(w).exists"] == .null { return "off" }
                return snapshot["win.\(w).agent.status"].string ?? binding.color ?? "nav"
            }
            return snapshot["agent.status"].string ?? binding.color ?? "nav"
        case "waiting": return (snapshot["agents.waiting"].number ?? 0) > 0 ? "needs_input" : "off"
        case "agent_working": return snapshot["agent.status"].string == "working" ? "warn" : "off"
        case "agent_mode": return snapshot["agent.mode"].string.map { "mode_" + $0 } ?? "sys"
        case "context_meter": return contextKey(snapshot) ?? binding.color
        case "attention": return binding.color
        case "choice": return choiceKey(binding, snapshot)
        case "agent_slot": return binding.params["slot"]?.int.flatMap { snapshot["agents.slot.\($0).status"].string } ?? "off"
        default: return nil
        }
    }

    static func builtin(_ name: String, binding: Binding, snapshot: Snapshot, settings: Settings) -> (color: String?, blink: Bool, label: String?)? {
        switch name {
        case "agent_status":
            let key: String
            if let w = binding.params["win"]?.int { key = "win.\(w).agent.status" } else { key = "agent.status" }
            if let w = binding.params["win"]?.int, snapshot["win.\(w).exists"] == .null {
                return (settings.color("off"), false, nil)
            }
            guard let s = snapshot[key].string.flatMap(AgentStatus.init(rawValue:)) else {
                return (settings.color(binding.color) ?? settings.color("nav"), false, nil)
            }
            return (settings.color(s.rawValue), s.wantsYou, nil)     // asks, approve? and done-but-unseen blink
        case "waiting":
            let n = snapshot["agents.waiting"].number ?? 0
            return n > 0 ? (settings.color("needs_input"), true, nil) : (settings.color("off"), false, nil)
        case "agent_working":
            return snapshot["agent.status"].string == "working" ? (settings.color("warn"), false, nil) : (settings.color("off"), false, nil)
        case "agent_mode":
            let m = snapshot["agent.mode"].string ?? ""
            return (settings.color("mode_\(m)") ?? settings.color("sys"), false, m.isEmpty ? nil : modeLabel(m))
        case "current_window":
            let w = binding.params["win"]?.int ?? -1
            return snapshot["window"].int == w ? (settings.color("ok"), false, nil) : nil
        case "attention":       // asks for you: blinks in its own colour
            return (settings.color(binding.color) ?? settings.color("warn"), !settings.reducedMotion, nil)
        case "choice":
            let k = choiceKey(binding, snapshot)
            return (settings.color(k), k == "ok" && !settings.reducedMotion, nil)
        case "agent_slot":       // the Agents overview: status colour; the ones waiting for you blink
            guard let n = binding.params["slot"]?.int, let s = snapshot["agents.slot.\(n).status"].string.flatMap(AgentStatus.init(rawValue:)) else {
                return (settings.color("off"), false, nil)
            }
            return (settings.color(s.rawValue), s.wantsYou && !settings.reducedMotion, nil)
        case "context_meter":
            guard let key = contextKey(snapshot), let c = snapshot["agent.context"].number else { return nil }
            return (settings.color(key), false, "\(binding.label ?? "Compact") \(Int(c))%")   // blinking = an agent waits for you
        default: return nil
        }
    }

    /// An option pad of an agent's question: the option under the agent's cursor (what ▶ / Enter takes) is green
    /// and blinks — the one pad saying "answer me now"; options answered in words ("Type something", "Chat about
    /// this") are magenta (voice), the rest white. Pads past the last option are off: nothing from the layer below.
    static func choiceKey(_ binding: Binding, _ snap: Snapshot) -> String {
        guard case .answer(let n) = binding.action else { return binding.color ?? "choice" }
        if n > (snap["q.count"].int ?? 0) { return "off" }
        if n == (snap["q.selected"].int ?? 1) { return "ok" }
        return isFree(n, snap) ? "choice_voice" : "choice"
    }
    static func isFree(_ n: Int, _ snap: Snapshot) -> Bool { snap["q.free.\(n)"].truthy || snap["q.other"].int == n }

    /// Words for agent statuses, as the legend shows them under window pads and in its colour key.
    public static let statusWords: [(String, String)] = [
        ("needs_input", "asks"), ("needs_approval", "approve?"), ("working", "working"), ("compacting", "compacting"),
        ("done_unread", "done ✓"), ("idle", "idle"), ("error", "error"), ("unknown", "no status"),
    ]
    public static func statusLabel(_ s: String) -> String { statusWords.first { $0.0 == s }?.1 ?? s }

    public static func modeLabel(_ m: String) -> String {
        ["default": "Manual", "acceptEdits": "Accept edits", "plan": "Plan", "auto": "Auto",
         "bypassPermissions": "Bypass", "dontAsk": "Don't ask"][m] ?? m
    }
}

// MARK: - Engine

/// Pure input → plan state machine. The Mac side feeds it events, context and a clock.
public final class Engine {
    public private(set) var config: Config
    public private(set) var stack: [StackEntry] = []
    public private(set) var shiftHeld = false
    public var padBank = "A"
    public var knobBank = "A"
    /// Shift is on while the shift role is held, or while pad bank B is active (when banks.pad_b = "shift").
    public var shiftActive: Bool { shiftHeld || (padBank == "B" && config.settings.padBankB == "shift") }
    /// Knobs follow KNOB BANK: bank B = the knobs' [shift] bindings.
    public func shiftActive(for control: String) -> Bool {
        control.hasPrefix("knob") ? (shiftHeld || knobBank == "B") : shiftActive
    }

    struct Press { var binding: Binding?; var layer: Layer?; var down: Double; var fired: Bool; var role: String?; var legend = false }
    private var presses: [String: Press] = [:]
    private var heldKeys: [String: (chord: KeyChord, since: Double)] = [:]
    private var lastBaseId: String?
    public private(set) var picker: PickerState?
    public var lastEvent = ""                       // for the app's log: why something closed

    /// An action waiting for ✓ / ✕ (confirm = "ask", or a picker with confirm = true).
    public struct PendingConfirm {
        var action: Action; var binding: Binding; var layer: Layer; var control: String
        public var label: String; var vars: [String: Value]
    }
    public private(set) var pendingConfirm: PendingConfirm?
    static let confirmLayer = "confirm"
    static let listLayer = "list"           // on top while a list is open: green ✓ takes, red ✕ closes

    func askConfirm(_ p: PendingConfirm, now: Double) -> [EngineOutput] {
        guard let cl = config.layers[Engine.confirmLayer] else {
            return [.plan(Plan(steps: [.toast("No confirm layer — not running “\(p.label)”")], pane: nil, agentSession: nil, label: "confirm"))]
        }
        pendingConfirm = p
        stack.removeAll { $0.layer == Engine.confirmLayer }
        let t = cl.timeout ?? 8
        stack.append(StackEntry(layer: cl.id, activation: .modal, expires: now + t, trigger: p.control, started: now, timeout: t))
        return [.plan(Plan(steps: [.toast("\(p.label)? ✓ green · ✕ red")], pane: nil, agentSession: nil, label: "confirm", sound: "picker")), .redraw]
    }
    public func isHeld(_ control: String) -> Bool { presses[control] != nil }
    private var extraVars: [String: Value] = [:]
    public static let pickerTimeout = 20.0
    public static let pickerCancel = "\u{1}cancel"

    public init(config: Config) { self.config = config }

    public func reload(_ c: Config) {
        config = c
        stack.removeAll { c.layers[$0.layer] == nil }
    }

    // MARK: layers

    public func baseLayer(_ ctx: Context) -> Layer {
        let fallback = config.layers["default"]!
        if padBank == "B" && config.settings.padBankB == "default" { return fallback }
        var best: Layer?
        for l in config.layers.values where l.kind == .base {
            guard let w = l.when, matches(w, ctx) else { continue }
            if let b = best {
                if (w.specificity, l.priority) > (b.when!.specificity, b.priority) { best = l }
            } else { best = l }
        }
        return best ?? fallback
    }

    func matches(_ w: When, _ ctx: Context) -> Bool {
        if !w.apps.isEmpty && !w.apps.contains(ctx.app) && !w.apps.contains(ctx.appName) { return false }
        if !w.tmuxCmd.isEmpty {
            guard let p = ctx.focusedPane, w.tmuxCmd.contains("*") || w.tmuxCmd.contains(p.command) else { return false }
        }
        if let re = w.window, ctx.windowTitle.range(of: re, options: .regularExpression) == nil { return false }
        return w.specificity > 0
    }

    /// Layers from bottom (base) to top.
    public func effectiveStack(_ ctx: Context, _ snap: Snapshot = Snapshot()) -> [Layer] {
        [baseLayer(ctx)] + autoLayers(snap) + stack.compactMap { config.layers[$0.layer] }
            + (picker != nil ? [config.layers[Engine.listLayer]].compactMap { $0 } : [])
    }

    /// Modal layers whose `auto` condition holds (e.g. Answer while the focused agent asks).
    public func autoLayers(_ snap: Snapshot) -> [Layer] {
        config.layers.values.filter { $0.kind == .modal && ($0.auto?.eval(snap.lookup).truthy ?? false) }.sorted { $0.id < $1.id }
    }

    public func layerPath(_ ctx: Context, now: Double, snap: Snapshot = Snapshot()) -> String {
        var parts = [baseLayer(ctx).name] + autoLayers(snap).map(\.name)
        if let p = picker { parts.append(p.title) }
        for e in stack {
            guard let l = config.layers[e.layer] else { continue }
            if let exp = e.expires { parts.append("\(l.name) (\(max(0, Int((exp - now).rounded(.up))))s)") } else { parts.append(l.name) }
        }
        if shiftHeld { parts.append("Shift") }
        return parts.joined(separator: " › ")
    }

    func chain(_ l: Layer) -> [Layer] {
        var out = [l], cur = l.extends
        while let id = cur, let p = config.layers[id] { out.append(p); cur = p.extends }
        return out
    }

    /// Resolve a control top-down through the stack; within a layer, shift tables first, then bindings, along extends.
    public func resolve(_ control: String, _ ctx: Context, _ snap: Snapshot = Snapshot(), shift: Bool? = nil) -> (Binding, Layer)? {
        func ok(_ b: Binding) -> Bool { b.condition?.eval(snap.lookup).truthy ?? true }
        func missing(_ b: Binding) -> Bool { b.params["win"].map { snap["win.\($0.int ?? -1).exists"] == .null } ?? false }
        // A window pad whose window doesn't exist uses an `empty` binding. These are handed out by priority: the
        // empty bindings in pad order (pad1's first) go to whichever window pads are empty, lowest pad first —
        // so a few empty pads always get the essentials (kick, snare, hat) and more pads add to them.
        func pick(_ b: Binding, _ ch: [Layer], _ shifted: Bool) -> Binding {
            guard let own = b.whenEmpty.first, missing(b) else { return b }
            let pads = (1...64).compactMap { n -> (String, Binding)? in
                let name = "pad\(n)"
                for c in ch { if let x = shifted ? c.shift[name] : c.bindings[name], ok(x) { return (name, x) } }
                return nil
            }.filter { !$0.1.whenEmpty.isEmpty }
            let kit = pads.map { $0.1.whenEmpty[0] }
            guard let rank = pads.filter({ missing($0.1) }).firstIndex(where: { $0.0 == control }), rank < kit.count else { return own }
            return kit[rank]
        }
        for l in effectiveStack(ctx, snap).reversed() {
            let ch = chain(l)
            if shift ?? shiftActive(for: control) { for c in ch { if let b = c.shift[control], ok(b) { return (pick(b, ch, true), l) } } }
            for c in ch { if let b = c.bindings[control], ok(b) { return (pick(b, ch, false), l) } }
            if l.exclusive, control.hasPrefix("pad") { return nil }   // e.g. confirm: the other pads are off (knobs still work)
        }
        return nil
    }

    func role(of control: String) -> String? {
        config.settings.roles.first { $0.value == control }?.key
    }

    /// Called when the frontmost app or focused pane changes the base layer.
    public func contextChanged(_ ctx: Context) -> [EngineOutput] {
        let base = baseLayer(ctx).id
        defer { lastBaseId = base }
        guard let last = lastBaseId, last != base else { return [] }
        if picker != nil { lastEvent = "list closed: layer changed \(last) → \(base)" }
        let before = stack.count
        stack.removeAll { $0.activation != .switch }
        let hadPicker = picker != nil
        picker = nil
        return before != stack.count || hadPicker ? [.redraw] : []
    }

    // MARK: input

    public func handle(_ e: ControlEvent, now: Double, ctx: Context, snap: Snapshot) -> [EngineOutput] {
        if let out = pickerInput(e, now: now, ctx: ctx, snap: snap) { return out }
        switch e {
        case .down(let c): return down(c, now: now, ctx: ctx, snap: snap)
        case .up(let c): return up(c, now: now, ctx: ctx, snap: snap)
        case .turn(let c, let d): return turn(c, d, now: now, ctx: ctx, snap: snap)
        }
    }

    func down(_ c: String, now: Double, ctx: Context, snap: Snapshot) -> [EngineOutput] {
        if let r = role(of: c), r == "shift" || r == "legend" {
            presses[c] = Press(binding: nil, layer: nil, down: now, fired: false, role: r)
            if r == "shift" { shiftHeld = true; return [.redraw] }
            return [.legend(.showHeld)]
        }
        guard let (b, l) = resolve(c, ctx, snap) else {
            presses[c] = Press(binding: nil, layer: nil, down: now, fired: true, role: nil)
            return []
        }
        // pressing something outside a temporary modal layer (menu-nav) leaves it
        let before = stack.count
        if let top = stack.last, top.activation == .modal, top.layer != l.id { stack.removeAll { $0.activation == .modal } }
        if stack.count != before, let (b2, l2) = resolve(c, ctx, snap), l2.id != l.id {
            presses[c] = Press(binding: b2, layer: l2, down: now, fired: false, role: nil)
        }
        presses[c] = presses[c] ?? Press(binding: b, layer: l, down: now, fired: false, role: nil)
        if b.confirmAsk, b.hold == nil, let a = b.action {     // with a hold: asks on release (a tap), below
            presses[c]?.fired = true
            return askConfirm(PendingConfirm(action: a, binding: b, layer: l, control: c,
                                             label: b.label.map { interpolate($0, snap.lookup) } ?? defaultLabel(b, layer: l), vars: [:]), now: now)
        }
        // a chord: another control is held down (e.g. ● Talk while pressing Skills…) → its `with` action instead
        if let (_, act) = b.with.first(where: { presses[$0.key] != nil && $0.key != c }) {
            presses[c]?.fired = true
            return fire(act, binding: b, layer: l, control: c, now: now, ctx: ctx, snap: snap)
        }
        if let k = b.passthrough {
            heldKeys[c] = (k, now)
            presses[c]?.fired = true
            return [.plan(Plan(steps: [.keyDown(k)], pane: nil, agentSession: nil, label: "hold \(k)"))]
        }
        if case .layer(let id, .hold, _) = b.action {
            stack.append(StackEntry(layer: id, activation: .hold, expires: nil, trigger: c, started: now, timeout: nil))
            presses[c]?.fired = true
            return [.redraw]
        }
        if b.confirmHold || b.hold != nil { return [.redraw] }
        presses[c]?.fired = true
        return fire(b.action, binding: b, layer: l, control: c, now: now, ctx: ctx, snap: snap)
    }

    func up(_ c: String, now: Double, ctx: Context, snap: Snapshot) -> [EngineOutput] {
        guard let p = presses.removeValue(forKey: c) else { return [] }
        if p.legend { return [.legend(.hideHeld)] }
        if let r = p.role {
            if r == "shift" { shiftHeld = false; return [.redraw] }
            return [.legend(now - p.down < config.settings.holdMs / 1000 ? .togglePin : .hideHeld)]
        }
        if let h = heldKeys.removeValue(forKey: c) {
            return [.plan(Plan(steps: [.keyUp(h.chord)], pane: nil, agentSession: nil, label: "release \(h.chord)"))]
        }
        if let i = stack.lastIndex(where: { $0.trigger == c && $0.activation == .hold }) {
            stack.remove(at: i); return [.redraw]
        }
        guard !p.fired, let b = p.binding, let l = p.layer else { return [] }
        if b.confirmHold { return [.plan(Plan(steps: [.toast("Hold to confirm")], pane: nil, agentSession: nil, label: "cancel"))] }
        if b.confirmAsk, let a = b.action {
            return askConfirm(PendingConfirm(action: a, binding: b, layer: l, control: c,
                                             label: b.label.map { interpolate($0, snap.lookup) } ?? defaultLabel(b, layer: l), vars: [:]), now: now)
        }
        return fire(b.action, binding: b, layer: l, control: c, now: now, ctx: ctx, snap: snap)
    }

    /// Knob travel not yet turned into moves (bindings with step > 1).
    var knobTravel: [String: (sum: Int, at: Double, dir: Int)] = [:]

    func turn(_ c: String, _ rawDelta: Int, now: Double, ctx: Context, snap: Snapshot) -> [EngineOutput] {
        guard let (b, l) = resolve(c, ctx, snap) else { return [] }
        var d = rawDelta
        if b.step > 1 {
            // less sensitive: `step` units per move. A fresh turn (after a pause or a change of direction) moves on
            // its first unit, so it never feels late; after that every `step` units.
            let dir = d > 0 ? 1 : -1
            var t = knobTravel[c] ?? (0, -10, 0)
            if now - t.at > 0.8 || dir != t.dir { t.sum = dir * (b.step - 1) }
            t.sum += d; t.at = now; t.dir = dir
            let moves = t.sum / b.step
            t.sum -= moves * b.step
            knobTravel[c] = t
            if moves == 0 { return [] }
            d = moves
        }
        let action = d > 0 ? (b.cw ?? b.action) : (b.ccw ?? b.action)
        var n = abs(d)
        if b.accel && n >= config.settings.accelThreshold { n *= 2 }
        n = min(n, 24)
        if b.then != nil { n = 1 }   // opens a menu: once, later detents move inside it
        if case .picker = action { n = 1 }
        if case .search = action { n = 1 }
        var out: [EngineOutput] = []
        for _ in 0..<n { out += fire(action, binding: b, layer: l, control: c, now: now, ctx: ctx, snap: snap) }
        return merge(out)
    }

    /// Hold thresholds, confirmations, timeouts, held-key safety.
    public func tick(now: Double, ctx: Context, snap: Snapshot) -> [EngineOutput] {
        var out: [EngineOutput] = []
        for (c, p) in presses where !p.fired && p.role == nil {
            guard let b = p.binding, let l = p.layer else { continue }
            if b.confirmHold, now - p.down >= config.settings.confirmHoldMs / 1000 {
                presses[c]?.fired = true
                out += fire(b.action, binding: b, layer: l, control: c, now: now, ctx: ctx, snap: snap)
            } else if !b.confirmHold, let h = b.hold,
                      now - p.down >= (b.holdTime ?? (h == .legend("show") ? config.settings.legendHoldMs : config.settings.holdMs) / 1000) {
                presses[c]?.fired = true
                if case .legend("show") = h { presses[c]?.legend = true; out.append(.legend(.showHeld)); continue }
                out += fire(h, binding: b, layer: l, control: c, now: now, ctx: ctx, snap: snap)
            }
        }
        let before = stack.count
        stack.removeAll { e in e.expires.map { $0 <= now } ?? false }
        if stack.count != before { out.append(.redraw) }
        if pendingConfirm != nil, !stack.contains(where: { $0.layer == Engine.confirmLayer }) {
            pendingConfirm = nil; out.append(soundOnly("cancel"))
        }
        if let p = picker, p.expires <= now { picker = nil; out.append(.redraw) }
        // the knob rested: take the highlighted item (the window list)
        if let at = picker?.commitAt, at <= now { out += commitPicker(now: now, ctx: ctx, snap: snap) }
        for (c, h) in heldKeys where now - h.since > config.settings.passthroughLimitSeconds {
            heldKeys[c] = nil
            out.append(.plan(Plan(steps: [.keyUp(h.chord), .toast("Released \(h.chord) after the safety limit")], pane: nil, agentSession: nil, label: "safety")))
        }
        return out
    }

    /// Release everything held (disconnect, quit, pause).
    public func releaseAll() -> [EngineOutput] {
        let steps = heldKeys.values.map { PlanStep.keyUp($0.chord) }
        heldKeys = [:]; presses = [:]; shiftHeld = false; picker = nil
        stack.removeAll { $0.activation == .hold }
        return steps.isEmpty ? [.redraw] : [.plan(Plan(steps: steps, pane: nil, agentSession: nil, label: "release")), .redraw]
    }

    public var holdingKeys: Bool { !heldKeys.isEmpty }

    // MARK: pickers

    /// While a picker is open: knobs (and < >) move. With the List layer (layers/list.toml) its green ✓ takes the
    /// highlighted item, its red ✕ closes the list and other pads do nothing; without it any control selects.
    func pickerInput(_ e: ControlEvent, now: Double, ctx: Context, snap: Snapshot) -> [EngineOutput]? {
        guard var p = picker else { return nil }
        if p.expires <= now { picker = nil; return nil }
        switch e {
        case .turn(_, let d):
            // a search list: -1 is the search row at the top, the knob moves down into the results and back
            let first = p.searching ? -1 : 0
            let next = max(first, min(p.items.count - 1, p.index + (d > 0 ? 1 : -1) * min(abs(d), 3)))
            let moved = next != p.index
            p.index = next
            p.expires = now + Engine.pickerTimeout
            if let wait = config.pickers[p.id]?.commitAfter, p.commitAt != nil { p.commitAt = now + wait }
            picker = p
            return moved ? [soundOnly("scroll"), .redraw] : [.redraw]
        case .down(let c) where c != "pause":
            // a hold-through key (● Talk) works normally while a list is open — and first turns a plain list into
            // a search (search row shown and focused), so what you say filters the list instead of landing in the
            // app behind it
            if let (b, _) = resolve(c, ctx, snap), b.passthrough != nil {
                guard !p.searching else { return nil }
                p.all = p.items.filter { $0.value != Engine.pickerCancel }
                p.searching = true
                p.commitAt = nil                    // the window list: no jumping while you talk
                picker = p
                _ = filterPicker("", now: now)
                return [.search, .redraw] + down(c, now: now, ctx: ctx, snap: snap)
            }
            if config.layers[Engine.listLayer] != nil, c != "search" {
                presses[c] = Press(binding: nil, layer: nil, down: now, fired: true, role: nil)
                if c == "left" || c == "right" { return pickerInput(.turn(c, c == "left" ? -1 : 1), now: now, ctx: ctx, snap: snap) }
                switch resolve(c, ctx, snap)?.0.action {
                case .decide(true)?: break                                          // green ✓: take it (below)
                case .decide(false)?: picker = nil; return [soundOnly("cancel"), .redraw]   // red ✕
                default: return []                                                  // a dark pad: nothing
                }
            }
            picker = nil
            presses[c] = Press(binding: nil, layer: nil, down: now, fired: true, role: nil)
            guard let def = config.pickers[p.id], let layer = config.layers[p.layer] ?? Optional(baseLayer(ctx)) else { return [.redraw] }
            // on the search row: the top match
            guard !p.items.isEmpty else { return [soundOnly("cancel"), .redraw] }
            let item = p.items[max(0, min(p.index, p.items.count - 1))]
            if item.value == Engine.pickerCancel { return [soundOnly("cancel"), .redraw] }
            extraVars = ["item": .string(item.value), "item.label": .string(item.label)]
            defer { extraVars = [:] }
            var b = Binding.parseBare()
            b.label = "\(def.title): \(item.label)"
            b.sound = "select"
            if def.confirm {
                return askConfirm(PendingConfirm(action: item.action ?? def.run, binding: b, layer: layer, control: c,
                                                 label: item.label, vars: extraVars), now: now)
            }
            return fire(item.action ?? def.run, binding: b, layer: layer, control: c, now: now, ctx: ctx, snap: snap) + [.redraw]
        case .down("pause"):
            picker = nil
            presses["pause"] = Press(binding: nil, layer: nil, down: now, fired: true, role: nil)
            return [soundOnly("cancel"), .redraw]
        case .down:
            return nil
        case .up:
            return nil
        }
    }

    /// Search pickers: show the items matching `query`, best first (empty = everything); ⏸ cancels.
    @discardableResult
    public func filterPicker(_ query: String, now: Double) -> [EngineOutput] {
        guard var p = picker, p.searching else { return [] }
        p.query = query
        p.items = query.trimmingCharacters(in: .whitespaces).isEmpty ? p.all : PickerSearch.rank(p.all, query).map(\.0)
        p.index = -1          // the search row is highlighted until a knob moves into the results
        p.expires = now + Engine.pickerTimeout * 3
        picker = p
        return [.redraw]
    }

    /// The best match when it's clearly the one meant (for dictated searches).
    public func confidentPick() -> PickerItem? {
        guard let p = picker, p.searching, !p.query.isEmpty else { return nil }
        return PickerSearch.confident(PickerSearch.rank(p.all, p.query))
    }

    /// Take the highlighted item (▶ / Enter in the search box). Closes the picker.
    public func commitPicker(now: Double, ctx: Context, snap: Snapshot) -> [EngineOutput] {
        guard picker != nil else { return [] }
        let out = pickerInput(.down("search"), now: now, ctx: ctx, snap: snap) ?? []
        presses["search"] = nil
        return out
    }

    /// Close the picker without taking anything.
    public func cancelPicker() -> [EngineOutput] {
        guard picker != nil else { return [] }
        picker = nil
        return [soundOnly("cancel"), .redraw]
    }

    /// Run an input request's action with the text the user entered ({input}).
    public func submitInput(_ r: InputRequest, text: String, now: Double, ctx: Context, snap: Snapshot) -> [EngineOutput] {
        guard let layer = config.layers[r.layer] else { return [] }
        extraVars = ["input": .string(text)]
        defer { extraVars = [:] }
        var b = Binding.parseBare()
        b.label = r.prompt
        b.sound = "select"
        return fire(r.action, binding: b, layer: layer, control: "input", now: now, ctx: ctx, snap: snap)
    }

    func soundOnly(_ s: String) -> EngineOutput {
        .plan(Plan(steps: [], pane: nil, agentSession: nil, label: s, sound: s))
    }

    // MARK: firing

    func fire(_ action: Action?, binding: Binding, layer: Layer, control: String, now: Double, ctx: Context, snap: Snapshot) -> [EngineOutput] {
        guard let action else {
            // a binding that only plays a sound (e.g. drums on empty window pads)
            if let s = binding.sound, !s.isEmpty { return [soundOnly(s)] }
            return []
        }
        // a question's pad past its last option: grey, does nothing (no sound either)
        if case .answer(let n) = action, n > (snap["q.count"].int ?? Int.max) { return [] }
        if case .agent(let s) = action, s.hasPrefix("slot "), let n = Int(s.dropFirst(5)), n > (snap["agents.count"].int ?? Int.max) { return [] }
        var out: [EngineOutput] = []
        let useTmux = (binding.target ?? (chain(layer).contains { $0.when?.usesTmux ?? false } ? .pane : .app)) == .pane
        let pane = useTmux ? ctx.focusedPane : nil
        if useTmux && pane == nil {
            return [.plan(Plan(steps: [.toast("No tmux pane in focus")], pane: nil, agentSession: nil, label: "no target"))]
        }
        var steps: [PlanStep] = []
        plan(action, into: &steps, out: &out, layer: layer, control: control, now: now, ctx: ctx, snap: snap, pane: pane)
        // a one-shot layer ends after the next action from another control
        if let top = stack.last, top.activation == .oneshot, top.trigger != control {
            stack.removeLast(); out.append(.redraw)
        }
        // modal stack layers: activity extends them; exit controls count down their steps — also when the press
        // was answered by a layer above it (a menu's options read from the screen, on the pads)
        if let i = stack.lastIndex(where: { $0.activation == .modal && ($0.layer == layer.id || layer.auto != nil) }),
           let ml = config.layers[stack[i].layer] {
            if ml.cancel.contains(control) {
                stack.remove(at: i)
            } else if ml.exit.contains(control) {
                stack[i].remaining -= 1
                if stack[i].remaining <= 0 { stack.remove(at: i) }
            } else {
                stack[i].expires = now + (ml.timeout ?? 30)
            }
            out.append(.redraw)
        }
        if let t = binding.then, let tl = config.layers[t] {
            stack.removeAll { $0.layer == t }
            stack.append(StackEntry(layer: t, activation: .modal, expires: now + (tl.timeout ?? 30), trigger: control,
                                    started: now, timeout: tl.timeout, remaining: max(1, binding.thenSteps)))
            out.append(.redraw)
        }
        let sound = soundFor(binding, action: action, control: control)
        if !steps.isEmpty || sound != nil {
            out.insert(.plan(Plan(steps: steps, pane: pane?.paneId, agentSession: nil,
                                  label: binding.label ?? control, sound: sound)), at: 0)
        }
        return out
    }

    /// Explicit sound, else by kind of action (lists, mode), else the binding's colour group. Knobs are silent unless set.
    func soundFor(_ b: Binding, action: Action, control: String) -> String? {
        if let s = b.sound { return s.isEmpty ? nil : s }
        if control.hasPrefix("knob") || b.passthrough != nil { return nil }
        if case .picker = action { return "picker" }
        if case .search = action { return "picker" }
        if case .mode = action { return "mode" }
        if let c = b.color, config.settings.sounds[c] != nil { return config.settings.sounds[c]!.isEmpty ? nil : c }
        if b.look != nil { return "nav" }
        return nil
    }

    func vars(_ snap: Snapshot, pane: PaneInfo?) -> (String) -> Value {
        { k in
            switch k {
            case "pane_path": return pane.map { .string($0.path) } ?? snap["pane.path"]
            case "pane": return pane.map { .string($0.paneId) } ?? snap["pane"]
            case "session": return pane.map { .string($0.session) } ?? snap["session"]
            case "window": return pane.map { .number(Double($0.window)) } ?? snap["window"]
            case "home": return .string(NSHomeDirectory())
            default: return self.extraVars[k] ?? snap[k]
            }
        }
    }

    func plan(_ a: Action, into steps: inout [PlanStep], out: inout [EngineOutput], layer: Layer, control: String,
              now: Double, ctx: Context, snap: Snapshot, pane: PaneInfo?) {
        let v = vars(snap, pane: pane)
        switch a {
        case .keys(let ks): steps.append(pane.map { .tmuxKeys(pane: $0.paneId, ks) } ?? .keys(ks))
        case .text(let t):
            let s = interpolate(t, v)
            steps.append(pane.map { .tmuxText(pane: $0.paneId, s) } ?? .typeText(s))
        case .prompt(let rawName):
            let name = interpolate(rawName, v)
            guard let body = config.promptText(name, layer: layer) else { steps.append(.toast("Prompt '\(name)' not found")); return }
            let s = interpolate(body, v)
            steps.append(pane.map { .tmuxText(pane: $0.paneId, s) } ?? .typeText(s))
        case .tmux(let args): steps.append(.tmux(args.map { interpolate($0, v) }))
        case .exec(let args): steps.append(.exec(args.map { interpolate($0, v) }, cwd: pane?.path))
        case .open(let s): steps.append(.open(interpolate(s, v)))
        case .shortcut(let s): steps.append(.shortcut(s))
        case .menu(let path): steps.append(.menu(path))
        case .script(let name):
            guard let url = config.scriptURL(name, layer: layer) else { steps.append(.toast("Script '\(name)' not found or not executable")); return }
            var env = ["PADCTL_CONTROL": control, "PADCTL_LAYER": layer.id, "PADCTL_APP": ctx.app]
            if let p = pane ?? ctx.focusedPane {
                env["PADCTL_PANE"] = p.paneId; env["PADCTL_PANE_PATH"] = p.path; env["PADCTL_SESSION"] = p.session
            }
            steps.append(.script(url.path, env: env))
        case .layer(let id, let act, let timeout):
            if act == .toggle || act == .switch, let i = stack.lastIndex(where: { $0.layer == id }) {
                stack.remove(at: i)
            } else {
                stack.append(StackEntry(layer: id, activation: act, expires: timeout.map { now + $0 },
                                        trigger: control, started: now, timeout: timeout))
            }
            out.append(.redraw)
        case .agent(let what):
            switch what {
            case "next_waiting":
                guard let target = snap["agents.oldest_waiting"].string else { steps.append(.toast("No agent is waiting")); return }
                steps += Engine.goToPane(target, ctx: ctx)
            case let s where s.hasPrefix("slot "):
                // the Agents overview: jump to the agent on that pad (iTerm comes to the front first)
                guard let n = Int(s.dropFirst(5)), let target = snap["agents.slot.\(n).pane"].string else { return }
                steps += Engine.goToPane(target, ctx: ctx)
            case "reset":
                if let p = pane ?? ctx.focusedPane { steps.append(.setState("@agent.reset", .string(p.paneId))) }
            default: steps.append(.toast("Unknown agent action '\(what)'"))
            }
        case .mode(let dir):
            guard let p = pane else { steps.append(.toast("Mode needs a tmux pane")); return }
            let k = try! KeyChord.parse("shift+tab")
            if dir == "next" { steps.append(.tmuxKeys(pane: p.paneId, [k])) }
            else { steps.append(.setMode(pane: p.paneId, target: interpolate(dir, v))) }
        case .setState(let k, let val): steps.append(.setState(k, val))
        case .toast(let s): steps.append(.toast(interpolate(s, v)))
        case .wait(let d): steps.append(.wait(d))
        case .search(let id):
            guard let def = config.pickers[id] else { steps.append(.toast("Unknown picker '\(id)'")); return }
            let items = def.resolveItems(config: config)
            guard !items.isEmpty else { steps.append(.toast("\(def.title): nothing to pick")); return }
            var p = PickerState(id: id, title: def.title, items: [], index: 0, expires: now + Engine.pickerTimeout * 3, layer: layer.id)
            p.all = items; p.searching = true
            picker = p
            _ = filterPicker("", now: now)
            out.append(.search); out.append(.redraw)
        case .picker(let id):
            guard let def = config.pickers[id] else { steps.append(.toast("Unknown picker '\(id)'")); return }
            if var p = picker, p.id == id {
                p.index = min(p.index + 1, p.items.count - 1); p.expires = now + Engine.pickerTimeout; picker = p
            } else {
                let items = def.resolveItems(config: config)
                guard !items.isEmpty else { steps.append(.toast("\(def.title): nothing to pick")); return }
                // "Cancel" sits above the list; the picker opens on the first real item
                let all = [PickerItem(label: "✕ Cancel", value: Engine.pickerCancel)] + items
                picker = PickerState(id: id, title: def.title, items: all, index: 1, expires: now + Engine.pickerTimeout, layer: layer.id)
                // a knob-turned list that commits on rest (the window list): the turn that opened it already
                // moves one on — to the window behind this one, like ⌘Tab
                if let wait = def.commitAfter, control.hasPrefix("knob") {
                    picker?.index = min(2, all.count - 1)
                    picker?.commitAt = now + wait
                }
            }
            out.append(.redraw)
        case .window(let dir): steps.append(.cycleWindow(next: dir == "next"))
        case .focusWindow(let w): steps.append(.focusWindow(interpolate(w, v)))
        case .pressButton(let names): steps.append(.pressButton(names))
        case .tab(let dir): steps.append(.cycleTab(next: dir == "next"))
        case .app(let raw):
            // "previous": the app in front before this one — a quick way back and forth
            let name = raw == "previous" ? (ctx.previousApp?.bundleId ?? "") : interpolate(raw, v)
            if name.isEmpty { steps.append(.toast("No previous app yet")) }
            else if let r = ctx.running.first(where: { $0.matches(name) }), r.bundleId == ctx.app { steps.append(.cycleWindow(next: true)) }
            else { steps.append(.openApp(ctx.running.first { $0.matches(name) }?.bundleId ?? name)) }
        case .input(let prompt, let then): out.append(.input(InputRequest(prompt: prompt, action: then, layer: layer.id)))
        case .decide(let ok):
            let pending = pendingConfirm
            pendingConfirm = nil
            stack.removeAll { $0.layer == Engine.confirmLayer }
            out.append(.redraw)
            guard let p = pending else { return }
            if ok {
                extraVars = p.vars
                out += fire(p.action, binding: p.binding, layer: p.layer, control: p.control, now: now, ctx: ctx, snap: snap)
                extraVars = [:]
            } else {
                out.append(soundOnly("cancel"))
            }
        case .answerRole(let role):
            guard let p = pane else { steps.append(.toast("Answer needs a tmux pane")); return }
            // the prompt's own option when it's on screen; otherwise Enter = the highlighted Yes, Esc = No
            if role != "no", let n = snap["q.\(role)"].int, let key = snap["q.key.\(n)"].string {
                steps.append(.tmuxKeys(pane: p.paneId, [KeyChord(modifiers: [], key: key)]))
            } else if role != "always" {
                steps.append(.tmuxKeys(pane: p.paneId, [KeyChord(modifiers: [], key: role == "no" ? "esc" : "enter")]))
            }
        case .answer(let n):
            guard let p = pane else { steps.append(.toast("Answer needs a tmux pane")); return }
            // read from the screen with the cursor known: move the cursor there and press Enter (works in any list,
            // also ones without number keys); otherwise the key shown ("1", or "o" for Codex's Other)
            if snap["q.screen"].truthy, snap["q.multi"].truthy == false, let cur = snap["q.selected"].int {
                let d = n - cur
                let arrow = KeyChord(modifiers: [], key: d > 0 ? "down" : "up")
                steps.append(.tmuxKeys(pane: p.paneId, Array(repeating: arrow, count: abs(d)) + [KeyChord(modifiers: [], key: "enter")]))
            } else {
                let key = snap["q.key.\(n)"].string ?? String(n)
                steps.append(.tmuxKeys(pane: p.paneId, [KeyChord(modifiers: [], key: key)]))
            }
            if Looks.isFree(n, snap) { steps.append(.wait(0.3)); out.append(.dictate) }
        case .legend(let how): out.append(.legend(how == "pin" ? .togglePin : .showHeld))
        case .seq(let items):
            for i in items { plan(i, into: &steps, out: &out, layer: layer, control: control, now: now, ctx: ctx, snap: snap, pane: pane) }
        }
    }

    /// Show an agent's pane: bring iTerm forward when another app is in front (a Dock click — your hotkey window
    /// appears), then switch tmux to the pane.
    static func goToPane(_ pane: String, ctx: Context) -> [PlanStep] {
        let iterm = "com.googlecode.iterm2"
        return (ctx.app == iterm ? [] : [.openApp(iterm), .wait(0.2)]) + [.focusPane(pane)]
    }

    func merge(_ outs: [EngineOutput]) -> [EngineOutput] {
        var steps: [PlanStep] = [], rest: [EngineOutput] = []
        var first: Plan?
        for o in outs {
            if case .plan(let p) = o { if first == nil { first = p }; steps += p.steps } else if !rest.contains(o) { rest.append(o) }
        }
        guard var p = first else { return rest }
        p.steps = steps
        return [.plan(p)] + rest
    }

    // MARK: appearance

    public func appearance(_ control: String, ctx: Context, snap: Snapshot) -> Appearance {
        if let r = role(of: control) {
            let label = r == "shift" ? "Shift" : r == "legend" ? "Legend" : r.capitalized
            return Appearance(label: label, color: config.settings.color(shiftHeld && r == "shift" ? "#ffffff" : "sys"),
                              blink: false, bound: true, detail: r == "legend" ? "hold: show · tap: pin" : "hold for the shift layer")
        }
        if control == "knob_bank" {
            return Appearance(label: "Knobs B", color: config.settings.color("sys"),
                              blink: false, bound: true, detail: "knob bank B = the knobs' shift layer (system knobs)")
        }
        if control == "pad_bank" && config.settings.padBankB == "shift" {
            return Appearance(label: "Pads B", color: config.settings.color("sys"),
                              blink: false, bound: true, detail: "bank B = shift layer (the pad's bank light shows it)")
        }
        if config.device.hardwareOnly.contains(control) {
            return Appearance(label: config.device.layout.labels[control] ?? control, color: nil, blink: false, bound: false, detail: "hardware only")
        }
        // The banks send no MIDI of their own, so padctl only learns the bank from the next press. The legend
        // therefore never guesses: a pad/knob shows its bank-A action, with the bank-B one printed above it.
        let on = control.hasPrefix("pad") || control.hasPrefix("knob") ? shiftHeld : shiftActive(for: control)
        var a = appearance(control, ctx: ctx, snap: snap, shift: on)
        if a.bound || control.hasPrefix("pad") || control.hasPrefix("knob") || !config.device.hardwareOnly.contains(control) {
            let other = appearance(control, ctx: ctx, snap: snap, shift: !on)
            if other.label != a.label && resolve(control, ctx, snap, shift: !on) != nil { a.altLabel = other.label }
        }
        return a
    }

    public func appearance(_ control: String, ctx: Context, snap: Snapshot, shift: Bool) -> Appearance {
        guard let (b, l) = resolve(control, ctx, snap, shift: shift) else {
            return Appearance(label: "", color: nil, blink: false, bound: false, detail: "")
        }
        let pendingLabel = pendingConfirm?.label
        let lookup: (String) -> Value = { k in k == "confirm.label" ? .string(pendingLabel ?? "OK") : snap.lookup(k) }
        var label = b.label.map { interpolate($0, lookup) } ?? defaultLabel(b, layer: l)
        var color = config.settings.color(b.color) ?? config.settings.color("act")
        var blink = false
        if let name = b.look {
            if let look = chain(l).compactMap({ $0.looks[name] }).first ?? config.layers.values.compactMap({ $0.looks[name] }).first {
                for r in look.rules where r.condition?.eval(lookup).truthy ?? true {
                    if let c = r.color { color = config.settings.color(c) }
                    blink = r.blink
                    if let lb = r.label { label = interpolate(lb, lookup) }
                    break
                }
            } else if let res = Looks.builtin(name, binding: b, snapshot: snap, settings: config.settings) {
                if let c = res.color { color = c }
                blink = res.blink && !config.settings.reducedMotion
                if let lb = res.label { label = lb }
            }
        }
        var a = Appearance(label: label, color: color, blink: blink, bound: true, detail: b.description ?? describe(b))
        a.key = b.color.flatMap { config.settings.colors[$0] != nil || config.settings.ledColors[$0] != nil ? $0 : nil }
        if let name = b.look {
            if let look = chain(l).compactMap({ $0.looks[name] }).first ?? config.layers.values.compactMap({ $0.looks[name] }).first {
                a.key = look.rules.first(where: { $0.condition?.eval(lookup).truthy ?? true })?.color ?? a.key
            } else if let k = Looks.builtinKey(name, binding: b, snapshot: snap) { a.key = k }
        }
        if case .app(let name) = b.action {
            // app slots: dark = not running, dim = running, bright (outlined in the legend) = in front
            if let r = name == "previous" ? ctx.previousApp : ctx.running.first(where: { $0.matches(name) }) {
                if r.bundleId == ctx.app { a.selected = true } else { a.windowSlot = true }
            } else { a.key = "off"; a.color = config.settings.color("off") }
        }
        if b.look == "choice", case .answer(let n)? = b.action, n > (snap["q.count"].int ?? 0) {
            a.label = ""; a.detail = "no option here"        // a short question: the rest of rows 1–2 stays grey
        }
        if b.look == "agent_slot", let n = b.params["slot"]?.int {
            if n > (snap["agents.count"].int ?? 0) { a.label = ""; a.detail = "no agent" }
            else {
                a.note = snap["agents.slot.\(n).note"].string ?? ""
                if snap["agents.slot.\(n).pane"] == snap["pane"] { a.selected = true } else { a.windowSlot = true }
            }
        }
        if let w = b.params["win"]?.int {
            a.windowSlot = true
            if snap["window"].int == w { a.selected = true }
            if b.look == "agent_status", let st = snap["win.\(w).agent.status"].string {
                // several agents in the window: one line each ("Claude working" / "Codex asks"); colour = most urgent
                // (two Claudes both working: "2 Claude working")
                let all = (snap["win.\(w).agents"].string ?? "").split(separator: "|").map(String.init)
                var lines: [(String, Int)] = []
                for x in all {
                    if let i = lines.firstIndex(where: { $0.0 == x }) { lines[i].1 += 1 } else { lines.append((x, 1)) }
                }
                a.note = all.count > 1
                    ? lines.prefix(3).map { x, n in
                        let p = x.split(separator: ":").map(String.init)
                        return "\(n > 1 ? "\(n) " : "")\(p[0].capitalized) \(Looks.statusLabel(p.count > 1 ? p[1] : ""))"
                    }.joined(separator: "\n")
                    : Looks.statusLabel(st)
            }
        }
        return a
    }

    func defaultLabel(_ b: Binding, layer: Layer) -> String {
        if case .prompt(let n) = b.action { return config.promptLabel(n, layer: layer) ?? n }
        if case .layer(let id, _, _) = b.action { return config.layers[id]?.name ?? id }
        return b.passthrough.map { "Hold \($0)" } ?? ""
    }

    func describe(_ b: Binding) -> String {
        func d(_ a: Action?) -> String {
            guard let a else { return "" }
            switch a {
            case .keys(let k): return k.map(\.description).joined(separator: " ")
            case .text(let t): return "type “\(t.replacingOccurrences(of: "\n", with: "⏎"))”"
            case .tmux(let a): return "tmux " + a.joined(separator: " ")
            case .exec(let a): return a.joined(separator: " ")
            case .open(let s): return "open \(s)"
            case .shortcut(let s): return "Shortcut “\(s)”"
            case .menu(let m): return "menu " + m.joined(separator: " › ")
            case .script(let s): return "script \(s)"
            case .prompt(let p): return "prompt \(p)"
            case .layer(let id, let a, let t): return "\(a.rawValue) layer \(id)" + (t.map { " (\(Int($0))s)" } ?? "")
            case .agent(let s): return s.replacingOccurrences(of: "_", with: " ")
            case .mode(let s): return "\(s) permission mode"
            case .setState(let k, let v): return "set \(k) = \(v)"
            case .toast(let s): return s
            case .wait(let s): return "wait \(s)s"
            case .seq(let a): return a.map { d($0) }.joined(separator: ", ")
            case .legend(let s): return s == "pin" ? "pin legend" : "show legend"
            case .picker(let id): return "pick \(config.pickers[id]?.title ?? id)"
            case .search(let id): return "search \(config.pickers[id]?.title ?? id) (type or dictate)"
            case .answer(let n): return "answer option \(n)"
            case .answerRole(let r): return r == "no" ? "decline (Esc)" : (r == "always" ? "yes, and don't ask again" : "yes")
            case .decide(let ok): return ok ? "confirm" : "cancel"
            case .window(let d): return "\(d) window of this app"
            case .tab(let d): return d == "next" ? "next tab (last → first)" : "previous tab (first → last)"
            case .pressButton(let n): return "press “\(n.joined(separator: "” / “"))”"
            case .focusWindow(let w): return "go to \(w.split(separator: "\u{1F}").last ?? "")"
            case .app(let n): return n == "previous" ? "back to the previous app" : "bring \(n) to the front (again: its next window)"
            case .input(let p, _): return "ask: \(p)"
            }
        }
        var parts: [String] = []
        if let p = b.passthrough { parts.append("hold = \(p)") }
        if b.cw != nil || b.ccw != nil { parts.append("↻ \(d(b.cw ?? b.action))  ↺ \(d(b.ccw ?? b.action))") }
        else if b.action != nil { parts.append((b.confirmHold ? "hold to confirm: " : "") + d(b.action)) }
        if let h = b.hold { parts.append("hold: " + d(h)) }
        return parts.joined(separator: " · ")
    }
}
