import Foundation

public struct PickerItem: Equatable {
    public var label: String
    public var value: String
    public var action: Action? = nil    // per-item action; otherwise the picker's `run`
    public var detail = ""              // description, searched too
    public init(label: String, value: String, action: Action? = nil, detail: String = "") {
        self.label = label; self.value = value; self.action = action; self.detail = detail
    }
}

/// A list shown in the legend: a knob scrolls, ▶ runs `run` with {item}, ⏸ cancels.
public struct PickerDef {
    public var id: String
    public var title: String
    public var items: [PickerItem]
    public var sources: [String]        // "claude-skills" | "skill-vault" | "mcp-vault" | "prompts" | "dirs" (one or a list)
    public var path: String?            // folder for source = "dirs"
    public var pin: [String]
    public var run: Action
    public var dir: URL                 // ruleset folder (prompts source)

    public static func parse(_ id: String, _ v: Value, dir: URL, file: String) throws -> PickerDef {
        guard let t = v.table else { throw ConfigError(file: file, "[\(id)] must be a table") }
        let run: Action
        do {
            if let rt = t["run"]?.table, let a = try Action.parse(rt, ctx: "\(id).run") { run = a } else { run = .toast("\(id): nothing to run") }
        } catch let e as ExprError { throw ConfigError(file: file, e.description) }
        var items: [PickerItem] = []
        for (n, i) in (t["items"]?.array ?? []).enumerated() {
            if let s = i.string { items.append(PickerItem(label: s, value: s)); continue }
            guard let it = i.table else { continue }
            var act: Action?
            do {
                if let r = it["run"]?.table { act = try Action.parse(r, ctx: "\(id).items[\(n)].run") }
            } catch let e as ExprError { throw ConfigError(file: file, e.description) }
            let v = it["value"]?.string ?? it["label"]?.string ?? "\(n)"
            items.append(PickerItem(label: it["label"]?.string ?? v, value: v, action: act))
        }
        if t["run"] == nil && items.contains(where: { $0.action == nil }) && t["source"] == nil {
            throw ConfigError(file: file, "[\(id)] needs run = { <action> } or a run on every item")
        }
        let sources = t["source"].map { $0.string.map { [$0] } ?? $0.stringList ?? [] } ?? []
        return PickerDef(id: id, title: t["title"]?.string ?? id.capitalized, items: items, sources: sources, path: t["path"]?.string,
                         pin: t["pin"]?.stringList ?? [], run: run, dir: dir)
    }

    /// Items to show now: static items, or a scanned source with pinned entries first.
    public func resolveItems(config: Config) -> [PickerItem] {
        var list = items
        for source in sources {
        switch source {
        case "claude-skills":
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            var found: [String: String] = [:]     // name → description
            for d in ["/.claude/skills", "/.claude/commands"] {
                for u in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: home.path + d), includingPropertiesForKeys: nil)) ?? [] {
                    let n = u.lastPathComponent
                    if n.hasPrefix(".") { continue }
                    let name = n.hasSuffix(".md") ? String(n.dropLast(3)) : n
                    let md = n.hasSuffix(".md") ? u : u.appendingPathComponent("SKILL.md")
                    found[name] = Self.frontMatter(md)["description"] ?? ""
                }
            }
            list += found.keys.sorted().map { PickerItem(label: "/" + $0, value: $0, detail: found[$0] ?? "") }
        case "skill-vault":
            // skills downloaded into the vault but not active: /vault-skills loads one by its path
            var seen = Set(list.map(\.value))
            list += Self.vaultSkills().filter { seen.insert($0.value).inserted }
        case "mcp-vault":
            // stashed MCP servers: /vault-mcp connects one
            guard let vault = Self.vaultPath("mcp-vault", default: "~/.mcp-vault"),
                  let data = FileManager.default.contents(atPath: vault + "/servers.json"),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = obj["mcpServers"] as? [String: Any] else { break }
            for name in servers.keys.sorted() {
                let meta = FileManager.default.contents(atPath: "\(vault)/meta/\(name).json")
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                list.append(PickerItem(label: "⧉ \(name) · MCP", value: name, action: .text("/vault-mcp use \(name) "),
                                       detail: meta?["description"] as? String ?? ""))
            }
        case "prompts":
            let dirs = [dir.appendingPathComponent("prompts"), config.root.appendingPathComponent("prompts")]
            for d in dirs {
                for u in ((try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path })
                where u.pathExtension == "md" {
                    let name = u.deletingPathExtension().lastPathComponent
                    let text = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
                    let label = Prompt.frontMatter(text)["label"] ?? name
                    // the prompt's own words are searchable too ("the one about tests")
                    let detail = String(Prompt.body(text).prefix(400))
                    if !list.contains(where: { $0.value == name }) { list.append(PickerItem(label: label, value: name, detail: detail)) }
                }
            }
        case "dirs":
            let raw = (path ?? "~").replacingOccurrences(of: "{home}", with: NSHomeDirectory())
            let base = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            let subs = ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
                .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
            list += subs.map { PickerItem(label: $0.lastPathComponent, value: $0.path) }
        default: break
        }
        }
        if !pin.isEmpty {
            let pinned = pin.compactMap { p in list.first { $0.value == p } }
            list = pinned + list.filter { i in !pin.contains(i.value) }
        }
        return list
    }
}

