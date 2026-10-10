import Foundation
import simd

/// Effects in Swift: a block a call, its arguments its parameters (defaults: the catalogue's, VFXNodes.swift), as
/// the built-in effects (VFXLibrary.swift) are written and as the editor's Copy as Swift writes one (`swiftSource`):
///
///     VFXEffect("sparks", emitters: [
///         VFXEmitter("sparks", capacity: 600,
///                    spawn: [.rate(200)],
///                    initialize: [.shape("point"), .velocity(speed: 3...6, spread: 0.2), .lifetime(0.7...1.5)],
///                    update: [.gravity(1), .drag(0.3)],
///                    output: [.billboard(), .size(0.012, 0.006), .color(VFXGradient([1, 0.8, 0.5, 1], [1, 0.5, 0.1, 1], [0.9, 0.2, 0, 1])),
///                             .flipbook(.spark), .orient("velocity", stretch: 0.025)]),
///     ])
extension VFXBlock {
    // Spawn
    static func rate(_ rate: Float, start: Float = 0, stop: Float = .greatestFiniteMagnitude, overTime: VFXCurve? = nil,
                     span: Float = 1, id: String = "") -> VFXBlock {
        var p: [String: VFXParam] = ["rate": .float(rate), "start": .float(start), "stop": .float(stop), "span": .float(span)]
        if let overTime { p["overTime"] = .curve(overTime) }
        return VFXBlock(.rate, p, id: id)
    }
    static func burst(at time: Float, count: Int, every period: Float = 0, repeats: Int = 0, id: String = "") -> VFXBlock {
        VFXBlock(.burst, ["time": .float(time), "count": .int(count), "period": .float(period), "repeats": .int(repeats)], id: id)
    }
    /// A child: born where `parent`'s particles die ("death"), collide ("collision") or meet a Trigger ("condition").
    static func event(_ parent: String, on: String = "death", count: Int = 1, id: String = "") -> VFXBlock {
        VFXBlock(.event, ["parent": .choice(parent), "on": .choice(on), "count": .int(count)], id: id)
    }

    // Initialize
    static func shape(_ shape: String = "point", at position: SIMD3<Float> = .zero, axis: SIMD3<Float> = [0, 1, 0],
                      radius: Float = 0.1, halfExtents: SIMD3<Float> = [0.5, 0.5, 0.5], id: String = "") -> VFXBlock {
        VFXBlock(.shape, ["shape": .choice(shape), "position": .vec3(position), "direction": .vec3(axis), "radius": .float(radius),
                          "halfExtents": .vec3(halfExtents)], id: id)
    }
    static func velocity(speed: ClosedRange<Float> = 0...0, spread: Float = 0, radial: Bool = false, add: SIMD3<Float> = .zero,
                         inherit: Float = 0, id: String = "") -> VFXBlock {
        VFXBlock(.velocity, ["speed": .range(speed.lowerBound, speed.upperBound), "spread": .float(spread), "radial": .bool(radial),
                             "add": .vec3(add), "inherit": .float(inherit)], id: id)
    }
    /// `max`: the longest a wired lifetime may be.
    static func lifetime(_ lifetime: ClosedRange<Float>, max: Float = 1, id: String = "") -> VFXBlock {
        VFXBlock(.lifetime, ["lifetime": .range(lifetime.lowerBound, lifetime.upperBound), "max": .float(max)], id: id)
    }
    static func setPosition(_ value: SIMD3<Float> = .zero, id: String = "") -> VFXBlock { VFXBlock(.setPosition, ["value": .vec3(value)], id: id) }
    static func setVelocity(_ value: SIMD3<Float> = .zero, id: String = "") -> VFXBlock { VFXBlock(.setVelocity, ["value": .vec3(value)], id: id) }
    static func setAttribute(_ attribute: String, _ value: SIMD4<Float> = .zero, id: String = "") -> VFXBlock {
        VFXBlock(.setAttribute, ["attribute": .choice(attribute), "value": .color(value)], id: id)
    }

