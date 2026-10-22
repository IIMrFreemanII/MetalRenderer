import EngineCore
import Foundation
import simd
import CPhysicsAtomics

extension PhysicsWorld {
    // MARK: Substeps

    @inline(__always) package static func moves(_ b: GPUPhysicsBody) -> Bool {
        b.position.w > 0 && b.info.y & (PhysicsWorld.asleep | PhysicsWorld.disabledBit) == 0
    }
    @inline(__always) package static func disabled(_ b: GPUPhysicsBody) -> Bool { b.info.y & PhysicsWorld.disabledBit != 0 }
    /// An anchored piece the ground still holds (it moves only once it comes free).
    @inline(__always) package static func held(_ b: GPUPhysicsBody) -> Bool { b.info.y & PhysicsWorld.anchoredBit != 0 && b.position.w == 0 }

    /// Every moving body by its velocity and gravity; the held one (`grab`) woken, slowed and pulled to the target;
    /// a kinematic body to where its table puts it at the end of substep `sub` (PhysicsFlesh.swift).
    package func integrate(_ p: GPUPhysicsParams, sub: Int) {
        let h = p.gravity.w, grab = self.grab, step = stepIndex, rows = kinematicRows
        movingBodies.withUnsafeBufferPointer { moving in
        withStepBuffers { s in
            PhysicsPool.shared.parallel(moving.count, grain: 128) { range in
                for t in range {
                    let i = Int(moving[t])
                    if PhysicsWorld.kinematic(s.bodies[i]) {
                        guard rows > 0 else { continue }
                        PhysicsWorld.moveKinematic(&s.bodies[i], to: kinematicPose(s.bodies[i], step: step, alpha: Float(sub + 1) / p.softDamping.z), h: h)
                        continue
                    }
                    let held = grab.target.w > 0 && grab.body == UInt32(i)
                    if held {
                        s.bodies[i].info.y &= ~PhysicsWorld.asleep
                        s.bodies[i].prevPosition.w = 0
                    }
                    guard PhysicsWorld.moves(s.bodies[i]) else { continue }
                    var b = s.bodies[i]
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
                    s.bodies[i] = b
                }
            }
        }
        }
    }

    /// The bodies a substep may move, in order (`movingBodies`): the kinematic ones, those that move, the held one.
    /// Made after the liquids, which wake what they push; nothing else between them wakes or stops a body but the
    /// held one's waking, so the substeps' loops over the bodies take these and pass over no body they would move.
    package func listMoving() {
        let held = grab.target.w > 0 ? Int(grab.body) : -1
        movingBodies.removeAll(keepingCapacity: true)
        for (i, b) in bodies.enumerated() where PhysicsWorld.kinematic(b) || PhysicsWorld.moves(b) || i == held {
            movingBodies.append(Int32(i))
        }
    }

