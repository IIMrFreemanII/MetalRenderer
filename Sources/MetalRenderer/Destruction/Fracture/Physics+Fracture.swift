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
/// A shot breaks a wall and goes on, knocking pieces out of it. In the step the wall breaks, the shot meets it whole and
/// held by the ground, which stops it dead; the pieces are only there from the next step. So a projectile (a body that
/// is not a piece) whose hardest hit of a step was on a held piece that broke or came free goes on at the speed it
/// started the step at (`giveWay`; its fracture state, unused otherwise, keeps that speed and the hit). And the pieces
/// of a held piece that broke stay held for a moment (`holdAfterBreak`), but for those its impacts freed: the shot's
/// push goes into the ground, not through the welds into the rest of the wall.
///
/// A welded pair is solved as a pair of the contact colouring (its one contact marks the weld: lambda.w = 1), so the
/// welds need no colours of their own, and solved like a joint fixed in place: its turn about its partner back to rest,
/// then their anchors together, a force of lambda / h^2 (N). The GPU's step (Shaders/Physics.metal) does the same in the
/// same order: PhysicsCPU.step's `beginFractureStep`, the contacts' and welds' pushes, `endFractureStep`.
extension PhysicsWorld {
    /// GPUFractureCommand.info.y.
    package enum FractureCommand: UInt32 {
        /// Body `info.z` (a disabled ball) placed at `origin` and sent along `direction` at its speed.
        case shoot = 0
        /// Every enabled body within `origin.w` pushed away from `origin`, its speed change at the middle `direction.w`
        /// (spread over the command's steps), and as much impact taken.
        case blast
        /// Body `info.z` woken (a wrecking ball, a weight held up asleep).
        case wake
        /// Body `info.z` freed from its anchor.
        case release
        /// A bullet (the CPU's only, as the three after it: Physics+Demolition.swift): body `info.z` hit at `origin`
        /// along `direction`, an impulse of `direction.w` (N s), and enough impact to break it a level.
        case hit
        /// Rocket `info.z` (a disabled ball with the fuse flag) sent from `origin` along `direction` at its speed, to
        /// go off where it meets something: a blast of radius `origin.w`.
        case rocket
        /// The walker's input from this step on: `direction.xz` its speed over the ground (m/s), `direction.y` a jump's
        /// speed (once), `info.z` DemolitionState.Drive flags, `origin` where to put it (a teleport).
        case drive
    }

