import EngineCore
import Foundation
import simd

/// A car's substep before the bodies move (Physics+Cars.swift's `carForces`): the input ramped, the steering, the
/// engine through the clutch, gearbox and differentials to the driven wheels, the brakes, the tyres (CarTires.swift),
/// the air; then its nodes moved. Over buffers, nothing allocated (Tools/perf/hot-functions.txt).
///
/// The engine is a flywheel driven by its torque curve (throttle x torque, less its friction; an idle control below
/// idle, the limiter's cut above it). The clutch is an impulse that brings the engine's speed and the gearbox's (the
/// driven wheels' mean spin x the gear's ratio) together, as far as its torque allows over the substep, shared
/// equally among the driven wheels (open differentials); a limited-slip one then brings a pair's spins together as far
/// as its locking allows. What turns the wheels turns the body back (the engine's nodes, a couple), and what brakes them
/// turns the knuckle (its steering arm against its hub). An automatic clutch slips at a launch and opens below idle;
/// an automatic gearbox shifts up near the limiter and down near idle, and S held at a stop selects reverse.
extension CarSolver {
    @inline(__always) package static func approach(_ x: Float, _ target: Float, _ step: Float) -> Float {
        x < target ? min(x + step, target) : max(x - step, target)
    }

    /// The ratio from the engine to the wheels in gear `gear` (negative in reverse; 0 in neutral).
    @inline(__always) package static func ratio(_ t: CarTune, _ gear: Int32) -> Float {
        gear > 0 ? t.gears[Int(min(gear, 7)) - 1] * t.finalDrive : gear < 0 ? -t.reverse * t.finalDrive : 0
    }

