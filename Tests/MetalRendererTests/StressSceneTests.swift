import XCTest
import simd
@testable import MetalRenderer

/// The stress building (Scene+Stress.swift), on the CPU: its knobs mean what the benchmarks' names say.
final class StressSceneTests: XCTestCase {
    private func scene(objects: Int, lights: Int) -> Scene {
        Scene(SceneSettings(kind: .stress, objects: objects, lights: lights))
    }

    /// Everything but the lights' visible shapes.
    private func geometry(_ s: Scene) -> [Scene.Instance] { s.instances.filter { $0.mask != Scene.maskLights } }

    func testItHasExactlyTheLightsAskedFor() {
        for (objects, lights) in [(0, 1), (400, 32), (100, 300), (50, 4096)] {
            XCTAssertEqual(scene(objects: objects, lights: lights).lights.count, lights, "\(objects) objects, \(lights) lights")
        }
    }

    func testEachObjectIsOneInstance() {
        let empty = geometry(scene(objects: 0, lights: 32)).count
        for objects in [1, 400, 2000] {
            XCTAssertEqual(geometry(scene(objects: objects, lights: 32)).count - empty, objects, "\(objects) objects")
        }
    }

    func testMostPropsMoveAtTheDefaultSize() {
        let still = geometry(scene(objects: 0, lights: 32)).filter(\.isStatic).count
        let s = scene(objects: 400, lights: 32)
        let moving = geometry(s).filter { !$0.isStatic }.count
        let props = geometry(s).count - still
        XCTAssertEqual(props, 400)
        XCTAssertGreaterThan(Float(moving) / Float(props), 0.5)
        XCTAssertLessThan(Float(moving) / Float(props), 0.75)
    }

    func testTheSameSettingsBuildTheSameScene() {
        let a = scene(objects: 400, lights: 32), b = scene(objects: 400, lights: 32)
        a.update(time: 5)
        b.update(time: 5)
        XCTAssertEqual(a.instances.map(\.transform), b.instances.map(\.transform))
        XCTAssertEqual(a.lights.map(\.current.position), b.lights.map(\.current.position))
    }

    func testTheLightsStayInsideTheBuilding() {
        let s = scene(objects: 400, lights: 256)
        for t in stride(from: Float(0), through: 30, by: 1.5) {
            s.update(time: t)
            for l in s.lights {
                let p = l.current.position
                XCTAssertTrue(abs(p.x) < 20 && abs(p.z) < 20 && p.y > 0 && p.y < 8, "a light at \(p), t = \(t)")
            }
        }
    }
}
