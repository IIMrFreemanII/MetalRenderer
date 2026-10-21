import Foundation
import simd

/// The open world's water, as a function of its seed and a place, as everything else of the world is: asked twice,
/// in any order, a place's water is the same, so every tile, scene and map agrees on it.
///
///   Sea     everything whose natural ground (the hills, before the cities levelled them) is under the sea's level,
///           which keeps 8 m under the origin's city (no other city is built under it or within 6 m over it).
///   Rivers  from springs (one to a 2 km region at most, high enough over the sea), down the steepest way on a
///           lattice of 32 m over the hills smoothed (the broad ones, a third of the rolling: a river doesn't stop at
///           every hollow), each step a function of its cell alone: two rivers that meet run on as one, and a river's
///           flow is the springs above it. Its bed goes down with that smoothed ground, and the ground is shaped to
///           it (World.height): within the channel to its bed, over the banks back to the hills (cut through a rise,
///           banked over a dip), wider and deeper the more springs feed it.
///   Ponds   where a river ends in a hollow of the smoothed ground: a round basin shaped into the ground there, a rim
///           round it, filled to just under the hollow's height.
///
/// The rivers are worked out the first time a place near them is asked for (the springs of the regions around it,
/// a few milliseconds), and kept.
final class WorldWater {
    let seed: UInt64
    let seaLevel: Float
    private let broadSeed: UInt32, rollingSeed: UInt32

    static let lattice = 32.0
    static let regionSize = 2048.0
    /// How far a river runs at most, in lattice steps (6.4 km): the springs that can feed a place are in the regions
    /// within `reach` of its own.
    static let steps = 200, reach = 4
    static let bucketSize = 128.0

    /// A river's step from one lattice cell to the next downstream: its ends, its bed's height at each, half its
    /// width and its depth, and the springs that feed it.
    struct Edge {
        var a: SIMD2<Double>, b: SIMD2<Double>
        var bedA: Float, bedB: Float
        var half: Float, depth: Float
        var flow: Int
        var level: (Float, Float) { (bedA + depth * 0.8, bedB + depth * 0.8) }
    }
    /// A river's end in a hollow: a round pond, its water's height, its radius and depth.
    struct Pond {
        var center: SIMD2<Double>
        var level: Float
        var radius: Float, depth: Float
    }

    private let lock = NSLock()
    private var springsTraced = Set<SIMD2<Int>>()
    private var windows = Set<SIMD2<Int>>()
    private var next: [SIMD2<Int>: SIMD2<Int>] = [:]
    private var passing: [SIMD2<Int>: Int] = [:]
    private var buckets: [SIMD2<Int>: [SIMD2<Int>]] = [:]    // a bucket's edges, by the cells they leave
    private var hollows = Set<SIMD2<Int>>()
    private var heights: [SIMD2<Int>: Float] = [:]   // the river cells' smoothed ground (cellHeight), kept
    private var pondBuckets: [SIMD2<Int>: [SIMD2<Int>]] = [:]

    private static let sharedLock = NSLock()
    private static var all: [UInt64: WorldWater] = [:]

    /// The water of the world of `seed` (one for every copy of it).
    static func shared(seed: UInt64, broad: UInt32, rolling: UInt32, originLevel: Float) -> WorldWater {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let w = all[seed] { return w }
        let w = WorldWater(seed: seed, broad: broad, rolling: rolling, originLevel: originLevel)
        all[seed] = w
        return w
    }

    private init(seed: UInt64, broad: UInt32, rolling: UInt32, originLevel: Float) {
        self.seed = seed
        broadSeed = broad
        rollingSeed = rolling
        seaLevel = min(-14, originLevel - 8)
    }

    private func broad(_ x: Double, _ z: Double) -> Float { 70 * Terrain.fbm(x / 1800, z / 1800, octaves: 4, seed: broadSeed) }
    private func rolling(_ x: Double, _ z: Double) -> Float { 15.3 * Terrain.fbm(x / 120, z / 120, octaves: 5, seed: rollingSeed) }

    /// The ground as the hills make it, before the rivers, the cities and the roads.
    func natural(_ x: Double, _ z: Double) -> Float { broad(x, z) + rolling(x, z) }
    /// ...smoothed: what the rivers run down.
    func smooth(_ x: Double, _ z: Double) -> Float { broad(x, z) + 0.33 * rolling(x, z) }

