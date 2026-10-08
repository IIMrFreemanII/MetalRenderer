import Foundation
import simd

/// A particle effect's source (Particles.swift, Shaders/Particles.metal): where its particles are born and how, the
/// forces on them, what they bounce off, and how they look. Its particles live in a fixed range of the system's pool:
/// `capacity` is a hard budget, and births past it are dropped.
///
/// A child emitter (`parent`) spawns `perEvent` particles where each of its parent's particles dies (or collides,
/// `trigger`), with a share of its velocity: sparks that leave smoke, rain that splashes.
struct ParticleEmitter {
    enum Shape {
        case point
        case sphere(radius: Float, surface: Bool = false)
        /// A disc of `radius` across the axis; the velocity spreads about the axis (`spread`).
        case disc(radius: Float)
        case box(halfExtents: SIMD3<Float>)
        /// A circle of `radius` across the axis, the particles spread round it evenly (by spawn id).
        case ring(radius: Float)

        var code: Float {
            switch self {
            case .point: return 0
            case .sphere(_, let surface): return surface ? 2 : 1
            case .disc: return 3
            case .box: return 4
            case .ring: return 5
            }
        }
        var radius: Float {
            switch self {
            case .point, .box: return 0
            case .sphere(let r, _), .disc(let r), .ring(let r): return r
            }
        }
    }

    /// How a particle faces a ray (Shaders/ParticleTrace.metal).
    enum Orientation {
        /// A disc square to every ray: a puff, a spark's glow.
        case rayFacing
        /// A quad along its velocity, as long as its radius plus its speed x `stretch`: sparks, rain.
        case velocity(stretch: Float)
        /// A quad that turns only about `axis`: flames, light shafts.
        case axis(SIMD3<Float>)
        /// A quad fixed in the world, square to `normal`: ripples, shockwave rings.
        case world(normal: SIMD3<Float>)

        var code: UInt32 {
            switch self {
            case .rayFacing: return 0
            case .velocity: return 1
            case .axis: return 2
            case .world: return 3
            }
        }
    }

    /// What makes a parent's particle an event for its children.
    enum Trigger { case death, collision }

    /// GPUParticleEmitter.ids.w; the low 8 bits reach the rays (GPUParticleRender.info.x >> 24; bits 3 and 4 hold the
    /// orientation there).
    struct Flags: OptionSet {
        let rawValue: UInt32
        static let emissive = Flags(rawValue: 1)          // unlit: its colour is the light it sends
        static let shadows = Flags(rawValue: 2)           // it shadows what is behind it from the lights
        static let frameBlend = Flags(rawValue: 4)        // flipbook frames blend into the next
        static let sixWay = Flags(rawValue: 1 << 5)       // lit by its atlas's six-way maps (smoke)
        static let motionVectors = Flags(rawValue: 1 << 6) // the frames blend along their atlas's motion
        static let killOnCollision = Flags(rawValue: 1 << 8)
        static let eventsOnDeath = Flags(rawValue: 1 << 9)       // a child spawns where it dies
        static let eventsOnCollision = Flags(rawValue: 1 << 10)  // ...where it collides
        static let sceneCollisions = Flags(rawValue: 1 << 11)    // it bounces off the scene's geometry (a ray a step)
    }

    var name: String
    var capacity: Int
    var position: SIMD3<Float>
    /// The shape's and the velocity's axis.
    var direction: SIMD3<Float> = [0, 1, 0]
    var shape: Shape = .point
    /// Particles a second, from `start` to `stop`.
    var rate: Float = 0
    var start: Float = 0
    var stop: Float = .greatestFiniteMagnitude
    /// `count` at `time`, then every `period` (0: once), `repeats` times (0: no end).
    var burst: (time: Float, count: Int, period: Float, repeats: Int)?
    var lifetime: ClosedRange<Float> = 1...1
    var speed: ClosedRange<Float> = 0...0
    /// Half angle about `direction` (rad).
    var spread: Float = 0
    /// Outward from `position` instead of along `direction`.
    var radial = false
    var velocity: SIMD3<Float> = .zero

