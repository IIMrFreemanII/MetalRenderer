import Characters
import EngineCore
import Foundation
import Physics
import Plants
import simd

/// A particle effect as a graph (the VFX editor's): its emitters, each four contexts of blocks run in order (Spawn,
/// Initialize, Update, Output), and operator nodes wired into the blocks' pins (`links`). A scene places effects
/// (Scene.addEffect), and one ParticleSystem runs every placed effect's emitters:
/// - an emitter whose blocks and pins all fit the fixed emitter (ParticleEmitter) is lowered to one (VFXLowering) and
///   runs the hand-written kernels (Shaders/ParticleSim.metal): the built-in effects, bit for bit as before;
/// - one that doesn't (a wired pin, a curve or gradient of other keys, an attribute, a condition) gets generated code
///   (VFXProgram, compiled into a library of its own by VFXCompiler) for what the fixed one can't do.
/// The catalogue of blocks and operators is VFXNodes.swift; saved as Assets/Effects/<name>.vfx.json (VFXStore), or
/// as Swift (VFXBuilder.swift).
package struct VFXEffect: Codable, Equatable {
    package static let format = 1
    package var name: String
    /// The point it is made about (a fire's, a wheel's rim): the VFX stage centres it there.
    package var origin = SIMD3<Float>.zero
    package var emitters: [VFXEmitter] = []
    /// Operator nodes, wired into blocks' pins and each other's by `links`.
    package var nodes: [VFXNode] = []
    package var links: [VFXLink] = []
    /// Vector fields its emitters move in (the Field block names one), in its own space.
    package var fields: [VFXField] = []
    /// Shapes its particles bounce off (the Collide block names them), in its own space. The scene's own colliders
    /// (Scene.addParticleCollider: a floor, a crate, a bowl) are named the same way.
    package var colliders: [VFXCollider] = []

    package init(_ name: String, origin: SIMD3<Float> = .zero, emitters: [VFXEmitter] = [], nodes: [VFXNode] = [], links: [VFXLink] = [],
         fields: [VFXField] = [], colliders: [VFXCollider] = []) {
        self.name = name
        self.origin = origin
        self.emitters = emitters
        self.nodes = nodes
        self.links = links
        self.fields = fields
        self.colliders = colliders
        normalizeIDs()
    }

    package func emitter(_ id: String) -> VFXEmitter? { emitters.first { $0.id == id } }
    package func node(_ id: String) -> VFXNode? { nodes.first { $0.id == id } }

    /// The block with this id, and its emitter's index.
    package func block(_ id: String) -> (emitter: Int, block: VFXBlock)? {
        for (i, e) in emitters.enumerated() {
            for c in VFXContext.allCases { if let b = e[c].first(where: { $0.id == id }) { return (i, b) } }
        }
        return nil
    }

    /// The link into pin `input` of node or block `id`, if one is wired there.
    package func link(into id: String, _ input: String) -> VFXLink? { links.first { $0.to == id && $0.input == input } }

    /// Every block and node an id (made from its emitter's and its kind: "flames.rate", "flames.gravity2"), and every
    /// emitter one (its name, or "e1"...): links name them.
    package mutating func normalizeIDs() {
        var used = Set<String>()
        for i in emitters.indices {
            if emitters[i].id.isEmpty || used.contains(emitters[i].id) {
                emitters[i].id = VFXEffect.unique(VFXEffect.slug(emitters[i].name), used)
            }
            used.insert(emitters[i].id)
        }
        for i in emitters.indices {
            for c in VFXContext.allCases {
                for k in emitters[i][c].indices where emitters[i][c][k].id.isEmpty || used.contains(emitters[i][c][k].id) {
                    emitters[i][c][k].id = VFXEffect.unique("\(emitters[i].id).\(emitters[i][c][k].kind.rawValue)", used)
                    used.insert(emitters[i][c][k].id)
                }
                for b in emitters[i][c] { used.insert(b.id) }
            }
        }
        for k in nodes.indices where nodes[k].id.isEmpty || used.contains(nodes[k].id) {
            nodes[k].id = VFXEffect.unique(nodes[k].kind.rawValue, used)
            used.insert(nodes[k].id)
        }
    }

    /// `base`, or base2, base3... whichever isn't in `used`.
    package static func unique(_ base: String, _ used: Set<String>) -> String {
        if !used.contains(base) && !base.isEmpty { return base }
        var n = 2
        while used.contains("\(base)\(n)") { n += 1 }
        return "\(base)\(n)"
    }

    /// A name as an id: lower case, words joined by "-".
    package static func slug(_ name: String) -> String {
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.isEmpty ? "e" : words.joined(separator: "-")
    }
}

