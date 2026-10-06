import Foundation
import simd

/// Rigid bodies that are SDF shapes (SDFShapes.swift), falling, sliding, rolling and stacking against each other and
/// against static colliders: XPBD with small substeps (Müller et al. 2020, Macklin et al. 2019). And particles: small
/// balls that pile up against each other and that the bodies and the static colliders push about (they don't push
/// the bodies back), as in Macklin et al. 2014's unified particles, in the same substeps.
///
/// A step (1/60 s) finds what may touch (a hash grid over the bodies' bounding spheres; every static collider whose
/// box a body's sphere meets), then each pair's contacts (PhysicsCollide.swift), then runs `substeps` substeps: move
/// every body by its velocity, push the contacts apart and hold them by static friction, take the velocities from how
/// far the bodies went, then apply dynamic friction, restitution and rolling and spinning resistance. The contacts are
/// found again every `contactRefresh` substeps (a turning body's go stale), and solved Gauss-Seidel, a colour of pairs
/// at a time: no two pairs of a colour share a body, so the GPU (Shaders/Physics.metal) solves a colour's at once and
/// gets the same numbers. Nothing adds floats atomically, so a run is the same every time. Bodies that have barely
/// moved for half a second, and whose neighbours have settled too, sleep until something moving touches them.
///
/// Time: `advance(to:)` takes the scene's animation time (so Pause and Time scale apply) and steps until the
/// simulation is no more than a step behind it. Going back in time replays from the start, so any time's state is
/// the same however it was reached (a benchmark's stills start at 5 s).
final class PhysicsWorld {
    static let staticBit: UInt32 = 0x8000_0000
    static let none: UInt32 = ~0
    /// info.y flags: a body's, and a particle's.
    static let asleep: UInt32 = 1
    static let clothBit: UInt32 = 1
    /// How many pairs a body may be in (more are dropped: statics and the lowest bodies stay) and contacts a pair may have.
    static let maxPairs = 16
    static let maxContacts = PhysicsManifold.capacity
    /// Rounds of colouring a step's pairs (Jones-Plassmann) before the rest are solved one after another (their
    /// GPUPhysicsPair.pad), and the most colours there can be (a pair shares its bodies with 30 others at most).
    static let maxRounds = 64
    static let maxColours = 32
    static let leftover: UInt32 = 0xFFFF_FFFE
    /// The contacts are found again every this many substeps.
    static let contactRefresh = 4
    static let stepLength: Float = 1.0 / 60
    static let topSpeed: Float = 30
    /// A body's sphere reaches as far as it goes in a step at up to this speed (faster ones lean on the substeps):
    /// what keeps the grid's cells small enough that a dense pile doesn't put dozens of bodies in each.
    static let cellSpeed: Float = 10
    static let margin: Float = 0.01
    /// The fastest an overlap is pushed apart (m/s).
    static let pushSpeed: Float = 3
    /// A particle keeps its nearest `maxNeighbours` particles and lowest `maxColliders` colliders (statics first).
    static let maxNeighbours = 16
    static let maxColliders = 8
    /// A particle's reach allows for this speed (m/s): what its grid's cells are sized for.
    static let particleSpeed: Float = 2
    /// How fast the air slows a cloth's vertices (1/s): without it a hanging cloth swings on and on.
    static let clothDrag: Float = 2
    /// A held body's anchor goes this fraction of the way to the target each substep, and the body's velocities fade
    /// at this rate (1/s) so that it doesn't swing about the cursor.
    static let holdPull: Float = 0.03
    static let holdDamping: Float = 8
    /// A particle in a heap going slower than this (m/s) over a substep stays put.
    static let particleRest: Float = 0.1
    /// How far ahead of a rolling body's contact the floor pushes back, and how wide a contact is against spinning on
    /// the spot (m): what brings a ball, a cone or a lying cylinder to a stop (without them they roll on for ever).
    static let rollingResistance: Float = 0.004
    static let spinningResistance: Float = 0.02

