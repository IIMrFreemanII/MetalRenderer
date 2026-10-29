import EngineCore
import Foundation
import simd

/// A species as data: everything that makes its plants what they are (how it grows, its twigs, its colours) and
/// where it grows. The built-in ones are BuiltInPlants.swift's; the plant editor saves its own as JSON
/// (Assets/Plants/<id>.json, PlantStore.swift), which replace a built-in one of the same id or add a species.
extension Foliage {
    /// What a species is to the scenes that place it.
    package enum Role: String, CaseIterable, Codable {
        case tree           // stands on its own; an assembly where the scene has them
        case bush           // under the trees, in patches
        case groundCover    // ferns and grass: meshes that lean in the wind by themselves
    }

    /// A species whose plants are patches of grass blades (Foliage.grassPatch), not grown.
    package struct GrassPatch: Codable, Equatable {
        package var size: Float = 2
        package var blades = 800

        package init(size: Float = 2, blades: Int = 800) {
            self.size = size
            self.blades = blades
        }
    }

    package struct Ages: Codable, Equatable {
        /// Seeded variants of each age, by `Age.rawValue` (sapling, young, mature). (How a younger plant grows is
        /// its growth's: Growth.Params.young and .sapling.)
        package var variants = [0, 0, 3]

        package init(variants: [Int] = [0, 0, 3]) {
            self.variants = variants
        }
    }

    /// Colours and textures. Colours are linear RGB; a leaf shade is picked per placed plant.
    package struct Look: Codable, Equatable {
        package var bark: SIMD3<Float>
        package var leaves: [SIMD3<Float>]
        package var autumn: SIMD3<Float>? = nil     // nil: the leaves stay as they are
        package var translucency: Float = 0.35
        package var barkTexture = FoliageTextures.Kind.roughBark
        package var leafTexture = FoliageTextures.Kind.leaf
        package var evergreen = false               // keeps its leaves: no leaf fall
    }

    package struct SpeciesDef: Codable, Equatable {
        package var id: String                      // the JSON file's name; the caches' and meshes' names
        package var name: String
        /// What the library's seeds are made from: the built-ins' places in the catalog, a custom species' own number
        /// (from 100, fixed when it is made), so that no species' plants change when another is added or deleted.
        package var seedIndex: Int
        package var role: Role
        package var grass: GrassPatch? = nil
        /// How it grows, bud by bud (Growth, Unreal's growth simulation); its ages are fewer cycles of it. (nil: the
        /// grass, which isn't grown.)
        package var growth: Growth.Params? = nil
        /// Its twigs: its palette (the meshes its trees hang hundreds of) and how they hang.
        package var twigs: Growth.Twigs? = nil
        /// Leaves on its own stems (a fern's pinnae), not on twigs.
        package var leaf: LeafRecipe? = nil
        package var ages = Ages()
        package var look: Look
        package var habitat = Habitat()
        package var stemsAreLeaves = false          // the stems are leaf material (fern fronds)
        package var basedOn: String? = nil          // a custom species: the one it was copied from

        package var paletteSize: Int { grass != nil ? 0 : twigs?.palette ?? 0 }
        package func variants(_ age: Age) -> Int { ages.variants.indices.contains(age.rawValue) ? ages.variants[age.rawValue] : 0 }
    }
}

/// As JSON: `"spiral"`, `"distichous"` or `{"whorled": n}`.
extension Foliage.Phyllotaxis: Codable {
    private enum Key: String, CodingKey { case whorled }

    package init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            switch name {
            case "spiral": self = .spiral
            case "distichous": self = .distichous
            default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "phyllotaxis \(name)"))
            }
            return
        }
        self = .whorled(try decoder.container(keyedBy: Key.self).decode(Int.self, forKey: .whorled))
    }

    package func encode(to encoder: Encoder) throws {
        switch self {
        case .spiral: var c = encoder.singleValueContainer(); try c.encode("spiral")
        case .distichous: var c = encoder.singleValueContainer(); try c.encode("distichous")
        case .whorled(let n): var c = encoder.container(keyedBy: Key.self); try c.encode(n, forKey: .whorled)
        }
    }
}

/// By name in JSON.
extension FoliageTextures.Kind: Codable {
    package init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let kind = Self.allCases.first(where: { $0.name == name }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "texture \(name)"))
        }
        self = kind
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}

/// The species plants are grown from, in order: a species is its place here (Foliage.Species). The built-in ones
/// come first, in their order, whatever replaces them.
package struct PlantCatalog: Equatable {
    package var species: [Foliage.SpeciesDef]

    package subscript(_ s: Foliage.Species) -> Foliage.SpeciesDef { species[s.rawValue] }
    package var all: [Foliage.Species] { species.indices.map(Foliage.Species.init(rawValue:)) }
    package var count: Int { species.count }
    package func species(id: String) -> Foliage.Species? { species.firstIndex { $0.id == id }.map(Foliage.Species.init(rawValue:)) }

    /// The bushes and ground cover, in the order they are scattered (Habitat.order).
    package var covers: [Foliage.Species] {
        all.filter { self[$0].role != .tree && self[$0].habitat.cover != nil }
            .sorted { (self[$0].habitat.order, $0.rawValue) < (self[$1].habitat.order, $1.rawValue) }
    }

    package static let builtIn = PlantCatalog(species: Foliage.builtInSpecies)

    /// (As the memberwise initializer, for the modules above this one.)
    package init(species: [Foliage.SpeciesDef]) {
        self.species = species
    }
}
