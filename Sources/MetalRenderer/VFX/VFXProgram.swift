import Foundation
import simd

/// An emitter's generated code (an effect's emitter the fixed one can't run: VFXLowering): Metal functions the
/// particle kernels call in the VFX library (VFXCompiler; the hooks in Shaders/ParticleSim.metal), and the same on the
/// CPU (closures the interpreter, ParticlesCPU, runs). Both are made from one walk of the graph, so they say the same.
///
/// The fixed emitter's values (ParticleEmitter, its descriptor) still hold what isn't wired: a Gravity whose share is
/// a value reads it from the descriptor as the fixed code does, so editing it is a descriptor's rewrite. What only
/// generated code has (an operator's inputs, a curve's keys, a Force's value) is in `params`, a float4 a value: the
/// code reads them from the buffer, never as literals, so a value's edit needs no compile (`slots`).
final class VFXProgram {
    struct Hooks: OptionSet {
        let rawValue: UInt32
        static let spawn = Hooks(rawValue: 1)    // MSL VFX_SPAWN: its newborns
        static let step = Hooks(rawValue: 2)     // VFX_STEP: its steps
        static let output = Hooks(rawValue: 4)   // VFX_OUTPUT: its size and colour in the pose
        static let rate = Hooks(rawValue: 8)     // VFX_RATE: its rate over time (a curve)
    }
    /// Which program it is in its system (its functions' suffix: vfxSpawn3).
    let number: Int
    let hooks: Hooks
    let metal: String
    var params: [SIMD4<Float>]
    /// Where each value is: "<node or block id>.<pin>", its first float4.
    let slots: [String: Int]
    /// The rate curve's first float4 (VFX_RATE).
    let rate: Int?
    /// The attributes it keeps (Set Attribute, Get Attribute): the highest's number + 1.
    let attributes: Int
    let initPlan: VFXInitPlan
    let stepPlan: VFXStepPlan
    let outputPlan: VFXOutputPlan

    init(number: Int, hooks: Hooks, metal: String, params: [SIMD4<Float>], slots: [String: Int], rate: Int?, attributes: Int,
         initPlan: VFXInitPlan, stepPlan: VFXStepPlan, outputPlan: VFXOutputPlan) {
        self.number = number
        self.hooks = hooks
        self.metal = metal
        self.params = params
        self.slots = slots
        self.rate = rate
        self.attributes = attributes
        self.initPlan = initPlan
        self.stepPlan = stepPlan
        self.outputPlan = outputPlan
    }
}

/// A compiled expression: its type, its Metal, and its value on the CPU.
struct VFXExpr {
    let type: VFXType
    let metal: String
    let eval: (VFXEnv) -> SIMD4<Float>

    func f(_ env: VFXEnv) -> Float { eval(env).x }
    func v3(_ env: VFXEnv) -> SIMD3<Float> { let c = eval(env); return SIMD3(c.x, c.y, c.z) }
    func c(_ env: VFXEnv) -> SIMD4<Float> { eval(env) }
    func b(_ env: VFXEnv) -> Bool { eval(env).x != 0 }
}

/// What the CPU's expressions read: the particle where the code is (its place, velocity, age...), the program's
/// parameters and the particle's attributes. A float is held in all four lanes, a vec3 in xyz, a bool as 1 or 0.
final class VFXEnv {
    var x = SIMD3<Float>.zero
    var v = SIMD3<Float>.zero
    var age: Float = 0
    var share: Float = 0      // age / life
    var life: Float = 0
    var seed: UInt32 = 0
    var id: UInt32 = 0
    var time: Float = 0
    var dt: Float = 0
    var origin = SIMD3<Float>.zero
    var params: [SIMD4<Float>] = []
    var attributes: [SIMD4<Float>] = []
    var fields: [GPUParticleField] = []
    var samples: [SIMD4<Float>] = []
}

/// What Initialize does past the fixed emitter's birth, in its blocks' order.
struct VFXInitPlan {
    enum Op { case lifetime, position, velocity, attribute(Int) }
    var ops: [(op: Op, expr: VFXExpr)] = []
}

