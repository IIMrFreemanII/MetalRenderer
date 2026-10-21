import AppKit
import Buildings
import Characters
import Effects
import EngineCore
import Materials
import MetalKit
import Physics
import Plants
import QuartzCore
import simd

extension Renderer {
    // MARK: - GI techniques

    /// Scene buffers at the indices every ray-tracing kernel uses (1 = TraceScene, 2...8 = geometry, instances, lights).
    package func bindScene(_ enc: ComputePass, slot: Int) {
        // What the scene's argument buffers point at is declared once per encoder (it holds for every dispatch in
        // it, and the frame's stages mostly share one); the bindings are set every time, since the kernels in
        // between use the same indices for their own buffers.
        let declare = sceneDeclaredIn !== enc.declarationScope
        enc.setBuffer(traceScene.buffers[slot], offset: 0, index: 1)
        if declare {
            // The top-level structure and what TraceScene points at; the BLASes it references by their IDs.
            enc.useResources([instanceAS[slot], traceScene.stats] + primitiveASResources + traceSceneResources(slot: slot), usage: .read)
            if pipelines.stats { enc.useResource(traceScene.stats, usage: [.read, .write]) }
        }
        enc.setBuffer(positionBuffer, offset: 0, index: 2)
        enc.setBuffer(normalBuffer, offset: 0, index: 3)
        enc.setBuffer(indexBuffer, offset: 0, index: 4)
        enc.setBuffer(meshBuffer, offset: 0, index: 5)
        // (A scene with blocks of instances: the table a hit finds a record through, the scene's own records being its
        // first.)
        enc.setBuffer(sceneBuffers.instanceTable ?? instanceDataBuffers[slot], offset: 0, index: 6)
        enc.setBuffer(shadingArgs[slot], offset: 0, index: 7)
        var gp = regirParams   // the light grid (ReGIR): ReSTIR DI's, GI's, the reflections' and the fog's candidates
        enc.setBuffer(regirBuffer ?? regirGrid(count: 1), offset: 0, index: 11)
        enc.setBytes(&gp, length: MemoryLayout<GPURegirParams>.stride, index: 12)
        enc.setBuffer(lightBuffers[slot], offset: 0, index: 8)
        guard declare else { return }
        sceneDeclaredIn = enc.declarationScope
        enc.useResources(shadingResources, usage: .read)
        if !slotTextures[slot].isEmpty { enc.useResources(proceduralResources(slot: slot), usage: .read) }
        enc.useResources([skyActive ? skyMap ?? dummyArray : dummyArray, skyActive ? cloudShadowMap ?? dummy2D : dummy2D], usage: .read)
        if scene.hasWater, let water { enc.useResources(water.resources(slot: slot), usage: .read) }
        if let textureStreamer {
            enc.useHeap(textureStreamer.heap)
            enc.useResource(textureStreamer.minLodBuffer(slot: slot), usage: .read)
            enc.useResource(textureStreamer.feedbackBuffer(slot: slot), usage: [.read, .write])
        }
    }
    /// `slot`'s TraceScene: the top-level structure the frame traces, virtual geometry's tables (the cut's clusters),
    /// the wind.
    package func writeTraceScene(slot: Int) {
        let clusters = virtualTracing?.selected(slot: slot)
        let plants = sceneBuffers.plants
        traceScene.write(slot: slot, TraceSceneArgs.Content(
            tlas: instanceAS[slot], vgTable: virtualTracing?.vgTable(slot), clusters: clusters,
            pool: virtualTracing?.pool, parts: plants?.parts, meshes: sceneBuffers.meshes,
            indices: sceneBuffers.indices, uvs: sceneBuffers.uvs, wind: windFrame, cutouts: plants?.cutouts,
            clusterInstance: scene.tracesClusters ? UInt32(sceneBuffers.instanceCount) : .max,
            particleCasters: particlesGPU?.parts[slot].casters?.structure, particleOthers: particlesGPU?.parts[slot].others?.structure,
            particleRender: particlesGPU?.render[slot], particleAtlas: particlesGPU?.atlas,
            particleCounts: particlesGPU?.traceCounts(slot: slot) ?? .zero,
            particleFlags: scene.particlesReflected ? 1 : 0,
            particleTrails: particlesGPU?.trails[slot]?.structure, trailPoints: particlesGPU?.trailPoints[slot],
            trailRecords: particlesGPU?.trailRecords[slot], trailShape: particlesGPU?.trailShape ?? .zero,
            frame: frameIndex, opacity: scene.hasOpacity ? opacityBuffers[slot] : nil, textures: textureTables[slot]))
    }