    /// GPUFractureNode.info.w flags.
    static let anchoredNode: UInt32 = 1
    /// What counts as an impact (m/s): a contact closing faster than this (pieces sliding past each other, settling,
    /// resting don't break anything).
    static let impactSpeed: Float = 1
    /// The fastest a freed piece is pushed by the impacts that freed it (m/s).
    static let freedPush: Float = 4
    /// How long (s) the pieces of a held piece that broke stay held where they are, but for those its impacts freed
    /// (Chaos keeps an anchored cluster's rest in place): the hit's push goes into the ground, the pieces it knocked out
    /// get away, and only then does the rest stand on its welds. (Let go at once, a shot that went on pushed the welded
    /// rest along, one weld solve a substep: the wall around the hole toppled.)
    static let holdAfterBreak: Float = 0.25
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
        PhysicsWorld.liveWeld(i, code, bodies: bodies, starts: weldStarts, list: weldList, welds: welds)
    }

    /// `liveWeld` on arrays a stage's loop took (any thread).
    @inline(__always) static func liveWeld(_ i: Int, _ code: UInt32, bodies: UnsafeBufferPointer<GPUPhysicsBody>,
                                           starts: UnsafeBufferPointer<UInt32>, list: UnsafeBufferPointer<SIMD2<UInt32>>,
                                           welds: UnsafeBufferPointer<GPUFractureWeld>) -> Int? {
        guard welds.count > 0, code & PhysicsWorld.staticBit == 0, bodies[i].info.y & PhysicsWorld.pieceBit != 0,
              bodies[Int(code)].info.y & PhysicsWorld.pieceBit != 0 else { return nil }
        for k in Int(starts[i])..<Int(starts[i + 1]) where list[k].x == code {
            let w = Int(list[k].y)
            return welds[w].info.z == 0 ? w : nil
        }
        return nil
    }
    static func liveWeld(_ i: Int, _ code: UInt32, bodies: [GPUPhysicsBody], starts: [UInt32], list: [SIMD2<UInt32>],
                         welds: [GPUFractureWeld]) -> Int? {
        bodies.withUnsafeBufferPointer { b in
            starts.withUnsafeBufferPointer { s in
                list.withUnsafeBufferPointer { l in welds.withUnsafeBufferPointer { liveWeld(i, code, bodies: b, starts: s, list: l, welds: $0) } }
            }
        }
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

    /// Fractured object `tree` placed by `transform` (its cells and welds are in shape space): its node k is body
    /// `first + k` (added in order, all but the root disabled), anchored where `anchored[k]`. Thresholds from its
    /// material and recipe, times `toughness` and `strength` (the scene's).
    func addFracture(_ tree: FractureTree, first: Int, transform: float4x4, anchored: [Bool], toughness: Float = 1,
                     strength: Float = 1, fadeRadius: Float = 0.1) {
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
            // (In the world, where the bodies are: shape space put a weld's anchors as far from its pieces as the
            // object is from the origin, and the first small turn after a break opened it past the snap.)
            let centre = PhysicsMath.xyz(transform * SIMD4(w.centre, 1))
            var weld = GPUFractureWeld()
            weld.anchorA = SIMD4(PhysicsMath.qrot(PhysicsMath.qconj(a.rotation), centre - PhysicsMath.xyz(a.position)), sigma * w.area)
            weld.anchorB = SIMD4(PhysicsMath.qrot(PhysicsMath.qconj(b.rotation), centre - PhysicsMath.xyz(b.position)), (w.area / .pi).squareRoot())
            weld.rest = PhysicsMath.qnormalize(PhysicsMath.qmul(PhysicsMath.qconj(a.rotation), b.rotation))
            weld.info = SIMD4(UInt32(first + w.a), UInt32(first + w.b), 0, 0)
            welds.append(weld)
        }
    }

    /// A weld between bodies `a` and `b` (pieces of two objects that touch: the demolition scene's slab's panels), of
    /// `area` (m^2) about `centre` (the world), holding `sigma` x that (N), as an object's own welds are. Before `finish`.
    package func addWeld(_ a: Int, _ b: Int, centre: SIMD3<Float>, area: Float, sigma: Float) {
        let x = bodies[a], y = bodies[b]
        var weld = GPUFractureWeld()
        weld.anchorA = SIMD4(PhysicsMath.qrot(PhysicsMath.qconj(x.rotation), centre - PhysicsMath.xyz(x.position)), sigma * area)
        weld.anchorB = SIMD4(PhysicsMath.qrot(PhysicsMath.qconj(y.rotation), centre - PhysicsMath.xyz(y.position)), (area / .pi).squareRoot())
        weld.rest = PhysicsMath.qnormalize(PhysicsMath.qmul(PhysicsMath.qconj(x.rotation), y.rotation))
        weld.info = SIMD4(UInt32(a), UInt32(b), 0, 0)
        welds.append(weld)
    }

    /// The Fracture Editor's preview of fractured object `tree` (its root body `first`): its pieces at `level` (and
    /// leaves above it) enabled, held where they are moved apart from its middle by `explode` x their distance, asleep;
    /// the rest disabled. Before `finish`.
    package func preview(_ tree: FractureTree, first: Int, level: Int, explode: Float) {
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
    package func disable(_ i: Int) { bodies[i].info.y |= PhysicsWorld.disabledBit }

    /// Body `i` starts asleep (held where it is until something wakes it: a command, a touch).
    package func startAsleep(_ i: Int) { bodies[i].info.y |= PhysicsWorld.asleep }

    // MARK: Commands

    /// A command from step `step` (the next one to run, if nil) for `steps` steps; returned for the GPU's copy.
    @discardableResult
    package func command(_ kind: FractureCommand, body: Int = 0, origin: SIMD3<Float> = .zero, radius: Float = 0, direction: SIMD3<Float> = .zero,
                 magnitude: Float = 0, at step: Int? = nil, steps: Int = 1) -> GPUFractureCommand {
        let c = GPUFractureCommand(info: SIMD4(UInt32(step ?? stepIndex), kind.rawValue, UInt32(body), UInt32(max(steps, 1))),
                                   origin: SIMD4(origin, radius), direction: SIMD4(direction, magnitude))
        add(c)
        return c
    }

    /// Command `c` kept (its start step `PhysicsWorld.none`: the next one to run), and indexed by its start.
    func add(_ c: GPUFractureCommand) {
        var c = c
        if c.info.x == PhysicsWorld.none { c.info.x = UInt32(stepIndex) }
        let index = Int32(fractureCommands.count)
        fractureCommands.append(c)
        longestCommand = max(longestCommand, c.info.w)
        // After every command that starts no later (those of a step stay in the order they came).
        var lo = 0, hi = commandOrder.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if fractureCommands[Int(commandOrder[mid])].info.x <= c.info.x { lo = mid + 1 } else { hi = mid }
        }
        commandOrder.insert(index, at: lo)
    }

    /// The commands live at step `clock` (`liveCommands`), in the order they were added: those that start in the
    /// window a command lasts at most, found by their start.
    private func findLiveCommands(_ clock: UInt32) {
        liveCommands.removeAll(keepingCapacity: true)
        let low = clock >= longestCommand ? clock - longestCommand + 1 : 0
        commandOrder.withUnsafeBufferPointer { order in
            fractureCommands.withUnsafeBufferPointer { all in
                var lo = 0, hi = order.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if all[Int(order[mid])].info.x < low { lo = mid + 1 } else { hi = mid }
                }
                var k = lo
                while k < order.count, all[Int(order[k])].info.x <= clock {
                    let c = all[Int(order[k])]
                    if clock < c.info.x + c.info.w { liveCommands.append(order[k]) }
                    k += 1
                }
            }
        }
        liveCommands.sort()
    }

    static let maxCommands = 1024
    /// The break events' ring (PhysicsGPU.breakRing; MSL PHYS_RING_SLOTS, PHYS_RING_EVENTS): steps it keeps, events a step.
    static let ringSlots = 64, ringEvents = 256

    /// The step's commands (PhysicsCPU.step's first stage; MSL physicsFractureCommandKernel).
    func beginFractureStep() {
        let clock = UInt32(stepIndex)
        findLiveCommands(clock)
        for k in liveCommands.indices {
            let c = fractureCommands[Int(liveCommands[k])]
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
            case .hit: hitBody(c)
            case .rocket: launchRocket(c, clock: clock)
            case .drive: demolition.walker.take(c, clock: clock)
            case nil: continue
            }
        }
        if demolition.active { beginDemolitionStep(clock) }   // the rockets' fuses, the blasts they set off, the walker
        for i in bodies.indices where bodies[i].info.y & PhysicsWorld.pieceBit == 0 {
            PhysicsWorld.startProjectile(bodies[i], &fractureState[i])
        }
    }

    /// A body that is not a piece at its step's start (after the commands): its speed then, no hit yet (its drawn scale
    /// stays).
    @inline(__always) static func startProjectile(_ b: GPUPhysicsBody, _ s: inout GPUFractureState) {
        s.strain = .zero
        s.impact = SIMD4(xyz(b.velocity), 0)
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
    /// impulse onto both pieces' strain; or its weld. (A colour's pairs share no body, piece or weld: on every core.)
    @inline(__always) static func pushFracturePair(_ e: Int, _ s: StepBuffers, h: Float, substeps: Float) {
        let i = e / PhysicsWorld.maxPairs, code = s.pairs[e].partner, dynamic = code & PhysicsWorld.staticBit == 0
        var a = s.bodies[i], b = s.partner(code)
        if PhysicsWorld.still(a, b) && s.contacts[e * PhysicsWorld.maxContacts].lambda.w != 1 { return }   // (a weld is a pair's one contact)
        for c in 0..<Int(s.pairs[e].contacts) {
            let ci = e * PhysicsWorld.maxContacts + c
            let contact = s.contacts[ci]
            if contact.lambda.w == 1 {
                let w = Int(contact.anchorA.x)
                PhysicsWorld.solveWeld(&s.welds[w], &a, &b, ownerIsA: s.welds[w].info.x == UInt32(i), h: h, substeps: substeps)
                continue
            }
            let push = PhysicsWorld.contactPush(contact, a, b, h: h)
            s.contacts[ci].lambda = SIMD4(push.lambda, push.speed, 0, 0)
            guard push.lambda > 0 else { continue }
            if -push.speed > PhysicsWorld.impactSpeed && (a.info.y | b.info.y) & PhysicsWorld.walkerBit == 0 {   // an impact, not a rest, a slide or the walker's step
                let impulse = push.lambda / h, point = PhysicsWorld.points(contact, a, b).pa, n = PhysicsMath.xyz(contact.normal)
                if a.info.y & PhysicsWorld.pieceBit != 0 { PhysicsWorld.strike(&s.fractureState[i], point, n, impulse) }
                if dynamic && b.info.y & PhysicsWorld.pieceBit != 0 { PhysicsWorld.strike(&s.fractureState[Int(code)], point, -n, impulse) }
                if dynamic { hitHeld(s, i, a, Int(code), b, impulse) }
            }
            PhysicsWorld.shove(&a, push.impulse, push.ra)
            PhysicsWorld.shove(&b, -push.impulse, push.rb)
        }
        s.bodies[i] = a
        if dynamic { s.bodies[Int(code)] = b }
    }

    /// PhysicsCPU.solveVelocities for pair `e` when there are fractured objects: its contacts' kicks, an impact's normal
    /// impulse onto both pieces' strain too (the push above moves an overlap apart at `pushSpeed` at most: the kick
    /// takes the rest of a hit's speed).
    @inline(__always) static func kickFracturePair(_ e: Int, _ s: StepBuffers, _ p: GPUPhysicsParams) {
        let i = e / PhysicsWorld.maxPairs, code = s.pairs[e].partner, dynamic = code & PhysicsWorld.staticBit == 0
        var a = s.bodies[i], b = s.partner(code)
        if PhysicsWorld.still(a, b) { return }   // (a weld's contact kicks nothing: its lambda.x is 0)
        for c in 0..<Int(s.pairs[e].contacts) {
            let contact = s.contacts[e * PhysicsWorld.maxContacts + c]
            guard let kick = PhysicsWorld.contactKick(contact, a, b, p) else { continue }
            if contact.lambda.y < -PhysicsWorld.impactSpeed && (a.info.y | b.info.y) & PhysicsWorld.pieceBit != 0
                && (a.info.y | b.info.y) & PhysicsWorld.walkerBit == 0 {
                let n = PhysicsMath.xyz(contact.normal), impulse = max(dot(kick.impulse, n), 0)
                if impulse > 0 {
                    let point = PhysicsWorld.points(contact, a, b).pa
                    if a.info.y & PhysicsWorld.pieceBit != 0 { PhysicsWorld.strike(&s.fractureState[i], point, n, impulse) }
                    if dynamic && b.info.y & PhysicsWorld.pieceBit != 0 { PhysicsWorld.strike(&s.fractureState[Int(code)], point, -n, impulse) }
                    if dynamic { hitHeld(s, i, a, Int(code), b, impulse) }
                }
            }
            PhysicsWorld.kick(&a, kick.impulse, kick.ra, kick.twist)
            PhysicsWorld.kick(&b, -kick.impulse, kick.rb, -kick.twist)
        }
        s.bodies[i] = a
        if dynamic { s.bodies[Int(code)] = b }
    }

    /// An impact between bodies i and j: a projectile's hardest hit on a held piece this step, kept in its state.
    @inline(__always) static func hitHeld(_ s: StepBuffers, _ i: Int, _ a: GPUPhysicsBody, _ j: Int, _ b: GPUPhysicsBody, _ impulse: Float) {
        if PhysicsWorld.fixed(b) && a.info.y & PhysicsWorld.pieceBit == 0 { PhysicsWorld.hit(&s.fractureState[i], j, impulse) }
        if PhysicsWorld.fixed(a) && b.info.y & PhysicsWorld.pieceBit == 0 { PhysicsWorld.hit(&s.fractureState[j], i, impulse) }
    }

    /// A piece held where it is (by the ground, or for now after its parent broke): no mass of its own.
    @inline(__always) static func fixed(_ b: GPUPhysicsBody) -> Bool { b.info.y & pieceBit != 0 && b.position.w == 0 }

    /// A projectile's hit on held piece `piece`: strain.x its impulse, strain.z the piece, if the hardest so far.
    @inline(__always) static func hit(_ s: inout GPUFractureState, _ piece: Int, _ impulse: Float) {
        guard impulse > s.strain.x else { return }
        s.strain.x = impulse
        s.strain.z = Float(piece)
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
        let tuning = fractureTuning, h = PhysicsWorld.stepLength, n = bodies.count
        let nodes = fractureNodes
        nodes.withUnsafeBufferPointer { nodes in
            // Phase A, each body's verdict...
            withStepBuffers { s in
                PhysicsPool.shared.parallel(n, grain: 128) { range in
                    for i in range { PhysicsWorld.verdict(s.bodies[i], &s.fractureState[i], nodes[i], h: h) }
                }
            }
            // ...then phase B, each against its parent as phase A left it (a copy: the parents change too)...
            let before = bodies, states = fractureState
            wakeFlags.removeAll(keepingCapacity: true)
            wakeFlags.append(contentsOf: repeatElement(0, count: n))
            wakeFlags.withUnsafeMutableBufferPointer { freed in
                before.withUnsafeBufferPointer { before in
                    states.withUnsafeBufferPointer { states in
                        withStepBuffers { s in
                            PhysicsPool.shared.parallel(n, grain: 128) { range in
                                for i in range {
                                    guard s.bodies[i].info.y & PhysicsWorld.pieceBit != 0 else {
                                        PhysicsWorld.giveWay(&s.bodies[i], s.fractureState[i], states)
                                        continue
                                    }
                                    let node = nodes[i], p = node.info.x == PhysicsWorld.none ? i : Int(node.info.x)
                                    let free = PhysicsWorld.apply(&s.bodies[i], &s.fractureState[i], node, parent: before[p], parentState: states[p],
                                                                  parentThreshold: nodes[p].offset.w, tuning: tuning)
                                    if free { freed[i] = 1 }
                                }
                            }
                        }
                    }
                }
                // ...and the welds of what came free broken (two freed pieces share one).
                for i in 0..<n where freed[i] != 0 { breakWelds(i) }
                // ...and what broke, for the dust (MSL physicsFractureEventsKernel: in body order, a step's first
                // `ringEvents`; from the pose phase B left).
                var logged = 0
                for i in 0..<n where logged < PhysicsWorld.ringEvents && states[i].strain.w == 1
                    && before[i].info.y & (PhysicsWorld.pieceBit | PhysicsWorld.disabledBit) == PhysicsWorld.pieceBit {
                    let b = bodies[i]
                    breakLog.append(GPUBreakEvent(position: SIMD4(PhysicsMath.xyz(b.position), b.invInertia.w),
                                                  velocity: SIMD4(PhysicsMath.xyz(b.velocity), nodes[i].extra.w)))
                    breakSteps.append(stepIndex)
                    logged += 1
                }
                breakTotal += logged
                if breakLog.count > PhysicsWorld.breakLogLength {
                    breakLog.removeFirst(breakLog.count - PhysicsWorld.breakLogLength)
                    breakSteps.removeFirst(breakSteps.count - PhysicsWorld.breakLogLength)
                }
            }
        }
    }

    /// Every weld of body `i` broken (it came free).
    func breakWelds(_ i: Int) {
        for k in Int(weldStarts[i])..<Int(weldStarts[i + 1]) { welds[Int(weldList[k].y)].info.z = 1 }
    }

    /// Phase B for a projectile b: if its hardest hit this step was on a held piece that broke or came free (`states`,
    /// as phase A left them), on at the speed it started the step at, into the pieces.
    @inline(__always) static func giveWay(_ b: inout GPUPhysicsBody, _ s: GPUFractureState, _ states: UnsafeBufferPointer<GPUFractureState>) {
        guard s.strain.x > 0, states[Int(s.strain.z)].strain.w != 0 else { return }
        b.velocity = SIMD4(xyz(s.impact), b.velocity.w)
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
    /// if it broke; in its parent's place if that broke; freed; let go after its hold; faded. Whether its welds break
    /// (it came free).
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
            if verdict == 2 {
                free(&b, node)
                s.hold.x = 0
            }
            if s.hold.x > 0 {   // held since its parent broke: let go
                s.hold.x -= stepLength
                if !(s.hold.x > 0) {
                    free(&b, node)
                    s.hold.x = 0
                }
            }
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
        let freed = inherited > node.extra.y
        // Held where it is if its parent was: by the ground if anchored, else for a moment unless freed.
        let anchored = node.info.w & anchoredNode != 0
        let held = parent.position.w == 0 && (anchored || !freed)
        b.position = SIMD4(x, held ? 0 : node.extra.x)
        b.rotation = q
        b.prevPosition = SIMD4(x, 0)
        b.prevRotation = q
        b.info.y &= ~(disabledBit | asleep)
        s = GPUFractureState()
        s.strain.z = inherited
        s.hold.x = held && !anchored ? holdAfterBreak : 0
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
