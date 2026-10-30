import EngineCore
import Foundation
import simd

/// The programs there are: the built-in species' and those compiled from Assets/Plants (PlantCompiler), and what runs a
/// species.
package enum PlantPrograms {
    /// The built-in species, in their order.
    package static let builtIn: [any PlantProgram.Type] = [Oak.self, Birch.self, Conifer.self, DeadTree.self, Bush.self, Fern.self, Grass.self]

    /// A program's graph, from a trace of it: nothing is grown.
    package static func trace(_ program: any PlantProgram.Type) -> PlantGraph {
        var twig = PlantContext(tracing: .twig)
        var nodes: [PlantNode] = []
        var palette: Int32 = -1
        if let made = program.palette {
            let last = program.twig(&twig)
            let wire: Wire<TwigPalette> = twig.record(.palette(made), .standard, [last.node])
            palette = wire.node
            nodes = twig.nodes
        }
        var plant = PlantContext(tracing: .plant, after: nodes, palette: palette)
        _ = program.plant(&plant)
        return PlantGraph(nodes: plant.nodes)
    }

    /// The species a program is.
    package static func def(of program: any PlantProgram.Type) -> Foliage.SpeciesDef {
        Foliage.SpeciesDef(program.species, graph: trace(program))
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var compiled: [String: any PlantProgram.Type] = [:]
    private nonisolated(unsafe) static var codeEntries: [String: PlantCodeEntry] = [:]

    /// A program compiled from a file, for the graph of that file: what grows that graph from now on.
    package static func register(_ program: any PlantProgram.Type, for graph: PlantGraph) {
        lock.lock()
        compiled[graph.key] = program
        for entry in program.code { codeEntries[entry.hash] = entry }
        lock.unlock()
    }

    package static func compiled(_ graph: PlantGraph) -> (any PlantProgram.Type)? {
        let key = graph.key
        lock.lock()
        defer { lock.unlock() }
        return compiled[key]
    }

    /// A Swift Code node's function, by its text's hash, if it has been compiled.
    static func code(_ hash: String) -> PlantCodeEntry? {
        lock.lock()
        defer { lock.unlock() }
        return codeEntries[hash]
    }

    /// What runs `def`: the program its graph's file was compiled to; its graph, stage by stage; the built-in program, if
    /// its recipe is that one's; or else its recipe, as a graph (and so a graph that can't run yet, wires missing).
    package static func runner(for def: Foliage.SpeciesDef) -> PlantRunner {
        if let graph = def.graph {
            if let program = compiled(graph) { return PlantRunner(.program(program)) }
            if graph.problem == nil { return PlantRunner(.graph(graph)) }
        } else if let i = builtIn.firstIndex(where: { $0.species.id == def.id }), def.sameRecipe(as: PlantCatalog.builtIn.species[i]) {
            return PlantRunner(.program(builtIn[i]))
        }
        return PlantRunner(.graph(PlantGraph.standard(def)))
    }

    /// What runs `def` as far as its graph's node `stage`, for a library of seed `seed` to show (the plant's end, a node
    /// with nothing to look at, or no such node: what runs it all).
    package static func runner(for def: Foliage.SpeciesDef, stage: Int, seed: UInt64) -> PlantRunner {
        let graph = def.grownGraph, id = Int32(truncatingIfNeeded: stage)
        guard stage >= 0, id != graph.end(of: .plant), graph.stageProblem(id) == nil, let made = PlantStage(graph, id, def: def, seed: seed) else {
            return runner(for: def)
        }
        return PlantRunner(.stage(made))
    }

    /// The checked-in file of a built-in species, read as a graph, where the sources are at hand: the graph with its
    /// comments, the same as the recipe's.
    package static func sourceGraph(_ def: Foliage.SpeciesDef) -> PlantGraph? {
        guard def.graph == nil, let i = builtIn.firstIndex(where: { $0.species.id == def.id }), def.sameRecipe(as: PlantCatalog.builtIn.species[i]) else { return nil }
        let name = String(describing: builtIn[i])
        let file = SourceTree.packageRoot.appendingPathComponent("Sources/Plants/Programs/\(name).swift")
        guard let text = try? String(contentsOf: file, encoding: .utf8), let read = PlantSwift.parse(text)?.graph,
              read.canonical == PlantGraph.standard(def).canonical else { return nil }
        return read
    }
}

/// One species' program or graph, run for each of its twigs and plants.
package struct PlantRunner {
    package enum Body {
        case program(any PlantProgram.Type)
        case graph(PlantGraph)
        case stage(PlantStage)
    }

    package let body: Body

    package init(_ body: Body) { self.body = body }

    private func twig(_ p: inout PlantContext) -> Wire<Foliage.Mesh> {
        switch body {
        case .program(let program): return program.twig(&p)
        case .graph(let graph): return graph.twig(&p)
        case .stage(let stage): return stage.graph.partialTwig(&p)
        }
    }

    private func plant(_ p: inout PlantContext) -> Wire<Foliage.Plant> {
        switch body {
        case .program(let program): return program.plant(&p)
        case .graph(let graph): return graph.plant(&p)
        case .stage(let stage): return stage.plant(&p)
        }
    }

    package func twig(_ species: Foliage.Species, variant: Int, of count: Int, sparse: Float?, seed: UInt64, cards: Bool = false) -> Foliage.Mesh {
        var p = PlantContext(.twig(variant: variant, of: count, sparse: sparse ?? 0.55, cards: cards), species: species, seed: seed)
        let made = twig(&p)
        return p.value(made)
    }

    package func plant(_ species: Foliage.Species, age: Foliage.Age, seed: UInt64, palette: [Foliage.Mesh], bark: Foliage.Bark? = nil) -> Foliage.Plant {
        if case .stage(let stage) = body, stage.onTwig { return stage.twigAsPlant(species, age: age) }
        var p = PlantContext(.plant(age: age, palette: palette, bark: bark), species: species, seed: seed)
        let made = plant(&p)
        return p.value(made)
    }

    /// A plant's skeleton, the same as `plant`'s: nothing is meshed.
    package func skeleton(_ species: Foliage.Species, age: Foliage.Age, seed: UInt64) -> PlantSkeleton? {
        if case .stage(let stage) = body, stage.onTwig { return stage.twigSkeleton(species) }
        var p = PlantContext(.plant(age: age, palette: [], bark: nil), species: species, seed: seed, probe: true)
        _ = plant(&p)
        return p.kept
    }

    /// A twig's skeleton, the same as `twig`'s.
    package func twigSkeleton(_ species: Foliage.Species, seed: UInt64) -> PlantSkeleton? {
        var p = PlantContext(.twig(variant: 0, of: 1, sparse: 1, cards: false), species: species, seed: seed, probe: true)
        _ = twig(&p)
        return p.kept
    }

    /// Whether what it makes is a twig, standing alone: too small for the workshop's person to stand beside.
    package var showsTwig: Bool {
        if case .stage(let stage) = body { return stage.onTwig }
        return false
    }

    /// Whether what it makes is only stems so far: a plant still growing, which has no wood yet.
    package var showsStems: Bool {
        if case .stage(let stage) = body { return stage.isGrowing }
        return false
    }
}
