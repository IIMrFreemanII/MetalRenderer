import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Materials
import Physics
import Plants
import simd

/// Where a scatter rule (ScatterRule) puts its things: one candidate to each cell of a grid over the world, each from
/// its cell's own random numbers (World.candidates' way), kept or not by the rule's filters against the ground as it
/// is. A candidate's place and look depend on its cell alone, so re-scattering a region after a brush stroke changes
/// nothing outside it.
enum TerrainScatter {
    struct Candidate: Hashable {
        var rule: Int
        var cell: SIMD2<Int>
        var x: Double, z: Double
        var yaw: Float
        var size: Float
        var chance: Float       // kept if under the rule's share of cells (`share`)
        var pick: Float         // which variant (a plant of the species, a rock)
        var shade: Int
    }

    /// The side of the grid's cell: as far apart as the rule's spacing at least, and wide enough that one to a cell is
    /// as many as its density asks for (or fewer, kept by chance).
    static func cell(_ rule: ScatterRule) -> Double {
        max(Double(max(rule.spacing, 0.1)), (10_000 / Double(max(rule.density, 1e-4))).squareRoot() * 0.999)
    }

    /// The share of cells kept: its density over one to a cell.
    static func share(_ rule: ScatterRule) -> Float {
        let c = cell(rule)
        return min(Float(Double(rule.density) * c * c / 10_000), 1)
    }

    /// The candidates of rule `index` whose cells' places fall in the square from `lo` to `hi` (the world's x, z).
    static func candidates(_ rule: ScatterRule, index: Int, lo: SIMD2<Double>, hi: SIMD2<Double>) -> [Candidate] {
        let c = cell(rule)
        let i0 = Int((lo.x / c).rounded(.down)), i1 = Int((hi.x / c).rounded(.down))
        let j0 = Int((lo.y / c).rounded(.down)), j1 = Int((hi.y / c).rounded(.down))
        guard i1 >= i0, j1 >= j0, (i1 - i0 + 1) * (j1 - j0 + 1) <= 4_000_000 else { return [] }
        var out: [Candidate] = []
        let seed = UInt64(bitPattern: Int64(rule.seed)) &* 0x9E37_79B9_7F4A_7C15
        for j in j0...j1 {
            for i in i0...i1 {
                var rng = SplitMix64(seed: seed ^ UInt64(bitPattern: Int64(i &* 73_856_093 ^ j &* 19_349_663)) &+ 0xC0FFEE)
                // (Jittered inside the cell, away from its sides: two never closer than the spacing's share.)
                let x = (Double(i) + Double(rng.range(0.15, 0.85))) * c, z = (Double(j) + Double(rng.range(0.15, 0.85))) * c
                guard x >= lo.x, x < hi.x, z >= lo.y, z < hi.y else { continue }
                let yaw = rng.range(0, 2 * .pi), size = rng.range(min(rule.sizeMin, rule.sizeMax), max(rule.sizeMin, rule.sizeMax))
                out.append(Candidate(rule: index, cell: SIMD2(i, j), x: x, z: z, yaw: yaw, size: size, chance: rng.next(), pick: rng.next(),
                                     shade: rng.int(16)))
            }
        }
        return out
    }

