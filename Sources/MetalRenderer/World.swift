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
///            streets a grid in the world's axes. A block is made from the seed and its place in the grid alone.
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
    static let version = 3
    static let tileSize: Float = 256
    static let cityCell = 4096.0
    /// A tile's levels of detail: 0 next to the viewer, 2 at the edge of what is seen.
    static let levels = 3
    /// The side of a ground cell at a level, metres.
    static func cellSize(_ level: Int) -> Float { level == 0 ? 1 : level == 1 ? 4 : 16 }
    /// Kerb to kerb, and from one block's corner to the next's: multiples of 4 m, so the roads lie on the ground's
    /// cells at levels 0 and 1.
    static let blockSize = SIMD2<Float>(72, 56), blockPitch = SIMD2<Float>(84, 68)
    /// What the underside of a street lamp's head emits at night.
    static let lampEmission = SIMD3<Float>(1.0, 0.78, 0.5) * 140
    /// How far beyond a city's last block its level ground rises back into the hills.
    static let cityBlend: Float = 300

    private let broadSeed: UInt32, rollingSeed: UInt32, coverSeed: UInt32, standSeed: UInt32

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
    }

    /// The city of a 4 km cell, if it has one. It and the ground it levels stay 128 m inside the cell.
    func city(cell: SIMD2<Int>) -> City? {
        let own = World.hash(seed, cell.x, cell.y, 0xC17)
        var rng = SplitMix64(seed: own)
        let roll = rng.next(), radius = rng.range(300, 900), u = Double(rng.next()), v = Double(rng.next())
        guard cell == SIMD2(0, 0) || roll < cityShare else { return nil }
        let margin = Double(radius + World.cityBlend) + 128, span = World.cityCell - 2 * margin
        func snap(_ c: Double) -> Double { (c / 16).rounded() * 16 }
        let center = SIMD2(snap(Double(cell.x) * World.cityCell + margin + u * span), snap(Double(cell.y) * World.cityCell + margin + v * span))
        return City(cell: cell, center: center, radius: radius, level: broad(center.x, center.y), seed: own)
    }

    func city(near x: Double, _ z: Double) -> City? {
        city(cell: SIMD2(Int((x / World.cityCell).rounded(.down)), Int((z / World.cityCell).rounded(.down))))
    }

    /// 1 on a city's level ground, 0 where the hills are their own again.
    func cityMask(_ city: City?, _ x: Double, _ z: Double) -> Float {
        guard let city else { return 0 }
        let d = Float(((x - city.center.x) * (x - city.center.x) + (z - city.center.y) * (z - city.center.y)).squareRoot())
        return 1 - World.smoothstep(city.radius, city.radius + World.cityBlend, d)
    }

    // MARK: - The ground

    private func broad(_ x: Double, _ z: Double) -> Float { 70 * Terrain.fbm(x / 1800, z / 1800, octaves: 4, seed: broadSeed) }

    /// The ground's height. `city`: the one of the place's 4 km cell (`city(near:)`), found once for many places.
    func height(_ x: Double, _ z: Double, city: City?) -> Float {
        let natural = broad(x, z) + 15.3 * Terrain.fbm(x / 120, z / 120, octaves: 5, seed: rollingSeed)
        guard let city else { return natural }
        let mask = cityMask(city, x, z)
        return mask <= 0 ? natural : natural + (city.level - natural) * mask
    }

    func height(_ x: Double, _ z: Double) -> Float { height(x, z, city: city(near: x, z)) }

    /// 1 in the woods, 0 in open country.
    func woods(_ x: Double, _ z: Double) -> Float { World.smoothstep(-0.12, 0.1, Terrain.fbm(x / 420, z / 420, octaves: 3, seed: coverSeed)) }

    /// What the ground is made of at a place: an index into `groundMaterials`. `up`: its normal's y.
    func ground(_ x: Double, _ z: Double, up: Float, city: City?) -> Int {
        let mask = cityMask(city, x, z)
        if mask >= 1 { return Ground.asphalt }
        if up < 0.8 { return Ground.rock }
        if woods(x, z) + 0.2 * Terrain.noise(x / 14, z / 14, seed: standSeed &+ 32) < 0.5 || mask > 0.3 { return Ground.meadow }
        return Terrain.noise(x / 9, z / 9, seed: standSeed &+ 31) > 0.18 ? Ground.moss : Ground.litter
    }

    enum Ground {
        static let litter = 0, moss = 1, meadow = 2, rock = 3, asphalt = 4
    }

    /// The ground's materials (`ground`'s indices). They name their textures by kind (`texture(_:)`): the asphalt its
    /// surface's, the others the ground's detail, which their colours are divided by the mean of (FoliageTextures.mean).
    static let groundMaterials: [GPUMaterial] = {
        func natural(_ c: SIMD3<Float>) -> GPUMaterial {
            var m = GPUMaterial(albedo: SIMD4(c / FoliageTextures.mean, 0), emission: SIMD4(.zero, 1))
            m.textures.x = groundDetail
            return m
        }
        var asphalt = GPUMaterial(albedo: SIMD4(0.1, 0.1, 0.11, 0), emission: SIMD4(.zero, 1))
        asphalt.textures.x = texture(.asphalt)
        return [natural([0.15, 0.13, 0.075]), natural([0.09, 0.135, 0.05]), natural([0.2, 0.3, 0.1]), natural([0.24, 0.23, 0.21]), asphalt]
    }()
    /// `GPUMaterial.textures.x` of a material with the ground's detail texture (Scene+World.swift makes it).
    static let groundDetail: UInt32 = 0x4100_0000

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
            guard cover > 0, cityMask(city, x, z) < 0.5 else { return }   // a belt of open ground around a city
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
                guard cityMask(city, x, z) < 0.9, chance < likely(x, z) * min(undergrowth, 1) else { return }
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

    // MARK: - City blocks

    /// A block of a city: its plan (CityPlan, in metres from the city's middle) and how far out it is.
    struct Block {
        var index: SIMD2<Int>
        var plan: CityPlan
        /// From the square's corner to the city's middle: add it to the plan's (x, z).
        var origin: SIMD2<Float>
    }

    /// Whether `city` can have blocks in the square from (x0, z0), `side` across.
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
                // Built only where all of it is on the level ground.
                let far = simd_max(abs(rect.lo), abs(rect.hi))
                guard length(far) < city.radius else { continue }
                var rng = SplitMix64(seed: World.hash(city.seed, i, j, 0xB10C))
                let park = rng.next() < 0.06 && length(middle) < 0.5 * city.radius
                out.append(Block(index: SIMD2(i, j),
                                 plan: CityPlan(block: rect, ring: length(middle) / city.radius, seed: rng.nextUInt64(), park: park),
                                 origin: SIMD2(Float(city.center.x - x0), Float(city.center.y - z0))))
            }
        }
        return (city, out)
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