    /// What `slot`'s TraceScene points at besides the structures.
    private func traceSceneResources(slot: Int) -> [MTLResource] {
        (virtualTracing?.resources(slot: slot) ?? [])
            + (sceneBuffers.plants?.resources(slot: slot) ?? []) + (particlesGPU?.resources(slot: slot) ?? [])
            + (scene.hasOpacity ? [opacityBuffers[slot], textureTables[slot]] + proceduralResources(slot: slot) : [])
    }


    /// Specular shading is on and the scene has materials with a specular lobe (glTF ones).
    package var usesSpecular: Bool { settings.specular && scene.hasSpecular }

    package var usesLightMaps: Bool {
        let wanted: Bool
        switch activeGIMode {
        case .pathTraced: wanted = settings.lightMaps
        case .radianceCascades: wanted = true
        case .restirGI: wanted = settings.restirGI.lightMaps
        }
        return settings.giEnabled && !accumulating && wanted && !scene.usesLightTable
    }

    /// References always path trace, so they stay ground truth whatever GI mode is selected (but
    /// METALRENDERER_BENCH=restirgicheck, which accumulates ReSTIR GI against them).
    package var activeGIMode: GIMode { accumulating ? referenceGIMode ?? .pathTraced : settings.giMode }

    package var techniqueDenoisesIndirect: Bool {
        switch activeGIMode {
        case .pathTraced: return true
        case .radianceCascades: return settings.cascades.denoiseIndirect
        case .restirGI: return settings.restirGI.denoise
        }
    }

    package func restirGITargets(width: Int, height: Int) -> RestirGITargets? {
        if let r = restirGIGrid, r.width == width, r.height == height { return r }
        restirGIGrid = try? RestirGITargets(device: device, width: width, height: height)
        restirGIWritten = false
        return restirGIGrid
    }

