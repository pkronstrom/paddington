import AppKit
import PadctlCore

/// Short feedback sounds. Names resolve through config [sounds] (categories and named sounds),
/// then as a built-in ("tick", "click"), a macOS system sound (Tink, Pop, …) or a file path (relative = config folder).
/// "name@0.4" scales that sound's volume relative to [sounds] volume.
public final class SoundPlayer {
    private var cache: [String: NSSound] = [:]
    public init() {}

    /// A sound key that names a sample file → (absolute path, gain), for padbeat.
    public static func file(_ key: String, settings: Settings) -> (String, Double)? {
        var name = settings.sounds[key] ?? key
        var gain = 1.0
        if let at = name.lastIndex(of: "@"), let g = Double(name[name.index(after: at)...]) { gain = g; name = String(name[..<at]) }
        guard name.contains("/") else { return nil }
        let path = name.hasPrefix("/") || name.hasPrefix("~") ? (name as NSString).expandingTildeInPath
                                                              : Config.defaultRoot.appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: path) ? (path, gain) : nil
    }

    public func play(_ key: String?, settings: Settings) {
        guard settings.soundsEnabled, let key, !key.isEmpty else { return }
        var name = settings.sounds[key] ?? key
        var gain = 1.0
        if let at = name.lastIndex(of: "@"), let g = Double(name[name.index(after: at)...]) {
            gain = g; name = String(name[..<at])
        }
        guard !name.isEmpty else { return }
        guard let s = sound(name) else { Log.write("sound '\(key)' → '\(name)': can't load"); return }
        if s.isPlaying { s.stop() }
        s.volume = Float(max(0, min(1, settings.soundVolume * gain)))
        s.play()
    }

    func sound(_ name: String) -> NSSound? {
        if let c = cache[name] { return c }
        let s: NSSound?
        switch name {
        case "tick": s = NSSound(data: Self.blip(freq: 3200, ms: 9, decay: 900))
        case "click": s = NSSound(data: Self.blip(freq: 1800, ms: 14, decay: 500))
        default:
            // a path: absolute, ~/…, or relative to the config folder (sounds/tr707/BassDrum1.wav)
            let path = name.hasPrefix("/") || name.hasPrefix("~") ? (name as NSString).expandingTildeInPath
                                                                  : Config.defaultRoot.appendingPathComponent(name).path
            s = name.contains("/") ? NSSound(contentsOfFile: path, byReference: true) : NSSound(named: NSSound.Name(name))
        }
        cache[name] = s
        return s
    }

    /// A tiny sine blip with an exponential decay, as 16-bit mono WAV.
    static func blip(freq: Double, ms: Double, decay: Double) -> Data {
        let rate = 44100.0, n = Int(rate * ms / 1000)
        return wav((0..<n).map { i in let t = Double(i) / rate; return sin(2 * .pi * freq * t) * exp(-t * decay) * 0.6 })
    }

    /// Samples in -1…1 → 16-bit mono WAV at 44.1 kHz.
    static func wav(_ samples: [Double]) -> Data {
        let rate = 44100.0
        var pcm = Data(capacity: samples.count * 2)
        for v in samples {
            var s = Int16(max(-1, min(1, v)) * 32767).littleEndian
            withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
        }
        func le32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(v).littleEndian, Array.init) }
        func le16(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt16(v).littleEndian, Array.init) }
        var d = Data("RIFF".utf8); d += le32(36 + pcm.count); d += Data("WAVEfmt ".utf8)
        d += le32(16); d += le16(1); d += le16(1); d += le32(Int(rate)); d += le32(Int(rate) * 2); d += le16(2); d += le16(16)
        d += Data("data".utf8); d += le32(pcm.count); d += pcm
        return d
    }
}