    // Forces.
    /// Share of gravity: 1 falls, negative rises (hot smoke).
    var gravity: Float = 1
    /// How fast the particle takes the air's velocity (1/s).
    var drag: Float = 0
    /// Share of the scene's wind in that air.
    var wind: Float = 0
    /// Curl noise: a divergence-free swirl (m/s^2), its frequency (1/m) and how fast it scrolls (1/s).
    var curl: Float = 0
    var curlFrequency: Float = 1
    var curlSpeed: Float = 0
    /// Curl noise from the system's baked tile (ParticleField.curl, read trilinearly) instead of three noise
    /// channels' gradients a step: about the same swirl for a fraction of the arithmetic.
    var bakedCurl = false
    /// A vector field (the system's `fields[index]`): with `follow`, the air's velocity there, which the particle
    /// takes at `strength` (1/s, as drag does); otherwise an acceleration, times `strength`.
    var field: (index: Int, strength: Float, follow: Bool)?
    /// Spin about `direction` through `attractor` (m/s^2), and pull toward it.
    var vortex: Float = 0
    var attraction: Float = 0
    var attractor: SIMD3<Float>?

    // Collisions.
    /// The system's colliders it meets (bit i: collider i).
    var colliders: UInt32 = 0
    var restitution: Float = 0.3
    var friction: Float = 0.2
    /// It dies where it first meets one (rain).
    var dieOnCollision = false
    /// It bounces off the scene's geometry too (on the GPU: a ray along each step; the CPU's reference has no scene).
    var collidesWithScene = false
    /// It meets the colliders as a ball this big (m): a mesh particle's size, so it rests on the floor, not in it.
    var collisionRadius: Float = 0

    // Look.
    var size: (start: Float, end: Float) = (0.05, 0.05)
    /// Each particle smaller by up to this share.
    var sizeJitter: Float = 0
    /// rgba at birth, at `midpoint` of its life, at death.
    var colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = ([1, 1, 1, 1], [1, 1, 1, 1], [1, 1, 1, 0])
    var midpoint: Float = 0.5
    /// Unlit, sending its colour x this (W/sr/m^2 per unit of colour); 0: lit by the scene's lights.
    var emission: Float = 0
    var atlas: ParticleTextures.Kind = .dot
    /// Frames of its flipbook it plays (up to ParticleTextures.frames), `fps` a second (0: once over its life).
    var frames: Int = 1
    var fps: Float = 0
    var randomFrame = false
    var frameBlend = true
    var orientation: Orientation = .rayFacing
    /// Most spin (rad/s), either way.
    var spin: Float = 0
    /// Fades over this distance in front of what is behind it (m).
    var soft: Float = 0.1
    var castsShadows = true
    /// A mesh in the scene's top-level structure instead of a billboard (debris, chunks): an instance a slot, `size`
    /// its scale, turning at up to `spin` rad/s about an axis of its own; opaque, so it shadows, reflects and takes
    /// GI as any geometry does. The scene reserves the instances (Scene.addParticles); the pose places them every
    /// frame, a dead one shrunk to nothing at the emitter.
    var mesh: (mesh: Int, material: Int)?
    /// A trail behind each particle: where it was at its last `points` places, `every` steps apart, and where it is,
    /// as a ribbon that faces every ray (flat Catmull-Rom curves in a structure of their own: ParticleTrace.metal),
    /// tapering to nothing at its end and fading along it; as wide as the particle times `trailWidth` at its head.
    /// Its look is the particle's (emissive or lit). Every trail emitter keeps the same number of points.
    var trail: (points: Int, every: Int)?
    var trailWidth: Float = 1
    /// How much of its opacity a shadow ray takes (0...1): a billboard stands for a soft volume, and a ray through a
    /// column of them at their full opacity sees far denser smoke than there is.
    var shadowDensity: Float = 1

    // A child.
    var parent: Int?
    var trigger: Trigger = .death
    /// Children an event (1...8).
    var perEvent = 1
    /// Share of the parent's velocity it starts with.
    var inherit: Float = 0

    init(_ name: String, capacity: Int, at position: SIMD3<Float>) {
        self.name = name
        self.capacity = capacity
        self.position = position
    }

    var flags: Flags {
        var f: Flags = []
        if emission > 0 { f.insert(.emissive) }
        if castsShadows { f.insert(.shadows) }
        if frameBlend && frames > 1 { f.insert(.frameBlend) }
        if emission == 0 && ParticleTextures.hasSixWay(atlas) { f.insert(.sixWay) }
        if frameBlend && frames > 1 && ParticleTextures.motionLayer(atlas) != nil { f.insert(.motionVectors) }
        if dieOnCollision { f.insert(.killOnCollision) }
        if collidesWithScene { f.insert(.sceneCollisions) }
        return f
    }
}

