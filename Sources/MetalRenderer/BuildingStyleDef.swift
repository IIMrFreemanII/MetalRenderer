import Foundation
import simd

/// A building style as data: what the building editor edits and Assets/Buildings/Styles keeps, the built-in ones
/// (BuiltInBuildings.swift) among them. A style is a set of ranges and choices; `BuildingStyle.draw` picks one
/// building's values from them with that building's seed, so two buildings of a style are related, not alike.
///
/// Each value is drawn from its own stream (the building's seed and the value's name): changing one range in the
/// editor changes that value alone, not every value drawn after it.
struct BuildingStyleDef: Codable, Equatable {
    var id: String
    var name: String
    /// The style it was made from (a custom style's), for the editor to say.
    var basedOn: String? = nil
    /// Where the city builds it: how likely it is on a lot of each district (CityStyle's names), against the
    /// district's own built-in style (whose weight is 1 in its own district). A built-in style has its own.
    var districts: [String: Float] = [:]
    var programme = Programme()
    var proportions = Proportions()
    var window = WindowDef()
    /// The ground floor's windows, if they differ from the upper ones.
    var groundWindow: WindowDef? = nil
    var facade = FacadeDef()
    var massing = MassingDef()
    var palette = Palette()
    var interior = InteriorDef()

    struct Proportions: Codable, Equatable {
        var groundHeight = Span(3.6, 4.2)
        var floorHeight = Span(2.9, 3.2)
        var bay = Span(2.8, 3.4)                    // the width a facade's bays aim for
        var pier = Choice<Float>([0.6])             // plain wall at each end of a facade
    }

    struct WindowDef: Codable, Equatable {
        var share = Choice<Float>([0.45])           // the opening's width as a share of its bay...
        var minWidth: Float = 1.0, maxWidth: Float = 1.5   // ...and its limits, in metres
        var sill = Choice<Float>([0.9])
        var height = Span(1.5, 1.8)
        var recess = Choice<Float>([0.2])          // how far the glass sits behind the wall's face
        var frame: Float = 0.08
        var mullions = Choice<Int>([1])
        var transom: Float = 0                      // chances
        var sillTrim: Float = 1
        var lintel: Float = 0
        var shutters: Float = 0
    }

    struct FacadeDef: Codable, Equatable {
        var shops: Float = 0                        // how likely a street front's ground floor is shops
        var awnings: Float = 0.5                    // ...with awnings over them
        var loadingDoors = false                    // warehouses: big doors on the ground floor
        var balconies = Choice<Float>([0])          // the share of a facade's bay columns with balconies
        var balustrade = Choice<Balustrade>([.bars])
        var ledge: Float = 1                        // chances: a string course over the ground floor...
        var floorLedges: Float = 0                  // ...and a thinner one at every floor
        var cornice = Span(0.25, 0.4)               // how far the cornice projects (0: none)
        var pilasters: Float = 0
        var plinth = true
        /// Without the building's interior: how deep the room boxes behind some windows are.
        var roomDepth: Float = 4.2
    }

    struct MassingDef: Codable, Equatable {
        var shapes: [PlanShape] = [.rect]
        /// Its own number of floors, if it has one (otherwise the lot's: its district's).
        var floors: Span? = nil
        var setback = Span(0, 0)                    // free-standing: how far the walls stand back from the lot's sides
        var tower: Int = 0                          // from this many floors a tower (podium, setbacks); 0: never
        var podium: Float = 0
        var setbacks = Choice<Int>([0])
        var penthouse: Float = 0                    // how likely the top floor stands back behind a terrace
        var roof = Choice<RoofKind>([.flat])
        var roofPitch = Span(0.6, 0.95)             // a gabled roof's rise over run
        var parapet = Choice<Float>([0.9])
        var chimneys: Float = 0                     // chances
        var waterTank: Float = 0
        var mast: Float = 0
    }

