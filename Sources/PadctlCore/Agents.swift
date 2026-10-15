import Foundation

public struct PaneInfo: Equatable {
    public var session: String
    public var window: Int
    public var windowName: String
    public var paneId: String
    public var active: Bool          // active pane of the active window of its session
    public var command: String
    public var path: String
    public init(session: String, window: Int, windowName: String, paneId: String, active: Bool, command: String, path: String) {
        self.session = session; self.window = window; self.windowName = windowName; self.paneId = paneId
        self.active = active; self.command = command; self.path = path
    }
}

/// What the user is looking at right now.
public struct Context: Equatable {
    public var app: String = ""             // bundle id
    public var appName: String = ""
    public var windowTitle: String = ""
    public var focusedPane: PaneInfo?       // tmux pane shown in the focused terminal, if known
    public var panes: [PaneInfo] = []       // all panes on the tmux server
    public init() {}
}

public enum AgentStatus: String, CaseIterable {
    case unknown, idle, working, needs_approval, needs_input, done_unread, error, compacting
    /// Higher wins when several agents share a window.
    public var urgency: Int {
        switch self {
        case .needs_approval: return 7
        case .needs_input: return 6
        case .error: return 5
        case .done_unread: return 4
        case .working: return 3
        case .compacting: return 2
        case .unknown: return 1
        case .idle: return 0
        }
    }
    public var waiting: Bool { self == .needs_approval || self == .needs_input }
}

public struct Agent: Equatable {
    public var sessionId: String
    public var pane: String
    public var status: AgentStatus
    public var reason: String = ""
    public var mode: String = ""
    public var since: Double
    public var statusBeforeCompact: AgentStatus = .idle
    public var pendingQuestions: [String: Value] = [:]   // tool_use_id → tool_input
    public var contextPct: Double?                       // from the status line: context window used, 0–100
}

/// Agent state from observe-only Claude Code hooks. Keyed by session id; a pane is an attribute.
public final class AgentStore {
    public private(set) var agents: [String: Agent] = [:]
    public init() {}

    public func agent(forPane pane: String) -> Agent? {
        agents.values.filter { $0.pane == pane }.max { $0.since < $1.since }
    }

    /// Apply one hook event. Returns true if anything changed.
    @discardableResult
    public func handle(event: String, payload: [String: Value], pane: String?, now: Double) -> Bool {
        guard let sid = payload["session_id"]?.string, !sid.isEmpty else { return false }
        let before = agents
        if event == "SessionEnd" { agents[sid] = nil; return before != agents }

        var a = agents[sid]
        if a == nil {
            guard let pane, !pane.isEmpty else { return false }
            // a new session in a pane replaces whatever ran there before
            for (k, v) in agents where v.pane == pane { agents[k] = nil }
            a = Agent(sessionId: sid, pane: pane, status: .idle, since: now)
        }
        guard var ag = a else { return false }
        if let p = pane, !p.isEmpty { ag.pane = p }
        if let m = payload["permission_mode"]?.string { ag.mode = m }
        let tool = payload["tool_name"]?.string ?? ""
        let toolUse = payload["tool_use_id"]?.string ?? ""

        func set(_ s: AgentStatus, _ reason: String = "") {
            if ag.status != s { ag.since = now }
            ag.status = s; ag.reason = reason
        }
        func clearWaitIfNoQuestions() {
            if ag.status.waiting && ag.pendingQuestions.isEmpty { set(.working) }
        }

        switch event {
        case "SessionStart": set(.idle); ag.pendingQuestions = [:]
        case "UserPromptSubmit": ag.pendingQuestions = [:]; set(.working)
        case "PreToolUse":
            if tool == "AskUserQuestion" {
                ag.pendingQuestions[toolUse] = payload["tool_input"] ?? .null
                set(.needs_input, "question")
            } else if !ag.status.waiting || (ag.status == .needs_approval && ag.pendingQuestions.isEmpty) {
                // a new tool call means any permission request before it was settled (approved, denied, or
                // auto-reviewed by Codex's Guardian without ever showing a prompt)
                set(.working)
            }
        case "PermissionRequest":
            set(.needs_approval, tool.isEmpty ? "permission" : tool)
        case "Notification":
            switch payload["notification_type"]?.string ?? "" {
            case "permission_prompt": if !ag.status.waiting { set(.needs_approval, "permission") }
            case "idle_prompt": if ag.status == .working { set(.done_unread) }
            default: break
            }
        case "PostToolUse", "PostToolUseFailure":
            if !toolUse.isEmpty { ag.pendingQuestions[toolUse] = nil }
            clearWaitIfNoQuestions()
            if ag.status == .idle || ag.status == .done_unread || ag.status == .unknown { set(.working) }
        case "Stop": ag.pendingQuestions = [:]; set(.done_unread)
        case "StopFailure": ag.pendingQuestions = [:]; set(.error, payload["error"]?.string ?? "error")
        case "PreCompact": ag.statusBeforeCompact = ag.status; set(.compacting)
        case "PostCompact": set(ag.statusBeforeCompact == .working ? .working : .idle)
        case "Interrupt": ag.pendingQuestions = [:]; set(.idle)          // Codex: the user interrupted the turn
        default: break
        }
        agents[sid] = ag
        return before != agents
    }

