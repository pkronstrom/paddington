import Foundation
import TOMLKit

/// JSON-like value used for config and state. TOML is converted to this once at load.
public enum Value: Equatable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Value])
    case table([String: Value])

    public init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { Value(any: $0) })
        case let d as [String: Any]: self = .table(d.mapValues { Value(any: $0) })
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .number(Double(i))
        case let d as Double: self = .number(d)
        default: self = .string("\(any!)")
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var int: Int? { number.map { Int($0) } }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [Value]? { if case .array(let a) = self { return a }; return nil }
    public var table: [String: Value]? { if case .table(let t) = self { return t }; return nil }
    public var isNull: Bool { self == .null }

    public subscript(key: String) -> Value? { table?[key] }

    /// Strings in an array, or a single string as a one-element array.
    public var stringList: [String]? {
        if let s = string { return [s] }
        return array?.compactMap { $0.string }
    }

    public var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .table: return true
        }
    }

    public var description: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .string(let s): return s
        case .array(let a): return a.map(\.description).joined(separator: ", ")
        case .table: return "{…}"
        }
    }

    public var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) as Any : n as Any
        case .string(let s): return s
        case .array(let a): return a.map(\.jsonObject)
        case .table(let t): return t.mapValues(\.jsonObject)
        }
    }
}

public struct ConfigError: Error, CustomStringConvertible {
    public let file: String
    public let message: String
    public init(file: String, _ message: String) { self.file = file; self.message = message }
    public var description: String { "\(file): \(message)" }
}

public enum TOML {
    public static func parse(_ text: String, file: String) throws -> [String: Value] {
        do {
            let table = try TOMLTable(string: text)
            let json = table.convert(to: .json)
            let obj = try JSONSerialization.jsonObject(with: Data(json.utf8))
            guard case .table(let t) = Value(any: obj) else { throw ConfigError(file: file, "top level is not a table") }
            return t
        } catch let e as TOMLParseError {
            throw ConfigError(file: file, "line \(e.source.begin.line): \(e.description)")
        }
    }

    public static func load(_ url: URL) throws -> [String: Value] {
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch {
            throw ConfigError(file: url.path, "cannot read: \(error.localizedDescription)")
        }
        return try parse(text, file: url.path)
    }
}
