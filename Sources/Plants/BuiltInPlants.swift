import EngineCore
import Foundation
import simd

/// The built-in species: how each grows (the growth simulation's parameters, Growth.Params), its twigs, its
/// colours and where it grows. Lengths are metres, angles radians. Originals in the families of Unreal's Mega Plants
/// presets: a broad oak, a birch, a spruce, a dead tree, a bush, a fern; and grass, patches of blades.
extension Foliage {
    package static let builtInSpecies: [SpeciesDef] = [oakDef, birchDef, coniferDef, deadDef, bushDef, fernDef, grassDef]

    /// The oak grown bud by bud, as Unreal's Mega Plants sample tree (DeciduousTree_01, its Grower nodes' values):
    /// a leader to the top, a clear bole to about 3 m, then a branch at nearly every node; alternate side branches;
    /// short spurs on the last generation's nodes; the shaded inner shoots shed. Its light is ours, not Unreal's (whose
    /// strong pull toward the sky its tips' heavy sag offsets): the turns toward it are weaker, the shade lighter, so
    /// that it comes out as that tree does, 12 m tall and 9 wide, about 350 branches and 750 twigs.
    private static let oakGrowth: Growth.Params = {
        var p = Growth.Params()
        p.cycles = 45
        p.targetHeight = 20
        p.maxGeneration = 4
        p.radiusGrowth = 0.0035
        p.apicalDominance = 0
        p.ethyleneBuildup = 0.15
        p.gravity = 0.2
        p.bareNodes = 3
        p.trunk.segment = 0.4
        p.trunk.apicalRamp = .points([[0, 0.994], [0.619, 0.381], [1, 0]])
        p.trunk.axillaryRamp = .points([[0, 0], [0.156, 0], [0.179, 0.435], [0.312, 0.674], [0.493, 0.664], [1, 1]])
        p.trunk.axillaryGrowth = 1
        p.trunk.axilAngle = 0.96                    // 55° (Unreal's axil angle 35° is up from the level)
        p.trunk.randomAngle = 0.03
        p.trunk.phototropism = 0.19
        p.trunk.sproutLight = 0.44
        p.trunk.requirement = 0.2
        var b = Growth.Shoot()
        b.segment = 0.34                            // 0.4 × its branch scale 0.85
        b.apicalGrowth = 1
        b.apicalRamp = .points([[0, 0.205], [0.423, 0.34], [1, 0]])
        b.axillaryGrowth = 1
        b.axillaryRamp = .points([[0, 0], [0.218, 0.387], [1, 1]])
        b.phyllotaxis = .distichous
        b.axilAngle = 0.785                         // 45°
        b.randomAngle = 0.06
        b.phototropism = 0.08
        b.requirement = 0
        p.branch = b
        p.light.lengthImpact = 0
        p.light.shadow = 16
        p.senescence?.threshold = 0.2
        p.grafts = Growth.Grafts()
        p.grafts?.perBranch = 2
        p.spurs = Growth.Spurs()
        p.carve = 0.1
        p.wood.thinning = 0.9
        p.wood.flare = 0.9
        p.wood.flareHeight = 0.7
        return p
    }()

    /// Its twigs, as that tree's Leaf_Twig meshes: a short shoot crowded with about a dozen elliptic, smooth-edged
    /// leaves set round it (LeafSet022's, leaves-oak), hung by Unreal's foliage distributor's hormone mode: every 0.3 m
    /// back from each tip while the wood is young, the trunk's top too, left and right of the branch in a plane of its
    /// own nearly square to it, twice their size and larger toward the branch's foot.
    private static let oakTwigs: Growth.Twigs = {
        var t = Growth.Twigs()
        // The twig: a short shoot crowded with leaves set round it, a clump, as the sample's Leaf_Twig meshes are.
        t.growth.cycles = 4
        t.growth.targetHeight = 0.34
        t.growth.maxGeneration = 2
        t.growth.trunk.segment = 0.08
        t.growth.trunk.apicalRamp = .linear(1, 0.8)
        t.growth.trunk.axillaryRamp = .linear(0, 0.4)
        t.growth.trunk.axillaryGrowth = 0.5
        t.growth.trunk.flatten = 0
        t.growth.trunk.randomAngle = 0.2
        t.growth.branch?.segment = 0.06
        t.growth.branch?.flatten = 0
        t.growth.seedRadius = 0.0009                // (hung twice their size: as thin as that tree's twigs)
        t.growth.radiusGrowth = 0.0005
        t.leaf.perMetre = 40
        t.leaf.length = 0.13
        t.leaf.start = 0.1
        t.leaf.angle = 0.75
        t.leaf.sheet = "leaves-oak"     // (LeafSet024's beech leaves stay the default sheet)
        t.scale = 1.725
        t.scaleV = 0.1
        t.spacing = 0.3
        t.ethylene = 0.9
        t.fromGeneration = 1
        t.angle = 1.45                              // 83°
        t.lightAim = 0.1
        t.alternate = true
        t.roll = 1.05
        t.tipScale = 1
        t.alongScale = 0.333
        t.sparse = 0.85                             // (Unreal's palette picks its twigs at random, all as leafy)
        return t
    }()