    @inline(__always) package static func carForces(_ c: Int, _ b: CarBuffers, _ p: GPUPhysicsParams, sub: Int) {
        var s = b.cars[c]
        let t = b.tunes[c], h = p.gravity.w
        let f = PhysicsWorld.carFrame(s, UnsafeBufferPointer(b.particles))
        let speed = dot(f.velocity, f.forward)
        if sub == 0 && s.input.autopilot { autopilot(&s, f.centre, f.forward, speed) }
        let input = s.input
        // The pedals: W and S are throttle and brake, or the other way round in reverse.
        if !input.manual {
            if s.gear >= 0 && input.decelerate > 0.1 && input.accelerate < 0.1 && speed < 0.5 {
                s.gear = -1
            } else if s.gear <= 0 && input.accelerate > 0.1 && input.decelerate < 0.1 && speed > -0.5 {
                s.gear = 1
            }
        }
        let reversing = s.gear < 0
        let throttleTarget = reversing ? input.decelerate : input.accelerate, brakeTarget = reversing ? input.accelerate : input.decelerate
        s.throttle = approach(s.throttle, throttleTarget, (throttleTarget > s.throttle ? 6 : 10) * h)
        s.brake = approach(s.brake, brakeTarget, 8 * h)
        s.handbrake = approach(s.handbrake, input.handbrake, 10 * h)
        s.steer = approach(s.steer, input.steer * t.steer / (1 + abs(speed) / 20), t.steerRate * h)
        let turn = sin(s.steer)

        // The wheels as they are: each one's axle, spin and inverse inertia about it.
        let wf = Int(s.firstWheel), wheels = min(Int(s.wheelCount), 8)
        var spins = SIMD8<Float>(), inverse = SIMD8<Float>()
        var driven: Float = 0, drivenInverse: Float = 0, meanSpin: Float = 0
        for k in 0..<wheels {
            let w = b.wheels[wf + k]
            if w.tie >= 0 {
                let limit = b.limits[Int(w.tie)]
                b.beams[Int(w.tie)].rest = limit.rest0 + limit.bend + limit.steer * turn
            }
            let o = b.bodies[Int(w.body)], a = PhysicsMath.qrot(o.rotation, w.axle)
            spins[k] = dot(PhysicsMath.xyz(o.angular), a)
            inverse[k] = PhysicsWorld.turnWeight(o, a)
            if w.flags & CarWheel.driven != 0 {
                driven += 1
                drivenInverse += inverse[k]
                meanSpin += spins[k]
            }
        }
        meanSpin /= max(driven, 1)

        // Traction control: the throttle eased off while the driven wheels spin faster than the car goes (by more than
        // their peak's slip, and a little more at a standstill, where a launch slips).
        var spinning: Float = 0
        if t.assists && driven > 0 {
            let ground = abs(speed), wheel = abs(meanSpin) * b.wheels[wf].radius
            spinning = simd_clamp((wheel - ground * (1 + tyrePeakRatio) - 0.3) / 1.0, 0, 1)
        }
        // The engine: its power cut by its damage and by its heat past half (CarDamage.swift); a seized one stopped.
        if s.running {
            var throttle = s.throttle * (1 - 0.95 * spinning)
            if s.engine < t.idle { throttle = max(throttle, min((t.idle - s.engine) / (0.2 * t.idle), 1) * 0.3) }
            if s.engine > t.limiter { throttle = 0 }
            let power = (1 - s.engineDamage) * (1 - 1.2 * max(s.heat - 0.5, 0))
            let torque = throttle * power * t.torque(at: s.engine) - (15 + 0.02 * s.engine) * min(s.engine / 10, 1)
            s.engine = max(s.engine + torque * h / t.engineInertia, 0)
        } else {
            s.engine = 0
        }
        // The gearbox: automatic shifts (the clutch out for a moment), up when the wheels turn the gearbox near the limiter,
        // down when they turn it near idle, not back at once.
        s.sinceShift += h
        if s.shifting > 0 {
            s.shifting -= h
        } else if !input.manual && s.gear > 0 && s.sinceShift > 0.8 {
            let gearbox = ratio(t, s.gear) * meanSpin
            if gearbox > 0.92 * t.limiter && s.gear < t.gearCount && s.throttle > 0.3 {
                s.gear += 1
                s.shifting = 0.2
                s.sinceShift = 0
            } else if s.gear > 1 && gearbox < 2.2 * t.idle && ratio(t, s.gear - 1) * meanSpin < 0.75 * t.limiter {
                s.gear -= 1
                s.shifting = 0.15
                s.sinceShift = 0
            }
        }
        // The clutch: slipping at a launch (as the engine revs), in while the gearbox turns above idle.
        let g = ratio(t, s.gear)
        var engage: Float = 0
        if g != 0 && s.shifting <= 0 && driven > 0 && s.running {
            let launch = s.throttle > 0.05 ? simd_clamp((s.engine - t.idle) / (1.2 * t.idle), 0, 1) : 0
            let rolling = simd_clamp((abs(g * meanSpin) - 0.9 * t.idle) / (0.4 * t.idle), 0, 1)
            engage = max(launch, rolling)
        }
        s.clutch = engage
        var given: Float = 0   // the angular impulse each driven wheel takes
        if engage > 0 && drivenInverse > 0 {
            let gearbox = g * g / (driven * driven) * drivenInverse
            let most = t.clutchTorque * engage * h
            let j = simd_clamp((s.engine - g * meanSpin) / (1 / t.engineInertia + gearbox), -most, most)
            s.engine -= j / t.engineInertia
            given = j * g / driven
        }
        var reaction = SIMD3<Float>()
        if given != 0 {
            for k in 0..<wheels where b.wheels[wf + k].flags & CarWheel.driven != 0 {
                let dw = given * inverse[k]
                spins[k] += dw
                reaction += spinWheel(b.wheels[wf + k], b, dw)
            }
            // A limited-slip differential: a driven pair's spins together, as far as its locking allows.
            if t.limitedSlip > 0 {
                for pair in 0..<(wheels / 2) {
                    let k0 = 2 * pair, k1 = k0 + 1
                    guard b.wheels[wf + k0].flags & b.wheels[wf + k1].flags & CarWheel.driven != 0, inverse[k0] + inverse[k1] > 0 else { continue }
                    let most = (100 + t.limitedSlip * abs(given) / h) * h
                    let j = simd_clamp((spins[k0] - spins[k1]) / (inverse[k0] + inverse[k1]), -most, most)
                    spins[k0] -= j * inverse[k0]
                    spins[k1] += j * inverse[k1]
                    _ = spinWheel(b.wheels[wf + k0], b, -j * inverse[k0])
                    _ = spinWheel(b.wheels[wf + k1], b, j * inverse[k1])
                }
            }
            couple(-reaction, b, Int(s.firstReaction), Int(s.reactionCount))
        }
        // The brakes (a locked wheel stays locked: the brake takes its spin down to 0 and no further).
        for k in 0..<wheels {
            let w = b.wheels[wf + k]
            var pedal = w.brake * s.brake
            // ABS: a wheel slower than the car by more than its peak's slip lets its brake off, smoothly from 0.8 to 1.3
            // of the peak.
            if t.assists && abs(speed) > 2 {
                let ratio = 1 - abs(spins[k]) * w.radius / abs(speed)
                pedal *= simd_clamp(1 - (ratio / tyrePeakRatio - 0.8) / 0.5, 0.15, 1)
            }
            // Traction control's brakes: a driven wheel spinning past its peak's slip is braked (an open differential
            // then gives its torque to the other wheel as well, and the car doesn't turn toward the one that grips).
            if t.assists && w.flags & CarWheel.driven != 0 {
                let excess = abs(spins[k]) * w.radius - abs(speed) * (1 + tyrePeakRatio) - 0.2
                if excess > 0 { pedal += min(excess * 1500, w.brake) }
            }
            let torque = pedal + (w.flags & CarWheel.handbraked != 0 ? t.handbrake * s.handbrake : 0)
            guard torque > 0, inverse[k] > 0 else { continue }
            let most = torque * h * inverse[k]
            let dw = spins[k] > 0 ? -min(spins[k], most) : min(-spins[k], most)
            guard dw != 0 else { continue }
            spins[k] += dw
            let taken = spinWheel(w, b, dw)
            knuckleCouple(-taken, w, b)
        }
        // The tyres (of the wheels still on).
        let candidates = Int(s.firstCandidate)..<Int(s.firstCandidate + s.candidateCount)
        for k in 0..<wheels where b.wheels[wf + k].flags & CarWheel.off == 0 { tyre(wf + k, b, t, candidates, h) }

        // The air's drag, and the nodes moved (their velocities, gravity).
        let v = length(f.velocity)
        let drag = v > 1e-3 ? -f.velocity * (0.5 * PhysicsWorld.airDensity * t.dragArea * v * h / s.mass) : SIMD3<Float>()
        let gravity = PhysicsMath.xyz(p.gravity) * h
        for i in Int(s.firstNode)..<Int(s.firstNode + s.nodeCount) {
            var q = b.particles[i]
            guard q.prevPosition.w > 0 else { continue }
            let x = PhysicsMath.xyz(q.position)
            let u = PhysicsMath.xyz(q.velocity) + gravity + drag
            q.prevPosition = SIMD4(x, q.prevPosition.w)
            q.velocity = SIMD4(u, q.velocity.w)
            q.position = SIMD4(x + u * h, q.position.w)
            b.particles[i] = q
        }
        b.cars[c] = s
    }

