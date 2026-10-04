import Foundation
import simd

/// How a window is made: its opening in a bay, how deep it sits in the wall, and what is around it.
struct WindowStyle {
    /// The opening's width as a share of its bay, and its limits in metres.
    var share: Float = 0.5
    var minWidth: Float = 0.8, maxWidth: Float = 1.6
    /// The sill's height above the floor, and the opening's height (cut short under the ceiling).
    var sill: Float = 0.95
    var height: Float = 1.5
    /// How far the glass sits behind the wall's face.
    var recess: Float = 0.18
    var frame: Float = 0.08             // the frame members' width (thinner ones vanish between traced pixels)
    var mullions = 1                    // vertical bars dividing the glass
    var transom = false                 // a horizontal bar, a third from the top
    var sillTrim = true                 // a projecting sill under it
    var lintel = false                  // a projecting head over it
    var shutters = false                // a pair of shutters on the wall beside it
}

/// What stands along the edge of a balcony.
enum Balustrade { case bars, glass, solid }

/// What closes a building's top.
enum RoofKind {
    case flat           // a parapet around it and things on it
    case gabled         // two slopes and a gable at each end (rectangles and L shapes)
    case hipped         // four slopes
    case mansard        // steep sides, a flat top
}

/// The shapes a building's plan can take (Footprint).
enum PlanShape { case rect, l, u, t, courtyard }

/// A building's style, drawn for one building: the proportions its facades are divided by, which pieces they are
/// made of, and its materials. `preset` picks them from the style's ranges and palettes with the building's own
/// generator, so two buildings of a style are related, not alike.
struct BuildingStyle {
    var kind = CityStyle.residential

    // Proportions
    var groundHeight: Float = 3.8
    var floorHeight: Float = 3.0
    var bay: Float = 3.0                // the width a facade's bays aim for
    var pier: Float = 0.6               // plain wall at each end of a facade
    var window = WindowStyle()
    var groundWindow = WindowStyle()

    // The facade's pieces
    var shops: Float = 0                // how likely a street front's ground floor is shop windows
    var loadingDoors = false            // warehouses: big doors on the ground floor
    var balconies: Float = 0            // the share of a facade's bay columns that have balconies
    var balustrade = Balustrade.bars
    var ledge = true                    // a string course over the ground floor
    var floorLedges = false             // ...and a thinner one at every floor
    var cornice: Float = 0.25           // how far the cornice at the top of the wall projects (0 = none)
    var pilasters = false               // flat piers between the bays
    var plinth = true

    // The plan and the top
    var shapes: [PlanShape] = [.rect]
    var setback: Float = 0              // free-standing: how far the walls stand back from the lot's open sides
    var podium = false                  // a wider base of a few floors under a tower
    var setbacks = 0                    // how many times the tower steps in on its way up
    var penthouse: Float = 0            // how likely the top floor stands back behind a terrace
    var roof = RoofKind.flat
    var parapet: Float = 0.9
    var roomDepth: Float = 4.2

    // Materials
    var wall = SurfaceMaterial(color: [0.7, 0.68, 0.62], surface: .plaster)
    var base = SurfaceMaterial(color: [0.55, 0.54, 0.52], surface: .concrete)
    var trim = SurfaceMaterial(color: [0.82, 0.8, 0.76], surface: .plaster)
    var frame = SurfaceMaterial(color: [0.9, 0.9, 0.88])   // diffuse: too thin for a reflection ray to be worth it
    var glass = SurfaceMaterial(color: [0.92, 0.95, 0.94], glass: true)
    var blind = SurfaceMaterial(color: [0.8, 0.78, 0.72])
    var roofing = SurfaceMaterial(color: [0.3, 0.3, 0.32], surface: .concrete)
    var metal = SurfaceMaterial(color: [0.55, 0.57, 0.6], surface: .metalpanel, roughness: 0.45, metallic: 0.9, specular: true)
    var accent = SurfaceMaterial(color: [0.2, 0.3, 0.25])
    var interior = SurfaceMaterial(color: [0.8, 0.77, 0.7])
    var flooring = SurfaceMaterial(color: [0.4, 0.3, 0.2])
    /// Behind a pane with its blind up and no room: the dark of an unlit room.
    var dark = SurfaceMaterial(color: [0.025, 0.025, 0.03])
    /// At night: a lit blind's glow and a room's ceiling lamp.
    var lit = SurfaceMaterial(color: .zero, emission: [0.9, 0.65, 0.4])
    var lamp = SurfaceMaterial(color: .zero, emission: [26, 21, 15])

