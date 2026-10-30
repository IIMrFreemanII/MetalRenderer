import XCTest
import QuartzCore
import simd
@testable import Plants

/// PlantStage.swift: a graph run as far as one of its nodes shows the plant on the way to what it becomes, and a node
/// with nothing to look at says so.
final class PlantStageTests: XCTestCase {
    private let oak = PlantCatalog.builtIn[.oak]

    private func node(_ g: PlantGraph, _ kind: PlantNodeKind, _ side: PlantSide = .plant) throws -> PlantNode {
        try XCTUnwrap(g.first(kind, side))
    }

    /// Up to where it stops it is the plant: the same seeds and draws.
    func testAStageIsThePlantSoFar() throws {
        let g = oak.grownGraph, wood = try node(g, .skeleton), seed = Foliage.seed(1, oak.seedIndex, Foliage.Age.mature.rawValue, 0)
        let whole = try XCTUnwrap(PlantPrograms.runner(for: oak).skeleton(.oak, age: .mature, seed: seed))
        let staged = try XCTUnwrap(PlantPrograms.runner(for: oak, stage: Int(wood.id), seed: 1).skeleton(.oak, age: .mature, seed: seed))
        XCTAssertEqual(whole.skeleton.nodes, staged.skeleton.nodes)
    }

    /// A plant still growing is its stems; its later stages have more on them, the wood none of the twigs.
    func testTheStagesOfThePlant() throws {
        let g = oak.grownGraph, seed = UInt64(5)
        func runner(_ n: PlantNode) -> PlantRunner { PlantPrograms.runner(for: oak, stage: Int(n.id), seed: 1) }
        let palette = Foliage.library(seed: 1, species: [.oak])[0].palette
        let grow = try node(g, .grow), wood = try node(g, .skeleton), hung = try node(g, .distribute)
        XCTAssertTrue(runner(grow).showsStems)
        XCTAssertFalse(runner(wood).showsStems)
        let grown = runner(grow).plant(.oak, age: .mature, seed: seed, palette: palette)
        XCTAssertEqual(grown.parts.count, 1)
        XCTAssertFalse(grown.bounds.isEmpty)
        XCTAssertNotNil(runner(grow).skeleton(.oak, age: .mature, seed: seed))
        let bare = runner(wood).plant(.oak, age: .mature, seed: seed, palette: palette)
        XCTAssertEqual(bare.parts.filter(\.shared).count, 0)
        XCTAssertEqual(bare.meshes[0].leafIndex, bare.meshes[0].indices.count, "wood alone")
        let placed = runner(hung).plant(.oak, age: .mature, seed: seed, palette: palette)
        XCTAssertGreaterThan(placed.parts.filter(\.shared).count, 50)
        // The Output is the plant itself, its program.
        guard case .program = PlantPrograms.runner(for: oak, stage: Int(try node(g, .output).id), seed: 1).body else { return XCTFail("not the program") }
    }

    /// A stage on the twig's side stands alone, the palette's fullest twig so far.
    func testTheStagesOfATwig() throws {
        let g = oak.grownGraph
        let last = try XCTUnwrap(Foliage.library(seed: 1, species: [.oak])[0].palette.last)
        func plant(_ n: PlantNode) -> Foliage.Plant { PlantPrograms.runner(for: oak, stage: Int(n.id), seed: 1).plant(.oak, age: .young, seed: 99, palette: []) }
        let twig = plant(try node(g, .twig, .twig))
        XCTAssertEqual(twig.age, .young, "where the library looks for it")
        XCTAssertEqual(twig.meshes[0].positions, last.positions)
        XCTAssertEqual(twig.meshes[0].indices, last.indices)
        XCTAssertEqual(twig.meshes[0].uvs, last.uvs)
        let wood = plant(try node(g, .skeleton, .twig))
        XCTAssertEqual(wood.meshes[0].leafIndex, wood.meshes[0].indices.count, "no leaves yet")
        XCTAssertGreaterThan(wood.meshes[0].indices.count, 0)
        XCTAssertEqual(wood.meshes[0].positions, Array(last.positions.prefix(wood.meshes[0].positions.count)), "the same wood")
        XCTAssertEqual(plant(try node(g, .leaves, .twig)).meshes[0].positions, last.positions)
        let stems = PlantPrograms.runner(for: oak, stage: Int(try node(g, .grow, .twig).id), seed: 1)
        XCTAssertTrue(stems.showsStems)
        XCTAssertNotNil(stems.skeleton(.oak, age: .mature, seed: 99))
    }