/// What Update does past the fixed emitter's step: wired shares of its forces (nil: the descriptor's), forces,
/// velocities, attributes, kills and triggers of its own.
struct VFXStepPlan {
    var gravity: VFXExpr?
    var drag: VFXExpr?
    var wind: VFXExpr?
    var curl: VFXExpr?
    var field: VFXExpr?
    var swirl: VFXExpr?
    var attraction: VFXExpr?
    var forces: [VFXExpr] = []
    var velocities: [VFXExpr] = []
    var attributes: [(Int, VFXExpr)] = []
    var kills: [VFXExpr] = []
    var triggers: [VFXExpr] = []
    var isEmpty: Bool {
        gravity == nil && drag == nil && wind == nil && curl == nil && field == nil && swirl == nil && attraction == nil
            && forces.isEmpty && velocities.isEmpty && attributes.isEmpty && kills.isEmpty && triggers.isEmpty
    }
}

/// The size (before its random shrink) and colour (before emission) over its life, if not the fixed emitter's.
struct VFXOutputPlan {
    var size: VFXExpr?
    var color: VFXExpr?
}

struct VFXError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Building a program

/// Walks one emitter's graph into a program: each of its blocks' wired pins (and their curves and gradients) as
/// expressions, in the context each runs in.
final class VFXProgramBuilder {
    let effect: VFXEffect
    let emitter: VFXEmitter
    let fieldIndex: [String: Int]
    var params: [SIMD4<Float>] = []
    private(set) var slots: [String: Int] = [:]
    private(set) var attributes = 0

    init(effect: VFXEffect, emitter: VFXEmitter, fieldIndex: [String: Int]) {
        self.effect = effect
        self.emitter = emitter
        self.fieldIndex = fieldIndex
    }

    /// The Metal names of the inputs in each context's code (VFXCodegen's templates) and their values on the CPU.
    static func symbol(_ input: VFXOpKind, _ context: VFXContext) -> String? {
        switch (input, context) {
        case (.position, .initialize): return "(at + offset)"
        case (.position, .update): return "x"
        case (.position, .output): return "q.position.xyz"
        case (.velocity, .initialize), (.velocity, .update): return "v"
        case (.velocity, .output): return "q.velocity.xyz"
        case (.speed, .initialize), (.speed, .update): return "length(v)"
        case (.speed, .output): return "length(q.velocity.xyz)"
        case (.age, .initialize): return "0.0f"
        case (.age, .update): return "age"
        case (.age, .output): return "q.position.w"
        case (.ageOverLife, .initialize): return "0.0f"
        case (.ageOverLife, .update): return "(age / max(p.velocity.w, 1e-6f))"
        case (.ageOverLife, .output): return "x"
        case (.lifetime, .initialize): return "life"
        case (.lifetime, .update): return "p.velocity.w"
        case (.lifetime, .output): return "q.velocity.w"
        case (.particleID, .initialize): return "float(spawn)"
        case (.particleID, .update): return "float(p.info.x)"
        case (.particleID, .output): return "float(q.info.x)"
        case (.time, _): return "s.time"
        case (.deltaTime, _): return "s.dt"
        case (.emitterPosition, _): return "e.origin.xyz"
        default: return nil
        }
    }

    /// The float4 that holds `value` (a key's own, made once).
    private func slot(_ key: String, _ value: [SIMD4<Float>]) -> Int {
        if let s = slots[key] { return s }
        let s = params.count
        params += value
        slots[key] = s
        return s
    }

    /// A curve's keys at a slot of their own: the count and smoothness, then (t, value) each, room for the most.
    func curveSlot(_ key: String, _ c: VFXCurve) -> Int {
        var block = [SIMD4<Float>](repeating: .zero, count: 1 + VFXCurve.maxKeys)
        block[0] = SIMD4(Float(min(c.keys.count, VFXCurve.maxKeys)), c.smooth ? 1 : 0, 0, 0)
        for (k, key) in c.keys.prefix(VFXCurve.maxKeys).enumerated() { block[1 + k] = SIMD4(key.x, key.y, 0, 0) }
        return slot(key, block)
    }
    /// A gradient's keys: the count, then (t) and the colour each.
    func gradientSlot(_ key: String, _ g: VFXGradient) -> Int {
        var block = [SIMD4<Float>](repeating: .zero, count: 1 + 2 * VFXGradient.maxKeys)
        block[0] = SIMD4(Float(min(g.keys.count, VFXGradient.maxKeys)), 0, 0, 0)
        for (k, key) in g.keys.prefix(VFXGradient.maxKeys).enumerated() {
            block[1 + 2 * k] = SIMD4(key.t, 0, 0, 0)
            block[2 + 2 * k] = key.color
        }
        return slot(key, block)
    }

