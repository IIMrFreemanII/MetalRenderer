import EngineCore
import Foundation
import Physics
import Plants
import simd

/// What the edits keep of a tile: per sample (tileCells squared, rows along j), the height added to the base, and if
/// it has been painted, the ground layers' painted weights (16 a sample, 0...255) with how much of the paint shows
/// over the layers' own rules (`mask`); and where the city's ground is kept level whatever the brushes do (`protect`).
package struct TerrainTile: Equatable {
    static let layers = 16
    var delta: [Float]
    var paint: [UInt8]? = nil
    var mask: [UInt8]? = nil
    var protect: [UInt8]? = nil
    /// Counts its edits (the renderer meshes again what changed since it last looked; saved, it says the tile changed).
    var revision = 0
    /// The same per chunk of `chunkCells` samples a side (a sector's size): the brushes mark what they change
    /// (`changed`), so only the sectors there are meshed again. Empty: every chunk is `revision`.
    var chunks: [Int] = []
    static let chunkCells = 64
    static let pending = Int.max

    /// Samples `lo`...`hi` (the tile's own, from its first) changed: their chunks, and those whose sectors' normals read
    /// them (one sample beyond), wait for the field's next revision.
    mutating func changed(_ lo: SIMD2<Int>, _ hi: SIMD2<Int>, cells n: Int) {
        let c = TerrainTile.chunkCells, per = max(n / c, 1)
        if chunks.count != per * per { chunks = [Int](repeating: revision, count: per * per) }
        let a = simd_max((lo &- 1) / c, .zero), b = simd_min((hi &+ 1) / c, SIMD2(repeating: per - 1))
        guard a.x <= b.x, a.y <= b.y else { return }
        for j in a.y...b.y { for i in a.x...b.x { chunks[j * per + i] = TerrainTile.pending } }
    }

    /// The highest revision of its chunks that samples `lo`...`hi` (the tile's own) are in.
    func revision(_ lo: SIMD2<Int>, _ hi: SIMD2<Int>, cells n: Int) -> Int {
        let c = TerrainTile.chunkCells, per = max(n / c, 1)
        guard chunks.count == per * per else { return revision }
        let a = simd_max(lo / c, .zero), b = simd_min(hi / c, SIMD2(repeating: per - 1))
        guard a.x <= b.x, a.y <= b.y else { return 0 }
        var r = 0
        for j in a.y...b.y { for i in a.x...b.x { r = max(r, chunks[j * per + i]) } }
        return r
    }

    package init(cells: Int) { delta = [Float](repeating: 0, count: cells * cells) }
    package init(delta: [Float], paint: [UInt8]? = nil, mask: [UInt8]? = nil, protect: [UInt8]? = nil, revision: Int = 0) {
        (self.delta, self.paint, self.mask, self.protect, self.revision) = (delta, paint, mask, protect, revision)
    }

    /// Nothing in it changes the ground.
    var isEmpty: Bool { paint == nil && protect == nil && !delta.contains { $0 != 0 } }

    package static func == (a: TerrainTile, b: TerrainTile) -> Bool {
        a.delta == b.delta && a.paint == b.paint && a.mask == b.mask && a.protect == b.protect && a.revision == b.revision
    }
}

