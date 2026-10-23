import XCTest
import simd
@testable import EngineCore
@testable import Game
@testable import MetalRenderer
@testable import Physics

/// Phase 4: the crash director's watch for the hit (CarDirector.swift) and the cameras (CarCameras.swift).
final class CarCameraTests: XCTestCase {
    /// A world with a floor, a civic at `speed` m/s toward +z, and a wall whose face is at `wall` (m), if any.
    private func world(speed: Float = 0, wall: Float? = nil) -> PhysicsWorld {
        let w = PhysicsWorld(substeps: 16)
        w.addPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        if let wall {
            w.addStatic(sdf: 90, SDFShape(.box(halfExtents: [6, 1.5, 0.5])), transform: translate([0, 1.5, wall + 0.5]), friction: 0.6, restitution: 0.1)
        }
        w.addCar(CarBlueprint(.preset(.civic)), transform: matrix_identity_float4x4, rimSDF: 100, wheelInstances: [0, 0, 0, 0], velocity: [0, 0, speed])
        w.finish()
        return w
    }

    /// The director finds the wall demo's hit within a tenth of a second of the car's front first crushing.
    func testTheDirectorFindsTheHit() {
        let w = world(speed: 50 / 3.6, wall: 10)
        var director = CarDirector()
        var found: Float?, crushed: Float?
        while w.time < 2 && (found == nil || crushed == nil) {
            w.advance(to: w.time + PhysicsWorld.stepLength * 1.5)
            let t = w.carTelemetry(0)
            if crushed == nil && t.frontCrush > 0.01 { crushed = w.time }
            if found == nil && director.watch(t, time: w.time) { found = w.time }
        }
        let hit = try! XCTUnwrap(found), crush = try! XCTUnwrap(crushed)
        XCTAssertEqual(hit, crush, accuracy: 0.1)
        XCTAssertEqual(director.hit?.time, hit)
        XCTAssertLessThan(abs(director.hit!.way.z - 1), 0.05, "its way: toward the wall")
    }

    /// Each camera's eye is finite: the cockpit's inside the car, the hood's above it, the chase's behind it, the
    /// orbit's at its radius, the trackside's ahead.
    func testTheCamerasArePlacedRoundTheCar() {
        let w = world()
        w.advance(to: 1)
        let t = w.carTelemetry(0), spec = CarSpec.preset(.civic)
        for mode in CarCamera.allCases {
            var rig = CarCameraRig()
            rig.mode = mode
            let (eye, look) = rig.place(t, spec: spec, dt: 1 / 60)
            XCTAssertTrue((0..<3).allSatisfy { eye[$0].isFinite && look[$0].isFinite }, "\(mode)")
            XCTAssertEqual(simd_length(look), 1, accuracy: 1e-4, "\(mode)")
            let local = eye - t.position, z = dot(local, t.forward), y = eye.y
            switch mode {
            case .chase: XCTAssertLessThan(z, -5)
            case .hood: XCTAssertGreaterThan(z, spec.wheelbase / 2 - 0.5); XCTAssertGreaterThan(y, spec.topHeight(spec.wheelbase / 2 - 0.15))
            case .cockpit:
                XCTAssertLessThan(abs(z), spec.wheelbase / 2)
                XCTAssertLessThan(y, spec.roof)
                XCTAssertGreaterThan(dot(local, cross(t.up, t.forward)), 0.2, "on the driver's side, left")
            case .orbit: XCTAssertEqual(simd_length(SIMD2(eye.x - t.centre.x, eye.z - t.centre.z)), CarCameraRig.orbitRadius, accuracy: 0.01)
            case .trackside: XCTAssertGreaterThan(z, 10)
            }
        }
    }
}
