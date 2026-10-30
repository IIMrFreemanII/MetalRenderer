import XCTest
import AppKit
@testable import Buildings
@testable import Characters
@testable import Editors
@testable import Effects
@testable import EngineCore
@testable import Game
@testable import Landscape
@testable import Materials
@testable import MetalRenderer
@testable import Physics
@testable import Plants

/// What the plant editor is built from without its UI: the parameter tables of a grown species (PlantParams.swift),
/// Mutate (PlantMutate.swift), and its model (undo, the scenes it reaches, copy and paste, saving).
final class PlantEditorTests: XCTestCase {
    private func check<Root>(_ table: [PlantParam<Root>], _ root: Root, _ what: String) {
        for p in table {
            let v = p.get(root)
            XCTAssertTrue(p.range.contains(v), "\(what) \(p.title): \(v) is outside \(p.range)")
            // Setting what it holds changes nothing.
            var r = root
            p.set(&r, v)
            XCTAssertEqual(p.get(r), v, "\(what) \(p.title)")
        }
    }

    /// Every number of a grown species (its growth, shoots, light, wood, twigs and leaves) inside its slider's range.
    private func checkGrown(_ def: Foliage.SpeciesDef, _ what: String) {
        if let g = def.growth {
            for table in [PlantParams.growth, PlantParams.hormones, PlantParams.gravity] { check(table, g, what) }
            check(PlantParams.shoot, g.trunk, "\(what) trunk")
            if let b = g.branch { check(PlantParams.shoot, b, "\(what) branches") }
            check(PlantParams.light, g.light, what)
            if let sen = g.senescence { check(PlantParams.senescence, sen, what) }
            if let fork = g.bifurcation { check(PlantParams.bifurcation, fork, what) }
            check(PlantParams.wood, g.wood, what)
            check(PlantParams.age, g.young, "\(what) young")
            check(PlantParams.age, g.sapling, "\(what) sapling")
        }
        if let t = def.twigs {
            check(PlantParams.twigs, t, "\(what) twigs")
            check(PlantParams.leaf, t.leaf, "\(what) twig leaf")
            for table in [PlantParams.growth, PlantParams.hormones] { check(table, t.growth, "\(what) twig") }
            check(PlantParams.shoot, t.growth.trunk, "\(what) twig stem")
            if let b = t.growth.branch { check(PlantParams.shoot, b, "\(what) twig side shoots") }
        }
        if let leaf = def.leaf { check(PlantParams.leaf, leaf, "\(what) leaf") }
        if let grass = def.grass { check(PlantParams.grass, grass, "\(what) grass") }
    }

    /// Every built-in species but the grass is grown, and every built-in number is inside its slider's range: the
    /// editor shows them where they are.
    func testTheBuiltInSpeciesFitTheSliders() {
        for def in PlantCatalog.builtIn.species {
            XCTAssertEqual(def.growth != nil, def.grass == nil, def.id)
            checkGrown(def, def.id)
            if def.role == .tree { check(PlantParams.tree, def.habitat, def.id) }
            if let cover = def.habitat.cover { check(PlantParams.cover, cover, "\(def.id) cover") }
        }
    }

