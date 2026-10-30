import EngineCore
import simd

/// The fern grown: nine fronds from one point, arching over (ribbons, the leaves along them its pinnae, shrinking to
/// the tip).
package enum Fern: PlantProgram {
    package static let species = Foliage.SpeciesInfo(id: "fern") {
        $0.name = "Fern"
        $0.seedIndex = 5
        $0.role = .groundCover
        $0.look.leaves = [[0.13, 0.28, 0.07], [0.16, 0.3, 0.08]]
        $0.look.autumn = [0.27, 0.17, 0.06]
        $0.habitat.order = 11
        $0.habitat.cover = .init()
        $0.habitat.cover?.count = 6000
        $0.habitat.cover?.cell = 4
        $0.habitat.cover?.patch = 17
        $0.habitat.cover?.salt = 47
        $0.habitat.cover?.what = 4066
        $0.habitat.cover?.size = 0.9...1.7
        $0.habitat.cover?.sink = 0.02
    }

    package static func plant(_ p: inout PlantContext) -> Wire<Foliage.Plant> {
        let grow = p.grow {
            $0.cycles = 8
            $0.targetHeight = 0.8
            $0.maxGeneration = 1
            $0.seedRadius = 0.003
            $0.radiusGrowth = 0.0004
            $0.apicalDominance = 0
            $0.trunk.segment = 0.1
            $0.trunk.apicalRamp = .linear(1, 0.7)
            $0.trunk.randomAngle = 0.05
            $0.trunk.phototropism = 0
            $0.trunk.gravitropism = -0.22
            $0.light.requirement = 0
            $0.senescence = nil
            $0.stems = 9
            $0.stemSpread = 0.75
        }
        let wood = p.skeleton(grow) {
            $0.noise = 0
            $0.flare = 0
            $0.ribbon = true
        }
        let leaves = p.leaves(wood) {
            $0.length = 0.13
            $0.width = 0.035
            $0.sizeV = 0.1
            $0.perMetre = 60
            $0.start = 0.12
            $0.angle = 1.3
            $0.angleV = 0.1
            $0.phyllotaxis = .distichous
            $0.fold = 0.05
            $0.size = .linear(1, 0.12)
            $0.flutter = 0.15
        }
        let output = p.output(wood, leaves: leaves) { $0.stemsAreLeaves = true }
        return output
    }
}
