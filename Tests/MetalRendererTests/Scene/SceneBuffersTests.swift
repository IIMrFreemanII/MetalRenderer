import XCTest
import Metal
import simd
@testable import MetalRenderer

/// A scene on the GPU (SceneBuffers.swift): borrowed meshes in buffers of their own, a still scene's one set of
/// instances, and the blocks (of meshes, of instances) and Metal's per-mesh structures handed on from one scene to
/// the next.
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
        try XCTSkipUnless(device.supportsRaytracing, "no ray tracing on this GPU")
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var options = SceneBuffers.Options(api: .metal3, slots: 3)
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

        scene.releaseGeometry()
        XCTAssertTrue(scene.positions.isEmpty && scene.borrowed.isEmpty && scene.geometryReleased)
        XCTAssertEqual(scene.lightTypeMask & 0x0600_0000, 0x0600_0000, "what the shaders are compiled for stays")
        XCTAssertEqual(scene.meshes.count, 3)
    }

    /// A named mesh's structure is the last scene's; a still scene has one structure over its
    /// instances, built with the buffers, and one that moves a structure per frame slot.
    func testNamedMeshesKeepTheirStructures() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        try XCTSkipUnless(device.supportsRaytracing, "no ray tracing on this GPU")
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var options = SceneBuffers.Options(api: .metal3, slots: 3)
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

    /// Two named meshes with an instance each, and a group of three more instances of them. `made`: called when the
    /// group's instances are asked for.
    private func grouped(group: String = "a tile's trees", made: @escaping () -> Void = {}) -> Scene {
        Scene(SceneSettings(kind: .cornell)) { scene in
            let material = scene.addMaterial(albedo: [0.5, 0.5, 0.5])
            let a = scene.addMesh(self.quad(0), name: "quad a"), b = scene.addMesh(self.quad(1), name: "quad b")
            scene.addInstance(a, material, matrix_identity_float4x4)
            scene.addInstance(b, material, translate([0, 0, 3]))
            scene.addGroup(name: group, count: 3) {
                made()
                return (0..<3).map { i in
                    let m = translate([Float(10 + i), 0, 0])
                    return Scene.Instance(mesh: i == 1 ? b : a, material: material, mask: Scene.maskGeometry, transform: m, prevTransform: m,
                                          animation: nil, normalMatrix: m.inverse.transpose)
                }
            }
        }
    }

    /// A group's instances are made once and go from scene to scene in a block, which keeps their records.
    func testInstanceGroupsGoFromSceneToScene() throws {
        var makes = 0
        let scene = grouped { makes += 1 }
        XCTAssertTrue(scene.hasGroups && scene.isStill)
        XCTAssertEqual(scene.instances.count, 2, "the group's instances are not the scene's own")
        XCTAssertEqual(scene.lightTypeMask & 0x0100_0000, 0x0100_0000, "GROUPED")
        XCTAssertEqual(makes, 0)

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        try XCTSkipUnless(device.supportsRaytracing, "no ray tracing on this GPU")
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var options = SceneBuffers.Options(api: .metal3, slots: 3)
        let first = try SceneBuffers(device: device, queue: queue, scene: scene, options: options)
        XCTAssertEqual(makes, 1)
        XCTAssertEqual(first.instanceCount, 5)
        let block = try XCTUnwrap(first.instanceBlocks.first)
        XCTAssertEqual(block.name, "a tile's trees")
        XCTAssertEqual(block.count, 3)
        let records: [GPUInstanceData] = contents(block.buffer, 3)
        XCTAssertEqual(records.map { $0.transform.columns.3.x }, [10, 11, 12])
        XCTAssertEqual(records.map(\.meshIndex), [0, 1, 0])

        // The next scene with a group of that name: not made again.
        options.instanceBlocks = first.namedInstanceBlocks
        XCTAssertEqual(Array(options.instanceBlocks.keys), ["a tile's trees"])
        let next = try SceneBuffers(device: device, queue: queue, scene: grouped { makes += 1 }, options: options)
        XCTAssertEqual(makes, 1)
        XCTAssertTrue(next.instanceBlocks[0] === block)
        // A group of another name is made, in a block with a number of its own.
        let other = try SceneBuffers(device: device, queue: queue, scene: grouped(group: "another tile's") { makes += 1 }, options: options)
        XCTAssertEqual(makes, 2)
        XCTAssertFalse(other.instanceBlocks[0] === block)
        XCTAssertNotEqual(other.instanceBlocks[0].number, block.number)
    }

    /// A block's records are in a buffer of its own, found through the scene's table; the scene's
    /// structure is built over every instance's descriptor, which names the instance by its id.
    func testMetalFindsABlocksRecordsThroughATable() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        try XCTSkipUnless(device.supportsRaytracing, "no ray tracing on this GPU")
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var makes = 0
        var options = SceneBuffers.Options(api: .metal3, slots: 3)
        let first = try SceneBuffers(device: device, queue: queue, scene: grouped { makes += 1 }, options: options)
        let block = try XCTUnwrap(first.instanceBlocks.first)
        XCTAssertTrue(first.indirect, "descriptors with ids, under Metal 3 too")
        XCTAssertEqual(first.instanceCount, 5)
        XCTAssertEqual(first.instanceStructures.count, 3)
        let table: [UInt64] = contents(try XCTUnwrap(first.instanceTable), InstanceBlock.capacity)
        XCTAssertEqual(table[0], first.instanceData[0].gpuAddress)
        XCTAssertEqual(table[block.number], block.buffer.gpuAddress)
        XCTAssertEqual(table.filter { $0 != 0 }.count, 2)
        XCTAssertEqual(first.instanceResources.count, 3)
        XCTAssertTrue(first.buffers.contains { $0 === block.buffer })
        func ids(_ buffers: SceneBuffers) -> [UInt32] {
            (0..<5).map { buffers.instanceDescriptors[0].contents().load(fromByteOffset: $0 * SceneBuffers.indirectStride + 60, as: UInt32.self) }
        }
        XCTAssertEqual(ids(first), [0, 1, block.id(0), block.id(1), block.id(2)])
        XCTAssertEqual(block.id(2), UInt32(block.number) << 20 | 2)

        // The next scene takes the block, and with the meshes' structures its descriptors as they are.
        options.instanceBlocks = first.namedInstanceBlocks
        options.known = first.namedPrimitives
        let next = try SceneBuffers(device: device, queue: queue, scene: grouped { makes += 1 }, options: options)
        XCTAssertEqual(makes, 1)
        XCTAssertTrue(next.instanceBlocks[0] === block)
        XCTAssertEqual(ids(next), ids(first))
        func structure(_ buffers: SceneBuffers, _ i: Int) -> MTLResourceID {
            buffers.instanceDescriptors[0].contents().load(fromByteOffset: i * SceneBuffers.indirectStride + 64, as: MTLResourceID.self)
        }
        XCTAssertEqual(structure(next, 3)._impl, next.primitives[1].gpuResourceID._impl)
        // Without them the meshes are built again, and the block's descriptors name the new structures.
        options.known = [:]
        let rebuilt = try SceneBuffers(device: device, queue: queue, scene: grouped { makes += 1 }, options: options)
        XCTAssertTrue(rebuilt.instanceBlocks[0] === block)
        XCTAssertEqual(structure(rebuilt, 3)._impl, rebuilt.primitives[1].gpuResourceID._impl)
        XCTAssertNotEqual(structure(rebuilt, 3)._impl, structure(first, 3)._impl)
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
        let buffers = try SceneBuffers(device: device, queue: queue, scene: scene, options: .init(api: .metal3, slots: 3))
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
        // By night it is the same world, with its lights; with another share of lit windows it is another.
        b = a
        b.worldLit = true
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.isSameWorld(as: b))
        b.city.lit = 0.6
        XCTAssertFalse(a.isSameWorld(as: b))
    }

    /// A borrowed mesh of several materials, one of them emissive, with the light that came with it (an open world's
    /// tile at night): the scene samples it as its own emissive instances, with the material the light names.
    func testABorrowedMeshComesWithItsLight() throws {
        func lit(firstEmits: Bool) -> Scene {
            Scene(SceneSettings(kind: .cornell)) { scene in
                let own = scene.addMaterial(albedo: .zero, emission: [3, 3, 3])
                scene.addInstance(scene.addMesh(self.quad(0)), own, matrix_identity_float4x4)
                // The borrowed mesh's materials: its first triangle has the first, the others the second.
                let first = firstEmits ? scene.addMaterial(albedo: .zero, emission: [1, 1, 1]) : scene.addMaterial(albedo: [0.5, 0.5, 0.5])
                _ = scene.addMaterial(albedo: .zero, emission: [2, 4, 8])
                let positions: [SIMD3<Float>] = [[0, 5, 0], [2, 5, 0], [2, 5, 2], [0, 5, 2], [1, 6, 1]]
                let borrowed = Scene.BorrowedMesh(positions: .made(positions), normals: .made([SIMD3<Float>](repeating: [0, 1, 0], count: 5)),
                                                  uvs: .made((0..<5).map { SIMD2(Float($0), 0.5) }),
                                                  indices: .made([0, 1, 2, 0, 2, 3, 0, 1, 4]), materials: .made([0, 1, 1]))
                let instance = scene.addInstance(scene.addMesh(borrowing: borrowed, bounds: AABB(lo: [0, 5, 0], hi: [2, 6, 2]), name: "a tile's chunk"),
                                                 first, translate([10, 0, 0]))
                // Its light, made as a tile makes its own: the two triangles of the second material, after a stranger.
                var draft = Scene.MeshLightDraft()
                draft.add(positions[0], positions[2], positions[3], emission: [2, 4, 8])
                draft.add(positions[0], positions[1], positions[4], emission: [2, 4, 8])
                var light = draft.finish(instance: instance, firstTriangle: 0)!
                light.materialOffset = 1
                let stranger = GPUEmissiveTriangle(v0: .zero, e1: .zero, e2: .zero, uv12: .zero)
                scene.addMeshLight(Scene.BorrowedLight(light: light, triangles: .made([stranger] + draft.triangles), range: 1..<3))
            }
        }
        for firstEmits in [false, true] {
            let scene = lit(firstEmits: firstEmits)
            // The scene's own emissive instance, then the borrowed mesh's light: no other of the borrowed mesh, whose
            // arrays the scene doesn't have, though its instance's material may emit.
            XCTAssertEqual(scene.meshLights.count, 2)
            let light = scene.meshLights[1]
            XCTAssertEqual([light.instance, light.firstTriangle, light.triangleCount, light.materialOffset], [1, 2, 2, 1])
            XCTAssertEqual(scene.emissiveTriangles.count, 4)
            let areas: [Float] = [2, Float(2).squareRoot()]
            XCTAssertEqual(SIMD3(scene.emissiveTriangles[2].v0.x, scene.emissiveTriangles[2].v0.y, scene.emissiveTriangles[2].v0.z), SIMD3(0, 5, 0))
            XCTAssertEqual(scene.emissiveTriangles[2].v0.w, areas[0] / (areas[0] + areas[1]), accuracy: 1e-5)
            XCTAssertEqual(scene.emissiveTriangles[3].v0.w, 1)
            XCTAssertEqual(scene.emissiveTriangles[3].e2, SIMD4(1, 1, 1, 0))
            XCTAssertLessThan(distance(light.power, SIMD3<Float>(2, 4, 8) * (areas[0] + areas[1])), 1e-4)
            // Its material is a light's: GI doesn't count what it emits again. The mesh's other material isn't.
            let material = scene.instances[1].material
            XCTAssertEqual(scene.materials[material + 1].params.z, 1)
            XCTAssertEqual(scene.materials[material].params.z, 0)
            // The light's record names the material, and the table has its triangles.
            var records = [GPULight](repeating: GPULight(positionRadius: .zero, color: .zero, axis: .zero, params: .zero), count: scene.lights.count)
            records.withUnsafeMutableBufferPointer { scene.writeLights(into: $0, all: true) }
            let record = try XCTUnwrap(records.last)
            XCTAssertEqual(record.axis.w, 1)
            XCTAssertEqual(record.params.w.bitPattern, 1)
            XCTAssertEqual(record.params.x.bitPattern, 2)
            XCTAssertEqual(record.positionRadius.x, 11, accuracy: 1e-4)
            XCTAssertEqual(records[records.count - 2].axis.w, 0, "the scene's own: its instance's material")
            XCTAssertEqual(scene.lightTable.triangles.count, 4)
            XCTAssertEqual(scene.lightTable.triangles[2].light, UInt32(scene.lights.count - 1))
            XCTAssertEqual(scene.lightTable.triangles[3].radianceLum, 2 * 0.2126 + 4 * 0.7152 + 8 * 0.0722, accuracy: 1e-4)
        }
    }

    /// The open world's lights (`Scene.cityLights`): materials that emit nothing as the scene is made, and their
    /// borrowed meshes' lights with them; as far on as the sun's height says, in the materials and in the light table.
    func testCityLightsComeOn() throws {
        let degree = Float.pi / 180
        let scene = Scene(SceneSettings(kind: .cornell)) { scene in
            let wall = scene.addMaterial(albedo: [0.5, 0.5, 0.5])
            let lamp = scene.addMaterial(albedo: [0.6, 0.6, 0.6])        // off: what it emits is the city light's to say
            let window = scene.addMaterial(albedo: [0.8, 0.8, 0.7])
            XCTAssertEqual([wall, lamp, window], [0, 1, 2])
            let positions: [SIMD3<Float>] = [[0, 5, 0], [2, 5, 0], [2, 5, 2], [0, 5, 2]]
            let borrowed = Scene.BorrowedMesh(positions: .made(positions), normals: .made([SIMD3<Float>](repeating: [0, 1, 0], count: 4)),
                                              uvs: .made([SIMD2<Float>](repeating: .zero, count: 4)),
                                              indices: .made([0, 1, 2, 0, 2, 3, 0, 1, 3]), materials: .made([1, 2, 0]))
            let instance = scene.addInstance(scene.addMesh(borrowing: borrowed, bounds: AABB(lo: [0, 5, 0], hi: [2, 5, 2]), name: "a chunk"),
                                             wall, matrix_identity_float4x4)
            for (offset, emission, triangle) in [(1, SIMD3<Float>(100, 80, 50), (0, 1, 2)), (2, SIMD3<Float>(1, 1, 1), (0, 2, 3))] {
                var draft = Scene.MeshLightDraft()
                draft.add(positions[triangle.0], positions[triangle.1], positions[triangle.2], emission: emission)
                var light = draft.finish(instance: instance, firstTriangle: 0)!
                light.materialOffset = offset
                scene.addMeshLight(Scene.BorrowedLight(light: light, triangles: .made(draft.triangles), range: 0..<1))
                scene.cityLights.append(Scene.CityLight(material: wall + offset, emission: emission, window: offset == 1 ? nil : 0.5))
            }
        }
        // The lights are there, off: nothing emits, and the table says so.
        XCTAssertEqual(scene.meshLights.count, 2)
        XCTAssertEqual(scene.lightTable.triangles.map(\.radianceLum), [0, 0])
        XCTAssertEqual(scene.lightTable.entries.count, 2, "but they are in it, each by what it emits when on")
        XCTAssertGreaterThan(scene.lightTable.entries[0].pdf, scene.lightTable.entries[1].pdf)
        XCTAssertEqual(scene.materials[1].params.z, 1, "a light's material")
        XCTAssertNil(scene.takeMaterialsDirty())
        XCTAssertNil(scene.takeLightTrianglesDirty())

        // The sun sets: the lamp is on, the window (its time is half-way through the dusk) not yet.
        scene.setCityLights(sunElevation: 0.2 * degree)
        XCTAssertEqual(scene.materials[1].emission, SIMD4(100, 80, 50, 1))
        XCTAssertEqual(scene.materials[2].emission, SIMD4(0, 0, 0, 1))
        XCTAssertEqual(scene.lightTable.triangles[0].radianceLum, 100 * 0.2126 + 80 * 0.7152 + 50 * 0.0722, accuracy: 1e-3)
        XCTAssertEqual(scene.lightTable.triangles[1].radianceLum, 0)
        XCTAssertEqual(scene.takeMaterialsDirty(), 1..<2)
        XCTAssertEqual(scene.takeLightTrianglesDirty(), 0..<1)
        // Dark: both; and nothing more to change after that.
        scene.setCityLights(sunElevation: -12 * degree)
        XCTAssertEqual(scene.materials[2].emission, SIMD4(1, 1, 1, 1))
        XCTAssertEqual(scene.lightTable.triangles[1].radianceLum, 1, accuracy: 1e-5)
        XCTAssertEqual(scene.takeMaterialsDirty(), 2..<3)
        XCTAssertEqual(scene.takeLightTrianglesDirty(), 1..<2)
        scene.setCityLights(sunElevation: -20 * degree)
        XCTAssertNil(scene.takeMaterialsDirty())
        // Morning: off again.
        scene.setCityLights(sunElevation: 10 * degree)
        XCTAssertEqual(scene.materials[1].emission, SIMD4(0, 0, 0, 1))
        XCTAssertEqual(scene.lightTable.triangles.map(\.radianceLum), [0, 0])
        XCTAssertEqual(scene.takeMaterialsDirty(), 1..<3)
    }
}
