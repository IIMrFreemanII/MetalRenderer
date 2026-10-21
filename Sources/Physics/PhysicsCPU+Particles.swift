import EngineCore
import Foundation
import simd
import CPhysicsAtomics

extension PhysicsWorld {
    // MARK: Particles

    /// A particle's reach this step: its radius, as far as it goes (at up to the particle speed), and the margin.
    @inline(__always) package static func particleReach(_ q: GPUPhysicsParticle, _ p: GPUPhysicsParams) -> Float {
        q.position.w + min(length(PhysicsMath.xyz(q.velocity)), p.particleGrid.y) * p.grid.w + p.grid.y
    }

    /// Every particle's neighbours (the nearest `maxNeighbours` within reach, the lower first of equals) and the
    /// colliders it may touch (statics, then bodies, the lowest `maxColliders`). The grid here; each particle's query on
    /// every core.
    package func particleBroadPhase(_ p: GPUPhysicsParams) {
        guard !particles.isEmpty else { return }
        let size = p.particleGrid.x, n = particles.count
        particles.withUnsafeBufferPointer { q in
            particleCells.build(q.count) { i in SIMD4(PhysicsWorld.cell(PhysicsMath.xyz(q[i].position), size), 0) }
        }
        let shapes = self.shapes, staticBounds = self.staticBounds
        particleCells.withView { grid in
            withParticleBuffers { s in
                PhysicsPool.shared.parallel(n, grain: 64) { range in
                    withUnsafeTemporaryAllocation(of: (Float, UInt32).self, capacity: PhysicsWorld.maxNeighbours) { kept in
                        for i in range { PhysicsWorld.particleNeighbours(i, s, grid, shapes, staticBounds, p, kept: kept) }
                    }
                }
            }
        }
    }

    /// Particle i's neighbours and colliders (particleBroadPhase): neighbours kept nearest first as they are found
    /// (the same as sorting them all: the order is total, none found twice); colliders found in the order they sort
    /// in (statics, then bodies, each by number), the first `maxColliders` kept.
    @inline(__always) package static func particleNeighbours(_ i: Int, _ s: ParticleBuffers, _ grid: PhysicsCellGrid.View, _ shapes: [GPUPhysicsShape],
                                                     _ staticBounds: [AABB], _ p: GPUPhysicsParams,
                                                     kept: UnsafeMutableBufferPointer<(Float, UInt32)>) {
        let k = PhysicsWorld.maxNeighbours, kc = PhysicsWorld.maxColliders
        let q = s.particles[i]
        let x = PhysicsMath.xyz(q.position), r = PhysicsWorld.particleReach(q, p)
        let c = PhysicsWorld.cell(x, p.particleGrid.x)
        var count = 0
        for dz: Int32 in -1...1 {
            for dy: Int32 in -1...1 {
                for dx: Int32 in -1...1 {
                    for m in grid.cell(SIMD4(c &+ SIMD3(dx, dy, dz), 0)) {
                        let j = grid.item(m)
                        guard j != i else { continue }
                        let o = s.particles[j]
                        if !PhysicsWorld.meets(q, o) { continue }   // cloths only meet colliders, a soft body not itself
                        let reach = r + PhysicsWorld.particleReach(o, p)
                        let d2 = length_squared(PhysicsMath.xyz(o.position) - x)
                        guard d2 < reach * reach else { continue }
                        let id = UInt32(j)
                        if count == k && !(d2 < kept[k - 1].0 || (d2 == kept[k - 1].0 && id < kept[k - 1].1)) { continue }
                        var at = min(count, k - 1)
                        while at > 0 && (d2 < kept[at - 1].0 || (d2 == kept[at - 1].0 && id < kept[at - 1].1)) {
                            kept[at] = kept[at - 1]
                            at -= 1
                        }
                        kept[at] = (d2, id)
                        count = min(count + 1, k)
                    }
                }
            }
        }
        s.neighbourCounts[i] = UInt32(count)
        for m in 0..<count { s.neighbours[i * k + m] = kept[m].1 }
        var touching = 0
        for st in s.statics.indices where touching < kc && PhysicsWorld.touchesStatic(s.statics[st], shapes, staticBounds[st], centre: x, radius: r) {
            s.colliders[i * kc + touching] = UInt32(st) | PhysicsWorld.staticBit
            touching += 1
        }
        // (A figure's flesh and skin don't meet its own bones: info.z = their first << 8 | how many.)
        let soft = q.info.y & PhysicsWorld.softBit != 0
        let own = soft ? Int(q.info.z >> 8)..<Int((q.info.z >> 8) + (q.info.z & 0xFF)) : 0..<0
        for j in s.bodies.indices where touching < kc {
            let b = s.bodies[j]
            guard !own.contains(j) && !PhysicsWorld.disabled(b) else { continue }
            let reach = r + PhysicsWorld.reach(b, p)
            if length_squared(PhysicsMath.xyz(b.position) - x) < reach * reach {
                s.colliders[i * kc + touching] = UInt32(j)
                touching += 1
            }
        }
        s.colliderCounts[i] = UInt32(touching)
    }

