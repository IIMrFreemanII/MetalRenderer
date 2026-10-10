import Foundation
import simd

/// The built-in building styles: one for each of the city's districts (CityStyle), what the generator made before
/// styles were data. A file in Assets/Buildings/Styles with one of these ids replaces it (BuildingStore).
enum BuiltInBuildings {
    typealias D = BuildingStyleDef

    static let all: [BuildingStyleDef] = [oldtown, residential, warehouse, office, modern]

    /// Narrow plastered houses with pitched roofs and shutters, a shop under some.
    static let oldtown: D = {
        var d = D(id: "oldtown", name: "Old town", districts: ["oldtown": 1])
        d.programme = Programme(use: .house, outerWall: 0.36, stairWidth: 0.95, liftFrom: 0, living: 3.4, bedroom: 2.6)
        d.proportions = D.Proportions(groundHeight: Span(3.2, 3.8), floorHeight: Span(2.8, 3.2), bay: Span(2.2, 2.8), pier: Choice([0.45]))
        d.window = D.WindowDef(share: Choice([0.45]), minWidth: 0.8, maxWidth: 1.1, sill: Choice([0.9]), height: Span(1.4, 1.7),
                               recess: Choice([0.2]), mullions: Choice([1]), transom: 1, sillTrim: 1, lintel: 0.5, shutters: 0.6)
        var ground = d.window
        ground.shutters = 0
        d.groundWindow = ground
        d.facade = D.FacadeDef(shops: 0.35, awnings: 0.5, ledge: 0.7, cornice: Span(0.2, 0.35), roomDepth: 3.6)
        d.massing = D.MassingDef(roof: Choice([.gabled, .gabled, .gabled, .hipped, .mansard]), roofPitch: Span(0.6, 0.95), chimneys: 1)
        d.palette.wall = MaterialDef([[0.86, 0.78, 0.6], [0.8, 0.62, 0.5], [0.72, 0.75, 0.7], [0.9, 0.86, 0.78], [0.78, 0.68, 0.72],
                                      [0.66, 0.74, 0.8], [0.84, 0.72, 0.52]], .plaster)
        d.palette.base = like("wall", 0.8, .plaster)
        d.palette.trim = MaterialDef([[0.88, 0.86, 0.8]], .plaster)
        d.palette.frame = MaterialDef([[0.92, 0.92, 0.9], [0.35, 0.22, 0.14], [0.2, 0.3, 0.24]], nil, shade: 0)
        d.palette.accent = MaterialDef([[0.18, 0.32, 0.24], [0.42, 0.14, 0.12], [0.16, 0.24, 0.4], [0.36, 0.24, 0.14], [0.8, 0.78, 0.7]], nil)
        d.palette.roofing = MaterialDef([[0.62, 0.26, 0.16], [0.5, 0.22, 0.15], [0.3, 0.3, 0.33]], .rooftile)
        d.interior.paints = [[0.86, 0.82, 0.72], [0.8, 0.84, 0.8], [0.88, 0.8, 0.7], [0.82, 0.78, 0.84], [0.9, 0.88, 0.82]]
        d.interior.woods = [[0.42, 0.28, 0.17], [0.34, 0.22, 0.14], [0.55, 0.42, 0.28]]
        d.interior.clutter = 0.75
        d.interior.plants = 0.5
        d.interior.doors = [[0.9, 0.88, 0.84], [0.42, 0.28, 0.18], [0.3, 0.4, 0.34]]
        return d
    }()

