import Characters
import Effects
import EngineCore
import Foundation
import Physics
import Plants
import simd

/// A building style as data: what the building editor edits and Assets/Buildings/Styles keeps, the built-in ones
/// (BuiltInBuildings.swift) among them. A style is a set of ranges and choices; `BuildingStyle.draw` picks one
/// building's values from them with that building's seed, so two buildings of a style are related, not alike.
///
/// Each value is drawn from its own stream (the building's seed and the value's name): changing one range in the
/// editor changes that value alone, not every value drawn after it.
package struct BuildingStyleDef: Codable, Equatable {
    package var id: String
    package var name: String
    /// The style it was made from (a custom style's), for the editor to say.
    package var basedOn: String? = nil
    /// Where the city builds it: how likely it is on a lot of each district (CityStyle's names), against the
    /// district's own built-in style (whose weight is 1 in its own district). A built-in style has its own.
    package var districts: [String: Float] = [:]
    package var programme = Programme()
    package var proportions = Proportions()
    package var window = WindowDef()
    /// The ground floor's windows, if they differ from the upper ones.
    package var groundWindow: WindowDef? = nil
    package var facade = FacadeDef()
    package var massing = MassingDef()
    package var palette = Palette()
    package var interior = InteriorDef()

    package struct Proportions: Codable, Equatable {
        package var groundHeight = Span(3.6, 4.2)
        package var floorHeight = Span(2.9, 3.2)
        package var bay = Span(2.8, 3.4)                    // the width a facade's bays aim for
        package var pier = Choice<Float>([0.6])             // plain wall at each end of a facade

        /// (As the memberwise initializer, for the modules above this one.)
        package init(groundHeight: Span = Span(3.6, 4.2), floorHeight: Span = Span(2.9, 3.2), bay: Span = Span(2.8, 3.4), pier: Choice<Float> = Choice<Float>([0.6])) {
            self.groundHeight = groundHeight
            self.floorHeight = floorHeight
            self.bay = bay
            self.pier = pier
        }
    }

    package struct WindowDef: Codable, Equatable {
        package var share = Choice<Float>([0.45])           // the opening's width as a share of its bay...
        package var minWidth: Float = 1.0, maxWidth: Float = 1.5   // ...and its limits, in metres
        package var sill = Choice<Float>([0.9])
        package var height = Span(1.5, 1.8)
        package var recess = Choice<Float>([0.2])          // how far the glass sits behind the wall's face
        package var frame: Float = 0.08
        package var mullions = Choice<Int>([1])
        package var transom: Float = 0                      // chances
        package var sillTrim: Float = 1
        package var lintel: Float = 0
        package var shutters: Float = 0
    }

    package struct FacadeDef: Codable, Equatable {
        package var shops: Float = 0                        // how likely a street front's ground floor is shops
        package var awnings: Float = 0.5                    // ...with awnings over them
        package var loadingDoors = false                    // warehouses: big doors on the ground floor
        package var balconies = Choice<Float>([0])          // the share of a facade's bay columns with balconies
        package var balustrade = Choice<Balustrade>([.bars])
        package var ledge: Float = 1                        // chances: a string course over the ground floor...
        package var floorLedges: Float = 0                  // ...and a thinner one at every floor
        package var cornice = Span(0.25, 0.4)               // how far the cornice projects (0: none)
        package var pilasters: Float = 0
        package var plinth = true
        /// Without the building's interior: how deep the room boxes behind some windows are.
        package var roomDepth: Float = 4.2
    }

    package struct MassingDef: Codable, Equatable {
        package var shapes: [PlanShape] = [.rect]
        /// Its own number of floors, if it has one (otherwise the lot's: its district's).
        package var floors: Span? = nil
        package var setback = Span(0, 0)                    // free-standing: how far the walls stand back from the lot's sides
        package var tower: Int = 0                          // from this many floors a tower (podium, setbacks); 0: never
        package var podium: Float = 0
        package var setbacks = Choice<Int>([0])
        package var penthouse: Float = 0                    // how likely the top floor stands back behind a terrace
        package var roof = Choice<RoofKind>([.flat])
        package var roofPitch = Span(0.6, 0.95)             // a gabled roof's rise over run
        package var parapet = Choice<Float>([0.9])
        package var chimneys: Float = 0                     // chances
        package var waterTank: Float = 0
        package var mast: Float = 0

        /// (As the memberwise initializer, for the modules above this one.)
        package init(shapes: [PlanShape] = [.rect], floors: Span? = nil, setback: Span = Span(0, 0), tower: Int = 0, podium: Float = 0, setbacks: Choice<Int> = Choice<Int>([0]), penthouse: Float = 0, roof: Choice<RoofKind> = Choice<RoofKind>([.flat]), roofPitch: Span = Span(0.6, 0.95), parapet: Choice<Float> = Choice<Float>([0.9]), chimneys: Float = 0, waterTank: Float = 0, mast: Float = 0) {
            self.shapes = shapes
            self.floors = floors
            self.setback = setback
            self.tower = tower
            self.podium = podium
            self.setbacks = setbacks
            self.penthouse = penthouse
            self.roof = roof
            self.roofPitch = roofPitch
            self.parapet = parapet
            self.chimneys = chimneys
            self.waterTank = waterTank
            self.mast = mast
        }
    }

    /// The outside's materials, a choice for each.
    package struct Palette: Codable, Equatable {
        package var wall = MaterialDef([[0.7, 0.68, 0.62]], .plaster)
        package var base = MaterialDef([[0.55, 0.54, 0.52]], .concrete)
        package var trim = MaterialDef([[0.82, 0.8, 0.76]], .plaster)
        package var frame = MaterialDef([[0.9, 0.9, 0.88]], nil)
        package var glass = MaterialDef([[0.92, 0.95, 0.94]], nil)
        package var blind = MaterialDef([[0.8, 0.78, 0.72]], nil)
        package var dark = MaterialDef([[0.025, 0.025, 0.03]], nil)
        package var roofing = MaterialDef([[0.3, 0.3, 0.32]], .concrete)
        /// A pitched roof's covering, if it differs from a flat one's.
        package var pitchedRoofing: MaterialDef? = nil
        package var metal = MaterialDef([[0.55, 0.57, 0.6]], .metalpanel, roughness: 0.45, metallic: 0.9, specular: true)
        package var accent = MaterialDef([[0.2, 0.3, 0.25]], nil)
        /// What glows behind a lit blind at night, and how brightly.
        package var glow: [SIMD3<Float>] = [[1.0, 0.72, 0.42], [1.0, 0.78, 0.5], [1.0, 0.86, 0.66], [0.95, 0.92, 0.85], [0.6, 0.75, 1.0]]
        package var glowScale = Span(0.6, 1.2)
    }

    /// The inside: its finishes, furniture and lights.
    package struct InteriorDef: Codable, Equatable {
        package var paints: [SIMD3<Float>] = [[0.82, 0.79, 0.72], [0.78, 0.8, 0.78], [0.84, 0.8, 0.7], [0.74, 0.76, 0.8], [0.86, 0.85, 0.82]]
        package var woods: [SIMD3<Float>] = [[0.42, 0.3, 0.2], [0.5, 0.4, 0.28], [0.3, 0.22, 0.16], [0.62, 0.5, 0.36]]
        package var tiles: [SIMD3<Float>] = [[0.85, 0.86, 0.86], [0.72, 0.76, 0.78], [0.5, 0.52, 0.54]]
        package var fabrics: [SIMD3<Float>] = [[0.32, 0.36, 0.42], [0.55, 0.3, 0.24], [0.6, 0.58, 0.52], [0.24, 0.32, 0.26], [0.7, 0.62, 0.42]]
        package var carpets: [SIMD3<Float>] = [[0.3, 0.31, 0.33], [0.36, 0.34, 0.3]]
        package var ceiling: SIMD3<Float> = [0.88, 0.88, 0.86]
        /// A room's ceiling light: its colour and how bright (a rect light's radiance, its panel's).
        package var lightColor: SIMD3<Float> = [1.0, 0.86, 0.7]
        package var lightPower: Float = 12
        /// How much stands on shelves and tables (0...1), and how likely a room has a plant.
        package var clutter: Float = 0.6
        package var plants: Float = 0.4
        /// Doors' leaves and frames.
        package var doors: [SIMD3<Float>] = [[0.9, 0.89, 0.86], [0.45, 0.32, 0.22]]
        /// The glTF props of Assets/Props/props.json in place of the generated pieces they name (PropLibrary).
        package var models = true
    }
}

