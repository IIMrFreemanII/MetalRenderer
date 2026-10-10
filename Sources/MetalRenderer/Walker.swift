import Foundation
import simd

/// Walking (walk mode, the V key): a person 1.8 m tall (1.2 crouched), 0.3 m round, who falls, stands on what is
/// under it, climbs what is a step high (stairs) and slides along walls. Pure and deterministic: the renderer steps
/// it every frame at 120 Hz with what is held, and puts the camera at its eyes.
///
/// It meets the scene's colliders (Scene.walkColliders: axis-aligned boxes, the buildings' walls, floors, steps,
/// furniture and glass, the ground) through a grid, and what moves: door leaves (thin boxes turned about their
/// hinge) and lift cabs (`Walker.Moving`).
struct Walker {
    var feet: SIMD3<Float>
    var velocity = SIMD3<Float>.zero
    var grounded = false
    var crouched = false
    /// The eyes' height over the feet, eased toward the stance's (and over a step climbed, so the view doesn't jump).
    var eye: Float = Walker.eyeStanding
    /// The platform it stands on (a lift's cab), if any: its id.
    var standingOn: Int?

    static let radius: Float = 0.28
    static let standing: Float = 1.8, crouching: Float = 1.2
    static let eyeStanding: Float = 1.68, eyeCrouching: Float = 1.08
    static let step: Float = 0.42
    static let gravity: Float = 9.81
    static let jumpSpeed: Float = 4.2
    static let walkSpeed: Float = 1.45, runSpeed: Float = 3.6, crouchSpeed: Float = 0.8
    static let dt: Float = 1 / 120

    var height: Float { crouched ? Walker.crouching : Walker.standing }
    var eyePosition: SIMD3<Float> { feet + SIMD3(0, eye, 0) }

    /// What it is told each step: where to go (x, z: a unit or zero, in the world), how, and whether to jump.
    struct Input {
        var move = SIMD2<Float>.zero
        var run = false
        var crouch = false
        var jump = false
    }

    /// Something that moves that it can't walk through, or stands on: a door's leaf (a box of `size` turned by
    /// `yaw` about `hinge`), or a cab (its floor and walls: boxes in the world, its id).
    struct Moving {
        var boxes: [Interior.Collider]
        var platform: Int?
    }

    init(feet: SIMD3<Float>) { self.feet = feet }

    // MARK: - Stepping

    /// Steps it `dt` (in fixed steps of `Walker.dt`; the rest carries over) with `input` among `world` and `moving`.
    mutating func advance(_ dt: Float, input: Input, world: ColliderGrid, moving: [Moving] = [], carry: (Int) -> SIMD3<Float> = { _ in .zero },
                          terrain: ((Float, Float) -> Float)? = nil, remainder: inout Float) {
        remainder += min(dt, 0.1)
        while remainder >= Walker.dt {
            remainder -= Walker.dt
            step(input, world: world, moving: moving, carry: carry, terrain: terrain)
        }
    }

