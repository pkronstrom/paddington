import Foundation
import PaddingtonCore

/// Runs padbeat (the stand-alone MIDI drum player next to the paddington binary) and keeps its note map current:
/// every pad note whose binding only plays a sample file (the drums and samples on idle pads) → that file.
/// padbeat listens to the pad's MIDI itself, so drum hits never wait for paddington. It acknowledges each map
/// generation in drums.json.ack once loaded and audible; only acknowledged notes are left to it.
public final class DrumSidecar {
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/paddington")
    }
    public static var mapPath: String { dir.appendingPathComponent("drums.json").path }
    static var ackPath: String { mapPath + ".ack" }

    var process: Process?
    var lastContent: Data?          // the map content last written successfully (without the generation)
    var generation = Int(Date().timeIntervalSince1970) % 1_000_000 * 100
    var lastStart = Date.distantPast
    public private(set) var notes: Set<Int> = []
    public init() {}

    static var binary: String? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let p = exe.deletingLastPathComponent().appendingPathComponent("padbeat").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    public var running: Bool { process?.isRunning ?? false }

    /// entries: note → (absolute file path, gain 0–1, gate: plays only while the pad is held)
    public func update(source: String, entries: [Int: (file: String, gain: Double, gate: Bool)], curve: Double = 0.5, floor: Double = 0.55, full: Double = 48) {
        let list = entries.keys.sorted().map { ["note": $0, "file": entries[$0]!.file, "gain": entries[$0]!.gain, "gate": entries[$0]!.gate] as [String: Any] }
        let body: [String: Any] = ["source": source, "notes": list, "velocity_curve": curve, "velocity_floor": floor, "velocity_full": full]
        guard let content = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
        if content != lastContent {
            var withGen = body
            withGen["generation"] = generation + 1
            do {
                let data = try JSONSerialization.data(withJSONObject: withGen, options: [.sortedKeys])
                try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: Self.mapPath), options: .atomic)
                generation += 1
                lastContent = content          // only once written: a failed write is retried on the next render
                notes = Set(entries.keys)
            } catch {
                Log.write("drum map: \(error.localizedDescription)")
            }
        }
        if !entries.isEmpty { ensureRunning() }
    }

    /// Has padbeat loaded the current map and got its audio running? Then it plays `note` itself.
    var ackCache: (stamp: Date, generation: Int, notes: Set<Int>)?
    public func plays(_ note: Int) -> Bool {
        guard running, notes.contains(note) else { return false }
        guard let stamp = (try? FileManager.default.attributesOfItem(atPath: Self.ackPath))?[.modificationDate] as? Date else { return false }
        if ackCache?.stamp != stamp {
            guard let d = FileManager.default.contents(atPath: Self.ackPath),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
            ackCache = (stamp, o["generation"] as? Int ?? -1, Set(o["notes"] as? [Int] ?? []))
        }
        return ackCache?.generation == generation && ackCache?.notes.contains(note) == true
    }

    func ensureRunning() {
        guard !running, Date().timeIntervalSince(lastStart) > 5, let bin = Self.binary else { return }
        lastStart = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = [Self.mapPath]
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            Log.write(String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do { try p.run(); process = p; Log.write("padbeat started (pid \(p.processIdentifier))") }
        catch { Log.write("padbeat: \(error.localizedDescription)") }
    }

    public func stop() { process?.terminate(); process = nil }

    /// Ask padbeat to log its state (audio engine, voices, output peak and device, mapped notes, hits).
    public func report() { if let p = process, p.isRunning { kill(p.processIdentifier, SIGUSR1) } }
}
