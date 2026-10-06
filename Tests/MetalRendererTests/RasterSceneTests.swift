import XCTest
import Metal
import simd
@testable import MetalRenderer

/// The raster visibility buffer's view of a scene (RasterScene.swift): which meshes it draws and how, their chunks of
/// 128 triangles, its targets, and a projection that puts each primary ray's point on its pixel's centre.
final class RasterSceneTests: XCTestCase {
    /// A flat grid of `n` x `n` quads (2 n² triangles).
    private func grid(_ n: Int, y: Float = 0) -> MeshGeometry {
        var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
        for z in 0...n { for x in 0...n { positions.append([Float(x), y, Float(z)]) } }
        for z in 0..<n {
            for x in 0..<n {
                let a = UInt32(z * (n + 1) + x), b = a + 1, c = a + UInt32(n + 1), d = c + 1
                indices += [a, b, d, a, d, c]
            }
        }
        return (positions, [SIMD3<Float>](repeating: [0, 1, 0], count: positions.count), indices)
    }

    /// A grid of 200 triangles (2 chunks), one of 8 (1 chunk) and a borrowed mesh, an instance of each.
    private func scene() -> Scene {
        Scene(SceneSettings(kind: .cornell)) { scene in
            let material = scene.addMaterial(albedo: [0.5, 0.5, 0.5])
            scene.addInstance(scene.addMesh(self.grid(10)), material, matrix_identity_float4x4)
            scene.addInstance(scene.addMesh(self.grid(2, y: 1)), material, translate([0, 0, 20]))
            let borrowed = Scene.BorrowedMesh(positions: .made([[0, 5, 0], [2, 5, 0], [2, 5, 2], [0, 5, 2]]),
                                              normals: .made([SIMD3<Float>](repeating: [0, 1, 0], count: 4)),
                                              uvs: .made((0..<4).map { SIMD2(Float($0), 0.5) }),
                                              indices: .made([0, 1, 2, 0, 2, 3]), materials: .made([0, 0]))
            scene.addInstance(scene.addMesh(borrowing: borrowed, bounds: AABB(lo: [0, 5, 0], hi: [2, 5, 2]), name: "tile"),
                              material, translate([10, 0, 0]))
        }
    }

    func testKinds() {
        let plain = GPUMesh(firstIndex: 0, indexCount: 6)
        XCTAssertEqual(RasterScene.kind(of: plain, borrowed: false), .arrays)
        XCTAssertEqual(RasterScene.kind(of: plain, borrowed: true), .block)
        var cards = plain
        cards.cutout = 1 << 24
        XCTAssertEqual(RasterScene.kind(of: cards, borrowed: false), .skip, "alpha-tested leaf cards are traced")
        var cover = plain
        cover.sways = 1
        XCTAssertEqual(RasterScene.kind(of: cover, borrowed: false), .skip, "it leans in the wind where the rays meet it")
        XCTAssertEqual(RasterScene.kind(of: GPUMesh(firstIndex: 0, indexCount: 0), borrowed: false), .skip)
        XCTAssertEqual(RasterScene.chunks(1), 1)
        XCTAssertEqual(RasterScene.chunks(128), 1)
        XCTAssertEqual(RasterScene.chunks(129), 2)
    }

    func testRecordsAndChunks() throws {
        let scene = scene()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let buffers = try SceneBuffers(device: device, queue: queue, scene: scene, options: SceneBuffers.Options(api: .metal3, slots: 3))
        let raster = try RasterScene(device: device, scene: scene, buffers: buffers, virtualBLAS: false)
        XCTAssertEqual(raster.meshCount, 3)
        XCTAssertEqual(raster.firstAssembly, 3, "after the meshes and the virtual ones (none here)")
        XCTAssertEqual(raster.chunkCount, 2 + 1 + 1)
        XCTAssertEqual(raster.instanceCount, 3)
        XCTAssertNil(raster.ids, "without blocks an instance is named by its place")
        XCTAssertTrue(raster.source === buffers.meshes)

        let records = Array(UnsafeBufferPointer(start: raster.meshes.contents().bindMemory(to: GPURasterMesh.self, capacity: 3), count: 3))
        XCTAssertEqual(records.map { $0.lo.w.bitPattern }, [0, 2, 3], "each mesh's first chunk")
        XCTAssertEqual(records.map { $0.hi.w.bitPattern }, [RasterScene.Kind.arrays, .arrays, .block].map(\.rawValue))
        XCTAssertEqual(SIMD3(records[0].lo.x, records[0].lo.y, records[0].lo.z), [0, 0, 0])
        XCTAssertEqual(SIMD3(records[0].hi.x, records[0].hi.y, records[0].hi.z), [10, 0, 10])
        let chunkMeshes = Array(UnsafeBufferPointer(start: raster.chunkMeshes.contents().bindMemory(to: UInt32.self, capacity: 4), count: 4))
        XCTAssertEqual(chunkMeshes, [0, 0, 1, 2])
    }

