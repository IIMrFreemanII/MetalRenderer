import Foundation
import simd

/// A pixel processor's function (Substance's): math nodes wired into a Result, evaluated for every pixel of the
/// node's image. It reads the pixel's position (0...1), the image's size, the node's seed, and its inputs sampled
/// anywhere (Sample). Made into Metal (MatFunctionCode.metal: the kernel's body, compiled at run time by MatCompiler)
/// and into closures the CPU runs (the tests check the two agree), from one walk.
struct MatFunction: Codable, Equatable, Hashable {
    var nodes: [MatFnNode] = []
    var links: [MatLink] = []

    init(nodes: [MatFnNode] = [], links: [MatLink] = []) {
        self.nodes = nodes
        self.links = links
        normalizeIDs()
    }

    /// Input 0 at the pixel: what a new pixel processor starts as.
    static var passThrough: MatFunction {
        MatFunction(nodes: [MatFnNode(.position, id: "position", at: [-420, 0]),
                            MatFnNode(.sample, id: "sample", at: [-220, 0]),
                            MatFnNode(.result, id: "result", at: [0, 0])],
                    links: [MatLink("position", to: "sample", "uv"), MatLink("sample", to: "result", "value")])
    }

    func node(_ id: String) -> MatFnNode? { nodes.first { $0.id == id } }
    func link(into id: String, _ input: String) -> MatLink? { links.first { $0.to == id && $0.input == input } }
    var result: MatFnNode? { nodes.first { $0.kind == .result } }

    mutating func normalizeIDs() {
        var used = Set<String>()
        for k in nodes.indices {
            if nodes[k].id.isEmpty || used.contains(nodes[k].id) { nodes[k].id = VFXEffect.unique(nodes[k].kind.rawValue, used) }
            used.insert(nodes[k].id)
        }
    }

    func upstream(of id: String) -> Set<String> {
        var found = Set<String>(), stack = [id]
        while let n = stack.popLast() {
            for l in links where l.to == n && !found.contains(l.from) {
                found.insert(l.from)
                stack.append(l.from)
            }
        }
        return found
    }
}

/// A function's node: its kind, the values of its unwired inputs, where the editor draws it.
struct MatFnNode: Codable, Equatable, Hashable, Identifiable {
    var id = ""
    var kind: MatFnKind
    var params: [String: MatParam] = [:]
    var at = SIMD2<Float>.zero

    init(_ kind: MatFnKind, _ params: [String: MatParam] = [:], id: String = "", at: SIMD2<Float> = .zero) {
        self.kind = kind
        self.params = params
        self.id = id
        self.at = at
    }

    func param(_ name: String) -> MatParam { params[name] ?? kind.spec.pin(name)?.value ?? .float(0) }
}

/// What a function's wire carries: 1 to 4 floats.
enum MatFnType: Int, Codable, CaseIterable {
    case float = 1, vec2, vec3, vec4

    var metal: String { self == .float ? "float" : "float\(rawValue)" }
    var title: String { self == .float ? "float" : "vec\(rawValue)" }
    static func wider(_ a: MatFnType, _ b: MatFnType) -> MatFnType { a.rawValue >= b.rawValue ? a : b }
}

/// A function node's input: its default (what an unwired one is), what is wired into it (nil: a value only; generic:
/// whatever comes, the node's output following the widest).
struct MatFnPinSpec {
    let name: String
    let value: MatParam
    var type: MatFnType? = .float
    var generic = false
    var span: ClosedRange<Float>?
    var choices: [String] = []

    init(_ name: String, _ value: MatParam = .float(0), _ type: MatFnType? = .float, generic: Bool = false,
         span: ClosedRange<Float>? = nil, choices: [String] = []) {
        self.name = name
        self.value = value
        self.type = type
        self.generic = generic
        self.span = span
        self.choices = choices
    }
}

struct MatFnSpec {
    let title: String
    let family: String
    let inputs: [MatFnPinSpec]
    /// A fixed type, or nil: its generic inputs' widest.
    let output: MatFnType?
    func pin(_ name: String) -> MatFnPinSpec? { inputs.first { $0.name == name } }
}