    /// The outside's materials, a choice for each.
    struct Palette: Codable, Equatable {
        var wall = MaterialDef([[0.7, 0.68, 0.62]], .plaster)
        var base = MaterialDef([[0.55, 0.54, 0.52]], .concrete)
        var trim = MaterialDef([[0.82, 0.8, 0.76]], .plaster)
        var frame = MaterialDef([[0.9, 0.9, 0.88]], nil)
        var glass = MaterialDef([[0.92, 0.95, 0.94]], nil)
        var blind = MaterialDef([[0.8, 0.78, 0.72]], nil)
        var dark = MaterialDef([[0.025, 0.025, 0.03]], nil)
        var roofing = MaterialDef([[0.3, 0.3, 0.32]], .concrete)
        /// A pitched roof's covering, if it differs from a flat one's.
        var pitchedRoofing: MaterialDef? = nil
        var metal = MaterialDef([[0.55, 0.57, 0.6]], .metalpanel, roughness: 0.45, metallic: 0.9, specular: true)
        var accent = MaterialDef([[0.2, 0.3, 0.25]], nil)
        /// What glows behind a lit blind at night, and how brightly.
        var glow: [SIMD3<Float>] = [[1.0, 0.72, 0.42], [1.0, 0.78, 0.5], [1.0, 0.86, 0.66], [0.95, 0.92, 0.85], [0.6, 0.75, 1.0]]
        var glowScale = Span(0.6, 1.2)
    }

    /// The inside: its finishes, furniture and lights.
    struct InteriorDef: Codable, Equatable {
        var paints: [SIMD3<Float>] = [[0.82, 0.79, 0.72], [0.78, 0.8, 0.78], [0.84, 0.8, 0.7], [0.74, 0.76, 0.8], [0.86, 0.85, 0.82]]
        var woods: [SIMD3<Float>] = [[0.42, 0.3, 0.2], [0.5, 0.4, 0.28], [0.3, 0.22, 0.16], [0.62, 0.5, 0.36]]
        var tiles: [SIMD3<Float>] = [[0.85, 0.86, 0.86], [0.72, 0.76, 0.78], [0.5, 0.52, 0.54]]
        var fabrics: [SIMD3<Float>] = [[0.32, 0.36, 0.42], [0.55, 0.3, 0.24], [0.6, 0.58, 0.52], [0.24, 0.32, 0.26], [0.7, 0.62, 0.42]]
        var carpets: [SIMD3<Float>] = [[0.3, 0.31, 0.33], [0.36, 0.34, 0.3]]
        var ceiling: SIMD3<Float> = [0.88, 0.88, 0.86]
        /// A room's ceiling light: its colour and how bright (a rect light's radiance, its panel's).
        var lightColor: SIMD3<Float> = [1.0, 0.86, 0.7]
        var lightPower: Float = 12
        /// How much stands on shelves and tables (0...1), and how likely a room has a plant.
        var clutter: Float = 0.6
        var plants: Float = 0.4
        /// Doors' leaves and frames.
        var doors: [SIMD3<Float>] = [[0.9, 0.89, 0.86], [0.45, 0.32, 0.22]]
        /// The glTF props of Assets/Props/props.json in place of the generated pieces they name (PropLibrary).
        var models = true
    }
}

/// What a building is for: how its storeys are divided (BuildingPlanner.swift).
enum BuildingUse: String, Codable, CaseIterable {
    case house          // one home over all its storeys, a stair up through it (a shop under it, maybe)
    case apartments     // flats off a stair (and a lift) on every floor
    case offices        // open floors around a core of stairs, lifts and toilets
    case warehouse      // a hall, an office in a corner

    var title: String {
        switch self {
        case .house: return "House"
        case .apartments: return "Apartments"
        case .offices: return "Offices"
        case .warehouse: return "Warehouse"
        }
    }
}

/// How a style's buildings are divided inside: their use, the walls' thickness, the stair, lift and corridor, and the
/// sizes its rooms aim for.
struct Programme: Codable, Equatable {
    var use = BuildingUse.apartments
    var outerWall: Float = 0.3
    var partition: Float = 0.12
    var slab: Float = 0.25
    var stairWidth: Float = 1.1
    /// From this many floors a lift beside the stair (0: never).
    var liftFrom = 5
    var corridor: Float = 1.6
    /// A flat's frontage.
    var unitWidth = Span(6.5, 9)
    /// The narrowest a living room, a bedroom, a kitchen, a bathroom and a hall may be, and how deep the band of
    /// bathrooms and halls along a flat's door side is.
    var living: Float = 3.6
    var bedroom: Float = 2.8
    var kitchen: Float = 2.4
    var bath: Float = 1.8
    var hall: Float = 1.3
    var innerBand: Float = 2.3
    /// How likely a flat's kitchen is open to its living room.
    var openKitchen: Float = 0.5
    /// Offices: the share of a floor's window wall given to meeting rooms and offices of their own.
    var cellular: Float = 0.25
}

/// A value drawn for each building: anywhere from `lo` to `hi` (the same: always that).
struct Span: Codable, Equatable {
    var lo: Float
    var hi: Float

    init(_ lo: Float, _ hi: Float? = nil) {
        self.lo = lo
        self.hi = hi ?? lo
    }

