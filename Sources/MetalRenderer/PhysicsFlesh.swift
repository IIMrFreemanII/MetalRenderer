import Foundation
import simd

/// Flesh on bones: soft tissue whose lattice (PhysicsSoft.swift) is held to a skeleton, with muscles in it that
/// contract as the joints they cross bend, under a skin (PhysicsSkin.swift).
///
/// The bones are bodies: a ragdoll's, which the physics moves, or a character's, which an animation moves. Those are
/// kinematic bodies: each step they go where a table of poses says (a row a step, baked from the character's clips
/// before the first: PhysicsRig.swift), whatever touches them, which they push, carry along by friction and wake.
/// The table repeats, so any step's pose is its row's, and a replay from the start is the same on both backends.
///
/// The flesh's particles are pinned to their bones by how deep they are (Position-Based Skinning, Abu Rumman and
/// Fratarcangeli 2015; Projective Skinning, Komaritzan and Botsch 2018): a core particle sits where its two nearest
/// bones put its rest point, blended by their weights (it has no mass: the rest is held to it); a particle further out
/// is pulled there by an XPBD constraint, softer the further out it is; one near the surface is free. A muscle is the
/// tets inside its belly: each tet's fibre (along the belly at rest) shortens by up to a share of its length as the
/// muscle's activation rises (Romeo et al. 2020's fibre constraint), with the angle between the bones it crosses, and
/// the tet's volume constraint makes it bulge. All of it one-way: the bones never feel the flesh.
///
/// Each substep, after the bodies and particles move: the muscles' activations and the pins (a barrier), the links
/// and tets (a tet's fibre with its volume), the skin's holds, then the particles' collisions. A figure's particles
/// don't collide with its own bones (GPUPhysicsParticle.info.z: the bones' first << 8 | how many).
extension PhysicsWorld {
    @inline(__always) static func kinematic(_ b: GPUPhysicsBody) -> Bool { b.info.y & kinematicBit != 0 }

    // MARK: Kinematic bodies

    /// Kinematic body `b`'s pose `alpha` of the way through step `step`: from the table's row for the step to the next.
    func kinematicPose(_ b: GPUPhysicsBody, step: Int, alpha: Float) -> Pose {
        let column = Int(b.info.y >> 8), rows = kinematicRows
        let a = ((step % rows) * kinematicColumns + column) * 2, e = (((step + 1) % rows) * kinematicColumns + column) * 2
        return PhysicsWorld.between(PhysicsMath.xyz(kinematicTable[a]), kinematicTable[a + 1],
                                    PhysicsMath.xyz(kinematicTable[e]), kinematicTable[e + 1], alpha)
    }

    /// Kinematic body `b` to `pose` over a substep of `h`: its velocities from how far it went (what friction and the
    /// contacts' speeds see).
    @inline(__always) static func moveKinematic(_ b: inout GPUPhysicsBody, to pose: Pose, h: Float) {
        b.prevPosition = SIMD4(PhysicsMath.xyz(b.position), b.prevPosition.w)
        b.prevRotation = b.rotation
        b.position = SIMD4(pose.position, b.position.w)
        b.rotation = pose.rotation
        b.velocity = SIMD4((pose.position - PhysicsMath.xyz(b.prevPosition)) / h, b.velocity.w)
        var dq = PhysicsMath.qmul(b.rotation, PhysicsMath.qconj(b.prevRotation))
        if dq.w < 0 { dq = -dq }
        b.angular = SIMD4(2 * PhysicsMath.xyz(dq) / h, b.angular.w)
    }

    // MARK: Muscles and pins

