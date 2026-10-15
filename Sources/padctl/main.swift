import AppKit
import Foundation
import PadctlCore
import PadctlMac

signal(SIGPIPE, SIG_IGN)   // `padctl status | head` or a vanished app must not kill the CLI (or the app, which runs this too)
let args = Array(CommandLine.arguments.dropFirst())
let env = ProcessInfo.processInfo.environment

func out(_ s: String) { print(s); fflush(stdout) }
func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

func jsonString(_ o: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return "\(o)" }
    return String(decoding: d, as: UTF8.self)
}

func appRequest(_ obj: [String: Any], timeout: Double = 2) -> [String: Any] {
    guard let r = ControlSocket.request(obj, timeout: timeout) else {
        fail("padctl app is not running. Start it with `padctl start`.")
    }
    return r
}

/// Bundled default config: <app>/Contents/Resources/config, or $PADCTL_SHARE, or the repo checkout.
func bundledConfig() -> URL? {
    var candidates: [URL] = []
    if let s = env["PADCTL_SHARE"] { candidates.append(URL(fileURLWithPath: s)) }
    if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("config")) }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    candidates.append(exe.deletingLastPathComponent().appendingPathComponent("../Resources/config").standardized)
    return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.toml").path) }
}

let help = """
padctl \(Padctl.version) — MIDI pad → Mac control surface

  padctl start                 launch the menu-bar app
  padctl init                  copy the default config to ~/.config/padctl (never overwrites)
  padctl status                app, pad connection, layer, permissions
  padctl doctor                check config, tmux, hooks, MIDI sources
  padctl monitor               print every incoming MIDI message (and what it maps to)
  padctl learn                 build the device profile by pressing each control
  padctl legend [pin|show|hide]
  padctl simulate <control> [tap|hold|down|up|turn N]
  padctl state get | set <key> <value>
  padctl reload                reload config now (it also reloads on save)
  padctl bt [connect|window]   Bluetooth: connect now, or Apple's Bluetooth MIDI window
  padctl apps                  bundle id + window title of the app in front (after 3 s)
  padctl hooks install|uninstall   Claude Code hooks (observe-only) in ~/.claude/settings.json
  padctl hook <Event>          (used by the hooks) forward a hook payload from stdin
"""

// The app bundle's Info.plist sets PADCTL_APP=1 via LSEnvironment.
if args.isEmpty && env["PADCTL_APP"] == "1" || args.first == "run" {
    let app = NSApplication.shared
    let delegate = AppController()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}

switch args.first ?? "help" {
case "hook":
    // Must never slow down or break Claude: always exit 0, quickly.
    let event = args.count > 1 ? args[1] : ""
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let payload = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    _ = ControlSocket.request(["cmd": "hook", "event": event, "pane": env["TMUX_PANE"] ?? "", "payload": payload], timeout: 0.2)
    exit(0)

case "statusline-tap":
    // Pipe Claude Code's status-line JSON here (see README). Silent, fast, never fails.
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let payload = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    _ = ControlSocket.request(["cmd": "statusline", "pane": env["TMUX_PANE"] ?? "", "payload": payload], timeout: 0.2)
    exit(0)

case "start":
    // the real executable path (argv[0] may be a bare name found through PATH, or the ~/.local/bin symlink)
    let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard bundle.pathExtension == "app" else { fail("not running from Padctl.app — run scripts/build-app.sh") }
    if ControlSocket.request(["cmd": "status"]) != nil { out("padctl is already running."); exit(0) }
    // under the login agent (Start at login), start it through launchd so a crash restarts it
    let job = "gui/\(getuid())/com.pkronstrom.padctl.agent"
    if Shell.run(["launchctl", "print", job]).ok {
        let r = Shell.run(["launchctl", "kickstart", job])
        out(r.ok ? "Started (login agent: restarts after a crash)" : "launchctl kickstart failed: \(r.err)")
    } else {
        let r = Shell.run(["open", bundle.path])
        out(r.ok ? "Started \(bundle.path)" : "open failed: \(r.err)")
    }

case "init":
    guard let src = bundledConfig() else { fail("bundled config not found (set PADCTL_SHARE to the repo's config/ folder)") }
    let dst = Config.defaultRoot
    let fm = FileManager.default
    var copied = 0, kept = 0
    for case let f as URL in fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey])! {
        let rel = f.path.replacingOccurrences(of: src.path + "/", with: "")
        let target = dst.appendingPathComponent(rel)
        if (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try? fm.createDirectory(at: target, withIntermediateDirectories: true); continue
        }
        if fm.fileExists(atPath: target.path) { kept += 1; continue }
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try fm.copyItem(at: f, to: target); copied += 1 } catch { out("  could not copy \(rel): \(error)") }
    }
    out("Config at \(dst.path): \(copied) file(s) copied, \(kept) existing kept.")

