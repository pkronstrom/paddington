import AppKit
import Foundation
import SQLite3

/// Catches what the user dictated while a search box is open, without relying on the dictation app pasting
/// into padctl's window (VoiceInk transcribes but doesn't paste there). Two sources, whichever comes first:
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
        if let t = Self.latestTranscript(), t.id > lastRow {
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

    /// VoiceInk's recorder panel is on screen (it shows while recording and transcribing).
    public static func recorderVisible() -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.prakashjoshipax.VoiceInk").first else { return false }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { w in
            (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
                && ((w[kCGWindowLayer as String] as? Int) ?? 0) > 0 && ((w[kCGWindowLayer as String] as? Int) ?? 0) < 25
        }
    }

    /// The newest VoiceInk transcript: (row id, enhanced text if any, else the raw text).
    static func latestTranscript() -> (id: Int64, text: String)? {
        guard FileManager.default.fileExists(atPath: voiceInkStore) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(voiceInkStore, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)
        var st: OpaquePointer?
        let sql = "select Z_PK, ZTEXT, ZENHANCEDTEXT from ZTRANSCRIPTION order by Z_PK desc limit 1"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        func col(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
        let enhanced = col(2).trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = col(1).trimmingCharacters(in: .whitespacesAndNewlines)
        return (sqlite3_column_int64(st, 0), enhanced.isEmpty ? raw : enhanced)
    }
}
