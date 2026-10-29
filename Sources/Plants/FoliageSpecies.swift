import EngineCore
import Foundation
import simd

/// The built-in species' palettes and variants, as the code before the species were data asked for them (the tests, the texture
/// dump). Scenes take theirs from the catalog they are built with (PlantCatalog), which the editor may have changed.
extension Foliage {
    /// Twig meshes per species: every tree of the species hangs these few on its limbs, turned and scaled.
    package static func paletteSize(_ species: Species) -> Int { PlantCatalog.builtIn[species].paletteSize }

    /// Seeded variants of a species at an age.
    package static func variants(_ species: Species, _ age: Age) -> Int { PlantCatalog.builtIn[species].variants(age) }
}
