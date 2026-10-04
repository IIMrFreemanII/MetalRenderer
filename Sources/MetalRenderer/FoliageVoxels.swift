import Foundation
import simd

/// Distance level of detail for generated plants (both tracers: VoxelLOD.swift on Metal's): each plant as a grid of voxels
/// holding how much leaf and wood is in them. Once a plant is far enough that a voxel is smaller than a pixel, rays
/// march its grid instead of walking its parts' triangles, and stop in a voxel with the probability that a ray
/// through it would have hit something (`rtVoxels` in Shaders/Intersect.metal). On average a far crown then covers
/// what its leaves would: it neither thins out nor turns solid, and nothing pops when a plant changes over.
///
/// A cell is 32 bits: 8 of optical depth across a level 0 voxel (`depth` = 255), 8 of how much of it is leaf, 16 of
/// its mean normal (octahedral, facing out of the crown). Three levels, each half the one before; 0 = empty.
enum FoliageVoxels {
    /// Level 0 voxels along the plant's longest side. Measured in the forest: a march of 32 steps costs less than
    /// walking the plant's parts, one of 64 costs more, so a finer level would only ever be slower than triangles.
    static let resolution = 32
    /// Wood counts for this many times its area: a trunk is solid, and a ray through the voxels of its two walls
    /// should stop in one of them nearly always, not as often as it would in the same area of scattered leaves.
    static let woodWeight: Float = 3
    static let levels = 3
    static let depth: Float = 4         // VOXEL_DEPTH in Shaders/Intersect.metal

    /// MSL `RTVoxels`: one plant's grid.
    struct Grid {
        var lo = SIMD4<Float>()         // xyz = the grid's corner (plant space), w = a level 0 voxel's size
        var dims = SIMD4<UInt32>()      // xyz = level 0 voxels per axis, w = 1: an evergreen (it keeps its leaves)
        var offsets = SIMD4<UInt32>()   // xyz = where levels 0, 1, 2 start among the cells
    }

    static func dims(_ d: SIMD3<Int>, level: Int) -> SIMD3<Int> {
        let r = (1 << level) - 1
        return SIMD3(max((d.x + r) >> level, 1), max((d.y + r) >> level, 1), max((d.z + r) >> level, 1))
    }

    /// What a plant's grid is made of: its meshes, placed in its space. The same on both tracers: an assembly's parts
    /// (custom tracer), or the parts a baked plant was flattened from (Metal's).
    struct Piece {
        var mesh: Foliage.Mesh
        var transform: float4x4         // into plant space
        var firstLeaf: UInt32           // the mesh's triangles from here on are leaves
        var leafCoverage: Float = 1     // the share of a leaf triangle that is there: a card's picture's (Scene.cutouts)
    }
    struct Plant {
        var key: String                 // what it is (its library, species and number): the cache's name for it
        var pieces: [Piece]
        var evergreen: Bool
    }

    /// Of `build`'s output: a change of the voxelisation makes other files in the cache.
    static let version = 1

    /// `build`, from the cache or into it (GeneratedCache); the file is named by the plants' keys and their cards'
    /// coverage, which is all their meshes are made from.
    static func cached(_ plants: [Plant]) -> (grids: [Grid], cells: [UInt32]) {
        guard !plants.isEmpty else { return ([], []) }
        var hasher = GeneratedCache.Hasher()
        for plant in plants {
            hasher.add(plant.key)
            hasher.add(plant.pieces.map(\.leafCoverage))
        }
        let name = "voxels-\(hasher.name()).sect", key = "voxels v\(version) \(resolution) \(levels)"
        let grid = SectionFile.id("grid"), cell = SectionFile.id("cell")
        if let file = GeneratedCache.load(name, key: key), let grids: [Grid] = file.array(grid), let cells: [UInt32] = file.array(cell),
           grids.count == plants.count {
            return (grids, cells)
        }
        let built = build(plants)
        var writer = SectionFile.Writer()
        writer.add(grid, built.grids)
        writer.add(cell, built.cells)
        GeneratedCache.store(name, key: key, writer)
        return built
    }

