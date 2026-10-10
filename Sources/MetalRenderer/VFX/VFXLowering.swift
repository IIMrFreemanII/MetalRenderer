import Foundation
import simd

/// An effect a scene placed (Scene.addEffect): where, and what its names bind to in the scene (a Mesh block's mesh
/// and material).
struct VFXInstance {
    var effect: VFXEffect
    var place: VFXPlacement
    var meshes: [String: (mesh: Int, material: Int)] = [:]
}

/// Placed effects into one particle system: each emitter into the fixed emitter (ParticleEmitter: what its blocks'
/// values say, the descriptor every kernel reads), and, if its graph asks for more than that, a program
/// (VFXProgram) the VFX library runs for it. Nothing here fails: what can't be done is left out and said in
/// `diagnostics` (the editor shows them).
enum VFXLowering {
    struct Result {
        let system: ParticleSystem
        let diagnostics: [String]
        /// Per instance, its emitters' places in the system, its colliders' and its fields'.
        let emitters: [[Int]]
    }

    static func system(_ instances: [VFXInstance], colliders sceneColliders: [(name: String, collider: ParticleCollider)] = [])
        -> Result {
        var notes: [String] = []
        var colliders = sceneColliders.map(\.collider)
        var fields: [ParticleField] = []
        var emitters: [ParticleEmitter] = [], programs: [VFXProgram?] = []
        // Each instance's colliders and fields.
        var colliderIndex: [[String: Int]] = [], fieldIndex: [[String: Int]] = []
        for instance in instances {
            let fx = instance.effect
            var c: [String: Int] = [:]   // the scene's names first: its own of the same name win
            for (i, sc) in sceneColliders.enumerated() { c[sc.name] = i }
            for collider in fx.colliders {
                guard colliders.count < 32 else { notes.append("\(fx.name): more than 32 colliders; \(collider.name) left out"); break }
                c[collider.name] = colliders.count
                colliders.append(collider.collider(instance.place))
            }
            var f: [String: Int] = [:]
            for field in fx.fields {
                guard fields.count < 15 else { notes.append("\(fx.name): more than 15 fields; \(field.name) left out"); break }
                f[field.name] = fields.count
                fields.append(field.field(instance.place))
            }
            colliderIndex.append(c)
            fieldIndex.append(f)
        }
        // The emitters in the pool by their seeds (a built-in effect's are their places in its scene's list from before
        // effects were graphs: the pool is laid out as it was, each particle in the slot it had).
        var order: [(instance: Int, emitter: Int, seed: UInt32)] = []
        for (i, instance) in instances.enumerated() {
            for (k, em) in instance.effect.emitters.enumerated() { order.append((i, k, em.seed ?? seed(instance.effect.name, em.name))) }
        }
        order = order.enumerated().sorted { ($0.element.seed, $0.offset) < ($1.element.seed, $1.offset) }.map(\.element)
        if order.count > ParticleSystem.maxEmitters {
            for o in order[ParticleSystem.maxEmitters...] {
                let fx = instances[o.instance].effect
                notes.append("\(fx.name): more than \(ParticleSystem.maxEmitters) emitters in the scene; \(fx.emitters[o.emitter].name) left out")
            }
            order = Array(order.prefix(ParticleSystem.maxEmitters))
        }
        var ids = [[String: Int]](repeating: [:], count: instances.count)
        var placed = [[Int]](repeating: [], count: instances.count)
        for (k, o) in order.enumerated() {
            ids[o.instance][instances[o.instance].effect.emitters[o.emitter].id] = k
            placed[o.instance].append(k)
        }
        for o in order {
            let instance = instances[o.instance], fx = instance.effect, em = fx.emitters[o.emitter]
            var e = lower(em, fx, instance, colliderIndex: colliderIndex[o.instance], fieldIndex: fieldIndex[o.instance],
                          parents: ids[o.instance], notes: &notes)
            var program: VFXProgram?
            do {
                program = try VFXProgramBuilder(effect: fx, emitter: em, fieldIndex: fieldIndex[o.instance])
                    .build(number: programs.compactMap { $0 }.count + 1)
            } catch {
                notes.append("\(fx.name)/\(em.name): \(error) (it runs without its graph's code)")
            }
            if let r = program?.rate, let p = program { e.rateCurve = Array(p.params[r..<(r + 1 + VFXCurve.maxKeys)]) }
            emitters.append(e)
            programs.append(program)
        }
        // Every trail keeps the same number of places (the first's).
        if let points = emitters.compactMap({ $0.trail?.points }).first {
            for i in emitters.indices where emitters[i].trail != nil && emitters[i].trail!.points != points {
                notes.append("\(emitters[i].name): a trail keeps \(points) places, as the first trail does")
                emitters[i].trail!.points = points
            }
        }
        if emitters.isEmpty { emitters = [ParticleEmitter("none", capacity: 1, at: .zero)]; programs = [nil] }
        let system = ParticleSystem(emitters: emitters, colliders: colliders, fields: fields, programs: programs)
        return Result(system: system, diagnostics: notes, emitters: placed)
    }

