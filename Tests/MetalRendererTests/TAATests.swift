import XCTest
import Metal
import simd
@testable import MetalRenderer

/// Temporal AA without upscaling (RenderSettings.taa, Post.metal taaResolveKernel): when it runs, its jitter, and the
/// resolve on small images.
final class TAATests: XCTestCase {
    func testItRunsOnlyWithoutUpscalingOrReferences() {
        let s = RenderSettings()
        XCTAssertTrue(Renderer.usesTAA(s, upscaling: false, accumulating: false))
        XCTAssertFalse(Renderer.usesTAA(s, upscaling: true, accumulating: false), "MetalFX's scaler gathers the jitter then")
        XCTAssertFalse(Renderer.usesTAA(s, upscaling: false, accumulating: true), "references average their own frames")
        var normals = s
        normals.viewMode = 4
        XCTAssertFalse(Renderer.usesTAA(normals, upscaling: false, accumulating: false), "only the views of the light")
        var off = s
        off.taa = false
        XCTAssertFalse(Renderer.usesTAA(off, upscaling: false, accumulating: false))
    }

    /// Scale 1: 8 Halton phases inside the pixel, about its centre, then again.
    func testJitterAtTheTracedResolution() {
        let phases = (0..<8).map { Upscaler.jitter(frame: UInt32($0), scale: 1) }
        XCTAssertEqual(Set(phases.map { [$0.x, $0.y] }).count, 8)
        for p in phases { XCTAssertTrue(abs(p.x) < 0.5 && abs(p.y) < 0.5, "\(p)") }
        let mean = phases.reduce(.zero, +) / 8
        XCTAssertLessThan(simd_length(mean), 0.08)
        XCTAssertEqual(Upscaler.jitter(frame: 8, scale: 1), phases[0])
    }

    // MARK: The resolve on the GPU

    private static let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders.metal")
    private static var compiled: (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines)?
    private let n = 16

    private func metal() throws -> (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines) {
        if let compiled = TAATests.compiled { return compiled }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal device") }
        let pipelines = try Pipelines(device: device, source: TAATests.shaders, lightTypes: 0x3F, stats: false)
        TAATests.compiled = (device, queue, pipelines)
        return (device, queue, pipelines)
    }

    private func texture(_ device: MTLDevice, _ format: MTLPixelFormat, _ value: (Int, Int) -> SIMD4<Float>) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: n, height: n, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        let t = device.makeTexture(descriptor: d)!
        let region = MTLRegionMake2D(0, 0, n, n)
        if format == .rgba32Float {
            var px = [SIMD4<Float>]()
            for y in 0..<n { for x in 0..<n { px.append(value(x, y)) } }
            t.replace(region: region, mipmapLevel: 0, withBytes: px, bytesPerRow: n * 16)
        } else {
            var px = [SIMD4<Float16>]()
            for y in 0..<n { for x in 0..<n { px.append(SIMD4<Float16>(value(x, y))) } }
            t.replace(region: region, mipmapLevel: 0, withBytes: px, bytesPerRow: n * 8)
        }
        return t
    }

    /// One resolve: `input` this frame, `history` the last, the trace's `motion` and the last frame's depth.
    private func resolve(input: (Int, Int) -> SIMD4<Float>, history: (Int, Int) -> SIMD4<Float>,
                         motion: (Int, Int) -> SIMD4<Float>, reset: Bool = false) throws -> [SIMD3<Float>] {
        let m = try metal()
        let output = texture(m.device, .rgba16Float) { _, _ in .zero }
        var u = Uniforms()
        u.width = UInt32(n); u.height = UInt32(n)
        u.post = SIMD4(1, 0, 0, 0)
        u.camForward = SIMD4(0, 0, -1, 0); u.camRight = SIMD4(1, 0, 0, 1); u.camUp = SIMD4(0, 1, 0, 1)
        (u.prevCamForward, u.prevCamRight, u.prevCamUp) = (u.camForward, u.camRight, u.camUp)
        var r: UInt32 = reset ? 1 : 0
        let cmd = m.queue.makeCommandBuffer()!, enc = cmd.makeComputeCommandEncoder()!
        enc.setComputePipelineState(m.pipelines[.taaResolve])
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setBytes(&r, length: 4, index: 1)
        enc.setTextures([texture(m.device, .rgba16Float, input), texture(m.device, .rgba16Float, history),
                         texture(m.device, .rgba32Float, motion), output], range: 0..<4)
        enc.dispatchThreads(MTLSize(width: n, height: n, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        XCTAssertNil(cmd.error)
        var px = [SIMD4<Float16>](repeating: .zero, count: n * n)
        output.getBytes(&px, bytesPerRow: n * 8, from: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0)
        return px.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
    }

    /// The motion of a still surface 5 m away, without jitter: each pixel was itself.
    private func still(_ x: Int, _ y: Int) -> SIMD4<Float> { SIMD4(Float(x), Float(y), 5, 1) }

    func testResetTakesTheFrameAsItIs() throws {
        let input = { (x: Int, y: Int) in SIMD4<Float>(Float(x) / 16, Float(y) / 16, 0.5, 1) }
        let out = try resolve(input: input, history: { _, _ in SIMD4(9, 9, 9, 1) }, motion: still, reset: true)
        for y in 0..<n { for x in 0..<n { XCTAssertLessThan(simd_length(out[y * n + x] - SIMD3<Float>(input(x, y).x, input(x, y).y, input(x, y).z)), 2e-3) } }
    }

    /// A flat frame leaves no room in the neighbourhood's box: a history far from it is clipped onto it.
    func testHistoryOutsideTheNeighbourhoodIsClipped() throws {
        let out = try resolve(input: { _, _ in SIMD4(0.2, 0.4, 0.6, 1) }, history: { _, _ in SIMD4(4, 0, 1, 1) }, motion: still)
        for c in out { XCTAssertLessThan(simd_length(c - SIMD3(0.2, 0.4, 0.6)), 2e-3) }
    }

    /// Checkers of two greys: the history at their mean stays inside the box, and the pixel takes a tenth of the new
    /// sample (Karis-weighted), so most of it is the history.
    func testHistoryInsideTheNeighbourhoodIsKept() throws {
        let out = try resolve(input: { x, y in (x + y) % 2 == 0 ? SIMD4(0.2, 0.2, 0.2, 1) : SIMD4(0.6, 0.6, 0.6, 1) },
                              history: { _, _ in SIMD4(0.4, 0.4, 0.4, 1) }, motion: still)
        for y in 2..<(n - 2) {
            for x in 2..<(n - 2) {
                let v = out[y * n + x].x, current: Float = (x + y) % 2 == 0 ? 0.2 : 0.6
                XCTAssertLessThan(abs(v - 0.4), 0.04, "(\(x), \(y))")
                XCTAssertGreaterThan(abs(v - current), 0.15)
            }
        }
    }

    /// The last frame didn't see this place: the new sample alone.
    func testOffScreenTakesTheNewSample() throws {
        let checkers = { (x: Int, y: Int) in (x + y) % 2 == 0 ? SIMD4<Float>(0.2, 0.2, 0.2, 1) : SIMD4<Float>(0.6, 0.6, 0.6, 1) }
        let out = try resolve(input: checkers, history: { _, _ in SIMD4(0.4, 0.4, 0.4, 1) },
                              motion: { x, y in SIMD4(Float(x) - 40, Float(y), 5, 1) })
        for y in 0..<n { for x in 0..<n { XCTAssertEqual(out[y * n + x].x, checkers(x, y).x, accuracy: 2e-3) } }
    }
}
