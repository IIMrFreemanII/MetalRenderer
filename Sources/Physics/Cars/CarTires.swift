import EngineCore
import Foundation
import simd

/// A car's tyres (CarDrivetrain.swift's substep calls `tyre` for each wheel). Over buffers, nothing allocated
/// (Tools/perf/hot-functions.txt).
///
/// A tyre is no collision shape (its wheel's body is a smaller rim, without friction, that only touches when the tyre
/// bottoms out): it is a radial spring and damper under the wheel's centre, toward the nearest static's surface in the
/// wheel's plane, and a contact patch where the spring meets it. The patch's slip (its velocity over the ground, the
/// wheel's spin included) gives the force along and across the road by a combined-slip Magic Formula (Pacejka's,
/// normalised: the slips over their peaks, one curve for both), at most the grip x the load, and never more in a
/// substep than stops the slip (so it can't flip it); below a few m/s it blends into plain Coulomb friction, which
/// holds a parked car still. The force moves the wheel's body; its torque about the axle spins the wheel, the rest
/// turns the knuckle (its hubs, a couple).
extension CarSolver {
    /// The Magic Formula's peaks (slip ratio, slip angle's tangent) and shapes (along, across).
    package static let tyrePeakRatio: Float = 0.1, tyrePeakAngle: Float = 0.12
    package static let tyreShapeAlong: Float = 1.5, tyreShapeAcross: Float = 1.35
    package static let tyreRolling: Float = 0.012

    @inline(__always) package static func tyre(_ wk: Int, _ b: CarBuffers, _ t: CarTune, _ candidates: Range<Int>, _ h: Float) {
        var w = b.wheels[wk]
        let i = Int(w.body)
        var o = b.bodies[i]
        guard PhysicsWorld.moves(o) else { return }
        let centre = PhysicsMath.xyz(o.position), a = PhysicsMath.qrot(o.rotation, w.axle), radius = w.radius
        // The static or body nearest the wheel's centre within its reach (a body: a crate, a piece of a wall, driven
        // onto; it takes the patch's impulse back, `tyreKick`).
        var best = -1, nearest = radius + 0.05, onBody = false
        for k in candidates {
            let code = b.candidates[k]
            if code & PhysicsWorld.staticBit != 0 {
                let st = Int(code & ~PhysicsWorld.staticBit), box = b.staticBounds[st]
                if any(centre .< box.lo - radius) || any(centre .> box.hi + radius) { continue }
                let s = b.statics[st]
                let d = b.shapes.distance(shape: Int(s.info.x), PhysicsWorld.Pose(s).toBody(centre))
                if d < nearest { (best, nearest, onBody) = (st, d, false) }
            } else {
                let j = Int(code), o = met(j, b)
                if length_squared(centre - PhysicsMath.xyz(o.position)) > (radius + o.invInertia.w) * (radius + o.invInertia.w) { continue }
                let d = b.shapes.distance(shape: Int(o.info.x), PhysicsWorld.Pose(o).toBody(centre))
                if d < nearest { (best, nearest, onBody) = (j, d, true) }
            }
        }
        w.load = 0
        w.slip = .zero
        w.over = 0
        defer { b.wheels[wk] = w }
        guard best >= 0 else { return }
        let s = onBody ? met(best, b) : b.statics[best], pose = PhysicsWorld.Pose(s), shape = Int(s.info.x)
        // The patch: the tyre's edge toward the surface, in the wheel's plane.
        var n = pose.direction(b.shapes.gradient(shape: shape, pose.toBody(centre)))
        var down = n * -1 + a * dot(n, a)
        let l = length(down)
        guard l > 0.3 else { return }
        down /= l
        let patch = centre + down * radius, local = pose.toBody(patch)
        let depth = -b.shapes.distance(shape: shape, local)
        guard depth > 0 else { return }
        n = pose.direction(b.shapes.gradient(shape: shape, local))
        // (On a body: its surface's velocity at the patch is the ground's.)
        let ground = onBody && PhysicsWorld.moves(s) ? PhysicsMath.xyz(s.velocity) + cross(PhysicsMath.xyz(s.angular), patch - PhysicsMath.xyz(s.position))
            : SIMD3<Float>()
        let v = PhysicsMath.xyz(o.velocity), spinning = PhysicsMath.xyz(o.angular)
        let load = simd_clamp(t.tyreStiffness * depth - t.tyreDamping * dot(v - ground, n), 0, t.tyreStiffness * 0.15)
        let lever = patch - centre
        let slipping = v + cross(spinning, lever) - ground
        let along = PhysicsMath.direction(cross(a, n)), across = PhysicsMath.direction(a - n * dot(a, n))
        let sx = dot(slipping, along), sy = dot(slipping, across), vx = dot(v, along)
        let grip = t.grip * min(s.velocity.w / 0.7, 1.3)
        // What the patch's impulse moves at once: the wheel and its hubs (the rest of the car follows through the axle
        // and the beams). An impulse sized for the car's share of its weight flung the 20 kg wheel past its slip, and
        // the slip across flipped every substep.
        let k = PhysicsWorld.turnWeight(o, a)
        let cornerMass = 1 / o.position.w + 1 / max(b.particles[Int(w.hubIn)].prevPosition.w, 1e-3) + 1 / max(b.particles[Int(w.hubOut)].prevPosition.w, 1e-3)
        let acrossMass = cornerMass, alongMass = 1 / (1 / cornerMass + radius * radius * k)
        // The Magic Formula, the slips normalised by their peaks.
        let reference = max(abs(vx), 0.5)
        let ux = sx / (tyrePeakRatio * reference), uy = sy / (tyrePeakAngle * reference)
        let u = (ux * ux + uy * uy).squareRoot()
        var jx: Float = 0, jy: Float = 0
        if u > 1e-6 {
            let shapeC = (tyreShapeAlong * ux * ux + tyreShapeAcross * uy * uy) / (u * u)
            let shapeB = tan(.pi / (2 * shapeC))
            let force = grip * load * sin(shapeC * atan(shapeB * u))
            jx = -force * h * ux / u
            jy = -force * h * uy / u
        }
        jx = simd_clamp(jx, -abs(sx) * alongMass, abs(sx) * alongMass)
        jy = simd_clamp(jy, -abs(sy) * acrossMass, abs(sy) * acrossMass)
        // Slow: Coulomb friction, all of the slip stopped as far as the grip holds.
        let blend = simd_clamp((abs(vx) - 1) / 2, 0, 1)
        if blend < 1 {
            var cx = -sx * alongMass, cy = -sy * acrossMass
            let most = grip * load * h, lc = (cx * cx + cy * cy).squareRoot()
            if lc > most {
                cx *= most / lc
                cy *= most / lc
            }
            jx = cx + (jx - cx) * blend
            jy = cy + (jy - cy) * blend
        }
        let impulse = n * (load * h) + along * jx + across * jy
        o.velocity = SIMD4(v + impulse * o.position.w, o.velocity.w)
        if onBody && PhysicsWorld.moves(s) { tyreKick(wk, best, -impulse, patch - PhysicsMath.xyz(s.position), b) }
        let torque = cross(lever, impulse), about = dot(torque, a)
        var spin = dot(spinning, a) + about * k
        let roll = tyreRolling * load * radius * h * k
        spin -= spin > 0 ? min(roll, spin) : max(-roll, spin)
        o.angular = SIMD4(spinning + a * (spin - dot(spinning, a)), o.angular.w)
        b.bodies[i] = o
        hubCouple(torque - a * about, w, b)
        w.load = load
        w.slip = SIMD2(sx, sy)
        w.over = dot(v - ground, along)
        w.spin = spin
    }