    func draw(_ u: Float) -> Float { lo + (hi - lo) * u }

    // A constant is written as a number.
    init(from decoder: Decoder) throws {
        if let v = try? decoder.singleValueContainer().decode(Float.self) {
            (lo, hi) = (v, v)
        } else {
            let c = try decoder.container(keyedBy: Keys.self)
            lo = try c.decode(Float.self, forKey: .lo)
            hi = try c.decode(Float.self, forKey: .hi)
        }
    }
    func encode(to encoder: Encoder) throws {
        if lo == hi {
            var c = encoder.singleValueContainer()
            try c.encode(lo)
        } else {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(lo, forKey: .lo)
            try c.encode(hi, forKey: .hi)
        }
    }
    private enum Keys: String, CodingKey { case lo, hi }
}

/// One of `options`, each as likely (an option listed twice is twice as likely).
struct Choice<T: Codable & Equatable>: Codable, Equatable {
    var options: [T]

    init(_ options: [T]) { self.options = options }

    func draw(_ u: Float) -> T { options[min(Int(u * Float(options.count)), options.count - 1)] }

    init(from decoder: Decoder) throws {
        if let one = try? decoder.singleValueContainer().decode(T.self) {
            options = [one]
        } else {
            options = try decoder.singleValueContainer().decode([T].self)
        }
        if options.isEmpty { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no options")) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if options.count == 1 { try c.encode(options[0]) } else { try c.encode(options) }
    }
}

/// A material picked for each building: one of `colors` (each shaded by up to `shade` either way) and one of
/// `finishes`; or, with probability `likeChance`, the colour drawn for slot `like` times `likeScale`.
struct MaterialDef: Codable, Equatable {
    var colors: [SIMD3<Float>]
    var shade: Float = 0.08
    var finishes: [Finish]
    var like: String? = nil
    var likeChance: Float = 0
    var likeScale: Float = 1

    struct Finish: Codable, Equatable {
        var surface: SurfaceKind? = nil
        var roughness: Float = 1
        var metallic: Float = 0
        var specular = false
    }

    init(_ colors: [SIMD3<Float>], _ surface: SurfaceKind?, roughness: Float = 1, metallic: Float = 0, specular: Bool = false,
         shade: Float = 0.08) {
        self.colors = colors
        self.shade = shade
        finishes = [Finish(surface: surface, roughness: roughness, metallic: metallic, specular: specular)]
    }
}

// MARK: - Codable for the generator's enums (by name, so the files read)

/// An enum written by its case's name.
protocol NamedCase: CaseIterable, Codable {}

extension NamedCase {
    var caseName: String { String(describing: self) }
    init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let found = Self.allCases.first(where: { "\($0)" == name }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no case \(name)"))
        }
        self = found
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(caseName)
    }
}

extension RoofKind: NamedCase {}
extension PlanShape: NamedCase {}
extension Balustrade: NamedCase {}

extension CityStyle {
    /// Its name in files (BuildingStyleDef.districts) and a built-in style's id.
    var name: String { String(describing: self) }
    init?(name: String) {
        guard let found = CityStyle.allCases.first(where: { $0.name == name }) else { return nil }
        self = found
    }
}

// MARK: - Drawing one building's style

/// One value of a style for one building: a uniform number from the building's seed and the value's own name.
struct StyleDraw {
    let seed: UInt64

    func u(_ name: String) -> Float {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in name.utf8 { h = (h ^ UInt64(byte)) &* 0x100_0000_01B3 }
        var g = SplitMix64(seed: seed ^ h)
        return g.next()
    }
    func span(_ s: Span, _ name: String) -> Float { s.draw(u(name)) }
    func choice<T>(_ c: Choice<T>, _ name: String) -> T { c.draw(u(name)) }
    func chance(_ p: Float, _ name: String) -> Bool { u(name) < p }
    func pick<T>(_ options: [T], _ name: String) -> T { options[min(Int(u(name) * Float(options.count)), options.count - 1)] }

    /// A material of `def`, its colour maybe slot `like`'s (`drawn` holds the colours drawn so far, by slot name).
    func material(_ def: MaterialDef, _ name: String, drawn: [String: SIMD3<Float>] = [:]) -> SurfaceMaterial {
        let finish = def.finishes.isEmpty ? MaterialDef.Finish() : pick(def.finishes, name + ".finish")
        var color: SIMD3<Float>
        if let like = def.like, let other = drawn[like], u(name + ".like") < def.likeChance {
            color = other * def.likeScale
        } else {
            color = def.colors.isEmpty ? SIMD3(repeating: 0.7) : pick(def.colors, name + ".color")
            color *= 1 + def.shade * (2 * u(name + ".shade") - 1)
        }
        return SurfaceMaterial(color: color, surface: finish.surface, roughness: finish.roughness, metallic: finish.metallic,
                               specular: finish.specular)
    }
}

