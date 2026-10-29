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
        XCTAssertEqual(Growth.aged(g, .young).cycles, g.cycles / 2)
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
        let birch = PlantCatalog.builtIn[.birch], conifer = PlantCatalog.builtIn[.conifer]
        m.select("birch")
        m.copy(.shoot, shoot: .branches)
        XCTAssertTrue(m.canPaste(.shoot))
        XCTAssertFalse(m.canPaste(.look))
        m.select("oak")
        m.paste(.shoot, shoot: .branches)
        XCTAssertEqual(m.def.growth?.branch, birch.growth?.branch ?? birch.growth?.trunk)
        XCTAssertEqual(m.def.growth?.trunk, PlantCatalog.builtIn[.oak].growth?.trunk, "only the branches")
        m.paste(.look)   // not what is on the clipboard: nothing
        XCTAssertEqual(m.def.look, PlantCatalog.builtIn[.oak].look)
        m.select("conifer")
        m.copy(.leaves, twig: true)
        m.select("bush")
        m.paste(.leaves, twig: true)
        XCTAssertEqual(m.def.twigs?.leaf, conifer.twigs?.leaf)
        m.copy(.wood)
        m.select("birch")
        m.paste(.wood)
        XCTAssertEqual(m.def.growth?.wood, PlantCatalog.builtIn[.bush].growth?.wood)
        m.select("conifer")
        m.copy(.shoot, twig: true)
        m.select("oak")
        m.paste(.shoot, twig: true)
        XCTAssertEqual(m.def.twigs?.growth.trunk, conifer.twigs?.growth.trunk)
    }

    /// New species, renamed, saved as files; a built-in species as it is built in has no file.
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
        XCTAssertEqual(files, ["oak.json", "weeping-willow.json"])
        XCTAssertEqual(PlantStore.load(from: folder).species(id: "weeping-willow").map { PlantStore.load(from: folder)[$0].growth?.trunk.gravitropism }, -0.3)
        // Back to built in: the file goes.
        m.resetToBuiltIn()
        m.save()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["weeping-willow.json"])
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
