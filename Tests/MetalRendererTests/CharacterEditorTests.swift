import XCTest
import AppKit
@testable import MetalRenderer

/// The character editor without its UI: its parameter table (CharacterParams), Randomize and Mutate, and its model
/// (CharacterEditorModel) against a stand-in renderer.
final class CharacterEditorTests: XCTestCase {
    private final class Host: CharacterEditorHost {
        var settings = RenderSettings()
        var defaultSettings = RenderSettings()
        var characterStats: CharacterStats?
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

    private func editor(in kind: SceneKind = .characters, folder: URL? = nil) -> (CharacterEditorModel, Host) {
        let host = Host()
        host.settings.scene.kind = kind
        return (CharacterEditorModel(controller: host, saved: .builtIn, folder: folder, draft: false), host)
    }

    func testTheBuiltInsFitTheSliders() {
        for d in BuiltInCharacters.all {
            for p in CharacterParams.all {
                let v = p.param.get(d)
                XCTAssertTrue(p.param.range.contains(v), "\(d.id) \(p.id): \(v) outside \(p.param.range)")
                var r = d
                p.param.set(&r, v)
                XCTAssertEqual(p.param.get(r), v, accuracy: 1e-6)
            }
        }
        XCTAssertEqual(Set(CharacterParams.all.map(\.id)).count, CharacterParams.all.count, "ids are unique")
        for s in CharacterParams.shapes { XCTAssertNotNil(CharacterMorphs.bumpTargets.first { $0.name == s.name }, "\(s.name) is a target") }
    }

    func testRandomizingKeepsLocksAndIsSeeded() {
        let d = BuiltInCharacters.all[0]
        let a = CharacterParams.randomized(d, groups: [.macro], locked: ["sex"], seed: 7)
        XCTAssertEqual(a, CharacterParams.randomized(d, groups: [.macro], locked: ["sex"], seed: 7))
        XCTAssertEqual(a.macro.sex, d.macro.sex)
        XCTAssertNotEqual(a.macro, d.macro)
        XCTAssertEqual(a.look, d.look, "only the groups asked for")
    }

    func testMutantsDifferAndKeepLocks() {
        let d = BuiltInCharacters.all[1]
        let m = CharacterParams.mutants(of: d, locked: ["age"], seed: 3)
        XCTAssertEqual(m.count, 5)
        XCTAssertEqual(Set(m.map(\.id)).count, 5)
        for v in m {
            XCTAssertEqual(v.macro.age, d.macro.age)
            XCTAssertNotEqual(v, d)
        }
    }

    /// A drag is one undo step however many values it went through; undo walks back.
    func testUndoStepsAreEdits() {
        let (m, host) = editor()
        let start = m.dna
        m.beginDrag()
        for w in stride(from: Float(0.1), through: 0.6, by: 0.1) { m.dna.macro.weight = w }
        m.endDrag()
        m.dna.macro.age = 60
        XCTAssertEqual(m.dna.macro.weight, 0.6, accuracy: 1e-5)
        m.undo.undo()
        XCTAssertEqual(m.dna.macro.age, start.macro.age)
        XCTAssertEqual(m.dna.macro.weight, 0.6, accuracy: 1e-5)
        m.undo.undo()
        XCTAssertEqual(m.dna, start)
        m.undo.redo()
        XCTAssertEqual(m.dna.macro.weight, 0.6, accuracy: 1e-5)
        XCTAssertNotEqual(host.settings.scene.characterCatalog, "", "the workshop is told the edited catalog")
    }

    func testEditsReachOnlyTheWorkshop() {
        let (m, host) = editor(in: .sun)
        m.dna.macro.muscle = 0.5
        XCTAssertEqual(host.settings.scene.characterCatalog, "")
        m.goToWorkshop()
        XCTAssertEqual(host.settings.scene.kind, .characters)
        XCTAssertEqual(CharacterCatalog.resolve(host.settings.scene.characterCatalog).character(id: m.selected)?.macro.muscle, 0.5)
    }

    func testMutateAndPick() {
        let (m, host) = editor()
        let id = m.dna.id
        m.mutate()
        XCTAssertEqual(host.settings.scene.characterWorkshop.layout, .mutate)
        XCTAssertEqual(CharacterCatalog.registered(host.settings.scene.characterWorkshop.mutants)?.characters.count, 5)
        let picked = m.mutants[2]
        m.pick(2)
        XCTAssertEqual(m.dna.id, id)
        XCTAssertEqual(m.dna.macro, picked.macro)
        XCTAssertEqual(host.settings.scene.characterWorkshop.layout, .single)
    }

    func testNewSaveAndRevert() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("character-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (m, _) = editor(folder: folder)
        m.newCharacter()
        XCTAssertFalse(m.isBuiltIn)
        m.rename("Old Sailor")
        XCTAssertEqual(m.dna.id, "old-sailor")
        m.dna.macro.age = 70
        m.save()
        XCTAssertFalse(m.isDirty)
        XCTAssertEqual(CharacterStore.load(from: folder).character(id: "old-sailor")?.macro.age, 70)
        m.dna.macro.age = 40
        m.revert()
        XCTAssertEqual(m.dna.macro.age, 70)
        m.deleteCharacter()
        m.save()
        XCTAssertNil(CharacterStore.load(from: folder).character(id: "old-sailor"))
    }
}
