import Foundation
import simd

/// Destruction (UE Chaos's, in this engine): fractured objects whose pieces break off under impacts.
///
/// An object fractured ahead of time (FractureTree) is a body per node of its tree, all made when the scene is built
/// (a world's bodies are fixed once it is finished): the root moves as the whole object, every other node is disabled
/// (it neither moves, collides nor shows) until its parent breaks. Then the parent is disabled and its children take
/// its place, moving as it moved; welds hold neighbouring pieces together (at any level, Chaos's connection graph)
/// until the force one takes passes its strength, so that a hit makes a hole, not a heap. A piece the ground held
/// (anchored) doesn't move until it comes free.
///
/// What breaks a piece is its step's impacts (Chaos's strain): the impulses of its contacts that met it faster than
/// resting does, summed over the step, and what it took over from its parent's break near where that was hit. At the
/// step's end each piece whose impacts pass its threshold breaks into its children; one whose impacts pass the
/// smaller one that frees it loses its welds and its anchor. Blasts and shots are commands kept with the step they
/// start at, so a replay does them again: any time's state is the same however it was reached.
///
/// A welded pair is solved as a pair of the contact colouring (its one contact marks the weld: lambda.w = 1), so the
/// welds need no colours of their own, and solved like a joint fixed in place: its turn about its partner back to rest,
/// then their anchors together, a force of lambda / h^2 (N). The GPU's step (Shaders/Physics.metal) does the same in the
/// same order: PhysicsCPU.step's `beginFractureStep`, the contacts' and welds' pushes, `endFractureStep`.
extension PhysicsWorld {
    /// GPUFractureCommand.info.y.
    enum FractureCommand: UInt32 {
        /// Body `info.z` (a disabled ball) placed at `origin` and sent along `direction` at its speed.
        case shoot = 0
        /// Every enabled body within `origin.w` pushed away from `origin`, its speed change at the middle `direction.w`
        /// (spread over the command's steps), and as much impact taken.
        case blast
        /// Body `info.z` woken (a wrecking ball, a weight held up asleep).
        case wake
        /// Body `info.z` freed from its anchor.
        case release
    }

    /// GPUFractureNode.info.w flags.
    static let anchoredNode: UInt32 = 1
    /// What counts as an impact (m/s): a contact closing faster than this (pieces sliding past each other, settling,
    /// resting don't break anything).
    static let impactSpeed: Float = 1
    /// The fastest a freed piece is pushed by the impacts that freed it (m/s).
    static let freedPush: Float = 4
    /// How far a weld stretches (m) or twists (rad) before it snaps: one pulled shut in a substep moves its pieces at
    /// gap / h (a centimetre's gap flung a brick at 10 m/s; a piece takes its parent's place where that had moved to).
    static let weldGap: Float = 3e-3
    static let weldTwist: Float = 0.03

    /// A weld's contact (its pair's only one while it holds): lambda.w = 1, the weld in anchorA.x.
    static func weldContact(_ w: Int) -> GPUPhysicsContact {
        GPUPhysicsContact(normal: SIMD4(0, 1, 0, 0), anchorA: SIMD4(Float(w), 0, 0, 0), anchorB: .zero, lambda: SIMD4(0, 0, 0, 1))
    }

    /// The weld between body `i` and partner `code` that still holds, if there is one.
    func liveWeld(_ i: Int, _ code: UInt32) -> Int? {
        guard !welds.isEmpty, code & PhysicsWorld.staticBit == 0, bodies[i].info.y & PhysicsWorld.pieceBit != 0,
              bodies[Int(code)].info.y & PhysicsWorld.pieceBit != 0 else { return nil }
        for k in Int(weldStarts[i])..<Int(weldStarts[i + 1]) where weldList[k].x == code {
            let w = Int(weldList[k].y)
            return welds[w].info.z == 0 ? w : nil
        }
        return nil
    }

    // MARK: Building

    /// A body for a fractured object's piece, its shape's mass and samples given (`ShapeBuild`, made side by side).
    @discardableResult
    func addPiece(sdf: Int, _ shape: SDFShape, build: ShapeBuild, transform: float4x4, instance: Int, material: FractureMaterial) -> Int {
        addBody(sdf: sdf, shape, transform: transform, instance: instance, density: material.density, friction: material.friction,
                restitution: material.restitution, prebuilt: build)
    }

