import Foundation
import Testing
@testable import PaddingtonCore

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

/// An idle pad: a drum — dark, and a press only plays its sound.
func isDrum(_ a: Appearance) -> Bool { a.key == "drum" || a.key == "sample" }
func drumOnly(_ outs: [EngineOutput]) -> Bool {
    let p = plans(outs)
    return p.count == 1 && p[0].steps.isEmpty && !(p[0].sound ?? "").isEmpty
}

func plans(_ outs: [EngineOutput]) -> [Plan] {
    outs.compactMap { if case .plan(let p) = $0 { return p }; return nil }
}

@Suite struct LegendHoldTests {
    /// ▶ shows the legend after legend_hold (250 ms), sooner than other holds; a quick tap is still Enter.
    @Test func shortHoldShowsLegend() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        _ = e.handle(.down("play"), now: 0, ctx: ctx, snap: windowsSnap)
        #expect(e.tick(now: 0.2, ctx: ctx, snap: windowsSnap).isEmpty)
        #expect(e.tick(now: 0.3, ctx: ctx, snap: windowsSnap).contains(.legend(.showHeld)))
        _ = e.handle(.up("play"), now: 0.6, ctx: ctx, snap: windowsSnap)
        _ = e.handle(.down("play"), now: 1, ctx: ctx, snap: windowsSnap)
        _ = e.tick(now: 1.1, ctx: ctx, snap: windowsSnap)
        let tap = plans(e.handle(.up("play"), now: 1.12, ctx: ctx, snap: windowsSnap))
        #expect(tap.first?.steps == [.tmuxKeys(pane: "%2", [try KeyChord.parse("enter")])])
    }
}

@Suite struct TmuxToolsTests {
    /// Hold > in a tmux / Claude / Codex pane: the tmux tools layer (legend up); one action and it closes.
    @Test func holdRightOpensTmuxTools() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()                                    // Claude in window 2, pane %2
        _ = e.handle(.down("right"), now: 0, ctx: ctx, snap: Snapshot())
        _ = e.tick(now: 0.6, ctx: ctx, snap: Snapshot())
        _ = e.handle(.up("right"), now: 0.7, ctx: ctx, snap: Snapshot())
        #expect(e.stack.last?.layer == "tmux-tools" && e.effectiveStack(ctx, Snapshot()).contains { $0.showsLegend })
        #expect(plans(e.handle(.down("pad1"), now: 1, ctx: ctx, snap: Snapshot())).first?.steps
                == [.tmux(["split-window", "-h", "-t", "%2", "-c", "/tmp/w2"])])
        #expect(e.stack.isEmpty)                                    // one action and it closes
        _ = e.handle(.up("pad1"), now: 1.1, ctx: ctx, snap: Snapshot())
        // > again closes it without doing anything; a tap is still next window
        _ = e.handle(.down("right"), now: 2, ctx: ctx, snap: Snapshot())
        _ = e.tick(now: 2.6, ctx: ctx, snap: Snapshot())
        _ = e.handle(.up("right"), now: 2.7, ctx: ctx, snap: Snapshot())
        _ = e.handle(.down("right"), now: 3, ctx: ctx, snap: Snapshot())
        #expect(e.stack.isEmpty)
        _ = e.handle(.up("right"), now: 3.1, ctx: ctx, snap: Snapshot())
        _ = e.handle(.down("right"), now: 4, ctx: ctx, snap: Snapshot())
        #expect(plans(e.handle(.up("right"), now: 4.1, ctx: ctx, snap: Snapshot())).first?.steps == [.tmux(["next-window", "-t", "main:"])])
        // in Codex too
        _ = e.handle(.down("right"), now: 5, ctx: itermContext(cmd: "codex"), snap: Snapshot())
        _ = e.tick(now: 5.6, ctx: itermContext(cmd: "codex"), snap: Snapshot())
        #expect(e.stack.last?.layer == "tmux-tools")
    }
}

@Suite struct AgentsOverviewTests {
    /// Hold < anywhere: every agent on a pad, waiting ones first (blinking); tap one → iTerm forward on that pane.
    @Test func overviewSortsAndJumps() throws {
        let e = Engine(config: try loadConfig())
        var ctx = Context(); ctx.app = "org.mozilla.firefox"; ctx.appName = "Firefox"
        ctx.panes = itermContext().panes                         // %1 %2 %3: claude in windows 1–3
        let store = AgentStore()
        for (sid, pane) in [("a", "%1"), ("b", "%2"), ("c", "%3")] {
            store.handle(event: "SessionStart", payload: ["session_id": .string(sid)], pane: pane, now: 0)
            store.handle(event: "UserPromptSubmit", payload: ["session_id": .string(sid)], pane: pane, now: 1)
        }
        store.handle(event: "Stop", payload: ["session_id": .string("c")], pane: "%3", now: 2)
        store.handle(event: "PermissionRequest", payload: ["session_id": .string("b"), "tool_name": .string("Bash")], pane: "%2", now: 3)
        store.showApproval(session: "b", now: 3)
        let snap = Snapshot.build(context: ctx, agents: store, custom: ["sounds.agents": .bool(true)], layerPath: "")
        // hold <: the overview opens (a tap would toggle iTerm instead)
        _ = e.handle(.down("left"), now: 10, ctx: ctx, snap: snap)
        _ = e.tick(now: 10.8, ctx: ctx, snap: snap)
        _ = e.handle(.up("left"), now: 11, ctx: ctx, snap: snap)
        #expect(e.stack.last?.layer == "agents")
        #expect(e.effectiveStack(ctx, snap).contains { $0.showsLegend })          // the legend comes up with it
        let (p1, p2, p3, p4) = (e.appearance("pad1", ctx: ctx, snap: snap), e.appearance("pad2", ctx: ctx, snap: snap),
                                e.appearance("pad3", ctx: ctx, snap: snap), e.appearance("pad4", ctx: ctx, snap: snap))
        #expect(p1.label == "2 · w2" && p1.note == "Claude approve?" && p1.blink)
        #expect(p2.label == "3 · w3" && p2.note == "Claude done ✓" && p2.blink)
        #expect(p3.label == "1 · w1" && p3.note == "Claude working" && !p3.blink)
        #expect(isDrum(p4) && drumOnly(e.handle(.down("pad4"), now: 12, ctx: ctx, snap: snap)))   // no agent there: a drum
        #expect(isDrum(e.appearance("pad15", ctx: ctx, snap: snap)))                          // row 4: only Sounds
        #expect(e.appearance("pad13", ctx: ctx, snap: snap).label == "🔔 Sounds on" && e.appearance("pad13", ctx: ctx, snap: snap).key == "ok")
        var muted = snap; muted.values["sounds.agents"] = .bool(false)
        #expect(e.appearance("pad13", ctx: ctx, snap: muted).label == "🔕 Sounds muted" && e.appearance("pad13", ctx: ctx, snap: muted).key == "danger")
        #expect(plans(e.handle(.down("pad13"), now: 12.5, ctx: ctx, snap: snap)).first?.steps == [.setState("@sounds.agents", .string("toggle"))])
        let jump = plans(e.handle(.down("pad1"), now: 13, ctx: ctx, snap: snap))
        #expect(jump.first?.steps == [.openApp("com.googlecode.iterm2"), .wait(0.2), .focusPane("%2")])
        #expect(e.stack.isEmpty && !e.effectiveStack(ctx, snap).contains { $0.showsLegend })   // …and goes with it
        // a quick tap of < still toggles iTerm
        _ = e.handle(.down("left"), now: 20, ctx: ctx, snap: snap)
        #expect(plans(e.handle(.up("left"), now: 20.1, ctx: ctx, snap: snap)).first?.steps == [.keys([try KeyChord.parse("ctrl+<")])])
    }
}

@Suite struct QuestionNotApprovalTests {
    /// Claude Code sends a PermissionRequest for its own AskUserQuestion: that stays a question (Choose layer),
    /// never a flash of the red / green Allow? layer.
    @Test func askUserQuestionPermissionIsAQuestion() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        let store = AgentStore()
        let q: Value = .table(["questions": .array([.table(["question": .string("Which store?"), "options": .array([
            .table(["label": .string("SQLite")]), .table(["label": .string("Redis")])])])])])
        store.handle(event: "SessionStart", payload: ["session_id": .string("a")], pane: "%2", now: 0)
        store.handle(event: "PreToolUse", payload: ["session_id": .string("a"), "tool_name": .string("AskUserQuestion"),
                                                    "tool_use_id": .string("t"), "tool_input": q], pane: "%2", now: 1)
        store.handle(event: "PermissionRequest", payload: ["session_id": .string("a"), "tool_name": .string("AskUserQuestion")], pane: "%2", now: 1.1)
        #expect(store.agent(forPane: "%2")?.status == .needs_input)
        let snap = Snapshot.build(context: ctx, agents: store, custom: [:], layerPath: "")
        #expect(e.layerPath(ctx, now: 2, snap: snap).contains("Choose") && !e.layerPath(ctx, now: 2, snap: snap).contains("Allow?"))
        // and a real permission prompt still asks yes / no, once it's on screen
        store.handle(event: "PermissionRequest", payload: ["session_id": .string("b"), "tool_name": .string("Bash")], pane: "%3", now: 3)
        #expect(store.showApproval(session: "b", now: 3.5) && store.agent(forPane: "%3")?.status == .needs_approval)
    }
}

