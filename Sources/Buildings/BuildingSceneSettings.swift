import CoreGraphics
import EngineCore
import Foundation
import Physics
import simd

/// Which buildings the city is made of: every style by district, or one of them everywhere.
package enum CityStyle: Int, CaseIterable, Codable {
    case mixed              // towers in the centre, mid-rise blocks around them, old town and warehouses at the edge
    case oldtown            // narrow plastered houses with pitched roofs and shutters
    case residential        // brick apartment blocks with balconies around courtyards
    case warehouse          // low, wide brick halls with big windows and loading doors
    case office             // glass towers on podiums, with setbacks
    case modern             // concrete and panel mid-rise blocks with ribbon windows

    package var title: String {
        switch self {
        case .mixed: return "Mixed districts"
        case .oldtown: return "Old town"
        case .residential: return "Residential blocks"
        case .warehouse: return "Warehouses"
        case .office: return "Office towers"
        case .modern: return "Modern mid-rise"
        }
    }
}

/// The generated city (the City scenes): changing any of it builds the city again.
/// (Which city is `SceneSettings.seed`'s to say, as for the plants.)
package struct CitySettings: Equatable, Codable {
    /// Blocks along each side of the street grid (1 = a single block).
    package var blocks = 4
    package var style = CityStyle.mixed
    /// At night: the share of windows with a light on behind them.
    package var lit: Float = 0.35
    /// The share of windows with a room behind the glass instead of a blind (at night the lit ones have a lamp).
    package var rooms: Float = 0.15
    /// Generated brick, plaster, concrete, tile and paving textures (ProceduralTextures); off: flat colours.
    package var textures = true
    /// A window's shell (reveal, frame, sill, lintel, shutters) is made once and placed at every window like it
    /// (Building.Module), a building an assembly of them (Scene.Assembly.rigid); off: every building one mesh of its own.
    package var modules = false
    /// The building the camera comes near (within `interiorReach` metres) has its interior made, in the background:
    /// rooms, stairs, furniture, lights you can walk among (Scene+Interiors.swift). Off: every building a shell.
    package var interiors = true
    package var interiorReach: Float = 30
    /// A canal through the city in place of its middle avenue (with 4 blocks a side or more): quays, bridges where
    /// the streets cross it, water (CityPlan.canal).
    package var canal = true

    package static let blockRange = 1...10
    package static let litRange: ClosedRange<Float> = 0...1
    package static let roomRange: ClosedRange<Float> = 0...0.5

    /// (As the memberwise initializer, for the modules above this one.)
    package init(blocks: Int = 4, style: CityStyle = CityStyle.mixed, lit: Float = 0.35, rooms: Float = 0.15, textures: Bool = true, modules: Bool = false, interiors: Bool = true, interiorReach: Float = 30, canal: Bool = true) {
        self.blocks = blocks
        self.style = style
        self.lit = lit
        self.rooms = rooms
        self.textures = textures
        self.modules = modules
        self.interiors = interiors
        self.interiorReach = interiorReach
        self.canal = canal
    }
}

/// The building workshop (Scene+Buildings.swift): which building it shows, and how.
package struct BuildingSceneSettings: Equatable, Codable {
    /// The style's id (BuildingCatalog), the lot (its width across the front, its depth), what its sides look onto,
    /// its floors and seed.
    package var style = "residential"
    package var lot = SIMD2<Float>(20, 14)
    package var sides = Sides.row
    package var floors = 5
    package var seed = 1
    package var layout = Layout.single
    package var view = View.full
    /// The cutaway's and the dollhouse's top storey (0: the ground floor).
    package var cut = 1
    package var night = false
    /// A single building of a city to show instead (the editor's Pin), nil: the workshop's own.
    package var pinned: LotRef? = nil
    /// Registry keys (BuildingCatalog.register), session state: the editor's variations of the style to show beside it
    /// (layout `mutate`), and the definitions to show in its place (comparing with the saved ones). "" = none.
    package var mutants = ""
    package var compare = ""

    package enum Sides: Int, CaseIterable, Codable {
        case row            // between neighbours, a yard behind
        case backToBack     // between neighbours, a neighbour behind too
        case corner         // a street in front and on its right
        case free           // streets and open ground all round
        package var edges: [CityPlan.Edge] {
            switch self {
            case .row: return [.street, .party, .open, .party]
            case .backToBack: return [.street, .party, .party, .party]
            case .corner: return [.street, .street, .party, .party]
            case .free: return [.street, .open, .open, .street]
            }
        }
        package var title: String { ["In a row", "Back to back", "On a corner", "Free-standing"][rawValue] }
    }
    package enum Layout: Int, CaseIterable, Codable {
        case single         // the building on its lot
        case street         // between two neighbours of its style
        case mutate         // it and the editor's variations of it, along a street
        package var title: String { ["One building", "In its street", "Variations"][rawValue] }
    }
    package enum View: Int, CaseIterable, Codable {
        case full
        case cutaway        // no roof and nothing above storey `cut`
        case dollhouse      // ...and no front wall up to it either
        package var title: String { ["Whole", "Cutaway", "Dollhouse"][rawValue] }
    }

    package static let floorRange = 1...40
    package static let widthRange: ClosedRange<Float> = 6...48
    package static let depthRange: ClosedRange<Float> = 8...48

    /// (As the memberwise initializer, for the modules above this one.)
    package init(style: String = "residential", lot: SIMD2<Float> = SIMD2<Float>(20, 14), sides: Sides = Sides.row, floors: Int = 5, seed: Int = 1, layout: Layout = Layout.single, view: View = View.full, cut: Int = 1, night: Bool = false, pinned: LotRef? = nil, mutants: String = "", compare: String = "") {
        self.style = style
        self.lot = lot
        self.sides = sides
        self.floors = floors
        self.seed = seed
        self.layout = layout
        self.view = view
        self.cut = cut
        self.night = night
        self.pinned = pinned
        self.mutants = mutants
        self.compare = compare
    }
}
