import Foundation
import simd

/// A building's tops: a flat roof with a parapet and things standing on it, or a pitched one (gabled, hipped,
/// mansard) folded over a rectangle. An L's gabled roof is two, one over the bar and one over the wing that runs
/// into it, which makes the valley between them. In the lot's frame.
extension BuildingAssembler {
    typealias Rect = CityPlan.Rect

    /// The top of `tier`. `next`: the plan of the tier that stands on it, if one does (nothing is put under it).
    mutating func roof(_ tier: BuildingTier, under next: Footprint?) {
        b.setFrame(matrix_identity_float4x4)
        let plan = tier.footprint, top = tier.top
        switch tier.roof {
        case .flat:
            for r in plan.cover { b[.roof].floor(x0: r.lo.x, x1: r.hi.x, z0: r.lo.y, z1: r.hi.y, y: top) }
            // The parapet: on every wall that isn't a party wall.
            for loop in plan.loops {
                let on = loop.indices.map { edgeKind(loop[$0], loop[($0 + 1) % loop.count]) != .party }
                band(loop, on: on, y0: top, y1: top + style.parapet, depth: -0.25, slot: .trim, underside: false, wallFace: true)
            }
            rooftop(tier, under: next)
        case .gabled:
            let cover = plan.cover
            let pitch = style.roofPitch   // rise over run
            // Along the front (the eaves to the street) more often than not; a wide, shallow plan along its length.
            let bar = cover[0]
            let alongX = bar.size.x >= bar.size.y * 1.6 || (bar.size.y < bar.size.x * 1.6 && rng.next() < 0.7)
            let rise = pitch * (alongX ? bar.size.y : bar.size.x) / 2
            gable(bar, y: top, rise: rise, alongX: alongX, open: [])
            if cover.count > 1 {
                // The wing: its roof runs along z into the bar's, to the bar's ridge (or its wall), and no higher.
                let wing = cover[1]
                let into = alongX ? bar.center.y : bar.lo.y + 0.4
                let arm = Rect(lo: wing.lo, hi: SIMD2(wing.hi.x, into))
                gable(arm, y: top, rise: min(pitch * arm.size.x / 2, rise - 0.05), alongX: false, open: [.front])
            }
            chimneys(bar, y: top, rise: rise, alongX: alongX)
        case .hipped:
            hip(plan.rect, y: top, pitch: rng.range(0.5, 0.8))
            chimneys(plan.rect, y: top, rise: 0, alongX: true)
        case .mansard:
            mansard(plan.rect, y: top)
        }
    }

    /// Which sides of `r` may have eaves: those that aren't on a party wall. front (+z), right, back, left.
    private func freeSides(_ r: Rect) -> [Bool] {
        [lotSide(SIMD2(r.center.x, r.hi.y), SIMD2(0, 1)), lotSide(SIMD2(r.hi.x, r.center.y), SIMD2(1, 0)),
         lotSide(SIMD2(r.center.x, r.lo.y), SIMD2(0, -1)), lotSide(SIMD2(r.lo.x, r.center.y), SIMD2(-1, 0))]
            .map { side in side.map { spec.edges[$0] != .party } ?? true }
    }

    private struct Ends: OptionSet {
        let rawValue: Int
        static let back = Ends(rawValue: 1), front = Ends(rawValue: 2)   // the ridge's low and high end
    }

