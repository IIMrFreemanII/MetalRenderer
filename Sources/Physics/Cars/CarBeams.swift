import EngineCore
import Foundation
import simd

/// A car's substep after the bodies moved (Physics+Cars.swift's `solveCars`): its axles, its beams, its nodes against
/// what they meet. Over buffers, nothing allocated (Tools/perf/hot-functions.txt).
///
/// A beam is an XPBD distance constraint with damping (Macklin et al. 2016, as a soft body's links). Its load is the
/// force its stretch stands for, `(length - rest) / compliance` (never lambda / h^2, which one substep's jolt makes
/// huge: the destruction's welds learned that), averaged over a few substeps; past its yield its rest length flows
/// toward where it is, the excess load's worth, and its yield hardens: the dent stays. The load summed over the step
/// breaks it past its strength (`breakBeams`).
extension PhysicsWorld {
    /// The most a beam's rest length flows in a substep (m): what a crumple zone's row of beams can give at the speed
    /// of a crash (8 mm at 960 substeps a second is 7.7 m/s a beam).
    package static let carFlow: Float = 0.008
    /// How much of the gap since the last substeps a beam's averaged load takes each substep.
    package static let carLoadAverage: Float = 0.25
    /// Passes over a car's beams a substep (XPBD's iterations, its lambda summed over them): one leaves the body about
    /// 6 mm low on its springs, two 3 mm, at twice the cost.
    package static let carIterations = 1

    /// Car `c`'s substep: axles, beams (in their order: an order alternating each substep made a two-substep rhythm
    /// that grew until the nodes flew apart), the nodes against the statics and the bodies, the hull's beams' middles
    /// against the statics, and the nodes' velocities.
    @inline(__always) package static func solveCar(_ c: Int, _ b: CarBuffers, _ p: GPUPhysicsParams) {
        let s = b.cars[c], h = p.gravity.w
        b.pushCounts[c] = 0
        for _ in 0..<axlePasses {
            for w in Int(s.firstWheel)..<Int(s.firstWheel + s.wheelCount) { solveAxle(b.wheels[w], b, h) }
        }
        let first = Int(s.firstBeam), count = Int(s.beamCount)
        for k in first..<(first + count) { b.lambdas[k] = 0 }
        for pass in 0..<carIterations { for k in first..<(first + count) { solveBeam(k, b, h, first: pass == 0) } }
        let candidates = Int(s.firstCandidate)..<Int(s.firstCandidate + s.candidateCount)
        for i in Int(s.firstNode)..<Int(s.firstNode + s.nodeCount) { nodeContacts(i, c, b, candidates, h) }
        for k in first..<(first + count) where b.beams[k].info & (CarBeam.hullBit | CarBeam.brokenBit) == CarBeam.hullBit {
            beamMiddle(b.beams[k], b, candidates, h)
        }
        let top = carTopSpeed
        for i in Int(s.firstNode)..<Int(s.firstNode + s.nodeCount) {
            var q = b.particles[i]
            var v = (PhysicsMath.xyz(q.position) - PhysicsMath.xyz(q.prevPosition)) / h
            let speed = length(v)
            if speed > top { v *= top / speed }
            q.velocity = SIMD4(v, q.velocity.w)
            b.particles[i] = q
        }
    }

    /// Wheel `w`'s axle: its two hub points (its axle's ends, `hubOffset` out from its centre) held to its hub nodes.
    @inline(__always) package static func solveAxle(_ w: CarWheel, _ b: CarBuffers, _ h: Float) {
        let i = Int(w.body)
        var body = b.bodies[i]
        let soft = axleCompliance / (h * h)
        for end in 0..<2 {
            let node = Int(end == 0 ? w.hubIn : w.hubOut)
            let r = PhysicsMath.qrot(body.rotation, w.axle * (end == 0 ? -w.hubOffset : w.hubOffset))
            let x = PhysicsMath.xyz(b.particles[node].position)
            let d = PhysicsMath.xyz(body.position) + r - x
            let l = length(d)
            guard l > 1e-9 else { continue }
            let n = d / l, wn = b.particles[node].prevPosition.w, wb = weight(body, r, n)
            guard wn + wb > 0 else { continue }
            let lambda = l / (wn + wb + soft)
            b.particles[node].position = SIMD4(x + n * (lambda * wn), b.particles[node].position.w)
            shove(&body, -n * lambda, r)
        }
        b.bodies[i] = body
    }

