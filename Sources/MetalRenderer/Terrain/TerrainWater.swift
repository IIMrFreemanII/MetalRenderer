import Characters
import Effects
import EngineCore
import Foundation
import Physics
import Plants
import simd

/// A terrain's water (WaterBody): a river's bed carved into the ground, a lake's basin found by flooding the ground
/// from a place up to its level, and the surfaces the scene draws: a sea's sheet, a lake's over its basin, a river's
/// ribbon along its line.
enum TerrainWater {
    /// The heights of a river's bed at its points: `depth` under the ground there, never higher than at the point
    /// before (it runs from its source, the first point, down to its mouth).
    static func bed(_ s: TerrainSnapshot, river: WaterBody) -> [Float] {
        if let kept = river.bed, river.bedPoints == river.points, kept.count == river.points.count { return kept }
        var out: [Float] = []
        var lowest = Float.infinity
        for p in river.points {
            lowest = min(lowest, s.height(x: p.x, z: p.y) - river.depth)
            out.append(lowest)
        }
        return out
    }

    /// The nearest point of a polyline to `p`: its distance, the segment and the share along it.
    static func nearest(_ points: [SIMD2<Double>], to p: SIMD2<Double>) -> (distance: Double, segment: Int, t: Double) {
        var best = (Double.infinity, 0, 0.0)
        for k in 0..<(points.count - 1) {
            let a = points[k], b = points[k + 1], ab = b - a
            let t = min(max(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-9), 0), 1)
            let d = simd_distance(p, a + ab * t)
            if d < best.0 { best = (d, k, t) }
        }
        return best
    }

    /// The river's bed carved: within half its width the ground goes down to a rounded channel over the bed, beyond
    /// that it fades back into the ground over another half width. Protected ground stays.
    static func carve(_ s: inout TerrainSnapshot, river: WaterBody, record: inout TerrainUndoRecord) -> Set<SIMD2<Int>> {
        let beds = bed(s, river: river), half = Double(max(river.width, 0.5)) / 2, reach = half * 2
        let xs = river.points.map(\.x), zs = river.points.map(\.y)
        let lo2 = SIMD2(xs.min()! - reach, zs.min()! - reach), hi2 = SIMD2(xs.max()! + reach, zs.max()! + reach)
        let g0 = s.grid.coordinates(lo2.x, lo2.y), g1 = s.grid.coordinates(hi2.x, hi2.y)
        var lo = SIMD2(Int(g0.x.rounded(.up)), Int(g0.y.rounded(.up))), hi = SIMD2(Int(g1.x.rounded(.down)), Int(g1.y.rounded(.down)))
        if let glo = s.grid.lo, let ghi = s.grid.hi { lo = simd_max(lo, glo); hi = simd_min(hi, ghi) }
        guard lo.x <= hi.x, lo.y <= hi.y else { return [] }
        let grid = s.grid, reading = s, points = river.points, depth = river.depth
        return TerrainSculpt.forEach(&s, lo: lo, hi: hi, record: &record) { i, j, base, delta in
            let p = grid.place(i, j)
            let n = nearest(points, to: p)
            guard n.distance < reach else { return }
            let bedHere = beds[n.segment] + (beds[n.segment + 1] - beds[n.segment]) * Float(n.t)
            let now = base + delta
            var target: Float
            if n.distance <= half {
                let x = Float(n.distance / half)
                target = bedHere + depth * x * x
            } else {
                target = .infinity   // the bank: faded below
            }
            let w = (1 - reading.protection(i, j))
            if target.isFinite {
                if target < now { delta += (target - now) * w }
            } else {
                // From the channel's edge (bed + depth) back to the ground, smoothly.
                let edge = bedHere + depth, x = Float((n.distance - half) / (reach - half))
                let f = x * x * (3 - 2 * x)
                let blended = edge + (now - edge) * f
                if blended < now { delta += (blended - now) * w }
            }
        }
    }

    /// A lake's basin: the cells connected to `seed` whose ground is under `level` (flooded from it, at most `limit`
    /// cells across), as a mask of cells (i, j) from `lo`, `size` across.
    static func basin(_ s: TerrainSnapshot, seed: SIMD2<Double>, level: Float, limit: Int = 2048) -> (lo: SIMD2<Int>, size: SIMD2<Int>, cells: [Bool])? {
        let g = s.grid.coordinates(seed.x, seed.y)
        let start = SIMD2(Int(g.x.rounded(.down)), Int(g.y.rounded(.down)))
        var lo = start &- limit / 2, hi = start &+ limit / 2
        if let glo = s.grid.lo, let ghi = s.grid.hi { lo = simd_max(lo, glo); hi = simd_min(hi &- 1, ghi &- 1) }
        let size = hi &- lo &+ 1
        guard size.x > 1, size.y > 1, start.x >= lo.x, start.y >= lo.y, start.x <= hi.x, start.y <= hi.y else { return nil }
        // A cell is under water where its lowest corner is under the level (its four corners' heights read once).
        let h = s.heights(from: lo, count: size &+ 1, step: 1), w = size.x + 1
        func wet(_ i: Int, _ j: Int) -> Bool {
            let k = j * w + i
            return min(min(h[k], h[k + 1]), min(h[k + w], h[k + w + 1])) < level
        }
        var cells = [Bool](repeating: false, count: size.x * size.y)
        let s0 = start &- lo
        guard wet(s0.x, s0.y) else { return (lo, size, cells) }
        var stack = [s0]
        cells[s0.y * size.x + s0.x] = true
        while let c = stack.popLast() {
            for d in [SIMD2(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1)] {
                let n = c &+ d
                guard n.x >= 0, n.y >= 0, n.x < size.x, n.y < size.y, !cells[n.y * size.x + n.x], wet(n.x, n.y) else { continue }
                cells[n.y * size.x + n.x] = true
                stack.append(n)
            }
        }
        return (lo, size, cells)
    }

    /// A flat sheet over cells (a lake's basin, a sea's extent: `cells` nil is all), at `level`, in the scene's
    /// coordinates (`offset` the world's place of its origin), cells merged into runs along x. UVs a metre a tile.
    static func sheet(grid: TerrainGrid, lo: SIMD2<Int>, size: SIMD2<Int>, cells: [Bool]?, level: Float, offset: SIMD2<Double>,
                      step: Int = 1) -> (MeshGeometry, [SIMD2<Float>])? {
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        func corner(_ i: Int, _ j: Int) -> UInt32 {
            let p = grid.place(lo.x + i, lo.y + j)
            positions.append(SIMD3(Float(p.x - offset.x), level, Float(p.y - offset.y)))
            normals.append([0, 1, 0])
            uvs.append(SIMD2(Float(p.x), Float(p.y)))
            return UInt32(positions.count - 1)
        }
        for j in stride(from: 0, to: size.y, by: step) {
            var i = 0
            while i < size.x {
                guard cells?[j * size.x + i] ?? true else { i += 1; continue }
                var end = i
                while end + 1 < size.x && (cells?[j * size.x + end + 1] ?? true) && end + 1 - i < 256 { end += 1 }
                let jj = min(j + step, size.y)
                let a = corner(i, j), b = corner(end + 1, j), c = corner(i, jj), d = corner(end + 1, jj)
                indices += [a, d, b, a, c, d]
                i = end + 1
            }
        }
        guard !indices.isEmpty else { return nil }
        return ((positions, normals, indices), uvs)
    }

    /// A level square from `a` to `b` (the world's x, z), `cells` a side, in the scene's coordinates.
    static func plane(from a: SIMD2<Double>, to b: SIMD2<Double>, level: Float, offset: SIMD2<Double>, cells: Int = 64)
        -> (MeshGeometry, [SIMD2<Float>]) {
        var positions: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        let n = cells + 1
        for j in 0...cells {
            for i in 0...cells {
                let p = a + (b - a) * SIMD2(Double(i), Double(j)) / Double(cells)
                positions.append(SIMD3(Float(p.x - offset.x), level, Float(p.y - offset.y)))
                uvs.append(SIMD2(Float(p.x), Float(p.y)))
            }
        }
        for j in 0..<cells {
            for i in 0..<cells {
                let q = UInt32(j * n + i), r = q + 1, c = q + UInt32(n), d = c + 1
                indices += [q, d, r, q, c, d]
            }
        }
        return ((positions, [SIMD3<Float>](repeating: [0, 1, 0], count: positions.count), indices), uvs)
    }

    /// A river's surface: a ribbon along its line, its width a little narrower than the channel's, at the bed plus most
    /// of its depth (so it runs downhill with it), in the scene's coordinates.
    static func ribbon(_ s: TerrainSnapshot, river: WaterBody, offset: SIMD2<Double>) -> (MeshGeometry, [SIMD2<Float>])? {
        let points = river.points
        guard points.count > 1 else { return nil }
        let beds = bed(s, river: river), half = Double(river.width) * 0.45
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        var along: Float = 0
        for (k, p) in points.enumerated() {
            let a = points[max(k - 1, 0)], b = points[min(k + 1, points.count - 1)]
            let dir = simd_normalize(b - a), side = SIMD2(-dir.y, dir.x)
            if k > 0 { along += Float(simd_distance(points[k - 1], p)) }
            let y = beds[k] + river.depth * 0.8
            for e in [-1.0, 1.0] {
                let q = p + side * half * e
                positions.append(SIMD3(Float(q.x - offset.x), y, Float(q.y - offset.y)))
                normals.append([0, 1, 0])
                uvs.append(SIMD2(along, Float(e * half)))
            }
            if k > 0 {
                let base = UInt32(positions.count - 4)
                indices += [base, base + 2, base + 1, base + 1, base + 2, base + 3]
            }
        }
        return ((positions, normals, indices), uvs)
    }
}
