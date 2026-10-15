import Foundation
import simd

/// A species as data: everything that makes its plants what they are (its recipes, how it ages, its colours) and
/// where it grows. The built-in ones are BuiltInPlants.swift's; the plant editor saves its own as JSON
/// (Assets/Plants/<id>.json, PlantStore.swift), which replace a built-in one of the same id or add a species.
extension Foliage {
    /// What a species is to the scenes that place it.
    enum Role: String, CaseIterable, Codable {
        case tree           // stands on its own; an assembly where the scene has them
        case bush           // under the trees, in patches
        case groundCover    // ferns and grass: meshes that lean in the wind by themselves
    }

    /// A species whose plants are patches of grass blades (Foliage.grassPatch), not grown from its recipe.
    struct GrassPatch: Codable, Equatable {
        var size: Float = 2
        var blades = 800
    }

    /// The boughs every tree of the species hangs: `count` meshes, every other one `short` times as long.
    struct Palette: Codable, Equatable {
        var count = 6
        var short: Float = 0.8
    }

    /// A level's child count at an age: `max(minimum, count x factor)`, rounded down.
    struct CountRule: Codable, Equatable {
        var level: Int
        var factor: Float
        var minimum: Int

        func apply(_ count: Int) -> Int {
            // (The built-in factors are 3/4, 7/10 and 9/20 of whole counts: what the products' float errors are
            // rounded past, never across.)
            max(minimum, Int(Double(count) * Double(factor) + 1e-3))
        }
    }

    /// How a younger plant differs from the mature recipe.
    struct AgeRule: Codable, Equatable {
        var trunkLength: Float = 1          // level 0's length, of the mature one's
        var counts: [CountRule] = []
        var maxLevels: Int? = nil           // keeps only the first levels
        var trunkSegments: Int? = nil
        var trunkRadial: Int? = nil
        var limbRadial: Int? = nil          // level 1's sides
        var ratio: Float = 1                // of the mature radius ratio
        var boughScale: Float = 1           // of the mature boughs' sizes
        var carve: Carve? = nil             // in place of the mature one

        func apply(_ r: inout Recipe) {
            r.levels[0].length *= trunkLength
            if let s = trunkSegments { r.levels[0].segments = s }
            if let s = trunkRadial { r.levels[0].radial = s }
            if let m = maxLevels { r.levels = Array(r.levels.prefix(max(m, 1))) }
            for rule in counts where rule.level < r.levels.count { r.levels[rule.level].count = rule.apply(r.levels[rule.level].count) }
            if let s = limbRadial, r.levels.count > 1 { r.levels[1].radial = s }
            r.ratio *= ratio
            if let boughs = r.graft?.scale { r.graft?.scale = boughs.lowerBound * boughScale...boughs.upperBound * boughScale }
            if let carve { r.carve = carve }
        }
    }

    struct Ages: Codable, Equatable {
        var young = AgeRule()
        var sapling = AgeRule()
        /// Seeded variants of each age, by `Age.rawValue` (sapling, young, mature).
        var variants = [0, 0, 3]
    }

    /// Colours and textures. Colours are linear RGB; a leaf shade is picked per placed plant.
    struct Look: Codable, Equatable {
        var bark: SIMD3<Float>
        var leaves: [SIMD3<Float>]
        var autumn: SIMD3<Float>? = nil     // nil: the leaves stay as they are
        var translucency: Float = 0.35
        var barkTexture = FoliageTextures.Kind.roughBark
        var leafTexture = FoliageTextures.Kind.leaf
        var evergreen = false               // keeps its leaves: no leaf fall
    }

    struct SpeciesDef: Codable, Equatable {
        var id: String                      // the JSON file's name; the caches' and meshes' names
        var name: String
        /// What the library's seeds are made from: the built-ins' places in the catalog, a custom species' own number
        /// (from 100, fixed when it is made), so that no species' plants change when another is added or deleted.
        var seedIndex: Int
        var role: Role
        var grass: GrassPatch? = nil
        var recipe: Recipe                  // the mature plant
        var bough: Recipe? = nil            // nil: no palette (its plants are one mesh)
        var palette = Palette()
        var ages = Ages()
        var look: Look
        var habitat = Habitat()
        var stemsAreLeaves = false          // the stems are leaf material (fern fronds)
        var basedOn: String? = nil          // a custom species: the one it was copied from

        var paletteSize: Int { bough == nil || grass != nil ? 0 : palette.count }
        func variants(_ age: Age) -> Int { ages.variants.indices.contains(age.rawValue) ? ages.variants[age.rawValue] : 0 }

        /// The recipe of its plants of an age.
        func recipe(_ age: Age) -> Recipe {
            var r = recipe
            switch age {
            case .mature: break
            case .young: ages.young.apply(&r)
            case .sapling: ages.sapling.apply(&r)
            }
            return r
        }

        /// A bough of its palette: grown lying along +Y with +Z toward the sky, about a metre long. The graft
        /// distributor scales it, so its leaves shrink with it.
        func boughRecipe(variant: Int) -> Recipe? {
            guard var r = bough else { return nil }
            if variant % 2 != 0 { r.levels[0].length *= palette.short }   // the palette has longer and shorter boughs
            return r
        }
    }
}

/// As JSON: `"spiral"`, `"distichous"` or `{"whorled": n}`.
extension Foliage.Phyllotaxis: Codable {
    private enum Key: String, CodingKey { case whorled }

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
        switch self {
        case .spiral: var c = encoder.singleValueContainer(); try c.encode("spiral")
        case .distichous: var c = encoder.singleValueContainer(); try c.encode("distichous")
        case .whorled(let n): var c = encoder.container(keyedBy: Key.self); try c.encode(n, forKey: .whorled)
        }
    }
}

/// By name in JSON.
extension FoliageTextures.Kind: Codable {
    init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let kind = Self.allCases.first(where: { $0.name == name }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "texture \(name)"))
        }
        self = kind
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}

/// The species plants are grown from, in order: a species is its place here (Foliage.Species). The built-in ones
/// come first, in their order, whatever replaces them.
struct PlantCatalog: Equatable {
    var species: [Foliage.SpeciesDef]

    subscript(_ s: Foliage.Species) -> Foliage.SpeciesDef { species[s.rawValue] }
    var all: [Foliage.Species] { species.indices.map(Foliage.Species.init(rawValue:)) }
    var count: Int { species.count }
    func species(id: String) -> Foliage.Species? { species.firstIndex { $0.id == id }.map(Foliage.Species.init(rawValue:)) }

    /// The bushes and ground cover, in the order they are scattered (Habitat.order).
    var covers: [Foliage.Species] {
        all.filter { self[$0].role != .tree && self[$0].habitat.cover != nil }
            .sorted { (self[$0].habitat.order, $0.rawValue) < (self[$1].habitat.order, $1.rawValue) }
    }

    static let builtIn = PlantCatalog(species: Foliage.builtInSpecies)
}
