import EngineCore
import simd

/// The birch grown: tall and narrow, steep thin branches, white-barked, its twigs hanging. Measured against Unreal's
/// sample quaking aspen (a 14 m one: a third as wide as tall, a trunk 0.12 m in radius, 26 / 81 / 57 branches of the
/// second to fourth generations, 634 twigs): every bud may sprout however shaded (its crown is open), its trunk's
/// internodes short enough for that many branches.
package enum Birch: PlantProgram {
    package static let species = Foliage.SpeciesInfo(id: "birch") {
        $0.name = "Birch"
        $0.seedIndex = 1
        $0.ages.variants = [2, 2, 3]
        $0.look.bark = [0.72, 0.7, 0.65]
        $0.look.leaves = [[0.19, 0.31, 0.07], [0.23, 0.34, 0.08], [0.16, 0.28, 0.07]]
        $0.look.autumn = [0.42, 0.33, 0.04]
        $0.look.barkTexture = .birchBark
        $0.habitat.order = 2
        $0.habitat.base = 0.25
        $0.habitat.light = 1
    }

    package static let palette: Foliage.Palette? = Foliage.Palette()

    package static func twig(_ p: inout PlantContext) -> Wire<Foliage.Mesh> {
        let twigGrow = p.grow(.twig) {
            $0.trunk.gravitropism = -0.35 // (its sky is +Z: these hang)
            $0.branch?.gravitropism = -0.35
        }
        let twigWood = p.skeleton(twigGrow, .twig)
        let twigLeaves = p.leaves(twigWood, .twig) {
            $0.length = 0.075
            $0.perMetre = 55
            $0.sheet = "leaves-birch" // pointed, serrated (ambientCG LeafSet014)
        }
        let twig = p.twig(twigWood, leaves: twigLeaves)
        return twig
    }

    package static func plant(_ p: inout PlantContext) -> Wire<Foliage.Plant> {
        let grow = p.grow {
            $0.cycles = 34
            $0.targetHeight = 17
            $0.radiusGrowth = 0.0034
            $0.apicalDominance = 0.45
            $0.gravity = 0.15
            $0.trunk.segment = 0.4
            $0.trunk.axillaryGrowth = 0.9
            $0.trunk.apicalRamp = .points([[0, 1], [0.7, 0.95], [1, 0]])
            $0.trunk.axillaryRamp = .points([[0, 0], [0.25, 0], [0.4, 0.7], [1, 1]])
            $0.trunk.axilAngle = 0.85
            $0.trunk.randomAngle = 0.06
            $0.trunk.phototropism = 0.05
            $0.trunk.gravitropism = 0.08
            $0.branch = .init()
            $0.branch?.segment = 0.35
            $0.branch?.axillaryGrowth = 0.85
            $0.branch?.apicalRamp = .linear(1, 0.45)
            $0.branch?.axillaryRamp = .linear(0.5, 1)
            $0.branch?.randomAngle = 0.2
            $0.branch?.phototropism = 0.3
            $0.branch?.gravitropism = 0.02
            $0.light.requirement = 0
            $0.light.shadow = 5
            $0.senescence = nil
        }
        let wood = p.skeleton(grow) {
            $0.thinning = 0.65
            $0.noise = 0.03
            $0.flare = 0.25
            $0.lobes = 3
            $0.lobeDepth = 0.08
        }
        let twigs = p.distribute(wood, palette: p.palette) {
            $0.spacing = 0.12
            $0.scale = 0.85
            $0.lightAim = 0.2
        }
        let output = p.output(wood, twigs: twigs)
        return output
    }
}
