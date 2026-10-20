import AppKit
import MetalKit
import QuartzCore
import simd

extension Renderer {
    // MARK: - Frame encoding

    /// The frame's encoder (ComputePass.swift) for the API in use.
    func makeFrame(_ plan: FramePlan, profile: GPUProfiler.Frame?) -> FrameEncoder? {
        if builtAPI == .metal4, #available(macOS 26.0, *) {
            let frame = metal4?.begin(slot: plan.slot, split: plan.splitPasses, overlap: plan.overlap)
            frame?.mipKernels = (pipelines[.mipDown2D], pipelines[.mipDown2DArray])
            return frame
        }
        return Metal3Frame(queue: queue, profile: profile, split: plan.splitPasses, overlap: plan.overlap)
    }

    /// The frame's compute stages by group, each group in the order it runs.
    struct FrameStages {
        var lightGrid: [ComputeStage] = []           // 1a. the light grid, before everything that samples lights
        var head: [ComputeStage] = []                // 1b, 2. light maps, the trace
        var gi: [ComputeStage] = []                  // 2b. radiance cascades or ReSTIR GI (they write t.indirect)
        var restir: [ComputeStage] = []              // 2e. ReSTIR DI
        var reflections: [ComputeStage] = []         // 2d. after the GI (they read its result)
        var fog: [ComputeStage] = []                 // 3d. first of the stages below
        var denoise: [ComputeStage] = []             // 2c, 3. sampled direct light, the denoisers
        var reflectionDenoise: [ComputeStage] = []
    }

    /// What the composite reads. The stage builders fill it in as they decide where each signal ends up.
    struct CompositeInputs {
        var uniforms: Uniforms            // the frame's, plus the flags that tell the composite how to read the rest
        var illumination: [MTLTexture]    // denoised light: one signal, or direct then indirect (the indirect is last)
        var specular: MTLTexture
        var meshDirect: MTLTexture
        var fogReference: MTLTexture?
    }

    /// The scene's structures for this frame, ahead of everything that traces rays.
    func encodeSceneUpdate(slot: Int, lod: VGView, passes: FrameEncoder) {
        // Rigid bodies: the steps since last frame (or a replay from the start), then every body's instance record,
        // and Metal's descriptor, where they are now. Ahead of everything that reads the instances.
        // Cloths too: their vertices, from where the physics (or the CPU's) left them.
        var deformed = false
        if let physicsGPU, let enc = passes.compute("physics", serial: true, concurrent: physicsGPU.hasFluid) {
            physicsGPU.concurrent = physicsGPU.hasFluid   // (its own barriers: the liquids' steps side by side)
            if physicsGPU.simulates {
                // With liquids a replay (a still at 5 s: 300 steps) would keep the GPU for seconds in one command
                // buffer, past the watchdog: it catches up over the next frames instead.
                // (Liquids and fractured objects: 20 steps a frame at most, so that a replay of thousands of bodies
                // stays under the GPU's watchdog; the rest wait for the next frames.)
                let (steps, restart) = scene.takePhysicsSteps(limit: physicsGPU.hasFluid || physicsGPU.fractures ? 20 : .max)
                physicsGPU.sendCommands()
                if steps > 0 || restart { physicsGPU.liquidFrames = Renderer.maxFramesInFlight + 1 }
                if restart { physicsGPU.encodeReset(enc, pipelines: pipelines) }
                physicsGPU.encodeSteps(enc, pipelines: pipelines, steps: steps, slot: slot)
                let descriptors = !sceneBuffers.still ? instanceDescBuffers[slot] : nil
                physicsGPU.encodePose(enc, pipelines: pipelines, slot: slot, instances: instanceDataBuffers[slot], descriptors: descriptors,
                                      descriptorStride: instanceDescriptorStride)
            }
            physicsGPU.encodeClothMesh(enc, pipelines: pipelines, slot: slot, positions: positionBuffer, normals: normalBuffer)
            physicsGPU.encodeSoftMesh(enc, pipelines: pipelines, slot: slot, positions: positionBuffer, normals: normalBuffer)
            physicsGPU.encodeHairCurves(enc, pipelines: pipelines, slot: slot, positions: positionBuffer)
            // The liquids' surfaces (and their structures), while they move and a few frames after: paused, they stay.
            let liquids = physicsGPU.hasFluid && physicsGPU.liquidFrames > 0
            if liquids {
                physicsGPU.encodeFluidSurfaces(enc, pipelines: pipelines, positions: positionBuffer, normals: normalBuffer, indices: indexBuffer)
                physicsGPU.liquidFrames -= 1
            }
            deformed = physicsGPU.hasCloth || physicsGPU.hasSoftBodies || physicsGPU.hasHair || liquids
            passes.endCompute()
        }
        // Mesh particles (debris): their instances where the particles are, ahead of the top level. (Their steps run
        // after it, with the billboards': below.)
        if let particlesGPU, particlesGPU.system.meshCapacity > 0, let enc = passes.compute("particle meshes", serial: true) {
            particlesGPU.encodeMeshPose(enc, pipelines: pipelines, instances: instanceDataBuffers[slot],
                                        descriptors: !sceneBuffers.still ? instanceDescBuffers[slot] : nil, descriptorStride: instanceDescriptorStride)
            passes.endCompute()
        }
        // 0. The crowd: this frame's poses and skinned vertices. Then the deforming meshes' (the pose slots', cloths')
        //    bottom-level structures around them (a refit: a pose keeps its triangles, so its tree keeps its shape).
        //    Ahead of the top level, which takes the new bounds.
        if let crowdSkinner, !CrowdSkinner.frozen {
            if let enc = passes.compute("skin", serial: true) {
                crowdSkinner.encode(enc, pose: pipelines[.crowdPose], skin: pipelines[.crowdSkin], hair: pipelines[.crowdHair], slot: slot,
                                    positions: positionBuffer, normals: normalBuffer)
                passes.endCompute()
            }
            deformed = true
        }
        if deformed, let primitiveRefit {
            // A liquid's surface: built over as many triangles as it last needed (read back a few frames late), with
            // room to grow by a fifth (a pour's surface grows by a few percent over those frames; past it, the
            // triangles left out wait a frame). The build's time is its triangles': on the M1 Max about 5 ms for 100k.
            if let fluid = physicsGPU?.fluid {
                for (i, m) in primitiveRefit.rebuiltMeshes.enumerated() {
                    guard let s = scene.liquidMeshes.first(where: { $0.mesh == m })?.system else { continue }
                    let room = Int(fluid.systems[s].system.surface.triangles.x), used = Int(fluid.readSurfaceStats(s).y)
                    primitiveRefit.setTriangles(i, min(room, (used * 6 / 5 + 2048 + 1023) / 1024 * 1024))
                }
            }
            passes.updatePrimitives(primitiveRefit, pass: "blas")
        }
        encodeDisplacement(passes: passes)
        encodeTerrain(slot: slot, passes: passes)
        encodeWaterWaves(slot: slot, passes: passes)
        encodePainting(passes: passes)
        // The plants' variants in the wind: their parts posed, then their structures refitted (and once more at rest).
        if let plants = sceneBuffers.plants, plants.needsPosing(slot: slot, wind: windFrame) {
            if let enc = passes.compute("wind", serial: true) {
                plants.encodeWind(enc, slot: slot, pipeline: pipelines[.plantWind], wind: windFrame)
                passes.endCompute()
            }
            passes.updatePrimitives(plants.refit(slot: slot), pass: "wind")
        }
        // Virtual geometry as clusters: this frame's cut and its boxes, then the structure over them.
        if let clusters = virtualTracing?.clusters {
            if let enc = passes.compute("vg", serial: true) {
                clusters.encode(enc, slot: slot, vg: pipelines.vg, instanceData: instanceDataBuffers[slot], camPos: lod.camPos,
                                pixelScale: lod.pixelScale, tau: lod.tau, frame: lod.frame)
                passes.endCompute()
            }
            passes.updatePrimitives(clusters.build(slot: slot), pass: "vg")
        }
        // 1. Update the top-level acceleration structure with this frame's instance transforms. A refit (new bounds,
        //    same tree) costs a quarter of a rebuild, but the tree degrades as objects drift from where they were when
        //    it was built: in the old stress hall (400 moving objects) rays got 35% slower after 256 refits. A rebuild
        //    every 16 frames (per slot) traces as fast as one every frame, for the refit's median cost. A new cut of
        //    virtual geometry (another BLAS under an instance) is a rebuild too.
        //    A still scene's was built with its buffers, and stays.
        if !sceneBuffers.still, instanceASStale[slot] || !instanceASBuilt.contains(slot) {
            if Int(frameIndex) % Renderer.tlasRebuildInterval < Renderer.maxFramesInFlight { instanceASBuilt.remove(slot) }
            if virtualTracing?.clusters != nil { instanceASBuilt.remove(slot) }   // its boxes' structure is new every frame
            let refit = instanceASBuilt.contains(slot)
            passes.updateTLAS(TLASUpdate(structure: instanceAS[slot], scratch: instanceScratch[slot], refit: refit,
                                         instanceCount: sceneBuffers.structureInstances, usage: Renderer.tlasUsage,
                                         instances: instanceDescBuffers[slot], instanceStride: instanceDescriptorStride,
                                         primitives: primitiveAS + (virtualTracing?.structures(slot: slot) ?? [])
                                            + (sceneBuffers.plants?.structures(slot: slot) ?? []),
                                         indirect: sceneBuffers.indirect), pass: "tlas")
            instanceASBuilt.insert(slot)
            slotRefitFrame[slot] = Int(frameIndex)
        }
        // 2. Particle effects: the steps since last frame (or a replay from the start; their scene collisions trace this
        //    frame's TLAS), then this slot's records and boxes and the structures over them, which only the particle
        //    queries trace (not in the TLAS). A slot built at these steps already (time paused) keeps its structures.
        if let particlesGPU {
            // The editor's edit whose code was compiling: in once it is ready.
            if let pending = pendingEffects {
                if let source = pending.system.programSource {
                    if let kernels = VFXCompiler.shared.kernels(for: source, setup: vfxSetup, device: device, compiler: compiler(for: pipelines.api),
                                                                wait: benchmark != nil) {
                        adoptEffects(pending, kernels: kernels)
                    } else if VFXCompiler.shared.failure(for: source, setup: vfxSetup) != nil {
                        pendingEffects = nil   // the old code keeps running; the editor says why
                    }
                } else {
                    adoptEffects(pending, kernels: nil)
                }
            }
            // An effect's programs (VFXProgram): the VFX library's kernels once compiled (benchmarks wait for them), then
            // a replay from the start with them, so what is drawn doesn't depend on when the compile finished.
            if particlesGPU.hasPrograms, particlesGPU.programKernels == nil, let source = particlesGPU.system.programSource,
               let kernels = VFXCompiler.shared.kernels(for: source, setup: vfxSetup, device: device, compiler: compiler(for: pipelines.api),
                                                        wait: benchmark != nil) {
                particlesGPU.programKernels = kernels
                scene.replayParticles()
            }
            // (Fractured objects' dust comes from the physics' steps, 20 a frame at most in a replay: these keep up with them.)
            let (steps, restart) = scene.takeParticleSteps(limit: particlesGPU.breakRing != nil ? 20 : ParticlesGPU.maxStepsPerFrame)
            // The camera's footprint widens the billboards (their boxes with them): posed again as it moves, paused too.
            let layerScale: Float = settings.particleScale < 1 ? 0.5 : 1
            let camera = SIMD4(lod.camPos, 1 / max(lod.pixelScale * layerScale, 1e-6))
            if steps > 0 || restart || camera != particlesCamera { particlesVersion += 1 }
            particlesCamera = camera
            if particlesBuilt[slot] != particlesVersion, let enc = passes.compute("particles", serial: true) {
                if restart { particlesGPU.encodeReset(enc, pipelines: pipelines, slot: slot) }
                if steps > 0 { writeCPUBreaks(first: particlesGPU.stepIndex, count: steps) }
                particlesGPU.encodeSteps(enc, pipelines: pipelines, steps: steps, slot: slot, wind: windFrame.wind) { [self] in
                    bindScene($0, slot: slot)
                }
                particlesGPU.encodePose(enc, pipelines: pipelines, slot: slot, camera: camera)
                passes.endCompute()
                if let build = particlesGPU.build(slot: slot) { passes.updatePrimitives(build, pass: "particle build") }
                particlesBuilt[slot] = particlesVersion
                writeTraceScene(slot: slot)   // the structures' new sizes (written above with the last ones)
            }
        }
        // Streamed textures: map and upload the levels last frame's hits asked for, ahead of this frame's work.
        if let textureStreamer {
            passes.streamTextures(textureStreamer, frame: frameIndex, slot: slot, framesInFlight: Renderer.maxFramesInFlight)
        }
    }

    /// Encodes the stages: one after another, or with `plan.overlap` the cascades next to the denoisers.
    func encode(_ s: FrameStages, plan: FramePlan, passes: FrameEncoder) {
        guard plan.overlap, let enc = passes.compute("trace") else {
            passes.run(s.lightGrid)
            passes.run(s.head)
            passes.run(s.gi)
            passes.run(s.restir)
            passes.run(s.reflections)
            passes.run(s.fog)
            passes.run(s.denoise)
            passes.run(s.reflectionDenoise)
            return
        }
        // The light grid first (the trace's bounces read it); light map, trace and cascade probes need only the
        // TLAS; then the cascade chain and the denoiser chain advance in lock-step, one barrier per step.
        // Reflections read the cascades' result: after both. ReSTIR leads the denoiser chain (after the fog).
        if !s.lightGrid.isEmpty {
            for stage in s.lightGrid { stage.encode(enc) }
            enc.memoryBarrier(scope: .buffers)
        }
        for stage in s.head + s.gi.prefix(1) { stage.encode(enc) }
        enc.memoryBarrier(scope: [.buffers, .textures])
        let gi = Array(s.gi.dropFirst()), chain = s.fog + s.restir + s.denoise
        for i in 0..<max(gi.count, chain.count) {
            if i < chain.count { chain[i].encode(enc) }
            if i < gi.count { gi[i].encode(enc) }
            enc.memoryBarrier(scope: [.buffers, .textures])
        }
        for stage in s.reflections + s.reflectionDenoise {
            stage.encode(enc)
            enc.memoryBarrier(scope: [.buffers, .textures])
        }
    }

    /// 3c-5. The geometry debug view, the composite and the upscale into the drawable (or the offscreen texture standing
    /// in for it). Returns it (nil if the surface had none of the right size), the drawable with the in-between picture
    /// to present before it (frame interpolation) and how long the surface took to hand them out.
    func encodeOutput(_ plan: FramePlan, composite c: CompositeInputs, targets t: RenderTargets, surface: RenderSurface,
                              passes: FrameEncoder) -> (output: FrameOutput?, between: FrameOutput?, wait: CFTimeInterval) {
        let size = plan.size, cur = plan.cur, overlap = plan.overlap
        // Solid shading: the whole picture, straight into the drawable; then the gizmos and a pick, as below.
        if plan.solid {
            let drawableStart = CACurrentMediaTime()
            var drawable = nextOutput(plan, surface: surface)
            let drawableWait = CACurrentMediaTime() - drawableStart
            if let d = drawable, d.texture.width != size.outWidth || d.texture.height != size.outHeight { drawable = nil }
            if let drawable, settings.solidLook.classic, let enc = passes.compute("solid") {
                bind(enc, .solid, c.uniforms, sceneSlot: plan.slot)
                enc.setTexture(drawable.texture, index: 0)
                dispatch(enc, .solid, width: size.outWidth, height: size.outHeight)
                passes.endCompute()
            } else if let drawable, let targets = solidTargets(width: size.outWidth, height: size.outHeight) {
                var params = solidParams()
                let flags = solidFlagBuffer()
                if let enc = passes.compute("solid") {
                    bind(enc, .solidTrace, c.uniforms, sceneSlot: plan.slot)
                    enc.setBytes(&params, length: MemoryLayout<GPUSolidParams>.stride, index: 9)
                    enc.setBuffer(flags, offset: 0, index: 10)
                    for (k, t) in targets.enumerated() { enc.setTexture(t, index: k) }
                    dispatch(enc, .solidTrace, width: size.outWidth, height: size.outHeight)
                    bind(enc, .solidResolve, c.uniforms)
                    enc.setBytes(&params, length: MemoryLayout<GPUSolidParams>.stride, index: 9)
                    for (k, t) in targets.enumerated() { enc.setTexture(t, index: k) }
                    enc.setTexture(drawable.texture, index: 3)
                    dispatch(enc, .solidResolve, width: size.outWidth, height: size.outHeight)
                    passes.endCompute()
                }
            }
            interpolator?.advance(kept: false)
            interpolating = false
            if let drawable { encodeGizmos([drawable.texture], slot: plan.slot, passes: passes) }
            encodePick(plan, passes: passes)
            return (drawable, nil, drawableWait)
        }
        // Reference "Path traced": the paths' mean, exposed and tone mapped into the drawable.
        if let pt = plan.pathTrace {
            let drawableStart = CACurrentMediaTime()
            var drawable = nextOutput(plan, surface: surface)
            let drawableWait = CACurrentMediaTime() - drawableStart
            if let d = drawable, d.texture.width != size.outWidth || d.texture.height != size.outHeight { drawable = nil }
            if let drawable, let enc = passes.compute("composite") {
                bind(enc, .tonemap, c.uniforms)
                enc.setBuffer(exposureMeter.current, offset: 0, index: 1)
                setTextures(enc, [pt.accum, drawable.texture])
                dispatch(enc, .tonemap, width: size.outWidth, height: size.outHeight)
                passes.endCompute()
            }
            return (drawable, nil, drawableWait)
        }
        // 3c. Geometry debug views: their own pass, only while one is shown.
        if RenderSettings.geometryViews.contains(settings.viewMode), let enc = passes.compute("geometry debug") {
            bind(enc, .geometryDebug, c.uniforms, sceneSlot: plan.slot)
            enc.setTexture(t.geometryDebug, index: 0)
            dispatch(enc, .geometryDebug, width: size.width, height: size.height)
            if overlap { enc.memoryBarrier(scope: [.textures]) }   // concurrent encoder: before the composite reads it
        }

        // Indirect light the composite adds when signals are separate: denoised, or raw (GI technique / GI off).
        let compositeIndirect = plan.accumulating || (plan.svgf && plan.separate && plan.denoiseIndirect)
            ? c.illumination.last! : t.indirect

        // 4. Composite: albedo * illumination + emission, tonemap, write to the drawable
        //    (or, with upscaling, to MetalFX's input color texture).
        let drawableStart = CACurrentMediaTime()
        var drawable = nextOutput(plan, surface: surface)
        let drawableWait = CACurrentMediaTime() - drawableStart
        // Right after a size change the view can still hand out a drawable of the old size: skip drawing this frame.
        if let d = drawable, d.texture.width != size.outWidth || d.texture.height != size.outHeight { drawable = nil }
        if let drawable, let enc = passes.compute("composite") {
            let output = size.upscaling || supersampling ? t.upscaleColor : plan.taa?.input ?? plan.post?.color ?? drawable.texture
            var uniforms = c.uniforms
            if (plan.post != nil || plan.taa != nil) && !size.upscaling { uniforms.flags |= UniformFlags.post }
            bind(enc, .composite, uniforms)
            setTextures(enc, [c.illumination[0], t.direct, t.indirect, t.albedo, t.emission, t.normalDepth[cur],
                              plan.shadowDenoiser ? t.shadow.meta[cur] : t.denoise[0].moments[cur], output, compositeIndirect,
                              t.giDebug, t.surfacePos, t.geoNormal, t.material, c.specular, t.geometryDebug, c.meshDirect,
                              plan.fog?.grid.integrated ?? dummy3D, c.fogReference ?? dummy2D, t.specularAlbedo, t.roughness,
                              plan.particles?.color ?? dummy2D,
                              plan.particles?.depth ?? dummy2D])
            enc.setBuffer(lightBuffers[plan.slot], offset: 0, index: 1)
            var fp = plan.fogParams
            enc.setBytes(&fp, length: MemoryLayout<GPUFogParams>.stride, index: 2)
            enc.setBuffer(shadingArgs[plan.slot], offset: 0, index: 7)
            if plan.water, let water { enc.useResources(water.resources(slot: plan.slot), usage: .read) }
            dispatch(enc, .composite, width: output.width, height: output.height)
        }

        // 4b. Supersampled reference: average the composited frames (from halfway through, once lighting has converged).
        if let drawable, supersampling, !size.upscaling, let accum = colorAccumTexture(width: size.width, height: size.height),
           let enc = passes.compute("composite") {
            if overlap { enc.memoryBarrier(scope: .textures) }
            let half = UInt32((benchmark?.current.frames ?? 0) / 2)
            let averaged = plan.accumCount + (plan.accumulation != nil ? 1 : 0)   // with this frame
            var params = SIMD2<UInt32>(colorAccumCount, averaged > half ? 1 : 0)
            if params.y != 0 { colorAccumCount += 1 }
            enc.setComputePipelineState(pipelines[.accumulateColor])
            enc.setBytes(&params, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
            setTextures(enc, [t.upscaleColor, accum, drawable.texture])
            dispatch(enc, .accumulateColor, width: size.width, height: size.height)
        }

        // 5. Upscale: MetalFX's denoising scaler denoises the raw light as it upscales.
        passes.endCompute()
        // ...or, at the traced resolution, the temporal AA resolves the jittered frames (the lens or the tone curve follow).
        if let drawable, let taa = plan.taa, let enc = passes.compute("taa") {
            let resolved = taa.history[cur]
            bind(enc, .taaResolve, c.uniforms)
            var reset: UInt32 = plan.taaHistory ? 0 : 1
            enc.setBytes(&reset, length: MemoryLayout<UInt32>.stride, index: 1)
            setTextures(enc, [taa.input, taa.history[plan.prev], t.motion, resolved])
            dispatch(enc, .taaResolve, width: size.width, height: size.height)
            passes.endCompute()
            let light = encodeHaze(plan, input: resolved, normalDepth: t.normalDepth[cur], passes: passes)
            if let post = plan.post {
                encodePost(plan, post: post, input: light, normalDepth: t.normalDepth[cur], uniforms: c.uniforms,
                           output: drawable.texture, passes: passes)
            } else if let enc = passes.compute("taa") {
                bind(enc, .tonemap, c.uniforms)
                enc.setBuffer(exposureMeter.current, offset: 0, index: 1)
                setTextures(enc, [light, drawable.texture])
                dispatch(enc, .tonemap, width: size.outWidth, height: size.outHeight)
                passes.endCompute()
            }
        } else if let drawable, let post = plan.post, !size.upscaling {
            let light = encodeHaze(plan, input: post.color, normalDepth: t.normalDepth[cur], passes: passes)
            encodePost(plan, post: post, input: light, normalDepth: t.normalDepth[cur], uniforms: c.uniforms,
                       output: drawable.texture, passes: passes)
        }
        // Frame interpolation: the picture goes to the interpolator's texture, and from there into its slot.
        let interpolation = plan.interpolate ? interpolator : nil
        var between: FrameOutput?
        if let drawable, let upscaler {
            if upscalerReset { interpolator?.reset() }
            passes.upscale(upscaler, UpscaleInputs(targets: t, normalDepth: t.normalDepth[cur], view: plan.view, jitter: plan.jitter,
                                                   reset: upscalerReset), pass: "upscale")
            upscalerReset = false
            // The particles over what it made (it would smear them: particleOverlayKernel).
            if let layer = plan.particles, let enc = passes.compute("particle overlay") {
                bind(enc, .particleOverlay, plan.uniforms, sceneSlot: plan.slot)
                var fp = plan.fogParams
                enc.setBytes(&fp, length: MemoryLayout<GPUFogParams>.stride, index: 9)
                setTextures(enc, [upscaler.hdrOutput, layer.color, layer.depth, t.normalDepth[cur], plan.fog?.grid.integrated ?? dummy3D])
                dispatch(enc, .particleOverlay, width: size.outWidth, height: size.outHeight)
                passes.endCompute()
            }
            // It leaves linear, unbounded light (bent by the heat haze, if any): the lens and the finish, or only the
            // exposure and the tone curve, into the drawable.
            let light = encodeHaze(plan, input: upscaler.hdrOutput, normalDepth: t.normalDepth[cur], passes: passes)
            let picture = interpolation?.color ?? drawable.texture
            if let post = plan.post {
                encodePost(plan, post: post, input: light, normalDepth: t.normalDepth[cur], uniforms: c.uniforms,
                           output: picture, passes: passes)
            } else if let enc = passes.compute("upscale") {
                bind(enc, .tonemap, c.uniforms)
                enc.setBuffer(exposureMeter.current, offset: 0, index: 1)
                setTextures(enc, [light, picture])
                dispatch(enc, .tonemap, width: size.outWidth, height: size.outHeight)
                passes.endCompute()
            }
            if let interpolation {
                if interpolation.hasHistory { between = FrameOutput(texture: interpolation.between[plan.slot], drawable: nil) }
                passes.interpolate(interpolation, InterpolateInputs(targets: t, view: plan.view, jitter: plan.jitter, deltaTime: frameDt,
                                                                    fovDegrees: settings.fovDegrees),
                                   slot: plan.slot, pass: "interpolate")
            }
        }
        // The next frame's interpolation starts from this frame's picture only if it went through the interpolator.
        interpolator?.advance(kept: interpolation != nil && drawable != nil && upscaler != nil)
        interpolating = interpolation != nil
        if let drawable { encodeGizmos([drawable.texture] + (between.map { [$0.texture] } ?? []), slot: plan.slot, passes: passes) }
        encodePick(plan, passes: passes)
        return (drawable, between, drawableWait)
    }

    /// The frame's output: with frame interpolation the interpolator's slot (the presenter takes the drawables once the
    /// frame is done); otherwise the surface's drawable, after what the presenter was handed is committed.
    private func nextOutput(_ plan: FramePlan, surface: RenderSurface) -> FrameOutput? {
        if plan.interpolate, let interpolator {
            interpolator.claim(plan.slot)
            return FrameOutput(texture: interpolator.shown[plan.slot], drawable: nil)
        }
        if interpolating { presenter?.drain() }
        return surface.nextOutput()
    }

    /// 5b. The heat haze (distortion particles: particleDistortKernel): `input`, the frame's linear light at the output
    /// size, bent where hot air is in front of it, into a texture of its own, which it returns for the lens to take;
    /// `input` itself when the scene has no distorters (or no particles).
    private func encodeHaze(_ plan: FramePlan, input: MTLTexture, normalDepth: MTLTexture, passes: FrameEncoder) -> MTLTexture {
        guard let gpu = particlesGPU, gpu.system.distortCapacity > 0, let haze = particleHazeTarget(width: input.width, height: input.height),
              let enc = passes.compute("particle distortion", serial: true) else { return input }
        bind(enc, .particleDistortDiscs, plan.uniforms)
        gpu.encodeDistortDiscs(enc)
        bind(enc, .particleDistort, plan.uniforms)
        setTextures(enc, [input, haze, normalDepth])
        dispatch(enc, .particleDistort, width: input.width, height: input.height)
        passes.endCompute()
        return haze
    }

    /// 6. The lens and the finish (Shaders/Post.metal): `input`, the frame's linear light at the output size, through the
    /// depth of field and the glow, then exposed, tone mapped, vignetted and grained into `output`. In order, in one
    /// serial pass.
    private func encodePost(_ plan: FramePlan, post: PostTargets, input: MTLTexture, normalDepth: MTLTexture, uniforms: Uniforms,
                            output: MTLTexture, passes: FrameEncoder) {
        guard let enc = passes.compute("post", serial: true) else { return }
        var params = plan.postParams
        func start(_ kernel: Kernel) {
            bind(enc, kernel, uniforms)
            enc.setBytes(&params, length: MemoryLayout<GPUPostParams>.stride, index: 1)
            enc.setBuffer(post.focus, offset: 0, index: 2)
        }
        var light = input
        if params.lens.x > 0 {
            start(.focus)
            enc.setTexture(normalDepth, index: 0)
            dispatch(enc, .focus, width: 1, height: 1)
            start(.dof)
            setTextures(enc, [light, normalDepth, post.dof])
            dispatch(enc, .dof, width: post.width, height: post.height)
            light = post.dof
        }
        if params.bloom.x > 0, !post.down.isEmpty {
            for (i, level) in post.down.enumerated() {
                params.frame.y = UInt32(i)
                start(.bloomDown)
                setTextures(enc, [i == 0 ? light : post.down[i - 1], level])
                dispatch(enc, .bloomDown, width: level.width, height: level.height)
            }
            for i in post.up.indices.reversed() {
                start(.bloomUp)
                setTextures(enc, [i == post.up.count - 1 ? post.down[i + 1] : post.up[i + 1], post.down[i], post.up[i]])
                dispatch(enc, .bloomUp, width: post.up[i].width, height: post.up[i].height)
            }
        }
        start(.finish)
        enc.setBuffer(exposureMeter.current, offset: 0, index: 2)
        setTextures(enc, [light, post.up.first ?? post.down.first ?? light, output])
        dispatch(enc, .finish, width: output.width, height: output.height)
        passes.endCompute()
    }

    /// Presents the drawable and commits the frame; its completion handler frees the frame slot and reports the timings.
    /// `encodeStart`: when the CPU started on this frame, not counting its waits.
    func commit(_ plan: FramePlan, passes: FrameEncoder, profile: GPUProfiler.Frame?, output: FrameOutput?,
                        between: FrameOutput?, encodeStart: CFTimeInterval) {
        let slot = plan.slot
        var writeCapture: (() -> Void)?
        if let benchmark, benchmark.shouldCapture, let summary = virtualTracing?.summary { print("  " + summary) }
        if let benchmark, benchmark.shouldCapture, let v = sceneBuffers.voxelLOD, !voxelLevels.running {
            print(String(format: "  Voxel levels: last rebuild picked in %.2f ms, built in %.2f ms, %d instances changed",
                         v.last.pickMs, v.last.buildMs, v.last.changed)
                  + (Renderer.voxelAsync ? ", \(voxelLevels.swaps) background rebuilds swapped in" : ""))
        }
        if let benchmark, benchmark.shouldCapture, let fluid = physicsGPU?.fluid { print("  Fluids: " + fluid.summary) }
        if let benchmark, benchmark.shouldCapture, let ts = textureStreamer {
            print("  " + ts.summary)
            if ProcessInfo.processInfo.environment["METALRENDERER_TEXTURE_DEBUG"] != nil { print(ts.details) }
        }
        if let benchmark, benchmark.shouldCapture, !streaming.preparedMs.isEmpty, !streaming.installedMs.isEmpty {
            print("  " + streaming.summary(sceneBuffers))
        }
        if let benchmark, benchmark.isMeasuring, pipelines.stats {
            // One frame's counters: reset at the first measured frame, read at the capture frame (single-frame runs).
            if benchmark.shouldCapture { print("  " + traceScene.takeStats().description) } else { _ = traceScene.takeStats() }
        }
        if let benchmark, let output, benchmark.shouldCapture || benchmark.shouldRecord,
           let capture = benchmark.capture(of: output.texture, device: device, sequence: !benchmark.shouldCapture) {
            passes.capture(output.texture, into: capture.buffer)
            writeCapture = capture.write
            if let between, benchmark.shouldCapture,
               let other = benchmark.capture(of: between.texture, device: device, suffix: "-interp") {
                passes.capture(between.texture, into: other.buffer)
                writeCapture = { capture.write(); other.write() }
            }
        }
        let checkCrowd = benchmark?.shouldCapture == true && CrowdSkinner.checked && !CrowdSkinner.frozen
        let semaphore = frameSemaphore
        let bench = benchmark, benchConfig = benchmark?.configIndex ?? 0
        let recordFrame = benchmark?.isMeasuring ?? false
        let vg = virtualTracing?.clusters, vgFrame = frameIndex, streamer = textureStreamer
        let cpuInterval = frameIntervalMs
        let encodeNow = (CACurrentMediaTime() - encodeStart) * 1000
        encodeSum += encodeNow
        encodeCount += 1
        // Benchmark: finish this frame before encoding the next (`wait`), so passes from consecutive frames
        // never overlap on the GPU and inflate each other's timings.
        // An interpolated frame's pictures go to the presenter once the frame is done (or, offscreen, the slot is free
        // again): the in-between one first, then the frame's own, each held as many refreshes as half a frame takes.
        let handOver = plan.interpolate && output != nil ? interpolator : nil, presenter = presenter
        let withBetween = between != nil
        let hold = FrameInterpolation.hold(frameMs: smoothedGPUMs, refreshMs: surface?.refreshInterval.map { $0 * 1000 })
        passes.commit(presenting: output?.drawable, wait: benchmark != nil) { [weak self] frame in
            if let handOver {
                if let presenter { presenter.present(handOver, slot: slot, withBetween: withBetween, hold: hold) } else { handOver.release(slot) }
            }
            if !Benchmark.isEnabled {
                vg?.collect(slot: slot, frame: vgFrame)
                streamer?.collect(slot: slot)
            }
            if let bench, recordFrame {
                var passMs: [String: Double] = [:]
                var start = Double.infinity, end = 0.0
                for p in frame.passes {
                    passMs[p.name, default: 0] += (p.end - p.start) * 1000   // a name can recur
                    start = min(start, p.start)
                    end = max(end, p.end)
                }
                if frame.passes.isEmpty {   // METALRENDERER_BENCH_SPLIT=0: the whole frame is one command buffer, as in normal mode
                    passMs["frame"] = (frame.end - frame.start) * 1000
                    start = frame.start
                    end = frame.end
                }
                bench.record(.init(config: benchConfig, passMs: passMs, spanMs: (end - start) * 1000, cpuMs: encodeNow))
            }
            writeCapture?()
            let times = profile?.resolve()
            semaphore.signal()
            let ms = (frame.end - frame.start) * 1000
            self?.perform { r in
                if !r.firstFrameDrawn {
                    r.firstFrameDrawn = true
                    DispatchQueue.main.async { Launch.firstFrame() }
                    r.onFirstFrame?()
                }
                r.gpuMs = ms
                r.smoothedGPUMs = r.smoothedGPUMs == 0 ? ms : r.smoothedGPUMs * 0.9 + min(ms, 250) * 0.1
                if r.debugActive { r.onFrameTime?(cpuInterval, ms) }
                if let times { r.addPassTimes(times, frameMs: ms) }
            }
        }
        sceneDeclaredIn = nil
        if benchmark != nil {
            vg?.collect(slot: slot, frame: vgFrame)   // here, not in the handler: the next frame must see the requests
            streamer?.collect(slot: slot)
        }
        if checkCrowd, let crowdSkinner {   // the frame is done (benchmarks wait for it)
            let skin = crowdSkinner.check(positions: positionBuffer, normals: normalBuffer)
            print(String(format: "  Crowd check: %d poses, GPU against CPU: positions within %.2g m, normals within %.2g",
                         crowdSkinner.crowd.slots.count, skin.position, skin.normal))
            if !crowdSkinner.crowd.hair.isEmpty {
                print(String(format: "  Hair check: %d grooms, GPU against CPU within %.2g m", crowdSkinner.crowd.hair.count,
                             crowdSkinner.checkHair(positions: positionBuffer)))
            }
        }
    }
}
