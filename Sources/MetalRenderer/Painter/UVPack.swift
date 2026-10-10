import Foundation
import simd

/// Charts into the square of a texture set by their outlines, not their boxes ("Tetris" packing, as in Lévy et al.'s
/// LSCM paper): the square keeps a horizon (per column of `padding` texels, how high it is filled), and each chart,
/// largest first, drops from above in whichever of its four quarter turns and wherever across it comes to rest best
/// (its outline's underside on the horizon, so a chart's notch takes another's bump): its top lowest, the room it
/// leaves under it counted against it; at the largest scale they all fit at (a binary search). Each keeps a gutter of `padding` texels all round (at least twice that between two),
/// which the painting dilates into so that filtering and the first mip levels never read past a chart's edge.
enum UVPack {
    /// Where each chart goes, in texels: `origins[i] + turn(uv, turns[i]) x scale`, `turn` a quarter turn
    /// `(x, y) -> (-y, x)` (the winding kept) `turns[i]` times.
    struct Result {
        var scale: Float              // texels per metre
        var origins: [SIMD2<Float>]
        var padding: Int
        var turns: [Int] = []
    }

    static func turn(_ p: SIMD2<Float>, _ times: Int) -> SIMD2<Float> {
        switch times & 3 {
        case 1: return SIMD2(-p.y, p.x)
        case 2: return -p
        case 3: return SIMD2(p.y, -p.x)
        default: return p
        }
    }

    /// `charts`: each chart's triangles' corners (3 a triangle, in metres).
    static func pack(_ charts: [[SIMD2<Float>]], resolution: Int, padding: Int) -> Result {
        var pad = padding
        // So many charts that their gutters alone don't fit: narrower gutters.
        while pad > 1 && charts.count * (2 * pad + 1) * (2 * pad + 1) > resolution * resolution / 2 { pad /= 2 }
        let shapes = charts.map(Shape.init)
        var area: Float = 0, widest: Float = 0
        for s in shapes { area += s.area; widest = max(widest, s.extent) }
        // Largest first (their boxes' area), then by index.
        let order = shapes.indices.sorted { shapes[$0].box > shapes[$1].box || (shapes[$0].box == shapes[$1].box && $0 < $1) }
        let r = Float(resolution)
        var lo: Float = 0
        var hi = min((r - 4 * Float(pad)) / max(widest, 1e-12), r / max(area.squareRoot(), 1e-12))
        var best: Placed?
        if let all = place(shapes, order, scale: hi, resolution: resolution, pad: pad) { return Result(scale: hi, origins: all.origins, padding: pad, turns: all.turns) }
        // From below: a fit that leaves the square's top empty grows by about the square root of what it left (and
        // at least 1%), a miss halves the gap; within 1% of the largest that fits.
        var guess = hi * 0.6
        for _ in 0..<24 {
            if let o = place(shapes, order, scale: guess, resolution: resolution, pad: pad) {
                lo = guess
                best = o
                guess = max(guess * (r / max(o.height, 1)).squareRoot(), guess * 1.01)
            } else {
                hi = guess
                guess = lo > 0 ? (lo + hi) / 2 : guess * 0.8
            }
            if hi - lo < hi * 0.01 { break }
            if guess >= hi { guess = (lo + hi) / 2 }
        }
        if best == nil { best = place(shapes, order, scale: lo, resolution: resolution, pad: pad) }
        return Result(scale: lo, origins: best?.origins ?? [SIMD2<Float>](repeating: .zero, count: charts.count), padding: pad,
                      turns: best?.turns ?? [Int](repeating: 0, count: charts.count))
    }

    /// Where the charts went, and how high the square is filled.
    private struct Placed {
        var origins: [SIMD2<Float>]
        var turns: [Int]
        var height: Float
    }

    /// A chart's triangles (metres) in each of its four quarter turns, from 0.
    private struct Shape {
        var turned: [[SIMD2<Float>]]      // per turn: its corners, from (0, 0)
        var lows: [SIMD2<Float>]          // per turn: what was taken off to bring it to 0
        var area: Float
        var box: Float
        var extent: Float

        init(_ corners: [SIMD2<Float>]) {
            turned = []
            lows = []
            var a: Float = 0
            for t in 0..<corners.count / 3 { a += abs(UVCheck.cross2(corners[3 * t + 1] - corners[3 * t], corners[3 * t + 2] - corners[3 * t])) / 2 }
            area = a
            box = 0
            extent = 0
            for k in 0..<4 {
                let p = corners.map { UVPack.turn($0, k) }
                var lo = SIMD2<Float>(repeating: .infinity), hi = -lo
                for q in p { lo = simd_min(lo, q); hi = simd_max(hi, q) }
                if !lo.x.isFinite { lo = .zero; hi = .zero }
                turned.append(p.map { $0 - lo })
                lows.append(lo)
                if k == 0 { box = (hi.x - lo.x) * (hi.y - lo.y); extent = simd_reduce_max(hi - lo) }
            }
        }

