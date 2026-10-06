import Foundation
import simd

/// The CPU's step: the reference the GPU's (Shaders/Physics.metal) is checked against, and the backend for scenes with
/// few bodies, where a GPU dispatch costs more than the work. Each stage is what a kernel does, over every body, in
/// the same order. Contacts are solved a colour at a time (Gauss-Seidel): no two pairs of a colour share a body, so
/// the GPU solves a colour's pairs at once and gets the same numbers. So are the joints, after the contacts.
extension PhysicsWorld {
    func step() {
        let p = params
        broadPhase(p)
        wake(p)
        link()
        narrowPhase(p, refresh: false)
        colourPairs()
        particleBroadPhase(p)
        let start = bodies.map { SIMD8<Float>(lowHalf: $0.position, highHalf: $0.rotation) }
        for sub in 0..<substeps {
            // The contacts again where the substeps have taken the bodies: found once a step, a turning body's
            // contacts stay where it was (a rolling rim's sinks into the floor, and the push out of it launches it).
            if sub > 0 && sub % PhysicsWorld.contactRefresh == 0 { narrowPhase(p, refresh: true) }
            integrate(p)
            integrateParticles(p)
            solveCloth(p)
            solveTets(p)
            solveParticles(p)   // against the bodies where this substep moved them, before they are pushed apart
            solvePositions(p)
            solveVelocities(p)
        }
        settle(p, start)
        stepHair(start)
        stepIndex += 1
    }

    // MARK: Broad phase

    /// A body's bounding sphere for this step: its radius, as far as it may go (at up to the cell speed), and the margin.
    @inline(__always) static func reach(_ b: GPUPhysicsBody, _ p: GPUPhysicsParams) -> Float {
        b.invInertia.w + min(length(PhysicsMath.xyz(b.velocity)), p.sleep.w) * p.grid.w + p.grid.y
    }

    @inline(__always) static func cell(_ x: SIMD3<Float>, _ size: Float) -> SIMD3<Int32> {
        SIMD3<Int32>((x / size).rounded(.down))
    }

    /// The squared distance between two points, fused as Physics.metal's physDistance2 is: the GPU sorts partners by it
    /// into the same order, bit for bit.
    @inline(__always) static func distance2(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return (d.x * d.x).addingProduct(d.y, d.y).addingProduct(d.z, d.z)
    }

    /// Whether a sphere meets static collider `s`'s box (an endless plane: whether it reaches below it).
    func touchesStatic(_ s: Int, centre: SIMD3<Float>, radius: Float) -> Bool {
        let st = statics[s]
        if shapes[Int(st.info.x)].info.x == PhysicsShapeKind.plane.rawValue {
            let n = PhysicsMath.qrot(st.rotation, SIMD3(0, 1, 0))
            return dot(centre - PhysicsMath.xyz(st.position), n) < radius
        }
        let box = staticBounds[s]
        let nearest = simd_clamp(centre, box.lo, box.hi)
        return length_squared(centre - nearest) < radius * radius
    }