    /// Every node of every built-in species either shows something or says why, and draws small the same way.
    func testEveryNodeShowsOrSays() {
        for (i, def) in PlantCatalog.builtIn.species.enumerated() {
            let s = Foliage.Species(rawValue: i), g = def.grownGraph
            let palette = Foliage.library(seed: 1, species: [s])[0].palette
            let sketches = PlantPrograms.sketches(def, species: s, age: .mature, variant: 0, seed: 1)
            for n in g.nodes {
                let name = "\(def.id) \(n.name)"
                if let why = g.stageProblem(n.id) {
                    XCTAssertEqual(n.kind, .palette, "\(name): \(why)")
                    XCTAssertNil(sketches[n.id], name)
                    continue
                }
                let plant = PlantPrograms.runner(for: def, stage: Int(n.id), seed: 1).plant(s, age: .mature, seed: 3, palette: palette)
                XCTAssertFalse(plant.bounds.isEmpty, name)
                XCTAssertNotNil(sketches[n.id]?.bounds, name)
            }
        }
    }

    /// What's drawn on a node grows as the plant does.
    func testSketches() throws {
        let g = oak.grownGraph
        let s = PlantPrograms.sketches(oak, species: .oak, age: .mature, variant: 0, seed: 1)
        let grow = try XCTUnwrap(s[try node(g, .grow).id]), grafts = try XCTUnwrap(s[try node(g, .grafts).id])
        XCTAssertGreaterThan(grow.lines.count, 100)
        XCTAssertGreaterThan(grafts.lines.count, grow.lines.count)
        XCTAssertTrue(grow.dots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(s[try node(g, .distribute).id]).dots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(s[try node(g, .output).id]).dots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(s[try node(g, .twig, .twig).id]).dots.isEmpty)
        // The grass has no stems.
        let grass = PlantCatalog.builtIn[.grass], patch = grass.grownGraph.nodes[0]
        let blades = PlantPrograms.sketches(grass, species: .grass, age: .mature, variant: 0, seed: 1)[patch.id]
        XCTAssertFalse(try XCTUnwrap(blades).dots.isEmpty)
    }

    /// What's off the node's way doesn't matter; what's on it, or what has no shape, it says.
    func testAGraphBeforeItsWhole() throws {
        var g = oak.grownGraph
        let grow = try node(g, .grow), wood = try node(g, .skeleton), output = try node(g, .output), palette = try node(g, .palette, .twig)
        // An Output with nothing wired in, and a stage hanging off nothing.
        g.nodes[g.nodes.firstIndex { $0.id == output.id }!].inputs = [-1, -1, -1]
        let stray = PlantNode(id: g.nextID, name: "stray", side: .plant, preset: .standard, settings: .carve(Growth.Carve()), inputs: [-1])
        g.nodes.insert(stray, at: 0)
        XCTAssertNotNil(g.problem)
        var def = oak
        def.graph = g
        XCTAssertNil(g.stageProblem(grow.id))
        XCTAssertNil(g.stageProblem(wood.id))
        XCTAssertTrue(try XCTUnwrap(g.stageProblem(output.id)).contains("nothing is wired"))
        XCTAssertTrue(try XCTUnwrap(g.stageProblem(stray.id)).contains("nothing is wired"))
        XCTAssertTrue(try XCTUnwrap(g.stageProblem(palette.id)).contains("list of twigs"))
        XCTAssertNotNil(g.stageProblem(9999))
        let bare = PlantPrograms.runner(for: def, stage: Int(wood.id), seed: 1).plant(.oak, age: .mature, seed: 3, palette: [])
        XCTAssertFalse(bare.bounds.isEmpty)
        let drawn = PlantPrograms.sketches(def, species: .oak, age: .mature, variant: 0, seed: 1)
        XCTAssertNotNil(drawn[wood.id])
        XCTAssertNil(drawn[output.id])
        XCTAssertNil(drawn[stray.id])
    }