case "status":
    out(jsonString(appRequest(["cmd": "status"])))

case "doctor":
    var problems = 0
    func check(_ ok: Bool, _ s: String) { out((ok ? "✓ " : "✗ ") + s); if !ok { problems += 1 } }
    do {
        let c = try Config.load()
        check(true, "config loads (\(c.layers.count) layers, device \(c.device.name))")
        for w in c.warnings { out("  ! \(w)") }
        check(!c.device.provisional, c.device.provisional ? "device profile is a provisional guess — run `padctl learn`" : "device profile learned")
    } catch { check(false, "config: \(error)") }
    check(Tmux.available, "tmux found")
    check(HooksInstaller.installed(), HooksInstaller.installed() ? "Claude hooks installed" : "Claude hooks not installed — `padctl hooks install`")
    check(HooksInstaller.codexInstalled(), HooksInstaller.codexInstalled() ? "Codex hooks installed (approve them once with /hooks in Codex)" : "Codex hooks not installed — `padctl hooks install`")
    let srcs = MIDIService.sources()
    check(!srcs.isEmpty, "MIDI sources: " + (srcs.isEmpty ? "none" : srcs.map(\.name).joined(separator: ", ")))
    if let s = ControlSocket.request(["cmd": "status"], timeout: 1) {
        check(true, "app running, layer: \(s["layer"] ?? "")")
        check(s["accessibility"] as? Bool ?? false, "Accessibility permission (needed for keystrokes)")
        check(s["connected"] as? Bool ?? false, "pad connected (bluetooth: \(s["bluetooth"] ?? ""))")
        if let e = s["error"] as? String { check(false, "app error: \(e)") }
    } else { check(false, "app not running — `padctl start`") }
    exit(problems == 0 ? 0 : 1)

case "monitor":
    MonitorTool.run(decodeWith: try? Config.load())

case "learn":
    let cfg: Config
    do { cfg = try Config.load() } catch { fail("config: \(error)\nRun `padctl init` first.") }
    let file = Config.defaultRoot.appendingPathComponent("devices/\(cfg.settings.device).toml")
    out("Learning \(cfg.device.name) → \(file.path)\nPress each control when asked. Enter skips a control.\n")
    if ControlSocket.request(["cmd": "status"]) != nil { out("(The app keeps running; it ignores presses it can't map until the new profile loads.)\n") }
    LearnTool(base: cfg.device, output: file).run()

case "legend":
    _ = appRequest(["cmd": "legend", "action": args.count > 1 ? args[1] : "pin"])

case "simulate":
    guard args.count >= 2 else { fail("usage: padctl simulate <control> [tap|hold|down|up|turn N]") }
    var req: [String: Any] = ["cmd": "simulate", "control": args[1], "event": args.count > 2 ? args[2] : "tap"]
    if args.count > 3, let n = Int(args[3]) { req["delta"] = n }
    out(jsonString(appRequest(req)))

case "state":
    if args.count >= 2 && args[1] == "get" {
        out(jsonString(appRequest(["cmd": "state_get"])["state"] ?? [:]))
    } else if args.count >= 4 && args[1] == "set" {
        let raw = args[3...].joined(separator: " ")
        let value: Any
        if let d = Double(raw) { value = d }
        else if raw == "true" || raw == "false" { value = raw == "true" }
        else if raw == "null" { value = NSNull() }
        else { value = raw }
        _ = appRequest(["cmd": "state_set", "key": args[2], "value": value])
    } else { fail("usage: padctl state get | padctl state set <key> <value>") }

case "reload":
    out(jsonString(appRequest(["cmd": "reload"])))

case "bt":
    out(jsonString(appRequest(["cmd": args.count > 1 && args[1] == "window" ? "bt_window" : "bt_connect"])))

case "items":
    // what a list (picker) shows right now, e.g. `padctl items skills` — add a query to see the search ranking
    guard args.count >= 2 else { fail("usage: padctl items <picker> [search words…]") }
    let cfg: Config
    do { cfg = try Config.load() } catch { fail("\(error)") }
    guard let def = cfg.pickers[args[1]] else { fail("no picker '\(args[1])' — known: \(cfg.pickers.keys.sorted().joined(separator: ", "))") }
    let items = def.resolveItems(config: cfg)
    if args.count > 2 {
        let q = args.dropFirst(2).joined(separator: " ")
        let ranked = PickerSearch.rank(items, q)
        let pick = PickerSearch.confident(ranked)
        for (it, sc) in ranked.prefix(10) { out("\(String(format: "%4d", sc))  \(it.label)\(it.value == pick?.value ? "   ← taken" : "")") }
        if ranked.isEmpty { out("no match for “\(q)”") }
    } else {
        for it in items { out(it.label) }
        out("— \(items.count) items")
    }

