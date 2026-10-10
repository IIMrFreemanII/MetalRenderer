import Foundation
import simd

/// A procedural material as a graph (the Material Designer's, after Substance Designer): image nodes wired into each
/// other, each one an image of its own size and precision (MatEngine bakes them on the GPU, one compute pass a node,
/// only those whose inputs or values changed), ending in output nodes that name the renderer's channels (base colour,
/// normal, roughness, metallic, AO, height, opacity, emissive). A graph's outputs become a material's textures
/// (MaterialBake), live in the renderer as the graph is edited; or, for a graph of point-wise nodes only, Metal code
/// the shading runs (MatShaderCode). A graph can be another's node (a subgraph: its input and output nodes are the
/// node's pins, its exposed inputs the node's parameters).
///
/// The catalogue of nodes is MatNodes.swift; saved as Assets/Materials/<name>.mat.json (MaterialStore).
struct MaterialGraph: Codable, Equatable {
    static let format = 1
    var name: String
    /// The output size, log2 (8...12: 256 to 4096 pixels square): nodes inherit it, or a size relative to it.
    var size = 10
    /// The precision nodes inherit (auto: 16-bit grey, 8-bit colour).
    var bits = MatBits.inherit
    /// Mixed into every node's seed: a graph's variations.
    var seed = 0
    /// How the renderer uses the outputs (parallax depth, UV scale, cutoff...).
    var surface = MatSurface()
    var nodes: [MatNode] = []
    var links: [MatLink] = []
    /// The parameters it exposes (a node's parameter bound to one of them: MatNode.exposed); a subgraph node's own.
    var inputs: [MatGraphInput] = []

    init(_ name: String, size: Int = 10, nodes: [MatNode] = [], links: [MatLink] = [], inputs: [MatGraphInput] = []) {
        self.name = name
        self.size = size
        self.nodes = nodes
        self.links = links
        self.inputs = inputs
        normalizeIDs()
    }

    func node(_ id: String) -> MatNode? { nodes.first { $0.id == id } }
    func index(_ id: String) -> Int? { nodes.firstIndex { $0.id == id } }

    /// The link into pin `input` of node `id`, if one is wired there.
    func link(into id: String, _ input: String) -> MatLink? { links.first { $0.to == id && $0.input == input } }

    /// Every node an id (its kind's name, numbered: "blend", "blend2").
    mutating func normalizeIDs() {
        var used = Set<String>()
        for k in nodes.indices {
            if nodes[k].id.isEmpty || used.contains(nodes[k].id) { nodes[k].id = VFXEffect.unique(nodes[k].kind.rawValue, used) }
            used.insert(nodes[k].id)
        }
    }

    var allIDs: Set<String> { Set(nodes.map(\.id)) }

    /// The output nodes, by the channel they give the renderer.
    var channels: [MatChannel: String] {
        var out: [MatChannel: String] = [:]
        for n in nodes where n.kind == .output {
            if let c = MatChannel(rawValue: n.choice("usage")), out[c] == nil { out[c] = n.id }
        }
        return out
    }

    /// The nodes whose outputs reach node `id` (through any number of wires).
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

    /// The nodes downstream of `id` (it too).
    func downstream(of id: String) -> Set<String> {
        var found: Set<String> = [id], stack = [id]
        while let n = stack.popLast() {
            for l in links where l.from == n && !found.contains(l.to) {
                found.insert(l.to)
                stack.append(l.to)
            }
        }
        return found
    }
}

/// The renderer's channels a graph's output nodes name.
enum MatChannel: String, Codable, CaseIterable {
    case baseColor, normal, roughness, metallic, ambientOcclusion, height, opacity, emissive

    var title: String {
        switch self {
        case .baseColor: return "Base Colour"
        case .normal: return "Normal"
        case .roughness: return "Roughness"
        case .metallic: return "Metallic"
        case .ambientOcclusion: return "Ambient Occlusion"
        case .height: return "Height"
        case .opacity: return "Opacity"
        case .emissive: return "Emissive"
        }
    }

    /// What it carries: a colour (base colour, normal, emissive) or a grey.
    var type: MatType { self == .baseColor || self == .normal || self == .emissive ? .color : .grey }

