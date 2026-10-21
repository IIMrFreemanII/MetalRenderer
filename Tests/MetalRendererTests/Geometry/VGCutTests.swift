import XCTest
import Metal
import simd
@testable import Characters
@testable import Editors
@testable import Effects
@testable import EngineCore
@testable import Game
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
}
