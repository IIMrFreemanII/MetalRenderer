import XCTest
import Metal
import simd
@testable import MetalRenderer

/// The raster clusters' software rasterizer (rasterSWKernel, Shaders/RasterSoftware.metal) against the hardware's draw of
/// the same clusters (rasterVertex / rasterFragment over reversed depth): the same triangle and the same depth at every
/// pixel, but for the few pixel centres the two put on the other side of an edge.
final class SoftwareRasterTests: XCTestCase {
    private static let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders.metal")
    private static let size = 64
    private static let capacity = 4   // list entries (the owners follow them)

    /// Two clusters' blobs in a pool as the streamer lays them out (header, offsets, positions, packed triangles): each a
    /// bumpy 8 x 8-quad grid (81 vertices, 128 triangles) over part of the screen, the second nearer and across the first.
    private func pool() -> (floats: [SIMD4<Float>], at: [Int]) {
        var pool: [SIMD4<Float>] = []
        var at: [Int] = []
        for c in 0..<2 {
            let start = pool.count
            at.append(start)
            let n = 8, verts = (n + 1) * (n + 1), tris = 2 * n * n
            let positionsAt = 2 * 16, trianglesAt = positionsAt + verts * 16
            pool.append(SIMD4(Float(bitPattern: 0), Float(bitPattern: UInt32(verts)), Float(bitPattern: UInt32(tris)), 0))
            pool.append(SIMD4(Float(bitPattern: 0), Float(bitPattern: UInt32(positionsAt)), Float(bitPattern: 0),
                              Float(bitPattern: UInt32(trianglesAt))))
            // Off the pixel grid (no vertex on a pixel centre's lines), tilted in depth, bumpy, a little rotated.
            let origin: SIMD2<Float> = c == 0 ? [-0.73, -0.61] : [-0.29, -0.41]
            let extent: Float = c == 0 ? 1.13 : 0.97
            for j in 0...n {
                for i in 0...n {
                    let u = Float(i) / Float(n), v = Float(j) / Float(n)
                    let z = (c == 0 ? 3.3 : 2.3) + 0.4 * u - 0.3 * v + 0.05 * sin(Float(i * 7 + j * 3))
                    let xy = origin + extent * SIMD2(u + 0.13 * v, v - 0.11 * u)
                    pool.append(SIMD4(xy.x * z, xy.y * z, z, 0))   // (clip x, y = these; w = z: on screen at xy)
                }
            }
            var packed: [UInt32] = []
            for j in 0..<n {
                for i in 0..<n {
                    let a = UInt32(j * (n + 1) + i), b = a + 1, d = a + UInt32(n + 1), e = d + 1
                    packed.append(a | b << 8 | e << 16)
                    packed.append(a | d << 8 | e << 16)   // (the other winding)
                }
            }
            while packed.count % 4 != 0 { packed.append(0) }
            for q in stride(from: 0, to: packed.count, by: 4) {
                pool.append(SIMD4(Float(bitPattern: packed[q]), Float(bitPattern: packed[q + 1]),
                                  Float(bitPattern: packed[q + 2]), Float(bitPattern: packed[q + 3])))
            }
            XCTAssertEqual((pool.count - start) * 16, trianglesAt + packed.count * 4)
        }
        return (pool, at)
    }

    func testSoftwareMatchesTheHardwareDraw() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        try XCTSkipUnless(device.supportsFamily(.apple8), "64-bit atomics: Apple8 GPUs and later")
        let library = try Pipelines.compile(device: device, source: SoftwareRasterTests.shaders, stats: false, compiler: nil)
        let constants = MTLFunctionConstantValues()
        var types: UInt32 = 0x3F   // the light types alone: without it every feature is on, instance blocks (TILED) too
        constants.setConstantValue(&types, type: .uint, index: 0)
        let software = try Pipelines.makeState(device: device, library: library, compiler: nil, kernel: .rasterSW, constants: constants)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try library.makeFunction(name: "rasterVertex", constantValues: constants)
        descriptor.fragmentFunction = try library.makeFunction(name: "rasterFragment", constantValues: constants)
        descriptor.colorAttachments[0].pixelFormat = Pipelines.visibilityFormat
        descriptor.depthAttachmentPixelFormat = Pipelines.depthFormat
        let draw = try device.makeRenderPipelineState(descriptor: descriptor)