    // Update
    static func gravity(_ share: Float = 1, id: String = "") -> VFXBlock { VFXBlock(.gravity, ["share": .float(share)], id: id) }
    static func drag(_ drag: Float, wind: Float = 0, id: String = "") -> VFXBlock {
        VFXBlock(.drag, ["drag": .float(drag), "wind": .float(wind)], id: id)
    }
    static func curl(_ strength: Float, frequency: Float = 1, speed: Float = 0, baked: Bool = false, id: String = "") -> VFXBlock {
        VFXBlock(.curl, ["strength": .float(strength), "frequency": .float(frequency), "speed": .float(speed), "baked": .bool(baked)], id: id)
    }
    static func field(_ name: String, strength: Float = 1, follow: Bool = false, id: String = "") -> VFXBlock {
        VFXBlock(.field, ["field": .choice(name), "strength": .float(strength), "follow": .bool(follow)], id: id)
    }
    /// `center`: nil, the emitter's position.
    static func vortex(swirl: Float = 0, attraction: Float = 0, center: SIMD3<Float>? = nil, id: String = "") -> VFXBlock {
        VFXBlock(.vortex, ["swirl": .float(swirl), "attraction": .float(attraction), "atEmitter": .bool(center == nil),
                           "center": .vec3(center ?? .zero)], id: id)
    }
    static func force(_ force: SIMD3<Float> = .zero, id: String = "") -> VFXBlock { VFXBlock(.force, ["force": .vec3(force)], id: id) }
    static func collide(_ colliders: [String] = [], scene: Bool = false, restitution: Float = 0.3, friction: Float = 0.2,
                        radius: Float = 0, kill: Bool = false, id: String = "") -> VFXBlock {
        VFXBlock(.collide, ["colliders": .names(colliders), "scene": .bool(scene), "restitution": .float(restitution),
                            "friction": .float(friction), "radius": .float(radius), "kill": .bool(kill)], id: id)
    }
    static func kill(_ when: Bool = false, id: String = "") -> VFXBlock { VFXBlock(.kill, ["when": .bool(when)], id: id) }
    static func trigger(_ when: Bool = false, id: String = "") -> VFXBlock { VFXBlock(.trigger, ["when": .bool(when)], id: id) }

    // Output
    static func billboard(id: String = "") -> VFXBlock { VFXBlock(.billboard, id: id) }
    static func mesh(_ mesh: String, material: String, id: String = "") -> VFXBlock {
        VFXBlock(.mesh, ["mesh": .choice(mesh), "material": .choice(material)], id: id)
    }
    static func trail(points: Int = 16, every: Int = 2, width: Float = 1, id: String = "") -> VFXBlock {
        VFXBlock(.trail, ["points": .int(points), "every": .int(every), "width": .float(width)], id: id)
    }
    static func distortion(_ amount: Float, id: String = "") -> VFXBlock { VFXBlock(.distortion, ["amount": .float(amount)], id: id) }
    /// From `start` at birth to `end` at death.
    static func size(_ start: Float, _ end: Float, jitter: Float = 0, id: String = "") -> VFXBlock {
        size(curve: VFXCurve(from: start, to: end), jitter: jitter, id: id)
    }
    static func size(curve: VFXCurve, jitter: Float = 0, id: String = "") -> VFXBlock {
        VFXBlock(.size, ["size": .curve(curve), "jitter": .float(jitter)], id: id)
    }
    static func color(_ gradient: VFXGradient, emission: Float = 0, id: String = "") -> VFXBlock {
        VFXBlock(.color, ["color": .gradient(gradient), "emission": .float(emission)], id: id)
    }
    static func flipbook(_ atlas: ParticleTextures.Kind, frames: Int = 1, fps: Float = 0, random: Bool = false, blend: Bool = true,
                         id: String = "") -> VFXBlock {
        VFXBlock(.flipbook, ["atlas": .choice(atlas.name), "frames": .int(frames), "fps": .float(fps), "random": .bool(random),
                             "blend": .bool(blend)], id: id)
    }
    /// `mode`: "ray facing", "velocity" (stretched by `stretch`), "axis" or "world" (about or square to `axis`).
    static func orient(_ mode: String, stretch: Float = 0, axis: SIMD3<Float> = [0, 1, 0], spin: Float = 0, id: String = "") -> VFXBlock {
        VFXBlock(.orient, ["mode": .choice(mode), "stretch": .float(stretch), "axis": .vec3(axis), "spin": .float(spin)], id: id)
    }
    static func lighting(soft: Float = 0.1, shadows: Bool = true, shadowDensity: Float = 1, id: String = "") -> VFXBlock {
        VFXBlock(.lighting, ["soft": .float(soft), "shadows": .bool(shadows), "shadowDensity": .float(shadowDensity)], id: id)
    }
}

// MARK: - Copy as Swift

