import Foundation
import simd

extension GarmentBuild {
    /// A drape carried from an earlier build of the garment (an edit's): each particle where the old panel's cloth
    /// was at its place on the sheet (inside one of the old panel's triangles, or at the nearest of them), NaN for a
    /// panel the old build hadn't. `positions` the old build's particles' places.
    package func carry(from old: GarmentBuild, positions: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let missing = SIMD3<Float>(repeating: .nan)
        var out = [SIMD3<Float>](repeating: missing, count: particleCount)
        guard positions.count == old.particleCount else { return out }
        for (pi, id) in panelIDs.enumerated() {
            guard let oi = old.panelIDs.firstIndex(of: id) else { continue }
            let tris = old.panelTriangles[oi]
            guard !tris.isEmpty else { continue }
            // The old panel's triangles binned by their boxes on the sheet.
            let cell: Float = 0.05
            var bins: [SIMD2<Int32>: [Int]] = [:]
            func key(_ p: SIMD2<Float>) -> SIMD2<Int32> { SIMD2(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down))) }
            for t in tris {
                let a = old.rest2D[Int(old.triangles[3 * t])], b = old.rest2D[Int(old.triangles[3 * t + 1])], c = old.rest2D[Int(old.triangles[3 * t + 2])]
                let lo = key(simd_min(simd_min(a, b), c)), hi = key(simd_max(simd_max(a, b), c))
                for y in lo.y...hi.y { for x in lo.x...hi.x { bins[SIMD2(x, y), default: []].append(t) } }
            }
            // The old panel's origin on the sheet against the new one's (a panel moved on the sheet carries its drape).
            let shift = centre(oi, old) - centre(pi, self)
            let first = panelFirst[pi]
            for i in first..<(first + panelCount[pi]) {
                let q = rest2D[i] + shift
                var best: (t: Int, w: SIMD3<Float>, d: Float)?
                for ring in 0...3 {
                    let k = key(q)
                    for y in (k.y - Int32(ring))...(k.y + Int32(ring)) {
                        for x in (k.x - Int32(ring))...(k.x + Int32(ring)) {
                            for t in bins[SIMD2(x, y)] ?? [] {
                                let a = old.rest2D[Int(old.triangles[3 * t])], b = old.rest2D[Int(old.triangles[3 * t + 1])],
                                    c = old.rest2D[Int(old.triangles[3 * t + 2])]
                                let w = barycentric(q, a, b, c)
                                // Outside by how much: the most negative weight.
                                let d = -min(0, min(w.x, min(w.y, w.z)))
                                if best == nil || d < best!.d { best = (t, w, d) }
                            }
                        }
                    }
                    if let b = best, b.d < 1e-4 { break }
                }
                guard let b = best else { continue }
                var w = simd_max(b.w, .zero)
                w /= max(1e-6, w.x + w.y + w.z)
                let ia = Int(old.triangles[3 * b.t]), ib = Int(old.triangles[3 * b.t + 1]), ic = Int(old.triangles[3 * b.t + 2])
                out[i] = positions[ia] * w.x + positions[ib] * w.y + positions[ic] * w.z
            }
        }
        return out
    }

    private func centre(_ pi: Int, _ b: GarmentBuild) -> SIMD2<Float> {
        var lo = SIMD2<Float>(repeating: .infinity), hi = -lo
        for i in b.panelFirst[pi]..<(b.panelFirst[pi] + b.panelCount[pi]) { lo = simd_min(lo, b.rest2D[i]); hi = simd_max(hi, b.rest2D[i]) }
        return (lo + hi) / 2
    }

    private func barycentric(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> SIMD3<Float> {
        let v0 = b - a, v1 = c - a, v2 = p - a
        let d = v0.x * v1.y - v1.x * v0.y
        guard abs(d) > 1e-12 else { return SIMD3(1, 0, 0) }
        let v = (v2.x * v1.y - v1.x * v2.y) / d, w = (v0.x * v2.y - v2.x * v0.y) / d
        return SIMD3(1 - v - w, v, w)
    }
}
