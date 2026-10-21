import XCTest
@testable import Characters
@testable import Editors
@testable import Effects
@testable import EngineCore
@testable import Game
@testable import Materials
@testable import MetalRenderer
@testable import Physics
@testable import Plants

/// The scenes by kind (SceneDefinition.swift): the engine's and the game's together, named as they were when scenes
/// were an enum, so saved settings, METALRENDERER_SCENE and outlines still find them.
final class SceneRegistryTests: XCTestCase {
    func testEveryOldSceneIsRegistered() {
        let kinds = SceneRegistry.kinds
        XCTAssertEqual(kinds.map(\.name), SceneKind.numbered, "the panel lists them in the enum's order")
        XCTAssertEqual(Set(kinds.map(\.definition.envName)).count, kinds.count, "env names are unique")
        for kind in kinds { XCTAssertEqual(kind.definition.kind, kind) }
    }

    func testEnvNames() {
        XCTAssertEqual(SceneKind(envText: "citynight"), .cityNight)
        XCTAssertEqual(SceneKind(envText: "CityNight"), .cityNight)
        XCTAssertEqual(SceneKind(envText: "people"), .characters)
        XCTAssertEqual(SceneKind.characters.envName, "people")
        XCTAssertEqual(SceneKind.softBodies.envName, "softbodies")
        XCTAssertNil(SceneKind(envText: "nowhere"))
    }

    /// Settings saved when scenes were an enum hold the case's number; they are saved by name now.
    func testOldSettingsReadBack() throws {
        var s = SceneSettings()
        s.kind = .cityNight
        let saved = try JSONEncoder().encode(s)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "cityNight")
        for (n, name) in SceneKind.numbered.enumerated() {
            object["kind"] = n
            let old = try JSONSerialization.data(withJSONObject: object)
            XCTAssertEqual(try JSONDecoder().decode(SceneSettings.self, from: old).kind.name, name)
        }
        object["kind"] = 99
        XCTAssertEqual(try JSONDecoder().decode(SceneSettings.self, from: JSONSerialization.data(withJSONObject: object)).kind, .cornell)
    }

    func testUnknownSceneIsTheCornellRoom() {
        let gone = SceneKind("gone")
        XCTAssertFalse(SceneRegistry.has(gone))
        XCTAssertEqual(gone.definition.kind, .cornell)
    }

    /// What the editors open, and what the old switches said of a few scenes.
    func testRolesAndTraits() {
        XCTAssertEqual(SceneRegistry.kind(for: .city), .city)
        XCTAssertEqual(SceneRegistry.kind(for: .forest), .forest)
        XCTAssertEqual(SceneRegistry.kind(for: .fracture), .destruction)
        XCTAssertEqual(SceneRegistry.kinds.filter(\.simulates).map(\.name),
                       ["physics", "ragdolls", "hair", "softBodies", "muscles", "fluids", "destruction", "demolition"])
        XCTAssertEqual(SceneRegistry.kinds.filter(\.usesPhysicsLook).count, 6)
        XCTAssertEqual(SceneRegistry.kinds.filter(\.hasRealisticLook).map(\.name),
                       ["sun", "valley", "forest", "crowd", "world", "plants", "buildings", "terrain"])
        XCTAssertEqual(SceneRegistry.kinds.filter { $0.dayCycle != nil }.map(\.name), ["sun", "valley", "forest", "city", "world", "terrain"])
        XCTAssertEqual(DayClock.of(.city)?.otherScene, .cityNight)
        XCTAssertTrue(SceneKind.demolition.definition.solid)
        XCTAssertEqual(SceneKind.market.definition.lights, GameScenes.marketLights)
        var s = SceneSettings()
        s.kind = .market
        s.startLights()
        XCTAssertEqual(s.lights, GameScenes.marketLights)
    }
}
