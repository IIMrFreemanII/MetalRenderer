import XCTest
import simd
@testable import EngineCore
@testable import Plants

/// Program/, Programs/: the built-in species as programs are what they were as data, and a graph of the same stages
/// grows the same plants, byte for byte.
final class PlantProgramTests: XCTestCase {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/builtin-species-v2.json")
    }

    /// (The scenes' meshes are named by it: PlantGoldenTests.)
    func testTheBuiltInSpeciesAreAsTheyWere() throws {
        XCTAssertEqual(PlantCatalog.builtIn.fingerprint, "a8ae60f4176e")
        let saved = try JSONDecoder().decode([Foliage.SpeciesDef].self, from: Data(contentsOf: fixture))
        XCTAssertEqual(PlantCatalog.builtIn.species, saved)
    }

    private func hash(_ mesh: Foliage.Mesh, into hasher: inout GeneratedCache.Hasher) {
        hasher.add(mesh.positions.flatMap { [$0.x, $0.y, $0.z] })
        hasher.add(mesh.normals.flatMap { [$0.x, $0.y, $0.z] })
        hasher.add(mesh.uvs)
        hasher.add(mesh.indices)
    }

    private func hash(_ runner: PlantRunner, _ s: Foliage.Species, seed: UInt64, cards: Bool) -> String {
        let def = PlantCatalog.builtIn[s]
        var hasher = GeneratedCache.Hasher()
        let palette = (0..<def.paletteSize).map {
            runner.twig(s, variant: $0, of: def.paletteSize, sparse: def.twigs?.sparse, seed: seed &+ UInt64($0), cards: cards)
        }
        palette.forEach { hash($0, into: &hasher) }
        for age in Foliage.Age.allCases {
            let plant = runner.plant(s, age: age, seed: seed &+ UInt64(age.rawValue), palette: palette)
            plant.meshes.forEach { hash($0, into: &hasher) }
            hasher.add(plant.parts.map(\.transform))
            hasher.add(plant.bones.map { SIMD4<Float>($0.pivot, $0.phase) })
        }
        return hasher.name()
    }

    /// A program, its trace, and its recipe's standard graph are one plant.
    func testAGraphGrowsWhatItsProgramGrows() {
        for (i, program) in PlantPrograms.builtIn.enumerated() {
            let s = Foliage.Species(rawValue: i), def = PlantCatalog.builtIn[s]
            XCTAssertEqual(PlantPrograms.trace(program).canonical, PlantGraph.standard(def).canonical, def.id)
            XCTAssertTrue(PlantPrograms.trace(program).isStandard, def.id)
            for (seed, cards) in [(UInt64(1), false), (7, false), (7, true)] {
                let grown = hash(PlantRunner(.program(program)), s, seed: seed, cards: cards)
                XCTAssertEqual(grown, hash(PlantRunner(.graph(PlantPrograms.trace(program))), s, seed: seed, cards: cards), def.id)
                XCTAssertEqual(grown, hash(PlantRunner(.graph(.standard(def))), s, seed: seed, cards: cards), def.id)
            }
        }
    }

    /// A species runs as its program until its recipe is edited; then as the recipe.
    func testARunnerIsTheProgramOrTheRecipe() {
        var def = PlantCatalog.builtIn[.oak]
        guard case .program = PlantPrograms.runner(for: def).body else { return XCTFail("the oak is its program") }
        def.growth?.cycles = 10
        guard case .graph = PlantPrograms.runner(for: def).body else { return XCTFail("an edited oak is its recipe") }
    }

    /// The workshop's skeleton is the plant's.
    func testASkeletonIsThePlants() {
        let def = PlantCatalog.builtIn[.birch], runner = PlantPrograms.runner(for: def)
        let skeleton = runner.skeleton(.birch, age: .young, seed: 3)!
        let plant = runner.plant(.birch, age: .young, seed: 3, palette: [])
        var bounds = AABB()
        for n in skeleton.skeleton.nodes { bounds.grow(Foliage.xyz(n)) }
        XCTAssertEqual(skeleton.rootPhase, plant.bones[0].phase)
        XCTAssertEqual(bounds.hi.y, plant.bounds.hi.y, accuracy: 0.5)
        XCTAssertEqual(skeleton.light.count, skeleton.skeleton.stems.count)
    }
}