    /// A gabled roof over `r` from height `y`: two slopes up to a ridge `rise` higher, along x or z, with eaves that
    /// overhang the free sides and a gable in the wall's material at each end but the `open` ones (an arm that runs
    /// into another roof).
    private mutating func gable(_ r: Rect, y: Float, rise: Float, alongX: Bool, open: Ends) {
        let free = freeSides(r)
        // In the roof's own terms: u along the ridge, v across it. `point` puts them back.
        let (u0, u1, v0, v1) = alongX ? (r.lo.x, r.hi.x, r.lo.y, r.hi.y) : (r.lo.y, r.hi.y, r.lo.x, r.hi.x)
        func point(_ u: Float, _ v: Float, _ h: Float) -> SIMD3<Float> { alongX ? SIMD3(u, h, v) : SIMD3(v, h, u) }
        let vm = (v0 + v1) / 2, slope = rise / (vm - v0)
        // Eaves: over the sides across the ridge; the verges: over the gable ends.
        let eave0: Float = (alongX ? free[2] : free[3]) ? 0.35 : 0, eave1: Float = (alongX ? free[0] : free[1]) ? 0.35 : 0
        let verge0: Float = (alongX ? free[3] : free[2]) && !open.contains(.back) ? 0.25 : 0
        let verge1: Float = (alongX ? free[1] : free[0]) && !open.contains(.front) ? 0.25 : 0
        let a = u0 - verge0, c = u1 + verge1
        b[.roof].quad(point(a, v0 - eave0, y - eave0 * slope), point(c, v0 - eave0, y - eave0 * slope), point(c, vm, y + rise), point(a, vm, y + rise))
        b[.roof].quad(point(c, v1 + eave1, y - eave1 * slope), point(a, v1 + eave1, y - eave1 * slope), point(a, vm, y + rise), point(c, vm, y + rise))
        if !open.contains(.back) { b[.wall].triangle(point(u0, v0, y), point(u0, v1, y), point(u0, vm, y + rise)) }
        if !open.contains(.front) { b[.wall].triangle(point(u1, v1, y), point(u1, v0, y), point(u1, vm, y + rise)) }
    }

    /// A hipped roof over `r`: four slopes, the ridge along the longer side.
    private mutating func hip(_ r: Rect, y: Float, pitch: Float) {
        let over: Float = freeSides(r).allSatisfy { $0 } ? 0.35 : 0
        let alongX = r.size.x >= r.size.y
        let (u0, u1, v0, v1) = alongX ? (r.lo.x - over, r.hi.x + over, r.lo.y - over, r.hi.y + over)
                                      : (r.lo.y - over, r.hi.y + over, r.lo.x - over, r.hi.x + over)
        func point(_ u: Float, _ v: Float, _ h: Float) -> SIMD3<Float> { alongX ? SIMD3(u, h, v) : SIMD3(v, h, u) }
        let halfSpan = (v1 - v0) / 2, vm = (v0 + v1) / 2
        let eave = y - over * pitch, ridge = eave + halfSpan * pitch
        let ra = u0 + halfSpan, rc = u1 - halfSpan   // the ridge's ends
        b[.roof].quad(point(u0, v0, eave), point(u1, v0, eave), point(rc, vm, ridge), point(ra, vm, ridge))
        b[.roof].quad(point(u1, v1, eave), point(u0, v1, eave), point(ra, vm, ridge), point(rc, vm, ridge))
        b[.roof].triangle(point(u0, v1, eave), point(u0, v0, eave), point(ra, vm, ridge))
        b[.roof].triangle(point(u1, v0, eave), point(u1, v1, eave), point(rc, vm, ridge))
        if over == 0 { return }
        // The eaves' underside, where they overhang the walls.
        b[.trim].floor(x0: r.lo.x - over, x1: r.hi.x + over, z0: r.lo.y - over, z1: r.lo.y, y: eave, up: false)
        b[.trim].floor(x0: r.lo.x - over, x1: r.hi.x + over, z0: r.hi.y, z1: r.hi.y + over, y: eave, up: false)
        b[.trim].floor(x0: r.lo.x - over, x1: r.lo.x, z0: r.lo.y, z1: r.hi.y, y: eave, up: false)
        b[.trim].floor(x0: r.hi.x, x1: r.hi.x + over, z0: r.lo.y, z1: r.hi.y, y: eave, up: false)
    }

