import EngineCore
import Metal
import simd

/// A garment's cloth on the GPU (Shaders/Garment.metal; GarmentSim is the same on the CPU): its particles' places,
/// velocities and the substep's predictions, its constraints by colour, the spheres and capsules it stays out of, the
/// body's distance field, and what draws its mesh (each particle's triangles, for its normal). A frame's steps are
/// substeps of predict, a solve per colour, and collide; then its vertices into the scene's buffers. What the CPU
/// changes (a new drape, frozen panels) goes through a frame slot's staging buffer and `garmentLoad`, in the GPU's
/// order, never into buffers a frame in flight is using.
package final class GarmentSolverGPU {
    package let particleCount: Int
    package let x: MTLBuffer, v: MTLBuffer, p: MTLBuffer
    let constraints: MTLBuffer
    let colourStarts: [Int]
    let starts: MTLBuffer, corners: MTLBuffer, indices: MTLBuffer
    private let staging: [MTLBuffer]
    private var spheres: MTLBuffer?
    private var sphereCount = 0
    private var sdf: MTLTexture?
    private var dummySDF: MTLTexture
    package var params = GPUGarmentParams()
    /// The scene's vertices it writes from, and where last frame's are.
    package let vertexBase: Int, prevOffset: Int
    /// Self-collision's: each particle's sheet place, panel, layer and seam partners; the hash's counts, starts and
    /// cursors (GARMENT_TABLE each), each particle's cell, the particles by cell, and the pushed places.
    private var selfBuffers: (rest: MTLBuffer, partners: MTLBuffer, counts: MTLBuffer, starts: MTLBuffer, cursors: MTLBuffer,
                              cellOf: MTLBuffer, sorted: MTLBuffer, out: MTLBuffer)?
    package static let hashTable = 32768
    /// A load waiting for the next frame: whole places (`mass` false), or only the inverse masses.
    private var pendingLoad: (values: [SIMD4<Float>], massOnly: Bool)?

    /// `positions` and `invMass` the particles' (a build's), `triangles` its mesh's (particle indices).
    package init(device: MTLDevice, positions: [SIMD3<Float>], invMass: [Float], constraints c: [GPUGarmentConstraint],
                 colourStarts: [Int], triangles: [UInt32], vertexBase: Int, prevOffset: Int, slots: Int) throws {
        particleCount = positions.count
        let n = max(1, positions.count)
        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: max(16, length), options: .storageModeShared) else { throw GPUError.allocation(label) }
            b.label = label
            return b
        }
        let xb = try buffer(n * 16, "garment x"), vb = try buffer(n * 16, "garment v"), pb = try buffer(n * 16, "garment p")
        let xs = zip(positions, invMass).map { SIMD4($0.0, $0.1) }
        xs.withUnsafeBytes { xb.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        xs.withUnsafeBytes { pb.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        memset(vb.contents(), 0, n * 16)
        (x, v, p) = (xb, vb, pb)
        let cb = try buffer(c.count * MemoryLayout<GPUGarmentConstraint>.stride, "garment constraints")
        c.withUnsafeBytes { if $0.count > 0 { cb.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        constraints = cb
        self.colourStarts = colourStarts
        // Each particle's triangles (their first index), for its normal.
        var count = [UInt32](repeating: 0, count: n + 1)
        for i in triangles { count[Int(i) + 1] += 1 }
        for k in 1..<count.count { count[k] += count[k - 1] }
        var next = count
        var list = [UInt32](repeating: 0, count: max(1, triangles.count))
        for t in stride(from: 0, to: triangles.count, by: 3) {
            for k in 0..<3 {
                let i = Int(triangles[t + k])
                list[Int(next[i])] = UInt32(t)
                next[i] += 1
            }
        }
        let sb = try buffer(count.count * 4, "garment starts"), kb = try buffer(list.count * 4, "garment corners")
        let ib = try buffer(triangles.count * 4, "garment indices")
        count.withUnsafeBytes { sb.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        list.withUnsafeBytes { kb.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        triangles.withUnsafeBytes { if $0.count > 0 { ib.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        (starts, corners, indices) = (sb, kb, ib)
        staging = try (0..<slots).map { _ in try buffer(n * 16, "garment staging") }
        self.vertexBase = vertexBase
        self.prevOffset = prevOffset
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        d.textureType = .type3D
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let dummy = device.makeTexture(descriptor: d) else { throw GPUError.allocation("garment sdf") }
        dummySDF = dummy
        params.counts = SIMD4(UInt32(positions.count), UInt32(c.count), 0, 0)
        params.collide = SIMD4(0.002, 0.5, 0.003, 1.5)
        params.seams.x = 1e-8
    }

    package enum GPUError: Error { case allocation(String) }

    /// Self-collision on, within `distance` (params.seams.y), with the build's sheet places and seam partners.
    package func enableSelfCollision(device: MTLDevice, rest: [SIMD4<Float>], partners: [SIMD4<UInt32>], distance: Float) {
        let n = max(1, particleCount), t = GarmentSolverGPU.hashTable
        func buffer(_ length: Int) -> MTLBuffer? { device.makeBuffer(length: max(16, length), options: .storageModeShared) }
        guard rest.count == particleCount, partners.count == particleCount,
              let r = device.makeBuffer(bytes: rest, length: n * 16, options: .storageModeShared),
              let pa = device.makeBuffer(bytes: partners, length: n * 16, options: .storageModeShared),
              let counts = buffer(t * 4), let starts = buffer((t + 1) * 4), let cursors = buffer(t * 4),
              let cellOf = buffer(n * 4), let sorted = buffer(n * 4), let out = buffer(n * 16) else { return }
        selfBuffers = (r, pa, counts, starts, cursors, cellOf, sorted, out)
        params.seams.y = distance
    }

    /// The body's signed distance (a grid of samples, x fastest, `cell` apart from `lo`) as a 3D texture.
    package func setBody(device: MTLDevice, lo: SIMD3<Float>, cell: Float, counts: SIMD3<Int>, values: [Float]) {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .r32Float
        d.width = counts.x; d.height = counts.y; d.depth = counts.z
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return }
        values.withUnsafeBytes {
            t.replace(region: MTLRegionMake3D(0, 0, 0, counts.x, counts.y, counts.z), mipmapLevel: 0, slice: 0,
                      withBytes: $0.baseAddress!, bytesPerRow: counts.x * 4, bytesPerImage: counts.x * counts.y * 4)
        }
        t.label = "garment body"
        sdf = t
        // The texels' centres are the samples: the box from half a cell before the first to half after the last.
        params.sdfLo = SIMD4(lo - cell / 2, cell)
        params.sdfHi = SIMD4(lo + (SIMD3<Float>(counts) - 0.5) * cell, 0)
        params.grabInfo.y = 1
    }

    /// The spheres and capsules the cloth stays out of; `slot` the frame's (each frame its own buffer, written while the
    /// others' frames may still read theirs).
    package func setSpheres(device: MTLDevice, _ s: [GPUGarmentSphere], slot: Int = 0) {
        sphereCount = s.count
        params.spheres.x = UInt32(s.count)
        guard !s.isEmpty else { spheres = nil; return }
        let length = s.count * MemoryLayout<GPUGarmentSphere>.stride
        while sphereRing.count <= slot { sphereRing.append(nil) }
        if sphereRing[slot].map({ $0.length < length }) ?? true {
            sphereRing[slot] = device.makeBuffer(length: max(length, 64 * MemoryLayout<GPUGarmentSphere>.stride), options: .storageModeShared)
        }
        guard let b = sphereRing[slot] else { return }
        s.withUnsafeBytes { b.contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
        spheres = b
    }
    private var sphereRing: [MTLBuffer?] = []

    /// Places for every particle (and their velocities zeroed) at the next frame.
    package func load(_ positions: [SIMD3<Float>], invMass: [Float]) {
        pendingLoad = (zip(positions, invMass).map { SIMD4($0.0, $0.1) }, false)
    }
    /// Only the inverse masses (frozen panels), the places kept.
    package func loadMasses(_ invMass: [Float]) {
        pendingLoad = (invMass.map { SIMD4(0, 0, 0, $0) }, true)
    }

    /// The particles' places as the GPU last left them (a frame or two behind).
    package func positions() -> [SIMD3<Float>] {
        let q = x.contents().bindMemory(to: SIMD4<Float>.self, capacity: particleCount)
        return (0..<particleCount).map { SIMD3(q[$0].x, q[$0].y, q[$0].z) }
    }

    /// A frame: a pending load, then `substeps` substeps of `dt` in all (0: none, the cloth stays where it is).
    package func encode(_ enc: ComputePass, pipelines: Pipelines, slot: Int, substeps: Int, dt: Float) {
        guard particleCount > 0 else { return }
        if let load = pendingLoad {
            pendingLoad = nil
            load.values.withUnsafeBytes { staging[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: min($0.count, staging[slot].length)) }
            var info = SIMD4<UInt32>(UInt32(particleCount), load.massOnly ? 1 : 0, 0, 0)
            enc.setComputePipelineState(pipelines[.garmentLoad])
            enc.setBytes(&info, length: 16, index: 0)
            enc.setBuffer(staging[slot], offset: 0, index: 1)
            enc.setBuffer(x, offset: 0, index: 2)
            enc.setBuffer(v, offset: 0, index: 3)
            dispatch(enc, pipelines[.garmentLoad], particleCount)
        }
        guard substeps > 0 else { return }
        params.gravity.w = dt / Float(substeps)
        var prm = params
        for _ in 0..<substeps {
            enc.setComputePipelineState(pipelines[.garmentPredict])
            enc.setBytes(&prm, length: MemoryLayout<GPUGarmentParams>.stride, index: 0)
            enc.setBuffer(x, offset: 0, index: 1)
            enc.setBuffer(v, offset: 0, index: 2)
            enc.setBuffer(p, offset: 0, index: 3)
            dispatch(enc, pipelines[.garmentPredict], particleCount)
            enc.setComputePipelineState(pipelines[.garmentSolve])
            enc.setBytes(&prm, length: MemoryLayout<GPUGarmentParams>.stride, index: 0)
            enc.setBuffer(constraints, offset: 0, index: 1)
            enc.setBuffer(p, offset: 0, index: 2)
            for k in 0..<(colourStarts.count - 1) {
                var range = SIMD2<UInt32>(UInt32(colourStarts[k]), UInt32(colourStarts[k + 1] - colourStarts[k]))
                guard range.y > 0 else { continue }
                enc.setBytes(&range, length: 8, index: 3)
                dispatch(enc, pipelines[.garmentSolve], Int(range.y))
            }
            let pushed = encodeSelf(enc, pipelines: pipelines, params: &prm)
            enc.setComputePipelineState(pipelines[.garmentCollide])
            enc.setBytes(&prm, length: MemoryLayout<GPUGarmentParams>.stride, index: 0)
            enc.setBuffer(x, offset: 0, index: 1)
            enc.setBuffer(v, offset: 0, index: 2)
            enc.setBuffer(pushed ?? p, offset: 0, index: 3)
            enc.setBuffer(spheres ?? x, offset: 0, index: 4)
            enc.setTexture(sdf ?? dummySDF, index: 0)
            dispatch(enc, pipelines[.garmentCollide], particleCount)
        }
    }

    /// A substep's self-collision: the hash made from the predicted places, each pushed from the others into `out`
    /// (the collision reads it). Nil when it is off.
    private func encodeSelf(_ enc: ComputePass, pipelines: Pipelines, params prm: inout GPUGarmentParams) -> MTLBuffer? {
        guard let s = selfBuffers, prm.seams.y > 0 else { return nil }
        let t = GarmentSolverGPU.hashTable
        enc.setComputePipelineState(pipelines[.garmentHashClear])
        enc.setBuffer(s.counts, offset: 0, index: 0)
        dispatch(enc, pipelines[.garmentHashClear], t)
        enc.setComputePipelineState(pipelines[.garmentHashCount])
        enc.setBytes(&prm, length: MemoryLayout<GPUGarmentParams>.stride, index: 0)
        enc.setBuffer(p, offset: 0, index: 1)
        enc.setBuffer(s.counts, offset: 0, index: 2)
        enc.setBuffer(s.cellOf, offset: 0, index: 3)
        dispatch(enc, pipelines[.garmentHashCount], particleCount)
        enc.setComputePipelineState(pipelines[.garmentHashScan])
        enc.setBuffer(s.counts, offset: 0, index: 0)
        enc.setBuffer(s.starts, offset: 0, index: 1)
        enc.setBuffer(s.cursors, offset: 0, index: 2)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1024, height: 1, depth: 1))
        enc.setComputePipelineState(pipelines[.garmentHashScatter])
        enc.setBytes(&prm, length: MemoryLayout<GPUGarmentParams>.stride, index: 0)
        enc.setBuffer(s.cellOf, offset: 0, index: 1)
        enc.setBuffer(s.cursors, offset: 0, index: 2)
        enc.setBuffer(s.sorted, offset: 0, index: 3)
        dispatch(enc, pipelines[.garmentHashScatter], particleCount)
        enc.setComputePipelineState(pipelines[.garmentSelf])
        enc.setBytes(&prm, length: MemoryLayout<GPUGarmentParams>.stride, index: 0)
        enc.setBuffer(p, offset: 0, index: 1)
        enc.setBuffer(s.rest, offset: 0, index: 2)
        enc.setBuffer(s.partners, offset: 0, index: 3)
        enc.setBuffer(s.starts, offset: 0, index: 4)
        enc.setBuffer(s.sorted, offset: 0, index: 5)
        enc.setBuffer(s.out, offset: 0, index: 6)
        enc.setTexture(sdf ?? dummySDF, index: 0)
        dispatch(enc, pipelines[.garmentSelf], particleCount)
        return s.out
    }

    /// The vertices and normals into the scene's buffers (last frame's first), ahead of the refits.
    package func encodeMesh(_ enc: ComputePass, pipelines: Pipelines, positions: MTLBuffer, normals: MTLBuffer) {
        guard particleCount > 0 else { return }
        var info = SIMD4<UInt32>(UInt32(particleCount), UInt32(vertexBase), UInt32(prevOffset), 0)
        enc.setComputePipelineState(pipelines[.garmentMesh])
        enc.setBytes(&info, length: 16, index: 0)
        enc.setBuffer(x, offset: 0, index: 1)
        enc.setBuffer(starts, offset: 0, index: 2)
        enc.setBuffer(corners, offset: 0, index: 3)
        enc.setBuffer(indices, offset: 0, index: 4)
        enc.setBuffer(positions, offset: 0, index: 5)
        enc.setBuffer(normals, offset: 0, index: 6)
        dispatch(enc, pipelines[.garmentMesh], particleCount)
    }

    /// The resources its kernels reach (for a frame's residency).
    package var resources: [MTLResource] {
        var r: [MTLResource] = [x, v, p, constraints, starts, corners, indices, dummySDF] + staging
        if let spheres { r.append(spheres) }
        if let sdf { r.append(sdf) }
        return r
    }

    private func dispatch(_ enc: ComputePass, _ state: MTLComputePipelineState, _ threads: Int) {
        let width = min(state.threadExecutionWidth * 2, max(threads, 1))
        enc.dispatchThreads(MTLSize(width: max(threads, 1), height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }
}
