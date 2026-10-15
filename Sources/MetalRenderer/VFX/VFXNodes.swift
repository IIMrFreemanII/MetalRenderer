import Foundation
import simd

/// What a wire carries.
enum VFXType: String, Codable, CaseIterable {
    case float, vec3, color, bool
    /// The wider of two (a float meets a vec3 as three of it).
    static func wider(_ a: VFXType, _ b: VFXType) -> VFXType {
        let order: [VFXType] = [.bool, .float, .vec3, .color]
        return order[max(order.firstIndex(of: a)!, order.firstIndex(of: b)!)]
    }
}

/// A block's or a node's input: its name (the key of `params`), its title, its default, and what can be wired into it
/// (nil: a value only). A generic one (`generic`) takes whatever is wired, the node's outputs following it.
struct VFXPinSpec {
    let name: String
    let title: String
    let value: VFXParam
    var wire: VFXType?
    var generic = false
    /// A slider's span (the editor's), and the choices of a choice.
    var span: ClosedRange<Float>?
    var choices: [String] = []

    init(_ name: String, _ title: String, _ value: VFXParam, wire: VFXType? = nil, generic: Bool = false,
         span: ClosedRange<Float>? = nil, choices: [String] = []) {
        self.name = name
        self.title = title
        self.value = value
        self.wire = wire
        self.generic = generic
        self.span = span
        self.choices = choices
    }
}

struct VFXBlockSpec {
    let title: String
    let contexts: [VFXContext]
    let pins: [VFXPinSpec]
    /// At most one of it in an emitter (the fixed emitter's: a Gravity, a Drag...); the others (Force, Set Attribute,
    /// Kill, Trigger) may repeat and need generated code.
    var unique = true
    let summary: String
    func pin(_ name: String) -> VFXPinSpec? { pins.first { $0.name == name } }
}

/// The blocks, by context. Their names are the JSON's and the Swift builder's (VFXBuilder.swift).
enum VFXBlockKind: String, Codable, CaseIterable {
    // Spawn
    case rate, burst, event
    // Initialize
    case shape, velocity, lifetime, setPosition, setVelocity
    // Update
    case gravity, drag, curl, field, vortex, force, collide, kill, trigger
    // Initialize and Update
    case setAttribute
    // Output: the renderer, then the look
    case billboard, mesh, trail, distortion, size, color, flipbook, orient, lighting

    var isRenderer: Bool { [.billboard, .mesh, .trail, .distortion].contains(self) }

    static let shapes = ["point", "sphere", "sphere surface", "disc", "box", "ring"]
    static let orientations = ["ray facing", "velocity", "axis", "world"]
    static let triggers = ["death", "collision", "condition"]
    static let attributes = ["A", "B", "C", "D"]