    /// A mansard over `r`: steep slopes on the free sides up to a flat top one storey higher, walls on the others,
    /// and a dormer for each of the front's bays.
    private mutating func mansard(_ r: Rect, y: Float) {
        let free = freeSides(r), rise: Float = 2.7, lean: Float = 1.0
        let inner = Rect(lo: r.lo + SIMD2(free[3] ? lean : 0, free[2] ? lean : 0), hi: r.hi - SIMD2(free[1] ? lean : 0, free[0] ? lean : 0))
        let lower = [SIMD2(r.lo.x, r.lo.y), SIMD2(r.lo.x, r.hi.y), SIMD2(r.hi.x, r.hi.y), SIMD2(r.hi.x, r.lo.y)]
        let upper = [SIMD2(inner.lo.x, inner.lo.y), SIMD2(inner.lo.x, inner.hi.y), SIMD2(inner.hi.x, inner.hi.y), SIMD2(inner.hi.x, inner.lo.y)]
        let sides = [free[3], free[0], free[1], free[2]]   // the loop's edges: left, front, right, back
        for i in 0..<4 {
            let k = (i + 1) % 4
            b[sides[i] ? .roof : .wall].quad([lower[i].x, y, lower[i].y], [lower[k].x, y, lower[k].y],
                                              [upper[k].x, y + rise, upper[k].y], [upper[i].x, y + rise, upper[i].y])
        }
        b[.roof].floor(x0: inner.lo.x, x1: inner.hi.x, z0: inner.lo.y, z1: inner.hi.y, y: y + rise)
        guard free[0] else { return }
        // Dormers along the front: a box that stands out of the slope with a window in its face.
        let count = max(1, Int((r.size.x - 2) / max(style.bay * 1.5, 3)))
        for k in 0..<count {
            let cx = r.lo.x + r.size.x * (Float(k) + 0.5) / Float(count)
            let x0 = cx - 0.65, x1 = cx + 0.65, y0 = y + 0.5, y1 = y + 2.0, face = r.hi.y - 0.35
            b[.trim].box([x0, y0, inner.hi.y - 0.3], [x1, y1, face], faces: [.left, .right, .top])
            let o = Opening(x0: x0 + 0.12, x1: x1 - 0.12, y0: y0 + 0.15, y1: y1 - 0.12)
            // Its face, cut around the window; the glass and the dark behind it.
            b[.trim].wall(x0: x0, x1: o.x0, y0: y0, y1: y1, z: face)
            b[.trim].wall(x0: o.x1, x1: x1, y0: y0, y1: y1, z: face)
            b[.trim].wall(x0: o.x0, x1: o.x1, y0: y0, y1: o.y0, z: face)
            b[.trim].wall(x0: o.x0, x1: o.x1, y0: o.y1, y1: y1, z: face)
            b[.trim].box([o.x0, o.y0, face - 0.2], [o.x1, o.y1, face], faces: [.left, .right, .top, .bottom])
            b[.glass].wall(x0: o.x0, x1: o.x1, y0: o.y0, y1: o.y1, z: face - 0.1)
            b[.dark].wall(x0: o.x0, x1: o.x1, y0: o.y0, y1: o.y1, z: face - 0.2)
        }
    }

    /// One or two chimneys through a pitched roof over `r`, near its ridge.
    private mutating func chimneys(_ r: Rect, y: Float, rise: Float, alongX: Bool) {
        guard style.chimneys > 0, rng.next() < style.chimneys else { return }
        for _ in 0..<(1 + rng.int(2)) {
            let t = rng.range(0.15, 0.85), off = rng.range(-0.8, 0.8)
            let c = alongX ? SIMD2(r.lo.x + r.size.x * t, r.center.y + off) : SIMD2(r.center.x + off, r.lo.y + r.size.y * t)
            let w: Float = rng.range(0.25, 0.4), height = y + max(rise, 1.5) + rng.range(0.5, 1.0)
            b[.wall].box([c.x - w, y - 0.3, c.y - w], [c.x + w, height, c.y + w], faces: [.sides])
            b[.trim].box([c.x - w - 0.06, height, c.y - w - 0.06], [c.x + w + 0.06, height + 0.12, c.y + w + 0.06])
        }
    }

    // MARK: - On a flat roof

