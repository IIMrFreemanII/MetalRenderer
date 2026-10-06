import Foundation
import simd

/// The open world: its ground, its forests and its cities as a function of a seed and a place, with no edge. Nothing
/// here keeps what it has made: asked twice, in any order, a place is the same, so the world can be made a tile at a
/// time around whoever looks at it (WorldTile.swift) and forgotten behind them.
///
/// Places are doubles (metres; x east, z south, y up), so that 50 km out is as exact as the origin; what is made for
/// a tile is in floats from the tile's corner.
///
///   Ground   broad hills (2 km across, tens of metres high) with the forest scene's rolling ground on top.
///   Cities   at most one to a 4 km cell, a disc of 300...900 m on ground levelled to its middle's height, its
///            streets a grid in the world's axes. A block is made from the seed and its place in the grid alone, and
///            a road lies along every side of a block that is built: the country's ground begins at the last road.
///   Roads    from a city to the cities of the four cells next to its own, each leaving by the end of the street
///            through the city's middle. The ground is the road's own for 10 m either side of its middle, and banked
///            back into the hills beyond.
///   Forest   one candidate tree to a cell of a grid over the whole world, each from its cell's own random numbers;
///            wooded and open country alternate over half a kilometre; none in a city.
struct World {
    let seed: UInt64
    /// Trees to a hectare of full forest (the Forest scene's 2500 on its 320 m).
    var treeDensity: Float = 244
    /// Bushes, ferns and grass: 1 = the Forest scene's.
    var undergrowth: Float = 1
    /// The share of the 4 km cells with a city in them. (The cell around the origin always has one.)
    var cityShare: Float = 0.5
    /// The share of the cities' windows with a light behind them, which is on at night.
    var lit: Float = 0.35

    /// Of everything below: a change of what a place looks like makes other tile files (WorldTile).
    static let version = 6
    static let tileSize: Float = 256
    static let cityCell = 4096.0
    /// A tile's levels of detail: 0 next to the viewer, 2 at the edge of what is seen.
    static let levels = 3
    /// The side of a ground cell at a level, metres.
    static func cellSize(_ level: Int) -> Float { level == 0 ? 1 : level == 1 ? 4 : 16 }
    /// Kerb to kerb, and from one block's corner to the next's: the roads between are 12 m.
    static let blockSize = SIMD2<Float>(72, 56), blockPitch = SIMD2<Float>(84, 68)
    static let roadWidth: Float = 12
    /// What the underside of a street lamp's head emits at night.
    static let lampEmission = SIMD3<Float>(1.0, 0.78, 0.5) * 140
    /// How far beyond a city's radius its ground is level (its last roads are out there, and the coarsest ground's
    /// cells under them have to be level too), and how far beyond that it rises back into the hills.
    static let cityApron: Float = 40, cityBlend: Float = 300

    private let broadSeed: UInt32, rollingSeed: UInt32, coverSeed: UInt32, standSeed: UInt32
    /// The beds of the roads between cities that have been asked for (`bed`): each is worked out once.
    private let roadbeds = Roadbeds()

    init(seed: UInt64) {
        self.seed = seed
        let s = UInt32(truncatingIfNeeded: seed &* 0x9E37_79B9 &+ 17)
        (broadSeed, rollingSeed, coverSeed, standSeed) = (s &+ 400, s, s &+ 500, s &+ 101)
    }