    /// The mass and samples of a convex piece (its cell is the piece): exact, from the polytope.
    static func pieceShape(_ cell: ConvexCell, sdf: Int) -> ShapeBuild {
        let centre = cell.centroid
        let (moments, axes) = eigen(cell.inertia)
        let rotation = simd_quatf(simd_float3x3(columns: (SIMD3<Float>(axes.columns.0), SIMD3<Float>(axes.columns.1),
                                                           SIMD3<Float>(axes.columns.2))))
        let q = PhysicsMath.quat(rotation)
        let toBody = { (p: SIMD3<Float>) in PhysicsMath.qrot(PhysicsMath.qconj(q), p - centre) }
        // Samples: its corners, then the middles of its edges and faces as far as there is room.
        var points = cell.vertices
        var more: [SIMD3<Float>] = []
        for f in cell.faces {
            for i in f.polygon.indices { more.append((f.polygon[i] + f.polygon[(i + 1) % f.polygon.count]) / 2) }
        }
        for f in cell.faces { more.append(f.polygon.reduce(SIMD3<Float>(), +) / Float(f.polygon.count)) }
        let eps = cell.size * 1e-3
        for p in more where points.count < maxSamples && !points.contains(where: { length($0 - p) < eps }) { points.append(p) }
        if points.count > maxSamples {
            // Farthest-point: the corners spread over the piece.
            var chosen = [points[0]]
            var nearest = points.map { length_squared($0 - points[0]) }
            while chosen.count < maxSamples {
                var far = 0
                for i in points.indices where nearest[i] > nearest[far] { far = i }
                chosen.append(points[far])
                for i in points.indices { nearest[i] = min(nearest[i], length_squared(points[i] - points[far])) }
            }
            points = chosen
        }
        let radius = cell.vertices.map { length($0 - centre) }.max() ?? 0
        let shape = GPUPhysicsShape(comPosition: SIMD4(centre, radius), comRotation: q,
                                    info: SIMD4(PhysicsShapeKind.sdf.rawValue, 0, 0, UInt32(sdf)))
        return ShapeBuild(shape: shape, samples: points.map { SIMD4(toBody($0), 0) }, volume: cell.volume, moments: SIMD3<Float>(moments))
    }

    /// Fractured object `tree`: its node k is body `first + k` (added in order, all but the root disabled), anchored
    /// where `anchored[k]`. Thresholds from its material and recipe, times `toughness` and `strength` (the scene's).
    func addFracture(_ tree: FractureTree, first: Int, anchored: [Bool], toughness: Float = 1, strength: Float = 1,
                     fadeRadius: Float = 0.1) {
        while fractureNodes.count < bodies.count { fractureNodes.append(GPUFractureNode()) }
        let material = tree.recipe.material
        let tough = material.toughness * tree.recipe.toughness * toughness
        for (k, node) in tree.nodes.enumerated() {
            let i = first + k
            var f = GPUFractureNode()
            let invMass = bodies[i].position.w
            // What breaks it: its size's share of the toughness; a piece at least its mass at the material's speed (up to
            // four times that: a small piece isn't broken by one of its size dropped on it, a big one still by a hit).
            let share = tough * pow(max(node.volume, 1e-9), 2 / 3)
            let carried = material.breakSpeed * toughness * tree.recipe.toughness / max(invMass, 1e-9)
            let threshold = node.parent < 0 ? share : max(share, min(carried, 4 * share))
            f.info = SIMD4(node.parent < 0 ? PhysicsWorld.none : UInt32(first + node.parent),
                           UInt32(first + (node.children.first ?? 0)), UInt32(node.children.count), anchored[k] ? PhysicsWorld.anchoredNode : 0)
            if node.parent >= 0 {
                let p = bodies[first + node.parent], b = bodies[i]
                f.offset = SIMD4(PhysicsMath.qrot(PhysicsMath.qconj(p.rotation), PhysicsMath.xyz(b.position) - PhysicsMath.xyz(p.position)), 0)
                f.rotation = PhysicsMath.qnormalize(PhysicsMath.qmul(PhysicsMath.qconj(p.rotation), b.rotation))
            }
            f.offset.w = node.isLeaf ? 0 : threshold
            let radius = bodies[i].invInertia.w
            f.extra = SIMD4(invMass, threshold, node.isLeaf && radius < fadeRadius ? radius : 0, Float(material.rawValue))
            fractureNodes[i] = f
            bodies[i].info.y |= PhysicsWorld.pieceBit
            if anchored[k] { bodies[i].info.y |= PhysicsWorld.anchoredBit }
            // Held by the ground: no mass until it comes free. Only the root moves at first.
            if anchored[k] { bodies[i].position.w = 0 }
            if k > 0 { bodies[i].info.y |= PhysicsWorld.disabledBit }
        }
        let sigma = material.strength * tree.recipe.strength * strength
        for w in tree.welds {
            let a = bodies[first + w.a], b = bodies[first + w.b]
            var weld = GPUFractureWeld()
            weld.anchorA = SIMD4(PhysicsMath.qrot(PhysicsMath.qconj(a.rotation), w.centre - PhysicsMath.xyz(a.position)), sigma * w.area)
            weld.anchorB = SIMD4(PhysicsMath.qrot(PhysicsMath.qconj(b.rotation), w.centre - PhysicsMath.xyz(b.position)), (w.area / .pi).squareRoot())
            weld.rest = PhysicsMath.qnormalize(PhysicsMath.qmul(PhysicsMath.qconj(a.rotation), b.rotation))
            weld.info = SIMD4(UInt32(first + w.a), UInt32(first + w.b), 0, 0)
            welds.append(weld)
        }
    }

