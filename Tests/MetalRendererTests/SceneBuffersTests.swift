import XCTest
import Metal
import simd
@testable import MetalRenderer

/// A scene on the GPU (SceneBuffers.swift): borrowed meshes in buffers of their own, a still scene's one set of
/// instances, and the blocks and Metal's per-mesh structures handed on from one scene to the next.
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

    func testBorrowedMeshesAreInBuffersOfTheirOwn() throws {
        let scene = scene()
        XCTAssertEqual(scene.positions.count, 8)
        XCTAssertEqual(scene.indices.count, 12)
        XCTAssertEqual(scene.meshes.map(\.firstIndex), [0, 0, 6], "the borrowed mesh's indices are its own")
        XCTAssertEqual(scene.meshes.map(\.indexCount), [6, 9, 6])
        XCTAssertEqual(scene.meshes.map(\.vertexCount), [0, 5, 0])
        XCTAssertTrue(scene.hasMaterialOffsets && scene.hasBorrowedMeshes)
        XCTAssertEqual(scene.lightTypeMask & 0x0600_0000, 0x0600_0000, "MULTI_MATERIAL and STREAMED")
        XCTAssertEqual(self.scene().lightTypeMask, scene.lightTypeMask)
        XCTAssertEqual(scene.meshNames, [1: "a tile's chunk"])
        XCTAssertTrue(scene.isStill)
        XCTAssertFalse(self.scene(moving: true).isStill)
        XCTAssertEqual(scene.localBounds(mesh: 1).hi, [2, 6, 2])

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var options = SceneBuffers.Options(rayTracer: .custom, api: .metal3, slots: 3)
        let buffers = try SceneBuffers(device: device, queue: queue, scene: scene, options: options)
        // The arrays' meshes are in the scene's buffers, with a material offset (0) for each of their triangles.
        XCTAssertEqual(contents(buffers.positions, 8), scene.positions)
        XCTAssertEqual(contents(buffers.indices, 12), scene.indices)
        XCTAssertEqual(contents(buffers.triangleMaterials, 4), [UInt8](repeating: 0, count: 4))
        // The borrowed one is in its block: its arrays one after the other, its indices as they were.
        XCTAssertEqual(buffers.blocks.map { $0 == nil }, [true, false, true])
        let block = try XCTUnwrap(buffers.blocks[1])
        XCTAssertEqual([block.vertexCount, block.indexCount, block.indexOffset], [5, 9, 200])
        XCTAssertEqual(block.name, "a tile's chunk")
        let vertices: [SIMD3<Float>] = contents(block.geometry, 10)
        XCTAssertEqual(vertices[4], [1, 6, 1])
        XCTAssertEqual(vertices[9], [0, 1, 0], "the normals follow the positions")
        let raw = block.geometry.contents()
        XCTAssertEqual(Array(UnsafeBufferPointer(start: (raw + 160).bindMemory(to: SIMD2<Float>.self, capacity: 5), count: 5))[1], [1, 0.5])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: (raw + 200).bindMemory(to: UInt32.self, capacity: 9), count: 9)), [0, 1, 2, 0, 2, 3, 0, 1, 4])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: (raw + 236).bindMemory(to: UInt8.self, capacity: 3), count: 3)), [0, 1, 1])
        let table: [GPUMesh] = contents(buffers.meshes, 3)
        XCTAssertEqual(table.map(\.block), [0, block.geometry.gpuAddress, 0], "the mesh table says where it is")
        XCTAssertTrue(buffers.buffers.contains { $0 === block.geometry })

        // A still scene: one set of instance records, written.
        XCTAssertTrue(buffers.still)
        XCTAssertTrue(buffers.instanceData[0] === buffers.instanceData[2])
        let records: [GPUInstanceData] = contents(buffers.instanceData[0], 3)
        XCTAssertEqual(records.map(\.meshIndex), [0, 1, 2])
        XCTAssertEqual(records[1].transform.columns.3.x, 10)
        // One that moves: a set per frame slot, for the frames to write.
        let moving = try SceneBuffers(device: device, queue: queue, scene: self.scene(moving: true), options: options)
        XCTAssertFalse(moving.still)
        XCTAssertFalse(moving.instanceData[0] === moving.instanceData[1])
        XCTAssertFalse(moving.blocks[1] === block, "not handed the block: its own")

        // The next scene with a mesh of that name takes the block; a mesh of another name gets a new one.
        options.blocks = buffers.namedBlocks
        XCTAssertEqual(Array(options.blocks.keys), ["a tile's chunk"])
        let next = try SceneBuffers(device: device, queue: queue, scene: self.scene(), options: options)
        XCTAssertTrue(next.blocks[1] === block)
        let other = try SceneBuffers(device: device, queue: queue, scene: self.scene(borrowedName: "another chunk"), options: options)
        XCTAssertFalse(other.blocks[1] === block)

        // The custom tracer: the arrays' meshes' trees in its buffers, the borrowed mesh's with its block: the tree
        // over the same triangles in arrays, its root first and its triangles after its nodes, built once.
        XCTAssertFalse(block.hasTree)
        let tracer = try CustomRayTracer(device: device, scene: scene, geometry: buffers, slots: 3)
        XCTAssertTrue(block.hasTree)
        let arrays = BVHBuilder.buildBLAS(positions: scene.positions, indices: scene.indices,
                                          meshes: [scene.meshes[0], GPUMesh(firstIndex: 0, indexCount: 0), scene.meshes[2]])
        XCTAssertEqual(contents(tracer.triangles, 12), arrays.triangles)
        let tree = try block.tree(device: device, cutout: 0)
        XCTAssertTrue(tracer.buffers.contains { $0 === tree.buffer })
        let alone = BVHBuilder.buildBLAS(positions: Array(vertices[..<5]), indices: [0, 1, 2, 0, 2, 3, 0, 1, 4],
                                         meshes: [GPUMesh(firstIndex: 0, indexCount: 9)])
        XCTAssertEqual([tree.nodeCount, tree.triangles, tree.depth], [3, 3, alone.maxDepth], "its node, and two to a multiple of three")
        XCTAssertEqual(alone.roots, [0])
        XCTAssertEqual(tree.bounds.hi, [2, 6, 2])
        // The same node, but its leaf counts the triangles from the buffer's start: 3 nodes are as long as 4 triangles.
        let nodes: [BVHNode] = contents(tree.buffer, 3)
        XCTAssertEqual(alone.nodes.count, 1)
        XCTAssertEqual([nodes[0].ref(0), nodes[0].ref(1)], [alone.nodes[0].ref(0) + 4, alone.nodes[0].ref(1) + 4])
        XCTAssertEqual([nodes[0].lo(0), nodes[0].hi(0)], [alone.nodes[0].lo(0), alone.nodes[0].hi(0)])
        let triangles = UnsafeBufferPointer(start: (tree.buffer.contents() + tree.nodeCount * MemoryLayout<BVHNode>.stride)
            .bindMemory(to: SIMD4<Float>.self, capacity: 9), count: 9)
        XCTAssertEqual(triangles.map(\.w.bitPattern), alone.triangles.map(\.w.bitPattern))
        XCTAssertEqual(triangles.map { SIMD3($0.x, $0.y, $0.z) }, alone.triangles.map { SIMD3($0.x, $0.y, $0.z) })
        _ = try CustomRayTracer(device: device, scene: self.scene(), geometry: next, slots: 3)
        XCTAssertTrue(try block.tree(device: device, cutout: 0).buffer === tree.buffer, "the next scene's tracer takes the tree")
        XCTAssertThrowsError(try CustomRayTracer(device: device, scene: scene, slots: 3), "borrowed meshes, and no buffers to read them from")

        scene.releaseGeometry()
        XCTAssertTrue(scene.positions.isEmpty && scene.borrowed.isEmpty && scene.geometryReleased)
        XCTAssertEqual(scene.lightTypeMask & 0x0600_0000, 0x0600_0000, "what the shaders are compiled for stays")
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