    package func integrateParticles(_ p: GPUPhysicsParams) {
        guard !particles.isEmpty else { return }
        let h = p.gravity.w, n = particles.count
        withParticleBuffers { s in
            PhysicsPool.shared.parallel(n, grain: 256) { range in
                for i in range where s.particles[i].prevPosition.w > 0 {   // (a pinned cloth vertex stays)
                    var q = s.particles[i]
                    q.prevPosition = SIMD4(PhysicsMath.xyz(q.position), q.prevPosition.w)
                    let rate = q.info.y & PhysicsWorld.clothBit != 0 ? p.particleGrid.z : q.info.y & PhysicsWorld.softBit != 0 ? p.softDamping.x : 0
                    let drag = max(1 - rate * h, 0)
                    var v = PhysicsMath.xyz(q.velocity) * drag + PhysicsMath.xyz(p.gravity) * h
                    let speed = length(v)
                    if speed > p.grid.z { v *= p.grid.z / speed }
                    q.velocity = SIMD4(v, q.velocity.w)
                    q.position = SIMD4(PhysicsMath.xyz(q.position) + v * h, q.position.w)
                    s.particles[i] = q
                }
            }
        }
    }

    /// A push of `overlap` along `n` less the sliding friction holds back: all of `slide`'s tangential part while it
    /// is under friction x the overlap (static), otherwise that much of it (dynamic).
    @inline(__always) package static func particlePush(_ n: SIMD3<Float>, _ overlap: Float, _ slide: SIMD3<Float>, _ friction: Float) -> SIMD3<Float> {
        var push = n * overlap
        let tangent = slide - n * dot(slide, n)
        let l = length(tangent)
        if l > 1e-7 { push -= tangent * min(friction * overlap / l, 1) }
        return push
    }

    /// Whether a particle that went `moved` this substep stays put (PhysicsCPU.solveParticles).
    @inline(__always) package static func rests(_ q: GPUPhysicsParticle, touching: Bool, shoved: Bool, moved: SIMD3<Float>,
                                        _ p: GPUPhysicsParams) -> Bool {
        touching && !shoved && q.info.y & (clothBit | softBit) == 0 && length(moved) < p.particleGrid.w * p.gravity.w
    }

    /// Each particle's pushes (Jacobi): its neighbours' overlaps, shared by mass and averaged, and the colliders' in
    /// full (they don't give), averaged too; then its velocity from how far it went. A soft body's particle takes both
    /// summed, and faster (`softPushSpeed`): its links hold it among its own, and averaged pushes let a body shove it
    /// in, or a jelly on top sink into it.
    package func solveParticles(_ p: GPUPhysicsParams) {
        guard !particles.isEmpty else { return }
        let n = particles.count, shapes = shapeData
        withParticleBuffers { s in
            s.before.baseAddress!.update(from: s.particles.baseAddress!, count: n)   // (Jacobi: every particle against these)
            PhysicsPool.shared.parallel(n, grain: 64) { range in
                for i in range where s.before[i].prevPosition.w > 0 { PhysicsWorld.solveParticle(i, s, shapes, p) }
            }
        }
    }

    /// Particle i's pushes (solveParticles), against the particles as the pass found them.
    @inline(__always) package static func solveParticle(_ i: Int, _ s: ParticleBuffers, _ shapes: PhysicsShapes, _ p: GPUPhysicsParams) {
        let h = p.gravity.w, k = PhysicsWorld.maxNeighbours, kc = PhysicsWorld.maxColliders
        let q = s.before[i]
        let x = PhysicsMath.xyz(q.position), moved = x - PhysicsMath.xyz(q.prevPosition), w = q.prevPosition.w
        let soft = q.info.y & PhysicsWorld.softBit != 0
        let cap = (soft ? PhysicsWorld.softPushSpeed : PhysicsWorld.pushSpeed) * h
        var shared = SIMD3<Float>(), sharedCount: Float = 0
        for n in 0..<Int(s.neighbourCounts[i]) {
            let o = s.before[Int(s.neighbours[i * k + n])]
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
        for n in 0..<Int(s.colliderCounts[i]) {
            let b = s.partner(s.colliders[i * kc + n])
            let pose = Pose(b), shape = Int(b.info.x)
            let local = pose.toBody(x)
            let depth = shapes.distance(shape: shape, local) - q.position.w
            guard depth < 0 else { continue }
            let normal = pose.direction(shapes.gradient(shape: shape, local))
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
        s.particles[i] = out
    }

    /// The cloths' and soft bodies' links, a colour at a time (Gauss-Seidel: each sees what the colours before it
    /// moved), each an XPBD distance constraint (one iteration a substep, so its lambda starts at 0); a soft body's
    /// with Macklin et al. 2016's damping of what moves along it.
    package func solveCloth(_ p: GPUPhysicsParams) {
        guard colourStarts.count > 1 else { return }
        let h = p.gravity.w, starts = colourStarts, constraints = self.constraints
        constraints.withUnsafeBufferPointer { constraints in
            withParticleBuffers { s in
                for c in 0..<(starts.count - 1) {
                    let lo = Int(starts[c]), hi = Int(starts[c + 1])
                    PhysicsPool.shared.parallel(hi - lo, grain: 256) { range in   // (a colour's links share no particle)
                        for t in range { PhysicsWorld.solveLink(constraints[lo + t], s.particles, h, p) }
                    }
                }
            }
        }
    }

    /// One link (solveCloth).
    @inline(__always) package static func solveLink(_ con: GPUPhysicsConstraint, _ particles: UnsafeMutableBufferPointer<GPUPhysicsParticle>,
                                            _ h: Float, _ p: GPUPhysicsParams) {
        let a = Int(con.a), b = Int(con.b)
        let wa = particles[a].prevPosition.w, wb = particles[b].prevPosition.w
        guard wa + wb > 0 else { return }
        let d = PhysicsMath.xyz(particles[a].position) - PhysicsMath.xyz(particles[b].position)
        let l = length(d)
        guard l > 1e-9 else { return }
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