    /// Where candidate `c` stands, if the rule keeps it there: its place (y on the ground, sunk) and the ground's
    /// normal. Nil: left out (by chance, height, slope, layer, patches, water, protected ground).
    static func placement(_ c: Candidate, rule: ScatterRule, snapshot s: TerrainSnapshot, layers: [TerrainLayer], water: [WaterBody])
        -> (position: SIMD3<Double>, normal: SIMD3<Float>)? {
        guard rule.enabled, c.chance < share(rule) else { return nil }
        let y = s.height(x: c.x, z: c.z), n = s.normal(x: c.x, z: c.z)
        guard y >= rule.heightMin, y <= rule.heightMax else { return nil }
        let slope = acos(min(max(n.y, -1), 1)) * 180 / .pi
        guard slope >= rule.slopeMin, slope <= rule.slopeMax else { return nil }
        if rule.patchCover < 1 {
            let v = Terrain.noise(c.x / Double(max(rule.patchScale, 1)), c.z / Double(max(rule.patchScale, 1)), seed: UInt32(truncatingIfNeeded: rule.seed &+ 977))
            // noise is about -0.7...0.7: the cover's share of it.
            guard v * 0.7 + 0.5 < rule.patchCover else { return nil }
        }
        let g = s.grid.coordinates(c.x, c.z), sample = s.grid.clamp(Int(g.x.rounded()), Int(g.y.rounded()))
        guard s.protection(sample.x, sample.y) < 0.5 else { return nil }
        if let layer = rule.layer {
            let w = TerrainPaint.weights(s, layers: layers, sample.x, sample.y, height: y, slope: slope)
            guard layer < 16, w[layer] >= rule.layerThreshold else { return nil }
        }
        if rule.avoidWater {
            for body in water {
                switch body.kind {
                case .sea: if y < body.level + 0.2 { return nil }
                case .lake: if y < body.level + 0.2 && simd_distance(SIMD2(c.x, c.z), body.seed) < 2000 { return nil }
                case .river:
                    if body.points.count > 1, TerrainWater.nearest(body.points, to: SIMD2(c.x, c.z)).distance < Double(body.width) { return nil }
                }
            }
        }
        return (SIMD3(c.x, Double(y - rule.sink * c.size), c.z), n)
    }

    /// The transform a placed thing has (in the scene: `offset` the world's place of its origin): turned about its own
    /// up, tilted toward the ground's normal as much as the rule says, sized.
    static func transform(_ c: Candidate, rule: ScatterRule, position p: SIMD3<Double>, normal: SIMD3<Float>, offset: SIMD2<Double>) -> float4x4 {
        let up = simd_normalize(SIMD3<Float>(0, 1, 0) * (1 - rule.alignToGround) + normal * rule.alignToGround)
        let at = SIMD3(Float(p.x - offset.x), Float(p.y), Float(p.z - offset.y))
        return translate(at) * Scene.alignY(up) * rotate(c.yaw, [0, 1, 0]) * scale(c.size)
    }

    /// A rock's mesh: an icosphere pushed in and out by noise (`roughness` how much), flattened a little, its own
    /// variant by `seed`.
    static func rock(roughness: Float, seed: Int) -> (MeshGeometry, [SIMD2<Float>]) {
        let base = Scene.icosphere(subdivisions: 3)
        let s = UInt32(truncatingIfNeeded: seed &* 7919 &+ 13)
        var positions = base.positions.map { p -> SIMD3<Float> in
            let n = simd_normalize(p)
            let bump = 1 + roughness * 0.35 * Terrain.noise(SIMD2(n.x * 1.7 + n.y, n.z * 1.7 - n.y) + Float(seed), seed: s)
                + roughness * 0.12 * Terrain.noise(SIMD2(n.x * 5 + n.z, n.y * 5) * 1.3, seed: s &+ 1)
            return n * bump * SIMD3(1, 0.62, 0.85)
        }
        // (Its foot a little under the ground: flat underneath.)
        for k in positions.indices where positions[k].y < -0.2 { positions[k].y = -0.2 - (positions[k].y + 0.2) * 0.2 }
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: base.indices.count, by: 3) {
            let a = Int(base.indices[t]), b = Int(base.indices[t + 1]), c = Int(base.indices[t + 2])
            let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += n; normals[b] += n; normals[c] += n
        }
        let uvs = positions.map { SIMD2($0.x + $0.y * 0.3, $0.z - $0.y * 0.3) }
        return ((positions, normals.map { simd_length($0) > 0 ? simd_normalize($0) : [0, 1, 0] }, base.indices), uvs)
    }
}
