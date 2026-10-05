import Metal

/// Matches `LumenParams` in Shaders/Lumen.metal.
struct LumenParams {
    var grid: SIMD4<UInt32>     // xy = probe grid, z = spacing (px, the direction tile's side), w = frame
    var tuning: SIMD4<Float>    // x = 1 for multi-bounce, y = history length, z = 1 if history is valid, w = 1 to filter
    var options: SIMD4<UInt32>  // x = debug view, y = screen-trace steps (0 = none), z = instances with cards (0 = none)
    var screen: SIMD4<Float>    // x = screen-trace thickness (fraction of the depth), y = its reach (m), z = the fields' reach
    var sdf: SIMD4<UInt32>      // x = 1: trace the mesh fields, y = their instances, z = culling tiles across, w = global levels
}

/// Pipelines the Lumen passes use (built with the rest of the shaders, so they hot-reload).
struct LumenPipelines {
    let probe: MTLComputePipelineState
    let trace: MTLComputePipelineState
    let filter: MTLComputePipelineState
    let sh: MTLComputePipelineState
    let clearAmbient: MTLComputePipelineState
    let resolve: MTLComputePipelineState
    let hzb: MTLComputePipelineState         // the closest-depth pyramid's level 0...
    let hzbReduce: MTLComputePipelineState   // ...and the others (the raster's min reduction)
    let cardCapture: MTLComputePipelineState
    let cardLight: MTLComputePipelineState
    let cardRadiosity: MTLComputePipelineState
    let cardCombine: MTLComputePipelineState
    let cull: MTLComputePipelineState
    let globalBin: MTLComputePipelineState
    let globalCompose: MTLComputePipelineState
}

/// Matches `LumenRadiosityParams` in Shaders/LumenCards.metal.
struct LumenRadiosityParams {
    var rays: UInt32
    var cardInstances: UInt32
    var frame: UInt32
    var on: UInt32
    var levels: UInt32 = 0      // > 0: trace the global field (its levels), else triangles
    var pad = SIMD3<UInt32>(0, 0, 0)
}

/// Lumen-style GI: screen probes on the G-buffer, traced, filtered, resolved and accumulated (see Shaders/Lumen.metal).
/// Owns the probe textures, their radiance atlas and the history for one render size and probe spacing.
final class Lumen {
    let width: Int
    let height: Int
    let spacing: Int
    let grid: SIMD2<Int>
    private let probePos: MTLTexture
    private let probeNs: MTLTexture
    private let probeNg: MTLTexture
    private let radiance: MTLTexture    // probe-major atlas: probe (x, y) owns texels [x, y] * spacing ..< +spacing
    private let filtered: MTLTexture
    private let sh: [MTLTexture]        // L1 SH per probe, one texture per colour channel
    private let history: [MTLTexture]   // [2] accumulated indirect light (a = frames), ping-ponged: also the multi-bounce
    private let rayKind: MTLTexture     // per probe ray: what answered it (the trace-kind debug view)
    private let hzb: MTLTexture         // closest view depth, mipmapped (the screen traces)
    /// The composite's lit diffuse light (FLAG_GI_RADIANCE): next frame's screen-trace hits read it.
    let giRadiance: MTLTexture
    private let placeholder: MTLBuffer  // bound where the cards' buffers go when there are none
    private let tileLists: MTLBuffer    // per culling tile (4x4 probes): the fields' instances around it
    private let tiles: SIMD2<Int>
    private let placeholder3D: MTLTexture
    private let ambient: [MTLBuffer]    // [2] mean probe irradiance (rgb sums x1024 + count), ping-ponged
    private var frame = 0
    private var historyReady = false    // textures start undefined: no history or feedback until one frame is resolved

    /// Forget last frame's indirect light (after a reset or teleport).
    func reset() { historyReady = false }