    /// Muscle `m`'s activation, with its bones `a` and `b` where they are: how far the angle between their axes is
    /// from where it starts to where it is full.
    @inline(__always) static func activation(_ m: GPUMuscle, _ a: GPUPhysicsBody, _ b: GPUPhysicsBody) -> Float {
        let u = PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(m.axisA)), v = PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(m.axisB))
        let angle = atan2(length(cross(u, v)), dot(u, v))
        let f = (angle - m.range.x) / (m.range.y - m.range.x)
        return m.range.z * min(max(f, 0), 1)
    }

    /// Where pin `pin`'s bones `a` and `b` put its particle.
    @inline(__always) static func pinTarget(_ pin: GPUFleshPin, _ a: GPUPhysicsBody, _ b: GPUPhysicsBody) -> SIMD3<Float> {
        (PhysicsMath.xyz(a.position) + PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(pin.restA))) * pin.restA.w
            + (PhysicsMath.xyz(b.position) + PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(pin.restB))) * pin.restB.w
    }

    /// Particle `q` held by `pin` to `target` over a substep of `h`: one of no mass put there, another pulled
    /// (an XPBD constraint of the pin's compliance, its lambda from 0).
    @inline(__always) static func pin(_ q: inout GPUPhysicsParticle, _ pin: GPUFleshPin, to target: SIMD3<Float>, h: Float) {
        let w = q.prevPosition.w
        if w > 0 {
            let k = w / (w + pin.compliance / (h * h))
            q.position = SIMD4(PhysicsMath.xyz(q.position) + (target - PhysicsMath.xyz(q.position)) * k, q.position.w)
        } else {
            q.prevPosition = SIMD4(PhysicsMath.xyz(q.position), 0)
            q.position = SIMD4(target, q.position.w)
            q.velocity = SIMD4((target - PhysicsMath.xyz(q.prevPosition)) / h, q.velocity.w)
        }
    }

    /// The muscles' activations, then every pinned particle held to its bones, where this substep moved them.
    func solveFlesh(_ p: GPUPhysicsParams) {
        for (m, muscle) in muscles.enumerated() {
            activations[m] = PhysicsWorld.activation(muscle, bodies[Int(muscle.bodyA)], bodies[Int(muscle.bodyB)])
        }
        for pin in pins {
            let target = PhysicsWorld.pinTarget(pin, bodies[Int(pin.bodyA)], bodies[Int(pin.bodyB)])
            PhysicsWorld.pin(&particles[Int(pin.particle)], pin, to: target, h: p.gravity.w)
        }
    }

    /// A muscle's tet's fibre (before its volume, in the same pass): XPBD on the fibre's stretch, |Ds g| (Ds the tet's
    /// edges now, g = Dm^-1 f), toward 1 less its shortening at the muscle's activation, damped along its gradient as
    /// the volume is.
    func solveFibre(_ t: GPUPhysicsTet, _ h: Float) {
        let f = fibres[Int(t.fibre) - 1]
        let i = [Int(t.ids.x), Int(t.ids.y), Int(t.ids.z), Int(t.ids.w)]
        let x = i.map { PhysicsMath.xyz(particles[$0].position) }
        let w = i.map { particles[$0].prevPosition.w }
        let v = (x[1] - x[0]) * f.g.x + (x[2] - x[0]) * f.g.y + (x[3] - x[0]) * f.g.z
        let l = length(v)
        guard l > 1e-9 else { return }
        let n = v / l
        let g = [-(f.g.x + f.g.y + f.g.z) * n, f.g.x * n, f.g.y * n, f.g.z * n]
        let alpha = f.compliance / (h * h), gamma = f.compliance * t.damping / h
        var sum: Float = 0, moved: Float = 0
        for k in 0..<4 {
            sum += w[k] * length_squared(g[k])
            moved += dot(g[k], x[k] - PhysicsMath.xyz(particles[i[k]].prevPosition))
        }
        let denominator = (1 + gamma) * sum + alpha
        guard denominator > 1e-12 else { return }
        let lambda = (-(l - (1 - f.g.w * activations[Int(f.muscle)])) - gamma * moved) / denominator
        for k in 0..<4 { particles[i[k]].position += SIMD4(g[k] * (lambda * w[k]), 0) }
    }

    // MARK: Building

    /// How a figure's flesh is made: its lattice's spacing, how heavy and how soft it is, how much its muscles do.
    struct FleshOptions {
        var spacing: Float = 0.035
        var density: Float = 1050
        /// Its links' compliance, and the outer layer's (all of its links' particles near the surface): skin tension.
        var edge: Float = 2e-4
        var skinEdge: Float = 4e-5
        /// Its tets' (m^3/N): flesh is nearly incompressible. (A jelly's 1e-9 is soft beside a 3.5 cm tet's own
        /// stiffness: a contracting muscle lost 8% of its volume rather than bulge.)
        var volume: Float = 1e-11
        var damping: Float = PhysicsWorld.softLinkDamping
        var friction: Float = 0.8
        /// The muscles' activations are scaled by this (0: none contract).
        var muscleGain: Float = 1
        /// How far a muscle's middle shortens at full activation (a share of its length).
        var shortening: Float = 0.4
        var fibreCompliance: Float = 1e-6
    }

    /// Depths (FleshFigure.depth) of the core, held where its bones put it, and of the free surface layer; between
    /// them the pins' compliance rises from `firmPin` to `loosePin`.
    static let coreDepth: Float = 0.45
    static let freeDepth: Float = 0.85
    static let firmPin: Float = 1e-7
    static let loosePin: Float = 1e-4

    /// What `addFlesh` made: its particles (`model`'s points from `first`) and its soft body.
    struct Flesh {
        var model: SoftModel
        var first: Int
        var body: Int
        /// Per point, its pin's two bones (figure bones) and weights.
        var bones: [(SIMD2<Int>, SIMD2<Float>)]
    }

    /// A figure's flesh: `model`, a lattice in the figure's rest space (SoftModel(_:spacing:)), each point pinned by its
    /// depth to its two nearest bones and starting where they put it; its tets in `muscles`' bellies with fibres.
    func addFlesh(_ lattice: SoftModel, figure: FleshFigure, muscles specs: [MuscleSpec], _ o: FleshOptions) -> Flesh {
        let first = particles.count, body = softBodies.count
        let bodies = figure.bodies
        // Each tet binds the bones its corners are nearest to only at their joint (FleshFigure.joins): a limb lying
        // along the trunk, or two legs together, keep apart.
        var model = lattice
        let nearest = model.points.map { p in figure.bones.indices.min { figure.depth(figure.bones[$0], p) < figure.depth(figure.bones[$1], p) }! }
        model.prune(keeping: model.tets.map { t in
            let ids = [t.x, t.y, t.z, t.w].map { nearest[Int($0)] }
            let centre = (model.points[Int(t.x)] + model.points[Int(t.y)] + model.points[Int(t.z)] + model.points[Int(t.w)]) / 4
            return ids.allSatisfy { a in ids.allSatisfy { b in a == b || figure.joins(a, b, at: centre) } }
        })
        // Each point's two nearest bones (by depth) and their weights, and how deep it is.
        var bones: [(SIMD2<Int>, SIMD2<Float>)] = [], depths: [Float] = []
        for p in model.points {
            // (Its second bone is the nearest joined to the first: blended across two bones apart, say both thighs,
            // its target would be between them as they part.)
            let d = figure.bones.map { figure.depth($0, p) }
            let order = d.indices.sorted { d[$0] < d[$1] || (d[$0] == d[$1] && $0 < $1) }
            let a = order[0]
            let b = order.dropFirst().first { figure.bones[$0].parent == a || figure.bones[a].parent == $0 } ?? a
            let wa = 1 / pow(max(d[a], 0.05), 4), wb = a == b ? 0 : 1 / pow(max(d[b], 0.05), 4)
            bones.append((SIMD2(a, b), SIMD2(wa, wb) / (wa + wb)))
            depths.append(d[a])
        }
        // The muscles: each tet whose middle is in a belly gets a fibre along it.
        var fibreOf = [Int](repeating: -1, count: model.tets.count)
        for spec in specs {
            guard let m = spec.resolve(figure, gain: o.muscleGain) else { continue }
            let index = UInt32(muscles.count)
            var found = false
            for (t, tet) in model.tets.enumerated() where fibreOf[t] < 0 {
                let centre = (model.points[Int(tet.x)] + model.points[Int(tet.y)] + model.points[Int(tet.z)] + model.points[Int(tet.w)]) / 4
                let axis = m.insertion - m.origin, u = dot(centre - m.origin, axis) / dot(axis, axis)
                guard u > 0, u < 1, length(centre - (m.origin + axis * u)) < m.radius else { continue }
                // A tet squashed flat at rest (the lattice's corners moved onto the surface) has a fibre far stiffer
                // than its neighbours' (its g as much as 25 times theirs), which shook the flesh: it keeps its volume
                // and links, and no fibre.
                let g = model.inverses[t] * normalize(axis)
                guard length(g) * model.spacing < 3 else { continue }
                fibreOf[t] = fibres.count
                fibres.append(GPUFleshFibre(g: SIMD4(g, o.shortening * sin(.pi * u)), muscle: index, compliance: o.fibreCompliance))
                found = true
            }
            if found {
                muscles.append(m.record)
                activations.append(0)
            }
        }
        let inMuscle = Set(model.tets.indices.filter { fibreOf[$0] >= 0 }.flatMap { [model.tets[$0].x, model.tets[$0].y, model.tets[$0].z, model.tets[$0].w] })
        func rest(_ bone: Int, _ p: SIMD3<Float>) -> SIMD4<Float> {
            let pose = figure.bones[bone].restPose
            return SIMD4(PhysicsMath.qrot(PhysicsMath.qconj(pose.rotation), p - pose.position), 0)
        }
        for (i, p) in model.points.enumerated() {
            let (pair, w) = bones[i]
            var pin = GPUFleshPin()
            pin.restA = rest(pair.x, p)
            pin.restA.w = w.x
            pin.restB = rest(pair.y, p)
            pin.restB.w = w.y
            pin.particle = UInt32(first + i)
            pin.bodyA = UInt32(figure.bones[pair.x].body)
            pin.bodyB = UInt32(figure.bones[pair.y].body)
            // Hard only where one bone holds it: where two blend (a joint), the blend loses volume (as linear blend
            // skinning does), and held hard the tets would push the one particle among them that gives by all of it.
            // Nor in a muscle's belly, which has to move to bulge: held loosely there (held firmly, the pins put the
            // belly back where the bones alone would every substep, and a contracting muscle lost volume instead).
            let depth = depths[i], belly = inMuscle.contains(UInt32(i))
            let hard = depth < PhysicsWorld.coreDepth && w.x > 0.9 && !belly
            let x = PhysicsWorld.pinTarget(pin, self.bodies[Int(pin.bodyA)], self.bodies[Int(pin.bodyB)])
            let mass = o.density * model.shares[i]
            particles.append(GPUPhysicsParticle(position: SIMD4(x, model.radius), velocity: SIMD4(.zero, o.friction),
                                                prevPosition: SIMD4(x, hard ? 0 : 1 / max(mass, 1e-6)),
                                                info: SIMD4(PhysicsWorld.none, PhysicsWorld.softBit,
                                                            UInt32(bodies.lowerBound) << 8 | UInt32(bodies.count), UInt32(body))))
            guard depth < PhysicsWorld.freeDepth else { continue }
            let f = max(depth - PhysicsWorld.coreDepth, 0) / (PhysicsWorld.freeDepth - PhysicsWorld.coreDepth)
            pin.compliance = hard ? 0 : belly ? PhysicsWorld.loosePin : PhysicsWorld.firmPin * pow(PhysicsWorld.loosePin / PhysicsWorld.firmPin, f)
            pins.append(pin)
        }
        let base = UInt32(first)
        for e in model.edges {
            let outer = depths[Int(e.x)] > PhysicsWorld.freeDepth && depths[Int(e.y)] > PhysicsWorld.freeDepth
            let belly = inMuscle.contains(e.x) && inMuscle.contains(e.y)
            unsortedConstraints.append(GPUPhysicsConstraint(a: e.x + base, b: e.y + base, rest: length(model.points[Int(e.x)] - model.points[Int(e.y)]),
                                                            compliance: outer ? o.skinEdge : belly ? o.edge * 10 : o.edge))
        }
        for (t, tet) in model.tets.enumerated() {
            unsortedTets.append(GPUPhysicsTet(ids: tet &+ base, rest: SoftModel.sixVolume(model.points, tet), compliance: o.volume,
                                              damping: o.damping, fibre: fibreOf[t] < 0 ? 0 : UInt32(fibreOf[t] + 1)))
        }
        softBodies.append(SIMD2(UInt32(first), UInt32(model.points.count)))
        return Flesh(model: model, first: first, body: body, bones: bones)
    }

    /// `flesh`'s drawn surface (its model's `surface`, embedded), whose vertices start at `vertexBase` in the scene's
    /// vertex buffer: each where its tets put it, or on `skin` (PhysicsSkin.swift) where it is nearest, out along it as
    /// far as it is at rest; or (no tet: `rigid` says which figure bone) on that bone's body.
    func addFleshSurface(_ flesh: Flesh, figure: FleshFigure, vertexBase: Int, rigid: [Int] = [], skin: SkinShell? = nil) {
        let model = flesh.model, base = UInt32(flesh.first)
        for v in model.surface.positions.indices {
            let ring = UInt32(softRings.count) << 5 | UInt32(model.rings[v].count)
            softRings += model.rings[v].map { $0 &+ UInt32(vertexBase) }
            let follows = model.embedding[v]
            if let skin, !follows.isEmpty, let on = skin.nearest(model.surface.positions[v]) {
                softVertices.append(GPUSoftVertex(info: SIMD4(UInt32(vertexBase + v), 0, UInt32(flesh.body), ring),
                                                  embeds: SIMD4(UInt32(softEmbeds.count), 1, 0, 0)))
                softEmbeds.append(GPUSoftEmbed(bary: SIMD4(on.weights.x, on.weights.y, on.out, 1),
                                               ids: SIMD4(on.corners &+ UInt32(skin.first), GPUSoftEmbed.triangleKind)))
                continue
            }
            if follows.isEmpty {
                let bone = figure.bones[rigid.isEmpty ? 0 : rigid[v]], pose = bone.restPose
                let local = PhysicsMath.qrot(PhysicsMath.qconj(pose.rotation), model.surface.positions[v] - pose.position)
                softVertices.append(GPUSoftVertex(info: SIMD4(UInt32(vertexBase + v), 0, UInt32(flesh.body), ring),
                                                  embeds: SIMD4(UInt32(softEmbeds.count), 1, 0, 0)))
                softEmbeds.append(GPUSoftEmbed(bary: SIMD4(local, 1), ids: SIMD4(UInt32(bone.body), 0, 0, GPUSoftEmbed.bodyKind)))
                continue
            }
            softVertices.append(GPUSoftVertex(info: SIMD4(UInt32(vertexBase + v), 0, UInt32(flesh.body), ring),
                                              embeds: SIMD4(UInt32(softEmbeds.count), UInt32(follows.count), 0, 0)))
            let share = 1 / Float(follows.count)
            softEmbeds += follows.map { GPUSoftEmbed(bary: SIMD4($0.bary, share), ids: model.tets[$0.tet] &+ base) }
        }
    }

    // MARK: The GPU's copy

    /// The flesh's buffer for the GPU (Physics.metal's PhysicsFleshHeader and what follows it): the header, then the
    /// pose table, the muscles, their activations, the fibres, the pins and the skin's holds, each from a 16-byte word.
    func fleshWords() -> [SIMD4<UInt32>] {
        var words = [SIMD4<UInt32>](repeating: .zero, count: MemoryLayout<GPUFleshHeader>.stride / 16)
        func append<T>(_ array: [T]) -> UInt32 {
            let at = UInt32(words.count)
            array.withUnsafeBytes { raw in
                var chunk = [SIMD4<UInt32>](repeating: .zero, count: (raw.count + 15) / 16)
                chunk.withUnsafeMutableBytes { $0.copyMemory(from: raw) }
                words += chunk
            }
            return at
        }
        var header = GPUFleshHeader()
        header.counts = SIMD4(UInt32(kinematicColumns), UInt32(kinematicRows), UInt32(muscles.count), UInt32(pins.count))
        header.more = SIMD4(UInt32(fibres.count), UInt32(skinAttachments.count), 0, 0)
        header.at = SIMD4(append(kinematicTable), append(muscles), append(activations), append(fibres))
        header.at2 = SIMD4(append(pins), append(skinAttachments), 0, 0)
        withUnsafeBytes(of: header) { raw in words.withUnsafeMutableBytes { $0.copyMemory(from: raw) } }
        return words
    }
}