/// A terrain as it is now: its base, and the tiles its edits have made (`tiles`). Its height at a sample is the base's
/// plus the tile's delta. A value: a snapshot of a field (TerrainField) that the scenes are made from, that the
/// walker and the brushes' cursor read, that is saved.
package struct TerrainSnapshot {
    package let base: TerrainBase
    package var tiles: [SIMD2<Int>: TerrainTile] = [:]
    /// The base's heights of the tiles that were asked for (TerrainBaseCache), shared by every snapshot of the field.
    package let baseCache: TerrainBaseCache

    package var grid: TerrainGrid { base.grid }

    /// The height added at sample (i, j).
    @inline(__always) package func delta(_ i: Int, _ j: Int) -> Float {
        let n = grid.tileCells, t = grid.tile(i, j)
        guard let tile = tiles[t] else { return 0 }
        return tile.delta[(j - t.y * n) * n + (i - t.x * n)]
    }

    /// The base's height at sample (i, j) (from the cache when its tile has been asked for whole).
    @inline(__always) package func baseHeight(_ i: Int, _ j: Int) -> Float {
        baseCache.height(i, j, base: base)
    }

    /// The ground's height at sample (i, j), clamped into the terrain.
    @inline(__always) package func height(_ i: Int, _ j: Int) -> Float {
        let s = grid.clamp(i, j)
        return baseHeight(s.x, s.y) + delta(s.x, s.y)
    }

    /// The heights of `count` samples along each axis, `step` apart, from sample `first` (clamped into the terrain),
    /// rows along j: each tile's arrays fetched once (a sector's mesh reads thousands).
    package func heights(from first: SIMD2<Int>, count: SIMD2<Int>, step: Int) -> [Float] {
        let n = grid.tileCells
        var out = [Float](repeating: 0, count: count.x * count.y)
        var bases: [SIMD2<Int>: [Float]?] = [:], stored: [SIMD2<Int>: Stored<Float>?] = [:], deltas: [SIMD2<Int>: [Float]?] = [:]
        out.withUnsafeMutableBufferPointer { o in
            // The tile the last sample was in, and its arrays: the dictionaries are asked only where a row crosses into
            // another tile (asked for every sample, they were half of a sector mesh's heights: Time Profiler).
            var tile = SIMD2<Int>(.min, .min)
            var full: [Float]? = nil, kept: Stored<Float>? = nil, delta: [Float]? = nil
            for b in 0..<count.y {
                for a in 0..<count.x {
                    let s = grid.clamp(first.x + a * step, first.y + b * step), t = grid.tile(s.x, s.y)
                    let li = s.x - t.x * n, lj = s.y - t.y * n, k = lj * n + li
                    if t != tile {
                        tile = t
                        if bases[t] == nil { bases[t] = .some(baseCache.cached(t)) }
                        if deltas[t] == nil { deltas[t] = .some(tiles[t]?.delta) }
                        full = bases[t]!
                        delta = deltas[t]!
                        kept = nil
                        if full == nil {
                            if stored[t] == nil { stored[t] = .some(step > 1 ? base.storedHeights(t, step: step) : nil) }
                            kept = stored[t]!
                        }
                    }
                    var h: Float
                    if let full {
                        h = full[k]
                    } else if let kept, li % step == 0, lj % step == 0 {
                        h = kept[(lj / step) * (n / step) + li / step]
                    } else {
                        h = base.height(s.x, s.y)
                    }
                    o[b * count.x + a] = h + (delta.map { $0[k] } ?? 0)
                }
            }
        }
        return out
    }

    /// The ground's height under (x, z) (the world's): on the mesh's triangle there, as `Terrain.height` (a cell's
    /// diagonal runs from its low corner to its high one).
    package func height(x: Double, z: Double) -> Float {
        let g = grid.coordinates(x, z)
        let fi = g.x.rounded(.down), fj = g.y.rounded(.down)
        var i = Int(fi), j = Int(fj)
        var u = Float(g.x - fi), v = Float(g.y - fj)
        if let lo = grid.lo, let hi = grid.hi {
            if i < lo.x { (i, u) = (lo.x, 0) } else if i >= hi.x { (i, u) = (hi.x - 1, 1) }
            if j < lo.y { (j, v) = (lo.y, 0) } else if j >= hi.y { (j, v) = (hi.y - 1, 1) }
        }
        let h00 = height(i, j), h10 = height(i + 1, j), h01 = height(i, j + 1), h11 = height(i + 1, j + 1)
        return u >= v ? h00 + (h10 - h00) * u + (h11 - h10) * v : h00 + (h11 - h01) * u + (h01 - h00) * v
    }

    /// How much the edits raised (or lowered) the ground under (x, z): their delta, between its samples.
    package func delta(x: Double, z: Double) -> Float {
        let g = grid.coordinates(x, z)
        let fi = g.x.rounded(.down), fj = g.y.rounded(.down), i = Int(fi), j = Int(fj)
        let u = Float(g.x - fi), v = Float(g.y - fj)
        let a = delta(i, j) + (delta(i + 1, j) - delta(i, j)) * u, b = delta(i, j + 1) + (delta(i + 1, j + 1) - delta(i, j + 1)) * u
        return a + (b - a) * v
    }

    /// The normal of that triangle.
    package func normal(x: Double, z: Double) -> SIMD3<Float> {
        let g = grid.coordinates(x, z)
        let fi = g.x.rounded(.down), fj = g.y.rounded(.down)
        var i = Int(fi), j = Int(fj)
        var u = Float(g.x - fi), v = Float(g.y - fj)
        if let lo = grid.lo, let hi = grid.hi {
            if i < lo.x { (i, u) = (lo.x, 0) } else if i >= hi.x { (i, u) = (hi.x - 1, 1) }
            if j < lo.y { (j, v) = (lo.y, 0) } else if j >= hi.y { (j, v) = (hi.y - 1, 1) }
        }
        let h00 = height(i, j), h10 = height(i + 1, j), h01 = height(i, j + 1), h11 = height(i + 1, j + 1)
        let slope = u >= v ? SIMD2(h10 - h00, h11 - h10) : SIMD2(h11 - h01, h01 - h00)
        return normalize(SIMD3(-slope.x, grid.cell, -slope.y))
    }

    /// Where a ray (the world's coordinates) first meets the ground, within `maxDistance`: marched in steps of half a
    /// cell near the ground (longer above it), then halved down to the crossing.
    package func raycast(origin o: SIMD3<Double>, direction d: SIMD3<Float>, maxDistance: Float = 4000) -> (point: SIMD3<Double>, distance: Float)? {
        let dir = SIMD3<Double>(normalize(d))
        func above(_ t: Double) -> Double {
            let p = o + dir * t
            return p.y - Double(height(x: p.x, z: p.z))
        }
        var t = 0.0, prev = above(0)
        if prev < 0 { return nil }   // under the ground
        let cell = Double(grid.cell), horizontal = max((dir.x * dir.x + dir.z * dir.z).squareRoot(), 1e-3)
        while t < Double(maxDistance) {
            // Far from the ground the step can be as long as the height over it allows at a steep (2:1) slope.
            let step = max(cell * 0.5 / horizontal, min(prev * 0.4, 64))
            let next = t + step, h = above(next)
            if h <= 0 {
                var a = t, b = next
                for _ in 0..<24 {
                    let m = (a + b) / 2
                    if above(m) > 0 { a = m } else { b = m }
                }
                return (o + dir * b, Float(b))
            }
            (t, prev) = (next, h)
        }
        return nil
    }

    /// The layer weights painted at sample (i, j), and how much they show (0...1); nil where nothing is painted.
    package func paint(_ i: Int, _ j: Int) -> (weights: SIMD16<UInt8>, mask: Float)? {
        let n = grid.tileCells, t = grid.tile(i, j)
        guard let tile = tiles[t], let paint = tile.paint, let mask = tile.mask else { return nil }
        let k = (j - t.y * n) * n + (i - t.x * n)
        guard mask[k] > 0 else { return nil }
        var w = SIMD16<UInt8>()
        for l in 0..<TerrainTile.layers { w[l] = paint[k * TerrainTile.layers + l] }
        return (w, Float(mask[k]) / 255)
    }

    /// How much sample (i, j) is kept as it is (0...1): as painted, or where its tile has no protection painted, the
    /// base's (the city's streets).
    package func protection(_ i: Int, _ j: Int) -> Float {
        let n = grid.tileCells, t = grid.tile(i, j)
        guard let protect = tiles[t]?.protect else { return base.protection(i, j) }
        return Float(protect[(j - t.y * n) * n + (i - t.x * n)]) / 255
    }

    /// What the edits are, as a word for the keys of what is made from the ground (a scene's generated textures):
    /// empty without any, else a hash of every edited tile's heights.
    package var editsFingerprint: String {
        let edited = tiles.filter { !$0.value.isEmpty }.sorted { ($0.key.y, $0.key.x) < ($1.key.y, $1.key.x) }
        guard !edited.isEmpty else { return "" }
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ v: UInt64) { h = (h ^ v) &* 0x100_0000_01B3 }
        for (t, tile) in edited {
            mix(UInt64(bitPattern: Int64(t.x))); mix(UInt64(bitPattern: Int64(t.y)))
            tile.delta.withUnsafeBufferPointer { for d in $0 { mix(UInt64(d.bitPattern)) } }
        }
        return " edits \(String(h, radix: 16))"
    }

    /// The highest revision of the tiles a sector reads (its own and the ring of samples around it): its mesh is
    /// made again when this changes.
    package func revision(around sector: TerrainSector) -> Int {
        let lo = sector.first &- sector.step, hi = sector.last &+ sector.step, n = grid.tileCells
        return grid.tiles(from: lo, to: hi).reduce(0) { r, t in
            guard let tile = tiles[t] else { return r }
            let first = grid.firstSample(t)
            return max(r, tile.revision(simd_max(lo, first) &- first, simd_min(hi, first &+ (n - 1)) &- first, cells: n))
        }
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(base: TerrainBase, tiles: [SIMD2<Int>: TerrainTile] = [:], baseCache: TerrainBaseCache) {
        self.base = base
        self.tiles = tiles
        self.baseCache = baseCache
    }
}

