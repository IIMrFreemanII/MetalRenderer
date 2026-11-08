import EngineCore
import Metal

/// What MegaLights' visible-light hashes were written for: a frame's are of use to the next one only in the same
/// scene, with the same lights and the same tiles.
package struct MegaLightsHistory: Equatable {
    var scene: Int, lights: Int, tilesX: Int, tilesY: Int, frame: UInt32
}

extension Renderer {
    /// 2e. MegaLights (DirectLightMode.megalights, Shaders/MegaLights.metal), in place of the sampled lights' kernel:
    /// the tiles' light lists, then each pixel's samples. Writes what sampledLightsKernel writes (direct light, the
    /// sampled specular), so the rest of the frame is Sampled's.
    package func megaLightsStages(_ plan: FramePlan, targets t: RenderTargets) -> [ComputeStage] {
        let uniforms = plan.uniforms, slot = plan.slot, cur = plan.cur, size = plan.size
        let m = settings.megaLights
        let tilesX = (size.width + GPUMegaLightsParams.tile - 1) / GPUMegaLightsParams.tile
        let tilesY = (size.height + GPUMegaLightsParams.tile - 1) / GPUMegaLightsParams.tile
        let capacity = MegaLightsSettings.capacityOptions.contains(m.capacity) ? m.capacity : MegaLightsSettings.capacityOptions.last!
        guard let lists = megaLightsTileLists(tiles: tilesX * tilesY, capacity: capacity),
              let guides = megaLightsGuides(tiles: tilesX * tilesY) else { return [] }
        // Last frame's hashes steer the picks if the frame before ran MegaLights on the same scene, lights and tiles.
        let now = MegaLightsHistory(scene: scene.serial, lights: scene.lights.count, tilesX: tilesX, tilesY: tilesY, frame: frameIndex)
        let history = megaLightsLast.map { $0.scene == now.scene && $0.lights == now.lights && $0.tilesX == tilesX
            && $0.tilesY == tilesY && $0.frame == frameIndex &- 1 } ?? false
        megaLightsLast = now
        let guide = guides[Int(frameIndex & 1)], prevGuide = guides[Int((frameIndex &+ 1) & 1)]
        let tree = lightTreeBuffer(slot: slot)   // the far field (built on the first frame that needs it, refit after)

        let flags: UInt32 = (m.guiding && history ? GPUMegaLightsParams.guideValid : 0) | (m.partition ? GPUMegaLightsParams.partition : 0)
        let clamp: Float = plan.accumulating ? 0 : 4 * 10   // 4 x the firefly clamp, as the sampled lights'
        // The cutoff is of exposed light: what it changes on screen doesn't depend on the scene's brightness.
        let cutoff = MegaLightsSettings.cutoffRange.clamp(m.cutoff) / max(uniforms.post.x, 1e-6)
        let samples = MegaLightsSettings.sampleRange.clamp(m.samples)
        let treeSamples = min(MegaLightsSettings.treeSampleRange.clamp(m.treeSamples), samples)
        let params = GPUMegaLightsParams(config: SIMD4(UInt32(samples - treeSamples), UInt32(capacity), flags, UInt32(tilesX)),
                                         tree: SIMD4(UInt32(treeSamples), UInt32(tree?.nodes ?? 0), 0, 0),
                                         tuning: SIMD4(cutoff, MegaLightsSettings.guideWeightRange.clamp(m.guideWeight), clamp, 0))
        let specular = plan.sampledSpecular ?? dummy2D!
        return [ComputeStage(pass: "megalights cull") { [self] enc in
            var p = params
            bind(enc, .megaLightsCull, uniforms, sceneSlot: slot)
            enc.setBytes(&p, length: MemoryLayout<GPUMegaLightsParams>.stride, index: 9)
            enc.setBuffer(lists, offset: 0, index: 10)
            enc.setBuffer(guide, offset: 0, index: 13)
            setTextures(enc, [t.surfacePos, t.normalDepth[cur]])
            // A 16x16 threadgroup a tile.
            enc.dispatchThreadgroups(MTLSize(width: tilesX, height: tilesY, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: GPUMegaLightsParams.tile, height: GPUMegaLightsParams.tile, depth: 1))
        }, ComputeStage(pass: "megalights") { [self] enc in
            var p = params
            bind(enc, .megaLightsSample, uniforms, sceneSlot: slot)
            enc.setBytes(&p, length: MemoryLayout<GPUMegaLightsParams>.stride, index: 9)
            enc.setBuffer(lists, offset: 0, index: 10)
            enc.setBuffer(guide, offset: 0, index: 13)
            enc.setBuffer(prevGuide, offset: 0, index: 14)
            enc.setBuffer(tree?.buffer ?? prevGuide, offset: 0, index: 15)   // (no tree: no lights but suns, not read)
            setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, t.albedo, t.material, t.direct, specular, t.visibility,
                              t.anisotropy, t.sheen, t.geometryDebug])   // (7: the suns' visibility, FLAG_SUN_VISIBILITY; 8, 9: MATERIAL_LOBES;
                                                                        //  10: the light debug views, FLAG_LIGHT_DEBUG)
            // A 16x16 threadgroup a tile, as the cull: it holds the tile's lights in threadgroup memory.
            enc.dispatchThreadgroups(MTLSize(width: tilesX, height: tilesY, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: GPUMegaLightsParams.tile, height: GPUMegaLightsParams.tile, depth: 1))
        }]
    }

    /// The tile lists: per tile its count, the lights that reached it and `capacity` 16-bit light indices. GPU only;
    /// made again when the tiles or the capacity change.
    private func megaLightsTileLists(tiles: Int, capacity: Int) -> MTLBuffer? {
        let length = max(tiles * (capacity + 2) * MemoryLayout<UInt16>.stride, 16)
        if let b = megaLightsTileLists, b.length == length { return b }
        megaLightsTileLists = device.makeBuffer(length: length, options: .storageModePrivate)
        megaLightsTileLists?.label = "megaLightsTileLists"
        return megaLightsTileLists
    }

    /// The visible-light hashes, 128 bits a tile: two, this frame's and last frame's. New ones hold nothing: the
    /// history check (megaLightsLast) keeps their first frame from reading them.
    private func megaLightsGuides(tiles: Int) -> [MTLBuffer]? {
        let length = max(tiles * MemoryLayout<SIMD4<UInt32>>.stride, 16)
        if megaLightsGuides.count == 2, megaLightsGuides[0].length == length { return megaLightsGuides }
        guard let a = device.makeBuffer(length: length, options: .storageModePrivate),
              let b = device.makeBuffer(length: length, options: .storageModePrivate) else { return nil }
        a.label = "megaLightsGuide"; b.label = "megaLightsGuide"
        megaLightsGuides = [a, b]
        megaLightsLast = nil
        return megaLightsGuides
    }
}
