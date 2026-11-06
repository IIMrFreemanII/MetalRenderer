import EngineCore
import Metal

/// Matches `WorldCacheParams` in Shaders/WorldCache.metal.
struct WorldCacheParams {
    var level: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero)       // w = spacing
    var origin: (SIMD4<Int32>, SIMD4<Int32>, SIMD4<Int32>) = (.zero, .zero, .zero)      // xyz = min-corner cell
    var update = SIMD4<UInt32>()   // x = first slot traced, y = per level, z = levels, w = epoch
    var blend = SIMD4<Float>()     // x = hysteresis, y = distance moments' range (spacings), z = 1: sun rays at hits
}

/// Pipelines of the world cache's passes.
struct WRCPipelines {
    let trace: MTLComputePipelineState
    let blend: MTLComputePipelineState
}

/// The world cache (Shaders/WorldCache.metal, WorldCacheSettings): irradiance probes in world space around the camera
/// that give the radiance cascades' hidden hits their light. Owns the probes' atlases and state for one set of settings;
/// `reset` forgets every probe (a new epoch: a probe is valid only for the epoch it was traced in).
package final class WorldRadianceCache {
    let settings: WorldCacheSettings
    private(set) var grid: WorldCacheGrid
    let irradiance: MTLTexture      // rgba16F array, a slice per level: 8x8 tiles, rgb = E / pi, a = backface share
    let distance: MTLTexture        // rg16F array: the tiles' distance moments
    let state: MTLTexture           // rgba32F array, 512 x 32: xyz = a probe's cell, w = its epoch
    private let rays: MTLBuffer     // this frame's rays: float4 per (traced probe, ray)
    private let perLevel: Int
    private var frame: UInt32 = 0
    private var epoch: UInt32 = 1

    /// Forget every probe: they're traced again from nothing (a scene change, a jump of the light).
    func reset() { epoch &+= 1 }

    init(device: MTLDevice, settings: WorldCacheSettings) throws {
        self.settings = settings
        let levels = WorldCacheSettings.levelsRange.clamp(settings.levels)
        grid = WorldCacheGrid(levels: levels, spacing: WorldCacheSettings.spacingRange.clamp(settings.spacing))
        perLevel = WorldCacheGrid.updateRange(frame: 0, updateFrames: WorldCacheSettings.updateFramesRange.clamp(settings.updateFrames)).count
        func make(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ label: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray
            d.pixelFormat = format
            d.width = w
            d.height = h
            d.arrayLength = levels
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        irradiance = try make(.rgba16Float, 512 * 8, 32 * 8, "wrc irradiance")
        distance = try make(.rg16Float, 512 * 8, 32 * 8, "wrc distance")
        state = try make(.rgba32Float, 512, 32, "wrc state")
        guard let b = device.makeBuffer(length: levels * perLevel * WorldCacheGrid.raysPerProbe * MemoryLayout<SIMD4<Float>>.stride,
                                        options: .storageModePrivate) else { throw RendererError.resourceCreation("wrc rays") }
        b.label = "wrc rays"
        rays = b
    }

    /// This frame's parameters, the grid moved to the camera. Call once a frame, before `stages`.
    func params(camera: SIMD3<Float>, hitRays: Bool) -> WorldCacheParams {
        grid.follow(camera: camera)
        let range = WorldCacheGrid.updateRange(frame: frame, updateFrames: WorldCacheSettings.updateFramesRange.clamp(settings.updateFrames))
        frame &+= 1
        var p = WorldCacheParams()
        let levels = grid.spacing.count
        func level(_ l: Int) -> SIMD4<Float> { l < levels ? SIMD4(0, 0, 0, grid.spacing[l]) : SIMD4(0, 0, 0, 1) }
        func origin(_ l: Int) -> SIMD4<Int32> { l < levels ? SIMD4(grid.origin[l], 0) : .zero }
        p.level = (level(0), level(1), level(2))
        p.origin = (origin(0), origin(1), origin(2))
        p.update = SIMD4(UInt32(range.first), UInt32(perLevel), UInt32(levels), epoch)
        p.blend = SIMD4(WorldCacheSettings.hysteresisRange.clamp(settings.hysteresis), 2, hitRays ? 1 : 0, 0)
        return p
    }

    /// Trace this frame's slice of probes, then blend it in. `bindScene` binds buffers 1...8 and 11...12.
    func stages(pipelines: WRCPipelines, uniforms: Uniforms, params: WorldCacheParams, bindScene: @escaping (ComputePass) -> Void,
                lightMap: MTLTexture) -> [ComputeStage] {
        let irradiance = irradiance, distance = distance, state = state, rays = rays
        let traced = Int(params.update.z) * perLevel
        return [
            ComputeStage(pass: "wrc trace") { enc in
                var u = uniforms, p = params
                enc.setComputePipelineState(pipelines.trace)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                bindScene(enc)
                enc.setBytes(&p, length: MemoryLayout<WorldCacheParams>.stride, index: 9)
                enc.setBuffer(rays, offset: 0, index: 10)
                enc.setTextures([lightMap, irradiance, distance, state], range: 0..<4)
                enc.dispatchThreads(MTLSize(width: traced * WorldCacheGrid.raysPerProbe, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            },
            ComputeStage(pass: "wrc blend") { enc in
                var u = uniforms, p = params
                enc.setComputePipelineState(pipelines.blend)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.setBytes(&p, length: MemoryLayout<WorldCacheParams>.stride, index: 9)
                enc.setBuffer(rays, offset: 0, index: 10)
                enc.setTextures([irradiance, distance, state], range: 1..<4)
                enc.dispatchThreadgroups(MTLSize(width: traced, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: WorldCacheGrid.raysPerProbe, height: 1, depth: 1))
            },
        ]
    }
}