    /// What it is without an output node: the material's own value.
    var fallback: SIMD4<Float> {
        switch self {
        case .baseColor: return [0.5, 0.5, 0.5, 1]
        case .normal: return [0.5, 0.5, 1, 1]
        case .roughness: return [0.5, 0.5, 0.5, 1]
        case .metallic: return [0, 0, 0, 1]
        case .ambientOcclusion, .opacity: return [1, 1, 1, 1]
        case .height: return [0.5, 0.5, 0.5, 1]
        case .emissive: return [0, 0, 0, 1]
        }
    }
}

/// How the renderer uses a graph's outputs.
struct MatSurface: Codable, Equatable {
    /// Parallax depth of the height (black to white), in the texture's tile (0: no parallax).
    var heightDepth: Float = 0.04
    /// How many times the texture repeats over the mesh's UVs (the workshop's meshes: a UV unit a metre).
    var uvScale: Float = 1
    /// Opacity below it is a hole.
    var alphaCutoff: Float = 0.5
    var aoStrength: Float = 1
    var normalStrength: Float = 1
    /// The emissive output's radiance at white (0: not emissive).
    var emissiveIntensity: Float = 4
    /// The normal output's convention: OpenGL (+Y up, the renderer's) or DirectX (green flipped).
    var normalDirectX = false
    /// The renderer computes it in the shading (MatShaderCode) rather than sampling its bake, when it can.
    var shaderMode = false
    /// Real displacement: the height moves the vertices of the meshes it is on (subdivided for it: Scene+Displacement),
    /// by this many metres from black to white (0: none; the height is then the parallax's). `displacementMid`: the
    /// height that stays where the surface is. `displacementDetail`: the longest edge left (metres).
    var displacement: Float = 0
    var displacementMid: Float = 0.5
    var displacementDetail: Float = 0.02

    /// How far a displaced vertex may move from the surface.
    var displacementReach: Float { displacement * max(displacementMid, 1 - displacementMid) }
    /// How far a displaced mesh's bounds are grown: room for its displacement to grow (an edit within it moves the
    /// vertices in place; past it, the scene is made again).
    var displacementRoom: Float { max(2 * displacementReach, 0.05) }
    /// The detail's choices (metres).
    static let displacementDetails: [Float] = [0.005, 0.01, 0.02, 0.04, 0.08]

    init() {}

    // Decoded field by field, each with its default: a file of an older version (fewer fields) still reads.
    private enum Key: String, CodingKey { case heightDepth, uvScale, alphaCutoff, aoStrength, normalStrength, emissiveIntensity, normalDirectX, shaderMode
        case displacement, displacementMid, displacementDetail }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let d = MatSurface()
        heightDepth = try c.decodeIfPresent(Float.self, forKey: .heightDepth) ?? d.heightDepth
        uvScale = try c.decodeIfPresent(Float.self, forKey: .uvScale) ?? d.uvScale
        alphaCutoff = try c.decodeIfPresent(Float.self, forKey: .alphaCutoff) ?? d.alphaCutoff
        aoStrength = try c.decodeIfPresent(Float.self, forKey: .aoStrength) ?? d.aoStrength
        normalStrength = try c.decodeIfPresent(Float.self, forKey: .normalStrength) ?? d.normalStrength
        emissiveIntensity = try c.decodeIfPresent(Float.self, forKey: .emissiveIntensity) ?? d.emissiveIntensity
        normalDirectX = try c.decodeIfPresent(Bool.self, forKey: .normalDirectX) ?? d.normalDirectX
        shaderMode = try c.decodeIfPresent(Bool.self, forKey: .shaderMode) ?? d.shaderMode
        displacement = try c.decodeIfPresent(Float.self, forKey: .displacement) ?? d.displacement
        displacementMid = try c.decodeIfPresent(Float.self, forKey: .displacementMid) ?? d.displacementMid
        displacementDetail = try c.decodeIfPresent(Float.self, forKey: .displacementDetail) ?? d.displacementDetail
    }
}

/// What a wire carries: a grey image (one channel) or a colour one (RGBA).
enum MatType: String, Codable, CaseIterable {
    case grey, color
}

/// A node's precision: inherited (the graph's; auto: 16-bit grey, 8-bit colour), 8-bit, 16-bit float, 32-bit float.
enum MatBits: String, Codable, CaseIterable {
    case inherit, b8 = "8", b16 = "16", b32 = "32f"