    /// Wheel `wk`'s tyre's impulse back on body `j`, at `lever` from its centre: kept in its car's list (one slot a
    /// wheel, `CarSystem.tyreKicks`) for `applyTyreKicks`, which applies them in the cars' order.
    @inline(__always) package static func tyreKick(_ wk: Int, _ j: Int, _ impulse: SIMD3<Float>, _ lever: SIMD3<Float>, _ b: CarBuffers) {
        b.tyreKicks[wk] = CarPush(body: Int32(j), impulse: impulse, twist: cross(lever, impulse), count: 1)
    }

    /// The tyres' impulses on bodies this substep (after the cars' forces, in the cars' order): each body's velocity
    /// and spin changed, the body woken; the slots emptied.
    @inline(__always) package static func applyTyreKicks(_ b: CarBuffers) {
        for k in b.tyreKicks.indices where b.tyreKicks[k].count > 0 {
            let kick = b.tyreKicks[k], j = Int(kick.body)
            var o = b.bodies[j]
            o.velocity = SIMD4(PhysicsMath.xyz(o.velocity) + kick.impulse * o.position.w, o.velocity.w)
            o.angular = SIMD4(PhysicsMath.xyz(o.angular) + PhysicsMath.applyInvInertia(o.rotation, PhysicsMath.xyz(o.invInertia), kick.twist), o.angular.w)
            o.info.y &= ~PhysicsWorld.asleep
            o.prevPosition.w = 0
            b.bodies[j] = o
            b.tyreKicks[k] = CarPush()
        }
    }

    /// An angular impulse `l` (across the axle) on wheel `w`'s knuckle, as a couple on its two hubs: `F` out, `-F` in,
    /// `apart x F = l`.
    @inline(__always) package static func hubCouple(_ l: SIMD3<Float>, _ w: CarWheel, _ b: CarBuffers) {
        let hubIn = Int(w.hubIn), hubOut = Int(w.hubOut)
        let apart = PhysicsMath.xyz(b.particles[hubOut].position) - PhysicsMath.xyz(b.particles[hubIn].position)
        let a2 = length_squared(apart)
        guard a2 > 1e-6 else { return }
        let push = cross(l, apart) / a2
        b.particles[hubOut].velocity += SIMD4(push * b.particles[hubOut].prevPosition.w, 0)
        b.particles[hubIn].velocity -= SIMD4(push * b.particles[hubIn].prevPosition.w, 0)
    }
}
