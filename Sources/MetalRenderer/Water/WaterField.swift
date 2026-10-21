import Characters
import EngineCore
import Foundation
import Physics
import Plants
import simd

/// The water at one place of the world: its surface's height, how it flows there (m/s, the world's x, z), its look
/// (an index into the scene's looks) and how white it runs (0...1).
package struct WaterSample {
    var level: Float
    var flow = SIMD2<Float>.zero
    var look: Int
    var turbulence: Float = 0
}

/// Where a scene's water is, everywhere (the world's x, z): what the water map (WaterMap) is drawn from, around the
/// camera. The ground's height comes with it, for the shore (how deep the water is) and the near patch. Read from a
/// background queue.
package protocol WaterField: AnyObject {
    func ground(_ x: Double, _ z: Double) -> Float
    func water(_ x: Double, _ z: Double, ground: Float) -> WaterSample?
    /// Rows `rows` of a square of texels (`origin` the world's x, z of texel (0, 0)'s corner, `cell` metres a texel,
    /// `size` a side): each texel's (level or WaterMap.dry, ground) and packed info (WaterMap.pack). Called on many
    /// threads at once, a band of rows each.
    func draw(rows: Range<Int>, origin: SIMD2<Double>, cell: Double, size: Int, surface: UnsafeMutablePointer<SIMD2<Float>>,
              info: UnsafeMutablePointer<UInt32>)
}

extension WaterField {
    /// Whether (x, z) is in the water or within `margin` metres of a river's (no plant there): by default, water there.
    package func wet(_ x: Double, _ z: Double, margin: Double) -> Bool { water(x, z, ground: ground(x, z)) != nil }

    package func draw(rows: Range<Int>, origin: SIMD2<Double>, cell: Double, size n: Int, surface: UnsafeMutablePointer<SIMD2<Float>>,
              info: UnsafeMutablePointer<UInt32>) {
        for j in rows {
            let z = origin.y + (Double(j) + 0.5) * cell
            for i in 0..<n {
                let x = origin.x + (Double(i) + 0.5) * cell
                let g = ground(x, z)
                guard let w = water(x, z, ground: g) else { surface[j * n + i] = SIMD2(WaterMap.dry, g); continue }
                surface[j * n + i] = SIMD2(w.level, g)
                info[j * n + i] = WaterMap.pack(w)
            }
        }
    }
}

/// A terrain's water (its document's bodies, TerrainWater): rivers over lakes over seas, each with the look the scene
/// gave it.
final class TerrainWaterField: WaterField {
    private struct Sea { var level: Float; var look: Int; var lo: SIMD2<Double>?; var hi: SIMD2<Double>? }
    private struct Lake { var lo: SIMD2<Int>; var size: SIMD2<Int>; var cells: [Bool]; var level: Float; var look: Int }
    private struct River {
        package var points: [SIMD2<Double>]
        package var beds: [Float]
        package var half: Double, depth: Float
        package var look: Int
        package var speed: [Float]        // per segment: m/s in the middle
        package var white: [Float]        // per segment: how white it runs
        package var buckets: [Int: [Int]] // segments by coarse cell (bucketSize), for the nearest one
    }
    private static let bucketSize = 16.0
    private let snapshot: TerrainSnapshot
    /// A finite terrain's ground, read once (every `step` samples, at most 2048 a side): the map reads it many times.
    private var raster: (lo: SIMD2<Int>, size: SIMD2<Int>, step: Int, heights: [Float])?
    private var seas: [Sea] = []
    private var lakes: [Lake] = []
    private var rivers: [River] = []

