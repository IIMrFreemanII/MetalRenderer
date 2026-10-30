import EngineCore
import simd

/// The conifer grown, a spruce: one leader to the top, whorls of five near-level branches in flat sprays, the lowest
/// shed in their own shade.
package enum Conifer: PlantProgram {
    package static let species = Foliage.SpeciesInfo(id: "conifer") {
        $0.name = "Conifer"
        $0.seedIndex = 2
        $0.ages.variants = [2, 2, 3]
        $0.look.bark = [0.19, 0.13, 0.09]
        $0.look.leaves = [[0.045, 0.11, 0.055], [0.055, 0.13, 0.06], [0.04, 0.1, 0.06]]
        $0.look.translucency = 0.12
        $0.look.leafTexture = .needle
        $0.look.evergreen = true
        $0.habitat.order = 0
        $0.habitat.base = 0.3
        $0.habitat.elevation.gain = 1.1
        $0.habitat.elevation.from = -0.1
        $0.habitat.slope = 3
        $0.habitat.stand = 1.6
    }

    package static let palette: Foliage.Palette? = Foliage.Palette()

    package static func twig(_ p: inout PlantContext) -> Wire<Foliage.Mesh> {
        let twigGrow = p.grow(.twig) {
            $0.cycles = 7
            $0.trunk.phyllotaxis = .distichous
            $0.trunk.axilAngle = 1
            $0.trunk.flatten = 0.9
            $0.branch?.phyllotaxis = .distichous
            $0.branch?.flatten = 0.9
        }
        let twigWood = p.skeleton(twigGrow, .twig)
        let twigLeaves = p.leaves(twigWood, .twig) {
            $0.shape = .needle
            $0.length = 0.06
            $0.width = 0.015
            $0.sizeV = 0.2
            $0.perMetre = 130
            $0.start = 0.05
            $0.angle = 1
            $0.angleV = 0.25
            $0.fold = 0
            $0.flutter = 0.4
            $0.cluster = 2
        }
        let twig = p.twig(twigWood, leaves: twigLeaves)
        return twig
    }

    package static func plant(_ p: inout PlantContext) -> Wire<Foliage.Plant> {
        let grow = p.grow {
            $0.cycles = 40
            $0.targetHeight = 20
            $0.maxGeneration = 3
            $0.radiusGrowth = 0.008
            $0.apicalDominance = 0.75
            $0.auxinFalloff = 0.4
            $0.gravity = 0.25
            $0.trunk.segment = 0.5
            $0.trunk.apicalRamp = .points([[0, 1], [0.9, 0.95], [1, 0]])
            $0.trunk.axillaryRamp = .points([[0, 0], [0.08, 0], [0.15, 1], [1, 1]])
            $0.trunk.phyllotaxis = .whorled(5)
            $0.trunk.axilAngle = 1.45
            $0.trunk.randomAngle = 0.03
            $0.trunk.phototropism = 0
            $0.trunk.gravitropism = 0.2
            $0.branch = .init()
            $0.branch?.axillaryGrowth = 0.7
            $0.branch?.apicalRamp = .linear(1, 0.3)
            $0.branch?.axillaryRamp = .linear(0.6, 1)
            $0.branch?.phyllotaxis = .distichous
            $0.branch?.axilAngle = 0.9
            $0.branch?.randomAngle = 0.08
            $0.branch?.flatten = 0.7
            $0.branch?.phototropism = 0.15
            $0.branch?.gravitropism = -0.05
            $0.light.requirement = 0.03
            $0.light.shadow = 6
            $0.senescence = nil
        }
        let wood = p.skeleton(grow) {
            $0.thinning = 0.6
            $0.noise = 0.02
            $0.flare = 0.35
            $0.lobes = 6
            $0.lobeDepth = 0.12
        }
        let twigs = p.distribute(wood, palette: p.palette) {
            $0.spacing = 0.15
            $0.ethylene = 0.9
            $0.angle = 0.4
            $0.lightAim = 0.1
        }
        let output = p.output(wood, twigs: twigs)
        return output
    }
}
