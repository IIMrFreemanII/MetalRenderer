import EngineCore
import Foundation
import simd

/// A settings value as a tree, what a plant file's `$0.a.b = literal` lines are applied to: the settings' JSON, with its
/// numbers kept as they are written.
indirect enum PlantTree: Equatable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([PlantTree])
    case object([(String, PlantTree)])

    static func == (a: PlantTree, b: PlantTree) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)): return x.map(\.0) == y.map(\.0) && x.map(\.1) == y.map(\.1)
        default: return false
        }
    }

    init?<T: Encodable>(encoding value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value) else { return nil }
        var reader = Reader(bytes: Array(data))
        guard let tree = reader.value() else { return nil }
        self = tree
    }

    func decode<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    var json: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s):
            let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
            return String(decoding: data, as: UTF8.self)
        case .array(let a): return "[" + a.map(\.json).joined(separator: ",") + "]"
        case .object(let o):
            return "{" + o.map { PlantTree.string($0.0).json + ":" + $0.1.json }.joined(separator: ",") + "}"
        }
    }

    /// The tree at `path` set to `value` (nil: taken out), Swift's way: through a `?.` of what isn't there, nothing
    /// happens. nil: the path isn't one this tree has room for.
    func setting(_ path: ArraySlice<(key: String, optional: Bool)>, to value: PlantTree?) -> PlantTree? {
        guard let step = path.first, case .object(var fields) = self else { return nil }
        let i = fields.firstIndex { $0.0 == step.key }
        if path.count == 1 {
            if let value {
                if let i { fields[i].1 = value } else { fields.append((step.key, value)) }
            } else if let i {
                fields.remove(at: i)
            }
            return .object(fields)
        }
        guard let i else { return step.optional ? self : nil }
        guard let inner = fields[i].1.setting(path.dropFirst(), to: value) else { return nil }
        fields[i].1 = inner
        return .object(fields)
    }

    private struct Reader {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skip() { while i < bytes.count, [32, 10, 13, 9].contains(bytes[i]) { i += 1 } }

        mutating func value() -> PlantTree? {
            skip()
            guard i < bytes.count else { return nil }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var fields: [(String, PlantTree)] = []
                skip()
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(fields) }
                while true {
                    guard case .string(let key)? = value() else { return nil }
                    skip()
                    guard bytes[i] == UInt8(ascii: ":") else { return nil }
                    i += 1
                    guard let v = value() else { return nil }
                    fields.append((key, v))
                    skip()
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(fields) }
                    return nil
                }
            case UInt8(ascii: "["):
                i += 1
                var items: [PlantTree] = []
                skip()
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while true {
                    guard let v = value() else { return nil }
                    items.append(v)
                    skip()
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    return nil
                }
            case UInt8(ascii: "\""):
                let start = i
                i += 1
                while i < bytes.count, bytes[i] != UInt8(ascii: "\"") { i += bytes[i] == UInt8(ascii: "\\") ? 2 : 1 }
                i += 1
                let raw = Data(bytes[start..<i])
                return (try? JSONDecoder().decode(String.self, from: raw)).map(PlantTree.string)
            case UInt8(ascii: "t"): i += 4; return .bool(true)
            case UInt8(ascii: "f"): i += 5; return .bool(false)
            case UInt8(ascii: "n"): i += 4; return .null
            default:
                let start = i
                while i < bytes.count, !([UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 32, 10, 13, 9].contains(bytes[i])) { i += 1 }
                return .number(String(decoding: bytes[start..<i], as: UTF8.self))
            }
        }
    }
}

/// Settings values as Swift: the lines that make one value from another, and its parts' literals.
enum PlantLiteral {
    /// As Swift, a Float literal comes to the same Float: compiled, the literal goes by way of a Double, read back by
    /// PlantSwift by way of its text.
    static func float(_ x: Float) -> String {
        var s = x.description
        if s.hasSuffix(".0") { s.removeLast(2) }
        if Float(s) == x, Double(s).map({ Float($0) }) == x { return s }
        var d = Double(x).description
        if d.hasSuffix(".0") { d.removeLast(2) }
        return d
    }

