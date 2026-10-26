import AppKit
import ApplicationServices
import Foundation
import PaddingtonCore

/// Runs plans serially, off the main thread. Revalidates the captured pane before every step.
public final class Executor {
    public var onToast: ((String) -> Void)?
    public var onError: (() -> Void)?
    public var onState: ((String, Value) -> Void)?
    public var clientTTY: (() -> String?)?
    public var dryRun = false
    public var log: ((String) -> Void)?

    private let queue = DispatchQueue(label: "paddington.executor")

    public init() {}

    public func run(_ plan: Plan) {
        // key holds must not wait behind slow commands
        if plan.steps.allSatisfy({ if case .keyDown = $0 { return true }; if case .keyUp = $0 { return true }; return false }) {
            for s in plan.steps { execute(s, plan: plan) }
            return
        }
        queue.async { [self] in
            for s in plan.steps {
                if let pane = plan.pane, needsPane(s), !paneAlive(pane) {
                    fail()
                    toast("Target pane \(pane) is gone — cancelled \(plan.label)")
                    return
                }
                if !execute(s, plan: plan) { return }
            }
        }
    }

    /// %CLIPBOARD% / %CLIPBOARD_Q% (URL-encoded) in typed text and URLs: the clipboard at that moment.
    static func expandClipboard(_ s: String) -> String {
        guard s.contains("%CLIPBOARD") else { return s }
        let clip = DispatchQueue.main.sync { NSPasteboard.general.string(forType: .string) ?? "" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let q = clip.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return s.replacingOccurrences(of: "%CLIPBOARD_Q%", with: q).replacingOccurrences(of: "%CLIPBOARD%", with: clip)
    }

    func needsPane(_ s: PlanStep) -> Bool {
        switch s { case .tmuxKeys, .tmuxText: return true; default: return false }
    }

    func paneAlive(_ pane: String) -> Bool {
        Tmux.run(["display-message", "-p", "-t", pane, "#{pane_id}"]).out.trimmingCharacters(in: .whitespacesAndNewlines) == pane
    }

    func toast(_ s: String) { DispatchQueue.main.async { self.onToast?(s) } }

    /// Returns false to stop the plan.
    @discardableResult
    func execute(_ s: PlanStep, plan: Plan) -> Bool {
        log?("exec \(s)")
        if dryRun { return true }
        do {
            switch s {
            case .keys(let ks): for k in ks { try Keyboard.press(k); usleep(8_000) }
            case .keyDown(let k): try Keyboard.down(k)
            case .keyUp(let k): try Keyboard.up(k)
            case .typeText(let t): Keyboard.type(Self.expandClipboard(t))
            case .tmuxKeys(let pane, let ks):
                let names = ks.compactMap(Keyboard.tmuxName)
                guard names.count == ks.count else { toast("Can't send \(ks.map(\.description).joined(separator: " ")) to a terminal"); return false }
                return check(Tmux.run(["send-keys", "-t", pane] + names), what: "send-keys")
            case .tmuxText(let pane, let text):
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                for (i, line) in lines.enumerated() {
                    // "--": a line starting with "-" (a markdown bullet, "---") is text, not a tmux flag
                    if !line.isEmpty, !check(Tmux.run(["send-keys", "-t", pane, "-l", "--", String(line)]), what: "send-keys") { return false }
                    if i < lines.count - 1 {
                        usleep(30_000)
                        if !check(Tmux.run(["send-keys", "-t", pane, "Enter"]), what: "send-keys") { return false }
                    }
                }
            case .tmux(let args): return check(Tmux.run(args), what: "tmux \(args.first ?? "")")
            case .focusPane(let pane):
                return check(Tmux.focus(pane: pane, panes: Tmux.panes(), clientTTY: clientTTY?()), what: "focus")
            case .exec(let argv, let cwd):
                // wait (off the main thread) so failures surface; long-running tools time out into the background
                let r = Shell.run(argv.map(Self.expandClipboard), cwd: cwd, timeout: 30)
                if !r.ok && r.status != 15 {
                    let msg = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
                    return check(RunResult(status: r.status, out: "", err: String(msg.suffix(160))), what: argv.first ?? "exec")
                }
            case .open(let rawTarget):
                let target = Self.expandClipboard(rawTarget)
                let argv = target.contains(":") || target.hasPrefix("/") || target.hasPrefix("~")
                    ? ["open", (target as NSString).expandingTildeInPath] : ["open", "-a", target]
                return check(Shell.run(argv), what: "open")
            case .shortcut(let name): if let e = Shell.spawn(["shortcuts", "run", name]) { toast(e); return false }
            case .menu(let path): try Menu.press(path)
            case .script(let path, let env): runScript(path, env: env)
            case .setState(let k, let v): DispatchQueue.main.async { self.onState?(k, v) }
            case .toast(let t): toast(t)
            case .wait(let d): usleep(useconds_t(max(0, min(d, 10)) * 1_000_000))
            case .setMode(let pane, let target): return setMode(pane: pane, target: target)
            case .cycleWindow(let next): try Menu.cycleWindow(next: next)
            case .focusWindow(let id): try WindowList.focus(id)
            case .pressButton(let names): try Menu.pressButton(names)
            case .cycleTab(let next): try Menu.cycleTab(next: next)
            case .mediaKey(let k): Menu.mediaKey(k)
            case .openApp(let app):
                // `open` sends a Dock click (reopen): a window appears even if the app had none — and iTerm shows
                // its hotkey window. Bundle ids go by -b, names by -a.
                let isId = app.contains(".") && !app.contains(" ") && NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) != nil
                return check(Shell.run(["open", isId ? "-b" : "-a", app]), what: "open \(app)")
            }
        } catch {
            fail()
            toast("\(error)")
            return false
        }
        return true
    }