        /// Its outline at `scale` in turn `k`, as columns of `cell` texels: per column its underside and top (texels,
        /// the gutter included: the chart's points lie from `reach` columns across and from 0 up), widened `reach`
        /// columns each side.
        func profile(_ k: Int, scale: Float, cell: Float, reach: Int, pad: Float) -> (bottom: [Float], top: [Float]) {
            let p = turned[k]
            var width: Float = 0
            for q in p { width = max(width, q.x * scale) }
            let columns = Int((width / cell).rounded(.down)) + 1   // the chart's own, from column `reach`
            var bottom = [Float](repeating: .infinity, count: columns + 2 * reach), top = [Float](repeating: -.infinity, count: columns + 2 * reach)
            for t in 0..<p.count / 3 {
                let a = p[3 * t] * scale, b = p[3 * t + 1] * scale, c = p[3 * t + 2] * scale
                let x0 = min(a.x, b.x, c.x), x1 = max(a.x, b.x, c.x)
                let c0 = Int((x0 / cell).rounded(.down)), c1 = min(Int((x1 / cell).rounded(.down)), columns - 1)
                guard c0 <= c1 else { continue }
                for col in c0...c1 {
                    // The triangle within the column's strip: its corners in it, and its edges where they cross its sides.
                    let xa = Float(col) * cell, xb = xa + cell
                    var ylo = Float.infinity, yhi = -Float.infinity
                    @inline(__always) func corner(_ v: SIMD2<Float>) {
                        if v.x >= xa && v.x <= xb { ylo = min(ylo, v.y); yhi = max(yhi, v.y) }
                    }
                    @inline(__always) func edge(_ u: SIMD2<Float>, _ v: SIMD2<Float>, _ x: Float) {
                        guard u.x != v.x else { return }
                        let s = (x - u.x) / (v.x - u.x)
                        guard s >= 0 && s <= 1 else { return }
                        let y = u.y + s * (v.y - u.y)
                        ylo = min(ylo, y); yhi = max(yhi, y)
                    }
                    corner(a); corner(b); corner(c)
                    if c0 != c1 {   // (a triangle within one column: its corners are all of it)
                        edge(a, b, xa); edge(b, c, xa); edge(c, a, xa)
                        edge(a, b, xb); edge(b, c, xb); edge(c, a, xb)
                    }
                    guard ylo <= yhi else { continue }
                    bottom[col + reach] = min(bottom[col + reach], ylo)
                    top[col + reach] = max(top[col + reach], yhi)
                }
            }
            // Widened `reach` columns each side (the gutter across), and by the gutter up and down.
            var b = bottom, tp = top
            for col in 0..<(columns + 2 * reach) {
                for n in max(col - reach, 0)...min(col + reach, columns + 2 * reach - 1) { b[col] = min(b[col], bottom[n]); tp[col] = max(tp[col], top[n]) }
            }
            for col in b.indices where b[col].isFinite {
                b[col] -= pad
                tp[col] += pad
            }
            return (b, tp)
        }
    }

    /// The charts on the horizon at `scale`, or nil if they don't fit: per chart its origin (texels) and turns.
    private static func place(_ shapes: [Shape], _ order: [Int], scale: Float, resolution: Int, pad: Int) -> Placed? {
        // Columns of half the gutter, two of them its width (between two charts' points 2 to 2.5 gutters across).
        let reach = pad >= 2 ? 2 : 1
        let cell = Float(max(pad, 1)) / Float(reach)
        let columns = Int(Float(resolution) / cell)
        let height = Float(resolution)
        var horizon = [Float](repeating: 0, count: columns)
        var origins = [SIMD2<Float>](repeating: .zero, count: shapes.count)
        var turns = [Int](repeating: 0, count: shapes.count)
        var rest = [Float](repeating: 0, count: columns), under = [Float](repeating: 0, count: columns)
        for i in order {
            var best: (score: Float, x: Int, y: Float, k: Int) = (.infinity, 0, 0, 0)
            var bestProfile: [Float] = []
            // (A chart of a few columns turned half round is much the same: its two quarter turns only.)
            for k in 0..<(shapes[i].box * scale * scale > Float(64 * pad * pad) ? 4 : 2) {
                let (bottom, top) = shapes[i].profile(k, scale: scale, cell: cell, reach: reach, pad: Float(pad))
                let w = bottom.count
                guard w <= columns else { continue }
                var topMax: Float = 0
                for c in 0..<w where top[c].isFinite { topMax = max(topMax, top[c]) }
                // Every position across at once, column by column of the chart (loops the compiler vectorises): where
                // it comes to rest (the highest of the horizon less its underside), and the room under it (its
                // columns' rest height and underside, less the horizon under them: a sum over them).
                let n = columns - w + 1
                rest.withUnsafeMutableBufferPointer { y in
                    under.withUnsafeMutableBufferPointer { sum in
                        horizon.withUnsafeBufferPointer { h in
                            for x in 0..<n { y[x] = 0; sum[x] = 0 }
                            var filled: Float = 0, undersides: Float = 0
                            for c in 0..<w where bottom[c].isFinite {
                                let b = bottom[c]
                                filled += 1
                                undersides += b
                                for x in 0..<n {
                                    let v = h[x + c]
                                    y[x] = max(y[x], v - b)
                                    sum[x] += v
                                }
                            }
                            for x in 0..<n {
                                let reached = y[x] + topMax
                                guard reached <= height, reached <= best.score else { continue }
                                // The room it leaves under it, per column, counts against it (four times).
                                let waste = filled * y[x] + undersides - sum[x]
                                let score = reached + 4 * waste / Float(w)
                                if score < best.score { best = (score, x, y[x], k) }
                            }
                        }
                    }
                }
                if best.k == k && best.score.isFinite { bestProfile = top }
            }
            guard best.score.isFinite else { return nil }
            for c in bestProfile.indices where bestProfile[c].isFinite {
                horizon[best.x + c] = max(horizon[best.x + c], best.y + bestProfile[c])
            }
            // Its points from `reach` columns across the profile's first, from `best.y` up.
            origins[i] = SIMD2(Float(best.x + reach) * cell, best.y) - shapes[i].lows[best.k] * scale
            turns[i] = best.k
        }
        return Placed(origins: origins, turns: turns, height: horizon.max() ?? 0)
    }
}
