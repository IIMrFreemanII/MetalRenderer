import EngineCore
import Foundation
import Physics
import simd

/// How a window is made: its opening in a bay, how deep it sits in the wall, and what is around it.
package struct WindowStyle {
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
package enum Balustrade: CaseIterable { case bars, glass, solid }

/// What closes a building's top.
package enum RoofKind: CaseIterable {
    case flat           // a parapet around it and things on it
    case gabled         // two slopes and a gable at each end (rectangles and L shapes)
    case hipped         // four slopes
    case mansard        // steep sides, a flat top
}

/// The shapes a building's plan can take (Footprint).
package enum PlanShape: CaseIterable { case rect, l, u, t, courtyard }

/// A building's style, drawn for one building from its style's definition (BuildingStyle.draw, BuildingStyleDef):
/// the proportions its facades are divided by, which pieces they are made of, what its plan and rooms are, and its
/// materials.
package struct BuildingStyle {
    /// What it was drawn from.
    package var def = BuiltInBuildings.residential
    package var programme = Programme()

    // Proportions
    package var groundHeight: Float = 3.8
    package var floorHeight: Float = 3.0
    package var bay: Float = 3.0                // the width a facade's bays aim for
    package var pier: Float = 0.6               // plain wall at each end of a facade
    package var window = WindowStyle()
    package var groundWindow = WindowStyle()

    // The facade's pieces
    package var shops: Float = 0                // how likely a street front's ground floor is shop windows
    package var awnings: Float = 0.5            // ...with awnings
    package var loadingDoors = false            // warehouses: big doors on the ground floor
    package var balconies: Float = 0            // the share of a facade's bay columns that have balconies
    package var balustrade = Balustrade.bars
    package var ledge = true                    // a string course over the ground floor
    package var floorLedges = false             // ...and a thinner one at every floor
    package var cornice: Float = 0.25           // how far the cornice at the top of the wall projects (0 = none)
    package var pilasters = false               // flat piers between the bays
    package var plinth = true

    // The plan and the top
    package var shapes: [PlanShape] = [.rect]
    package var setback: Float = 0              // free-standing: how far the walls stand back from the lot's open sides
    package var tower = 0                       // from this many floors a tower (0: never)
    package var podium = false                  // a wider base of a few floors under a tower
    package var setbacks = 0                    // how many times the tower steps in on its way up
    package var penthouse: Float = 0            // how likely the top floor stands back behind a terrace
    package var roof = RoofKind.flat
    package var roofPitch: Float = 0.75         // a gabled roof's rise over run
    package var parapet: Float = 0.9
    package var roomDepth: Float = 4.2          // without an interior: the room boxes behind some windows
    package var chimneys: Float = 0, waterTank: Float = 0, mast: Float = 0

    // Materials
    package var wall = SurfaceMaterial(color: [0.7, 0.68, 0.62], surface: .plaster)
    package var base = SurfaceMaterial(color: [0.55, 0.54, 0.52], surface: .concrete)
    package var trim = SurfaceMaterial(color: [0.82, 0.8, 0.76], surface: .plaster)
    package var frame = SurfaceMaterial(color: [0.9, 0.9, 0.88])   // diffuse: too thin for a reflection ray to be worth it
    package var glass = SurfaceMaterial(color: [0.92, 0.95, 0.94], glass: true)
    package var blind = SurfaceMaterial(color: [0.8, 0.78, 0.72])
    package var roofing = SurfaceMaterial(color: [0.3, 0.3, 0.32], surface: .concrete)
    package var metal = SurfaceMaterial(color: [0.55, 0.57, 0.6], surface: .metalpanel, roughness: 0.45, metallic: 0.9, specular: true)
    package var accent = SurfaceMaterial(color: [0.2, 0.3, 0.25])
    package var interior = SurfaceMaterial(color: [0.8, 0.77, 0.7])
    package var flooring = SurfaceMaterial(color: [0.4, 0.3, 0.2])
    /// Behind a pane with its blind up and no room: the dark of an unlit room.
    package var dark = SurfaceMaterial(color: [0.025, 0.025, 0.03])
    /// At night: a lit blind's glow and a room's ceiling lamp.
    package var lit = SurfaceMaterial(color: .zero, emission: [0.9, 0.65, 0.4])
    package var lamp = SurfaceMaterial(color: .zero, emission: [26, 21, 15])

    package var isOffice: Bool { programme.use == .offices }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(def: BuildingStyleDef = BuiltInBuildings.residential, programme: Programme = Programme(), groundHeight: Float = 3.8, floorHeight: Float = 3.0, bay: Float = 3.0, pier: Float = 0.6, window: WindowStyle = WindowStyle(), groundWindow: WindowStyle = WindowStyle(), shops: Float = 0, awnings: Float = 0.5, loadingDoors: Bool = false, balconies: Float = 0, balustrade: Balustrade = Balustrade.bars, ledge: Bool = true, floorLedges: Bool = false, cornice: Float = 0.25, pilasters: Bool = false, plinth: Bool = true, shapes: [PlanShape] = [.rect], setback: Float = 0, tower: Int = 0, podium: Bool = false, setbacks: Int = 0, penthouse: Float = 0, roof: RoofKind = RoofKind.flat, roofPitch: Float = 0.75, parapet: Float = 0.9, roomDepth: Float = 4.2, chimneys: Float = 0, waterTank: Float = 0, mast: Float = 0, wall: SurfaceMaterial = SurfaceMaterial(color: [0.7, 0.68, 0.62], surface: .plaster), base: SurfaceMaterial = SurfaceMaterial(color: [0.55, 0.54, 0.52], surface: .concrete), trim: SurfaceMaterial = SurfaceMaterial(color: [0.82, 0.8, 0.76], surface: .plaster), frame: SurfaceMaterial = SurfaceMaterial(color: [0.9, 0.9, 0.88]), glass: SurfaceMaterial = SurfaceMaterial(color: [0.92, 0.95, 0.94], glass: true), blind: SurfaceMaterial = SurfaceMaterial(color: [0.8, 0.78, 0.72]), roofing: SurfaceMaterial = SurfaceMaterial(color: [0.3, 0.3, 0.32], surface: .concrete), metal: SurfaceMaterial = SurfaceMaterial(color: [0.55, 0.57, 0.6], surface: .metalpanel, roughness: 0.45, metallic: 0.9, specular: true), accent: SurfaceMaterial = SurfaceMaterial(color: [0.2, 0.3, 0.25]), interior: SurfaceMaterial = SurfaceMaterial(color: [0.8, 0.77, 0.7]), flooring: SurfaceMaterial = SurfaceMaterial(color: [0.4, 0.3, 0.2]), dark: SurfaceMaterial = SurfaceMaterial(color: [0.025, 0.025, 0.03]), lit: SurfaceMaterial = SurfaceMaterial(color: .zero, emission: [0.9, 0.65, 0.4]), lamp: SurfaceMaterial = SurfaceMaterial(color: .zero, emission: [26, 21, 15])) {
        self.def = def
        self.programme = programme
        self.groundHeight = groundHeight
        self.floorHeight = floorHeight
        self.bay = bay
        self.pier = pier
        self.window = window
        self.groundWindow = groundWindow
        self.shops = shops
        self.awnings = awnings
        self.loadingDoors = loadingDoors
        self.balconies = balconies
        self.balustrade = balustrade
        self.ledge = ledge
        self.floorLedges = floorLedges
        self.cornice = cornice
        self.pilasters = pilasters
        self.plinth = plinth
        self.shapes = shapes
        self.setback = setback
        self.tower = tower
        self.podium = podium
        self.setbacks = setbacks
        self.penthouse = penthouse
        self.roof = roof
        self.roofPitch = roofPitch
        self.parapet = parapet
        self.roomDepth = roomDepth
        self.chimneys = chimneys
        self.waterTank = waterTank
        self.mast = mast
        self.wall = wall
        self.base = base
        self.trim = trim
        self.frame = frame
        self.glass = glass
        self.blind = blind
        self.roofing = roofing
        self.metal = metal
        self.accent = accent
        self.interior = interior
        self.flooring = flooring
        self.dark = dark
        self.lit = lit
        self.lamp = lamp
    }
}
