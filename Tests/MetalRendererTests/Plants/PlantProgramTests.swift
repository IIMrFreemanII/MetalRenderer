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

    private func oak(strength: Float?, seed: UInt64 = 5) -> (plant: Foliage.Plant, skeleton: PlantSkeleton) {
        var graph = PlantGraph.standard(PlantCatalog.builtIn[.oak])
        if let strength {
            var s = Growth.BoneReduction()
            s.strength = strength
            graph.insert(.boneReduction(s), after: .skeleton)
        }
        let runner = PlantRunner(.graph(graph))
        let palette = (0..<3).map { runner.twig(.oak, variant: $0, of: 3, sparse: 0.85, seed: UInt64($0)) }
        return (runner.plant(.oak, age: .young, seed: seed, palette: palette), runner.skeleton(.oak, age: .young, seed: seed)!)
    }

    /// Bone Reduction takes bones and nothing else: the same meshes and transforms and the same bones kept, at 0 all of
    /// them; at 1, one for each stem that has twigs (Unreal keeps one between each of a branch's joints); the furthest
    /// twig on a shared bone moves no further than a twig does by itself.
    func testBoneReductionTakesOnlyBones() {
        let plain = oak(strength: nil).plant
        let bits = { (m: float4x4) in [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w].map(\.bitPattern) } }
        func same(_ a: Foliage.Plant, _ b: Foliage.Plant) -> Bool {
            a.meshes.flatMap(\.positions) == b.meshes.flatMap(\.positions) && a.parts.map { bits($0.transform) } == b.parts.map { bits($0.transform) }
                && a.parts.map(\.mesh) == b.parts.map(\.mesh)
        }
        let none = oak(strength: 0).plant
        XCTAssertTrue(same(plain, none))
        XCTAssertEqual(plain.parts.map(\.bone), none.parts.map(\.bone))
        XCTAssertEqual(plain.bones.map(\.pivot), none.bones.map(\.pivot))
        XCTAssertEqual(plain.bones.map(\.phase), none.bones.map(\.phase))
        XCTAssertTrue(plain.bones.allSatisfy { $0.swing == 1 })

        let limbs = plain.parts.filter { !$0.shared }.count
        let twigs = plain.parts.count - limbs
        XCTAssertGreaterThan(twigs, 100)
        var last = plain.bones.count
        for s: Float in [0.5, 0.83, 1] {
            let (fewer, skeleton) = oak(strength: s)
            XCTAssertTrue(same(plain, fewer), "\(s)")
            XCTAssertLessThan(fewer.bones.count, last, "\(s)")
            last = fewer.bones.count
            // As FoliageTests asks of any plant, and each kept bone is one the plain plant has.
            XCTAssertEqual(fewer.bones[0].parent, -1)
            for (b, bone) in fewer.bones.enumerated().dropFirst() { XCTAssertTrue(bone.parent >= 0 && Int(bone.parent) < b) }
            for part in fewer.parts { XCTAssertTrue(fewer.bones.indices.contains(part.bone)) }
            let kept = Set(plain.bones.map { SIMD4<Float>($0.pivot, $0.phase) })
            XCTAssertTrue(fewer.bones.allSatisfy { kept.contains(SIMD4<Float>($0.pivot, $0.phase)) })
            XCTAssertEqual(Set(fewer.parts.map(\.bone)).count, fewer.bones.count, "no bone is left with nothing on it")
            for (p, part) in fewer.parts.enumerated() where part.shared {
                let bone = fewer.bones[part.bone], own = plain.bones[plain.parts[p].bone]
                XCTAssertEqual(bone.parent, own.parent, "it stays on its limb")
                XCTAssertLessThanOrEqual(bone.swing, 1)
                XCTAssertLessThanOrEqual(bone.swing * (length(own.pivot - bone.pivot) + own.length), bone.length * 1.0001)
            }
            if s == 1 {
                // (A trunk's and a limb's part sit on the first bones; each stem that has twigs has one more.)
                let stems = Set(fewer.parts.filter(\.shared).map(\.bone)).count
                XCTAssertEqual(fewer.bones.count, 1 + skeleton.skeleton.limbs + stems)
                XCTAssertLessThanOrEqual(stems, skeleton.skeleton.stems.count)
            }
        }
    }

    /// How many a stem's twigs keep: lerp(n, 1, strength) rounded up, in runs along the stem, on the one nearest its foot.
    func testKeptBones() {
        func places(_ stems: [Int]) -> [Growth.TwigPlace] {
            stems.enumerated().flatMap { stem, n in
                (0..<n).map { _ in Growth.TwigPlace(position: .zero, direction: [0, 1, 0], size: 1, stem: stem, light: 1, radius: 0.01) }
            }
        }
        XCTAssertEqual(Growth.keptBones(places([3]), strength: 0), [0, 1, 2])
        XCTAssertEqual(Growth.keptBones(places([3]), strength: 1), [2, 2, 2])
        XCTAssertEqual(Growth.keptBones(places([3, 1, 2]), strength: 1), [2, 2, 2, 3, 5, 5])
        XCTAssertEqual(Growth.keptBones(places([10]), strength: 0.5), [0, 2, 2, 4, 4, 5, 7, 7, 9, 9], "lerp(10, 1, 0.5) = 5.5: 6")
        XCTAssertEqual(Growth.keptBones(places([]), strength: 1), [])
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

    /// Gravity and Bone Reduction: the file compiled is the graph run, byte for byte (on the plant and on the twig), and
    /// they do something.
    func testTheNewStagesCompiledAreTheGraphRun() throws {
        if let why = PlantCompiler.shared.problem() { throw XCTSkip(why) }
        var def = PlantCatalog.builtIn[.birch]
        let plain = PlantGraph.standard(def)
        var graph = plain
        var bent = Growth.Gravity()
        bent.strength = 0.61803
        bent.direction = [0.3, -1, 0.1]
        bent.angleCorrection = 0.4
        graph.insert(.gravity(bent), after: .grow)
        var toLight = Growth.Gravity()
        toLight.mode = .phototropic
        graph.insert(.gravity(toLight), after: .grow, side: .twig)
        var fewer = Growth.BoneReduction()
        fewer.strength = 0.7
        graph.insert(.boneReduction(fewer), after: .skeleton)
        def.setGraph(graph)
        XCTAssertNil(graph.problem)

        func grown(_ runner: PlantRunner) -> (positions: [SIMD3<Float>], uvs: [SIMD2<Float>], transforms: [float4x4], part: [Int], bones: [SIMD4<Float>], swing: [Float], twig: [SIMD3<Float>]) {
            let palette = (0..<def.paletteSize).map { runner.twig(.birch, variant: $0, of: def.paletteSize, sparse: def.twigs?.sparse, seed: UInt64($0) &+ 3) }
            let plant = runner.plant(.birch, age: .mature, seed: 21, palette: palette)
            return (plant.meshes.flatMap(\.positions), plant.meshes.flatMap(\.uvs), plant.parts.map(\.transform), plant.parts.map(\.bone),
                    plant.bones.map { SIMD4<Float>($0.pivot, $0.phase) }, plant.bones.map(\.swing), palette.flatMap(\.positions))
        }
        let graphRun = grown(PlantRunner(.graph(graph)))
        let compiled = try PlantCompiler.shared.program(of: def).get()
        let compiledRun = grown(PlantRunner(.program(compiled.program)))
        XCTAssertEqual(graphRun.positions, compiledRun.positions)
        XCTAssertEqual(graphRun.uvs, compiledRun.uvs)
        XCTAssertEqual(graphRun.transforms, compiledRun.transforms)
        XCTAssertEqual(graphRun.part, compiledRun.part)
        XCTAssertEqual(graphRun.bones, compiledRun.bones)
        XCTAssertEqual(graphRun.swing, compiledRun.swing)
        XCTAssertEqual(graphRun.twig, compiledRun.twig)

        let before = grown(PlantRunner(.graph(plain)))
        XCTAssertNotEqual(before.positions, graphRun.positions, "the plant bent")
        XCTAssertNotEqual(before.twig, graphRun.twig, "the twig bent")
        XCTAssertLessThan(graphRun.bones.count, before.bones.count, "it has fewer bones")
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