    /// A Swift Code node is what's on its wire, which may be something without a shape; a statement never runs here.
    func testCodeAndStatements() throws {
        var g = oak.grownGraph
        let wood = try node(g, .skeleton), leaves = try node(g, .leaves, .twig), id = g.nextID
        let onWood = PlantNode(id: id, name: "code", side: .plant, preset: .standard, settings: .code(PlantCode(on: .skeleton)), inputs: [wood.id])
        let onLeaves = PlantNode(id: id + 1, name: "odd", side: .twig, preset: .standard, settings: .code(PlantCode(on: .leaves)), inputs: [leaves.id])
        let statement = PlantNode(id: id + 2, name: "made", side: .plant, preset: .standard, settings: .statement("let made = 1"), inputs: [])
        let onStatement = PlantNode(id: id + 3, name: "after", side: .plant, preset: .standard, settings: .code(PlantCode(on: .any)), inputs: [id + 2])
        g.nodes += [onWood, onLeaves, statement, onStatement]
        XCTAssertNil(g.stageProblem(onWood.id))
        XCTAssertTrue(try XCTUnwrap(g.stageProblem(onLeaves.id)).contains("LeafSet"))
        XCTAssertTrue(try XCTUnwrap(g.stageProblem(statement.id)).contains("compiled"))
        XCTAssertTrue(try XCTUnwrap(g.stageProblem(onStatement.id)).contains("compiled"))
        var def = oak
        def.graph = g
        let shown = PlantPrograms.runner(for: def, stage: Int(onWood.id), seed: 1)
        XCTAssertFalse(shown.showsStems)
        XCTAssertFalse(shown.plant(.oak, age: .mature, seed: 3, palette: []).bounds.isEmpty, "not compiled: what's on its wire")
        let drawn = PlantPrograms.sketches(def, species: .oak, age: .mature, variant: 0, seed: 1)
        XCTAssertNotNil(drawn[onWood.id])
        XCTAssertNil(drawn[onLeaves.id])
        XCTAssertNil(drawn[statement.id])
    }

    /// A count that can't be (a file written by hand) grows nothing rather than taking the app down from the thumbnails'
    /// queue.
    func testNoCyclesAtAll() throws {
        var g = oak.grownGraph
        let i = try XCTUnwrap(g.nodes.firstIndex { $0.kind == .grow && $0.side == .plant })
        guard case .grow(var p) = g.nodes[i].settings else { return XCTFail("not a Grower") }
        p.cycles = -3
        g.nodes[i].settings = .grow(p)
        var def = oak
        def.graph = g
        XCTAssertNotNil(PlantPrograms.sketches(def, species: .oak, age: .mature, variant: 0, seed: 1)[g.nodes[i].id])
    }

    /// One run of the graph for all its nodes: about as long as growing the plant. (What a drag's thumbnails cost, off the
    /// main thread.)
    func testSketchingIsQuick() {
        var best = Double.infinity
        for _ in 0..<5 {
            let start = CACurrentMediaTime()
            _ = PlantPrograms.sketches(oak, species: .oak, age: .mature, variant: 0, seed: 1)
            best = min(best, CACurrentMediaTime() - start)
        }
        print("sketches of the oak's graph: \(best * 1000) ms")
        XCTAssertLessThan(best, 0.25)
    }
}