    /// Every plant's grid (offsets from 0: `build` places them) and cells. The plants are voxelised in parallel.
    static func build(_ plants: [Plant]) -> (grids: [Grid], cells: [UInt32]) {
        var built = [(grid: Grid, cells: [UInt32])](repeating: (Grid(), []), count: plants.count)
        built.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: plants.count) { p in slots[p] = voxelise(plants[p]) }
        }
        var grids: [Grid] = [], cells: [UInt32] = []
        cells.reserveCapacity(built.reduce(0) { $0 + $1.cells.count })
        for b in built {
            var grid = b.grid
            grid.offsets &+= SIMD4(repeating: UInt32(cells.count))
            grids.append(grid)
            cells += b.cells
        }
        return (grids, cells)
    }

    private static func octahedral(_ n: SIMD3<Float>) -> UInt32 {
        let s = abs(n.x) + abs(n.y) + abs(n.z)
        var e = SIMD2(n.x, n.y) / max(s, 1e-8)
        if n.z < 0 { e = SIMD2((1 - abs(e.y)) * (e.x >= 0 ? 1 : -1), (1 - abs(e.x)) * (e.y >= 0 ? 1 : -1)) }
        let q = simd_clamp((e * 0.5 + 0.5) * 255 + 0.5, SIMD2(repeating: 0), SIMD2(repeating: 255))
        return UInt32(q.x) | UInt32(q.y) << 8
    }

    private static func voxelise(_ plant: Plant) -> (grid: Grid, cells: [UInt32]) {
        // The box of the placed vertices (a piece's own box, turned, would be looser).
        var box = AABB()
        for piece in plant.pieces {
            let c = piece.transform.columns
            let x = Foliage.xyz(c.0), y = Foliage.xyz(c.1), z = Foliage.xyz(c.2), origin = Foliage.xyz(c.3)
            for p in piece.mesh.positions { box.grow(x * p.x + y * p.y + z * p.z + origin) }
        }
        let extent = box.hi - box.lo
        let size = max(extent.max() / Float(resolution), 1e-3)
        let d0 = SIMD3<Int>(max(Int((extent.x / size).rounded(.up)), 1), max(Int((extent.y / size).rounded(.up)), 1),
                            max(Int((extent.z / size).rounded(.up)), 1))
        // Level 0: the area of leaf and of wood in each voxel, and the area-weighted normal, facing out of the crown.
        let count = d0.x * d0.y * d0.z
        var area = [Float](repeating: 0, count: count), leafArea = [Float](repeating: 0, count: count)
        var normal = [SIMD3<Float>](repeating: .zero, count: count)
        let heart = SIMD3<Float>((box.lo.x + box.hi.x) / 2, box.lo.y + 0.35 * extent.y, (box.lo.z + box.hi.z) / 2)
        let top = SIMD3<Float>(Float(d0.x - 1), Float(d0.y - 1), Float(d0.z - 1))
        for piece in plant.pieces {
            let positions = piece.mesh.positions, indices = piece.mesh.indices
            let c = piece.transform.columns
            let x = Foliage.xyz(c.0), y = Foliage.xyz(c.1), z = Foliage.xyz(c.2), origin = Foliage.xyz(c.3)
            @inline(__always) func placed(_ i: UInt32) -> SIMD3<Float> { let p = positions[Int(i)]; return x * p.x + y * p.y + z * p.z + origin }
            for t in 0..<indices.count / 3 {
                let p0 = placed(indices[3 * t]), e1 = placed(indices[3 * t + 1]) - p0, e2 = placed(indices[3 * t + 2]) - p0
                let cr = cross(e1, e2)
                let twice = length(cr)
                guard twice > 0 else { continue }
                var n = cr / twice
                if dot(n, p0 + (e1 + e2) / 3 - heart) < 0 { n = -n }
                // A triangle bigger than a voxel (the trunk's) is spread over k x k points of it.
                let k = min(max(Int((max(length(e1), length(e2)) / (0.7 * size)).rounded(.up)), 1), 16)
                // A card is only there where its picture is: its area counts by that share.
                let isLeaf = UInt32(t) >= piece.firstLeaf
                let there = isLeaf ? piece.leafCoverage : 1
                let share = twice / 2 / Float(k * k) * there
                for i in 0..<k {
                    for j in 0..<(2 * (k - i) - 1) {
                        // The centroids of the k x k small triangles: row i has k - i upright ones and k - i - 1 flipped.
                        let u = (Float(i) + (j % 2 == 0 ? 1 : 2) / 3) / Float(k), v = (Float(j / 2) + (j % 2 == 0 ? 1 : 2) / 3) / Float(k)
                        let q = simd_clamp((p0 + e1 * u + e2 * v - box.lo) / size, .zero, top)
                        let cell = (Int(q.z) * d0.y + Int(q.y)) * d0.x + Int(q.x)
                        area[cell] += share
                        if isLeaf { leafArea[cell] += share }
                        normal[cell] += n * share
                    }
                }
            }
        }

        var grid = Grid(lo: SIMD4(box.lo, size), dims: SIMD4(UInt32(d0.x), UInt32(d0.y), UInt32(d0.z), plant.evergreen ? 1 : 0))
        var cells: [UInt32] = []
        var d = d0
        for level in 0..<levels {
            grid.offsets[level] = UInt32(cells.count)
            // A ray across a voxel of area A (faces every way) in volume V meets A / 2V of it per metre: the cell
            // keeps that times a level 0 voxel's size (the shader scales it by the level's).
            let volume = size * size * size * Float(1 << (3 * level))
            for i in 0..<d.x * d.y * d.z {
                guard area[i] > 0 else { cells.append(0); continue }
                let tau = (leafArea[i] + (area[i] - leafArea[i]) * woodWeight) / (2 * volume) * size
                let stored = min(max(UInt32((tau / depth * 255).rounded()), 1), 255)
                let leaf = UInt32((leafArea[i] / area[i] * 255).rounded())
                let n = length_squared(normal[i]) > 1e-12 ? normalize(normal[i]) : SIMD3<Float>(0, 1, 0)
                cells.append(stored << 24 | leaf << 16 | octahedral(n))
            }
            guard level + 1 < levels else { break }
            // The next level: each voxel the sum of the (up to) eight it covers.
            let next = dims(d0, level: level + 1), nextCount = next.x * next.y * next.z
            var a = [Float](repeating: 0, count: nextCount), l = [Float](repeating: 0, count: nextCount)
            var m = [SIMD3<Float>](repeating: .zero, count: nextCount)
            for zi in 0..<d.z {
                for yi in 0..<d.y {
                    for xi in 0..<d.x {
                        let from = (zi * d.y + yi) * d.x + xi, to = ((zi / 2) * next.y + yi / 2) * next.x + xi / 2
                        a[to] += area[from]; l[to] += leafArea[from]; m[to] += normal[from]
                    }
                }
            }
            (area, leafArea, normal, d) = (a, l, m, next)
        }
        return (grid, cells)
    }
}