enum MatFnKind: String, Codable, CaseIterable {
    // Inputs
    case position, size, seed, float, vector2, color
    // Sampling
    case sample
    // Math (generic)
    case add, subtract, multiply, divide, minimum, maximum, power, modulo, lerp, clamp, step, smoothstep,
         abs, negate, oneMinus, saturate, floor, fract, sqrt, sin, cos
    // Vector
    case makeVector2, makeVector4, split, dot, length, distance, normalize, atan2
    // Logic
    case compare, select
    // Random
    case random
    // The function's value
    case result

    var spec: MatFnSpec {
        typealias P = MatFnPinSpec
        func g(_ name: String, _ v: Float = 0) -> P { P(name, .float(v), .float, generic: true) }
        func unary(_ title: String) -> MatFnSpec { MatFnSpec(title: title, family: "Math", inputs: [g("a")], output: nil) }
        func binary(_ title: String, _ b: Float = 0) -> MatFnSpec { MatFnSpec(title: title, family: "Math", inputs: [g("a"), g("b", b)], output: nil) }
        switch self {
        case .position: return MatFnSpec(title: "Position", family: "Inputs", inputs: [], output: .vec2)
        case .size: return MatFnSpec(title: "Size", family: "Inputs", inputs: [], output: .vec2)
        case .seed: return MatFnSpec(title: "Seed", family: "Inputs", inputs: [], output: .float)
        case .float: return MatFnSpec(title: "Float", family: "Inputs", inputs: [P("value", .float(0), nil, span: 0...1)], output: .float)
        case .vector2: return MatFnSpec(title: "Vector2", family: "Inputs", inputs: [P("value", .vec2(.zero), nil)], output: .vec2)
        case .color: return MatFnSpec(title: "Colour", family: "Inputs", inputs: [P("value", .color([1, 1, 1, 1]), nil)], output: .vec4)
        case .sample:
            return MatFnSpec(title: "Sample", family: "Sampling",
                             inputs: [P("uv", .vec2(.zero), .vec2), P("input", .choice("in0"), nil, choices: ["in0", "in1", "in2", "in3"])],
                             output: .vec4)
        case .add: return binary("Add")
        case .subtract: return binary("Subtract")
        case .multiply: return binary("Multiply", 1)
        case .divide: return binary("Divide", 1)
        case .minimum: return binary("Min")
        case .maximum: return binary("Max")
        case .power: return binary("Power", 1)
        case .modulo: return binary("Modulo", 1)
        case .lerp: return MatFnSpec(title: "Lerp", family: "Math", inputs: [g("a"), g("b", 1), P("t", .float(0.5))], output: nil)
        case .clamp: return MatFnSpec(title: "Clamp", family: "Math", inputs: [g("x"), g("low", 0), g("high", 1)], output: nil)
        case .step: return MatFnSpec(title: "Step", family: "Math", inputs: [g("edge", 0.5), g("x")], output: nil)
        case .smoothstep: return MatFnSpec(title: "Smoothstep", family: "Math", inputs: [g("low", 0), g("high", 1), g("x")], output: nil)
        case .abs: return unary("Abs")
        case .negate: return unary("Negate")
        case .oneMinus: return unary("One Minus")
        case .saturate: return unary("Saturate")
        case .floor: return unary("Floor")
        case .fract: return unary("Fract")
        case .sqrt: return unary("Sqrt")
        case .sin: return unary("Sin")
        case .cos: return unary("Cos")
        case .makeVector2: return MatFnSpec(title: "Vector2 of", family: "Vector", inputs: [P("x"), P("y")], output: .vec2)
        case .makeVector4: return MatFnSpec(title: "Vector4 of", family: "Vector", inputs: [P("x"), P("y"), P("z"), P("w", .float(1))], output: .vec4)
        case .split:
            return MatFnSpec(title: "Component", family: "Vector",
                             inputs: [P("v", .float(0), .vec4, generic: true), P("component", .choice("x"), nil, choices: ["x", "y", "z", "w"])],
                             output: .float)
        case .dot: return MatFnSpec(title: "Dot", family: "Vector", inputs: [g("a"), g("b")], output: .float)
        case .length: return MatFnSpec(title: "Length", family: "Vector", inputs: [g("a")], output: .float)
        case .distance: return MatFnSpec(title: "Distance", family: "Vector", inputs: [g("a"), g("b")], output: .float)
        case .normalize: return unary("Normalize")
        case .atan2: return MatFnSpec(title: "Atan2", family: "Vector", inputs: [P("y"), P("x", .float(1))], output: .float)
        case .compare:
            return MatFnSpec(title: "Compare", family: "Logic",
                             inputs: [P("a"), P("b"), P("op", .choice("<"), nil, choices: ["<", "<=", ">", ">=", "==", "!="])], output: .float)
        case .select: return MatFnSpec(title: "Select", family: "Logic", inputs: [P("condition"), g("a"), g("b")], output: nil)
        case .random: return MatFnSpec(title: "Random", family: "Random", inputs: [P("at", .vec2(.zero), .vec2), P("salt", .float(0))], output: .float)
        case .result: return MatFnSpec(title: "Result", family: "Result", inputs: [P("value", .color([0, 0, 0, 1]), .vec4, generic: true)], output: nil)
        }
    }
}