    /// The value of pin `pin` of block or node `target`: what is wired into it, else its value (`value`) from the
    /// parameters, as type `type`.
    func input(_ target: String, _ pin: String, _ value: VFXParam, as type: VFXType, in context: VFXContext,
               visiting: Set<String> = []) throws -> VFXExpr {
        if let l = effect.link(into: target, pin) {
            return cast(try node(l.from, l.output, in: context, visiting: visiting), to: type)
        }
        return constant("\(target).\(pin)", value, as: type)
    }

    /// Whether anything is wired into pin `pin` of `target`.
    func wired(_ target: String, _ pin: String) -> Bool { effect.link(into: target, pin) != nil }

    /// `value` from the parameters, as `type`.
    func constant(_ key: String, _ value: VFXParam, as type: VFXType) -> VFXExpr {
        let k: Int
        switch value {
        case .vec3(let v): k = slot(key, [SIMD4(v, 0)])
        case .color(let c): k = slot(key, [c])
        default: k = slot(key, [SIMD4(repeating: value.float)])
        }
        let natural: VFXType
        switch value {
        case .vec3: natural = .vec3
        case .color: natural = .color
        case .bool: natural = .bool
        default: natural = .float
        }
        let metal: String
        switch natural {
        case .float: metal = "P[\(k)].x"
        case .vec3: metal = "P[\(k)].xyz"
        case .color: metal = "P[\(k)]"
        case .bool: metal = "(P[\(k)].x != 0.0f)"
        }
        let e: VFXExpr
        switch natural {
        case .vec3: e = VFXExpr(type: .vec3, metal: metal) { env in let p = env.params[k]; return SIMD4(p.x, p.y, p.z, 0) }
        case .bool: e = VFXExpr(type: .bool, metal: metal) { env in SIMD4(repeating: env.params[k].x != 0 ? 1 : 0) }
        case .float: e = VFXExpr(type: .float, metal: metal) { env in SIMD4(repeating: env.params[k].x) }
        case .color: e = VFXExpr(type: .color, metal: metal) { env in env.params[k] }
        }
        return cast(e, to: type)
    }

