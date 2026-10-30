import EngineCore
import simd

/// Patches of blades (grassPatch), not grown.
package enum Grass: PlantProgram {
    package static let species = Foliage.SpeciesInfo(id: "grass") {
        $0.name = "Grass"
        $0.seedIndex = 6
        $0.role = .groundCover
        $0.ages.variants = [0, 0, 6]
        $0.look.leaves = [[0.19, 0.32, 0.09], [0.23, 0.34, 0.1], [0.27, 0.33, 0.12]]
        $0.look.autumn = [0.3, 0.27, 0.11]
        $0.look.translucency = 0.3
        $0.look.leafTexture = .grass
        $0.habitat.order = 12
        $0.habitat.cover = .init()
        $0.habitat.cover?.count = 0
        $0.habitat.cover?.cell = 2
        $0.habitat.cover?.what = 1578
        $0.habitat.cover?.size = 1.05...1.2
        $0.habitat.cover?.sink = 0
        $0.habitat.cover?.open = true
        $0.habitat.cover?.grid = 2
    }

    package static func plant(_ p: inout PlantContext) -> Wire<Foliage.Plant> {
        let grass = p.grass()
        return grass
    }
}