// MARK: - Code

/// A function's expression: its type, its Metal, its value on the CPU (a float in all four lanes; a vector's unused
/// lanes 0).
struct MatFnExpr {
    let type: MatFnType
    let metal: String
    let eval: (MatFnEnv) -> SIMD4<Float>
}

/// What the CPU's expressions read: the pixel, the image's size, the seed, the inputs (a function of the UV).
struct MatFnEnv {
    var uv = SIMD2<Float>.zero
    var size = SIMD2<Float>(1, 1)
    var seed: Float = 0
    var sample: (Int, SIMD2<Float>) -> SIMD4<Float> = { _, _ in .zero }
}

extension MatFunction {
    /// The Metal function's body (`return` a float4 from `uv`, `size`, `seed` and `sampleInput(i, uv)`) and the CPU's
    /// closure, or why it can't be made (no Result, a loop).
    func code() throws -> (metal: String, eval: (MatFnEnv) -> SIMD4<Float>) {
        guard let result else { throw MatError("the function has no Result node") }
        var lines: [String] = []
        var made: [String: MatFnExpr] = [:]
        var visiting = Set<String>()

        func value(_ v: MatParam, _ t: MatFnType) -> MatFnExpr {
            let c: SIMD4<Float>
            switch v {
            case .vec2(let x): c = SIMD4(x.x, x.y, 0, 0)
            case .color(let x): c = x
            default: c = SIMD4(repeating: v.float)
            }
            let k: SIMD4<Float> = t == .float ? SIMD4(repeating: c.x) : c
            let lit = (0..<t.rawValue).map { MatFunction.literal(k[$0]) }.joined(separator: ", ")
            return MatFnExpr(type: t, metal: t == .float ? lit : "\(t.metal)(\(lit))", eval: { _ in k })
        }

        func input(_ n: MatFnNode, _ name: String) throws -> MatFnExpr {
            guard let pin = n.kind.spec.pin(name) else { return value(.float(0), .float) }
            if let l = link(into: n.id, name) { return try expr(l.from) }
            let v = n.param(name)
            switch v {
            case .vec2: return value(v, .vec2)
            case .color: return value(v, .vec4)
            default: return value(v, pin.generic ? .float : (pin.type ?? .float))
            }
        }

        func expr(_ id: String) throws -> MatFnExpr {
            if let e = made[id] { return e }
            guard let n = node(id) else { throw MatError("a wire from \(id), which isn't there") }
            guard visiting.insert(id).inserted else { throw MatError("a loop through \(id)") }
            defer { visiting.remove(id) }
            let e = try make(n)
            // Each node a variable: shared values computed once (the CPU's closures recompute them; tests are small).
            let name = "v_" + id.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
            lines.append("    \(e.type.metal) \(name) = \(e.metal);")
            let named = MatFnExpr(type: e.type, metal: name, eval: e.eval)
            made[id] = named
            return named
        }

        func cast(_ e: MatFnExpr, _ t: MatFnType) -> MatFnExpr {
            if e.type == t { return e }
            let metal: String
            if e.type == .float { metal = "\(t.metal)(\(e.metal))" }
            else if t == .float { metal = "(\(e.metal)).x" }
            else if t.rawValue < e.type.rawValue { metal = "(\(e.metal)).\(String("xyzw".prefix(t.rawValue)))" }
            else { metal = "\(t.metal)(\(e.metal)\(String(repeating: ", 0.0", count: t.rawValue - e.type.rawValue)))" }
            let from = e.type, ev = e.eval
            return MatFnExpr(type: t, metal: metal, eval: { env in
                let v = ev(env)
                if from == .float { return t == .float ? v : SIMD4(repeating: v.x) }
                var r = SIMD4<Float>.zero
                for i in 0..<t.rawValue { r[i] = i < from.rawValue ? v[i] : 0 }
                return t == .float ? SIMD4(repeating: v.x) : r
            })
        }

        /// A generic node's inputs, cast to their widest.
        func generic(_ n: MatFnNode, _ names: [String]) throws -> ([MatFnExpr], MatFnType) {
            let es = try names.map { try input(n, $0) }
            let t = es.reduce(MatFnType.float) { MatFnType.wider($0, $1.type) }
            return (es.map { cast($0, t) }, t)
        }

        func lanes(_ t: MatFnType, _ v: SIMD4<Float>) -> SIMD4<Float> {
            if t == .float { return SIMD4(repeating: v.x) }
            var r = SIMD4<Float>.zero
            for i in 0..<t.rawValue { r[i] = v[i] }
            return r
        }

        func map(_ n: MatFnNode, _ f: String, _ op: @escaping (Float) -> Float) throws -> MatFnExpr {
            let (es, t) = try generic(n, ["a"])
            let a = es[0].eval
            return MatFnExpr(type: t, metal: "\(f)(\(es[0].metal))", eval: { env in
                let v = a(env)
                return lanes(t, SIMD4(op(v.x), op(v.y), op(v.z), op(v.w)))
            })
        }

        func zip(_ n: MatFnNode, _ names: [String], _ metal: ([String]) -> String, _ op: @escaping ([Float]) -> Float) throws -> MatFnExpr {
            let (es, t) = try generic(n, names)
            let evals = es.map(\.eval)
            return MatFnExpr(type: t, metal: metal(es.map(\.metal)), eval: { env in
                let vs = evals.map { $0(env) }
                var r = SIMD4<Float>.zero
                for i in 0..<4 { r[i] = op(vs.map { $0[i] }) }
                return lanes(t, r)
            })
        }

        func make(_ n: MatFnNode) throws -> MatFnExpr {
            switch n.kind {
            case .position: return MatFnExpr(type: .vec2, metal: "uv", eval: { SIMD4($0.uv.x, $0.uv.y, 0, 0) })
            case .size: return MatFnExpr(type: .vec2, metal: "size", eval: { SIMD4($0.size.x, $0.size.y, 0, 0) })
            case .seed: return MatFnExpr(type: .float, metal: "seed", eval: { SIMD4(repeating: $0.seed) })
            case .float: return value(n.param("value"), .float)
            case .vector2: return value(n.param("value"), .vec2)
            case .color: return value(n.param("value"), .vec4)
            case .sample:
                let uv = cast(try input(n, "uv"), .vec2)
                let i = max(["in0", "in1", "in2", "in3"].firstIndex(of: n.param("input").choice) ?? 0, 0)
                let f = uv.eval
                return MatFnExpr(type: .vec4, metal: "sampleInput(\(i), \(uv.metal))", eval: { env in
                    let p = f(env)
                    return env.sample(i, SIMD2(p.x, p.y))
                })
            case .add: return try zip(n, ["a", "b"], { "(\($0[0]) + \($0[1]))" }, { $0[0] + $0[1] })
            case .subtract: return try zip(n, ["a", "b"], { "(\($0[0]) - \($0[1]))" }, { $0[0] - $0[1] })
            case .multiply: return try zip(n, ["a", "b"], { "(\($0[0]) * \($0[1]))" }, { $0[0] * $0[1] })
            case .divide: return try zip(n, ["a", "b"], { "(\($0[0]) / \($0[1]))" }, { $0[0] / $0[1] })
            case .minimum: return try zip(n, ["a", "b"], { "min(\($0[0]), \($0[1]))" }, { Swift.min($0[0], $0[1]) })
            case .maximum: return try zip(n, ["a", "b"], { "max(\($0[0]), \($0[1]))" }, { Swift.max($0[0], $0[1]) })
            case .power: return try zip(n, ["a", "b"], { "pow(abs(\($0[0])), \($0[1]))" }, { Foundation.pow(Swift.abs($0[0]), $0[1]) })
            case .modulo: return try zip(n, ["a", "b"], { "fmod(\($0[0]), \($0[1]))" }, { fmodf($0[0], $0[1]) })
            case .lerp:
                let (es, t) = try generic(n, ["a", "b"])
                let tt = cast(try input(n, "t"), .float)
                let a = es[0].eval, b = es[1].eval, u = tt.eval
                return MatFnExpr(type: t, metal: "mix(\(es[0].metal), \(es[1].metal), \(tt.metal))", eval: { env in
                    let k = u(env).x
                    return lanes(t, a(env) + (b(env) - a(env)) * k)
                })
            case .clamp: return try zip(n, ["x", "low", "high"], { "clamp(\($0[0]), \($0[1]), \($0[2]))" }, { Swift.min(Swift.max($0[0], $0[1]), $0[2]) })
            case .step: return try zip(n, ["edge", "x"], { "step(\($0[0]), \($0[1]))" }, { $0[1] < $0[0] ? 0 : 1 })
            case .smoothstep:
                return try zip(n, ["low", "high", "x"], { "smoothstep(\($0[0]), \($0[1]), \($0[2]))" }) { v in
                    let t = Swift.min(Swift.max((v[2] - v[0]) / (v[1] - v[0]), 0), 1)
                    return t * t * (3 - 2 * t)
                }
            case .abs: return try map(n, "abs", Swift.abs)
            case .negate: return try map(n, "-", { -$0 })
            case .oneMinus: return try map(n, "1.0 - ", { 1 - $0 })
            case .saturate: return try map(n, "saturate", { Swift.min(Swift.max($0, 0), 1) })
            case .floor: return try map(n, "floor", { Foundation.floor($0) })
            case .fract: return try map(n, "fract", { $0 - Foundation.floor($0) })
            case .sqrt: return try map(n, "sqrt", { Foundation.sqrt(Swift.max($0, 0)) })
            case .sin: return try map(n, "sin", { Foundation.sin($0) })
            case .cos: return try map(n, "cos", { Foundation.cos($0) })
            case .normalize:
                let (es, t) = try generic(n, ["a"])
                let a = es[0].eval
                return MatFnExpr(type: t, metal: t == .float ? "sign(\(es[0].metal))" : "normalize(\(es[0].metal))", eval: { env in
                    let v = lanes(t, a(env))
                    if t == .float { return SIMD4(repeating: v.x > 0 ? 1 : v.x < 0 ? -1 : 0) }
                    let l = simd_length(v)
                    return l > 0 ? v / l : v
                })
            case .makeVector2:
                let x = cast(try input(n, "x"), .float), y = cast(try input(n, "y"), .float)
                let fx = x.eval, fy = y.eval
                return MatFnExpr(type: .vec2, metal: "float2(\(x.metal), \(y.metal))", eval: { SIMD4(fx($0).x, fy($0).x, 0, 0) })
            case .makeVector4:
                let es = try ["x", "y", "z", "w"].map { cast(try input(n, $0), .float) }
                let fs = es.map(\.eval)
                return MatFnExpr(type: .vec4, metal: "float4(\(es.map(\.metal).joined(separator: ", ")))",
                                 eval: { env in SIMD4(fs[0](env).x, fs[1](env).x, fs[2](env).x, fs[3](env).x) })
            case .split:
                let v = cast(try input(n, "v"), .vec4)
                let c = n.param("component").choice, i = max("xyzw".firstIndex(of: Character(c.isEmpty ? "x" : c)).map { "xyzw".distance(from: "xyzw".startIndex, to: $0) } ?? 0, 0)
                let f = v.eval
                return MatFnExpr(type: .float, metal: "(\(v.metal)).\(c.isEmpty ? "x" : c)", eval: { SIMD4(repeating: f($0)[i]) })
            case .dot:
                let (es, t) = try generic(n, ["a", "b"])
                let a = es[0].eval, b = es[1].eval
                return MatFnExpr(type: .float, metal: t == .float ? "(\(es[0].metal) * \(es[1].metal))" : "dot(\(es[0].metal), \(es[1].metal))",
                                 eval: { env in SIMD4(repeating: t == .float ? a(env).x * b(env).x : simd_dot(lanes(t, a(env)), lanes(t, b(env)))) })
            case .length:
                let (es, t) = try generic(n, ["a"])
                let a = es[0].eval
                return MatFnExpr(type: .float, metal: t == .float ? "abs(\(es[0].metal))" : "length(\(es[0].metal))",
                                 eval: { env in SIMD4(repeating: t == .float ? Swift.abs(a(env).x) : simd_length(lanes(t, a(env)))) })
            case .distance:
                let (es, t) = try generic(n, ["a", "b"])
                let a = es[0].eval, b = es[1].eval
                return MatFnExpr(type: .float, metal: t == .float ? "abs(\(es[0].metal) - \(es[1].metal))" : "distance(\(es[0].metal), \(es[1].metal))",
                                 eval: { env in SIMD4(repeating: t == .float ? Swift.abs(a(env).x - b(env).x) : simd_distance(lanes(t, a(env)), lanes(t, b(env)))) })
            case .atan2:
                let y = cast(try input(n, "y"), .float), x = cast(try input(n, "x"), .float)
                let fy = y.eval, fx = x.eval
                return MatFnExpr(type: .float, metal: "atan2(\(y.metal), \(x.metal))", eval: { SIMD4(repeating: Foundation.atan2(fy($0).x, fx($0).x)) })
            case .compare:
                let a = cast(try input(n, "a"), .float), b = cast(try input(n, "b"), .float)
                let op = n.param("op").choice.isEmpty ? "<" : n.param("op").choice
                let fa = a.eval, fb = b.eval
                return MatFnExpr(type: .float, metal: "((\(a.metal) \(op) \(b.metal)) ? 1.0 : 0.0)", eval: { env in
                    let x = fa(env).x, y = fb(env).x
                    let r: Bool
                    switch op {
                    case "<=": r = x <= y
                    case ">": r = x > y
                    case ">=": r = x >= y
                    case "==": r = x == y
                    case "!=": r = x != y
                    default: r = x < y
                    }
                    return SIMD4(repeating: r ? 1 : 0)
                })
            case .select:
                let cond = cast(try input(n, "condition"), .float)
                let (es, t) = try generic(n, ["a", "b"])
                let fc = cond.eval, a = es[0].eval, b = es[1].eval
                return MatFnExpr(type: t, metal: "((\(cond.metal) != 0.0) ? \(es[0].metal) : \(es[1].metal))",
                                 eval: { env in fc(env).x != 0 ? a(env) : b(env) })
            case .random:
                let at = cast(try input(n, "at"), .vec2), salt = cast(try input(n, "salt"), .float)
                let fa = at.eval, fs = salt.eval
                return MatFnExpr(type: .float, metal: "matRandom(\(at.metal), \(salt.metal) + seed)", eval: { env in
                    let p = fa(env)
                    return SIMD4(repeating: MatFunction.random(SIMD2(p.x, p.y), fs(env).x + env.seed))
                })
            case .result:
                return cast(try input(n, "value"), .vec4)
            }
        }

        let out = try expr(result.id)
        let metal = lines.joined(separator: "\n") + "\n    return \(out.metal);"
        let eval = out.eval
        return (metal, { env in eval(env) })
    }

    /// A float as Metal: finite, with a point.
    static func literal(_ f: Float) -> String {
        guard f.isFinite else { return f > 0 ? "INFINITY" : f < 0 ? "-INFINITY" : "0.0" }
        let s = "\(f)"
        return s.contains(".") || s.contains("e") ? s : s + ".0"
    }

    /// The Random node's value (MSL matRandom, line for line): a hash of the point and the salt, 0..<1.
    static func random(_ p: SIMD2<Float>, _ salt: Float) -> Float {
        var h = UInt32(bitPattern: Int32(truncatingIfNeeded: Int((p.x * 4096).rounded(.down))))
        h = h &* 0x27d4_eb2d ^ UInt32(bitPattern: Int32(truncatingIfNeeded: Int((p.y * 4096).rounded(.down)))) &* 0x1656_67b1
        h ^= UInt32(bitPattern: Int32(truncatingIfNeeded: Int(salt.rounded(.down)))) &* 0x9e37_79b9
        h ^= h >> 15; h = h &* 0x2c1b_3c6d; h ^= h >> 12; h = h &* 0x297a_2d39; h ^= h >> 15
        return Float(h >> 8) / Float(1 << 24)
    }
}
