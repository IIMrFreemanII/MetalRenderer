import XCTest
import Metal
import simd
@testable import MetalRenderer

/// Displacement (MatSurface.displacement): meshes subdivided to a material's detail (MeshSubdivider), their vertices
/// grouped where they meet, moved on the GPU by the height (MaterialShaders/MatDisplace.metal) without opening the
/// surface; the scene's displaced copies (Scene+Displacement).
final class MaterialDisplacementTests: XCTestCase {
    /// A unit quad in XZ, its UVs its X and Z.
    private func quad() -> MeshSubdivider {
        MeshSubdivider(positions: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]], normals: Array(repeating: [0, 1, 0], count: 4),
                       uvs: [[0, 0], [1, 0], [1, 1], [0, 1]], indices: [0, 2, 1, 0, 3, 2])
    }

    private func box() -> MeshSubdivider {
        var b = MeshBuilder()
        Scene.tiledBox(&b, half: 0.5)
        let g = b.geometry
        return MeshSubdivider(positions: g.positions, normals: g.normals, uvs: b.uvs, indices: g.indices)
    }

    func testEdgesAreSplitDownToTheDetail() {
        var q = quad()
        q.subdivide(edge: 0.1, cap: 1_000_000)
        XCTAssertFalse(q.capped)
        XCTAssertLessThanOrEqual(q.longestEdge, 0.1)
        XCTAssertGreaterThan(q.triangleCount, 2 * 100)
        // The area kept, every triangle facing up as the quad did, UVs and normals interpolated.
        XCTAssertEqual(Scene.area(q.positions, q.indices), 1, accuracy: 1e-4)
        for t in 0..<q.triangleCount {
            let p = (0..<3).map { q.positions[Int(q.indices[3 * t + $0])] }
            XCTAssertGreaterThan(simd_cross(p[1] - p[0], p[2] - p[0]).y, 0)
        }
        for (p, uv) in zip(q.positions, q.uvs) { XCTAssertEqual(SIMD2(p.x, p.z), uv) }
        XCTAssertTrue(q.normals.allSatisfy { $0 == [0, 1, 0] })

        var capped = quad()
        capped.subdivide(edge: 0.001, cap: 5000)
        XCTAssertTrue(capped.capped)
        XCTAssertLessThanOrEqual(capped.triangleCount, 5000)
    }

    /// A box's faces have vertices of their own: where they meet, the vertices are one group, which moves along the
    /// faces' mean normal; inside a face, along the face's.
    func testGroupsAcrossHardEdges() {
        var b = box()
        b.subdivide(edge: 0.2, cap: 1_000_000)
        let w = b.welds()
        for v in b.positions.indices {
            let members = w.members[Int(w.start[v])..<Int(w.start[v] + w.count[v])]
            XCTAssertTrue(members.contains(UInt32(v)))
            XCTAssertTrue(members.allSatisfy { b.positions[Int($0)] == b.positions[v] })
            let p = b.positions[v], onFaces = (0..<3).filter { abs(abs(p[$0]) - 0.5) < 1e-6 }.count
            switch onFaces {
            case 3: XCTAssertEqual(simd_dot(w.direction[v], simd_normalize(simd_sign(p))), 1, accuracy: 1e-4, "a corner: diagonal")
            case 1: XCTAssertEqual(w.count[v], 1); XCTAssertEqual(simd_dot(w.direction[v], b.normals[v]), 1, accuracy: 1e-5)
            default: XCTAssertGreaterThan(w.count[v], 1)
            }
        }
    }

    /// The kernel: every vertex moved by the height its group reads, the groups' members to one point (no cracks).
    func testDisplacedSurfaceStaysClosed() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        var b = box()
        b.subdivide(edge: 0.1, cap: 1_000_000)
        let w = b.welds()
        // A height that varies across U: the groups' members read different heights at a seam.
        let side = 64
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: side, height: side, mipmapped: false)
        let height = try XCTUnwrap(device.makeTexture(descriptor: d))
        var texels = [Float](repeating: 0, count: side * side)
        for y in 0..<side { for x in 0..<side { texels[y * side + x] = Float(x) / Float(side - 1) } }
        height.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: texels, bytesPerRow: side * 4)
        var records: [SIMD4<Float>] = []
        for v in b.positions.indices {
            records.append(SIMD4(b.positions[v], Float(bitPattern: w.start[v])))
            records.append(SIMD4(w.direction[v], Float(bitPattern: w.count[v])))
        }
        let positions = try XCTUnwrap(device.makeBuffer(bytes: b.positions, length: b.positions.count * 16, options: .storageModeShared))
        let pipeline = try MatCompiler.shared.state("matDisplace", device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue()), cmd = try XCTUnwrap(queue.makeCommandBuffer())
        let enc = try XCTUnwrap(cmd.makeComputeCommandEncoder())
        var args = MatDisplaceArgs(first: 0, count: UInt32(b.positions.count), records: 0, members: 0, amount: 0.2, mid: 0.5, uvScale: 1, lod: 0)
        enc.setComputePipelineState(pipeline)
        enc.setBytes(&args, length: MemoryLayout<MatDisplaceArgs>.stride, index: 0)
        enc.setBuffer(device.makeBuffer(bytes: records, length: records.count * 16, options: .storageModeShared), offset: 0, index: 1)
        enc.setBuffer(device.makeBuffer(bytes: w.members, length: w.members.count * 4, options: .storageModeShared), offset: 0, index: 2)
        enc.setBuffer(device.makeBuffer(bytes: b.uvs, length: b.uvs.count * 8, options: .storageModeShared), offset: 0, index: 3)
        enc.setBuffer(positions, offset: 0, index: 4)
        enc.setTexture(height, index: 0)
        enc.dispatchThreads(MTLSize(width: b.positions.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let moved = Array(UnsafeBufferPointer(start: positions.contents().bindMemory(to: SIMD3<Float>.self, capacity: b.positions.count),
                                              count: b.positions.count))
        var largest: Float = 0
        for v in b.positions.indices {
            for m in w.members[Int(w.start[v])..<Int(w.start[v] + w.count[v])] { XCTAssertEqual(moved[Int(m)], moved[v], "a crack at \(b.positions[v])") }
            // Along its direction, by its group's mean height (within the texture's filtering).
            let along = simd_dot(moved[v] - b.positions[v], w.direction[v])
            XCTAssertEqual(simd_length(moved[v] - b.positions[v]), abs(along), accuracy: 1e-5)
            XCTAssertLessThanOrEqual(abs(along), 0.1 + 1e-5)
            largest = max(largest, abs(along))
            // (Not within a texel of the ramp's wrap, where it jumps from 1 to 0.)
            let u = b.uvs[v].x - b.uvs[v].x.rounded(.down)
            if w.count[v] == 1, u > 1 / Float(side), u < 1 - 1 / Float(side) {
                XCTAssertEqual(along, (u - 0.5) * 0.2, accuracy: 0.2 / Float(side) + 1e-4)
            }
        }
        XCTAssertGreaterThan(largest, 0.08)
    }

    /// The workshop with a displacing starter: each shape on a copy of its mesh fine enough, bounds grown by the
    /// reach, the material's parallax off; the scene is no longer still (its structures are built again).
    func testWorkshopMeshesAreDisplaced() throws {
        var s = SceneSettings(kind: .materials)
        s.materialWorkshop.graph = "Cobblestone"
        let surface = try XCTUnwrap(MaterialLibrary.named("Cobblestone")).surface
        XCTAssertGreaterThan(surface.displacement, 0)
        let scene = Scene(s)
        let pm = try XCTUnwrap(scene.procedural.first)
        XCTAssertEqual(Set(scene.displaced.map(\.material)), [pm.material])
        XCTAssertEqual(scene.displaced.count, 4, "sphere, cube, cylinder, tile")
        XCTAssertTrue(scene.displacedMaterials.contains(pm.material))
        XCTAssertFalse(scene.isStill)
        let meshes = scene.displacedMeshSet
        for inst in scene.instances where inst.material == pm.material { XCTAssertTrue(meshes.contains(inst.mesh)) }
        var total = 0
        for d in scene.displaced {
            XCTAssertLessThanOrEqual(d.edge, surface.displacementDetail * 1.0001)
            XCTAssertLessThanOrEqual(d.triangles, Scene.displacedTrianglesPerMesh)
            XCTAssertEqual(Int(scene.meshes[d.mesh].indexCount) / 3, d.triangles)
            total += d.triangles
            let b = scene.localBounds(mesh: d.mesh)
            let lo = scene.positions[d.first..<(d.first + d.count)].reduce(SIMD3(repeating: Float.infinity), simd_min)
            XCTAssertEqual(lo.x - b.lo.x, surface.displacementRoom / d.scale, accuracy: 1e-4)
        }
        XCTAssertLessThanOrEqual(total, Scene.displacedTrianglesPerScene)
        XCTAssertEqual(scene.displaceVertices.count, 2 * scene.displaced.reduce(0) { $0 + $1.count })
    }
}