/// The base's heights of whole tiles, kept once asked for (a brush reads around it many times a frame): at most
/// `capacity` tiles, the oldest let go of. Any thread.
package final class TerrainBaseCache {
    private let lock = NSLock()
    private var tiles: [SIMD2<Int>: [Float]] = [:]
    private var order: [SIMD2<Int>] = []
    let capacity: Int

    package init(capacity: Int = 48) { self.capacity = capacity }

    /// The tile's heights, made now if it isn't kept.
    func heights(_ tile: SIMD2<Int>, base: TerrainBase) -> [Float] {
        lock.lock()
        if let h = tiles[tile] { lock.unlock(); return h }
        lock.unlock()
        let h = base.tileHeights(tile)
        lock.lock(); defer { lock.unlock() }
        if tiles[tile] == nil {
            tiles[tile] = h
            order.append(tile)
            if order.count > capacity { tiles[order.removeFirst()] = nil }
        }
        return h
    }

    /// Fills the cache with a tile's heights made elsewhere (an open world's tile file has them).
    func set(_ tile: SIMD2<Int>, heights: [Float]) {
        lock.lock(); defer { lock.unlock() }
        if tiles[tile] == nil { order.append(tile) }
        tiles[tile] = heights
        if order.count > capacity { tiles[order.removeFirst()] = nil }
    }

    /// A tile's heights if they are kept.
    func cached(_ tile: SIMD2<Int>) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        return tiles[tile]
    }

    func isCached(_ tile: SIMD2<Int>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tiles[tile] != nil
    }

    /// The base's height at a sample: from its tile if that is kept, else straight from the base.
    @inline(__always) func height(_ i: Int, _ j: Int, base: TerrainBase) -> Float {
        let n = base.grid.tileCells, t = base.grid.tile(i, j)
        lock.lock()
        let h = tiles[t]
        lock.unlock()
        if let h { return h[(j - t.y * n) * n + (i - t.x * n)] }
        return base.height(i, j)
    }
}

