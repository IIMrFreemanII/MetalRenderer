import Foundation
import simd

/// Where each panel's outline is sampled: every edge at about the garment's spacing, and the stretches a seam sews
/// at the same count on both sides (a 1:1 seam's samples meet one for one; an N:1 seam's long side gets its short
/// sides' counts together). Each edge's samples are fractions of its length from its start, its end left to the next.
package enum SeamSampling {
    package static func samples(_ g: Garment, panels: [Panel]) -> [[[Float]]] {
        // Each sewn stretch's sample count, by (panel, edge, its two ends).
        var counts: [Key: Int] = [:]
        for seam in g.seams {
            let la = seam.a.map { length(g, $0) }, lb = seam.b.map { length(g, $0) }
            let ta = la.reduce(0, +), tb = lb.reduce(0, +)
            guard ta > 0, tb > 0 else { continue }
            let d = spacing(g, seam.a.first?.panel ?? 0)
            let total = max(1, Int((max(ta, tb) / d).rounded(.up)))
            func assign(_ ends: [SeamEnd], _ lengths: [Float], _ sum: Float) {
                for (k, e) in ends.enumerated() {
                    counts[Key(e)] = max(1, Int((Float(total) * lengths[k] / sum).rounded()))
                }
            }
            assign(seam.a, la, ta)
            assign(seam.b, lb, tb)
        }
        return panels.map { p in
            let d = spacing(g, p.id)
            return p.points.indices.map { e -> [Float] in
                let curve = p.edge(e)
                // The edge's breaks: its ends and its seams' ends.
                var breaks: [Float] = [0, 1]
                var sewn: [(lo: Float, hi: Float, count: Int)] = []
                for (key, n) in counts where key.panel == p.id && key.edge == e {
                    breaks += [key.lo, key.hi]
                    sewn.append((key.lo, key.hi, n))
                }
                breaks = Array(Set(breaks.map { max(0, min(1, $0)) })).sorted()
                var fs: [Float] = []
                for k in 0..<(breaks.count - 1) {
                    let lo = breaks[k], hi = breaks[k + 1]
                    guard hi - lo > 1e-5 else { continue }
                    let n = sewn.first(where: { abs($0.lo - lo) < 1e-5 && abs($0.hi - hi) < 1e-5 })?.count
                        ?? max(1, Int(((hi - lo) * curve.length / d).rounded(.up)))
                    for i in 0..<n { fs.append(lo + (hi - lo) * Float(i) / Float(n)) }
                }
                return fs
            }
        }
    }

    /// The spacing of panel `id`'s mesh.
    package static func spacing(_ g: Garment, _ id: Int) -> Float {
        max(0.004, g.panel(id: id)?.particleDistance ?? g.particleDistance)
    }

    /// A seam end's length (metres).
    package static func length(_ g: Garment, _ e: SeamEnd) -> Float {
        guard let p = g.panel(id: e.panel), p.points.indices.contains(e.edge) else { return 0 }
        return p.edge(e.edge).length * abs(e.t1 - e.t0)
    }

    struct Key: Hashable {
        let panel: Int, edge: Int
        let lo: Float, hi: Float
        init(_ e: SeamEnd) { panel = e.panel; edge = e.edge; lo = min(e.t0, e.t1); hi = max(e.t0, e.t1) }
    }
}