    // MARK: - The lattice

    /// Where a lattice cell's river point is: its middle, moved a little by the cell's own numbers (a river doesn't run
    /// in straight lines).
    func point(_ c: SIMD2<Int>) -> SIMD2<Double> {
        let h = World.hash(seed, c.x, c.y, 0x51BE)
        let jx = Double(h & 0xFFFF) / 65535 - 0.5, jz = Double((h >> 16) & 0xFFFF) / 65535 - 0.5
        return (SIMD2(Double(c.x), Double(c.y)) + 0.5 + SIMD2(jx, jz) * 0.6) * WorldWater.lattice
    }
    private func cellHeight(_ c: SIMD2<Int>) -> Float { let p = point(c); return smooth(p.x, p.y) }
    private static func region(_ x: Double, _ z: Double) -> SIMD2<Int> {
        SIMD2(Int((x / regionSize).rounded(.down)), Int((z / regionSize).rounded(.down)))
    }
    private static func bucket(_ x: Double, _ z: Double) -> SIMD2<Int> {
        SIMD2(Int((x / bucketSize).rounded(.down)), Int((z / bucketSize).rounded(.down)))
    }

    /// A region's springs: up to three, high enough over the sea, by its own numbers.
    private func springs(_ r: SIMD2<Int>) -> [SIMD2<Int>] {
        var rng = SplitMix64(seed: World.hash(seed, r.x, r.y, 0x5A1C))
        var out: [SIMD2<Int>] = []
        for _ in 0..<3 {
            let chance = rng.next(), u = Double(rng.next()), v = Double(rng.next())
            guard chance < 0.8 else { continue }
            let p = (SIMD2(Double(r.x), Double(r.y)) + SIMD2(0.05 + 0.9 * u, 0.05 + 0.9 * v)) * WorldWater.regionSize
            let c = SIMD2(Int((p.x / WorldWater.lattice).rounded(.down)), Int((p.y / WorldWater.lattice).rounded(.down)))
            if cellHeight(c) > seaLevel + 18 { out.append(c) }
        }
        return out
    }

    /// A spring's river: its cells from the spring down, and whether it ends in a hollow (its last cell's pond).
    private func trace(from start: SIMD2<Int>) -> (cells: [SIMD2<Int>], hollow: Bool) {
        var cells = [start], c = start, h = cellHeight(start)
        for _ in 0..<WorldWater.steps {
            if h < seaLevel { return (cells, false) }   // the sea
            var best = c, low = h
            for dz in -1...1 {
                for dx in -1...1 where dx != 0 || dz != 0 {
                    let n = c &+ SIMD2(dx, dz), hn = cellHeight(n)
                    if hn < low { (best, low) = (n, hn) }
                }
            }
            if best == c {
                // A hollow: through its rim to the lowest cell lower than it a little farther on (the step's channel
                // cuts a gorge through the rim), or, in a basin, a pond.
                for r in 2...8 where best == c {
                    for dz in -r...r {
                        for dx in -r...r where max(abs(dx), abs(dz)) == r {
                            let n = c &+ SIMD2(dx, dz), hn = cellHeight(n)
                            if hn < low { (best, low) = (n, hn) }
                        }
                    }
                }
                if best == c { return (cells, true) }
            }
            cells.append(best)
            (c, h) = (best, low)
        }
        return (cells, false)
    }