extension BuildingStyle {
    /// One building's style, drawn from `def` with `seed`.
    static func draw(_ def: BuildingStyleDef, seed: UInt64) -> BuildingStyle {
        let d = StyleDraw(seed: seed)
        var s = BuildingStyle()
        s.def = def
        s.programme = def.programme
        let p = def.proportions
        s.groundHeight = d.span(p.groundHeight, "groundHeight")
        s.floorHeight = d.span(p.floorHeight, "floorHeight")
        s.bay = max(d.span(p.bay, "bay"), 0.8)
        s.pier = d.choice(p.pier, "pier")
        func window(_ w: BuildingStyleDef.WindowDef, _ name: String) -> WindowStyle {
            WindowStyle(share: d.choice(w.share, name + ".share"), minWidth: w.minWidth, maxWidth: max(w.maxWidth, w.minWidth),
                        sill: d.choice(w.sill, name + ".sill"), height: d.span(w.height, name + ".height"),
                        recess: d.choice(w.recess, name + ".recess"), frame: w.frame, mullions: d.choice(w.mullions, name + ".mullions"),
                        transom: d.chance(w.transom, name + ".transom"), sillTrim: d.chance(w.sillTrim, name + ".sillTrim"),
                        lintel: d.chance(w.lintel, name + ".lintel"), shutters: d.chance(w.shutters, name + ".shutters"))
        }
        s.window = window(def.window, "window")
        s.groundWindow = def.groundWindow.map { window($0, "groundWindow") } ?? s.window
        let f = def.facade
        s.shops = f.shops
        s.awnings = f.awnings
        s.loadingDoors = f.loadingDoors
        s.balconies = d.choice(f.balconies, "balconies")
        s.balustrade = d.choice(f.balustrade, "balustrade")
        s.ledge = d.chance(f.ledge, "ledge")
        s.floorLedges = d.chance(f.floorLedges, "floorLedges")
        s.cornice = d.span(f.cornice, "cornice")
        s.pilasters = d.chance(f.pilasters, "pilasters")
        s.plinth = f.plinth
        s.roomDepth = f.roomDepth
        let m = def.massing
        s.shapes = m.shapes.isEmpty ? [.rect] : m.shapes
        s.setback = d.span(m.setback, "setback")
        s.tower = m.tower
        s.podium = d.chance(m.podium, "podium")
        s.setbacks = d.choice(m.setbacks, "setbacks")
        s.penthouse = m.penthouse
        s.roof = d.choice(m.roof, "roof")
        s.roofPitch = d.span(m.roofPitch, "roofPitch")
        s.parapet = d.choice(m.parapet, "parapet")
        s.chimneys = m.chimneys
        s.waterTank = m.waterTank
        s.mast = m.mast

        let c = def.palette
        var drawn: [String: SIMD3<Float>] = [:]
        func material(_ m: MaterialDef, _ name: String) -> SurfaceMaterial {
            let made = d.material(m, name, drawn: drawn)
            drawn[name] = made.color
            return made
        }
        s.wall = material(c.wall, "wall")
        s.base = material(c.base, "base")
        s.trim = material(c.trim, "trim")
        s.frame = material(c.frame, "frame")
        s.glass = material(c.glass, "glass")
        s.glass.glass = true
        s.glass.surface = nil
        s.blind = material(c.blind, "blind")
        s.dark = material(c.dark, "dark")
        s.roofing = material(s.roof != .flat ? c.pitchedRoofing ?? c.roofing : c.roofing, "roofing")
        s.metal = material(c.metal, "metal")
        s.accent = material(c.accent, "accent")
        s.lit = SurfaceMaterial(color: .zero, emission: (c.glow.isEmpty ? [1, 0.8, 0.6] : d.pick(c.glow, "glow")) * d.span(c.glowScale, "glowScale"))
        let i = def.interior
        s.interior = SurfaceMaterial(color: i.paints.isEmpty ? [0.8, 0.78, 0.72] : d.pick(i.paints, "roomPaint"))
        s.flooring = SurfaceMaterial(color: i.woods.isEmpty ? [0.4, 0.3, 0.2] : d.pick(i.woods, "roomFloor"))
        s.lamp = SurfaceMaterial(color: .zero, emission: i.lightColor * i.lightPower * 2.1)
        return s
    }
}