/// An analytic shape particles bounce off (or die on: ParticleEmitter.Flags.killOnCollision), or one of the scene's
/// SDF shapes' instances, met by its distance (a ball of the particle's collision radius against the shape's
/// surface, pushed out along its gradient: only on the GPU, with the scene bound, as the scene's own collisions).
enum ParticleCollider {
    case plane(normal: SIMD3<Float>, point: SIMD3<Float>)
    case sphere(center: SIMD3<Float>, radius: Float)
    case box(center: SIMD3<Float>, halfExtents: SIMD3<Float>)
    /// Instance `instance` of SDF shape `shape` (Scene.addInstance(sdf:) and addSDFShape's numbers).
    case shape(instance: Int, shape: Int)

    var gpu: GPUParticleCollider {
        switch self {
        case .plane(let n, let p):
            let u = normalize(n)
            return GPUParticleCollider(a: SIMD4(u, dot(u, p)), b: SIMD4(0, 0, 0, 0))
        case .sphere(let c, let r): return GPUParticleCollider(a: SIMD4(c, r), b: SIMD4(0, 0, 0, 1))
        case .box(let c, let h): return GPUParticleCollider(a: SIMD4(c, 0), b: SIMD4(h, 2))
        case .shape(let i, let s):
            return GPUParticleCollider(a: SIMD4(Float(bitPattern: UInt32(i)), Float(bitPattern: UInt32(s)), 0, 0), b: SIMD4(0, 0, 0, 3))
        }
    }
}

/// A vector field particles move in (ParticleEmitter.field, .bakedCurl): a vector at each node of a grid over a box,
/// read trilinearly between them (MSL particleField; ParticleMath.field its twin). Outside the box, nothing; a
/// `periodic` one repeats instead (a tile: the box's size its period, the nodes `dims` apart along it with the
/// first standing in for the one past the last).
struct ParticleField {
    var lo: SIMD3<Float>
    var size: SIMD3<Float>
    var dims: SIMD3<Int32>
    var periodic = false
    var samples: [SIMD3<Float>]

    /// `f` at the nodes of a `dims` grid over the box at `center`.
    init(center: SIMD3<Float>, halfExtents: SIMD3<Float>, dims: SIMD3<Int32>, periodic: Bool = false, _ f: (SIMD3<Float>) -> SIMD3<Float>) {
        precondition(all(dims .>= 2), "two nodes or more along each axis")
        lo = center - halfExtents
        size = halfExtents * 2
        self.dims = dims
        self.periodic = periodic
        let steps = SIMD3<Float>(dims &- (periodic ? 0 : 1))
        var s: [SIMD3<Float>] = []
        s.reserveCapacity(Int(dims.x * dims.y * dims.z))
        for z in 0..<dims.z {
            for y in 0..<dims.y {
                for x in 0..<dims.x { s.append(f(lo + size * SIMD3(Float(x), Float(y), Float(z)) / steps)) }
            }
        }
        samples = s
    }

    /// Curl noise baked into a tile `period` noise cells on a side, `perCell` nodes a cell: the curl of three
    /// channels of gradient noise whose lattice repeats every `period` cells (so the tile does), in the same units
    /// as ParticleMath.curl at frequency 1 (a lattice cell a unit); read at p x frequency, times the frequency.
    static func curl(period: Int32 = 4, perCell: Int32 = 8) -> ParticleField {
        let n = period * perCell, p = Float(period)
        return ParticleField(center: SIMD3(repeating: p / 2), halfExtents: SIMD3(repeating: p / 2), dims: SIMD3(repeating: n), periodic: true) { q in
            ParticleMath.periodicCurl(q, period: period)
        }
    }

