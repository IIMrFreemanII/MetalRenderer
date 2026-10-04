import Foundation
import simd

/// The city's layout, from its settings alone (no geometry yet): a street grid with jittered block sizes and wider
/// avenues through the middle, each block's district style and its lots, and where the street lamps and trees
/// stand. Seeded: the same settings always give the same plan. Metres; the city is centred on the origin, x and z.
///
/// A block is either built on, or a park. Its lots depend on its style: houses and apartment blocks stand shoulder
/// to shoulder around the block's edge with a courtyard behind them (or back to back if the block is narrow);
/// towers and warehouses stand free, a few to a block. A lot knows what is on each of its four sides: a street,
/// open ground (a courtyard, a yard), or a neighbour's wall.
struct CityPlan {
    /// An axis-aligned rectangle on the ground: `lo` and `hi` are (x, z).
    struct Rect: Equatable {
        var lo: SIMD2<Float>, hi: SIMD2<Float>
        var size: SIMD2<Float> { hi - lo }
        var center: SIMD2<Float> { (lo + hi) / 2 }
        func inset(_ d: Float) -> Rect { Rect(lo: lo + SIMD2(d, d), hi: hi - SIMD2(d, d)) }
        func contains(_ r: Rect, tolerance: Float = 1e-3) -> Bool {
            r.lo.x >= lo.x - tolerance && r.lo.y >= lo.y - tolerance && r.hi.x <= hi.x + tolerance && r.hi.y <= hi.y + tolerance
        }
        func overlaps(_ r: Rect, tolerance: Float = 1e-3) -> Bool {
            r.lo.x < hi.x - tolerance && r.hi.x > lo.x + tolerance && r.lo.y < hi.y - tolerance && r.hi.y > lo.y + tolerance
        }
    }

    /// What a lot's side looks onto.
    enum Edge: Equatable {
        case street     // the building's front, or a corner lot's other street side
        case open       // a courtyard, a yard, a plaza: windows, but no shop fronts or doors
        case party      // a neighbour stands against it: a blank wall
    }

    /// A building's site. The building is made in the lot's own frame: its width along x, its depth along z, its
    /// front toward +z, standing on y = 0 around the origin. `yaw` turns that frame into the world.
    struct Lot {
        var rect: Rect
        var yaw: Float
        /// front (+z), right (+x), back (-z), left (-x), in the lot's frame.
        var edges: [Edge]
        var style: CityStyle            // never .mixed
        var floors: Int
        var seed: UInt64
        var block: Int

        /// Width (across the front) and depth.
        var size: SIMD2<Float> {
            let s = rect.size
            return abs(sin(yaw)) > 0.5 ? SIMD2(s.y, s.x) : s
        }
        var transform: float4x4 { translate([rect.center.x, 0, rect.center.y]) * rotate(yaw, [0, 1, 0]) }
        /// The world direction (x, z) the front faces.
        var front: SIMD2<Float> { SIMD2(sin(yaw), cos(yaw)).rounded(.toNearestOrAwayFromZero) }
    }

    struct Block {
        var rect: Rect                  // kerb to kerb: the sidewalk and what stands inside it
        var style: CityStyle            // never .mixed
        var park = false
    }

    /// A stretch of road between the kerbs, with `along` = 0 for one running along x, 1 along z.
    struct Street {
        var rect: Rect
        var along: Int
    }

    struct Lamp {
        var position: SIMD2<Float>
        var toRoad: SIMD2<Float>        // unit, from the pole to the road it lights
        var block: Int
    }

    enum View { case overview, street, facade }

    static let sidewalk: Float = 3.5
    static let margin: Float = 300      // open ground around the outermost streets

    let settings: CitySettings
    let seed: Int
    private(set) var blocks: [Block] = []
    private(set) var lots: [Lot] = []
    private(set) var streets: [Street] = []
    private(set) var lamps: [Lamp] = []
    private(set) var trees: [SIMD3<Float>] = []         // x, z and the tree's size
    /// The streets and everything inside them.
    private(set) var extent = Rect(lo: .zero, hi: .zero)