    var gravity = SIMD3<Float>(0, -9.81, 0)
    let substeps: Int

    /// What the shapes are made of: their distances and samples (PhysicsCollide.swift).
    private(set) var shapes: [GPUPhysicsShape] = []
    private(set) var samples: [SIMD4<Float>] = []
    private(set) var sdfShapes: [SDFShape] = []
    private(set) var sdfVolumes: [SDFVolume] = []
    private var shapeOf: [Int: Int] = [:]   // SDF shape -> its physics shape
    private var massOf: [Int: (volume: Float, moments: SIMD3<Float>)] = [:]

    /// The state (dynamic bodies, then the static colliders and their world boxes), as the GPU has it.
    var bodies: [GPUPhysicsBody] = []
    private(set) var statics: [GPUPhysicsBody] = []
    private(set) var staticBounds: [AABB] = []
    /// The state at the start (what a replay starts from).
    private(set) var initialBodies: [GPUPhysicsBody] = []
    /// Per body, `maxPairs` entries (`pairCounts` of them used), and per entry `maxContacts` contacts.
    var pairs: [GPUPhysicsPair] = []
    var pairCounts: [UInt32] = []
    var contacts: [GPUPhysicsContact] = []
    /// This step's owned pairs with contacts, by colour (PhysicsCPU.colourPairs), and where each colour starts; the
    /// last colour is what the rounds left, solved one pair after another.
    var pairOrder: [UInt32] = []
    var pairColourStarts: [UInt32] = [0]

    /// The body the mouse holds, if any (`target.w` = 1), which the substeps pull to the target; the GPU takes a copy
    /// each frame (PhysicsGPU.setGrab).
    var grab = GPUPhysicsGrab()
    /// The poses the bodies were last drawn with when the GPU steps them (its snapshot, a position and a rotation per
    /// body): what picking sees. Empty when the CPU steps them (then `bodies` are).
    var drawnPoses: [SIMD4<Float>] = []

    /// The particles, their start, and per particle its neighbours and the colliders it may touch this step.
    var particles: [GPUPhysicsParticle] = []
    private(set) var initialParticles: [GPUPhysicsParticle] = []
    var neighbours: [UInt32] = []
    var neighbourCounts: [UInt32] = []
    var colliders: [UInt32] = []
    var colliderCounts: [UInt32] = []
    /// The cloths' distance constraints, by colour (no two of a colour share a vertex: each colour is solved at once,
    /// one after the other, Gauss-Seidel), and where each colour starts (`colours + 1` entries).
    private(set) var constraints: [GPUPhysicsConstraint] = []
    private(set) var colourStarts: [UInt32] = [0]
    /// Each cloth: its first particle, its grid, and its first vertex in the scene's vertex buffer.
    struct Cloth {
        var first: Int
        var columns: Int
        var rows: Int
        var vertexBase: Int
    }
    private(set) var cloths: [Cloth] = []
    /// For the GPU: per cloth its first particle, columns, rows and first vertex, then its last frame's vertices'
    /// offset (Scene.finishDeforming), as MSL PhysicsCloth has them.
    func clothTable(prevOffsets: [UInt32]) -> [SIMD4<UInt32>] {
        zip(cloths, prevOffsets).flatMap { c, prev in
            [SIMD4(UInt32(c.first), UInt32(c.columns), UInt32(c.rows), UInt32(c.vertexBase)), SIMD4(prev, 0, 0, 0)]
        }
    }
    private var unsortedConstraints: [GPUPhysicsConstraint] = []

    /// How far the simulation has gone (whole steps).
    var stepIndex = 0
    var time: Float { Float(stepIndex) * PhysicsWorld.stepLength }

    init(substeps: Int) {
        self.substeps = max(substeps, 1)
    }

    // MARK: - Building

