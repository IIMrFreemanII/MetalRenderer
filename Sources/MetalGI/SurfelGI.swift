import Metal
import simd

/// Matches `SurfelParams` in Shaders.metal.
struct SurfelParams {
    var gridMin: SIMD4<Float>     // xyz = grid origin, w = cell size
    var gridDims: SIMD4<UInt32>   // xyz = cells, w = cell count
    var config: SIMD4<UInt32>     // x = max surfels, y = rays per surfel, z = frame
    var tuning: SIMD4<Float>      // x = target radius (px), y = max history, z = pixel angle
}

/// Pipelines the surfel passes use (built with the rest of the shaders, so they hot-reload).
struct SurfelPipelines {
    let clear: MTLComputePipelineState
    let begin: MTLComputePipelineState
    let transform: MTLComputePipelineState
    let scan: MTLComputePipelineState
    let scatter: MTLComputePipelineState
    let trace: MTLComputePipelineState
    let gatherSpawn: MTLComputePipelineState
    let lifecycle: MTLComputePipelineState
}

/// Surfel GI: a pool of surfels on scene surfaces that each trace a few rays per frame and accumulate irradiance;
/// pixels gather from the surfels around them (see Shaders.metal). Owns the pool, the spatial grid and the
/// per-frame lists for one pool size.
final class SurfelGI {
    static let cellSize: Float = 0.5        // surfel radius is clamped to half a cell, so a surfel touches <= 8 cells
    static let headerAliveOffset = 0, headerFreeOffset = 4
    static let headerAliveDispatchOffset = 16, headerTraceDispatchOffset = 28

    let maxSurfels: Int
    private let gridMin: SIMD3<Float>
    private let gridDims: SIMD3<Int>
    private var cellCount: Int { gridDims.x * gridDims.y * gridDims.z }

    private let surfels, irradiance0, irradiance1, freeStack, lastUsed, killFlag, aliveList: MTLBuffer
    private let worldPos, worldNormal, worldGeomNormal: MTLBuffer
    private let cellCounts, cellStart, cellCursor, cellSurfels: MTLBuffer
    let header: MTLBuffer                   // shared storage: the CPU reads the alive count / free-stack size
    private let ambient: [MTLBuffer]        // [2] mean surfel irradiance (rgb sums x1024 + count), ping-ponged
    private var needsClear = true
    private var frame = 0