    /// The Fracture Editor's preview of fractured object `tree` (its root body `first`): its pieces at `level` (and
    /// leaves above it) enabled, held where they are moved apart from its middle by `explode` x their distance, asleep;
    /// the rest disabled. Before `finish`.
    func preview(_ tree: FractureTree, first: Int, level: Int, explode: Float) {
        let centre = PhysicsWorld.xyz(bodies[first].position)
        for (k, node) in tree.nodes.enumerated() {
            let i = first + k
            guard node.level == level || (node.isLeaf && node.level < level) else {
                bodies[i].info.y |= PhysicsWorld.disabledBit
                continue
            }
            let x = PhysicsWorld.xyz(bodies[i].position)
            let moved = x + (x - centre) * explode
            bodies[i].info.y = (bodies[i].info.y & ~PhysicsWorld.disabledBit) | PhysicsWorld.asleep
            bodies[i].position = SIMD4(moved, 0)
            bodies[i].prevPosition = SIMD4(moved, 0)
            fractureNodes[i].extra.x = 0   // (held: nothing frees it)
        }
    }

    /// A ball for shots: disabled until a `shoot` command sends it.
    func disable(_ i: Int) { bodies[i].info.y |= PhysicsWorld.disabledBit }

    /// Body `i` starts asleep (held where it is until something wakes it: a command, a touch).
    func startAsleep(_ i: Int) { bodies[i].info.y |= PhysicsWorld.asleep }

    // MARK: Commands

    /// A command from step `step` (the next one to run, if nil) for `steps` steps; returned for the GPU's copy.
    @discardableResult
    func command(_ kind: FractureCommand, body: Int = 0, origin: SIMD3<Float> = .zero, radius: Float = 0, direction: SIMD3<Float> = .zero,
                 magnitude: Float = 0, at step: Int? = nil, steps: Int = 1) -> GPUFractureCommand {
        let c = GPUFractureCommand(info: SIMD4(UInt32(step ?? stepIndex), kind.rawValue, UInt32(body), UInt32(max(steps, 1))),
                                   origin: SIMD4(origin, radius), direction: SIMD4(direction, magnitude))
        fractureCommands.append(c)
        return c
    }

    static let maxCommands = 1024
    /// The break events' ring (PhysicsGPU.breakRing; MSL PHYS_RING_SLOTS, PHYS_RING_EVENTS): steps it keeps, events a step.
    static let ringSlots = 64, ringEvents = 256