    /// Brick apartment blocks with balconies around courtyards.
    static let residential: D = {
        var d = D(id: "residential", name: "Residential blocks", districts: ["residential": 1])
        d.programme = Programme(use: .apartments, liftFrom: 6)
        d.proportions = D.Proportions(groundHeight: Span(3.6, 4.2), floorHeight: Span(2.9, 3.2), bay: Span(2.8, 3.4), pier: Choice([0.6]))
        d.window = D.WindowDef(share: Choice([0.45]), minWidth: 1.0, maxWidth: 1.5, sill: Choice([0.9]), height: Span(1.5, 1.8),
                               recess: Choice([0.2]), mullions: Choice([1]), transom: 0.5, sillTrim: 1, lintel: 1)
        d.facade = D.FacadeDef(shops: 0.45, awnings: 0.5, balconies: Choice([0, 0.34, 0.5]), balustrade: Choice([.bars, .bars, .solid]),
                               ledge: 1, floorLedges: 0.3, cornice: Span(0.25, 0.4), pilasters: 0.3)
        d.massing = D.MassingDef(shapes: [.rect, .rect, .l], roof: Choice([.flat, .flat, .mansard]), chimneys: 1, waterTank: 0.45)
        d.palette.wall = MaterialDef([[0.62, 0.3, 0.22], [0.7, 0.42, 0.3], [0.55, 0.36, 0.28], [0.76, 0.66, 0.5], [0.48, 0.24, 0.2],
                                      [0.66, 0.5, 0.36]], .brick)
        d.palette.base = MaterialDef([[0.6, 0.58, 0.55], [0.5, 0.48, 0.45], [0.72, 0.68, 0.6]], .concrete)
        d.palette.trim = MaterialDef([[0.8, 0.77, 0.7]], .concrete)
        d.palette.frame = MaterialDef([[0.92, 0.92, 0.9], [0.15, 0.15, 0.16], [0.4, 0.26, 0.16]], nil, shade: 0)
        d.palette.accent = MaterialDef([[0.12, 0.2, 0.16], [0.4, 0.12, 0.1], [0.12, 0.16, 0.3], [0.1, 0.1, 0.11]], nil)
        d.palette.roofing = MaterialDef([[0.3, 0.3, 0.31]], .concrete)
        d.palette.pitchedRoofing = MaterialDef([[0.28, 0.3, 0.34]], .rooftile)
        return d
    }()

    /// Low, wide brick halls with big windows and loading doors.
    static let warehouse: D = {
        var d = D(id: "warehouse", name: "Warehouses", districts: ["warehouse": 1])
        d.programme = Programme(use: .warehouse, outerWall: 0.38, partition: 0.15, slab: 0.3, stairWidth: 1.2, liftFrom: 0)
        d.proportions = D.Proportions(groundHeight: Span(4.8, 6.0), floorHeight: Span(4.0, 4.6), bay: Span(4.5, 5.5), pier: Choice([0.8]))
        d.window = D.WindowDef(share: Choice([0.7]), minWidth: 2.0, maxWidth: 4.0, sill: Choice([1.2]), height: Span(2.4),
                               recess: Choice([0.25]), frame: 0.07, mullions: Choice([3]), transom: 1, sillTrim: 1)
        d.facade = D.FacadeDef(loadingDoors: true, ledge: 0.5, cornice: Span(0.2), pilasters: 1, roomDepth: 5)
        d.massing = D.MassingDef(shapes: [.rect, .rect, .l], setback: Span(0, 2.5), roof: Choice([.gabled, .flat]), roofPitch: Span(0.22, 0.34),
                                 parapet: Choice([0.6]), waterTank: 0.45)
        d.palette.wall = MaterialDef([[0.5, 0.26, 0.2], [0.58, 0.34, 0.26], [0.42, 0.3, 0.26], [0.62, 0.56, 0.48]], .brick)
        d.palette.base = like("wall", 1, .brick)
        d.palette.trim = MaterialDef([[0.62, 0.6, 0.56]], .concrete)
        d.palette.frame = MaterialDef([[0.1, 0.1, 0.11], [0.16, 0.22, 0.2], [0.3, 0.14, 0.1]], nil, shade: 0)
        d.palette.accent = MaterialDef([[0.2, 0.3, 0.26], [0.38, 0.16, 0.1], [0.14, 0.2, 0.34], [0.45, 0.42, 0.38]], nil)
        d.palette.roofing = MaterialDef([[0.28, 0.28, 0.29]], .concrete)
        d.palette.pitchedRoofing = MaterialDef([[0.5, 0.52, 0.54]], .metalpanel, roughness: 0.5, metallic: 0.8, specular: true)
        d.interior.paints = [[0.78, 0.76, 0.72], [0.7, 0.7, 0.68]]
        d.interior.lightColor = [1, 0.95, 0.88]
        d.interior.lightPower = 16
        d.interior.clutter = 0.8
        d.interior.plants = 0.1
        d.interior.doors = [[0.3, 0.32, 0.34], [0.5, 0.2, 0.14]]
        return d
    }()

