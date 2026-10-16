import CoreBluetooth
import Foundation

/// SMC-PAD pad lights over Bluetooth LE (GATT service AE40), separate from MIDI.
/// Protocol and the unlock session come from github.com/spectalive/smc-pad (Apache-2.0):
/// packets are [00 59 <cmd> <len24-le> <data> <~sum(data)>]; colour = cmd 22, data 05 <addr32> 03 00 00 R G B,
/// addr = 0x418 + (note - 36) * 26 for bank A of the first preset (bank B: see address(note:)). Writes are ignored until the official app's
/// connect session is replayed; a read poll every 0.5 s keeps it open.
public final class PadLEDs: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "AE40")
    static let writeUUID = CBUUID(string: "AE41")
    static let notifyUUID = CBUUID(string: "AE42")
    /// A second command service in the same shape (AE01 in, AE02 out); only listened to, for research.
    static let altService = CBUUID(string: "AE00")
    static let altNotifyUUID = CBUUID(string: "AE02")
    /// The official app's connect session (discovery + config reads), from spectalive/smc-pad reference/gatt_unlock.txt.
    static let unlock: [String] = [
        "00 59 11 00 00 00 FF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 05 00 00 00 00 F1 03 00 06",
        "00 59 23 08 00 00 05 F1 03 00 00 F1 03 00 12",
        "00 59 23 08 00 00 05 E2 07 00 00 F1 03 00 1D",
        "00 59 23 08 00 00 05 D3 0B 00 00 F1 03 00 28",
        "00 59 23 08 00 00 05 C4 0F 00 00 F1 03 00 33",
        "00 59 23 08 00 00 05 B5 13 00 00 F1 03 00 3E",
        "00 59 23 08 00 00 05 A6 17 00 00 F1 03 00 49",
        "00 59 23 08 00 00 05 97 1B 00 00 F1 03 00 54",
        "00 59 23 08 00 00 05 88 1F 00 00 F1 03 00 5F",
        "00 59 23 08 00 00 05 79 23 00 00 F1 03 00 6A",
        "00 59 23 08 00 00 05 6A 27 00 00 F1 03 00 75",
        "00 59 23 08 00 00 05 5B 2B 00 00 F1 03 00 80",
        "00 59 23 08 00 00 05 4C 2F 00 00 F1 03 00 8B",
        "00 59 23 08 00 00 05 3D 33 00 00 F1 03 00 96",
        "00 59 23 08 00 00 05 2E 37 00 00 F1 03 00 A1",
        "00 59 23 08 00 00 05 1F 3B 00 00 F1 03 00 AC",
        "00 59 23 08 00 00 05 10 3F 00 00 F1 03 00 B7",
        "00 59 23 08 00 00 05 01 43 00 00 F1 03 00 C2",
        "00 59 23 08 00 00 05 F2 46 00 00 F1 03 00 CE",
        "00 59 23 08 00 00 05 E3 4A 00 00 F1 03 00 D9",
        "00 59 23 08 00 00 05 D4 4E 00 00 F1 03 00 E4",
        "00 59 23 08 00 00 05 C5 52 00 00 F1 03 00 EF",
        "00 59 23 08 00 00 05 B6 56 00 00 F1 03 00 FA",
        "00 59 23 08 00 00 05 A7 5A 00 00 F1 03 00 05",
        "00 59 23 08 00 00 05 98 5E 00 00 F1 03 00 10",
        "00 59 23 08 00 00 05 89 62 00 00 F1 03 00 1B",
        "00 59 23 08 00 00 05 7A 66 00 00 F1 03 00 26",
        "00 59 23 08 00 00 05 6B 6A 00 00 F1 03 00 31",
        "00 59 23 08 00 00 05 5C 6E 00 00 3C 00 00 F4",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF"
    ]

    public var onStatus: ((String) -> Void)?
    public private(set) var ready = false
    public private(set) var status = "off"

    private var central: CBCentralManager?
    private var pad: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var timers: [Timer] = []
    private var current: [Int: (UInt8, UInt8, UInt8)] = [:]   // note → colour last written
    private var pending: [Int: (UInt8, UInt8, UInt8)] = [:]
    private var pump: Timer?
    public var profile = 0                                   // pad preset (SHIFT + pads 1–8 switch it)
    /// The pad's global settings block (region 4, 12 bytes), read by the keep-alive poll twice a second. Its
    /// fields aren't documented; changes are logged to find out what SHIFT / NOTE REPEAT combinations change.
    public private(set) var global: [UInt8] = []
    public var onGlobal: (([UInt8]) -> Void)?
    /// What the global bytes are, as far as known (docs/smc-pad-findings.md).
    public enum Global {
        public static let size = 12
        public static let tempo = 0          // 0x78 = 120 (BPM, note repeat)
        public static let swing = 2          // 0x32 = 50
        public static let noteRepeat = 5     // 1 = note repeat latched on (lights NOTE REPEAT)
        public static let octave = 6         // the colour group bank A shows (and its notes): 2 = notes 36–51
        public static let shiftPads9to12 = 8 // SHIFT + pad 9 / 10 / 11 / 12 → 0 / 1 / 2 / 3
        public static let preset = 10        // SHIFT + pad 1–8: 0–7
        public static let padBank = 11       // PAD BANK: 0 = A, 1 = B
    }
    private var rx: [UInt8] = []                             // AE42 bytes not yet parsed into a frame
    private var config: [UInt8] = []                         // region 5 (all presets) as the unlock reads it
    private var oddFrames = 0

    public override init() { super.init() }

    func report(_ s: String) { status = s; DispatchQueue.main.async { self.onStatus?(s) } }

    public func start() {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) } else { connect() }
    }

    public func stop() {
        timers.forEach { $0.invalidate() }; timers = []
        pump?.invalidate(); pump = nil
        ready = false; writeChar = nil; current = [:]
        if let p = pad { central?.cancelPeripheralConnection(p) }
        report("off")
    }

    func connect() {
        guard let c = central, c.state == .poweredOn else { return }
        // a bonded pad stops advertising: take it from the system's connections
        if let p = c.retrieveConnectedPeripherals(withServices: [Self.service]).first
            ?? c.retrieveConnectedPeripherals(withServices: [CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")]).first(where: { ($0.name ?? "").contains("SMC") }) {
            pad = p; p.delegate = self; c.connect(p, options: nil); report("connecting LEDs…")
        } else {
            report("pad not connected")
        }
    }

    public func centralManagerDidUpdateState(_ c: CBCentralManager) { if c.state == .poweredOn { connect() } }
    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([Self.service, Self.altService]) }
    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        ready = false; writeChar = nil; current = [:]
        timers.forEach { $0.invalidate() }; timers = []
        report("LEDs disconnected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.connect() }
    }
    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let alt = p.services?.first(where: { $0.uuid == Self.altService }) { p.discoverCharacteristics([Self.altNotifyUUID], for: alt) }
        guard let s = p.services?.first(where: { $0.uuid == Self.service }) else { report("no LED service"); return }
        p.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: s)
    }
    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        if s.uuid == Self.altService {
            for ch in s.characteristics ?? [] where ch.uuid == Self.altNotifyUUID { p.setNotifyValue(true, for: ch) }
            return
        }
        for ch in s.characteristics ?? [] {
            if ch.uuid == Self.notifyUUID { p.setNotifyValue(true, for: ch) }
            if ch.uuid == Self.writeUUID { writeChar = ch }
        }
        if writeChar != nil { config = []; runUnlock() }
    }
    public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value, !v.isEmpty else { return }
        guard ch.uuid == Self.notifyUUID else {
            Log.write("pad \(ch.uuid.uuidString): \(Self.hex(Array(v)))"); return
        }
        rx += v
        if rx.count > 8192 { rx = [] }
        while let f = Self.nextFrame(&rx) { handle(frame: f) }
    }

    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

    /// One logical packet `00 59 <cmd> <len24> <data> <sum>` off the front of the buffer, once it's all there.
    static func nextFrame(_ buf: inout [UInt8]) -> [UInt8]? {
        while buf.count >= 2, !(buf[0] == 0x00 && buf[1] == 0x59) { buf.removeFirst() }
        guard buf.count >= 6 else { return nil }
        let len = Int(buf[3]) | Int(buf[4]) << 8 | Int(buf[5]) << 16
        guard len < 4096 else { buf.removeFirst(2); return nil }
        guard buf.count >= 7 + len else { return nil }
        let f = Array(buf[0..<(7 + len)])
        buf.removeFirst(7 + len)
        return f
    }

    func handle(frame f: [UInt8]) {
        let cmd = f[2], data = Array(f[6..<(f.count - 1)])
        switch cmd {
        case 0x00:                                           // the answer to a write: 0 = OK
            if let code = data.first, code != 0 { Log.write("pad refused a write (code \(code))") }
        case 0x23 where data.count >= 8:                     // a read: region, address, length, bytes
            let region = data[0]
            let addr = Int(data[1]) | Int(data[2]) << 8 | Int(data[3]) << 16 | Int(data[4]) << 24
            let bytes = Array(data[8...])
            if region == 4, addr == 0 {
                if bytes != global {
                    let what = global.isEmpty ? "" : " — changed: " + bytes.indices.filter { $0 < global.count && bytes[$0] != global[$0] }
                        .map { "[\($0)] \(String(format: "%02X", global[$0]))→\(String(format: "%02X", bytes[$0]))" }.joined(separator: ", ")
                    Log.write("pad global: \(Self.hex(bytes))\(what)")
                    if global.count == Global.size, bytes.count == Global.size,
                       bytes[Global.octave] != global[Global.octave] || bytes[Global.preset] != global[Global.preset] {
                        repaintAll()
                    }
                    global = bytes
                    onGlobal?(bytes)
                }
            } else if region == 5, addr == config.count, config.count < Self.configSize {
                config += bytes
                // the pad drops colour writes while it answers reads: send them all again after a dump
                if config.count >= Self.configSize { saveConfig(); repaintAll() } else if ready { readConfig() }
            }
        default:
            oddFrames += 1
            if oddFrames <= 200 { Log.write("pad says cmd \(String(format: "%02X", cmd)): \(Self.hex(data))") }
        }
    }

    static let configSize = 28312

    /// One byte of the global settings. Takes effect at once (the poll reads it back); the pad keeps it until it's
    /// changed back, so callers restore what they change.
    public func writeGlobal(index: Int, value: UInt8) {
        guard ready, let ch = writeChar, let p = pad, (0..<Global.size).contains(index) else { return }
        let d: [UInt8] = [0x04] + Self.le(index, 4) + Self.le(1, 3) + [value]
        let ck = UInt8((~d.map(Int.init).reduce(0, +)) & 0xFF)
        p.writeValue(Data([0x00, 0x59, 0x22] + Self.le(d.count, 3) + d + [ck]), for: ch, type: .withoutResponse)
        Log.write("pad global write: [\(index)] = \(String(format: "%02X", value))")
    }

    /// Read all presets (saved to pad-config.bin when complete). Only on request: while the pad answers reads it
    /// drops colour writes.
    public func dumpConfig() { config = []; readConfig() }

    /// Send every colour again (after an octave or preset change the pad shows another group of records).
    public func repaintAll() {
        for (n, c) in current where pending[n] == nil { pending[n] = c }
        current = [:]
    }

    /// The colour last sent to each pad note, as #rrggbb.
    public var written: [Int: String] { current.mapValues { String(format: "#%02x%02x%02x", $0.0, $0.1, $0.2) } }

    /// The unlock's own reads come too fast for the pad (it answers about one in three), so the rest of the
    /// config is read after it, one chunk per answer.
    func readConfig() {
        guard let ch = writeChar, let p = pad, config.count < Self.configSize else { return }
        let n = min(1009, Self.configSize - config.count)
        let d: [UInt8] = [0x05] + Self.le(config.count, 4) + Self.le(n, 3)
        let ck = UInt8((~d.map(Int.init).reduce(0, +)) & 0xFF)
        p.writeValue(Data([0x00, 0x59, 0x23] + Self.le(d.count, 3) + d + [ck]), for: ch, type: .withoutResponse)
    }

    /// All eight presets as the pad holds them, for reading its button / knob / pad records (see FINDINGS in
    /// spectalive/smc-pad: per preset 5 × 23-byte buttons, 16 × 6-byte knobs, 128 × 26-byte pads).
    func saveConfig() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/paddington")
        let url = dir.appendingPathComponent("pad-config.bin")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if (try? Data(config).write(to: url)) != nil { Log.write("pad config read: \(config.count) bytes → \(url.path)") }
    }

    static func bytes(_ hex: String) -> [UInt8] { hex.split(separator: " ").compactMap { UInt8($0, radix: 16) } }

    func runUnlock() {
        guard let ch = writeChar, let p = pad else { return }
        report("unlocking LEDs…")
        let packets = Self.unlock.map(Self.bytes)
        var i = 0
        let t = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if i < packets.count {
                p.writeValue(Data(packets[i]), for: ch, type: .withoutResponse); i += 1
                return
            }
            t.invalidate()
            self.ready = true
            self.report("LEDs ready")
            let poll = packets.first { $0.count > 6 && $0[2] == 0x23 && $0[6] == 0x04 } ?? packets[1]
            self.timers.append(Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, let ch = self.writeChar else { return }
                self.pad?.writeValue(Data(poll), for: ch, type: .withoutResponse)
            })
            self.startPump()
        }
        timers.append(t)
    }

    static func le(_ v: Int, _ w: Int) -> [UInt8] { (0..<w).map { UInt8((v >> (8 * $0)) & 0xFF) } }

    /// A preset holds 128 pad records of 26 bytes from byte 211, colour at byte 5, in 8 groups of 16. Bank A shows
    /// the group of the pad's octave (global byte 6; the default 2 = notes 36–51, records 32–47); bank B always shows
    /// group 7 (records 112–127, also notes 52–67 — group 3 has the same notes but is bank A an octave up).
    func address(note: Int) -> Int {
        let record = note >= 52 ? 112 + (note - 52) : 32 + (note - 36)
        return profile * 3539 + 211 + record * 26 + 5
    }

    static func colourPacket(_ addr: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
        let d: [UInt8] = [0x05] + le(addr, 4) + [0x03, 0x00, 0x00, r, g, b]
        let ck = UInt8((~d.map(Int.init).reduce(0, +)) & 0xFF)
        return [0x00, 0x59, 0x22] + le(d.count, 3) + d + [ck]
    }

    /// Queue a colour; only changes are written, a few per 50 ms (the colour lives in the pad's flash).
    public func set(note: Int, r: UInt8, g: UInt8, b: UInt8) {
        guard (36...67).contains(note) else { return }
        if let c = current[note], c == (r, g, b) { pending[note] = nil; return }
        pending[note] = (r, g, b)
    }

    func startPump() {
        pump?.invalidate()
        pump = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.ready, let ch = self.writeChar, let p = self.pad else { return }
            for note in self.pending.keys.sorted().prefix(2) {
                guard let c = self.pending.removeValue(forKey: note) else { continue }
                p.writeValue(Data(Self.colourPacket(self.address(note: note), c.0, c.1, c.2)), for: ch, type: .withoutResponse)
                self.current[note] = c
            }
        }
    }
}
