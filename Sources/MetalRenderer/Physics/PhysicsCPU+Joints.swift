import Foundation
import simd
import CPhysicsAtomics

extension PhysicsWorld {
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

    /// With fractured objects (settle): whether rubble `b` has stayed near `anchor` (its pose when its still time
    /// began): moved less than the sleep speed x the sleep time, and turned its mass less than the sleep turn x the
    /// sleep time (as `still` measures a turn). Its speed over the time, not each step's: a heap's pieces creep at
    /// around a cm/s on the solver's last corrections (a cm and 2 degrees a second), and jolt faster for a step now
    /// and then, which restarted their timers.
    @inline(__always) static func near(_ b: GPUPhysicsBody, _ anchor: SIMD8<Float>, _ p: GPUPhysicsParams) -> Bool {
        let moved = length(PhysicsMath.xyz(b.position) - PhysicsMath.xyz(anchor.lowHalf))
        guard moved < p.sleep.x * p.sleep.z else { return false }
        let turn = PhysicsMath.xyz(PhysicsMath.qmul(b.rotation, PhysicsMath.qconj(anchor.highHalf)))
        let sine = length(turn)
        guard sine > 1e-9 else { return true }
        let w = turnWeight(b, turn / sine)
        return w <= 0 || 2 * sine * min(sqrt(b.position.w / w), gyration) < p.sleep.y * p.sleep.z
    }

    /// How fast body `b`'s mass went over a step from `start` (its pose then) in `h`: its move, and its turn x its
    /// radius of gyration about the turn (`gyration` at most).
    @inline(__always) static func motion(_ b: GPUPhysicsBody, _ start: SIMD8<Float>, _ h: Float) -> SIMD4<Float> {
        let moved = length(PhysicsMath.xyz(b.position) - PhysicsMath.xyz(start.lowHalf))
        let turn = PhysicsMath.xyz(PhysicsMath.qmul(b.rotation, PhysicsMath.qconj(start.highHalf)))
        let sine = length(turn)
        guard sine > 1e-9 else { return SIMD4(moved / h, 0, 0, 0) }
        let w = turnWeight(b, turn / sine)
        return SIMD4(moved / h, w > 0 ? 2 * sine * min(sqrt(b.position.w / w), gyration) / h : 0, 0, 0)
    }

    /// After the substeps: a body that has been slow for long enough falls asleep, once the bodies it touches (has
    /// contacts with) have been slow for half as long (or sleep): a pile goes to sleep together, not one body propped on moving ones.
    /// With fractured objects, rubble is slow while it stays near where its slow time began (`near`), and every
    /// moving body's motion over the step is kept for the next step's wake (`stepMotion`).
    func settle(_ p: GPUPhysicsParams, _ start: [SIMD8<Float>]) {
        let n = bodies.count, k = PhysicsWorld.maxPairs, heaps = fractures
        wakeFlags.removeAll(keepingCapacity: true)
        wakeFlags.append(contentsOf: repeatElement(0, count: n))
        if heaps && sleepAnchors.count != n { sleepAnchors = [SIMD8<Float>](repeating: SIMD8(), count: n) }
        if heaps && stepMotion.count != n { stepMotion = [SIMD4<Float>](repeating: .zero, count: n) }
        wakeFlags.withUnsafeMutableBufferPointer { sleeps in
            start.withUnsafeBufferPointer { start in
            initialBodies.withUnsafeBufferPointer { initial in
            sleepAnchors.withUnsafeMutableBufferPointer { anchors in
            stepMotion.withUnsafeMutableBufferPointer { motion in
                withStepBuffers { s in
                    // The timers...
                    PhysicsPool.shared.parallel(n, grain: 128) { range in
                        for i in range {
                            let b = s.bodies[i]
                            guard PhysicsWorld.moves(b) else {
                                if heaps { motion[i] = .zero }
                                continue
                            }
                            guard heaps else {
                                s.bodies[i].prevPosition.w = PhysicsWorld.still(b, start[i].lowHalf, start[i].highHalf, p) ? b.prevPosition.w + p.grid.w : 0
                                continue
                            }
                            motion[i] = PhysicsWorld.motion(b, start[i], p.grid.w)
                            let here = SIMD8(lowHalf: b.position, highHalf: b.rotation)
                            if !PhysicsWorld.rubble(b, initial[i]) {
                                s.bodies[i].prevPosition.w = PhysicsWorld.still(b, start[i].lowHalf, start[i].highHalf, p) ? b.prevPosition.w + p.grid.w : 0
                                anchors[i] = here
                            } else if b.prevPosition.w > 0 && PhysicsWorld.near(b, anchors[i], p) {
                                s.bodies[i].prevPosition.w = b.prevPosition.w + p.grid.w
                            } else {
                                // (It moves on: left in under half the sleep time, faster than twice the sleep speed. Not one
                                // just woken, which starts its time here, nor one creeping out after a while.)
                                if b.prevPosition.w > 0 && b.prevPosition.w <= p.sleep.z / 2 { motion[i].z = 1 }
                                if b.prevPosition.w > 0 { motion[i].w = 1 }   // (it left its place: what rests on it wakes)
                                s.bodies[i].prevPosition.w = p.grid.w
                                anchors[i] = here
                            }
                        }
                    }
                    // ...then who may sleep (reading the timers only)...
                    PhysicsPool.shared.parallel(n, grain: 64) { range in
                        for i in range where PhysicsWorld.moves(s.bodies[i]) && s.bodies[i].prevPosition.w > p.sleep.z {
                            var settled = true
                            for m in 0..<Int(s.pairCounts[i]) {
                                let e = i * k + m, partner = s.pairs[e].partner, link = s.pairs[e].link
                                guard partner & PhysicsWorld.staticBit == 0, link != PhysicsWorld.none, s.pairs[Int(link)].contacts > 0 else { continue }
                                let o = s.bodies[Int(partner)]
                                if PhysicsWorld.moves(o) && o.prevPosition.w <= p.sleep.z / 2 { settled = false; break }
                            }
                            sleeps[i] = settled ? 1 : 0
                        }
                    }
                }
            }
            }
            }
            }
            // A ragdoll sleeps whole: while any of its moving bodies can't, none does (one asleep would hold its joints).
            for r in ragdolls {
                let range = Int(r.x)..<Int(r.x + r.y)
                if range.contains(where: { PhysicsWorld.moves(bodies[$0]) && sleeps[$0] == 0 }) { for i in range { sleeps[i] = 0 } }
            }
            // ...and they sleep.
            withStepBuffers { s in
                PhysicsPool.shared.parallel(n, grain: 256) { range in
                    for i in range where sleeps[i] != 0 {
                        s.bodies[i].info.y |= PhysicsWorld.asleep
                        s.bodies[i].velocity = SIMD4(.zero, s.bodies[i].velocity.w)
                        s.bodies[i].angular = SIMD4(.zero, s.bodies[i].angular.w)
                    }
                }
            }
        }
    }
}
