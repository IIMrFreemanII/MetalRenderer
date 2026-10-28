import Foundation
import simd

extension AvatarFrame {
    /// A loop drawn on the body (`points`, in order round it) flattened into a panel's outline: unwrapped from the
    /// cylinder of the slot it is on (the arrangement's mapping run backwards: round the cylinder is across the sheet,
    /// along it is up), so that the panel goes back where it was drawn. Returns the outline about its middle and the
    /// arrangement that puts it there.
    package func flatten(_ points: [SIMD3<Float>]) -> (outline: [SIMD2<Float>], arrangement: Arrangement)? {
        guard points.count >= 3 else { return nil }
        let mid = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        let m = measurements
        let slot: ArrangementSlot
        if abs(mid.x) > m.shoulderWidth / 2 && mid.y > m.chestHeight - 0.1 { slot = mid.x > 0 ? .armLeft : .armRight }
        else if mid.y < m.crotchHeight { slot = mid.x > 0 ? (mid.z >= 0 ? .legLeftFront : .legLeftBack) : (mid.z >= 0 ? .legRightFront : .legRightBack) }
        else if mid.y > m.neckHeight + 0.08 { slot = .head }
        else if mid.y < m.waistHeight - 0.05 { slot = mid.z >= 0 ? .hipsFront : .hipsBack }
        else { slot = mid.z >= 0 ? .chestFront : .chestBack }
        guard let s = slots[slot] else { return nil }
        // Each point round the axis (its angle from the facing side times its distance out) and along it.
        var uv: [SIMD2<Float>] = []
        for p in points {
            let along: Float
            let base: SIMD3<Float>
            if s.upright {
                let t = abs(s.axis.y) > 1e-3 ? (p.y - s.origin.y) / s.axis.y : 0
                base = s.origin + s.axis * t
                along = p.y
            } else {
                along = simd_dot(p - s.origin, s.axis)
                base = s.origin + s.axis * along
            }
            let d = p - base
            let r = max(0.02, simd_length(d - s.axis * simd_dot(d, s.axis)))
            let theta = atan2(simd_dot(d, s.side), simd_dot(d, s.facing))
            uv.append(SIMD2(theta * r, along))
        }
        // Counter-clockwise on the sheet.
        if Polygon2D.signedArea(uv) < 0 { uv.reverse() }
        var lo = SIMD2<Float>(repeating: .infinity), hi = -lo
        for q in uv { lo = simd_min(lo, q); hi = simd_max(hi, q) }
        let centre = (lo + hi) / 2
        var a = Arrangement(slot: slot, offset: centre)
        a.clearance = 0.045
        return (uv.map { $0 - centre }, a)
    }
}
