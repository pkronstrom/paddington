import AppKit
import CoreAudio
import Foundation
import SQLite3

/// Catches what the user dictated while a search box is open, without relying on the dictation app pasting
/// into paddington's window (VoiceInk transcribes but doesn't paste there). Two sources, whichever comes first:
/// a new row in VoiceInk's transcript history (read-only), or new text on the clipboard (other tools).
public final class DictationWatcher {
    static let voiceInkStore = NSHomeDirectory() + "/Library/Application Support/com.prakashjoshipax.VoiceInk/default.store"

    private var timer: Timer?
    private var lastRow: Int64 = 0
    private var lastClip = 0
    private var onText: ((String) -> Void)?

    public init() {}

    public func start(_ onText: @escaping (String) -> Void) {
        stop()
        self.onText = onText
        lastRow = Self.latestTranscript()?.id ?? 0
        lastClip = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.poll() }
    }

    public func stop() { timer?.invalidate(); timer = nil; onText = nil }

    private func poll() {
        if let t = Self.latestTranscript(), t.id > lastRow, t.done {
            lastRow = t.id
            if !t.text.isEmpty { Log.write("dictation: VoiceInk “\(t.text)”"); deliver(t.text); return }
        }
        let pb = NSPasteboard.general
        if pb.changeCount != lastClip {
            lastClip = pb.changeCount
            if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.count < 120 {
                Log.write("dictation: clipboard “\(s)”"); deliver(s)
            }
        }
    }

    private func deliver(_ s: String) { onText?(s) }

    /// Is VoiceInk recording right now — capturing from a microphone? Asked of Core Audio, so it's VoiceInk's real
    /// state, whatever its tap / hold rules made of the last ● press. nil: can't tell (VoiceInk isn't running).
    public static func voiceInkRecording() -> Bool? {
        guard #available(macOS 14.2, *),
              var pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.prakashjoshipax.VoiceInk").first?.processIdentifier
        else { return nil }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process) == noErr else { return nil }
        guard process != kAudioObjectUnknown else { return false }          // no audio at all yet
        addr.mSelector = kAudioProcessPropertyIsRunningInput
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &running) == noErr else { return nil }
        return running != 0
    }

    /// VoiceInk's recorder panel is on screen (it shows while recording and transcribing).
    public static func recorderVisible() -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.prakashjoshipax.VoiceInk").first else { return false }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { w in
            (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
                && ((w[kCGWindowLayer as String] as? Int) ?? 0) > 0 && ((w[kCGWindowLayer as String] as? Int) ?? 0) < 25
        }
    }

    /// The newest VoiceInk transcript: (row id, enhanced text if any, else the raw text, finished?). Finished =
    /// status completed / canceled (or no status: older VoiceInk). Recordings with nothing said are saved empty.
    static func latestTranscript() -> (id: Int64, text: String, done: Bool)? {
        guard FileManager.default.fileExists(atPath: voiceInkStore) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(voiceInkStore, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)
        var st: OpaquePointer?
        let sql = "select Z_PK, ZTEXT, ZENHANCEDTEXT, ZTRANSCRIPTIONSTATUS from ZTRANSCRIPTION order by Z_PK desc limit 1"
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) != SQLITE_OK {     // an older VoiceInk without a status column
            sqlite3_finalize(st); st = nil
            guard sqlite3_prepare_v2(db, "select Z_PK, ZTEXT, ZENHANCEDTEXT, '' from ZTRANSCRIPTION order by Z_PK desc limit 1",
                                     -1, &st, nil) == SQLITE_OK else { return nil }
        }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        func col(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
        let enhanced = col(2).trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = col(1).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = col(3).lowercased()
        let done = status.isEmpty || status == "completed" || status == "canceled" || status == "failed"
        return (sqlite3_column_int64(st, 0), enhanced.isEmpty ? raw : enhanced, done)
    }
}