/// A muscle, by the parts of a figure it is on and crosses (FleshFigure.Role): its belly along a bone, to one side of
/// it, and the angle between two bones' axes that activates it.
struct MuscleSpec {
    enum Side { case front, back, out }
    enum Axis { case along, up, front }

    var name: String
    var on: FleshFigure.Role
    var span: ClosedRange<Float>     // along the bone (from its joint, a share of its length)
    var side: Side
    var offset: Float                // how far to that side the belly's axis is (a share of the bone's thickness)
    var radius: Float                // the belly's (a share of the bone's thickness)
    var a: (role: FleshFigure.Role, axis: Axis)
    var b: (role: FleshFigure.Role, axis: Axis)
    var angles: (start: Float, full: Float)
    var gain: Float

    /// Its belly (rest space) and its record, if the figure has its bones.
    func resolve(_ figure: FleshFigure, gain scale: Float) -> (origin: SIMD3<Float>, insertion: SIMD3<Float>, radius: Float, record: GPUMuscle)? {
        guard let bone = figure.bone(on), let ba = figure.bone(a.role), let bb = figure.bone(b.role) else { return nil }
        let axis = normalize(bone.to - bone.from)
        func across(_ v: SIMD3<Float>) -> SIMD3<Float> {
            let u = v - axis * dot(v, axis)
            return length(u) > 1e-4 ? normalize(u) : SIMD3(0, 0, 1)
        }
        let direction: SIMD3<Float>
        switch side {
        case .front: direction = across([0, 0, 1])
        case .back: direction = across([0, 0, -1])
        case .out:
            let trunk = figure.bone(.chest).map { PhysicsMath.xyz($0.rest.columns.3) } ?? .zero
            direction = across(bone.from - trunk)
        }
        let shift = direction * (offset * bone.thickness)
        let origin = bone.from + (bone.to - bone.from) * span.lowerBound + shift
        let insertion = bone.from + (bone.to - bone.from) * span.upperBound + shift
        func local(_ b: FleshFigure.Bone, _ which: Axis) -> SIMD4<Float> {
            let v: SIMD3<Float>
            switch which {
            case .along: v = normalize(b.to - b.from)
            case .up: v = [0, 1, 0]
            case .front: v = [0, 0, 1]
            }
            return SIMD4(PhysicsMath.qrot(PhysicsMath.qconj(b.restPose.rotation), v), 0)
        }
        let record = GPUMuscle(axisA: local(ba, a.axis), axisB: local(bb, b.axis), range: SIMD4(angles.start, angles.full, gain * scale, 0),
                               bodyA: UInt32(ba.body), bodyB: UInt32(bb.body))
        return (origin, insertion, radius * bone.thickness, record)
    }

