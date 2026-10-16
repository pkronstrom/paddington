import Foundation
import PaddingtonCore

/// Thread-safe buffer of incoming MIDI for CLI tools that block while waiting.
final class MIDIInbox {
    private let lock = NSLock()
    private var items: [(MIDIMessage, String, Date)] = []
    func push(_ m: MIDIMessage, _ src: String) { lock.lock(); items.append((m, src, Date())); lock.unlock() }
    func drain() -> [(MIDIMessage, String, Date)] { lock.lock(); defer { items = []; lock.unlock() }; return items }
}

/// Reads stdin lines on a background thread so prompts can be skipped with Enter.
final class LineReader {
    private let lock = NSLock()
    private var lines: [String] = []
    init() {
        Thread.detachNewThread { [weak self] in
            while let l = readLine() { self?.lock.lock(); self?.lines.append(l); self?.lock.unlock() }
        }
    }
    func take() -> String? { lock.lock(); defer { lock.unlock() }; return lines.isEmpty ? nil : lines.removeFirst() }
    func clear() { lock.lock(); lines = []; lock.unlock() }
}

public enum MonitorTool {
    public static func run(decodeWith config: Config?) -> Never {
        let midi = MIDIService()
        let decoder = config.map { DeviceDecoder(profile: $0.device) }
        midi.onMessage = { m, src in
            var line = String(format: "%@  %-24@ %@", Self.time(), src as NSString, m.description as NSString)
            if let d = decoder, config.map({ $0.device.match.isEmpty || src.localizedCaseInsensitiveContains($0.device.match) }) ?? false {
                let ev = d.decode(m)
                if !ev.isEmpty { line += "   → " + ev.map { "\($0)" }.joined(separator: ", ") }
            }
            print(line); fflush(stdout)
        }
        midi.onSetupChanged = { print("— MIDI setup changed: \(MIDIService.sources().map(\.name).joined(separator: ", "))") }
        do { try midi.start() } catch { print("MIDI error: \(error)"); exit(1) }
        let srcs = MIDIService.sources()
        print("Sources: " + (srcs.isEmpty ? "none — connect the pad first" : srcs.map { "\($0.name)\($0.online ? "" : " (offline)")" }.joined(separator: ", ")))
        print("Listening. Ctrl-C to stop.")
        dispatchMain()
    }

    static func time() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date())
    }
}

/// Interactive profile builder: press each control when asked; writes devices/<file>.toml.
public final class LearnTool {
    let midi = MIDIService()
    let inbox = MIDIInbox()
    let input = LineReader()
    var source: String?
    let out: URL
    let base: DeviceProfile

    public init(base: DeviceProfile, output: URL) { self.base = base; self.out = output }

    func say(_ s: String) { print(s); fflush(stdout) }

    var lastSource: String?

    func waitFirst(timeout: Double? = nil, accept: (MIDIMessage) -> Bool) -> MIDIMessage? {
        input.clear(); _ = inbox.drain()
        let start = Date()
        while true {
            if input.take() != nil { return nil }
            for (m, src, _) in inbox.drain() where source == nil || src == source {
                if accept(m) { lastSource = src; return m }
            }
            if let t = timeout, Date().timeIntervalSince(start) > t { return nil }
            usleep(10_000)
        }
    }

