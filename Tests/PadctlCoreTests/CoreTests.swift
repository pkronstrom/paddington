import Foundation
import Testing
@testable import PadctlCore

let repoConfig = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("config")

func loadConfig() throws -> Config { try Config.load(root: repoConfig) }

func itermContext(cmd: String = "claude", window: Int = 2) -> Context {
    var c = Context()
    c.app = "com.googlecode.iterm2"; c.appName = "iTerm2"
    let panes = (1...3).map { w in
        PaneInfo(session: "main", window: w, windowName: "w\(w)", paneId: "%\(w)", active: w == window,
                 command: w == window ? cmd : "claude", path: "/tmp/w\(w)")
    }
    c.panes = panes
    c.focusedPane = panes[window - 1]
    return c
}

/// Windows 1–3 exist (as in itermContext), so window pads switch windows instead of playing drums.
let windowsSnap = Snapshot(values: ["win.1.exists": .bool(true), "win.2.exists": .bool(true), "win.3.exists": .bool(true)])

func plans(_ outs: [EngineOutput]) -> [Plan] {
    outs.compactMap { if case .plan(let p) = $0 { return p }; return nil }
}

@Suite struct ApprovalTests {
    /// Codex can settle a permission request itself (Guardian auto-review): the next tool call ends the wait.
    @Test func nextToolCallEndsApprovalWait() {
        let st = AgentStore()
        let sid: [String: Value] = ["session_id": .string("s1"), "tool_name": .string("Bash")]
        st.handle(event: "SessionStart", payload: sid, pane: "%1", now: 0)
        st.handle(event: "PermissionRequest", payload: sid, pane: "%1", now: 1)
        #expect(st.agent(forPane: "%1")?.status == .needs_approval)
        #expect(st.approvalWaits(now: 2).isEmpty && st.approvalWaits(now: 3.5).count == 1)
        st.handle(event: "PreToolUse", payload: sid, pane: "%1", now: 4)
        #expect(st.agent(forPane: "%1")?.status == .working)
        st.handle(event: "PermissionRequest", payload: sid, pane: "%1", now: 5)
        #expect(st.dismissApproval(session: "s1", now: 8))
        #expect(st.agent(forPane: "%1")?.status == .working)
    }
}

@Suite struct DrumTests {
    /// A window pad whose window doesn't exist uses its `empty` binding: a drum sound, no tmux command.
    @Test func emptyWindowPadPlaysDrum() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        let snap = Snapshot(values: ["win.1.exists": .bool(true)])
        // only window 1 exists: pads 2–8 are empty and get the kit in priority order, Kick first
        #expect(e.appearance("pad2", ctx: ctx, snap: snap).label == "Kick")
        #expect(e.appearance("pad3", ctx: ctx, snap: snap).label == "Snare")
        #expect(e.appearance("pad4", ctx: ctx, snap: snap).label == "Hat")
        let p = plans(e.handle(.down("pad3"), now: 0.1, ctx: ctx, snap: snap))
        #expect(p.count == 1 && p[0].steps.isEmpty && p[0].sound == "snare")
        _ = e.handle(.up("pad3"), now: 0.2, ctx: ctx, snap: snap)
        // windows 1–6: the two empty pads still make a beat
        let six = Snapshot(values: Dictionary(uniqueKeysWithValues: (1...6).map { ("win.\($0).exists", Value.bool(true)) }))
        #expect(e.appearance("pad7", ctx: ctx, snap: six).label == "Kick")
        #expect(e.appearance("pad8", ctx: ctx, snap: six).label == "Snare")
        // an existing window: the normal binding
        #expect(e.appearance("pad1", ctx: ctx, snap: snap).label == "Win 1")
        let w = plans(e.handle(.down("pad1"), now: 0.3, ctx: ctx, snap: snap))
        #expect(w.first?.steps == [.tmux(["select-window", "-t", "main:1"])])
    }
}

@Suite struct ConfigTests {
    @Test func shippedConfigLoads() throws {
        let c = try loadConfig()
        #expect(c.layers["default"] != nil)
        #expect(c.layers["claude"] != nil && c.layers["codex"] != nil && c.layers["tmux"] != nil)
        #expect(c.device.allControlNames.count == 16 + 8 + 10)
        #expect(c.warnings.isEmpty, "\(c.warnings)")
    }

