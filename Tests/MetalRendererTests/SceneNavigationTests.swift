import AppKit
import XCTest
import simd
@testable import MetalRenderer

/// The scene view's navigation (SceneNavigation.swift): the camera about its pivot, and the scene gizmo.
final class SceneNavigationTests: XCTestCase {
    private func camera(yaw: Float = 0.4, pitch: Float = -0.3) -> Camera {
        var c = Camera()
        c.position = [1, 2, 3]
        c.yaw = yaw
        c.pitch = pitch
        return c
    }

    private func assertNear(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ accuracy: Float = 1e-4, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_distance(a, b), accuracy, "\(a) vs \(b) \(message)", file: file, line: line)
    }

    func testOrbitKeepsThePivot() {
        var c = camera()
        let p = c.pivot(at: 5)
        c.orbit(dx: 120, dy: -40, about: p)
        XCTAssertEqual(simd_distance(c.position, p.target), 5, accuracy: 1e-4, "at the pivot's distance")
        assertNear(c.position + c.forward * 5, p.target, 1e-4, "looking at it")
        XCTAssertEqual(c.yaw, 0.4 + 120 * Camera.turnRate, accuracy: 1e-6)
        c.orbit(dx: 0, dy: -10_000, about: p)
        XCTAssertEqual(c.pitch, Camera.pitchLimit, accuracy: 1e-6, "up to just short of straight down on it")
        XCTAssertTrue(c.right.x.isFinite && abs(simd_length(c.right) - 1) < 1e-3, "right stays defined there")
    }

    func testLookMovesThePivotAlong() {
        var c = camera()
        let p = c.look(dx: 50, dy: 20, pivot: c.pivot(at: 6))
        XCTAssertEqual(c.position, [1, 2, 3], "it turns where it is")
        XCTAssertEqual(p.distance, 6)
        assertNear(p.target, c.position + c.forward * 6)
    }

    func testPanMovesCameraAndPivotTogether() {
        var c = camera()
        let before = c.pivot(at: 4), start = c.position
        let p = c.pan(by: [0.1, -0.05], pivot: before, aspect: 1.6)
        assertNear(c.position - start, p.target - before.target, 1e-5, "the same move")
        XCTAssertEqual(p.distance, 4)
        // Across the view: a tenth of the view's width at the pivot's depth, to the left (the scene follows the cursor).
        let width = 2 * tan(c.fovY / 2) * 1.6 * 4
        XCTAssertEqual(dot(c.position - start, c.right), -0.1 * width, accuracy: 1e-4)
        XCTAssertEqual(dot(c.position - start, c.up), -0.05 * 2 * tan(c.fovY / 2) * 4, accuracy: 1e-4,
                       "the cursor went up: the camera goes down")
    }

    func testDollyIsClamped() {
        var c = camera()
        var p = c.dolly(by: 0.5, pivot: c.pivot(at: 4))
        XCTAssertEqual(p.distance, 2)
        assertNear(c.position + c.forward * 2, p.target)
        p = c.dolly(by: 1e-6, pivot: p)
        XCTAssertEqual(p.distance, Camera.pivotDistances.lowerBound)
        p = c.dolly(by: 1e9, pivot: p)
        XCTAssertEqual(p.distance, Camera.pivotDistances.upperBound)
    }

    func testSnappedViews() {
        for axis in ViewAxis.allCases {
            var c = camera()
            (c.yaw, c.pitch) = Camera.angles(viewing: axis, yaw: c.yaw)
            XCTAssertGreaterThan(dot(c.forward, -axis.direction), 0.9998, "\(axis) looks back along its axis")
            XCTAssertEqual(ViewAxis.snapped(c.forward), axis)
            XCTAssertEqual(SceneGizmo.title(yaw: c.yaw, pitch: c.pitch), axis.title)
            XCTAssertTrue(c.right.x.isFinite && c.right.z.isFinite, "\(axis): right is defined")
        }
        XCTAssertEqual(SceneGizmo.title(yaw: 0.4, pitch: -0.3), "Persp")
        // The default camera looks down -Z: the front view.
        XCTAssertEqual(ViewAxis.snapped(Camera(yaw: 0, pitch: 0).forward), .front)
    }

    func testSteps() {
        let step = Float.pi / 4
        var a = Camera.stepped(yaw: 0.1, pitch: -0.2, yawSteps: 1, pitchSteps: 0)
        XCTAssertEqual(a.yaw, step, accuracy: 1e-6, "from the nearest 45° view, one on")
        XCTAssertEqual(a.pitch, 0, accuracy: 1e-6)
        a = Camera.stepped(yaw: a.yaw, pitch: a.pitch, yawSteps: -3, pitchSteps: -5)
        XCTAssertEqual(a.yaw, -2 * step, accuracy: 1e-6)
        XCTAssertEqual(a.pitch, -Camera.pitchLimit, accuracy: 1e-6, "no further than straight down")
    }

    func testGizmoHitsTheFrontCone() {
        // From the front (looking down -Z), +Z points at the view and -Z away: both at the centre; +Z is hit.
        XCTAssertEqual(SceneGizmo.hit(.zero, yaw: 0, pitch: 0), .front)
        // +X is to the right, at an arm's length.
        XCTAssertEqual(SceneGizmo.hit([SceneGizmo.reach, 0], yaw: 0, pitch: 0), .right)
        XCTAssertEqual(SceneGizmo.hit([0, SceneGizmo.reach], yaw: 0, pitch: 0), .top)
        XCTAssertEqual(SceneGizmo.hit([0, -SceneGizmo.reach], yaw: 0, pitch: 0), .bottom)
        XCTAssertNil(SceneGizmo.hit([SceneGizmo.reach * 0.6, SceneGizmo.reach * 0.6], yaw: 0, pitch: 0), "between the arms")
        // Back to front: the last arm drawn is the one most towards the view.
        let arms = SceneGizmo.layout(yaw: 0.5, pitch: -0.4)
        XCTAssertEqual(arms.map(\.depth), arms.map(\.depth).sorted(by: >))
    }

    /// SCENE_GIZMO_PNG=<folder>: the gizmo drawn offscreen from a few views.
    func testGizmoPictures() throws {
        guard let path = ProcessInfo.processInfo.environment["SCENE_GIZMO_PNG"] else { throw XCTSkip("SCENE_GIZMO_PNG not set") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let views: [(String, Float, Float)] = [("persp", 0.6, -0.4), ("front", 0, 0), ("top", 0, -Camera.pitchLimit),
                                               ("right", -.pi / 2, 0), ("below", 2.4, 0.7)]
        for (name, yaw, pitch) in views {
            let gizmo = SceneGizmo()
            gizmo.frame = NSRect(x: 0, y: 0, width: SceneGizmo.width, height: SceneGizmo.width + SceneGizmo.labelHeight)
            gizmo.show(yaw: yaw, pitch: pitch)
            let rep = try XCTUnwrap(gizmo.bitmapImageRepForCachingDisplay(in: gizmo.bounds))
            gizmo.cacheDisplay(in: gizmo.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("gizmo-\(name).png"))
        }
    }
}

private extension Camera {
    init(yaw: Float, pitch: Float) {
        self.init()
        self.yaw = yaw
        self.pitch = pitch
    }
}
