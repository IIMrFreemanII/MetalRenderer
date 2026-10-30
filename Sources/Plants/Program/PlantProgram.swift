import EngineCore
import Foundation
import simd

/// A plant as code: Swift that calls its stages one after another, each stage's result a wire into the next, as the
/// nodes of a vegetation graph are wired (Unreal's Procedural Vegetation Editor). The built-in species are programs
/// (Programs/), a file in Assets/Plants is one too (PlantStore, PlantCompiler).
///
/// A program's two functions are run many times, once for each twig of the palette and each plant of the library, and
/// once with a context that only writes down what they call (PlantContext.Mode.trace), which is how a program's
/// species and graph are known without growing anything.
package protocol PlantProgram {
    static var species: Foliage.SpeciesInfo { get }
    /// Its twigs' palette (nil: it hangs no twigs, and `twig` is never called).
    static var palette: Foliage.Palette? { get }
    /// One twig of the palette, grown along +Y with +Z its sky.
    static func twig(_ p: inout PlantContext) -> Wire<Foliage.Mesh>
    /// One plant.
    static func plant(_ p: inout PlantContext) -> Wire<Foliage.Plant>
    /// Its Swift Code nodes' functions, for a graph of the same code to run while it isn't compiled itself.
    static var code: [PlantCodeEntry] { get }
}

extension PlantProgram {
    package static var palette: Foliage.Palette? { nil }
    package static func twig(_ p: inout PlantContext) -> Wire<Foliage.Mesh> { p.noTwig() }
    package static var code: [PlantCodeEntry] { [] }
}

/// A Swift Code node's function, compiled: by the hash of its text (PlantCode.hash), taking what's on its wire.
package struct PlantCodeEntry {
    let hash: String
    let run: (inout PlantContext, Any) -> Any

    package init<T>(_ hash: String, _ function: @escaping (inout PlantContext, T) -> T) {
        self.hash = hash
        // (Its wire may have been moved to another type since: what's on it goes through until it compiles again.)
        run = { p, input in
            guard let value = input as? T else { return input }
            return function(&p, value)
        }
    }
}

/// A stage's result: which value of the context it is.
package struct Wire<Value> {
    package let node: Int32
}

/// Which of a stage's starting points its closure edits.
package enum PlantPreset: String, Codable, Equatable {
    case standard
    case twig           // a twig's: Growth.Twigs' defaults
}

extension Foliage {
    /// What a program says of its species besides how it grows: all of SpeciesDef that isn't a stage's.
    package struct SpeciesInfo: Codable, Equatable {
        package var id: String
        package var name: String
        package var seedIndex = 100
        package var role = Role.tree
        package var ages = Ages()
        package var look = Look()
        package var habitat = Habitat()
        package var basedOn: String? = nil

        package init(id: String, _ edit: (inout SpeciesInfo) -> Void = { _ in }) {
            self.id = id
            name = id
            edit(&self)
        }
    }

    /// A species' twigs, a palette of meshes (Unreal's graft palette): how many, from sparse to dense.
    package struct Palette: Codable, Equatable {
        package var count = 6
        package var sparse: Float? = nil            // the sparsest twig's leaves, of the densest's (nil: 0.55)

        package init(_ edit: (inout Palette) -> Void = { _ in }) { edit(&self) }
    }

    /// The last stage's settings.
    package struct Assembly: Codable, Equatable {
        package var stemsAreLeaves = false          // the stems are leaf material (fern fronds)

        package init() {}
    }
}

extension Growth {
    /// The carve stage's settings: the trunk's foot cut off, this share of its length (Unreal's Carve from the bottom).
    package struct Carve: Codable, Equatable {
        package var share: Float = 0.1

        package init() {}
    }

    /// The gravity stage's settings: the plant bent once it's grown (Unreal's Gravity node), where Params.gravity sags
    /// it cycle by cycle. The defaults' strength is Unreal's sample tree's.
    package struct Gravity: Codable, Equatable {
        package enum Mode: String, Codable {
            case gravity
            case phototropic                        // toward each point's light, not `direction`
        }

        package var mode = Mode.gravity
        package var strength: Float = 0.33          // an internode turns toward the pull by a tenth of this at most
        package var direction: SIMD3<Float>? = nil  // the pull (nil: away from the plant's sky)
        package var angleCorrection: Float = 0      // what's along the pull already turns less: at 1, a tenth as much

        package init() {}
    }

    /// The bone reduction stage's settings (Unreal's Bone Reduction): of a stem's n twig bones, lerp(n, 1, strength) stay.
    /// The default is Unreal's sample tree's.
    package struct BoneReduction: Codable, Equatable {
        package var strength: Float = 0.83

        package init() {}
    }
}
