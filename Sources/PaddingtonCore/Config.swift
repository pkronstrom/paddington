import Foundation

/// Everything loaded from ~/.config/paddington. Immutable; a reload builds a new one.
public struct Config {
    public var root: URL
    public var settings: Settings
    public var device: DeviceProfile
    public var layers: [String: Layer]
    public var pickers: [String: PickerDef] = [:]
    public var warnings: [String]

    public static var defaultRoot: URL {
        if let p = ProcessInfo.processInfo.environment["PADDINGTON_CONFIG"] { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/paddington")
    }

    public static func load(root: URL = defaultRoot) throws -> Config {
        let fm = FileManager.default
        let cfgURL = root.appendingPathComponent("config.toml")
        let settings = fm.fileExists(atPath: cfgURL.path) ? Settings.parse(try TOML.load(cfgURL)) : Settings()
        let devURL = root.appendingPathComponent("devices/\(settings.device).toml")
        guard fm.fileExists(atPath: devURL.path) else {
            throw ConfigError(file: devURL.path, "device profile not found (config.toml: device = \"\(settings.device)\")")
        }
        let device = try DeviceProfile.load(devURL)

        var layers: [String: Layer] = [:]
        let layersDir = root.appendingPathComponent("layers")
        let files = (fm.enumerator(at: layersDir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "toml" && $0.lastPathComponent != "pickers.toml" }
            .sorted { $0.path < $1.path }
        for f in files {
            let id = f.deletingPathExtension().lastPathComponent
            let rel = f.path.replacingOccurrences(of: root.path + "/", with: "")
            if let other = layers[id] { throw ConfigError(file: rel, "layer id '\(id)' also defined in \(other.file)") }
            layers[id] = try Layer.parse(try TOML.load(f), id: id, dir: f.deletingLastPathComponent(), file: rel)
        }
        var c = Config(root: root, settings: settings, device: device, layers: layers, warnings: [])
        let pickerFiles = [root.appendingPathComponent("pickers.toml")]
            + ((fm.enumerator(at: layersDir, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [])
                .filter { $0.lastPathComponent == "pickers.toml" }.sorted { $0.path < $1.path }
        for f in pickerFiles where fm.fileExists(atPath: f.path) {
            let rel = f.path.replacingOccurrences(of: root.path + "/", with: "")
            for (id, v) in try TOML.load(f) {
                if c.pickers[id] != nil { throw ConfigError(file: rel, "picker '\(id)' defined twice") }
                c.pickers[id] = try PickerDef.parse(id, v, dir: f.deletingLastPathComponent(), file: rel)
            }
        }
        try c.validate()
        return c
    }

    mutating func validate() throws {
        guard layers["default"] != nil else { throw ConfigError(file: "layers/", "a layer named 'default' is required (layers/default.toml)") }
        let known = Set(device.allControlNames)
        for l in layers.values {
            var seen: Set<String> = [l.id]
            var cur = l.extends
            while let p = cur {
                guard let pl = layers[p] else { throw ConfigError(file: l.file, "extends unknown layer '\(p)'") }
                guard seen.insert(p).inserted else { throw ConfigError(file: l.file, "extends cycle through '\(p)'") }
                cur = pl.extends
            }
            for name in Set(l.bindings.keys).union(l.shift.keys) where !known.contains(name) {
                warnings.append("\(l.file): '\(name)' is not a control of \(device.name)")
            }
            for b in Array(l.bindings.values) + Array(l.shift.values) {
                if let t = b.then, layers[t] == nil { throw ConfigError(file: l.file, "then = '\(t)': unknown layer") }
                if let look = b.look, l.looks[look] == nil, !Looks.builtins.contains(look),
                   !layers.values.contains(where: { $0.looks[look] != nil }) {
                    warnings.append("\(l.file): unknown look '\(look)'")
                }
                for a in [b.action, b.hold, b.cw, b.ccw].compactMap({ $0 }) {
                    if case .layer(let id, _, _) = a, layers[id] == nil {
                        throw ConfigError(file: l.file, "binding switches to unknown layer '\(id)'")
                    }
                    if case .picker(let id) = a, pickers[id] == nil {
                        throw ConfigError(file: l.file, "unknown picker '\(id)' (define it in a pickers.toml)")
                    }
                }
            }
        }
    }

    /// Prompt file lookup: the layer's folder first, then the config root.
    public func promptText(_ name: String, layer: Layer?) -> String? {
        var dirs: [URL] = []
        if let l = layer { dirs.append(l.dir.appendingPathComponent("prompts")) }
        dirs.append(root.appendingPathComponent("prompts"))
        for d in dirs {
            let f = d.appendingPathComponent(name.hasSuffix(".md") ? name : name + ".md")
            if let s = try? String(contentsOf: f, encoding: .utf8) { return Prompt.body(s) }
        }
        return nil
    }

    public func promptLabel(_ name: String, layer: Layer?) -> String? {
        var dirs: [URL] = []
        if let l = layer { dirs.append(l.dir.appendingPathComponent("prompts")) }
        dirs.append(root.appendingPathComponent("prompts"))
        for d in dirs {
            let f = d.appendingPathComponent(name.hasSuffix(".md") ? name : name + ".md")
            if let s = try? String(contentsOf: f, encoding: .utf8) { return Prompt.frontMatter(s)["label"] }
        }
        return nil
    }

    public func scriptURL(_ name: String, layer: Layer?) -> URL? {
        var dirs: [URL] = []
        if let l = layer { dirs.append(l.dir.appendingPathComponent("scripts")) }
        dirs.append(root.appendingPathComponent("scripts"))
        for d in dirs {
            let f = d.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: f.path) { return f }
        }
        return nil
    }
}

public enum Prompt {
    public static func frontMatter(_ s: String) -> [String: String] {
        guard s.hasPrefix("---\n"), let end = s.range(of: "\n---", range: s.index(s.startIndex, offsetBy: 4)..<s.endIndex) else { return [:] }
        var out: [String: String] = [:]
        for line in s[s.index(s.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
            guard let c = line.firstIndex(of: ":") else { continue }
            out[line[..<c].trimmingCharacters(in: .whitespaces)] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }
    public static func body(_ s: String) -> String {
        guard s.hasPrefix("---\n"), let end = s.range(of: "\n---", range: s.index(s.startIndex, offsetBy: 4)..<s.endIndex) else {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var rest = s[end.upperBound...]
        if rest.hasPrefix("\n") { rest = rest.dropFirst() }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
