import Metal
import XCTest
import simd
@testable import MetalRenderer

/// Lumen's global distance field (LumenGlobalSDF.swift): where its windows are, and which bricks it composes.
final class GlobalSDFTests: XCTestCase {
    func testWindowIsOnABrickAroundTheCamera() {
        for camera: SIMD3<Float> in [[0, 0, 0], [3.37, -1.2, 40.9], [-12.05, 7, -0.01]] {
            let o = LumenGlobalSDF.window(camera: camera, voxel: 0.1)
            XCTAssertEqual(o.x % 8, 0); XCTAssertEqual(o.y % 8, 0); XCTAssertEqual(o.z % 8, 0)
            let cell = SIMD3<Int32>((camera / 0.1).rounded(.down))
            XCTAssertTrue(all(cell .>= o &+ 56) && all(cell .< o &+ 72), "\(camera): the camera's cell near the middle")
        }
    }

    func testScrollingComposesOnlyTheNewSlab() {
        let a = LumenGlobalSDF.window(camera: [0, 0, 0], voxel: 0.1)
        XCTAssertEqual(LumenGlobalSDF.enteringBricks(old: nil, new: a).count, 16 * 16 * 16)
        XCTAssertTrue(LumenGlobalSDF.enteringBricks(old: a, new: a).isEmpty)
        let b = a &+ SIMD3(8, 0, 0)   // a brick along x
        let entering = LumenGlobalSDF.enteringBricks(old: a, new: b)
        XCTAssertEqual(entering.count, 16 * 16)
        XCTAssertTrue(entering.allSatisfy { $0.x == b.x / 8 + 15 })
        XCTAssertEqual(LumenGlobalSDF.enteringBricks(old: a, new: a &+ SIMD3(8 * 40, 0, 0)).count, 16 * 16 * 16, "far: all new")
    }

    func testABoxTouchesItsBricksWithTheBand() {
        let origin = SIMD3<Int32>(-64, -64, -64)   // cells; bricks -8 ..< 8
        let box = AABB(lo: [0.05, 0.05, 0.05], hi: [0.75, 0.15, 0.15])   // inside brick 0 (0.8 m a side)
        let tight = LumenGlobalSDF.bricks(touching: box, voxel: 0.1, band: 0, origin: origin)
        XCTAssertEqual(Set(tight), [SIMD3(0, 0, 0)])
        let banded = LumenGlobalSDF.bricks(touching: box, voxel: 0.1, band: 0.1, origin: origin)
        XCTAssertEqual(banded.count, 3 * 2 * 2, "x from -0.05 to 0.85 m: bricks -1...1; y and z to 0.25 m: -1...0")
        let outside = AABB(lo: [100, 0, 0], hi: [101, 1, 1])
        XCTAssertTrue(LumenGlobalSDF.bricks(touching: outside, voxel: 0.1, band: 0.4, origin: origin).isEmpty)
    }

    func testQueueTakesTheBudgetFinestFirst() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let g = try LumenGlobalSDF(device: device, levels: 3, voxel: 0.1, frameSlots: 1)
        let levels = g.update(camera: .zero, changed: [], everything: false, slot: 0)
        XCTAssertEqual(levels.count, 3)
        XCTAssertEqual(levels[1].voxel.x, 0.2, accuracy: 1e-6)
        XCTAssertEqual(g.dirtyCount, LumenGlobalSDF.budget, "the first frame: the finest level's 4096 bricks")
        XCTAssertFalse(g.isComplete)
        _ = g.update(camera: .zero, changed: [], everything: false, slot: 0)
        _ = g.update(camera: .zero, changed: [], everything: false, slot: 0)
        XCTAssertTrue(g.isComplete)
        _ = g.update(camera: .zero, changed: [], everything: false, slot: 0)
        XCTAssertEqual(g.dirtyCount, 0, "a still scene composes nothing")
        _ = g.update(camera: .zero, changed: [AABB(lo: [0, 0, 0], hi: [0.5, 0.5, 0.5])], everything: false, slot: 0)
        XCTAssertGreaterThan(g.dirtyCount, 0)
        _ = g.update(camera: .zero, changed: [], everything: true, slot: 0)
        XCTAssertEqual(g.dirtyCount, LumenGlobalSDF.budget, "a bake landed: everything again")
    }

    func testLayout() {
        XCTAssertEqual(LumenGlobalSDF.layout(bounds: ([-5, 0, -5], [5, 5, 5]), large: false).levels, 2)
        let city = LumenGlobalSDF.layout(bounds: ([-300, 0, -300], [300, 80, 300]), large: true)
        XCTAssertEqual(city.voxel, 0.2)
        XCTAssertEqual(city.levels, 6)
    }
}
