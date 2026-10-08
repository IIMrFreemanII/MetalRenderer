import XCTest
import AppKit
@testable import MetalRenderer

/// What the plant editor is built from without its UI: the parameter table (PlantParams.swift) and Mutate
/// (PlantMutate.swift).
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

    /// Every built-in number is inside its slider's range: the editor shows them where they are.
    func testTheBuiltInSpeciesFitTheSliders() {
        for def in PlantCatalog.builtIn.species where def.grass == nil {
            for recipe in [def.recipe] + (def.bough.map { [$0] } ?? []) {
                check(PlantParams.trunk, recipe.levels[0], "\(def.id) level 0")
                for (l, level) in recipe.levels.enumerated().dropFirst() { check(PlantParams.level, level, "\(def.id) level \(l)") }
                if let leaf = recipe.leaf { check(PlantParams.leaf, leaf, "\(def.id) leaf") }
            }
            check(PlantParams.recipe, def.recipe, def.id)
            if let graft = def.recipe.graft { check(PlantParams.graft, graft, "\(def.id) graft") }
            check(PlantParams.palette, def.palette, def.id)
            check(PlantParams.age, def.ages.young, "\(def.id) young")
            check(PlantParams.age, def.ages.sapling, "\(def.id) sapling")
            if def.role == .tree { check(PlantParams.tree, def.habitat, def.id) }
        }
        for def in PlantCatalog.builtIn.species { if let cover = def.habitat.cover { check(PlantParams.cover, cover, "\(def.id) cover") } }
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
            XCTAssertNotEqual(m.recipe == oak.recipe && m.bough == oak.bough, true, "\(m.id) is the oak")
            XCTAssertEqual(m.seedIndex, oak.seedIndex)
            XCTAssertEqual(m.look, oak.look)
            for (l, level) in m.recipe.levels.enumerated().dropFirst() { check(PlantParams.level, level, "\(m.id) level \(l)") }
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
        XCTAssertEqual(picked.recipe, a[2].recipe)
        XCTAssertEqual(picked.habitat, oak.habitat)
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
        for count in [15, 16, 17, 18] { m.def.recipe.levels[1].count = count }
        m.endDrag()
        m.def.look.translucency = 0.5
        XCTAssertEqual(m.def.recipe.levels[1].count, 18)
        m.undo.undo()
        XCTAssertEqual(m.def.look.translucency, 0.35)
        XCTAssertEqual(m.def.recipe.levels[1].count, 18)
        m.undo.undo()
        XCTAssertEqual(m.def.recipe.levels[1].count, 14)
        XCTAssertFalse(m.isDirty)
        m.undo.redo()
        XCTAssertEqual(m.def.recipe.levels[1].count, 18)
        m.undo.redo()
        XCTAssertEqual(m.def.look.translucency, 0.5)
        // A click on a slider or a curve that moves nothing is no step at all.
        m.beginDrag()
        m.endDrag()
        m.undo.undo()
        XCTAssertEqual(m.def.look.translucency, 0.35)
    }

    /// While dragging only the workshop follows (in another scene with plants, nothing until it is let go); an edit
    /// names the catalog the scenes are built with, and undoing it to what is saved names the saved one again.
    func testEditsReachTheScenes() {
        let (m, host) = editor(in: .forest)
        m.beginDrag()
        m.def.recipe.levels[1].count = 20
        XCTAssertEqual(host.settings.scene.plantCatalog, "", "the forest follows a drag only when it is let go")
        m.endDrag()
        let key = host.settings.scene.plantCatalog
        XCTAssertFalse(key.isEmpty)
        XCTAssertEqual(PlantCatalog.resolve(key)[.oak].recipe.levels[1].count, 20)
        m.undo.undo()
        XCTAssertEqual(host.settings.scene.plantCatalog, PlantCatalog.launch == .builtIn ? "" : PlantCatalog.register(.builtIn))

        let (w, workshop) = editor(in: .plants)
        w.beginDrag()
        w.def.recipe.levels[1].count = 9
        XCTAssertEqual(PlantCatalog.resolve(workshop.settings.scene.plantCatalog)[.oak].recipe.levels[1].count, 9, "the workshop follows the drag")
        w.endDrag()

        // A scene without plants isn't told (it would be made again for nothing) until it is one with plants.
        let (c, cornell) = editor(in: .cornell)
        c.def.recipe.levels[1].count = 7
        XCTAssertEqual(cornell.settings.scene.plantCatalog, "")
        cornell.update { $0.scene.kind = .valley }
        XCTAssertEqual(PlantCatalog.resolve(cornell.settings.scene.plantCatalog)[.oak].recipe.levels[1].count, 7)
    }

    /// Copy and paste between species: a level, the leaves; never another kind of clip.
    func testCopyAndPaste() {
        let (m, _) = editor()
        m.pasteboard = NSPasteboard(name: NSPasteboard.Name("PlantEditorTests"))
        m.select("birch")
        m.level = 2
        m.copy(.level)
        XCTAssertTrue(m.canPaste(.level))
        XCTAssertFalse(m.canPaste(.look))
        m.select("oak")
        m.level = 2
        m.paste(.level)
        XCTAssertEqual(m.def.recipe.levels[2], PlantCatalog.builtIn[.birch].recipe.levels[2])
        m.paste(.look)   // not what is on the clipboard: nothing
        XCTAssertEqual(m.def.look, PlantCatalog.builtIn[.oak].look)
        m.select("conifer")
        m.copy(.leaves, bough: true)
        m.select("bush")
        m.paste(.leaves, bough: true)
        XCTAssertEqual(m.def.bough?.leaf, PlantCatalog.builtIn[.conifer].bough?.leaf)
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
        m.def.recipe.levels[2].tropism = -1.5
        m.select("oak")
        m.def.look.translucency = 0.2
        m.save()
        XCTAssertFalse(m.isDirty)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files, ["oak.json", "weeping-willow.json"])
        XCTAssertEqual(PlantStore.load(from: folder).species(id: "weeping-willow").map { PlantStore.load(from: folder)[$0].recipe.levels[2].tropism }, -1.5)
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
        XCTAssertEqual(m.def.recipe, third.recipe)
        XCTAssertEqual(host.settings.scene.plants.layout, .single)
        m.undo.undo()
        XCTAssertEqual(m.def, PlantCatalog.builtIn[.oak])
    }
}
