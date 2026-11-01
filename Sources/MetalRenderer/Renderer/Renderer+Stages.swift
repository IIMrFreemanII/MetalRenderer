import AppKit
import Buildings
import Characters
import Effects
import EngineCore
import Landscape
import Materials
import MetalKit
import Physics
import Plants
import QuartzCore
import simd

extension Renderer {
    // MARK: - Frame stages

    /// Starts a kernel's dispatch: its pipeline, the uniforms, and for kernels that trace rays the scene.
    /// `pass`: the kernel's own flags, for the kernels with variants (Kernel.fixedPassFlags).
    package func bind(_ enc: ComputePass, _ kernel: Kernel, _ uniforms: Uniforms, pass: UInt32 = 0, sceneSlot: Int? = nil) {
        var u = uniforms
        // While the blue-noise tile is on its way (a first launch), the general pipelines: a variant for the flags
        // of those few frames would be compiled for nothing.
        let awaitingNoise = settings.blueNoise && !blueNoiseReady
        enc.setComputePipelineState(awaitingNoise ? pipelines[kernel]
                                                  : pipelines.state(kernel, flags: u.flags, pass: pass, wait: benchmark != nil))
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        if let sceneSlot { bindScene(enc, slot: sceneSlot) }
    }

    /// 1a. The light grid's build. It reads only the light and instance buffers, which the CPU wrote.
    package func lightGridStages(_ plan: FramePlan) -> [ComputeStage] {
        guard let grid = plan.lightGrid else { return [] }
        let uniforms = plan.uniforms, slot = plan.slot
        return [ComputeStage(pass: "regir") { [self] enc in
            bind(enc, .regirBuild, uniforms, sceneSlot: slot)
            dispatch(enc, .regirBuild, width: grid.buffer.length / MemoryLayout<GPURegirReservoir>.stride, height: 1)
        }]
    }