    /// Wheel `w`'s spin changed by `dw` (rad/s): the angular impulse it took (the world).
    @inline(__always) package static func spinWheel(_ w: CarWheel, _ b: CarBuffers, _ dw: Float) -> SIMD3<Float> {
        let i = Int(w.body)
        var o = b.bodies[i]
        guard PhysicsWorld.moves(o) else { return .zero }
        let a = PhysicsMath.qrot(o.rotation, w.axle)
        o.angular = SIMD4(PhysicsMath.xyz(o.angular) + a * dw, o.angular.w)
        b.bodies[i] = o
        let k = PhysicsWorld.turnWeight(o, a)
        return k > 0 ? a * (dw / k) : .zero
    }

    /// An angular impulse `l` on nodes `first..<first + count` of the reaction list (the engine's), as velocity
    /// changes that add to no push: each node's `l x r / S` about their middle.
    @inline(__always) package static func couple(_ l: SIMD3<Float>, _ b: CarBuffers, _ first: Int, _ count: Int) {
        guard count > 1, length_squared(l) > 0 else { return }
        var centre = SIMD3<Float>()
        for k in first..<(first + count) { centre += PhysicsMath.xyz(b.particles[Int(b.reactions[k])].position) }
        centre /= Float(count)
        let axis = normalize(l)
        var spread: Float = 0
        for k in first..<(first + count) {
            let r = PhysicsMath.xyz(b.particles[Int(b.reactions[k])].position) - centre
            spread += length_squared(r) - dot(r, axis) * dot(r, axis)
        }
        guard spread > 1e-6 else { return }
        for k in first..<(first + count) {
            let i = Int(b.reactions[k])
            let r = PhysicsMath.xyz(b.particles[i].position) - centre
            b.particles[i].velocity += SIMD4(cross(l, r) / spread * b.particles[i].prevPosition.w, 0)
        }
    }

