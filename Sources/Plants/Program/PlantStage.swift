import EngineCore
import Foundation
import simd

/// A graph run as far as one of its nodes, to look at what that stage has made as a plant (the node editor's previews,
/// Unreal's vegetation editor has them): a plant still growing is its stems, a Mesh Builder its wood, Leaves those on
/// their stems, a distributor the wood with its twigs hung, and on a twig's side the palette's fullest twig so far. The
/// same seeds and draws as the plant it is on the way to, up to there.
package struct PlantStage {
    let graph: PlantGraph
    let node: PlantNode
    private let twigSeed: UInt64
    private let twigCount: Int

    /// `seed`: the library's.
    init?(_ graph: PlantGraph, _ id: Int32, def: Foliage.SpeciesDef, seed: UInt64) {
        guard let node = graph.node(id) else { return nil }
        self.graph = graph
        self.node = node
        twigCount = max(def.paletteSize, 1)
        twigSeed = Foliage.seed(seed, def.seedIndex, -1, twigCount - 1)
    }

    var onTwig: Bool { node.side == .twig }
    var isGrowing: Bool { graph.output(of: node.id) == .growing }

    private var twigMode: PlantContext.Mode { .twig(variant: twigCount - 1, of: twigCount, sparse: 1, cards: false) }

    /// The plant's side, in a context made to run it.
    func plant(_ p: inout PlantContext) -> Wire<Foliage.Plant> {
        let wire = graph.stages(.plant, &p, partial: true, until: node.id).wire
        func w<T>(_ id: Int32) -> Wire<T> { Wire(node: wire[id] ?? -1) }
        func stems(_ wood: Wire<PlantSkeleton>, twigs: Wire<TwigPlacement>? = nil, leaves: Wire<LeafSet>? = nil, _ settings: Foliage.Assembly = Foliage.Assembly()) -> Wire<Foliage.Plant> {
            p.output(wood, twigs: twigs, leaves: leaves, settings: settings)
        }
        guard wire[node.id] != nil else { return p.noPlant() }
        switch graph.output(of: node.id) {
        case .growing:
            let wood = p.skeleton(w(node.id), settings: graph.woodBelow(node), preset: node.preset)
            return stems(wood)
        case .skeleton: return stems(w(node.id))
        case .leaves:
            var settings = Foliage.Assembly()
            if case .output(let a)? = graph.first(.output, .plant)?.settings { settings = a }
            return stems(w(node.inputs[0]), leaves: w(node.id), settings)
        case .twigs: return stems(w(node.inputs[0]), twigs: w(node.id))
        default: return w(node.id)
        }
    }

    /// The twig's side as far as the node, the mesh it has come to.
    private func twig(_ p: inout PlantContext) -> Wire<Foliage.Mesh> {
        let wire = graph.stages(.twig, &p, partial: true, until: node.id).wire
        func w<T>(_ id: Int32) -> Wire<T> { Wire(node: wire[id] ?? -1) }
        guard wire[node.id] != nil else { return p.noTwig() }
        switch graph.output(of: node.id) {
        case .growing:
            let wood = p.skeleton(w(node.id), settings: graph.woodBelow(node), preset: node.preset)
            return p.twigStems(wood)
        case .skeleton: return p.twigStems(w(node.id))
        case .leaves: return p.twig(w(node.inputs[0]), leaves: w(node.id))
        case .twigMesh: return w(node.id)
        default: return p.noTwig()
        }
    }

    /// A stage on the twig's side as one plant of a library: that mesh standing alone.
    func twigAsPlant(_ species: Foliage.Species, age: Foliage.Age) -> Foliage.Plant {
        var p = PlantContext(twigMode, species: species, seed: twigSeed)
        let made = twig(&p)
        let mesh = p.value(made)
        return Foliage.Plant(species: species, age: age, meshes: [mesh],
                             parts: [Foliage.Part(mesh: 0, shared: false, transform: matrix_identity_float4x4, bone: 0)],
                             bones: [Foliage.Bone(pivot: .zero, axis: [0, 1, 0], parent: -1, length: 1, radius: 0.01, phase: 0)], bounds: mesh.bounds)
    }

    func twigSkeleton(_ species: Foliage.Species) -> PlantSkeleton? {
        var p = PlantContext(twigMode, species: species, seed: twigSeed, probe: true)
        _ = twig(&p)
        return p.kept
    }
}