    /// 1b. Light-visibility maps. 2. Ray trace: primary visibility (G-buffer), direct light with shadow rays,
    /// path-traced indirect light.
    package func headStages(_ plan: FramePlan, targets t: RenderTargets) -> [ComputeStage] {
        let uniforms = plan.uniforms, slot = plan.slot, cur = plan.cur, size = plan.size
        var stages: [ComputeStage] = []
        if plan.lightMaps {
            stages.append(ComputeStage(pass: "lightmap") { [self] enc in
                bind(enc, .lightMap, uniforms, sceneSlot: slot)
                enc.setTexture(lightMap, index: 0)
                enc.dispatchThreads(MTLSize(width: lightMap.width, height: lightMap.height, depth: scene.lights.count),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            })
        }
        // Liquids: the camera rays bent through them, which the trace goes on with.
        if let liquid = plan.liquid, scene.hasLiquid {
            stages.append(ComputeStage(pass: "liquid") { [self] enc in
                bind(enc, .liquid, uniforms, sceneSlot: slot)
                setTextures(enc, [liquid.ray, liquid.direction, liquid.through, liquid.reflection, blueNoiseTexture])
                dispatch(enc, .liquid, width: size.width, height: size.height)
            })
        }
        // Water: the camera rays bent into it, after the liquids' (a liquid in front keeps its pixels).
        if let liquid = plan.liquid, plan.water {
            stages.append(ComputeStage(pass: "water") { [self] enc in
                bind(enc, .water, uniforms, sceneSlot: slot)
                setTextures(enc, [liquid.ray, liquid.direction, liquid.through, liquid.reflection, blueNoiseTexture, liquid.scatter,
                                  liquid.reflections[1 - cur], liquid.reflections[cur]])
                dispatch(enc, .water, width: size.width, height: size.height)
            })
        }
        stages.append(ComputeStage(pass: "trace") { [self] enc in
            bind(enc, .trace, uniforms, pass: uniforms.tracePassFlags, sceneSlot: slot)
            setTextures(enc, [t.normalDepth[cur], t.albedo, t.emission, t.motion, t.direct, t.indirect,
                              t.deviceDepth, t.pixelMotion, blueNoiseTexture, t.surfacePos, t.geoNormal, lightMap,
                              t.visibility, t.blocker, t.material])
            if let liquid = plan.liquid {
                enc.setTexture(liquid.ray, index: 16)
                enc.setTexture(liquid.direction, index: 17)
            }
            enc.setTexture(t.sheen, index: 18)
            enc.setTexture(t.anisotropy, index: 19)
            dispatch(enc, .trace, width: size.width, height: size.height)
        })
        // Water's surface and what it does to what is seen under it, before window panes (they are in front of it).
        if let liquid = plan.liquid, plan.water {
            stages.append(ComputeStage(pass: "water apply") { [self] enc in
                bind(enc, .waterApply, uniforms, sceneSlot: slot)
                setTextures(enc, [t.albedo, t.emission, t.material, liquid.ray, liquid.through, liquid.reflection, liquid.scatter,
                                  t.normalDepth[cur], t.surfacePos])
                dispatch(enc, .waterApply, width: size.width, height: size.height)
            })
        }
        if plan.glass {
            stages.append(ComputeStage(pass: "glass") { [self] enc in
                bind(enc, .glass, uniforms, sceneSlot: slot)
                setTextures(enc, [t.normalDepth[cur], t.albedo, t.emission, t.material, blueNoiseTexture])
                dispatch(enc, .glass, width: size.width, height: size.height)
            })
        }
        if let liquid = plan.liquid, scene.hasLiquid {
            stages.append(ComputeStage(pass: "liquid") { [self] enc in
                bind(enc, .liquidApply, uniforms)
                setTextures(enc, [t.albedo, t.emission, t.material, liquid.ray, liquid.through, liquid.reflection])
                dispatch(enc, .liquidApply, width: size.width, height: size.height)
            })
        }
        return stages
    }

    /// 1c. The particles' light, once a particle (Shaders/ParticleLight.metal): it needs only the structures.
    package func particleLightStages(_ plan: FramePlan) -> [ComputeStage] {
        guard plan.particles != nil, let gpu = particlesGPU else { return [] }
        let uniforms = plan.uniforms, slot = plan.slot
        return [ComputeStage(pass: "particle light") { [self] enc in
            bind(enc, .particleLight, uniforms, sceneSlot: slot)
            enc.setBuffer(gpu.render[slot], offset: 0, index: 13)
            enc.setBuffer(gpu.lighting, offset: 0, index: 14)
            var n = UInt32(gpu.system.capacity)
            enc.setBytes(&n, length: 4, index: 15)
            dispatch(enc, .particleLight, width: gpu.system.capacity, height: 1)
        }]
    }

    /// 3e. The particles in front of the camera's surfaces, after the fog's grid (they're fogged where they are). The
    /// composite puts the layer over the scene, or particleOverlayKernel over MetalFX's output (which would filter it
    /// with the scene's motion), upsampled by depth where the layer is smaller than the frame (`particleScale`).
    package func particleLayerStages(_ plan: FramePlan, targets t: RenderTargets, composite: inout CompositeInputs) -> [ComputeStage] {
        guard let layer = plan.particles else { return [] }
        if !plan.neuralDenoise { composite.uniforms.flags |= UniformFlags.particles }
        let uniforms = plan.uniforms, slot = plan.slot, cur = plan.cur, size = plan.size
        let fogGrid = plan.fog?.grid.integrated
        var fogParams = plan.fogParams
        // Its rays through the frame's own (jittered) pixels when it is the frame's size and goes in the composite;
        // otherwise through its texels' centres, steady (nothing filters it over time). Over MetalFX's output the
        // overlay traces the thin ones again at its size (`detail`).
        struct Params { var size: SIMD2<UInt32>; var jitter: UInt32; var detail: UInt32 }
        let fits = layer.color.width == size.width && layer.color.height == size.height
        var params = Params(size: SIMD2(UInt32(layer.color.width), UInt32(layer.color.height)), jitter: fits && !plan.neuralDenoise ? 1 : 0,
                            detail: plan.neuralDenoise ? 1 : 0)
        return [ComputeStage(pass: "particle layer") { [self] enc in
            bind(enc, .particleLayer, uniforms, sceneSlot: slot)
            enc.setBytes(&fogParams, length: MemoryLayout<GPUFogParams>.stride, index: 9)
            enc.setBytes(&params, length: MemoryLayout<Params>.stride, index: 10)
            setTextures(enc, [t.normalDepth[cur], layer.color, fogGrid ?? dummy3D, layer.depth])
            dispatch(enc, .particleLayer, width: layer.color.width, height: layer.color.height)
        }]
    }

    /// 2b. The GI technique, if one runs: it writes t.indirect (the path tracer already did, inside traceKernel), after
    /// the trace (its G-buffer) and before the reflections (they read it).
    package func giStages(_ plan: FramePlan, targets t: RenderTargets) -> [ComputeStage] {
        if plan.cascades { return radianceCascadeStages(plan, targets: t) }
        if let grid = plan.restirGIGrid { return restirGIStages(plan, grid: grid, targets: t) }
        return []
    }

    /// 1c. The air along the camera's rays, before the composite reads it.
    package func aerialStages(_ plan: FramePlan) -> [ComputeStage] {
        guard plan.aerial, let lut = aerialLUT, let tLUT = transmittanceLUT, let msLUT = multiScatterLUT else { return [] }
        let uniforms = plan.uniforms
        var params = skyParams
        return [ComputeStage(pass: "aerial") { [self] enc in
            bind(enc, .aerial, uniforms)
            enc.setBytes(&params, length: MemoryLayout<GPUSkyParams>.stride, index: 1)
            setTextures(enc, [tLUT, msLUT, lut])
            dispatch(enc, .aerial, width: lut.width, height: lut.height)
        }]
    }

    /// 2c'. The contact rays: on the G-buffer, for the composite.
    package func contactAOStages(_ plan: FramePlan, targets t: RenderTargets) -> [ComputeStage] {
        guard plan.contactAO else { return [] }
        let uniforms = plan.uniforms, slot = plan.slot, cur = plan.cur, size = plan.size
        var tuning = SIMD2<Float>(RenderSettings.contactAORange.clamp(settings.contactAO), RenderSettings.contactAOReachRange.clamp(settings.contactAOReach))
        return [ComputeStage(pass: "contact AO") { [self] enc in
            bind(enc, .contactAO, uniforms, sceneSlot: slot)
            enc.setBytes(&tuning, length: MemoryLayout<SIMD2<Float>>.stride, index: 9)
            setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, t.contactAO])
            dispatch(enc, .contactAO, width: size.width, height: size.height)
        }]
    }

    /// 2d. Reflections (glTF specular materials): after the GI (they read its result), before the denoisers. The second
    /// group is their own denoiser.
    package func reflectionStages(_ plan: FramePlan, targets t: RenderTargets,
                                  composite: inout CompositeInputs) -> (trace: [ComputeStage], denoise: [ComputeStage]) {
        guard plan.specular else { return ([], []) }
        let uniforms = plan.uniforms, slot = plan.slot, cur = plan.cur, prev = plan.prev, size = plan.size
        let fogParams = plan.fogParams, fogNoise = plan.fog?.noise, restirSpecular = plan.restirGrid?.specular
        let roomAmbient = plan.cascades ? radianceCascades?.lastAmbient : nil
        let trace = [ComputeStage(pass: "reflections") { [self] enc in
            bind(enc, .reflection, uniforms, pass: fogParams.reflectionPassFlags, sceneSlot: slot)
            var fp = fogParams
            enc.setBytes(&fp, length: MemoryLayout<GPUFogParams>.stride, index: 9)
            // The cascades' mean probe light (none: zeros, and its hits off screen keep the sky's).
            if let ambient = roomAmbient { enc.setBuffer(ambient, offset: 0, index: 10) } else {
                var none = SIMD4<UInt32>(repeating: 0)
                enc.setBytes(&none, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 10)
            }
            setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, t.material, blueNoiseTexture, t.indirect, t.specular,
                              fogNoise ?? dummy3D, restirSpecular ?? dummy2D, t.specularHitDistance, t.sheen, t.anisotropy])
            dispatch(enc, .reflection, width: size.width, height: size.height)
        }]
        guard plan.svgf else { return (trace, []) }
        let d = t.denoise[2]
        var denoise = [ComputeStage(pass: "reflections") { [self] enc in
            var inputCount: UInt32 = 1
            bind(enc, .temporal, uniforms)
            enc.setBytes(&inputCount, length: MemoryLayout<UInt32>.stride, index: 1)
            setTextures(enc, [t.specular, t.specular, t.motion, t.normalDepth[cur], t.normalDepth[prev],
                              d.history, d.moments[prev], d.pingA, d.moments[cur]])
            dispatch(enc, .temporal, width: size.width, height: size.height)
        }]
        for i in 0..<2 {
            let pass = d.atrousPass(i)
            denoise.append(ComputeStage(pass: "reflections") { [self] enc in
                var step = Int32(1 << i)
                bind(enc, .atrous, uniforms)
                enc.setBytes(&step, length: MemoryLayout<Int32>.stride, index: 1)
                setTextures(enc, [pass.src, t.normalDepth[cur], pass.dst])
                dispatch(enc, .atrous, width: size.width, height: size.height)
            })
        }
        composite.specular = d.pingB
        return (trace, denoise)
    }

    /// 2e. ReSTIR DI: after the trace (its G-buffer), before the reflections (they add its direct specular) and the
    /// denoiser.
    package func restirStages(_ plan: FramePlan, targets t: RenderTargets) -> [ComputeStage] {
        guard let rg = plan.restirGrid else { return [] }
        let uniforms = plan.uniforms, slot = plan.slot, cur = plan.cur, prev = plan.prev, size = plan.size
        let r = plan.restirSettings
        let temporalValid = r.temporal && plan.restirHistory   // (not the denoiser's history: that follows the denoiser)
        var flags: UInt32 = (temporalValid ? GPURestirParams.temporalValid : 0) | (r.visibilityReuse ? GPURestirParams.visibilityReuse : 0)
            | (plan.restirSplit ? GPURestirParams.split : 0)
        let maxM = UInt32(RestirSettings.maxMRange.clamp(r.maxM))
        let samples = UInt32(RestirSettings.spatialSampleRange.clamp(r.spatialSamples))
        let radius = RestirSettings.radiusRange.clamp(r.radius) * Float(size.width) / 960
        let clamp: Float = plan.accumulating ? 0 : 4 * 10   // 4 x the firefly clamp, as the mesh-light pass
        let candidates = RestirSettings.candidateRange.clamp(r.candidates)
        let params = GPURestirParams(config: SIMD4(UInt32(candidates), maxM, flags, samples),
                                     tuning: SIMD4(radius, 0, clamp, Float(rg.chains)))
        // Last frame's lights, for the temporal reuse: what the frame before wrote into its slot (the GPU reads that
        // buffer for two more frames before the CPU comes back to it). This frame's on a scene's first frame.
        let previousSlot = (slot + Renderer.maxFramesInFlight - 1) % Renderer.maxFramesInFlight
        let previousLights = lightBuffers[frameDataWritten[previousSlot] ? previousSlot : slot]
        var stages = [ComputeStage(pass: "restir") { [self] enc in
            var p = params
            bind(enc, .restirTemporal, uniforms, pass: p.config.z, sceneSlot: slot)
            enc.setBytes(&p, length: MemoryLayout<GPURestirParams>.stride, index: 9)
            enc.setBuffer(previousLights, offset: 0, index: 10)
            setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, t.albedo, t.material, t.motion, t.normalDepth[prev],
                              rg.reservoir[prev], rg.temporal])
            dispatch(enc, .restirTemporal, width: size.width, height: size.height)
        }]
        let passes = RestirSettings.spatialPassRange.clamp(r.spatialPasses)
        flags &= ~GPURestirParams.temporalValid
        for i in 0..<max(passes, 1) {
            let last = i == max(passes, 1) - 1
            let src = i == 0 ? rg.temporal : rg.spatial, dst = last ? rg.reservoir[cur] : rg.spatial
            var p = params
            p.config.z = flags | (last ? GPURestirParams.shade : 0)
            p.config.w = passes == 0 ? 0 : samples
            p.tuning.y = Float(i)
            stages.append(ComputeStage(pass: "restir") { [self] enc in
                var p = p
                bind(enc, .restirSpatial, uniforms, pass: p.config.z, sceneSlot: slot)
                enc.setBytes(&p, length: MemoryLayout<GPURestirParams>.stride, index: 9)
                setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, t.albedo, t.material, src, dst, t.direct, rg.specular,
                                  t.visibility, t.blocker])
                dispatch(enc, .restirSpatial, width: size.width, height: size.height)
            })
        }
        return stages
    }

    /// 2c. Direct light that is sampled per pixel: one light per group with more than 4 lights (manyLightsKernel), and
    /// the emissive-mesh lights. After the trace and before anything that reads direct light or visibility.
    package func sampledLightStages(_ plan: FramePlan, targets t: RenderTargets) -> [ComputeStage] {
        let uniforms = plan.uniforms, slot = plan.slot, cur = plan.cur, prev = plan.prev, size = plan.size
        var stages: [ComputeStage] = []
        if plan.manyLights {
            let reuse = plan.lightReuse
            let config = SIMD4<UInt32>(UInt32(plan.manyLightRays), UInt32(max(settings.manyLightReuse, 0)),
                                       plan.lightPicksValid ? 1 : 0, 0)
            stages.append(ComputeStage(pass: "many lights") { [self] enc in
                var config = config
                bind(enc, reuse ? .manyLightsReuse : .manyLights, uniforms, sceneSlot: slot)
                enc.setBytes(&config, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 9)
                setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, blueNoiseTexture, t.direct, t.visibility, t.blocker,
                                  t.motion, t.normalDepth[prev], t.shadow.reservoir[prev], t.shadow.reservoirWeight[prev],
                                  t.shadow.reservoir[cur], t.shadow.reservoirWeight[cur], t.albedo])
                dispatch(enc, .manyLights, width: size.width, height: size.height)
            })
        }
        if plan.meshLights {
            let shadowDenoiser = plan.shadowDenoiser
            stages.append(ComputeStage(pass: "mesh lights") { [self] enc in
                var addToDirect: UInt32 = shadowDenoiser ? 0 : 1
                bind(enc, .meshLights, uniforms, sceneSlot: slot)
                enc.setBytes(&addToDirect, length: MemoryLayout<UInt32>.stride, index: 9)
                setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, blueNoiseTexture, t.direct, t.meshDirect, t.albedo])
                dispatch(enc, .meshLights, width: size.width, height: size.height)
            })
        }
        return stages
    }

    /// 3b. The shadow denoiser: direct light's per-group visibility through its own temporal and spatial filter.
    package func shadowDenoiseStages(_ plan: FramePlan, targets t: RenderTargets, composite: inout CompositeInputs) -> [ComputeStage] {
        guard plan.shadowDenoiser else { return [] }
        let uniforms = plan.uniforms, cur = plan.cur, prev = plan.prev, size = plan.size
        let d = settings.denoiser, s = t.shadow
        let maxHistory = DenoiserSettings.maxHistoryRange.clamp(d.shadowHistory)
        var stages = [ComputeStage(pass: "shadow temporal") { [self] enc in
            var params = SIMD4<Float>(maxHistory, d.shadowClamp, d.shadowSigma, 0)
            bind(enc, .shadowTemporal, uniforms)
            enc.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            setTextures(enc, [t.visibility, t.blocker, t.motion, t.normalDepth[cur], t.normalDepth[prev], s.history,
                              s.meta[prev], s.pingA, s.meta[cur], s.penumbra, s.tiles])
            // Whole 8x8 threadgroups: each one classifies its tile.
            enc.dispatchThreadgroups(MTLSize(width: (size.width + 7) / 8, height: (size.height + 7) / 8, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        }]
        // Pass 0 writes `history`, which feeds next frame's temporal pass (as in SVGF).
        let chain: [(src: MTLTexture, dst: MTLTexture)] = [(s.pingA, s.history), (s.history, s.pingB), (s.pingB, s.pingA),
                                                           (s.pingA, s.pingB), (s.pingB, s.pingA)]
        let passes = DenoiserSettings.passRange.clamp(d.shadowPasses)
        for (i, pass) in chain.prefix(passes).enumerated() {
            stages.append(ComputeStage(pass: "shadow filter") { [self] enc in
                var params = SIMD4<Float>(maxHistory, d.shadowClamp, d.shadowSigma, Float(1 << i))
                bind(enc, .shadowFilter, uniforms)
                enc.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                setTextures(enc, [pass.src, t.normalDepth[cur], s.penumbra, s.meta[cur], s.tiles, pass.dst])
                dispatch(enc, .shadowFilter, width: size.width, height: size.height)
            })
        }
        composite.illumination = [chain[passes - 1].dst]
        composite.uniforms.flags |= UniformFlags.shadowDenoiser | UniformFlags.separateSignals
        return stages
    }

    /// Reference "Path traced": this frame's paths join the running mean (Shaders/PathTrace.metal), which encodeOutput
    /// tone maps. Nothing to add once it has max samples.
    package func pathTraceStages(_ plan: FramePlan) -> [ComputeStage] {
        guard let pt = plan.pathTrace, pt.params.samples.y > 0 else { return [] }
        let uniforms = plan.uniforms, size = plan.size, slot = plan.slot
        return [ComputeStage(pass: "path trace") { [self] enc in
            var params = pt.params, fog = pt.fog
            bind(enc, .pathTrace, uniforms, sceneSlot: slot)
            enc.setBytes(&fog, length: MemoryLayout<GPUFogParams>.stride, index: 9)
            enc.setBytes(&params, length: MemoryLayout<GPUPathTraceParams>.stride, index: 13)
            enc.setBuffer(lightProxies ?? lightBuffers[slot], offset: 0, index: 14)
            enc.setBuffer(pt.lightTree ?? lightBuffers[slot], offset: 0, index: 15)   // (unread without the tree)
            setTextures(enc, [pt.accum, pt.fogNoise ?? dummy3D])
            dispatch(enc, .pathTrace, width: size.width, height: size.height)
        }]
    }

    /// Benchmark references: this frame's raw light joins the average, which the composite shows.
    package func accumulateStages(_ plan: FramePlan, targets t: RenderTargets, composite: inout CompositeInputs) -> [ComputeStage] {
        guard let accum = plan.accumulation else { return [] }
        let uniforms = plan.uniforms, size = plan.size, averaged = plan.accumCount
        composite.illumination = [accum.direct, accum.indirect]
        composite.specular = accum.specular
        // Tells the composite pass to read the illumination as separate direct + indirect light.
        composite.uniforms.flags |= UniformFlags.denoise | UniformFlags.separateSignals
        if plan.accumFull { return [] }   // Reference's max samples: the average as it is
        return [ComputeStage(pass: "accumulate") { [self] enc in
            var count = averaged
            bind(enc, .accumulate, uniforms)
            enc.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 1)
            setTextures(enc, [t.direct, t.indirect, accum.direct, accum.indirect, t.specular, accum.specular])
            dispatch(enc, .accumulate, width: size.width, height: size.height)
        }]
    }

    /// A signal SVGF filters: its noisy input (two are summed), its history and ping-pong textures, how many a-trous
    /// passes it gets and the uniforms that carry its filter settings.
    private struct DenoiseSignal {
        let noisy: [MTLTexture]
        let targets: DenoiseTargets
        let passes: Int
        let uniforms: Uniforms
    }

    /// The signals SVGF filters this frame, in the order the composite's illumination lists them.
    private func denoiseSignals(_ plan: FramePlan, targets t: RenderTargets) -> [DenoiseSignal] {
        // ReSTIR's direct light: its own edge-stopping, and its variance scaled up (reused samples are correlated).
        var restirUniforms = plan.uniforms
        restirUniforms.denoise.x = DenoiserSettings.luminanceSigmaRange.clamp(settings.restir.denoiseSigma)
        restirUniforms.denoise.w = max(settings.restir.varianceBoost, 1)
        restirUniforms.denoise.y = DenoiserSettings.maxHistoryRange.clamp(settings.restir.denoiseHistory)
        // ReSTIR GI's indirect light: the same, with its own settings.
        let rgi = settings.restirGI
        var restirGIUniforms = plan.uniforms
        restirGIUniforms.denoise.x = DenoiserSettings.luminanceSigmaRange.clamp(rgi.denoiseSigma)
        restirGIUniforms.denoise.w = max(rgi.varianceBoost, 1)
        restirGIUniforms.denoise.y = DenoiserSettings.maxHistoryRange.clamp(rgi.denoiseHistory)
        restirGIUniforms.denoise.z = DenoiserSettings.antiLagRange.clamp(rgi.antiLag)
        func signal(_ noisy: [MTLTexture], _ d: DenoiseTargets, _ passes: Int) -> DenoiseSignal {
            let restirs = plan.restir && d === (plan.restirSplit ? t.denoise[3] : t.denoise[0])
            let uniforms = plan.restirGI && d === t.denoise[1] ? restirGIUniforms : restirs ? restirUniforms : plan.uniforms
            return DenoiseSignal(noisy: noisy, targets: d, passes: passes, uniforms: uniforms)
        }
        var signals: [DenoiseSignal] = []
        // First, so the indirect light stays last: ReSTIR's unshadowed light (no edges to keep), or the mesh lights'.
        if plan.restirSplit { signals.append(signal([t.direct], t.denoise[3], plan.directPasses)) }
        if plan.denoiseMeshLights { signals.append(signal([t.meshDirect], t.denoise[3], settings.denoiser.passes(for: .pathTraced))) }
        if !plan.shadowDenoiser {
            signals.append(signal(plan.separate ? [t.direct] : [t.direct, t.indirect], t.denoise[0], plan.directPasses))
        }
        if plan.separate && plan.denoiseIndirect { signals.append(signal([t.indirect], t.denoise[1], plan.indirectPasses)) }
        return signals
    }

    /// 3. SVGF: one temporal pass and up to five a-trous passes over every signal.
    package func svgfStages(_ plan: FramePlan, targets t: RenderTargets, composite: inout CompositeInputs) -> [ComputeStage] {
        guard plan.svgf else { return [] }
        let signals = denoiseSignals(plan, targets: t)
        guard !signals.isEmpty else { return [] }
        let cur = plan.cur, prev = plan.prev, size = plan.size
        var stages = [ComputeStage(pass: "temporal") { [self] enc in
            for s in signals {
                let d = s.targets
                var inputCount = UInt32(s.noisy.count)
                bind(enc, .temporal, s.uniforms)
                enc.setBytes(&inputCount, length: MemoryLayout<UInt32>.stride, index: 1)
                setTextures(enc, [s.noisy[0], s.noisy.last!, t.motion, t.normalDepth[cur], t.normalDepth[prev],
                                  d.history, d.moments[prev], d.pingA, d.moments[cur]])
                dispatch(enc, .temporal, width: size.width, height: size.height)
            }
        }]
        for i in 0..<(signals.map(\.passes).max() ?? 0) {
            stages.append(ComputeStage(pass: "atrous") { [self] enc in
                var step = Int32(1 << i)
                for s in signals where i < s.passes {
                    let pass = s.targets.atrousPass(i)
                    bind(enc, .atrous, s.uniforms)
                    enc.setBytes(&step, length: MemoryLayout<Int32>.stride, index: 1)
                    setTextures(enc, [pass.src, t.normalDepth[cur], pass.dst])
                    dispatch(enc, .atrous, width: size.width, height: size.height)
                }
            })
        }
        composite.illumination = (plan.shadowDenoiser ? composite.illumination : [])
            + signals.map { $0.targets.atrousPass($0.passes - 1).dst }
        if plan.denoiseMeshLights {
            composite.meshDirect = composite.illumination[1]
            composite.uniforms.flags |= UniformFlags.meshLights
        }
        if plan.restirSplit { composite.meshDirect = composite.illumination[1] }
        if plan.separate { composite.uniforms.flags |= UniformFlags.separateSignals }
        return stages
    }

    /// 3d. Volumetric fog: light the froxel grid in front of the surfaces and integrate it (or, for references, march
    /// every camera ray). It needs the TLAS, the lights and the G-buffer's depth.
    package func fogStages(_ plan: FramePlan, targets t: RenderTargets, composite: inout CompositeInputs) -> [ComputeStage] {
        guard let (g, noise) = plan.fog else { return [] }
        let uniforms = plan.uniforms, slot = plan.slot, cur = plan.cur, prev = plan.prev, size = plan.size
        let fogParams = plan.fogParams, samples = plan.fogSamples
        if let ref = plan.fogReference {
            composite.fogReference = ref
            composite.uniforms.flags |= UniformFlags.fog | UniformFlags.fogReference
            if plan.accumFull { return [] }   // Reference's max samples: the march's average as it is
            return [ComputeStage(pass: "fog") { [self] enc in
                var fp = fogParams, count = samples
                bind(enc, .fogReference, uniforms, sceneSlot: slot)
                enc.setBytes(&fp, length: MemoryLayout<GPUFogParams>.stride, index: 9)
                enc.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 10)
                setTextures(enc, [noise, t.normalDepth[cur], ref])
                dispatch(enc, .fogReference, width: size.width, height: size.height)
            }]
        }
        composite.uniforms.flags |= UniformFlags.fog
        return [
            ComputeStage(pass: "fog") { [self] enc in
                var fp = fogParams
                bind(enc, .fogInject, uniforms, sceneSlot: slot)
                enc.setBytes(&fp, length: MemoryLayout<GPUFogParams>.stride, index: 9)
                setTextures(enc, [blueNoiseTexture, noise, g.scatter[prev], g.scatter[cur], t.normalDepth[cur]])
                enc.dispatchThreads(MTLSize(width: g.columns, height: g.rows, depth: g.slices),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            },
            ComputeStage(pass: "fog") { [self] enc in
                var fp = fogParams
                bind(enc, .fogIntegrate, uniforms)
                enc.setBytes(&fp, length: MemoryLayout<GPUFogParams>.stride, index: 9)
                setTextures(enc, [g.scatter[cur], g.integrated])
                dispatch(enc, .fogIntegrate, width: g.columns, height: g.rows)
            },
        ]
    }
}