    /// Status-line payload (Claude Code): context usage per session, plan usage overall.
    public private(set) var usage5h: Double?
    public private(set) var usage7d: Double?

    @discardableResult
    public func statusline(payload: [String: Value], pane: String?, now: Double) -> Bool {
        let before = (agents, usage5h, usage7d)
        if let rl = payload["rate_limits"]?.table {
            usage5h = rl["five_hour"]?["used_percentage"]?.number ?? usage5h
            usage7d = rl["seven_day"]?["used_percentage"]?.number ?? usage7d
        }
        if let sid = payload["session_id"]?.string, let pct = payload["context_window"]?["used_percentage"]?.number {
            if agents[sid] == nil, let pane, !pane.isEmpty {
                for (k, v) in agents where v.pane == pane { agents[k] = nil }
                agents[sid] = Agent(sessionId: sid, pane: pane, status: .unknown, since: now)
            }
            agents[sid]?.contextPct = pct
        }
        return before.0 != agents || before.1 != usage5h || before.2 != usage7d
    }

    /// The user is looking at this pane: finished work counts as seen.
    @discardableResult
    public func visit(pane: String, now: Double) -> Bool {
        var changed = false
        for (k, v) in agents where v.pane == pane && v.status == .done_unread {
            agents[k]?.status = .idle; agents[k]?.since = now; changed = true
        }
        return changed
    }

    /// Drop agents whose pane is gone or no longer runs an agent.
    @discardableResult
    public func reconcile(panes: [PaneInfo], agentCommands: Set<String>) -> Bool {
        let live = Dictionary(panes.map { ($0.paneId, $0) }, uniquingKeysWith: { a, _ in a })
        let before = agents.count
        agents = agents.filter { _, a in
            guard let p = live[a.pane] else { return false }
            return agentCommands.contains(p.command)
        }
        return before != agents.count
    }

    /// Permission prompts as the agents draw them; a "waiting for approval" with none of these on screen is stale.
    public static let approvalMarkers = ["Would you like to", "Yes, proceed", "No, and tell Codex",   // Codex
                                         "Do you want to", "Yes, and don't ask again"]                 // Claude Code

    /// Agents waiting for approval for longer than `grace` seconds (to check against the screen).
    public func approvalWaits(now: Double, grace: Double = 2) -> [Agent] {
        agents.values.filter { $0.status == .needs_approval && now - $0.since >= grace }
    }

    /// The prompt isn't on screen (any more): the agent is working again.
    @discardableResult
    public func dismissApproval(session: String, now: Double) -> Bool {
        guard agents[session]?.status == .needs_approval else { return false }
        agents[session]?.status = .working; agents[session]?.reason = ""; agents[session]?.since = now
        return true
    }