    var spec: VFXBlockSpec {
        typealias P = VFXPinSpec
        switch self {
        case .rate:
            return VFXBlockSpec(title: "Rate", contexts: [.spawn], pins: [
                P("rate", "Rate (/s)", .float(10), span: 0...1000),
                P("start", "Start (s)", .float(0), span: 0...10),
                P("stop", "Stop (s)", .float(.greatestFiniteMagnitude), span: 0...60),
                P("overTime", "Rate over time", .curve(VFXCurve(constant: 1))),
                P("span", "Curve's span (s)", .float(1), span: 0.1...30),
            ], summary: "Particles a second from Start to Stop; the curve scales it over its span of the emitter's time.")
        case .burst:
            return VFXBlockSpec(title: "Burst", contexts: [.spawn], pins: [
                P("time", "At (s)", .float(0), span: 0...10),
                P("count", "Count", .int(10), span: 1...1000),
                P("period", "Every (s, 0: once)", .float(0), span: 0...10),
                P("repeats", "Bursts (0: no end)", .int(0), span: 0...100),
            ], summary: "Count at once, then every period.")
        case .event:
            return VFXBlockSpec(title: "Spawn on Event", contexts: [.spawn], pins: [
                P("parent", "Parent", .choice("")),
                P("on", "On", .choice("death"), choices: VFXBlockKind.triggers),
                P("count", "Per event", .int(1), span: 1...8),
            ], summary: "A child: born where its parent's particles die, collide, or meet a Trigger's condition.")
        case .shape:
            return VFXBlockSpec(title: "Spawn Shape", contexts: [.initialize], pins: [
                P("shape", "Shape", .choice("point"), choices: VFXBlockKind.shapes),
                P("position", "Position", .vec3(.zero)),
                P("direction", "Axis", .vec3([0, 1, 0])),
                P("radius", "Radius", .float(0.1), span: 0...5),
                P("halfExtents", "Half extents", .vec3([0.5, 0.5, 0.5])),
            ], summary: "Where newborns appear about the emitter's position, and the axis their velocity spreads about.")
        case .velocity:
            return VFXBlockSpec(title: "Velocity", contexts: [.initialize], pins: [
                P("speed", "Speed (m/s)", .range(0, 0), span: 0...20),
                P("spread", "Spread (rad)", .float(0), span: 0...3.1416),
                P("radial", "Outward", .bool(false)),
                P("add", "Added", .vec3(.zero)),
                P("inherit", "Parent's share", .float(0), span: 0...1),
            ], summary: "A speed along the axis (within Spread of it) or outward from the emitter, plus a velocity of its own.")
        case .lifetime:
            return VFXBlockSpec(title: "Lifetime", contexts: [.initialize], pins: [
                P("lifetime", "Lifetime (s)", .range(1, 1), wire: .float, span: 0.01...20),
                P("max", "Longest (s, wired)", .float(1), span: 0.01...60),
            ], summary: "How long each lives. Wired, no longer than Longest (the structures are sized by it).")
        case .setPosition:
            return VFXBlockSpec(title: "Set Position", contexts: [.initialize], pins: [
                P("value", "Offset", .vec3(.zero), wire: .vec3),
            ], unique: false, summary: "Where it is born, from the emitter's position (instead of the shape's).")
        case .setVelocity:
            return VFXBlockSpec(title: "Set Velocity", contexts: [.initialize, .update], pins: [
                P("value", "Velocity", .vec3(.zero), wire: .vec3),
            ], unique: false, summary: "Its velocity: at birth, or each step before it moves.")
        case .gravity:
            return VFXBlockSpec(title: "Gravity", contexts: [.update], pins: [
                P("share", "Share", .float(1), wire: .float, span: -2...2),
            ], summary: "The scene's gravity times Share (negative: it rises, as hot smoke does).")
        case .drag:
            return VFXBlockSpec(title: "Drag", contexts: [.update], pins: [
                P("drag", "Drag (1/s)", .float(1), wire: .float, span: 0...10),
                P("wind", "Wind's share", .float(0), wire: .float, span: 0...2),
            ], summary: "It takes the air's velocity (the wind's share of the scene's) at Drag.")
        case .curl:
            return VFXBlockSpec(title: "Curl Noise", contexts: [.update], pins: [
                P("strength", "Strength (m/s²)", .float(1), wire: .float, span: 0...10),
                P("frequency", "Frequency (1/m)", .float(1), span: 0.05...10),
                P("speed", "Scroll (1/s)", .float(0), span: 0...5),
                P("baked", "From the baked tile", .bool(false)),
            ], summary: "A divergence-free swirl. Baked: the same from a tile, for a fraction of the arithmetic.")
        case .field:
            return VFXBlockSpec(title: "Vector Field", contexts: [.update], pins: [
                P("field", "Field", .choice("")),
                P("strength", "Strength", .float(1), wire: .float, span: 0...5),
                P("follow", "Follow (a velocity)", .bool(false)),
            ], summary: "A field of the effect's: a push (times Strength), or the air's velocity it takes at Strength.")
        case .vortex:
            return VFXBlockSpec(title: "Vortex", contexts: [.update], pins: [
                P("swirl", "Swirl (m/s²)", .float(1), wire: .float, span: 0...10),
                P("attraction", "Pull (m/s²)", .float(0), wire: .float, span: 0...10),
                P("atEmitter", "About the emitter", .bool(true)),
                P("center", "Centre", .vec3(.zero)),
            ], summary: "A spin about the shape's axis through the centre, and a pull toward it.")
        case .force:
            return VFXBlockSpec(title: "Force", contexts: [.update], pins: [
                P("force", "Force (m/s²)", .vec3(.zero), wire: .vec3),
            ], unique: false, summary: "An acceleration of your own.")
        case .collide:
            return VFXBlockSpec(title: "Collide", contexts: [.update], pins: [
                P("colliders", "Colliders", .names([])),
                P("scene", "The scene's geometry", .bool(false)),
                P("restitution", "Bounce", .float(0.3), span: 0...1),
                P("friction", "Friction", .float(0.2), span: 0...1),
                P("radius", "Radius (m)", .float(0), span: 0...0.5),
                P("kill", "Dies on contact", .bool(false)),
            ], summary: "Bounces off the named colliders (the effect's and the scene's), and the scene's geometry by a ray a step.")
        case .kill:
            return VFXBlockSpec(title: "Kill", contexts: [.update], pins: [
                P("when", "When", .bool(false), wire: .bool),
            ], unique: false, summary: "It dies where the condition holds (its children's event, if they spawn on death).")
        case .trigger:
            return VFXBlockSpec(title: "Trigger Event", contexts: [.update], pins: [
                P("when", "When", .bool(false), wire: .bool),
            ], unique: false, summary: "An event for the children that spawn on a condition, each step it holds.")
        case .setAttribute:
            return VFXBlockSpec(title: "Set Attribute", contexts: [.initialize, .update], pins: [
                P("attribute", "Attribute", .choice("A"), choices: VFXBlockKind.attributes),
                P("value", "Value", .color(.zero), wire: .color),
            ], unique: false, summary: "A value the particle keeps (four numbers), for Get Attribute to read.")
        case .billboard:
            return VFXBlockSpec(title: "Billboard", contexts: [.output], pins: [],
                                summary: "A quad the rays meet: lit, or glowing.")
        case .mesh:
            return VFXBlockSpec(title: "Mesh", contexts: [.output], pins: [
                P("mesh", "Mesh", .choice("rock")),
                P("material", "Material", .choice("stone")),
            ], summary: "Real geometry in the scene's structure (shadows, reflections, GI): the scene binds the names.")
        case .trail:
            return VFXBlockSpec(title: "Trail", contexts: [.output], pins: [
                P("points", "Places", .int(16), span: 3...32),
                P("every", "Steps apart", .int(2), span: 1...8),
                P("width", "Width (of the size)", .float(1), span: 0...4),
            ], summary: "A billboard with a ribbon behind it, through its last places.")
        case .distortion:
            return VFXBlockSpec(title: "Distortion", contexts: [.output], pins: [
                P("amount", "Bend (rad)", .float(0.0025), span: 0...0.02),
            ], summary: "Never drawn: bends the view through it (heat haze), as much as its colour's alpha.")
        case .size:
            return VFXBlockSpec(title: "Size", contexts: [.output], pins: [
                P("size", "Size over life (m)", .curve(VFXCurve(from: 0.05, to: 0.05)), wire: .float),
                P("jitter", "Random shrink", .float(0), span: 0...1),
            ], summary: "Its radius over its life, each particle smaller by up to the jitter.")
        case .color:
            return VFXBlockSpec(title: "Color", contexts: [.output], pins: [
                P("color", "Colour over life", .gradient(VFXGradient([1, 1, 1, 1], [1, 1, 1, 1], [1, 1, 1, 0])), wire: .color),
                P("emission", "Emission (0: lit)", .float(0), span: 0...100),
            ], summary: "Its colour and opacity over its life; glowing (unlit) times Emission, or lit by the scene.")
        case .flipbook:
            return VFXBlockSpec(title: "Flipbook", contexts: [.output], pins: [
                P("atlas", "Atlas", .choice("dot"), choices: ParticleTextures.Kind.allCases.map(\.name)),
                P("frames", "Frames", .int(1), span: 1...64),
                P("fps", "Frames a second (0: over its life)", .float(0), span: 0...60),
                P("random", "Random first frame", .bool(false)),
                P("blend", "Blend frames", .bool(true)),
            ], summary: "Its picture: an atlas's frames played over its life or at a rate.")
        case .orient:
            return VFXBlockSpec(title: "Orientation", contexts: [.output], pins: [
                P("mode", "Faces", .choice("ray facing"), choices: VFXBlockKind.orientations),
                P("stretch", "Stretch (velocity, s)", .float(0), span: 0...0.2),
                P("axis", "Axis / normal", .vec3([0, 1, 0])),
                P("spin", "Spin (rad/s)", .float(0), span: 0...20),
            ], summary: "Square to each ray, along its velocity, turning only about an axis, or fixed in the world.")
        case .lighting:
            return VFXBlockSpec(title: "Lighting", contexts: [.output], pins: [
                P("soft", "Soft (m)", .float(0.1), span: 0...1),
                P("shadows", "Casts shadows", .bool(true)),
                P("shadowDensity", "Shadow density", .float(1), span: 0...1),
            ], summary: "How it fades into what is behind it, and the shadows it casts.")
        }
    }
}

