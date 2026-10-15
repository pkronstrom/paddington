import Foundation

/// A choice prompt on an agent's screen: Claude's AskUserQuestion and permission menus, Codex's questions.
/// Read from the bottom of the pane: a numbered list where one line carries the selection cursor (❯ or ›).
/// A plain numbered list in a reply has no cursor, so it never counts.
public struct ScreenChoices: Equatable {
    public struct Option: Equatable {
        public var key: String          // what to type to pick it: "1", "2", … (or a letter)
        public var label: String
        public var freeForm: Bool       // "Type something", "Other", "No, and tell Claude…": answer in words
    }
    public var options: [Option]
    public var selected: Int?           // 0-based index of the option under the cursor
    public var title: String?           // the question line just above the options, if any

    static let cursors: Set<Character> = ["❯", "›", "▶", "➤"]
    static let freeFormWords = ["type something", "something else", "other", "free-form", "freeform", "tell claude",
                                "tell codex", "chat about this", "your own"]

    /// The options as snapshot values: q.active, q.count, q.option.N, q.label.N, q.key.N, q.other.
    public var vars: [String: Value] {
        var v: [String: Value] = ["q.active": .bool(true), "q.count": .number(Double(options.count)), "q.screen": .bool(true)]
        for (i, o) in options.enumerated() {
            let n = i + 1
            v["q.option.\(n)"] = .string(o.label)
            v["q.key.\(n)"] = .string(o.key)
            v["q.label.\(n)"] = .string(o.freeForm ? "🎤 \(o.label)" : "\(o.key) · \(o.label)")
            if o.freeForm { v["q.free.\(n)"] = .bool(true) }     // answered in words: picking it starts dictation
        }
        if let o = options.firstIndex(where: \.freeForm) { v["q.other"] = .number(Double(o + 1)) }
        if let t = title { v["q.text"] = .string(t) }
        if let s = selected { v["q.selected"] = .number(Double(s + 1)) }
        // a confirmation (permission menus): Yes / "Yes, and don't ask again" / No — gets green ✓ and red ✕
        if let c = confirmation {
            v["q.confirm"] = .bool(true)
            v["q.yes"] = .number(Double(c.yes + 1))
            if let a = c.always { v["q.always"] = .number(Double(a + 1)); v["q.always.label"] = .string(options[a].label) }
            if let n = c.no { v["q.no"] = .number(Double(n + 1)) }
        }
        return v
    }

    /// Yes / always / no options of a permission-style prompt (option indexes), or nil for a question.
    public var confirmation: (yes: Int, always: Int?, no: Int?)? {
        let l = options.map { $0.label.lowercased() }
        guard let yes = l.firstIndex(where: { $0 == "yes" || ($0.hasPrefix("yes") && !$0.hasPrefix("yes,") && !$0.contains("don't ask")) })
                ?? l.firstIndex(where: { $0.hasPrefix("yes") }) else { return nil }
        let always = l.indices.first { $0 != yes && l[$0].hasPrefix("yes") }
        let no = l.firstIndex { $0.hasPrefix("no") }
        guard no != nil || always != nil else { return nil }
        return (yes, always, no)
    }

    /// `screen`: the pane's visible text. Looks at the last `window` lines only (prompts sit at the bottom).
    public static func parse(_ screen: String, window: Int = 30) -> ScreenChoices? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).suffix(window)
        var found: [(line: Int, key: String, label: String, cursor: Bool)] = []
        for (i, raw) in lines.enumerated() {
            var s = Substring(raw).drop { $0 == " " || $0 == "│" || $0 == "┃" || $0 == "\t" }
            var cursor = false
            if let c = s.first, cursors.contains(c) { cursor = true; s = s.dropFirst().drop { $0 == " " } }
            // "1. Label" / "1) Label" (also "o. Other")
            guard let dot = s.firstIndex(where: { $0 == "." || $0 == ")" }), s.distance(from: s.startIndex, to: dot) <= 2 else { continue }
            let key = String(s[..<dot])
            guard key.allSatisfy(\.isNumber) || (key.count == 1 && key.first!.isLetter && key.first!.isLowercase) else { continue }
            let after = s[s.index(after: dot)...]
            guard after.first == " " else { continue }
            let label = after.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            found.append((i, key, label, cursor))
        }
        // the last run that starts at 1 and counts up (description lines may sit between options)
        var best: [(line: Int, key: String, label: String, cursor: Bool)] = []
        var run: [(line: Int, key: String, label: String, cursor: Bool)] = []
        for f in found {
            let expect = run.count + 1
            if f.key == "1" { if run.count >= 2 { best = run }; run = [f]; continue }
            if !run.isEmpty, f.key == String(expect) || (f.key.first?.isLetter == true && f.line - run.last!.line <= 3) {
                run.append(f)
            } else if !run.isEmpty, f.key.allSatisfy(\.isNumber) {
                if run.count >= 2 { best = run }; run = []
            }
        }
        if run.count >= 2 { best = run }
        guard best.count >= 2, best.contains(where: \.cursor) else { return nil }
        // options must reach close to the bottom: a prompt, not an old list higher up
        guard let last = best.last, lines.count - last.line <= 12 else { return nil }
        let options = best.map { f in
            Option(key: f.key, label: f.label.replacingOccurrences(of: "  ", with: " "),
                   freeForm: freeFormWords.contains { f.label.lowercased().contains($0) })
        }
        // the question: the nearest non-empty line above the first option that isn't decoration
        var title: String?
        var i = best[0].line - 1
        while i >= 0 {
            let t = lines[lines.startIndex + i].trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, t.contains(where: \.isLetter), !t.hasPrefix("─") { title = t; break }
            i -= 1
        }
        return ScreenChoices(options: options, selected: best.firstIndex(where: \.cursor), title: title)
    }
}