    @Test func badTomlReportsFileAndLine() {
        #expect(throws: ConfigError.self) { try TOML.parse("a = \n", file: "x.toml") }
    }

    @Test func execMustBeList() {
        #expect(throws: ExprError.self) { try Binding.parse(.table(["exec": .string("rm -rf /")]), ctx: "pad1") }
    }
}

@Suite struct ExprTests {
    let snap: [String: Value] = ["agents.waiting": .number(2), "agent.status": .string("working")]
    func ev(_ s: String) throws -> Bool { try Expr.parse(s).eval { snap[$0] ?? .null }.truthy }

    @Test func comparisons() throws {
        #expect(try ev("agents.waiting > 0"))
        #expect(try ev("agent.status == 'working'"))
        #expect(try !ev("agent.status != \"working\""))
        #expect(try ev("not missing.key"))
        #expect(try ev("agents.waiting >= 2 and (agent.status == 'idle' or true)"))
    }

    @Test func rejectsGarbage() {
        #expect(throws: ExprError.self) { try Expr.parse("a == ") }
        #expect(throws: ExprError.self) { try Expr.parse("a ; b") }
    }

    @Test func interpolation() {
        #expect(interpolate("Waiting {agents.waiting}") { snap[$0] ?? .null } == "Waiting 2")
    }
}

@Suite struct DeviceTests {
    @Test func decodesPadsAndKnobs() throws {
        let c = try loadConfig()
        let d = DeviceDecoder(profile: c.device)
        #expect(d.decode(MIDIMessage(status: 0x90, channel: 9, data1: 38, data2: 100)) == [.down("pad3")])
        #expect(d.decode(MIDIMessage(status: 0x80, channel: 9, data1: 38, data2: 0)) == [.up("pad3")])
        #expect(d.decode(MIDIMessage(status: 0xB0, channel: 0, data1: 30, data2: 50)) == [])          // first value: no delta yet
        #expect(d.decode(MIDIMessage(status: 0xB0, channel: 0, data1: 30, data2: 52)) == [.turn("knob1", 2)])
        #expect(d.decode(MIDIMessage(status: 0xB0, channel: 0, data1: 30, data2: 51)) == [.turn("knob1", -1)])
        #expect(d.decode(MIDIMessage(status: 0xB0, channel: 0, data1: 27, data2: 127)) == [.down("play")])
    }

    @Test func knobBankB() throws {
        let c = try loadConfig()
        let d = DeviceDecoder(profile: c.device)
        _ = d.decode(MIDIMessage(status: 0xB0, channel: 0, data1: 38, data2: 10))
        #expect(d.decode(MIDIMessage(status: 0xB0, channel: 0, data1: 38, data2: 12)) == [.turn("knob1", 2)])
        #expect(d.knobBank == "B")
        let e = Engine(config: c)
        e.knobBank = "B"
        var ctx = Context(); ctx.app = "com.apple.TextEdit"
        // the legend never swaps on the (lagging) bank: bank-A action, bank-B one as altLabel
        #expect(e.appearance("knob1", ctx: ctx, snap: Snapshot()).altLabel == "Volume")
        #expect(e.appearance("knob1", ctx: ctx, snap: Snapshot(), shift: true).label == "Volume")
        #expect(e.appearance("knob6", ctx: ctx, snap: Snapshot(), shift: true).label == "Zoom")     // no shift binding: falls through
        #expect(e.appearance("pad1", ctx: ctx, snap: Snapshot()).label == "Copy")      // pads follow the pad bank only
    }

    @Test func encodings() {
        #expect(KnobEncoding.offset64.delta(66, last: nil) == 2)
        #expect(KnobEncoding.signBit.delta(65, last: nil) == -1)
        #expect(KnobEncoding.absolute.delta(10, last: 7) == 3)
    }
}

