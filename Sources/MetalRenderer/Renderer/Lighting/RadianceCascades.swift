import Buildings
import Characters
import Effects
import EngineCore
import Landscape
import Materials
import Metal
import Physics
import Plants

/// Matches `RCParams` in Shaders/RadianceCascades.metal.
struct RCParams {
    var grids: SIMD4<UInt32>      // xy = this cascade's probe grid, zw = the next cascade's
    var layout: SIMD4<UInt32>     // x = probe spacing (px), y = direction tile side, z = cascade, w = 1 if last
    var interval: SIMD4<Float>    // x = start, y = end (m), z = 1 for multi-bounce feedback, w = 1 with a last frame
}

/// Pipelines the radiance-cascade passes use (built with the rest of the shaders, so they hot-reload).
struct RCPipelines {
    let probe: MTLComputePipelineState
    let traceMerge: MTLComputePipelineState
    let filter: MTLComputePipelineState
    let sh: MTLComputePipelineState
    let clearAmbient: MTLComputePipelineState
    let resolve: MTLComputePipelineState
}

/// Radiance cascades GI: screen-space probes, world-space ray intervals, merged top-down (see Shaders/RadianceCascades.metal).
/// Owns the per-cascade probe textures and radiance atlases for one render size and set of settings.
package final class RadianceCascades {
    struct Cascade {
        let grid: SIMD2<Int>          // probes
        let spacing: Int              // pixels between probes
        let dirSide: Int              // direction tile side (dirSide^2 bins per probe)
        let interval: ClosedRange<Float>
        let probePos: MTLTexture
        let probeNs: MTLTexture
        let probeNg: MTLTexture
        let merged: MTLTexture        // probe-major atlas: probe (x, y) owns texels [x, y] * dirSide ..< +dirSide
        let filtered: MTLTexture?     // cascades 1 and up: rcFilterKernel's first pass (its second writes `merged` again)
    }

    static let maxCascades = 5          // RC_MAX_CASCADES in the shader (CascadeSettings.cascadeRange)

    let width: Int
    let height: Int
    let settings: CascadeSettings
    let cascades: [Cascade]
    private let history: [MTLTexture]   // [2] resolved indirect light, ping-ponged: last frame's feeds multi-bounce
    private let sh: [MTLTexture]        // cascade-0 probes' L1 SH, one texture per colour channel
    private let ambient: [MTLBuffer]    // [2] mean probe irradiance (rgb sums x1024 + count), ping-ponged
    private var frame = 0
    /// Last frame's mean probe irradiance (rgb sums x1024 + count), as this frame's trace reads it: the reflection
    /// pass's light at its hits off screen in the interiors' box (a room's, where the sky's was).
    private(set) var lastAmbient: MTLBuffer?
    private var historyReady = false    // textures start undefined: no feedback until one frame has been resolved

    /// Forget last frame's indirect light (after a reset or teleport).
    func reset() { historyReady = false }

    package init(device: MTLDevice, width: Int, height: Int, settings: CascadeSettings) throws {
        self.width = width
        self.height = height
        self.settings = settings
        func make(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ label: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        precondition(CascadeSettings.cascadeRange.upperBound <= RadianceCascades.maxCascades)
        let count = CascadeSettings.cascadeRange.clamp(settings.cascades)
        let b1 = CascadeSettings.firstIntervalRange.clamp(settings.firstInterval)
        cascades = try (0..<count).map { c in
            let spacing = settings.probeSpacing << c, dirSide = 4 << c
            let grid = SIMD2((width + spacing - 1) / spacing, (height + spacing - 1) / spacing)
            let start: Float = c == 0 ? 0 : b1 * pow(4, Float(c - 1))
            return Cascade(grid: grid, spacing: spacing, dirSide: dirSide, interval: start...(b1 * pow(4, Float(c))),
                           probePos: try make(.rgba32Float, grid.x, grid.y, "rc\(c) probePos"),
                           probeNs: try make(.rgba16Float, grid.x, grid.y, "rc\(c) probeNs"),
                           probeNg: try make(.rgba16Float, grid.x, grid.y, "rc\(c) probeNg"),
                           merged: try make(.rgba16Float, grid.x * dirSide, grid.y * dirSide, "rc\(c) merged"),
                           filtered: c == 0 ? nil : try make(.rgba16Float, grid.x * dirSide, grid.y * dirSide, "rc\(c) filtered"))
        }
        history = [try make(.rgba16Float, width, height, "rc history0"), try make(.rgba16Float, width, height, "rc history1")]
        let g0 = cascades[0].grid
        sh = try ["R", "G", "B"].map { try make(.rgba16Float, g0.x, g0.y, "rc sh\($0)") }
        ambient = try (0..<2).map { i in
            guard let b = device.makeBuffer(length: 16, options: .storageModePrivate) else {
                throw RendererError.resourceCreation("rc ambient")
            }
            b.label = "rc ambient\(i)"
            return b
        }
    }

    private func params(_ c: Int) -> RCParams {
        let k = cascades[c], next = c + 1 < cascades.count ? cascades[c + 1].grid : k.grid
        return RCParams(grids: SIMD4(UInt32(k.grid.x), UInt32(k.grid.y), UInt32(next.x), UInt32(next.y)),
                        layout: SIMD4(UInt32(k.spacing), UInt32(k.dirSide), UInt32(c), c == cascades.count - 1 ? 1 : 0),
                        interval: SIMD4(k.interval.lowerBound, k.interval.upperBound, settings.feedback && historyReady ? 1 : 0,
                                        historyReady ? 1 : 0))
    }

    /// Probes -> trace/merge (top down) -> SH -> resolve into `targets.indirect` and `targets.giDebug`, as stages that
    /// must run in order (each depends on the one before). Also needs this frame's light map and G-buffer (normalDepth,
    /// surfacePos), so the caller runs them after the trace and light-map passes; stage 0 needs only the TLAS.
    /// `bindScene` binds buffers 1...8.
    func stages(pipelines: RCPipelines, uniforms: Uniforms, bindScene: @escaping (ComputePass) -> Void,
                lightMap: MTLTexture, normalDepth: MTLTexture, prevNormalDepth: MTLTexture,
                targets t: RenderTargets) -> [ComputeStage] {
        let cur = frame & 1, prev = cur ^ 1
        frame += 1
        lastAmbient = historyReady ? ambient[prev] : nil
        defer { historyReady = true }
        let cascades = cascades, history = history, sh = sh, ambient = ambient, width = width, height = height

        var stages = [ComputeStage(pass: "rc probes") { enc in
            // All cascades in one flat dispatch; see rcProbeKernel. Unused texture slots repeat cascade 0's.
            var u = uniforms
            enc.setComputePipelineState(pipelines.probe)
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            bindScene(enc)
            var batch = [SIMD4<UInt32>](repeating: .zero, count: RadianceCascades.maxCascades)
            var first = 0
            for (c, k) in cascades.enumerated() {
                batch[c] = SIMD4(UInt32(k.grid.x), UInt32(k.grid.y), UInt32(k.spacing), UInt32(first))
                first += k.grid.x * k.grid.y
            }
            var count = UInt32(cascades.count)
            enc.setBytes(&batch, length: MemoryLayout<SIMD4<UInt32>>.stride * batch.count, index: 9)
            enc.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 10)
            let slots = (0..<RadianceCascades.maxCascades).map { cascades[$0 < cascades.count ? $0 : 0] }
            enc.setTextures(slots.map(\.probePos) + slots.map(\.probeNs) + slots.map(\.probeNg),
                            range: 0..<(3 * RadianceCascades.maxCascades))
            enc.dispatchThreads(MTLSize(width: first, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            // This frame's ambient sums (accumulated by the SH stage; the trace stages read last frame's).
            enc.setComputePipelineState(pipelines.clearAmbient)
            enc.setBuffer(ambient[cur], offset: 0, index: 10)
            enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        }]
        // With walkable interiors (an interiors' box: lo <= hi), the upper cascades' probes are filtered in place
        // (rcFilterKernel, through `filtered`) before the cascade below merges them.
        let interiors = uniforms.interiorLo.x <= uniforms.interiorHi.x
        for c in cascades.indices.reversed() {
            let k = cascades[c], next = c + 1 < cascades.count ? cascades[c + 1] : k
            let p = params(c)
            stages.append(ComputeStage(pass: "rc trace") { enc in
                var u = uniforms, p = p
                enc.setComputePipelineState(pipelines.traceMerge)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                bindScene(enc)
                enc.setBytes(&p, length: MemoryLayout<RCParams>.stride, index: 9)
                enc.setTextures([k.probePos, k.probeNs, k.probeNg, next.probePos, next.probeNs, next.merged, k.merged,
                                 lightMap, prevNormalDepth, history[prev]], range: 0..<10)
                enc.setBuffer(ambient[prev], offset: 0, index: 10)
                enc.dispatchThreads(MTLSize(width: k.grid.x * k.grid.y * k.dirSide * k.dirSide, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            })
            if interiors, let filtered = k.filtered {
                stages.append(ComputeStage(pass: "rc filter") { enc in
                    var u = uniforms, p = p
                    enc.setComputePipelineState(pipelines.filter)
                    enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.setBytes(&p, length: MemoryLayout<RCParams>.stride, index: 9)
                    // merged -> filtered (step 1) -> merged (step 2): the cascade below merges it as ever.
                    for (step, from, to) in [(Int32(1), k.merged, filtered), (Int32(2), filtered, k.merged)] {
                        var step = step
                        enc.setBytes(&step, length: MemoryLayout<Int32>.stride, index: 10)
                        enc.setTextures([k.probePos, k.probeNs, from, to], range: 0..<4)
                        enc.dispatchThreads(MTLSize(width: k.grid.x * k.dirSide, height: k.grid.y * k.dirSide, depth: 1),
                                            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                        if step == 1 { enc.memoryBarrier(scope: .textures) }
                    }
                })
            }
        }
        let p0 = params(0)
        stages.append(ComputeStage(pass: "rc sh") { enc in
            var p = p0
            enc.setComputePipelineState(pipelines.sh)
            enc.setBytes(&p, length: MemoryLayout<RCParams>.stride, index: 9)
            enc.setBuffer(ambient[cur], offset: 0, index: 10)
            enc.setTextures([cascades[0].probePos, cascades[0].merged, sh[0], sh[1], sh[2]], range: 0..<5)
            enc.dispatchThreads(MTLSize(width: cascades[0].grid.x, height: cascades[0].grid.y, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        })
        stages.append(ComputeStage(pass: "rc resolve") { enc in
            var u = uniforms, p = p0
            enc.setComputePipelineState(pipelines.resolve)
            enc.setBytes(&p, length: MemoryLayout<RCParams>.stride, index: 9)
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setTextures([cascades[0].probePos, cascades[0].probeNs, sh[0], sh[1], sh[2], normalDepth, t.surfacePos,
                             t.indirect, history[cur], t.giDebug, prevNormalDepth, history[prev]], range: 0..<12)
            enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        })
        return stages
    }
}