    /// Glass towers on podiums, with setbacks.
    static let office: D = {
        var d = D(id: "office", name: "Office towers", districts: ["office": 1])
        d.programme = Programme(use: .offices, stairWidth: 1.25, liftFrom: 3, corridor: 1.8)
        d.proportions = D.Proportions(groundHeight: Span(5.0, 6.0), floorHeight: Span(3.6, 3.9), bay: Span(1.5, 3.0), pier: Choice([0.3, 0.5, 1.2]))
        d.window = D.WindowDef(share: Choice([0.94]), minWidth: 1.0, maxWidth: 4.0, sill: Choice([0.05, 0.6, 0.9]), height: Span(4),
                               recess: Choice([0.1]), frame: 0.07, mullions: Choice([0]), sillTrim: 0)
        var ground = d.window
        ground.sill = Choice([0.1])
        ground.mullions = Choice([1])
        d.groundWindow = ground
        d.facade = D.FacadeDef(shops: 1, awnings: 0, ledge: 1, cornice: Span(0), pilasters: 0.6, plinth: false, roomDepth: 6)
        d.massing = D.MassingDef(shapes: [.rect, .rect, .u, .courtyard], setback: Span(1.5, 4), tower: 10, podium: 0.6,
                                 setbacks: Choice([0, 1, 2]), roof: Choice([.flat]), parapet: Choice([1.2]), mast: 1)
        d.palette.glass = MaterialDef([[0.62, 0.78, 0.86], [0.6, 0.82, 0.74], [0.82, 0.74, 0.6], [0.7, 0.74, 0.8], [0.5, 0.6, 0.7]], nil, shade: 0)
        var wall = MaterialDef([[0.62, 0.64, 0.66], [0.3, 0.32, 0.35], [0.75, 0.74, 0.72], [0.16, 0.17, 0.19]], .concrete)
        wall.finishes.append(MaterialDef.Finish(surface: .metalpanel, roughness: 0.4, metallic: 0.9, specular: true))
        d.palette.wall = wall
        d.palette.base = MaterialDef([[0.32, 0.31, 0.3]], .concrete, roughness: 0.35, specular: true)
        d.palette.trim = like("wall", 1, .concrete)
        d.palette.frame = MaterialDef([[0.1, 0.1, 0.11], [0.5, 0.52, 0.55], [0.75, 0.75, 0.76]], nil, shade: 0)
        d.palette.blind = MaterialDef([[0.55, 0.56, 0.56]], nil)
        d.palette.dark = MaterialDef([[0.05, 0.055, 0.06]], nil, shade: 0)
        d.palette.glow = [[0.95, 0.95, 1.0], [1.0, 0.95, 0.85], [0.85, 0.92, 1.0]]
        d.palette.glowScale = Span(0.7, 1.1)
        d.interior.paints = [[0.86, 0.86, 0.85], [0.8, 0.8, 0.8], [0.84, 0.83, 0.8]]
        d.interior.carpets = [[0.3, 0.31, 0.33], [0.24, 0.26, 0.3], [0.36, 0.35, 0.33]]
        d.interior.lightColor = [0.98, 0.98, 1.0]
        d.interior.lightPower = 11.5
        d.interior.clutter = 0.5
        d.interior.plants = 0.35
        d.interior.doors = [[0.8, 0.8, 0.8], [0.4, 0.3, 0.22]]
        return d
    }()

