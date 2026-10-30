import XCTest
import simd
@testable import EngineCore
@testable import Plants

/// PlantSwift: a species as a Swift file and back, the file compiled is the graph run, byte for byte.
final class PlantSwiftTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let files = ["Oak", "Birch", "Conifer", "DeadTree", "Bush", "Fern", "Grass"]

    private func source(_ name: String) throws -> String {
        try String(contentsOf: PlantSwiftTests.root.appendingPathComponent("Sources/Plants/Programs/\(name).swift"), encoding: .utf8)
    }

    /// The built-in files are the emitter's own: read and written, they come back byte for byte; read, they are their
    /// programs' traces.
    func testTheBuiltInFilesRoundTrip() throws {
        for (i, name) in PlantSwiftTests.files.enumerated() {
            let text = try source(name)
            let def = try XCTUnwrap(PlantSwift.parse(text), name)
            XCTAssertEqual(PlantSwift.emit(def).text, text, name)
            XCTAssertEqual(def.graph?.canonical, PlantPrograms.trace(PlantPrograms.builtIn[i]).canonical, name)
            var plain = def
            plain.graph = nil
            XCTAssertEqual(plain, PlantCatalog.builtIn.species[i], name)
        }
    }

    /// A species no file has written comes back as itself, its numbers exact; moved nodes stay where they were put.
    func testAnEditedSpeciesRoundTrips() throws {
        var def = PlantCatalog.builtIn[.oak]
        def.growth?.cycles = 33
        def.growth?.trunk.axilAngle = 0.123456789
        def.growth?.branch = nil
        def.growth?.grafts = nil
        def.twigs?.leaf.size = .points([[0, 1], [0.25, 0.7], [1, 0.1]])
        def.look.leaves.append([1.0 / 3, 0.1, 1e-7])
        def.habitat.cover = Foliage.Habitat.Cover(size: 0.25...1.5, grid: 3)
        var graph = PlantGraph.standard(def)
        graph.nodes[0].at = [120.5, -40]
        def.setGraph(graph)
        let text = PlantSwift.emit(def).text
        let back = try XCTUnwrap(PlantSwift.parse(text))
        XCTAssertEqual(back.growth, def.growth)
        XCTAssertEqual(back.twigs, def.twigs)
        XCTAssertEqual(back.look, def.look)
        XCTAssertEqual(back.habitat, def.habitat)
        XCTAssertEqual(back.graph?.canonical, graph.canonical)
        XCTAssertEqual(back.graph?.nodes[0].at, [120.5, -40])
        XCTAssertEqual(PlantSwift.emit(back).text, text)
    }

    /// Every Float's literal is that Float, read as the compiler does and as the parser does.
    func testFloatLiteralsAreExact() {
        var rng = SplitMix64(seed: 11)
        for _ in 0..<200_000 {
            let x = Float(bitPattern: UInt32(truncatingIfNeeded: rng.nextUInt64()))
            guard x.isFinite else { continue }
            let text = PlantLiteral.float(x)
            XCTAssertEqual(Float(Double(text)!), x, text)
            XCTAssertEqual(Float(text), x, text)
        }
    }

    /// Hand-written Swift: other layouts of the same stages are the same graph; what isn't a stage is a statement, kept
    /// as written, wired from what it mentions; other members stay.
    func testHandEditedFiles() throws {
        let tidy = """
        import Plants
        enum Mine: PlantProgram {
            static let species = Foliage.SpeciesInfo(id: "mine") { $0.name = "Mine" }
            static func helper() -> Float { 1 } // not the program's
            static func plant(_ p: inout PlantContext) -> Wire<Foliage.Plant> {
                let grow = p.grow { $0.cycles = 12; $0.targetHeight = 3 }
                let wood = p.skeleton(grow)
                return p.output(wood)
            }
        }
        """
        let def = try XCTUnwrap(PlantSwift.parse(tidy))
        XCTAssertEqual(def.id, "mine")
        XCTAssertEqual(def.name, "Mine")
        XCTAssertEqual(def.growth?.cycles, 12)
        XCTAssertEqual(def.growth?.targetHeight, 3)
        XCTAssertEqual(def.graph?.problem, nil)
        XCTAssertEqual(def.graph?.nodes.map(\.kind), [.grow, .skeleton, .output])
        XCTAssertTrue(PlantSwift.emit(def).text.contains("static func helper() -> Float { 1 }"))

        let odd = """
        package enum Odd: PlantProgram {
            package static let species = Foliage.SpeciesInfo(id: "odd")
            package static func plant(_ p: inout PlantContext) -> Wire<Foliage.Plant> {
                let grow = p.grow {
                    /* a nested /* comment */ here */
                    $0.cycles = 6 + 6 // not a literal
                }
                let name = "a \\(1 + 2) string with } in it"
                print(name)
                let wood = p.skeleton(grow)
                return p.output(wood)
            }
        }
        """
        let read = try XCTUnwrap(PlantSwift.parse(odd))
        let graph = try XCTUnwrap(read.graph)
        XCTAssertEqual(graph.nodes.map(\.kind), [.statement, .statement, .statement, .skeleton, .output])
        XCTAssertNotNil(graph.problem, "a statement runs only compiled")
        let written = PlantSwift.emit(read).text
        XCTAssertTrue(written.contains("$0.cycles = 6 + 6 // not a literal"), written)
        XCTAssertTrue(written.contains(#"let name = "a \(1 + 2) string with } in it""#), written)
        XCTAssertEqual(PlantSwift.parse(written)?.graph?.canonical, graph.canonical)
        XCTAssertNil(PlantSwift.parse("struct NotAPlant {}"))
    }

    private func meshes(_ runner: PlantRunner, _ s: Foliage.Species, count: Int, sparse: Float?) -> ([Float], [Float4x4Bits]) {
        let palette = (0..<count).map { runner.twig(s, variant: $0, of: count, sparse: sparse, seed: UInt64($0) &+ 3) }
        let plant = runner.plant(s, age: .young, seed: 21, palette: palette)
        var floats: [Float] = []
        for mesh in palette + plant.meshes { floats += mesh.positions.flatMap { [$0.x, $0.y, $0.z] } + mesh.uvs.flatMap { [$0.x, $0.y] } }
        return (floats, plant.parts.map { Float4x4Bits($0.transform) })
    }

    private struct Float4x4Bits: Equatable {
        let bits: [UInt32]
        init(_ m: float4x4) { bits = [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w].map(\.bitPattern) } }
    }

    /// What the editor runs while a slider is dragged and what it compiles when it's let go are one plant, a graph with
    /// a Grow More and a Swift Code node too.
    func testTheFileCompiledIsTheGraphRun() throws {
        if let why = PlantCompiler.shared.problem() { throw XCTSkip(why) }
        var def = PlantCatalog.builtIn[.birch]
        var graph = PlantGraph.standard(def)
        // Grafts, then more growth, then a function on the skeleton.
        let more = graph.nextID
        let grow = try XCTUnwrap(graph.first(.grow, .plant)), wood = try XCTUnwrap(graph.first(.skeleton, .plant))
        graph.nodes.insert(PlantNode(id: more, name: "more", side: .plant, preset: .standard, settings: .growMore(Growth.GrowMore()), inputs: [grow.id]),
                           at: graph.nodes.firstIndex { $0.id == wood.id }!)
        graph.nodes[graph.nodes.firstIndex { $0.id == wood.id }!].inputs = [more]
        let bend = graph.nextID
        let code = PlantCode(text: """
        static func bend(_ p: inout PlantContext, _ input: PlantSkeleton) -> PlantSkeleton {
            var out = input
            out.moveStems { $0.x += 0.25 }
            return out
        }
        """)
        graph.nodes.insert(PlantNode(id: bend, name: "bend", side: .plant, preset: .standard, settings: .code(code), inputs: [wood.id]),
                           at: graph.nodes.firstIndex { $0.id == wood.id }! + 1)
        for i in graph.nodes.indices where graph.nodes[i].id != bend {
            graph.nodes[i].inputs = graph.nodes[i].inputs.map { $0 == wood.id && graph.nodes[i].side == .plant ? bend : $0 }
        }
        def.setGraph(graph)
        XCTAssertNil(def.graph?.problem)

        let text = PlantSwift.emit(def).text
        let reread = try XCTUnwrap(PlantSwift.parse(text))
        XCTAssertEqual(reread.graph?.canonical, def.graph?.canonical)
        let compiled = try PlantCompiler.shared.program(of: def).get()
        // (Now the node's function is compiled, the graph runs it too.)
        guard case .program = PlantPrograms.runner(for: def).body else { return XCTFail("compiled, its file is what runs") }
        let graphRun = meshes(PlantRunner(.graph(def.grownGraph)), .birch, count: def.paletteSize, sparse: def.twigs?.sparse)
        let compiledRun = meshes(PlantRunner(.program(compiled.program)), .birch, count: def.paletteSize, sparse: def.twigs?.sparse)
        XCTAssertEqual(graphRun.0, compiledRun.0)
        XCTAssertEqual(graphRun.1, compiledRun.1)
        // The code ran: the stems moved.
        let plain = meshes(PlantRunner(.program(Birch.self)), .birch, count: def.paletteSize, sparse: def.twigs?.sparse)
        XCTAssertNotEqual(plain.0, graphRun.0)
    }

    /// Moving a node doesn't regrow anything; a change of a stage does.
    func testTheFingerprintIsWhatGrows() {
        var def = PlantCatalog.builtIn[.oak]
        var graph = def.grownGraph
        graph.nodes[0].at = [10, 20]
        def.setGraph(graph)
        XCTAssertEqual(PlantCatalog(species: [def]).fingerprint, PlantCatalog(species: [PlantCatalog.builtIn[.oak]]).fingerprint)
        graph.nodes[0].settings = .grow(Growth.Params())
        def.setGraph(graph)
        XCTAssertNotEqual(PlantCatalog(species: [def]).fingerprint, PlantCatalog(species: [PlantCatalog.builtIn[.oak]]).fingerprint)
    }

    /// In the folder: a file is a species of its stages, whether it's compiled yet or not, and beats a recipe of its id.
    func testAFileIsASpecies() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plant-swift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var def = PlantCatalog.builtIn[.fern]
        def.growth?.cycles = 5
        try PlantStore.encode(def).write(to: PlantStore.url("fern", in: folder))
        XCTAssertEqual(PlantStore.load(from: folder)[.fern].growth?.cycles, 5, "an older recipe still loads")
        def.growth?.cycles = 7
        try PlantStore.save(def, in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: PlantStore.url("fern", in: folder).path), "saving replaces the recipe")
        let loaded = PlantStore.load(from: folder)[.fern]
        XCTAssertEqual(loaded.growth?.cycles, 7)
        XCTAssertEqual(loaded.seedIndex, PlantCatalog.builtIn[.fern].seedIndex)
        XCTAssertEqual(PlantCatalog(species: [loaded]).fingerprint, PlantCatalog(species: [def]).fingerprint)
    }
}
