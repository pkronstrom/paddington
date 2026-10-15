import Foundation

public struct PickerItem: Equatable {
    public var label: String
    public var value: String
    public var action: Action? = nil    // per-item action; otherwise the picker's `run`
    public init(label: String, value: String, action: Action? = nil) { self.label = label; self.value = value; self.action = action }
}

/// A list shown in the legend: a knob scrolls, ▶ runs `run` with {item}, ⏸ cancels.
public struct PickerDef {
    public var id: String
    public var title: String
    public var items: [PickerItem]
    public var source: String?          // "claude-skills" | "prompts" | "dirs"
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
        return PickerDef(id: id, title: t["title"]?.string ?? id.capitalized, items: items, source: t["source"]?.string, path: t["path"]?.string,
                         pin: t["pin"]?.stringList ?? [], run: run, dir: dir)
    }

    /// Items to show now: static items, or a scanned source with pinned entries first.
    public func resolveItems(config: Config) -> [PickerItem] {
        var list = items
        switch source {
        case "claude-skills":
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            var names = Set<String>()
            for d in ["/.claude/skills", "/.claude/commands"] {
                for u in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: home.path + d), includingPropertiesForKeys: nil)) ?? [] {
                    let n = u.lastPathComponent
                    if n.hasPrefix(".") { continue }
                    names.insert(n.hasSuffix(".md") ? String(n.dropLast(3)) : n)
                }
            }
            list += names.sorted().map { PickerItem(label: "/" + $0, value: $0) }
        case "prompts":
            let dirs = [dir.appendingPathComponent("prompts"), config.root.appendingPathComponent("prompts")]
            for d in dirs {
                for u in ((try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path })
                where u.pathExtension == "md" {
                    let name = u.deletingPathExtension().lastPathComponent
                    let label = (try? String(contentsOf: u, encoding: .utf8)).flatMap { Prompt.frontMatter($0)["label"] } ?? name
                    if !list.contains(where: { $0.value == name }) { list.append(PickerItem(label: label, value: name)) }
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
    public var items: [PickerItem]
    public var index: Int
    public var expires: Double
    public var layer: String
}