    /// Concrete and panel mid-rise blocks with ribbon windows and glass balconies.
    static let modern: D = {
        var d = D(id: "modern", name: "Modern mid-rise", districts: ["modern": 1])
        d.programme = Programme(use: .apartments, liftFrom: 5, unitWidth: Span(7, 10))
        d.proportions = D.Proportions(groundHeight: Span(3.8, 4.4), floorHeight: Span(3.0, 3.3), bay: Span(3.2, 4.4), pier: Choice([0.3, 0.8]))
        d.window = D.WindowDef(share: Choice([0.6, 0.86]), minWidth: 1.4, maxWidth: 4.0, sill: Choice([0.1, 0.8, 0.95]), height: Span(1.5, 2.4),
                               recess: Choice([0.1, 0.3]), frame: 0.07, mullions: Choice([1, 2]), sillTrim: 0)
        d.facade = D.FacadeDef(shops: 0.6, awnings: 0.5, balconies: Choice([0, 0.34, 0.5, 1]), balustrade: Choice([.glass, .glass, .solid]),
                               ledge: 0.5, floorLedges: 0.4, cornice: Span(0), plinth: false, roomDepth: 4.8)
        d.massing = D.MassingDef(shapes: [.rect, .rect, .l, .u, .t], penthouse: 0.4, roof: Choice([.flat]), parapet: Choice([0.5, 1.1]))
        var wall = MaterialDef([[0.86, 0.86, 0.84], [0.68, 0.68, 0.66], [0.8, 0.74, 0.64], [0.55, 0.57, 0.6], [0.3, 0.31, 0.33],
                                [0.74, 0.5, 0.36]], .concrete)
        wall.finishes = [MaterialDef.Finish(surface: .concrete), MaterialDef.Finish(surface: .plaster), MaterialDef.Finish(surface: .concrete)]
        d.palette.wall = wall
        var base = MaterialDef([[0.3, 0.3, 0.31], [0.5, 0.5, 0.5]], .concrete)
        (base.like, base.likeChance) = ("wall", 1.0 / 3)
        d.palette.base = base
        var trim = MaterialDef([[0.9, 0.9, 0.9], [0.25, 0.25, 0.26]], .concrete)
        (trim.like, trim.likeChance) = ("wall", 1.0 / 3)
        d.palette.trim = trim
        d.palette.frame = MaterialDef([[0.1, 0.1, 0.11], [0.22, 0.22, 0.24], [0.8, 0.8, 0.8]], nil, shade: 0)
        d.palette.accent = MaterialDef([[0.7, 0.36, 0.12], [0.12, 0.3, 0.4], [0.5, 0.5, 0.2], [0.15, 0.15, 0.16], [0.6, 0.2, 0.16]], nil)
        d.palette.glass = MaterialDef([[0.9, 0.95, 0.94], [0.78, 0.88, 0.9]], nil, shade: 0)
        d.interior.paints = [[0.9, 0.9, 0.88], [0.82, 0.84, 0.84], [0.86, 0.82, 0.76], [0.7, 0.74, 0.72]]
        d.interior.woods = [[0.62, 0.5, 0.36], [0.72, 0.62, 0.48], [0.3, 0.24, 0.2]]
        return d
    }()

    /// A colour that is slot `slot`'s times `scale`, on `surface`.
    private static func like(_ slot: String, _ scale: Float, _ surface: SurfaceKind?) -> MaterialDef {
        var m = MaterialDef([[0.7, 0.7, 0.7]], surface)
        (m.like, m.likeChance, m.likeScale) = (slot, 1, scale)
        return m
    }

    /// The built-in style of a district (a mixed city's lots have their own districts: never .mixed).
    static func style(_ district: CityStyle) -> BuildingStyleDef {
        switch district {
        case .oldtown: return oldtown
        case .residential: return residential
        case .warehouse: return warehouse
        case .office: return office
        case .modern, .mixed: return modern
        }
    }
}
