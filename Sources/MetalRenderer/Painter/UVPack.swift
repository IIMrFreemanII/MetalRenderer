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
        // From the top: what the largest scale left over (the share of the area it placed) says where to start.
        var guess: Float
        switch place(shapes, order, scale: hi, resolution: resolution, pad: pad) {
        case .fit(let all): return Result(scale: hi, origins: all.origins, padding: pad, turns: all.turns)
        case .miss(let placed): guess = hi * max((placed / max(area, 1e-20)).squareRoot() * 0.97, 0.3)
        }
        // A fit grows by the square root of the room it left above its horizon (at least 1%, at most halfway to the
        // smallest miss); a miss aims at the square root of the share it placed (between the two it knows of, else
        // halfway); within 1% of the largest that fits.
        for _ in 0..<24 {
            switch place(shapes, order, scale: guess, resolution: resolution, pad: pad) {
            case .fit(let o):
                lo = guess
                best = o
                let grow = guess * (r * r / max(r * r - o.free, r * r / 4)).squareRoot() * 0.995
                guess = min(max(grow, guess * 1.01), (lo + hi) / 2)
            case .miss(let placed):
                hi = guess
                let aim = guess * (placed / max(area, 1e-20)).squareRoot() * 0.995
                guess = lo == 0 ? min(aim, guess * 0.9) : (aim > lo * 1.005 && aim < hi ? aim : (lo + hi) / 2)
            }
            if hi - lo < hi * 0.01 { break }
            if guess >= hi { guess = (lo + hi) / 2 }
        }
        if best == nil, case .fit(let o) = place(shapes, order, scale: lo, resolution: resolution, pad: pad) { best = o }
        return Result(scale: lo, origins: best?.origins ?? [SIMD2<Float>](repeating: .zero, count: charts.count), padding: pad,
                      turns: best?.turns ?? [Int](repeating: 0, count: charts.count))
    }

    /// Where the charts went, and the room left above them (texels²).
    private struct Placed {
        var origins: [SIMD2<Float>]
        var turns: [Int]
        var free: Float
    }
    /// They all fit, or the area (metres) of those that did before one didn't.
    private enum Outcome {
        case fit(Placed)
        case miss(placed: Float)
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

    /// The charts on the horizon at `scale`, if they fit: per chart its origin (texels) and turns.
    private static func place(_ shapes: [Shape], _ order: [Int], scale: Float, resolution: Int, pad: Int) -> Outcome {
        // Columns of half the gutter, two of them its width (between two charts' points 2 to 2.5 gutters across).
        let reach = pad >= 2 ? 2 : 1
        let cell = Float(max(pad, 1)) / Float(reach)
        let columns = Int(Float(resolution) / cell)
        let height = Float(resolution)
        // (Eight floats over the end, so that the scan reads whole SIMD8s.)
        var horizon = [Float](repeating: 0, count: columns + 8)
        var origins = [SIMD2<Float>](repeating: .zero, count: shapes.count)
        var turns = [Int](repeating: 0, count: shapes.count)
        var rest = [SIMD8<Float>](repeating: .zero, count: columns / 8 + 1), under = [Float](repeating: 0, count: columns)
        var prefix = [Double](repeating: 0, count: columns + 1)
        var placed: Float = 0
        for i in order {
            var best: (score: Float, x: Int, y: Float, k: Int) = (.infinity, 0, 0, 0)
            var bestProfile: [Float] = []
            // The horizon's running sum (the room under a chart whose columns are all of it, at once).
            for c in 0..<columns { prefix[c + 1] = prefix[c] + Double(horizon[c]) }
            // (A chart of a few columns turned half round is much the same: its two quarter turns only.)
            for k in 0..<(shapes[i].box * scale * scale > Float(64 * pad * pad) ? 4 : 2) {
                let (bottom, top) = shapes[i].profile(k, scale: scale, cell: cell, reach: reach, pad: Float(pad))
                let w = bottom.count
                guard w <= columns else { continue }
                var topMax: Float = 0
                for c in 0..<w where top[c].isFinite { topMax = max(topMax, top[c]) }
                // Every position across at once, column by column of the chart (eight at a time): where it comes to
                // rest (the highest of the horizon less its underside), and the room under it (its columns' rest
                // height and underside, less the horizon under them: a sum over them).
                let n = columns - w + 1, n8 = (n + 7) / 8
                var filled: Float = 0, undersides: Float = 0
                for c in 0..<w where bottom[c].isFinite { filled += 1; undersides += bottom[c] }
                let whole = Int(filled) == w
                rest.withUnsafeMutableBufferPointer { y8 in
                    under.withUnsafeMutableBufferPointer { sum in
                        horizon.withUnsafeBufferPointer { h in
                            let raw = UnsafeRawPointer(h.baseAddress!)
                            for j in 0..<n8 { y8[j] = .zero }
                            if whole {
                                for x in 0..<n { sum[x] = Float(prefix[x + w] - prefix[x]) }
                            } else {
                                for x in 0..<n { sum[x] = 0 }
                                for c in 0..<w where bottom[c].isFinite {
                                    for x in 0..<n { sum[x] += h[x + c] }
                                }
                            }
                            for c in 0..<w where bottom[c].isFinite {
                                let b = SIMD8<Float>(repeating: bottom[c])
                                for j in 0..<n8 {
                                    let v = raw.loadUnaligned(fromByteOffset: 4 * (8 * j + c), as: SIMD8<Float>.self)
                                    y8[j] = simd_max(y8[j], v - b)
                                }
                            }
                            for x in 0..<n {
                                let yx = y8[x >> 3][x & 7]
                                let reached = yx + topMax
                                guard reached <= height, reached <= best.score else { continue }
                                // The room it leaves under it, per column, counts against it (four times).
                                let waste = filled * yx + undersides - sum[x]
                                let score = reached + 4 * waste / Float(w)
                                if score < best.score { best = (score, x, yx, k) }
                            }
                        }
                    }
                }
                if best.k == k && best.score.isFinite { bestProfile = top }
            }
            guard best.score.isFinite else { return .miss(placed: placed) }
            placed += shapes[i].area
            for c in bestProfile.indices where bestProfile[c].isFinite {
                horizon[best.x + c] = max(horizon[best.x + c], best.y + bestProfile[c])
            }
            // Its points from `reach` columns across the profile's first, from `best.y` up.
            origins[i] = SIMD2(Float(best.x + reach) * cell, best.y) - shapes[i].lows[best.k] * scale
            turns[i] = best.k
        }
        var free: Float = 0
        for h in horizon[..<columns] { free += max(height - h, 0) * cell }
        return .fit(Placed(origins: origins, turns: turns, free: free))
    }
}