    /// A column of air rising round `axis` through `center`: swirling at `swirl` m/s round it within `radius`, lifted at
    /// `lift` m/s, drawn in toward it below and out above (a dust devil's, a chimney's draft).
    static func vortex(center: SIMD3<Float>, radius: Float, height: Float, swirl: Float, lift: Float, dims: Int32 = 16) -> ParticleField {
        ParticleField(center: center + SIMD3(0, height / 2, 0), halfExtents: SIMD3(radius * 1.5, height / 2, radius * 1.5),
                      dims: SIMD3(dims, dims, dims)) { p in
            let r = SIMD3(p.x - center.x, 0, p.z - center.z), d = length(r)
            guard d > 1e-4 else { return SIMD3(0, lift, 0) }
            let around = cross(SIMD3<Float>(0, 1, 0), r / d), falloff = exp(-pow(d / radius, 2))
            let h = (p.y - center.y) / height                       // 0 at its foot, 1 at its top
            let inward = -(r / d) * (0.5 - h) * swirl * 0.6 * falloff
            return around * swirl * (d / radius) * falloff * 1.6 + SIMD3(0, lift * falloff, 0) + inward
        }
    }

    var gpu: GPUParticleField {
        GPUParticleField(lo: SIMD4(lo, periodic ? 1 : 0), size: SIMD4(size, 0), dims: SIMD4(UInt32(dims.x), UInt32(dims.y), UInt32(dims.z), 0))
    }
}

/// A scene's particle effects: its emitters' pools side by side in one pool, the colliders, and the clock. Steps are
/// a fixed 1/60 s, counted from the start (as the physics': `claim`); the GPU runs them (ParticlesGPU), and
/// ParticlesCPU is the same step on the CPU, the tests' reference.
///
/// Each step, as GPU particle systems do it (Shaders/Particles.metal): `begin` clamps what each emitter asks for
/// (its rate and bursts over the step, or its parent's events) to its free slots, pops them off its dead list and
/// writes the indirect arguments; `emit` writes the newborns and appends them to the alive list; `simulate` ages and
/// moves every alive particle, pushes the dead back on their emitter's dead list and appends the rest to the other
/// alive list, which the next step reads. The CPU never reads a count back.
final class ParticleSystem {
    static let stepLength: Float = 1.0 / 60.0
    static let maxEmitters = 32         // PARTICLE_EMITTERS: `begin` is one SIMD group, a thread an emitter
    static let none = UInt32.max
    static let alive: UInt32 = 1        // GPUParticle.info.w
    static let maxPerEvent = 8          // a child's spawn id is its parent's x 8 + which

    let emitters: [ParticleEmitter]
    let colliders: [ParticleCollider]
    /// The vector fields (ParticleEmitter.field), and last the baked curl tile if an emitter asks for it.
    let fields: [ParticleField]
    let bakedCurlField: Int?
    /// Each emitter's first slot; the pool's size. The emitters that cast shadows have the pool's first
    /// `casterCapacity` slots: shadow rays look only through their structure (ParticleTrace.metal). The mesh
    /// emitters' slots are the last `meshCapacity`: they're instances in the scene's structure, not boxes.
    let bases: [Int]
    let capacity: Int
    let casterCapacity: Int
    let meshCapacity: Int
    /// The billboards' slots (the casters' and the others'), ahead of the meshes'.
    var billboardCapacity: Int { capacity - meshCapacity }
    /// Per emitter, the first of its instances in the scene (a mesh emitter's: Scene.addParticles reserves them).
    var meshInstances: [Int?]
    /// The trails (ParticleEmitter.trail): per emitter its first (a trail a slot of a trail emitter), how many in all,
    /// and the places each keeps (0: no trails); its curve has those and the head.
    let trailBases: [Int?]
    let trailCount: Int
    let trailPoints: Int
    /// A trail's control points (its places and its head) and its curve's segments (four points each, a point apart).
    var trailControlPoints: Int { trailPoints + 1 }
    var trailSegments: Int { trailPoints > 0 ? trailControlPoints - 3 : 0 }
    var gravity: Float = 9.81
    /// The air's speed at wind strength 1 (WindFrame.wind.z), m/s.
    static let windSpeed: Float = 4
    /// Steps run (or claimed by the GPU).
    private(set) var stepIndex = 0

