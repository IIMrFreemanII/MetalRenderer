import XCTest
import Metal
@testable import Buildings
@testable import Characters
@testable import Editors
@testable import Effects
@testable import EngineCore
@testable import Game
@testable import Materials
@testable import MetalRenderer
@testable import Physics
@testable import Plants

/// The mip kernels Metal 4 frames use (Shaders/Mips.metal, Metal4Frame.generateMipmaps) against the blit encoder's
/// generateMipmaps, which Metal 3 frames use: the same levels, bit for bit, so the two APIs draw the same frames.
final class MipKernelTests: XCTestCase {
    private static let shaders = SourceTree.packageRoot.appendingPathComponent("Sources/MetalRenderer/Shaders.metal")
    private static var compiled: (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines)?

    private func metal() throws -> (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines) {
        if let compiled = MipKernelTests.compiled { return compiled }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal device") }
        let pipelines = try Pipelines(device: device, source: MipKernelTests.shaders, lightTypes: 0x3F, stats: false)
        MipKernelTests.compiled = (device, queue, pipelines)
        return (device, queue, pipelines)
    }

    /// A texture like the frames' (`type`, `format`, `slices`), its first level random half floats of either sign
    /// and many magnitudes (`channels` halves a texel).
    private func texture(_ device: MTLDevice, _ queue: MTLCommandQueue, type: MTLTextureType, format: MTLPixelFormat,
                         channels: Int, size: Int, slices: Int, seed: UInt64) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: true)
        d.textureType = type
        if type == .type2DArray { d.arrayLength = slices }
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw XCTSkip("texture") }
        var rng = SplitMix64(seed: seed)
        let count = size * size * channels
        let bytes = count * 2
        guard let staging = device.makeBuffer(length: bytes * slices, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { throw XCTSkip("buffer") }
        let halves = staging.contents().bindMemory(to: Float16.self, capacity: count * slices)
        for i in 0..<(count * slices) {
            let magnitude = rng.next() * pow(10, Float(rng.int(7)) - 3)   // 1e-3 ... 1e3
            halves[i] = Float16(rng.int(4) == 0 ? -magnitude : magnitude)
        }
        for s in 0..<slices {
            blit.copy(from: staging, sourceOffset: s * bytes, sourceBytesPerRow: size * channels * 2, sourceBytesPerImage: bytes,
                      sourceSize: MTLSize(width: size, height: size, depth: 1), to: t, destinationSlice: s, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return t
    }

    /// Every level of every slice, as raw bits.
    private func levels(_ t: MTLTexture, _ device: MTLDevice, _ queue: MTLCommandQueue, channels: Int) throws -> [[UInt16]] {
        let slices = t.textureType == .type2DArray ? t.arrayLength : 1
        var out: [[UInt16]] = []
        for level in 0..<t.mipmapLevelCount {
            let w = max(t.width >> level, 1), h = max(t.height >> level, 1), bytes = w * h * channels * 2
            guard let buffer = device.makeBuffer(length: bytes * slices, options: .storageModeShared),
                  let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { throw XCTSkip("buffer") }
            for s in 0..<slices {
                blit.copy(from: t, sourceSlice: s, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: w, height: h, depth: 1), to: buffer, destinationOffset: s * bytes,
                          destinationBytesPerRow: w * channels * 2, destinationBytesPerImage: bytes)
            }
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            out.append(Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: UInt16.self, capacity: bytes / 2 * slices),
                                                 count: bytes / 2 * slices)))
        }
        return out
    }

    private func check(type: MTLTextureType, format: MTLPixelFormat, channels: Int, slices: Int) throws {
        let m = try metal()
        let a = try texture(m.device, m.queue, type: type, format: format, channels: channels, size: 64, slices: slices, seed: 7)
        let b = try texture(m.device, m.queue, type: type, format: format, channels: channels, size: 64, slices: slices, seed: 7)
        guard let cb = m.queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { throw XCTSkip("encoder") }
        blit.generateMipmaps(for: a)
        blit.endEncoding()
        guard let enc = cb.makeComputeCommandEncoder() else { throw XCTSkip("encoder") }
        let flat = type == .type2D
        for level in 0..<(b.mipmapLevelCount - 1) {
            var l = UInt32(level)
            enc.setComputePipelineState(m.pipelines[flat ? .mipDown2D : .mipDown2DArray])
            enc.setTexture(b, index: 0)
            enc.setTexture(b, index: 1)
            enc.setBytes(&l, length: 4, index: 0)
            enc.dispatchThreads(MTLSize(width: max(b.width >> (level + 1), 1), height: max(b.height >> (level + 1), 1), depth: flat ? 1 : slices),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            enc.memoryBarrier(scope: .textures)
        }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let blitted = try levels(a, m.device, m.queue, channels: channels), computed = try levels(b, m.device, m.queue, channels: channels)
        for level in 1..<blitted.count {
            let differ = zip(blitted[level], computed[level]).filter { $0 != $1 }
            let ulps = zip(blitted[level], computed[level]).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertEqual(differ.count, 0, "\(format) level \(level): \(differ.count) of \(blitted[level].count) halves differ (at most \(ulps) ulps)")
        }
    }

    func testTheSkysAndTheWavesMipsMatchTheBlits() throws {
        try check(type: .type2DArray, format: .rgba16Float, channels: 4, slices: 2)
    }

    func testTheCausticsMipsMatchTheBlits() throws {
        try check(type: .type2D, format: .r16Float, channels: 1, slices: 1)
    }
}
