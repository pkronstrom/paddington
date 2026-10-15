import Foundation

public struct MIDIMessage: Equatable, CustomStringConvertible {
    public var status: UInt8   // high nibble: 0x80 note off, 0x90 note on, 0xB0 CC, …
    public var channel: Int    // 0-15
    public var data1: Int
    public var data2: Int
    public init(status: UInt8, channel: Int, data1: Int, data2: Int) {
        self.status = status; self.channel = channel; self.data1 = data1; self.data2 = data2
    }
    public init?(bytes: [UInt8]) {
        guard bytes.count >= 2, bytes[0] & 0x80 != 0, bytes[0] < 0xF0 else { return nil }
        status = bytes[0] & 0xF0; channel = Int(bytes[0] & 0x0F)
        data1 = Int(bytes[1]); data2 = bytes.count > 2 ? Int(bytes[2]) : 0
    }
    public var isNoteOn: Bool { status == 0x90 && data2 > 0 }
    public var isNoteOff: Bool { status == 0x80 || (status == 0x90 && data2 == 0) }
    public var isCC: Bool { status == 0xB0 }
    public var description: String {
        let ch = "ch\(channel + 1)"
        switch status {
        case 0x90 where data2 > 0: return "note-on  \(ch) note=\(data1) vel=\(data2)"
        case 0x80, 0x90: return "note-off \(ch) note=\(data1)"
        case 0xB0: return "cc       \(ch) cc=\(data1) value=\(data2)"
        case 0xA0: return "poly-at  \(ch) note=\(data1) value=\(data2)"
        case 0xD0: return "chan-at  \(ch) value=\(data1)"
        case 0xE0: return "pitch    \(ch) value=\(data1 | data2 << 7)"
        case 0xC0: return "program  \(ch) program=\(data1)"
        default: return String(format: "status=%02X %@ %d %d", status, ch, data1, data2)
        }
    }
}

public enum KnobEncoding: String {
    case relative2c = "relative-2c"          // 1…63 = +n, 65…127 = −(128−v)
    case offset64 = "relative-offset64"      // v − 64
    case signBit = "relative-signbit"        // bit 6 = negative, low 6 bits = n
    case absolute = "absolute"               // delta from last value

    public func delta(_ v: Int, last: Int?) -> Int {
        switch self {
        case .relative2c: return v == 0 ? 0 : (v < 64 ? v : v - 128)
        case .offset64: return v - 64
        case .signBit: return v & 64 != 0 ? -(v & 63) : (v & 63)
        case .absolute:
            guard let last else { return 0 }
            if v == 127 && last == 127 { return 1 }
            if v == 0 && last == 0 { return -1 }
            return v - last
        }
    }
}

public enum ControlKind: String { case pad, knob, button }

public struct ControlSpec: Equatable {
    public var name: String
    public var kind: ControlKind
    public var note: Int?
    public var cc: Int?
    public var channel: Int?        // 0-based; nil = any
    public var encoding: KnobEncoding
    public var toggles: Bool        // CC button sends one message per press (no release)
    public var bank: String         // "A" or "B"
}

public struct DeviceLayout: Equatable {
    public var padRows = 4, padCols = 4
    public var knobRows = 4, knobCols = 2
    public var buttons: [String] = []          // side column, top to bottom
    public var labels: [String: String] = [:]  // short printed labels for buttons
    public init() {}
}

public enum ControlEvent: Equatable {
    case down(String)
    case up(String)
    case turn(String, Int)
    public var control: String {
        switch self { case .down(let c), .up(let c), .turn(let c, _): return c }
    }
}

public struct DeviceProfile {
    public var name: String
    public var match: String
    public var layout: DeviceLayout
    public var controls: [ControlSpec]
    public var hardwareOnly: Set<String>
    public var provisional: Bool