    init(emitters: [ParticleEmitter], colliders: [ParticleCollider] = [], fields: [ParticleField] = []) {
        precondition(!emitters.isEmpty && emitters.count <= ParticleSystem.maxEmitters, "1 to \(ParticleSystem.maxEmitters) emitters")
        precondition(colliders.count <= 32, "a mask holds 32 colliders")
        for (i, e) in emitters.enumerated() {
            precondition(e.capacity > 0, "\(e.name): no capacity")
            if let p = e.parent { precondition(p >= 0 && p < emitters.count && p != i, "\(e.name): its parent isn't an emitter") }
            precondition((1...ParticleSystem.maxPerEvent).contains(e.perEvent), "\(e.name): 1 to 8 children an event")
            precondition(e.frames >= 1 && e.frames <= ParticleTextures.frames, "\(e.name): 1 to \(ParticleTextures.frames) frames")
            if let t = e.trail { precondition(t.points >= 3 && t.every >= 1 && e.mesh == nil, "\(e.name): 3 places or more, a billboard's") }
        }
        let trails = emitters.compactMap { $0.trail?.points }
        precondition(Set(trails).count <= 1, "every trail emitter keeps the same number of places")
        var trailBases = [Int?](repeating: nil, count: emitters.count), t = 0
        for (i, e) in emitters.enumerated() where e.trail != nil { trailBases[i] = t; t += e.capacity }
        self.trailBases = trailBases
        trailCount = t
        trailPoints = trails.first ?? 0
        self.emitters = emitters
        self.colliders = colliders
        for e in emitters { if let f = e.field { precondition(f.index >= 0 && f.index < fields.count, "\(e.name): no such field") } }
        precondition(fields.count < 16, "16 fields at most")
        if emitters.contains(where: { $0.bakedCurl && $0.curl != 0 }) {
            bakedCurlField = fields.count
            self.fields = fields + [ParticleSystem.curlTile]
        } else {
            bakedCurlField = nil
            self.fields = fields
        }
        var bases = [Int](repeating: 0, count: emitters.count), n = 0
        for (i, e) in emitters.enumerated() where e.mesh == nil && e.castsShadows { bases[i] = n; n += e.capacity }
        casterCapacity = n
        for (i, e) in emitters.enumerated() where e.mesh == nil && !e.castsShadows { bases[i] = n; n += e.capacity }
        let meshes = n
        for (i, e) in emitters.enumerated() where e.mesh != nil { bases[i] = n; n += e.capacity }
        meshCapacity = n - meshes
        self.bases = bases
        capacity = n
        meshInstances = Array(repeating: nil, count: emitters.count)
    }

    /// The steps that reach `time` (from the start: `restart`).
    func stepsTo(_ time: Float) -> (steps: Int, restart: Bool) {
        let target = max(Int((time / ParticleSystem.stepLength).rounded(.down)), 0)
        return target < stepIndex ? (target, true) : (target - stepIndex, false)
    }

    /// For the GPU: the steps that reach `time` (from the start, `restart`), counted as run.
    func claim(to time: Float) -> (steps: Int, restart: Bool) {
        let (steps, restart) = stepsTo(time)
        if restart { stepIndex = 0 }
        stepIndex += steps
        return (steps, restart)
    }

    /// The CPU's reference counts its own steps.
    func setStepIndex(_ i: Int) { stepIndex = i }

    // MARK: - What the kernels read