    /// SDF shapes are traced: each has a record past the assemblies (as GPUInstanceData.meshIndex counts them), with
    /// its bounds, so its box is drawn where it is instead of every primary ray tracing as well.
    func testShapesHaveBoxRecords() throws {
        let scene = Scene(SceneSettings(kind: .cornell)) { scene in
            let material = scene.addMaterial(albedo: [0.5, 0.5, 0.5])
            scene.addInstance(scene.addMesh(self.grid(2)), material, matrix_identity_float4x4)
            let shape = scene.addSDFShape(SDFShape([SDFShape.Node(.sphere(radius: 0.5))]))
            scene.addInstance(sdf: shape, material, translate([3, 1, 0]))
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let buffers = try SceneBuffers(device: device, queue: queue, scene: scene, options: SceneBuffers.Options(api: .metal3, slots: 3))
        let raster = try RasterScene(device: device, scene: scene, buffers: buffers, virtualBLAS: false)
        XCTAssertEqual(raster.meshCount, 2, "the mesh, then the shape")
        let records = Array(UnsafeBufferPointer(start: raster.meshes.contents().bindMemory(to: GPURasterMesh.self, capacity: 2), count: 2))
        XCTAssertEqual(records[1].hi.w.bitPattern, RasterScene.Kind.skip.rawValue)
        XCTAssertEqual(records[1].lo.x, -0.5, accuracy: 0.05)
        XCTAssertEqual(records[1].hi.x, 0.5, accuracy: 0.05)
        XCTAssertNotEqual(scene.instances[1].mask & Scene.maskShadowTraced, 0, "virtual shadow maps trace it")
    }

    func testDeformingMeshesHaveNoChunkBounds() {
        let r = RasterScene.record(lo: [-1, 0, -1], hi: [1, 2, 1], kind: .arrays, deforms: true, firstChunk: 7)
        XCTAssertEqual(r.hi.w.bitPattern, RasterScene.Kind.arrays.rawValue | RasterScene.deforms)
        XCTAssertEqual(r.lo.w.bitPattern, 7)
        XCTAssertEqual(SIMD3(r.hi.x, r.hi.y, r.hi.z), [1, 2, 1], "a pose slot's bounds hold every pose already")
    }

    func testTargets() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let t = try RasterTargets(device: device, width: 640, height: 400, chunks: 1000, instances: 50)
        XCTAssertEqual([t.hzb.width, t.hzb.height], [512, 256], "half the size, rounded up to powers of two")
        XCTAssertEqual(t.hzb.mipmapLevelCount, 10, "down to 1 x 1")
        XCTAssertGreaterThanOrEqual(t.maxDraws, 65536)
        XCTAssertEqual(t.maxGroups, 50 + t.maxDraws / 64 + 1)
        XCTAssertEqual(t.records.length, 2 * t.maxGroups * RasterTargets.recordSize, "a RasterInstance per group, per pass")
        XCTAssertEqual(t.visibility.pixelFormat, Pipelines.visibilityFormat)
        XCTAssertEqual(t.depth.pixelFormat, Pipelines.depthFormat)
    }

    /// rasterProjection and rasterClip (Shaders/Raster.metal) against primaryDirection (Shaders/LightSampling.metal):
    /// a point of an instance on pixel p's jittered primary ray lands on p's centre, where the raster samples, at reversed
    /// depth NEAR_PLANE / view depth.
    func testProjectionPutsPrimaryRaysOnPixelCentres() {
        var camera = Camera()
        camera.position = [1, 2, 3]
        camera.yaw = 0.7
        camera.pitch = -0.2
        let (w, h): (Float, Float) = (640, 400)
        let tanY = tan(camera.fovY / 2), tanX = tanY * w / h
        let right = camera.right, up = camera.up, forward = camera.forward
        let jitter = SIMD2<Float>(0.31, -0.27)
        let m = translate([4, -1, 2]) * simd_float4x4(simd_quatf(angle: 0.6, axis: normalize(SIMD3<Float>(1, 2, 0.5))))
        // rasterProjection:
        var rel = m
        rel.columns.3 -= SIMD4(camera.position, 0)
        let a = right / tanX - 2 * jitter.x / w * forward, b = up / tanY + 2 * jitter.y / h * forward
        let rows = [a, b, forward].map { SIMD4($0, 0) * rel }
        for pixel in [SIMD2<Float>(0, 0), [100, 250], [639, 399], [320, 200]] {
            let uv = (pixel + 0.5 + jitter) / SIMD2(w, h)
            let dir = normalize(forward + (2 * uv.x - 1) * tanX * right + (1 - 2 * uv.y) * tanY * up)
            let world = camera.position + dir * 7.5
            let local = m.inverse * SIMD4(world, 1)
            // rasterClip:
            let clip = SIMD4<Float>(dot(rows[0], local), dot(rows[1], local), Camera.nearPlane, dot(rows[2], local))
            let ndc = SIMD2(clip.x, clip.y) / clip.w
            let landed = SIMD2((ndc.x * 0.5 + 0.5) * w, (0.5 - ndc.y * 0.5) * h)
            XCTAssertEqual(landed.x, pixel.x + 0.5, accuracy: 1e-3)
            XCTAssertEqual(landed.y, pixel.y + 0.5, accuracy: 1e-3)
            XCTAssertEqual(clip.z / clip.w, Camera.nearPlane / dot(world - camera.position, forward), accuracy: 1e-6)
        }
    }
}
