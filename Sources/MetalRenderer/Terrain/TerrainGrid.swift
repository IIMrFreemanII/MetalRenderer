import Foundation
import simd

/// Where a terrain's samples are. A sample is a point of a square grid of `cell` metres, numbered (i, j) from the one
/// at `origin` (the world's x, z). The grid is cut into tiles of `tileCells` samples a side (what is saved, and the
/// open world's tiles: 256 m at a metre a cell), and a tile into sectors of `sectorCells` cells (what a frame meshes
/// and builds again while the ground is sculpted). A terrain may end (`lo`...`hi`, the samples it has: the Forest's
/// 320 m square) or not (the open world).
///
/// A tile owns its samples i in tx * T ..< (tx + 1) * T (and the same along j): a sample on a tile's side is the
/// next tile's, so no sample is kept twice.
package struct TerrainGrid: Codable, Equatable {
    var cell: Float
    package var origin: SIMD2<Double>
    var tileCells = 256
    var sectorCells = 64
    var lo: SIMD2<Int>? = nil
    var hi: SIMD2<Int>? = nil

    var isFinite: Bool { lo != nil && hi != nil }

    /// A square of `size` metres centred on `center`, `cells` to a side.
    package static func square(size: Float, cells: Int, center: SIMD2<Double> = .zero) -> TerrainGrid {
        TerrainGrid(cell: size / Float(cells), origin: center - SIMD2(repeating: Double(size) / 2), lo: SIMD2(0, 0), hi: SIMD2(cells, cells))
    }

    /// The world's place of sample (i, j).
    @inline(__always) func place(_ i: Int, _ j: Int) -> SIMD2<Double> {
        origin + SIMD2(Double(i), Double(j)) * Double(cell)
    }

    /// A place as the grid's continuous coordinates (sample (i, j) is at (i, j)).
    @inline(__always) func coordinates(_ x: Double, _ z: Double) -> SIMD2<Double> {
        SIMD2((x - origin.x) / Double(cell), (z - origin.y) / Double(cell))
    }

    /// The tile that owns sample (i, j).
    @inline(__always) func tile(_ i: Int, _ j: Int) -> SIMD2<Int> {
        SIMD2(TerrainGrid.floorDiv(i, tileCells), TerrainGrid.floorDiv(j, tileCells))
    }

    /// The first sample of a tile.
    @inline(__always) func firstSample(_ tile: SIMD2<Int>) -> SIMD2<Int> { tile &* tileCells }

    /// The tile's corner, in the world.
    func corner(_ tile: SIMD2<Int>) -> SIMD2<Double> { place(tile.x * tileCells, tile.y * tileCells) }

    /// Sample (i, j) kept inside the terrain (unchanged where it has no edge).
    @inline(__always) func clamp(_ i: Int, _ j: Int) -> SIMD2<Int> {
        guard let lo, let hi else { return SIMD2(i, j) }
        return SIMD2(min(max(i, lo.x), hi.x), min(max(j, lo.y), hi.y))
    }

    /// The tiles that hold any of the terrain's samples (nil: it has no edge).
    package var tiles: [SIMD2<Int>]? {
        guard let lo, let hi else { return nil }
        let a = tile(lo.x, lo.y), b = tile(hi.x, hi.y)
        var out: [SIMD2<Int>] = []
        for tz in a.y...b.y { for tx in a.x...b.x { out.append(SIMD2(tx, tz)) } }
        return out
    }

    /// The tiles any sample of the rectangle of samples `a`...`b` is in.
    package func tiles(from a: SIMD2<Int>, to b: SIMD2<Int>) -> [SIMD2<Int>] {
        let ta = tile(a.x, a.y), tb = tile(b.x, b.y)
        guard ta.x <= tb.x, ta.y <= tb.y else { return [] }
        var out: [SIMD2<Int>] = []
        for tz in ta.y...tb.y { for tx in ta.x...tb.x { out.append(SIMD2(tx, tz)) } }
        return out
    }

    @inline(__always) static func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }
    @inline(__always) static func floorMod(_ a: Int, _ b: Int) -> Int { a - floorDiv(a, b) * b }
}