case "drums":
    // why no drum sound? padctl's side (map, bank) + padbeat's own report (audio engine, MIDI, hits)
    out(jsonString(appRequest(["cmd": "drums"])))
    usleep(400_000)
    let log = (try? String(contentsOfFile: NSHomeDirectory() + "/Library/Logs/padctl.log", encoding: .utf8)) ?? ""
    out(log.split(separator: "\n").last { $0.contains("padbeat: engine=") }.map(String.init) ?? "padbeat didn't answer (not running?)")

case "apps":
    out("Switch to the app you want… (3 s)")
    sleep(3)
    if let app = NSWorkspace.shared.frontmostApplication {
        out("bundle id: \(app.bundleIdentifier ?? "?")\nname:      \(app.localizedName ?? "?")")
        out("ruleset:   when = { app = [\"\(app.bundleIdentifier ?? "")\"] }")
    }

case "hooks":
    let exe = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/padctl")
    let bin = FileManager.default.fileExists(atPath: exe.path) ? exe.path : URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    switch args.count > 1 ? args[1] : "" {
    case "install":
        let only = args.count > 2 ? args[2] : "all"
        if only != "codex" {
            let r = HooksInstaller.install(binary: bin)
            out(r.ok ? "Claude Code: installed observe-only hooks (\(r.message)). New Claude sessions pick them up." : "Claude Code: failed: \(r.message)")
        }
        if only != "claude" {
            let r = HooksInstaller.installCodex(binary: bin)
            out(r.ok ? "Codex: installed observe-only hooks in ~/.codex/hooks.json (\(r.message)).\n       Approve them once: run /hooks inside Codex and trust the padctl entries." : "Codex: failed: \(r.message)")
        }
    case "uninstall":
        let only = args.count > 2 ? args[2] : "all"
        if only != "codex" {
            let r = HooksInstaller.install(binary: bin, uninstallOnly: true)
            out(r.ok ? "Claude Code: removed padctl hooks (\(r.message))." : "Claude Code: failed: \(r.message)")
        }
        if only != "claude" {
            let r = HooksInstaller.installCodex(binary: bin, uninstallOnly: true)
            out(r.ok ? "Codex: removed padctl hooks (\(r.message))." : "Codex: failed: \(r.message)")
        }
    default: fail("usage: padctl hooks install|uninstall [claude|codex]")
    }

case "send":
    // padctl send <dest-match> <status> <data1> <data2> [...more triples] — numbers in decimal or 0x hex
    guard args.count >= 5 else { fail("usage: padctl send <destination-substring> <status> <d1> <d2> ...") }
    let nums = args[2...].compactMap { $0.hasPrefix("0x") ? Int($0.dropFirst(2), radix: 16) : Int($0) }
    let midi = MIDIService()
    do { try midi.start() } catch { fail("MIDI: \(error)") }
    usleep(300_000)
    let dests = MIDIService.destinations().filter { $0.name.localizedCaseInsensitiveContains(args[1]) }
    guard !dests.isEmpty else { fail("no destination matching '\(args[1])': \(MIDIService.destinations().map(\.name))") }
    var i = 0
    while i + 2 < nums.count { midi.send([UInt8(nums[i]), UInt8(nums[i + 1]), UInt8(nums[i + 2])], to: args[1]); usleep(5_000); i += 3 }
    usleep(200_000)
    out("sent \(nums.count / 3) message(s) to \(dests.map(\.name).joined(separator: ", "))")

case "leds":
    // padctl leds start|stop|status|test|set <note> <#rrggbb>
    var req: [String: Any] = ["cmd": "leds", "action": args.count > 1 ? args[1] : "status"]
    if args.count > 3, args[1] == "set", let n = Int(args[2]) { req["note"] = n; req["color"] = args[3] }
    out(jsonString(appRequest(req)))

case "destinations":
    let midi = MIDIService(); try? midi.start(); usleep(300_000)
    out(MIDIService.destinations().map { "\($0.name)\($0.online ? "" : " (offline)")" }.joined(separator: "\n"))

case "version", "--version":
    out(Padctl.version)

default:
    out(help)
}