    private static let oakDef = SpeciesDef(
        id: "oak", name: "Oak", seedIndex: 0, role: .tree,
        growth: oakGrowth,
        twigs: oakTwigs,
        ages: Ages(variants: [2, 2, 3]),
        // Muted olive leaves, as the Mega Plants tree's read in Unreal's vegetation editor (the light the leaves pass
        // among themselves greens and saturates them). Its leaf texture's own mean is a deeper olive, 0.10/0.12/0.04:
        // these sit between that hue and the grey ones that once matched its crown (a third darker: its glossier leaves
        // catch more of the sun).
        look: Look(bark: [0.15, 0.125, 0.092], leaves: [[0.21, 0.24, 0.19], [0.23, 0.26, 0.205], [0.18, 0.21, 0.17], [0.235, 0.255, 0.2]],
                   autumn: [0.3, 0.14, 0.035]),
        habitat: Habitat(order: 1, base: 0.9, elevation: .init(gain: -0.7, from: 0, to: 0.7), stand: -1.6))

    /// The birch grown: tall and narrow, steep thin branches, white-barked, its twigs hanging. Measured against Unreal's
    /// sample quaking aspen (a 14 m one: a third as wide as tall, a trunk 0.12 m in radius, 26 / 81 / 57 branches of the
    /// second to fourth generations, 634 twigs): every bud may sprout however shaded (its crown is open), its trunk's
    /// internodes short enough for that many branches.
    private static let birchGrowth: Growth.Params = {
        var p = Growth.Params()
        p.cycles = 34
        p.targetHeight = 17
        p.radiusGrowth = 0.0034
        p.apicalDominance = 0.45
        p.gravity = 0.15
        p.trunk.segment = 0.4
        p.trunk.apicalRamp = .points([[0, 1], [0.7, 0.95], [1, 0]])
        p.trunk.axillaryRamp = .points([[0, 0], [0.25, 0], [0.4, 0.7], [1, 1]])
        p.trunk.axillaryGrowth = 0.9
        p.trunk.axilAngle = 0.85
        p.trunk.randomAngle = 0.06
        p.trunk.phototropism = 0.05
        p.trunk.gravitropism = 0.08
        var b = Growth.Shoot()
        b.segment = 0.35
        b.apicalRamp = .linear(1, 0.45)
        b.axillaryGrowth = 0.85
        b.axillaryRamp = .linear(0.5, 1)
        b.axilAngle = 0.8
        b.randomAngle = 0.2
        b.phototropism = 0.3
        b.gravitropism = 0.02
        p.branch = b
        p.wood.thinning = 0.65
        p.wood.flare = 0.25
        p.wood.lobes = 3
        p.wood.lobeDepth = 0.08
        p.wood.noise = 0.03
        p.light.shadow = 5
        p.senescence = nil
        p.light.requirement = 0
        return p
    }()

    private static let birchTwigs: Growth.Twigs = {
        var t = Growth.Twigs()
        t.growth.trunk.gravitropism = -0.35       // (its sky is +Z: these hang)
        t.growth.branch?.gravitropism = -0.35
        t.leaf.length = 0.075
        t.leaf.perMetre = 55
        t.leaf.sheet = "leaves-birch"             // pointed, serrated (ambientCG LeafSet014)
        t.scale = 0.85
        t.spacing = 0.12
        t.lightAim = 0.2
        return t
    }()