    /// The physics shape of SDF shape `sdf` (made the first time it is asked for).
    private func shape(sdf: Int, _ shape: SDFShape) -> Int {
        if let s = shapeOf[sdf] { return s }
        while sdfShapes.count <= sdf { sdfShapes.append(shape) }
        sdfShapes[sdf] = shape
        var build = PhysicsWorld.buildShape(shape, index: sdf, volumes: sdfVolumes)
        build.shape.info.y = UInt32(samples.count)
        build.shape.info.z = UInt32(build.samples.count)
        samples += build.samples
        shapes.append(build.shape)
        shapeOf[sdf] = shapes.count - 1
        massOf[shapes.count - 1] = (build.volume, build.moments)
        return shapes.count - 1
    }

    /// The scene's baked grids, for shapes made of them (before any such shape is added).
    func setVolumes(_ volumes: [SDFVolume]) { sdfVolumes = volumes }

    /// The pose of shape `s`'s body whose shape space is placed by `transform` (a rotation and a translation).
    private func pose(shape s: Int, _ transform: float4x4) -> (SIMD3<Float>, SIMD4<Float>) {
        let shape = shapes[s]
        let rotation = PhysicsMath.quat(simd_quatf(simd_float3x3(columns: (PhysicsMath.xyz(transform.columns.0),
                                                                           PhysicsMath.xyz(transform.columns.1),
                                                                           PhysicsMath.xyz(transform.columns.2)))))
        let q = PhysicsMath.qnormalize(PhysicsMath.qmul(rotation, shape.comRotation))
        let p = transform * SIMD4(PhysicsMath.xyz(shape.comPosition), 1)
        return (PhysicsMath.xyz(p), q)
    }

    /// A body moving `instance`, SDF shape `sdf`, placed by `transform` (no scale); `density` kg/m^3.
    @discardableResult
    func addBody(sdf: Int, _ shape: SDFShape, transform: float4x4, instance: Int, density: Float = 500, friction: Float = 0.5,
                 restitution: Float = 0.2, velocity: SIMD3<Float> = .zero, spin: SIMD3<Float> = .zero) -> Int {
        let s = self.shape(sdf: sdf, shape)
        let (p, q) = pose(shape: s, transform)
        let mass = massOf[s]!
        let m = density * mass.volume
        var b = GPUPhysicsBody()
        b.position = SIMD4(p, 1 / m)
        b.rotation = q
        b.velocity = SIMD4(velocity, friction)
        b.angular = SIMD4(spin, restitution)
        b.prevPosition = SIMD4(p, 0)
        b.prevRotation = q
        b.invInertia = SIMD4(1 / (density * mass.moments), shapes[s].comPosition.w)
        b.info = SIMD4(UInt32(s), 0, UInt32(instance), 0)
        bodies.append(b)
        return bodies.count - 1
    }

    /// A static collider: SDF shape `sdf` placed by `transform` (it needn't be drawn).
    func addStatic(sdf: Int, _ shape: SDFShape, transform: float4x4, friction: Float = 0.6, restitution: Float = 0.2) {
        let s = self.shape(sdf: sdf, shape)
        let (p, q) = pose(shape: s, transform)
        var b = GPUPhysicsBody()
        b.position = SIMD4(p, 0)
        b.rotation = q
        b.velocity = SIMD4(.zero, friction)
        b.angular = SIMD4(.zero, restitution)
        b.prevPosition = SIMD4(p, 0)
        b.prevRotation = q
        b.invInertia = SIMD4(.zero, shapes[s].comPosition.w)
        b.info = SIMD4(UInt32(s), 0, PhysicsWorld.none, 0)
        statics.append(b)
        staticBounds.append(shape.bounds(volumes: sdfVolumes).transformed(transform))
    }