public struct PickerState: Equatable {
    public var id: String
    public var title: String
    public var items: [PickerItem]      // what's shown: all items, or the matches for `query`
    public var index: Int
    public var expires: Double
    public var layer: String
    public var all: [PickerItem] = []   // every item (search pickers)
    public var query = ""
    public var searching = false
}

// MARK: vaults and front matter

extension PickerDef {
    private static let vaultLock = NSLock()
    nonisolated(unsafe) private static var vaultCache: (at: Date, items: [PickerItem])?

    /// The skill vault as picker items. Scanning it takes a few hundred ms, so it's cached for 10 minutes;
    /// the app warms it up in the background at start.
    public static func vaultSkills(maxAge: TimeInterval = 600) -> [PickerItem] {
        vaultLock.lock(); defer { vaultLock.unlock() }
        if let c = vaultCache, Date().timeIntervalSince(c.at) < maxAge { return c.items }
        var items: [PickerItem] = []
        if let vault = vaultPath("skill-vault", default: "~/.skill-vault") {
            var seen = Set<String>()
            for (rel, md) in skillFiles(in: vault) {
                let fm = frontMatter(md)
                let name = fm["name"] ?? URL(fileURLWithPath: rel).lastPathComponent
                guard seen.insert(name).inserted else { continue }
                let category = rel.split(separator: "/").first.map(String.init) ?? ""
                items.append(PickerItem(label: "◇ \(name) · \(category)", value: name,
                                        action: .text("/vault-skills \(rel) "), detail: fm["description"] ?? ""))
            }
        }
        vaultCache = (Date(), items)
        return items
    }