    /// The step's commands (PhysicsCPU.step's first stage; MSL physicsFractureCommandKernel).
    func beginFractureStep() {
        let clock = UInt32(stepIndex)
        for c in fractureCommands where c.info.x <= clock && clock < c.info.x + c.info.w {
            switch FractureCommand(rawValue: c.info.y) {
            case .shoot:
                let i = Int(c.info.z)
                guard clock == c.info.x, bodies.indices.contains(i) else { continue }
                PhysicsWorld.launch(&bodies[i], c)
            case .blast:
                for i in bodies.indices { PhysicsWorld.blast(&bodies[i], &fractureState[i], fractureNodes[i], c) }
            case .wake:
                let i = Int(c.info.z)
                guard bodies.indices.contains(i) else { continue }
                bodies[i].info.y &= ~PhysicsWorld.asleep
                bodies[i].prevPosition.w = 0
            case .release:
                let i = Int(c.info.z)
                guard bodies.indices.contains(i) else { continue }
                PhysicsWorld.free(&bodies[i], fractureNodes[i])
            case nil: continue
            }
        }
    }

    /// A shot's ball enabled at the command's origin, sent along its direction.
    @inline(__always) static func launch(_ b: inout GPUPhysicsBody, _ c: GPUFractureCommand) {
        let x = xyz(c.origin)
        b.info.y &= ~(disabledBit | asleep)
        b.position = SIMD4(x, b.position.w)
        b.prevPosition = SIMD4(x, 0)
        b.prevRotation = b.rotation
        b.velocity = SIMD4(xyz(c.direction) * c.direction.w, b.velocity.w)
        b.angular = SIMD4(.zero, b.angular.w)
    }