    var title: String {
        switch self {
        case .inherit: return "Inherit"
        case .b8: return "8-bit"
        case .b16: return "16-bit"
        case .b32: return "32-bit float"
        }
    }
}

/// A node's size: inherited (its first input's, else the graph's), relative to that (log2 steps: -1 is half), or its
/// own (log2).
enum MatSize: Codable, Equatable, Hashable {
    case inherit
    case relative(Int)
    case absolute(Int)

    private enum Key: String, CodingKey { case relative, absolute }
    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self), s == "inherit" { self = .inherit; return }
        let c = try decoder.container(keyedBy: Key.self)
        if let r = try c.decodeIfPresent(Int.self, forKey: .relative) { self = .relative(r) } else { self = .absolute(try c.decode(Int.self, forKey: .absolute)) }
    }
    func encode(to encoder: Encoder) throws {
        switch self {
        case .inherit:
            var c = encoder.singleValueContainer()
            try c.encode("inherit")
        case .relative(let r):
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(r, forKey: .relative)
        case .absolute(let a):
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(a, forKey: .absolute)
        }
    }
}

/// A node: its kind (MatOpKind), its parameters' values (the spec's defaults otherwise), where the editor draws it,
/// its size and precision, the parameters bound to the graph's exposed inputs, and a pixel processor's function.
struct MatNode: Codable, Equatable, Identifiable {
    var id = ""
    var kind: MatOpKind
    var params: [String: MatParam] = [:]
    var at = SIMD2<Float>.zero
    var size = MatSize.inherit
    var bits = MatBits.inherit
    /// Parameter name → the graph input that sets it.
    var exposed: [String: String] = [:]
    /// A pixel processor's per-pixel function (MatFunction).
    var function: MatFunction?

    init(_ kind: MatOpKind, _ params: [String: MatParam] = [:], id: String = "", at: SIMD2<Float> = .zero) {
        self.kind = kind
        self.params = params
        self.id = id
        self.at = at
        if kind == .pixelProcessor { function = MatFunction.passThrough }
    }

    func param(_ name: String) -> MatParam { params[name] ?? kind.spec.param(name)?.value ?? .float(0) }
    func float(_ name: String) -> Float { param(name).float }
    func int(_ name: String) -> Int { param(name).int }
    func bool(_ name: String) -> Bool { param(name).bool }
    func choice(_ name: String) -> String { param(name).choice }
    func text(_ name: String) -> String { param(name).text }

    private enum Key: String, CodingKey { case id, kind, params, at, size, bits, exposed, function }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try c.decode(MatOpKind.self, forKey: .kind)
        params = try c.decodeIfPresent([String: MatParam].self, forKey: .params) ?? [:]
        at = try c.decodeIfPresent(SIMD2<Float>.self, forKey: .at) ?? .zero
        size = try c.decodeIfPresent(MatSize.self, forKey: .size) ?? .inherit
        bits = try c.decodeIfPresent(MatBits.self, forKey: .bits) ?? .inherit
        exposed = try c.decodeIfPresent([String: String].self, forKey: .exposed) ?? [:]
        function = try c.decodeIfPresent(MatFunction.self, forKey: .function)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        if !params.isEmpty { try c.encode(params, forKey: .params) }
        try c.encode(at, forKey: .at)
        if size != .inherit { try c.encode(size, forKey: .size) }
        if bits != .inherit { try c.encode(bits, forKey: .bits) }
        if !exposed.isEmpty { try c.encode(exposed, forKey: .exposed) }
        try c.encodeIfPresent(function, forKey: .function)
    }
}

/// A wire: node `from`'s output `output` into pin `input` of node `to`.
struct MatLink: Codable, Equatable, Hashable {
    var from: String
    var output: String
    var to: String
    var input: String

    init(_ from: String, _ output: String = "out", to: String, _ input: String) {
        self.from = from
        self.output = output
        self.to = to
        self.input = input
    }
}

/// A parameter the graph exposes: its name (what nodes bind to, and a subgraph node's parameter), its title, default
/// and a slider's span.
struct MatGraphInput: Codable, Equatable {
    var name: String
    var title: String
    var value: MatParam
    var span: ClosedRange<Float>?

    init(_ name: String, _ title: String? = nil, _ value: MatParam, span: ClosedRange<Float>? = nil) {
        self.name = name
        self.title = title ?? name
        self.value = value
        self.span = span
    }
}