    /// A vault's folder: its tool records it in ~/.config/<name>/config.
    static func vaultPath(_ name: String, default def: String) -> String? {
        let cfg = NSHomeDirectory() + "/.config/\(name)/config"
        let recorded = (try? String(contentsOfFile: cfg, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = ((recorded?.isEmpty == false ? recorded! : def) as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// SKILL.md files under a vault, as (path relative to the vault without /SKILL.md, file URL).
    static func skillFiles(in vault: String) -> [(String, URL)] {
        let base = URL(fileURLWithPath: vault)
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [(String, URL)] = []
        for case let u as URL in e {
            if e.level > 6 { e.skipDescendants(); continue }
            guard u.lastPathComponent == "SKILL.md" else { continue }
            let rel = u.deletingLastPathComponent().path.replacingOccurrences(of: base.path + "/", with: "")
            out.append((rel, u))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// `key: value` lines between the leading `---` fences of a Markdown file.
    static func frontMatter(_ url: URL) -> [String: String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? h.close() }
        let head = String(decoding: h.readData(ofLength: 4096), as: UTF8.self)
        var out: [String: String] = [:]
        let lines = head.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        for l in lines.dropFirst() {
            if l.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let c = l.firstIndex(of: ":") else { continue }
            let k = l[..<c].trimmingCharacters(in: .whitespaces)
            var v = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) { v = String(v.dropFirst().dropLast()) }
            out[k] = v
        }
        return out
    }
}

// MARK: search

/// Ranks items for a typed or dictated query. Built for speech: case, punctuation and hyphens don't matter,
/// "vault skills" finds vault-skills, extra words ("the brainstorm skill") and near-misses still match.
public enum PickerSearch {
    static let filler: Set<String> = ["slash", "skill", "skills", "the", "a", "an", "use", "run", "please", "mcp", "server"]

    static let numbers = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
                          "seven": "7", "eight": "8", "nine": "9", "ten": "10"]

    /// Lowercased words; spoken numbers become digits ("context seven" → context 7).
    static func words(_ s: String) -> [String] {
        // dictation may come back in another script ("Хэндофф"): transliterate, then drop accents
        let latin = (s.applyingTransform(.toLatin, reverse: false) ?? s).applyingTransform(.stripDiacritics, reverse: false) ?? s
        let lowered = latin.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(lowered).split(separator: " ").map { numbers[String($0)] ?? String($0) }
    }

    /// 0 = no match; higher is better (exact name 1000).
    public static func score(_ item: PickerItem, _ query: String) -> Int {
        // with and without filler words ("the …skill", but also names like vault-skills): the better one counts
        let all = words(query)
        let trimmed = all.filter { !filler.contains($0) }
        // a match that needed words dropped counts a little less than one using everything that was said
        return max(score(item, words: all), trimmed.isEmpty || trimmed == all ? 0 : score(item, words: trimmed) * 9 / 10)
    }

    static func score(_ item: PickerItem, words q: [String]) -> Int {
        guard !q.isEmpty else { return 0 }
        // the label is a name too ("Where are we" for status.md) — without symbols or a "· category" suffix
        let label = item.label.components(separatedBy: " · ").first ?? item.label
        let named = label.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = item.value.hasPrefix("/") ? item.value : item.value.components(separatedBy: "/").last ?? item.value
        return max(score(item, words: q, name: value), named.isEmpty || named == value ? 0 : score(item, words: q, name: named))
    }

    static func score(_ item: PickerItem, words q: [String], name: String) -> Int {
        let n = words(name)
        let qs = q.joined(), ns = n.joined()
        if ns == qs { return 1000 }
        if ns.hasPrefix(qs) { return 900 - min(100, ns.count - qs.count) }
        if q.allSatisfy({ w in n.contains { $0.hasPrefix(w) } }) { return 800 }
        if qs.contains(ns), ns.count >= 3 { return 700 }                       // "the brainstorming skill please"
        // fuzzy: misheard, misspelt or transliterated — by letters and by consonant skeleton (sound-alike),
        // against the whole name and against its beginning ("transcribe" → transcribe-media)
        let head = String(ns.prefix(max(qs.count, 1)))
        let ks = skeleton(qs), kn = skeleton(ns), kh = String(kn.prefix(max(ks.count, 1)))
        let best = max(similarity(qs, ns), similarity(qs, head) * 0.95,
                       ks.count >= 2 ? similarity(ks, kn) : 0, ks.count >= 3 ? similarity(ks, kh) * 0.95 : 0)
        if best >= 0.55 { return Int(650 * best) }
        let d = Set(words(item.detail + " " + item.label))
        if q.allSatisfy({ w in d.contains { $0.hasPrefix(w) } }) { return 300 }
        return 0
    }

    /// Matches, best first (stable for equal scores).
    public static func rank(_ items: [PickerItem], _ query: String) -> [(PickerItem, Int)] {
        items.enumerated().compactMap { (i, it) -> (Int, PickerItem, Int)? in
            let s = score(it, query); return s > 0 ? (i, it, s) : nil
        }.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }.map { ($0.1, $0.2) }
    }

    /// The match to take without asking: clearly the best one.
    public static func confident(_ ranked: [(PickerItem, Int)]) -> PickerItem? {
        guard let top = ranked.first, top.1 >= 500 else { return nil }
        if top.1 >= 900 || ranked.count == 1 || top.1 - ranked[1].1 >= 100 { return top.0 }
        return nil
    }

    /// Consonants only, with sound-alike letters merged: "handoff" and "hend of" are both "hndf".
    static func skeleton(_ s: String) -> String {
        var t = s
        for (from, to) in [("ph", "f"), ("ck", "k"), ("c", "k"), ("q", "k"), ("x", "ks"), ("w", "v"), ("z", "s"), ("j", "i")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        var out = ""
        for ch in t where !"aeiouy".contains(ch) { if out.last != ch { out.append(ch) } }
        return out
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = Array(0...b.count), cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return 1 - Double(prev[b.count]) / Double(max(a.count, b.count))
    }
}
