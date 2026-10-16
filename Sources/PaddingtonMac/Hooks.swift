import Foundation

/// Observe-only agent hooks. Entries are recognised by "paddington hook " (or "padctl hook ", the old name).
/// Claude Code: ~/.claude/settings.json · Codex: ~/.codex/hooks.json (same event → matcher group → handlers shape).
public enum HooksInstaller {
    public static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "StopFailure",
                                "PreCompact", "PostCompact"]
    public static let codexEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                                     "PostToolUse", "PreCompact", "PostCompact", "Stop", "Interrupt"]

    /// Commands that are ours: the current name and the old one (padctl), so install replaces old entries.
    static let markers = ["paddington hook ", "padctl hook "]

    static var settingsPath: String { ProcessInfo.processInfo.environment["PADDINGTON_CLAUDE_SETTINGS"] ?? NSHomeDirectory() + "/.claude/settings.json" }
    static var codexPath: String { ProcessInfo.processInfo.environment["PADDINGTON_CODEX_HOOKS"] ?? NSHomeDirectory() + "/.codex/hooks.json" }

    public static func installCodex(binary: String, uninstallOnly: Bool = false) -> (ok: Bool, message: String) {
        let path = codexPath
        if !FileManager.default.fileExists(atPath: path) {
            if uninstallOnly { return (true, "nothing to remove") }
            guard FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent) else { return (false, "Codex config folder not found") }
            FileManager.default.createFile(atPath: path, contents: Data("{}\n".utf8))
        }
        return edit(path: path, binary: binary, events: codexEvents, uninstallOnly: uninstallOnly)
    }

    /// Edits with python3 so key order and formatting style survive; backs up first.
    public static func install(binary: String, uninstallOnly: Bool = false) -> (ok: Bool, message: String) {
        let path = settingsPath
        guard FileManager.default.fileExists(atPath: path) else { return (false, "\(path) not found") }
        return edit(path: path, binary: binary, events: events, uninstallOnly: uninstallOnly)
    }

    static func edit(path: String, binary: String, events: [String], uninstallOnly: Bool) -> (ok: Bool, message: String) {
        let backup = path + ".paddington-backup"
        try? FileManager.default.removeItem(atPath: backup)
        do { try FileManager.default.copyItem(atPath: path, toPath: backup) } catch { return (false, "backup failed: \(error)") }
        let script = """
        import json, sys
        path, binary, mode = sys.argv[1], sys.argv[2], sys.argv[3]
        events = sys.argv[4].split(",")
        markers = sys.argv[5].split(",")
        with open(path) as f: data = json.load(f)
        hooks = data.setdefault("hooks", {})
        removed = 0
        for ev in list(hooks.keys()):
            groups = []
            for g in hooks[ev]:
                hs = [h for h in g.get("hooks", []) if not any(m in h.get("command", "") for m in markers)]
                removed += len(g.get("hooks", [])) - len(hs)
                if hs: g["hooks"] = hs; groups.append(g)
            if groups: hooks[ev] = groups
            else: del hooks[ev]
        added = 0
        if mode == "install":
            for ev in events:
                hooks.setdefault(ev, []).append({"hooks": [{"type": "command", "command": f"{binary} hook {ev}", "timeout": 2 if ev in ("SessionEnd", "Interrupt") else 5}]})
                added += 1
        if not hooks: del data["hooks"]
        with open(path, "w") as f:
            json.dump(data, f, indent=2, ensure_ascii=False); f.write("\\n")
        print(f"removed {removed}, added {added}")
        """
        let r = Shell.run(["python3", "-I", "-c", script, path, binary, uninstallOnly ? "uninstall" : "install",
                           events.joined(separator: ","), markers.joined(separator: ",")], timeout: 15)
        guard r.ok else { return (false, "edit failed: \(r.err)") }
        return (true, "\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) — backup at \(backup)")
    }

    public static func installed() -> Bool { has(settingsPath, markers) }
    public static func codexInstalled() -> Bool { has(codexPath, markers) }
    /// Still installed under the old name: they work (the build keeps a `padctl` link), `hooks install` renames them.
    public static func oldName() -> Bool { has(settingsPath, ["padctl hook "]) || has(codexPath, ["padctl hook "]) }

    static func has(_ path: String, _ marks: [String]) -> Bool {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return marks.contains { s.contains($0) }
    }
}