/// One of an effect's emitters: a pool of `capacity` particles, and what its four contexts do to them.
package struct VFXEmitter: Codable, Equatable, Identifiable {
    package var id = ""
    package var name: String
    package var capacity: Int
    /// What its particles' random numbers start from (ParticleEmitter.seed); nil: a hash of the effect's and its name,
    /// so it looks the same wherever it is placed.
    package var seed: UInt32?
    package var spawn: [VFXBlock] = []
    package var initialize: [VFXBlock] = []
    package var update: [VFXBlock] = []
    /// The renderer first (Billboard, Mesh, Trail or Distortion), then its look.
    package var output: [VFXBlock] = []
    /// Where the editor draws it.
    package var canvas = SIMD2<Float>.zero

    package init(_ name: String, capacity: Int, seed: UInt32? = nil, spawn: [VFXBlock] = [], initialize: [VFXBlock] = [],
         update: [VFXBlock] = [], output: [VFXBlock] = [], id: String = "") {
        self.id = id
        self.name = name
        self.capacity = capacity
        self.seed = seed
        self.spawn = spawn
        self.initialize = initialize
        self.update = update
        self.output = output
    }

    package subscript(_ c: VFXContext) -> [VFXBlock] {
        get {
            switch c {
            case .spawn: return spawn
            case .initialize: return initialize
            case .update: return update
            case .output: return output
            }
        }
        set {
            switch c {
            case .spawn: spawn = newValue
            case .initialize: initialize = newValue
            case .update: update = newValue
            case .output: output = newValue
            }
        }
    }

    /// Its first enabled block of `kind` (in any context).
    package func first(_ kind: VFXBlockKind) -> VFXBlock? {
        for c in VFXContext.allCases { if let b = self[c].first(where: { $0.kind == kind && $0.enabled }) { return b } }
        return nil
    }
    package func all(_ kind: VFXBlockKind, in c: VFXContext) -> [VFXBlock] { self[c].filter { $0.kind == kind && $0.enabled } }

    /// Its renderer (the Output context's first block, if it is one): what its particles are.
    package var renderer: VFXBlockKind { output.first { $0.enabled && $0.kind.isRenderer }?.kind ?? .billboard }
    /// The emitter whose events it spawns from (a Spawn context's Event block), if it is a child.
    package var parent: String? { first(.event)?.choice("parent") }
}