    /// The rivers of every spring that can reach the regions around `r` (and the region's neighbours), traced once.
    private func ensure(region r: SIMD2<Int>) {
        lock.lock()
        let done = windows.contains(r)
        lock.unlock()
        if done { return }
        let reach = WorldWater.reach + 1
        for dz in -reach...reach {
            for dx in -reach...reach {
                let q = r &+ SIMD2(dx, dz)
                lock.lock()
                let traced = springsTraced.contains(q)
                if !traced { springsTraced.insert(q) }
                lock.unlock()
                guard !traced else { continue }
                for s in springs(q) {
                let (cells, hollow) = trace(from: s)
                let cellHeights = cells.map(cellHeight)
                lock.lock()
                for (k, c) in cells.enumerated() {
                    passing[c, default: 0] += 1
                    heights[c] = cellHeights[k]
                    if k + 1 < cells.count, next[c] == nil {
                        next[c] = cells[k + 1]
                        // (Into the buckets its banks reach: its widest is 2 x 20 m from its line; a step through a
                        // hollow's rim is up to 8 cells long.)
                        let a = point(c), b = point(cells[k + 1]), m = 44.0
                        let lo = WorldWater.bucket(min(a.x, b.x) - m, min(a.y, b.y) - m), hi = WorldWater.bucket(max(a.x, b.x) + m, max(a.y, b.y) + m)
                        for bz in lo.y...hi.y { for bx in lo.x...hi.x { buckets[SIMD2(bx, bz), default: []].append(c) } }
                    }
                }
                if hollow, let last = cells.last, !hollows.contains(last) {
                    hollows.insert(last)
                    let p = point(last), m = 100.0
                    let lo = WorldWater.bucket(p.x - m, p.y - m), hi = WorldWater.bucket(p.x + m, p.y + m)
                    for bz in lo.y...hi.y { for bx in lo.x...hi.x { pondBuckets[SIMD2(bx, bz), default: []].append(last) } }
                }
                lock.unlock()
                }
            }
        }
        lock.lock()
        windows.insert(r)
        lock.unlock()
    }

    // MARK: - What a place has of it

    private func width(_ flow: Int) -> (half: Float, depth: Float) {
        let f = Float(flow).squareRoot()
        return (min(2.5 + 1.8 * f, 20), min(0.8 + 0.35 * f, 4))
    }
    private func edge(_ c: SIMD2<Int>, _ n: SIMD2<Int>, flow: Int, flowNext: Int, heights h: (Float?, Float?)) -> Edge {
        let w = width(flow), wn = width(flowNext)
        // (Its depth and width are its upstream end's; the bed goes down with the smoothed ground under its points.)
        return Edge(a: point(c), b: point(n), bedA: (h.0 ?? cellHeight(c)) - w.depth, bedB: (h.1 ?? cellHeight(n)) - max(w.depth, wn.depth),
                    half: w.half, depth: w.depth, flow: flow)
    }
    private func pond(_ c: SIMD2<Int>, flow: Int, height: Float?) -> Pond {
        let f = Float(flow).squareRoot()
        return Pond(center: point(c), level: (height ?? cellHeight(c)) - 0.3, radius: min(22 + 9 * f, 90), depth: 1.5 + 0.5 * f)
    }

    /// The rivers' steps and ponds whose shaping reaches into the square from `lo` to `hi` (the world's x, z).
    func near(lo: SIMD2<Double>, hi: SIMD2<Double>) -> (edges: [Edge], ponds: [Pond]) {
        let r0 = WorldWater.region(lo.x, lo.y), r1 = WorldWater.region(hi.x, hi.y)
        for rz in r0.y...r1.y { for rx in r0.x...r1.x { ensure(region: SIMD2(rx, rz)) } }
        let b0 = WorldWater.bucket(lo.x, lo.y), b1 = WorldWater.bucket(hi.x, hi.y)
        var cells = Set<SIMD2<Int>>(), pits = Set<SIMD2<Int>>()
        lock.lock()
        for bz in b0.y...b1.y {
            for bx in b0.x...b1.x {
                for c in buckets[SIMD2(bx, bz)] ?? [] { cells.insert(c) }
                for p in pondBuckets[SIMD2(bx, bz)] ?? [] { pits.insert(p) }
            }
        }
        let steps = cells.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.compactMap { c in
            next[c].map { (c, $0, passing[c] ?? 1, passing[$0] ?? 1, heights[c], heights[$0]) }
        }
        let ends = pits.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.map { ($0, passing[$0] ?? 1, heights[$0]) }
        lock.unlock()
        return (steps.map { edge($0.0, $0.1, flow: $0.2, flowNext: $0.3, heights: ($0.4, $0.5)) }, ends.map { pond($0.0, flow: $0.1, height: $0.2) })
    }