    /// Random numbers of a thing's own: from the world's seed, the thing's two whole coordinates and what it is.
    static func hash(_ seed: UInt64, _ a: Int, _ b: Int, _ what: UInt64) -> UInt64 {
        SplitMix64.mix(seed ^ UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: Int64(b)) &* 0xC2B2_AE3D_27D4_EB4F
                       ^ what &* 0x1656_67B1_9E37_79F9)
    }

    @inline(__always) private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Cities

    struct City: Equatable {
        var cell: SIMD2<Int>
        var center: SIMD2<Double>       // a multiple of 16 m, so its streets lie on the ground's cells
        var radius: Float               // of what is built
        var level: Float                // its ground's height
        var seed: UInt64
        /// Its roads to the cities of the cells east, west, south and north of its own: those of them that have one.
        var highways: [Highway] = []
    }

    /// The city of a 4 km cell, if it has one. It and the ground it levels stay 88 m inside the cell.
    func city(cell: SIMD2<Int>) -> City? {
        guard var city = site(cell: cell) else { return nil }
        for axis in 0..<2 {
            let next = axis == 0 ? SIMD2(1, 0) : SIMD2(0, 1)
            if let other = site(cell: cell &+ next) { city.highways.append(highway(from: city, to: other, axis: axis)) }
            if let other = site(cell: cell &- next) { city.highways.append(highway(from: other, to: city, axis: axis)) }
        }
        return city
    }

    /// A cell's city without its highways.
    private func site(cell: SIMD2<Int>) -> City? {
        let own = World.hash(seed, cell.x, cell.y, 0xC17)
        var rng = SplitMix64(seed: own)
        let roll = rng.next(), radius = rng.range(300, 900), u = Double(rng.next()), v = Double(rng.next())
        guard cell == SIMD2(0, 0) || roll < cityShare else { return nil }
        let margin = Double(radius + World.cityBlend) + 128, span = World.cityCell - 2 * margin
        func snap(_ c: Double) -> Double { (c / 16).rounded() * 16 }
        let center = SIMD2(snap(Double(cell.x) * World.cityCell + margin + u * span), snap(Double(cell.y) * World.cityCell + margin + v * span))
        return City(cell: cell, center: center, radius: radius, level: broad(center.x, center.y), seed: own)
    }

    private static func cell(_ x: Double, _ z: Double) -> SIMD2<Int> {
        SIMD2(Int((x / World.cityCell).rounded(.down)), Int((z / World.cityCell).rounded(.down)))
    }

    func city(near x: Double, _ z: Double) -> City? { city(cell: World.cell(x, z)) }

    /// 1 on a city's level ground, 0 where the hills are their own again.
    func cityMask(_ city: City?, _ x: Double, _ z: Double) -> Float {
        guard let city else { return 0 }
        let d = Float(((x - city.center.x) * (x - city.center.x) + (z - city.center.y) * (z - city.center.y)).squareRoot())
        let level = city.radius + World.cityApron
        return 1 - World.smoothstep(level, level + World.cityBlend, d)
    }

    /// Whether a place is in the open ground around a city, where no tree stands: a belt from its level ground out,
    /// 30 m wide here and 250 m there.
    func belt(_ city: City?, _ x: Double, _ z: Double) -> Bool {
        let mask = cityMask(city, x, z)
        guard mask > 0.1 else { return false }
        return mask > min(max(0.55 + 0.8 * Terrain.noise(x / 170, z / 170, seed: standSeed &+ 61), 0.1), 0.97)
    }

    /// What grows on a place in a city's belt: the belt is fields, two to a cell of 128 by 96 m of a grid in the
    /// city's axes (or one), each a meadow, a crop or ploughed earth. Their sides are multiples of 16 m from the
    /// city's middle: on the ground's cells at every level. Nil outside the belt.
    func field(_ city: City?, _ x: Double, _ z: Double) -> Int? {
        guard let city, belt(city, x, z) else { return nil }
        let p = SIMD2(x - city.center.x, z - city.center.y)
        let a = (p.x / 128).rounded(.down), b = (p.y / 96).rounded(.down)
        var rng = SplitMix64(seed: World.hash(city.seed, Int(a), Int(b), 0xF1E1D))
        let split = 32 + 16 * Double(rng.int(5)), two = rng.next() < 0.6, first = rng.next(), second = rng.next()
        let crop = two && p.x - a * 128 >= split ? second : first
        return crop < 0.35 ? Ground.meadow : crop < 0.6 ? Ground.wheat : crop < 0.85 ? Ground.crop : Ground.ploughed
    }

    // MARK: - The ground

    private func broad(_ x: Double, _ z: Double) -> Float { 70 * Terrain.fbm(x / 1800, z / 1800, octaves: 4, seed: broadSeed) }

    /// The ground's height. `city`: the one of the place's 4 km cell (`city(near:)`), found once for many places.
    func height(_ x: Double, _ z: Double, city: City?) -> Float {
        let natural = broad(x, z) + 15.3 * Terrain.fbm(x / 120, z / 120, octaves: 5, seed: rollingSeed)
        guard let city else { return natural }
        let mask = cityMask(city, x, z)
        var h = mask <= 0 ? natural : mask >= 1 ? city.level : natural + (city.level - natural) * mask
        for road in city.highways {
            guard let d = road.distance(x, z), d < Highway.shoulder + Highway.widestBank else { continue }
            let (own, bank) = road.bed(road.axis == 0 ? x : z)
            if d <= Highway.shoulder { h = own } else if d < Highway.shoulder + bank {
                h += (own - h) * (1 - World.smoothstep(Highway.shoulder, Highway.shoulder + bank, d))
            }
        }
        return h
    }

    func height(_ x: Double, _ z: Double) -> Float { height(x, z, city: city(near: x, z)) }

    /// The ground's height as it is without the roads between cities: what a road is cut into or banked over.
    func country(_ x: Double, _ z: Double) -> Float { height(x, z, city: site(cell: World.cell(x, z))) }

    /// 1 in the woods, 0 in open country.
    func woods(_ x: Double, _ z: Double) -> Float { World.smoothstep(-0.12, 0.1, Terrain.fbm(x / 420, z / 420, octaves: 3, seed: coverSeed)) }

    /// What the ground is made of at a place: an index into `groundMaterials`. `up`: its normal's y. (A city's roads
    /// and blocks lie on it: on the fields that are all around the city.)
    func ground(_ x: Double, _ z: Double, up: Float, city: City?) -> Int {
        if up < 0.8 { return Ground.rock }
        if let road = highway(city, x, z), road.distance < Highway.shoulder { return Ground.meadow }
        if let field = field(city, x, z) { return field }
        if woods(x, z) + 0.2 * Terrain.noise(x / 14, z / 14, seed: standSeed &+ 32) < 0.5 { return Ground.meadow }
        return Terrain.noise(x / 9, z / 9, seed: standSeed &+ 31) > 0.18 ? Ground.moss : Ground.litter
    }

    enum Ground {
        static let litter = 0, moss = 1, meadow = 2, rock = 3, wheat = 4, crop = 5, ploughed = 6
    }

    /// The ground's materials (`ground`'s indices). They name the ground's detail texture, or a sown field's rows,
    /// which their colours are divided by the mean of (FoliageTextures.mean).
    static let groundMaterials: [GPUMaterial] = {
        func natural(_ c: SIMD3<Float>, _ texture: UInt32 = groundDetail) -> GPUMaterial {
            var m = GPUMaterial(albedo: SIMD4(c / FoliageTextures.mean, 0), emission: SIMD4(.zero, 1))
            m.textures.x = texture
            return m
        }
        return [natural([0.15, 0.13, 0.075]), natural([0.09, 0.135, 0.05]), natural([0.2, 0.3, 0.1]), natural([0.24, 0.23, 0.21]),
                natural([0.42, 0.36, 0.15], fieldRows), natural([0.13, 0.24, 0.07], fieldRows), natural([0.19, 0.14, 0.095], fieldRows)]
    }()
    /// `GPUMaterial.textures.x` of a material with the ground's detail texture, or with a field's rows
    /// (Scene+World.swift makes them), and the side of one repeat of either, metres.
    static let groundDetail: UInt32 = 0x4100_0000, fieldRows: UInt32 = 0x4100_0001, groundTile: Float = 5

    /// A tile's materials name a generated surface's textures by its kind, in `GPUMaterial.textures.x`: whoever puts
    /// the tile into a scene puts that scene's texture indices there.
    static func texture(_ kind: SurfaceKind) -> UInt32 { 0x4000_0000 | UInt32(kind.rawValue) }
    static func kind(ofTexture code: UInt32) -> SurfaceKind? { code & 0xFFFF_FF00 == 0x4000_0000 ? SurfaceKind(rawValue: Int(code & 0xFF)) : nil }

    // MARK: - Plants

    /// A plant in a tile: where it stands (metres from the tile's corner; y the world's), turned and scaled, and which
    /// plant of the world's library it is. 32 bytes, as the tile's file holds it.
    struct Placement: Equatable {
        var x: Float, y: Float, z: Float
        var yaw: Float
        var size: Float
        var species: UInt16
        var plant: UInt16               // its index in its species' set (Foliage.SpeciesSet.plants)
        var shade: UInt16               // which of the species' leaf colours
        var pad: UInt16 = 0
        var pad1: UInt32 = 0
    }

    /// The library's plants by species and age, as their indices: all the placing needs to know of it.
    struct Flora {
        private var byAge: [[[Int]]]    // species, age, plants

        init(_ sets: [Foliage.SpeciesSet]) {
            byAge = Foliage.Species.allCases.map { _ in Foliage.Age.allCases.map { _ in [] } }
            for set in sets {
                for age in Foliage.Age.allCases { byAge[set.species.rawValue][age.rawValue] = set.plants(of: age) }
            }
        }

        /// The species' plants of an age; the mature ones if it has none that young.
        func plants(_ species: Foliage.Species, _ age: Foliage.Age) -> [Int] {
            let some = byAge[species.rawValue][age.rawValue]
            return some.isEmpty ? byAge[species.rawValue][Foliage.Age.mature.rawValue] : some
        }
    }

    /// The side of the grid cell that holds one candidate tree.
    var treeCell: Double { Double((10_000 / (max(treeDensity, 1) * 2.6)).squareRoot()) }

    /// One candidate to each cell of a grid of `cell` metres over the world, for the cells whose candidate stands in
    /// the square from (x0, z0), `side` across: `body` gets the candidate's place and its cell's random numbers.
    private func candidates(x0: Double, z0: Double, side: Double, cell: Double, what: UInt64,
                            _ body: (_ x: Double, _ z: Double, _ rng: inout SplitMix64) -> Void) {
        let i0 = Int((x0 / cell).rounded(.down)) - 1, i1 = Int(((x0 + side) / cell).rounded(.down)) + 1
        let j0 = Int((z0 / cell).rounded(.down)) - 1, j1 = Int(((z0 + side) / cell).rounded(.down)) + 1
        for j in j0...j1 {
            for i in i0...i1 {
                var rng = SplitMix64(seed: World.hash(seed, i, j, what))
                let x = (Double(i) + Double(rng.range(0.15, 0.85))) * cell, z = (Double(j) + Double(rng.range(0.15, 0.85))) * cell
                if x >= x0 && x < x0 + side && z >= z0 && z < z0 + side { body(x, z, &rng) }
            }
        }
    }

    private func up(_ x: Double, _ z: Double, city: City?) -> Float {
        let dx = height(x + 0.5, z, city: city) - height(x - 0.5, z, city: city)
        let dz = height(x, z + 0.5, city: city) - height(x, z - 0.5, city: city)
        return 1 / (1 + dx * dx + dz * dz).squareRoot()
    }

    /// The trees of the square from (x0, z0), `side` across (a tile), in the order of their cells: conifers up the
    /// hills and on slopes, oaks on low ground, birches at the woods' edge, a dead tree now and then.
    func trees(x0: Double, z0: Double, side: Double, flora: Flora) -> [Placement] {
        let city = city(near: x0 + side / 2, z0 + side / 2)
        var out: [Placement] = []
        candidates(x0: x0, z0: z0, side: side, cell: treeCell, what: 0x7EE) { x, z, rng in
            let chance = rng.next(), pick = rng.next(), u = rng.next()
            let yaw = rng.range(0, 2 * .pi), size = rng.range(0.85, 1.2), shade = rng.int(16), which = rng.next()
            let cover = woods(x, z)
            guard cover > 0, !belt(city, x, z), (highway(city, x, z)?.distance ?? .infinity) > Highway.shoulder + 1 else { return }
            let slope = 1 - up(x, z, city: city)
            let density = cover * World.smoothstep(0.72, 0.86, 1 - slope) * (0.6 + 0.6 * Terrain.noise(x / 23, z / 23, seed: standSeed &+ 7))
            guard chance < density else { return }
            let y = height(x, z, city: city), high = (y - broad(x, z)) / 9, mix = Terrain.noise(x / 55, z / 55, seed: standSeed)
            let conifer = max(0.05, 0.3 + 1.1 * World.smoothstep(-0.1, 0.7, high) + 3 * slope + 1.6 * mix)
            let oak = max(0.05, 0.9 - 0.7 * World.smoothstep(0, 0.7, high) - 1.6 * mix)
            let birch = 0.25 + 1.6 * (1 - World.smoothstep(0.15, 0.6, cover))
            var p = pick * (conifer + oak + birch) * 1.035
            let species: Foliage.Species
            if p < conifer { species = .conifer } else {
                p -= conifer
                if p < oak { species = .oak } else { species = p - oak < birch ? .birch : .dead }
            }
            let age: Foliage.Age = u < 0.12 ? .sapling : u < 0.4 ? .young : .mature
            let plants = flora.plants(species, age)
            guard !plants.isEmpty else { return }
            out.append(Placement(x: Float(x - x0), y: y - 0.12, z: Float(z - z0), yaw: yaw, size: size, species: UInt16(species.rawValue),
                                 plant: UInt16(plants[min(Int(which * Float(plants.count)), plants.count - 1)]), shade: UInt16(shade)))
        }
        return out
    }

    /// The bushes, ferns and grass of the square from (x0, z0), `side` across (a ground-cover cell): bushes and ferns
    /// in patches under the trees, grass in the open.
    func groundCover(x0: Double, z0: Double, side: Double, flora: Flora) -> [Placement] {
        let city = city(near: x0 + side / 2, z0 + side / 2)
        var out: [Placement] = []
        func scatter(_ species: Foliage.Species, cell: Double, what: UInt64, sizes: ClosedRange<Float>, sink: Float,
                     likely: (Double, Double) -> Float) {
            candidates(x0: x0, z0: z0, side: side, cell: cell, what: what) { x, z, rng in
                let chance = rng.next(), yaw = rng.range(0, 2 * .pi), size = rng.range(sizes.lowerBound, sizes.upperBound)
                let old = rng.next() < 0.5, which = rng.next(), shade = rng.int(16)
                // (None on a road, and none in a field that is not a meadow.)
                guard chance < likely(x, z) * min(undergrowth, 1), !paved(city, x, z, margin: 1.5),
                      (field(city, x, z) ?? Ground.meadow) == Ground.meadow else { return }
                if let road = highway(city, x, z), road.distance < road.half + 1 { return }
                let plants = flora.plants(species, old ? .mature : .young)
                guard !plants.isEmpty else { return }
                out.append(Placement(x: Float(x - x0), y: height(x, z, city: city) - sink, z: Float(z - z0), yaw: yaw, size: size,
                                     species: UInt16(species.rawValue), plant: UInt16(plants[min(Int(which * Float(plants.count)), plants.count - 1)]),
                                     shade: UInt16(shade)))
            }
        }
        let thick = Double(max(undergrowth, 1).squareRoot())   // more than the Forest's: a finer grid
        scatter(.bush, cell: 6.1 / thick, what: 0xB05, sizes: 0.8...1.3, sink: 0.05) { x, z in
            woods(x, z) * World.smoothstep(-0.25, 0.35, Terrain.noise(x / 28, z / 28, seed: standSeed &+ 31))
        }
        scatter(.fern, cell: 4 / thick, what: 0xFE2, sizes: 0.9...1.7, sink: 0.02) { x, z in
            woods(x, z) * World.smoothstep(-0.25, 0.35, Terrain.noise(x / 17, z / 17, seed: standSeed &+ 47))
        }
        scatter(.grass, cell: 2 / thick, what: 0x62A, sizes: 1.05...1.2, sink: 0) { x, z in
            (1 - 0.9 * woods(x, z)) * World.smoothstep(0.8, 0.9, up(x, z, city: city))
        }
        return out
    }

    // MARK: - Roads between cities

    /// The road from a city to the city of the next cell east of it (axis 0: it runs along x) or south of it (axis
    /// 1). It leaves the first by the street through its middle, where that street ends, and comes into the second
    /// the same way: straight on at both ends, swinging over from the one's line to the other's between them. So it
    /// is a graph over its axis, one place across (`across`) for each place along; and it stays between its two
    /// cities, in their two cells, where no other road of theirs comes.
    struct Highway: Equatable {
        var axis: Int
        /// Along the axis, where its curve begins and ends (`stub` beyond each city's last crossing); across it,
        /// where it is there: the cities' middles.
        var u0: Double, u1: Double, v0: Double, v1: Double
        /// Its bed at each knot along its axis, from knot `first` (which is at `first * knot` metres) to beyond its
        /// end: the road's height there, and how wide the bank beside it is.
        var first = 0
        var knots: [SIMD2<Float>] = []

        /// Its asphalt, away from the cities: it leaves one as wide as a street.
        static let width: Float = 8
        /// From its middle, how far the ground is the road's own (at one height across it: the ground's cells of 4 m
        /// under the asphalt are then level too). Beyond that the ground comes back to the country's over a bank:
        /// `bank` metres wide, or `slope` times what the road is over or under the country there, `widestBank` at most.
        static let shoulder: Float = 10, bank: Float = 36, slope: Float = 2.5, widestBank: Float = 120
        /// Its first metres from a city's last crossing are a street's: straight, and on the city's level ground.
        /// It stays on that level for `level` metres more, then comes down (or up) to its own over `ease`, or over
        /// half its length.
        static let stub: Float = 12, level = 32.0, ease = 700.0
        /// Its height is given every `knot` metres along its axis, and straight between: the side of the coarsest
        /// ground's cells, so that the ground under it is the same planes at every level.
        static let knot = 16.0

        /// Where it is across its axis `u` along it, and how fast that changes.
        func across(_ u: Double) -> (v: Double, slope: Double) {
            let t = min(max((u - u0) / (u1 - u0), 0), 1)
            return (v0 + (v1 - v0) * t * t * t * (t * (6 * t - 15) + 10), (v1 - v0) / (u1 - u0) * 30 * t * t * (1 - t) * (1 - t))
        }

        /// Half the width of its asphalt `u` along it: a street's at its ends, its own from 24 m on.
        func half(_ u: Double) -> Float {
            (Highway.width + (World.roadWidth - Highway.width) * (1 - World.smoothstep(0, 24, Float(min(u - u0, u1 - u))))) / 2
        }

        func place(_ u: Double, _ v: Double) -> SIMD2<Double> { axis == 0 ? SIMD2(u, v) : SIMD2(v, u) }

        /// Its height `u` along its axis, and how wide its bank is there: straight between its knots.
        func bed(_ u: Double) -> (level: Float, bank: Float) {
            let at = u / Highway.knot, k = at.rounded(.down), i = min(max(Int(k) - first, 0), knots.count - 2)
            let a = knots[i], b = knots[i + 1], both = a + (b - a) * Float(min(max(at - Double(first + i), 0), 1))
            return (both.x, both.y)
        }

        /// How far a place is from its middle line (across its direction there); nil beyond its ends.
        func distance(_ x: Double, _ z: Double) -> Float? {
            let u = axis == 0 ? x : z
            guard u >= u0 - Double(Highway.stub), u <= u1 + Double(Highway.stub) else { return nil }
            let (v, slope) = across(u)
            return Float(abs((axis == 0 ? z : x) - v) / (1 + slope * slope).squareRoot())
        }
    }

    /// How many blocks are built along an axis from the city's middle: the street through the middle ends at the
    /// crossing that many from it, on either side.
    func gate(_ city: City, axis: Int) -> Int {
        var n = 0
        while built(city, axis == 0 ? n : 0, axis == 1 ? n : 0) { n += 1 }
        return n
    }

    private func highway(from a: City, to b: City, axis: Int) -> Highway {
        func out(_ city: City) -> Double { Double(Float(gate(city, axis: axis)) * World.blockPitch[axis] + World.roadWidth / 2 + Highway.stub) }
        var road = Highway(axis: axis, u0: a.center[axis] + out(a), u1: b.center[axis] - out(b), v0: a.center[1 - axis], v1: b.center[1 - axis])
        road.first = Int(((road.u0 - Double(Highway.stub)) / Highway.knot).rounded(.down))
        road.knots = roadbeds.bed(SIMD3(a.cell.x, a.cell.y, axis)) { bed(of: road, from: a, to: b) }
        return road
    }

    /// The roads' beds that have been made, by the cell of the road's first city and its axis.
    private final class Roadbeds {
        private let lock = NSLock()
        private var beds: [SIMD3<Int>: [SIMD2<Float>]] = [:]

        func bed(_ key: SIMD3<Int>, make: () -> [SIMD2<Float>]) -> [SIMD2<Float>] {
            lock.lock()
            defer { lock.unlock() }
            if let known = beds[key] { return known }
            let made = make()
            beds[key] = made
            return made
        }
    }

    /// A road's bed (`Highway.knots`). The road lies on the broadest of the hills alone (the two widest of `broad`'s
    /// four waves): it goes through what rises above them in a cutting, and over what lies below on a bank. It
    /// leaves a city on the city's level, and comes to its own over `ease` metres.
    private func bed(of road: Highway, from a: City, to b: City) -> [SIMD2<Float>] {
        func hills(_ u: Double) -> Float {
            let p = road.place(u, road.across(u).v)
            return 70 * Terrain.fbm(p.x / 1800, p.y / 1800, octaves: 2, seed: broadSeed)
        }
        let level = Highway.level, ease = min(Highway.ease, (road.u1 - road.u0) / 2 - level)
        let lift0 = a.level - hills(road.u0 + level), lift1 = b.level - hills(road.u1 - level)
        func share(_ d: Double) -> Float {
            let t = Float(min(max(d / ease, 0), 1))
            return 1 - t * t * t * (t * (6 * t - 15) + 10)
        }
        let last = Int(((road.u1 + Double(Highway.stub)) / Highway.knot).rounded(.down)) + 1
        var heights: [Float] = [], apart: [Float] = []   // the road's, and how far it is from the country's
        for k in road.first...last {
            let u = Double(k) * Highway.knot, from = u - road.u0 - level, to = road.u1 - level - u
            let y = from <= 0 ? a.level : to <= 0 ? b.level : hills(u) + lift0 * share(from) + lift1 * share(to)
            let p = road.place(u, road.across(u).v)
            heights.append(y)
            apart.append(abs(country(p.x, p.y) - y))
        }
        // A bank is as wide as the deepest of the five knots around it asks for.
        return heights.indices.map { i in
            SIMD2(heights[i], min(max(Highway.bank, Highway.slope * apart[max(i - 2, 0)...min(i + 2, apart.count - 1)].max()!), Highway.widestBank))
        }
    }

    /// The nearest of a city's highways to a place: how far its middle line is, and half the width of its asphalt
    /// there. Nil with none within its bank.
    func highway(_ city: City?, _ x: Double, _ z: Double) -> (distance: Float, half: Float)? {
        guard let city else { return nil }
        var found: (distance: Float, half: Float)?
        for road in city.highways {
            let u = road.axis == 0 ? x : z
            guard let d = road.distance(x, z), d < found?.distance ?? Highway.shoulder + Highway.widestBank,
                  d < Highway.shoulder + road.bed(u).bank else { continue }
            found = (d, road.half(u))
        }
        return found
    }

    // MARK: - City blocks

    /// A block of a city: its plan (CityPlan, in metres from the city's middle) and how far out it is.
    struct Block {
        var index: SIMD2<Int>
        var plan: CityPlan
        /// From the square's corner to the city's middle: add it to the plan's (x, z).
        var origin: SIMD2<Float>
    }

    /// A piece of road: a street from one crossing of the grid to the next, or the square where two cross.
    struct Road {
        var rect: CityPlan.Rect         // metres from the city's middle
        /// 0 = it runs along x, 1 = along z, 2 = a crossing.
        var along: Int
        /// A street's ends (the low one, the high one) where it meets a crossing three or four streets come to:
        /// there people cross it, and cars stop.
        var junction = [false, false]
    }

    /// Whether block (i, j) of the city's grid is built: only where all of it is inside the city's radius.
    func built(_ city: City, _ i: Int, _ j: Int) -> Bool {
        let corner = SIMD2(Float(i), Float(j)) * World.blockPitch + (World.blockPitch - World.blockSize) / 2
        return length(simd_max(abs(corner), abs(corner + World.blockSize))) < city.radius
    }

    /// Whether a place is on one of the city's blocks or roads, or within `margin` of one. (A built block's roads
    /// are the four along its sides and the crossings at its corners: its cell of the grid and half a road around it.)
    func paved(_ city: City?, _ x: Double, _ z: Double, margin: Float = 0) -> Bool {
        guard let city else { return false }
        let p = SIMD2(Float(x - city.center.x), Float(z - city.center.y)), pitch = World.blockPitch
        guard length(p) < city.radius + World.cityApron else { return false }
        let i = Int((p.x / pitch.x).rounded(.down)), j = Int((p.y / pitch.y).rounded(.down)), reach = World.roadWidth / 2 + margin
        for dj in -1...1 {
            for di in -1...1 {
                let lo = SIMD2(Float(i + di), Float(j + dj)) * pitch
                if p.x > lo.x - reach && p.x < lo.x + pitch.x + reach && p.y > lo.y - reach && p.y < lo.y + pitch.y + reach
                    && built(city, i + di, j + dj) { return true }
            }
        }
        return false
    }

    /// Whether `city` can have blocks or roads in the square from (x0, z0), `side` across.
    private func reaches(_ city: City, x0: Double, z0: Double, side: Double) -> Bool {
        let lo = SIMD2(x0 - city.center.x, z0 - city.center.y), reach = Double(city.radius) + 64
        return lo.x < reach && lo.y < reach && lo.x + side > -reach && lo.y + side > -reach
    }

    /// Whether the square from (x0, z0), `side` across, is one a city can have blocks in: what is made for it
    /// depends on the cities' settings (`lit`).
    func hasCity(x0: Double, z0: Double, side: Double) -> Bool {
        guard let city = city(near: x0 + side / 2, z0 + side / 2) else { return false }
        return reaches(city, x0: x0, z0: z0, side: side)
    }

    /// The blocks whose middle is in the square from (x0, z0), `side` across, in the order of their rows.
    func blocks(x0: Double, z0: Double, side: Double) -> (city: City, blocks: [Block])? {
        guard let city = city(near: x0 + side / 2, z0 + side / 2) else { return nil }
        let pitch = World.blockPitch, size = World.blockSize
        let lo = SIMD2(x0 - city.center.x, z0 - city.center.y)
        guard reaches(city, x0: x0, z0: z0, side: side) else { return (city, []) }
        var out: [Block] = []
        let i0 = Int((lo.x / Double(pitch.x)).rounded(.down)) - 1, i1 = Int(((lo.x + side) / Double(pitch.x)).rounded(.down)) + 1
        let j0 = Int((lo.y / Double(pitch.y)).rounded(.down)) - 1, j1 = Int(((lo.y + side) / Double(pitch.y)).rounded(.down)) + 1
        for j in j0...j1 {
            for i in i0...i1 {
                // The block's rectangle: its pitch's cell, less half a road on each side.
                let corner = SIMD2(Float(i), Float(j)) * pitch + (pitch - size) / 2
                let rect = CityPlan.Rect(lo: corner, hi: corner + size), middle = rect.center
                guard Double(middle.x) >= lo.x, Double(middle.x) < lo.x + side, Double(middle.y) >= lo.y, Double(middle.y) < lo.y + side
                else { continue }
                guard built(city, i, j) else { continue }
                var rng = SplitMix64(seed: World.hash(city.seed, i, j, 0xB10C))
                let park = rng.next() < 0.06 && length(middle) < 0.5 * city.radius
                out.append(Block(index: SIMD2(i, j),
                                 plan: CityPlan(block: rect, ring: length(middle) / city.radius, seed: rng.nextUInt64(), park: park),
                                 origin: SIMD2(Float(city.center.x - x0), Float(city.center.y - z0))))
            }
        }
        return (city, out)
    }

    /// The roads of the grid's cells whose middle is in the square from (x0, z0), `side` across, in the order of
    /// their rows: a cell's are the street along its -x side, the one along its -z side and the crossing at the
    /// corner between them, each there if a block next to it is built. `origin`: from the square's corner to the
    /// city's middle.
    func roads(x0: Double, z0: Double, side: Double) -> (city: City, origin: SIMD2<Float>, roads: [Road])? {
        guard let city = city(near: x0 + side / 2, z0 + side / 2), reaches(city, x0: x0, z0: z0, side: side) else { return nil }
        let pitch = World.blockPitch, half = World.roadWidth / 2
        let lo = SIMD2(x0 - city.center.x, z0 - city.center.y)
        var out: [Road] = []
        let i0 = Int((lo.x / Double(pitch.x)).rounded(.down)) - 1, i1 = Int(((lo.x + side) / Double(pitch.x)).rounded(.down)) + 1
        let j0 = Int((lo.y / Double(pitch.y)).rounded(.down)) - 1, j1 = Int(((lo.y + side) / Double(pitch.y)).rounded(.down)) + 1
        // The streets that come to the grid's corner (i, j): toward -z and +z, toward -x and +x.
        func streets(_ i: Int, _ j: Int) -> [Bool] {
            let a = built(city, i - 1, j - 1), b = built(city, i, j - 1), c = built(city, i - 1, j), d = built(city, i, j)
            return [a || b, c || d, a || c, b || d]
        }
        // The corners a highway comes to, and from which of those four sides.
        let gates: [(corner: SIMD2<Int>, toward: Int)] = city.highways.map { road in
            let out = road.u0 > city.center[road.axis], n = gate(city, axis: road.axis)
            return (road.axis == 0 ? SIMD2(out ? n : -n, 0) : SIMD2(0, out ? n : -n), (road.axis == 0 ? 2 : 0) + (out ? 1 : 0))
        }
        func highways(_ i: Int, _ j: Int) -> [Bool] { (0..<4).map { k in gates.contains { $0.corner == SIMD2(i, j) && $0.toward == k } } }
        func junction(_ i: Int, _ j: Int) -> Bool { zip(streets(i, j), highways(i, j)).reduce(0) { $0 + ($1.0 || $1.1 ? 1 : 0) } >= 3 }
        for j in j0...j1 {
            for i in i0...i1 {
                let middle = (SIMD2(Float(i), Float(j)) + 0.5) * pitch
                guard Double(middle.x) >= lo.x, Double(middle.x) < lo.x + side, Double(middle.y) >= lo.y, Double(middle.y) < lo.y + side
                else { continue }
                let c = SIMD2(Float(i), Float(j)) * pitch, here = streets(i, j)
                if here[1] {
                    out.append(Road(rect: CityPlan.Rect(lo: c + SIMD2(-half, half), hi: c + SIMD2(half, pitch.y - half)), along: 1,
                                    junction: [junction(i, j), junction(i, j + 1)]))
                }
                if here[3] {
                    out.append(Road(rect: CityPlan.Rect(lo: c + SIMD2(half, -half), hi: c + SIMD2(pitch.x - half, half)), along: 0,
                                    junction: [junction(i, j), junction(i + 1, j)]))
                }
                if here.contains(true) { out.append(Road(rect: CityPlan.Rect(lo: c - half, hi: c + half), along: 2)) }
                // A highway's first metres from the corner: a street's.
                for (k, comes) in highways(i, j).enumerated() where comes {
                    let axis = k < 2 ? 1 : 0, plus = k % 2 == 1, meets = junction(i, j)
                    var lo = c - half, hi = c + half
                    lo[axis] = c[axis] + (plus ? half : -half - Highway.stub)
                    hi[axis] = c[axis] + (plus ? half + Highway.stub : -half)
                    out.append(Road(rect: CityPlan.Rect(lo: lo, hi: hi), along: axis, junction: [plus && meets, !plus && meets]))
                }
            }
        }
        return (city, SIMD2(Float(city.center.x - x0), Float(city.center.y - z0)), out)
    }
}