    /// Mutate: the same seed, the same variations; each one a little different, sound, and still in its sliders.
    func testMutantsAreSeededAndSound() {
        let oak = PlantCatalog.builtIn[.oak]
        let a = PlantMutate.mutants(of: oak, seed: 42), b = PlantMutate.mutants(of: oak, seed: 42)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, PlantMutate.mutants(of: oak, seed: 43))
        XCTAssertEqual(a.count, 6)
        XCTAssertEqual(Set(a.map(\.id)).count, 6)
        var catalog = PlantCatalog.builtIn
        for m in a {
            XCTAssertFalse(m.growth == oak.growth && m.twigs == oak.twigs, "\(m.id) is the oak")
            XCTAssertEqual(m.seedIndex, oak.seedIndex)
            XCTAssertEqual(m.look, oak.look)
            checkGrown(m, m.id)
            catalog.species.append(m)
        }
        // They grow as sound plants, in a catalog of their own after the built-in ones (as the workshop shows them).
        let sets = Foliage.library(seed: 1, catalog: catalog, species: (7..<13).map(Foliage.Species.init(rawValue:)))
        for set in sets {
            for plant in set.plants(of: .mature).map({ set.plants[$0] }) {
                for mesh in plant.meshes { XCTAssertEqual(Foliage.problems(mesh), []) }
            }
        }
        // Picking one keeps the species itself.
        let picked = PlantMutate.pick(a[2], into: oak)
        XCTAssertEqual(picked.id, "oak")
        XCTAssertEqual(picked.growth, a[2].growth)
        XCTAssertEqual(picked.twigs, a[2].twigs)
        XCTAssertEqual(picked.habitat, oak.habitat)
        // The fern (leaves on its own stems) and the grass (blades) mutate too.
        for id in [Foliage.Species.fern, .grass] {
            let def = PlantCatalog.builtIn[id]
            XCTAssertTrue(PlantMutate.mutants(of: def, seed: 7).contains { $0.leaf != def.leaf || $0.grass != def.grass
                || $0.growth != def.growth }, def.id)
        }
    }

    /// The younger ages are their shares of the mature plant's cycles and height.
    func testAgesAreShares() {
        var g = PlantCatalog.builtIn[.oak].growth!
        g.young = Growth.AgeShare(cycles: 0.5, height: 0.25)
        XCTAssertEqual(Growth.aged(g, .young).cycles, Int((Float(g.cycles) / 2).rounded()))
        XCTAssertEqual(Growth.aged(g, .young).targetHeight, g.targetHeight / 4, accuracy: 1e-5)
        XCTAssertEqual(Growth.aged(g, .mature), g)
        XCTAssertLessThan(Growth.aged(g, .sapling).cycles, Growth.aged(g, .young).cycles)
    }

    /// A grown species without twigs is its wood (and any leaves of its own): no palette, no shared parts.
    func testTwigsOff() {
        var def = PlantCatalog.builtIn[.oak]
        def.twigs = nil
        XCTAssertEqual(def.paletteSize, 0)
        let plant = Foliage.plant(def, .oak, age: .mature, seed: 3, palette: [])
        XCTAssertFalse(plant.parts.contains(where: \.shared))
        for mesh in plant.meshes { XCTAssertEqual(Foliage.problems(mesh), []) }
    }

    func testSlugs() {
        XCTAssertEqual(PlantEditorModel.slug("Weeping Willow 2"), "weeping-willow-2")
        XCTAssertEqual(PlantEditorModel.slug("  Oak — tall! "), "oak-tall")
    }

    // MARK: - The editor's model, with a stand-in for the renderer

    private final class Host: PlantEditorHost {
        var settings = RenderSettings()
        var defaultSettings = RenderSettings()
        var plantStats: PlantStats?
        var updates = 0
        private var observers: [(RenderSettings) -> Void] = []
        func update(_ change: @escaping (inout RenderSettings) -> Void) {
            change(&settings)
            updates += 1
            observers.forEach { $0(settings) }
        }
        func observeSettings(_ observer: @escaping (RenderSettings) -> Void) { observers.append(observer) }
        func observeTick(_ observer: @escaping () -> Void) {}
        func frameWorkshop() {}
    }

    private func editor(in kind: SceneKind = .plants, folder: URL? = nil) -> (PlantEditorModel, Host) {
        let host = Host()
        host.settings.scene.kind = kind
        return (PlantEditorModel(controller: host, saved: .builtIn, folder: folder, draft: false), host)
    }

    /// A drag is one undo step however many values it went through; each other edit is one; undo and redo walk them.
    func testUndoStepsAreEdits() {
        let (m, _) = editor()
        m.beginDrag()
        let cycles = m.def.growth!.cycles
        for c in 1...4 { m.def.growth?.cycles = cycles + c }
        m.endDrag()
        m.def.look.translucency = 0.5
        XCTAssertEqual(m.def.growth?.cycles, cycles + 4)
        m.undo.undo()
        XCTAssertEqual(m.def.look.translucency, PlantCatalog.builtIn[.oak].look.translucency)
        XCTAssertEqual(m.def.growth?.cycles, cycles + 4)
        m.undo.undo()
        XCTAssertEqual(m.def.growth?.cycles, cycles)
        XCTAssertFalse(m.isDirty)
        m.undo.redo()
        XCTAssertEqual(m.def.growth?.cycles, cycles + 4)
        m.undo.redo()
        XCTAssertEqual(m.def.look.translucency, 0.5)
        // A click on a slider or a curve that moves nothing is no step at all.
        m.beginDrag()
        m.endDrag()
        m.undo.undo()
        XCTAssertEqual(m.def.look.translucency, PlantCatalog.builtIn[.oak].look.translucency)
    }

    /// While dragging only the workshop follows (in another scene with plants, nothing until it is let go); an edit
    /// names the catalog the scenes are built with, and undoing it to what is saved names the saved one again.
    func testEditsReachTheScenes() {
        let (m, host) = editor(in: .forest)
        m.beginDrag()
        m.def.growth?.cycles = 20
        XCTAssertEqual(host.settings.scene.plantCatalog, "", "the forest follows a drag only when it is let go")
        m.endDrag()
        let key = host.settings.scene.plantCatalog
        XCTAssertFalse(key.isEmpty)
        XCTAssertEqual(PlantCatalog.resolve(key)[.oak].growth?.cycles, 20)
        m.undo.undo()
        XCTAssertEqual(host.settings.scene.plantCatalog, PlantCatalog.launch == .builtIn ? "" : PlantCatalog.register(.builtIn))

        let (w, workshop) = editor(in: .plants)
        w.beginDrag()
        w.def.growth?.cycles = 9
        XCTAssertEqual(PlantCatalog.resolve(workshop.settings.scene.plantCatalog)[.oak].growth?.cycles, 9, "the workshop follows the drag")
        w.endDrag()

        // A scene without plants isn't told (it would be made again for nothing) until it is one with plants.
        let (c, cornell) = editor(in: .cornell)
        c.def.growth?.cycles = 7
        XCTAssertEqual(cornell.settings.scene.plantCatalog, "")
        cornell.update { $0.scene.kind = .valley }
        XCTAssertEqual(PlantCatalog.resolve(cornell.settings.scene.plantCatalog)[.oak].growth?.cycles, 7)
    }

    /// Copy and paste between species: a shoot, the twigs' leaves, the wood; never another kind of clip.
    func testCopyAndPaste() {
        let (m, _) = editor()
        m.pasteboard = NSPasteboard(name: NSPasteboard.Name("PlantEditorTests"))
        m.select("birch")
        let wood = m.graph.first(.skeleton, .plant)!
        m.selection = ["\(wood.id)"]
        m.copySelection()
        m.select("oak")
        m.paste()
        let pasted = m.graph.nodes.last!
        XCTAssertEqual(pasted.settings, wood.settings)
        XCTAssertNotEqual(pasted.name, wood.name, "named for this graph")
        XCTAssertEqual(pasted.inputs, [-1], "its wires stayed behind")
        XCTAssertEqual(m.selection, ["\(pasted.id)"])
    }

    /// The graph is an edit like any other: what its nodes hold is the species', one undo step to a slider's drag;
    /// wires go only where what they carry is taken and never in a circle; what can't run yet leaves the plant as it was.
    func testTheGraphIsTheSpecies() throws {
        let (m, host) = editor()
        m.select("oak")
        let grow = try XCTUnwrap(m.graph.first(.grow, .plant))
        guard case .grow(var p) = grow.settings else { return XCTFail("a grower") }
        m.beginDrag()
        p.cycles = 20
        m.setSettings(grow.id, .grow(p))
        XCTAssertEqual(m.def.growth?.cycles, 20)
        p.cycles = 21
        m.setSettings(grow.id, .grow(p))
        m.endDrag()
        XCTAssertEqual(m.def.growth?.cycles, 21)
        XCTAssertNotEqual(host.settings.scene.plantCatalog, "")
        m.undo.undo()
        XCTAssertEqual(m.def, PlantCatalog.builtIn[.oak], "the drag is one step")

        // Moved: no other plants.
        let key = host.settings.scene.plantCatalog
        m.moveSelection(by: [10, 0], ids: ["\(grow.id)"])
        XCTAssertEqual(m.graph.node(grow.id)?.at?.x, (grow.at?.x ?? 0) + 10)
        XCTAssertEqual(host.settings.scene.plantCatalog, key, "a node moved grows nothing new")
        m.undo.undo()

        // Wires.
        let g = m.graph
        let wood = try XCTUnwrap(g.first(.skeleton, .plant)), output = try XCTUnwrap(g.first(.output, .plant))
        XCTAssertFalse(m.link("\(grow.id)", "out", to: "\(output.id)", "0"), "wood takes stems, not what's growing")
        XCTAssertFalse(m.link("\(output.id)", "out", to: "\(grow.id)", "0"), "a grower takes nothing")
        XCTAssertFalse(m.link("\(wood.id)", "out", to: "\(wood.id)", "0"))
        XCTAssertEqual(m.wire(into: "\(output.id)", "0")?.from, "\(wood.id)")

        // A wire off: the graph says what's missing, and the plant stays its recipe's.
        m.unlink("\(output.id)", "0")
        XCTAssertNotNil(m.def.graph?.problem)
        guard case .graph(let running) = PlantPrograms.runner(for: m.def).body else { return XCTFail("its recipe") }
        XCTAssertNil(running.problem)
        m.link("\(wood.id)", "out", to: "\(output.id)", "0")
        XCTAssertNil(m.def.graph?.problem)

        // Added below the selected one, wired to it.
        m.selection = ["\(grow.id)"]
        m.addNode(.growMore, at: [0, 0])
        let more = try XCTUnwrap(m.graph.nodes.first { $0.kind == .growMore })
        XCTAssertEqual(more.inputs, [grow.id])
        XCTAssertFalse(try XCTUnwrap(m.def.graph).isStandard)
        m.selection = ["\(more.id)"]
        m.deleteSelection()
        XCTAssertNil(m.graph.nodes.first { $0.kind == .growMore })
    }

    /// Mutate and the recipe's other edits reach a species that has a graph.
    func testAGraphFollowsItsRecipe() throws {
        let (m, _) = editor()
        m.select("birch")
        m.moveSelection(by: [5, 5], ids: Set(m.graph.nodes.map { "\($0.id)" }))
        XCTAssertNotNil(m.def.graph)
        m.def.growth?.cycles = 12
        XCTAssertEqual(m.def.grownGraph.first(.grow, .plant).flatMap { n -> Int? in if case .grow(let p) = n.settings { return p.cycles } else { return nil } }, 12)
        let mutants = PlantMutate.mutants(of: m.def, seed: 4)
        for mutant in mutants { XCTAssertEqual(mutant.graph?.canonical, PlantGraph.standard(mutant).canonical) }
    }

    /// New species, renamed, saved as files; a built-in species as it is built in has no file.
    /// A node hung off the chain, added below the selected one, comes after the Output: the plant is still the Output's,
    /// run or compiled, and a Swift Code node's first function takes what it's wired to.
    func testANodeOffTheChainLeavesThePlant() throws {
        let (m, _) = editor()
        let before = PlantPrograms.runner(for: m.def).plant(.oak, age: .mature, seed: 1, palette: [])
        let grow = try XCTUnwrap(m.graph.first(.grow, .plant))
        for kind in [PlantNodeKind.spurs, .code] {
            m.selection = ["\(grow.id)"]
            m.addNode(kind, at: [0, 0])
        }
        let graph = try XCTUnwrap(m.def.graph)
        XCTAssertEqual(graph.nodes.suffix(2).map(\.kind), [.spurs, .code])
        XCTAssertNil(graph.problem)
        guard case .code(let code)? = graph.nodes.last?.settings else { return XCTFail("a code node") }
        XCTAssertTrue(code.text.contains("_ input: Growing) -> Growing"), code.text)

        let after = PlantPrograms.runner(for: m.def).plant(.oak, age: .mature, seed: 1, palette: [])
        XCTAssertEqual(after.parts.count, before.parts.count)
        XCTAssertEqual(after.bones.count, before.bones.count)

        if let why = PlantCompiler.shared.problem() { throw XCTSkip(why) }
        guard case .success = PlantCompiler.shared.program(PlantSwift.emit(m.def).text) else { return XCTFail("it doesn't compile") }
    }

    /// A pin not wired has no file that compiles: the status says what's missing, not the compiler, and Save leaves the
    /// file as it was.
    func testAnUnwiredGraphStaysADraft() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (m, _) = editor(folder: folder)

        m.selection = []
        m.addNode(.code, at: [0, 0])
        guard case .incomplete(let code) = m.compile else { return XCTFail("\(m.compile)") }
        XCTAssertTrue(code.contains("nothing is wired into In"), code)
        m.save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: PlantStore.swiftURL("oak", in: folder).path))
        XCTAssertTrue(m.message?.hasPrefix("Not saved") == true, m.message ?? "")
        XCTAssertTrue(m.isDirty)
        m.undo.undo()

        let wood = try XCTUnwrap(m.graph.first(.skeleton, .plant))
        m.unlink("\(wood.id)", "0")
        guard case .incomplete = m.compile else { return XCTFail("\(m.compile)") }
        m.save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: PlantStore.swiftURL("oak", in: folder).path))
    }

    func testSpeciesAndSaving() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plant-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (m, host) = editor(folder: folder)
        m.select("birch")
        m.newSpecies()
        XCTAssertEqual(m.selected, "birch-copy")
        XCTAssertEqual(host.settings.scene.plants.species, "birch-copy")
        m.rename("Weeping Willow")
        XCTAssertEqual(m.selected, "weeping-willow")
        XCTAssertGreaterThanOrEqual(m.def.seedIndex, 100)
        m.def.growth?.trunk.gravitropism = -0.3
        m.select("oak")
        m.def.look.translucency = 0.2
        m.save()
        XCTAssertFalse(m.isDirty)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files, ["oak.swift", "weeping-willow.swift"])
        XCTAssertEqual(PlantStore.load(from: folder).species(id: "weeping-willow").map { PlantStore.load(from: folder)[$0].growth?.trunk.gravitropism }, -0.3)
        // Back to built in: the file goes.
        m.resetToBuiltIn()
        m.save()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["weeping-willow.swift"])
        m.select("weeping-willow")
        m.deleteSpecies()
        m.save()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    /// Mutate shows the variations in the workshop; picking one is one edit and goes back to the one plant.
    func testMutateAndPick() {
        let (m, host) = editor()
        m.mutate()
        XCTAssertEqual(host.settings.scene.plants.layout, .mutate)
        XCTAssertEqual(PlantCatalog.registered(host.settings.scene.plants.mutants)?.count, 6)
        let third = m.mutants[2]
        m.pick(2)
        XCTAssertEqual(m.def.growth, third.growth)
        XCTAssertEqual(m.def.twigs, third.twigs)
        XCTAssertEqual(host.settings.scene.plants.layout, .single)
        m.undo.undo()
        XCTAssertEqual(m.def, PlantCatalog.builtIn[.oak])
    }
}