extension VFXEffect {
    /// The effect as Swift: the calls above, a block's arguments only where they aren't its kind's defaults, its id
    /// where a wire names it; the nodes and the wires after the emitters.
    var swiftSource: String {
        var s = "VFXEffect(\(Swift.quote(name)), emitters: [\n"
        let wiredIDs = Set(links.map(\.to))
        for e in emitters {
            s += "    VFXEmitter(\(Swift.quote(e.name)), capacity: \(e.capacity)"
            if let seed = e.seed { s += ", seed: \(seed)" }
            for c in VFXContext.allCases where !e[c].isEmpty {
                s += ",\n               \(c.rawValue): [" + e[c].map { b in
                    var call = Swift.call(b)
                    if wiredIDs.contains(b.id) || b.id != VFXEffect.unique("\(e.id).\(b.kind.rawValue)", []) {
                        call = call.hasSuffix("()") ? String(call.dropLast()) + "id: \(Swift.quote(b.id)))"
                            : String(call.dropLast()) + ", id: \(Swift.quote(b.id)))"
                    }
                    return b.enabled ? call : call + " /* disabled */"
                }.joined(separator: ", ") + "]"
            }
            if e.id != VFXEffect.slug(e.name) { s += ",\n               id: \(Swift.quote(e.id))" }
            s += "),\n"
        }
        s += "]"
        if !nodes.isEmpty {
            s += ", nodes: [\n" + nodes.map { n in
                let params = n.params.keys.sorted().map { "\(Swift.quote($0)): \(Swift.literal(n.params[$0]!))" }
                return "    VFXNode(.\(n.kind.rawValue)" + (params.isEmpty ? "" : ", [\(params.joined(separator: ", "))]")
                    + ", id: \(Swift.quote(n.id)), at: [\(Swift.number(n.canvas.x)), \(Swift.number(n.canvas.y))]),\n"
            }.joined() + "]"
        }
        if !links.isEmpty {
            s += ", links: [\n" + links.map {
                "    VFXLink(\(Swift.quote($0.from)), \(Swift.quote($0.output)), to: \(Swift.quote($0.to)), \(Swift.quote($0.input))),\n"
            }.joined() + "]"
        }
        if !fields.isEmpty {
            s += ", fields: [\n" + fields.map { f in
                "    VFXField(name: \(Swift.quote(f.name)), kind: .\(f.kind.rawValue), center: \(Swift.vector(f.center)), radius: \(Swift.number(f.radius)), "
                    + "height: \(Swift.number(f.height)), swirl: \(Swift.number(f.swirl)), lift: \(Swift.number(f.lift))),\n"
            }.joined() + "]"
        }
        if !colliders.isEmpty {
            s += ", colliders: [\n" + colliders.map { c in
                let shape: String
                switch c.shape {
                case .plane(let n, let p): shape = ".plane(normal: \(Swift.vector(n)), point: \(Swift.vector(p)))"
                case .sphere(let c, let r): shape = ".sphere(center: \(Swift.vector(c)), radius: \(Swift.number(r)))"
                case .box(let c, let h): shape = ".box(center: \(Swift.vector(c)), halfExtents: \(Swift.vector(h)))"
                }
                return "    VFXCollider(name: \(Swift.quote(c.name)), shape: \(shape)),\n"
            }.joined() + "]"
        }
        return s + ")\n"
    }

