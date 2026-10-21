import Metal
import XCTest
@testable import Characters
@testable import Editors
@testable import Effects
@testable import EngineCore
@testable import Game
@testable import MetalRenderer
@testable import Physics
@testable import Plants

/// M0 of the water: what the near patch's structure costs a frame on this GPU, built fast from scratch against refit
/// in place after its vertices moved (its grid keeps its triangles, only their corners move with the waves).
final class WaterBLASSpikeTests: XCTestCase {
    func testNearPatchBuildAgainstRefit() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsRaytracing, let queue = device.makeCommandQueue() else {
            throw XCTSkip("no ray tracing")
        }
        func measure(cells: Int) -> (build: Double, refit: Double) {
            let n = cells + 1
            var positions: [SIMD3<Float>] = []
            for j in 0..<n { for i in 0..<n { positions.append(SIMD3(Float(i) * 0.5, 0, Float(j) * 0.5)) } }
            var indices: [UInt32] = []
            for j in 0..<cells {
                for i in 0..<cells {
                    let a = UInt32(j * n + i), b = a + 1, c = a + UInt32(n), d = c + 1
                    indices += [a, d, b, a, c, d]
                }
            }
            let offset = positions.count * 16
            let buffer = device.makeBuffer(length: offset + indices.count * 4, options: .storageModeShared)!
            positions.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            indices.withUnsafeBytes { (buffer.contents() + offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
            geometry.vertexBuffer = buffer
            geometry.vertexStride = 16
            geometry.indexBuffer = buffer
            geometry.indexBufferOffset = offset
            geometry.indexType = .uint32
            geometry.triangleCount = cells * cells * 2
            geometry.opaque = false
            func timed(_ encode: (MTLAccelerationStructureCommandEncoder) -> Void) -> Double {
                var best = Double.infinity
                for round in 0..<6 {
                    // (Waves: every vertex moves between rounds.)
                    let p = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: n * n)
                    for k in 0..<n * n { p[k].y = sin(Float(k % n) * 0.3 + Float(round)) * 0.8 }
                    let cmd = queue.makeCommandBuffer()!, enc = cmd.makeAccelerationStructureCommandEncoder()!
                    encode(enc)
                    enc.endEncoding()
                    cmd.commit()
                    cmd.waitUntilCompleted()
                    if round > 0 { best = min(best, (cmd.gpuEndTime - cmd.gpuStartTime) * 1000) }
                }
                return best
            }
            let fast = MTLPrimitiveAccelerationStructureDescriptor()
            fast.geometryDescriptors = [geometry]
            fast.usage = .preferFastBuild
            let fastSizes = device.accelerationStructureSizes(descriptor: fast)
            let fastAS = device.makeAccelerationStructure(size: fastSizes.accelerationStructureSize)!
            let fastScratch = device.makeBuffer(length: fastSizes.buildScratchBufferSize, options: .storageModePrivate)!
            let build = timed { $0.build(accelerationStructure: fastAS, descriptor: fast, scratchBuffer: fastScratch, scratchBufferOffset: 0) }

            let refitting = MTLPrimitiveAccelerationStructureDescriptor()
            refitting.geometryDescriptors = [geometry]
            refitting.usage = .refit
            let sizes = device.accelerationStructureSizes(descriptor: refitting)
            let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize)!
            let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, sizes.refitScratchBufferSize, 16), options: .storageModePrivate)!
            do {
                let cmd = queue.makeCommandBuffer()!, enc = cmd.makeAccelerationStructureCommandEncoder()!
                enc.build(accelerationStructure: structure, descriptor: refitting, scratchBuffer: scratch, scratchBufferOffset: 0)
                enc.endEncoding()
                cmd.commit()
                cmd.waitUntilCompleted()
            }
            let refit = timed {
                $0.refit(sourceAccelerationStructure: structure, descriptor: refitting, destinationAccelerationStructure: nil,
                         scratchBuffer: scratch, scratchBufferOffset: 0)
            }
            print(String(format: "Water BLAS: %d x %d cells (%d triangles): fast build %.3f ms, refit %.3f ms", cells, cells, cells * cells * 2,
                         build, refit))
            return (build, refit)
        }
        _ = measure(cells: 64)
        let near = measure(cells: 110)   // about the ring grid's 24k triangles
        _ = measure(cells: 160)
        XCTAssertGreaterThan(near.refit, 0)
    }
}
