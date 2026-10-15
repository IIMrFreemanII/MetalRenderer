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
enum Balustrade: CaseIterable { case bars, glass, solid }

/// What closes a building's top.
enum RoofKind: CaseIterable {
    case flat           // a parapet around it and things on it
    case gabled         // two slopes and a gable at each end (rectangles and L shapes)
    case hipped         // four slopes
    case mansard        // steep sides, a flat top
}

/// The shapes a building's plan can take (Footprint).
enum PlanShape: CaseIterable { case rect, l, u, t, courtyard }

/// A building's style, drawn for one building from its style's definition (BuildingStyle.draw, BuildingStyleDef):
/// the proportions its facades are divided by, which pieces they are made of, what its plan and rooms are, and its
/// materials.
struct BuildingStyle {
    /// What it was drawn from.
    var def = BuiltInBuildings.residential
    var programme = Programme()

    // Proportions
    var groundHeight: Float = 3.8
    var floorHeight: Float = 3.0
    var bay: Float = 3.0                // the width a facade's bays aim for
    var pier: Float = 0.6               // plain wall at each end of a facade
    var window = WindowStyle()
    var groundWindow = WindowStyle()

    // The facade's pieces
    var shops: Float = 0                // how likely a street front's ground floor is shop windows
    var awnings: Float = 0.5            // ...with awnings
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
    var tower = 0                       // from this many floors a tower (0: never)
    var podium = false                  // a wider base of a few floors under a tower
    var setbacks = 0                    // how many times the tower steps in on its way up
    var penthouse: Float = 0            // how likely the top floor stands back behind a terrace
    var roof = RoofKind.flat
    var roofPitch: Float = 0.75         // a gabled roof's rise over run
    var parapet: Float = 0.9
    var roomDepth: Float = 4.2          // without an interior: the room boxes behind some windows
    var chimneys: Float = 0, waterTank: Float = 0, mast: Float = 0

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

    var isOffice: Bool { programme.use == .offices }
}