    public func kind(of control: String) -> ControlKind {
        if control.hasPrefix("pad"), Int(control.dropFirst(3)) != nil { return .pad }
        if control.hasPrefix("knob"), Int(control.dropFirst(4)) != nil { return .knob }
        return .button
    }

    public var allControlNames: [String] {
        (1...(layout.padRows * layout.padCols)).map { "pad\($0)" }
            + (1...(layout.knobRows * layout.knobCols)).map { "knob\($0)" }
            + layout.buttons
    }

    public static func load(_ url: URL) throws -> DeviceProfile {
        try parse(TOML.load(url), file: url.lastPathComponent)
    }

    public static func parse(_ t: [String: Value], file: String) throws -> DeviceProfile {
        var layout = DeviceLayout()
        if let l = t["layout"]?.table {
            if let p = l["pads"]?.array, p.count == 2 { layout.padRows = p[0].int ?? 4; layout.padCols = p[1].int ?? 4 }
            if let k = l["knobs"]?.array, k.count == 2 { layout.knobRows = k[0].int ?? 4; layout.knobCols = k[1].int ?? 2 }
            layout.buttons = l["buttons"]?.stringList ?? []
        }
        layout.labels = (t["labels"]?.table ?? [:]).compactMapValues { $0.string }
        var p = DeviceProfile(name: t["name"]?.string ?? file, match: t["match"]?.string ?? "",
                              layout: layout, controls: [],
                              hardwareOnly: Set(t["hardware_only"]?.stringList ?? []),
                              provisional: t["provisional"]?.bool ?? false)
        for (section, bank) in [("controls", "A"), ("controls_bank_b", "B")] {
            for (name, v) in t[section]?.table ?? [:] {
                guard let c = v.table else { throw ConfigError(file: file, "\(section).\(name) must be a table") }
                let enc = c["encoding"]?.string.flatMap(KnobEncoding.init(rawValue:)) ?? .relative2c
                if c["encoding"] != nil, KnobEncoding(rawValue: c["encoding"]?.string ?? "") == nil {
                    throw ConfigError(file: file, "\(name): unknown encoding \(c["encoding"]!)")
                }
                guard c["note"] != nil || c["cc"] != nil else { throw ConfigError(file: file, "\(name): needs note or cc") }
                p.controls.append(ControlSpec(name: name, kind: p.kind(of: name), note: c["note"]?.int, cc: c["cc"]?.int,
                                              channel: c["channel"]?.int.map { $0 - 1 },
                                              encoding: enc, toggles: c["toggles"]?.bool ?? false, bank: bank))
            }
        }
        return p
    }
}

/// Stateful decoder: raw MIDI → logical events. Tracks the active pad bank and absolute knob values.
public final class DeviceDecoder {
    public let profile: DeviceProfile
    public private(set) var padBank = "A"
    public private(set) var knobBank = "A"
    private var lastValue: [String: Int] = [:]

    public init(profile: DeviceProfile) { self.profile = profile }

    public func decode(_ m: MIDIMessage) -> [ControlEvent] {
        for c in profile.controls {
            if let ch = c.channel, ch != m.channel { continue }
            if let n = c.note, (m.status == 0x90 || m.status == 0x80), m.data1 == n {
                if c.kind == .pad { padBank = c.bank }
                if c.kind == .knob { return [] }
                return [m.isNoteOn ? .down(c.name) : .up(c.name)]
            }
            if let cc = c.cc, m.isCC, m.data1 == cc {
                if c.kind == .knob {
                    knobBank = c.bank
                    let key = c.name + c.bank
                    let d = c.encoding.delta(m.data2, last: lastValue[key])
                    lastValue[key] = m.data2
                    return d == 0 ? [] : [.turn(c.name, d)]
                }
                if c.kind == .pad { padBank = c.bank }
                if c.toggles { return [.down(c.name), .up(c.name)] }
                return [m.data2 > 0 ? .down(c.name) : .up(c.name)]
            }
        }
        return []
    }
}
