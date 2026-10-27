import EngineCore
import Foundation
import simd

/// A node parameter's value. A menu is a string (its item's name), a group or attribute field, code and a file are
/// strings too; their spec says how the parameter pane edits them.
package enum ProcParam: Equatable, Hashable {
    case float(Float)
    case int(Int)
    case bool(Bool)
    case vec2(SIMD2<Float>)
    case vec3(SIMD3<Float>)
    case vec4(SIMD4<Float>)
    case string(String)
    /// A list of positions (an Add or Curve node's points).
    case points([SIMD3<Float>])
    /// A ramp over 0...1: (position, value) keys, linear between them.
    case ramp([SIMD2<Float>])

    package var float: Float {
        switch self {
        case .float(let f): f
        case .int(let i): Float(i)
        case .bool(let b): b ? 1 : 0
        case .vec2(let v): v.x
        case .vec3(let v): v.x
        case .vec4(let v): v.x
        case .string(let s): Float(s) ?? 0
        default: 0
        }
    }
    package var int: Int {
        switch self {
        case .int(let i): i
        case .float(let f): Int(f.rounded())
        case .bool(let b): b ? 1 : 0
        case .string(let s): Int(s) ?? 0
        default: 0
        }
    }
    package var bool: Bool {
        switch self {
        case .bool(let b): b
        case .int(let i): i != 0
        case .float(let f): f != 0
        default: false
        }
    }
    package var vec2: SIMD2<Float> {
        switch self {
        case .vec2(let v): v
        case .vec3(let v): SIMD2(v.x, v.y)
        case .vec4(let v): SIMD2(v.x, v.y)
        case .float(let f): SIMD2(repeating: f)
        case .int(let i): SIMD2(repeating: Float(i))
        default: .zero
        }
    }
    package var vec3: SIMD3<Float> {
        switch self {
        case .vec3(let v): v
        case .vec4(let v): SIMD3(v.x, v.y, v.z)
        case .vec2(let v): SIMD3(v.x, v.y, 0)
        case .float(let f): SIMD3(repeating: f)
        case .int(let i): SIMD3(repeating: Float(i))
        default: .zero
        }
    }
    package var vec4: SIMD4<Float> {
        switch self {
        case .vec4(let v): v
        case .vec3(let v): SIMD4(v.x, v.y, v.z, 1)
        case .vec2(let v): SIMD4(v.x, v.y, 0, 1)
        case .float(let f): SIMD4(f, f, f, 1)
        case .int(let i): SIMD4(repeating: Float(i))
        default: .zero
        }
    }
    package var string: String {
        switch self {
        case .string(let s): s
        case .int(let i): String(i)
        case .float(let f): String(format: "%g", f)
        case .bool(let b): b ? "1" : "0"
        default: ""
        }
    }
    /// The value with component `k` of it (nil: the number itself) set to `x`, of the same kind.
    package func setting(_ k: Int?, _ x: Float) -> ProcParam {
        switch self {
        case .float: return .float(x)
        case .int: return .int(Int(x.rounded()))
        case .bool: return .bool(x != 0)
        case .vec2(var v): if let k, k < 2 { v[k] = x }; return .vec2(v)
        case .vec3(var v): if let k, k < 3 { v[k] = x }; return .vec3(v)
        case .vec4(var v): if let k, k < 4 { v[k] = x }; return .vec4(v)
        default: return self
        }
    }

    package var points: [SIMD3<Float>] { if case .points(let p) = self { return p }; return [] }
    package var ramp: [SIMD2<Float>] { if case .ramp(let r) = self { return r }; return [SIMD2(0, 0), SIMD2(1, 1)] }

    /// The value the ramp has at `t` (its keys sorted by position).
    package static func sample(_ keys: [SIMD2<Float>], _ t: Float) -> Float {
        guard let first = keys.first else { return t }
        if keys.count == 1 || t <= first.x { return first.y }
        for i in 1..<keys.count where t <= keys[i].x {
            let a = keys[i - 1], b = keys[i]
            let s = b.x > a.x ? (t - a.x) / (b.x - a.x) : 1
            return a.y + (b.y - a.y) * s
        }
        return keys[keys.count - 1].y
    }

    /// Adds the value to a cook key: the kind and the bits, so `.int(1)` and `.float(1)` differ.
    package func hash(into h: inout Hasher64) {
        switch self {
        case .float(let f): h.add(1); h.add(f)
        case .int(let i): h.add(2); h.add(i)
        case .bool(let b): h.add(3); h.add(b)
        case .vec2(let v): h.add(4); h.add(SIMD4(v.x, v.y, 0, 0))
        case .vec3(let v): h.add(5); h.add(SIMD4(v.x, v.y, v.z, 0))
        case .vec4(let v): h.add(6); h.add(v)
        case .string(let s): h.add(7); h.add(s)
        case .points(let p): h.add(8); h.add(p.count); for v in p { h.add(SIMD4(v.x, v.y, v.z, 0)) }
        case .ramp(let r): h.add(9); h.add(r.count); for v in r { h.add(SIMD4(v.x, v.y, 0, 0)) }
        }
    }
}

// The JSON: a value is an object of one key, its kind ({"float": 1.5}, {"string": "group1"}), as MatParam's.
extension ProcParam: Codable {
    private enum Key: String, CodingKey { case float, int, bool, vec2, vec3, vec4, string, points, ramp }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "an empty value"))
        }
        switch key {
        case .float: self = .float(try c.decode(Float.self, forKey: key))
        case .int: self = .int(try c.decode(Int.self, forKey: key))
        case .bool: self = .bool(try c.decode(Bool.self, forKey: key))
        case .vec2: self = .vec2(try c.decode(SIMD2<Float>.self, forKey: key))
        case .vec3: self = .vec3(try c.decode(SIMD3<Float>.self, forKey: key))
        case .vec4: self = .vec4(try c.decode(SIMD4<Float>.self, forKey: key))
        case .string: self = .string(try c.decode(String.self, forKey: key))
        case .points: self = .points(try c.decode([SIMD3<Float>].self, forKey: key))
        case .ramp: self = .ramp(try c.decode([SIMD2<Float>].self, forKey: key))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .float(let v): try c.encode(v, forKey: .float)
        case .int(let v): try c.encode(v, forKey: .int)
        case .bool(let v): try c.encode(v, forKey: .bool)
        case .vec2(let v): try c.encode(v, forKey: .vec2)
        case .vec3(let v): try c.encode(v, forKey: .vec3)
        case .vec4(let v): try c.encode(v, forKey: .vec4)
        case .string(let v): try c.encode(v, forKey: .string)
        case .points(let v): try c.encode(v, forKey: .points)
        case .ramp(let v): try c.encode(v, forKey: .ramp)
        }
    }
}