    /// Every body's partners: the static colliders it meets, then the bodies in the 27 cells around it whose spheres
    /// meet its own, nearest first (the lower first of equals), `maxPairs` at most: a crowded body drops its farthest
    /// bodies, never what holds it up. Two bodies a joint joins aren't partners (they overlap where it is). (Keeping the lowest-numbered instead, a tower's middle blocks dropped a body
    /// dragged into them, which went through.)
    private func broadPhase(_ p: GPUPhysicsParams) {
        let size = p.grid.x
        var grid: [SIMD3<Int32>: [Int]] = [:]
        for (i, b) in bodies.enumerated() { grid[PhysicsWorld.cell(PhysicsMath.xyz(b.position), size), default: []].append(i) }
        let k = PhysicsWorld.maxPairs
        for (i, b) in bodies.enumerated() {
            let x = PhysicsMath.xyz(b.position), r = PhysicsWorld.reach(b, p)
            let c = PhysicsWorld.cell(x, size)
            var found: [(Float, UInt32)] = []   // (distance squared, -1 for a static; partner)
            for dz: Int32 in -1...1 {
                for dy: Int32 in -1...1 {
                    for dx: Int32 in -1...1 {
                        for j in grid[c &+ SIMD3(dx, dy, dz)] ?? [] where j != i && !PhysicsWorld.joined(b, i, bodies[j], j) {
                            let o = bodies[j]
                            let reach = r + PhysicsWorld.reach(o, p)
                            let d2 = PhysicsWorld.distance2(PhysicsMath.xyz(o.position), x)
                            if d2 < reach * reach { found.append((d2, UInt32(j))) }
                        }
                    }
                }
            }
            for s in statics.indices where touchesStatic(s, centre: x, radius: r) { found.append((-1, UInt32(s) | PhysicsWorld.staticBit)) }
            found.sort { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
            pairCounts[i] = UInt32(min(found.count, k))
            for (n, f) in found.prefix(k).enumerated() { pairs[i * k + n] = GPUPhysicsPair(partner: f.1) }
        }
    }

    /// A sleeping body wakes when something it touches moves faster than the wake speed, or turns its mass faster than
    /// the wake turn (its turn rate x its radius of gyration about the turn, at most `gyration`), above the sleep ones: a neighbour settling
    /// down beside it doesn't, nor a thin limb jittering about its length.
    @inline(__always) static func stirs(_ b: GPUPhysicsBody, _ p: GPUPhysicsParams) -> Bool {
        guard moves(b) else { return false }
        if length(PhysicsMath.xyz(b.velocity)) > p.rolling.z { return true }
        let omega = PhysicsMath.xyz(b.angular), rate = length(omega)
        guard rate > 1e-9 else { return false }
        let w = turnWeight(b, omega / rate)
        return w > 0 && rate * min(sqrt(b.position.w / w), gyration) > p.rolling.w
    }

    private func wake(_ p: GPUPhysicsParams) {
        let k = PhysicsWorld.maxPairs
        let before = bodies
        for i in bodies.indices where before[i].info.y & PhysicsWorld.asleep != 0 {
            for n in 0..<Int(pairCounts[i]) {
                let partner = pairs[i * k + n].partner
                guard partner & PhysicsWorld.staticBit == 0, PhysicsWorld.stirs(before[Int(partner)], p) else { continue }
                bodies[i].info.y &= ~PhysicsWorld.asleep
                bodies[i].prevPosition.w = 0
                break
            }
        }
        // A ragdoll wakes whole: if any of its bodies is awake (or held), the rest wake.
        for r in ragdolls {
            let range = Int(r.x)..<Int(r.x + r.y)
            guard range.contains(where: { PhysicsWorld.moves(bodies[$0]) || grab.target.w > 0 && grab.body == UInt32($0) }) else { continue }
            for i in range where bodies[i].info.y & PhysicsWorld.asleep != 0 {
                bodies[i].info.y &= ~PhysicsWorld.asleep
                bodies[i].prevPosition.w = 0
            }
        }
    }

    /// Each entry's owner: the lower body of two, or the body against a static. Another body's entry points at the
    /// owner's. A pair one of the two dropped (a crowded body keeps its nearest) neither has: the colours see a pair
    /// only through both bodies' lists, and one the higher body didn't list took a colour beside its other pairs, and
    /// two GPU threads moved that body at once (a dense pile's runs differed after a second).
    private func link() {
        let k = PhysicsWorld.maxPairs
        for i in bodies.indices {
            for n in 0..<Int(pairCounts[i]) {
                let e = i * k + n, partner = pairs[e].partner
                if partner & PhysicsWorld.staticBit != 0 {
                    pairs[e].link = UInt32(e)
                    continue
                }
                if Int(partner) > i {
                    let o = Int(partner)
                    pairs[e].link = (0..<Int(pairCounts[o])).contains { pairs[o * k + $0].partner == UInt32(i) } ? UInt32(e) : PhysicsWorld.none
                    continue
                }
                let o = Int(partner)
                pairs[e].link = PhysicsWorld.none
                for m in 0..<Int(pairCounts[o]) where pairs[o * k + m].partner == UInt32(i) {
                    pairs[e].link = UInt32(o * k + m)
                    break
                }
            }
        }
    }

    // MARK: Narrow phase

    /// The partner's record: a body, or a static collider.
    @inline(__always) func partner(_ code: UInt32) -> GPUPhysicsBody {
        code & PhysicsWorld.staticBit != 0 ? statics[Int(code & ~PhysicsWorld.staticBit)] : bodies[Int(code)]
    }

    /// Each owned entry's contacts, closer than the margin plus how far the two may close in a step.
    /// `refresh`: within the step, when only the pairs that had contacts at its start, and of which a body moves, are
    /// found again.
    private func narrowPhase(_ p: GPUPhysicsParams, refresh: Bool) {
        let k = PhysicsWorld.maxPairs
        for i in bodies.indices {
            let a = bodies[i]
            for n in 0..<Int(pairCounts[i]) {
                let e = i * k + n
                guard pairs[e].link == UInt32(e) else { continue }
                let b = partner(pairs[e].partner)
                // A refresh: the coloured pairs (with contacts at the step's start) of which a body moves.
                if refresh && (pairs[e].pad == PhysicsWorld.none || !PhysicsWorld.moves(a) && !PhysicsWorld.moves(b)) { continue }
                let closing = (length(PhysicsMath.xyz(a.velocity)) + length(PhysicsMath.xyz(b.velocity))
                               + length(PhysicsMath.xyz(a.angular)) * a.invInertia.w
                               + length(PhysicsMath.xyz(b.angular)) * b.invInertia.w) * p.grid.w
                let manifold = collide(a, b, margin: p.grid.y + closing)
                let pa = Pose(a), pb = Pose(b)
                pairs[e].contacts = UInt32(manifold.points.count)
                for (c, point) in manifold.points.enumerated() {
                    contacts[e * PhysicsWorld.maxContacts + c] = GPUPhysicsContact(
                        normal: SIMD4(point.normal, point.separation),
                        anchorA: SIMD4(pa.toBody(point.pointA), point.radiusA),
                        anchorB: SIMD4(pb.toBody(point.pointB), point.radiusB),
                        lambda: .zero)
                }
            }
        }
    }

    // MARK: Colours

    /// A pair's priority in the colouring: a hash of its entry (Physics.metal physPairPriority), so that neighbours
    /// numbered in a row (a sorted pile) don't wait on each other one at a time; the entry breaks ties.
    @inline(__always) static func priority(_ e: UInt32) -> UInt64 {
        var x = e &* 0x9E37_79B1
        x ^= x >> 16
        x &*= 0x85EB_CA6B
        x ^= x >> 13
        return UInt64(x) << 32 | UInt64(e)
    }

    /// The owned pairs with contacts in colours, once a step, no two of a colour sharing a body (the contacts reach as
    /// far as a pair can close in a step, so a pair without any meets in none of its refreshes either). Jones-Plassmann:
    /// in each round, every pair outranking the uncoloured pairs it shares a body with takes the lowest colour none of
    /// those it shares a body with has (at most 31: a pair shares its bodies with 30 others at most). What
    /// `maxRounds` rounds leave (pad = `leftover`) is solved one pair after another, after the colours.
    private func colourPairs() {
        let k = PhysicsWorld.maxPairs
        func live(_ e: Int) -> Bool { e % k < Int(pairCounts[e / k]) && pairs[e].link == UInt32(e) && pairs[e].contacts > 0 }
        func touching(_ i: Int) -> [Int] {
            (0..<Int(pairCounts[i])).compactMap { n in
                let link = pairs[i * k + n].link
                return link != PhysicsWorld.none && pairs[Int(link)].contacts > 0 ? Int(link) : nil
            }
        }
        func around(_ e: Int) -> [Int] {
            let code = pairs[e].partner
            return touching(e / k) + (code & PhysicsWorld.staticBit == 0 ? touching(Int(code)) : [])
        }
        var left: [Int] = []
        for e in pairs.indices {
            pairs[e].pad = PhysicsWorld.none
            if live(e) { left.append(e) }
        }
        var rounds = 0
        while !left.isEmpty && rounds < PhysicsWorld.maxRounds {
            let mine = { (e: Int) in PhysicsWorld.priority(UInt32(e)) }
            let chosen = left.filter { e in
                around(e).allSatisfy { q in q == e || pairs[q].pad != PhysicsWorld.none || mine(q) < mine(e) }
            }
            for e in chosen {
                var used: UInt64 = 0
                for q in around(e) where q != e && pairs[q].pad != PhysicsWorld.none { used |= 1 << UInt64(pairs[q].pad) }
                pairs[e].pad = UInt32((~used).trailingZeroBitCount)
            }
            left.removeAll { pairs[$0].pad != PhysicsWorld.none }
            rounds += 1
        }
        for e in left { pairs[e].pad = PhysicsWorld.leftover }
        let colours = Int(pairs.filter { $0.pad < PhysicsWorld.leftover }.map(\.pad).max().map { $0 + 1 } ?? 0)
        pairOrder = []
        pairColourStarts = [0]
        for c in 0..<colours {
            pairOrder += pairs.indices.filter { pairs[$0].pad == UInt32(c) }.map(UInt32.init)
            pairColourStarts.append(UInt32(pairOrder.count))
        }
        pairOrder += left.map(UInt32.init)   // the rest: one after another
        pairColourStarts.append(UInt32(pairOrder.count))
    }

    // MARK: Substeps

    @inline(__always) static func moves(_ b: GPUPhysicsBody) -> Bool { b.position.w > 0 && b.info.y & PhysicsWorld.asleep == 0 }

    /// Every moving body by its velocity and gravity; the held one (`grab`) woken, slowed and pulled to the target.
    private func integrate(_ p: GPUPhysicsParams) {
        let h = p.gravity.w
        for i in bodies.indices {
            let held = grab.target.w > 0 && grab.body == UInt32(i)
            if held {
                bodies[i].info.y &= ~PhysicsWorld.asleep
                bodies[i].prevPosition.w = 0
            }
            guard PhysicsWorld.moves(bodies[i]) else { continue }
            var b = bodies[i]
            b.prevPosition = SIMD4(PhysicsMath.xyz(b.position), b.prevPosition.w)
            b.prevRotation = b.rotation
            let decay: Float = held ? max(1 - PhysicsWorld.holdDamping * h, 0) : 1
            b.angular = SIMD4(PhysicsMath.xyz(b.angular) * decay, b.angular.w)
            var v = PhysicsMath.xyz(b.velocity) * decay + PhysicsMath.xyz(p.gravity) * h
            let speed = length(v)
            if speed > p.grid.z { v *= p.grid.z / speed }
            b.velocity = SIMD4(v, b.velocity.w)
            b.position = SIMD4(PhysicsMath.xyz(b.position) + v * h, b.position.w)
            b.rotation = PhysicsMath.qturn(b.rotation, PhysicsMath.xyz(b.angular) * h)
            if held { PhysicsWorld.hold(&b, grab) }
            bodies[i] = b
        }
    }

    /// The held body's anchor a fraction (`holdPull`) of the way to the target, shared between moving and turning
    /// it by its inverse mass and inertia there (as a contact's push is): a body held off its centre swings and hangs.
    @inline(__always) static func hold(_ b: inout GPUPhysicsBody, _ g: GPUPhysicsGrab) {
        let r = PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(g.anchor))
        let gap = PhysicsMath.xyz(g.target) - (PhysicsMath.xyz(b.position) + r)
        let l = length(gap)
        guard l > 1e-7 else { return }
        let n = gap / l
        let w = weight(b, r, n)
        guard w > 0 else { return }
        shove(&b, n * (l * holdPull / w), r)
    }