    public func reset(pane: String, now: Double) {
        for (k, v) in agents where v.pane == pane {
            agents[k]?.status = .idle; agents[k]?.pendingQuestions = [:]; agents[k]?.since = now
        }
    }

    /// Oldest waiting agent, excluding a pane (usually the focused one) when others wait.
    public func oldestWaiting(excluding: String? = nil) -> Agent? {
        let waiting = agents.values.filter { $0.status.waiting }.sorted { $0.since < $1.since }
        return waiting.first { $0.pane != excluding } ?? waiting.first
    }
}

/// Flat key → value view over context, agents and custom state, for expressions and labels.
public struct Snapshot {
    public var values: [String: Value] = [:]
    public init(values: [String: Value] = [:]) { self.values = values }
    public subscript(key: String) -> Value { values[key] ?? .null }
    public func lookup(_ k: String) -> Value { self[k] }

    public static let agentCommands: Set<String> = ["claude", "codex"]

    public static func build(context: Context, agents: AgentStore, custom: [String: Value], layerPath: String) -> Snapshot {
        var v = custom
        v["app"] = .string(context.app)
        v["app.name"] = .string(context.appName)
        v["layer"] = .string(layerPath)
        func status(of pane: PaneInfo) -> AgentStatus? {
            if let a = agents.agent(forPane: pane.paneId) { return a.status }
            return agentCommands.contains(pane.command) ? .unknown : nil
        }
        if let f = context.focusedPane {
            v["pane"] = .string(f.paneId)
            v["pane.path"] = .string(f.path)
            v["pane.command"] = .string(f.command)
            v["session"] = .string(f.session)
            v["window"] = .number(Double(f.window))
            if let s = status(of: f) { v["agent.status"] = .string(s.rawValue) }
            if let a = agents.agent(forPane: f.paneId) {
                v["agent.mode"] = .string(a.mode); v["agent.reason"] = .string(a.reason)
                if let c = a.contextPct { v["agent.context"] = .number(c) }
                // the focused agent's pending AskUserQuestion: first question and its options
                if a.status == .needs_input, let input = a.pendingQuestions.values.first,
                   let qs = input["questions"]?.array, let q = qs.first?.table {
                    v["q.active"] = .bool(true)
                    v["q.total"] = .number(Double(qs.count))
                    v["q.text"] = q["question"] ?? .null
                    v["q.header"] = q["header"] ?? .null
                    v["q.multi"] = .bool(q["multiSelect"]?.bool ?? false)
                    let opts = q["options"]?.array ?? []
                    v["q.count"] = .number(Double(opts.count))
                    for (i, o) in opts.enumerated() {
                        v["q.option.\(i + 1)"] = o["label"] ?? o
                    }
                }
            }
            for p in context.panes where p.session == f.session {
                v["win.\(p.window).exists"] = .bool(true)
                v["win.\(p.window).name"] = .string(p.windowName)
                if let s = status(of: p) {
                    let key = "win.\(p.window).agent.status"
                    let cur = v[key]?.string.flatMap(AgentStatus.init(rawValue:))
                    if cur == nil || s.urgency > cur!.urgency { v[key] = .string(s.rawValue) }
                }
                if p.window == f.window { v["win.\(p.window).current"] = .bool(true) }
            }
        }
        if let u = agents.usage5h { v["usage.5h"] = .number(u) }
        if let u = agents.usage7d { v["usage.7d"] = .number(u) }
        let all = Array(agents.agents.values)
        v["agents.waiting"] = .number(Double(all.filter { $0.status.waiting }.count))
        v["agents.working"] = .number(Double(all.filter { $0.status == .working }.count))
        v["agents.done"] = .number(Double(all.filter { $0.status == .done_unread }.count))
        if let o = agents.oldestWaiting(excluding: context.focusedPane?.paneId) {
            v["agents.oldest_waiting"] = .string(o.pane)
            if let p = context.panes.first(where: { $0.paneId == o.pane }) {
                v["agents.oldest_waiting.window"] = .number(Double(p.window))
                v["agents.oldest_waiting.reason"] = .string(o.reason)
            }
        }
        return Snapshot(values: v)
    }
}
