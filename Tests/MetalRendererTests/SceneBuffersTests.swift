import XCTest
import Metal
import simd
@testable import MetalRenderer

/// A scene on the GPU (SceneBuffers.swift): borrowed meshes, a still scene's one set of instances, and Metal's
/// per-mesh structures handed on from one scene to the next.
final class SceneBuffersTests: XCTestCase {
    private func quad(_ y: Float) -> MeshGeometry {
        ([[0, y, 0], [1, y, 0], [1, y, 1], [0, y, 1]], [SIMD3<Float>](repeating: [0, 1, 0], count: 4), [0, 1, 2, 0, 2, 3])
    }

    /// Two meshes in the scene's arrays with a borrowed one added between them, an instance of each.
    private func scene(borrowedName: String = "a tile's chunk", moving: Bool = false) -> Scene {
        Scene(SceneSettings(kind: .cornell)) { scene in
            let material = scene.addMaterial(albedo: [0.5, 0.5, 0.5])
            scene.addInstance(scene.addMesh(self.quad(0)), material, matrix_identity_float4x4)
            let borrowed = Scene.BorrowedMesh(positions: .made([[0, 5, 0], [2, 5, 0], [2, 5, 2], [0, 5, 2], [1, 6, 1]]),
                                              normals: .made([SIMD3<Float>](repeating: [0, 1, 0], count: 5)),
                                              uvs: .made((0..<5).map { SIMD2(Float($0), 0.5) }),
                                              indices: .made([0, 1, 2, 0, 2, 3, 0, 1, 4]), materials: .made([0, 1, 1]))
            let mesh = scene.addMesh(borrowing: borrowed, bounds: AABB(lo: [0, 5, 0], hi: [2, 6, 2]), name: borrowedName)
            scene.addInstance(mesh, material, translate([10, 0, 0]))
            _ = scene.addMaterial(albedo: [1, 0, 0])   // the borrowed mesh's second material
            scene.addInstance(scene.addMesh(self.quad(1)), material, translate([0, 0, 3]),
                              animation: moving ? { t in translate([0, t, 3]) } : nil)
        }
    }

