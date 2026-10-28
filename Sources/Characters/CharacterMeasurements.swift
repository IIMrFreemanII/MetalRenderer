import Foundation
import simd

/// A body's measurements as a tailor takes them (metres): girths round the chest, waist, hips, thigh, neck and arm,
/// lengths and heights, from its mesh and skeleton in the bind pose. The garment templates are graded to them
/// (GarmentTemplate.params).
package struct BodyMeasurements: Codable, Equatable {
    package var height: Float = 1.79
    package var chest: Float = 1.0
    package var waist: Float = 0.86
    package var hips: Float = 1.0
    package var neck: Float = 0.39
    package var thigh: Float = 0.57
    package var upperArm: Float = 0.32
    package var shoulderWidth: Float = 0.44
    package var armLength: Float = 0.6
    package var shoulderHeight: Float = 1.46
    package var neckHeight: Float = 1.53
    package var chestHeight: Float = 1.3
    package var waistHeight: Float = 1.08
    package var hipHeight: Float = 0.95
    package var crotchHeight: Float = 0.82
    package var kneeHeight: Float = 0.5
    package var ankleHeight: Float = 0.08

    package init() {}

    /// The body of `c` in its bind pose.
    package static func measure(_ c: SkinnedCharacter) -> BodyMeasurements {
        var m = BodyMeasurements()
        let poses = c.bindPoses
        func joint(_ name: String) -> SIMD3<Float>? { CharacterBase.joint(name, in: c).map { poses[$0].t } }
        let p = c.positions
        guard !p.isEmpty else { return m }
        m.height = p.reduce(-Float.infinity) { max($0, $1.y) } - p.reduce(Float.infinity) { min($0, $1.y) }
        if let l = joint("LeftArm"), let r = joint("RightArm") {
            m.shoulderHeight = (l.y + r.y) / 2
            m.shoulderWidth = simd_distance(l, r) * 1.12
        }
        if let a = joint("LeftArm"), let h = joint("LeftHand") { m.armLength = simd_distance(a, h) }
        if let n = joint("Neck") { m.neckHeight = n.y }
        if let s = joint("Spine2") { m.chestHeight = s.y }
        if let s = joint("Spine1") { m.waistHeight = s.y - 0.02 }
        if let h = joint("Hips") { m.hipHeight = h.y - 0.04 }
        if let k = joint("LeftLeg") { m.kneeHeight = k.y }
        if let f = joint("LeftFoot") { m.ankleHeight = f.y }
        // The crotch: the lowest point between the legs above the knees.
        let between = p.filter { abs($0.x) < 0.02 && $0.y > m.kneeHeight + 0.1 && $0.y < m.hipHeight + 0.05 }
        if let low = between.map(\.y).min() { m.crotchHeight = low }
        // Girths: round the trunk's slice at a height (the arms left out), round one leg's, the neck's.
        let half = m.shoulderWidth / 2 * 0.82
        m.chest = girth(p, at: m.chestHeight, keep: { abs($0.x) < half }) ?? m.chest
        m.waist = girth(p, at: m.waistHeight, keep: { abs($0.x) < half }) ?? m.waist
        m.hips = girth(p, at: m.hipHeight, keep: { abs($0.x) < half * 1.2 }) ?? m.hips
        m.thigh = girth(p, at: m.crotchHeight - 0.05, keep: { $0.x > 0.005 }) ?? m.thigh
        // The neck above the shoulders' slope (round it, nothing but the neck within 7 cm of the middle).
        let neckY = m.neckHeight + 0.04
        m.neck = min(0.5, girth(p, at: neckY, keep: { abs($0.x) < 0.07 && abs($0.z - (joint("Neck")?.z ?? 0)) < 0.08 }) ?? m.neck)
        if let a = joint("LeftArm"), let e = joint("LeftForeArm") {
            // Round the upper arm, across its axis halfway along it.
            let axis = simd_normalize(e - a), mid = (a + e) / 2
            let ring = p.filter { abs(simd_dot($0 - mid, axis)) < 0.01 && simd_distance($0, mid) < 0.12 }
            var u = simd_cross(axis, SIMD3(0, 0, 1))
            if simd_length(u) < 0.1 { u = simd_cross(axis, SIMD3(0, 1, 0)) }
            u = simd_normalize(u)
            let v = simd_cross(axis, u)
            if ring.count >= 3 { m.upperArm = hullPerimeter(ring.map { SIMD2(simd_dot($0 - mid, u), simd_dot($0 - mid, v)) }) }
        }
        return m
    }

    /// The length round the convex hull of the mesh's points within a centimetre of height `y` that `keep` keeps.
    static func girth(_ p: [SIMD3<Float>], at y: Float, keep: (SIMD3<Float>) -> Bool) -> Float? {
        let slice = p.filter { abs($0.y - y) < 0.01 && keep($0) }.map { SIMD2($0.x, $0.z) }
        guard slice.count >= 3 else { return nil }
        let g = hullPerimeter(slice)
        return g > 0.05 ? g : nil
    }

    /// The perimeter of the points' convex hull (monotone chain).
    package static func hullPerimeter(_ pts: [SIMD2<Float>]) -> Float {
        let s = pts.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard s.count >= 3 else { return 0 }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [SIMD2<Float>] = [], upper: [SIMD2<Float>] = []
        for q in s {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in s.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        let hull = Array(lower.dropLast() + upper.dropLast())
        var len: Float = 0
        for i in hull.indices { len += simd_distance(hull[i], hull[(i + 1) % hull.count]) }
        return len
    }
}