    /// Output `output` of node `id`, in `context`'s code.
    func node(_ id: String, _ output: String, in context: VFXContext, visiting: Set<String>) throws -> VFXExpr {
        guard let n = effect.node(id) else { throw VFXError("a wire from \(id), which isn't a node") }
        guard !visiting.contains(id) else { throw VFXError("\(n.kind.spec.title) (\(id)) is wired into itself") }
        var visiting = visiting
        visiting.insert(id)
        let spec = n.kind.spec
        func pin(_ name: String) -> VFXPinSpec { spec.pin(name)! }
        func arg(_ name: String, _ t: VFXType) throws -> VFXExpr {
            try input(id, name, n.param(name), as: t, in: context, visiting: visiting)
        }
        /// A generic input's own type: what is wired into it, else its value's.
        func natural(_ name: String) throws -> VFXType {
            if let l = effect.link(into: id, name) { return try node(l.from, l.output, in: context, visiting: visiting).type }
            switch n.param(name) {
            case .vec3: return .vec3
            case .color: return .color
            case .bool: return .bool
            default: return .float
            }
        }
        func generic(_ names: [String]) throws -> (VFXType, [VFXExpr]) {
            var t = VFXType.float
            for name in names { t = VFXType.wider(t, try natural(name)) }
            if t == .bool { t = .float }
            return (t, try names.map { try arg($0, t) })
        }
        let mt = { (t: VFXType) in VFXProgramBuilder.metalType(t) }

        switch n.kind {
        case .age, .ageOverLife, .lifetime, .position, .velocity, .speed, .particleID, .time, .deltaTime, .emitterPosition:
            guard let s = VFXProgramBuilder.symbol(n.kind, context) else {
                throw VFXError("\(spec.title) isn't known in \(context.title)")
            }
            let t = spec.outputs[0].type!
            let kind = n.kind
            return VFXExpr(type: t, metal: s) { env in
                switch kind {
                case .age: return SIMD4(repeating: env.age)
                case .ageOverLife: return SIMD4(repeating: env.share)
                case .lifetime: return SIMD4(repeating: env.life)
                case .position: return SIMD4(env.x, 0)
                case .velocity: return SIMD4(env.v, 0)
                case .speed: return SIMD4(repeating: length(env.v))
                case .particleID: return SIMD4(repeating: Float(env.id))
                case .time: return SIMD4(repeating: env.time)
                case .deltaTime: return SIMD4(repeating: env.dt)
                default: return SIMD4(env.origin, 0)
                }
            }
        case .random:
            let k = UInt32(max(n.param("salt").int, 0)) &+ 16
            let seed = context == .initialize ? "seed" : context == .update ? "p.info.y" : "q.info.y"
            return VFXExpr(type: .float, metal: "particleRandom(\(seed), \(k)u)") { env in
                SIMD4(repeating: ParticleMath.random(env.seed, k))
            }
        case .float, .vector, .colorValue:
            let t = spec.outputs[0].type!
            return constant("\(id).value", n.param("value"), as: t)
        case .add, .subtract, .multiply, .divide, .minimum, .maximum:
            let (t, a) = try generic(["a", "b"])
            let x = a[0], y = a[1]
            let kind = n.kind
            let metal: String
            switch kind {
            case .add: metal = "(\(x.metal) + \(y.metal))"
            case .subtract: metal = "(\(x.metal) - \(y.metal))"
            case .multiply: metal = "(\(x.metal) * \(y.metal))"
            case .divide: metal = "(\(x.metal) / \(y.metal))"
            case .minimum: metal = "min(\(x.metal), \(y.metal))"
            default: metal = "max(\(x.metal), \(y.metal))"
            }
            return VFXExpr(type: t, metal: metal) { env in
                let p = x.eval(env), q = y.eval(env)
                switch kind {
                case .add: return p + q
                case .subtract: return p - q
                case .multiply: return p * q
                case .divide: return p / q
                case .minimum: return simd_min(p, q)
                default: return simd_max(p, q)
                }
            }
        case .lerp:
            let (t, ab) = try generic(["a", "b"])
            let u = try arg("t", .float)
            return VFXExpr(type: t, metal: "mix(\(ab[0].metal), \(ab[1].metal), \(u.metal))") { env in
                let p = ab[0].eval(env), q = ab[1].eval(env)
                return p + (q - p) * u.f(env)
            }
        case .clamp:
            let (t, a) = try generic(["x", "lo", "hi"])
            return VFXExpr(type: t, metal: "clamp(\(a[0].metal), \(a[1].metal), \(a[2].metal))") { env in
                simd_min(simd_max(a[0].eval(env), a[1].eval(env)), a[2].eval(env))
            }
        case .abs, .negate, .oneMinus, .saturate, .floor, .fract, .sqrt, .sin, .cos:
            let (t, a) = try generic(["a"])
            let x = a[0], kind = n.kind
            let metal: String
            switch kind {
            case .abs: metal = "abs(\(x.metal))"
            case .negate: metal = "(-\(x.metal))"
            case .oneMinus: metal = "(1.0f - \(x.metal))"
            case .saturate: metal = "saturate(\(x.metal))"
            case .floor: metal = "floor(\(x.metal))"
            case .fract: metal = "fract(\(x.metal))"
            case .sqrt: metal = "sqrt(\(x.metal))"
            case .sin: metal = "sin(\(x.metal))"
            default: metal = "cos(\(x.metal))"
            }
            return VFXExpr(type: t, metal: metal) { env in
                let p = x.eval(env)
                switch kind {
                case .abs: return simd_abs(p)
                case .negate: return -p
                case .oneMinus: return 1 - p
                case .saturate: return simd_clamp(p, SIMD4(repeating: 0), SIMD4(repeating: 1))
                case .floor: return p.rounded(.down)
                case .fract: return p - p.rounded(.down)
                case .sqrt: return p.squareRoot()
                case .sin: return SIMD4(sin(p.x), sin(p.y), sin(p.z), sin(p.w))
                default: return SIMD4(cos(p.x), cos(p.y), cos(p.z), cos(p.w))
                }
            }
        case .power:
            let (t, a) = try generic(["a"])
            let e = try arg("e", .float), x = a[0]
            return VFXExpr(type: t, metal: "pow(\(x.metal), \(mt(t))(\(e.metal)))") { env in
                let p = x.eval(env), k = e.f(env)
                return SIMD4(pow(p.x, k), pow(p.y, k), pow(p.z, k), pow(p.w, k))
            }
        case .remap:
            let x = try arg("x", .float), a = try arg("inLo", .float), b = try arg("inHi", .float)
            let c = try arg("outLo", .float), d = try arg("outHi", .float)
            return VFXExpr(type: .float, metal: "(\(c.metal) + (\(x.metal) - \(a.metal)) / (\(b.metal) - \(a.metal)) * (\(d.metal) - \(c.metal)))") { env in
                let lo = c.f(env)
                return SIMD4(repeating: lo + (x.f(env) - a.f(env)) / (b.f(env) - a.f(env)) * (d.f(env) - lo))
            }
        case .step:
            let edge = try arg("edge", .float), x = try arg("x", .float)
            return VFXExpr(type: .float, metal: "step(\(edge.metal), \(x.metal))") { env in
                SIMD4(repeating: x.f(env) < edge.f(env) ? 0 : 1)
            }
        case .smoothstep:
            let lo = try arg("lo", .float), hi = try arg("hi", .float), x = try arg("x", .float)
            return VFXExpr(type: .float, metal: "smoothstep(\(lo.metal), \(hi.metal), \(x.metal))") { env in
                let a = lo.f(env), b = hi.f(env)
                let u = min(max((x.f(env) - a) / (b - a), 0), 1)
                return SIMD4(repeating: u * u * (3 - 2 * u))
            }
        case .makeVector:
            let x = try arg("x", .float), y = try arg("y", .float), z = try arg("z", .float)
            return VFXExpr(type: .vec3, metal: "float3(\(x.metal), \(y.metal), \(z.metal))") { env in
                SIMD4(x.f(env), y.f(env), z.f(env), 0)
            }
        case .splitVector:
            let v = try arg("v", .vec3)
            let lane = ["x": 0, "y": 1, "z": 2][output] ?? 0
            return VFXExpr(type: .float, metal: "(\(v.metal)).\(["x", "y", "z"][lane])") { env in SIMD4(repeating: v.eval(env)[lane]) }
        case .makeColor:
            let rgb = try arg("rgb", .vec3), a = try arg("a", .float)
            return VFXExpr(type: .color, metal: "float4(\(rgb.metal), \(a.metal))") { env in SIMD4(rgb.v3(env), a.f(env)) }
        case .splitColor:
            let c = try arg("c", .color)
            if output == "a" { return VFXExpr(type: .float, metal: "(\(c.metal)).w") { env in SIMD4(repeating: c.eval(env).w) } }
            return VFXExpr(type: .vec3, metal: "(\(c.metal)).xyz") { env in let p = c.eval(env); return SIMD4(p.x, p.y, p.z, 0) }
        case .length:
            let v = try arg("v", .vec3)
            return VFXExpr(type: .float, metal: "length(\(v.metal))") { env in SIMD4(repeating: length(v.v3(env))) }
        case .normalize:
            let v = try arg("v", .vec3)
            return VFXExpr(type: .vec3, metal: "vfxNormalize(\(v.metal))") { env in
                let p = v.v3(env), l = length(p)
                return SIMD4(l > 1e-12 ? p / l : .zero, 0)
            }
        case .dot:
            let a = try arg("a", .vec3), b = try arg("b", .vec3)
            return VFXExpr(type: .float, metal: "dot(\(a.metal), \(b.metal))") { env in SIMD4(repeating: dot(a.v3(env), b.v3(env))) }
        case .cross:
            let a = try arg("a", .vec3), b = try arg("b", .vec3)
            return VFXExpr(type: .vec3, metal: "cross(\(a.metal), \(b.metal))") { env in SIMD4(cross(a.v3(env), b.v3(env)), 0) }
        case .distance:
            let a = try arg("a", .vec3), b = try arg("b", .vec3)
            return VFXExpr(type: .float, metal: "distance(\(a.metal), \(b.metal))") { env in SIMD4(repeating: distance(a.v3(env), b.v3(env))) }
        case .compare:
            let a = try arg("a", .float), b = try arg("b", .float)
            let op = n.param("op").choice
            guard ["<", "<=", ">", ">=", "==", "!="].contains(op) else { throw VFXError("Compare: no test \(op)") }
            return VFXExpr(type: .bool, metal: "(\(a.metal) \(op) \(b.metal))") { env in
                let p = a.f(env), q = b.f(env)
                let r: Bool
                switch op {
                case "<": r = p < q
                case "<=": r = p <= q
                case ">": r = p > q
                case ">=": r = p >= q
                case "==": r = p == q
                default: r = p != q
                }
                return SIMD4(repeating: r ? 1 : 0)
            }
        case .select:
            let c = try arg("if", .bool)
            let (t, ab) = try generic(["then", "else"])
            return VFXExpr(type: t, metal: "(\(c.metal) ? \(ab[0].metal) : \(ab[1].metal))") { env in
                c.b(env) ? ab[0].eval(env) : ab[1].eval(env)
            }
        case .and, .or:
            let a = try arg("a", .bool), b = try arg("b", .bool), and = n.kind == .and
            return VFXExpr(type: .bool, metal: "(\(a.metal) \(and ? "&&" : "||") \(b.metal))") { env in
                SIMD4(repeating: (and ? a.b(env) && b.b(env) : a.b(env) || b.b(env)) ? 1 : 0)
            }
        case .not:
            let a = try arg("a", .bool)
            return VFXExpr(type: .bool, metal: "(!\(a.metal))") { env in SIMD4(repeating: a.b(env) ? 0 : 1) }
        case .curve:
            let t = try arg("t", .float), k = curveSlot("\(id).curve", n.param("curve").curve)
            return VFXExpr(type: .float, metal: "vfxCurve(P + \(k), \(t.metal))") { env in
                SIMD4(repeating: VFXProgram.curve(env.params, k, t.f(env)))
            }
        case .gradient:
            let t = try arg("t", .float), k = gradientSlot("\(id).gradient", n.param("gradient").gradient)
            return VFXExpr(type: .color, metal: "vfxGradient(P + \(k), \(t.metal))") { env in
                VFXProgram.gradient(env.params, k, t.f(env))
            }
        case .noise:
            let p = try arg("p", .vec3), f = try arg("frequency", .float), s = try arg("scroll", .float)
            return VFXExpr(type: .float, metal: "particleNoise(\(p.metal) * \(f.metal) + float3(0.0f, s.time * \(s.metal), 0.0f), 0x1B873593u).x") { env in
                SIMD4(repeating: ParticleMath.noise(p.v3(env) * f.f(env) + SIMD3(0, env.time * s.f(env), 0), 0x1B873593).x)
            }
        case .curlNoise:
            let p = try arg("p", .vec3), f = try arg("frequency", .float), s = try arg("scroll", .float)
            return VFXExpr(type: .vec3, metal: "particleCurl(\(p.metal), \(f.metal), s.time * \(s.metal))") { env in
                SIMD4(ParticleMath.curl(p.v3(env), frequency: f.f(env), time: env.time * s.f(env)), 0)
            }
        case .sampleField:
            guard context != .output else { throw VFXError("Sample Field: not in Output (the pose has no fields)") }
            let name = n.param("field").choice
            guard let k = fieldIndex[name] else { throw VFXError("Sample Field: no field \"\(name)\"") }
            let p = try arg("p", .vec3)
            return VFXExpr(type: .vec3, metal: "particleField(fields[\(k)], samples, \(p.metal))") { env in
                SIMD4(ParticleMath.field(env.fields[k], env.samples, p.v3(env)), 0)
            }
        case .getAttribute:
            let k = attribute(n.param("attribute").choice)
            return VFXExpr(type: .color, metal: "A[\(k)]") { env in env.attributes[k] }
        }
    }

