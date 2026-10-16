import Foundation

/// Expression language for `if` conditions: comparisons, and/or/not, numbers,
/// strings, dotted state keys. No calls, no side effects. A missing key is null.
public indirect enum Expr: Equatable {
    case literal(Value)
    case key(String)
    case not(Expr)
    case and(Expr, Expr)
    case or(Expr, Expr)
    case cmp(String, Expr, Expr)

    public static func parse(_ text: String) throws -> Expr {
        var p = ExprParser(tokens: try tokenize(text), source: text)
        let e = try p.parseOr()
        guard p.atEnd else { throw ExprError("unexpected '\(p.peek ?? "")' in \(text)") }
        return e
    }

    public func eval(_ lookup: (String) -> Value) -> Value {
        switch self {
        case .literal(let v): return v
        case .key(let k): return lookup(k)
        case .not(let e): return .bool(!e.eval(lookup).truthy)
        case .and(let a, let b): return .bool(a.eval(lookup).truthy && b.eval(lookup).truthy)
        case .or(let a, let b): return .bool(a.eval(lookup).truthy || b.eval(lookup).truthy)
        case .cmp(let op, let a, let b):
            let l = a.eval(lookup), r = b.eval(lookup)
            switch op {
            case "==": return .bool(Expr.equal(l, r))
            case "!=": return .bool(!Expr.equal(l, r))
            default:
                guard let x = l.number, let y = r.number else { return .bool(false) }
                switch op {
                case ">": return .bool(x > y)
                case "<": return .bool(x < y)
                case ">=": return .bool(x >= y)
                case "<=": return .bool(x <= y)
                default: return .bool(false)
                }
            }
        }
    }

    static func equal(_ a: Value, _ b: Value) -> Bool {
        if let x = a.number, let y = b.number { return x == y }
        if case .string(let s) = a, case .number = b { return Double(s) == b.number }
        return a == b
    }
}

public struct ExprError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

private func tokenize(_ s: String) throws -> [String] {
    var out: [String] = []
    let chars = Array(s)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c.isWhitespace { i += 1; continue }
        if c == "'" || c == "\"" {
            var j = i + 1
            while j < chars.count && chars[j] != c { j += 1 }
            guard j < chars.count else { throw ExprError("unterminated string in \(s)") }
            out.append(String(chars[i...j])); i = j + 1; continue
        }
        if "()".contains(c) { out.append(String(c)); i += 1; continue }
        if "=!<>".contains(c) {
            if i + 1 < chars.count && chars[i + 1] == "=" { out.append(String(chars[i...i+1])); i += 2 }
            else if c == "<" || c == ">" { out.append(String(c)); i += 1 }
            else { throw ExprError("unexpected '\(c)' in \(s)") }
            continue
        }
        var j = i
        while j < chars.count && (chars[j].isLetter || chars[j].isNumber || "._-@".contains(chars[j])) { j += 1 }
        guard j > i else { throw ExprError("unexpected '\(c)' in \(s)") }
        out.append(String(chars[i..<j])); i = j
    }
    return out
}

private struct ExprParser {
    var tokens: [String]
    let source: String
    var pos = 0
    var atEnd: Bool { pos >= tokens.count }
    var peek: String? { atEnd ? nil : tokens[pos] }
    mutating func next() -> String? { defer { pos += 1 }; return peek }

    mutating func parseOr() throws -> Expr {
        var e = try parseAnd()
        while peek == "or" { _ = next(); e = .or(e, try parseAnd()) }
        return e
    }
    mutating func parseAnd() throws -> Expr {
        var e = try parseNot()
        while peek == "and" { _ = next(); e = .and(e, try parseNot()) }
        return e
    }
    mutating func parseNot() throws -> Expr {
        if peek == "not" { _ = next(); return .not(try parseNot()) }
        return try parseCmp()
    }
    mutating func parseCmp() throws -> Expr {
        let a = try parseAtom()
        if let op = peek, ["==", "!=", ">", "<", ">=", "<="].contains(op) {
            _ = next(); return .cmp(op, a, try parseAtom())
        }
        return a
    }
    mutating func parseAtom() throws -> Expr {
        guard let t = next() else { throw ExprError("unexpected end of \(source)") }
        if t == "(" {
            let e = try parseOr()
            guard next() == ")" else { throw ExprError("missing ')' in \(source)") }
            return e
        }
        if t.hasPrefix("'") || t.hasPrefix("\"") { return .literal(.string(String(t.dropFirst().dropLast()))) }
        if let n = Double(t) { return .literal(.number(n)) }
        switch t {
        case "true": return .literal(.bool(true))
        case "false": return .literal(.bool(false))
        case "null": return .literal(.null)
        default: return .key(t)
        }
    }
}

/// Replace `{key}` in a label with state values. Unknown keys become empty.
public func interpolate(_ template: String, _ lookup: (String) -> Value) -> String {
    guard template.contains("{") else { return template }
    var out = ""
    var i = template.startIndex
    while i < template.endIndex {
        if template[i] == "{", let close = template[i...].firstIndex(of: "}") {
            let key = String(template[template.index(after: i)..<close])
            out += lookup(key).description
            i = template.index(after: close)
        } else {
            out.append(template[i]); i = template.index(after: i)
        }
    }
    return out
}