    init(_ settings: CitySettings, seed: Int = 1) {
        self.settings = settings
        self.seed = seed
        let n = max(settings.blocks, 1)
        var rng = SplitMix64(seed: 0xC17F_0000 ^ UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9)

        // The grid: block sizes, and the roads between and around them (the middle ones are avenues).
        func roads(_ count: Int) -> [Float] {
            (0...count).map { i in count >= 4 && i == count / 2 ? 15 : count >= 8 && i % 4 == count / 2 % 4 ? 12 : 9 }
        }
        let widths = (0..<n).map { _ in rng.range(58, 84) }, depths = (0..<n).map { _ in rng.range(46, 64) }
        let roadsX = roads(n), roadsZ = roads(n)
        func starts(_ sizes: [Float], _ roads: [Float]) -> (lo: [Float], total: Float) {
            var at = roads[0], lo: [Float] = []
            for i in sizes.indices { lo.append(at); at += sizes[i] + roads[i + 1] }
            return (lo.map { $0 - at / 2 }, at)
        }
        let (x0, totalX) = starts(widths, roadsX), (z0, totalZ) = starts(depths, roadsZ)
        extent = Rect(lo: SIMD2(-totalX / 2, -totalZ / 2), hi: SIMD2(totalX / 2, totalZ / 2))
        for i in 0...n {   // the roads running along z, then the ones along x
            let lo = i < n ? x0[i] - roadsX[i] : extent.hi.x - roadsX[n]
            streets.append(Street(rect: Rect(lo: SIMD2(lo, extent.lo.y), hi: SIMD2(lo + roadsX[i], extent.hi.y)), along: 1))
        }
        for j in 0...n {
            let lo = j < n ? z0[j] - roadsZ[j] : extent.hi.y - roadsZ[n]
            streets.append(Street(rect: Rect(lo: SIMD2(extent.lo.x, lo), hi: SIMD2(extent.hi.x, lo + roadsZ[j])), along: 0))
        }

        // Districts: towers in the middle, old houses and warehouses at the edge; one block near the middle is a park.
        let mid = Float(n - 1) / 2
        let park = n >= 3 ? (Int(mid) + (rng.next() < 0.5 ? 1 : -1), Int(mid + 0.5) - (n % 2 == 0 ? rng.int(2) : 0)) : (-1, -1)
        for j in 0..<n {
            for i in 0..<n {
                let rect = Rect(lo: SIMD2(x0[i], z0[j]), hi: SIMD2(x0[i] + widths[i], z0[j] + depths[j]))
                let ring = max(abs(Float(i) - mid), abs(Float(j) - mid)) / max(mid, 0.5)
                let style = CityPlan.district(settings.style, ring: n == 1 ? 0.6 : ring, &rng)
                blocks.append(Block(rect: rect, style: style, park: settings.style == .mixed && (i, j) == park))
            }
        }

        for b in blocks.indices {
            let ring = n == 1 ? 0.6 : simd_reduce_max(abs(blocks[b].rect.center / (extent.size / 2)))
            if !blocks[b].park { subdivide(block: b, ring: ring, &rng) }
            furnish(block: b, &rng)
        }
        for i in lots.indices {
            lots[i].seed = SplitMix64.mix(UInt64(truncatingIfNeeded: seed) &* 0x1_0000_0001 &+ UInt64(i) &* 0x9E37_79B9_7F4A_7C15)
        }
    }

    /// A block's style in a city of `style`: for the mixed city, by how far out the block is (`ring`: 0 = the middle,
    /// 1 = the outermost blocks), with some noise.
    private static func district(_ style: CityStyle, ring: Float, _ rng: inout SplitMix64) -> CityStyle {
        guard style == .mixed else { return style }
        let t = ring + rng.range(-0.2, 0.2), pick = rng.next()
        if t < 0.42 { return pick < 0.7 ? .office : .modern }
        if t < 0.8 { return pick < 0.45 ? .modern : pick < 0.9 ? .residential : .office }
        return pick < 0.4 ? .residential : pick < 0.75 ? .oldtown : .warehouse
    }

    private static func floors(_ style: CityStyle, ring: Float, _ rng: inout SplitMix64) -> Int {
        switch style {
        case .office: return max(8, Int((34 - 20 * min(ring, 1)) * rng.range(0.6, 1.15)))
        case .modern: return 5 + rng.int(9)
        case .residential: return 4 + rng.int(4)
        case .oldtown: return 2 + rng.int(3)
        case .warehouse: return 1 + rng.int(2)
        case .mixed: return 4
        }
    }

    // MARK: - Lots

