import Foundation
import simd

/// Charts' rectangles into the square of a texture set, on a skyline (each, tallest first, where it lies lowest:
/// bottom-left), at the largest scale they fit at (a binary search). Each keeps a gutter of `padding` texels all round
/// (twice that between two), which the painting dilates into so that filtering and the first mip levels never read
/// past a chart's edge.
enum UVPack {
    /// Where each chart's rectangle (from 0, in metres) goes, in texels: `origins[i] + uv x scale`, its UVs first
    /// turned a quarter (`(x, y) -> (h - y, x)`, h its height) where `turned[i]`.
    struct Result {
        var scale: Float              // texels per metre
        var origins: [SIMD2<Float>]
        var padding: Int
        var turned: [Bool] = []
    }

    static func pack(_ sizes: [SIMD2<Float>], resolution: Int, padding: Int) -> Result {
        let order = sizes.indices.sorted { sizes[$0].y > sizes[$1].y || (sizes[$0].y == sizes[$1].y && $0 < $1) }   // (all lie down)
        var pad = padding
        // So many charts that their gutters alone don't fit: narrower gutters.
        while pad > 1 && sizes.count * (2 * pad + 1) * (2 * pad + 1) > resolution * resolution / 2 { pad /= 2 }
        let r = resolution
        var area: Float = 0, widest: Float = 0
        for s in sizes { area += s.x * s.y; widest = max(widest, s.x, s.y) }
        var lo: Float = 0
        var hi = min((Float(r) - 2 * Float(pad)) / max(widest, 1e-12), Float(r) / max(area.squareRoot(), 1e-12))
        var best = place(sizes, order, scale: 0, resolution: r, pad: pad) ?? ([], [])
        if let all = place(sizes, order, scale: hi, resolution: r, pad: pad) { return Result(scale: hi, origins: all.0, padding: pad, turned: all.1) }
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if let o = place(sizes, order, scale: mid, resolution: r, pad: pad) { lo = mid; best = o } else { hi = mid }
            if hi - lo < hi * 0.002 { break }
        }
        return Result(scale: lo, origins: best.0.isEmpty ? [SIMD2<Float>](repeating: .zero, count: sizes.count) : best.0, padding: pad,
                      turned: best.1.isEmpty ? [Bool](repeating: false, count: sizes.count) : best.1)
    }

    /// The charts on the skyline at `scale`, or nil if they don't fit. The skyline: segments (x, width, height) left
    /// to right; a rectangle goes where the highest segment under it is lowest (then leftmost), lying or standing,
    /// whichever lies lower.
    private static func place(_ sizes: [SIMD2<Float>], _ order: [Int], scale: Float, resolution r: Int, pad: Int) -> ([SIMD2<Float>], [Bool])? {
        var origins = [SIMD2<Float>](repeating: .zero, count: sizes.count)
        var turned = [Bool](repeating: false, count: sizes.count)
        var sky: [(x: Int, w: Int, y: Int)] = [(0, r, 0)]
        for i in order {
            let lying = (Int((sizes[i].x * scale).rounded(.up)) + 2 * pad, Int((sizes[i].y * scale).rounded(.up)) + 2 * pad)
            var bestY = Int.max, bestX = 0, bestJ = -1, w = 0, h = 0, bestTurn = false
            for turn in [false, true] {
                let (cw, ch) = turn ? (lying.1, lying.0) : lying
                if cw > r || ch > r { continue }
                for j in sky.indices {
                    let x = sky[j].x
                    guard x + cw <= r else { break }
                    var y = 0, k = j, covered = 0
                    while covered < cw {
                        y = max(y, sky[k].y)
                        covered += sky[k].x + sky[k].w - max(x, sky[k].x)
                        if covered < cw { k += 1 }
                    }
                    if y + ch <= r && (y + ch < bestY + h || (y + ch == bestY + h && x < bestX) || bestJ < 0) {
                        bestY = y; bestX = x; bestJ = j; w = cw; h = ch; bestTurn = turn
                    }
                }
            }
            guard bestJ >= 0 else { return nil }
            origins[i] = SIMD2(Float(bestX + pad), Float(bestY + pad))
            turned[i] = bestTurn
            // The skyline: the new segment over [x, x + w), what is left of the ones it covers.
            let top = bestY + h, end = bestX + w
            var next: [(x: Int, w: Int, y: Int)] = []
            for s in sky {
                let sEnd = s.x + s.w
                if sEnd <= bestX || s.x >= end { next.append(s); continue }
                if s.x < bestX { next.append((s.x, bestX - s.x, s.y)) }
                if sEnd > end { next.append((end, sEnd - end, s.y)) }
            }
            next.append((bestX, w, top))
            next.sort { $0.x < $1.x }
            // Neighbours at one height are one segment.
            var merged: [(x: Int, w: Int, y: Int)] = []
            for s in next {
                if let l = merged.last, l.y == s.y, l.x + l.w == s.x { merged[merged.count - 1].w += s.w } else { merged.append(s) }
            }
            sky = merged
        }
        return (origins, turned)
    }
}