    init(device: MTLDevice, width: Int, height: Int, spacing: Int) throws {
        self.width = width
        self.height = height
        self.spacing = spacing
        func make(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ label: String, mips: Int = 1) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: mips > 1)
            d.mipmapLevelCount = mips
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        let grid = SIMD2((width + spacing - 1) / spacing, (height + spacing - 1) / spacing)
        self.grid = grid
        probePos = try make(.rgba32Float, grid.x, grid.y, "lumen probePos")
        probeNs = try make(.rgba16Float, grid.x, grid.y, "lumen probeNs")
        probeNg = try make(.rgba32Float, grid.x, grid.y, "lumen probeNg")   // w: its instance's id + 1 (exact as a float)
        radiance = try make(.rgba16Float, grid.x * spacing, grid.y * spacing, "lumen radiance")
        filtered = try make(.rgba16Float, grid.x * spacing, grid.y * spacing, "lumen filtered")
        sh = try ["R", "G", "B"].map { try make(.rgba16Float, grid.x, grid.y, "lumen sh\($0)") }
        history = [try make(.rgba16Float, width, height, "lumen history0"), try make(.rgba16Float, width, height, "lumen history1")]
        rayKind = try make(.r8Unorm, grid.x * spacing, grid.y * spacing, "lumen rayKind")
        hzb = try make(.r32Float, width, height, "lumen hzb", mips: 7)   // cells up to 64 px
        giRadiance = try make(.rgba16Float, width, height, "lumen giRadiance")
        tiles = (grid &+ 3) / 4
        guard let b = device.makeBuffer(length: 64, options: .storageModePrivate),
              let lists = device.makeBuffer(length: tiles.x * tiles.y * 64 * 4, options: .storageModePrivate) else {
            throw RendererError.resourceCreation("lumen")
        }
        placeholder = b
        tileLists = lists
        let d3 = MTLTextureDescriptor()
        d3.textureType = .type3D
        d3.pixelFormat = .r8Snorm
        d3.width = 1; d3.height = 1; d3.depth = 1
        d3.usage = .shaderRead
        d3.storageMode = .private
        guard let t3 = device.makeTexture(descriptor: d3) else { throw RendererError.resourceCreation("lumen") }
        placeholder3D = t3
        ambient = try (0..<2).map { i in
            guard let b = device.makeBuffer(length: 16, options: .storageModePrivate) else {
                throw RendererError.resourceCreation("lumen ambient")
            }
            b.label = "lumen ambient\(i)"
            return b
        }
    }

    /// Cards (capture, light) -> probes -> trace -> filter -> SH -> resolve into `targets.indirect` and `targets.giDebug`,
    /// as stages that must run in order. Needs this frame's G-buffer and light map, so the caller runs them after the
    /// trace and light-map passes. `bindScene` binds buffers 1...8 (and the light grid). `cards`: the surface cache, its
    /// buffers for frame slot `slot` written (LumenCards.update), covering the scene's first `cardInstances` instances.
    func stages(pipelines: LumenPipelines, settings: LumenSettings, uniforms: Uniforms, bindScene: @escaping (ComputePass) -> Void,
                lightMap: MTLTexture, normalDepth: MTLTexture, prevNormalDepth: MTLTexture,
                cards: LumenCards?, cardInstances: Int, scene sdfScene: LumenScene?,
                global: (field: LumenGlobalSDF, levels: [GPULumenClipLevel])?, slot: Int,
                targets t: RenderTargets) -> [ComputeStage] {
        let cur = frame & 1, prev = cur ^ 1
        let params = LumenParams(grid: SIMD4(UInt32(grid.x), UInt32(grid.y), UInt32(spacing), UInt32(truncatingIfNeeded: frame)),
                                 tuning: SIMD4(settings.feedback && historyReady ? 1 : 0, LumenSettings.historyRange.clamp(settings.history),
                                               settings.temporal && historyReady ? 1 : 0, settings.filter ? 1 : 0),
                                 options: SIMD4(UInt32(max(settings.debug, 0)),
                                                settings.screenTraces && historyReady ? UInt32(LumenSettings.screenStepRange.clamp(settings.screenSteps)) : 0,
                                                cards != nil ? UInt32(cardInstances) : 0,
                                                cards != nil && settings.radiosity ? 1 : 0),
                                 screen: SIMD4(LumenSettings.thicknessRange.clamp(settings.thickness),
                                               LumenSettings.screenReachRange.clamp(settings.screenReach),
                                               LumenSettings.meshReachRange.clamp(settings.meshReach), 0),
                                 sdf: SIMD4(settings.trace == .sdf && sdfScene != nil ? 1 : 0, UInt32(sdfScene?.instanceCount ?? 0),
                                            UInt32(tiles.x), UInt32(global?.levels.count ?? 0)))
        let screenTraces = params.options.y > 0
        frame += 1
        historyReady = true
        let grid = grid, spacing = spacing, width = width, height = height
        let probePos = probePos, probeNs = probeNs, probeNg = probeNg, radiance = radiance, filtered = filtered
        let sh = sh, history = history, ambient = ambient, rayKind = rayKind, hzb = hzb, giRadiance = giRadiance
        let one = MTLSize(width: 1, height: 1, depth: 1), tile = MTLSize(width: 8, height: 8, depth: 1)
        let placeholder = placeholder
        let cardBuffers = cards.map { ($0.cards(slot: slot), $0.table(slot: slot)) } ?? (placeholder, placeholder)
        let cardTextures = cards.map { [$0.normalDepth, $0.final] } ?? [filtered, filtered]
        let cardAlbedo = cards?.albedo ?? filtered
        let sdfBuffers = sdfScene.map { [$0.records(slot: slot), $0.table(slot: slot), $0.instances(slot: slot)] }
            ?? [placeholder, placeholder, placeholder]
        let sdfAtlas = sdfScene?.atlas ?? placeholder3D
        let sdfCoarse = sdfScene?.coarse(slot: slot) ?? placeholder
        let tileLists = tileLists, tiles = tiles, culls = params.sdf.x != 0
        let globalTextures = global.map { [$0.field.distance, $0.field.owner] } ?? [placeholder3D, placeholder3D]
        let clipLevels = global?.levels ?? [GPULumenClipLevel(origin: .zero, voxel: .zero)]
        /// The fields' records, card-style table and instances (15...17), their coarse grids (25) and the clip levels (22).
        func bindFields(_ enc: ComputePass) {
            for (i, b) in sdfBuffers.enumerated() { enc.setBuffer(b, offset: 0, index: 15 + i) }
            enc.setBuffer(sdfCoarse, offset: 0, index: 25)
            var levels = clipLevels
            enc.setBytes(&levels, length: levels.count * MemoryLayout<GPULumenClipLevel>.stride, index: 22)
        }

        var stages: [ComputeStage] = []
        if let global, global.field.dirtyCount > 0, let sdfScene {
            // The global field's dirty bricks: their instances, then their cells.
            let dirty = global.field.dirty(slot: slot), bins = global.field.binLists, count = global.field.dirtyCount
            let atlas = sdfScene.atlas
            stages.append(ComputeStage(pass: "lumen global sdf") { enc in
                var n = UInt32(count), listCount = UInt32(sdfScene.instanceCount)
                bindScene(enc)
                enc.setBuffer(dirty, offset: 0, index: 20)
                enc.setBytes(&n, length: 4, index: 21)
                bindFields(enc)
                enc.setBytes(&listCount, length: 4, index: 23)
                enc.setBuffer(bins, offset: 0, index: 24)
                enc.setComputePipelineState(pipelines.globalBin)
                enc.dispatchThreadgroups(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                enc.setComputePipelineState(pipelines.globalCompose)
                enc.setTextures([atlas] + globalTextures, range: 0..<3)
                enc.dispatchThreads(MTLSize(width: count * 512, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            })
        }
        if let cards, cards.captureTiles + cards.lightTiles > 0 {
            let captureTiles = cards.captureTiles, lightTiles = cards.lightTiles, tileBuffer = cards.tiles(slot: slot)
            let radiosity = LumenRadiosityParams(rays: UInt32(LumenSettings.radiosityRayRange.clamp(settings.radiosityRays)),
                                                 cardInstances: UInt32(cardInstances), frame: params.grid.w,
                                                 on: settings.radiosity ? 1 : 0,
                                                 levels: params.sdf.x != 0 && settings.radiosityThroughSDF ? params.sdf.w : 0)
            if captureTiles > 0 {
                stages.append(ComputeStage(pass: "lumen card capture") { enc in
                    var u = uniforms, count = UInt32(captureTiles)
                    enc.setComputePipelineState(pipelines.cardCapture)
                    enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    bindScene(enc)
                    enc.setBuffer(cardBuffers.0, offset: 0, index: 13)
                    enc.setBuffer(tileBuffer, offset: 0, index: 14)
                    enc.setBytes(&count, length: 4, index: 15)
                    enc.setTextures([cards.albedo, cards.normalDepth, cards.emission, cards.indirect], range: 0..<4)
                    enc.dispatchThreads(MTLSize(width: captureTiles * 64, height: 1, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                })
            }
            if lightTiles > 0 { stages.append(ComputeStage(pass: "lumen card light") { enc in
                var u = uniforms, count = UInt32(lightTiles)
                enc.setComputePipelineState(pipelines.cardLight)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                bindScene(enc)
                enc.setBuffer(cardBuffers.0, offset: 0, index: 13)
                enc.setBuffer(tileBuffer, offset: captureTiles * MemoryLayout<SIMD2<UInt32>>.stride, index: 14)
                enc.setBytes(&count, length: 4, index: 15)
                enc.setTextures([cards.albedo, cards.normalDepth, cards.emission, lightMap, cards.direct, cards.final,
                                 cards.indirect], range: 0..<7)
                enc.dispatchThreads(MTLSize(width: lightTiles * 64, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            })
            // Radiosity (reads the cards' light as it was, on its own budget), then what hits read.
            let radiosityTiles = cards.radiosityTiles, stride = MemoryLayout<SIMD2<UInt32>>.stride
            stages.append(ComputeStage(pass: "lumen radiosity") { enc in
                var u = uniforms, rp = radiosity
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                bindScene(enc)
                enc.setBuffer(cardBuffers.0, offset: 0, index: 13)
                enc.setTextures([cards.albedo, cards.normalDepth, cards.emission, lightMap, cards.direct, cards.final,
                                 cards.indirect], range: 0..<7)
                enc.setBytes(&rp, length: MemoryLayout<LumenRadiosityParams>.stride, index: 16)
                enc.setBuffer(cardBuffers.1, offset: 0, index: 17)
                if rp.on != 0 && radiosityTiles > 0 {
                    var count = UInt32(radiosityTiles)
                    enc.setBuffer(tileBuffer, offset: (captureTiles + lightTiles) * stride, index: 14)
                    enc.setBytes(&count, length: 4, index: 15)
                    // The fields, for rays through the global one.
                    enc.setBuffer(sdfBuffers[0], offset: 0, index: 18)
                    enc.setBuffer(sdfBuffers[1], offset: 0, index: 19)
                    enc.setBuffer(sdfCoarse, offset: 0, index: 25)
                    var levels = clipLevels
                    enc.setBytes(&levels, length: levels.count * MemoryLayout<GPULumenClipLevel>.stride, index: 22)
                    enc.setTextures([sdfAtlas] + globalTextures, range: 7..<10)
                    enc.setComputePipelineState(pipelines.cardRadiosity)
                    enc.dispatchThreads(MTLSize(width: radiosityTiles * 4, height: 1, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                }
                var count = UInt32(lightTiles)
                enc.setBuffer(tileBuffer, offset: captureTiles * stride, index: 14)
                enc.setBytes(&count, length: 4, index: 15)
                enc.setComputePipelineState(pipelines.cardCombine)
                enc.dispatchThreads(MTLSize(width: lightTiles * 64, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            }) }
        }

        return stages + [
            ComputeStage(pass: "lumen probes") { enc in
                var u = uniforms, p = params
                enc.setComputePipelineState(pipelines.probe)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.setBytes(&p, length: MemoryLayout<LumenParams>.stride, index: 9)
                enc.setTextures([t.surfacePos, normalDepth, t.geoNormal, probePos, probeNs, probeNg], range: 0..<6)
                enc.dispatchThreads(MTLSize(width: grid.x, height: grid.y, depth: 1), threadsPerThreadgroup: tile)
            },
            ComputeStage(pass: "lumen cull") { enc in
                var p = params
                enc.setBytes(&p, length: MemoryLayout<LumenParams>.stride, index: 9)
                // The fields' instances around each tile of probes.
                if culls {
                    enc.setComputePipelineState(pipelines.cull)
                    enc.setBuffer(sdfBuffers[2], offset: 0, index: 17)
                    enc.setBuffer(tileLists, offset: 0, index: 18)
                    enc.setTexture(probePos, index: 0)
                    enc.dispatchThreadgroups(MTLSize(width: tiles.x, height: tiles.y, depth: 1),
                                             threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                }
                // This frame's ambient sums (accumulated by the SH stage; the trace reads last frame's).
                enc.setComputePipelineState(pipelines.clearAmbient)
                enc.setBuffer(ambient[cur], offset: 0, index: 10)
                enc.dispatchThreads(one, threadsPerThreadgroup: one)
            },
            ComputeStage(pass: "lumen hzb") { enc in
                // The closest-depth pyramid the screen traces march.
                guard screenTraces else { return }
                enc.setComputePipelineState(pipelines.hzb)
                enc.setTextures([normalDepth, hzb], range: 0..<2)
                enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: tile)
                enc.setComputePipelineState(pipelines.hzbReduce)
                for level in 1..<hzb.mipmapLevelCount {
                    var l = UInt32(level)
                    enc.setBytes(&l, length: 4, index: 0)
                    enc.dispatchThreads(MTLSize(width: max(width >> level, 1), height: max(height >> level, 1), depth: 1),
                                        threadsPerThreadgroup: tile)
                }
            },
            ComputeStage(pass: "lumen trace") { enc in
                var u = uniforms, p = params
                enc.setComputePipelineState(pipelines.trace)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                bindScene(enc)
                enc.setBytes(&p, length: MemoryLayout<LumenParams>.stride, index: 9)
                enc.setBuffer(ambient[prev], offset: 0, index: 10)
                enc.setBuffer(cardBuffers.0, offset: 0, index: 13)
                enc.setBuffer(cardBuffers.1, offset: 0, index: 14)
                bindFields(enc)
                enc.setBuffer(tileLists, offset: 0, index: 18)
                enc.setTextures([probePos, probeNg, radiance, lightMap, prevNormalDepth, history[prev], hzb, normalDepth, t.motion,
                                 giRadiance, rayKind] + cardTextures + [sdfAtlas] + globalTextures, range: 0..<16)
                enc.dispatchThreads(MTLSize(width: grid.x * grid.y * spacing * spacing, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            },
            ComputeStage(pass: "lumen filter") { enc in
                var p = params
                enc.setComputePipelineState(pipelines.filter)
                enc.setBytes(&p, length: MemoryLayout<LumenParams>.stride, index: 9)
                enc.setTextures([probePos, probeNs, radiance, filtered], range: 0..<4)
                enc.dispatchThreads(MTLSize(width: grid.x * spacing, height: grid.y * spacing, depth: 1), threadsPerThreadgroup: tile)
            },
            ComputeStage(pass: "lumen sh") { enc in
                var p = params
                enc.setComputePipelineState(pipelines.sh)
                enc.setBytes(&p, length: MemoryLayout<LumenParams>.stride, index: 9)
                enc.setBuffer(ambient[cur], offset: 0, index: 10)
                enc.setTextures([probePos, filtered, sh[0], sh[1], sh[2]], range: 0..<5)
                enc.dispatchThreads(MTLSize(width: grid.x, height: grid.y, depth: 1), threadsPerThreadgroup: tile)
            },
            ComputeStage(pass: "lumen resolve") { enc in
                var u = uniforms, p = params
                enc.setComputePipelineState(pipelines.resolve)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.setBytes(&p, length: MemoryLayout<LumenParams>.stride, index: 9)
                bindScene(enc)   // the instances (the card views)
                enc.setBuffer(cardBuffers.0, offset: 0, index: 13)
                enc.setBuffer(cardBuffers.1, offset: 0, index: 14)
                enc.setTextures([probePos, probeNs, sh[0], sh[1], sh[2], normalDepth, t.surfacePos, t.motion, prevNormalDepth,
                                 history[prev], t.indirect, history[cur], t.giDebug, rayKind] + cardTextures + [cardAlbedo, sdfAtlas]
                                    + globalTextures, range: 0..<20)
                bindFields(enc)
                enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: tile)
            },
        ]
    }
}