// MARK: - Values

/// A parameter's value.
enum MatParam: Equatable, Hashable {
    case float(Float)
    case vec2(SIMD2<Float>)
    case color(SIMD4<Float>)
    case bool(Bool)
    case int(Int)
    /// One of a list (a blend mode, a channel).
    case choice(String)
    /// A curve over 0...1 (Curve), a gradient (Gradient Map).
    case curve(VFXCurve)
    case gradient(VFXGradient)
    /// Text: a file's path (Bitmap), Metal code (Code), a name.
    case text(String)

    var float: Float {
        switch self {
        case .float(let f): return f
        case .int(let i): return Float(i)
        case .bool(let b): return b ? 1 : 0
        case .vec2(let v): return v.x
        case .color(let c): return c.x
        default: return 0
        }
    }
    var vec2: SIMD2<Float> {
        switch self {
        case .vec2(let v): return v
        case .float(let f): return SIMD2(repeating: f)
        case .color(let c): return SIMD2(c.x, c.y)
        default: return .zero
        }
    }
    var color: SIMD4<Float> {
        switch self {
        case .color(let c): return c
        case .float(let f): return SIMD4(f, f, f, 1)
        case .vec2(let v): return SIMD4(v.x, v.y, 0, 1)
        default: return SIMD4(0, 0, 0, 1)
        }
    }
    var bool: Bool {
        switch self {
        case .bool(let b): return b
        case .float(let f): return f != 0
        case .int(let i): return i != 0
        default: return false
        }
    }
    var int: Int {
        switch self {
        case .int(let i): return i
        case .float(let f): return Int(f.rounded())
        case .bool(let b): return b ? 1 : 0
        default: return 0
        }
    }
    var choice: String { if case .choice(let s) = self { return s }; return "" }
    var text: String {
        switch self {
        case .text(let s), .choice(let s): return s
        default: return ""
        }
    }
    var curve: VFXCurve { if case .curve(let c) = self { return c }; return VFXCurve(from: 0, to: 1) }
    var gradient: VFXGradient { if case .gradient(let g) = self { return g }; return VFXGradient([.init(0, [0, 0, 0, 1]), .init(1, [1, 1, 1, 1])]) }
}

extension VFXCurve: Hashable {
    func hash(into h: inout Hasher) {
        for k in keys { h.combine(k.x); h.combine(k.y) }
        h.combine(smooth)
    }
}

extension VFXGradient: Hashable {
    func hash(into h: inout Hasher) {
        for k in keys { h.combine(k.t); h.combine(k.color.x); h.combine(k.color.y); h.combine(k.color.z); h.combine(k.color.w) }
    }
}

// The JSON: a value is an object of one key, its kind ({"float": 1.5}, {"choice": "multiply"}).
extension MatParam: Codable {
    private enum Key: String, CodingKey { case float, vec2, color, bool, int, choice, curve, gradient, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "an empty value"))
        }
        switch key {
        case .float: self = .float(try c.decode(Float.self, forKey: key))
        case .vec2: self = .vec2(try c.decode(SIMD2<Float>.self, forKey: key))
        case .color: self = .color(try c.decode(SIMD4<Float>.self, forKey: key))
        case .bool: self = .bool(try c.decode(Bool.self, forKey: key))
        case .int: self = .int(try c.decode(Int.self, forKey: key))
        case .choice: self = .choice(try c.decode(String.self, forKey: key))
        case .curve: self = .curve(try c.decode(VFXCurve.self, forKey: key))
        case .gradient: self = .gradient(try c.decode(VFXGradient.self, forKey: key))
        case .text: self = .text(try c.decode(String.self, forKey: key))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .float(let v): try c.encode(v, forKey: .float)
        case .vec2(let v): try c.encode(v, forKey: .vec2)
        case .color(let v): try c.encode(v, forKey: .color)
        case .bool(let v): try c.encode(v, forKey: .bool)
        case .int(let v): try c.encode(v, forKey: .int)
        case .choice(let v): try c.encode(v, forKey: .choice)
        case .curve(let v): try c.encode(v, forKey: .curve)
        case .gradient(let v): try c.encode(v, forKey: .gradient)
        case .text(let v): try c.encode(v, forKey: .text)
        }
    }
}

/// A graph's error (a loop, a missing subgraph, a file of a newer format).
struct MatError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