    /// An angular impulse `l` on wheel `w`'s knuckle: its steering arm pushed one way, its hubs the other.
    @inline(__always) package static func knuckleCouple(_ l: SIMD3<Float>, _ w: CarWheel, _ b: CarBuffers) {
        let arm = Int(w.arm), hubIn = Int(w.hubIn), hubOut = Int(w.hubOut)
        let middle = (PhysicsMath.xyz(b.particles[hubIn].position) + PhysicsMath.xyz(b.particles[hubOut].position)) / 2
        var r = PhysicsMath.xyz(b.particles[arm].position) - middle
        let axis = PhysicsMath.direction(l)
        r -= axis * dot(r, axis)
        let r2 = length_squared(r)
        guard r2 > 1e-6 else { return }
        let push = cross(l, r) / r2
        b.particles[arm].velocity += SIMD4(push * b.particles[arm].prevPosition.w, 0)
        b.particles[hubIn].velocity -= SIMD4(push * (0.5 * b.particles[hubIn].prevPosition.w), 0)
        b.particles[hubOut].velocity -= SIMD4(push * (0.5 * b.particles[hubOut].prevPosition.w), 0)
    }

    /// The autopilot's input (once a step): round its circle at its speed, steering for the tangent bent back toward
    /// the circle, the pedals for the speed.
    @inline(__always) package static func autopilot(_ s: inout CarState, _ centre: SIMD3<Float>, _ forward: SIMD3<Float>, _ speed: Float) {
        let lap = s.input.lap
        let r = SIMD2(centre.x - lap.x, centre.z - lap.y)
        let distance = max(length(r), 1e-3), radial = r / distance
        let tangent = SIMD2(-radial.y, radial.x)
        let want = normalize(tangent - radial * simd_clamp((distance - lap.z) * 0.15, -0.6, 0.6))
        let ahead = SIMD2(forward.x, forward.z)
        guard length(ahead) > 1e-3 else { return }
        let heading = normalize(ahead)
        let error = atan2(heading.x * want.y - heading.y * want.x, dot(heading, want))
        s.input.steer = simd_clamp(-error * 2, -1, 1)
        let e = lap.w - speed
        s.input.accelerate = simd_clamp(e * 0.5, 0, 1)
        s.input.decelerate = simd_clamp(-e * 0.3, 0, 1)
    }
}