@Suite struct EngineTests {
    @Test func picksClaudeLayerOnlyForClaudePane() throws {
        let e = Engine(config: try loadConfig())
        #expect(e.baseLayer(itermContext()).id == "claude")
        #expect(e.baseLayer(itermContext(cmd: "fish")).id == "tmux")
        #expect(e.baseLayer(itermContext(cmd: "codex")).id == "codex")
        var noTmux = itermContext(); noTmux.focusedPane = nil
        #expect(e.baseLayer(noTmux).id == "default")
        var safari = Context(); safari.app = "com.apple.Safari"
        #expect(e.baseLayer(safari).id == "browser")
        var notes = Context(); notes.app = "com.apple.Notes"
        #expect(e.baseLayer(notes).id == "default")
    }

    @Test func windowPadTargetsFocusedSession() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        let p = plans(e.handle(.down("pad3"), now: 0, ctx: ctx, snap: windowsSnap))
        #expect(p.first?.steps == [.tmux(["select-window", "-t", "main:3"])])
        #expect(p.first?.pane == "%2")
    }

    @Test func codexInheritsTmuxWindows() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext(cmd: "codex")
        #expect(plans(e.handle(.down("pad1"), now: 0, ctx: ctx, snap: windowsSnap)).first?.steps == [.tmux(["select-window", "-t", "main:1"])])
        #expect(plans(e.handle(.down("pad15"), now: 1, ctx: ctx, snap: Snapshot())).first?.steps == [.tmuxText(pane: "%2", "/compact\n")])
    }

    @Test func textGoesToCapturedPane() throws {
        let e = Engine(config: try loadConfig())
        let p = plans(e.handle(.down("pad15"), now: 0, ctx: itermContext(), snap: Snapshot()))
        #expect(p.first?.steps == [.tmuxText(pane: "%2", "/compact\n")])
    }

    @Test func defaultLayerTypesToApp() throws {
        let e = Engine(config: try loadConfig())
        var ctx = Context(); ctx.app = "com.apple.TextEdit"
        let p = plans(e.handle(.down("pad1"), now: 0, ctx: ctx, snap: Snapshot()))
        #expect(p.first?.steps == [.keys([try KeyChord.parse("cmd+c")])])
    }

    @Test func padBankBIsShift() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        e.padBank = "B"
        #expect(e.baseLayer(ctx).id == "claude")
        let p = plans(e.handle(.down("pad1"), now: 0.1, ctx: ctx, snap: Snapshot()))
        #expect(p.first?.steps == [.tmux(["select-pane", "-t", "main:.1"])])
        #expect(!e.layerPath(ctx, now: 0).contains("Shift"))   // the bank lags, so the header doesn't claim it
        e.padBank = "A"
        #expect(!e.shiftActive)
    }

    @Test func closeHoldOpensChoices() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        #expect(plans(e.handle(.down("pad12"), now: 0, ctx: ctx, snap: Snapshot())).isEmpty)
        let early = plans(e.handle(.up("pad12"), now: 0.3, ctx: ctx, snap: Snapshot()))
        #expect(early.first?.steps == [.toast("Hold to confirm")])
        _ = e.handle(.down("pad12"), now: 1, ctx: ctx, snap: Snapshot())
        _ = e.tick(now: 2.1, ctx: ctx, snap: Snapshot())
        #expect(e.picker?.id == "close" && e.picker?.items[1].label == "Close window")
        _ = e.handle(.up("pad12"), now: 2.2, ctx: ctx, snap: Snapshot())
        let p = plans(e.handle(.down("play"), now: 2.5, ctx: ctx, snap: Snapshot()))
        #expect(p.first?.steps == [.tmux(["kill-window", "-t", "main:2"])])
    }

    @Test func newTapSplitsHoldOpensPicker() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        let home = NSHomeDirectory()
        _ = e.handle(.down("pad11"), now: 0, ctx: ctx, snap: Snapshot())
        let tap = plans(e.handle(.up("pad11"), now: 0.1, ctx: ctx, snap: Snapshot()))
        #expect(tap.first?.steps == [.tmux(["new-window", "-t", "main:", "-c", home + "/Projects/own", "claude"]),
                                     .tmux(["split-window", "-h", "-t", "main:", "-c", home + "/Projects/own"]),
                                     .tmux(["select-pane", "-t", "main:", "-L"])])
        _ = e.handle(.down("pad11"), now: 1, ctx: ctx, snap: Snapshot())
        _ = e.tick(now: 1.5, ctx: ctx, snap: Snapshot())
        #expect(e.picker?.id == "new-session")
        _ = e.handle(.up("pad11"), now: 1.6, ctx: ctx, snap: Snapshot())
        _ = e.handle(.turn("knob1", 3), now: 2, ctx: ctx, snap: Snapshot())
        _ = e.handle(.turn("knob1", 2), now: 2.05, ctx: ctx, snap: Snapshot())   // → "Claude in project…"
        #expect(e.picker?.items[e.picker!.index].label == "Claude in project…")
        _ = e.handle(.down("play"), now: 2.1, ctx: ctx, snap: Snapshot())
        #expect(e.picker?.id == "project-claude")                                 // nested folder list
    }

    @Test func defaultCloseTapVsLongHold() throws {
        let e = Engine(config: try loadConfig())
        var ctx = Context(); ctx.app = "com.apple.TextEdit"
        _ = e.handle(.down("pad12"), now: 0, ctx: ctx, snap: Snapshot())
        #expect(plans(e.handle(.up("pad12"), now: 0.2, ctx: ctx, snap: Snapshot())).first?.steps == [.keys([try KeyChord.parse("cmd+w")])])
        _ = e.handle(.down("pad12"), now: 1, ctx: ctx, snap: Snapshot())
        #expect(plans(e.tick(now: 2.6, ctx: ctx, snap: Snapshot())).isEmpty)          // not yet 2 s
        #expect(plans(e.tick(now: 3.05, ctx: ctx, snap: Snapshot())).first?.steps == [.keys([try KeyChord.parse("cmd+q")])])
        #expect(plans(e.handle(.up("pad12"), now: 3.2, ctx: ctx, snap: Snapshot())).isEmpty)
    }

    @Test func talkPassthroughAndSafety() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        let rc = try KeyChord.parse("rightcmd")
        #expect(plans(e.handle(.down("rec"), now: 0, ctx: ctx, snap: Snapshot())).first?.steps == [.keyDown(rc)])
        #expect(plans(e.handle(.up("rec"), now: 2, ctx: ctx, snap: Snapshot())).first?.steps == [.keyUp(rc)])
        _ = e.handle(.down("rec"), now: 10, ctx: ctx, snap: Snapshot())
        let safety = plans(e.tick(now: 10 + 301, ctx: ctx, snap: Snapshot()))
        #expect(safety.first?.steps.first == .keyUp(rc))
    }

    @Test func knobTurnsRepeat() throws {
        let e = Engine(config: try loadConfig())
        let p = plans(e.handle(.turn("knob1", -2), now: 0, ctx: itermContext(), snap: Snapshot()))
        let up = try KeyChord.parse("up")
        #expect(p.first?.steps == [.tmuxKeys(pane: "%2", [up]), .tmuxKeys(pane: "%2", [up])])
    }

    @Test func holdPlayShowsLegendTapIsEnter() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        _ = e.handle(.down("play"), now: 0, ctx: ctx, snap: Snapshot())
        #expect(plans(e.handle(.up("play"), now: 0.1, ctx: ctx, snap: Snapshot())).first?.steps == [.tmuxKeys(pane: "%2", [try KeyChord.parse("enter")])])
        _ = e.handle(.down("play"), now: 1, ctx: ctx, snap: Snapshot())
        #expect(e.tick(now: 1.6, ctx: ctx, snap: Snapshot()) == [.legend(.showHeld)])
        #expect(e.handle(.up("play"), now: 3, ctx: ctx, snap: Snapshot()) == [.legend(.hideHeld)])
    }

    @Test func nextWaitingUsesSnapshot() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        let none = plans(e.handle(.down("pad9"), now: 0, ctx: ctx, snap: Snapshot()))
        #expect(none.first?.steps == [.toast("No agent is waiting")])
        let snap = Snapshot(values: ["agents.oldest_waiting": .string("%3")])
        #expect(plans(e.handle(.down("pad9"), now: 1, ctx: ctx, snap: snap)).first?.steps == [.focusPane("%3")])
    }

    @Test func promptFileIsInterpolated() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        e.padBank = "B"
        #expect(e.appearance("pad16", ctx: ctx, snap: Snapshot()).altLabel == "Prompts…")
        _ = e.handle(.down("pad16"), now: 0.1, ctx: ctx, snap: Snapshot())
        #expect(e.picker?.items[1].label == "Review diff")
        let p = plans(e.handle(.down("play"), now: 0.2, ctx: ctx, snap: Snapshot()))
        #expect(p.first?.steps == [.tmuxText(pane: "%2", "Review the uncommitted diff in /tmp/w2. List bugs first, then risks. Don't edit files.")])
    }
}