extension PlantGraph {
    /// Why a node has nothing to look at, if it hasn't: something it needs isn't wired or can't run yet, or what it makes
    /// has no shape. (The nodes that don't lead to it don't matter.)
    package func stageProblem(_ id: Int32) -> String? {
        guard let n = node(id) else { return "There's no such node" }
        if n.kind == .palette { return "A palette is only a list of twigs: its Twig shows one" }
        if n.kind == .code, case let wire = output(of: id), wire != .any, ![.growing, .skeleton, .twigMesh, .plant].contains(wire) {
            return "What it hands on, a \(wire.swiftType), has no shape to show"
        }
        var stack = [id], seen = Set<Int32>()
        while let at = stack.popLast() {
            guard seen.insert(at).inserted, let n = node(at) else { continue }
            if n.isStatement { return "\(n.name.isEmpty ? "A statement" : n.name) runs only when its file is compiled" }
            if let why = pinProblem(n) { return why }
            if n.kind != .distribute, n.inputs.contains(where: { node($0).map { $0.side != n.side } ?? false }) {
                return "\(n.kind.title) \(n.name) is wired across the twig and the plant"
            }
            stack += n.inputs.filter { $0 >= 0 }
        }
        return nil
    }

    /// The wood that a plant still growing at `n` is going to be: the first Mesh Builder after it (or a new one's).
    func woodBelow(_ n: PlantNode) -> Growth.Wood {
        var stack = [n.id], seen = Set<Int32>()
        while let at = stack.popLast() {
            guard seen.insert(at).inserted else { continue }
            for below in nodes where below.inputs.contains(at) {
                if case .skeleton(let wood) = below.settings { return wood }
                stack.append(below.id)
            }
        }
        return n.preset == .twig ? Growth.Twigs.twigGrowth.wood : Growth.Wood()
    }

    /// The twig's side, whatever else isn't wired yet: the palette's twig, or nothing where it can't run.
    func partialTwig(_ p: inout PlantContext) -> Wire<Foliage.Mesh> {
        let wire = stages(.twig, &p, partial: true).wire
        if let end = end(of: .twig), output(of: end) == .twigMesh, let made = wire[end] { return Wire(node: made) }
        return p.noTwig()
    }
}