    /// Where a point is from a step's line: how far, and the share along it.
    @inline(__always) static func along(_ e: Edge, _ p: SIMD2<Double>) -> (distance: Double, t: Double) {
        let ab = e.b - e.a
        let t = min(max(simd_dot(p - e.a, ab) / max(simd_length_squared(ab), 1e-9), 0), 1)
        return (simd_distance(p, e.a + ab * t), t)
    }

    /// The ground `h` at `x, z` shaped to the water near it (`edges`, `ponds`: the ones near it): in a river's channel
    /// its rounded bed, over its banks from the bank's top back to the ground, in a pond its bowl, round it a rim.
    static func shape(_ x: Double, _ z: Double, _ h: Float, edges: [Edge], ponds: [Pond]) -> Float {
        let p = SIMD2(x, z)
        var channel = Float.infinity, bank = Float.infinity
        for e in edges {
            let (d, t) = along(e, p), half = Double(e.half)
            guard d < half * 2 else { continue }
            let bed = e.bedA + (e.bedB - e.bedA) * Float(t)
            if d <= half {
                let u = Float(d / half)
                channel = min(channel, bed + e.depth * u * u)
            } else {
                let top = bed + e.depth, f = World.smoothstep(0, 1, Float((d - half) / half))
                bank = min(bank, top + (h - top) * f)
            }
        }
        for o in ponds {
            let d = Float(simd_distance(p, o.center))
            guard d < o.radius * 1.8 else { continue }
            if d <= o.radius {
                let u = d / o.radius
                channel = min(channel, o.level - o.depth * (1 - u * u) - 0.05)
            } else {
                let top = o.level + 0.4, f = World.smoothstep(0, 1, (d - o.radius) / (o.radius * 0.8))
                bank = min(bank, top + (h - top) * f)
            }
        }
        return channel.isFinite ? channel : bank.isFinite ? bank : h
    }

    /// The ground at `x, z` shaped to the water (World.height's first step, over its natural ground `h`).
    func carve(_ x: Double, _ z: Double, _ h: Float) -> Float {
        let (edges, ponds) = near(lo: SIMD2(x, z), hi: SIMD2(x, z))
        return edges.isEmpty && ponds.isEmpty ? h : WorldWater.shape(x, z, h, edges: edges, ponds: ponds)
    }

    /// The water at a place, if any (river over pond over sea), with the ground there (`ground`), of the water near it.
    static func sample(_ x: Double, _ z: Double, ground: Float, edges: [Edge], ponds: [Pond], seaLevel: Float,
                       looks: (sea: Int, lake: Int, river: Int)) -> WaterSample? {
        let p = SIMD2(x, z)
        var best: (Double, Edge, Double)?
        for e in edges {
            let (d, t) = along(e, p)
            if d < Double(e.half) * 1.15, d < best?.0 ?? .infinity { best = (d, e, t) }
        }
        if let (d, e, t) = best {
            let (la, lb) = e.level
            let level = la + (lb - la) * Float(t)
            if ground < level + 0.05 || d < Double(e.half) * 0.9 {
                let length = Float(simd_distance(e.a, e.b)), slope = max(e.bedA - e.bedB, 0) / max(length, 1)
                let across = Float(min(d / Double(e.half), 1)), profile = max(1 - across * across, 0.15)
                let speed = min(1.2 * (0.6 + 25 * slope) * pow(8 / max(e.half * 2, 1), 0.3), 5)
                let along = SIMD2<Float>(simd_normalize(e.b - e.a))
                return WaterSample(level: level, flow: along * speed * profile, look: looks.river,
                                   turbulence: 0.7 * World.smoothstep(0.015, 0.07, slope) * profile)
            }
        }
        for o in ponds where Float(simd_distance(p, o.center)) < o.radius * 1.05 && ground < o.level + 0.05 {
            return WaterSample(level: o.level, look: looks.lake)
        }
        if ground < seaLevel + 0.05 { return WaterSample(level: seaLevel, look: looks.sea) }
        return nil
    }

    /// Whether a place is in the water or on its very edge (no tree, no bush there).
    func wet(_ x: Double, _ z: Double, ground: Float, margin: Float = 1.5) -> Bool {
        if ground < seaLevel + 0.4 { return true }
        let (edges, ponds) = near(lo: SIMD2(x, z), hi: SIMD2(x, z))
        let p = SIMD2(x, z)
        for e in edges where WorldWater.along(e, p).distance < Double(e.half + margin) { return true }
        for o in ponds where Float(simd_distance(p, o.center)) < o.radius + margin { return true }
        return false
    }