    static func preset(_ kind: CityStyle, _ rng: inout SplitMix64) -> BuildingStyle {
        func pick<T>(_ options: [T]) -> T { options[rng.int(options.count)] }
        func shade(_ c: SIMD3<Float>, _ amount: Float = 0.08) -> SIMD3<Float> { c * rng.range(1 - amount, 1 + amount) }
        var s = BuildingStyle()
        s.kind = kind
        // What glows behind the blinds at night: mostly warm, some neutral, a few the blue of a screen.
        let glow: [SIMD3<Float>] = [[1.0, 0.72, 0.42], [1.0, 0.78, 0.5], [1.0, 0.86, 0.66], [0.95, 0.92, 0.85], [0.6, 0.75, 1.0]]
        let g = rng.int(glow.count + 2)
        s.lit.emission = glow[g < glow.count ? g : g - glow.count] * rng.range(0.6, 1.2)
        s.interior.color = shade(pick([[0.82, 0.79, 0.72], [0.78, 0.8, 0.78], [0.84, 0.8, 0.7], [0.74, 0.76, 0.8]]))
        s.flooring.color = shade(pick([[0.42, 0.3, 0.2], [0.5, 0.4, 0.28], [0.3, 0.28, 0.27]]))

        switch kind {
        case .oldtown:
            s.groundHeight = rng.range(3.2, 3.8); s.floorHeight = rng.range(2.8, 3.2)
            s.bay = rng.range(2.2, 2.8); s.pier = 0.45
            s.window = WindowStyle(share: 0.45, minWidth: 0.8, maxWidth: 1.1, sill: 0.9, height: rng.range(1.4, 1.7), recess: 0.2,
                                   mullions: 1, transom: true, sillTrim: true, lintel: rng.next() < 0.5, shutters: rng.next() < 0.6)
            s.groundWindow = s.window
            s.groundWindow.shutters = false
            s.shops = 0.35
            s.ledge = rng.next() < 0.7; s.cornice = rng.range(0.2, 0.35); s.pilasters = false
            s.roof = pick([.gabled, .gabled, .gabled, .hipped, .mansard])
            s.roomDepth = 3.6
            s.wall = SurfaceMaterial(color: shade(pick([[0.86, 0.78, 0.6], [0.8, 0.62, 0.5], [0.72, 0.75, 0.7], [0.9, 0.86, 0.78],
                                                        [0.78, 0.68, 0.72], [0.66, 0.74, 0.8], [0.84, 0.72, 0.52]])), surface: .plaster)
            s.base = SurfaceMaterial(color: s.wall.color * 0.8, surface: .plaster)
            s.trim = SurfaceMaterial(color: shade([0.88, 0.86, 0.8]), surface: .plaster)
            s.frame.color = pick([[0.92, 0.92, 0.9], [0.35, 0.22, 0.14], [0.2, 0.3, 0.24]])
            s.accent.color = shade(pick([[0.18, 0.32, 0.24], [0.42, 0.14, 0.12], [0.16, 0.24, 0.4], [0.36, 0.24, 0.14], [0.8, 0.78, 0.7]]))
            s.roofing = SurfaceMaterial(color: shade(pick([[0.62, 0.26, 0.16], [0.5, 0.22, 0.15], [0.3, 0.3, 0.33]])), surface: .rooftile)
        case .residential:
            s.groundHeight = rng.range(3.6, 4.2); s.floorHeight = rng.range(2.9, 3.2)
            s.bay = rng.range(2.8, 3.4); s.pier = 0.6
            s.window = WindowStyle(share: 0.45, minWidth: 1.0, maxWidth: 1.5, sill: 0.9, height: rng.range(1.5, 1.8), recess: 0.2,
                                   mullions: 1, transom: rng.next() < 0.5, sillTrim: true, lintel: true)
            s.groundWindow = s.window
            s.shops = 0.45
            s.balconies = pick([0, 0.34, 0.5]); s.balustrade = pick([.bars, .bars, .solid])
            s.ledge = true; s.floorLedges = rng.next() < 0.3; s.cornice = rng.range(0.25, 0.4); s.pilasters = rng.next() < 0.3
            s.shapes = [.rect, .rect, .l]
            s.roof = pick([.flat, .flat, .mansard])
            s.wall = SurfaceMaterial(color: shade(pick([[0.62, 0.3, 0.22], [0.7, 0.42, 0.3], [0.55, 0.36, 0.28], [0.76, 0.66, 0.5],
                                                        [0.48, 0.24, 0.2], [0.66, 0.5, 0.36]])), surface: .brick)
            s.base = SurfaceMaterial(color: shade(pick([[0.6, 0.58, 0.55], [0.5, 0.48, 0.45], [0.72, 0.68, 0.6]])), surface: .concrete)
            s.trim = SurfaceMaterial(color: shade([0.8, 0.77, 0.7]), surface: .concrete)
            s.frame.color = pick([[0.92, 0.92, 0.9], [0.15, 0.15, 0.16], [0.4, 0.26, 0.16]])
            s.accent.color = shade(pick([[0.12, 0.2, 0.16], [0.4, 0.12, 0.1], [0.12, 0.16, 0.3], [0.1, 0.1, 0.11]]))
            s.roofing = s.roof == .mansard ? SurfaceMaterial(color: shade([0.28, 0.3, 0.34]), surface: .rooftile)
                                           : SurfaceMaterial(color: shade([0.3, 0.3, 0.31]), surface: .concrete)
        case .warehouse:
            s.groundHeight = rng.range(4.8, 6.0); s.floorHeight = rng.range(4.0, 4.6)
            s.bay = rng.range(4.5, 5.5); s.pier = 0.8
            s.window = WindowStyle(share: 0.7, minWidth: 2.0, maxWidth: 4.0, sill: 1.2, height: 2.4, recess: 0.25, frame: 0.07,
                                   mullions: 3, transom: true, sillTrim: true, lintel: false)
            s.groundWindow = s.window
            s.loadingDoors = true
            s.ledge = rng.next() < 0.5; s.cornice = 0.2; s.pilasters = true
            s.shapes = [.rect, .rect, .l]
            s.setback = rng.range(0, 2.5)
            s.roof = pick([.gabled, .flat])
            s.parapet = 0.6
            s.roomDepth = 5
            s.wall = SurfaceMaterial(color: shade(pick([[0.5, 0.26, 0.2], [0.58, 0.34, 0.26], [0.42, 0.3, 0.26], [0.62, 0.56, 0.48]])),
                                     surface: .brick)
            s.base = s.wall
            s.trim = SurfaceMaterial(color: shade([0.62, 0.6, 0.56]), surface: .concrete)
            s.frame.color = pick([[0.1, 0.1, 0.11], [0.16, 0.22, 0.2], [0.3, 0.14, 0.1]])
            s.accent.color = shade(pick([[0.2, 0.3, 0.26], [0.38, 0.16, 0.1], [0.14, 0.2, 0.34], [0.45, 0.42, 0.38]]))
            s.roofing = s.roof == .gabled
                ? SurfaceMaterial(color: shade([0.5, 0.52, 0.54]), surface: .metalpanel, roughness: 0.5, metallic: 0.8, specular: true)
                : SurfaceMaterial(color: shade([0.28, 0.28, 0.29]), surface: .concrete)
        case .office:
            s.groundHeight = rng.range(5.0, 6.0); s.floorHeight = rng.range(3.6, 3.9)
            s.bay = rng.range(1.5, 3.0); s.pier = pick([0.3, 0.5, 1.2])
            s.window = WindowStyle(share: 0.94, minWidth: 1.0, maxWidth: 4.0, sill: pick([0.05, 0.6, 0.9]), height: 4, recess: 0.1,
                                   frame: 0.07, mullions: 0, transom: false, sillTrim: false, lintel: false)
            s.groundWindow = s.window
            s.groundWindow.sill = 0.1; s.groundWindow.mullions = 1
            s.shops = 1                 // a glazed lobby
            s.ledge = true; s.cornice = 0; s.pilasters = rng.next() < 0.6; s.plinth = false
            s.shapes = [.rect, .rect, .u, .courtyard]
            s.setback = rng.range(1.5, 4)
            s.podium = rng.next() < 0.6; s.setbacks = rng.int(3)
            s.roof = .flat; s.parapet = 1.2
            s.roomDepth = 6
            // Tinted glass and the spandrels between the floors.
            let tint: SIMD3<Float> = pick([[0.62, 0.78, 0.86], [0.6, 0.82, 0.74], [0.82, 0.74, 0.6], [0.7, 0.74, 0.8], [0.5, 0.6, 0.7]])
            s.glass.color = tint
            let panel: SIMD3<Float> = pick([[0.62, 0.64, 0.66], [0.3, 0.32, 0.35], [0.75, 0.74, 0.72], [0.16, 0.17, 0.19]])
            s.wall = rng.next() < 0.5 ? SurfaceMaterial(color: shade(panel), surface: .concrete)
                : SurfaceMaterial(color: shade(panel), surface: .metalpanel, roughness: 0.4, metallic: 0.9, specular: true)
            s.base = SurfaceMaterial(color: shade([0.32, 0.31, 0.3]), surface: .concrete, roughness: 0.35, specular: true)
            s.trim = s.wall
            s.frame.color = pick([[0.1, 0.1, 0.11], [0.5, 0.52, 0.55], [0.75, 0.75, 0.76]])
            s.blind.color = shade([0.55, 0.56, 0.56]); s.dark.color = [0.05, 0.055, 0.06]
            s.interior.color = shade([0.8, 0.8, 0.8]); s.flooring.color = shade([0.35, 0.36, 0.38])
            s.lit.emission = pick([[0.95, 0.95, 1.0], [1.0, 0.95, 0.85], [0.85, 0.92, 1.0]]) * rng.range(0.7, 1.1)
            s.lamp.emission = [24, 24, 25]
        case .modern, .mixed:
            s.groundHeight = rng.range(3.8, 4.4); s.floorHeight = rng.range(3.0, 3.3)
            s.bay = rng.range(3.2, 4.4); s.pier = pick([0.3, 0.8])
            s.window = WindowStyle(share: pick([0.6, 0.86]), minWidth: 1.4, maxWidth: 4.0, sill: pick([0.1, 0.8, 0.95]),
                                   height: rng.range(1.5, 2.4), recess: pick([0.1, 0.3]), frame: 0.07, mullions: pick([1, 2]),
                                   transom: false, sillTrim: false, lintel: false)
            s.groundWindow = s.window
            s.shops = 0.6
            s.balconies = pick([0, 0.34, 0.5, 1]); s.balustrade = pick([.glass, .glass, .solid])
            s.ledge = rng.next() < 0.5; s.floorLedges = rng.next() < 0.4; s.cornice = 0; s.plinth = false
            s.shapes = [.rect, .rect, .l, .u, .t]
            s.penthouse = 0.4
            s.roof = .flat; s.parapet = pick([0.5, 1.1])
            s.roomDepth = 4.8
            s.wall = SurfaceMaterial(color: shade(pick([[0.86, 0.86, 0.84], [0.68, 0.68, 0.66], [0.8, 0.74, 0.64], [0.55, 0.57, 0.6],
                                                        [0.3, 0.31, 0.33], [0.74, 0.5, 0.36]])), surface: pick([.concrete, .plaster, .concrete]))
            s.base = SurfaceMaterial(color: shade(pick([[0.3, 0.3, 0.31], [0.5, 0.5, 0.5], s.wall.color])), surface: .concrete)
            s.trim = SurfaceMaterial(color: shade(pick([[0.9, 0.9, 0.9], [0.25, 0.25, 0.26], s.wall.color])), surface: .concrete)
            s.frame.color = pick([[0.1, 0.1, 0.11], [0.22, 0.22, 0.24], [0.8, 0.8, 0.8]])
            s.accent.color = shade(pick([[0.7, 0.36, 0.12], [0.12, 0.3, 0.4], [0.5, 0.5, 0.2], [0.15, 0.15, 0.16], [0.6, 0.2, 0.16]]))
            s.glass.color = pick([[0.9, 0.95, 0.94], [0.78, 0.88, 0.9]])
        }
        return s
    }
}