    @inline(__always) static func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }

    /// A blast's push on body b this step, and the impact it takes (a held piece takes the impact only).
    @inline(__always) static func blast(_ b: inout GPUPhysicsBody, _ s: inout GPUFractureState, _ node: GPUFractureNode, _ c: GPUFractureCommand) {
        guard b.info.y & disabledBit == 0, b.info.y & kinematicBit == 0 else { return }
        let o = xyz(c.origin), radius = c.origin.w, x = xyz(b.position)
        let away = x - o, d = length(away)
        guard d < radius + b.invInertia.w * 0.5 else { return }
        let f = max(1 - max(d - b.invInertia.w * 0.5, 0) / radius, 0)
        // Out from the middle and a little up.
        let dir = PhysicsMath.direction(away / max(d, 1e-4) + SIMD3(0, 0.35, 0))
        let dv = c.direction.w * f / Float(c.info.w)
        let invMass = b.position.w > 0 ? b.position.w : node.extra.x
        guard invMass > 0, dv > 0 else { return }
        if b.position.w > 0 {
            b.info.y &= ~asleep
            b.prevPosition.w = 0
            b.velocity = SIMD4(xyz(b.velocity) + dir * dv, b.velocity.w)
        }
        let impulse = dv / invMass
        s.strain.x += impulse
        s.impact += SIMD4(o * impulse, impulse)
        s.direction = SIMD4(xyz(s.direction) + dir * impulse, s.direction.w)
    }

    /// A held piece let go: its own mass back, awake.
    @inline(__always) static func free(_ b: inout GPUPhysicsBody, _ node: GPUFractureNode) {
        if b.position.w == 0 && node.extra.x > 0 { b.position.w = node.extra.x }
        b.info.y &= ~asleep
        b.prevPosition.w = 0
    }

    // MARK: Contacts and welds

    /// PhysicsCPU.solvePositions for pair `e` when there are fractured objects: its contacts' pushes, each impact's
    /// impulse onto both pieces' strain; or its weld.
    func pushFracturePair(_ e: Int, h: Float, g: Float) {
        let i = e / PhysicsWorld.maxPairs, code = pairs[e].partner, dynamic = code & PhysicsWorld.staticBit == 0
        var a = bodies[i], b = partner(code)
        for c in 0..<Int(pairs[e].contacts) {
            let ci = e * PhysicsWorld.maxContacts + c
            let contact = contacts[ci]
            if contact.lambda.w == 1 {
                let w = Int(contact.anchorA.x)
                PhysicsWorld.solveWeld(&welds[w], &a, &b, ownerIsA: welds[w].info.x == UInt32(i), h: h, substeps: Float(substeps))
                continue
            }
            let push = PhysicsWorld.contactPush(contact, a, b, h: h)
            contacts[ci].lambda = SIMD4(push.lambda, push.speed, 0, 0)
            guard push.lambda > 0 else { continue }
            if -push.speed > PhysicsWorld.impactSpeed {   // an impact, not a rest or a slide
                let impulse = push.lambda / h, point = PhysicsWorld.points(contact, a, b).pa, n = PhysicsMath.xyz(contact.normal)
                if a.info.y & PhysicsWorld.pieceBit != 0 { PhysicsWorld.strike(&fractureState[i], point, n, impulse) }
                if dynamic && b.info.y & PhysicsWorld.pieceBit != 0 { PhysicsWorld.strike(&fractureState[Int(code)], point, -n, impulse) }
            }
            PhysicsWorld.shove(&a, push.impulse, push.ra)
            PhysicsWorld.shove(&b, -push.impulse, push.rb)
        }
        bodies[i] = a
        if dynamic { bodies[Int(code)] = b }
    }

    /// PhysicsCPU.solveVelocities for pair `e` when there are fractured objects: its contacts' kicks, an impact's normal
    /// impulse onto both pieces' strain too (the push above moves an overlap apart at `pushSpeed` at most: the kick
    /// takes the rest of a hit's speed).
    func kickFracturePair(_ e: Int, _ p: GPUPhysicsParams) {
        let i = e / PhysicsWorld.maxPairs, code = pairs[e].partner, dynamic = code & PhysicsWorld.staticBit == 0
        var a = bodies[i], b = partner(code)
        let g = length(PhysicsMath.xyz(p.gravity)), h = p.gravity.w
        for c in 0..<Int(pairs[e].contacts) {
            let contact = contacts[e * PhysicsWorld.maxContacts + c]
            guard let kick = PhysicsWorld.contactKick(contact, a, b, p) else { continue }
            if contact.lambda.y < -PhysicsWorld.impactSpeed && (a.info.y | b.info.y) & PhysicsWorld.pieceBit != 0 {
                let n = PhysicsMath.xyz(contact.normal), impulse = max(dot(kick.impulse, n), 0)
                if impulse > 0 {
                    let point = PhysicsWorld.points(contact, a, b).pa
                    if a.info.y & PhysicsWorld.pieceBit != 0 { PhysicsWorld.strike(&fractureState[i], point, n, impulse) }
                    if dynamic && b.info.y & PhysicsWorld.pieceBit != 0 { PhysicsWorld.strike(&fractureState[Int(code)], point, -n, impulse) }
                }
            }
            PhysicsWorld.kick(&a, kick.impulse, kick.ra, kick.twist)
            PhysicsWorld.kick(&b, -kick.impulse, kick.rb, -kick.twist)
        }
        bodies[i] = a
        if dynamic { bodies[Int(code)] = b }
    }

    @inline(__always) static func strike(_ s: inout GPUFractureState, _ point: SIMD3<Float>, _ push: SIMD3<Float>, _ impulse: Float) {
        s.strain.x += impulse
        s.impact += SIMD4(point * impulse, impulse)
        s.direction = SIMD4(xyz(s.direction) + push * impulse, s.direction.w)
    }

    /// Weld `w` between its A and B (`a` is the pair's owner, `b` its partner: `ownerIsA` says which the weld's A is):
    /// their turn about each other back to rest, then their anchors together (a joint fixed in place, of no compliance);
    /// it breaks when the load that takes (its force, lambda / h^2, over what it holds, and its moment's), averaged
    /// over about a step (`info.w`, a float: each substep's a 1 / substeps share), passes 1. (A substep's alone, a jolt
    /// of a few mm made a force of tens of kN: every weld a falling piece brushed broke.)
    @inline(__always) static func solveWeld(_ w: inout GPUFractureWeld, _ a: inout GPUPhysicsBody, _ b: inout GPUPhysicsBody,
                                            ownerIsA: Bool, h: Float, substeps: Float) {
        guard w.info.z == 0, moves(a) || moves(b) else { return }
        if ownerIsA { weld(&w, &a, &b, h: h, substeps: substeps) } else { weld(&w, &b, &a, h: h, substeps: substeps) }
    }

    @inline(__always) static func weld(_ w: inout GPUFractureWeld, _ x: inout GPUPhysicsBody, _ y: inout GPUPhysicsBody, h: Float,
                                       substeps: Float) {
        // The turn: y's rotation should be x's times the rest.
        let target = PhysicsMath.qmul(x.rotation, w.rest)
        var dq = PhysicsMath.qmul(y.rotation, PhysicsMath.qconj(target))
        if dq.w < 0 { dq = -dq }
        let theta = 2 * PhysicsMath.xyz(dq)
        let angle = length(theta)
        var moment: Float = 0
        if angle > 1e-7 {
            let k = theta / angle, wa = turnWeight(x, k) + turnWeight(y, k)
            if wa > 0 { moment = angle / wa / (h * h) }
        }
        let ra = PhysicsMath.qrot(x.rotation, PhysicsMath.xyz(w.anchorA)), rb = PhysicsMath.qrot(y.rotation, PhysicsMath.xyz(w.anchorB))
        let gap = (PhysicsMath.xyz(y.position) + rb) - (PhysicsMath.xyz(x.position) + ra)
        let l = length(gap)
        var force: Float = 0
        if l > 1e-7 {
            let n = gap / l, wl = weight(x, ra, n) + weight(y, rb, n)
            if wl > 0 { force = l / wl / (h * h) }
        }
        let load = force / w.anchorA.w + moment / (w.anchorA.w * max(w.anchorB.w, 1e-3))
        let k = 1 / substeps, average = Float(bitPattern: w.info.w) * (1 - k) + load * k
        w.info.w = average.bitPattern
        if average > 1 || l > weldGap || angle > weldTwist {
            w.info.z = 1
            return
        }
        if angle > 1e-7 { swivel(&x, &y, theta) }
        let ra2 = PhysicsMath.qrot(x.rotation, PhysicsMath.xyz(w.anchorA)), rb2 = PhysicsMath.qrot(y.rotation, PhysicsMath.xyz(w.anchorB))
        let gap2 = (PhysicsMath.xyz(y.position) + rb2) - (PhysicsMath.xyz(x.position) + ra2)
        let l2 = length(gap2)
        guard l2 > 1e-7 else { return }
        let n = gap2 / l2, wl = weight(x, ra2, n) + weight(y, rb2, n)
        guard wl > 0 else { return }
        shove(&x, n * (l2 / wl), ra2)
        shove(&y, -n * (l2 / wl), rb2)
    }

    // MARK: The step's end

    /// What the step's impacts did (PhysicsCPU.step's last stage; MSL physicsFractureVerdictKernel, then
    /// physicsFractureApplyKernel): each piece breaks into its children, comes free, fades, or nothing; then each
    /// child of a piece that broke takes its place.
    func endFractureStep() {
        let tuning = fractureTuning, h = PhysicsWorld.stepLength
        for i in bodies.indices {
            PhysicsWorld.verdict(bodies[i], &fractureState[i], fractureNodes[i], h: h)
        }
        let before = bodies, states = fractureState
        for i in bodies.indices {
            let node = fractureNodes[i], p = node.info.x == PhysicsWorld.none ? i : Int(node.info.x)
            let free = PhysicsWorld.apply(&bodies[i], &fractureState[i], node, parent: before[p], parentState: states[p],
                                          parentThreshold: fractureNodes[p].offset.w, tuning: tuning)
            if free { breakWelds(i) }
        }
    }

    /// Every weld of body `i` broken (it came free).
    private func breakWelds(_ i: Int) {
        for k in Int(weldStarts[i])..<Int(weldStarts[i + 1]) { welds[Int(weldList[k].y)].info.z = 1 }
    }

    /// Phase A: the step's verdict on body b (and its time lying still, for fading).
    @inline(__always) static func verdict(_ b: GPUPhysicsBody, _ s: inout GPUFractureState, _ node: GPUFractureNode, h: Float) {
        s.strain.w = 0
        guard b.info.y & (pieceBit | disabledBit) == pieceBit else { return }
        let total = s.strain.x + s.strain.z
        if node.info.z > 0 && total > node.offset.w {
            s.strain.w = 1
        } else if total > node.extra.y && node.info.x != PhysicsWorld.none {   // (a root breaks, or holds)
            s.strain.w = 2
        }
        s.strain.y = node.extra.z > 0 && b.info.y & asleep != 0 ? s.strain.y + h : 0
    }

    /// Phase B for one body (it reads only its parent's state as phase A left it, and writes only its own): disabled
    /// if it broke; in its parent's place if that broke; freed; faded. Whether its welds break (it came free).
    @inline(__always) static func apply(_ b: inout GPUPhysicsBody, _ s: inout GPUFractureState, _ node: GPUFractureNode,
                                        parent: GPUPhysicsBody, parentState ps: GPUFractureState, parentThreshold: Float,
                                        tuning: SIMD4<Float>) -> Bool {
        guard b.info.y & pieceBit != 0 else { return false }
        if b.info.y & disabledBit == 0 {
            let verdict = s.strain.w
            if verdict == 1 {
                b.info.y |= disabledBit   // (its strain stays: its children read it)
                return false
            }
            if verdict == 2 { free(&b, node) }
            // Fading: a small piece lying still shrinks away, then is gone.
            let scale = min(max(1 - (s.strain.y - tuning.x) / max(tuning.y, 1e-3), 0), 1)
            if scale <= 0 { b.info.y |= disabledBit }
            s.strain.x = 0
            s.strain.z = 0
            s.impact = .zero
            s.direction = SIMD4(0, 0, 0, scale)
            return verdict == 2
        }
        // Disabled: in its parent's place, if that just broke.
        guard node.info.x != PhysicsWorld.none, ps.strain.w == 1, parent.info.y & disabledBit == 0 else { return false }
        let x = xyz(parent.position) + PhysicsMath.qrot(parent.rotation, xyz(node.offset))
        let q = PhysicsMath.qnormalize(PhysicsMath.qmul(parent.rotation, node.rotation))
        var v = xyz(parent.velocity) + cross(xyz(parent.angular), x - xyz(parent.position))
        // What it takes over of the break: the parent's impacts, less with distance from where they were (the
        // further past its threshold the parent went, the further the damage spreads).
        let total = ps.strain.x + ps.strain.z
        let hit = ps.impact.w > 0 ? xyz(ps.impact) / ps.impact.w : xyz(parent.position)
        let spread = max(tuning.z * cbrt(total / max(parentThreshold, 1e-6)), 1e-3)
        // (From its near side: the piece the hit was on takes all of it.)
        let f = max(1 - max(length(x - hit) - 0.6 * b.invInertia.w, 0) / spread, 0)
        let inherited = total * f * f
        // Held by the ground only if its parent was.
        let held = node.info.w & anchoredNode != 0 && parent.position.w == 0
        b.position = SIMD4(x, held ? 0 : node.extra.x)
        b.rotation = q
        b.prevPosition = SIMD4(x, 0)
        b.prevRotation = q
        b.info.y &= ~(disabledBit | asleep)
        s = GPUFractureState()
        s.strain.z = inherited
        let freed = inherited > node.extra.y
        if freed && !held {
            // Pushed on the way the impacts pushed its parent.
            let d = xyz(ps.direction), l = length(d)
            if l > 1e-6 && node.extra.x > 0 { v += d / l * min(inherited * tuning.w * node.extra.x, PhysicsWorld.freedPush) }
        }
        b.velocity = SIMD4(v, b.velocity.w)
        b.angular = SIMD4(xyz(parent.angular), b.angular.w)
        return freed
    }

    // MARK: Drawing

    /// How big body `i` is drawn (0: not at all, a disabled body; less than 1 while it fades).
    func drawnScale(_ i: Int) -> Float {
        if bodies[i].info.y & PhysicsWorld.disabledBit != 0 { return 0 }
        return fractureState.indices.contains(i) ? fractureState[i].direction.w : 1
    }
}