        func buffer(_ length: Int) throws -> MTLBuffer {
            let b = try XCTUnwrap(device.makeBuffer(length: max(length, 16), options: .storageModeShared))
            memset(b.contents(), 0, b.length)
            return b
        }
        func buffer<T>(_ values: [T]) throws -> MTLBuffer {
            let b = try buffer(values.count * MemoryLayout<T>.stride)
            values.withUnsafeBytes { b.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            return b
        }
        let n = SoftwareRasterTests.size, capacity = SoftwareRasterTests.capacity
        let (floats, at) = pool()
        let poolBuffer = try buffer(floats)
        var u = Uniforms()
        u.width = UInt32(n)
        u.height = UInt32(n)
        var rp = GPURasterParams()
        rp.maxDraws = 2
        rp.virtualCount = 1
        var p = RasterClusters.Params(lodCam: .zero, tau: 1, workCount: 0, instanceCount: 1, capacity: UInt32(capacity), frame: 0,
                                      requestCapacity: 0, flags: RasterClusters.Params.software, softwareSide: 32)
        // The state: counters, then the one instance's RasterInstance: clip x, y, w rows (object x, y, z).
        let state = try buffer(64 + 68)
        let rows = state.contents().advanced(by: 64).bindMemory(to: SIMD4<Float>.self, capacity: 3)
        rows[0] = [1, 0, 0, 0]
        rows[1] = [0, 1, 0, 0]
        rows[2] = [0, 0, 1, 0]
        // The list: entry k's (error, pool offset), then its owners (virtual instance 0, scene instance 7 + k).
        var list = [SIMD2<UInt32>](repeating: .zero, count: 2 * capacity)
        for k in 0..<2 {
            list[k] = [0, UInt32(at[k])]
            list[capacity + k] = [0, UInt32(7 + k)]
        }
        let listBuffer = try buffer(list)
        // The software list: both clusters in pass 1.
        var sw = [UInt32](repeating: 0, count: RasterClusters.softwareHeader + capacity)
        sw[0] = 2
        sw[1] = 2
        sw[RasterClusters.softwareHeader] = 0
        sw[RasterClusters.softwareHeader + 1] = 1
        let swBuffer = try buffer(sw)
        let depths = try buffer(n * n * 8)
        // The hardware's draws: a cluster each (positions, entry, triangles | RASTER_CLUSTERS << 16, triangles' uint).
        let draws = try buffer((0..<2).map { k -> SIMD4<UInt32> in
            SIMD4(UInt32(at[k] + 2), UInt32(k), 128 | 5 << 16, UInt32(4 * at[k]) + UInt32(2 * 16 + 81 * 16) / 4)
        })

        func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: n, height: n, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        let visibility = try texture(Pipelines.visibilityFormat), depth = try texture(Pipelines.depthFormat)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = visibility
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(UInt32.max), green: Double(UInt32.max), blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .store
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .greater
        depthDescriptor.isDepthWriteEnabled = true
        let r = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: pass))
        r.setRenderPipelineState(draw)
        r.setDepthStencilState(device.makeDepthStencilState(descriptor: depthDescriptor))
        r.setVertexBytes(&rp, length: MemoryLayout<GPURasterParams>.stride, index: 9)
        r.setVertexBuffer(draws, offset: 0, index: 17)
        r.setVertexBuffer(draws, offset: 0, index: 19)   // (the records: not read by a cluster's vertices)
        r.setVertexBuffer(poolBuffer, offset: 0, index: 20)
        r.setVertexBuffer(state, offset: 0, index: 26)
        r.setVertexBuffer(listBuffer, offset: capacity * 8, index: 27)
        r.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 2 * 3 * RasterScene.chunk)
        r.endEncoding()

        let c = try XCTUnwrap(cb.makeComputeCommandEncoder())
        c.setComputePipelineState(software)
        c.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        c.setBuffer(swBuffer, offset: 0, index: 7)
        c.setBuffer(depths, offset: 0, index: 8)
        c.setBytes(&rp, length: MemoryLayout<GPURasterParams>.stride, index: 9)
        c.setBuffer(poolBuffer, offset: 0, index: 20)
        c.setBytes(&p, length: MemoryLayout<RasterClusters.Params>.stride, index: 21)
        c.setBuffer(state, offset: 0, index: 26)
        c.setBuffer(listBuffer, offset: 0, index: 27)
        c.dispatchThreadgroups(MTLSize(width: 2, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: RasterScene.chunk, height: 1, depth: 1))
        c.endEncoding()

        // The draw's targets, read back.
        let visRead = try buffer(n * n * 8), depthRead = try buffer(n * n * 4)
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: visibility, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: n, height: n, depth: 1),
                  to: visRead, destinationOffset: 0, destinationBytesPerRow: n * 8, destinationBytesPerImage: n * n * 8)
        blit.copy(from: depth, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: n, height: n, depth: 1),
                  to: depthRead, destinationOffset: 0, destinationBytesPerRow: n * 4, destinationBytesPerImage: n * n * 4)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)

        let hw = visRead.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: n * n)
        let hwDepth = depthRead.contents().bindMemory(to: Float.self, capacity: n * n)
        let words = depths.contents().bindMemory(to: UInt64.self, capacity: n * n)
        var covered = 0, differ = 0, perCluster = [0, 0]
        for i in 0..<(n * n) {
            let hwId: UInt32? = hw[i].x == UInt32.max ? nil : hw[i].y
            let swId: UInt32? = words[i] == 0 ? nil : UInt32(truncatingIfNeeded: words[i])
            if hwId != nil || swId != nil { covered += 1 }
            if let swId { perCluster[Int((swId >> 7) & 0xFF_FFFF)] += 1 }
            guard hwId == swId else { differ += 1; continue }
            if let swId {
                XCTAssertNotEqual(swId & RasterClusters.flag, 0)
                let swDepth = Float(bitPattern: UInt32(truncatingIfNeeded: words[i] >> 32))
                XCTAssertEqual(swDepth, hwDepth[i], accuracy: 1e-3 * hwDepth[i], "pixel \(i): the same depth")
            }
        }
        XCTAssertGreaterThan(perCluster[0], 400, "the far cluster shows around the near one")
        XCTAssertGreaterThan(perCluster[1], 400)
        XCTAssertGreaterThan(covered, 1000)
        XCTAssertLessThanOrEqual(Double(differ), 0.01 * Double(covered),
                                 "\(differ) of \(covered) pixels differ: only edge pixel centres should")
    }

    /// Without 64-bit atomics the software rasterizer falls back to the clusters drawn, and says why.
    func testWithoutAtomicsTheClustersAreDrawn() {
        var settings = RenderSettings()
        settings.virtualGeometry.raster = .software
        var caps = Capabilities()
        XCTAssertNil(settings.missing(in: caps))
        XCTAssertEqual(settings.clamped(to: caps).settings.virtualGeometry.raster, .software)
        caps.atomics64 = false
        XCTAssertEqual(settings.missing(in: caps), "64-bit atomics")
        let clamped = settings.clamped(to: caps)
        XCTAssertEqual(clamped.settings.virtualGeometry.raster, .clusters)
        XCTAssertEqual(clamped.notes.count, 1)
    }
}