@Suite struct StoppedAgentTests {
    /// An agent that stopped (Stop hook) waits for you too: its window pad blinks green and it counts as waiting —
    /// after questions and approvals in the "next waiting" order. Looking at the pane makes it idle.
    @Test func stoppedAgentWaitsForYou() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext(window: 1)
        let store = AgentStore()
        store.handle(event: "SessionStart", payload: ["session_id": .string("a")], pane: "%2", now: 0)
        store.handle(event: "UserPromptSubmit", payload: ["session_id": .string("a")], pane: "%2", now: 1)
        store.handle(event: "Stop", payload: ["session_id": .string("a")], pane: "%2", now: 5)
        var snap = Snapshot.build(context: ctx, agents: store, custom: [:], layerPath: "")
        let pad = e.appearance("pad2", ctx: ctx, snap: snap)
        #expect(pad.key == "done_unread" && pad.blink && pad.note == "done ✓")
        #expect(snap["agents.waiting"].int == 1 && snap["agents.oldest_waiting.reason"].string == "done")
        // a question elsewhere comes first, even though it's newer
        store.handle(event: "SessionStart", payload: ["session_id": .string("b")], pane: "%3", now: 0)
        store.handle(event: "PermissionRequest", payload: ["session_id": .string("b"), "tool_name": .string("Bash")], pane: "%3", now: 9)
        store.showApproval(session: "b", now: 9)
        snap = Snapshot.build(context: ctx, agents: store, custom: [:], layerPath: "")
        #expect(snap["agents.oldest_waiting"].string == "%3" && snap["agents.waiting"].int == 2)
        // seen: no longer waiting
        store.visit(pane: "%2", now: 10)
        snap = Snapshot.build(context: ctx, agents: store, custom: [:], layerPath: "")
        #expect(e.appearance("pad2", ctx: ctx, snap: snap).blink == false)
    }

    /// Looking at a window counts for every pane in it (an agent in the pane next to the focused shell is on
    /// screen too), but not while the window is zoomed to another pane.
    @Test func visitingAWindowSeesAllItsPanes() {
        func pane(_ id: String, _ w: Int, _ cmd: String) -> PaneInfo {
            PaneInfo(session: "main", window: w, windowName: "w\(w)", paneId: id, active: id == "%1", command: cmd, path: "/tmp")
        }
        var shell = pane("%1", 1, "fish")
        let panes = [shell, pane("%2", 1, "claude"), pane("%3", 2, "codex")]
        let st = AgentStore()
        for (sid, p) in [("a", "%2"), ("b", "%3")] {
            st.handle(event: "SessionStart", payload: ["session_id": .string(sid)], pane: p, now: 0)
            st.handle(event: "Stop", payload: ["session_id": .string(sid)], pane: p, now: 1)
        }
        shell.zoomed = true
        #expect(!st.visit(focused: shell, panes: panes, now: 2))                   // zoomed to the shell: %2 unseen
        shell.zoomed = false
        #expect(st.visit(focused: shell, panes: panes, now: 3))
        #expect(st.agent(forPane: "%2")?.status == .idle && st.agent(forPane: "%3")?.status == .done_unread)
    }
}

@Suite struct WindowStatusTests {
    /// A window with Claude and Codex: one line per agent on its pad; the colour follows the most urgent.
    @Test func severalAgentsInOneWindow() throws {
        let e = Engine(config: try loadConfig())
        var ctx = itermContext()
        ctx.panes.append(PaneInfo(session: "main", window: 2, windowName: "w2", paneId: "%9", active: false, command: "codex", path: "/tmp/w2"))
        let store = AgentStore()
        store.handle(event: "SessionStart", payload: ["session_id": .string("c1")], pane: "%2", now: 0)
        store.handle(event: "UserPromptSubmit", payload: ["session_id": .string("c1")], pane: "%2", now: 1)
        store.handle(event: "SessionStart", payload: ["session_id": .string("x1")], pane: "%9", now: 0)
        store.handle(event: "PermissionRequest", payload: ["session_id": .string("x1"), "tool_name": .string("Bash")], pane: "%9", now: 2)
        store.showApproval(session: "x1", now: 2)
        let snap = Snapshot.build(context: ctx, agents: store, custom: [:], layerPath: "")
        let a = e.appearance("pad2", ctx: ctx, snap: snap)
        #expect(a.note == "Claude working\nCodex approve?")
        #expect(a.key == "needs_approval" && a.blink)
    }
}

@Suite struct ChoicesTests {
    @Test func claudeAskUserQuestion() {
        let screen = """
        ⏺ Let me ask a few questions.

        ────────────────────────────────────────────────
         ☐ Layout  ☐ Colours  ✔ Submit  →

        Which layout do you prefer?

        ❯ 1. Compact
             Smaller pads, more on screen
          2. Large
             Bigger pads
          3. Type something.
          4. Chat about this

        Enter to select · ↑/↓ to navigate · Esc to cancel
        """
        let c = ScreenChoices.parse(screen)
        #expect(c?.options.map(\.label) == ["Compact", "Large", "Type something.", "Chat about this"])
        #expect(c?.selected == 0)
        #expect(c?.title == "Which layout do you prefer?")
        #expect(c?.vars["q.other"] == .number(3))                  // the first free-form option: dictate
        #expect(c?.vars["q.label.1"] == .string("1 · Compact"))
    }

