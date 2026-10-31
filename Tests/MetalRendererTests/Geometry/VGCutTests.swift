import XCTest
import Metal
import simd
@testable import Buildings
@testable import Characters
@testable import Editors
@testable import Effects
@testable import EngineCore
@testable import Game
@testable import Landscape
@testable import Materials
@testable import MetalRenderer
@testable import Physics
@testable import Plants

/// Virtual geometry's cut as the rays meet it: the per-instance BLAS over the CPU's cut (VirtualBLAS.selection).
final class VGCutTests: XCTestCase {
    /// VirtualBLAS on Metal: the first frame's cut (made at once) is a structure over exactly the cut's triangles, laid
    /// out as the shaders read them (VGBlas: corners, then the debug views' IDs in the second and third corners' w).
    func testTheCutsBLASHoldsTheCutsTriangles() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        try XCTSkipUnless(device.supportsRaytracing, "no ray tracing on this GPU")
        let mesh = VGStreamerTests.mesh
        let transform = float4x4(diagonal: [1, 1, 1, 1])
        let blas = try VirtualBLAS(device: device, meshes: [mesh], instances: [(0, 0)], slots: 1)
        let instance = Scene.Instance(mesh: -1, material: 0, mask: Scene.maskGeometry, transform: transform, prevTransform: transform,
                                      animation: nil, normalMatrix: transform)
        let camPos = SIMD3<Float>(0, 2, 30)
        blas.update(frame: 1, slot: 0, framesInFlight: 1, camPos: camPos, pixelScale: 400, tau: 1, sceneInstances: [instance])
        let structure = try XCTUnwrap(blas.structures[0], "a structure over the first cut")
        XCTAssertGreaterThan(structure.size, 0)
        let selection = VirtualBLAS.selection(mesh: mesh, groups: 0..<mesh.groups.count, transform: transform, camPos: camPos,
                                              pixelScale: 400, tau: 1).selection
        let expected = selection.reduce(0) { $0 + Int(mesh.clusters[Int($1)].triangles) }
        let entry = blas.table(slot: 0).contents().load(as: VirtualBLAS.Entry.self)
        XCTAssertEqual(Int(entry.triangles), expected)
        let buffer = try XCTUnwrap(blas.resources(slot: 0).compactMap { $0 as? MTLBuffer }.first { $0.gpuAddress == entry.tris })
        let tris = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 3 * expected)
        var clusters = Set<UInt32>()
        for t in 0..<expected {
            clusters.insert(tris[3 * t + 1].w.bitPattern & 0xFF_FFFF)
            let p = SIMD3(tris[3 * t].x, tris[3 * t].y, tris[3 * t].z)
            XCTAssertTrue(all(p .>= mesh.bounds.lo - 1e-3) && all(p .<= mesh.bounds.hi + 1e-3), "triangle \(t) outside the mesh")
        }
        XCTAssertEqual(clusters, Set(selection), "every triangle names its cluster, and every cluster of the cut is there")
        XCTAssertEqual(entry.attrs, entry.tris + UInt64(48 * expected))
    }

    func testChangedTrianglesCountsWhatOnlyOneCutHas() {
        let mesh = VGStreamerTests.mesh
        func triangles(_ c: Int) -> Int { Int(mesh.clusters[c].triangles) }
        XCTAssertEqual(VirtualBLAS.changedTriangles(mesh: mesh, from: [0, 1, 2], to: [0, 1, 2]), 0)
        XCTAssertEqual(VirtualBLAS.changedTriangles(mesh: mesh, from: [0, 1, 2], to: [1, 2, 3]), triangles(0) + triangles(3))
        XCTAssertEqual(VirtualBLAS.changedTriangles(mesh: mesh, from: [], to: [4]), triangles(4))
        XCTAssertEqual(VirtualBLAS.changedTriangles(mesh: mesh, from: [4], to: []), triangles(4))
    }

    func testASmallChangeWaitsAndALargeOneDoesNot() {
        XCTAssertFalse(VirtualBLAS.buildsNow(changed: 9, triangles: 100, waited: 0))
        XCTAssertFalse(VirtualBLAS.buildsNow(changed: 9, triangles: 100, waited: VirtualBLAS.waitPasses - 1))
        XCTAssertTrue(VirtualBLAS.buildsNow(changed: 9, triangles: 100, waited: VirtualBLAS.waitPasses))
        XCTAssertTrue(VirtualBLAS.buildsNow(changed: 10, triangles: 100, waited: 0))
        XCTAssertTrue(VirtualBLAS.buildsNow(changed: 3, triangles: 0, waited: 0), "a cut gone empty")
    }

    /// A cut that waits isn't lost: with the camera then at rest (no pass would look at the instance again if its last
    /// cut still counted), it is built within `waitPasses`.
    func testACutThatWaitedIsBuiltWithTheCameraAtRest() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        try XCTSkipUnless(device.supportsRaytracing, "no ray tracing on this GPU")
        let mesh = VGStreamerTests.mesh
        let transform = float4x4(diagonal: [1, 1, 1, 1])
        func cut(_ z: Float) -> [UInt32] {
            VirtualBLAS.selection(mesh: mesh, groups: 0..<mesh.groups.count, transform: transform, camPos: SIMD3(0, 2, z),
                                  pixelScale: 4000, tau: 1).selection
        }
        func triangles(_ s: [UInt32]) -> Int { s.reduce(0) { $0 + Int(mesh.clusters[Int($1)].triangles) } }
        // A camera whose cut differs from the first one's, by little enough to wait.
        let start: Float = 30
        let first = cut(start)
        let near = try XCTUnwrap(stride(from: start - 0.01, to: 1, by: -0.01).first { z in
            let s = cut(z)
            return s != first && !VirtualBLAS.buildsNow(changed: VirtualBLAS.changedTriangles(mesh: mesh, from: first, to: s),
                                                        triangles: triangles(s), waited: 0)
        }, "no camera with a small change of the cut")
        let blas = try VirtualBLAS(device: device, meshes: [mesh], instances: [(0, 0)], slots: 1)
        let instance = Scene.Instance(mesh: -1, material: 0, mask: Scene.maskGeometry, transform: transform, prevTransform: transform,
                                      animation: nil, normalMatrix: transform)
        func pass(_ z: Float, _ frame: UInt32) {
            blas.update(frame: frame, slot: 0, framesInFlight: 1, camPos: SIMD3(0, 2, z), pixelScale: 4000, tau: 1, sceneInstances: [instance])
            while blas.isBusy { usleep(100) }
        }
        pass(start, 1)
        XCTAssertEqual(blas.stats.rebuilds, 1)
        pass(near, 2)
        XCTAssertEqual(blas.stats.rebuilds, 1, "a small change waits")
        for i in 0...VirtualBLAS.waitPasses { pass(near, UInt32(3 + i)) }
        XCTAssertEqual(blas.stats.rebuilds, 2, "built, once, when it has waited long enough")
        pass(near, 100)   // (swaps it in)
        XCTAssertEqual(Int(blas.table(slot: 0).contents().load(as: VirtualBLAS.Entry.self).triangles), triangles(cut(near)))
    }
}
