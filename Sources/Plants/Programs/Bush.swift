import EngineCore
import simd

/// The bush grown: six stems from the ground, branching freely into a rounded mass, its stems a hazel's (Unreal's
/// sample hazels: 1.2 to 1.8 cm in radius at 2 to 3 m).
package enum Bush: PlantProgram {
    package static let species = Foliage.SpeciesInfo(id: "bush") {
        $0.name = "Bush"
        $0.seedIndex = 4
        $0.role = .bush
        $0.ages.variants = [0, 2, 3]
        $0.look.leaves = [[0.12, 0.24, 0.07], [0.1, 0.2, 0.06], [0.15, 0.25, 0.06]]
        $0.look.autumn = [0.36, 0.09, 0.04]
        $0.habitat.order = 10
        $0.habitat.cover = .init()
        $0.habitat.cover?.count = 2600
        $0.habitat.cover?.cell = 6.1
        $0.habitat.cover?.patch = 28
        $0.habitat.cover?.salt = 31
        $0.habitat.cover?.what = 2821
        $0.habitat.cover?.sink = 0.05
    }

    package static let palette: Foliage.Palette? = Foliage.Palette()

    package static func twig(_ p: inout PlantContext) -> Wire<Foliage.Mesh> {
        let twigGrow = p.grow(.twig)
        let twigWood = p.skeleton(twigGrow, .twig)
        let twigLeaves = p.leaves(twigWood, .twig) {
            $0.length = 0.1
            $0.sheet = "leaves-bush" // round, toothed, a hazel's (ambientCG LeafSet009)
        }
        let twig = p.twig(twigWood, leaves: twigLeaves)
        return twig
    }

    package static func plant(_ p: inout PlantContext) -> Wire<Foliage.Plant> {
        let grow = p.grow {
            $0.cycles = 14
            $0.targetHeight = 2
            $0.maxGeneration = 3
            $0.seedRadius = 0.003
            $0.radiusGrowth = 0.0009
            $0.apicalDominance = 0.2
            $0.gravity = 0.05
            $0.trunk.segment = 0.2
            $0.trunk.axillaryGrowth = 0.8
            $0.trunk.apicalRamp = .linear(1, 0.3)
            $0.trunk.axillaryRamp = .linear(0.3, 1)
            $0.trunk.randomAngle = 0.18
            $0.trunk.phototropism = 0.3
            $0.trunk.gravitropism = 0.05
            $0.branch = .init()
            $0.branch?.segment = 0.15
            $0.branch?.axillaryGrowth = 0.8
            $0.branch?.apicalRamp = .linear(1, 0.3)
            $0.branch?.axillaryRamp = .linear(0.3, 1)
            $0.branch?.randomAngle = 0.18
            $0.branch?.phototropism = 0.3
            $0.branch?.gravitropism = 0.05
            $0.stems = 6
            $0.stemSpread = 0.55
        }
        let wood = p.skeleton(grow) {
            $0.noise = 0.02
            $0.flare = 0
            $0.lobeDepth = 0
        }
        let twigs = p.distribute(wood, palette: p.palette) {
            $0.spacing = 0.14
            $0.ethylene = 0.9
            $0.fromGeneration = 1
            $0.scale = 0.55
        }
        let output = p.output(wood, twigs: twigs)
        return output
    }
}
