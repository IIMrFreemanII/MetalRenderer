import Foundation
import simd

/// The CPU's step: the reference the GPU's (Shaders/Physics.metal) is checked against, and the backend for scenes with
/// few bodies, where a GPU dispatch costs more than the work. Each stage is what a kernel does, over every body, in
/// the same order; a stage that reads other bodies reads them as they were when it began (Jacobi).
extension PhysicsWorld {
    func step() {
        let p = params
        broadPhase(p)
        wake(p)
        link()
        narrowPhase(p)
        particleBroadPhase(p)
        for _ in 0..<substeps {
            integrate(p)
            integrateParticles(p)
            solveCloth(p)
            solveParticles(p)   // against the bodies where this substep moved them, before they are pushed apart
            solvePositions(p)
            solveVelocities(p)
        }
        settle(p)
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
    /// meet its own, lowest first, `maxPairs` at most (a crowded body drops its farthest-numbered bodies, never what
    /// holds it up).
    private func broadPhase(_ p: GPUPhysicsParams) {
        let size = p.grid.x
        var grid: [SIMD3<Int32>: [Int]] = [:]
        for (i, b) in bodies.enumerated() { grid[PhysicsWorld.cell(PhysicsMath.xyz(b.position), size), default: []].append(i) }
        let k = PhysicsWorld.maxPairs
        for (i, b) in bodies.enumerated() {
            let x = PhysicsMath.xyz(b.position), r = PhysicsWorld.reach(b, p)
            let c = PhysicsWorld.cell(x, size)
            var found: [UInt32] = []
            for dz: Int32 in -1...1 {
                for dy: Int32 in -1...1 {
                    for dx: Int32 in -1...1 {
                        for j in grid[c &+ SIMD3(dx, dy, dz)] ?? [] where j != i {
                            let o = bodies[j]
                            let reach = r + PhysicsWorld.reach(o, p)
                            if length_squared(PhysicsMath.xyz(o.position) - x) < reach * reach { found.append(UInt32(j)) }
                        }
                    }
                }
            }
            for s in statics.indices where touchesStatic(s, centre: x, radius: r) { found.append(UInt32(s) | PhysicsWorld.staticBit) }
            found.sort { ($0 ^ PhysicsWorld.staticBit) < ($1 ^ PhysicsWorld.staticBit) }
            pairCounts[i] = UInt32(min(found.count, k))
            for (n, partner) in found.prefix(k).enumerated() { pairs[i * k + n] = GPUPhysicsPair(partner: partner) }
        }
    }

    /// A sleeping body that something moving touches wakes.
    private func wake(_ p: GPUPhysicsParams) {
        let k = PhysicsWorld.maxPairs
        let before = bodies
        for i in bodies.indices where before[i].info.y & PhysicsWorld.asleep != 0 {
            for n in 0..<Int(pairCounts[i]) {
                let partner = pairs[i * k + n].partner
                guard partner & PhysicsWorld.staticBit == 0 else { continue }
                let o = before[Int(partner)]
                if o.info.y & PhysicsWorld.asleep == 0 && o.position.w > 0 && o.prevPosition.w == 0 {
                    bodies[i].info.y &= ~PhysicsWorld.asleep
                    bodies[i].prevPosition.w = 0
                    break
                }
            }
        }
    }

    /// Each entry's owner: the lower body of two, or the body against a static. Another body's entry points at the
    /// owner's (none if the owner dropped it: then neither has the pair).
    private func link() {
        let k = PhysicsWorld.maxPairs
        for i in bodies.indices {
            for n in 0..<Int(pairCounts[i]) {
                let e = i * k + n, partner = pairs[e].partner
                if partner & PhysicsWorld.staticBit != 0 || Int(partner) > i {
                    pairs[e].link = UInt32(e)
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
    private func narrowPhase(_ p: GPUPhysicsParams) {
        let k = PhysicsWorld.maxPairs
        for i in bodies.indices {
            let a = bodies[i]
            for n in 0..<Int(pairCounts[i]) {
                let e = i * k + n
                guard pairs[e].link == UInt32(e) else { continue }
                let b = partner(pairs[e].partner)
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

    // MARK: Substeps

    @inline(__always) static func moves(_ b: GPUPhysicsBody) -> Bool { b.position.w > 0 && b.info.y & PhysicsWorld.asleep == 0 }

    /// Every moving body by its velocity and gravity.
    private func integrate(_ p: GPUPhysicsParams) {
        let h = p.gravity.w
        for i in bodies.indices where PhysicsWorld.moves(bodies[i]) {
            var b = bodies[i]
            b.prevPosition = SIMD4(PhysicsMath.xyz(b.position), b.prevPosition.w)
            b.prevRotation = b.rotation
            var v = PhysicsMath.xyz(b.velocity) + PhysicsMath.xyz(p.gravity) * h
            let speed = length(v)
            if speed > p.grid.z { v *= p.grid.z / speed }
            b.velocity = SIMD4(v, b.velocity.w)
            b.position = SIMD4(PhysicsMath.xyz(b.position) + v * h, b.position.w)
            b.rotation = PhysicsMath.qturn(b.rotation, PhysicsMath.xyz(b.angular) * h)
            bodies[i] = b
        }
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

    /// Each moving body gathers its contacts' pushes (Jacobi: from the poses all bodies had when the pass began), and
    /// moves by their mean. The owner keeps each contact's lambda and normal speed for the velocity pass.
    private func solvePositions(_ p: GPUPhysicsParams) {
        let k = PhysicsWorld.maxPairs, before = bodies
        for i in before.indices {
            let me = before[i]
            var dx = SIMD3<Float>(), dtheta = SIMD3<Float>(), count: Float = 0
            for n in 0..<Int(pairCounts[i]) {
                let e = i * k + n, link = pairs[e].link
                guard link != PhysicsWorld.none else { continue }
                let owner = link == UInt32(e)
                let other = owner ? partnerBefore(pairs[e].partner, before) : before[Int(link) / k]
                let (a, b) = owner ? (me, other) : (other, me)
                for c in 0..<Int(pairs[Int(link)].contacts) {
                    let ci = Int(link) * PhysicsWorld.maxContacts + c
                    let push = PhysicsWorld.contactPush(contacts[ci], a, b, h: p.gravity.w)
                    if owner { contacts[ci].lambda = SIMD4(push.lambda, push.speed, 0, 0) }
                    guard push.lambda > 0, PhysicsWorld.moves(me) else { continue }
                    if owner {
                        dx += push.impulse * me.position.w
                        dtheta += PhysicsMath.applyInvInertia(me.rotation, PhysicsMath.xyz(me.invInertia), cross(push.ra, push.impulse))
                    } else {
                        dx -= push.impulse * me.position.w
                        dtheta -= PhysicsMath.applyInvInertia(me.rotation, PhysicsMath.xyz(me.invInertia), cross(push.rb, push.impulse))
                    }
                    count += 1
                }
            }
            guard PhysicsWorld.moves(me) else { continue }
            var b = me
            if count > 0 {
                let s = 1 / count
                b.position = SIMD4(PhysicsMath.xyz(me.position) + dx * s, me.position.w)
                b.rotation = PhysicsMath.qturn(me.rotation, dtheta * s)
            }
            // The velocities from where the substep took it.
            let h = p.gravity.w
            b.velocity = SIMD4((PhysicsMath.xyz(b.position) - PhysicsMath.xyz(b.prevPosition)) / h, b.velocity.w)
            var dq = PhysicsMath.qmul(b.rotation, PhysicsMath.qconj(b.prevRotation))
            if dq.w < 0 { dq = -dq }
            b.angular = SIMD4(2 * PhysicsMath.xyz(dq) / h, b.angular.w)
            bodies[i] = b
        }
    }

    @inline(__always) private func partnerBefore(_ code: UInt32, _ before: [GPUPhysicsBody]) -> GPUPhysicsBody {
        code & PhysicsWorld.staticBit != 0 ? statics[Int(code & ~PhysicsWorld.staticBit)] : before[Int(code)]
    }

    /// A contact's velocity change: dynamic friction against the sliding, and restitution (none for slow impacts).
    @inline(__always) static func contactKick(_ c: GPUPhysicsContact, _ a: GPUPhysicsBody, _ b: GPUPhysicsBody, _ p: GPUPhysicsParams)
        -> (impulse: SIMD3<Float>, ra: SIMD3<Float>, rb: SIMD3<Float>)? {
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
        let l = length(dv)
        guard l > 1e-7 else { return nil }
        let w = weight(a, ra, dv / l) + weight(b, rb, dv / l)
        guard w > 0 else { return nil }
        return (dv / w, ra, rb)
    }

    /// Each moving body gathers its contacts' velocity changes (Jacobi again) and takes their mean.
    private func solveVelocities(_ p: GPUPhysicsParams) {
        let k = PhysicsWorld.maxPairs, before = bodies
        for i in before.indices where PhysicsWorld.moves(before[i]) {
            let me = before[i]
            var dv = SIMD3<Float>(), dw = SIMD3<Float>(), count: Float = 0
            for n in 0..<Int(pairCounts[i]) {
                let e = i * k + n, link = pairs[e].link
                guard link != PhysicsWorld.none else { continue }
                let owner = link == UInt32(e)
                let other = owner ? partnerBefore(pairs[e].partner, before) : before[Int(link) / k]
                let (a, b) = owner ? (me, other) : (other, me)
                for c in 0..<Int(pairs[Int(link)].contacts) {
                    guard let kick = PhysicsWorld.contactKick(contacts[Int(link) * PhysicsWorld.maxContacts + c], a, b, p) else { continue }
                    let s: Float = owner ? 1 : -1
                    dv += s * kick.impulse * me.position.w
                    dw += s * PhysicsMath.applyInvInertia(me.rotation, PhysicsMath.xyz(me.invInertia), cross(owner ? kick.ra : kick.rb, kick.impulse))
                    count += 1
                }
            }
            guard count > 0 else { continue }
            let s = 1 / count
            bodies[i].velocity = SIMD4(PhysicsMath.xyz(me.velocity) + dv * s, me.velocity.w)
            bodies[i].angular = SIMD4(PhysicsMath.xyz(me.angular) + dw * s, me.angular.w)
        }
    }

    /// After the substeps: a body that has been slow for long enough falls asleep.
    private func settle(_ p: GPUPhysicsParams) {
        for i in bodies.indices where PhysicsWorld.moves(bodies[i]) {
            var b = bodies[i]
            let still = length(PhysicsMath.xyz(b.velocity)) < p.sleep.x && length(PhysicsMath.xyz(b.angular)) < p.sleep.y
            b.prevPosition.w = still ? b.prevPosition.w + p.grid.w : 0
            if b.prevPosition.w > p.sleep.z {
                b.info.y |= PhysicsWorld.asleep
                b.velocity = SIMD4(.zero, b.velocity.w)
                b.angular = SIMD4(.zero, b.angular.w)
            }
            bodies[i] = b
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
                            if (q.info.y | o.info.y) & PhysicsWorld.clothBit != 0 { continue }   // cloths only meet colliders
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
            let drag: Float = q.info.y & PhysicsWorld.clothBit != 0 ? max(1 - p.particleGrid.z * h, 0) : 1
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

    /// Each particle's pushes (Jacobi): its neighbours' overlaps, shared by mass and averaged, and the colliders' in
    /// full (they don't give), averaged too; then its velocity from how far it went.
    private func solveParticles(_ p: GPUPhysicsParams) {
        let h = p.gravity.w, k = PhysicsWorld.maxNeighbours, kc = PhysicsWorld.maxColliders
        let before = particles
        for i in before.indices where before[i].prevPosition.w > 0 {
            let q = before[i]
            let x = PhysicsMath.xyz(q.position), moved = x - PhysicsMath.xyz(q.prevPosition), w = q.prevPosition.w
            var shared = SIMD3<Float>(), sharedCount: Float = 0
            for n in 0..<Int(neighbourCounts[i]) {
                let o = before[Int(neighbours[i * k + n])]
                let d = x - PhysicsMath.xyz(o.position)
                let dist = length(d)
                let overlap = min(q.position.w + o.position.w - dist, PhysicsWorld.pushSpeed * h)
                guard overlap > 0, dist > 1e-6 else { continue }
                let share = w / (w + o.prevPosition.w)
                let slide = moved - (PhysicsMath.xyz(o.position) - PhysicsMath.xyz(o.prevPosition))
                shared += PhysicsWorld.particlePush(d / dist, overlap, slide, sqrt(q.velocity.w * o.velocity.w)) * share
                sharedCount += 1
            }
            var held = SIMD3<Float>(), heldCount: Float = 0
            for n in 0..<Int(colliderCounts[i]) {
                let b = partner(colliders[i * kc + n])
                let pose = Pose(b), shape = Int(b.info.x)
                let local = pose.toBody(x)
                let depth = distance(shape: shape, local) - q.position.w
                guard depth < 0 else { continue }
                let normal = pose.direction(gradient(shape: shape, local))
                let surface = PhysicsMath.xyz(b.velocity) + cross(PhysicsMath.xyz(b.angular), x - pose.position)
                held += PhysicsWorld.particlePush(normal, min(-depth, PhysicsWorld.pushSpeed * h), moved - surface * h,
                                                  sqrt(q.velocity.w * b.velocity.w))
                heldCount += 1
            }
            var out = q
            var y = x
            if sharedCount > 0 { y += shared / sharedCount }
            if heldCount > 0 { y += held / heldCount }
            out.position = SIMD4(y, q.position.w)
            out.velocity = SIMD4((y - PhysicsMath.xyz(q.prevPosition)) / h, q.velocity.w)
            particles[i] = out
        }
    }

    /// The cloths' constraints, a colour at a time (Gauss-Seidel: each sees what the colours before it moved), each an
    /// XPBD distance constraint (one iteration a substep, so its lambda starts at 0).
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
                let lambda = -(l - con.rest) / (wa + wb + con.compliance / (h * h))
                let push = d / l * lambda
                particles[a].position += SIMD4(push * wa, 0)
                particles[b].position -= SIMD4(push * wb, 0)
            }
        }
    }
}