@Suite struct ModalTests {
    @Test func pickerScrollsAndCommits() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        _ = e.handle(.turn("knob7", 1), now: 0, ctx: ctx, snap: Snapshot())
        #expect(e.picker?.id == "model")
        _ = e.handle(.turn("knob1", 2), now: 0.2, ctx: ctx, snap: Snapshot())   // any knob moves it
        #expect(e.picker?.index == 3)          // 0 = Cancel, opens on 1
        let p = plans(e.handle(.down("play"), now: 0.4, ctx: ctx, snap: Snapshot()))
        #expect(p.first?.steps == [.tmuxText(pane: "%2", "/model fable\n")])
        #expect(e.picker == nil)
        #expect(plans(e.handle(.up("play"), now: 0.5, ctx: ctx, snap: Snapshot())).isEmpty)
    }

    @Test func pickerCancelEntry() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        _ = e.handle(.turn("knob7", 1), now: 0, ctx: ctx, snap: Snapshot())
        _ = e.handle(.turn("knob7", -1), now: 0.1, ctx: ctx, snap: Snapshot())
        #expect(e.picker?.items[e.picker!.index].label == "✕ Cancel")
        let p = plans(e.handle(.down("play"), now: 0.2, ctx: ctx, snap: Snapshot()))
        #expect(p.allSatisfy { $0.steps.isEmpty } && p.first?.sound == "cancel")   // nothing runs, just the cancel sound
        #expect(e.picker == nil)
    }

    @Test func pickerCancelAndTimeout() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        _ = e.handle(.turn("knob8", 1), now: 0, ctx: ctx, snap: Snapshot())
        _ = e.handle(.down("pause"), now: 1, ctx: ctx, snap: Snapshot())
        #expect(e.picker == nil)
        _ = e.handle(.turn("knob8", 1), now: 2, ctx: ctx, snap: Snapshot())
        _ = e.tick(now: 2 + Engine.pickerTimeout + 1, ctx: ctx, snap: Snapshot())
        #expect(e.picker == nil)
    }

    @Test func modePickerUsesClosedLoop() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        _ = e.handle(.down("pad14"), now: 0, ctx: ctx, snap: Snapshot())
        _ = e.tick(now: 0.6, ctx: ctx, snap: Snapshot())
        #expect(e.picker?.id == "modes")
        _ = e.handle(.up("pad14"), now: 0.7, ctx: ctx, snap: Snapshot())
        _ = e.handle(.turn("knob1", 2), now: 1, ctx: ctx, snap: Snapshot())
        let p = plans(e.handle(.down("play"), now: 1.2, ctx: ctx, snap: Snapshot()))
        #expect(p.first?.steps == [.setMode(pane: "%2", target: "plan")])
    }

    @Test func rewindEntersMenuNavForTwoSelects() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        _ = e.handle(.down("pad13"), now: 0, ctx: ctx, snap: Snapshot())
        #expect(e.stack.last?.layer == "menu-nav")
        let down = try KeyChord.parse("down")
        #expect(plans(e.handle(.turn("knob1", 1), now: 1, ctx: ctx, snap: Snapshot())).first?.steps == [.tmuxKeys(pane: "%2", [down])])
        _ = e.handle(.down("play"), now: 2, ctx: ctx, snap: Snapshot())
        #expect(e.stack.last?.layer == "menu-nav")       // rewind has a second menu
        _ = e.handle(.down("play"), now: 3, ctx: ctx, snap: Snapshot())
        #expect(e.stack.isEmpty)
    }

    @Test func pauseLeavesMenuNavAtOnce() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        _ = e.handle(.down("pad13"), now: 0, ctx: ctx, snap: Snapshot())
        _ = e.handle(.down("pause"), now: 1, ctx: ctx, snap: Snapshot())
        #expect(e.stack.isEmpty)
    }

    @Test func anyPadSelectsInMenuNav() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        _ = e.handle(.down("pad13"), now: 0, ctx: ctx, snap: Snapshot())
        let p = plans(e.handle(.down("pad3"), now: 1, ctx: ctx, snap: Snapshot()))
        #expect(p.first?.steps == [.tmuxKeys(pane: "%2", [try KeyChord.parse("enter")])])
        #expect(e.stack.last?.layer == "menu-nav")      // rewind's second menu
        _ = e.handle(.down("pad5"), now: 2, ctx: ctx, snap: Snapshot())
        #expect(e.stack.isEmpty)
    }

    @Test func anyPadSelectsInPicker() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        _ = e.handle(.turn("knob8", 1), now: 0, ctx: ctx, snap: Snapshot())
        let p = plans(e.handle(.down("pad12"), now: 1, ctx: ctx, snap: Snapshot()))
        #expect(p.first?.steps == [.tmuxText(pane: "%2", "/effort low\n")])
        #expect(plans(e.handle(.up("pad12"), now: 1.1, ctx: ctx, snap: Snapshot())).isEmpty)
    }

    @Test func answerLayerAppearsForQuestions() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        let s = AgentStore()
        let q: Value = .table(["questions": .array([.table(["question": .string("Which store?"), "options": .array([
            .table(["label": .string("SQLite")]), .table(["label": .string("Redis")])])])])])
        s.handle(event: "PreToolUse", payload: ["session_id": .string("a"), "tool_name": .string("AskUserQuestion"),
                                                "tool_use_id": .string("t"), "tool_input": q], pane: "%2", now: 0)
        let snap = Snapshot.build(context: ctx, agents: s, custom: [:], layerPath: "")
        #expect(e.appearance("pad2", ctx: ctx, snap: snap).label == "2 · Redis")
        #expect(e.appearance("pad3", ctx: ctx, snap: snap).label == "Win 3")      // only 2 options: pad3 falls through
        #expect(plans(e.handle(.down("pad2"), now: 1, ctx: ctx, snap: snap)).first?.steps
                == [.tmuxKeys(pane: "%2", [KeyChord(modifiers: [], key: "2")])])
        #expect(e.layerPath(ctx, now: 1, snap: snap).contains("Claude asks"))
    }

    @Test func shiftLabelsShownAsAlt() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        let a = e.appearance("pad13", ctx: ctx, snap: Snapshot())
        #expect(a.label == "Rewind" && a.altLabel == "/clear")
        e.padBank = "B"
        let b = e.appearance("pad13", ctx: ctx, snap: Snapshot())
        #expect(b.label == "Rewind" && b.altLabel == "/clear")   // fixed: bank A on the face, bank B above
    }
}