// MARK: - The day

/// Where the world's sun and moon are at a time of its day, and what they light.
///
/// The sun goes round as it does at a latitude of 48 degrees in late spring: up for six tenths of the day, 60 degrees
/// high at noon, 24 under the horizon at midnight; it rises in the east (+x) and passes over -z. The moon is across
/// the sky from it, up from before the sun sets until after it rises, 37 degrees high at midnight.
struct Heavens: Equatable {
    /// Toward the sun and toward the moon (unit), wherever they are.
    var sun: SIMD3<Float>, moon: SIMD3<Float>
    /// How much of the sun's disc is over the horizon, and of the moon's.
    var sunUp: Float, moonUp: Float
    /// How much of the moon's light there is to see: none while the sun is up, all of it once the sun is 6 degrees
    /// under the horizon.
    var moonlight: Float

    /// How bright the stars are, 0...1: out between the sun's 3 and 10 degrees under the horizon.
    var stars: Float { World.smooth(-3 * .pi / 180, -10 * .pi / 180, sunElevation) }

    /// The eye adapts as the day ends, and nothing here stands for it but the lights: the sun's light, on the ground
    /// and in the sky, is this many times what it is, from 1 with the sun 10 degrees up to 128 with it 6 under the
    /// horizon. (Left as it is, sunset is a hundredth of noon and dusk is over as it begins: the cities' lights and
    /// the moon are as bright as an eye used to the night sees them.)
    var adaptation: Float {
        let e = sunElevation * 180 / .pi
        return exp2(min(0.3 * max(10 - e, 0) + 0.6 * max(-2 - e, 0), 7))
    }