    /// The seed of an emitter that has none of its own: a hash of its effect's name and its own (FNV-1a), so it is
    /// the same wherever the effect is.
    static func seed(_ effect: String, _ emitter: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for b in "\(effect)/\(emitter)".utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return h
    }

    /// A size curve the fixed emitter's lerp is: two keys, at 0 and 1, straight.
    static func linearSize(_ c: VFXCurve) -> (Float, Float)? {
        guard c.keys.count == 2, c.keys[0].x == 0, c.keys[1].x == 1, !c.smooth else { return nil }
        return (c.keys[0].y, c.keys[1].y)
    }

    /// The fixed emitter `em`'s blocks' values make (what generated code adds, VFXProgram does).
    static func lower(_ em: VFXEmitter, _ fx: VFXEffect, _ instance: VFXInstance, colliderIndex: [String: Int],
                      fieldIndex: [String: Int], parents: [String: Int], notes: inout [String]) -> ParticleEmitter {
        let place = instance.place
        let shapeBlock = em.first(.shape)
        var e = ParticleEmitter(em.name, capacity: max(em.capacity, 1), at: place.point(shapeBlock?.vec3("position") ?? .zero))
        e.seed = em.seed ?? seed(fx.name, em.name)
        let where_ = "\(fx.name)/\(em.name)"

        // Spawn
        if let r = em.first(.rate) {
            e.rate = max(r.float("rate"), 0)
            e.start = max(r.float("start"), 0)
            e.stop = r.float("stop")
        }
        if let b = em.first(.burst) {
            e.burst = (max(b.float("time"), 0), max(b.int("count"), 0), max(b.float("period"), 0), max(b.int("repeats"), 0))
        }
        if let ev = em.first(.event) {
            if let p = parents[ev.choice("parent")], p != parents[em.id] {
                e.parent = p
                switch ev.choice("on") {
                case "collision": e.trigger = .collision
                case "condition": e.trigger = .condition
                default: e.trigger = .death
                }
                e.perEvent = min(max(ev.int("count"), 1), ParticleSystem.maxPerEvent)
            } else {
                notes.append("\(where_): its parent \"\(ev.choice("parent"))\" isn't an emitter of the effect")
            }
        }
        // Initialize
        if let s = shapeBlock {
            let r = max(s.float("radius"), 0)
            switch s.choice("shape") {
            case "sphere": e.shape = .sphere(radius: r)
            case "sphere surface": e.shape = .sphere(radius: r, surface: true)
            case "disc": e.shape = .disc(radius: r)
            case "box": e.shape = .box(halfExtents: simd_abs(s.vec3("halfExtents")))
            case "ring": e.shape = .ring(radius: r)
            default: e.shape = .point
            }
            e.direction = s.vec3("direction")
        }
        if let v = em.first(.velocity) {
            e.speed = v.range("speed")
            e.spread = v.float("spread")
            e.radial = v.bool("radial")
            e.velocity = v.vec3("add")
            e.inherit = v.float("inherit")
        }
        if let l = em.first(.lifetime) {
            let r = l.range("lifetime")
            if fx.link(into: l.id, "lifetime") != nil {
                let most = max(l.float("max"), 1e-3)
                e.lifetime = min(max(r.lowerBound, 1e-3), most)...most
            } else {
                e.lifetime = max(r.lowerBound, 1e-4)...max(r.upperBound, 1e-4)
            }
        }
        // Update
        e.gravity = em.first(.gravity)?.float("share") ?? 0
        if let d = em.first(.drag) {
            e.drag = max(d.float("drag"), 0)
            e.wind = d.float("wind")
        }
        if let c = em.first(.curl) {
            e.curl = c.float("strength")
            e.curlFrequency = c.float("frequency")
            e.curlSpeed = c.float("speed")
            e.bakedCurl = c.bool("baked")
        }
        if let f = em.first(.field) {
            if let k = fieldIndex[f.choice("field")] {
                e.field = (k, f.float("strength"), f.bool("follow"))
            } else {
                notes.append("\(where_): no field \"\(f.choice("field"))\"")
            }
        }
        if let v = em.first(.vortex) {
            e.vortex = v.float("swirl")
            e.attraction = v.float("attraction")
            if !v.bool("atEmitter") { e.attractor = place.point(v.vec3("center")) }
        }
        if let c = em.first(.collide) {
            var mask: UInt32 = 0
            for name in c.names("colliders") {
                if let k = colliderIndex[name] { mask |= 1 << UInt32(k) } else { notes.append("\(where_): no collider \"\(name)\"") }
            }
            e.colliders = mask
            e.collidesWithScene = c.bool("scene")
            e.restitution = c.float("restitution")
            e.friction = c.float("friction")
            e.collisionRadius = max(c.float("radius"), 0)
            e.dieOnCollision = c.bool("kill")
        }
        // Output
        let renderer = em.output.first { $0.enabled && $0.kind.isRenderer }
        switch renderer?.kind {
        case .mesh?:
            let name = renderer!.choice("mesh")
            if let m = instance.meshes[name] {
                e.mesh = m
            } else {
                notes.append("\(where_): the scene has no mesh \"\(name)\" for it (drawn as billboards)")
            }
        case .trail?:
            e.trail = (max(renderer!.int("points"), 3), max(renderer!.int("every"), 1))
            e.trailWidth = renderer!.float("width")
        case .distortion?:
            e.distortion = max(renderer!.float("amount"), 0)
        default: break
        }
        if let s = em.first(.size) {
            let c = s.param("size").curve
            if let (a, b) = linearSize(c) {
                e.size = (a, b)
            } else {
                e.size = (c.value(0), c.value(1))   // what the meshes, trails and haze take (the program has the rest)
            }
            e.sizeJitter = min(max(s.float("jitter"), 0), 1)
        }
        if let c = em.first(.color) {
            let g = c.param("color").gradient
            if let (c0, c1, c2, m) = g.threeKeys {
                e.colors = (c0, c1, c2)
                e.midpoint = m
            } else {
                e.colors = (g.value(0), g.value(0.5), g.value(1))
                e.midpoint = 0.5
            }
            e.emission = max(c.float("emission"), 0)
        }
        if let f = em.first(.flipbook) {
            e.atlas = ParticleTextures.Kind(name: f.choice("atlas")) ?? .dot
            e.frames = min(max(f.int("frames"), 1), ParticleTextures.frames)
            e.fps = max(f.float("fps"), 0)
            e.randomFrame = f.bool("random")
            e.frameBlend = f.bool("blend")
        }
        if let o = em.first(.orient) {
            switch o.choice("mode") {
            case "velocity": e.orientation = .velocity(stretch: o.float("stretch"))
            case "axis": e.orientation = .axis(o.vec3("axis"))
            case "world": e.orientation = .world(normal: o.vec3("axis"))
            default: e.orientation = .rayFacing
            }
            e.spin = o.float("spin")
        }
        if let l = em.first(.lighting) {
            e.soft = max(l.float("soft"), 0)
            e.castsShadows = l.bool("shadows")
            e.shadowDensity = min(max(l.float("shadowDensity"), 0), 1)
        }
        if e.distortion > 0 && (e.mesh != nil || e.trail != nil) { e.distortion = 0 }
        return e
    }
}
