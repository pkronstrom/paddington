import CoreBluetooth
import Foundation

/// SMC-PAD pad lights over Bluetooth LE (GATT service AE40), separate from MIDI.
/// Protocol and the unlock session come from github.com/spectalive/smc-pad (Apache-2.0):
/// packets are [00 59 <cmd> <len24-le> <data> <~sum(data)>]; colour = cmd 22, data 05 <addr32> 03 00 00 R G B,
/// addr = 0x418 + (note - 36) * 26 for the first preset. Writes are ignored until the official app's
/// connect session is replayed; a read poll every 0.5 s keeps it open.
public final class PadLEDs: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "AE40")
    static let writeUUID = CBUUID(string: "AE41")
    static let notifyUUID = CBUUID(string: "AE42")
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
    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([Self.service]) }
    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        ready = false; writeChar = nil; current = [:]
        timers.forEach { $0.invalidate() }; timers = []
        report("LEDs disconnected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.connect() }
    }
    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.service }) else { report("no LED service"); return }
        p.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: s)
    }
    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == Self.notifyUUID { p.setNotifyValue(true, for: ch) }
            if ch.uuid == Self.writeUUID { writeChar = ch }
        }
        if writeChar != nil { runUnlock() }
    }
    public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {}

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

    func address(note: Int) -> Int { 0x418 + profile * 3539 + (note - 36) * 26 }

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