/// A piece of ground a scene meshes as one: `cells` cells (each `step` samples across) from sample `first`, inside
/// tile `tile` at level of detail `level` (`step` = 4^level: the open world's 1, 4 and 16 m cells at a metre a sample).
/// At level 0 a tile is cut into sectors of `sectorCells`; a coarser tile is one sector.
package struct TerrainSector: Hashable {
    var tile: SIMD2<Int>
    var index: SIMD2<Int>           // its place among its tile's sectors
    var level: Int
    var first: SIMD2<Int>           // its first sample
    var cells: SIMD2<Int>           // along x, along z
    var step: Int
    /// The realistic look's near ground (realism high: Scene.refineTerrain): each cell cut into subdiv x subdiv, the
    /// ground smooth between the samples and raised by its scans' relief (GroundRelief); 1: a cell a sample apart.
    var subdiv = 1
    /// ...and the sides (bits: -z, +z, -x, +x) whose neighbour is coarse: the relief and the smoothing fade out toward
    /// them, so the side lies on the neighbour's triangles.
    var seams: UInt8 = 0

    /// Its quads along x and z (cells times subdiv).
    var quads: SIMD2<Int> { cells &* subdiv }
    /// Vertices: the grid, then a skirt of (quads + 1) under each side (-z, +z, -x, +x).
    var gridVertices: Int { (quads.x + 1) * (quads.y + 1) }
    var vertexCount: Int { gridVertices + 2 * (quads.x + 1) + 2 * (quads.y + 1) }
    var triangleCount: Int { 2 * quads.x * quads.y + 4 * quads.x + 4 * quads.y }
    var indexCount: Int { 3 * triangleCount }

    /// What scenes call its mesh: the same sector of the same terrain is the same mesh in every scene that has it, so
    /// the renderer keeps its buffer and its structure from one scene to the next (the open world's).
    func meshName(terrain: String) -> String {
        "terrain \(terrain) L\(level) tile \(tile.x) \(tile.y) sector \(index.x) \(index.y) \(cells.x)x\(cells.y)"
            + (subdiv > 1 ? " S\(subdiv) \(seams)" : "")
    }

    /// The last sample along each axis (its far corner).
    var last: SIMD2<Int> { first &+ cells &* step }

    /// The sectors of a tile at a level, cut to the terrain's samples. Empty if the tile has none.
    package static func sectors(of tile: SIMD2<Int>, level: Int, grid: TerrainGrid) -> [TerrainSector] {
        let step = level == 0 ? 1 : level == 1 ? 4 : 16
        let span = min(grid.sectorCells * step, grid.tileCells)   // samples a sector covers
        var lo = grid.firstSample(tile), hi = lo &+ grid.tileCells
        if let glo = grid.lo, let ghi = grid.hi {
            lo = simd_max(lo, glo)
            hi = simd_min(hi, ghi)
        }
        guard lo.x < hi.x, lo.y < hi.y else { return [] }
        let start = grid.firstSample(tile)
        var out: [TerrainSector] = []
        let k0 = (lo &- start) / span, k1 = (hi &- start &- 1) / span
        for kz in k0.y...k1.y {
            for kx in k0.x...k1.x {
                let a = simd_max(start &+ SIMD2(kx, kz) &* span, lo)
                let b = simd_min(start &+ SIMD2(kx + 1, kz + 1) &* span, hi)
                let cells = (b &- a) / step
                guard cells.x > 0, cells.y > 0 else { continue }
                out.append(TerrainSector(tile: tile, index: SIMD2(kx, kz), level: level, first: a, cells: cells, step: step))
            }
        }
        return out
    }
}
