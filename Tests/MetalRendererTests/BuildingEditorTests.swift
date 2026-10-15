import XCTest
import AppKit
import simd
@testable import MetalRenderer

/// The building editor without its UI (BuildingEditorModel, BuildingParams, BuildingMutate), the styles as data
/// (BuildingStore) and the plans' hand edits (PlanEdits.swift).
final class BuildingEditorTests: XCTestCase {
    private final class Host: BuildingEditorHost {
        var settings = RenderSettings()
        var defaultSettings = RenderSettings()
        var buildingStats: BuildingStats?
        var buildingPlan: BuildingPlan?
        var walker: WalkerStatus?
        var cameraPosition: SIMD3<Float>?
        private var observers: [(RenderSettings) -> Void] = []
        func update(_ change: @escaping (inout RenderSettings) -> Void) {
            change(&settings)
            observers.forEach { $0(settings) }
        }
        func observeSettings(_ observer: @escaping (RenderSettings) -> Void) { observers.append(observer) }
        func observeTick(_ observer: @escaping () -> Void) {}
        func frameWorkshop() {}
    }

    private func editor(in kind: SceneKind = .buildings, folder: URL? = nil) -> (BuildingEditorModel, Host) {
        let host = Host()
        host.settings.scene.kind = kind
        return (BuildingEditorModel(controller: host, saved: .builtIn, folder: folder, draft: false), host)
    }

    /// Every built-in number is inside its slider's range.
    func testTheBuiltInStylesFitTheSliders() {
        for def in BuiltInBuildings.all {
            for p in BuildingParams.all {
                XCTAssertTrue(p.range.contains(p.get(def)), "\(def.id) \(p.title): \(p.get(def)) is outside \(p.range)")
            }
        }
    }

    /// A style survives being written and read: the same building from it.
    func testStylesRoundTrip() throws {
        for def in BuiltInBuildings.all {
            let data = try BuildingStore.encode(def)
            let back = try JSONDecoder().decode(BuildingStore.File.self, from: data).style
            XCTAssertEqual(back, def, def.id)
        }
        // Catalogs: the same contents, the same key; another, another.
        XCTAssertEqual(BuildingCatalog.builtIn.fingerprint, BuildingCatalog(styles: BuiltInBuildings.all).fingerprint)
        var other = BuildingCatalog.builtIn
        other.styles[0].proportions.bay = Span(3, 3.5)
        XCTAssertNotEqual(other.fingerprint, BuildingCatalog.builtIn.fingerprint)
        let key = BuildingCatalog.register(other)
        XCTAssertEqual(BuildingCatalog.resolve(key), other)
        XCTAssertEqual(BuildingCatalog.resolve("builtin"), .builtIn)
    }

    /// A custom style is built now and then in the districts it names, never in others.
    func testCustomStylesTakeTheirDistricts() {
        var c = BuildingCatalog.builtIn
        var mine = BuiltInBuildings.modern
        (mine.id, mine.districts) = ("glass", ["residential": 1])
        c.styles.append(mine)
        var glass = 0
        for seed in 0..<400 as Range<UInt64> {
            if c.style(for: .residential, seed: seed).id == "glass" { glass += 1 }
            XCTAssertNotEqual(c.style(for: .office, seed: seed).id, "glass")
        }
        XCTAssertEqual(Double(glass) / 400, 0.5, accuracy: 0.1)
    }

    /// A drag is one undo step; while dragging only the workshop follows, the city when it is let go.
    func testUndoStepsAndPushes() {
        let (m, host) = editor(in: .city)
        m.beginDrag()
        for bay: Float in [3, 3.2, 3.4] { m.def.proportions.bay = Span(bay, bay + 0.4) }
        XCTAssertEqual(host.settings.scene.buildingCatalog, "", "the city follows a drag only when it is let go")
        m.endDrag()
        XCTAssertFalse(host.settings.scene.buildingCatalog.isEmpty)
        XCTAssertEqual(BuildingCatalog.resolve(host.settings.scene.buildingCatalog).style(id: m.selected)?.proportions.bay.lo, 3.4)
        m.def.facade.shops = 0.9
        m.undo.undo()
        XCTAssertNotEqual(m.def.facade.shops, 0.9)
        m.undo.undo()
        XCTAssertEqual(m.def, BuiltInBuildings.residential)
        XCTAssertFalse(m.isDirty)
        m.undo.redo()
        XCTAssertEqual(m.def.proportions.bay.lo, 3.4)
    }