    /// Claude Code's mode line labels → permission modes. No label shown = default ("manual").
    static let modeLabels: [(String, String)] = [("accept edits on", "acceptEdits"), ("plan mode on", "plan"),
                                                 ("auto mode on", "auto"), ("bypass permissions on", "bypassPermissions"),
                                                 ("don't ask on", "dontAsk"), ("manual mode on", "default")]

    static func readMode(pane: String) -> String? {
        let r = Tmux.run(["capture-pane", "-p", "-t", pane, "-S", "-6"])
        guard r.ok else { return nil }
        let text = r.out.lowercased()
        return modeLabels.first { text.contains($0.0) }?.1 ?? "default"
    }

    /// Closed loop: read, step once, read again — stop when it matches, when nothing changes, or after one full cycle.
    func setMode(pane: String, target: String) -> Bool {
        guard target != "bypassPermissions" else { toast("Won't switch to bypass permissions from the pad"); return false }
        guard var cur = Self.readMode(pane: pane) else { toast("Can't read the mode line"); return false }
        var seen: Set<String> = [cur]
        for _ in 0..<6 {
            if cur == target { toast("Mode: \(PaddingtonCore.Looks.modeLabel(target))"); return true }
            Tmux.run(["send-keys", "-t", pane, "BTab"])
            usleep(250_000)
            guard let next = Self.readMode(pane: pane) else { toast("Can't read the mode line"); return false }
            if next == cur { toast("Mode didn't change — is a menu or question open?"); return false }
            if next == "bypassPermissions" && target != "bypassPermissions" { seen.insert(next) }
            cur = next
            if seen.contains(cur) && cur != target && seen.count > 1 && cur == seen.first { break }
            seen.insert(cur)
        }
        if cur == target { toast("Mode: \(PaddingtonCore.Looks.modeLabel(target))"); return true }
        toast("Couldn't reach \(PaddingtonCore.Looks.modeLabel(target)) mode (now \(PaddingtonCore.Looks.modeLabel(cur)))")
        return false
    }

    func fail() { DispatchQueue.main.async { self.onError?() } }

    func check(_ r: RunResult, what: String) -> Bool {
        if !r.ok {
            fail()
            toast("\(what): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return r.ok
    }

    /// Script contract: env in, optional JSON out: {"state": {...}, "toast": "...", "focus_pane": "%3"}.
    func runScript(_ path: String, env: [String: String]) {
        let r = Shell.run([path], env: env, timeout: 10)
        if !r.ok { toast("\((path as NSString).lastPathComponent) failed: \(r.err.prefix(200))"); return }
        let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard out.hasPrefix("{"), let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)),
              case .table(let t) = Value(any: obj) else { return }
        for (k, v) in t["state"]?.table ?? [:] { DispatchQueue.main.async { self.onState?(k, v) } }
        if let s = t["toast"]?.string { toast(s) }
        if let p = t["focus_pane"]?.string { _ = Tmux.focus(pane: p, panes: Tmux.panes(), clientTTY: clientTTY?()) }
    }
}