    /// An endless static plane through `point`, facing `normal`.
    func addPlane(point: SIMD3<Float>, normal: SIMD3<Float>, friction: Float = 0.6, restitution: Float = 0.2) {
        if shapes.firstIndex(where: { $0.info.x == PhysicsShapeKind.plane.rawValue }) == nil {
            shapes.append(GPUPhysicsShape(comPosition: SIMD4(0, 0, 0, 0), info: SIMD4(PhysicsShapeKind.plane.rawValue, 0, 0, 0)))
        }
        let s = shapes.firstIndex { $0.info.x == PhysicsShapeKind.plane.rawValue }!
        var b = GPUPhysicsBody()
        let q = PhysicsMath.quat(simd_quatf(from: SIMD3(0, 1, 0), to: normalize(normal)))
        b.position = SIMD4(point, 0)
        b.rotation = q
        b.velocity = SIMD4(.zero, friction)
        b.angular = SIMD4(.zero, restitution)
        b.prevPosition = SIMD4(point, 0)
        b.prevRotation = q
        b.invInertia = SIMD4(.zero, 0)   // no bounding sphere: it is tested by its plane
        b.info = SIMD4(UInt32(s), 0, PhysicsWorld.none, 0)
        statics.append(b)
        staticBounds.append(AABB(lo: SIMD3(repeating: -.infinity), hi: SIMD3(repeating: .infinity)))
    }

    /// A particle moving `instance` (a sphere of `radius` centred on its origin).
    func addParticle(at position: SIMD3<Float>, radius: Float, instance: Int, density: Float = 1500, friction: Float = 0.5,
                     velocity: SIMD3<Float> = .zero) {
        let mass = density * 4 / 3 * Float.pi * radius * radius * radius
        particles.append(GPUPhysicsParticle(position: SIMD4(position, radius), velocity: SIMD4(velocity, friction),
                                            prevPosition: SIMD4(position, 1 / mass), info: SIMD4(UInt32(instance), 0, 0, 0)))
    }

    /// A cloth: `columns` x `rows` vertices from `origin` along `across` and `down` (the whole width and height),
    /// each a particle of `thickness` radius; `pinned` vertices (row-major indices) never move. `vertexBase`: where its
    /// vertices are in the scene's vertex buffer (the mesh that draws it). Stretch and shear hold it (`stretch`
    /// compliance), every other vertex along the rows and columns bends it (`bend`).
    func addCloth(origin: SIMD3<Float>, across: SIMD3<Float>, down: SIMD3<Float>, columns: Int, rows: Int, pinned: Set<Int>,
                  thickness: Float, density: Float = 0.3, friction: Float = 0.6, vertexBase: Int,
                  stretch: Float = 0, bend: Float = 2e-3) {
        let first = particles.count
        let area = length(across) * length(down)
        let mass = density * area / Float(columns * rows)   // kg/m^2 over the vertices
        func at(_ c: Int, _ r: Int) -> SIMD3<Float> {
            origin + across * Float(c) / Float(columns - 1) + down * Float(r) / Float(rows - 1)
        }
        for r in 0..<rows {
            for c in 0..<columns {
                let v = r * columns + c
                particles.append(GPUPhysicsParticle(position: SIMD4(at(c, r), thickness), velocity: SIMD4(.zero, friction),
                                                    prevPosition: SIMD4(at(c, r), pinned.contains(v) ? 0 : 1 / mass),
                                                    info: SIMD4(PhysicsWorld.none, PhysicsWorld.clothBit, UInt32(vertexBase + v),
                                                                UInt32(cloths.count))))
            }
        }
        func link(_ c0: Int, _ r0: Int, _ c1: Int, _ r1: Int, _ compliance: Float) {
            guard c1 >= 0, c1 < columns, r1 < rows else { return }
            let a = first + r0 * columns + c0, b = first + r1 * columns + c1
            unsortedConstraints.append(GPUPhysicsConstraint(a: UInt32(a), b: UInt32(b),
                                                            rest: length(at(c0, r0) - at(c1, r1)), compliance: compliance))
        }
        for r in 0..<rows {
            for c in 0..<columns {
                link(c, r, c + 1, r, stretch)
                link(c, r, c, r + 1, stretch)
                link(c, r, c + 1, r + 1, stretch)
                link(c, r, c - 1, r + 1, stretch)
                link(c, r, c + 2, r, bend)
                link(c, r, c, r + 2, bend)
            }
        }
        cloths.append(Cloth(first: first, columns: columns, rows: rows, vertexBase: vertexBase))
    }

