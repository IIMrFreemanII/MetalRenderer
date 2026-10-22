import Metal
import XCTest
@testable import Buildings
@testable import Characters
@testable import Editors
@testable import Effects
@testable import EngineCore
@testable import Game
@testable import Landscape
@testable import Materials
@testable import MetalRenderer
@testable import Physics
@testable import Plants

/// M0's measurement: what a fast build of a ground grid's structure costs on this GPU, for a sector (64 cells a side)
/// against a whole tile (256), so the terrain's live edits know how many sectors a frame can afford.
final class TerrainBLASSpikeTests: XCTestCase {
    func testSectorAgainstTileBuild() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsRaytracing, let queue = device.makeCommandQueue() else {
            throw XCTSkip("no ray tracing")
        }
        func grid(_ cells: Int) -> MTLBuffer {
            let n = cells + 1
            var positions: [SIMD3<Float>] = []
            for j in 0..<n { for i in 0..<n { positions.append(SIMD3(Float(i), sin(Float(i + j) * 0.1), Float(j))) } }
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
            return buffer
        }
        func time(_ cells: Int, count: Int) -> Double {
            let buffer = grid(cells), n = cells + 1
            let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
            geometry.vertexBuffer = buffer
            geometry.vertexStride = 16
            geometry.indexBuffer = buffer
            geometry.indexBufferOffset = n * n * 16
            geometry.indexType = .uint32
            geometry.triangleCount = cells * cells * 2
            geometry.opaque = true
            let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
            descriptor.geometryDescriptors = [geometry]
            descriptor.usage = .preferFastBuild
            let sizes = device.accelerationStructureSizes(descriptor: descriptor)
            let structures = (0..<count).map { _ in device.makeAccelerationStructure(size: sizes.accelerationStructureSize)! }
            let scratch = device.makeBuffer(length: sizes.buildScratchBufferSize, options: .storageModePrivate)!
            var best = Double.infinity
            for _ in 0..<5 {
                let cmd = queue.makeCommandBuffer()!, enc = cmd.makeAccelerationStructureCommandEncoder()!
                for s in structures { enc.build(accelerationStructure: s, descriptor: descriptor, scratchBuffer: scratch, scratchBufferOffset: 0) }
                enc.endEncoding()
                cmd.commit()
                cmd.waitUntilCompleted()
                best = min(best, (cmd.gpuEndTime - cmd.gpuStartTime) * 1000)
            }
            print(String(format: "Terrain BLAS: %d x %d cells (%d triangles), %d builds: %.2f ms (%.3f ms each), %.0f KB each", cells, cells,
                         cells * cells * 2, count, best, best / Double(count), Double(sizes.accelerationStructureSize) / 1024))
            return best / Double(count)
        }
        _ = time(32, count: 16); _ = time(128, count: 4); let sector = time(64, count: 8), tile = time(256, count: 2)
        print(String(format: "Terrain BLAS: a tile costs %.1f sectors' builds (16 sectors make a tile)", tile / sector))
        XCTAssertGreaterThan(sector, 0)
    }
}