/// The contexts an emitter's blocks run in, in order: Spawn (how many are born a step), Initialize (each newborn),
/// Update (each particle each step), Output (what the rays meet, each frame).
package enum VFXContext: String, Codable, CaseIterable {
    case spawn, initialize, update, output
    package var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// A block in a context: a kind (VFXBlockKind) and its parameters, each a pin an operator can be wired into (if its
/// kind says so) or a value. A missing parameter is its kind's default.
package struct VFXBlock: Codable, Equatable, Identifiable {
    package var id = ""
    package var kind: VFXBlockKind
    package var params: [String: VFXParam] = [:]
    package var enabled = true

    package init(_ kind: VFXBlockKind, _ params: [String: VFXParam] = [:], id: String = "") {
        self.kind = kind
        self.params = params
        self.id = id
    }

    /// Parameter `name`, or its kind's default.
    package func param(_ name: String) -> VFXParam { params[name] ?? kind.spec.pin(name)?.value ?? .float(0) }
    package func float(_ name: String) -> Float { param(name).float }
    package func vec3(_ name: String) -> SIMD3<Float> { param(name).vec3 }
    package func color(_ name: String) -> SIMD4<Float> { param(name).color }
    package func bool(_ name: String) -> Bool { param(name).bool }
    package func int(_ name: String) -> Int { param(name).int }
    package func range(_ name: String) -> ClosedRange<Float> { param(name).range }
    package func choice(_ name: String) -> String { param(name).choice }
    package func names(_ name: String) -> [String] { param(name).names }
}

/// An operator node: a kind (VFXOpKind), the values of its unwired inputs, and where the editor draws it.
package struct VFXNode: Codable, Equatable, Identifiable {
    package var id = ""
    package var kind: VFXOpKind
    package var params: [String: VFXParam] = [:]
    package var canvas = SIMD2<Float>.zero

    package init(_ kind: VFXOpKind, _ params: [String: VFXParam] = [:], id: String = "", at canvas: SIMD2<Float> = .zero) {
        self.kind = kind
        self.params = params
        self.id = id
        self.canvas = canvas
    }

    package func param(_ name: String) -> VFXParam { params[name] ?? kind.spec.pin(name)?.value ?? .float(0) }
}

/// A wire: node `from`'s output `output` into pin `input` of node or block `to`.
package struct VFXLink: Codable, Equatable, Hashable {
    package var from: String
    package var output: String
    package var to: String
    package var input: String

    package init(_ from: String, _ output: String = "out", to: String, _ input: String) {
        self.from = from
        self.output = output
        self.to = to
        self.input = input
    }
}

/// A vector field in an effect's space (ParticleField's presets): `vortex` a dust devil's whirl, `plume` a fire's hot air.
package struct VFXField: Codable, Equatable {
    package enum Kind: String, Codable, CaseIterable { case vortex, plume }
    package var name: String
    package var kind: Kind
    package var center: SIMD3<Float>
    package var radius: Float
    package var height: Float
    package var swirl: Float = 0
    package var lift: Float

    /// The field, its centre at `center` placed by `place`.
    package func field(_ place: VFXPlacement) -> ParticleField {
        let c = place.point(center)
        switch kind {
        case .vortex: return .vortex(center: c, radius: radius, height: height, swirl: swirl, lift: lift)
        case .plume: return .plume(center: c, radius: radius, height: height, lift: lift)
        }
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(name: String, kind: Kind, center: SIMD3<Float>, radius: Float, height: Float, swirl: Float = 0, lift: Float) {
        self.name = name
        self.kind = kind
        self.center = center
        self.radius = radius
        self.height = height
        self.swirl = swirl
        self.lift = lift
    }
}

/// A collider in an effect's space.
package struct VFXCollider: Codable, Equatable {
    package enum Shape: Codable, Equatable {
        case plane(normal: SIMD3<Float>, point: SIMD3<Float>)
        case sphere(center: SIMD3<Float>, radius: Float)
        case box(center: SIMD3<Float>, halfExtents: SIMD3<Float>)
    }
    package var name: String
    package var shape: Shape

    package func collider(_ place: VFXPlacement) -> ParticleCollider {
        switch shape {
        case .plane(let n, let p): return .plane(normal: n, point: place.point(p))
        case .sphere(let c, let r): return .sphere(center: place.point(c), radius: r)
        case .box(let c, let h): return .box(center: place.point(c), halfExtents: h)
        }
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(name: String, shape: Shape) {
        self.name = name
        self.shape = shape
    }
}

/// Where a scene puts an effect: a translation (an effect isn't turned or scaled). Identity adds nothing, so an effect
/// written in the scene's space (the built-in ones) keeps its numbers bit for bit.
package struct VFXPlacement: Codable, Equatable {
    var offset = SIMD3<Float>.zero
    static let identity = VFXPlacement()
    func point(_ p: SIMD3<Float>) -> SIMD3<Float> { offset == .zero ? p : offset + p }
}

// MARK: - Values

/// A parameter's value.
package enum VFXParam: Equatable {
    case float(Float)
    case vec3(SIMD3<Float>)
    case color(SIMD4<Float>)
    case bool(Bool)
    case int(Int)
    /// A random value between, per particle.
    case range(Float, Float)
    /// One of a list (a shape, an atlas, an emitter's id, a field's name).
    case choice(String)
    /// Some of a list (colliders).
    case names([String])
    case curve(VFXCurve)
    case gradient(VFXGradient)

    package var float: Float {
        switch self {
        case .float(let f): return f
        case .int(let i): return Float(i)
        case .bool(let b): return b ? 1 : 0
        case .range(let a, _): return a
        case .vec3(let v): return v.x
        case .color(let c): return c.x
        default: return 0
        }
    }
    package var vec3: SIMD3<Float> {
        switch self {
        case .vec3(let v): return v
        case .color(let c): return SIMD3(c.x, c.y, c.z)
        case .float(let f): return SIMD3(repeating: f)
        default: return .zero
        }
    }
    package var color: SIMD4<Float> {
        switch self {
        case .color(let c): return c
        case .vec3(let v): return SIMD4(v, 1)
        case .float(let f): return SIMD4(repeating: f)
        default: return .zero
        }
    }
    package var bool: Bool {
        switch self {
        case .bool(let b): return b
        case .float(let f): return f != 0
        case .int(let i): return i != 0
        default: return false
        }
    }
    package var int: Int {
        switch self {
        case .int(let i): return i
        case .float(let f): return Int(f)
        case .bool(let b): return b ? 1 : 0
        default: return 0
        }
    }
    package var range: ClosedRange<Float> {
        switch self {
        case .range(let a, let b): return min(a, b)...max(a, b)
        case .float(let f): return f...f
        default: return 0...0
        }
    }
    package var choice: String { if case .choice(let s) = self { return s }; return "" }
    package var names: [String] { if case .names(let n) = self { return n }; return [] }
    package var curve: VFXCurve { if case .curve(let c) = self { return c }; return VFXCurve(constant: float) }
    package var gradient: VFXGradient { if case .gradient(let g) = self { return g }; return VFXGradient(constant: color) }
}

/// A curve over 0...1: keys (t, value), t rising, straight (or smooth: Hermite with flat ends at the keys) between;
/// flat past its ends. Up to `maxKeys`.
package struct VFXCurve: Codable, Equatable {
    package static let maxKeys = 8
    package var keys: [SIMD2<Float>]
    package var smooth = false

    package init(_ keys: [SIMD2<Float>], smooth: Bool = false) {
        self.keys = keys
        self.smooth = smooth
    }
    package init(constant v: Float) { keys = [SIMD2(0, v), SIMD2(1, v)] }
    /// From `a` at 0 to `b` at 1.
    package init(from a: Float, to b: Float) { keys = [SIMD2(0, a), SIMD2(1, b)] }

    /// Its value at t (VFXCodegen's vfxCurve, line for line).
    package func value(_ t: Float) -> Float {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if t <= first.x { return first.y }
        if t >= last.x { return last.y }
        for k in 1..<keys.count where t <= keys[k].x {
            let a = keys[k - 1], b = keys[k]
            var u = (t - a.x) / max(b.x - a.x, 1e-6)
            if smooth { u = u * u * (3 - 2 * u) }
            return a.y + (b.y - a.y) * u
        }
        return last.y
    }
    package var range: ClosedRange<Float> { (keys.map(\.y).min() ?? 0)...(keys.map(\.y).max() ?? 0) }
}

/// A gradient over 0...1: colour keys, t rising, straight between; flat past its ends. Up to `maxKeys`.
package struct VFXGradient: Codable, Equatable {
    package static let maxKeys = 8
    package struct Key: Codable, Equatable {
        package var t: Float
        package var color: SIMD4<Float>
        package init(_ t: Float, _ color: SIMD4<Float>) { self.t = t; self.color = color }
    }
    package var keys: [Key]

    package init(_ keys: [Key]) { self.keys = keys }
    package init(constant c: SIMD4<Float>) { keys = [Key(0, c), Key(1, c)] }
    /// ParticleEmitter's three keys: at birth, at `midpoint` of its life, at death.
    package init(_ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, midpoint: Float = 0.5) {
        keys = [Key(0, c0), Key(midpoint, c1), Key(1, c2)]
    }

    package func value(_ t: Float) -> SIMD4<Float> {
        guard let first = keys.first, let last = keys.last else { return .zero }
        if t <= first.t { return first.color }
        if t >= last.t { return last.color }
        for k in 1..<keys.count where t <= keys[k].t {
            let a = keys[k - 1], b = keys[k]
            let u = (t - a.t) / max(b.t - a.t, 1e-6)
            return a.color + (b.color - a.color) * u
        }
        return last.color
    }
    /// ParticleEmitter's three keys, if it is that: 3 keys, the first at 0, the last at 1.
    package var threeKeys: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, midpoint: Float)? {
        guard keys.count == 3, keys[0].t == 0, keys[2].t == 1 else { return nil }
        return (keys[0].color, keys[1].color, keys[2].color, keys[1].t)
    }
}

// The JSON: a value is an object of one key, its kind ({"float": 1.5}, {"range": [0.3, 0.7]}, {"choice": "disc"}).
extension VFXParam: Codable {
    private enum Key: String, CodingKey { case float, vec3, color, bool, int, range, choice, names, curve, gradient }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "an empty value"))
        }
        switch key {
        case .float: self = .float(try c.decode(Float.self, forKey: key))
        case .vec3: self = .vec3(try c.decode(SIMD3<Float>.self, forKey: key))
        case .color: self = .color(try c.decode(SIMD4<Float>.self, forKey: key))
        case .bool: self = .bool(try c.decode(Bool.self, forKey: key))
        case .int: self = .int(try c.decode(Int.self, forKey: key))
        case .range:
            let r = try c.decode([Float].self, forKey: key)
            guard r.count == 2 else { throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "a range is two numbers") }
            self = .range(r[0], r[1])
        case .choice: self = .choice(try c.decode(String.self, forKey: key))
        case .names: self = .names(try c.decode([String].self, forKey: key))
        case .curve: self = .curve(try c.decode(VFXCurve.self, forKey: key))
        case .gradient: self = .gradient(try c.decode(VFXGradient.self, forKey: key))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .float(let v): try c.encode(v, forKey: .float)
        case .vec3(let v): try c.encode(v, forKey: .vec3)
        case .color(let v): try c.encode(v, forKey: .color)
        case .bool(let v): try c.encode(v, forKey: .bool)
        case .int(let v): try c.encode(v, forKey: .int)
        case .range(let a, let b): try c.encode([a, b], forKey: .range)
        case .choice(let v): try c.encode(v, forKey: .choice)
        case .names(let v): try c.encode(v, forKey: .names)
        case .curve(let v): try c.encode(v, forKey: .curve)
        case .gradient(let v): try c.encode(v, forKey: .gradient)
        }
    }
}