    /// The conifer grown, a spruce: one leader to the top, whorls of five near-level branches in flat sprays, the
    /// lowest shed in their own shade.
    private static let coniferGrowth: Growth.Params = {
        var p = Growth.Params()
        p.cycles = 40
        p.targetHeight = 20
        p.maxGeneration = 3
        p.radiusGrowth = 0.008
        p.apicalDominance = 0.75
        p.auxinFalloff = 0.4
        p.gravity = 0.25
        p.trunk.segment = 0.5
        p.trunk.apicalRamp = .points([[0, 1], [0.9, 0.95], [1, 0]])
        p.trunk.axillaryRamp = .points([[0, 0], [0.08, 0], [0.15, 1], [1, 1]])
        p.trunk.phyllotaxis = .whorled(5)
        p.trunk.axilAngle = 1.45
        p.trunk.randomAngle = 0.03
        p.trunk.phototropism = 0
        p.trunk.gravitropism = 0.2
        var b = Growth.Shoot()
        b.segment = 0.3
        b.apicalRamp = .linear(1, 0.3)
        b.axillaryGrowth = 0.7
        b.axillaryRamp = .linear(0.6, 1)
        b.phyllotaxis = .distichous
        b.axilAngle = 0.9
        b.flatten = 0.7
        b.randomAngle = 0.08
        b.phototropism = 0.15
        b.gravitropism = -0.05
        p.branch = b
        p.wood.thinning = 0.6
        p.wood.flare = 0.35
        p.wood.lobes = 6
        p.wood.lobeDepth = 0.12
        p.wood.noise = 0.02
        p.senescence = nil
        p.light.requirement = 0.03
        p.light.shadow = 6
        return p
    }()

    private static let coniferTwigs: Growth.Twigs = {
        var t = Growth.Twigs()
        t.growth.cycles = 7
        t.growth.trunk.phyllotaxis = .distichous
        t.growth.trunk.flatten = 0.9
        t.growth.trunk.axilAngle = 1.0
        t.growth.branch?.phyllotaxis = .distichous
        t.growth.branch?.flatten = 0.9
        t.leaf = LeafRecipe(shape: .needle, length: 0.06, width: 0.015, sizeV: 0.2, perMetre: 130, start: 0.05, angle: 1.0,
                            angleV: 0.25, fold: 0, flutter: 0.4, cluster: 2)
        t.spacing = 0.15
        t.scale = 0.9
        t.ethylene = 0.9
        t.angle = 0.4
        t.lightAim = 0.1
        return t
    }()

    /// The dead tree grown: gnarled, most of its branches shed in the shade, no leaves.
    private static let deadGrowth: Growth.Params = {
        var p = Growth.Params()
        p.cycles = 30
        p.targetHeight = 10
        p.radiusGrowth = 0.01
        p.apicalDominance = 0.4
        p.gravity = 0.1
        p.trunk.segment = 0.4
        p.trunk.apicalRamp = .linear(1, 0)
        p.trunk.axillaryRamp = .points([[0, 0], [0.3, 0], [0.45, 0.8], [1, 1]])
        p.trunk.axilAngle = 0.9
        p.trunk.randomAngle = 0.15
        var b = Growth.Shoot()
        b.segment = 0.35
        b.randomAngle = 0.3
        b.phototropism = 0.2
        b.axillaryGrowth = 0.6
        b.axillaryRamp = .linear(0.4, 1)
        p.branch = b
        p.senescence?.threshold = 0.4
        p.senescence?.cycles = 2
        p.wood.noise = 0.12
        p.wood.flare = 0.5
        p.wood.lobeDepth = 0.3
        return p
    }()

    /// The bush grown: six stems from the ground, branching freely into a rounded mass, its stems a hazel's (Unreal's
    /// sample hazels: 1.2 to 1.8 cm in radius at 2 to 3 m).
    private static let bushGrowth: Growth.Params = {
        var p = Growth.Params()
        p.stems = 6
        p.stemSpread = 0.55
        p.cycles = 14
        p.targetHeight = 2
        p.maxGeneration = 3
        p.seedRadius = 0.003
        p.radiusGrowth = 0.0009
        p.apicalDominance = 0.2
        p.gravity = 0.05
        p.trunk.segment = 0.2
        p.trunk.apicalRamp = .linear(1, 0.3)
        p.trunk.axillaryRamp = .linear(0.3, 1)
        p.trunk.axillaryGrowth = 0.8
        p.trunk.axilAngle = 0.8
        p.trunk.randomAngle = 0.18
        p.trunk.phototropism = 0.3
        p.trunk.gravitropism = 0.05
        var b = p.trunk
        b.segment = 0.15
        p.branch = b
        p.wood.flare = 0
        p.wood.lobeDepth = 0
        p.wood.noise = 0.02
        return p
    }()

    private static let bushTwigs: Growth.Twigs = {
        var t = Growth.Twigs()
        t.leaf.length = 0.1
        t.leaf.sheet = "leaves-bush"              // round, toothed, a hazel's (ambientCG LeafSet009)
        t.scale = 0.55
        t.spacing = 0.14
        t.fromGeneration = 1
        t.ethylene = 0.9
        return t
    }()