    /// `sceneBounds` = min/max corner of everything that can carry surfels; the grid covers it plus a margin.
    init(device: MTLDevice, maxSurfels: Int, sceneBounds: (SIMD3<Float>, SIMD3<Float>)) throws {
        self.maxSurfels = maxSurfels
        gridMin = sceneBounds.0 - 1
        let extent = sceneBounds.1 + 1 - gridMin
        gridDims = SIMD3(Int((extent.x / SurfelGI.cellSize).rounded(.up)), Int((extent.y / SurfelGI.cellSize).rounded(.up)),
                         Int((extent.z / SurfelGI.cellSize).rounded(.up)))
        let cells = gridDims.x * gridDims.y * gridDims.z
        func buffer(_ length: Int, _ label: String, shared: Bool = false) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: max(length, 16), options: shared ? .storageModeShared : .storageModePrivate) else {
                throw RendererError.resourceCreation("buffer \(label)")
            }
            b.label = label
            return b
        }
        surfels = try buffer(maxSurfels * 64, "surfels")
        irradiance0 = try buffer(maxSurfels * 32, "surfel irradiance0")
        irradiance1 = try buffer(maxSurfels * 32, "surfel irradiance1")
        freeStack = try buffer(maxSurfels * 4, "surfel freeStack")
        lastUsed = try buffer(maxSurfels * 4, "surfel lastUsed")
        killFlag = try buffer(maxSurfels * 4, "surfel killFlag")
        aliveList = try buffer(maxSurfels * 4, "surfel aliveList")
        worldPos = try buffer(maxSurfels * 16, "surfel worldPos")
        worldNormal = try buffer(maxSurfels * 16, "surfel worldNormal")
        worldGeomNormal = try buffer(maxSurfels * 16, "surfel worldGeomNormal")
        cellCounts = try buffer(cells * 4, "surfel cellCount")
        cellStart = try buffer((cells + 1) * 4, "surfel cellStart")
        cellCursor = try buffer(cells * 4, "surfel cellCursor")
        cellSurfels = try buffer(maxSurfels * 8 * 4, "surfel cellSurfels")
        header = try buffer(48, "surfel header", shared: true)
        ambient = [try buffer(16, "surfel ambient0"), try buffer(16, "surfel ambient1")]
    }

    /// Start over with an empty pool (GI mode switch, benchmark setting change, shader reload).
    func reset() { needsClear = true }

    /// Pool counts after the last completed frame. `alive` was counted before that frame's spawns and kills, so a
    /// healthy pool has alive + spawned - killed + free == maxSurfels.
    var stats: (alive: Int, free: Int, spawned: Int, killed: Int) {
        let p = header.contents()
        func load(_ offset: Int) -> Int { Int(p.load(fromByteOffset: offset, as: UInt32.self)) }
        return (load(0), load(4), load(8), load(12))
    }

    func encode(beginPass: (String) -> MTLComputeCommandEncoder?, pipelines: SurfelPipelines, uniforms: inout Uniforms,
                settings: SurfelSettings, bindScene: (MTLComputeCommandEncoder) -> Void, lightMap: MTLTexture,
                normalDepth: MTLTexture, targets t: RenderTargets) {
        let rays = 1 << Int(log2(Double(SurfelSettings.raysRange.clamp(settings.raysPerSurfel))).rounded())
        var params = SurfelParams(
            gridMin: SIMD4(gridMin, SurfelGI.cellSize),
            gridDims: SIMD4(UInt32(gridDims.x), UInt32(gridDims.y), UInt32(gridDims.z), UInt32(cellCount)),
            config: SIMD4(UInt32(maxSurfels), UInt32(rays), uniforms.frameIndex, 0),
            tuning: SIMD4(settings.radiusPixels, max(settings.maxHistory, 1), 2 * uniforms.camUp.w / Float(uniforms.height), 0))
        let (irrPrev, irrCur) = frame & 1 == 0 ? (irradiance0, irradiance1) : (irradiance1, irradiance0)
        let (ambientCur, ambientPrev) = frame & 1 == 0 ? (ambient[0], ambient[1]) : (ambient[1], ambient[0])
        frame += 1

        func bindAll(_ enc: MTLComputeCommandEncoder) {
            let buffers: [(MTLBuffer, Int)] = [
                (header, 10), (aliveList, 11), (cellCounts, 12), (worldPos, 13), (worldNormal, 14), (worldGeomNormal, 15),
                (cellStart, 16), (cellCursor, 17), (cellSurfels, 18), (irrPrev, 19), (irrCur, 20), (lastUsed, 21),
                (surfels, 22), (freeStack, 23), (killFlag, 24), (ambientCur, 25), (ambientPrev, 26),
            ]
            for (b, i) in buffers { enc.setBuffer(b, offset: 0, index: i) }
            bindScene(enc)
            enc.setBytes(&params, length: MemoryLayout<SurfelParams>.stride, index: 0)
            enc.setBytes(&params, length: MemoryLayout<SurfelParams>.stride, index: 9)
        }
        let size64 = MTLSize(width: 64, height: 1, depth: 1)

        if let enc = beginPass("surfel grid") {
            bindAll(enc)
            if needsClear {
                enc.setComputePipelineState(pipelines.clear)
                enc.dispatchThreads(MTLSize(width: max(maxSurfels, cellCount), height: 1, depth: 1), threadsPerThreadgroup: size64)
                // The begin kernel only clears this frame's ambient sums: clear last frame's too.
                enc.setComputePipelineState(pipelines.begin)
                enc.setBuffer(ambientPrev, offset: 0, index: 25)
                enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
                enc.setBuffer(ambientCur, offset: 0, index: 25)
                needsClear = false
            }
            enc.setComputePipelineState(pipelines.begin)
            enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            enc.setComputePipelineState(pipelines.transform)
            enc.dispatchThreads(MTLSize(width: maxSurfels, height: 1, depth: 1), threadsPerThreadgroup: size64)
            enc.setComputePipelineState(pipelines.scan)
            enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1024, height: 1, depth: 1))
            enc.setComputePipelineState(pipelines.scatter)
            enc.dispatchThreadgroups(indirectBuffer: header, indirectBufferOffset: SurfelGI.headerAliveDispatchOffset,
                                     threadsPerThreadgroup: size64)
        }
        if let enc = beginPass("surfel trace") {
            bindAll(enc)
            enc.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setComputePipelineState(pipelines.trace)
            enc.setTexture(lightMap, index: 0)
            enc.dispatchThreadgroups(indirectBuffer: header, indirectBufferOffset: SurfelGI.headerTraceDispatchOffset,
                                     threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        }
        if let enc = beginPass("surfel gather") {
            bindAll(enc)
            enc.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setComputePipelineState(pipelines.gatherSpawn)
            enc.setTextures([t.surfacePos, normalDepth, t.geoNormal, t.indirect, t.giDebug], range: 0..<5)
            // Whole 16x16 tiles: the spawn step reduces over all 256 threads of a tile.
            enc.dispatchThreadgroups(MTLSize(width: (t.width + 15) / 16, height: (t.height + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.setComputePipelineState(pipelines.lifecycle)
            enc.dispatchThreadgroups(indirectBuffer: header, indirectBufferOffset: SurfelGI.headerAliveDispatchOffset,
                                     threadsPerThreadgroup: size64)
        }
    }
}