/// PlantCompiler, PlantStore: a Swift file is a program.
final class PlantCompilerTests: XCTestCase {
    private func oakFile() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Plants/Programs/Oak.swift"), encoding: .utf8)
    }

    /// A copy of the built-in file, compiled, grows the built-in's plants; and compiles once.
    func testACopyOfTheOakIsTheOak() throws {
        if let why = PlantCompiler.shared.problem() { throw XCTSkip(why) }
        let source = try oakFile()
        let made = try PlantCompiler.shared.program(source).get()
        XCTAssertEqual(PlantPrograms.def(of: made.program), PlantCatalog.builtIn[.oak])
        let runner = PlantRunner(.program(made.program)), built = PlantRunner(.program(Oak.self))
        let a = runner.twig(.oak, variant: 2, of: 6, sparse: 0.85, seed: 5), b = built.twig(.oak, variant: 2, of: 6, sparse: 0.85, seed: 5)
        XCTAssertEqual(a.positions, b.positions)
        XCTAssertEqual(a.uvs, b.uvs)
        let p = runner.plant(.oak, age: .young, seed: 9, palette: [a]), q = built.plant(.oak, age: .young, seed: 9, palette: [b])
        XCTAssertEqual(p.parts.map(\.transform), q.parts.map(\.transform))
        XCTAssertEqual(p.meshes.flatMap(\.positions), q.meshes.flatMap(\.positions))
        _ = try PlantCompiler.shared.program(source).get()
        XCTAssertEqual(PlantCompiler.shared.lastCompileSeconds, 0)
    }

    /// In the folder: its id's species, its source's hash in the catalog's fingerprint. What doesn't compile is told, and
    /// isn't a species.
    func testAFileInTheFolderIsASpecies() throws {
        if let why = PlantCompiler.shared.problem() { throw XCTSkip(why) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plant-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var source = try oakFile()
        source = source.replacingOccurrences(of: "package enum Oak", with: "package enum MyOak")
            .replacingOccurrences(of: "SpeciesInfo(id: \"oak\")", with: "SpeciesInfo(id: \"myoak\")")
            .replacingOccurrences(of: "$0.cycles = 45", with: "$0.cycles = 20")
        try source.write(to: folder.appendingPathComponent("myoak.swift"), atomically: true, encoding: .utf8)
        try "package enum Broken: PlantProgram { nonsense }".write(to: folder.appendingPathComponent("broken.swift"), atomically: true, encoding: .utf8)
        let catalog = PlantStore.load(from: folder)
        let s = try XCTUnwrap(catalog.species(id: "myoak"))
        XCTAssertEqual(catalog[s].growth?.cycles, 20)
        XCTAssertGreaterThanOrEqual(catalog[s].seedIndex, 100)
        XCTAssertNil(catalog.species(id: "broken"))
        XCTAssertEqual(PlantStore.problems.count, 1)
        XCTAssertTrue(PlantStore.problems[0].hasPrefix("broken.swift"), PlantStore.problems[0])
        guard case .graph = PlantPrograms.runner(for: catalog[s]).body else { return XCTFail("a file runs as its graph until it's compiled") }
        _ = try PlantCompiler.shared.program(of: catalog[s]).get()
        guard case .program = PlantPrograms.runner(for: catalog[s]).body else { return XCTFail("a file runs as its program once it is") }
        let set = Foliage.library(seed: 1, catalog: catalog, species: [s])[0]
        XCTAssertEqual(set.plants.count, catalog[s].ages.variants.reduce(0, +))
        XCTAssertNotEqual(catalog.fingerprint, PlantCatalog.builtIn.fingerprint)
    }
}