/// A terrain being edited: its snapshot as it is now, which the brushes change (on the render thread) and anyone
/// else takes a copy of (`snapshot`). Edits make the touched tiles' revision go up, and `revision` with them.
package final class TerrainField {
    private let lock = NSLock()
    private var current: TerrainSnapshot
    private(set) var revision = 0

    package init(base: TerrainBase, tiles: [SIMD2<Int>: TerrainTile] = [:]) {
        current = TerrainSnapshot(base: base, tiles: tiles, baseCache: TerrainBaseCache())
        revision = tiles.values.map(\.revision).max() ?? 0
    }

    package var base: TerrainBase { current.base }
    package var grid: TerrainGrid { current.base.grid }

    /// The terrain as it is now (a copy: its arrays are shared until either side changes them).
    package func snapshot() -> TerrainSnapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Changes the terrain: `body` gets it to edit, and says which tiles it changed (their revisions go up).
    @discardableResult
    package func edit(_ body: (inout TerrainSnapshot) -> Set<SIMD2<Int>>) -> Set<SIMD2<Int>> {
        lock.lock(); defer { lock.unlock() }
        let touched = body(&current)
        guard !touched.isEmpty else { return touched }
        revision += 1
        for t in touched {
            guard var tile = current.tiles[t] else { continue }
            current.tiles[t] = nil
            tile.revision = revision
            // (Chunks a brush marked take this revision; without marks the whole tile did change.)
            if tile.chunks.contains(TerrainTile.pending) {
                for k in tile.chunks.indices where tile.chunks[k] == TerrainTile.pending { tile.chunks[k] = revision }
            } else {
                tile.chunks = []
            }
            current.tiles[t] = tile
        }
        return touched
    }

    /// Puts tiles back as they were (an undo): `tiles[t]` nil makes tile t unedited (kept, empty: its revision says
    /// it changed).
    package func restore(_ tiles: [SIMD2<Int>: TerrainTile?]) {
        lock.lock(); defer { lock.unlock() }
        revision += 1
        for (t, tile) in tiles {
            var tile = tile ?? TerrainTile(cells: grid.tileCells)
            tile.revision = revision
            tile.chunks = []
            current.tiles[t] = tile
        }
    }

    /// Replaces every tile (a document loaded, or reverted to what is saved).
    package func replaceAll(_ tiles: [SIMD2<Int>: TerrainTile]) {
        lock.lock(); defer { lock.unlock() }
        revision += 1
        var out = tiles
        for t in out.keys { out[t]!.revision = revision; out[t]!.chunks = [] }
        for t in current.tiles.keys where out[t] == nil {
            var empty = TerrainTile(cells: grid.tileCells)
            empty.revision = revision
            out[t] = empty
        }
        current.tiles = out
    }
}