    @Test func claudePermissionAndCodexQuestion() {
        let permission = """
         Bash command
           git push origin main
         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don't ask again for git push commands
           3. No, and tell Claude what to do differently (esc)
        """
        let p = ScreenChoices.parse(permission)
        #expect(p?.options.count == 3 && p?.options[2].freeForm == true && p?.title == "Do you want to proceed?")
        #expect(p?.vars["q.confirm"] == .bool(true) && p?.vars["q.yes"] == .number(1) && p?.vars["q.always"] == .number(2) && p?.vars["q.no"] == .number(3))
        #expect(ScreenChoices.parse("""
        Which layout?
        ❯ 1. Compact
          2. Large
        """)?.vars["q.confirm"] == nil)                          // a question, not a confirmation
        let codex = """
          Question 1/2: Which database should the prototype use?
          › 1. Postgres (Recommended)
            2. SQLite
            o. Other (free-form)
        """
        let q = ScreenChoices.parse(codex)
        #expect(q?.options.map(\.key) == ["1", "2", "o"])
        #expect(q?.options.last?.freeForm == true)
    }

    @Test func plainListsDontCount() {
        let reply = """
        ⏺ Next steps:
          1. Add the tests
          2. Run them
          3. Commit

        › Ask Codex to do anything
        """
        #expect(ScreenChoices.parse(reply) == nil)                 // no cursor on an option
    }
}

@Suite struct KnobStepTests {
    /// Window knob with step = 3: a fresh turn moves on its first unit, then every third; reversing moves at once.
    @Test func stepMakesKnobsLessSensitive() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        func moves(_ d: Int, _ t: Double) -> Int {
            plans(e.handle(.turn("knob3", d), now: t, ctx: ctx, snap: windowsSnap)).reduce(0) { $0 + $1.steps.count }
        }
        #expect(moves(1, 0) == 1)          // first click: next window
        #expect(moves(1, 0.1) == 0)
        #expect(moves(1, 0.2) == 0)
        #expect(moves(1, 0.3) == 1)        // third unit after the first move
        #expect(moves(6, 0.4) == 2)        // a fast flick: 6 units = 2 windows, not 6
        #expect(moves(-1, 0.5) == 1)       // back: moves at once
        #expect(moves(1, 2.0) == 1)        // after a pause, fresh again
    }
}

@Suite struct SearchTests {
    let items = [PickerItem(label: "/brainstromming", value: "brainstromming", detail: "Explore ideas before building"),
                 PickerItem(label: "/vault-skills", value: "vault-skills", detail: "Catalog of downloaded-but-inactive skills"),
                 PickerItem(label: "/vault-mcp", value: "vault-mcp", detail: "Vault of inactive MCP servers"),
                 PickerItem(label: "/rev", value: "rev", detail: "Review code changes"),
                 PickerItem(label: "◇ stop-slop · writing", value: "stop-slop", action: .text("/vault-skills writing/stop-slop "))]

    /// Dictated text: capitals, punctuation, spoken hyphens, extra words and a misspelt skill name.
    @Test func dictationFindsTheSkill() {
        func top(_ q: String) -> String? { PickerSearch.confident(PickerSearch.rank(items, q))?.value }
        #expect(top("Vault skills.") == "vault-skills")
        #expect(top("vault MCP") == "vault-mcp")
        #expect(top("Brainstorming") == "brainstromming")          // the skill's own name is misspelt
        #expect(top("the stop slop skill please") == "stop-slop")
        #expect(top("rev") == "rev")
        // VoiceInk sometimes hears English as Russian: transliterated + sound-alike still finds it
        let mixed = [PickerItem(label: "/handoff", value: "handoff"), PickerItem(label: "/rev", value: "rev"),
                     PickerItem(label: "/transcribe-media", value: "transcribe-media"),
                     PickerItem(label: "◇ claude-handoff · engineering", value: "claude-handoff"),
                     PickerItem(label: "◇ agent-transcript · engineering", value: "agent-transcript"),
                     PickerItem(label: "/vault-skills", value: "vault-skills"), PickerItem(label: "/vault-mcp", value: "vault-mcp")]
        func pick(_ q: String) -> String? { PickerSearch.confident(PickerSearch.rank(mixed, q))?.value }
        #expect(pick("Хэндофф.") == "handoff")
        #expect(pick("Хэнд оф.") == "handoff")
        #expect(pick("Транскрайб.") == "transcribe-media")
        #expect(pick("Ваулк Скиллс.") == "vault-skills")
        #expect(pick("transcribe") == "transcribe-media")
        #expect(PickerSearch.confident(PickerSearch.rank([PickerItem(label: "⧉ context7 · MCP", value: "context7")], "Context seven.")) != nil)
        #expect(top("vault") == nil)                                // two equally good: don't guess
        #expect(PickerSearch.rank(items, "review").first?.0.value == "rev")   // via the description
    }

    /// Hold ● and press Skills…: a search picker; typing filters, Enter takes the top match and types it.
    @Test func voiceChordOpensSearchAndCommits() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        _ = e.handle(.down("rec"), now: 0, ctx: ctx, snap: windowsSnap)
        let out = e.handle(.down("pad13"), now: 0.1, ctx: ctx, snap: windowsSnap)
        #expect(out.contains(.search))
        #expect(e.picker?.searching == true)
        _ = e.handle(.up("pad13"), now: 0.2, ctx: ctx, snap: windowsSnap)
        _ = e.handle(.up("rec"), now: 0.3, ctx: ctx, snap: windowsSnap)
        // ● pressed again while the list is open: dictation, not a choice
        _ = e.handle(.down("rec"), now: 0.4, ctx: ctx, snap: windowsSnap)
        #expect(e.picker != nil)
        _ = e.handle(.up("rec"), now: 0.5, ctx: ctx, snap: windowsSnap)
        e.filterPicker("rev", now: 0.6)
        #expect(e.picker?.index == -1)                       // the search row is highlighted
        #expect(e.picker?.items.first?.value == "rev")
        // a knob moves into the results and back up to the search row
        _ = e.handle(.turn("knob1", 1), now: 0.62, ctx: ctx, snap: windowsSnap)
        #expect(e.picker?.index == 0)
        _ = e.handle(.turn("knob1", -1), now: 0.64, ctx: ctx, snap: windowsSnap)
        #expect(e.picker?.index == -1)
        // from the search row, ▶ / Enter takes the top match
        let p = plans(e.commitPicker(now: 0.7, ctx: ctx, snap: windowsSnap))
        #expect(e.picker == nil)
        #expect(p.first?.steps.first == .tmuxText(pane: "%2", "/rev "))
    }
}

@Suite struct BackgroundSessionTests {
    /// Claude Code background sessions run their hooks outside tmux (no TMUX_PANE): the pane is the one Claude pane
    /// in that project no other session owns.
    @Test func paneFromTheProject() {
        func pane(_ id: String, _ cmd: String, _ path: String) -> PaneInfo {
            PaneInfo(session: "main", window: 1, windowName: "w", paneId: id, active: false, command: cmd, path: path)
        }
        let panes = [pane("%54", "claude", "/p/sous-chef"), pane("%7", "claude", "/p/sous-chef"),
                     pane("%26", "codex", "/p/sous-chef"), pane("%12", "claude", "/p/smc.pad")]
        let st = AgentStore()
        st.handle(event: "SessionStart", payload: ["session_id": .string("fg")], pane: "%54", now: 0)
        let ask: [String: Value] = ["session_id": .string("bg"), "tool_name": .string("AskUserQuestion"),
                                    "cwd": .string("/p/sous-chef/"), "tool_use_id": .string("t1")]
        st.handle(event: "PreToolUse", payload: ask, pane: "", panes: panes, now: 1)
        #expect(st.agent(forPane: "%7")?.status == .needs_input && st.agent(forPane: "%54")?.status == .idle)
        // from the transcript's folder name when the session's directory changed
        let other: [String: Value] = ["session_id": .string("bg2"), "cwd": .string("/p/smc.pad/Sources"),
                                      "transcript_path": .string("/u/.claude/projects/-p-smc-pad/bg2.jsonl")]
        st.handle(event: "UserPromptSubmit", payload: other, pane: nil, panes: panes, now: 2)
        #expect(st.agent(forPane: "%12")?.status == .working)
        // two unowned Claude panes in one project: no guess
        let st2 = AgentStore()
        st2.handle(event: "PreToolUse", payload: ask, pane: nil, panes: panes, now: 1)
        #expect(st2.agents.isEmpty)
    }
}

@Suite struct ApprovalTests {
    /// Codex settles most permission requests itself (Guardian auto-review) without drawing a prompt: a request is
    /// only "approve?" once its prompt is on screen, and the next tool call ends it either way.
    @Test func approvalWaitsForThePromptOnScreen() {
        let st = AgentStore()
        let sid: [String: Value] = ["session_id": .string("s1"), "tool_name": .string("Bash")]
        st.handle(event: "SessionStart", payload: sid, pane: "%1", now: 0)
        st.handle(event: "UserPromptSubmit", payload: sid, pane: "%1", now: 0.5)
        st.handle(event: "PermissionRequest", payload: sid, pane: "%1", now: 1)
        #expect(st.agent(forPane: "%1")?.status == .working && st.approvalRequests.count == 1)   // no flash, no sound
        st.handle(event: "PreToolUse", payload: sid, pane: "%1", now: 4)                         // Guardian said yes
        #expect(st.approvalRequests.isEmpty && !st.showApproval(session: "s1", now: 4))
        // a prompt that does show: waiting until it goes away
        st.handle(event: "PermissionRequest", payload: sid, pane: "%1", now: 5)
        #expect(st.showApproval(session: "s1", now: 5.5) && st.agent(forPane: "%1")?.status == .needs_approval)
        #expect(st.agent(forPane: "%1")?.reason == "Bash" && st.approvalRequests.isEmpty)
        #expect(st.approvalWaits(now: 6).isEmpty && st.approvalWaits(now: 8).count == 1)
        #expect(st.dismissApproval(session: "s1", now: 8) && st.agent(forPane: "%1")?.status == .working)
        #expect(st.approvalRequests.count == 1)                                  // back on screen? asks again
        st.handle(event: "PostToolUse", payload: sid, pane: "%1", now: 9)
        #expect(st.approvalRequests.isEmpty)
    }

    /// The focused pane's agent asks permission (hook) but nothing is on screen: no Allow? layer. The prompt on
    /// screen opens it.
    @Test func allowLayerFollowsTheScreen() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()                                     // focused: %2
        let store = AgentStore()
        store.handle(event: "SessionStart", payload: ["session_id": .string("x")], pane: "%2", now: 0)
        store.handle(event: "PermissionRequest", payload: ["session_id": .string("x"), "tool_name": .string("Bash")], pane: "%2", now: 1)
        var snap = Snapshot.build(context: ctx, agents: store, custom: [:], layerPath: "")
        #expect(!e.layerPath(ctx, now: 2, snap: snap).contains("Allow?"))
        let screen = ScreenChoices.parse("""
          Would you like to run the following command?
        › 1. Yes, proceed (y)
          2. No, and tell Codex what to do differently (esc)
        """)!
        store.showApproval(session: "x", now: 2)
        snap = Snapshot.build(context: ctx, agents: store, custom: [:], layerPath: "")
        snap.values.merge(screen.vars) { $1 }
        #expect(e.layerPath(ctx, now: 3, snap: snap).contains("Allow?"))
    }

    /// Only Yes / No options under a cursor count — not a reply that asks "Would you like to…".
    @Test func approvalOnScreen() {
        let codex = """
          Would you like to run the following command?
            $ git push origin main
        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for this command (a)
          3. No, and tell Codex what to do differently (esc)
        """
        #expect(AgentStore.approvalShown(codex) && AgentStore.approvalStillShown(codex))
        let reply = """
        • Done — the build passes. Would you like to also update the docs?
        › Summarize recent commits
        """
        #expect(!AgentStore.approvalShown(reply) && AgentStore.approvalStillShown(reply))
        #expect(!AgentStore.approvalShown("• Running cargo test\n  └ 12 passed"))
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

    /// Every idle pad is a drum, the kit handed out in pad order and starting over past its end.
    @Test func kitGoesRoundTheIdlePads() throws {
        let e = Engine(config: try loadConfig())
        var ctx = Context(); ctx.app = "com.example.nothing"            // the default layer
        let idle = (1...16).map { "pad\($0)" }.filter { isDrum(e.appearance($0, ctx: ctx, snap: Snapshot())) }
        let kit = e.config.settings.drumKit
        #expect(kit.first == "kick" && Engine.drumLabel("open_hat") == "Open hat")
        for (i, pad) in idle.enumerated() {
            #expect(e.appearance(pad, ctx: ctx, snap: Snapshot()).label == Engine.drumLabel(kit[i % kit.count]))
        }
    }

    /// Hold a drum pad: it records (red, blinking) until it's let go; a tap only plays it. A recorded pad plays its
    /// sample, and the kit skips it.
    @Test func holdADrumToSample() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        let snap = Snapshot(values: ["win.1.exists": .bool(true)])        // pads 2–8: drums
        #expect(drumOnly(e.handle(.down("pad3"), now: 0, ctx: ctx, snap: snap)))
        #expect(e.tick(now: 0.5, ctx: ctx, snap: snap).isEmpty)
        #expect(e.handle(.up("pad3"), now: 0.6, ctx: ctx, snap: snap).isEmpty)                    // a tap
        _ = e.handle(.down("pad3"), now: 1, ctx: ctx, snap: snap)
        #expect(e.tick(now: 1.9, ctx: ctx, snap: snap).contains(.sampler(.record("A.pad3"))))
        #expect(e.tick(now: 2.0, ctx: ctx, snap: snap).isEmpty)                                   // once
        let rec = e.appearance("pad3", ctx: ctx, snap: snap)
        #expect(rec.key == "danger" && !rec.blink && rec.selected && rec.label == "● Rec")      // solid red
        #expect(e.handle(.up("pad3"), now: 3, ctx: ctx, snap: snap).contains(.sampler(.stop("A.pad3"))))
        #expect(e.recording == nil)
        // the sample plays on pad 3; pad 2 keeps the kick, pad 4 gets the snare
        e.samples = ["A.pad3": "/tmp/A.pad3.1.wav@4"]
        let a3 = e.appearance("pad3", ctx: ctx, snap: snap)
        #expect(a3.label == "Sample" && a3.key == "sample")
        #expect(e.resolve("pad3", ctx, snap)?.0.params["gate"] == .bool(true))                // plays while held
        #expect(plans(e.handle(.down("pad3"), now: 4, ctx: ctx, snap: snap)).first?.sound == "/tmp/A.pad3.1.wav@4")
        #expect(e.tick(now: 6, ctx: ctx, snap: snap).isEmpty)                                    // holding it never records
        _ = e.handle(.up("pad3"), now: 6.1, ctx: ctx, snap: snap)
        #expect(e.appearance("pad2", ctx: ctx, snap: snap).label == "Kick" && e.appearance("pad4", ctx: ctx, snap: snap).label == "Snare")
        // a pad that does something never records
        _ = e.handle(.down("pad1"), now: 7, ctx: ctx, snap: snap)
        #expect(!e.tick(now: 8, ctx: ctx, snap: snap).contains { if case .sampler = $0 { return true }; return false })
        _ = e.handle(.up("pad1"), now: 8.1, ctx: ctx, snap: snap)
    }

    /// Letting go right after the recording starts (a hold just past the threshold, a tap on ●) doesn't end it: it
    /// keeps recording until the pad, ● or ⏸ is tapped — and that tap does nothing else.
    @Test func aQuickReleaseLatchesTheRecording() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        let snap = Snapshot(values: ["win.1.exists": .bool(true)])
        _ = e.handle(.down("pad4"), now: 0, ctx: ctx, snap: snap)
        #expect(e.tick(now: 0.85, ctx: ctx, snap: snap).contains(.sampler(.record("A.pad4"))))
        #expect(e.handle(.up("pad4"), now: 0.95, ctx: ctx, snap: snap) == [.sampler(.latched("A.pad4")), .redraw])
        #expect(e.recording == "A.pad4" && e.tick(now: 2, ctx: ctx, snap: snap).isEmpty)
        #expect(e.appearance("rec", ctx: ctx, snap: snap).label == "■ Stop")
        #expect(e.appearance("pad4", ctx: ctx, snap: snap).label == "● Rec")
        #expect(e.handle(.down("pad4"), now: 3, ctx: ctx, snap: snap) == [.sampler(.stop("A.pad4")), .redraw])   // no drum hit
        #expect(e.handle(.up("pad4"), now: 3.1, ctx: ctx, snap: snap).isEmpty && e.recording == nil)
        // a tap on ● while holding a sample pad: the same, and the next ● tap stops it without talking
        e.samples = ["A.pad3": "/tmp/A.pad3.1.wav@4"]
        _ = e.handle(.down("pad3"), now: 4, ctx: ctx, snap: snap)
        _ = e.handle(.down("rec"), now: 4.3, ctx: ctx, snap: snap)
        #expect(e.handle(.up("rec"), now: 4.5, ctx: ctx, snap: snap) == [.sampler(.latched("A.pad3")), .redraw])
        _ = e.handle(.up("pad3"), now: 4.6, ctx: ctx, snap: snap)
        #expect(e.recording == "A.pad3")
        #expect(e.handle(.down("rec"), now: 6, ctx: ctx, snap: snap) == [.sampler(.stop("A.pad3")), .redraw])
        #expect(e.handle(.up("rec"), now: 6.2, ctx: ctx, snap: snap).isEmpty)
        // a longer hold still ends on release
        _ = e.handle(.down("pad4"), now: 7, ctx: ctx, snap: snap)
        _ = e.tick(now: 7.9, ctx: ctx, snap: snap)
        #expect(e.handle(.up("pad4"), now: 9, ctx: ctx, snap: snap) == [.sampler(.stop("A.pad4")), .redraw])
    }

    /// Hold a sample pad: ● records again (until ● is let go, not the pad), ⏸ erases it — neither talks nor sends
    /// Esc then. Without a held drum pad they do what they always do.
    @Test func recordAndEraseWithTheButtons() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        let snap = Snapshot(values: ["win.1.exists": .bool(true)])
        e.samples = ["A.pad3": "/tmp/A.pad3.1.wav@4"]
        _ = e.handle(.down("pad3"), now: 0, ctx: ctx, snap: snap)
        #expect(e.appearance("rec", ctx: ctx, snap: snap).label == "● Record")
        #expect(e.appearance("pause", ctx: ctx, snap: snap).label == "Erase sample")
        #expect(e.handle(.down("rec"), now: 0.3, ctx: ctx, snap: snap) == [.sampler(.record("A.pad3")), .redraw])
        _ = e.handle(.up("pad3"), now: 0.5, ctx: ctx, snap: snap)                                // still recording
        #expect(e.recording == "A.pad3")
        #expect(e.handle(.up("rec"), now: 1.5, ctx: ctx, snap: snap) == [.sampler(.stop("A.pad3")), .redraw])
        _ = e.handle(.down("pad3"), now: 2, ctx: ctx, snap: snap)
        #expect(e.handle(.down("pause"), now: 2.2, ctx: ctx, snap: snap) == [.sampler(.erase("A.pad3")), .redraw])
        #expect(e.handle(.up("pause"), now: 2.3, ctx: ctx, snap: snap).isEmpty)                  // no Esc on release either
        _ = e.handle(.up("pad3"), now: 2.4, ctx: ctx, snap: snap)
        // nothing held: ⏸ is Esc again
        #expect(plans(e.handle(.down("pause"), now: 3, ctx: ctx, snap: snap)).first?.steps.isEmpty == false)
        _ = e.handle(.up("pause"), now: 3.1, ctx: ctx, snap: snap)
        // a press that lost its release stops counting as held after a while
        _ = e.handle(.down("pad4"), now: 4, ctx: ctx, snap: snap)
        _ = e.tick(now: 4.9, ctx: ctx, snap: snap)
        e.recordingEnded()                                                                       // the app's length limit
        #expect(e.recording == nil && e.tick(now: 6, ctx: ctx, snap: snap).isEmpty)              // and no new recording
        _ = e.tick(now: 30, ctx: ctx, snap: snap)
        #expect(plans(e.handle(.down("pause"), now: 30.1, ctx: ctx, snap: snap)).first?.steps.isEmpty == false)
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

    /// The pad reports its bank in its global settings: known before any press, and a knob or button press
    /// doesn't undo it; the next pad press (its note) still decides.
    @Test func padBankFromThePad() throws {
        let d = DeviceDecoder(profile: try loadConfig().device)
        d.setPadBank("B")
        _ = d.decode(MIDIMessage(status: 0xB0, channel: 0, data1: 27, data2: 127))
        _ = d.decode(MIDIMessage(status: 0xB0, channel: 0, data1: 30, data2: 50))
        #expect(d.padBank == "B")
        _ = d.decode(MIDIMessage(status: 0x90, channel: 9, data1: 38, data2: 100))     // a bank-A note
        #expect(d.padBank == "A")
    }

    /// Once the pad reports its bank, the legend's pads follow PAD BANK: bank B's (shift) actions on the face, bank
    /// A's above; before that it never guesses.
    @Test func legendFollowsReportedPadBank() throws {
        let e = Engine(config: try loadConfig())
        var ctx = Context(); ctx.app = "com.apple.TextEdit"
        let a = e.appearance("pad1", ctx: ctx, snap: Snapshot(), shift: false).label
        let b = e.appearance("pad1", ctx: ctx, snap: Snapshot(), shift: true).label
        #expect(a != b)
        e.padBank = "B"
        #expect(e.appearance("pad1", ctx: ctx, snap: Snapshot()).label == a)            // bank only from a press: no guess
        e.padBankLive = true
        let face = e.appearance("pad1", ctx: ctx, snap: Snapshot())
        #expect(face.label == b && face.altLabel == a)
        #expect(e.appearance("pad_bank", ctx: ctx, snap: Snapshot()).selected)
        e.padBank = "A"
        #expect(e.appearance("pad1", ctx: ctx, snap: Snapshot()).label == a && !e.appearance("pad_bank", ctx: ctx, snap: Snapshot()).selected)
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
        #expect(plans(e.handle(.down("pad9"), now: 1, ctx: ctx, snap: Snapshot())).first?.steps == [.tmuxText(pane: "%2", "/compact\n")])
    }

    @Test func textGoesToCapturedPane() throws {
        let e = Engine(config: try loadConfig())
        let p = plans(e.handle(.down("pad9"), now: 0, ctx: itermContext(), snap: Snapshot()))
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
        let p = plans(e.handle(.down("pad5"), now: 0.1, ctx: ctx, snap: Snapshot(values: ["win.9.exists": .bool(true)])))
        #expect(p.first?.steps == [.tmux(["select-window", "-t", "main:9"])])
        #expect(!e.layerPath(ctx, now: 0).contains("Shift"))   // the bank lags, so the header doesn't claim it
        e.padBank = "A"
        #expect(!e.shiftActive)
    }

    /// Close… → choose → confirm: pad 11 green ✓ runs it, pad 10 / the top row red ✕ drop it, other pads do nothing.
    /// Close (pad 16): a tap asks once — green ✓ runs it, red ✕ drops it, other pads do nothing. A hold opens
    /// the Close… list, where picking with green ✓ is the confirmation (no second ask).
    @Test func closeAsksGreenOrRed() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        _ = e.handle(.down("pad16"), now: 0, ctx: ctx, snap: Snapshot())
        let asked = plans(e.handle(.up("pad16"), now: 0.1, ctx: ctx, snap: Snapshot()))
        #expect(asked.first?.steps == [.toast("Close? ✓ green · ✕ red")])
        #expect(e.stack.last?.layer == "confirm")
        #expect(e.appearance("pad11", ctx: ctx, snap: Snapshot()).label == "✓ Close")
        #expect(isDrum(e.appearance("pad5", ctx: ctx, snap: Snapshot())))               // other pads are drums
        #expect(drumOnly(e.handle(.down("pad5"), now: 0.6, ctx: ctx, snap: Snapshot())))
        #expect(e.appearance("pad6", ctx: ctx, snap: Snapshot()).label == "✕ Cancel" && e.appearance("pad7", ctx: ctx, snap: Snapshot()).label == "✓ Close")
        #expect(isDrum(e.appearance("pad16", ctx: ctx, snap: Snapshot())))              // only the middle four are lit
        // red: dropped
        _ = e.handle(.down("pad10"), now: 0.7, ctx: ctx, snap: Snapshot())
        #expect(e.stack.isEmpty && e.pendingConfirm == nil)
        // again, green: runs
        _ = e.handle(.down("pad16"), now: 1, ctx: ctx, snap: Snapshot())
        _ = e.handle(.up("pad16"), now: 1.1, ctx: ctx, snap: Snapshot())
        let ran = plans(e.handle(.down("pad11"), now: 1.3, ctx: ctx, snap: Snapshot()))
        #expect(ran.contains { $0.steps == [.tmux(["kill-window", "-t", "main:2"])] })
        #expect(e.stack.isEmpty)
        _ = e.handle(.up("pad11"), now: 1.35, ctx: ctx, snap: Snapshot())
        // unanswered: gives up after its timeout
        _ = e.handle(.down("pad16"), now: 2, ctx: ctx, snap: Snapshot())
        _ = e.handle(.up("pad16"), now: 2.1, ctx: ctx, snap: Snapshot())
        _ = e.tick(now: 11, ctx: ctx, snap: Snapshot())
        #expect(e.pendingConfirm == nil && e.stack.isEmpty)
        // hold: the list; green ✓ on "Close window" closes it — one confirmation, not two
        _ = e.handle(.down("pad16"), now: 20, ctx: ctx, snap: Snapshot())
        _ = e.tick(now: 20.6, ctx: ctx, snap: Snapshot())
        #expect(e.picker?.id == "close" && e.picker?.items[1].label == "Close window")
        _ = e.handle(.up("pad16"), now: 20.7, ctx: ctx, snap: Snapshot())
        let picked = plans(e.handle(.down("pad11"), now: 21, ctx: ctx, snap: Snapshot()))
        #expect(picked.contains { $0.steps == [.tmux(["kill-window", "-t", "main:2"])] } && e.pendingConfirm == nil)
    }

    /// An agent's permission prompt on screen: pad 11 green Yes, pad 10 red No (Esc), pad 12 "always".
    @Test func permissionPromptIsGreenAndRed() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        let screen = ScreenChoices.parse("""
         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don't ask again for git push commands
           3. No, and tell Claude what to do differently (esc)
        """)!
        let snap = Snapshot(values: windowsSnap.values.merging(screen.vars) { $1 })
        #expect(e.layerPath(ctx, now: 0, snap: snap).contains("Allow?"))
        #expect(e.layerPath(ctx, now: 0, snap: snap).contains("Choose") == false)
        #expect(plans(e.handle(.down("pad11"), now: 0, ctx: ctx, snap: snap)).first?.steps == [.tmuxKeys(pane: "%2", [try KeyChord.parse("1")])])
        #expect(plans(e.handle(.down("pad12"), now: 0.1, ctx: ctx, snap: snap)).first?.steps == [.tmuxKeys(pane: "%2", [try KeyChord.parse("2")])])
        #expect(plans(e.handle(.down("pad10"), now: 0.2, ctx: ctx, snap: snap)).first?.steps == [.tmuxKeys(pane: "%2", [try KeyChord.parse("esc")])])
        #expect(isDrum(e.appearance("pad1", ctx: ctx, snap: snap)))                 // window pads are drums meanwhile
    }

    /// A question: only the option under the cursor is green and blinks; the rest white, free-form magenta;
    /// the top row is red ✕ (Esc). Permission prompts use the middle four instead (red left, green right).
    @Test func questionLightsOnePadAndARedRow() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        let screen = ScreenChoices.parse("""
         Which store?
           1. SQLite
         ❯ 2. Redis
           3. Type something.
        """)!
        let snap = Snapshot(values: windowsSnap.values.merging(screen.vars) { $1 })
        let (p1, p2, p3) = (e.appearance("pad1", ctx: ctx, snap: snap), e.appearance("pad2", ctx: ctx, snap: snap),
                            e.appearance("pad3", ctx: ctx, snap: snap))
        #expect(p2.key == "ok" && p2.blink)
        #expect(p1.key == "choice" && !p1.blink)
        #expect(p3.key == "choice_voice" && !p3.blink)
        for pad in ["pad13", "pad16"] {
            let a = e.appearance(pad, ctx: ctx, snap: snap)
            #expect(a.label == "✕ Cancel" && a.key == "danger" && !a.blink)
        }
        #expect(plans(e.handle(.down("pad14"), now: 0, ctx: ctx, snap: snap)).first?.steps == [.tmuxKeys(pane: "%2", [try KeyChord.parse("esc")])])
        #expect(e.appearance("pad11", ctx: ctx, snap: snap).label == "Last window")    // row 3 stays the agent's

        let permit = ScreenChoices.parse("""
         Do you want to proceed?
         ❯ 1. Yes
           2. No, and tell Claude what to do differently (esc)
        """)!
        let snap2 = Snapshot(values: windowsSnap.values.merging(permit.vars) { $1 })
        #expect(e.appearance("pad6", ctx: ctx, snap: snap2).label == "✕ No" && e.appearance("pad7", ctx: ctx, snap: snap2).label == "✓ Yes")
        #expect(plans(e.handle(.down("pad6"), now: 1, ctx: ctx, snap: snap2)).first?.steps == [.tmuxKeys(pane: "%2", [try KeyChord.parse("esc")])])
        #expect(isDrum(e.appearance("pad15", ctx: ctx, snap: snap2)))
    }

    @Test func newTapSplitsHoldOpensPicker() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        let home = NSHomeDirectory()
        _ = e.handle(.down("pad15"), now: 0, ctx: ctx, snap: Snapshot())
        let tap = plans(e.handle(.up("pad15"), now: 0.1, ctx: ctx, snap: Snapshot()))
        #expect(tap.first?.steps == [.tmux(["new-window", "-t", "main:", "-c", home + "/Projects/own", "claude"]),
                                     .tmux(["split-window", "-h", "-t", "main:", "-c", home + "/Projects/own"]),
                                     .tmux(["select-pane", "-t", "main:", "-L"])])
        // hold New: the New… list
        _ = e.handle(.down("pad15"), now: 1, ctx: ctx, snap: Snapshot())
        _ = e.tick(now: 1.6, ctx: ctx, snap: Snapshot())
        #expect(e.picker?.id == "new-session")
        _ = e.handle(.up("pad15"), now: 1.8, ctx: ctx, snap: Snapshot())
        _ = e.handle(.turn("knob1", 3), now: 2, ctx: ctx, snap: Snapshot())
        _ = e.handle(.turn("knob1", 2), now: 2.05, ctx: ctx, snap: Snapshot())   // → "Claude in project…"
        #expect(e.picker?.items[e.picker!.index].label == "Claude in project…")
        _ = e.handle(.down("play"), now: 2.1, ctx: ctx, snap: Snapshot())
        #expect(e.picker?.id == "project-claude")                                 // nested folder list
    }

    @Test func defaultCloseTapVsLongHold() throws {
        let e = Engine(config: try loadConfig())
        var ctx = Context(); ctx.app = "com.apple.TextEdit"
        _ = e.handle(.down("pad16"), now: 0, ctx: ctx, snap: Snapshot())
        #expect(plans(e.handle(.up("pad16"), now: 0.2, ctx: ctx, snap: Snapshot())).first?.steps == [.keys([try KeyChord.parse("cmd+w")])])
        _ = e.handle(.down("pad16"), now: 1, ctx: ctx, snap: Snapshot())
        #expect(plans(e.tick(now: 2.6, ctx: ctx, snap: Snapshot())).isEmpty)          // not yet 2 s
        #expect(plans(e.tick(now: 3.05, ctx: ctx, snap: Snapshot())).first?.steps == [.keys([try KeyChord.parse("cmd+q")])])
        #expect(plans(e.handle(.up("pad16"), now: 3.2, ctx: ctx, snap: Snapshot())).isEmpty)
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
        // the action is no longer on a pad by default (window pads blink); bind it for the test
        var cfg = try loadConfig()
        cfg.layers["tmux"]?.bindings["pad11"] = try Binding.parse(.table(["agent": .string("next_waiting")]), ctx: "test")
        let e = Engine(config: cfg)
        let ctx = itermContext()
        let none = plans(e.handle(.down("pad11"), now: 0, ctx: ctx, snap: Snapshot()))
        #expect(none.first?.steps == [.toast("No agent is waiting")])
        let snap = Snapshot(values: ["agents.oldest_waiting": .string("%3")])
        #expect(plans(e.handle(.down("pad11"), now: 1, ctx: ctx, snap: snap)).first?.steps == [.focusPane("%3")])
    }

    @Test func promptFileIsInterpolated() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        #expect(e.appearance("pad14", ctx: ctx, snap: Snapshot()).label == "Prompts…")
        _ = e.handle(.down("pad14"), now: 0.1, ctx: ctx, snap: Snapshot())
        _ = e.handle(.up("pad14"), now: 0.15, ctx: ctx, snap: Snapshot())      // opens as a search: the search row first
        #expect(e.picker?.searching == true && e.picker?.index == -1)
        let i = e.picker?.items.firstIndex { $0.label == "Review diff" } ?? 0
        for _ in 0...i { _ = e.handle(.turn("knob1", 1), now: 0.16, ctx: ctx, snap: Snapshot()) }
        #expect(e.picker.map { $0.items[$0.index].label } == "Review diff")
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
        e.padBank = "B"                                                           // Mode is on PAD BANK B, pad 14
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
        _ = e.handle(.down("pad10"), now: 0, ctx: ctx, snap: Snapshot())
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
        _ = e.handle(.down("pad14"), now: 0, ctx: ctx, snap: Snapshot())
        _ = e.handle(.down("pause"), now: 1, ctx: ctx, snap: Snapshot())
        #expect(e.stack.isEmpty)
    }

    /// Claude's question as it really looks: 4 options, then "Type something." and "Chat about this" — both magenta
    /// (answered in words), pads 7–8 drums instead of the windows underneath.
    @Test func shortQuestionLeavesTheRestGrey() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        let screen = ScreenChoices.parse("""
         Where should the toggle go?
         ❯ 1. The < button (Recommended)
           2. Long-press <
           3. Bank-B pad 1 (iTerm slot)
           4. Pad 9 in every layer
           5. Type something.
           6. Chat about this
        """)!
        let snap = Snapshot(values: windowsSnap.values.merging(screen.vars) { $1 })
        let a = (1...8).map { e.appearance("pad\($0)", ctx: ctx, snap: snap) }
        #expect(a[0].key == "ok" && a[1].key == "choice" && a[3].key == "choice")
        #expect(a[4].key == "choice_voice" && a[5].key == "choice_voice")
        #expect(isDrum(a[6]) && isDrum(a[7]))
        #expect(drumOnly(e.handle(.down("pad7"), now: 0, ctx: ctx, snap: snap)))
        // "Chat about this" picks it and starts dictation, like "Type something"
        #expect(e.handle(.down("pad6"), now: 1, ctx: ctx, snap: snap).contains(.dictate))
    }

    /// Sites… opens as a search (type or say it); ● there still starts dictation, and what you say filters it.
    /// ● in a plain list (Model) turns it into a search first.
    @Test func talkInAListSearchesIt() throws {
        let e = Engine(config: try loadConfig())
        let rc = try KeyChord.parse("rightcmd")
        let model = Engine(config: try loadConfig())
        _ = model.handle(.turn("knob7", 1), now: 0, ctx: itermContext(), snap: Snapshot())
        #expect(model.picker?.id == "model" && model.picker?.searching == false)
        let toSearch = model.handle(.down("rec"), now: 0.5, ctx: itermContext(), snap: Snapshot())
        #expect(toSearch.contains(.search) && model.picker?.searching == true)
        var ctx = Context(); ctx.app = "org.mozilla.firefox"
        let opened = e.handle(.down("pad14"), now: 0, ctx: ctx, snap: Snapshot())   // Sites…
        _ = e.handle(.up("pad14"), now: 0.1, ctx: ctx, snap: Snapshot())
        #expect(opened.contains(.search) && e.picker?.searching == true)
        let out = e.handle(.down("rec"), now: 1, ctx: ctx, snap: Snapshot())
        #expect(plans(out).contains { $0.steps == [.keyDown(rc)] })   // VoiceInk still starts
        #expect(e.picker?.all.contains { $0.value == Engine.pickerCancel } == false)
        _ = e.filterPicker("chat gpt", now: 2)
        let took = plans(e.handle(.down("pad11"), now: 3, ctx: ctx, snap: Snapshot()))
        #expect(took.first?.steps.last == .typeText("https://chatgpt.com/\n"))
        #expect(plans(e.handle(.up("rec"), now: 3.5, ctx: ctx, snap: Snapshot())).contains { $0.steps == [.keyUp(rc)] })
    }

    /// An agent's menu (Rewind, /model): the middle four — green ✓ = Enter (7, 11), red ✕ = Esc (6, 10), the rest off.
    @Test func menuNavIsGreenAndRed() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        _ = e.handle(.down("pad10"), now: 0, ctx: ctx, snap: Snapshot())         // Rewind
        _ = e.handle(.up("pad10"), now: 0.1, ctx: ctx, snap: Snapshot())
        #expect(drumOnly(e.handle(.down("pad3"), now: 0.5, ctx: ctx, snap: Snapshot())))   // a drum
        let p = plans(e.handle(.down("pad11"), now: 1, ctx: ctx, snap: Snapshot()))
        #expect(p.first?.steps == [.tmuxKeys(pane: "%2", [try KeyChord.parse("enter")])])
        #expect(e.stack.last?.layer == "menu-nav")      // rewind's second menu
        _ = e.handle(.down("pad7"), now: 2, ctx: ctx, snap: Snapshot())
        #expect(e.stack.isEmpty)
        // red: Esc, and the menu mode ends at once
        _ = e.handle(.down("pad10"), now: 3, ctx: ctx, snap: Snapshot())         // Rewind again
        _ = e.handle(.up("pad10"), now: 3.1, ctx: ctx, snap: Snapshot())
        #expect(drumOnly(e.handle(.down("pad13"), now: 3.2, ctx: ctx, snap: Snapshot())))                      // a drum
        #expect(plans(e.handle(.down("pad6"), now: 3.5, ctx: ctx, snap: Snapshot())).first?.steps == [.tmuxKeys(pane: "%2", [try KeyChord.parse("esc")])])
        #expect(e.stack.isEmpty)
    }

    /// A list: only the middle four pads — left red ✕ closes (6, 10), right green ✓ takes (7, 11); the rest are off.
    @Test func listIsGreenAndRed() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        _ = e.handle(.turn("knob8", 1), now: 0, ctx: ctx, snap: Snapshot())
        #expect(e.appearance("pad11", ctx: ctx, snap: Snapshot()).key == "ok")
        #expect(e.appearance("pad7", ctx: ctx, snap: Snapshot()).key == "ok")
        #expect(e.appearance("pad6", ctx: ctx, snap: Snapshot()).key == "danger" && e.appearance("pad10", ctx: ctx, snap: Snapshot()).key == "danger")
        #expect(isDrum(e.appearance("pad14", ctx: ctx, snap: Snapshot())))
        #expect(isDrum(e.appearance("pad3", ctx: ctx, snap: Snapshot())))               // window pads are drums meanwhile
        #expect(drumOnly(e.handle(.down("pad3"), now: 0.5, ctx: ctx, snap: Snapshot())) && e.picker != nil)
        let p = plans(e.handle(.down("pad11"), now: 1, ctx: ctx, snap: Snapshot()))
        #expect(p.first?.steps == [.tmuxText(pane: "%2", "/effort low\n")])
        #expect(plans(e.handle(.up("pad11"), now: 1.1, ctx: ctx, snap: Snapshot())).isEmpty)
        // < > move; red closes without taking anything
        _ = e.handle(.turn("knob8", 1), now: 2, ctx: ctx, snap: Snapshot())
        _ = e.handle(.down("right"), now: 2.1, ctx: ctx, snap: Snapshot())
        #expect(e.picker?.index == 2)
        #expect(drumOnly(e.handle(.down("pad13"), now: 2.15, ctx: ctx, snap: Snapshot())) && e.picker != nil)   // a drum
        #expect(plans(e.handle(.down("pad6"), now: 2.2, ctx: ctx, snap: Snapshot())).allSatisfy { $0.steps.isEmpty } && e.picker == nil)
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
        let p3 = e.appearance("pad3", ctx: ctx, snap: snap)                      // only 2 options: pad3 is a drum, not Win 3
        #expect(isDrum(p3) && drumOnly(e.handle(.down("pad3"), now: 0.5, ctx: ctx, snap: snap)))
        #expect(plans(e.handle(.down("pad2"), now: 1, ctx: ctx, snap: snap)).first?.steps
                == [.tmuxKeys(pane: "%2", [KeyChord(modifiers: [], key: "2")])])
        #expect(e.layerPath(ctx, now: 1, snap: snap).contains("Choose"))
    }

    @Test func shiftLabelsShownAsAlt() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        let a = e.appearance("pad9", ctx: ctx, snap: Snapshot())
        #expect(a.label.hasPrefix("Compact") && a.altLabel == "/clear")
        #expect(e.appearance("pad10", ctx: ctx, snap: Snapshot()).altLabel == "/resume")
        e.padBank = "B"
        let b = e.appearance("pad9", ctx: ctx, snap: Snapshot())
        #expect(b.label.hasPrefix("Compact") && b.altLabel == "/clear")   // fixed: bank A on the face, bank B above
    }
}

@Suite struct ITermToggleTests {
    /// < shows / hides iTerm's hotkey window (⌃<) in every ruleset — as a real keypress, never typed into tmux.
    @Test func lessThanTogglesITermEverywhere() throws {
        let e = Engine(config: try loadConfig())
        let toggle = [PlanStep.keys([try KeyChord.parse("ctrl+<")])]
        var browser = Context(); browser.app = "org.mozilla.firefox"
        var discord = Context(); discord.app = "com.hnc.Discord"
        var text = Context(); text.app = "com.apple.TextEdit"
        let question = Snapshot(values: windowsSnap.values.merging(ScreenChoices.parse("""
         Which store?
         ❯ 1. SQLite
           2. Redis
        """)!.vars) { $1 })
        for (ctx, snap) in [(itermContext(), Snapshot()), (itermContext(cmd: "codex"), Snapshot()), (browser, Snapshot()),
                            (discord, Snapshot()), (text, Snapshot()), (itermContext(), question)] {
            _ = e.handle(.down("left"), now: 0, ctx: ctx, snap: snap)
            let p = plans(e.handle(.up("left"), now: 0.1, ctx: ctx, snap: snap))      // a tap (hold = Agents overview)
            #expect(p.first?.steps == toggle, "in \(e.layerPath(ctx, now: 0, snap: snap))")
        }
    }
}

@Suite struct AppSlotTests {
    /// Bank-B pads 1–4 in every ruleset: dark = not running, dim = running, bright = in front (tap again: next window).
    @Test func appSlotsLightAndSwitch() throws {
        let e = Engine(config: try loadConfig())
        e.padBank = "B"
        var ctx = itermContext()
        ctx.running = [RunningApp(bundleId: "com.googlecode.iterm2", name: "iTerm2", file: "iTerm"),
                       RunningApp(bundleId: "org.mozilla.firefox", name: "Firefox", file: "Firefox")]
        ctx.previousApp = ctx.running[1]
        let snap = Snapshot.build(context: ctx, agents: AgentStore(), custom: [:], layerPath: "")
        let (iterm, firefox, obsidian, back) = (e.appearance("pad1", ctx: ctx, snap: snap, shift: true), e.appearance("pad2", ctx: ctx, snap: snap, shift: true),
                                                e.appearance("pad3", ctx: ctx, snap: snap, shift: true), e.appearance("pad4", ctx: ctx, snap: snap, shift: true))
        #expect(iterm.selected && !iterm.windowSlot)                  // in front: bright
        #expect(firefox.windowSlot && !firefox.selected)              // running: dim
        #expect(obsidian.key == "off")                                // not running: dark
        #expect(back.label == "↩ Firefox")
        #expect(plans(e.handle(.down("pad1"), now: 0, ctx: ctx, snap: snap)).first?.steps == [.cycleWindow(next: true)])
        #expect(plans(e.handle(.down("pad2"), now: 0.1, ctx: ctx, snap: snap)).first?.steps == [.openApp("org.mozilla.firefox")])
        #expect(plans(e.handle(.down("pad3"), now: 0.2, ctx: ctx, snap: snap)).first?.steps == [.openApp("Obsidian")])
        #expect(plans(e.handle(.down("pad4"), now: 0.3, ctx: ctx, snap: snap)).first?.steps == [.openApp("org.mozilla.firefox")])
        // the same slots in the browser
        var b = ctx; b.app = "org.mozilla.firefox"; b.appName = "Firefox"; b.focusedPane = nil
        #expect(e.baseLayer(b).id == "browser")
        #expect(e.appearance("pad2", ctx: b, snap: snap, shift: true).selected)
    }
}

@Suite struct WindowListTests {
    /// KNOB BANK B · knob 4: the first turn opens every window, already on the one behind this; turning moves,
    /// resting 0.9 s goes there.
    @Test func turnThenRestGoesThere() throws {
        PickerDef.providers["windows"] = {
            (0..<4).map { PickerItem(label: "App — w\($0)", value: "1\u{1F}\($0)\u{1F}w\($0)", action: .focusWindow("1\u{1F}\($0)\u{1F}w\($0)")) }
        }
        let e = Engine(config: try loadConfig())
        e.knobBank = "B"
        let ctx = itermContext()
        _ = e.handle(.turn("knob4", 1), now: 0, ctx: ctx, snap: Snapshot())
        #expect(e.picker?.id == "windows" && e.picker?.items[e.picker!.index].label == "App — w1")
        #expect(plans(e.tick(now: 0.5, ctx: ctx, snap: Snapshot())).isEmpty)
        _ = e.handle(.turn("knob4", 1), now: 0.6, ctx: ctx, snap: Snapshot())      // keeps turning: w2, and the wait restarts
        #expect(plans(e.tick(now: 1.2, ctx: ctx, snap: Snapshot())).isEmpty)
        let went = plans(e.tick(now: 1.6, ctx: ctx, snap: Snapshot()))
        #expect(went.first?.steps == [.focusWindow("1\u{1F}2\u{1F}w2")])
        #expect(e.picker == nil)
        // ⏸ cancels instead
        _ = e.handle(.turn("knob4", 1), now: 3, ctx: ctx, snap: Snapshot())
        _ = e.handle(.down("pause"), now: 3.2, ctx: ctx, snap: Snapshot())
        #expect(plans(e.tick(now: 5, ctx: ctx, snap: Snapshot())).isEmpty && e.picker == nil)
    }
}

@Suite struct MeetingTests {
    @Test func meetTabGetsMeetingControls() throws {
        let e = Engine(config: try loadConfig())
        var ctx = Context(); ctx.app = "org.mozilla.firefox"; ctx.appName = "Firefox"
        ctx.windowTitle = "Meet - abc-defg-hij"
        #expect(e.baseLayer(ctx).id == "meet")
        #expect(plans(e.handle(.down("pad1"), now: 0, ctx: ctx, snap: Snapshot())).first?.steps == [.keys([try KeyChord.parse("cmd+d")])])
        #expect(plans(e.handle(.down("pad4"), now: 0.1, ctx: ctx, snap: Snapshot())).first?.steps == [.keyDown(try KeyChord.parse("space"))])
        _ = e.handle(.up("pad4"), now: 0.5, ctx: ctx, snap: Snapshot())
        // Leave asks first: green ✓ / red ✕
        _ = e.handle(.down("pad16"), now: 1, ctx: ctx, snap: Snapshot())
        _ = e.handle(.up("pad16"), now: 1.1, ctx: ctx, snap: Snapshot())
        #expect(e.stack.last?.layer == "confirm")
        #expect(e.appearance("pad11", ctx: ctx, snap: Snapshot()).label == "✓ Leave")
        _ = e.handle(.down("pad10"), now: 1.2, ctx: ctx, snap: Snapshot())          // red ✕: stays in the meeting
        #expect(e.stack.isEmpty)
        ctx.windowTitle = "Chat | General | Microsoft Teams"
        #expect(e.baseLayer(ctx).id == "teams")
        ctx.windowTitle = "Hacker News"
        #expect(e.baseLayer(ctx).id == "browser")
        ctx.windowTitle = "Lo-fi beats to code to - YouTube"
        #expect(e.baseLayer(ctx).id == "youtube")
        #expect(plans(e.handle(.down("pad1"), now: 10, ctx: ctx, snap: Snapshot())).first?.steps == [.keys([try KeyChord.parse("k")])])
        ctx.windowTitle = "Pull requests · owner/repo · GitHub"
        #expect(e.baseLayer(ctx).id == "github")
        #expect(plans(e.handle(.down("pad7"), now: 11, ctx: ctx, snap: Snapshot())).first?.steps
                == [.keys([try KeyChord.parse("g"), try KeyChord.parse("p")])])
        ctx.windowTitle = "GitHub - the full course - YouTube"                      // both match: YouTube wins
        #expect(e.baseLayer(ctx).id == "youtube")
        // tabs move in tab order (Firefox's ⌃⇥ may be "recently used") and wrap round at the ends
        #expect(plans(e.handle(.turn("knob3", 3), now: 20, ctx: ctx, snap: Snapshot())).first?.steps == [.cycleTab(next: true)])
        #expect(plans(e.handle(.down("right"), now: 21, ctx: ctx, snap: Snapshot())).first?.steps == [.cycleTab(next: true)])
    }
}

@Suite struct VideoTests {
    /// A fullscreen video in the browser (any site): the Video layer — media keys, seek, the Mac's volume.
    @Test func fullscreenVideoLayer() throws {
        let e = Engine(config: try loadConfig())
        var ctx = Context(); ctx.app = "org.mozilla.firefox"; ctx.appName = "Firefox"
        ctx.windowTitle = "Someone on X: \"a video\" / X"
        #expect(e.baseLayer(ctx).id == "browser")
        ctx.fullscreen = true
        #expect(e.baseLayer(ctx).id == "video")
        #expect(plans(e.handle(.down("pad6"), now: 0, ctx: ctx, snap: Snapshot())).first?.steps == [.mediaKey("play")])
        #expect(plans(e.handle(.down("pad4"), now: 0.01, ctx: ctx, snap: Snapshot())).first?.steps == [.keys(try KeyChord.parseSequence("right right right"))])
        #expect(plans(e.handle(.down("pad16"), now: 0.02, ctx: ctx, snap: Snapshot())).first?.steps == [.keys([try KeyChord.parse("esc")])])
        // volume: the Mac's volume keys (HUD, 1/16 a click) — clockwise is louder
        #expect(plans(e.handle(.turn("knob1", 1), now: 0.05, ctx: ctx, snap: Snapshot())).first?.steps == [.mediaKey("volume_up")])
        #expect(plans(e.handle(.turn("knob1", -1), now: 0.06, ctx: ctx, snap: Snapshot())).first?.steps == [.mediaKey("volume_down")])
        #expect(plans(e.handle(.down("pad3"), now: 0.1, ctx: ctx, snap: Snapshot())).first?.steps == [.keys([try KeyChord.parse("right")])])
        // nothing from the browser underneath: rows 3–4 and the other knobs are off; < still toggles iTerm
        #expect(isDrum(e.appearance("pad15", ctx: ctx, snap: Snapshot())) && e.appearance("knob3", ctx: ctx, snap: Snapshot()).bound == false)
        #expect(drumOnly(e.handle(.down("pad12"), now: 0.2, ctx: ctx, snap: Snapshot())) && isDrum(e.appearance("pad8", ctx: ctx, snap: Snapshot())))
        _ = e.handle(.down("left"), now: 0.3, ctx: ctx, snap: Snapshot())
        #expect(plans(e.handle(.up("left"), now: 0.35, ctx: ctx, snap: Snapshot())).first?.steps == [.keys([try KeyChord.parse("ctrl+<")])])
        // YouTube and meetings keep their own layers when fullscreen
        ctx.windowTitle = "Lo-fi beats to code to - YouTube"
        #expect(e.baseLayer(ctx).id == "youtube")
        ctx.windowTitle = "Meet - abc-defg-hij"
        #expect(e.baseLayer(ctx).id == "meet")
    }
}

@Suite struct DiscordTests {
    @Test func voiceControls() throws {
        let e = Engine(config: try loadConfig())
        var ctx = Context(); ctx.app = "com.hnc.Discord"; ctx.appName = "Discord"
        #expect(e.baseLayer(ctx).id == "discord")
        #expect(plans(e.handle(.down("pad1"), now: 0, ctx: ctx, snap: Snapshot())).first?.steps == [.keys([try KeyChord.parse("cmd+shift+m")])])
        #expect(plans(e.handle(.down("pad2"), now: 0.1, ctx: ctx, snap: Snapshot())).first?.steps == [.keys([try KeyChord.parse("cmd+shift+d")])])
        #expect(plans(e.handle(.down("pad3"), now: 0.2, ctx: ctx, snap: Snapshot())).first?.steps == [.pressButton(["Turn On Camera", "Turn Off Camera"])])
        _ = e.handle(.down("pad16"), now: 0.3, ctx: ctx, snap: Snapshot())                     // Leave call asks first
        #expect(e.stack.last?.layer == "confirm")
        #expect(plans(e.handle(.down("pad11"), now: 0.4, ctx: ctx, snap: Snapshot())).contains { $0.steps == [.pressButton(["Disconnect"])] })
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
        // Sites…: pinned sites first; ▶ opens the highlighted one in a new tab
        _ = e.handle(.down("pad14"), now: 0.5, ctx: ctx, snap: Snapshot())
        _ = e.handle(.up("pad14"), now: 0.6, ctx: ctx, snap: Snapshot())
        #expect(e.picker?.id == "sites" && e.picker?.items.first?.label == "ChatGPT")      // ▶ takes the top one
        #expect(plans(e.handle(.down("play"), now: 0.7, ctx: ctx, snap: Snapshot())).first?.steps
                == [.keys([try KeyChord.parse("cmd+t")]), .wait(0.25), .typeText("https://chatgpt.com/\n")])
        _ = e.handle(.up("play"), now: 0.75, ctx: ctx, snap: Snapshot())
        // DuckDuckGo is on bank B pad 12
        e.padBank = "B"
        _ = e.handle(.down("pad12"), now: 1, ctx: ctx, snap: Snapshot())
        let hold = plans(e.tick(now: 1.6, ctx: ctx, snap: Snapshot()))
        #expect(hold.first?.steps.last == .typeText("https://duckduckgo.com/?q=%CLIPBOARD_Q%\n"))
        _ = e.handle(.up("pad12"), now: 1.7, ctx: ctx, snap: Snapshot())
        e.padBank = "A"
        #expect(plans(e.handle(.down("pad11"), now: 2, ctx: ctx, snap: Snapshot())).isEmpty)   // has a hold: fires on release
        #expect(plans(e.handle(.up("pad11"), now: 2.1, ctx: ctx, snap: Snapshot())).first?.steps == [.keys([try KeyChord.parse("alt+space")])])
        _ = e.handle(.down("pad12"), now: 3, ctx: ctx, snap: Snapshot())
        #expect(plans(e.handle(.down("pad12"), now: 3, ctx: ctx, snap: Snapshot())).first?.steps == [.keys([try KeyChord.parse("alt"), try KeyChord.parse("alt")])])
    }
}

@Suite struct InputTests {
    @Test func worktreeFromDictatedTask() throws {
        let e = Engine(config: try loadConfig())
        let ctx = itermContext()
        _ = e.handle(.down("pad15"), now: 0, ctx: ctx, snap: Snapshot())         // hold New → the New… list
        _ = e.tick(now: 0.6, ctx: ctx, snap: Snapshot())
        _ = e.handle(.up("pad15"), now: 0.7, ctx: ctx, snap: Snapshot())
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
        #expect(sound(.down("pad9"), 1) == "act")                 // Compact
        #expect(sound(.turn("knob1", 1), 2) == nil)               // ↑↓ knob silent
        #expect(sound(.turn("knob3", 1), 2.5) == "nav")           // window knob clicks
        _ = e.handle(.down("play"), now: 3, ctx: ctx, snap: Snapshot())
        #expect(plans(e.handle(.up("play"), now: 3.1, ctx: ctx, snap: Snapshot())).first?.sound == nil)   // Enter silent
        _ = e.handle(.down("pad15"), now: 4, ctx: ctx, snap: Snapshot())
        #expect(plans(e.handle(.up("pad15"), now: 4.1, ctx: ctx, snap: Snapshot())).first?.sound == "new")
        #expect(sound(.down("pad13"), 5) == "picker")             // Skills… opens a list (a search)
        _ = e.handle(.up("pad13"), now: 5.1, ctx: ctx, snap: Snapshot())
        #expect(sound(.turn("knob1", 1), 5.5) == "scroll")        // moving in the list
        #expect(sound(.down("pad11"), 6) == "select")             // green ✓ selects in the list
        _ = e.handle(.down("pad13"), now: 7, ctx: ctx, snap: Snapshot())
        _ = e.handle(.up("pad13"), now: 7.1, ctx: ctx, snap: Snapshot())
        #expect(sound(.down("pause"), 8) == "cancel")             // ⏸ cancels
        _ = e.handle(.down("pad10"), now: 9, ctx: ctx, snap: Snapshot())   // Rewind → menu
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
        s.showApproval(session: "a", now: 0)
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
        let a = e.appearance("pad9", ctx: ctx, snap: snap)
        #expect(a.label == "Compact 85%" && a.key == "danger")
    }

    @Test func reconcileDropsDeadPanes() {
        let s = AgentStore()
        s.handle(event: "SessionStart", payload: payload("a"), pane: "%9", now: 0)
        s.reconcile(panes: itermContext().panes, agentCommands: ["claude"])
        #expect(s.agents.isEmpty)
    }
}

@Suite struct SleepTests {
    /// [sleep]: dark after `after` seconds without pad input; the first press, turn or button only wakes the pad.
    @Test func firstPressOnlyWakes() {
        var s = PadSleep(after: 300, now: 0)
        var fell = s.check(now: 299)
        #expect(!fell && !s.asleep)
        var r = s.input([.down("pad3")], now: 100)                                    // input resets the clock
        #expect(r.events == [.down("pad3")])
        _ = s.input([.up("pad3")], now: 100.1)
        fell = s.check(now: 399)
        #expect(!fell)
        fell = s.check(now: 400.2)
        #expect(fell && s.asleep)
        fell = s.check(now: 500)
        #expect(!fell)                                                                // falls asleep once
        // a pad wakes it: neither its press nor its release reach the engine
        r = s.input([.down("pad5")], now: 500)
        #expect(r.events.isEmpty && r.woke && !s.asleep)
        r = s.input([.up("pad5")], now: 500.3)
        #expect(r.events.isEmpty && !r.woke)
        r = s.input([.down("pad5")], now: 501)
        #expect(r.events == [.down("pad5")])                                          // the next press acts
        r = s.input([.up("pad5")], now: 501.1)
        #expect(r.events == [.up("pad5")])
        // a knob wakes it: the rest of that turn is ignored for a moment, other controls aren't
        s.sleep()
        r = s.input([.turn("knob3", 1)], now: 600)
        #expect(r.woke && r.events.isEmpty)
        r = s.input([.turn("knob3", 1)], now: 600.2)
        #expect(r.events.isEmpty)
        r = s.input([.turn("knob4", 1)], now: 600.3)
        #expect(r.events == [.turn("knob4", 1)])
        r = s.input([.turn("knob3", -1)], now: 600.6)
        #expect(r.events == [.turn("knob3", -1)])
        // an agent wakes it: the next press acts
        s.sleep(); s.wake(now: 700)
        r = s.input([.down("play")], now: 701)
        #expect(r.events == [.down("play")])
    }

    @Test func neverSleepsWithZeroAndParsesSettings() throws {
        var s = PadSleep(after: 0, now: 0)
        let fell = s.check(now: 100_000)
        #expect(!fell)
        let st = Settings.parse(["sleep": .table(["after": .string("2m"), "level": .number(0.05), "wake_for_agents": .bool(true)])])
        #expect(st.sleepAfter == 120 && st.sleepLevel == 0.05 && st.sleepWakeForAgents)
        #expect(Settings().sleepAfter == 300 && Settings().sleepLevel == 0)
        let shipped = try loadConfig()
        #expect(shipped.settings.sleepAfter == 300 && shipped.settings.sleepLevel == 0 && !shipped.settings.sleepWakeForAgents)
    }
}
