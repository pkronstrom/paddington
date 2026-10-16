import AppKit
import CoreAudioKit
import CoreBluetooth
import CoreMIDI
import Foundation

/// Bluetooth LE MIDI connector, following Apple's documented path:
/// connect with CoreBluetooth, discover the MIDI service and characteristic,
/// then MIDIBluetoothDriverActivateAllConnections() so CoreMIDI exposes the port.
public final class BLEMIDIConnector: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    public static let serviceUUID = CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")
    public static let characteristicUUID = CBUUID(string: "7772E5DB-3868-4112-A1A9-F2669D106BF3")

    public var nameMatch: String
    public var onStatus: ((String) -> Void)?
    public private(set) var status = "idle"

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var wantConnect = false
    private var windowController: NSWindowController?

    public init(nameMatch: String) { self.nameMatch = nameMatch }

    private func report(_ s: String) {
        status = s
        DispatchQueue.main.async { self.onStatus?(s) }
    }

    /// Start (or retry) scanning and connecting. Safe to call repeatedly.
    public func connect() {
        wantConnect = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main); return }
        startScan()
    }

    public func stop() {
        wantConnect = false
        central?.stopScan()
    }

    private func startScan() {
        guard let c = central, c.state == .poweredOn, wantConnect else { return }
        // already connected at the system level (e.g. paired in Audio MIDI Setup)?
        for p in c.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]) where matches(p.name) {
            attach(p); return
        }
        report("scanning for \(nameMatch)…")
        c.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    private func matches(_ name: String?) -> Bool {
        guard let name else { return false }
        return nameMatch.isEmpty || name.localizedCaseInsensitiveContains(nameMatch)
    }

    private func attach(_ p: CBPeripheral) {
        central?.stopScan()
        peripheral = p
        p.delegate = self
        report("connecting to \(p.name ?? "pad")…")
        central?.connect(p, options: nil)
    }

    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: startScan()
        case .unauthorized: report("Bluetooth permission denied — allow Paddington in System Settings › Privacy › Bluetooth")
        case .poweredOff: report("Bluetooth is off")
        default: report("Bluetooth unavailable (\(c.state.rawValue))")
        }
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard matches(p.name) || matches(advName) else { return }
        attach(p)
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        report("discovering MIDI service…")
        p.discoverServices([Self.serviceUUID])
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        report("connect failed: \(error?.localizedDescription ?? "unknown")")
        retryLater()
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        report("disconnected")
        retryLater()
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.serviceUUID }) else { report("no MIDI service on \(p.name ?? "device")"); return }
        p.discoverCharacteristics([Self.characteristicUUID], for: s)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard s.characteristics?.contains(where: { $0.uuid == Self.characteristicUUID }) == true else {
            report("MIDI characteristic missing"); return
        }
        let st = MIDIBluetoothDriverActivateAllConnections()
        report(st == noErr ? "connected" : "activation failed (\(st)) — try the Bluetooth MIDI window")
    }

    private func retryLater() {
        guard wantConnect else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.startScan() }
    }

    /// Apple's pairing window — the fallback when automatic connection fails.
    public func showPairingWindow() {
        let wc = CABTLEMIDIWindowController()
        windowController = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public static func openAudioMIDISetup() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
    }
}