    /// The constraints in colours: each takes the first colour none of its vertices' constraints has (greedy).
    private func colourConstraints() {
        var used: [Int: UInt64] = [:]   // per vertex, the colours its constraints have
        var colour = [Int](repeating: 0, count: unsortedConstraints.count)
        for (i, k) in unsortedConstraints.enumerated() {
            let taken = (used[Int(k.a)] ?? 0) | (used[Int(k.b)] ?? 0)
            let c = (~taken).trailingZeroBitCount
            precondition(c < 64, "a cloth vertex in more than 63 constraints")
            colour[i] = c
            used[Int(k.a), default: 0] |= 1 << c
            used[Int(k.b), default: 0] |= 1 << c
        }
        let colours = (colour.max() ?? -1) + 1
        constraints = []
        colourStarts = [0]
        for c in 0..<colours {
            constraints += unsortedConstraints.indices.filter { colour[$0] == c }.map { unsortedConstraints[$0] }
            colourStarts.append(UInt32(constraints.count))
        }
    }

    /// Once everything is in: the arrays the steps use, and the start to replay from.
    func finish() {
        colourConstraints()
        pairs = [GPUPhysicsPair](repeating: GPUPhysicsPair(), count: bodies.count * PhysicsWorld.maxPairs)
        pairCounts = [UInt32](repeating: 0, count: bodies.count)
        contacts = [GPUPhysicsContact](repeating: GPUPhysicsContact(), count: pairs.count * PhysicsWorld.maxContacts)
        neighbours = [UInt32](repeating: 0, count: particles.count * PhysicsWorld.maxNeighbours)
        neighbourCounts = [UInt32](repeating: 0, count: particles.count)
        colliders = [UInt32](repeating: 0, count: particles.count * PhysicsWorld.maxColliders)
        colliderCounts = [UInt32](repeating: 0, count: particles.count)
        initialBodies = bodies
        initialParticles = particles
    }

    /// Back to the start.
    func reset() {
        bodies = initialBodies
        particles = initialParticles
        stepIndex = 0
    }

    /// The grid's cell: twice the largest bounding sphere a body may have in a step (its radius, its travel, the margin).
    var cellSize: Float {
        let r = bodies.map(\.invInertia.w).max() ?? 1
        return 2 * (r + PhysicsWorld.cellSpeed * PhysicsWorld.stepLength + PhysicsWorld.margin)
    }

    /// Buckets of the GPU's hash grid: a power of two, twice the bodies at least.
    var buckets: Int { PhysicsWorld.buckets(bodies.count) }
    var particleBuckets: Int { PhysicsWorld.buckets(particles.count) }
    static func buckets(_ n: Int) -> Int { max(64, 1 << Int(ceil(log2(Double(max(n, 1) * 2))))) }

    /// The particles' grid cell: twice the largest reach a particle has in a step.
    var particleCellSize: Float {
        let r = particles.map(\.position.w).max() ?? 0.05
        return 2 * (r + PhysicsWorld.particleSpeed * PhysicsWorld.stepLength + PhysicsWorld.margin)
    }

    var params: GPUPhysicsParams {
        GPUPhysicsParams(gravity: SIMD4(gravity, PhysicsWorld.stepLength / Float(substeps)),
                         counts: SIMD4(UInt32(bodies.count), UInt32(statics.count), UInt32(PhysicsWorld.maxPairs), UInt32(buckets)),
                         grid: SIMD4(cellSize, PhysicsWorld.margin, PhysicsWorld.topSpeed, PhysicsWorld.stepLength),
                         sleep: SIMD4(0.05, 0.08, 0.5, PhysicsWorld.cellSpeed),
                         particles: SIMD4(UInt32(particles.count), UInt32(particleBuckets), UInt32(PhysicsWorld.maxNeighbours),
                                          UInt32(PhysicsWorld.maxColliders)),
                         particleGrid: SIMD4(particleCellSize, PhysicsWorld.particleSpeed, PhysicsWorld.clothDrag, PhysicsWorld.particleRest),
                         cloth: SIMD4(UInt32(constraints.count), UInt32(colourStarts.count - 1), 0, 0),
                         rolling: SIMD4(PhysicsWorld.rollingResistance, PhysicsWorld.spinningResistance, 0.1, 0.16))
    }

