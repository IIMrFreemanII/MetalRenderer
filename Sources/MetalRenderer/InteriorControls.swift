import Foundation
import simd

/// What moves and switches in a scene's interiors: the doors' leaves (how far each is open), the rooms' lights (on
/// or off, and their switches), the lifts (InteriorLifts.swift) and the walker's flashlight. The scene's instances
/// and lights read it in their poses (Scene.update); the renderer moves it on before each frame (`advance`) and
/// tells it what the walker does (`use`). Only the render thread touches it.
final class InteriorControls {
    struct Door {
        /// The hinge's foot (the world), the leaf's direction from it when shut (x, z, unit), and which way it opens
        /// (+1: turning the leaf counter-clockwise seen from above).
        var hinge: SIMD3<Float>
        var along: SIMD2<Float>
        var turn: Float
        var width: Float
        var height: Float
        var thickness: Float = 0.04
        /// How open it is (0 shut ... 1 at 90 degrees), and where it is going.
        var open: Float
        var target: Float
        /// It opens as the walker comes up to it, and (if it opened so) shuts a while after.
        var auto = true
        var autoOpened = false
        var openedAt: Float = -100

        /// The leaf's frame now: x along it from the hinge, y up, z across.
        var frame: float4x4 {
            let angle = turn * open * .pi / 2 * 0.95
            let a = atan2(along.y, along.x) + angle
            let u = SIMD2(cos(a), sin(a))
            return float4x4(columns: (SIMD4(u.x, 0, u.y, 0), SIMD4(0, 1, 0, 0), SIMD4(-u.y, 0, u.x, 0), SIMD4(hinge, 1)))
        }
        /// The leaf as boxes the walker meets (a few, along it: a turned box isn't axis-aligned).
        var colliders: [Interior.Collider] {
            let f = frame
            var out: [Interior.Collider] = []
            let pieces = 4
            for k in 0..<pieces {
                let a = f * SIMD4(width * Float(k) / Float(pieces), 0, 0, 1), b = f * SIMD4(width * Float(k + 1) / Float(pieces), 0, 0, 1)
                let lo = simd_min(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z)) - SIMD3(thickness, 0, thickness)
                let hi = simd_max(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z)) + SIMD3(thickness, height, thickness)
                out.append(Interior.Collider(lo: lo, hi: SIMD3(hi.x, hinge.y + height, hi.z)))
            }
            return out
        }
    }

    struct Switch {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var lights: [Int]
        var on: Bool
    }

    var doors: [Door] = []
    var switches: [Switch] = []
    /// Each light's brightness now (0 off, 1 on): what its pose's scale is.
    var lights: [Float] = []
    var lifts: [Lift] = []
    /// The loose furniture: its bodies in the scene's physics (Scene.physics) and the boxes' half sizes.
    struct Prop {
        var body: Int
        var half: SIMD3<Float>
    }
    var props: [Prop] = []
    /// The walker's flashlight: on, and where it is and points (the renderer's camera).
    var flashlight = (on: false, position: SIMD3<Float>.zero, direction: SIMD3<Float>(0, 0, -1))
    /// Doors open by themselves as the walker comes up to them.
    var autoDoors = true
    private(set) var time: Float = 0

    /// What changed since the frame before (the renderer redraws the reference image only then).
    private(set) var moving = false

    func advance(_ dt: Float, walker: SIMD3<Float>?) {
        time += dt
        moving = false
        for i in doors.indices {
            var d = doors[i]
            if autoDoors, let w = walker, d.auto {
                // Walked up to: opens; left alone a while: shuts again (if it opened by itself).
                let mid = d.hinge + SIMD3(d.along.x, 0, d.along.y) * d.width / 2
                let near = simd_length(SIMD2(w.x - mid.x, w.z - mid.z)) < 1.1 && abs(w.y - d.hinge.y) < 1.5
                if near && d.target < 1 { d.target = 1; d.autoOpened = true }
                if near { d.openedAt = time }
                if !near && d.autoOpened && d.target > 0 && time - d.openedAt > 6 { d.target = 0; d.autoOpened = false }
            }
            if d.open != d.target {
                let step = dt * 1.6
                d.open = d.open < d.target ? min(d.open + step, d.target) : max(d.open - step, d.target)
                moving = true
            }
            doors[i] = d
        }
        for i in lifts.indices {
            // Someone in its doorway or its cab: the doors wait for them.
            if let w = walker { lifts[i].hold(w) }
            if lifts[i].advance(dt) { moving = true }
        }
    }

    /// The walker uses what it looks at, within `reach`: a door opens or shuts, a switch flips, a lift button calls.
    /// `blocked`: how far the view is clear (the first wall). Returns what it used, for the status line.
    @discardableResult
    func use(from eye: SIMD3<Float>, along ray: SIMD3<Float>, reach: Float = 2.4, blocked: Float? = nil) -> String? {
        let limit = min(reach, (blocked ?? .infinity) + 0.15)
        var best: (t: Float, what: Int, kind: Int)?
        for (i, d) in doors.enumerated() {
            for c in d.colliders {
                if let t = ColliderGrid.hit(c.lo, c.hi, eye, ray), t < limit, t < best?.t ?? .infinity { best = (t, i, 0) }
            }
        }
        for (i, s) in switches.enumerated() {
            if let t = ColliderGrid.hit(s.position - 0.12, s.position + 0.12, eye, ray), t < limit, t < best?.t ?? .infinity { best = (t, i, 1) }
        }
        for (i, l) in lifts.enumerated() {
            for (b, button) in l.buttons.enumerated() {
                if let t = ColliderGrid.hit(button.position - 0.1, button.position + 0.1, eye, ray), t < limit, t < best?.t ?? .infinity {
                    best = (t, i * 1000 + b, 2)
                }
            }
            // ...or a landing's door itself: the call button of that floor.
            for k in l.floors.indices {
                let (lo, hi) = l.doorway(k)
                if let t = ColliderGrid.hit(lo, hi, eye, ray), t < limit, t < best?.t ?? .infinity { best = (t, i * 1000 + 500 + k, 2) }
            }
        }
        guard let best else { return nil }
        switch best.kind {
        case 0:
            doors[best.what].target = doors[best.what].target > 0.5 ? 0 : 1
            doors[best.what].autoOpened = false
            return doors[best.what].target > 0.5 ? "Door opened" : "Door shut"
        case 1:
            switches[best.what].on.toggle()
            for l in switches[best.what].lights { lights[l] = switches[best.what].on ? 1 : 0 }
            moving = true
            return switches[best.what].on ? "Light on" : "Light off"
        default:
            let lift = best.what / 1000, b = best.what % 1000
            let floor = b >= 500 ? b - 500 : lifts[lift].buttons[b].floor
            lifts[lift].call(floor)
            return "Lift called to floor \(floor)"
        }
    }

    /// The switches within `reach` of `point` turned on or off (and their lights).
    func setSwitches(near point: SIMD3<Float>, within reach: Float, on: Bool) {
        for i in switches.indices where simd_distance(switches[i].position, point) < reach && switches[i].on != on {
            switches[i].on = on
            for l in switches[i].lights { lights[l] = on ? 1 : 0 }
            moving = true
        }
    }

    /// The loose furniture as the walker meets it: each body's box (turned as it lies) as the box round it.
    func propObstacles(_ physics: PhysicsWorld?) -> [Walker.Moving] {
        guard let physics, !props.isEmpty else { return [] }
        return props.compactMap { p in
            guard physics.bodies.indices.contains(p.body) else { return nil }
            let b = physics.bodies[p.body]
            let x = PhysicsMath.xyz(b.position), q = b.rotation
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
            for corner in [SIMD3<Float>(-1, -1, -1), [1, -1, -1], [-1, 1, -1], [1, 1, -1], [-1, -1, 1], [1, -1, 1], [-1, 1, 1], [1, 1, 1]] {
                let w = x + PhysicsMath.qrot(q, corner * p.half)
                lo = simd_min(lo, w); hi = simd_max(hi, w)
            }
            return Walker.Moving(boxes: [Interior.Collider(lo: lo, hi: hi, kind: .furniture)], platform: nil)
        }
    }

    /// The walker at `feet` moving at `velocity` shoves what it walks into: each body it touches gets going its way
    /// (and wakes); a heavy one hardly.
    func push(_ physics: PhysicsWorld?, feet: SIMD3<Float>, velocity: SIMD3<Float>, height: Float) {
        guard let physics, !props.isEmpty else { return }
        let along = SIMD2(velocity.x, velocity.z)
        guard length(along) > 0.2 else { return }
        for p in props where physics.bodies.indices.contains(p.body) {
            var b = physics.bodies[p.body]
            let x = PhysicsMath.xyz(b.position)
            guard x.y > feet.y - p.half.y - 0.1, x.y < feet.y + height else { continue }
            let d = SIMD2(x.x - feet.x, x.z - feet.z)
            let reach = Walker.radius + max(p.half.x, p.half.z) + 0.08
            guard length(d) < reach, dot(d, along) > 0 else { continue }
            // Its way, at about the walker's speed (less for a heavier piece), from where the walker meets it: low, so it
            // tips if it is tall.
            let mass = b.position.w > 0 ? 1 / b.position.w : 100
            let speed = min(length(along), 2.5) * min(1, 12 / mass)
            let push = normalize(along) * speed
            b.velocity.x = max(b.velocity.x * 0.5 + push.x, -3)
            b.velocity.z = max(b.velocity.z * 0.5 + push.y, -3)
            b.info.y &= ~PhysicsWorld.asleep
            physics.bodies[p.body] = b
        }
    }

    /// What of it the walker can't walk through, and what it stands on (lift cabs).
    var obstacles: [Walker.Moving] {
        doors.map { Walker.Moving(boxes: $0.colliders, platform: nil) } + lifts.enumerated().map { Walker.Moving(boxes: $1.colliders, platform: $0) }
    }
}