    /// A contact's world points and lever arms (from each centre of mass) for the poses given.
    @inline(__always) static func points(_ c: GPUPhysicsContact, _ a: GPUPhysicsBody, _ b: GPUPhysicsBody, previous: Bool = false)
        -> (pa: SIMD3<Float>, pb: SIMD3<Float>, ra: SIMD3<Float>, rb: SIMD3<Float>) {
        let n = PhysicsMath.xyz(c.normal)
        let xa = PhysicsMath.xyz(previous && moves(a) ? a.prevPosition : a.position)
        let xb = PhysicsMath.xyz(previous && moves(b) ? b.prevPosition : b.position)
        let ra = PhysicsMath.qrot(previous && moves(a) ? a.prevRotation : a.rotation, PhysicsMath.xyz(c.anchorA)) - n * c.anchorA.w
        let rb = PhysicsMath.qrot(previous && moves(b) ? b.prevRotation : b.rotation, PhysicsMath.xyz(c.anchorB)) + n * c.anchorB.w
        return (xa + ra, xb + rb, ra, rb)
    }

    /// The generalised inverse mass of body `b` at lever arm `r` along `n` (0 for one that doesn't move).
    @inline(__always) static func weight(_ b: GPUPhysicsBody, _ r: SIMD3<Float>, _ n: SIMD3<Float>) -> Float {
        guard moves(b) else { return 0 }
        let rn = cross(r, n)
        return b.position.w + dot(rn, PhysicsMath.applyInvInertia(b.rotation, PhysicsMath.xyz(b.invInertia), rn))
    }