@Suite struct BrowserTests {
    @Test func searchPadsAndQuickChats() throws {
        let e = Engine(config: try loadConfig())
        var ctx = Context(); ctx.app = "org.mozilla.firefox"
        #expect(e.baseLayer(ctx).id == "browser")
        _ = e.handle(.down("pad13"), now: 0, ctx: ctx, snap: Snapshot())
        let tap = plans(e.handle(.up("pad13"), now: 0.1, ctx: ctx, snap: Snapshot()))
        #expect(tap.first?.steps == [.keys([try KeyChord.parse("cmd+t")]), .wait(0.25), .typeText("https://www.google.com\n")])
        _ = e.handle(.down("pad14"), now: 1, ctx: ctx, snap: Snapshot())
        let hold = plans(e.tick(now: 1.6, ctx: ctx, snap: Snapshot()))
        #expect(hold.first?.steps.last == .typeText("https://duckduckgo.com/?q=%CLIPBOARD_Q%\n"))
        #expect(plans(e.handle(.down("pad15"), now: 2, ctx: ctx, snap: Snapshot())).isEmpty)   // has a hold: fires on release
        #expect(plans(e.handle(.up("pad15"), now: 2.1, ctx: ctx, snap: Snapshot())).first?.steps == [.keys([try KeyChord.parse("alt+space")])])
        _ = e.handle(.down("pad16"), now: 3, ctx: ctx, snap: Snapshot())
        #expect(plans(e.handle(.down("pad16"), now: 3, ctx: ctx, snap: Snapshot())).first?.steps == [.keys([try KeyChord.parse("alt"), try KeyChord.parse("alt")])])
    }
}