    /// `looks[k]`: body k's look's index in the scene's looks (nil: the body made nothing).
    package init(snapshot s: TerrainSnapshot, bodies: [WaterBody], looks: [Int?]) {
        snapshot = s
        let grid = s.grid
        if let lo = grid.lo, let hi = grid.hi {
            let step = max(1, (simd_reduce_max(hi &- lo) + 2047) / 2048)
            let size = (hi &- lo) / step &+ 1
            var heights = [Float](repeating: 0, count: size.x * size.y)
            let bands = (size.y + 63) / 64
            heights.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: bands) { b in
                    let rows = min(64, size.y - b * 64)
                    let part = s.heights(from: SIMD2(lo.x, lo.y + b * 64 * step), count: SIMD2(size.x, rows), step: step)
                    for k in part.indices { out[b * 64 * size.x + k] = part[k] }
                }
            }
            raster = (lo, size, step, heights)
        }
        for (k, body) in bodies.enumerated() {
            guard let look = looks[k] else { continue }
            switch body.kind {
            case .sea:
                let lo = grid.lo.map { grid.place($0.x, $0.y) }, hi = grid.hi.map { grid.place($0.x, $0.y) }
                seas.append(Sea(level: body.level, look: look, lo: lo, hi: hi))
            case .lake:
                guard let b = TerrainWater.basin(s, seed: body.seed, level: body.level) else { continue }
                lakes.append(Lake(lo: b.lo, size: b.size, cells: b.cells, level: body.level, look: look))
            case .river:
                guard body.points.count > 1 else { continue }
                let beds = TerrainWater.bed(s, river: body), half = Double(body.width) * 0.45
                let appearance = body.appearance
                var speed: [Float] = [], white: [Float] = [], buckets: [Int: [Int]] = [:]
                for i in 0..<(body.points.count - 1) {
                    let a = body.points[i], b = body.points[i + 1], length = Float(max(simd_distance(a, b), 0.1))
                    // Faster down a steep bed and through a narrow one; white where it drops fast.
                    let slope = max(beds[i] - beds[i + 1], 0) / length
                    let narrow = pow(8 / max(body.width, 1), 0.3)
                    speed.append(min(appearance.flowSpeed * (0.6 + 25 * slope) * narrow, 5))
                    white.append(appearance.whiteWater * TerrainWaterField.smoothstep(0.015, 0.07, slope))
                    let lo = simd_min(a, b) - half * 1.7 - 4, hi = simd_max(a, b) + half * 1.7 + 4
                    for cz in Int((lo.y / Self.bucketSize).rounded(.down))...Int((hi.y / Self.bucketSize).rounded(.down)) {
                        for cx in Int((lo.x / Self.bucketSize).rounded(.down))...Int((hi.x / Self.bucketSize).rounded(.down)) {
                            buckets[Self.key(cx, cz), default: []].append(i)
                        }
                    }
                }
                rivers.append(River(points: body.points, beds: beds, half: half, depth: body.depth, look: look, speed: speed, white: white,
                                    buckets: buckets))
            }
        }
    }

    private static func key(_ x: Int, _ z: Int) -> Int { (x &* 73_856_093) ^ (z &* 19_349_663) }
    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    func ground(_ x: Double, _ z: Double) -> Float {
        guard let r = raster else { return snapshot.height(x: x, z: z) }
        let g = snapshot.grid.coordinates(x, z)
        let fx = min(max((g.x - Double(r.lo.x)) / Double(r.step), 0), Double(r.size.x - 1))
        let fz = min(max((g.y - Double(r.lo.y)) / Double(r.step), 0), Double(r.size.y - 1))
        let i = min(Int(fx), r.size.x - 2), j = min(Int(fz), r.size.y - 2)
        let u = Float(fx - Double(i)), v = Float(fz - Double(j)), k = j * r.size.x + i
        let a = r.heights[k] + (r.heights[k + 1] - r.heights[k]) * u
        let b = r.heights[k + r.size.x] + (r.heights[k + r.size.x + 1] - r.heights[k + r.size.x]) * u
        return a + (b - a) * v
    }

    package func draw(rows: Range<Int>, origin: SIMD2<Double>, cell: Double, size n: Int, surface: UnsafeMutablePointer<SIMD2<Float>>,
              info: UnsafeMutablePointer<UInt32>) {
        // (Everything the texels read, in this band's own locals: many threads reading the field's arrays through
        // `self` would fight over their reference counts.)
        let rivers = self.rivers, lakes = self.lakes, seas = self.seas, raster = self.raster, grid = snapshot.grid, snapshot = self.snapshot
        let heights = raster?.heights ?? []
        heights.withUnsafeBufferPointer { h in
            for j in rows {
                let z = origin.y + (Double(j) + 0.5) * cell
                for i in 0..<n {
                    let x = origin.x + (Double(i) + 0.5) * cell
                    let g: Float
                    if let r = raster {
                        let c = grid.coordinates(x, z)
                        let fx = min(max((c.x - Double(r.lo.x)) / Double(r.step), 0), Double(r.size.x - 1))
                        let fz = min(max((c.y - Double(r.lo.y)) / Double(r.step), 0), Double(r.size.y - 1))
                        let ii = min(Int(fx), r.size.x - 2), jj = min(Int(fz), r.size.y - 2)
                        let u = Float(fx - Double(ii)), v = Float(fz - Double(jj)), k = jj * r.size.x + ii
                        let a = h[k] + (h[k + 1] - h[k]) * u, b = h[k + r.size.x] + (h[k + r.size.x + 1] - h[k + r.size.x]) * u
                        g = a + (b - a) * v
                    } else {
                        g = snapshot.height(x: x, z: z)
                    }
                    guard let w = TerrainWaterField.water(x, z, ground: g, rivers: rivers, lakes: lakes, seas: seas, grid: grid) else {
                        surface[j * n + i] = SIMD2(WaterMap.dry, g)
                        continue
                    }
                    surface[j * n + i] = SIMD2(w.level, g)
                    info[j * n + i] = WaterMap.pack(w)
                }
            }
        }
    }

    func water(_ x: Double, _ z: Double, ground: Float) -> WaterSample? {
        TerrainWaterField.water(x, z, ground: ground, rivers: rivers, lakes: lakes, seas: seas, grid: snapshot.grid)
    }

    func wet(_ x: Double, _ z: Double, margin: Double) -> Bool {
        let g = ground(x, z)
        if let w = water(x, z, ground: g), g < w.level + Float(margin) * 0.3 { return true }
        // (A lake's shore: within the margin of one of its cells.)
        let grid = snapshot.grid, reach = Int((margin / Double(grid.cell)).rounded(.up))
        if reach > 0 {
            let at = grid.coordinates(x, z), c = SIMD2(Int(at.x.rounded(.down)), Int(at.y.rounded(.down)))
            for l in lakes {
                let q0 = c &- l.lo
                guard q0.x >= -reach, q0.y >= -reach, q0.x < l.size.x + reach, q0.y < l.size.y + reach else { continue }
                for dz in -reach...reach {
                    for dx in -reach...reach where dx * dx + dz * dz <= reach * reach {
                        let q = q0 &+ SIMD2(dx, dz)
                        if q.x >= 0, q.y >= 0, q.x < l.size.x, q.y < l.size.y, l.cells[q.y * l.size.x + q.x] { return true }
                    }
                }
            }
        }
        let p = SIMD2(x, z)
        for r in rivers {
            guard let list = r.buckets[Self.key(Int((x / Self.bucketSize).rounded(.down)), Int((z / Self.bucketSize).rounded(.down)))] else { continue }
            for i in list {
                let a = r.points[i], ab = r.points[i + 1] - a
                let t = min(max(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-9), 0), 1)
                if simd_distance(p, a + ab * t) < r.half / 0.9 + margin { return true }
            }
        }
        return false
    }

    private static func water(_ x: Double, _ z: Double, ground: Float, rivers: [River], lakes: [Lake], seas: [Sea], grid: TerrainGrid) -> WaterSample? {
        let p = SIMD2(x, z)
        for r in rivers {
            guard let list = r.buckets[Self.key(Int((x / Self.bucketSize).rounded(.down)), Int((z / Self.bucketSize).rounded(.down)))] else { continue }
            var best = (d: Double.infinity, i: 0, t: 0.0)
            for i in list {
                let a = r.points[i], ab = r.points[i + 1] - a
                let t = min(max(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-9), 0), 1)
                let d = simd_distance(p, a + ab * t)
                if d < best.d { best = (d, i, t) }
            }
            // (A little past the ribbon's edge: the shore's soft edge reads the level there.)
            guard best.d < r.half * 1.6 else { continue }
            let bed = r.beds[best.i] + (r.beds[best.i + 1] - r.beds[best.i]) * Float(best.t)
            let level = bed + r.depth * 0.8
            guard ground < level + 0.05 || best.d < r.half else { continue }
            let a = r.points[best.i], b = r.points[best.i + 1]
            let along = SIMD2<Float>(simd_normalize(b - a))
            // Slower toward the banks.
            let across = Float(min(best.d / r.half, 1)), profile = max(1 - across * across, 0.15)
            return WaterSample(level: level, flow: along * r.speed[best.i] * profile, look: r.look, turbulence: r.white[best.i] * profile)
        }
        for l in lakes {
            let g = grid.coordinates(x, z)
            let c = SIMD2(Int(g.x.rounded(.down)), Int(g.y.rounded(.down))) &- l.lo
            // (The cell next to a wet one counts as the lake too: the shore's texels straddle its edge.)
            var wet = false
            for dz in -1...1 where !wet {
                for dx in -1...1 {
                    let q = c &+ SIMD2(dx, dz)
                    if q.x >= 0, q.y >= 0, q.x < l.size.x, q.y < l.size.y, l.cells[q.y * l.size.x + q.x] { wet = true; break }
                }
            }
            if wet { return WaterSample(level: l.level, look: l.look) }
        }
        for s in seas {
            if let lo = s.lo, let hi = s.hi, x < lo.x || z < lo.y || x > hi.x || z > hi.y { continue }
            if ground < s.level + 0.05 { return WaterSample(level: s.level, look: s.look) }
        }
        return nil
    }
}

/// Water at one level over a square of the world (the swamp's): wherever the ground is under it, with one look.
package final class LevelWaterField: WaterField {
    let level: Float, look: Int, lo: SIMD2<Double>, hi: SIMD2<Double>
    private let height: (Double, Double) -> Float
    package init(level: Float, look: Int, lo: SIMD2<Double>, hi: SIMD2<Double>, ground: @escaping (Double, Double) -> Float) {
        (self.level, self.look, self.lo, self.hi, height) = (level, look, lo, hi, ground)
    }
    package func ground(_ x: Double, _ z: Double) -> Float { height(x, z) }
    package func water(_ x: Double, _ z: Double, ground: Float) -> WaterSample? {
        guard x >= lo.x, z >= lo.y, x <= hi.x, z <= hi.y, ground < level + 0.05 else { return nil }
        return WaterSample(level: level, look: look)
    }
}