/// What a building is for: how its storeys are divided (BuildingPlanner.swift).
package enum BuildingUse: String, Codable, CaseIterable {
    case house          // one home over all its storeys, a stair up through it (a shop under it, maybe)
    case apartments     // flats off a stair (and a lift) on every floor
    case offices        // open floors around a core of stairs, lifts and toilets
    case warehouse      // a hall, an office in a corner

    package var title: String {
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
package struct Programme: Codable, Equatable {
    package var use = BuildingUse.apartments
    package var outerWall: Float = 0.3
    package var partition: Float = 0.12
    package var slab: Float = 0.25
    package var stairWidth: Float = 1.1
    /// From this many floors a lift beside the stair (0: never).
    package var liftFrom = 5
    package var corridor: Float = 1.6
    /// A flat's frontage.
    package var unitWidth = Span(6.5, 9)
    /// The narrowest a living room, a bedroom, a kitchen, a bathroom and a hall may be, and how deep the band of
    /// bathrooms and halls along a flat's door side is.
    package var living: Float = 3.6
    package var bedroom: Float = 2.8
    package var kitchen: Float = 2.4
    package var bath: Float = 1.8
    package var hall: Float = 1.3
    package var innerBand: Float = 2.3
    /// How likely a flat's kitchen is open to its living room.
    package var openKitchen: Float = 0.5
    /// Offices: the share of a floor's window wall given to meeting rooms and offices of their own.
    package var cellular: Float = 0.25
}

/// A value drawn for each building: anywhere from `lo` to `hi` (the same: always that).
package struct Span: Codable, Equatable {
    package var lo: Float
    package var hi: Float

    package init(_ lo: Float, _ hi: Float? = nil) {
        self.lo = lo
        self.hi = hi ?? lo
    }

    package func draw(_ u: Float) -> Float { lo + (hi - lo) * u }

    // A constant is written as a number.
    package init(from decoder: Decoder) throws {
        if let v = try? decoder.singleValueContainer().decode(Float.self) {
            (lo, hi) = (v, v)
        } else {
            let c = try decoder.container(keyedBy: Keys.self)
            lo = try c.decode(Float.self, forKey: .lo)
            hi = try c.decode(Float.self, forKey: .hi)
        }
    }
    package func encode(to encoder: Encoder) throws {
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
package struct Choice<T: Codable & Equatable>: Codable, Equatable {
    package var options: [T]

    package init(_ options: [T]) { self.options = options }

    package func draw(_ u: Float) -> T { options[min(Int(u * Float(options.count)), options.count - 1)] }

    package init(from decoder: Decoder) throws {
        if let one = try? decoder.singleValueContainer().decode(T.self) {
            options = [one]
        } else {
            options = try decoder.singleValueContainer().decode([T].self)
        }
        if options.isEmpty { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no options")) }
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if options.count == 1 { try c.encode(options[0]) } else { try c.encode(options) }
    }
}

/// A material picked for each building: one of `colors` (each shaded by up to `shade` either way) and one of
/// `finishes`; or, with probability `likeChance`, the colour drawn for slot `like` times `likeScale`.
package struct MaterialDef: Codable, Equatable {
    package var colors: [SIMD3<Float>]
    package var shade: Float = 0.08
    package var finishes: [Finish]
    package var like: String? = nil
    package var likeChance: Float = 0
    package var likeScale: Float = 1

    package struct Finish: Codable, Equatable {
        package var surface: SurfaceKind? = nil
        package var roughness: Float = 1
        package var metallic: Float = 0
        package var specular = false

        /// (As the memberwise initializer, for the modules above this one.)
        package init(surface: SurfaceKind? = nil, roughness: Float = 1, metallic: Float = 0, specular: Bool = false) {
            self.surface = surface
            self.roughness = roughness
            self.metallic = metallic
            self.specular = specular
        }
    }

    package init(_ colors: [SIMD3<Float>], _ surface: SurfaceKind?, roughness: Float = 1, metallic: Float = 0, specular: Bool = false,
         shade: Float = 0.08) {
        self.colors = colors
        self.shade = shade
        finishes = [Finish(surface: surface, roughness: roughness, metallic: metallic, specular: specular)]
    }
}

// MARK: - Codable for the generator's enums (by name, so the files read)

/// An enum written by its case's name.
package protocol NamedCase: CaseIterable, Codable {}

extension NamedCase {
    package var caseName: String { String(describing: self) }
    package init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let found = Self.allCases.first(where: { "\($0)" == name }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no case \(name)"))
        }
        self = found
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(caseName)
    }
}

extension RoofKind: NamedCase {}
extension PlanShape: NamedCase {}
extension Balustrade: NamedCase {}

extension CityStyle {
    /// Its name in files (BuildingStyleDef.districts) and a built-in style's id.
    package var name: String { String(describing: self) }
    package init?(name: String) {
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