    private func contents<T>(_ buffer: MTLBuffer, _ count: Int) -> [T] {
        Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: T.self, capacity: count), count: count))
    }

    func testBorrowedMeshesComeAfterTheArrays() throws {
        let scene = scene()
        XCTAssertEqual(scene.positions.count, 8)
        XCTAssertEqual(scene.vertexCount, 13)
        XCTAssertEqual(scene.indexCount, 21)
        XCTAssertEqual(scene.meshes.map(\.firstIndex), [0, 12, 6], "the borrowed mesh's indices follow the arrays'")
        XCTAssertEqual(scene.meshes.map(\.indexCount), [6, 9, 6])
        XCTAssertTrue(scene.hasMaterialOffsets)
        XCTAssertEqual(scene.lightTypeMask & 0x0400_0000, 0x0400_0000)
        XCTAssertEqual(scene.meshNames, [1: "a tile's chunk"])
        XCTAssertTrue(scene.isStill)
        XCTAssertFalse(self.scene(moving: true).isStill)
        XCTAssertEqual(scene.localBounds(mesh: 1).hi, [2, 6, 2])

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let buffers = try SceneBuffers(device: device, queue: queue, scene: scene, options: .init(rayTracer: .custom, api: .metal3, slots: 3))
        let positions: [SIMD3<Float>] = contents(buffers.positions, 13)
        XCTAssertEqual(Array(positions[..<8]), scene.positions)
        XCTAssertEqual(positions[12], [1, 6, 1])
        let uvs: [SIMD2<Float>] = contents(buffers.uvs, 13)
        XCTAssertEqual(uvs[9], [1, 0.5])
        let indices: [UInt32] = contents(buffers.indices, 21)
        XCTAssertEqual(Array(indices[..<12]), scene.indices)
        XCTAssertEqual(Array(indices[12...]), [8, 9, 10, 8, 10, 11, 8, 9, 12], "the borrowed mesh's indices, as the scene's")
        let offsets: [UInt8] = contents(buffers.triangleMaterials, 7)
        XCTAssertEqual(offsets, [0, 0, 0, 0, 0, 1, 1])

        // A still scene: one set of instance records, written.
        XCTAssertTrue(buffers.still)
        XCTAssertTrue(buffers.instanceData[0] === buffers.instanceData[2])
        let records: [GPUInstanceData] = contents(buffers.instanceData[0], 3)
        XCTAssertEqual(records.map(\.meshIndex), [0, 1, 2])
        XCTAssertEqual(records[1].transform.columns.3.x, 10)
        // One that moves: a set per frame slot, for the frames to write.
        let moving = try SceneBuffers(device: device, queue: queue, scene: self.scene(moving: true),
                                      options: .init(rayTracer: .custom, api: .metal3, slots: 3))
        XCTAssertFalse(moving.still)
        XCTAssertFalse(moving.instanceData[0] === moving.instanceData[1])

        // The custom tracer's trees over the buffers are the trees over the same meshes in arrays.
        let all: [SIMD3<Float>] = contents(buffers.positions, 13)
        let fromArrays = BVHBuilder.buildBLAS(positions: all, indices: indices, meshes: scene.meshes)
        let tracer = try CustomRayTracer(device: device, scene: scene, geometry: buffers, slots: 3)
        let triangles: [SIMD4<Float>] = contents(tracer.triangles, fromArrays.triangles.count)
        XCTAssertEqual(triangles.map(\.w.bitPattern), fromArrays.triangles.map(\.w.bitPattern))
        XCTAssertEqual(triangles.map { SIMD3($0.x, $0.y, $0.z) }, fromArrays.triangles.map { SIMD3($0.x, $0.y, $0.z) })
        XCTAssertThrowsError(try CustomRayTracer(device: device, scene: scene, slots: 3), "borrowed meshes, and no buffers to read them from")

        scene.releaseGeometry()
        XCTAssertTrue(scene.positions.isEmpty && scene.borrowed.isEmpty && scene.geometryReleased)
        XCTAssertEqual(scene.lightTypeMask & 0x0400_0000, 0x0400_0000, "what the shaders are compiled for stays")
        XCTAssertEqual(scene.meshes.count, 3)
    }

    /// Metal's tracer: a named mesh's structure is the last scene's; a still scene has one structure over its
    /// instances, built with the buffers, and one that moves a structure per frame slot.
    func testNamedMeshesKeepTheirStructures() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        try XCTSkipUnless(device.supportsRaytracing, "no ray tracing on this GPU")
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var options = SceneBuffers.Options(rayTracer: .metal, api: .metal3, slots: 3)
        let first = try SceneBuffers(device: device, queue: queue, scene: scene(), options: options)
        XCTAssertEqual(first.primitives.count, 3)
        XCTAssertEqual(Array(first.namedPrimitives.keys), ["a tile's chunk"])
        XCTAssertTrue(first.namedPrimitives["a tile's chunk"] === first.primitives[1])
        XCTAssertTrue(first.still)
        XCTAssertEqual(first.instanceStructures.count, 3)
        XCTAssertTrue(first.instanceStructures[0] === first.instanceStructures[2])
        XCTAssertTrue(first.instanceScratch.isEmpty, "built, and not to be built again")
        XCTAssertGreaterThan(first.megabytes.primitives, 0)

        options.known = first.namedPrimitives
        let second = try SceneBuffers(device: device, queue: queue, scene: scene(), options: options)
        XCTAssertTrue(second.primitives[1] === first.primitives[1], "the named mesh's structure is handed on")
        XCTAssertFalse(second.primitives[0] === first.primitives[0])
        let other = try SceneBuffers(device: device, queue: queue, scene: scene(borrowedName: "another chunk"), options: options)
        XCTAssertFalse(other.primitives[1] === first.primitives[1])

        let moving = try SceneBuffers(device: device, queue: queue, scene: scene(moving: true), options: options)
        XCTAssertFalse(moving.still)
        XCTAssertFalse(moving.instanceStructures[0] === moving.instanceStructures[1])
        XCTAssertEqual(moving.instanceScratch.count, 3)
        XCTAssertFalse(moving.instanceDescriptors[0] === moving.instanceDescriptors[1])
    }

    /// The crowd's pose slots: a structure each for the frames to refit, the size of its character's first pose's
    /// (whose tree it is: only that one is built). Skipped where Assets/Characters isn't there.
    func testEveryPoseHasAStructureOfItsOwn() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        try XCTSkipUnless(device.supportsRaytracing, "no ray tracing on this GPU")
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let scene = Scene(SceneSettings(kind: .crowd, characters: 40, poses: 24))
        guard let crowd = scene.crowd else { throw XCTSkip("no characters in \(CharacterLibrary.directory.path)") }
        XCTAssertEqual(crowd.slots.count, 24)
        let buffers = try SceneBuffers(device: device, queue: queue, scene: scene, options: .init(rayTracer: .metal, api: .metal3, slots: 3))
        let refit = try XCTUnwrap(buffers.primitiveRefit)
        XCTAssertEqual(refit.structures.count, 24)
        XCTAssertEqual(Set(refit.structures.map { ObjectIdentifier($0) }).count, 24)
        for (i, slot) in crowd.slots.enumerated() {
            XCTAssertTrue(refit.structures[i] === buffers.primitives[slot.mesh])
            XCTAssertEqual(refit.structures[i].size, refit.structures[crowd.parts[slot.part].firstSlot].size)
            XCTAssertFalse(buffers.primitives[slot.mesh] === buffers.primitives[crowd.parts[slot.part].mesh], "not the bind pose's")
        }
    }

    func testTheSameWorld() {
        var a = SceneSettings(kind: .world), b = SceneSettings(kind: .world)
        a.worldTile = SIMD2(3, 4)
        b.worldAnchor = SIMD2(8, 0)
        XCTAssertTrue(a.isSameWorld(as: b))
        b.seed = 7
        XCTAssertFalse(a.isSameWorld(as: b))
        XCTAssertFalse(SceneSettings(kind: .forest).isSameWorld(as: SceneSettings(kind: .forest)))
    }
}
