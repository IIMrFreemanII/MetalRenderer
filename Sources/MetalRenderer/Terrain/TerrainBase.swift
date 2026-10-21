import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Materials
import Physics
import Plants
import simd

/// The ground a terrain's edits are made on: a function of the sample, from the scene's own seed (the Forest's
/// rolling hills, the open world's), or flat. Edits are kept as heights added to it (TerrainField), so an unedited
/// terrain is its base exactly, and the open world stays endless: only the tiles that were edited keep anything.
/// Any thread.
package protocol TerrainBase: AnyObject {
    var grid: TerrainGrid { get }
    /// What the base is made from, said in full: edits saved over another base aren't used (TerrainStore).
    var fingerprint: String { get }
    /// The base's height at sample (i, j).
    func height(_ i: Int, _ j: Int) -> Float
    /// What the ground is made of in the cell from sample (i, j) to (i + step, j + step), where it is level: an index
    /// into the scene's ground materials (the open world's fields, woods and meadows). Nil: one material (the scene's).
    /// Steep ground is rock whatever this says (`TerrainSectorMesh`).
    func kind(_ i: Int, _ j: Int, step: Int) -> UInt8?
    /// How much the brushes leave sample (i, j) as it is where nothing is painted over it (0...1): the city's level
    /// ground under its streets.
    func protection(_ i: Int, _ j: Int) -> Float
    /// The heights of a tile's samples `step` apart that are kept somewhere (the open world's tile files), rows along j
    /// ((tileCells / step) squared): read in place of `height` where they are.
    func storedHeights(_ tile: SIMD2<Int>, step: Int) -> Stored<Float>?
    /// A tile's cells' kinds at a level, all at once ((tileCells / step) squared, rows along j), if it keeps them.
    func kinds(_ tile: SIMD2<Int>, step: Int) -> [UInt8]?
}

extension TerrainBase {
    package func kind(_ i: Int, _ j: Int, step: Int) -> UInt8? { nil }
    package func protection(_ i: Int, _ j: Int) -> Float { 0 }
    package func storedHeights(_ tile: SIMD2<Int>, step: Int) -> Stored<Float>? { nil }
    package func kinds(_ tile: SIMD2<Int>, step: Int) -> [UInt8]? { nil }

    /// The base's heights of a tile's samples (tileCells squared, rows along j), on every core.
    func tileHeights(_ tile: SIMD2<Int>) -> [Float] {
        let n = grid.tileCells, first = grid.firstSample(tile)
        var out = [Float](repeating: 0, count: n * n)
        out.withUnsafeMutableBufferPointer { p in
            DispatchQueue.concurrentPerform(iterations: n) { j in
                for i in 0..<n { p[j * n + i] = height(first.x + i, first.y + j) }
            }
        }
        return out
    }
}

/// Rolling ground from octaves of gradient noise, as `Terrain` makes it (the Forest's, Mireland's), level inside a
/// clearing: the same heights at the same samples, bit for bit.
package final class NoiseTerrainBase: TerrainBase {
    package let grid: TerrainGrid
    let seed: UInt64
    let relief: Float
    let flat: (center: SIMD2<Float>, inner: Float, outer: Float)?
    /// Metres per feature of its broadest octave, and how many octaves.
    let featureSize: Float
    let octaves: Int
    private let noiseSeed: UInt32
    private let half: Float, step: Float

    /// `size` metres across, `cells` to a side, centred on the origin (as `Terrain`).
    package init(size: Float, cells: Int, seed: UInt64, relief: Float, flat: (center: SIMD2<Float>, inner: Float, outer: Float)? = nil,
         featureSize: Float = 120, octaves: Int = 5) {
        grid = .square(size: size, cells: cells)
        self.seed = seed
        self.relief = relief
        self.flat = flat
        self.featureSize = featureSize
        self.octaves = octaves
        noiseSeed = UInt32(truncatingIfNeeded: seed &* 0x9E37_79B9 &+ 17)
        half = size / 2
        step = size / Float(cells)
    }

    package var fingerprint: String {
        let f = flat.map { "flat \($0.center.x) \($0.center.y) \($0.inner) \($0.outer)" } ?? "no flat"
        let shape = featureSize == 120 && octaves == 5 ? "" : " features \(featureSize) octaves \(octaves)"
        return "noise seed \(seed) relief \(relief) cell \(grid.cell) \(grid.hi.map { "\($0.x)x\($0.y)" } ?? "") \(f)\(shape)"
    }

    package func height(_ i: Int, _ j: Int) -> Float {
        let p = SIMD2<Float>(Float(i) * step - half, Float(j) * step - half)
        var h = relief * 1.7 * Terrain.fbm(p / featureSize, octaves: octaves, seed: noiseSeed)
        if let flat {
            let t = min(max((length(p - flat.center) - flat.inner) / (flat.outer - flat.inner), 0), 1)
            h *= t * t * (3 - 2 * t)
        }
        return h
    }
}