    /// How the Swift is written.
    private enum Swift {
        static func quote(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        /// The shortest decimal that is the same float.
        static func number(_ f: Float) -> String {
            if f == .greatestFiniteMagnitude { return ".greatestFiniteMagnitude" }
            if f == f.rounded() && abs(f) < 1e7 { return String(Int(f)) }
            return "\(f)"
        }
        static func vector(_ v: SIMD3<Float>) -> String { "[\(number(v.x)), \(number(v.y)), \(number(v.z))]" }
        static func color(_ c: SIMD4<Float>) -> String { "[\(number(c.x)), \(number(c.y)), \(number(c.z)), \(number(c.w))]" }
        static func curve(_ c: VFXCurve) -> String {
            "VFXCurve([" + c.keys.map { "[\(number($0.x)), \(number($0.y))]" }.joined(separator: ", ") + "]" + (c.smooth ? ", smooth: true" : "") + ")"
        }
        static func gradient(_ g: VFXGradient) -> String {
            if let (c0, c1, c2, m) = g.threeKeys {
                return "VFXGradient(\(color(c0)), \(color(c1)), \(color(c2))" + (m == 0.5 ? "" : ", midpoint: \(number(m))") + ")"
            }
            return "VFXGradient([" + g.keys.map { ".init(\(number($0.t)), \(color($0.color)))" }.joined(separator: ", ") + "])"
        }
        static func literal(_ p: VFXParam) -> String {
            switch p {
            case .float(let f): return ".float(\(number(f)))"
            case .vec3(let v): return ".vec3(\(vector(v)))"
            case .color(let c): return ".color(\(color(c)))"
            case .bool(let b): return ".bool(\(b))"
            case .int(let i): return ".int(\(i))"
            case .range(let a, let b): return ".range(\(number(a)), \(number(b)))"
            case .choice(let c): return ".choice(\(quote(c)))"
            case .names(let n): return ".names([\(n.map(quote).joined(separator: ", "))])"
            case .curve(let c): return ".curve(\(curve(c)))"
            case .gradient(let g): return ".gradient(\(gradient(g)))"
            }
        }

        /// A block as its builder's call, with only the arguments that differ from the defaults.
        static func call(_ b: VFXBlock) -> String {
            var args: [String] = []
            func differs(_ name: String) -> Bool { b.param(name) != b.kind.spec.pin(name)!.value }
            func f(_ name: String, _ label: String?) {
                guard differs(name) else { return }
                args.append((label.map { "\($0): " } ?? "") + number(b.float(name)))
            }
            func vec(_ name: String, _ label: String) { if differs(name) { args.append("\(label): \(vector(b.vec3(name)))") } }
            func flag(_ name: String, _ label: String) { if differs(name) { args.append("\(label): \(b.bool(name))") } }
            func int(_ name: String, _ label: String) { if differs(name) { args.append("\(label): \(b.int(name))") } }
            func range(_ r: ClosedRange<Float>) -> String { "\(number(r.lowerBound))...\(number(r.upperBound))" }
            switch b.kind {
            case .rate:
                args.append(number(b.float("rate")))
                f("start", "start"); f("stop", "stop")
                if differs("overTime") { args.append("overTime: \(curve(b.param("overTime").curve))") }
                f("span", "span")
            case .burst:
                args.append("at: \(number(b.float("time")))")
                args.append("count: \(b.int("count"))")
                f("period", "every"); int("repeats", "repeats")
            case .event:
                args.append(quote(b.choice("parent")))
                if differs("on") { args.append("on: \(quote(b.choice("on")))") }
                int("count", "count")
            case .shape:
                args.append(quote(b.choice("shape")))
                vec("position", "at"); vec("direction", "axis"); f("radius", "radius"); vec("halfExtents", "halfExtents")
            case .velocity:
                if differs("speed") { args.append("speed: \(range(b.range("speed")))") }
                f("spread", "spread"); flag("radial", "radial"); vec("add", "add"); f("inherit", "inherit")
            case .lifetime:
                args.append(range(b.range("lifetime")))
                f("max", "max")
            case .setPosition, .setVelocity:
                if differs("value") { args.append(vector(b.vec3("value"))) }
            case .setAttribute:
                args.append(quote(b.choice("attribute")))
                if differs("value") { args.append(color(b.color("value"))) }
            case .gravity: args.append(number(b.float("share")))
            case .drag: args.append(number(b.float("drag"))); f("wind", "wind")
            case .curl:
                args.append(number(b.float("strength")))
                f("frequency", "frequency"); f("speed", "speed"); flag("baked", "baked")
            case .field:
                args.append(quote(b.choice("field")))
                f("strength", "strength"); flag("follow", "follow")
            case .vortex:
                f("swirl", "swirl"); f("attraction", "attraction")
                if !b.bool("atEmitter") { args.append("center: \(vector(b.vec3("center")))") }
            case .force: if differs("force") { args.append(vector(b.vec3("force"))) }
            case .collide:
                if differs("colliders") { args.append("[\(b.names("colliders").map(quote).joined(separator: ", "))]") }
                flag("scene", "scene"); f("restitution", "restitution"); f("friction", "friction"); f("radius", "radius")
                flag("kill", "kill")
            case .kill, .trigger: if differs("when") { args.append("\(b.bool("when"))") }
            case .billboard: break
            case .mesh: args.append(quote(b.choice("mesh"))); args.append("material: \(quote(b.choice("material")))")
            case .trail: int("points", "points"); int("every", "every"); f("width", "width")
            case .distortion: args.append(number(b.float("amount")))
            case .size:
                if let (a, z) = VFXLowering.linearSize(b.param("size").curve) {
                    args.append(number(a)); args.append(number(z))
                } else {
                    args.append("curve: \(curve(b.param("size").curve))")
                }
                f("jitter", "jitter")
            case .color:
                args.append(gradient(b.param("color").gradient))
                f("emission", "emission")
            case .flipbook:
                args.append(".\(b.choice("atlas"))")
                int("frames", "frames"); f("fps", "fps"); flag("random", "random"); flag("blend", "blend")
            case .orient:
                args.append(quote(b.choice("mode")))
                f("stretch", "stretch"); vec("axis", "axis"); f("spin", "spin")
            case .lighting:
                f("soft", "soft"); flag("shadows", "shadows"); f("shadowDensity", "shadowDensity")
            }
            return ".\(b.kind.rawValue)(\(args.joined(separator: ", ")))"
        }
    }
}
