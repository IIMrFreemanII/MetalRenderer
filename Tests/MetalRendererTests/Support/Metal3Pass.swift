import Metal
@testable import EngineCore

/// A `ComputePass` straight through to a Metal 3 compute encoder: the tests run the frame's stages on their own
/// command buffers with it. (The app's frames are Metal 4's: Metal4Frame.)
struct Metal3Pass: ComputePass {
    let enc: MTLComputeCommandEncoder
    var declarationScope: AnyObject { enc }

    func setComputePipelineState(_ state: MTLComputePipelineState) { enc.setComputePipelineState(state) }
    func setBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) { enc.setBytes(bytes, length: length, index: index) }
    func setBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int) { enc.setBuffer(buffer, offset: offset, index: index) }
    func setTexture(_ texture: MTLTexture?, index: Int) { enc.setTexture(texture, index: index) }
    func setTextures(_ textures: [MTLTexture?], range: Range<Int>) { enc.setTextures(textures, range: range) }
    func setAccelerationStructure(_ accelerationStructure: MTLAccelerationStructure?, bufferIndex: Int) {
        enc.setAccelerationStructure(accelerationStructure, bufferIndex: bufferIndex)
    }
    func useResource(_ resource: MTLResource, usage: MTLResourceUsage) { enc.useResource(resource, usage: usage) }
    func useResources(_ resources: [MTLResource], usage: MTLResourceUsage) { enc.useResources(resources, usage: usage) }
    func useHeap(_ heap: MTLHeap) { enc.useHeap(heap) }
    func memoryBarrier(scope: MTLBarrierScope) { enc.memoryBarrier(scope: scope) }
    func dispatchThreads(_ threadsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize) {
        enc.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }
    func dispatchThreadgroups(_ threadgroupsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize) {
        enc.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }
    func dispatchThreadgroups(indirectBuffer: MTLBuffer, indirectBufferOffset: Int, threadsPerThreadgroup: MTLSize) {
        enc.dispatchThreadgroups(indirectBuffer: indirectBuffer, indirectBufferOffset: indirectBufferOffset,
                                 threadsPerThreadgroup: threadsPerThreadgroup)
    }

}