/// Level ground at `level`, with hills on it (the valley's): each the top of an ellipsoid sunk into the ground, about
/// `center` (the world's x, y, z) with radii `radii`. Where `protect` says, the brushes leave the ground as it is (the
/// city's streets and blocks: TerrainSnapshot.protection).
package final class FlatTerrainBase: TerrainBase {
    package struct Hill: Equatable {
        var center: SIMD3<Float>
        var radii: SIMD3<Float>

        /// (As the memberwise initializer, for the modules above this one.)
        package init(center: SIMD3<Float>, radii: SIMD3<Float>) {
            self.center = center
            self.radii = radii
        }
    }
    package let grid: TerrainGrid
    let level: Float
    let hills: [Hill]
    /// Kept level (x, z rectangles of the world, metres).
    let protect: [(lo: SIMD2<Float>, hi: SIMD2<Float>)]

    /// With `kinds`, a cell is kind 0 (level ground) or 1 (a hill's).
    package let kinds: Bool

    package init(grid: TerrainGrid, level: Float = 0, hills: [Hill] = [], kinds: Bool = false, protect: [(lo: SIMD2<Float>, hi: SIMD2<Float>)] = []) {
        self.grid = grid
        self.level = level
        self.hills = hills
        self.kinds = kinds
        self.protect = protect
    }

    package func kind(_ i: Int, _ j: Int, step: Int) -> UInt8? {
        guard kinds else { return nil }
        return height(i + step / 2, j + step / 2) > level + 0.05 || height(i, j) > level + 0.05 ? 1 : 0
    }

    package var fingerprint: String {
        "flat \(level) cell \(grid.cell) \(grid.hi.map { "\($0.x)x\($0.y)" } ?? "")"
            + hills.map { " hill \($0.center) \($0.radii)" }.joined()
    }

    package func height(_ i: Int, _ j: Int) -> Float {
        guard !hills.isEmpty else { return level }
        let p = grid.place(i, j), q = SIMD2(Float(p.x), Float(p.y))
        var h = level
        for hill in hills {
            let d = (q - SIMD2(hill.center.x, hill.center.z)) / SIMD2(hill.radii.x, hill.radii.z)
            let r = 1 - simd_length_squared(d)
            if r > 0 { h = max(h, hill.center.y + hill.radii.y * r.squareRoot()) }
        }
        return h
    }

    package func protection(_ i: Int, _ j: Int) -> Float {
        guard !protect.isEmpty else { return 0 }
        let p = grid.place(i, j), q = SIMD2(Float(p.x), Float(p.y))
        return protect.contains { q.x >= $0.lo.x && q.x <= $0.hi.x && q.y >= $0.lo.y && q.y <= $0.hi.y } ? 1 : 0
    }
}

