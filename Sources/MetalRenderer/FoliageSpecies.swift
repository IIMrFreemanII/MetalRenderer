import Foundation
import simd

/// The built-in species' recipes, as the code before the species were data asked for them (the tests, the texture
/// dump). Scenes take theirs from the catalog they are built with (PlantCatalog), which the editor may have changed.
extension Foliage {
    /// Bough meshes per species: every tree of the species hangs these few on its limbs, turned and scaled.
    static func paletteSize(_ species: Species) -> Int { PlantCatalog.builtIn[species].paletteSize }

    /// Seeded variants of a species at an age.
    static func variants(_ species: Species, _ age: Age) -> Int { PlantCatalog.builtIn[species].variants(age) }

    static func recipe(_ species: Species, age: Age) -> Recipe { PlantCatalog.builtIn[species].recipe(age) }

    /// A bough of the species' palette (an oak's for a species without one).
    static func boughRecipe(_ species: Species, variant: Int) -> Recipe {
        PlantCatalog.builtIn[species].boughRecipe(variant: variant) ?? PlantCatalog.builtIn[.oak].boughRecipe(variant: variant)!
    }
}
