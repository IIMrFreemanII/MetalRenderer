import XCTest
import simd
@testable import MetalRenderer

/// The random rooms the neural denoiser's dataset is made of (Scene+Training.swift): a clip's noisy frames and its
/// references are rendered in two runs, so a seed must always make the same room, and different seeds different ones.
final class TrainingSceneTests: XCTestCase {
    /// Rooms take their models from the gallery's: only the small one here (a 2.6 MB model instead of up to 80 MB).
    override func setUp() { setenv("METALRENDERER_GALLERY", "fiery demon", 1) }
    override func tearDown() { unsetenv("METALRENDERER_GALLERY") }

    private func room(_ seed: Int) -> Scene {
        var s = SceneSettings(kind: .randomRoom)
        s.seed = seed
        return Scene(s)
    }

    func testASeedAlwaysMakesTheSameRoom() {
        for seed in [100, 101] {
            let a = room(seed), b = room(seed)
            XCTAssertEqual(a.instances.count, b.instances.count, "seed \(seed)")
            XCTAssertEqual(a.lights.count, b.lights.count, "seed \(seed)")
            XCTAssertEqual(a.materials.count, b.materials.count, "seed \(seed)")
            XCTAssertEqual(a.instances.map(\.transform), b.instances.map(\.transform), "seed \(seed)")
            XCTAssertEqual(a.defaultCamera.position, b.defaultCamera.position, "seed \(seed)")
        }
    }

    func testSeedsMakeDifferentRooms() {
        let rooms = (100..<104).map(room)
        let cameras = Set(rooms.map { "\($0.defaultCamera.position)" })
        XCTAssertEqual(cameras.count, rooms.count)
        XCTAssertGreaterThan(Set(rooms.map(\.instances.count)).count, 1)
    }

    /// The camera starts inside the room (its walls are the first instances: floor, back, left, right).
    func testTheCameraIsInside() {
        for seed in 100..<105 {
            let scene = room(seed), p = scene.defaultCamera.position
            let floor = scene.instances[0].transform
            let halfWidth = floor.columns.0.x / 2, halfDepth = floor.columns.2.z / 2
            XCTAssertLessThan(abs(p.x), halfWidth - 2, "seed \(seed)")
            XCTAssertLessThan(abs(p.z), halfDepth, "seed \(seed)")
            XCTAssertGreaterThan(p.y, 1)
        }
    }
}