    /// ReSTIR GI's stages for this frame: initial paths, temporal reuse, spatial reuse (the last pass writes t.indirect).
    package func restirGIStages(_ plan: FramePlan, grid g: RestirGITargets, targets t: RenderTargets) -> [ComputeStage] {
        let uniforms = plan.uniforms, slot = plan.slot, cur = plan.cur, prev = plan.prev
        let r = settings.restirGI
        let width = t.width, height = t.height
        let lightMaps = plan.lightMaps && r.lightMaps
        // Multi-bounce feedback: last frame's indirect light, denoised (still in the denoiser's ping-pong textures until
        // this frame's denoiser runs) or raw (kept by the last spatial pass).
        let denoisedFeedback = t.denoise[1].atrousPass(DenoiserSettings.passRange.clamp(r.denoisePasses) - 1).dst
        let useDenoised = r.denoisedFeedback && r.denoise && plan.svgf
        let feedbackSource = useDenoised ? denoisedFeedback : g.feedback[prev]
        let feedback = r.feedback && plan.restirGIHistory && (plan.history || !useDenoised)
        var flags: UInt32 = (r.temporal && plan.restirGIHistory ? GPURestirGIParams.temporalValid : 0)
            | (lightMaps ? GPURestirGIParams.lightMaps : 0) | (feedback ? GPURestirGIParams.feedback : 0)
            | (r.feedback ? GPURestirGIParams.feedbackSet : 0)
            | (r.unbiased ? GPURestirGIParams.unbiased : 0) | (r.feedback && !useDenoised ? GPURestirGIParams.keepFeedback : 0)
            | (r.feedback && r.feedbackFallback ? GPURestirGIParams.fallback : 0)
        let maxM = UInt32(RestirGISettings.maxMRange.clamp(r.maxM))
        let samples = UInt32(RestirGISettings.spatialSampleRange.clamp(r.spatialSamples))
        let radius = RestirGISettings.radiusRange.clamp(r.radius) * Float(width) / 960
        let clamp: Float = plan.accumulating ? 0 : 4 * 10   // 4 x the firefly clamp, as ReSTIR DI
        let params = GPURestirGIParams(config: SIMD4(flags, maxM, samples, 0),
                                       tuning: SIMD4(radius, max(r.minDistance, 0), clamp, 0),
                                       extra: SIMD4(r.quarterBudget ? 1 : 0, UInt32(RenderSettings.bounceRange.clamp(r.bounces)),
                                                    UInt32(RestirGISettings.maxAgeRange.clamp(r.maxAge)), 0))
        var stages: [ComputeStage] = []
        stages.append(ComputeStage(pass: "restir gi initial") { [self] enc in
            var p = params
            bind(enc, .restirGIInitial, uniforms, pass: p.initialPassFlags, sceneSlot: slot)
            enc.setBytes(&p, length: MemoryLayout<GPURestirGIParams>.stride, index: 9)
            setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, blueNoiseTexture, lightMap, t.normalDepth[prev],
                              feedbackSource, g.spatial.a, g.spatial.b])
            enc.setBuffer(g.ambient[prev], offset: 0, index: 10)
            if r.quarterBudget { dispatch(enc, .restirGIInitial, width: (width + 1) / 2, height: (height + 1) / 2) }
            else { dispatch(enc, .restirGIInitial, width: width, height: height) }
        })
        stages.append(ComputeStage(pass: "restir gi temporal") { [self] enc in
            var p = params
            bind(enc, .restirGITemporal, uniforms)
            enc.setBytes(&p, length: MemoryLayout<GPURestirGIParams>.stride, index: 9)
            setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, t.motion, t.normalDepth[prev], g.spatial.a, g.spatial.b,
                              g.reservoir[prev].a, g.reservoir[prev].b, g.temporal.a, g.temporal.b])
            enc.setBuffer(g.ambient[cur], offset: 0, index: 10)
            dispatch(enc, .restirGITemporal, width: width, height: height)
        })
        let passes = RestirGISettings.spatialPassRange.clamp(r.spatialPasses)
        flags &= ~GPURestirGIParams.temporalValid
        for i in 0..<max(passes, 1) {
            let last = i == max(passes, 1) - 1
            let src = i == 0 ? g.temporal : g.spatial, dst = last ? g.reservoir[cur] : g.spatial
            var p = params
            p.config.x = flags | (last ? GPURestirGIParams.shade : 0)
            p.config.z = passes == 0 ? 0 : samples
            p.config.w = UInt32(i)
            stages.append(ComputeStage(pass: "restir gi spatial") { [self] enc in
                var p = p
                bind(enc, .restirGISpatial, uniforms, sceneSlot: slot)
                enc.setBytes(&p, length: MemoryLayout<GPURestirGIParams>.stride, index: 9)
                setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, src.a, src.b, dst.a, dst.b, t.indirect, t.giDebug,
                                  g.feedback[cur]])
                enc.setBuffer(g.ambient[cur], offset: 0, index: 10)
                dispatch(enc, .restirGISpatial, width: width, height: height)
            })
        }
        return stages
    }

    /// Radiance-cascade stages for this frame (they write t.indirect and t.giDebug); empty if allocation failed.
    package func radianceCascadeStages(_ plan: FramePlan, targets t: RenderTargets) -> [ComputeStage] {
        let slot = plan.slot
        if radianceCascades == nil || radianceCascades!.width != t.width || radianceCascades!.height != t.height
            || radianceCascades!.settings != settings.cascades {
            do {
                radianceCascades = try RadianceCascades(device: device, width: t.width, height: t.height,
                                                        settings: settings.cascades)
            } catch {
                print(error)
                return []
            }
        }
        return radianceCascades!.stages(pipelines: pipelines.rc, uniforms: plan.uniforms,
                                        bindScene: { [unowned self] in bindScene($0, slot: slot) }, lightMap: lightMap,
                                        normalDepth: t.normalDepth[plan.cur], prevNormalDepth: t.normalDepth[plan.prev], targets: t)
    }

    /// Drops all temporal GI state (cascade feedback, denoiser history).
    package func resetGIState() {
        historyValid = false
        taaHistory = false
        restirWritten = false
        restirGIWritten = false
        skyRefreshed = nil
        fogLastFrame = nil
        radianceCascades?.reset()
    }
}
