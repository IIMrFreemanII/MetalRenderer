import XCTest
@testable import EngineCore
@testable import Game
@testable import MetalRenderer

/// Switching scenes (the scene-switching skill): what each install keeps of the scene before (SceneChange,
/// SceneSession), which background load is put in (SceneLoadQueue). The switches themselves, on the GPU, are the
/// skill's scripts/switches.py.
final class SceneSwitchTests: XCTestCase {
    // MARK: - SceneChange

    func testAnotherKindIsASwitch() {
        XCTAssertEqual(SceneChange(from: SceneSettings(kind: .cornell), to: SceneSettings(kind: .muscles), remade: false), .switched)
        XCTAssertEqual(SceneChange(from: SceneSettings(kind: .cornell), to: SceneSettings(kind: .muscles), remade: true), .switched)
        XCTAssertTrue(SceneChange.switched.restartsClock)
        XCTAssertTrue(SceneChange.switched.resetsCamera)
    }

    /// The same kind made again (a setting, a hot reload): new simulations, so a new clock; the camera stays.
    func testTheSameKindMadeAgainRestartsTheClock() {
        var a = SceneSettings(kind: .muscles), b = a
        XCTAssertEqual(SceneChange(from: a, to: b, remade: true), .remade, "a hot reload")
        XCTAssertEqual(SceneChange(from: a, to: b, remade: false), .remade, "virtual geometry or the season: the same settings")
        b.physics.substeps += 1
        XCTAssertEqual(SceneChange(from: a, to: b, remade: false), .remade, "a setting of the scene")
        a = SceneSettings(kind: .cars)
        b = a
        b.cars.cars = a.cars.cars + 1
        XCTAssertEqual(SceneChange(from: a, to: b, remade: false), .remade)
        XCTAssertTrue(SceneChange.remade.restartsClock)
        XCTAssertFalse(SceneChange.remade.resetsCamera)
    }

    /// The open world's next tile, the city's next interior, a workshop's edit: the same place, its clock kept.
    func testStreamingAndEditsContinue() {
        var a = SceneSettings(kind: .world), b = a
        b.worldTile = [1, 2]
        XCTAssertEqual(SceneChange(from: a, to: b, remade: false), .continued, "the world's next tile")
        XCTAssertEqual(SceneChange(from: a, to: b, remade: true), .remade, "the world made again (a hot reload)")
        a = SceneSettings(kind: .city)
        b = a
        b.interior = "block 3"
        XCTAssertEqual(SceneChange(from: a, to: b, remade: false), .continued, "another interior")
        a = SceneSettings(kind: .plants)
        b = a
        b.plants.age = a.plants.age == .young ? .mature : .young
        XCTAssertEqual(SceneChange(from: a, to: b, remade: false), .continued, "the plant editor's edit")
        b.plants.species = a.plants.species == "oak" ? "birch" : "oak"
        XCTAssertEqual(SceneChange(from: a, to: b, remade: false), .remade, "another species is another workshop")
        XCTAssertFalse(SceneChange.continued.restartsClock)
        XCTAssertFalse(SceneChange.continued.resetsCamera)
    }

    // MARK: - SceneSession

    private func session() -> SceneSession {
        var s = SceneSession()
        s.pickPending = 1
        s.pendingInstanceEdits = [[3], [4]]
        s.stillRefitPending = true
        s.placementDrag = Renderer.PlacementDrag(axis: 0, object: 2, last: 0, mode: .move)
        s.interiorWanted = ("block", 1)
        s.scriptHooks = [ScriptHook(owner: "a.swift", run: { _, _ in })]
        return s
    }

    func testASwitchDropsTheWholeSession() {
        let next = session().after(.switched)
        XCTAssertNil(next.pickPending)
        XCTAssertTrue(next.pendingInstanceEdits.isEmpty)
        XCTAssertFalse(next.stillRefitPending)
        XCTAssertNil(next.placementDrag)
        XCTAssertNil(next.interiorWanted)
        XCTAssertTrue(next.scriptHooks.isEmpty, "a script's closures name the scene they were set in")
    }

    func testARemakeKeepsOnlyTheScriptsClosures() {
        let next = session().after(.remade)
        XCTAssertNil(next.pickPending)
        XCTAssertNil(next.placementDrag)
        XCTAssertNil(next.interiorWanted)
        XCTAssertEqual(next.scriptHooks.map(\.owner), ["a.swift"], "a script that edits the scene file makes it again")
    }

    func testAContinuationDropsOnlyWhatNamesTheInstanceTable() {
        let next = session().after(.continued)
        XCTAssertNil(next.pickPending, "the next tile's instances are others")
        XCTAssertTrue(next.pendingInstanceEdits.isEmpty)
        XCTAssertFalse(next.stillRefitPending)
        XCTAssertNotNil(next.placementDrag)
        XCTAssertEqual(next.interiorWanted?.key, "block")
        XCTAssertEqual(next.scriptHooks.count, 1)
    }

    // MARK: - SceneLoadQueue

    func testOnlyTheLatestLoadIsPutIn() {
        var q = SceneLoadQueue()
        let a = q.start(SceneSettings(kind: .muscles)), b = q.start(SceneSettings(kind: .fluids))
        XCTAssertEqual(q.loading?.kind, .fluids)
        XCTAssertFalse(q.finished(a), "superseded")
        XCTAssertTrue(q.finished(b))
        XCTAssertNil(q.loading)
        XCTAssertFalse(q.finished(b), "once")
    }

    /// A, B, then A again: the first load of A, superseded, is dropped though its settings are the same.
    func testASupersededLoadOfTheSameSettingsIsDropped() {
        var q = SceneLoadQueue()
        let first = q.start(SceneSettings(kind: .muscles))
        _ = q.start(SceneSettings(kind: .fluids))
        let again = q.start(SceneSettings(kind: .muscles))
        XCTAssertFalse(q.finished(first))
        XCTAssertTrue(q.finished(again))
    }

    /// Away and back while it loads: the load is no longer wanted, and nothing is put in.
    func testGoingBackDropsTheLoad() {
        var q = SceneLoadQueue()
        let drawn = SceneSettings(kind: .cornell)
        let a = q.start(SceneSettings(kind: .muscles))
        XCTAssertFalse(q.settle(asked: SceneSettings(kind: .muscles), drawn: drawn), "still wanted")
        XCTAssertTrue(q.settle(asked: drawn, drawn: drawn))
        XCTAssertNil(q.loading)
        XCTAssertFalse(q.finished(a))
    }

    /// The scene drawn made again (a hot reload, virtual geometry): its load asks for the settings drawn, and stays.
    func testARemakeOfTheSceneDrawnIsKept() {
        var q = SceneLoadQueue()
        let drawn = SceneSettings(kind: .muscles)
        let remake = q.start(drawn)
        XCTAssertFalse(q.settle(asked: drawn, drawn: drawn))
        XCTAssertTrue(q.finished(remake))
    }
}