    /// The scene has one light from the sky: the sun while any of it is up, then the moon.
    var lightIsMoon: Bool { sunUp <= 0 }
    var light: SIMD3<Float> { lightIsMoon ? moon : sun }
    /// The sun's height over the horizon, radians.
    var sunElevation: Float { asin(min(max(sun.y, -1), 1)) }

    /// The world's day in seconds, and the part of it that has gone by at time 0 (midnight is 0, noon 0.5): the
    /// clock starts in the middle of the morning.
    static let day: Float = 240, start: Float = 0.4
    /// The moon's irradiance above the atmosphere, in the renderer's units: about a twentieth of the sun's (the eye
    /// has adapted), and bluer.
    static let moonIrradiance = SIMD3<Float>(0.1, 0.14, 0.26)
    /// What lights the night's atmosphere, from where the moon is: far more than the moon's own light would, so
    /// that the night's sky lights the ground about as much as the moon does (a night to see by).
    static let nightSkyIrradiance = SIMD3<Float>(0.9, 0.75, 0.8)
    static let discRadius: Float = 0.27 * .pi / 180
    /// The sun's height below which the sky has no more light from it.
    static let twilightEnd: Float = -18 * .pi / 180

    /// The part of the day gone by at `time` (seconds on the scene's day clock): 0...1.
    static func phase(at time: Float) -> Float {
        let p = start + time / day
        return p - p.rounded(.down)
    }