    /// The fern grown: nine fronds from one point, arching over (ribbons, the leaves along them its pinnae).
    private static let fernGrowth: Growth.Params = {
        var p = Growth.Params()
        p.stems = 9
        p.stemSpread = 0.75
        p.cycles = 8
        p.targetHeight = 0.8
        p.maxGeneration = 1
        p.seedRadius = 0.003
        p.radiusGrowth = 0.0004
        p.apicalDominance = 0
        p.trunk.segment = 0.1
        p.trunk.apicalRamp = .linear(1, 0.7)
        p.trunk.randomAngle = 0.05
        p.trunk.phototropism = 0
        p.trunk.gravitropism = -0.22
        p.light.requirement = 0
        p.senescence = nil
        p.wood.ribbon = true
        p.wood.flare = 0
        p.wood.noise = 0
        return p
    }()

    private static let birchDef = SpeciesDef(
        id: "birch", name: "Birch", seedIndex: 1, role: .tree,
        growth: birchGrowth,
        twigs: birchTwigs,
        ages: Ages(variants: [2, 2, 3]),
        look: Look(bark: [0.72, 0.7, 0.65], leaves: [[0.19, 0.31, 0.07], [0.23, 0.34, 0.08], [0.16, 0.28, 0.07]],
                   autumn: [0.42, 0.33, 0.04], barkTexture: .birchBark),
        habitat: Habitat(order: 2, base: 0.25, light: 1))

    private static let coniferDef = SpeciesDef(
        id: "conifer", name: "Conifer", seedIndex: 2, role: .tree,
        growth: coniferGrowth,
        twigs: coniferTwigs,
        ages: Ages(variants: [2, 2, 3]),
        look: Look(bark: [0.19, 0.13, 0.09], leaves: [[0.045, 0.11, 0.055], [0.055, 0.13, 0.06], [0.04, 0.1, 0.06]],
                   translucency: 0.12, leafTexture: .needle, evergreen: true),
        habitat: Habitat(order: 0, base: 0.3, elevation: .init(gain: 1.1, from: -0.1, to: 0.7), slope: 3, stand: 1.6))

    private static let deadDef = SpeciesDef(
        id: "dead", name: "Dead tree", seedIndex: 3, role: .tree,
        growth: deadGrowth,
        ages: Ages(variants: [0, 1, 2]),
        look: Look(bark: [0.36, 0.33, 0.29], leaves: [[0.3, 0.27, 0.2]], translucency: 0),
        habitat: Habitat(order: 3, share: 0.035))

    private static let bushDef = SpeciesDef(
        id: "bush", name: "Bush", seedIndex: 4, role: .bush,
        growth: bushGrowth,
        twigs: bushTwigs,
        ages: Ages(variants: [0, 2, 3]),
        look: Look(bark: [0.22, 0.16, 0.11], leaves: [[0.12, 0.24, 0.07], [0.1, 0.2, 0.06], [0.15, 0.25, 0.06]], autumn: [0.36, 0.09, 0.04]),
        habitat: Habitat(order: 10, cover: .init(count: 2600, cell: 6.1, patch: 28, salt: 31, what: 0xB05, size: 0.8...1.3, sink: 0.05)))

    /// Its pinnae either side of the fronds, shrinking to the tip.
    private static let fernDef = SpeciesDef(
        id: "fern", name: "Fern", seedIndex: 5, role: .groundCover,
        growth: fernGrowth,
        leaf: LeafRecipe(shape: .kite, length: 0.13, width: 0.035, sizeV: 0.1, perMetre: 60, start: 0.12, angle: 1.3,
                       angleV: 0.1, phyllotaxis: .distichous, fold: 0.05, tipScale: 0.12, flutter: 0.15),
        ages: Ages(variants: [0, 0, 3]),
        look: Look(bark: [0.22, 0.16, 0.11], leaves: [[0.13, 0.28, 0.07], [0.16, 0.3, 0.08]], autumn: [0.27, 0.17, 0.06]),
        habitat: Habitat(order: 11, cover: .init(count: 6000, cell: 4, patch: 17, salt: 47, what: 0xFE2, size: 0.9...1.7, sink: 0.02)),
        stemsAreLeaves: true)

    /// Patches of blades (grassPatch), not grown.
    private static let grassDef = SpeciesDef(
        id: "grass", name: "Grass", seedIndex: 6, role: .groundCover, grass: GrassPatch(),
        ages: Ages(variants: [0, 0, 6]),
        look: Look(bark: [0.22, 0.16, 0.11], leaves: [[0.19, 0.32, 0.09], [0.23, 0.34, 0.1], [0.27, 0.33, 0.12]],
                   autumn: [0.3, 0.27, 0.11], translucency: 0.3, leafTexture: .grass),
        habitat: Habitat(order: 12, cover: .init(count: 0, cell: 2, patch: 20, what: 0x62A, size: 1.05...1.2, sink: 0, open: true, grid: 2)))
}
