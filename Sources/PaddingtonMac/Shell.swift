import AppKit
import Foundation
import PaddingtonCore

public struct RunResult {
    public var status: Int32
    public var out: String
    public var err: String
    public var ok: Bool { status == 0 }
}

/// ~/Library/Logs/paddington.log: context changes and failures, for "why did it show Default?".
/// PADDINGTON_LOG=<path> writes elsewhere (test instances).
public enum Log {
    static let url = ProcessInfo.processInfo.environment["PADDINGTON_LOG"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/paddington.log")
    static let lock = NSLock()
    static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()

    public static func write(_ msg: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(stamp.string(from: Date())) \(msg)\n"
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
            let old = url.deletingPathExtension().appendingPathExtension("1.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

public enum Shell {
    /// PATH for child processes: an app launched from Finder gets a minimal PATH.
    public static let path: String = {
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/.cargo/bin",
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let cur = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (cur + extra).filter { seen.insert($0).inserted }.joined(separator: ":")
    }()

    public static func which(_ name: String) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for d in path.split(separator: ":") {
            let p = "\(d)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Run a program (no shell) and wait, with a timeout.
    @discardableResult
    public static func run(_ argv: [String], cwd: String? = nil, env: [String: String] = [:], input: String? = nil,
                           timeout: Double = 5) -> RunResult {
        guard let first = argv.first, let exe = which(first) else {
            return RunResult(status: 127, out: "", err: "\(argv.first ?? "?"): not found")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(argv.dropFirst())
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = path
        // without a UTF-8 locale tmux 3.6 escapes tabs in -F output as "_" (an app started by launchd has no LANG)
        if e["LANG"] == nil && e["LC_ALL"] == nil && e["LC_CTYPE"] == nil { e["LANG"] = "en_US.UTF-8" }
        for (k, v) in env { e[k] = v }
        p.environment = e
        if let cwd, FileManager.default.fileExists(atPath: cwd) { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe; p.standardInput = inPipe
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        do { try p.run() } catch { return RunResult(status: 126, out: "", err: error.localizedDescription) }
        if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)) }
        try? inPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(5_000) }
        if p.isRunning { p.terminate(); usleep(50_000); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        p.waitUntilExit()
        group.wait()
        return RunResult(status: p.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                         err: String(decoding: errData, as: UTF8.self))
    }

    /// Start a program and don't wait (new windows, long-running tools).
    public static func spawn(_ argv: [String], cwd: String? = nil) -> String? {
        guard let first = argv.first, let exe = which(first) else { return "\(argv.first ?? "?"): not found" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(argv.dropFirst())
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = path
        if e["LANG"] == nil && e["LC_ALL"] == nil && e["LC_CTYPE"] == nil { e["LANG"] = "en_US.UTF-8" }
        p.environment = e
        if let cwd, FileManager.default.fileExists(atPath: cwd) { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return error.localizedDescription }
        return nil
    }
}

public enum Tmux {
    public static var available: Bool { Shell.which("tmux") != nil }

    /// PADDINGTON_TMUX_SOCKET=name targets an isolated server (`tmux -L name`), for tests.
    static let socketArgs: [String] = ProcessInfo.processInfo.environment["PADDINGTON_TMUX_SOCKET"].map { ["-L", $0] } ?? []

    @discardableResult
    public static func run(_ args: [String], timeout: Double = 2) -> RunResult { Shell.run(["tmux"] + socketArgs + args, timeout: timeout) }

    public static func panes() -> [PaneInfo] { (try? panesOrError()) ?? [] }

    static let shells: Set<String> = ["fish", "bash", "zsh", "sh", "dash", "nu", "login"]

    /// A window started as `new-window … claude` runs `fish -c claude`: Claude is a child in fish's process
    /// group, so tmux names the pane "fish". When a shell runs an agent start command, the pane is that agent.
    /// (If the agent exits, a `-c` shell exits too and the pane closes, so this can't go stale.)
    static func agentCommand(current: String, start: String) -> String {
        guard shells.contains(current) else { return current }
        let first = start.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).split(separator: " ").first.map(String.init) ?? ""
        let name = (first as NSString).lastPathComponent
        return Snapshot.agentCommands.contains(name) ? name : current
    }

    /// Throws when tmux itself fails (as opposed to "no server running", which is simply no panes).
    public static func panesOrError() throws -> [PaneInfo] {
        let fmt = "#{session_name}\t#{window_index}\t#{window_name}\t#{pane_id}\t#{pane_active}\t#{window_active}\t#{pane_current_command}\t#{pane_current_path}\t#{window_zoomed_flag}\t#{pane_start_command}"
        let r = run(["list-panes", "-a", "-F", fmt])
        guard r.ok else {
            let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            // no server at all is fine (no panes); a socket that exists but can't be reached is an error
            // (e.g. paddington was started inside an agent's sandbox) and must not look like "no tmux"
            if err.contains("no server running") || (err.contains("error connecting") && err.contains("No such file")) { return [] }
            throw KeyError("tmux list-panes failed (\(r.status)): \(err.isEmpty ? "timed out?" : err)")
        }
        let lines = r.out.split(separator: "\n")
        let panes = lines.compactMap { line -> PaneInfo? in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8, let w = Int(f[1]) else { return nil }
            var p = PaneInfo(session: f[0], window: w, windowName: f[2], paneId: f[3], active: f[4] == "1" && f[5] == "1",
                             command: agentCommand(current: f[6], start: f.count > 9 ? f[9...].joined(separator: "\t") : ""), path: f[7])
            p.zoomed = f.count > 8 && f[8] == "1"
            return p
        }
        if panes.isEmpty && !lines.isEmpty { throw KeyError("tmux output not understood (locale?): \(lines[0].prefix(80))") }
        return panes
    }

    public struct Client { public var tty: String; public var session: String; public var activity: Int }

    public static func clients() -> [Client] {
        let r = run(["list-clients", "-F", "#{client_tty}\t#{client_session}\t#{client_activity}"])
        guard r.ok else { return [] }
        return r.out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t").map(String.init)
            guard f.count >= 3 else { return nil }
            return Client(tty: f[0], session: f[1], activity: Int(f[2]) ?? 0)
        }
    }

    /// The pane shown by the client attached to `tty` (or the most recently active client when tty is unknown).
    public static func focusedPane(tty: String?, panes: [PaneInfo]) -> PaneInfo? {
        let cs = clients()
        if cs.isEmpty && !socketArgs.isEmpty { return panes.first { $0.active } }   // isolated test server, no client attached
        guard !cs.isEmpty else { return nil }
        let client: Client?
        if let tty { client = cs.first { $0.tty == tty } } else { client = cs.max { $0.activity < $1.activity } }
        guard let c = client else { return nil }
        return panes.first { $0.session == c.session && $0.active }
    }

    /// Switch the client that shows `pane`'s session … or any client, to that pane.
    public static func focus(pane: String, panes: [PaneInfo], clientTTY: String?) -> RunResult {
        guard let p = panes.first(where: { $0.paneId == pane }) else { return RunResult(status: 1, out: "", err: "pane \(pane) is gone") }
        var args = ["switch-client"]
        if let t = clientTTY { args += ["-c", t] }
        args += ["-t", "\(p.session):\(p.window)"]
        let r = run(args)
        run(["select-window", "-t", "\(p.session):\(p.window)"])
        run(["select-pane", "-t", pane])
        return r
    }
}

/// iTerm2: tty of the focused session (needs Automation permission once).
public enum ITerm {
    public static let bundleId = "com.googlecode.iterm2"
    private static let queue = DispatchQueue(label: "paddington.iterm")
    private static var cached: String?
    private static var cachedAt = Date.distantPast
    private static var inFlight = false

    /// Non-blocking: returns the last known tty and refreshes it in the background. A lookup runs as a
    /// killable `osascript` with a timeout (an in-process NSAppleScript could hang and freeze the answer);
    /// an answer older than 3 s counts as unknown, so callers fall back to the most active tmux client.
    public static func focusedTTYCached() -> String? {
        if !inFlight {
            inFlight = true
            queue.async {
                let t = focusedTTY()
                DispatchQueue.main.async {
                    cached = t; inFlight = false
                    if t != nil { cachedAt = Date() }
                }
            }
        }
        return Date().timeIntervalSince(cachedAt) < 3 ? cached : nil
    }

    static let script = """
        tell application id "com.googlecode.iterm2"
            if (count of windows) is 0 then return ""
            return tty of current session of current window
        end tell
        """

    public static func focusedTTY() -> String? {
        let r = Shell.run(["osascript", "-e", script], timeout: 2)
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && s.hasPrefix("/dev/") ? s : nil
    }
}