    func collect(for seconds: Double, cc: Int) -> [Int] {
        var vals: [Int] = []
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            for (m, src, _) in inbox.drain() where (source == nil || src == source) && m.isCC && m.data1 == cc { vals.append(m.data2) }
            usleep(10_000)
        }
        return vals
    }

    static func encoding(right: [Int], left: [Int]) -> KnobEncoding {
        func all(_ v: [Int], _ r: ClosedRange<Int>) -> Bool { !v.isEmpty && v.allSatisfy { r.contains($0) } }
        if all(right, 1...20) && all(left, 108...127) { return .relative2c }
        if all(right, 65...84) && all(left, 44...63) { return .offset64 }
        if all(right, 1...20) && all(left, 65...84) { return .signBit }
        return .absolute
    }

    public func run() -> Never {
        midi.onMessage = { [inbox] m, s in inbox.push(m, s) }
        do { try midi.start() } catch { say("MIDI error: \(error)"); exit(1) }
        Thread.detachNewThread { [self] in self.learn(); exit(0) }
        dispatchMain()
    }

    func learn() {
        usleep(300_000)
        let srcs = MIDIService.sources().filter(\.online)
        if srcs.isEmpty {
            say("No MIDI source found. Connect the pad first (the Paddington menu-bar icon (4×4 grid) › Connect pad, or Bluetooth MIDI window).")
            return
        }
        say("MIDI sources: " + srcs.map(\.name).joined(separator: ", "))
        say("\nPress PAD 1 (bottom-left) to pick the device…")
        guard let first = waitFirst(accept: { $0.isNoteOn || ($0.isCC && $0.data2 > 0) }) else { say("Cancelled."); return }
        // the source of that press becomes the device
        let srcName = lastSource ?? srcs.first!.name
        source = srcName
        say("Using source: \(srcName)\n")
        var lines: [String] = []
        var used = Set<String>()
        func key(_ m: MIDIMessage) -> String { m.isCC ? "cc\(m.data1)/\(m.channel)" : "n\(m.data1)/\(m.channel)" }
        func spec(_ m: MIDIMessage) -> String {
            (m.isCC ? "cc = \(m.data1)" : "note = \(m.data1)") + ", channel = \(m.channel + 1)"
        }
        // first press was pad1
        lines.append("pad1 = { \(spec(first)) }"); used.insert(key(first))
        let pads = base.layout.padRows * base.layout.padCols
        for n in 2...pads {
            say("Press PAD \(n)   (Enter = skip)")
            guard let m = waitFirst(accept: { ($0.isNoteOn || ($0.isCC && $0.data2 > 0)) && !used.contains(key($0)) }) else { say("  skipped"); continue }
            lines.append("pad\(n) = { \(spec(m)) }"); used.insert(key(m)); say("  → \(m)")
        }
        let knobs = base.layout.knobRows * base.layout.knobCols
        for n in 1...knobs {
            say("Turn KNOB \(n) slowly to the RIGHT (clockwise)   (Enter = skip)")
            guard let m = waitFirst(accept: { $0.isCC && !used.contains(key($0)) }) else { say("  skipped"); continue }
            let right = [m.data2] + collect(for: 1.2, cc: m.data1)
            say("  now turn it to the LEFT")
            _ = waitFirst(timeout: 10, accept: { $0.isCC && $0.data1 == m.data1 })
            let left = collect(for: 1.2, cc: m.data1)
            let enc = Self.encoding(right: right, left: left)
            lines.append("knob\(n) = { \(spec(m)), encoding = \"\(enc.rawValue)\" }")
            used.insert(key(m)); say("  → cc \(m.data1), \(enc.rawValue)   (right \(right.prefix(4)), left \(left.prefix(4)))")
        }
        var hardwareOnly: [String] = []
        for b in base.layout.buttons {
            let label = base.layout.labels[b] ?? b
            say("Press and release \(label)   (Enter = it sends nothing)")
            guard let m = waitFirst(accept: { ($0.isNoteOn || ($0.isCC && $0.data2 > 0)) && !used.contains(key($0)) }) else {
                hardwareOnly.append(b); say("  hardware only"); continue
            }
            var toggles = false
            if m.isCC {
                let after = collect(for: 1.0, cc: m.data1)
                toggles = !after.contains(0)
            }
            lines.append("\(b) = { \(spec(m))\(toggles ? ", toggles = true" : "") }")
            used.insert(key(m)); say("  → \(m)\(toggles ? " (one message per press)" : "")")
        }
        var bankB: [String] = []
        say("\nOptional: switch PAD BANK to bank B, then press PAD 1   (Enter = skip)")
        if let m = waitFirst(accept: { ($0.isNoteOn || ($0.isCC && $0.data2 > 0)) }), let pad1 = lines.first {
            let a = Int(pad1.components(separatedBy: "= ")[2].components(separatedBy: ",")[0].trimmingCharacters(in: .whitespaces)) ?? -1
            let offset = m.data1 - a
            if offset != 0 {
                for n in 1...pads {
                    if let l = lines.first(where: { $0.hasPrefix("pad\(n) = ") }), let v = Int(l.components(separatedBy: "= ")[2].components(separatedBy: ",")[0].trimmingCharacters(in: .whitespaces)) {
                        bankB.append("pad\(n) = { \(m.isCC ? "cc" : "note") = \(v + offset), channel = \(m.channel + 1) }")
                    }
                }
                say("  bank B = bank A + \(offset)")
            } else { say("  bank B sends the same messages; no bank mapping needed") }
        }
        write(lines: lines, bankB: bankB, hardwareOnly: hardwareOnly, source: srcName)
    }

    func write(lines: [String], bankB: [String], hardwareOnly: [String], source: String) {
        let quoted = { (a: [String]) in a.map { "\"\($0)\"" }.joined(separator: ", ") }
        var t = """
        # Learned by `paddington learn` on \(ISO8601DateFormatter().string(from: Date())) from "\(source)".
        name = "\(base.name)"
        match = "\(source)"
        hardware_only = [\(quoted(hardwareOnly))]

        [layout]
        pads = [\(base.layout.padRows), \(base.layout.padCols)]
        knobs = [\(base.layout.knobRows), \(base.layout.knobCols)]
        buttons = [\(quoted(base.layout.buttons))]

        [labels]

        """
        for b in base.layout.buttons { if let l = base.layout.labels[b] { t += "\(b) = \"\(l)\"\n" } }
        t += "\n[controls]\n" + lines.joined(separator: "\n") + "\n"
        if !bankB.isEmpty { t += "\n[controls_bank_b]\n" + bankB.joined(separator: "\n") + "\n" }
        let fm = FileManager.default
        if fm.fileExists(atPath: out.path) {
            let bak = out.appendingPathExtension("bak")
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: out, to: bak)
        }
        do {
            try t.write(to: out, atomically: true, encoding: .utf8)
            say("\nWrote \(out.path)\(fm.fileExists(atPath: out.path + ".bak") ? " (previous saved as .bak)" : ""). The app reloads it automatically.")
            if !hardwareOnly.isEmpty { say("Hardware-only (sent nothing): \(hardwareOnly.joined(separator: ", ")).") }
            if hardwareOnly.contains("shift") || hardwareOnly.contains("note_repeat") {
                say("Tip: SHIFT/NOTE REPEAT are roles in config.toml [roles] — point them at a control that sends MIDI.")
            }
        } catch { say("Write failed: \(error)") }
    }
}