    /// A contact's position correction: its normal push (lambda) and, if static friction holds it, its tangential one
    /// (the impulse on A; B takes the opposite), and the normal speed before it. The same numbers for both bodies.
    @inline(__always) static func contactPush(_ c: GPUPhysicsContact, _ a: GPUPhysicsBody, _ b: GPUPhysicsBody, h: Float)
        -> (impulse: SIMD3<Float>, lambda: Float, speed: Float, ra: SIMD3<Float>, rb: SIMD3<Float>) {
        let n = PhysicsMath.xyz(c.normal)
        let (pa, pb, ra, rb) = points(c, a, b)
        let va = PhysicsMath.xyz(a.velocity) + cross(PhysicsMath.xyz(a.angular), ra)
        let vb = PhysicsMath.xyz(b.velocity) + cross(PhysicsMath.xyz(b.angular), rb)
        let speed = dot(va - vb, n)
        // A deep overlap (bodies placed into each other, or a fast hit) comes apart at no more than `pushSpeed`: what
        // the push moves a body becomes its velocity, and a whole overlap in one substep would fling it.
        let depth = max(dot(pa - pb, n), -PhysicsWorld.pushSpeed * h)
        guard depth < 0 else { return (.zero, 0, speed, ra, rb) }
        let w = weight(a, ra, n) + weight(b, rb, n)
        guard w > 0 else { return (.zero, 0, speed, ra, rb) }
        let lambda = -depth / w
        var impulse = n * lambda
        // Static friction: undo how far the two points slid past each other this substep, if it takes no more than
        // friction x the normal push.
        let (qa, qb, _, _) = points(c, a, b, previous: true)
        let slide = (pa - qa) - (pb - qb)
        let tangent = slide - n * dot(slide, n)
        let l = length(tangent)
        if l > 1e-7 {
            let t = tangent / l
            let wt = weight(a, ra, t) + weight(b, rb, t)
            let friction = sqrt(a.velocity.w * b.velocity.w)
            if wt > 0 && l / wt < friction * lambda { impulse -= t * (l / wt) }
        }
        return (impulse, lambda, speed, ra, rb)
    }

    /// Moves body `b` (if it moves) by `impulse` at lever arm `r`.
    @inline(__always) static func shove(_ b: inout GPUPhysicsBody, _ impulse: SIMD3<Float>, _ r: SIMD3<Float>) {
        guard moves(b) else { return }
        b.position = SIMD4(PhysicsMath.xyz(b.position) + impulse * b.position.w, b.position.w)
        b.rotation = PhysicsMath.qturn(b.rotation, PhysicsMath.applyInvInertia(b.rotation, PhysicsMath.xyz(b.invInertia), cross(r, impulse)))
    }

    /// Speeds body `b` (if it moves) up by `impulse` at lever arm `r` and angular impulse `twist`.
    @inline(__always) static func kick(_ b: inout GPUPhysicsBody, _ impulse: SIMD3<Float>, _ r: SIMD3<Float>, _ twist: SIMD3<Float>) {
        guard moves(b) else { return }
        b.velocity = SIMD4(PhysicsMath.xyz(b.velocity) + impulse * b.position.w, b.velocity.w)
        b.angular = SIMD4(PhysicsMath.xyz(b.angular)
                          + PhysicsMath.applyInvInertia(b.rotation, PhysicsMath.xyz(b.invInertia), cross(r, impulse) + twist), b.angular.w)
    }

    /// Pair `e`'s contacts, one after the other, each pushing both bodies at once (`body` does it to the two).
    private func solvePair(_ e: Int, _ body: (inout GPUPhysicsBody, inout GPUPhysicsBody, GPUPhysicsContact, Int) -> Void) {
        let i = e / PhysicsWorld.maxPairs, code = pairs[e].partner, dynamic = code & PhysicsWorld.staticBit == 0
        var a = bodies[i], b = partner(code)
        for c in 0..<Int(pairs[e].contacts) {
            let ci = e * PhysicsWorld.maxContacts + c
            body(&a, &b, contacts[ci], ci)
        }
        bodies[i] = a
        if dynamic { bodies[Int(code)] = b }
    }

    /// The joints, then the contacts' pushes, a colour at a time, then every moving body's velocities from how far it went.
    private func solvePositions(_ p: GPUPhysicsParams) {
        let h = p.gravity.w
        // The joints first, a colour at a time (twice: PhysicsWorld.jointIterations), then the contacts: static
        // friction undoes what the substep slid a contact, the joints' pushes included. (Joints after the contacts
        // slid a resting ragdoll's chest a little every substep, out of friction's reach: it crept and never slept.)
        for _ in 0..<PhysicsWorld.jointIterations {
            for c in 0..<(jointStarts.count - 1) {
                for k in Int(jointStarts[c])..<Int(jointStarts[c + 1]) {
                    let j = joints[k], ia = Int(j.info.x), ib = Int(j.info.y)
                    var a = bodies[ia], b = bodies[ib]
                    PhysicsWorld.solveJoint(j, &a, &b)
                    bodies[ia] = a
                    bodies[ib] = b
                }
            }
        }
        for e in pairOrder {
            solvePair(Int(e)) { a, b, contact, ci in
                let push = PhysicsWorld.contactPush(contact, a, b, h: h)
                contacts[ci].lambda = SIMD4(push.lambda, push.speed, 0, 0)
                guard push.lambda > 0 else { return }
                PhysicsWorld.shove(&a, push.impulse, push.ra)
                PhysicsWorld.shove(&b, -push.impulse, push.rb)
            }
        }
        for i in bodies.indices where PhysicsWorld.moves(bodies[i]) {
            var b = bodies[i]
            b.velocity = SIMD4((PhysicsMath.xyz(b.position) - PhysicsMath.xyz(b.prevPosition)) / h, b.velocity.w)
            var dq = PhysicsMath.qmul(b.rotation, PhysicsMath.qconj(b.prevRotation))
            if dq.w < 0 { dq = -dq }
            b.angular = SIMD4(2 * PhysicsMath.xyz(dq) / h, b.angular.w)
            bodies[i] = b
        }
    }

