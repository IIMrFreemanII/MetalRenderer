import EngineCore
import Foundation
import simd

/// What a program calls its stages on: one for each run, holding the values on its wires.
package struct PlantContext {
    package enum Mode {
        case plant(age: Foliage.Age, palette: [Foliage.Mesh], bark: Foliage.Bark?)
        case twig(variant: Int, of: Int, sparse: Float, cards: Bool)
        case trace(PlantSide)
    }

    package let mode: Mode
    package let species: Foliage.Species
    /// The plant's or the twig's own seed, what its wood's lobes and a grass patch are seeded with.
    package let seed: UInt64
    /// Stop at the skeleton: no mesh is made, for what wants only the skeleton (`kept`).
    package let probe: Bool
    /// The last skeleton made, when probing.
    package private(set) var kept: PlantSkeleton?

    package var rng: SplitMix64
    private var growthSeedsDrawn = 0
    private var values: [Any?] = []
    /// What a trace wrote down, and which node is the palette's.
    package var nodes: [PlantNode] = []
    private var paletteNode: Int32 = -1

    /// A plant draws its growth's seed from its seed, a twig grows from its seed itself and draws its leaves from the
    /// seed's other stream.
    package init(_ mode: Mode, species: Foliage.Species, seed: UInt64, probe: Bool = false) {
        self.mode = mode
        self.species = species
        self.seed = seed
        self.probe = probe
        if case .twig = mode { rng = SplitMix64(seed: seed ^ 0x51ED_2701) } else { rng = SplitMix64(seed: seed) }
    }

    /// A trace of the plant side that goes on from its twig side's (the palette its nodes end in).
    package init(tracing side: PlantSide, after nodes: [PlantNode] = [], palette: Int32 = -1) {
        self.init(.trace(side), species: .oak, seed: 0)
        self.nodes = nodes
        paletteNode = palette
    }

    package func value<T>(_ wire: Wire<T>) -> T { values[Int(wire.node)] as! T }

    private var side: PlantSide? { if case .trace(let side) = mode { return side } else { return nil } }

    private mutating func store<T>(_ value: T) -> Wire<T> {
        values.append(value)
        return Wire(node: Int32(values.count - 1))
    }

    /// In a trace: the stage, written down.
    @discardableResult
    package mutating func record<T>(_ settings: PlantNodeSettings, _ preset: PlantPreset, _ inputs: [Int32]) -> Wire<T> {
        var graph = PlantGraph(nodes: nodes)
        let id = graph.nextID, side = side ?? .plant
        graph.nodes.append(PlantNode(id: id, name: graph.uniqueName(settings.kind.name(side: side)), side: side, preset: preset, settings: settings, inputs: inputs))
        nodes = graph.nodes
        return Wire(node: id)
    }

    private mutating func growthSeed() -> UInt64 {
        growthSeedsDrawn += 1
        if case .twig = mode, growthSeedsDrawn == 1 { return seed }
        return rng.nextUInt64()
    }

    // MARK: - The stages

    /// Grows a plant from its seed, its age's share of `cycles` (Unreal's Grower).
    package mutating func grow(_ preset: PlantPreset = .standard, _ edit: (inout Growth.Params) -> Void = { _ in }) -> Wire<Growing> {
        var settings = preset == .twig ? Growth.Twigs.twigGrowth : Growth.Params()
        edit(&settings)
        return grow(settings: settings, preset: preset)
    }

    package mutating func grow(settings: Growth.Params, preset: PlantPreset) -> Wire<Growing> {
        guard side == nil else { return record(.grow(settings.growOnly(preset)), preset, []) }
        var p = settings
        if case .plant(let age, _, _) = mode { p = Growth.aged(p, age) }
        var plant = Growth.Plant(p, seed: growthSeed())
        for _ in 0..<p.cycles { plant.cycle() }
        return store(Growing(plant: plant))
    }

    /// The plant grows on, its grafts and spurs too (Unreal's second Grower).
    package mutating func growMore(_ input: Wire<Growing>, _ edit: (inout Growth.GrowMore) -> Void = { _ in }) -> Wire<Growing> {
        var settings = Growth.GrowMore()
        edit(&settings)
        return growMore(input, settings: settings)
    }

    package mutating func growMore(_ input: Wire<Growing>, settings: Growth.GrowMore) -> Wire<Growing> {
        guard side == nil else { return record(.growMore(settings), .standard, [input.node]) }
        var g = value(input)
        if settings.revive { g.plant.revive() }
        for _ in 0..<settings.cycles { g.plant.cycle() }
        return store(g)
    }

    /// Small shoots set on the outer branches (Unreal's Graft Distributor).
    package mutating func grafts(_ input: Wire<Growing>, _ edit: (inout Growth.Grafts) -> Void = { _ in }) -> Wire<Growing> {
        var settings = Growth.Grafts()
        edit(&settings)
        return grafts(input, settings: settings)
    }

    package mutating func grafts(_ input: Wire<Growing>, settings: Growth.Grafts) -> Wire<Growing> {
        guard side == nil else { return record(.grafts(settings), .standard, [input.node]) }
        var g = value(input)
        g.plant.graft(settings)
        return store(g)
    }

    /// Short side shoots on the last generation's nodes.
    package mutating func spurs(_ input: Wire<Growing>, _ edit: (inout Growth.Spurs) -> Void = { _ in }) -> Wire<Growing> {
        var settings = Growth.Spurs()
        edit(&settings)
        return spurs(input, settings: settings)
    }

    package mutating func spurs(_ input: Wire<Growing>, settings: Growth.Spurs) -> Wire<Growing> {
        guard side == nil else { return record(.spurs(settings), .standard, [input.node]) }
        var g = value(input)
        g.plant.spur(settings)
        return store(g)
    }

    /// The trunk's foot cut off and the plant lowered onto the cut (Unreal's Carve).
    package mutating func carve(_ input: Wire<Growing>, _ edit: (inout Growth.Carve) -> Void = { _ in }) -> Wire<Growing> {
        var settings = Growth.Carve()
        edit(&settings)
        return carve(input, settings: settings)
    }

    package mutating func carve(_ input: Wire<Growing>, settings: Growth.Carve) -> Wire<Growing> {
        guard side == nil else { return record(.carve(settings), .standard, [input.node]) }
        var g = value(input)
        g.plant.carveFoot(settings.share)
        return store(g)
    }

    /// The plant bent toward a pull or the light, once it's grown (Unreal's Gravity).
    package mutating func gravity(_ input: Wire<Growing>, _ edit: (inout Growth.Gravity) -> Void = { _ in }) -> Wire<Growing> {
        var settings = Growth.Gravity()
        edit(&settings)
        return gravity(input, settings: settings)
    }

    package mutating func gravity(_ input: Wire<Growing>, settings: Growth.Gravity) -> Wire<Growing> {
        guard side == nil else { return record(.gravity(settings), .standard, [input.node]) }
        var g = value(input)
        g.plant.bend(settings)
        return store(g)
    }

    /// One plant's points moved, turned and cut by hand (Unreal's Manual Edit): only the plant of the seed it holds.
    package mutating func manualEdit(_ input: Wire<Growing>, _ edit: (inout Growth.ManualEdit) -> Void = { _ in }) -> Wire<Growing> {
        var settings = Growth.ManualEdit()
        edit(&settings)
        return manualEdit(input, settings: settings)
    }

    package mutating func manualEdit(_ input: Wire<Growing>, settings: Growth.ManualEdit) -> Wire<Growing> {
        guard side == nil else { return record(.manualEdit(settings), .standard, [input.node]) }
        var g = value(input)
        if settings.seed != 0, seed == settings.seed { g.plant.edit(settings) }
        return store(g)
    }

    /// The branches as stems, and how they will be wood (Unreal's Mesh Builder, its settings). A plant draws its root
    /// bone's sway here.
    package mutating func skeleton(_ input: Wire<Growing>, _ preset: PlantPreset = .standard,
                                   _ edit: (inout Growth.Wood) -> Void = { _ in }) -> Wire<PlantSkeleton> {
        var settings = preset == .twig ? Growth.Twigs.twigGrowth.wood : Growth.Wood()
        edit(&settings)
        return skeleton(input, settings: settings, preset: preset)
    }

    package mutating func skeleton(_ input: Wire<Growing>, settings: Growth.Wood, preset: PlantPreset) -> Wire<PlantSkeleton> {
        guard side == nil else { return record(.skeleton(settings), preset, [input.node]) }
        let plant = value(input).plant
        let placed = plant.placed(settings)
        let (skeleton, stemOf) = plant.skeleton(settings, at: placed)
        var rootPhase: Float = 0
        if case .plant = mode { rootPhase = rng.next() }
        let made = PlantSkeleton(skeleton: skeleton, wood: settings, up: normalize(plant.p.up), axis: plant.p.axis.map(normalize),
                                 stemOf: stemOf, placed: placed, plant: plant, rootPhase: rootPhase)
        if probe { kept = made }
        return store(made)
    }

    /// Fewer bones for the wind to turn (Unreal's Bone Reduction): the Output these stems go on to hangs a stem's twigs
    /// on fewer bones. Nothing moves and nothing else is drawn differently; the wind is less exact.
    package mutating func boneReduction(_ input: Wire<PlantSkeleton>, _ edit: (inout Growth.BoneReduction) -> Void = { _ in }) -> Wire<PlantSkeleton> {
        var settings = Growth.BoneReduction()
        edit(&settings)
        return boneReduction(input, settings: settings)
    }

    package mutating func boneReduction(_ input: Wire<PlantSkeleton>, settings: Growth.BoneReduction) -> Wire<PlantSkeleton> {
        guard side == nil else { return record(.boneReduction(settings), .standard, [input.node]) }
        var made = value(input)
        made.boneReduction = settings.strength
        return store(made)
    }

    /// Leaves on a skeleton's stems, for the twig or the plant to be made with (Unreal's Foliage Distributor).
    package mutating func leaves(_ input: Wire<PlantSkeleton>, _ preset: PlantPreset = .standard,
                                 _ edit: (inout Foliage.LeafRecipe) -> Void = { _ in }) -> Wire<LeafSet> {
        var settings = preset == .twig ? Growth.Twigs().leaf : Foliage.LeafRecipe()
        edit(&settings)
        return leaves(input, settings: settings, preset: preset)
    }

    package mutating func leaves(_ input: Wire<PlantSkeleton>, settings: Foliage.LeafRecipe, preset: PlantPreset) -> Wire<LeafSet> {
        guard side == nil else { return record(.leaves(settings), preset, [input.node]) }
        return store(LeafSet(recipe: settings))
    }

    /// One twig of the palette: its wood and its leaves, as many as its place in the palette has.
    package mutating func twig(_ input: Wire<PlantSkeleton>, leaves: Wire<LeafSet>) -> Wire<Foliage.Mesh> {
        guard side == nil else { return record(.twig, .standard, [input.node, leaves.node]) }
        guard case .twig(let variant, let count, let sparse, let cards) = mode else { return noTwig() }
        guard !probe else { return noTwig() }
        let made = value(input), skeleton = made.skeleton
        var leaf = value(leaves).recipe
        leaf.perMetre *= count > 1 ? sparse + (1 - sparse) * Float(variant) / Float(count - 1) : 1
        if cards {
            return store(Foliage.cardMesh(skeleton, cards: Foliage.cards(on: skeleton, leaf, up: made.up, rng: &rng), up: made.up))
        }
        let anchors = Foliage.leaves(on: skeleton, leaf, up: made.up, rng: &rng)
        // Its health, for the shading (the palette's sparse twigs hang in the shade).
        let health = count > 1 ? Int((7 * Float(variant) / Float(count - 1)).rounded()) : 7
        var mesh = Foliage.mesh(skeleton, stems: nil, leaves: anchors, shape: leaf.shape, fold: leaf.fold, up: made.up, allLeaves: false,
                                leafTag: health, sheet: leaf.sheetName)
        // Its wood (written before its leaves) told from the tree's: its generations carried past twigWood in U.
        let firstLeafVertex = mesh.indices[mesh.leafIndex...].min().map(Int.init) ?? mesh.uvs.count
        for v in 0..<firstLeafVertex { mesh.uvs[v].x += Growth.twigWood }
        return store(mesh)
    }

    /// (A program without twigs: its palette is empty, so this is never a twig.)
    package mutating func noTwig() -> Wire<Foliage.Mesh> {
        guard side == nil else { return Wire(node: -1) }
        return store(Foliage.Mesh(positions: [], normals: [], uvs: [], indices: [], leafVertex: 0, leafIndex: 0, bounds: AABB()))
    }

    /// The species' palette of twigs, for the distributor.
    package var palette: Wire<TwigPalette> { Wire(node: paletteNode) }

    /// Where the twigs hang (Unreal's Foliage Distributor, its hormone mode).
    package mutating func distribute(_ input: Wire<PlantSkeleton>, palette: Wire<TwigPalette>,
                                     _ edit: (inout Growth.Twigs) -> Void = { _ in }) -> Wire<TwigPlacement> {
        var settings = Growth.Twigs()
        edit(&settings)
        return distribute(input, palette: palette, settings: settings)
    }

    package mutating func distribute(_ input: Wire<PlantSkeleton>, palette: Wire<TwigPalette>, settings: Growth.Twigs) -> Wire<TwigPlacement> {
        guard side == nil else { return record(.distribute(settings.placingOnly), .standard, [input.node, palette.node]) }
        guard !probe else { return store(TwigPlacement(places: [])) }
        let made = value(input)
        return store(TwigPlacement(places: made.plant.twigs(settings, at: made.placed, stemOf: made.stemOf)))
    }

    /// The plant: its wood, and its twigs or the leaves on its own stems.
    package mutating func output(_ input: Wire<PlantSkeleton>, twigs: Wire<TwigPlacement>? = nil, leaves: Wire<LeafSet>? = nil,
                                 _ edit: (inout Foliage.Assembly) -> Void = { _ in }) -> Wire<Foliage.Plant> {
        var settings = Foliage.Assembly()
        edit(&settings)
        return output(input, twigs: twigs, leaves: leaves, settings: settings)
    }

    package mutating func output(_ input: Wire<PlantSkeleton>, twigs: Wire<TwigPlacement>?, leaves: Wire<LeafSet>?,
                                 settings: Foliage.Assembly) -> Wire<Foliage.Plant> {
        guard side == nil else {
            return record(.output(settings), .standard, [input.node, twigs?.node ?? -1, leaves?.node ?? -1])
        }
        guard case .plant(let age, let palette, let bark) = mode, !probe else { return store(Foliage.Plant(species: species, age: .mature, meshes: [], parts: [], bones: [], bounds: AABB())) }
        let made = value(input), skeleton = made.skeleton, up = made.up, trunk = skeleton.stems[0]
        var bones = [Foliage.Bone(pivot: .zero, axis: made.axis ?? up, parent: -1, length: trunk.length,
                                  radius: skeleton.nodes[Int(trunk.first)].w, phase: made.rootPhase)]
        func whole(_ mesh: Foliage.Mesh) -> Foliage.Plant {
            Foliage.Plant(species: species, age: age, meshes: [mesh],
                          parts: [Foliage.Part(mesh: 0, shared: false, transform: matrix_identity_float4x4, bone: 0)],
                          bones: bones, bounds: mesh.bounds)
        }
        guard let twigs, !palette.isEmpty else {
            // No twigs: one mesh, the wood (a dead tree), or the stems with the leaves that grow on them (a fern's
            // fronds and pinnae).
            guard let leaves else {
                return store(whole(Growth.wood(skeleton, stems: nil, made.wood, up: up, seed: seed, bark: bark)))
            }
            let leaf = value(leaves).recipe
            let anchors = Foliage.leaves(on: skeleton, leaf, up: up, rng: &rng)
            return store(whole(Foliage.mesh(skeleton, stems: nil, leaves: anchors, shape: leaf.shape, fold: leaf.fold, up: up,
                                            allLeaves: settings.stemsAreLeaves, bark: bark, sheet: leaf.sheetName)))
        }

        // The scaffold: the trunk is one part, each limb (a branch of it and all that grows on it) another.
        var parts: [Foliage.Part] = []
        var meshes: [Foliage.Mesh] = []
        var bounds = AABB()
        var groups = [[Int]](repeating: [], count: 1 + skeleton.limbs)
        for (i, s) in skeleton.stems.enumerated() { groups[Int(s.limb) + 1].append(i) }
        for (g, stems) in groups.enumerated() {
            let mesh = Growth.wood(skeleton, stems: stems, made.wood, up: up, seed: seed, bark: bark)
            bounds.grow(mesh.bounds)
            if g > 0 {
                let s = skeleton.stems[stems[0]]
                let foot = skeleton.sample(s, 0)
                bones.append(Foliage.Bone(pivot: foot.position, axis: foot.tangent, parent: 0, length: s.length, radius: foot.radius,
                                          phase: rng.next()))
            }
            parts.append(Foliage.Part(mesh: meshes.count, shared: false, transform: matrix_identity_float4x4, bone: g))
            meshes.append(mesh)
        }

        // The twigs, where the distributor put them: the palette's sparser ones in the shade, its denser ones in the
        // light (the palette runs from sparse to dense). Each turns on a bone of its own, hung on its limb's, or with a
        // bone reduction on the one it shares (the draws are the same whichever): that one turns less, so that the
        // furthest twig on it moves no further than a twig does by itself.
        let places = value(twigs).places
        let keeper = Growth.keptBones(places, strength: made.boneReduction)
        var boneOf = [Int](repeating: 0, count: places.count)
        var reach = places.map(\.size)
        var next = bones.count
        for (i, k) in keeper.enumerated() {
            if k == i {
                boneOf[i] = next
                next += 1
            }
            reach[k] = max(reach[k], length(places[i].position - places[k].position) + places[i].size)
        }
        for (i, t) in places.enumerated() {
            let lit = Int(min(max(t.light, 0), 0.999) * Float(palette.count))
            let pick = min(max(lit + rng.int(3) - 1, 0), palette.count - 1)
            let transform = Foliage.graftTransform(at: t.position, along: t.direction, scale: t.size, up: up, roll: rng.range(-0.6, 0.6))
            bounds.grow(palette[pick].bounds.transformed(transform))
            let phase = rng.next()
            if keeper[i] == i {
                bones.append(Foliage.Bone(pivot: t.position, axis: t.direction, parent: skeleton.stems[t.stem].limb + 1, length: t.size,
                                          radius: max(t.radius, 0.002), phase: phase, swing: reach[i] > 0 ? t.size / reach[i] : 1))
            }
            parts.append(Foliage.Part(mesh: pick, shared: true, transform: transform, bone: boneOf[keeper[i]]))
        }
        return store(Foliage.Plant(species: species, age: age, meshes: meshes, parts: parts, bones: bones, bounds: bounds))
    }

    /// A Swift Code node: `function`, on what's on the wire.
    package mutating func code<T>(_ function: (inout PlantContext, T) -> T, _ input: Wire<T>) -> Wire<T> {
        guard side == nil else { return record(.code(PlantCode(text: "")), .standard, [input.node]) }
        return store(function(&self, value(input)))
    }

    /// The same, in a graph that isn't compiled: the function of that text, as far as one has been compiled (otherwise
    /// what's on the wire goes through it).
    mutating func code(_ hash: String, input: Int32) -> Int32 {
        guard side == nil else { return input }
        guard let entry = PlantPrograms.code(hash), input >= 0, let held = values[Int(input)] else { return input }
        let made = entry.run(&self, held)
        values.append(made)
        return Int32(values.count - 1)
    }

    /// A patch of grass blades, not grown.
    package mutating func grass(_ edit: (inout Foliage.GrassPatch) -> Void = { _ in }) -> Wire<Foliage.Plant> {
        var settings = Foliage.GrassPatch()
        edit(&settings)
        return grass(settings: settings)
    }

    package mutating func grass(settings: Foliage.GrassPatch) -> Wire<Foliage.Plant> {
        guard side == nil else { return record(.grass(settings), .standard, []) }
        var age = Foliage.Age.mature
        if case .plant(let a, _, _) = mode { age = a }
        let patch = Foliage.grassPatch(seed: seed, size: settings.size, blades: settings.blades)
        return store(Foliage.Plant(species: species, age: age, meshes: [patch],
                                   parts: [Foliage.Part(mesh: 0, shared: false, transform: matrix_identity_float4x4, bone: 0)],
                                   bones: [Foliage.Bone(pivot: .zero, axis: [0, 1, 0], parent: -1, length: 0.4, radius: 0.004, phase: 0)],
                                   bounds: patch.bounds))
    }
}

extension Growth.Params {
    /// As the grow stage holds them: without what other stages hold.
    func growOnly(_ preset: PlantPreset) -> Growth.Params {
        var p = self
        p.grafts = nil
        p.spurs = nil
        p.carve = nil
        p.wood = preset == .twig ? Growth.Twigs.twigGrowth.wood : Growth.Wood()
        return p
    }
}

extension Growth.Twigs {
    /// As the distribute stage holds them: without what other stages hold.
    var placingOnly: Growth.Twigs {
        var t = self
        let plain = Growth.Twigs()
        t.growth = plain.growth
        t.leaf = plain.leaf
        t.palette = plain.palette
        t.sparse = plain.sparse
        return t
    }
}