    /// Beam `k`: its length back toward its rest (pushes only, or pulls only, for a stop or a strap), its load, and its
    /// flow past its yield.
    @inline(__always) package static func solveBeam(_ k: Int, _ b: CarBuffers, _ h: Float, first: Bool) {
        var beam = b.beams[k]
        guard beam.info & CarBeam.brokenBit == 0 else { return }
        let ia = Int(beam.nodes.x), ib = Int(beam.nodes.y)
        let qa = b.particles[ia], qb = b.particles[ib]
        let wa = qa.prevPosition.w, wb = qb.prevPosition.w
        guard wa + wb > 0 else { return }
        let xa = PhysicsMath.xyz(qa.position), xb = PhysicsMath.xyz(qb.position)
        let d = xa - xb, l = length(d)
        guard l > 1e-9 else { return }
        let kind = beam.kind
        if kind == CarBeamKind.compression.rawValue && l >= beam.rest { return }
        if kind == CarBeamKind.tension.rawValue && l <= beam.rest { return }
        let n = d / l, stretch = l - beam.rest
        let alpha = beam.compliance, soft = alpha / (h * h), gamma = alpha * beam.damping / h
        let moved = dot(n, (xa - PhysicsMath.xyz(qa.prevPosition)) - (xb - PhysicsMath.xyz(qb.prevPosition)))
        let lambda = (-stretch - soft * b.lambdas[k] - gamma * moved) / ((1 + gamma) * (wa + wb) + soft)
        b.lambdas[k] += lambda
        b.particles[ia].position = SIMD4(xa + n * (lambda * wa), qa.position.w)
        b.particles[ib].position = SIMD4(xb - n * (lambda * wb), qb.position.w)
        guard kind == CarBeamKind.plastic.rawValue && first else { return }
        let force = stretch / alpha
        b.loads[k] += force
        beam.load += carLoadAverage * (force - beam.load)
        let over = abs(beam.load) - beam.yield
        if over > 0 {
            let flow = min(over * alpha, carFlow)
            beam.rest += beam.load > 0 ? flow : -flow
            let limit = b.limits[k]
            beam.yield *= 1 + limit.hardening * flow / limit.rest0
        }
        b.beams[k] = beam
    }

    /// Node `i` of car `c` pushed out of the statics and bodies among `candidates` (by no more than it went in this
    /// substep and `pushSpeed`), held by friction as a particle is; a body's share of a push kept for it (its push and
    /// turn, `applyCarReactions`).
    @inline(__always) package static func nodeContacts(_ i: Int, _ c: Int, _ b: CarBuffers, _ candidates: Range<Int>, _ h: Float) {
        var q = b.particles[i]
        let wn = q.prevPosition.w
        guard wn > 0 else { return }
        let r = q.position.w, prev = PhysicsMath.xyz(q.prevPosition)
        var x = PhysicsMath.xyz(q.position)
        for k in candidates {
            let code = b.candidates[k]
            if code & staticBit != 0 {
                let st = Int(code & ~staticBit), box = b.staticBounds[st]
                if any(x .< box.lo - r) || any(x .> box.hi + r) { continue }
                let o = b.statics[st], pose = Pose(o), local = pose.toBody(x)
                let depth = b.shapes.distance(shape: Int(o.info.x), local) - r
                guard depth < 0 else { continue }
                let n = pose.direction(b.shapes.gradient(shape: Int(o.info.x), local))
                let moved = x - prev
                let overlap = min(-depth, max(-dot(moved, n), 0) + pushSpeed * h)
                x += particlePush(n, overlap, moved, (q.velocity.w * o.velocity.w).squareRoot())
            } else {
                let j = Int(code), o = b.bodies[j], centre = PhysicsMath.xyz(o.position)
                let reach = r + o.invInertia.w
                if length_squared(x - centre) > reach * reach { continue }
                let pose = Pose(o), local = pose.toBody(x)
                let depth = b.shapes.distance(shape: Int(o.info.x), local) - r
                guard depth < 0 else { continue }
                let n = pose.direction(b.shapes.gradient(shape: Int(o.info.x), local))
                let lever = x - centre
                let surface = PhysicsMath.xyz(o.velocity) + cross(PhysicsMath.xyz(o.angular), lever)
                let slide = (x - prev) - surface * h
                let overlap = min(-depth, max(-dot(slide, n), 0) + pushSpeed * h)
                let push = particlePush(n, overlap, slide, (q.velocity.w * o.velocity.w).squareRoot())
                let l = length(push)
                guard l > 1e-9 else { continue }
                let wb = weight(o, lever, push / l)
                x += push * (wn / (wn + wb))
                let count = Int(b.pushCounts[c])
                if wb > 0 && count < CarSystem.maxPushes {
                    b.pushes[c * CarSystem.maxPushes + count] = CarPush(body: Int32(j), impulse: -push / (wn + wb), lever: lever)
                    b.pushCounts[c] = Int32(count + 1)
                }
            }
        }
        q.position = SIMD4(x, q.position.w)
        b.particles[i] = q
    }

