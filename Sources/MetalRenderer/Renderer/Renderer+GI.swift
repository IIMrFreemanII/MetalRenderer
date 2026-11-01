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
        var gp = regirParams   // the light grid (ReGIR): sampled lights', GI's, the reflections' and the fog's candidates
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
    /// `slot`'s TraceScene: the top-level structure the frame traces, virtual geometry's table, the wind.
    package func writeTraceScene(slot: Int) {
        let plants = sceneBuffers.plants
        traceScene.write(slot: slot, TraceSceneArgs.Content(
            tlas: instanceAS[slot], vgTable: virtualTracing?.vgTable(slot), parts: plants?.parts, meshes: sceneBuffers.meshes,
            indices: sceneBuffers.indices, uvs: sceneBuffers.uvs, wind: windFrame, cutouts: plants?.cutouts,
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
        }
        return settings.giEnabled && !accumulating && wanted && !scene.usesLightTable
    }

    /// References always path trace, so they stay ground truth whatever GI mode is selected.
    package var activeGIMode: GIMode { accumulating ? .pathTraced : settings.giMode }

    package var techniqueDenoisesIndirect: Bool {
        switch activeGIMode {
        case .pathTraced: return true
        case .radianceCascades: return settings.cascades.denoiseIndirect
        }
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
        let definition = scene.settings.kind.definition
        radianceCascades!.skyGaps = definition.cascadeSkyGaps || settings.cascades.skyGaps || (settings.cascades.hitRays && definition.hasPlants)
        radianceCascades!.hiddenLight = definition.cascadeHiddenLight ? settings.cascades.hiddenLight : 1
        return radianceCascades!.stages(pipelines: pipelines.rc, uniforms: plan.uniforms,
                                        bindScene: { [unowned self] in bindScene($0, slot: slot) }, lightMap: lightMap,
                                        normalDepth: t.normalDepth[plan.cur], prevNormalDepth: t.normalDepth[plan.prev], targets: t)
    }

    /// Drops all temporal GI state (cascade feedback, denoiser history).
    package func resetGIState() {
        historyValid = false
        taaHistory = false
        skyRefreshed = nil
        fogLastFrame = nil
        radianceCascades?.reset()
    }
}