    /// The generalised inverse inertia of body `b` about axis `k` (0 for one that doesn't move).
    @inline(__always) static func turnWeight(_ b: GPUPhysicsBody, _ k: SIMD3<Float>) -> Float {
        moves(b) ? dot(k, PhysicsMath.applyInvInertia(b.rotation, PhysicsMath.xyz(b.invInertia), k)) : 0
    }

    /// A contact's velocity change: dynamic friction against the sliding, and restitution (none for slow impacts);
    /// and its angular impulse (on A; B takes the opposite) against rolling and spinning on the spot, each held back by
    /// at most its resistance (a length) x the normal impulse.
    @inline(__always) static func contactKick(_ c: GPUPhysicsContact, _ a: GPUPhysicsBody, _ b: GPUPhysicsBody, _ p: GPUPhysicsParams)
        -> (impulse: SIMD3<Float>, twist: SIMD3<Float>, ra: SIMD3<Float>, rb: SIMD3<Float>)? {
        let lambda = c.lambda.x
        guard lambda > 0 else { return nil }
        let n = PhysicsMath.xyz(c.normal), h = p.gravity.w
        let (_, _, ra, rb) = points(c, a, b)
        let va = PhysicsMath.xyz(a.velocity) + cross(PhysicsMath.xyz(a.angular), ra)
        let vb = PhysicsMath.xyz(b.velocity) + cross(PhysicsMath.xyz(b.angular), rb)
        let v = va - vb
        let vn = dot(v, n)
        let vt = v - n * vn
        var dv = SIMD3<Float>()
        let slide = length(vt)
        if slide > 1e-6 {
            // Coulomb: the sliding slows by at most friction x the normal speed the push gave (lambda w / h).
            let friction = sqrt(a.velocity.w * b.velocity.w)
            let pushed = lambda * (weight(a, ra, n) + weight(b, rb, n)) / h
            dv -= vt / slide * min(friction * pushed, slide)
        }
        let before = c.lambda.y
        let e = abs(before) <= 2 * length(PhysicsMath.xyz(p.gravity)) * h ? 0 : max(a.angular.w, b.angular.w)
        dv += n * (-vn + max(-e * before, 0))
        var impulse = SIMD3<Float>()
        let l = length(dv)
        if l > 1e-7 {
            let w = weight(a, ra, dv / l) + weight(b, rb, dv / l)
            if w > 0 { impulse = dv / w }
        }
        // Rolling and spinning: the relative turn across the normal and about it, each stopped by an angular impulse
        // of up to resistance x the normal impulse (lambda / h).
        var twist = SIMD3<Float>()
        let spin = PhysicsMath.xyz(a.angular) - PhysicsMath.xyz(b.angular)
        let about = n * dot(spin, n)
        for (part, resistance) in [(spin - about, p.rolling.x), (about, p.rolling.y)] {
            let speed = length(part)
            guard speed > 1e-6 else { continue }
            let k = part / speed
            let w = turnWeight(a, k) + turnWeight(b, k)
            guard w > 0 else { continue }
            twist -= k * min(speed / w, resistance * lambda / h)
        }
        guard impulse != .zero || twist != .zero else { return nil }
        return (impulse, twist, ra, rb)
    }

    /// The contacts' velocity changes, a colour of pairs at a time.
    private func solveVelocities(_ p: GPUPhysicsParams) {
        for e in pairOrder {
            solvePair(Int(e)) { a, b, contact, _ in
                guard let kick = PhysicsWorld.contactKick(contact, a, b, p) else { return }
                PhysicsWorld.kick(&a, kick.impulse, kick.ra, kick.twist)
                PhysicsWorld.kick(&b, -kick.impulse, kick.rb, -kick.twist)
            }
        }
        for c in 0..<(jointStarts.count - 1) {
            for k in Int(jointStarts[c])..<Int(jointStarts[c + 1]) {
                let j = joints[k], ia = Int(j.info.x), ib = Int(j.info.y)
                var a = bodies[ia], b = bodies[ib]
                PhysicsWorld.dampJoint(j, &a, &b, h: p.gravity.w)
                bodies[ia] = a
                bodies[ib] = b
            }
        }
    }

    // MARK: Joints

    /// Turns `a` by `correction` (an angle times an axis) and `b` by its opposite, shared by their inverse inertia
    /// about the axis (an XPBD angular constraint of no compliance).
    @inline(__always) static func swivel(_ a: inout GPUPhysicsBody, _ b: inout GPUPhysicsBody, _ correction: SIMD3<Float>) {
        let angle = length(correction)
        guard angle > 1e-7 else { return }
        let k = correction / angle
        let w = turnWeight(a, k) + turnWeight(b, k)
        guard w > 0 else { return }
        let impulse = k * (angle / w)
        if moves(a) { a.rotation = PhysicsMath.qturn(a.rotation, PhysicsMath.applyInvInertia(a.rotation, PhysicsMath.xyz(a.invInertia), impulse)) }
        if moves(b) { b.rotation = PhysicsMath.qturn(b.rotation, -PhysicsMath.applyInvInertia(b.rotation, PhysicsMath.xyz(b.invInertia), impulse)) }
    }

    /// The turn of A about `n` that brings the angle from `n1` (A's) to `n2` (B's) about `n` back within [lo, hi].
    @inline(__always) static func limitAngle(_ n: SIMD3<Float>, _ n1: SIMD3<Float>, _ n2: SIMD3<Float>, _ lo: Float, _ hi: Float) -> SIMD3<Float> {
        let phi = atan2(dot(cross(n1, n2), n), dot(n1, n2))
        return n * (phi - min(max(phi, lo), hi))
    }