    var gpuEmitters: [GPUParticleEmitter] {
        emitters.enumerated().map { i, e in
            var flags = e.flags
            for c in emitters where c.parent == i { flags.insert(c.trigger == .death ? .eventsOnDeath : .eventsOnCollision) }
            let axis = simd_length(e.direction) > 0 ? normalize(e.direction) : SIMD3<Float>(0, 1, 0)
            var extent = SIMD3<Float>.zero
            if case .box(let h) = e.shape { extent = h }
            var lock = SIMD3<Float>(0, 1, 0)
            var stretch: Float = 0
            switch e.orientation {
            case .rayFacing: break
            case .velocity(let s): stretch = s
            case .axis(let a): lock = normalize(a)
            case .world(let n): lock = normalize(n)
            }
            let b = e.burst, dt = ParticleSystem.stepLength
            return GPUParticleEmitter(
                origin: SIMD4(e.position, e.shape.radius),
                axis: SIMD4(axis, e.spread),
                extent: SIMD4(extent, e.shape.code),
                velocity: SIMD4(e.velocity, e.inherit),
                speed: SIMD4(e.speed.lowerBound, e.speed.upperBound, e.radial ? 1 : 0, e.start / dt),
                life: SIMD4(e.lifetime.lowerBound, e.lifetime.upperBound, e.parent == nil ? e.rate * dt : 0, min(e.stop, 1e9) / dt),
                burst: e.parent == nil ? SIMD4((b?.time ?? 0) / dt, Float(b?.count ?? 0), (b?.period ?? 0) / dt, Float(b?.repeats ?? 0)) : .zero,
                forces: SIMD4(e.gravity, e.drag, e.wind, e.curl),
                noise: SIMD4(e.curlFrequency, e.curlSpeed, e.vortex, e.attraction),
                attractor: SIMD4(e.attractor ?? e.position, e.restitution),
                size: SIMD4(e.size.start, e.size.end, e.sizeJitter, stretch),
                color0: e.colors.0, color1: e.colors.1, color2: e.colors.2,
                look: SIMD4(e.midpoint, e.emission, e.soft, e.spin),
                flip: SIMD4(Float(e.frames), e.fps, e.randomFrame ? 1 : 0, ParticleTextures.trim(e.atlas)),
                lock: SIMD4(lock, e.friction),
                ids: SIMD4(UInt32(bases[i]), UInt32(e.capacity), e.parent.map(UInt32.init) ?? ParticleSystem.none, flags.rawValue),
                ids2: SIMD4(UInt32(e.perEvent), e.colliders, e.orientation.code,
                            UInt32(e.atlas.rawValue) | UInt32((min(max(e.shadowDensity, 0), 1) * 255).rounded()) << 8),
                ids3: SIMD4(meshInstances[i].map(UInt32.init) ?? ParticleSystem.none, UInt32(e.trail?.points ?? 0),
                            trailBases[i].map(UInt32.init) ?? ParticleSystem.none, UInt32(e.trail?.every ?? 1)),
                extra: SIMD4(e.collisionRadius, e.trailWidth, 0, 0),
                field: SIMD4(e.field.map { Float($0.index) } ?? -1, e.field?.strength ?? 0, e.field?.follow == true ? 1 : 0,
                             e.bakedCurl ? Float(bakedCurlField ?? -1) : -1))
        }
    }

    var gpuColliders: [GPUParticleCollider] { colliders.map(\.gpu) }

    /// The baked curl tile (made once: 32^3 nodes of three noise channels' curl).
    static let curlTile = ParticleField.curl()

    /// The fields' table and their nodes, one after another (GPUParticleField.dims.w: where a field's start).
    var gpuFields: (table: [GPUParticleField], samples: [SIMD4<Float>]) {
        var table: [GPUParticleField] = [], samples: [SIMD4<Float>] = []
        for f in fields {
            var g = f.gpu
            g.dims.w = UInt32(samples.count)
            table.append(g)
            samples += f.samples.map { SIMD4($0, 0) }
        }
        return (table, samples)
    }

    /// Step `step`'s parameters; `wind`: the scene's (WindFrame.wind: xy where to, z strength); `scene`: the scene is
    /// bound, for the emitters that collide with it.
    func stepParams(_ step: Int, wind: SIMD4<Float> = .zero, scene: Bool = false) -> GPUParticleStep {
        let dt = ParticleSystem.stepLength
        let air = SIMD3<Float>(wind.x, 0, wind.y) * wind.z * ParticleSystem.windSpeed
        return GPUParticleStep(wind: SIMD4(air, Float(step) * dt), time: Float(step) * dt, dt: dt, step: UInt32(step),
                               parity: UInt32(step & 1) | (scene ? 2 : 0), emitters: UInt32(emitters.count), colliders: UInt32(colliders.count),
                               capacity: UInt32(capacity), gravity: gravity)
    }

    /// MSL particleFloor.
    static func floorCount(_ x: Float) -> Float { (x + 1e-3 + x * 2e-7).rounded(.down) }