@Suite struct InputTests {
    @Test func worktreeFromDictatedTask() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        _ = e.handle(.down("pad11"), now: 0, ctx: ctx, snap: Snapshot())
        _ = e.tick(now: 0.6, ctx: ctx, snap: Snapshot())                         // hold New → list
        _ = e.handle(.up("pad11"), now: 0.7, ctx: ctx, snap: Snapshot())
        _ = e.handle(.turn("knob1", 3), now: 1, ctx: ctx, snap: Snapshot())       // → "Claude worktree (dictate task)…"
        #expect(e.picker?.items[e.picker!.index].label == "Claude worktree (dictate task)…")
        let out = e.handle(.down("play"), now: 1.1, ctx: ctx, snap: Snapshot())
        guard case .input(let req)? = out.first(where: { if case .input = $0 { return true }; return false }) else {
            Issue.record("no input request"); return
        }
        let p = plans(e.submitInput(req, text: "fix the $(rm) login bug", now: 2, ctx: ctx, snap: Snapshot()))
        #expect(p.first?.steps == [.exec(["workmux", "add", "-A", "-p", "fix the $(rm) login bug"], cwd: "/tmp/w2")])
    }
}

@Suite struct SoundTests {
    @Test func soundsFollowGroups() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        func sound(_ ev: ControlEvent, _ t: Double) -> String? { plans(e.handle(ev, now: t, ctx: ctx, snap: windowsSnap)).first?.sound }
        #expect(sound(.down("pad3"), 0) == "nav")                 // window switch
        #expect(sound(.down("pad15"), 1) == "act")                // Compact
        #expect(sound(.turn("knob1", 1), 2) == nil)               // ↑↓ knob silent
        #expect(sound(.turn("knob3", 1), 2.5) == "nav")           // window knob clicks
        _ = e.handle(.down("play"), now: 3, ctx: ctx, snap: Snapshot())
        #expect(plans(e.handle(.up("play"), now: 3.1, ctx: ctx, snap: Snapshot())).first?.sound == nil)   // Enter silent
        _ = e.handle(.down("pad11"), now: 4, ctx: ctx, snap: Snapshot())
        #expect(plans(e.handle(.up("pad11"), now: 4.1, ctx: ctx, snap: Snapshot())).first?.sound == "new")
        #expect(sound(.down("pad16"), 5) == "picker")             // Skills… opens a list
        #expect(sound(.turn("knob1", 1), 5.5) == "scroll")        // moving in the list
        #expect(sound(.down("pad4"), 6) == "select")              // a pad selects in the list
        _ = e.handle(.down("pad16"), now: 7, ctx: ctx, snap: Snapshot())
        #expect(sound(.down("pause"), 8) == "cancel")             // ⏸ cancels
        _ = e.handle(.down("pad13"), now: 9, ctx: ctx, snap: Snapshot())   // Rewind → menu
        #expect(sound(.turn("knob1", 1), 10) == "scroll")
        #expect(sound(.down("pause"), 11) == "cancel")
    }
}

