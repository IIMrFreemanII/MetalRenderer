import Foundation
import simd

/// Whether a mesh's own UVs can hold a painted texture set: every point of it at a texel of its own. If not, the
/// painter unwraps it (UVUnwrap).
enum UVCheck {
    enum Verdict: String, Codable {
        case good
        case missing        // all zeros: the generated meshes'
        case degenerate     // triangles of no UV area (a planar or partial mapping)
        case tiled          // UVs past 0...1: a pattern repeated (the workshop's shapes, a building's walls)
        case overlapping    // two places at one texel: mirrored halves, stacked pieces
    }

    /// The verdict, on a coverage raster of `raster` squared (a texel's centre is in a triangle strictly inside its
    /// edges, so neighbours sharing an edge are never both at it).
    static func verdict(_ mesh: PaintMesh, raster: Int = 512) -> Verdict {
        let n = mesh.triangleCount
        guard n > 0, mesh.uvs.contains(where: { $0 != .zero }) else { return .missing }
        var zero = 0, outsideArea: Float = 0, totalArea: Float = 0
        for t in 0..<n {
            let (a, b, c) = mesh.corners(t)
            let ua = mesh.uvs[a], ub = mesh.uvs[b], uc = mesh.uvs[c]
            let area = abs(cross2(ub - ua, uc - ua)) / 2
            if area < 1e-10 { zero += 1; continue }
            totalArea += area
            let lo = simd_min(ua, simd_min(ub, uc)), hi = simd_max(ua, simd_max(ub, uc))
            if simd_reduce_min(lo) < -1e-4 || simd_reduce_max(hi) > 1 + 1e-4 { outsideArea += area }
        }
        if Float(zero) > 0.01 * Float(n) { return .degenerate }
        if outsideArea > 0.01 * totalArea { return .tiled }
        var hits = [UInt8](repeating: 0, count: raster * raster)
        var covered = 0, twice = 0
        let size = Float(raster)
        for t in 0..<n {
            let (a, b, c) = mesh.corners(t)
            var p0 = mesh.uvs[a] * size, p1 = mesh.uvs[b] * size
            let p2 = mesh.uvs[c] * size
            if cross2(p1 - p0, p2 - p0) < 0 { swap(&p0, &p1) }
            let lo = simd_max(SIMD2<Int>(simd_min(p0, simd_min(p1, p2)).rounded(.down)), .zero)
            let hi = simd_min(SIMD2<Int>(simd_max(p0, simd_max(p1, p2)).rounded(.up)), SIMD2(repeating: raster - 1))
            guard lo.x <= hi.x, lo.y <= hi.y else { continue }
            for y in lo.y...hi.y {
                for x in lo.x...hi.x {
                    let q = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                    guard cross2(p1 - p0, q - p0) > 0, cross2(p2 - p1, q - p1) > 0, cross2(p0 - p2, q - p2) > 0 else { continue }
                    let i = y * raster + x
                    if hits[i] == 0 { covered += 1 } else if hits[i] == 1 { twice += 1 }
                    hits[i] = min(hits[i], 254) + 1
                }
            }
        }
        return Float(twice) > 0.005 * Float(max(covered, 1)) ? .overlapping : .good
    }

    @inline(__always) static func cross2(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
}