    /// Attribute `name`'s number (A 0, B 1...); the program keeps that many.
    func attribute(_ name: String) -> Int {
        let k = VFXBlockKind.attributes.firstIndex(of: name) ?? 0
        attributes = max(attributes, k + 1)
        return k
    }

    static func metalType(_ t: VFXType) -> String {
        switch t {
        case .float: return "float"
        case .vec3: return "float3"
        case .color: return "float4"
        case .bool: return "bool"
        }
    }

    /// `e` as type `t`: a float spread over a vector's lanes, a vector's first lane as a float, a colour's rgb, a
    /// vec3 with alpha 1, a bool as 1 or 0 (and a number as true where it isn't 0).
    func cast(_ e: VFXExpr, to t: VFXType) -> VFXExpr {
        if e.type == t { return e }
        switch (e.type, t) {
        case (.float, .vec3): return VFXExpr(type: t, metal: "float3(\(e.metal))", eval: e.eval)
        case (.float, .color): return VFXExpr(type: t, metal: "float4(\(e.metal))", eval: e.eval)
        case (.vec3, .color): return VFXExpr(type: t, metal: "float4(\(e.metal), 1.0f)") { env in SIMD4(e.v3(env), 1) }
        case (.color, .vec3): return VFXExpr(type: t, metal: "(\(e.metal)).xyz") { env in SIMD4(e.v3(env), 0) }
        case (.vec3, .float), (.color, .float): return VFXExpr(type: t, metal: "(\(e.metal)).x") { env in SIMD4(repeating: e.f(env)) }
        case (.bool, _): return cast(VFXExpr(type: .float, metal: "(\(e.metal) ? 1.0f : 0.0f)", eval: e.eval), to: t)
        case (_, .bool):
            let f = cast(e, to: .float)
            return VFXExpr(type: .bool, metal: "(\(f.metal) != 0.0f)") { env in SIMD4(repeating: f.f(env) != 0 ? 1 : 0) }
        default: return e
        }
    }
}