@Suite struct AgentTests {
    func payload(_ sid: String, _ extra: [String: Value] = [:]) -> [String: Value] {
        var p: [String: Value] = ["session_id": .string(sid)]
        for (k, v) in extra { p[k] = v }
        return p
    }

    @Test func lifecycle() {
        let s = AgentStore()
        s.handle(event: "SessionStart", payload: payload("a", ["permission_mode": .string("auto")]), pane: "%1", now: 0)
        #expect(s.agent(forPane: "%1")?.status == .idle)
        #expect(s.agent(forPane: "%1")?.mode == "auto")
        s.handle(event: "UserPromptSubmit", payload: payload("a"), pane: "%1", now: 1)
        #expect(s.agent(forPane: "%1")?.status == .working)
        s.handle(event: "PreToolUse", payload: payload("a", ["tool_name": .string("AskUserQuestion"), "tool_use_id": .string("t1")]), pane: "%1", now: 2)
        #expect(s.agent(forPane: "%1")?.status == .needs_input)
        // an unrelated tool finishing must not clear the pending question
        s.handle(event: "PostToolUse", payload: payload("a", ["tool_name": .string("Bash"), "tool_use_id": .string("t0")]), pane: "%1", now: 3)
        #expect(s.agent(forPane: "%1")?.status == .needs_input)
        s.handle(event: "PostToolUse", payload: payload("a", ["tool_name": .string("AskUserQuestion"), "tool_use_id": .string("t1")]), pane: "%1", now: 4)
        #expect(s.agent(forPane: "%1")?.status == .working)
        s.handle(event: "Stop", payload: payload("a"), pane: "%1", now: 5)
        #expect(s.agent(forPane: "%1")?.status == .done_unread)
        s.visit(pane: "%1", now: 6)
        #expect(s.agent(forPane: "%1")?.status == .idle)
    }

