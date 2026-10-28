import Foundation
import simd

/// The pattern as a flat DXF (R12, millimetres) for a plotter or a cutter: each panel's sewing line (SEAM), its cutting
/// line with the seam allowance round it (CUT), its internal lines (INTERNAL), its grain line (GRAIN), and notches
/// where its seams start and end (NOTCH), with its name (TEXT).
package enum DXFWriter {
    package static func write(_ g: Garment, allowance: Float = 0.01) -> String {
        var out = "0\nSECTION\n2\nHEADER\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n"
        out += "0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n70\n6\n"
        for (name, colour) in [("CUT", 7), ("SEAM", 1), ("INTERNAL", 5), ("GRAIN", 3), ("NOTCH", 2), ("TEXT", 7)] {
            out += "0\nLAYER\n2\n\(name)\n70\n0\n62\n\(colour)\n6\nCONTINUOUS\n"
        }
        out += "0\nENDTAB\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n"
        func mm(_ v: Float) -> String { String(format: "%.3f", v * 1000) }
        func polyline(_ pts: [SIMD2<Float>], layer: String, closed: Bool) {
            out += "0\nPOLYLINE\n8\n\(layer)\n66\n1\n70\n\(closed ? 1 : 0)\n"
            for p in pts { out += "0\nVERTEX\n8\n\(layer)\n10\n\(mm(p.x))\n20\n\(mm(p.y))\n" }
            out += "0\nSEQEND\n8\n\(layer)\n"
        }
        func line(_ a: SIMD2<Float>, _ b: SIMD2<Float>, layer: String) {
            out += "0\nLINE\n8\n\(layer)\n10\n\(mm(a.x))\n20\n\(mm(a.y))\n11\n\(mm(b.x))\n21\n\(mm(b.y))\n"
        }
        for p in g.panels where !p.hidden {
            let outline = p.outline
            polyline(outline, layer: "SEAM", closed: true)
            polyline(allowance > 0 ? p.allowance(allowance) : outline, layer: "CUT", closed: true)
            for l in p.lines { polyline(l.points, layer: "INTERNAL", closed: false) }
            // The grain: an arrow through the middle, two fifths of the panel long.
            let c = p.centre, size = simd_length(p.bounds.hi - p.bounds.lo) * 0.2
            let d = SIMD2<Float>(cos(p.grain), sin(p.grain)) * size, side = SIMD2(-d.y, d.x) * 0.15
            line(c - d, c + d, layer: "GRAIN")
            line(c + d, c + d * 0.8 + side, layer: "GRAIN")
            line(c + d, c + d * 0.8 - side, layer: "GRAIN")
            out += "0\nTEXT\n8\nTEXT\n10\n\(mm(c.x))\n20\n\(mm(c.y - size * 0.3))\n40\n\(mm(0.012))\n1\n\(p.name)\n"
        }
        // Notches: a short cut inwards at each seam stretch's ends.
        for seam in g.seams {
            for e in seam.a + seam.b {
                guard let p = g.panel(id: e.panel), p.points.indices.contains(e.edge) else { continue }
                let curve = p.edge(e.edge)
                for t in [e.t0, e.t1] {
                    let q = curve.point(at: t), tan = curve.tangent(at: t)
                    let inward = SIMD2(-tan.y, tan.x)
                    line(q - inward * allowance, q + inward * 0.004, layer: "NOTCH")
                }
            }
        }
        out += "0\nENDSEC\n0\nEOF\n"
        return out
    }
}