    /// The muscles of a figure's arms and legs, each side's: biceps and triceps (the elbow), the deltoid (the arm
    /// raised from the side), quadriceps and hamstrings (the knee), and the calf (the ankle, where there is a foot).
    static let limbs: [MuscleSpec] = [Float(-1), 1].flatMap { s -> [MuscleSpec] in
        [MuscleSpec(name: "biceps", on: .upperArm(s), span: 0.2...0.85, side: .front, offset: 0.4, radius: 0.65,
                    a: (.upperArm(s), .along), b: (.forearm(s), .along), angles: (0.35, 2.0), gain: 1),
         MuscleSpec(name: "triceps", on: .upperArm(s), span: 0.15...0.8, side: .back, offset: 0.4, radius: 0.6,
                    a: (.upperArm(s), .along), b: (.forearm(s), .along), angles: (0.9, 0.1), gain: 0.3),
         MuscleSpec(name: "deltoid", on: .upperArm(s), span: 0.0...0.35, side: .out, offset: 0.35, radius: 0.75,
                    a: (.chest, .up), b: (.upperArm(s), .along), angles: (2.7, 1.5), gain: 0.8),
         MuscleSpec(name: "quadriceps", on: .thigh(s), span: 0.15...0.85, side: .front, offset: 0.4, radius: 0.65,
                    a: (.thigh(s), .along), b: (.shin(s), .along), angles: (0.15, 1.4), gain: 0.9),
         MuscleSpec(name: "hamstrings", on: .thigh(s), span: 0.2...0.85, side: .back, offset: 0.45, radius: 0.6,
                    a: (.thigh(s), .along), b: (.shin(s), .along), angles: (0.7, 1.8), gain: 0.5),
         MuscleSpec(name: "calf", on: .shin(s), span: 0.08...0.55, side: .back, offset: 0.45, radius: 0.65,
                    a: (.shin(s), .along), b: (.foot(s), .along), angles: (1.65, 2.3), gain: 0.9)]
    }
}