    @Test func idlePromptIsNotWaiting() {
        let s = AgentStore()
        s.handle(event: "UserPromptSubmit", payload: payload("a"), pane: "%1", now: 0)
        s.handle(event: "Notification", payload: payload("a", ["notification_type": .string("idle_prompt")]), pane: "%1", now: 1)
        #expect(s.agent(forPane: "%1")?.status == .done_unread)
    }

    @Test func newSessionReplacesOldInPane() {
        let s = AgentStore()
        s.handle(event: "SessionStart", payload: payload("old"), pane: "%1", now: 0)
        s.handle(event: "SessionStart", payload: payload("new"), pane: "%1", now: 1)
        #expect(s.agents.count == 1)
        #expect(s.agent(forPane: "%1")?.sessionId == "new")
    }

    @Test func snapshotWindowsAndWaiting() {
        let s = AgentStore()
        s.handle(event: "PermissionRequest", payload: payload("a", ["tool_name": .string("Bash")]), pane: "%3", now: 0)
        s.handle(event: "UserPromptSubmit", payload: payload("b"), pane: "%1", now: 0)
        let snap = Snapshot.build(context: itermContext(), agents: s, custom: [:], layerPath: "Claude")
        #expect(snap["win.3.agent.status"] == .string("needs_approval"))
        #expect(snap["win.1.agent.status"] == .string("working"))
        #expect(snap["win.2.agent.status"] == .string("unknown"))   // claude pane without events yet
        #expect(snap["agents.waiting"] == .number(1))
        #expect(snap["agents.oldest_waiting"] == .string("%3"))
    }

    @Test func statuslineContextMeter() throws {
        let s = AgentStore()
        let payload: [String: Value] = ["session_id": .string("a"),
                                        "context_window": .table(["used_percentage": .number(85)]),
                                        "rate_limits": .table(["five_hour": .table(["used_percentage": .number(42)])])]
        s.statusline(payload: payload, pane: "%2", now: 0)
        let ctx = itermContext()
        let snap = Snapshot.build(context: ctx, agents: s, custom: [:], layerPath: "")
        #expect(snap["agent.context"] == .number(85) && snap["usage.5h"] == .number(42))
        let e = Engine(config: try loadConfig())
        let a = e.appearance("pad15", ctx: ctx, snap: snap)
        #expect(a.label == "Compact 85%" && a.key == "danger")
    }

    @Test func reconcileDropsDeadPanes() {
        let s = AgentStore()
        s.handle(event: "SessionStart", payload: payload("a"), pane: "%9", now: 0)
        s.reconcile(panes: itermContext().panes, agentCommands: ["claude"])
        #expect(s.agents.isEmpty)
    }
}