    /// The lots of block `b`: around its edge for houses and apartment blocks, free-standing for towers and halls.
    private mutating func subdivide(block b: Int, ring: Float, _ rng: inout SplitMix64) {
        let style = blocks[b].style
        let site = blocks[b].rect.inset(CityPlan.sidewalk)
        let size = site.size
        func add(_ rect: Rect, yaw: Float, world: [Edge], style lotStyle: CityStyle? = nil) {
            // `world`: what is toward +z, +x, -z, -x; the lot's own sides are those, turned by its yaw.
            let turn = Int((yaw / (.pi / 2)).rounded()) & 3
            let s = lotStyle ?? style
            lots.append(Lot(rect: rect, yaw: yaw, edges: (0..<4).map { world[($0 + turn) & 3] }, style: s,
                            floors: CityPlan.floors(s, ring: ring, &rng), seed: 0, block: b))
        }
        /// `length` cut into pieces of about `width`: the cuts' positions from 0 to `length`.
        func cuts(_ length: Float, _ width: ClosedRange<Float>) -> [Float] {
            let count = max(1, Int((length / rng.range(width.lowerBound, width.upperBound)).rounded()))
            let shares = (0..<count).map { _ in rng.range(0.8, 1.2) }, total = shares.reduce(0, +)
            var at: Float = 0
            return [0] + shares.map { share -> Float in at += share / total * length; return at }.dropLast() + [length]
        }

        switch style {
        case .office, .warehouse:
            // Free-standing: a grid of big lots with a gap between them, each facing its nearest street.
            let target: Float = style == .office ? 38 : 34, gap: Float = style == .office ? 5 : 4
            let nx = max(1, Int((size.x / target).rounded())), nz = max(1, Int((size.y / target).rounded()))
            let cell = SIMD2((size.x - gap * Float(nx - 1)) / Float(nx), (size.y - gap * Float(nz - 1)) / Float(nz))
            for j in 0..<nz {
                for i in 0..<nx {
                    let lo = site.lo + SIMD2(Float(i), Float(j)) * (cell + SIMD2(gap, gap))
                    let world: [Edge] = [j == nz - 1 ? .street : .open, i == nx - 1 ? .street : .open,
                                         j == 0 ? .street : .open, i == 0 ? .street : .open]
                    // The front: a street side, the one along z if there is a choice (the longer blocks' sides).
                    let yaw: Float = j == nz - 1 ? 0 : j == 0 ? .pi : i == nx - 1 ? .pi / 2 : -.pi / 2
                    add(Rect(lo: lo, hi: lo + cell), yaw: yaw, world: world)
                }
            }
        case .oldtown, .residential, .modern, .mixed:
            let widths: ClosedRange<Float> = style == .oldtown ? 7...11 : style == .residential ? 14...22 : 20...32
            let depth: Float = style == .oldtown ? rng.range(10, 13) : style == .residential ? rng.range(12, 15) : rng.range(14, 17)
            func infill() -> CityStyle? {   // now and then a newer building among the others
                style == .residential && rng.next() < 0.12 ? .modern : style == .oldtown && rng.next() < 0.08 ? .residential : nil
            }
            if size.y < 2 * depth + 9 {
                // Too narrow for a courtyard: two rows back to back.
                let half = size.y / 2
                for (row, yaw) in [(0, Float.pi), (1, Float(0))] {
                    let x = cuts(size.x, widths)
                    for k in 0..<x.count - 1 {
                        let lo = SIMD2(site.lo.x + x[k], site.lo.y + Float(row) * half)
                        let world: [Edge] = [row == 1 ? .street : .party, k == x.count - 2 ? .street : .party,
                                             row == 0 ? .street : .party, k == 0 ? .street : .party]
                        add(Rect(lo: lo, hi: SIMD2(site.lo.x + x[k + 1], lo.y + half)), yaw: yaw, world: world, style: infill())
                    }
                }
            } else {
                // A ring: full rows along the two long sides, shorter ones between them at the ends.
                for (row, yaw) in [(0, Float.pi), (1, Float(0))] {
                    let x = cuts(size.x, widths)
                    for k in 0..<x.count - 1 {
                        let z = row == 0 ? site.lo.y : site.hi.y - depth
                        let first = k == 0, last = k == x.count - 2
                        // The end lots turn the corner; the ones next to them have the side rows behind them.
                        let behind: Edge = x[k + 1] <= depth + 0.5 || x[k] >= size.x - depth - 0.5 ? .party : .open
                        let world: [Edge] = [row == 1 ? .street : behind, last ? .street : .party,
                                             row == 0 ? .street : behind, first ? .street : .party]
                        add(Rect(lo: SIMD2(site.lo.x + x[k], z), hi: SIMD2(site.lo.x + x[k + 1], z + depth)), yaw: yaw, world: world,
                            style: infill())
                    }
                }
                for (side, yaw) in [(0, -Float.pi / 2), (1, Float.pi / 2)] {
                    let z = cuts(size.y - 2 * depth, widths)
                    for k in 0..<z.count - 1 {
                        let x = side == 0 ? site.lo.x : site.hi.x - depth
                        let world: [Edge] = [.party, side == 1 ? .street : .open, .party, side == 0 ? .street : .open]
                        add(Rect(lo: SIMD2(x, site.lo.y + depth + z[k]), hi: SIMD2(x + depth, site.lo.y + depth + z[k + 1])),
                            yaw: yaw, world: world, style: infill())
                    }
                }
            }
        }
    }