    /// `v` less its part along unit `n`, as a unit vector (0 if nothing is left).
    @inline(__always) static func across(_ v: SIMD3<Float>, _ n: SIMD3<Float>) -> SIMD3<Float> {
        let u = v - n * dot(v, n)
        let l = length(u)
        return l > 1e-6 ? u / l : .zero
    }

    /// Joint `j` between `a` and `b` (Müller et al. 2020): the turn limits (a ball joint's swing cone and twist; a
    /// hinge's axes together and its angle), then the anchors together.
    @inline(__always) static func solveJoint(_ j: GPUPhysicsJoint, _ a: inout GPUPhysicsBody, _ b: inout GPUPhysicsBody) {
        guard moves(a) || moves(b) else { return }
        let lo = j.axisA.w, hi = j.axisB.w
        var axisA = PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.axisA)), axisB = PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(j.axisB))
        let bend = cross(axisA, axisB), sine = length(bend)
        if j.info.z == PhysicsJointKind.hinge.rawValue {
            if sine > 1e-6 { swivel(&a, &b, bend / sine * atan2(sine, dot(axisA, axisB))) }
            axisA = PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.axisA))
            let n1 = across(PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.referenceA)), axisA)
            let n2 = across(PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(j.referenceB)), axisA)
            swivel(&a, &b, limitAngle(axisA, n1, n2, lo, hi))
        } else {
            let swing = atan2(sine, dot(axisA, axisB))
            if sine > 1e-6 && swing > j.referenceA.w { swivel(&a, &b, bend / sine * (swing - j.referenceA.w)) }
            axisA = PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.axisA))
            axisB = PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(j.axisB))
            let mid = axisA + axisB, l = length(mid)
            if l > 1e-6 {
                let n = mid / l
                let n1 = across(PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.referenceA)), n)
                let n2 = across(PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(j.referenceB)), n)
                swivel(&a, &b, limitAngle(n, n1, n2, lo, hi))
            }
        }
        let ra = PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.anchorA)), rb = PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(j.anchorB))
        let gap = (PhysicsMath.xyz(b.position) + rb) - (PhysicsMath.xyz(a.position) + ra)
        let l = length(gap)
        guard l > 1e-7 else { return }
        let n = gap / l
        let w = weight(a, ra, n) + weight(b, rb, n)
        guard w > 0 else { return }
        shove(&a, n * (l / w), ra)
        shove(&b, -n * (l / w), rb)
    }

    /// Body `b`'s inverse inertia about axis `k` through the point at lever arm `r` (from its centre): what turning
    /// it about a joint's anchor takes, its mass going round the anchor included (0 for one that doesn't move).
    @inline(__always) static func anchorTurnWeight(_ b: GPUPhysicsBody, _ k: SIMD3<Float>, _ r: SIMD3<Float>) -> Float {
        let w = turnWeight(b, k)
        guard w > 0 else { return 0 }
        return 1 / (1 / w + length_squared(cross(k, r)) / b.position.w)
    }

    /// Joint `j`'s damping: the two bodies' relative turning fades at its rate, each turned about the anchor (its
    /// velocity with it) by an angular impulse shared by their inertia about it. (Slowing only their turning about
    /// their centres hardly slowed a head swinging on its neck: the joint gave the turning back from how its centre
    /// still went round the anchor.)
    @inline(__always) static func dampJoint(_ j: GPUPhysicsJoint, _ a: inout GPUPhysicsBody, _ b: inout GPUPhysicsBody, h: Float) {
        let relative = PhysicsMath.xyz(b.angular) - PhysicsMath.xyz(a.angular)
        let speed = length(relative)
        guard speed > 1e-6 else { return }
        let k = relative / speed
        let ra = PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.anchorA)), rb = PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(j.anchorB))
        let wa = anchorTurnWeight(a, k, ra), wb = anchorTurnWeight(b, k, rb)
        guard wa + wb > 0 else { return }
        let impulse = speed * min(j.referenceB.w * h, 1) / (wa + wb)
        if wa > 0 {
            let turn = k * (impulse * wa)
            a.angular = SIMD4(PhysicsMath.xyz(a.angular) + turn, a.angular.w)
            a.velocity = SIMD4(PhysicsMath.xyz(a.velocity) - cross(turn, ra), a.velocity.w)
        }
        if wb > 0 {
            let turn = -k * (impulse * wb)
            b.angular = SIMD4(PhysicsMath.xyz(b.angular) + turn, b.angular.w)
            b.velocity = SIMD4(PhysicsMath.xyz(b.velocity) - cross(turn, rb), b.velocity.w)
        }
    }

    /// Whether body `b` went slower than the sleep speed this step, and turned its mass slower than the sleep turn (its
    /// turn x its radius of gyration about the turn's axis, at most `gyration`), from `position` and `rotation` (where its velocities say
    /// little: at rest on a few contacts they are what the last substep's kicks left, which the next substep's pushes
    /// take back).
    @inline(__always) static func still(_ b: GPUPhysicsBody, _ position: SIMD4<Float>, _ rotation: SIMD4<Float>,
                                        _ p: GPUPhysicsParams) -> Bool {
        let moved = length(PhysicsMath.xyz(b.position) - PhysicsMath.xyz(position))
        let turn = PhysicsMath.xyz(PhysicsMath.qmul(b.rotation, PhysicsMath.qconj(rotation)))
        let sine = length(turn)
        guard moved < p.sleep.x * p.grid.w else { return false }
        guard sine > 1e-9 else { return true }
        let w = turnWeight(b, turn / sine)
        return w <= 0 || 2 * sine * min(sqrt(b.position.w / w), gyration) < p.sleep.y * p.grid.w
    }

    /// After the substeps: a body that has been slow for long enough falls asleep, once the bodies it touches (has
    /// contacts with) have been slow for half as long (or sleep): a pile goes to sleep together, not one body propped on moving ones.
    private func settle(_ p: GPUPhysicsParams, _ start: [SIMD8<Float>]) {
        for i in bodies.indices where PhysicsWorld.moves(bodies[i]) {
            let b = bodies[i]
            bodies[i].prevPosition.w = PhysicsWorld.still(b, start[i].lowHalf, start[i].highHalf, p) ? b.prevPosition.w + p.grid.w : 0
        }
        let k = PhysicsWorld.maxPairs, timers = bodies
        var sleeps = [Bool](repeating: false, count: bodies.count)
        for i in bodies.indices where PhysicsWorld.moves(timers[i]) && timers[i].prevPosition.w > p.sleep.z {
            var settled = true
            for n in 0..<Int(pairCounts[i]) {
                let e = i * k + n, partner = pairs[e].partner, link = pairs[e].link
                guard partner & PhysicsWorld.staticBit == 0, link != PhysicsWorld.none, pairs[Int(link)].contacts > 0 else { continue }
                let o = timers[Int(partner)]
                if PhysicsWorld.moves(o) && o.prevPosition.w <= p.sleep.z / 2 { settled = false; break }
            }
            sleeps[i] = settled
        }
        // A ragdoll sleeps whole: while any of its moving bodies can't, none does (one asleep would hold its joints).
        for r in ragdolls {
            let range = Int(r.x)..<Int(r.x + r.y)
            if range.contains(where: { PhysicsWorld.moves(timers[$0]) && !sleeps[$0] }) { for i in range { sleeps[i] = false } }
        }
        for i in bodies.indices where sleeps[i] {
            bodies[i].info.y |= PhysicsWorld.asleep
            bodies[i].velocity = SIMD4(.zero, timers[i].velocity.w)
            bodies[i].angular = SIMD4(.zero, timers[i].angular.w)
        }
    }

    // MARK: Particles

    /// A particle's reach this step: its radius, as far as it goes (at up to the particle speed), and the margin.
    @inline(__always) static func particleReach(_ q: GPUPhysicsParticle, _ p: GPUPhysicsParams) -> Float {
        q.position.w + min(length(PhysicsMath.xyz(q.velocity)), p.particleGrid.y) * p.grid.w + p.grid.y
    }

    /// Every particle's neighbours (the nearest `maxNeighbours` within reach, the lower first of equals) and the
    /// colliders it may touch (statics, then bodies, the lowest `maxColliders`).
    private func particleBroadPhase(_ p: GPUPhysicsParams) {
        let size = p.particleGrid.x, k = PhysicsWorld.maxNeighbours, kc = PhysicsWorld.maxColliders
        var grid: [SIMD3<Int32>: [Int]] = [:]
        for (i, q) in particles.enumerated() { grid[PhysicsWorld.cell(PhysicsMath.xyz(q.position), size), default: []].append(i) }
        for (i, q) in particles.enumerated() {
            let x = PhysicsMath.xyz(q.position), r = PhysicsWorld.particleReach(q, p)
            let c = PhysicsWorld.cell(x, size)
            var found: [(Float, UInt32)] = []
            for dz: Int32 in -1...1 {
                for dy: Int32 in -1...1 {
                    for dx: Int32 in -1...1 {
                        for j in grid[c &+ SIMD3(dx, dy, dz)] ?? [] where j != i {
                            let o = particles[j]
                            if !PhysicsWorld.meets(q, o) { continue }   // cloths only meet colliders, a soft body not itself
                            let reach = r + PhysicsWorld.particleReach(o, p)
                            let d2 = length_squared(PhysicsMath.xyz(o.position) - x)
                            if d2 < reach * reach { found.append((d2, UInt32(j))) }
                        }
                    }
                }
            }
            found.sort { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
            neighbourCounts[i] = UInt32(min(found.count, k))
            for (n, f) in found.prefix(k).enumerated() { neighbours[i * k + n] = f.1 }
            var touching: [UInt32] = []
            for s in statics.indices where touchesStatic(s, centre: x, radius: r) { touching.append(UInt32(s) | PhysicsWorld.staticBit) }
            for (j, b) in bodies.enumerated() {
                let reach = r + PhysicsWorld.reach(b, p)
                if length_squared(PhysicsMath.xyz(b.position) - x) < reach * reach { touching.append(UInt32(j)) }
            }
            touching.sort { ($0 ^ PhysicsWorld.staticBit) < ($1 ^ PhysicsWorld.staticBit) }
            colliderCounts[i] = UInt32(min(touching.count, kc))
            for (n, code) in touching.prefix(kc).enumerated() { colliders[i * kc + n] = code }
        }
    }

    private func integrateParticles(_ p: GPUPhysicsParams) {
        let h = p.gravity.w
        for i in particles.indices where particles[i].prevPosition.w > 0 {   // (a pinned cloth vertex stays)
            var q = particles[i]
            q.prevPosition = SIMD4(PhysicsMath.xyz(q.position), q.prevPosition.w)
            let rate = q.info.y & PhysicsWorld.clothBit != 0 ? p.particleGrid.z : q.info.y & PhysicsWorld.softBit != 0 ? p.softDamping.x : 0
            let drag = max(1 - rate * h, 0)
            var v = PhysicsMath.xyz(q.velocity) * drag + PhysicsMath.xyz(p.gravity) * h
            let speed = length(v)
            if speed > p.grid.z { v *= p.grid.z / speed }
            q.velocity = SIMD4(v, q.velocity.w)
            q.position = SIMD4(PhysicsMath.xyz(q.position) + v * h, q.position.w)
            particles[i] = q
        }
    }

    /// A push of `overlap` along `n` less the sliding friction holds back: all of `slide`'s tangential part while it
    /// is under friction x the overlap (static), otherwise that much of it (dynamic).
    @inline(__always) static func particlePush(_ n: SIMD3<Float>, _ overlap: Float, _ slide: SIMD3<Float>, _ friction: Float) -> SIMD3<Float> {
        var push = n * overlap
        let tangent = slide - n * dot(slide, n)
        let l = length(tangent)
        if l > 1e-7 { push -= tangent * min(friction * overlap / l, 1) }
        return push
    }

    /// Whether a particle that went `moved` this substep stays put (PhysicsCPU.solveParticles).
    @inline(__always) static func rests(_ q: GPUPhysicsParticle, touching: Bool, shoved: Bool, moved: SIMD3<Float>,
                                        _ p: GPUPhysicsParams) -> Bool {
        touching && !shoved && q.info.y & (clothBit | softBit) == 0 && length(moved) < p.particleGrid.w * p.gravity.w
    }

    /// Each particle's pushes (Jacobi): its neighbours' overlaps, shared by mass and averaged, and the colliders' in
    /// full (they don't give), averaged too; then its velocity from how far it went. A soft body's particle takes both
    /// summed, and faster (`softPushSpeed`): its links hold it among its own, and averaged pushes let a body shove it
    /// in, or a jelly on top sink into it.
    private func solveParticles(_ p: GPUPhysicsParams) {
        let h = p.gravity.w, k = PhysicsWorld.maxNeighbours, kc = PhysicsWorld.maxColliders
        let before = particles
        for i in before.indices where before[i].prevPosition.w > 0 {
            let q = before[i]
            let x = PhysicsMath.xyz(q.position), moved = x - PhysicsMath.xyz(q.prevPosition), w = q.prevPosition.w
            let soft = q.info.y & PhysicsWorld.softBit != 0
            let cap = (soft ? PhysicsWorld.softPushSpeed : PhysicsWorld.pushSpeed) * h
            var shared = SIMD3<Float>(), sharedCount: Float = 0
            for n in 0..<Int(neighbourCounts[i]) {
                let o = before[Int(neighbours[i * k + n])]
                let d = x - PhysicsMath.xyz(o.position)
                let dist = length(d)
                let overlap = min(q.position.w + o.position.w - dist, cap)
                guard overlap > 0, dist > 1e-6 else { continue }
                let share = w / (w + o.prevPosition.w)
                let slide = moved - (PhysicsMath.xyz(o.position) - PhysicsMath.xyz(o.prevPosition))
                shared += PhysicsWorld.particlePush(d / dist, overlap, slide, sqrt(q.velocity.w * o.velocity.w)) * share
                sharedCount += 1
            }
            var held = SIMD3<Float>(), heldCount: Float = 0, shoved = false
            for n in 0..<Int(colliderCounts[i]) {
                let b = partner(colliders[i * kc + n])
                let pose = Pose(b), shape = Int(b.info.x)
                let local = pose.toBody(x)
                let depth = distance(shape: shape, local) - q.position.w
                guard depth < 0 else { continue }
                let normal = pose.direction(gradient(shape: shape, local))
                let surface = PhysicsMath.xyz(b.velocity) + cross(PhysicsMath.xyz(b.angular), x - pose.position)
                held += PhysicsWorld.particlePush(normal, min(-depth, cap), moved - surface * h,
                                                  sqrt(q.velocity.w * b.velocity.w))
                heldCount += 1
                shoved = shoved || PhysicsWorld.moves(b)
            }
            var out = q
            var y = x
            if sharedCount > 0 { y += soft ? shared : shared / sharedCount }
            if heldCount > 0 { y += soft ? held : held / heldCount }
            // At rest: a particle in a heap (no body shoving it, not a cloth's or a soft body's) that went slower than
            // the rest speed stays where it was (Macklin et al. 2014's sleeping); the averaged pushes otherwise keep a
            // heap fizzing.
            if PhysicsWorld.rests(q, touching: sharedCount + heldCount > 0, shoved: shoved, moved: y - PhysicsMath.xyz(q.prevPosition), p) {
                y = PhysicsMath.xyz(q.prevPosition)
            }
            out.position = SIMD4(y, q.position.w)
            out.velocity = SIMD4((y - PhysicsMath.xyz(q.prevPosition)) / h, q.velocity.w)
            particles[i] = out
        }
    }

    /// The cloths' and soft bodies' links, a colour at a time (Gauss-Seidel: each sees what the colours before it
    /// moved), each an XPBD distance constraint (one iteration a substep, so its lambda starts at 0); a soft body's
    /// with Macklin et al. 2016's damping of what moves along it.
    private func solveCloth(_ p: GPUPhysicsParams) {
        let h = p.gravity.w
        for c in 0..<(colourStarts.count - 1) {
            for k in Int(colourStarts[c])..<Int(colourStarts[c + 1]) {
                let con = constraints[k]
                let a = Int(con.a), b = Int(con.b)
                let wa = particles[a].prevPosition.w, wb = particles[b].prevPosition.w
                guard wa + wb > 0 else { continue }
                let d = PhysicsMath.xyz(particles[a].position) - PhysicsMath.xyz(particles[b].position)
                let l = length(d)
                guard l > 1e-9 else { continue }
                let n = d / l
                let gamma = particles[a].info.y & PhysicsWorld.softBit != 0 ? con.compliance * p.softDamping.y / h : 0
                let moved = dot(n, PhysicsMath.xyz(particles[a].position - particles[a].prevPosition)
                                   - PhysicsMath.xyz(particles[b].position - particles[b].prevPosition))
                let lambda = (-(l - con.rest) - gamma * moved) / ((1 + gamma) * (wa + wb) + con.compliance / (h * h))
                let push = n * lambda
                particles[a].position += SIMD4(push * wa, 0)
                particles[b].position -= SIMD4(push * wb, 0)
            }
        }
    }
}