    private static func quoted(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            default: out.append(c)
            }
        }
        return out + "\""
    }

    /// What's a single value in the lines, its literal; nil: a struct, whose fields have lines of their own.
    static func atom(_ value: Any) -> String? {
        switch value {
        case let x as Float: return float(x)
        case let x as Double:
            var s = x.description
            if s.hasSuffix(".0") { s.removeLast(2) }
            return s
        case let x as Int: return String(x)
        case let x as UInt32: return String(x)
        case let x as UInt64: return String(x)
        case let x as Bool: return x ? "true" : "false"
        case let x as String: return quoted(x)
        case let x as SIMD2<Float>: return "[\(float(x.x)), \(float(x.y))]"
        case let x as SIMD3<Float>: return "[\(float(x.x)), \(float(x.y)), \(float(x.z))]"
        case let x as [SIMD3<Float>]: return "[" + x.map { atom($0)! }.joined(separator: ", ") + "]"
        case let x as [SIMD2<Float>]: return "[" + x.map { atom($0)! }.joined(separator: ", ") + "]"
        case let x as [Int]: return "[" + x.map(String.init).joined(separator: ", ") + "]"
        case let x as ClosedRange<Float>: return "\(float(x.lowerBound))...\(float(x.upperBound))"
        case let x as Foliage.Curve:
            switch x {
            case .linear(let a, let b): return ".linear(\(float(a)), \(float(b)))"
            case .taper(let t): return ".taper(\(float(t)))"
            case .points(let p): return ".points(\(atom(p)!))"
            }
        case let x as Foliage.Phyllotaxis:
            switch x {
            case .spiral: return ".spiral"
            case .distichous: return ".distichous"
            case .whorled(let n): return ".whorled(\(n))"
            }
        case let x as Foliage.LeafShape: return "." + x.rawValue
        case let x as Foliage.Role: return "." + x.rawValue
        case let x as FoliageTextures.Kind: return "." + x.name
        default: return nil
        }
    }

    /// An optional struct's fields start from this, once it is there.
    private static func fresh(_ value: Any) -> Any? {
        switch value {
        case is Growth.Shoot: return Growth.Shoot()
        case is Growth.Senescence: return Growth.Senescence()
        case is Growth.Bifurcation: return Growth.Bifurcation()
        case is Growth.Spurs: return Growth.Spurs()
        case is Growth.Grafts: return Growth.Grafts()
        case is Foliage.Habitat.Cover: return Foliage.Habitat.Cover()
        default: return nil
        }
    }

    /// The defaults of what `$0.field = .init()` makes, by the field's name.
    static func fresh(field: String) -> PlantTree? {
        switch field {
        case "branch", "trunk": return PlantTree(encoding: Growth.Shoot())
        case "senescence": return PlantTree(encoding: Growth.Senescence())
        case "bifurcation": return PlantTree(encoding: Growth.Bifurcation())
        case "spurs": return PlantTree(encoding: Growth.Spurs())
        case "grafts": return PlantTree(encoding: Growth.Grafts())
        case "cover": return PlantTree(encoding: Foliage.Habitat.Cover())
        default: return nil
        }
    }

    private static func optional(_ value: Any) -> (isOptional: Bool, value: Any?) {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return (false, value) }
        return (true, mirror.children.first?.value)
    }

    /// The lines that turn `base` into `value`: ("a.b", "a?.b" as written, its literal), in the fields' order.
    static func lines(_ value: Any, from base: Any, path: String = "", written: String = "") -> [(path: String, written: String, literal: String)] {
        var out: [(path: String, written: String, literal: String)] = []
        let fields = Mirror(reflecting: value).children, bases = Mirror(reflecting: base).children
        for (field, other) in zip(fields, bases) {
            guard let label = field.label else { continue }
            let key = path.isEmpty ? label : path + "." + label
            let line = written.isEmpty ? label : written + "." + label
            let v = optional(field.value), b = optional(other.value)
            guard let now = v.value else {
                if b.value != nil { out.append((key, line, "nil")) }
                continue
            }
            if let literal = atom(now) {
                if b.value.flatMap(atom) != literal { out.append((key, line, literal)) }
                continue
            }
            if v.isOptional {
                if let was = b.value {
                    out += lines(now, from: was, path: key, written: line + "?")
                } else if let start = fresh(now) {
                    out.append((key, line, ".init()"))
                    out += lines(now, from: start, path: key, written: line + "?")
                }
            } else {
                out += lines(now, from: b.value ?? now, path: key, written: line)
            }
        }
        return out
    }
}