    mutating func step(_ input: Input, world: ColliderGrid, moving: [Moving], carry: (Int) -> SIMD3<Float>,
                       terrain: ((Float, Float) -> Float)? = nil) {
        let dt = Walker.dt
        // On a platform: moved with it first.
        if let p = standingOn { feet += carry(p) }
        // Crouching, or standing up if there is room over it.
        if input.crouch { crouched = true } else if crouched && room(above: Walker.standing, world: world, moving: moving) { crouched = false }
        let targetEye = crouched ? Walker.eyeCrouching : Walker.eyeStanding
        eye += (targetEye - eye) * min(1, dt * 10)

        // Toward where it is told, quickly on the ground and a little in the air.
        let speed = crouched ? Walker.crouchSpeed : input.run ? Walker.runSpeed : Walker.walkSpeed
        let want = input.move * speed
        let accel: Float = grounded ? 14 : 2.5
        var horizontal = SIMD2(velocity.x, velocity.z)
        let change = want - horizontal
        let most = accel * dt
        horizontal += length(change) > most ? normalize(change) * most : change
        velocity.x = horizontal.x
        velocity.z = horizontal.y
        if input.jump && grounded {
            velocity.y = Walker.jumpSpeed
            grounded = false
            standingOn = nil
        }
        velocity.y -= Walker.gravity * dt

        // Across: moved, then pushed out of whatever stands higher than a step (twice: corners).
        feet.x += velocity.x * dt
        feet.z += velocity.z * dt
        for _ in 0..<3 {
            var pushed = false
            for box in blockers(world: world, moving: moving) {
                if let push = Walker.push(SIMD2(feet.x, feet.z), Walker.radius, box) {
                    feet.x += push.x
                    feet.z += push.y
                    // Into the wall no more.
                    let n = normalize(push)
                    let into = dot(SIMD2(velocity.x, velocity.z), n)
                    if into < 0 { velocity.x -= n.x * into; velocity.z -= n.y * into }
                    pushed = true
                }
            }
            if !pushed { break }
        }

        // Up and down: falls, lands on the highest thing under it within a step, stops under a ceiling.
        let wasGrounded = grounded
        feet.y += velocity.y * dt
        var ground = groundUnder(world: world, moving: moving, reach: wasGrounded && velocity.y <= 0 ? Walker.step : 0.02)
        // The terrain: under whatever stands on it (it can't be walked under).
        if let terrain {
            let h = terrain(feet.x, feet.z)
            if h > ground?.top ?? -.infinity && h <= feet.y + Walker.step { ground = (h, nil) }
            if feet.y < h - 0.5 { feet.y = h }
        }
        if let g = ground, velocity.y <= 0, feet.y <= g.top + 1e-4 {
            let climbed = g.top - feet.y
            feet.y = g.top
            velocity.y = 0
            grounded = true
            standingOn = g.platform
            if climbed > 0.05 { eye -= climbed * 0.6 }   // the view eases up a step instead of jumping
        } else if let g = ground, wasGrounded, velocity.y <= 0, feet.y - g.top < Walker.step {
            // Going down a step: stays on the ground.
            eye += (feet.y - g.top) * 0.6
            feet.y = g.top
            velocity.y = 0
            grounded = true
            standingOn = g.platform
        } else {
            grounded = false
            standingOn = nil
        }
        if velocity.y > 0, let ceiling = ceilingOver(world: world, moving: moving), feet.y + height > ceiling {
            feet.y = ceiling - height
            velocity.y = 0
        }
    }

    /// The boxes that block it across: those from a step over its feet to its head.
    private func blockers(world: ColliderGrid, moving: [Moving]) -> [Interior.Collider] {
        let lo = SIMD3(feet.x - Walker.radius, feet.y + Walker.step, feet.z - Walker.radius)
        let hi = SIMD3(feet.x + Walker.radius, feet.y + height, feet.z + Walker.radius)
        return world.boxes(overlapping: lo, hi) + moving.flatMap(\.boxes).filter { Walker.overlaps($0, lo, hi) }
    }

    /// The highest top under its feet (from `reach` below them to a step above), and whose it is.
    private func groundUnder(world: ColliderGrid, moving: [Moving], reach: Float) -> (top: Float, platform: Int?)? {
        let r = Walker.radius * 0.7
        let lo = SIMD3(feet.x - r, feet.y - reach - 0.001, feet.z - r), hi = SIMD3(feet.x + r, feet.y + Walker.step, feet.z + r)
        var best: (top: Float, platform: Int?)?
        for b in world.boxes(overlapping: lo, hi) where b.hi.y <= hi.y && b.hi.y >= lo.y {
            if b.hi.y > best?.top ?? -.infinity { best = (b.hi.y, nil) }
        }
        for m in moving {
            for b in m.boxes where Walker.overlaps(b, lo, hi) && b.hi.y <= hi.y && b.hi.y >= lo.y {
                // (A platform level with the floor round it is what it stands on: a cab at its landing.)
                let level = m.platform != nil && best.map { abs(b.hi.y - $0.top) < 0.01 && $0.platform == nil } == true
                if b.hi.y > best?.top ?? -.infinity || level { best = (max(b.hi.y, best?.top ?? b.hi.y), m.platform) }
            }
        }
        return best
    }

    /// The lowest underside over its head (or the room to stand: `room(above:)`).
    private func ceilingOver(world: ColliderGrid, moving: [Moving]) -> Float? {
        let r = Walker.radius * 0.7
        let lo = SIMD3(feet.x - r, feet.y + Walker.step, feet.z - r), hi = SIMD3(feet.x + r, feet.y + height + 0.3, feet.z + r)
        let under = world.boxes(overlapping: lo, hi) + moving.flatMap(\.boxes).filter { Walker.overlaps($0, lo, hi) }
        return under.filter { $0.lo.y > feet.y + Walker.step }.map(\.lo.y).min()
    }