/// The open world's ground (World.height): its hills, its cities' level ground and its roads' beds, a metre a sample
/// from the world's origin (a tile of the grid is a tile of the world). The city a sample's height is levelled for is
/// the one of its tile's middle, as WorldTile has always made it. Its kinds are the world's ground materials
/// (`World.ground` for level ground), worked out once per tile and level (WorldTile keeps them in its file).
final class WorldTerrainBase: TerrainBase {
    let world: World
    let grid: TerrainGrid
    private let lock = NSLock()
    private var kinds: [SIMD3<Int>: Stored<UInt8>] = [:]   // (tile, level): a cell's kind, rows along z
    private var heights: [SIMD3<Int>: Stored<Float>] = [:] // (tile, level): its samples' heights

    package init(world: World) {
        self.world = world
        grid = TerrainGrid(cell: 1, origin: .zero, tileCells: Int(World.tileSize), sectorCells: 64)
    }

    var fingerprint: String { "world seed \(world.seed) v\(World.version) cities \(world.cityShare)" }

    func height(_ i: Int, _ j: Int) -> Float {
        let tile = grid.tile(i, j), side = Double(World.tileSize)
        let city = world.city(near: (Double(tile.x) + 0.5) * side, (Double(tile.y) + 0.5) * side)
        return world.height(Double(i), Double(j), city: city)
    }

    /// The level ground's kinds of a tile's cells at a level (WorldTile.groundKinds): given once, read by every mesh of it.
    func setKinds(_ k: Stored<UInt8>, tile: SIMD2<Int>, level: Int) {
        lock.lock(); defer { lock.unlock() }
        kinds[SIMD3(tile.x, tile.y, level)] = k
    }

    /// The cities' level ground (and their roads to the edge of it) is kept as it is, unless painted otherwise.
    func protection(_ i: Int, _ j: Int) -> Float {
        let x = Double(i), z = Double(j)
        return world.cityMask(world.city(near: x, z), x, z) >= 0.999 ? 1 : 0
    }

    /// A tile's heights at a level as its file has them (WorldTile.groundHeights).
    func setHeights(_ h: Stored<Float>, tile: SIMD2<Int>, level: Int) {
        lock.lock(); defer { lock.unlock() }
        heights[SIMD3(tile.x, tile.y, level)] = h
    }

    package func storedHeights(_ tile: SIMD2<Int>, step: Int) -> Stored<Float>? {
        let level = step == 1 ? 0 : step == 4 ? 1 : 2, n = grid.tileCells / step
        lock.lock(); defer { lock.unlock() }
        return heights[SIMD3(tile.x, tile.y, level)].flatMap { $0.count == n * n ? $0 : nil }
    }

    package func kinds(_ tile: SIMD2<Int>, step: Int) -> [UInt8]? {
        let level = step == 1 ? 0 : step == 4 ? 1 : 2, n = grid.tileCells / step
        lock.lock()
        let k = kinds[SIMD3(tile.x, tile.y, level)]
        lock.unlock()
        return k.flatMap { $0.count == n * n ? $0.array : nil }
    }

    func kind(_ i: Int, _ j: Int, step: Int) -> UInt8? {
        let level = step == 1 ? 0 : step == 4 ? 1 : 2, tile = grid.tile(i, j)
        lock.lock()
        let k = kinds[SIMD3(tile.x, tile.y, level)]
        lock.unlock()
        let n = grid.tileCells / step, first = grid.firstSample(tile)
        let ci = (i - first.x) / step, cj = (j - first.y) / step
        if let k, k.count == n * n { return k[cj * n + ci] }
        // (Not given: worked out here, at the cell's middle.)
        let side = Double(World.tileSize), x = Double(i) + Double(step) / 2, z = Double(j) + Double(step) / 2
        let city = world.city(near: (Double(tile.x) + 0.5) * side, (Double(tile.y) + 0.5) * side)
        return UInt8(world.ground(x, z, up: 1, city: city))
    }
}
