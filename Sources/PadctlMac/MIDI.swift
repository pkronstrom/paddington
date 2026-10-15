import CoreMIDI
import Foundation
import PadctlCore

public struct MIDIEndpointInfo: Equatable {
    public var ref: MIDIEndpointRef
    public var name: String
    public var online: Bool
}

/// CoreMIDI input for every source, plus setup-change notifications.
/// Callbacks arrive on the main queue.
public final class MIDIService {
    public var onMessage: ((MIDIMessage, String) -> Void)?
    public var onSetupChanged: (() -> Void)?

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var connected: Set<MIDIEndpointRef> = []

    public init() {}

    public func start() throws {
        var st = MIDIClientCreateWithBlock("padctl" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.refresh(); self?.onSetupChanged?() }
            }
        }
        guard st == noErr else { throw NSError(domain: "MIDI", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "MIDIClientCreate failed (\(st))"]) }
        st = MIDIInputPortCreateWithProtocol(client, "padctl-in" as CFString, ._1_0, &inPort) { [weak self] list, srcRef in
            let name = srcRef.map { Unmanaged<NSString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
            var msgs: [MIDIMessage] = []
            for packet in list.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                withUnsafeBytes(of: packet.pointee.words) { raw in
                    let words = raw.bindMemory(to: UInt32.self)
                    var i = 0
                    while i < min(count, words.count) {
                        let w = words[i]
                        let type = w >> 28
                        if type == 0x2 {   // MIDI 1.0 channel voice
                            let b0 = UInt8((w >> 16) & 0xFF), b1 = UInt8((w >> 8) & 0xFF), b2 = UInt8(w & 0xFF)
                            if let m = MIDIMessage(bytes: [b0, b1, b2]) { msgs.append(m) }
                        }
                        i += type >= 0x3 && type <= 0x4 ? 2 : (type == 0x5 ? 4 : 1)
                    }
                }
            }
            guard !msgs.isEmpty else { return }
            DispatchQueue.main.async { msgs.forEach { self?.onMessage?($0, name) } }
        }
        guard st == noErr else { throw NSError(domain: "MIDI", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "MIDIInputPortCreate failed (\(st))"]) }
        MIDIOutputPortCreate(client, "padctl-out" as CFString, &outPort)
        refresh()
    }

    /// Connect to every source not yet connected. Source name is passed as the refCon.
    public func refresh() {
        let current = Set(Self.sources().map(\.ref))
        for s in Self.sources() where !connected.contains(s.ref) {
            let refCon = Unmanaged.passRetained(s.name as NSString).toOpaque()
            if MIDIPortConnectSource(inPort, s.ref, refCon) == noErr { connected.insert(s.ref) }
        }
        connected = connected.intersection(current)
    }

    public static func sources() -> [MIDIEndpointInfo] {
        (0..<MIDIGetNumberOfSources()).map { endpointInfo(MIDIGetSource($0)) }
    }

    public static func destinations() -> [MIDIEndpointInfo] {
        (0..<MIDIGetNumberOfDestinations()).map { endpointInfo(MIDIGetDestination($0)) }
    }

    static func endpointInfo(_ e: MIDIEndpointRef) -> MIDIEndpointInfo {
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &name)
        var offline: Int32 = 0
        MIDIObjectGetIntegerProperty(e, kMIDIPropertyOffline, &offline)
        return MIDIEndpointInfo(ref: e, name: (name?.takeRetainedValue() as String?) ?? "?", online: offline == 0)
    }

    /// Send raw MIDI 1.0 bytes to destinations whose name contains `match`.
    public func send(_ bytes: [UInt8], to match: String) {
        guard bytes.count == 3 else { return }
        for d in Self.destinations() where d.name.localizedCaseInsensitiveContains(match) {
            var list = MIDIEventList()
            let pkt = MIDIEventListInit(&list, ._1_0)
            var word: UInt32 = 0x2000_0000 | UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
            MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, pkt, 0, 1, &word)
            MIDISendEventList(outPort, d.ref, &list)
        }
    }
}