/// The operators' families (the editor colours their headers by them).
enum VFXFamily: String, CaseIterable {
    case input = "Inputs", value = "Values", math = "Math", vector = "Vector", logic = "Logic", curve = "Curves",
         noise = "Noise", attribute = "Attributes"
}

struct VFXOpSpec {
    let title: String
    let family: VFXFamily
    let inputs: [VFXPinSpec]
    /// Its outputs: a fixed type, or nil: its generic inputs' widest.
    let outputs: [(name: String, type: VFXType?)]
    func pin(_ name: String) -> VFXPinSpec? { inputs.first { $0.name == name } }
}

/// The operators. Their code is VFXProgram's (Metal and the CPU's, side by side).
enum VFXOpKind: String, Codable, CaseIterable {
    // Inputs: the particle and the clock.
    case age, ageOverLife, lifetime, position, velocity, speed, particleID, random, time, deltaTime, emitterPosition
    // Values
    case float, vector, colorValue
    // Math (generic: floats, vectors or colours)
    case add, subtract, multiply, divide, minimum, maximum, lerp, clamp, abs, negate, oneMinus, saturate, floor, fract,
         sqrt, sin, cos, power, remap, step, smoothstep
    // Vector
    case makeVector, splitVector, makeColor, splitColor, length, normalize, dot, cross, distance
    // Logic
    case compare, select, and, or, not
    // Curves
    case curve, gradient
    // Noise and fields
    case noise, curlNoise, sampleField
    // Attributes
    case getAttribute

