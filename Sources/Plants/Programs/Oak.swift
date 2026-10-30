import EngineCore
import simd

/// The oak grown bud by bud, as Unreal's Mega Plants sample tree (DeciduousTree_01, its Grower nodes' values): a leader
/// to the top, a clear bole to about 3 m, then a branch at nearly every node; alternate side branches; short spurs on
/// the last generation's nodes; the shaded inner shoots shed. Its light is ours, not Unreal's (whose strong pull toward
/// the sky its tips' heavy sag offsets): the turns toward it are weaker, the shade lighter, so that it comes out as that
/// tree does, 12 m tall and 9 wide, about 350 branches and 750 twigs.
package enum Oak: PlantProgram {
    package static let species = Foliage.SpeciesInfo(id: "oak") {
        $0.name = "Oak"
        $0.seedIndex = 0
        $0.ages.variants = [2, 2, 3]
        // Muted olive leaves, as the Mega Plants tree's read in Unreal's vegetation editor (the light the leaves pass
        // among themselves greens and saturates them). Its leaf texture's own mean is a deeper olive, 0.10/0.12/0.04:
        // these sit between that hue and the grey ones that once matched its crown (a third darker: its glossier leaves
        // catch more of the sun).
        $0.look.bark = [0.15, 0.125, 0.092]
        $0.look.leaves = [[0.21, 0.24, 0.19], [0.23, 0.26, 0.205], [0.18, 0.21, 0.17], [0.235, 0.255, 0.2]]
        $0.look.autumn = [0.3, 0.14, 0.035]
        $0.habitat.order = 1
        $0.habitat.base = 0.9
        $0.habitat.elevation.gain = -0.7
        $0.habitat.stand = -1.6
    }

    package static let palette: Foliage.Palette? = Foliage.Palette {
        $0.sparse = 0.85 // (Unreal's palette picks its twigs at random, all as leafy)
    }

    /// Its twigs, as that tree's Leaf_Twig meshes: a short shoot crowded with about a dozen elliptic, smooth-edged
    /// leaves set round it (LeafSet022's, leaves-oak), a clump.
    package static func twig(_ p: inout PlantContext) -> Wire<Foliage.Mesh> {
        let twigGrow = p.grow(.twig) {
            $0.cycles = 4
            $0.targetHeight = 0.34
            $0.maxGeneration = 2
            $0.seedRadius = 0.0009 // (hung twice their size: as thin as that tree's twigs)
            $0.radiusGrowth = 0.0005
            $0.trunk.segment = 0.08
            $0.trunk.axillaryGrowth = 0.5
            $0.trunk.apicalRamp = .linear(1, 0.8)
            $0.trunk.axillaryRamp = .linear(0, 0.4)
            $0.trunk.randomAngle = 0.2
            $0.trunk.flatten = 0
            $0.branch?.segment = 0.06
            $0.branch?.flatten = 0
        }
        let twigWood = p.skeleton(twigGrow, .twig)
        let twigLeaves = p.leaves(twigWood, .twig) {
            $0.perMetre = 40
            $0.angle = 0.75
            $0.sheet = "leaves-oak" // (LeafSet024's beech leaves stay the default sheet)
        }
        let twig = p.twig(twigWood, leaves: twigLeaves)
        return twig
    }

    package static func plant(_ p: inout PlantContext) -> Wire<Foliage.Plant> {
        let grow = p.grow {
            $0.cycles = 45
            $0.targetHeight = 20
            $0.radiusGrowth = 0.0035
            $0.apicalDominance = 0
            $0.ethyleneBuildup = 0.15
            $0.gravity = 0.2
            $0.trunk.segment = 0.4
            $0.trunk.apicalRamp = .points([[0, 0.994], [0.619, 0.381], [1, 0]])
            $0.trunk.axillaryRamp = .points([[0, 0], [0.156, 0], [0.179, 0.435], [0.312, 0.674], [0.493, 0.664], [1, 1]])
            $0.trunk.axilAngle = 0.96 // 55° (Unreal's axil angle 35° is up from the level)
            $0.trunk.randomAngle = 0.03
            $0.trunk.phototropism = 0.19
            $0.trunk.sproutLight = 0.44
            $0.trunk.requirement = 0.2
            $0.branch = .init()
            $0.branch?.segment = 0.34 // 0.4 × its branch scale 0.85
            $0.branch?.apicalRamp = .points([[0, 0.205], [0.423, 0.34], [1, 0]])
            $0.branch?.axillaryRamp = .points([[0, 0], [0.218, 0.387], [1, 1]])
            $0.branch?.phyllotaxis = .distichous
            $0.branch?.axilAngle = 0.785 // 45°
            $0.branch?.randomAngle = 0.06
            $0.branch?.phototropism = 0.08
            $0.branch?.requirement = 0
            $0.light.lengthImpact = 0
            $0.light.shadow = 16
            $0.senescence?.threshold = 0.2
            $0.bareNodes = 3
        }
        let grafts = p.grafts(grow) { $0.perBranch = 2 }
        let spurs = p.spurs(grafts)
        let carve = p.carve(spurs)
        let wood = p.skeleton(carve) {
            $0.thinning = 0.9
            $0.flare = 0.9
            $0.flareHeight = 0.7
        }
        // Hung by Unreal's foliage distributor's hormone mode: every 0.3 m back from each tip while the wood is young,
        // the trunk's top too, left and right of the branch in a plane of its own nearly square to it, twice their size
        // and larger toward the branch's foot.
        let twigs = p.distribute(wood, palette: p.palette) {
            $0.spacing = 0.3
            $0.ethylene = 0.9
            $0.fromGeneration = 1
            $0.scale = 1.725
            $0.scaleV = 0.1
            $0.angle = 1.45 // 83°
            $0.lightAim = 0.1
            $0.alternate = true
            $0.roll = 1.05
            $0.tipScale = 1
            $0.alongScale = 0.333
        }
        let output = p.output(wood, twigs: twigs)
        return output
    }
}
