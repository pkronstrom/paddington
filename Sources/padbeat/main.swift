// padbeat — a minimal MIDI drum player.
//
// Listens to MIDI note-ons and plays a sample for each mapped note: preloaded buffers, 16 voices (hits layer
// instead of cutting each other off), loudness follows velocity. A "gate" note plays only while it's held: its
// note-off fades it out. It knows nothing about paddington: it reads one
// JSON map, applies it when its contents change, and acknowledges it in <map>.ack once it can play it.
//
//   padbeat [map.json]   (default: ~/Library/Application Support/paddington/drums.json)
//
//   { "generation": 7,                                     // echoed in the .ack file
//     "source": "SMC-PAD",                                 // MIDI sources whose name contains this ("" = all)
//     "velocity_curve": 0.5, "velocity_floor": 0.55, "velocity_full": 48,
//                        // loudness = floor + (1 − floor) · min(1, velocity/full)^curve
//     "notes": [ { "note": 40, "file": "/path/clap.wav", "gain": 1.0, "gate": false }, … ] }
//
// An empty map stops the audio engine. padbeat exits when its parent process does.
// SIGUSR1 logs its state (engine, voices, output peak and device, hits) to stderr.

import AVFoundation
import CoreMIDI
import Foundation

let mapPath = CommandLine.arguments.dropFirst().first
    ?? NSHomeDirectory() + "/Library/Application Support/paddington/drums.json"
let ackPath = mapPath + ".ack"
let parent = getppid()
signal(SIGPIPE, SIG_IGN)   // stderr goes to paddington through a pipe

func log(_ s: String) { FileHandle.standardError.write(Data("padbeat: \(s)\n".utf8)) }

struct Hit { let buffer: AVAudioPCMBuffer; let gain: Float; var gate = false }

struct KitMap {
    var generation = 0
    var source = ""
    var curve: Float = 0.5, floor: Float = 0.55, full: Float = 48
    var notes: [UInt8: Hit] = [:]
}

/// Everything audio — engine, voices, the active map, the sample cache — lives on `queue`.
final class Kit {
    let queue = DispatchQueue(label: "padbeat.audio", qos: .userInteractive)
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    var voices: [AVAudioPlayerNode] = []
    var next = 0
    var voiceNote: [UInt8?] = Array(repeating: nil, count: 16)   // the note each voice last started
    var voiceToken = Array(repeating: 0, count: 16)              // bumped on every hit: a fade leaves a reused voice alone
    var map = KitMap()
    var cache: [String: AVAudioPCMBuffer] = [:]     // key: path + modification time
    var hits = 0, misses = 0, lastNote: UInt8 = 0
    var startFailed = false
    var ackedGeneration = -1

    let peakLock = NSLock()
    var peak: Float = 0                               // loudest sample out of the mixer since the last report