    init(at time: Float) {
        let latitude = Float(48) * .pi / 180
        /// A body `declination` north of the sky's equator, `hour` past its highest.
        func body(_ hour: Float, _ declination: Float) -> SIMD3<Float> {
            SIMD3(-cos(declination) * sin(hour),
                  sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(hour),
                  cos(latitude) * sin(declination) - sin(latitude) * cos(declination) * cos(hour))
        }
        func up(_ d: SIMD3<Float>) -> Float { World.smooth(-Heavens.discRadius, Heavens.discRadius, asin(min(max(d.y, -1), 1))) }
        let hour = 2 * Float.pi * (Heavens.phase(at: time) - 0.5)
        sun = body(hour, 18 * .pi / 180)
        moon = body(hour + .pi, -5 * .pi / 180)
        sunUp = up(sun)
        moonUp = up(moon)
        moonlight = World.smooth(-0.5 * .pi / 180, -6 * .pi / 180, asin(min(max(sun.y, -1), 1)))
    }
}

extension World {
    /// 0 at a, 1 at b, smoothly (a may be the larger).
    static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { smoothstep(a, b, x) }

    /// The sun's height (radians) below which a scene of the world is made with its cities' lights (`SceneSettings.
    /// worldLit`): before any of them comes on, so that the scene is there when they do.
    static let lightsReady: Float = 6 * .pi / 180
    /// How far on a light is with the sun `elevation` high (radians), 0...1: a street lamp, which comes on as the
    /// sun sets, or with `window` (0...1, the window's own) a window, each at its own time between then and dark.
    static func lightOn(elevation: Float, window: Float? = nil) -> Float {
        let degree = Float.pi / 180
        guard let window else { return smooth(2.5 * degree, 0.5 * degree, elevation) }
        let on = (3 - 9 * window) * degree
        return smooth(on, on - 1.2 * degree, elevation)
    }
}
