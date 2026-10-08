import XCTest
import Metal
import simd
@testable import MetalRenderer

/// The raster clusters' cut on the GPU (rasterVGCutKernel, Shaders/RasterClusters.metal) against the CPU's: the clusters
/// it draws and the groups it asks for, frame after frame while its pool streams them in, must be the ones the rule
/// picks for what is resident; once nothing is waiting, the cut is the per-instance BLAS's (VirtualBLAS.selection).
final class VGCutTests: XCTestCase {
    private static let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders.metal")
    private static let maxDraws = 8192

    /// The cut's pipeline, from one compile of the shaders.
    private static let pipeline: Result<(MTLDevice, MTLComputePipelineState), Error>? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return Result {
            let library = try Pipelines.compile(device: device, source: shaders, stats: false, compiler: nil)
            // The light types alone (function constant 0): without it every feature is on, instance blocks (TILED) too.
            let constants = MTLFunctionConstantValues()
            var types: UInt32 = 0x3F
            constants.setConstantValue(&types, type: .uint, index: 0)
            return (device, try Pipelines.makeState(device: device, library: library, compiler: nil, kernel: .rasterVGCut,
                                                     constants: constants))
        }
    }()

    /// What a dispatch drew (its clusters, by index in the mesh, with each one's triangles) and asked for.
    private struct GPUCut {
        var drawn: [Int: UInt32] = [:]
        var requested: Set<Int> = []
    }

    /// One frame's cut of `mesh`'s one instance at `transform`, every cluster in view (a projection that puts every
    /// box at the centre of the screen), detail chosen for `view`.
    private func gpuCut(_ rc: RasterClusters, mesh: VirtualMesh, transform: float4x4, view: VGView,
                        device: MTLDevice, pipeline: MTLComputePipelineState) throws -> GPUCut {
        func buffer(_ length: Int) throws -> MTLBuffer {
            let b = try XCTUnwrap(device.makeBuffer(length: length, options: .storageModeShared))
            memset(b.contents(), 0, length)
            return b
        }
        var u = Uniforms()
        u.width = 64
        u.height = 64
        var instance = GPUInstanceData(transform: transform, prevTransform: transform, normalMatrix: transform.inverse.transpose,
                                       meshIndex: 0, materialIndex: 0, pad1: 1)
        var rp = GPURasterParams()
        rp.maxDraws = UInt32(VGCutTests.maxDraws)
        rp.hzbLevels = 1
        rp.hzbSize = [1, 1]
        rp.virtualCount = 1
        var params = rc.params(view: view, previous: false, mesh: false)
        let counters = try buffer(3 * 32), draws = try buffer(VGCutTests.maxDraws * 16)

        // The state: counters, the instance's RasterInstance (clip x = y = 0, w = 1: in view), whether it is in view.
        let state = rc.state(slot: 0)
        memset(state.contents(), 0, state.length)
        let rows = state.contents().advanced(by: 64).bindMemory(to: SIMD4<Float>.self, capacity: 4)
        rows[2] = [0, 0, 0, 1]
        state.contents().storeBytes(of: UInt32(1), toByteOffset: 64 + 64 * rc.instanceCount, as: UInt32.self)

        let pyramid = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        let hzb = try XCTUnwrap(device.makeTexture(descriptor: pyramid))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setBytes(&instance, length: MemoryLayout<GPUInstanceData>.stride, index: 6)
        enc.setBytes(&rp, length: MemoryLayout<GPURasterParams>.stride, index: 9)
        enc.setBuffer(counters, offset: 0, index: 13)
        enc.setBuffer(draws, offset: 0, index: 17)
        enc.setBuffer(rc.streamer.pool, offset: 0, index: 20)
        enc.setBytes(&params, length: MemoryLayout<RasterClusters.Params>.stride, index: 21)
        let pages = rc.streamer.bindPages(slot: 0)
        for (i, b) in [rc.vinstances, rc.groupRecords, rc.streamer.clusterBuffer, pages, state, rc.listBuffers[0],
                       rc.requests(slot: 0), rc.streamer.requestStamp, rc.streamer.lastUsed].enumerated() {
            enc.setBuffer(b, offset: 0, index: 22 + i)
        }
        enc.setTexture(hzb, index: 0)
        enc.setTexture(hzb, index: 1)
        enc.dispatchThreads(MTLSize(width: rc.workCount, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)

        // A list entry's pool offset names its cluster: its group's page plus its own offset in it.
        let table = pages.contents().bindMemory(to: UInt32.self, capacity: mesh.groups.count)
        var clusterAt: [UInt32: Int] = [:]
        for (ci, c) in mesh.clusters.enumerated() where table[Int(c.group)] != .max {
            clusterAt[table[Int(c.group)] + c.pageOffset / 16] = ci
        }
        let header = state.contents().bindMemory(to: UInt32.self, capacity: 16)
        XCTAssertEqual(header[2], 0, "the list overflowed")
        let list = rc.listBuffers[0].contents().bindMemory(to: SIMD2<UInt32>.self, capacity: Int(header[0]))
        var out = GPUCut()
        var triangles = 0
        for k in 0..<Int(header[0]) {
            let ci = try XCTUnwrap(clusterAt[list[k].y], "entry \(k): no cluster at pool offset \(list[k].y)")
            XCTAssertEqual(list[k].x, mesh.clusters[ci].lo.w.bitPattern, "entry \(k): not its cluster's own error")
            XCTAssertNil(out.drawn.updateValue(mesh.clusters[ci].triangles, forKey: ci), "cluster \(ci) drawn twice")
            triangles += Int(mesh.clusters[ci].triangles)
        }
        XCTAssertEqual(Int(header[3]), triangles)

        // Every entry has one draw: (its positions in the pool in float4s, entry, its triangles | RASTER_CLUSTERS, its
        // packed triangles in uints), and its owners (virtual instance, scene instance) after the list's entries.
        let slots = Int(counters.contents().load(as: UInt32.self)) / 384
        XCTAssertEqual(slots, Int(header[0]))
        let d = draws.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: VGCutTests.maxDraws)
        let owners = rc.listBuffers[0].contents().advanced(by: RasterClusters.ownersOffset)
            .bindMemory(to: SIMD2<UInt32>.self, capacity: RasterClusters.capacity)
        var entries = Set<UInt32>()
        for i in 0..<min(slots, VGCutTests.maxDraws) {
            let k = Int(d[i].y)
            XCTAssertTrue(entries.insert(d[i].y).inserted)
            let ci = try XCTUnwrap(clusterAt[list[k].y])
            let c = mesh.clusters[ci]
            XCTAssertEqual(d[i].z, c.triangles | 5 << 16)
            XCTAssertEqual(owners[k], [0, 0])
            // The blob's header (vgClusterView): byte offsets of its positions and its triangles.
            let blob = Int(mesh.groups[Int(c.group)].pageOffset) + Int(c.pageOffset)
            let (positions, triangles) = mesh.pageData.withUnsafeBytes {
                ($0.load(fromByteOffset: blob + 20, as: UInt32.self), $0.load(fromByteOffset: blob + 28, as: UInt32.self))
            }
            XCTAssertEqual(d[i].x, list[k].y + positions / 16)
            XCTAssertEqual(d[i].w, 4 * list[k].y + triangles / 4)
        }

        let requests = rc.requests(slot: 0).contents().bindMemory(to: SIMD2<UInt32>.self, capacity: RasterClusters.requestCapacity)
        for i in 0..<min(Int(header[1]), RasterClusters.requestCapacity) {
            XCTAssertTrue(out.requested.insert(Int(requests[i].x)).inserted, "group \(requests[i].x) asked for twice")
        }
        return out
    }

    /// The rule on the CPU for what is resident: the clusters it draws, the groups it asks for, and the clusters (and
    /// groups) whose test is too close to tau for the GPU's arithmetic to be sure to agree.
    private func cpuCut(mesh: VirtualMesh, resident: [Bool], transform m: float4x4, view: VGView)
        -> (drawn: Set<Int>, requested: Set<Int>, borderline: Set<Int>) {
        let scale = max(length(SIMD3(m[0].x, m[0].y, m[0].z)), length(SIMD3(m[1].x, m[1].y, m[1].z)), length(SIMD3(m[2].x, m[2].y, m[2].z)))
        var close = false
        func fineEnough(_ s: SIMD4<Float>, _ error: Float) -> Bool {
            let c = m * SIMD4<Float>(s.x, s.y, s.z, 1)
            let d = length(SIMD3(c.x, c.y, c.z) - view.camPos) - s.w * scale
            let projected = d <= 1e-4 ? Float.infinity : error * scale * view.pixelScale / d
            if abs(projected - view.tau) <= 1e-3 * view.tau { close = true }
            return projected <= view.tau
        }
        var drawn = Set<Int>(), requested = Set<Int>(), borderline = Set<Int>()
        for (g, grp) in mesh.groups.enumerated() where resident[g] {
            let range = Int(grp.clusterStart)..<Int(grp.clusterStart + grp.clusterCount)
            close = false
            let coarserEnough = !grp.isRoot && fineEnough(mesh.clusters[range.lowerBound].parentSphere, grp.error)
            if close { borderline.formUnion(range) }
            if coarserEnough { continue }
            for ci in range {
                let c = mesh.clusters[ci]
                if c.childGroup != .max {
                    close = false
                    let fine = fineEnough(c.selfSphere, c.lo.w)
                    if close { borderline.insert(ci) }
                    if !fine {
                        if resident[Int(c.childGroup)] { continue }
                        requested.insert(Int(c.childGroup))
                    }
                }
                drawn.insert(ci)
            }
        }
        return (drawn, requested, borderline)
    }

    /// From the roots alone to a settled pool, for two views (near the grid's corner, and above it from afar): each
    /// frame's GPU cut is the CPU's for that frame's residency, and its requests stream in until none are left.
    func testGPUCutMatchesTheCPUs() throws {
        guard let (device, pipeline) = try VGCutTests.pipeline?.get() else { throw XCTSkip("no Metal device") }
        let mesh = VGStreamerTests.mesh
        let rc = try RasterClusters(device: device, meshes: [mesh], instances: [(0, 0)], poolMB: 64, slots: 1)
        // Turned, scaled by 1.5 and moved: the cut must measure the error through the instance's transform.
        var transform = float4x4(simd_quatf(angle: 0.4, axis: [0, 1, 0])) * float4x4(diagonal: [1.5, 1.5, 1.5, 1])
        transform.columns.3 = [3, -1, 7, 1]
        var frame: UInt32 = 1
        var levels = Set<UInt32>()
        for camPos in [SIMD3<Float>(-4, 3, -2), SIMD3<Float>(70, 120, 60)] {
            let view = VGView(camPos: camPos, pixelScale: 400, tau: 1, frame: 0)
            var settled = false
            for _ in 0..<32 {
                var v = view
                v.frame = frame
                let table = rc.streamer.bindPages(slot: 0).contents().bindMemory(to: UInt32.self, capacity: mesh.groups.count)
                let resident = (0..<mesh.groups.count).map { table[$0] != .max }
                let gpu = try gpuCut(rc, mesh: mesh, transform: transform, view: v, device: device, pipeline: pipeline)
                let cpu = cpuCut(mesh: mesh, resident: resident, transform: transform, view: v)
                let drawn = Set(gpu.drawn.keys)
                XCTAssertEqual(drawn.symmetricDifference(cpu.drawn).subtracting(cpu.borderline), [], "frame \(frame)")
                let unsure = Set(cpu.borderline.map { Int(mesh.clusters[$0].childGroup) })
                XCTAssertEqual(gpu.requested.symmetricDifference(cpu.requested).subtracting(unsure), [], "frame \(frame)")
                if cpu.requested.isEmpty && rc.streamer.isSettled {
                    // Settled: the cut is the BLAS's, every page there to read.
                    let blas = VirtualBLAS.selection(mesh: mesh, groups: 0..<mesh.groups.count, transform: transform,
                                                     camPos: camPos, pixelScale: view.pixelScale, tau: view.tau).selection
                    XCTAssertEqual(drawn.symmetricDifference(blas.map { Int($0) }).subtracting(cpu.borderline), [])
                    levels.formUnion(drawn.map { mesh.groups[Int(mesh.clusters[$0].group)].level })
                    settled = true
                    frame += 1
                    break
                }
                // As the renderer does once the frame has finished: its requests to the pool, which loads them.
                rc.collect(slot: 0, frame: frame, camera: true, shadows: false)
                rc.update(frame: frame, slot: 0, framesInFlight: 1)
                rc.streamer.waitForCopies()
                frame += 1
            }
            XCTAssertTrue(settled, "still streaming after 32 frames from \(camPos)")
        }
        XCTAssertGreaterThan(levels.count, 1, "every cut was of one level: the test shows little")
    }

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