    /// A hull beam's middle against the statics: a pole between its two nodes pushes both out.
    @inline(__always) package static func beamMiddle(_ beam: CarBeam, _ b: CarBuffers, _ candidates: Range<Int>, _ h: Float) {
        let ia = Int(beam.nodes.x), ib = Int(beam.nodes.y)
        let qa = b.particles[ia], qb = b.particles[ib]
        guard qa.prevPosition.w > 0 || qb.prevPosition.w > 0 else { return }
        let r = qa.position.w
        var x = (PhysicsMath.xyz(qa.position) + PhysicsMath.xyz(qb.position)) / 2
        let start = x
        let moved = x - (PhysicsMath.xyz(qa.prevPosition) + PhysicsMath.xyz(qb.prevPosition)) / 2
        for k in candidates {
            let code = b.candidates[k]
            guard code & staticBit != 0 else { continue }
            let st = Int(code & ~staticBit), box = b.staticBounds[st]
            if any(x .< box.lo - r) || any(x .> box.hi + r) { continue }
            let o = b.statics[st], pose = Pose(o), local = pose.toBody(x)
            let depth = b.shapes.distance(shape: Int(o.info.x), local) - r
            guard depth < 0 else { continue }
            let n = pose.direction(b.shapes.gradient(shape: Int(o.info.x), local))
            let overlap = min(-depth, max(-dot(moved, n), 0) + pushSpeed * h)
            x += particlePush(n, overlap, moved, (qa.velocity.w * o.velocity.w).squareRoot())
        }
        let push = x - start
        guard push != .zero else { return }
        if qa.prevPosition.w > 0 { b.particles[ia].position += SIMD4(push, 0) }
        if qb.prevPosition.w > 0 { b.particles[ib].position += SIMD4(push, 0) }
    }

    /// Car `c`'s step end: each beam's load over the step (its sum over the substeps), and the beams it broke.
    @inline(__always) package static func breakBeams(_ c: Int, _ b: CarBuffers, substeps: Float) {
        let s = b.cars[c]
        for k in Int(s.firstBeam)..<Int(s.firstBeam + s.beamCount) {
            let load = b.loads[k] / substeps
            b.loads[k] = 0
            var beam = b.beams[k]
            guard beam.kind == CarBeamKind.plastic.rawValue && beam.info & CarBeam.brokenBit == 0 else { continue }
            let limit = b.limits[k]
            if abs(load) > limit.strength || abs(beam.rest - limit.rest0) > limit.strainLimit * limit.rest0 {
                beam.info |= CarBeam.brokenBit
                b.beams[k] = beam
            }
        }
    }
}
