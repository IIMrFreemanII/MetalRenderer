import XCTest
import simd
@testable import Characters
@testable import Editors
@testable import Effects
@testable import EngineCore
@testable import Game
@testable import Materials
@testable import MetalRenderer
@testable import Physics
@testable import Plants

/// Scene files (SceneFile.swift): written and read back the same, another version a miss, and what one places in a
/// scene (Scene.place) where it says.
final class SceneFileTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("scenefile-\(UUID().uuidString).scene")
    }

    private var sample: SceneFile {
        var camera = Camera()
        camera.position = [1, 2, 3]
        camera.yaw = 0.4
        camera.pitch = -0.2
        return SceneFile(
            objects: [
                SceneFile.Object(asset: "prefab:box", name: "Table", position: [0, 0.4, -2], scale: [1.6, 0.8, 0.9], material: "wood"),
                SceneFile.Object(asset: "prefab:ball", name: "Lamp", parent: 0, position: [0, 0.6, 0],
                                 rotation: simd_quatf(angle: 0.5, axis: [0, 1, 0]), scale: [0.2, 0.2, 0.2]),
            ],
            lights: [SceneFile.Light(kind: .spot, name: "Spot", position: [0, 3, 0], color: [5, 4, 3], size: [0.1, 0.3, 0.5, 0])],
            generators: [SceneFile.Generator(name: "stalls", seed: 42, parameters: [12, 0.5])],
            camera: camera)
    }

    func testWrittenAndReadBackTheSame() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = sample
        try file.write(to: url)
        let read = try XCTUnwrap(SceneFile(url: url))
        XCTAssertEqual(read.objects, file.objects)
        XCTAssertEqual(read.lights, file.lights)
        XCTAssertEqual(read.generators, file.generators)
        XCTAssertEqual(read.camera?.position, file.camera?.position)
        XCTAssertEqual(read.camera?.yaw, file.camera?.yaw)
        XCTAssertEqual(read.camera?.pitch, file.camera?.pitch)
    }

    /// A file of another version (or not a scene's) is no file: the scene builds from code.
    func testAnotherVersionIsAMiss() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var writer = SectionFile.Writer()
        writer.add(SectionFile.id("objs"), [Float](repeating: 0, count: 20))
        try writer.write(to: url, key: "scene/0")
        XCTAssertNil(SceneFile(url: url))
        XCTAssertNil(SceneFile(url: temporaryURL()))
    }

    /// Its objects in the scene: each by its asset at its world transform (its parent's applied), under its name.
    func testPlacedWhereItSays() throws {
        let scene = Scene(SceneSettings()) { scene in
            scene.nameMaterial("wood", scene.addMaterial(albedo: [0.5, 0.3, 0.2]))
            scene.place(self.sample)
        }
        let placed = try XCTUnwrap(scene.placed)
        XCTAssertEqual(placed.instances.map(\.count), [1, 1])
        let table = scene.instances[placed.instances[0][0]], lamp = scene.instances[placed.instances[1][0]]
        XCTAssertEqual(table.material, 0)
        let lampAt = SIMD3(lamp.transform.columns.3.x, lamp.transform.columns.3.y, lamp.transform.columns.3.z)
        XCTAssertEqual(lampAt.y, 0.4 + 0.6 * 0.8, accuracy: 1e-5, "under the table: its scale applies")
        XCTAssertEqual(placed.object(of: placed.instances[1][0]), 1)
        XCTAssertEqual(scene.lights.count, 1)
        XCTAssertEqual(scene.defaultCamera.position, [1, 2, 3])
    }
}