    /// The held body's anchor a fraction (`holdPull`) of the way to the target, shared between moving and turning
    /// it by its inverse mass and inertia there (as a contact's push is): a body held off its centre swings and hangs.
    @inline(__always) package static func hold(_ b: inout GPUPhysicsBody, _ g: GPUPhysicsGrab) {
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
    @inline(__always) package static func points(_ c: GPUPhysicsContact, _ a: GPUPhysicsBody, _ b: GPUPhysicsBody, previous: Bool = false)
        -> (pa: SIMD3<Float>, pb: SIMD3<Float>, ra: SIMD3<Float>, rb: SIMD3<Float>) {
        let n = PhysicsMath.xyz(c.normal)
        // (A kinematic body went somewhere too: a ball on a moving arm slides on it only as far as the arm left it.)
        let am = previous && (moves(a) || kinematic(a)), bm = previous && (moves(b) || kinematic(b))
        let xa = PhysicsMath.xyz(am ? a.prevPosition : a.position)
        let xb = PhysicsMath.xyz(bm ? b.prevPosition : b.position)
        let ra = PhysicsMath.qrot(am ? a.prevRotation : a.rotation, PhysicsMath.xyz(c.anchorA)) - n * c.anchorA.w
        let rb = PhysicsMath.qrot(bm ? b.prevRotation : b.rotation, PhysicsMath.xyz(c.anchorB)) + n * c.anchorB.w
        return (xa + ra, xb + rb, ra, rb)
    }

    /// The generalised inverse mass of body `b` at lever arm `r` along `n` (0 for one that doesn't move).
    @inline(__always) package static func weight(_ b: GPUPhysicsBody, _ r: SIMD3<Float>, _ n: SIMD3<Float>) -> Float {
        guard moves(b) else { return 0 }
        let rn = cross(r, n)
        return b.position.w + dot(rn, PhysicsMath.applyInvInertia(b.rotation, PhysicsMath.xyz(b.invInertia), rn))
    }

    /// A contact's position correction: its normal push (lambda) and, if static friction holds it, its tangential one
    /// (the impulse on A; B takes the opposite), and the normal speed before it. The same numbers for both bodies.
    @inline(__always) package static func contactPush(_ c: GPUPhysicsContact, _ a: GPUPhysicsBody, _ b: GPUPhysicsBody, h: Float)
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
    @inline(__always) package static func shove(_ b: inout GPUPhysicsBody, _ impulse: SIMD3<Float>, _ r: SIMD3<Float>) {
        guard moves(b) else { return }
        b.position = SIMD4(PhysicsMath.xyz(b.position) + impulse * b.position.w, b.position.w)
        b.rotation = PhysicsMath.qturn(b.rotation, PhysicsMath.applyInvInertia(b.rotation, PhysicsMath.xyz(b.invInertia), cross(r, impulse)))
    }

    /// Speeds body `b` (if it moves) up by `impulse` at lever arm `r` and angular impulse `twist`.
    @inline(__always) package static func kick(_ b: inout GPUPhysicsBody, _ impulse: SIMD3<Float>, _ r: SIMD3<Float>, _ twist: SIMD3<Float>) {
        guard moves(b) else { return }
        b.velocity = SIMD4(PhysicsMath.xyz(b.velocity) + impulse * b.position.w, b.velocity.w)
        b.angular = SIMD4(PhysicsMath.xyz(b.angular)
                          + PhysicsMath.applyInvInertia(b.rotation, PhysicsMath.xyz(b.invInertia), cross(r, impulse) + twist), b.angular.w)
    }

    /// Two bodies neither of which moves (asleep, held, kinematic, static): their contacts push and kick nothing
    /// (each one's weight is 0: a push of 0, which no kick follows), so their pair is passed over. (Not a weld: it
    /// counts its load.)
    @inline(__always) package static func still(_ a: GPUPhysicsBody, _ b: GPUPhysicsBody) -> Bool { !moves(a) && !moves(b) }

    /// Pair `e`'s contacts' pushes, one after the other, each on both bodies at once.
    @inline(__always) package static func pushPair(_ e: Int, _ s: StepBuffers, h: Float) {
        let i = e / PhysicsWorld.maxPairs, code = s.pairs[e].partner, dynamic = code & PhysicsWorld.staticBit == 0
        var a = s.bodies[i], b = s.partner(code)
        if PhysicsWorld.still(a, b) { return }
        for c in 0..<Int(s.pairs[e].contacts) {
            let ci = e * PhysicsWorld.maxContacts + c
            let push = PhysicsWorld.contactPush(s.contacts[ci], a, b, h: h)
            s.contacts[ci].lambda = SIMD4(push.lambda, push.speed, 0, 0)
            guard push.lambda > 0 else { continue }
            PhysicsWorld.shove(&a, push.impulse, push.ra)
            PhysicsWorld.shove(&b, -push.impulse, push.rb)
        }
        s.bodies[i] = a
        if dynamic { s.bodies[Int(code)] = b }
    }

    /// Pair `e`'s contacts' kicks.
    @inline(__always) package static func kickPair(_ e: Int, _ s: StepBuffers, _ p: GPUPhysicsParams) {
        let i = e / PhysicsWorld.maxPairs, code = s.pairs[e].partner, dynamic = code & PhysicsWorld.staticBit == 0
        var a = s.bodies[i], b = s.partner(code)
        if PhysicsWorld.still(a, b) { return }
        for c in 0..<Int(s.pairs[e].contacts) {
            guard let kick = PhysicsWorld.contactKick(s.contacts[e * PhysicsWorld.maxContacts + c], a, b, p) else { continue }
            PhysicsWorld.kick(&a, kick.impulse, kick.ra, kick.twist)
            PhysicsWorld.kick(&b, -kick.impulse, kick.rb, -kick.twist)
        }
        s.bodies[i] = a
        if dynamic { s.bodies[Int(code)] = b }
    }

    /// Pairs a chunk of `pairSchedule` (eachColour): a pair's solve takes from tens of ns (a weld) to a µs (four
    /// contacts). (8 and 32 were about as fast, 4 and 64 slower; 1 several times slower.)
    package static let colourGrain = 16
    /// The chunks' done flags a cache line apart (Int32s): a flag a chunk's thread writes, the others read.
    package static let flagStride = 32

    /// The pairs in `pairOrder` (the colours, then the rest), on every core, each body's pairs in that order, so each
    /// pair sees its bodies as the colours one at a time would give them, bit for bit. Not a colour at a time: each
    /// chunk of `pairSchedule` (the pairs by depth, colourPairs) waits only for the chunks with the pairs before its
    /// pairs' on their bodies (`pairWaits`), and says it is done once its pairs are, so the threads move on through
    /// the depths without a stop for each colour (a pass is about 50 of them, most a few pairs). The chunks are
    /// handed out in order, one at a time, and a chunk waits only on chunks before it: the first one not done has
    /// none to wait on, so it always moves. (Three buildings settling, at 11 s: the two passes 9.2 → 7.7 ms a step;
    /// on the efficiency cores too, slower than a colour at a time: their chunks held the rest up.)
    private func eachColour(_ s: StepBuffers, _ solve: (Int) -> Void) {
        let total = pairOrder.count
        guard total > 0 else { return }
        pairPass &+= 1
        let pass = pairPass, grain = PhysicsWorld.colourGrain, stride = PhysicsWorld.flagStride
        pairSchedule.withUnsafeBufferPointer { schedule in
            pairWaits.withUnsafeBufferPointer { waits in
                pairDone.withUnsafeMutableBufferPointer { done in
                    let flags = done.baseAddress!
                    PhysicsPool.shared.parallel(total, grain: grain, single: true) { range in
                        for u in range {
                            let wait = waits[u]
                            if wait.x >= 0 { while cpa_load32(flags + Int(wait.x) * stride) != pass { cpa_pause() } }
                            if wait.y >= 0 { while cpa_load32(flags + Int(wait.y) * stride) != pass { cpa_pause() } }
                            solve(Int(schedule[u]))
                        }
                        cpa_store32(flags + range.lowerBound / grain * stride, pass)
                    }
                }
            }
        }
    }

    /// Joint colour by colour (a colour's joints share no body), each joint's two bodies through `solve`.
    private func eachJointColour(_ s: StepBuffers, _ solve: (GPUPhysicsJoint, inout GPUPhysicsBody, inout GPUPhysicsBody) -> Void) {
        let starts = jointStarts
        joints.withUnsafeBufferPointer { joints in
            for c in 0..<(starts.count - 1) {
                let lo = Int(starts[c]), hi = Int(starts[c + 1])
                PhysicsPool.shared.parallel(hi - lo, grain: 32) { range in
                    for t in range {
                        let j = joints[lo + t], ia = Int(j.info.x), ib = Int(j.info.y)
                        var a = s.bodies[ia], b = s.bodies[ib]
                        solve(j, &a, &b)
                        s.bodies[ia] = a
                        s.bodies[ib] = b
                    }
                }
            }
        }
    }

    /// The joints, then the contacts' pushes, a colour at a time, then every moving body's velocities from how far it went.
    package func solvePositions(_ p: GPUPhysicsParams) {
        let h = p.gravity.w, fractured = fractures, substeps = Float(self.substeps)
        withStepBuffers { s in
            // The joints first, a colour at a time (twice: PhysicsWorld.jointIterations), then the contacts: static
            // friction undoes what the substep slid a contact, the joints' pushes included. (Joints after the contacts
            // slid a resting ragdoll's chest a little every substep, out of friction's reach: it crept and never slept.)
            for _ in 0..<PhysicsWorld.jointIterations {
                eachJointColour(s) { j, a, b in PhysicsWorld.solveJoint(j, &a, &b) }
            }
            if fractured {
                eachColour(s) { e in PhysicsWorld.pushFracturePair(e, s, h: h, substeps: substeps) }
            } else {
                eachColour(s) { e in PhysicsWorld.pushPair(e, s, h: h) }
            }
            movingBodies.withUnsafeBufferPointer { moving in
            PhysicsPool.shared.parallel(moving.count, grain: 128) { range in
                for t in range {
                    let i = Int(moving[t])
                    guard PhysicsWorld.moves(s.bodies[i]) else { continue }
                    var b = s.bodies[i]
                    b.velocity = SIMD4((PhysicsMath.xyz(b.position) - PhysicsMath.xyz(b.prevPosition)) / h, b.velocity.w)
                    var dq = PhysicsMath.qmul(b.rotation, PhysicsMath.qconj(b.prevRotation))
                    if dq.w < 0 { dq = -dq }
                    b.angular = SIMD4(2 * PhysicsMath.xyz(dq) / h, b.angular.w)
                    s.bodies[i] = b
                }
            }
            }
        }
    }

    /// The generalised inverse inertia of body `b` about axis `k` (0 for one that doesn't move).
    @inline(__always) package static func turnWeight(_ b: GPUPhysicsBody, _ k: SIMD3<Float>) -> Float {
        moves(b) ? dot(k, PhysicsMath.applyInvInertia(b.rotation, PhysicsMath.xyz(b.invInertia), k)) : 0
    }

    /// A contact's velocity change: dynamic friction against the sliding, and restitution (none for slow impacts);
    /// and its angular impulse (on A; B takes the opposite) against rolling and spinning on the spot, each held back by
    /// at most its resistance (a length) x the normal impulse.
    @inline(__always) package static func contactKick(_ c: GPUPhysicsContact, _ a: GPUPhysicsBody, _ b: GPUPhysicsBody, _ p: GPUPhysicsParams)
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
        for k in 0..<2 {
            let part = k == 0 ? spin - about : about, resistance = k == 0 ? p.rolling.x : p.rolling.y
            let speed = length(part)
            guard speed > 1e-6 else { continue }
            let axis = part / speed
            let w = turnWeight(a, axis) + turnWeight(b, axis)
            guard w > 0 else { continue }
            twist -= axis * min(speed / w, resistance * lambda / h)
        }
        guard impulse != .zero || twist != .zero else { return nil }
        return (impulse, twist, ra, rb)
    }

    /// The contacts' velocity changes, a colour of pairs at a time.
    package func solveVelocities(_ p: GPUPhysicsParams) {
        let fractured = fractures
        withStepBuffers { s in
            if fractured {
                eachColour(s) { e in PhysicsWorld.kickFracturePair(e, s, p) }
            } else {
                eachColour(s) { e in PhysicsWorld.kickPair(e, s, p) }
            }
            eachJointColour(s) { j, a, b in PhysicsWorld.dampJoint(j, &a, &b, h: p.gravity.w) }
        }
    }
}