    /// The rivers' steps in chains (each from a step no other in the square leads into, along the next ones) and the
    /// ponds in the square from `lo` to `hi`: what a scene's water surfaces are.
    func contents(lo: SIMD2<Double>, hi: SIMD2<Double>) -> (edges: [Edge], chains: [[Int]], ponds: [Pond]) {
        let (edges, ponds) = near(lo: lo, hi: hi)
        var index: [SIMD2<Double>: Int] = [:]
        for (k, e) in edges.enumerated() { index[e.a] = k }
        let entered = Set(edges.map(\.b))
        var chains: [[Int]] = [], used = Set<Int>()
        for (k, e) in edges.enumerated() where !entered.contains(e.a) {
            var chain: [Int] = [], at = k
            while !used.contains(at) {
                chain.append(at)
                used.insert(at)
                guard let n = index[edges[at].b] else { break }
                at = n
            }
            chains.append(chain)
        }
        for k in edges.indices where !used.contains(k) { chains.append([k]) }
        return (edges, chains, ponds)
    }
}

/// The open world's water for the water map (WaterMap): the world's (WorldWater), with the looks the scene gave it.
/// A band of the map's rows gets the rivers and ponds over it once, then works out its texels without asking again.
final class WorldWaterField: WaterField {
    let world: World
    let looks: (sea: Int, lake: Int, river: Int)
    package init(world: World, looks: (sea: Int, lake: Int, river: Int)) { (self.world, self.looks) = (world, looks) }
    func ground(_ x: Double, _ z: Double) -> Float { world.water.carve(x, z, world.water.natural(x, z)) }
    func water(_ x: Double, _ z: Double, ground: Float) -> WaterSample? {
        let (edges, ponds) = world.water.near(lo: SIMD2(x, z), hi: SIMD2(x, z))
        return WorldWater.sample(x, z, ground: ground, edges: edges, ponds: ponds, seaLevel: world.water.seaLevel, looks: looks)
    }

    func draw(rows: Range<Int>, origin: SIMD2<Double>, cell: Double, size n: Int, surface: UnsafeMutablePointer<SIMD2<Float>>,
              info: UnsafeMutablePointer<UInt32>) {
        let w = world.water, sea = w.seaLevel
        let lo = origin + SIMD2(0, Double(rows.lowerBound) * cell), hi = origin + SIMD2(Double(n) * cell, Double(rows.upperBound) * cell)
        let (allEdges, allPonds) = w.near(lo: lo, hi: hi)
        // (Per 64 texels of a row, the ones near them.)
        let chunk = 64
        for j in rows {
            let z = origin.y + (Double(j) + 0.5) * cell
            for c0 in stride(from: 0, to: n, by: chunk) {
                let x0 = origin.x + Double(c0) * cell, x1 = x0 + Double(chunk) * cell
                let edges = allEdges.filter { e in
                    let m = Double(e.half) * 2 + cell
                    return max(e.a.x, e.b.x) > x0 - m && min(e.a.x, e.b.x) < x1 + m && max(e.a.y, e.b.y) > z - m && min(e.a.y, e.b.y) < z + m
                }
                let ponds = allPonds.filter { o in
                    let m = Double(o.radius) * 1.8 + cell
                    return o.center.x > x0 - m && o.center.x < x1 + m && abs(o.center.y - z) < m
                }
                for i in c0..<min(c0 + chunk, n) {
                    let x = origin.x + (Double(i) + 0.5) * cell
                    let natural = w.natural(x, z)
                    let g = edges.isEmpty && ponds.isEmpty ? natural : WorldWater.shape(x, z, natural, edges: edges, ponds: ponds)
                    guard let s = WorldWater.sample(x, z, ground: g, edges: edges, ponds: ponds, seaLevel: sea, looks: looks) else {
                        surface[j * n + i] = SIMD2(WaterMap.dry, g)
                        continue
                    }
                    surface[j * n + i] = SIMD2(s.level, g)
                    info[j * n + i] = WaterMap.pack(s)
                }
            }
        }
    }
}