/// A stage drawn small, side on, for its node: lines for its stems, a level to each, and dots for what hangs on them
/// (leaves, the twigs' places, grass blades).
package struct PlantSketch: Equatable {
    package struct Line: Equatable {
        package var level: Int
        package var points: [SIMD2<Float>]
    }

    package var lines: [Line] = []
    package var dots: [SIMD2<Float>] = []

    package init() {}

    /// Its stems.
    init(_ skeleton: Foliage.Skeleton) {
        lines = skeleton.stems.map { s in
            Line(level: Int(s.level), points: (0..<Int(s.count)).map { i in
                let n = skeleton.nodes[Int(s.first) + i]
                return SIMD2(n.x, n.y)
            })
        }
    }

    /// With a few hundred of these at most: a small picture needs no more.
    mutating func add(dots points: [SIMD3<Float>], most: Int = 600) {
        let step = max(points.count / most, 1)
        for i in stride(from: 0, to: points.count, by: step) { dots.append(SIMD2(points[i].x, points[i].y)) }
    }

    /// Its box.
    package var bounds: (lo: SIMD2<Float>, hi: SIMD2<Float>)? {
        var lo = SIMD2<Float>(repeating: .infinity), hi = -lo
        for line in lines { for p in line.points { lo = simd_min(lo, p); hi = simd_max(hi, p) } }
        for p in dots { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return lo.x <= hi.x ? (lo, hi) : nil
    }
}

extension PlantPrograms {
    /// Every node of `def`'s graph that has a shape, drawn as the workshop's plant of that seed, age and variant stands
    /// at it. One run of the graph; nothing is meshed.
    package static func sketches(_ def: Foliage.SpeciesDef, species: Foliage.Species, age: Foliage.Age, variant: Int, seed: UInt64) -> [Int32: PlantSketch] {
        let graph = def.grownGraph
        let age = def.variants(age) > 0 ? age : .mature
        let plantSeed = Foliage.seed(seed, def.seedIndex, age.rawValue, min(max(variant, 0), max(def.variants(age) - 1, 0)))
        var out: [Int32: PlantSketch] = [:]
        func draw(_ node: PlantNode, _ wire: [Int32: Int32], _ p: inout PlantContext) {
            func stems(_ id: Int32) -> PlantSkeleton? { wire[id].map { p.value(Wire<PlantSkeleton>(node: $0)) } }
            func leaves(on made: PlantSkeleton?, _ id: Int32) -> PlantSketch? {
                guard let made, let at = wire[id] else { return nil }
                var drawn = PlantSketch(made.skeleton), rng = SplitMix64(seed: plantSeed)
                drawn.add(dots: Foliage.leaves(on: made.skeleton, p.value(Wire<LeafSet>(node: at)).recipe, up: made.up, rng: &rng).map { $0.position + $0.direction * $0.length * 0.7 })
                return drawn
            }
            switch (node.settings, graph.output(of: node.id)) {
            case (_, .growing):
                guard let at = wire[node.id] else { return }
                let plant = p.value(Wire<Growing>(node: at)).plant, wood = graph.woodBelow(node)
                out[node.id] = PlantSketch(plant.skeleton(wood, at: plant.placed(wood)).0)
            case (_, .skeleton):
                out[node.id] = stems(node.id).map { PlantSketch($0.skeleton) }
            case (.leaves, _):
                out[node.id] = leaves(on: stems(node.inputs[0]), node.id)
            case (.twig, _):
                out[node.id] = leaves(on: stems(node.inputs[0]), node.inputs[1])
            case (.distribute(let settings), _):
                guard let made = stems(node.inputs[0]) else { return }
                var drawn = PlantSketch(made.skeleton)
                drawn.add(dots: made.plant.twigs(settings, at: made.placed, stemOf: made.stemOf).map { $0.position + $0.direction * $0.size * 0.5 })
                out[node.id] = drawn
            case (.output, _):
                guard var drawn = out[node.inputs[0]] else { return }
                for hung in node.inputs.dropFirst() { drawn.dots += out[hung]?.dots ?? [] }
                out[node.id] = drawn
            case (.grass, _):
                var drawn = PlantSketch()
                if let at = wire[node.id], let mesh = p.value(Wire<Foliage.Plant>(node: at)).meshes.first { drawn.add(dots: mesh.positions) }
                out[node.id] = drawn
            case (.code, let kind) where kind == .twigMesh || kind == .plant:
                out[node.id] = out[node.inputs[0]]     // (nothing is meshed here: as it came in)
            default: break
            }
        }
        var twig = PlantContext(.twig(variant: max(def.paletteSize, 1) - 1, of: max(def.paletteSize, 1), sparse: 1, cards: false), species: species,
                                seed: Foliage.seed(seed, def.seedIndex, -1, max(def.paletteSize, 1) - 1), probe: true)
        _ = graph.stages(.twig, &twig, partial: true, each: draw)
        var plant = PlantContext(.plant(age: age, palette: [], bark: nil), species: species, seed: plantSeed, probe: true)
        _ = graph.stages(.plant, &plant, partial: true, each: draw)
        return out
    }
}