    init() {
        for _ in 0..<16 {
            let v = AVAudioPlayerNode()
            engine.attach(v)
            engine.connect(v, to: engine.mainMixerNode, format: format)
            voices.append(v)
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData else { return }
            var m: Float = 0
            for i in 0..<Int(buf.frameLength) { m = max(m, abs(ch[0][i])) }
            self.peakLock.lock(); self.peak = max(self.peak, m); self.peakLock.unlock()
        }
        engine.prepare()
        // output device changed (headphones, AirPods, a virtual device): the engine stops; supervise() restarts it
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { log("audio configuration changed (device \(self.outputDevice))"); self.supervise() }
        }
    }

    /// On `queue`: the engine runs exactly when there is something to play, and every voice is ready.
    func supervise() {
        if map.notes.isEmpty {
            if engine.isRunning { voices.forEach { $0.stop() }; engine.stop() }
            return
        }
        if !engine.isRunning {
            do { try engine.start(); startFailed = false }
            catch { if !startFailed { log("audio start failed: \(error) — retrying") }; startFailed = true; return }
        }
        for v in voices where !v.isPlaying { v.play() }
        if ackedGeneration != map.generation { ack() }
    }

    /// Tell the map's writer this generation is loaded and audible.
    func ack() {
        let obj: [String: Any] = ["generation": map.generation, "notes": map.notes.keys.map(Int.init).sorted(), "pid": getpid()]
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        do { try d.write(to: URL(fileURLWithPath: ackPath), options: .atomic); ackedGeneration = map.generation }
        catch { log("can't write \(ackPath): \(error.localizedDescription)") }
    }

    /// On `queue`. A note-on from the pad.
    func hit(_ note: UInt8, velocity: UInt8) {
        lastNote = note
        guard let h = map.notes[note] else { misses += 1; return }
        hits += 1
        if !engine.isRunning { supervise() }
        guard engine.isRunning else { return }
        let i = next, v = voices[i]
        next = (next + 1) % voices.count
        voiceToken[i] += 1; voiceNote[i] = note
        v.volume = 1
        let level = h.gain * (map.floor + (1 - map.floor) * powf(min(1, Float(velocity) / map.full), map.curve))
        // the loudness is baked into a copy of the sample: a player's volume only changes on the next render
        // cycle, after a drum's attack has already played at the voice's previous volume
        v.scheduleBuffer(scaled(h.buffer, by: level) ?? h.buffer, at: nil, options: .interrupts)
        if !v.isPlaying { v.play() }
    }

    /// On `queue`. A note-off: a gate note's voices fade out over ~36 ms (stopping dead would click).
    func release(_ note: UInt8) {
        guard map.notes[note]?.gate == true else { return }
        let steps = 6
        for (i, v) in voices.enumerated() where voiceNote[i] == note {
            voiceNote[i] = nil
            let token = voiceToken[i]
            for s in 1...steps {
                queue.asyncAfter(deadline: .now() + 0.006 * Double(s)) { [weak self] in
                    guard let self, self.voiceToken[i] == token else { return }
                    if s < steps { v.volume = Float(steps - s) / Float(steps) } else { v.stop(); v.volume = 1; v.play() }
                }
            }
        }
    }

    /// A copy of `b` multiplied by `g` (a short drum sample: well under a millisecond).
    func scaled(_ b: AVAudioPCMBuffer, by g: Float) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength),
              let src = b.floatChannelData, let dst = out.floatChannelData else { return nil }
        out.frameLength = b.frameLength
        let n = Int(b.frameLength)
        for c in 0..<Int(b.format.channelCount) {
            for i in 0..<n { dst[c][i] = src[c][i] * g }
        }
        return out
    }

    /// On `queue`. Any audio file → a non-empty buffer in the engine's format, or nil.
    func load(_ path: String) -> AVAudioPCMBuffer? {
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)@\(mtime)"
        if let b = cache[key] { return b }
        do {
            let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            guard f.length > 0, let src = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else {
                log("\(path): empty"); return nil
            }
            try f.read(into: src)
            guard src.frameLength > 0, let conv = AVAudioConverter(from: src.format, to: format) else { log("\(path): can't convert"); return nil }
            let ratio = format.sampleRate / src.format.sampleRate
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(src.frameLength) * ratio) + 64) else { return nil }
            var fed = false
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, st in
                if fed { st.pointee = .endOfStream; return nil }
                fed = true; st.pointee = .haveData; return src
            }
            guard status != .error, err == nil, out.frameLength > 0 else {
                log("\(path): conversion failed \(err?.localizedDescription ?? "")"); return nil
            }
            cache[key] = out
            return out
        } catch {
            log("\(path): \(error.localizedDescription)")
            return nil
        }
    }

    /// On `queue`. Apply a map's bytes. Returns false (keeping the current map) if they can't be read.
    func apply(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        var m = KitMap()
        m.generation = obj["generation"] as? Int ?? 0
        m.source = obj["source"] as? String ?? ""
        m.curve = Float(obj["velocity_curve"] as? Double ?? 0.5)
        m.floor = Float(obj["velocity_floor"] as? Double ?? 0.55)
        m.full = Float(max(1, obj["velocity_full"] as? Double ?? 48))
        var failed = false
        for n in obj["notes"] as? [[String: Any]] ?? [] {
            guard let note = n["note"] as? Int, (0...127).contains(note), let file = n["file"] as? String else { continue }
            guard let buf = load(file) else { failed = true; continue }
            m.notes[UInt8(note)] = Hit(buffer: buf, gain: Float(n["gain"] as? Double ?? 1), gate: n["gate"] as? Bool ?? false)
        }
        if failed { return false }          // a sample didn't load: keep the old kit and retry next tick
        map = m
        ackedGeneration = -1
        supervise()
        return true
    }

    /// Name of the device the engine plays to.
    var outputDevice: String {
        guard let unit = engine.outputNode.audioUnit else { return "?" }
        var dev = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, &size) == noErr else { return "?" }
        var name: CFString = "" as CFString; var nsize = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(dev, &addr, 0, nil, &nsize, $0) }
        return "\(name) (#\(dev))"
    }

    func report() -> String {
        peakLock.lock(); let p = peak; peak = 0; peakLock.unlock()
        let playing = voices.filter(\.isPlaying).count
        return "engine=\(engine.isRunning ? "running" : "stopped") voices-playing=\(playing)/\(voices.count) peak=\(String(format: "%.3f", p)) " +
            "notes=\(map.notes.keys.sorted()) generation=\(map.generation) acked=\(ackedGeneration) hits=\(hits) other-notes=\(misses) " +
            "last-note=\(lastNote) device=\(outputDevice)"
    }
}