// MARK: - The CPU's twins of the generated code's helpers

extension VFXProgram {
    /// MSL vfxCurve: the curve whose keys start at params[k].
    static func curve(_ p: [SIMD4<Float>], _ k: Int, _ t: Float) -> Float {
        let n = Int(p[k].x)
        guard n > 0 else { return 0 }
        let first = p[k + 1], last = p[k + n]
        if t <= first.x { return first.y }
        if t >= last.x { return last.y }
        for j in 2...max(n, 2) where j <= n {
            let b = p[k + j]
            if t <= b.x {
                let a = p[k + j - 1]
                var u = (t - a.x) / max(b.x - a.x, 1e-6)
                if p[k].y > 0 { u = u * u * (3 - 2 * u) }
                return a.y + (b.y - a.y) * u
            }
        }
        return last.y
    }

    /// MSL vfxGradient.
    static func gradient(_ p: [SIMD4<Float>], _ k: Int, _ t: Float) -> SIMD4<Float> {
        let n = Int(p[k].x)
        guard n > 0 else { return .zero }
        if t <= p[k + 1].x { return p[k + 2] }
        if t >= p[k + 2 * n - 1].x { return p[k + 2 * n] }
        for j in 1..<n {
            let tb = p[k + 1 + 2 * j].x
            if t <= tb {
                let ta = p[k + 1 + 2 * (j - 1)].x
                let u = (t - ta) / max(tb - ta, 1e-6)
                let a = p[k + 2 * j], b = p[k + 2 + 2 * j]
                return a + (b - a) * u
            }
        }
        return p[k + 2 * n]
    }