    private func room(above h: Float, world: ColliderGrid, moving: [Moving]) -> Bool {
        let r = Walker.radius * 0.9
        let lo = SIMD3(feet.x - r, feet.y + Walker.crouching, feet.z - r), hi = SIMD3(feet.x + r, feet.y + h, feet.z + r)
        return world.boxes(overlapping: lo, hi).isEmpty && !moving.contains { $0.boxes.contains { Walker.overlaps($0, lo, hi) } }
    }

    static func overlaps(_ b: Interior.Collider, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> Bool {
        all(b.lo .< hi) && all(b.hi .> lo)
    }

    /// How far to move a circle at `c` of radius `r` (x, z) out of box `b`'s footprint, if it is in it.
    static func push(_ c: SIMD2<Float>, _ r: Float, _ b: Interior.Collider) -> SIMD2<Float>? {
        let lo = SIMD2(b.lo.x, b.lo.z), hi = SIMD2(b.hi.x, b.hi.z)
        let closest = simd_clamp(c, lo, hi)
        let d = c - closest
        let dist = length(d)
        if dist > 1e-5 {
            return dist < r ? d / dist * (r - dist) : nil
        }
        // Its centre inside the box: out by the nearest side.
        let out = [c.x - lo.x, hi.x - c.x, c.y - lo.y, hi.y - c.y]
        let k = out.indices.min { out[$0] < out[$1] }!
        switch k {
        case 0: return SIMD2(-(out[0] + r), 0)
        case 1: return SIMD2(out[1] + r, 0)
        case 2: return SIMD2(0, -(out[2] + r))
        default: return SIMD2(0, out[3] + r)
        }
    }
}

/// The scene's colliders by where they are: a grid of 2 m cells over x and z, each cell listing the boxes over it.
struct ColliderGrid {
    let boxes: [Interior.Collider]
    private var cells: [SIMD2<Int32>: [Int32]] = [:]
    /// Boxes too big for the grid (the ground): tested always.
    private var large: [Int] = []
    static let cell: Float = 2

    init(_ boxes: [Interior.Collider]) {
        self.boxes = boxes
        for (i, b) in boxes.enumerated() {
            let lo = ColliderGrid.key(b.lo), hi = ColliderGrid.key(b.hi)
            let count = Int(hi.x - lo.x + 1) * Int(hi.y - lo.y + 1)
            if count > 400 { large.append(i); continue }
            for x in lo.x...hi.x { for z in lo.y...hi.y { cells[SIMD2(x, z), default: []].append(Int32(i)) } }
        }
    }

    private static func key(_ p: SIMD3<Float>) -> SIMD2<Int32> {
        SIMD2(Int32((p.x / cell).rounded(.down)), Int32((p.z / cell).rounded(.down)))
    }

    /// The boxes that overlap the box from `lo` to `hi`.
    func boxes(overlapping lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> [Interior.Collider] {
        var seen = Set<Int32>(), out: [Interior.Collider] = []
        let a = ColliderGrid.key(lo), b = ColliderGrid.key(hi)
        for x in a.x...b.x {
            for z in a.y...b.y {
                for i in cells[SIMD2(x, z)] ?? [] where seen.insert(i).inserted {
                    if Walker.overlaps(boxes[Int(i)], lo, hi) { out.append(boxes[Int(i)]) }
                }
            }
        }
        for i in large where Walker.overlaps(boxes[i], lo, hi) { out.append(boxes[i]) }
        return out
    }

    /// Where a ray from `origin` along `direction` first meets a box, within `limit`.
    func raycast(_ origin: SIMD3<Float>, _ direction: SIMD3<Float>, limit: Float) -> Float? {
        var best: Float?
        let end = origin + direction * limit
        for b in boxes(overlapping: simd_min(origin, end) - 0.01, simd_max(origin, end) + 0.01) {
            if let t = ColliderGrid.hit(b.lo, b.hi, origin, direction), t <= limit, t < best ?? .infinity { best = t }
        }
        return best
    }

    /// Where a ray meets the box from `lo` to `hi` (slab test), if it does in front of it.
    static func hit(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, _ o: SIMD3<Float>, _ d: SIMD3<Float>) -> Float? {
        let safe = SIMD3(abs(d.x) < 1e-9 ? 1e-9 : d.x, abs(d.y) < 1e-9 ? 1e-9 : d.y, abs(d.z) < 1e-9 ? 1e-9 : d.z)
        let inv = SIMD3<Float>(1, 1, 1) / safe
        let t0 = (lo - o) * inv, t1 = (hi - o) * inv
        let near = simd_reduce_max(simd_min(t0, t1)), far = simd_reduce_min(simd_max(t0, t1))
        guard far >= max(near, 0) else { return nil }
        return max(near, 0)
    }
}