    func testCopyPasteMutateAndPick() {
        let (m, host) = editor()
        m.pasteboard = NSPasteboard(name: NSPasteboard.Name("BuildingEditorTests"))
        m.select("oldtown")
        m.copy(.look)
        XCTAssertTrue(m.canPaste(.look))
        XCTAssertFalse(m.canPaste(.rooms))
        m.select("modern")
        m.paste(.look)
        XCTAssertEqual(m.def.palette, BuiltInBuildings.oldtown.palette)
        m.paste(.rooms)   // not what is on the clipboard: nothing
        XCTAssertEqual(m.def.programme, BuiltInBuildings.modern.programme)

        let a = BuildingMutate.mutants(of: BuiltInBuildings.office, seed: 9), b = BuildingMutate.mutants(of: BuiltInBuildings.office, seed: 9)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set(a.map(\.id)).count, 6)
        for d in a { XCTAssertNotEqual(d, BuiltInBuildings.office) }
        m.select("office")
        m.mutate()
        XCTAssertEqual(host.settings.scene.buildings.layout, .mutate)
        XCTAssertEqual(BuildingCatalog.registered(host.settings.scene.buildings.mutants)?.styles.count, 6)
        let third = m.mutants[2]
        m.pick(2)
        XCTAssertEqual(m.def.proportions, third.proportions)
        XCTAssertEqual(m.def.id, "office")
        XCTAssertEqual(host.settings.scene.buildings.layout, .single)
    }

    /// New styles, saved as files with the single buildings' plans; a built-in style as it is built in has no file.
    func testStylesAndSaving() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("building-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (m, _) = editor(folder: folder)
        m.select("residential")
        m.newStyle()
        m.rename("Red Brick Flats")
        XCTAssertEqual(m.selected, "red-brick-flats")
        m.def.programme.unitWidth = Span(8, 11)
        m.addEdit(PlanEdit(op: .setType, storeys: .all, at: [0, 0], type: .study))
        m.select("office")
        m.def.facade.pilasters = 1
        m.save()
        XCTAssertFalse(m.isDirty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Styles").path).sorted(),
                       ["office.json", "red-brick-flats.json"])
        let loaded = BuildingStore.load(from: folder)
        XCTAssertEqual(loaded.style(id: "red-brick-flats")?.programme.unitWidth, Span(8, 11))
        XCTAssertEqual(loaded.overrides.count, 1)
        XCTAssertEqual(loaded.overrides.first?.edits.first?.type, .study)
        // Revert: the selected style as saved, the others as they are; Revert All: everything.
        m.def.massing.podium = 1
        m.select("red-brick-flats")
        m.def.programme.unitWidth = Span(9, 12)
        m.select("office")
        XCTAssertTrue(m.isDirty("office"))
        m.revert()
        XCTAssertFalse(m.isDirty("office"), "reverted")
        XCTAssertTrue(m.isDirty("red-brick-flats"), "the other style kept")
        m.revertAll()
        XCTAssertFalse(m.isDirty)
        m.resetToBuiltIn()
        m.save()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Styles").path), ["red-brick-flats.json"])
    }

    /// A draft from the last run: the editor starts from it, and Revert takes a style of it back to the saved one.
    func testTheDraftReverts() {
        var draft = BuildingCatalog.builtIn
        draft.styles[draft.styles.firstIndex { $0.id == "office" }!].massing.podium = 1
        BuildingStore.saveDraft(draft)
        defer { BuildingStore.saveDraft(nil) }
        let host = Host()
        host.settings.scene.kind = .buildings
        host.settings.scene.buildings.style = "office"
        let m = BuildingEditorModel(controller: host, saved: .builtIn, folder: nil, draft: true)
        XCTAssertEqual(m.selected, "office")
        XCTAssertTrue(m.isDirty("office"))
        m.revert()
        XCTAssertFalse(m.isDirty("office"))
        XCTAssertFalse(m.isDirty)
    }

    /// A style file from before a field was added still reads: the field takes its default.
    func testOlderStyleFilesRead() throws {
        let def = BuiltInBuildings.office
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: BuildingStore.encode(def)) as? [String: Any])
        var style = try XCTUnwrap(json["style"] as? [String: Any])
        var interior = try XCTUnwrap(style["interior"] as? [String: Any])
        interior["models"] = nil
        style["interior"] = interior
        style["programme"] = nil
        json["style"] = style
        let read = try BuildingStore.decode(JSONSerialization.data(withJSONObject: json)).style
        XCTAssertEqual(read.interior.models, true)
        XCTAssertEqual(read.programme, Programme())
        XCTAssertEqual(read.palette, def.palette)
    }

    /// glTF props in place of generated pieces: a model (a quad, here) fitted where the sofas would stand, in living
    /// rooms only.
    func testModelsTakeThePlaceOfPieces() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("props-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var bytes = Data()
        for v: Float in [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0] { withUnsafeBytes(of: v) { bytes.append(contentsOf: $0) } }
        for i: UInt16 in [0, 1, 2, 0, 2, 3] { withUnsafeBytes(of: i) { bytes.append(contentsOf: $0) } }
        let gltf = """
        {"asset":{"version":"2.0"},"scenes":[{"nodes":[0]}],"scene":0,"nodes":[{"mesh":0}],
         "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
         "accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},
                      {"bufferView":1,"componentType":5123,"count":6,"type":"SCALAR"}],
         "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":12}],
         "buffers":[{"byteLength":60,"uri":"data:application/octet-stream;base64,\(bytes.base64EncodedString())"}]}
        """
        try gltf.write(to: folder.appendingPathComponent("sofa.gltf"), atomically: true, encoding: .utf8)
        let kept = PropLibrary.shared
        defer { PropLibrary.shared = kept }
        PropLibrary.shared = PropLibrary(entries: [PropLibrary.Entry(file: "sofa.gltf", replaces: .sofa, rooms: [.living])], folder: folder)
        var spec = BuildingSpec(size: SIMD2(22, 14))
        (spec.style, spec.floors, spec.seed, spec.interior) = (.residential, 3, 5, true)
        let b = BuildingGenerator.generate(spec)
        let models = try XCTUnwrap(b.interior?.models)
        XCTAssertFalse(models.isEmpty)
        for m in models {
            let p = SIMD2(m.frame.columns.3.x, m.frame.columns.3.z) + SIMD2(m.frame.columns.0.x + m.frame.columns.2.x, m.frame.columns.0.z + m.frame.columns.2.z) * 0.05
            XCTAssertEqual(b.plan.storeys[m.storey].room(at: p)?.type, .living)
        }
        let fit = try XCTUnwrap(PropLibrary.shared.fit(0, into: SIMD3(2, 0.8, 0.9)))
        let top = fit * SIMD4<Float>(1, 1, 0, 1)
        XCTAssertEqual(top.y, 0.8, accuracy: 1e-4, "scaled to the piece's height")
        let scene = Scene(SceneSettings(kind: .buildings))
        XCTAssertGreaterThan(scene.meshes.count, 0)
    }

    // MARK: - Hand edits

    private func spec(edits: [PlanEdit] = [], floors: Int = 4, seed: UInt64 = 3) -> BuildingSpec {
        var s = BuildingSpec(size: SIMD2(22, 14))
        (s.style, s.floors, s.seed, s.edits) = (.residential, floors, seed, edits)
        return s
    }

    /// Splitting a room, typing it, merging it back, moving a wall, adding and taking away doors: each changes the
    /// plan where it says and nowhere else, and the plan stays one the walker can go through.
    func testEditsChangeThePlan() {
        let base = BuildingGenerator.generate(spec()).plan
        let f = base.storeys[1]
        guard let living = f.rooms.first(where: { $0.type == .living }) else { return XCTFail("no living room") }
        let at = living.rect.center
        let split = BuildingGenerator.generate(spec(edits: [PlanEdit(op: .split, storeys: .one(1), at: at, alongX: false)])).plan
        XCTAssertEqual(split.storeys[1].rooms.count, f.rooms.count + 1)
        XCTAssertEqual(split.storeys[2].rooms.count, base.storeys[2].rooms.count, "only floor 1")
        XCTAssertTrue(split.orphaned.isEmpty)
        // A study in its half, then the halves one again.
        let typed = BuildingGenerator.generate(spec(edits: [PlanEdit(op: .split, storeys: .one(1), at: at, alongX: false),
                                                            PlanEdit(op: .setType, storeys: .one(1), at: at + SIMD2(0.3, 0), type: .study)])).plan
        XCTAssertTrue(typed.storeys[1].rooms.contains { $0.type == .study })
        let merged = BuildingGenerator.generate(spec(edits: [PlanEdit(op: .split, storeys: .one(1), at: at, alongX: false),
                                                             PlanEdit(op: .merge, storeys: .one(1), at: at - SIMD2(0.3, 0), to: at + SIMD2(0.3, 0))])).plan
        XCTAssertEqual(merged.storeys[1].rooms.count, f.rooms.count)
        // An edit that finds nothing is kept, and does nothing.
        let lost = BuildingGenerator.generate(spec(edits: [PlanEdit(op: .merge, storeys: .all, at: [100, 100], to: [101, 100])])).plan
        XCTAssertEqual(lost.orphaned, [0])
        XCTAssertEqual(lost.storeys.map(\.rooms), base.storeys.map(\.rooms))
        // Every edited plan: rooms tile it and every room is reached.
        for plan in [split, typed, merged] {
            for floor in plan.storeys {
                XCTAssertEqual(floor.rooms.reduce(0) { $0 + $1.area }, floor.usable.reduce(0) { $0 + $1.area }, accuracy: 0.1)
                var reached = Set<Int>(), queue = floor.rooms.indices.filter { floor.rooms[$0].type == .stairs } + floor.doors.filter { $0.b < 0 }.map(\.a)
                while let r = queue.popLast() {
                    guard reached.insert(r).inserted else { continue }
                    for d in floor.doors where d.touches(r) && d.b >= 0 { queue.append(d.other(r)) }
                }
                XCTAssertEqual(reached.count + floor.rooms.filter { $0.type == .lift }.count, floor.rooms.count, "storey \(floor.storey)")
            }
        }
    }

    /// Edits survive a change of the seed or the floors: they find their rooms where they are.
    func testEditsSurviveRegeneration() {
        let base = BuildingGenerator.generate(spec()).plan
        let corridor = base.storeys[1].rooms.first { $0.type == .corridor }!
        let edit = PlanEdit(op: .setType, storeys: .all, at: corridor.rect.center, type: .lobby)
        for s in [spec(edits: [edit], floors: 6), spec(edits: [edit], seed: 3)] {
            let plan = BuildingGenerator.generate(s).plan
            XCTAssertTrue(plan.orphaned.isEmpty)
            XCTAssertTrue(plan.storeys[1].rooms.contains { $0.type == .lobby && $0.rect.contains(corridor.rect.center) })
        }
        // Doors: one added where there was none, one taken away.
        let wall = base.storeys[1].rooms.first { $0.type == .bedroom }!
        let side = SIMD2(wall.rect.center.x, wall.rect.lo.y)
        let added = BuildingGenerator.generate(spec(edits: [PlanEdit(op: .addDoor, storeys: .one(1), at: side, width: 0.9)])).plan
        XCTAssertTrue(added.orphaned.isEmpty || base.storeys[1].doors.contains { distance($0.at, side) < 0.6 })
        let door = base.storeys[1].doors.first { $0.kind == .door }!
        let removed = BuildingGenerator.generate(spec(edits: [PlanEdit(op: .removeDoor, storeys: .one(1), at: door.at)])).plan
        XCTAssertFalse(removed.storeys[1].doors.contains { distance($0.at, door.at) < 0.01 && $0.kind == .door })
    }
}