    var spec: VFXOpSpec {
        typealias P = VFXPinSpec
        func a(_ name: String = "a", _ v: Float = 0) -> P { P(name, name, .float(v), wire: .float, generic: true) }
        func f(_ name: String, _ title: String, _ v: Float = 0) -> P { P(name, title, .float(v), wire: .float) }
        func v3(_ name: String, _ title: String, _ v: SIMD3<Float> = .zero) -> P { P(name, title, .vec3(v), wire: .vec3) }
        func input(_ title: String, _ t: VFXType) -> VFXOpSpec { VFXOpSpec(title: title, family: .input, inputs: [], outputs: [("out", t)]) }
        func unary(_ title: String) -> VFXOpSpec { VFXOpSpec(title: title, family: .math, inputs: [a()], outputs: [("out", nil)]) }
        func binary(_ title: String, _ b: Float = 0) -> VFXOpSpec {
            VFXOpSpec(title: title, family: .math, inputs: [a(), a("b", b)], outputs: [("out", nil)])
        }
        switch self {
        case .age: return input("Age (s)", .float)
        case .ageOverLife: return input("Age / Life", .float)
        case .lifetime: return input("Lifetime (s)", .float)
        case .position: return input("Position", .vec3)
        case .velocity: return input("Velocity", .vec3)
        case .speed: return input("Speed", .float)
        case .particleID: return input("Particle ID", .float)
        case .random:
            return VFXOpSpec(title: "Random 0..1", family: .input, inputs: [P("salt", "Which", .int(0), span: 0...15)],
                             outputs: [("out", .float)])
        case .time: return input("Time (s)", .float)
        case .deltaTime: return input("Step (s)", .float)
        case .emitterPosition: return input("Emitter Position", .vec3)
        case .float: return VFXOpSpec(title: "Float", family: .value, inputs: [P("value", "Value", .float(0))], outputs: [("out", .float)])
        case .vector: return VFXOpSpec(title: "Vector", family: .value, inputs: [P("value", "Value", .vec3(.zero))], outputs: [("out", .vec3)])
        case .colorValue:
            return VFXOpSpec(title: "Colour", family: .value, inputs: [P("value", "Value", .color([1, 1, 1, 1]))], outputs: [("out", .color)])
        case .add: return binary("Add")
        case .subtract: return binary("Subtract")
        case .multiply: return binary("Multiply", 1)
        case .divide: return binary("Divide", 1)
        case .minimum: return binary("Min")
        case .maximum: return binary("Max")
        case .lerp:
            return VFXOpSpec(title: "Lerp", family: .math, inputs: [a(), a("b", 1), f("t", "t")], outputs: [("out", nil)])
        case .clamp:
            return VFXOpSpec(title: "Clamp", family: .math, inputs: [a("x"), a("lo"), a("hi", 1)], outputs: [("out", nil)])
        case .abs: return unary("Abs")
        case .negate: return unary("Negate")
        case .oneMinus: return unary("One Minus")
        case .saturate: return unary("Saturate")
        case .floor: return unary("Floor")
        case .fract: return unary("Fraction")
        case .sqrt: return unary("Square Root")
        case .sin: return unary("Sin")
        case .cos: return unary("Cos")
        case .power:
            return VFXOpSpec(title: "Power", family: .math, inputs: [a(), f("e", "Exponent", 2)], outputs: [("out", nil)])
        case .remap:
            return VFXOpSpec(title: "Remap", family: .math, inputs: [
                f("x", "x"), f("inLo", "From low", 0), f("inHi", "From high", 1), f("outLo", "To low", 0), f("outHi", "To high", 1),
            ], outputs: [("out", .float)])
        case .step: return VFXOpSpec(title: "Step", family: .math, inputs: [f("edge", "Edge", 0.5), f("x", "x")], outputs: [("out", .float)])
        case .smoothstep:
            return VFXOpSpec(title: "Smoothstep", family: .math, inputs: [f("lo", "Low", 0), f("hi", "High", 1), f("x", "x")],
                             outputs: [("out", .float)])
        case .makeVector:
            return VFXOpSpec(title: "Make Vector", family: .vector, inputs: [f("x", "x"), f("y", "y"), f("z", "z")], outputs: [("out", .vec3)])
        case .splitVector:
            return VFXOpSpec(title: "Split Vector", family: .vector, inputs: [v3("v", "Vector")],
                             outputs: [("x", .float), ("y", .float), ("z", .float)])
        case .makeColor:
            return VFXOpSpec(title: "Make Colour", family: .vector, inputs: [v3("rgb", "RGB", [1, 1, 1]), f("a", "Alpha", 1)],
                             outputs: [("out", .color)])
        case .splitColor:
            return VFXOpSpec(title: "Split Colour", family: .vector, inputs: [P("c", "Colour", .color([1, 1, 1, 1]), wire: .color)],
                             outputs: [("rgb", .vec3), ("a", .float)])
        case .length: return VFXOpSpec(title: "Length", family: .vector, inputs: [v3("v", "Vector")], outputs: [("out", .float)])
        case .normalize: return VFXOpSpec(title: "Normalize", family: .vector, inputs: [v3("v", "Vector", [0, 1, 0])], outputs: [("out", .vec3)])
        case .dot: return VFXOpSpec(title: "Dot", family: .vector, inputs: [v3("a", "a"), v3("b", "b")], outputs: [("out", .float)])
        case .cross: return VFXOpSpec(title: "Cross", family: .vector, inputs: [v3("a", "a"), v3("b", "b")], outputs: [("out", .vec3)])
        case .distance:
            return VFXOpSpec(title: "Distance", family: .vector, inputs: [v3("a", "a"), v3("b", "b")], outputs: [("out", .float)])
        case .compare:
            return VFXOpSpec(title: "Compare", family: .logic, inputs: [
                f("a", "a"), f("b", "b"), P("op", "Test", .choice("<"), choices: ["<", "<=", ">", ">=", "==", "!="]),
            ], outputs: [("out", .bool)])
        case .select:
            return VFXOpSpec(title: "Select", family: .logic, inputs: [P("if", "If", .bool(false), wire: .bool), a("then"), a("else")],
                             outputs: [("out", nil)])
        case .and:
            return VFXOpSpec(title: "And", family: .logic, inputs: [P("a", "a", .bool(true), wire: .bool), P("b", "b", .bool(true), wire: .bool)],
                             outputs: [("out", .bool)])
        case .or:
            return VFXOpSpec(title: "Or", family: .logic, inputs: [P("a", "a", .bool(false), wire: .bool), P("b", "b", .bool(false), wire: .bool)],
                             outputs: [("out", .bool)])
        case .not: return VFXOpSpec(title: "Not", family: .logic, inputs: [P("a", "a", .bool(false), wire: .bool)], outputs: [("out", .bool)])
        case .curve:
            return VFXOpSpec(title: "Curve", family: .curve, inputs: [f("t", "t"), P("curve", "Curve", .curve(VFXCurve(from: 0, to: 1)))],
                             outputs: [("out", .float)])
        case .gradient:
            return VFXOpSpec(title: "Gradient", family: .curve, inputs: [
                f("t", "t"), P("gradient", "Gradient", .gradient(VFXGradient([1, 1, 1, 1], [1, 1, 1, 1], [1, 1, 1, 0]))),
            ], outputs: [("out", .color)])
        case .noise:
            return VFXOpSpec(title: "Noise", family: .noise, inputs: [v3("p", "Position"), f("frequency", "Frequency", 1), f("scroll", "Scroll (1/s)", 0)],
                             outputs: [("out", .float)])
        case .curlNoise:
            return VFXOpSpec(title: "Curl Noise", family: .noise, inputs: [v3("p", "Position"), f("frequency", "Frequency", 1), f("scroll", "Scroll (1/s)", 0)],
                             outputs: [("out", .vec3)])
        case .sampleField:
            return VFXOpSpec(title: "Sample Field", family: .noise, inputs: [v3("p", "Position"), P("field", "Field", .choice(""))],
                             outputs: [("out", .vec3)])
        case .getAttribute:
            return VFXOpSpec(title: "Get Attribute", family: .attribute,
                             inputs: [P("attribute", "Attribute", .choice("A"), choices: VFXBlockKind.attributes)], outputs: [("out", .color)])
        }
    }
}

extension ParticleTextures.Kind {
    /// The name the effects' JSON and the editor use.
    var name: String { "\(self)" }
    init?(name: String) {
        guard let k = ParticleTextures.Kind.allCases.first(where: { "\($0)" == name }) else { return nil }
        self = k
    }
}
