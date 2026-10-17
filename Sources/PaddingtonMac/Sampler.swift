import AVFoundation
import PaddingtonCore

/// The mini-sampler: hold an idle (drum) pad and it records a short sound from the microphone for itself.
/// Samples live in ~/Library/Application Support/paddington/samples as "<bank>.<pad>.<time>.wav" (A.pad3.…);
/// a pad keeps its sample until it records a new one or the sample is erased (hold the pad + ⏸).
public final class PadSampler {
    static var dir: URL { DrumSidecar.dir.appendingPathComponent("samples") }

    /// What came of a recording; `level` is its loudest moment in dBFS (0 = full scale).
    public enum Result { case saved(seconds: Double, level: Double), silent(level: Double), failed(String) }

    private var audio: AVAudioEngine?
    private var frames: [Float] = []
    private var maxFrames = 0
    private var rate = 44100.0
    private let lock = NSLock()
    public private(set) var recording: String?
    public init() {}

    /// The microphone it records from (the Mac's default input).
    public var inputName: String { AVCaptureDevice.default(for: .audio)?.localizedName ?? "no microphone" }

    /// Recorded samples: key ("A.pad3") → file path (the newest file per pad).
    public static func load() -> [String: String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [String: String] = [:]
        for f in files.sorted() where f.hasSuffix(".wav") {
            let parts = f.split(separator: ".")
            guard parts.count >= 4 else { continue }
            out["\(parts[0]).\(parts[1])"] = dir.appendingPathComponent(f).path
        }
        return out
    }

    /// Start recording for a pad. Asks for the microphone the first time (then the pad has to be held again).
    public func start(_ key: String, maxSeconds: Double) -> String? {
        guard recording == nil else { return "already recording" }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in Log.write("microphone access \(ok ? "granted" : "denied")") }
            return "Allow the microphone, then hold the pad again"
        default:
            return "No microphone access: System Settings › Privacy & Security › Microphone › Paddington"
        }
        let e = AVAudioEngine()
        let input = e.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return "no microphone" }
        rate = fmt.sampleRate
        lock.lock(); frames = []; maxFrames = Int(rate * maxSeconds); lock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData else { return }
            let n = Int(buf.frameLength), chans = Int(buf.format.channelCount)
            var mono = [Float](repeating: 0, count: n)
            for c in 0..<chans { for i in 0..<n { mono[i] += ch[c][i] / Float(chans) } }
            self.lock.lock()
            if self.frames.count < self.maxFrames { self.frames += mono.prefix(self.maxFrames - self.frames.count) }
            self.lock.unlock()
        }
        do { try e.start() } catch {
            input.removeTap(onBus: 0)
            return "microphone: \(error.localizedDescription)"
        }
        audio = e; recording = key
        return nil
    }

    /// Stop and keep what was recorded: trimmed to the sound, normalised, faded at both ends. Nothing above a
    /// whisper: the pad keeps the sound it had.
    public func stop() -> Result {
        guard let key = recording, let e = audio else { return .failed("not recording") }
        e.inputNode.removeTap(onBus: 0); e.stop()
        audio = nil; recording = nil
        lock.lock(); let raw = frames; frames = []; lock.unlock()
        let old = (try? FileManager.default.contentsOfDirectory(atPath: Self.dir.path))?.filter { $0.hasPrefix(key + ".") } ?? []
        let peak = raw.reduce(0) { max($0, abs($1)) }
        let level = (20 * log10(max(Double(peak), 1e-6)) * 10).rounded() / 10
        guard let clip = Self.trim(raw, rate: rate) else { return .silent(level: level) }
        do {
            try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            let name = "\(key).\(Int(Date().timeIntervalSince1970 * 1000)).wav"
            try Self.wav(clip, rate: rate).write(to: Self.dir.appendingPathComponent(name))
            for f in old { try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(f)) }
            return .saved(seconds: Double(clip.count) / rate, level: level)
        } catch { return .failed(error.localizedDescription) }
    }

    /// Remove a pad's sample. False if it had none.
    @discardableResult
    public static func erase(_ key: String) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasPrefix(key + ".") } ?? []
        for f in files { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        return !files.isEmpty
    }

    public static func clearAll() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The sound in a recording: from just before it starts to its tail, peak at -1 dBFS. nil = (near) silence.
    static func trim(_ x: [Float], rate: Double) -> [Float]? {
        let peak = x.reduce(0) { max($0, abs($1)) }
        guard peak >= 0.015 else { return nil }          // about -36 dBFS: quieter is the room, not a sound
        let pre = Int(rate * 0.005), tail = Int(rate * 0.06)
        guard let first = x.firstIndex(where: { abs($0) >= peak * 0.1 }),
              let last = x.lastIndex(where: { abs($0) >= peak * 0.03 }) else { return nil }
        var y = Array(x[max(0, first - pre)...min(x.count - 1, last + tail)])
        let gain = 0.89 / peak
        let fadeIn = min(Int(rate * 0.002), y.count / 2), fadeOut = min(Int(rate * 0.015), y.count / 2)
        for i in y.indices {
            var g = gain
            if i < fadeIn { g *= Float(i) / Float(fadeIn) }
            if i >= y.count - fadeOut { g *= Float(y.count - 1 - i) / Float(fadeOut) }
            y[i] *= g
        }
        return y
    }

    /// Samples in -1…1 → 16-bit mono WAV.
    static func wav(_ samples: [Float], rate: Double) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for v in samples {
            var s = Int16(max(-1, min(1, v)) * 32767).littleEndian
            withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
        }
        func le32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(v).littleEndian, Array.init) }
        func le16(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt16(v).littleEndian, Array.init) }
        let r = Int(rate)
        var d = Data("RIFF".utf8); d += le32(36 + pcm.count); d += Data("WAVEfmt ".utf8)
        d += le32(16); d += le16(1); d += le16(1); d += le32(r); d += le32(r * 2); d += le16(2); d += le16(16)
        d += Data("data".utf8); d += le32(pcm.count); d += pcm
        return d
    }
}