    /// What stands on a flat roof: the stair's head, air handlers, a water tank, a mast. Each on free roof, clear of
    /// the parapet, of the tier above and of the others.
    private mutating func rooftop(_ tier: BuildingTier, under next: Footprint?) {
        let plan = tier.footprint, top = tier.top
        var taken: [Rect] = []
        /// A free place for something `size` big, or nil after a few tries.
        func place(_ size: SIMD2<Float>) -> Rect? {
            for _ in 0..<12 {
                let within = plan.cover[rng.int(plan.cover.count)].inset(1.2)
                guard within.size.x > size.x, within.size.y > size.y else { continue }
                let lo = SIMD2(rng.range(within.lo.x, within.hi.x - size.x), rng.range(within.lo.y, within.hi.y - size.y))
                let r = Rect(lo: lo, hi: lo + size)
                if let next, next.rect.inset(-0.8).overlaps(r) { continue }
                if taken.contains(where: { $0.inset(-0.5).overlaps(r) }) { continue }
                taken.append(r)
                return r
            }
            return nil
        }
        let topmost = next == nil
        let area = plan.area
        let h: Float = rng.range(2.4, 2.9)
        if topmost, let stair = self.plan.storeys.last?.stair?.rect {
            // The stair's head: a small house over the stair, with its own roof slab.
            let r = Rect(lo: stair.lo - SIMD2(0.2, 0.2), hi: stair.hi + SIMD2(0.2, 0.2))
            taken.append(r)
            b[.wall].box([r.lo.x, top, r.lo.y], [r.hi.x, top + h, r.hi.y], faces: [.sides])
            b[.trim].box([r.lo.x - 0.15, top + h, r.lo.y - 0.15], [r.hi.x + 0.15, top + h + 0.15, r.hi.y + 0.15])
        }
        for _ in 0..<min(1 + Int(area / 120), 6) {
            // Air handlers: a metal box with a fan on it.
            guard let r = place(SIMD2(rng.range(1.2, 2.6), rng.range(1.0, 1.8))) else { break }
            let h: Float = rng.range(0.9, 1.7)
            b[.metal].box([r.lo.x, top + 0.15, r.lo.y], [r.hi.x, top + 0.15 + h, r.hi.y], faces: [.sides, .top])
            b[.metal].cylinder([r.center.x, top + 0.15 + h, r.center.y], radius: min(r.size.x, r.size.y) * 0.32, height: 0.18, segments: 10)
        }
        if topmost && rng.next() < style.waterTank, let r = place(SIMD2(3, 3)) {
            // A water tank on legs, with a conical lid.
            let c = SIMD3<Float>(r.center.x, top, r.center.y), legs: Float = rng.range(1.6, 2.4), radius: Float = 1.25
            for (dx, dz) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
                let p = c + SIMD3(dx, 0, dz) * 0.8
                b[.metal].box(p - [0.06, 0, 0.06], p + [0.06, legs, 0.06], faces: [.sides])
            }
            b[.accent].cylinder(c + [0, legs, 0], radius: radius, height: 2.2, segments: 14, cap: false)
            b[.accent].cylinder(c + [0, legs + 2.2, 0], radius: radius + 0.08, topRadius: 0.05, height: 0.7, segments: 14)
            b[.accent].floor(x0: c.x - radius * 0.7, x1: c.x + radius * 0.7, z0: c.z - radius * 0.7, z1: c.z + radius * 0.7, y: legs + top, up: false)
        }
        if topmost && rng.next() < style.mast, let r = place(SIMD2(1.2, 1.2)) {
            // A mast.
            let h: Float = rng.range(8, 18)
            b[.metal].cylinder([r.center.x, top, r.center.y], radius: 0.14, topRadius: 0.04, height: h, segments: 6)
            for t: Float in [0.55, 0.75] {
                b[.metal].box([r.center.x - 0.6, top + h * t, r.center.y - 0.03], [r.center.x + 0.6, top + h * t + 0.05, r.center.y + 0.03])
            }
        }
    }
}
