import EngineCore
import simd

/// The dead tree grown: gnarled, most of its branches shed in the shade, no leaves.
package enum DeadTree: PlantProgram {
    package static let species = Foliage.SpeciesInfo(id: "dead") {
        $0.name = "Dead tree"
        $0.seedIndex = 3
        $0.ages.variants = [0, 1, 2]
        $0.look.bark = [0.36, 0.33, 0.29]
        $0.look.leaves = [[0.3, 0.27, 0.2]]
        $0.look.translucency = 0
        $0.habitat.order = 3
        $0.habitat.share = 0.035
    }

    package static func plant(_ p: inout PlantContext) -> Wire<Foliage.Plant> {
        let grow = p.grow {
            $0.cycles = 30
            $0.targetHeight = 10
            $0.radiusGrowth = 0.01
            $0.apicalDominance = 0.4
            $0.gravity = 0.1
            $0.trunk.segment = 0.4
            $0.trunk.axillaryRamp = .points([[0, 0], [0.3, 0], [0.45, 0.8], [1, 1]])
            $0.trunk.axilAngle = 0.9
            $0.trunk.randomAngle = 0.15
            $0.branch = .init()
            $0.branch?.segment = 0.35
            $0.branch?.axillaryGrowth = 0.6
            $0.branch?.axillaryRamp = .linear(0.4, 1)
            $0.branch?.randomAngle = 0.3
            $0.senescence?.threshold = 0.4
            $0.senescence?.cycles = 2
        }
        let wood = p.skeleton(grow) {
            $0.noise = 0.12
            $0.flare = 0.5
            $0.lobeDepth = 0.3
        }
        let output = p.output(wood)
        return output
    }
}