    /// The integral of a rate curve over its emitter's first `steps` steps from its start (MSL vfxRateIntegral): its
    /// keys over `span` steps (params[k].z), its last key's value past them; a negative value counts as none.
    static func rateIntegral(_ p: [SIMD4<Float>], _ k: Int, _ steps: Float) -> Float {
        let n = Int(p[k].x), span = max(p[k].z, 1e-6), smooth = p[k].y > 0
        guard n > 0 else { return steps }
        let tau = min(steps / span, 1)
        var sum: Float = 0
        let first = p[k + 1], last = p[k + n]
        sum += max(first.y, 0) * min(tau, first.x)
        if n > 1 {
            for j in 1..<n {
                let a = p[k + j], b = p[k + j + 1]
                guard tau > a.x else { break }
                let width = max(b.x - a.x, 1e-6), w = min((tau - a.x) / width, 1)
                let ya = max(a.y, 0), yb = max(b.y, 0)
                let h = smooth ? w * w * w - w * w * w * w / 2 : w * w / 2
                sum += width * (ya * w + (yb - ya) * h)
            }
        }
        if tau > last.x { sum += max(last.y, 0) * (tau - last.x) }
        return sum * span + max(steps - span, 0) * max(last.y, 0)
    }
}

extension ParticleMath {
    /// MSL particleRandom: a number of particle `seed`'s that stays the same over its life (`k`: which).
    static func random(_ seed: UInt32, _ k: UInt32) -> Float {
        Float(hash(seed ^ (k &* 0x9E3779B9 &+ 0x85EBCA6B))) * (1.0 / 4294967296.0)
    }
}