/// Click a menu item of the frontmost app through Accessibility.
public enum Menu {
    /// A media key as the keyboard sends it. Play / next / previous go to whatever is playing (a browser video —
    /// Firefox and Chrome support media keys —, Music, Spotify); the volume keys change the Mac's volume in its own
    /// steps (1/16) and show its volume HUD.
    public static func mediaKey(_ name: String) {
        // NX_KEYTYPE_PLAY / NEXT / PREVIOUS / SOUND_UP / SOUND_DOWN / MUTE
        let key: Int32 = ["play": 16, "next": 17, "prev": 18, "volume_up": 0, "volume_down": 1, "mute": 7][name] ?? 16
        for down in [true, false] {
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Next / previous browser tab that wraps around: on the last tab "next" goes to the first (⌘1), on the first
    /// "previous" to the last (⌘9); otherwise ⌥⌘→ / ⌥⌘←. Where the selected tab is comes from the window's tab
    /// strip (Accessibility); if it can't be read, plain ⌥⌘→ / ⌥⌘← (no wrap).
    public static func cycleTab(next: Bool) throws {
        var keys = next ? "cmd+alt+right" : "cmd+alt+left"
        if let app = NSWorkspace.shared.frontmostApplication, let (sel, count) = selectedTab(pid: app.processIdentifier), count > 1 {
            if next && sel == count - 1 { keys = "cmd+1" }
            if !next && sel == 0 { keys = "cmd+9" }
        }
        try Keyboard.press(try KeyChord.parse(keys))
    }

    nonisolated(unsafe) static var tabStrip: (pid: pid_t, window: AXUIElement, group: AXUIElement)?

    /// (selected tab index, tab count) of the focused window's tab strip. The strip is found once per window.
    static func selectedTab(pid: pid_t) -> (Int, Int)? {
        func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let w = attr(app, kAXFocusedWindowAttribute) else { return nil }
        let win = w as! AXUIElement
        var group: AXUIElement?
        if let c = tabStrip, c.pid == pid, CFEqual(c.window, win) { group = c.group }
        if group == nil {
            var queue: [(AXUIElement, Int)] = [(win, 0)], seen = 0
            while !queue.isEmpty, seen < 3000, group == nil {
                let (e, d) = queue.removeFirst(); seen += 1
                if (attr(e, kAXRoleAttribute) as? String) == kAXTabGroupRole as String { group = e; break }
                if d < 12 { queue += ((attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []).map { ($0, d + 1) } }
            }
            guard let g = group else { return nil }
            tabStrip = (pid, win, g)
        }
        let tabs = ((attr(group!, kAXChildrenAttribute) as? [AXUIElement]) ?? []).filter { (attr($0, kAXRoleAttribute) as? String) == kAXRadioButtonRole as String }
        let isSelected = { (t: AXUIElement) -> Bool in let v = attr(t, kAXValueAttribute); return (v as? Int) == 1 || (v as? Bool) == true }
        guard let sel = tabs.firstIndex(where: isSelected) else { tabStrip = nil; return nil }
        return (sel, tabs.count)
    }

    /// Press a button of the front app by its accessible name (title or description, any case) — for things with
    /// no shortcut, like Discord's camera. The first name found wins. Electron apps (Discord, Slack…) only build
    /// their accessibility tree when asked, so the first press may need a moment.
    public static func pressButton(_ names: [String]) throws {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw KeyError("no frontmost app") }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.5)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let wanted = names.map { $0.lowercased() }
        let t0 = Date()
        for attempt in 0..<4 {
            if let (b, label, seen) = findButton(ax, wanted) {
                AXUIElementPerformAction(b, kAXPressAction as CFString)
                Log.write("pressed “\(label)” in \(app.localizedName ?? "?") (\(seen) elements, \(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
                return
            }
            if attempt < 3 { usleep(250_000) }
        }
        throw KeyError("no “\(names[0])” button in \(app.localizedName ?? "the app") right now")
    }

    /// Breadth-first through the app's windows; the first button with any of the names (they're alternatives,
    /// like "Turn On Camera" / "Turn Off Camera", so only one is there at a time).
    static func findButton(_ app: AXUIElement, _ wanted: [String]) -> (AXUIElement, String, Int)? {
        func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
        var queue = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var seen = 0
        while !queue.isEmpty, seen < 40_000 {
            let e = queue.removeFirst(); seen += 1
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            if role == kAXButtonRole as String || role == kAXCheckBoxRole as String || role == "AXSwitch" || role == kAXRadioButtonRole as String {
                for k in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let s = attr(e, k) as? String, wanted.contains(s.lowercased()) { return (e, s, seen) }
                }
            }
            queue += (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return nil
    }

    /// Raise the frontmost app's next (back-most) or previous window.
    public static func cycleWindow(next: Bool) throws {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw KeyError("no frontmost app") }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success,
              let wins = (v as? [AXUIElement])?.filter({ w in
                  var m: CFTypeRef?; AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m)
                  return (m as? Bool) != true
              }), wins.count > 1 else { return }
        let target = next ? wins.last! : wins[1]
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    public static func press(_ path: [String]) throws {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw KeyError("no frontmost app") }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &bar) == .success, let barEl = bar else {
            throw KeyError("\(app.localizedName ?? "app") has no accessible menu bar (Accessibility permission?)")
        }
        var current = barEl as! AXUIElement
        for (i, title) in path.enumerated() {
            guard let next = child(of: current, titled: title) else {
                throw KeyError("menu item '\(path[...i].joined(separator: " › "))' not found in \(app.localizedName ?? "app")")
            }
            if i == path.count - 1 {
                AXUIElementPerformAction(next, kAXPressAction as CFString)
            } else {
                // descend: menu bar item → its menu → items
                var kids: CFTypeRef?
                AXUIElementCopyAttributeValue(next, kAXChildrenAttribute as CFString, &kids)
                guard let menu = (kids as? [AXUIElement])?.first else { throw KeyError("'\(title)' has no submenu") }
                current = menu
            }
        }
    }

    static func child(of el: AXUIElement, titled title: String) -> AXUIElement? {
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids)
        for k in (kids as? [AXUIElement]) ?? [] {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(k, kAXTitleAttribute as CFString, &t)
            if let s = t as? String, s.caseInsensitiveCompare(title) == .orderedSame || s.hasPrefix(title) { return k }
        }
        return nil
    }
}