    /// MSL particleRequests: what a root emitter asks for over step `s` (its rate's births by the step's end less
    /// those by its start, so a fraction carries; its bursts in the step). In steps, not seconds.
    static func requests(_ e: GPUParticleEmitter, _ s: GPUParticleStep) -> UInt32 {
        let k = Float(s.step)
        var n: Float = 0
        if e.life.z > 0 {
            let span = max(e.life.w - e.speed.w, 0)
            let a = min(max(k - e.speed.w, 0), span), b = min(max(k + 1 - e.speed.w, 0), span)
            n += floorCount(b * e.life.z) - floorCount(a * e.life.z)
        }
        if e.burst.y > 0 {
            if e.burst.z > 0 {
                var first = ((k - e.burst.x - 1e-3) / e.burst.z).rounded(.up), end = ((k + 1 - e.burst.x - 1e-3) / e.burst.z).rounded(.up)
                first = max(first, 0)
                if e.burst.w > 0 { end = min(end, e.burst.w) }
                n += max(end - first, 0) * e.burst.y
            } else if (e.burst.x + 1e-3).rounded(.down) == k {
                n += e.burst.y
            }
        }
        return UInt32(max(n, 0))
    }

    // MARK: - How many can be alive (the structures' sizes)

    /// What a root emitter asks for over steps a..<b: `requests` summed. Each step's count is a difference of a
    /// monotone count (births by its end less those by its start; bursts by its end less those by its start), so the
    /// sum telescopes: two evaluations, whatever the span.
    static func requests(_ e: GPUParticleEmitter, from a: Int, to b: Int) -> Int {
        guard b > a else { return 0 }
        var n: Float = 0
        if e.life.z > 0 {
            let span = max(e.life.w - e.speed.w, 0)
            func births(_ k: Int) -> Float { floorCount(min(max(Float(k) - e.speed.w, 0), span) * e.life.z) }
            n += births(b) - births(a)
        }
        if e.burst.y > 0 {
            if e.burst.z > 0 {
                // Bursts begun before step k: ceil((k - first - 1e-3) / period), clamped to 0...repeats.
                func bursts(_ k: Int) -> Float {
                    var c = max(((Float(k) - e.burst.x - 1e-3) / e.burst.z).rounded(.up), 0)
                    if e.burst.w > 0 { c = min(c, e.burst.w) }
                    return c
                }
                n += (bursts(b) - bursts(a)) * e.burst.y
            } else {
                let k = (e.burst.x + 1e-3).rounded(.down)
                if k >= Float(a) && k < Float(b) { n += e.burst.y }
            }
        }
        return Int(max(n, 0))
    }

    /// Steps a particle of emitter `e` can live, at most: born in a step and aged by it, it is gone once its age
    /// reaches its lifetime (ceil(life / dt) steps), and one to spare.
    private func lifeSteps(_ e: Int) -> Int {
        Int(min((emitters[e].lifetime.upperBound / ParticleSystem.stepLength).rounded(.up), 1e12)) + 1
    }

    /// At most how many particles emitter `e` gives birth to over steps a..<b (clipped to `cap`). A child's come from
    /// its parent's events a step earlier, each from a particle born up to its life before: a death is one event a
    /// particle; so is a collision that kills. One that doesn't can be an event every step: no bound but its pool.
    private func births(_ e: Int, from a: Int, to b: Int, cap: Int, gpu: [GPUParticleEmitter]) -> Int {
        let a = max(a, 0)
        guard b > a else { return 0 }
        let em = emitters[e]
        guard let p = em.parent else { return min(ParticleSystem.requests(gpu[e], from: a, to: b), cap) }
        if em.trigger == .collision && !emitters[p].dieOnCollision { return cap }
        let per = em.perEvent
        let parents = births(p, from: a - 1 - lifeSteps(p), to: b, cap: (cap + per - 1) / per, gpu: gpu)
        return min(parents * per, cap)
    }

    /// Per emitter, at most how many of its particles are alive once `steps` steps have run: those born within its
    /// longest life, within its pool. The pose packs the alive ones at the front of their structure's range, and
    /// the builds take only this many boxes (ParticlesGPU.encodePose).
    func aliveBounds(after steps: Int) -> [Int] {
        let gpu = gpuEmitters
        return emitters.indices.map { e in
            births(e, from: steps - lifeSteps(e) - 1, to: steps, cap: emitters[e].capacity, gpu: gpu)
        }
    }

    /// The shadow casters' and the others' bounds (aliveBounds summed by structure).
    func partBounds(after steps: Int) -> SIMD2<Int> {
        let b = aliveBounds(after: steps)
        var s = SIMD2<Int>.zero
        for (i, e) in emitters.enumerated() where e.mesh == nil { s[e.castsShadows ? 0 : 1] += b[i] }
        return s
    }
}