    // MARK: - Time

    /// How many steps reach `time` (from the start again if it is behind: `reset` first, which this says). Before 0
    /// the world waits at its start.
    func stepsTo(_ time: Float) -> (steps: Int, restart: Bool) {
        let target = max(Int((time / PhysicsWorld.stepLength).rounded(.down)), 0)
        return target < stepIndex ? (target, true) : (target - stepIndex, false)
    }

    /// Steps on the CPU to `time`.
    func advance(to time: Float) {
        let (steps, restart) = stepsTo(time)
        if restart { reset() }
        for _ in 0..<steps { step() }
    }

    /// For the GPU: the steps that reach `time` (from the start, `restart`), counted as run.
    func claim(to time: Float) -> (steps: Int, restart: Bool) {
        let (steps, restart) = stepsTo(time)
        if restart { stepIndex = 0 }
        stepIndex += steps
        return (steps, restart)
    }

    // MARK: - Picking

    /// Body `i`'s pose as last drawn.
    func drawnPose(_ i: Int) -> (position: SIMD3<Float>, rotation: SIMD4<Float>) {
        drawnPoses.count == 2 * bodies.count ? (PhysicsMath.xyz(drawnPoses[2 * i]), drawnPoses[2 * i + 1])
                                             : (PhysicsMath.xyz(bodies[i].position), bodies[i].rotation)
    }

    /// The nearest body the ray from `origin` along `direction` (unit) meets, where it meets it (in the body's space)
    /// and how far along: each body whose bounding sphere the ray crosses, sphere-traced through its distance.
    func pick(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (body: Int, anchor: SIMD3<Float>, distance: Float)? {
        var best: (body: Int, anchor: SIMD3<Float>, distance: Float)?
        for i in bodies.indices {
            let (x, q) = drawnPose(i)
            let radius = bodies[i].invInertia.w, oc = origin - x
            let b = dot(oc, direction), c = dot(oc, oc) - radius * radius, disc = b * b - c
            guard disc >= 0 else { continue }
            var t = max(-b - sqrt(disc), 0)
            let end = min(-b + sqrt(disc), best?.distance ?? .infinity)
            for _ in 0..<64 where t < end {
                let local = PhysicsMath.qrot(PhysicsMath.qconj(q), origin + direction * t - x)
                let d = distance(shape: Int(bodies[i].info.x), local)
                if d < 1e-3 {
                    best = (i, local, t)
                    break
                }
                t += max(d, 1e-4)
            }
        }
        return best
    }

    // MARK: - Drawing

    /// Body `i`'s instance transform: its shape space in the world.
    func transform(_ i: Int) -> float4x4 {
        transform(i, position: PhysicsMath.xyz(bodies[i].position), rotation: bodies[i].rotation)
    }

    /// Particle `i`'s instance transform.
    func particleTransform(_ i: Int) -> float4x4 { translate(PhysicsMath.xyz(particles[i].position)) }

    /// ...for the pose given (the GPU's).
    func transform(_ i: Int, position: SIMD3<Float>, rotation: SIMD4<Float>) -> float4x4 {
        let shape = shapes[Int(bodies[i].info.x)]
        let q = PhysicsMath.qmul(rotation, PhysicsMath.qconj(shape.comRotation))
        return translate(position) * float4x4(PhysicsMath.simdQuat(q)) * translate(-PhysicsMath.xyz(shape.comPosition))
    }
}