let kit = Kit()

// ── MIDI (main thread for setup; the callback only queues hits) ─────────
var client = MIDIClientRef(), port = MIDIPortRef()
var connected: Set<MIDIEndpointRef> = []
var sourceMatch = ""

func connectSources() {
    for s in connected { MIDIPortDisconnectSource(port, s) }   // never subscribe twice (every hit would play double)
    connected = []
    for i in 0..<MIDIGetNumberOfSources() {
        let src = MIDIGetSource(i)
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name)
        let n = name?.takeRetainedValue() as String? ?? ""
        guard sourceMatch.isEmpty || n.localizedCaseInsensitiveContains(sourceMatch) else { continue }
        if MIDIPortConnectSource(port, src, nil) == noErr { connected.insert(src) }
    }
}

MIDIClientCreateWithBlock("padbeat" as CFString, &client) { note in
    if note.pointee.messageID == .msgSetupChanged { DispatchQueue.main.async { connectSources() } }
}
let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!
MIDIInputPortCreateWithProtocol(client, "padbeat-in" as CFString, ._1_0, &port) { list, _ in
    for packet in list.unsafeSequence() {
        // read wordCount words through the packet pointer (a packet may hold more than the 64-word tuple)
        let count = Int(packet.pointee.wordCount)
        let words = UnsafeRawPointer(packet).advanced(by: wordsOffset).assumingMemoryBound(to: UInt32.self)
        var i = 0
        while i < count {
            let w = words[i], type = w >> 28
            // MIDI 1.0 channel voice: note-on with velocity > 0; note-off (or note-on with velocity 0)
            if type == 0x2, (w >> 20) & 0xF == 0x9 || (w >> 20) & 0xF == 0x8 {
                let note = UInt8((w >> 8) & 0x7F), vel = UInt8(w & 0x7F)
                if (w >> 20) & 0xF == 0x9 && vel > 0 { kit.queue.async { kit.hit(note, velocity: vel) } }
                else { kit.queue.async { kit.release(note) } }
            }
            i += type >= 0x3 && type <= 0x4 ? 2 : (type == 0x5 ? 4 : 1)
        }
    }
}

// SIGUSR1: report state on stderr (paddington logs it)
signal(SIGUSR1, SIG_IGN)
let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
usr1.setEventHandler { kit.queue.async { log(kit.report() + " sources=\(connected.count)") } }
usr1.resume()

// ── main loop: follow the parent, apply map changes, keep the audio supervised ──
var applied: Data?
var badMapLogged = false
func tick() {
    if getppid() != parent { exit(0) }    // paddington is gone
    let data = FileManager.default.contents(atPath: mapPath) ?? Data("{\"notes\":[]}".utf8)
    if data != applied {
        let ok = kit.queue.sync { kit.apply(data) }
        if ok {
            applied = data; badMapLogged = false
            let src = kit.queue.sync { kit.map.source }
            if src != sourceMatch || connected.isEmpty { sourceMatch = src; connectSources() }
        } else if !badMapLogged {
            badMapLogged = true; log("couldn't apply \(mapPath) — keeping the previous kit, retrying")
        }
    }
    kit.queue.async { kit.supervise() }
}
tick()
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in tick() }
RunLoop.main.run()