    // MARK: - Street furniture

    /// Lamps along block `b`'s kerb with a tree between each two, and a park's trees.
    private mutating func furnish(block b: Int, _ rng: inout SplitMix64) {
        let rect = blocks[b].rect, inner = rect.inset(0.9)
        let size = inner.size
        for side in 0..<4 {
            // Along the side from one corner to the next, counter-clockwise from the -z side.
            let horizontal = side % 2 == 0
            let length = horizontal ? size.x : size.y
            let count = max(2, Int((length / 24).rounded()))
            let out: SIMD2<Float> = [SIMD2(0, -1), SIMD2(1, 0), SIMD2(0, 1), SIMD2(-1, 0)][side]
            func at(_ t: Float) -> SIMD2<Float> {
                switch side {
                case 0: return SIMD2(inner.lo.x + t * length, inner.lo.y)
                case 1: return SIMD2(inner.hi.x, inner.lo.y + t * length)
                case 2: return SIMD2(inner.hi.x - t * length, inner.hi.y)
                default: return SIMD2(inner.lo.x, inner.hi.y - t * length)
                }
            }
            for k in 0..<count {
                lamps.append(Lamp(position: at((Float(k) + 0.25) / Float(count)), toRoad: out, block: b))
                let p = at((Float(k) + 0.75) / Float(count))
                if rng.next() < 0.8 { trees.append(SIMD3(p.x, p.y, rng.range(0.8, 1.15))) }
            }
        }
        if blocks[b].park {
            let lawn = rect.inset(CityPlan.sidewalk + 3)
            for _ in 0..<Int(lawn.size.x * lawn.size.y / 90) {
                trees.append(SIMD3(rng.range(lawn.lo.x, lawn.hi.x), rng.range(lawn.lo.y, lawn.hi.y), rng.range(1.0, 1.8)))
            }
        }
    }

    // MARK: - Cameras

    /// Where to look at the city from: above a corner, from a pavement in the middle, or in front of one building.
    func camera(_ view: View) -> Camera {
        func looking(from position: SIMD3<Float>, at target: SIMD3<Float>) -> Camera {
            var c = Camera()
            let d = normalize(target - position)
            c.position = position
            c.yaw = atan2(d.x, -d.z)
            c.pitch = asin(d.y)
            return c
        }
        let size = extent.size
        // The road nearest the middle that runs along z, and the block on its -x side nearest the middle.
        let road = streets.filter { $0.along == 1 }.min { abs($0.rect.center.x) < abs($1.rect.center.x) }!
        switch view {
        case .overview:
            // Far enough off a corner to take in the tallest building.
            let reach = max(size.x, size.y), tallest = Float(lots.map(\.floors).max() ?? 4) * 3.4
            return looking(from: [extent.hi.x + 4 + 0.04 * reach + 0.1 * tallest, 12 + 0.26 * reach + 0.1 * tallest,
                                  extent.hi.y + 8 + 0.16 * reach + 0.2 * tallest],
                           at: [0, 0.03 * reach + 0.25 * tallest, 0])
        case .street:
            // On the kerb near the far end of the middle road, looking back down it.
            let x = road.rect.hi.x - 1.2, z = min(extent.hi.y - 4, road.rect.center.y + 70)
            return looking(from: [x, 1.7, z], at: [road.rect.center.x - 2, 9, z - 60])
        case .facade:
            // Across the street from the lot nearest the middle that faces +z.
            let facing = lots.filter { $0.front == SIMD2(0, 1) && $0.edges[0] == .street }
            guard let lot = facing.min(by: { length($0.rect.center) < length($1.rect.center) }) else { return camera(.street) }
            let c = lot.rect.center
            return looking(from: [c.x + 5, 3.2, lot.rect.hi.y + 15], at: [c.x - 1, 5.5, lot.rect.hi.y])
        }
    }
}

extension SplitMix64 {
    /// One well-mixed value from `x`: a seed for something's own generator.
    static func mix(_ x: UInt64) -> UInt64 {
        var g = SplitMix64(seed: x)
        return g.nextUInt64()
    }
}
