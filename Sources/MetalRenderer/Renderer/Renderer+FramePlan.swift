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
    // MARK: - Render thread

    /// Starts making frames on the render thread (main thread, once, after `init` and the `on…` callbacks are set).
    package func startRenderThread() {
        perform { $0.publishOutline() }   // the first scene's (the others' when they are installed)
        renderThread.start { [weak self] in self?.drawFrame() ?? false }
    }

    /// Stops the frames, once the one being encoded is committed (main thread, at quit).
    package func stopRenderThread() { renderThread.stop() }

    /// Runs `work` on the render thread before its next frame. Any thread.
    package func perform(_ work: @escaping (Renderer) -> Void) {
        renderThread.perform { [weak self] in if let self { work(self) } }
    }

    /// Applies the controller's settings edit number `update` (render thread). The settings go back with that number
    /// even if the edit changes nothing, so the panel knows its edits are all in.
    package func applySettings(update: Int, _ change: (inout RenderSettings) -> Void) {
        settingsUpdate = update
        let before = settings
        change(&settings)
        if settings == before { publishSettings() }
    }

    package func publishSettings() { onSettings?(settings, settingsUpdate, persistSettings) }

    /// One frame: the scene's next state and its upload, the frame's plan, the stages the plan asks for, their
    /// encoding, the output, and what the frame leaves for the next one. Each step is a function below. Returns false
    /// if it drew nothing.
    private func drawFrame() -> Bool {
        // Launch: the shaders are still compiling (startCompilingShaders). And nothing while the window is hidden.
        guard pipelines != nil, let surface, surface.isVisible, benchmark?.isFinished != true else { return false }
        noteFrameStart()
        let size = frameSize(on: surface)
        guard let t = renderTargets(for: size) else { return false }
        // The open world: the scene is made around the tile the camera is in (Scene+World.swift).
        if let place = scene.worldPlace, settings.scene.kind.isWorld, loading == nil {
            let wanted = place.wanted(for: camera.position)
            if wanted != place.tile {
                settings.scene.worldTile = wanted
                let anchor = place.anchorTile(around: wanted)
                if anchor != place.anchorTile { settings.scene.worldAnchor = anchor }
            }
        }
        if scene.worldPlace != nil { scene.follow(camera.position) }
        if settings.scene.kind.isCity || settings.scene.kind.isWorld, settings.scene.city.interiors, loading == nil, benchmark == nil {
            chooseInterior()
        }
        setWorldLights()
        if settings.scene.effects != scene.settings.effects, loading == nil { editEffects() }
        if settings.scene.materials != scene.settings.materials, loading == nil { editMaterials() }
        if placedPending != nil { remakeForPendingPlaced() }
        if loading != nil { settleLoads() }
        if settings.scene != scene.settings || virtualGeometryChanged || plantSeasonChanged || sceneRemake != nil {
            // A benchmark makes its scenes right here, but the world's next one as the app does, in the background: its
            // frames then show what a tile crossing costs. A headless app driven by scripts (`serve`) loads as the
            // window does, so that what a script switches is what the user's switch does.
            let streamed = settings.scene.isSameWorld(as: scene.settings) || settings.scene.isSameCity(as: scene.settings)
            if let benchmark, !benchmark.current.serves, !streamed { rebuildScene() } else { startLoadingScene() }
        }
        frameSemaphore.wait()
        let encodeStart = CACurrentMediaTime()
        guard prepareUpscalers(for: size) else {
            frameSemaphore.signal()
            return false
        }

        // The CPU's part: move the camera and the scene, pick virtual geometry's detail, write the slot's buffers.
        simulate(size)
        let slot = Int(frameIndex) % Renderer.maxFramesInFlight
        let lod = detailView(height: size.height)
        updateVoxelLOD(lod)
        virtualTracing?.update(frame: frameIndex, slot: slot, framesInFlight: Renderer.maxFramesInFlight, view: lod, scene: scene)
        writeFrameData(slot: slot, lod: lod)
        // GPU pass timings (the Debug window): a command buffer per pass, as a benchmark's, each reporting its GPU time.
        let profiling = profilePasses && benchmark == nil
        let plan = planFrame(size: size, slot: slot, profiling: profiling)
        regirParams = plan.lightGrid?.params ?? GPURegirParams()   // bound with the scene (bindScene)
        let passes = makeFrame(plan)
        if let released = virtualTracing?.takeReleased(), !released.isEmpty { passes.release(released) }   // (before the frame binds)
        encodeSceneUpdate(slot: slot, lod: lod, passes: passes)
        if skyActive && !plan.solid { encodeSky(passes) }

        // The stages, in the order their results land in the composite's inputs (each denoiser replaces what the one
        // before it set).
        var composite = CompositeInputs(uniforms: plan.uniforms, illumination: [t.denoise[0].pingA], specular: t.specular,
                                        meshDirect: t.meshDirect)
        var stages = FrameStages()
        if plan.pathTrace != nil {
            // Reference "Path traced": one kernel makes the whole picture.
            stages.head = pathTraceStages(plan)
        } else if !plan.solid {   // (solid shading: encodeOutput draws it)
            stages.lightGrid = lightGridStages(plan)
            stages.head = headStages(plan, targets: t)
            stages.gi = giStages(plan, targets: t)
            (stages.reflections, stages.reflectionDenoise) = reflectionStages(plan, targets: t, composite: &composite)
            stages.restir = restirStages(plan, targets: t)
            stages.denoise = sampledLightStages(plan, targets: t)
            stages.denoise += shadowDenoiseStages(plan, targets: t, composite: &composite)
            stages.denoise += accumulateStages(plan, targets: t, composite: &composite)
            stages.denoise += svgfStages(plan, targets: t, composite: &composite)
            stages.fog = fogStages(plan, targets: t, composite: &composite)
            stages.head = particleLightStages(plan) + stages.head
            stages.fog += particleLayerStages(plan, targets: t, composite: &composite)
        }

        encode(stages, plan: plan, passes: passes)
        let output = encodeOutput(plan, composite: composite, targets: t, surface: surface, passes: passes)
        commit(plan, passes: passes, profiling: profiling, output: output.output, between: output.between,
               encodeStart: encodeStart + output.wait)

        finishFrame(plan)
        updateTitle(width: size.width, height: size.height, outWidth: size.outWidth, outHeight: size.outHeight)
        if let benchmark { advanceBenchmark(benchmark) } else { publishStreams() }
        return true
    }

    // MARK: - Frame setup

    /// The traced size and the size the drawable shows.
    package struct FrameSize {
        let width: Int, height: Int, outWidth: Int, outHeight: Int
        var upscaling: Bool { outWidth > width }
    }

    /// The time since the last frame started (the Debug window's CPU graph) and the traversal counters.
    private func noteFrameStart() {
        let drawStart = CACurrentMediaTime()
        if let last = lastDrawTime {
            frameIntervalMs = (drawStart - last) * 1000
            frameIntervalSum += frameIntervalMs
            frameIntervalCount += 1
        }
        lastDrawTime = drawStart
        if let benchmark, benchmark.isMeasuring, benchmark.frameInConfig > benchmark.warmupFrames {
            streaming.longestFrameMs = max(streaming.longestFrameMs, frameIntervalMs)
        }
        if benchmark == nil, pipelines?.stats == true {
            let counts = traceScene.readCounters()   // what the frames finished since the last read added (in-flight ones in part)
            if let last = traversalLast {
                traversalSum = traversalSum + TraversalStats(counts: zip(counts, last).map { UInt64($0 &- $1) })
                traversalFrames += 1
            }
            traversalLast = counts
        }
    }

    /// Render resolution = window size in points * renderScale. Without upscaling the layer stretches it to the window.
    /// With upscaling, MetalFX outputs renderScale * upscaleFactor, capped at the window's size in physical pixels.
    private func frameSize(on surface: RenderSurface) -> FrameSize {
        let points = surface.pointSize
        let width = max(64, Int((points.width * settings.renderScale).rounded()))
        let height = max(64, Int((points.height * settings.renderScale).rounded()))
        var outWidth = width, outHeight = height
        // (Not under a reference picture: the denoising scaler would blend in its own history.)
        if settings.upscaleFactor > 1 && upscaleSupported && settings.reference.mode == .off {
            let backing = surface.backingScale
            let maxWidth = points.width * backing, maxHeight = points.height * backing
            let factor = min(settings.upscaleFactor, maxUpscale, maxWidth / CGFloat(width), maxHeight / CGFloat(height))
            if factor > 1.01 {
                outWidth = Int((CGFloat(width) * factor).rounded())
                outHeight = Int((CGFloat(height) * factor).rounded())
            }
        }
        surface.outputSize = CGSize(width: outWidth, height: outHeight)
        return FrameSize(width: width, height: height, outWidth: outWidth, outHeight: outHeight)
    }

    /// The screen-sized textures, recreated (without history) when the render resolution changed.
    private func renderTargets(for size: FrameSize) -> RenderTargets? {
        if let t = targets, t.width == size.width, t.height == size.height { return t }
        do {
            targets = try RenderTargets(device: device, width: size.width, height: size.height)
            historyValid = false
            taaHistory = false
        } catch {
            print(error)
            return nil
        }
        return targets
    }

    /// Makes MetalFX's denoising scaler while upscaling, if it isn't there at this size. False when it couldn't be
    /// made: upscaling is then turned off (SVGF denoises instead) and the frame skipped.
    private func prepareUpscalers(for size: FrameSize) -> Bool {
        let width = size.width, height = size.height, outWidth = size.outWidth, outHeight = size.outHeight
        // Solid shading uses neither: what is there stays for the way back (made again only if the size changed).
        if settings.solid { return true }
        if !size.upscaling {
            upscaler = nil
        } else if upscaler == nil || upscaler!.inputWidth != width || upscaler!.inputHeight != height
                    || upscaler!.outputWidth != outWidth || upscaler!.outputHeight != outHeight {
            do {
                upscaler = try Upscaler(device: device, inputWidth: width, inputHeight: height, outputWidth: outWidth,
                                        outputHeight: outHeight, synchronous: benchmark != nil, compiler: compiler)
                upscalerReset = true
                interpolator = nil   // it reads the scaler's depth and motion: made again with it
                historyValid = false   // the denoising scaler comes or goes: SVGF's history is not this frame's
            } catch {
                print(error)
                upscaler = nil
                settings.upscaleFactor = 0
                return false
            }
        }
        if let upscaler, settings.frameInterpolation != .off, Capabilities.current.frameInterpolator {
            if interpolator == nil {
                do {
                    interpolator = try FrameInterpolator(device: device, upscaler: upscaler, slots: Renderer.maxFramesInFlight)
                } catch {
                    print(error)
                    settings.frameInterpolation = .off
                }
            }
        } else {
            interpolator = nil
        }
        return true
    }

    /// Whether this frame presents an in-between picture before its own: On always, Auto while a frame's GPU time is
    /// over three of the display's refreshes (FrameInterpolation.autoOn). Never without a display that paces the
    /// frames, except On (benchmarks).
    private func interpolatesFrame(on surface: RenderSurface) -> Bool {
        guard interpolator != nil else { return false }
        switch settings.frameInterpolation {
        case .off: return false
        case .on: return true
        case .auto:
            guard let refresh = surface.refreshInterval else { return false }
            return FrameInterpolation.autoOn(frameMs: smoothedGPUMs, refreshMs: refresh * 1000, was: interpolating)
        }
    }

    /// Advances the clock, the camera and the scene's animation by one frame.
    private func simulate(_ size: FrameSize) {
        let now = CACurrentMediaTime()
        var dt = Float(min(now - lastTime, 0.1))
        lastTime = now
        if let benchmark {
            let (width, height) = (size.width, size.height)
            benchmark.noteDraw(resolution: size.upscaling ? "\(width)×\(height) → \(size.outWidth)×\(size.outHeight)" : "\(width)×\(height)")
            dt = benchmark.fixedDt   // deterministic animation so every setting renders the same frames
            if benchmark.current.cameraPath {
                camera = Benchmark.cameraPose(progress: benchmark.progressInConfig, scene: settings.scene.kind, sceneCamera: scene.defaultCamera)
            }
            if let track = benchmark.current.track { camera = track.camera(at: benchmark.trackTime) }
            benchmarkActs(benchmark)
            // A flight: the setting's, or METALRENDERER_FLIGHT="x,y,z,frames" for every setting (metres a second; with
            // `frames`, there and back again, turning every so many frames).
            if let velocity = benchmark.current.flight ?? Renderer.flightOverride?.velocity {
                let back = Renderer.flightOverride.map { $0.turn > 0 && (benchmark.frameInConfig / $0.turn) % 2 == 1 } ?? false
                camera.position += velocity * (back ? -dt : dt)
            }
        }
        frameDt = dt
        if !session.scriptHooks.isEmpty { runScriptHooks(dt: dt) }
        updateCamera(dt: dt)
        let angles = SIMD2(camera.yaw, camera.pitch)
        if angles != sentAngles {
            sentAngles = angles
            onCameraTurned?(angles.x, angles.y)
        }
        camera.fovY = settings.fovDegrees * .pi / 180
        viewAspect = Float(size.outWidth) / Float(max(size.outHeight, 1))
        moveGrab()
        previousAnimTime = animTime
        // Paint mode holds the scene still (a character's pose is where the brush's tiles were measured). The scene's
        // own slow motion on top (SceneBehaviour.timeScale).
        if !settings.paused && painter.active == nil { animTime += dt * settings.timeScale * (scene.behaviour?.timeScale ?? 1) }
        scene.viewer = camera.position
        scene.update(time: animTime, dayTime: dayTime)
        scene.behaviour?.lateUpdate(self, dt: dt)
        sendDayTime()
        scene.setLeaves(season: settings.foliage.season, translucency: settings.foliage.translucency)
    }

    /// The picture cuts (a scene's camera jumps to another): this frame keeps none of the last ones' history (the
    /// denoisers', TAA's, MetalFX's).
    package func cut() {
        historyValid = false
        taaHistory = false
        upscalerReset = true
    }

    /// The open world's scene is one with its cities' lights from a little before the sun sets until a little after
    /// it has risen (`SceneSettings.worldLit`).
    package func setWorldLights() {
        if settings.scene.kind.isWorld { settings.scene.worldLit = Heavens(at: dayTime).sunElevation < World.lightsReady }
    }

    /// The sun's day cycle can be offset or held (Time of day, DayClock); everything else keeps the animation time.
    private var dayTime: Float { settings.dayTime(animTime: animTime) }

    /// A settings change that moved the day: a hold turned on or off keeps the day where it is, and a day that jumped
    /// draws its sky again at once, and drops what the frames before had gathered of the light if it went far.
    package func dayChanged(from old: RenderSettings) {
        guard settings.scene.kind == old.scene.kind, let cycle = settings.scene.kind.dayCycle else { return }
        settings.keepDay(from: old, animTime: animTime)
        let moved = abs(settings.dayTime(animTime: animTime) - old.dayTime(animTime: animTime)) / cycle
        let jump = min(moved - moved.rounded(.down), 1 - (moved - moved.rounded(.down)))
        guard jump > 1e-5 else { return }
        if jump > DayClock.lightJump { resetGIState() } else { skyRefreshed = nil }
    }

    /// Tells the day bar the day's time once it has moved a minute of the day (and at a new scene).
    private func sendDayTime() {
        guard let onDayTime, let cycle = settings.scene.kind.dayCycle else { sentDayTime = nil; return }
        let day = dayTime
        if let sent = sentDayTime, abs(day - sent) < cycle / (24 * 60) { return }
        sentDayTime = day
        onDayTime(day)
    }

    /// The wind on the plants this frame (Shaders/Foliage.metal).
    package var windFrame: WindFrame {
        let f = settings.foliage, a = f.windDirection * .pi / 180
        return WindFrame(wind: SIMD4(cos(a), sin(a), f.wind, f.gusts), time: animTime, previousTime: previousAnimTime, lodBias: f.lod,
                         leafFall: Scene.leafFall(season: f.season))
    }

    /// The viewpoint virtual geometry picks its detail for: the camera, or where it was when "Freeze LOD" was turned on.
    private func detailView(height: Int) -> VGView {
        let live = (camera.position, Float(height) / (2 * tan(camera.fovY / 2)))
        if !settings.virtualGeometry.freeze { frozenLOD = nil } else if frozenLOD == nil { frozenLOD = live }
        let lod = frozenLOD ?? live
        return VGView(camPos: lod.0, pixelScale: lod.1, tau: settings.virtualGeometry.pixelError)
    }

    /// Where the far baked plants' voxel levels are (VoxelLOD). A rebuild runs on `voxelQueue` and
    /// tells the render thread when it is done; the structure it built is swapped in at a frame's start, and the next
    /// may start once no frame in flight traces the structure it builds into: `maxFramesInFlight - 1` frames after a
    /// swap.
    package struct VoxelLevels {
        weak var owner: VoxelLOD?
        var running = false
        var ready = false
        var swapFrame: UInt32?
        var started: CFTimeInterval = 0
        var swaps = 0                   // background rebuilds swapped in (benchmark summary)
    }
    /// A rebuild once the view has moved this far (m), at most this often (s): METALRENDERER_VOXEL_STEP / _INTERVAL.
    /// The grid the camera is placed on for the plants' sway reach (WindFrame.sway), in metres.
    package static let swayStep: Float = 2
    private static let voxelStep = Float(ProcessInfo.processInfo.environment["METALRENDERER_VOXEL_STEP"] ?? "") ?? 1
    private static let voxelInterval = Double(ProcessInfo.processInfo.environment["METALRENDERER_VOXEL_INTERVAL"] ?? "") ?? 0.25
    /// METALRENDERER_VOXEL_ASYNC=1: benchmarks rebuild in the background too, as the app does (its pictures then
    /// depend on how long the builds take).
    package static let voxelAsync = ProcessInfo.processInfo.environment["METALRENDERER_VOXEL_ASYNC"] == "1"

    /// Swaps in a finished rebuild of the voxel levels and starts the next if the view moved (or the bias changed).
    /// Benchmarks rebuild here and wait: their pictures don't depend on how long a build takes.
    private func updateVoxelLOD(_ lod: VGView) {
        guard let voxels = sceneBuffers.voxelLOD else { return }
        if voxelLevels.owner !== voxels { voxelLevels = VoxelLevels(owner: voxels) }
        if voxelLevels.ready {
            voxels.swap()
            voxelLevels.ready = false
            voxelLevels.swapFrame = frameIndex
            voxelLevels.swaps += 1
        }
        // Not while a rebuild runs: it writes the levels and `pickedView`.
        guard !voxelLevels.running else { return }
        let view = SIMD4(lod.camPos, settings.foliage.lod / max(lod.pixelScale, 1e-6))
        if let picked = voxels.pickedView, picked.w == view.w,
           distance(SIMD3(picked.x, picked.y, picked.z), lod.camPos) < Renderer.voxelStep { return }
        guard voxelLevels.swapFrame.map({ frameIndex >= $0 &+ UInt32(Renderer.maxFramesInFlight - 1) }) ?? true else { return }
        let queue = buildQueue
        if benchmark != nil && !Renderer.voxelAsync {
            if voxels.rebuild(for: view, queue: queue) {
                voxels.swap()
                voxelLevels.swapFrame = frameIndex
            }
            return
        }
        let now = CACurrentMediaTime()
        guard now - voxelLevels.started >= Renderer.voxelInterval else { return }
        voxelLevels.running = true
        voxelLevels.started = now
        voxelQueue.async { [weak self] in
            let built = voxels.rebuild(for: view, queue: queue)
            self?.renderThread.perform {   // the frames' thread: the one `voxelLevels` belongs to
                guard let self, self.voxelLevels.owner === voxels else { return }
                self.voxelLevels.running = false
                self.voxelLevels.ready = built
            }
        }
    }

    // MARK: - Frame plan

    /// Everything one frame does, decided once from the settings, the scene and what the last frame left, before
    /// anything is encoded. The stage builders read this, and none of the renderer's state that changes with a frame.
    package struct FramePlan {
        let size: FrameSize
        let slot: Int                           // the frame-in-flight slot its buffers come from
        let cur: Int                            // this frame's side of the ping-pong textures...
        var prev: Int { cur ^ 1 }               // ...and the last frame's
        var jitter = SIMD2<Float>()
        var uniforms = Uniforms()               // what every kernel gets (the composite adds flags: CompositeInputs)
        var view = Upscaler.View()              // the camera as matrices (MetalFX's denoising scaler)
        var interpolate = false                 // an in-between picture before the frame's own (FrameInterpolator)
        var accumulating = false                // benchmark reference: raw frames are averaged instead of denoised
        var splitPasses = false                 // benchmark: a command buffer per pass, so its GPU time can be read back
        var overlap = false                     // one concurrent encoder: the cascades and the denoisers overlap on the GPU
        var solid = false                       // solid shading: solidKernel draws the frame at the output size, nothing else runs

        // Lighting
        var giMode = GIMode.pathTraced
        var cascades = false                    // radiance-cascade GI runs
        var restirGI = false                    // ReSTIR GI runs...
        var restirGIGrid: RestirGITargets?      // ...on these reservoirs (nil if they couldn't be allocated: no stages)...
        var restirGIHistory = false             // ...which the last frame filled
        var restir = false                      // ReSTIR DI lights the scene, as above
        var restirGrid: RestirTargets?
        var restirHistory = false
        var restirSettings = RestirSettings()   // references: unbiased initial sampling alone
        var lightGrid: (params: GPURegirParams, buffer: MTLBuffer)?   // the light grid (ReGIR), rebuilt this frame
        var lightMaps = false
        var specular = false                    // reflections (glTF specular materials)
        var glass = false                       // window panes over the traced G-buffer (glassKernel)
        var liquid: LiquidTargets?              // camera rays bent through liquids (liquidKernel), before the trace
        var water = false                       // ...and into water (waterKernel; in the liquids' targets)
        var particles: (color: MTLTexture, depth: MTLTexture)?   // the particles' layer over the scene (particleLayerKernel)
        var manyLights = false                  // more than 4 lights: one sampled light per group...
        var manyLightRays = 1                   // ...with this many shadow rays a group...
        var lightReuse = false                  // ...whose picks are kept for the next frame...
        var lightPicksValid = false             // ...and the last frame's are there to reuse
        var meshLights = false                  // emissive-mesh lights, sampled per pixel

        // Denoisers
        var history = false                     // the last frame left denoiser history
        var svgf = false                        // the denoiser is on (never for references)
        var neuralDenoise = false               // MetalFX's denoising scaler denoises instead, as it upscales
        var shadowDenoiser = false             // direct light's visibility goes through its own filter
        var restirSplit = false                 // ReSTIR's visibility too, and its unshadowed light through SVGF
        var separate = false                    // direct and indirect light are separate signals
        var denoiseIndirect = false
        var denoiseMeshLights = false           // mesh lights' direct light is an SVGF signal of its own
        var directPasses = 0, indirectPasses = 0
        var accumulation: (direct: MTLTexture, indirect: MTLTexture, specular: MTLTexture)?   // references
        var accumCount: UInt32 = 0              // frames averaged so far
        var accumFull = false                   // ...as many as Reference's max samples: shown, not added to
        // A reference frame made without what the picture needs yet (the fog's noise, made in the background): it
        // replaces the average instead of joining it.
        var provisional = false
        var pathTrace: PathTracePlan?           // Reference "Path traced": nothing else runs

        // Volumetric fog
        var fog: (grid: FogTargets, noise: MTLTexture)?
        var fogParams = GPUFogParams()
        var fogReference: MTLTexture?           // references: every camera ray is marched instead
        var fogSamples: UInt32 = 0              // ...and this many frames are averaged so far

        // The lens and the finish (not in references, nor in the views that aren't light)
        var post: PostTargets?
        var postParams = GPUPostParams()
        // Temporal AA without upscaling (not in references or the views that aren't light)
        var taa: TAATargets?
        var taaHistory = false                  // the last frame resolved into taa.history[prev]
    }

    /// Reference "Path traced": pathTraceKernel adds `params.samples.y` paths per pixel to the mean of `samples.x` in
    /// `accum` (none once it has max samples), and the frame is that mean tone mapped.
    package struct PathTracePlan {
        let accum: MTLTexture
        var params = GPUPathTraceParams()
        var fog = GPUFogParams()
        var fogNoise: MTLTexture?
        var lightTree: MTLBuffer?               // with more than PT_LIGHT_HITS lights
    }

    /// Resolves this frame's modes and allocates what they need that isn't there yet.
    private func planFrame(size: FrameSize, slot: Int, profiling: Bool) -> FramePlan {
        let width = size.width, height = size.height
        var p = FramePlan(size: size, slot: slot, cur: Int(frameIndex & 1))
        checkReferenceView(width: width, height: height)
        // Solid shading: one camera ray a pixel at the output size, unjittered. No lights, GI, denoisers, fog or lens.
        if settings.solid {
            p.solid = true
            p.uniforms = makeUniforms(width: size.outWidth, height: size.outHeight, giMode: activeGIMode, directMode: activeDirectMode)
            p.uniforms.jitter = SIMD4<Float>()
            p.splitPasses = profiling || benchmark != nil && Benchmark.splitPasses
            return p
        }
        p.accumulating = accumulating
        p.giMode = activeGIMode
        let directMode = activeDirectMode
        p.restir = directMode == .restir
        p.specular = usesSpecular
        p.glass = scene.hasGlass
        if scene.hasLiquid || scene.hasWater { p.liquid = liquidTargets(width: width, height: height) }
        p.water = scene.hasWater && p.liquid != nil && prepareWater(slot: slot)
        if particlesGPU != nil {
            let scale = settings.particleScale < 1 ? 0.5 : 1.0
            p.particles = particleLayerTarget(width: max(Int((Double(width) * scale).rounded()), 1), height: max(Int((Double(height) * scale).rounded()), 1))
        }
        p.history = historyValid

        var u = makeUniforms(width: width, height: height, giMode: p.giMode, directMode: directMode)
        // The denoising scaler gathers jittered samples, and so does the temporal AA without it; supersampled references
        // average 1024 jittered frames.
        if neuralDenoise {
            p.view = Upscaler.View(worldToView: camera.worldToView, viewToClip: camera.viewToClip(aspect: Float(width) / Float(height)))
            p.interpolate = surface.map(interpolatesFrame) ?? false
        }
        if Renderer.usesTAA(settings, upscaling: size.upscaling, accumulating: accumulating || supersampling || referenceMode != .off) {
            p.taa = taaTargets(width: width, height: height)
            p.taaHistory = taaHistory
        } else {
            taaTargetsCache = nil
        }
        p.jitter = size.upscaling
            ? Upscaler.jitter(frame: frameIndex, scale: Float(size.outWidth) / Float(width))
            : p.taa != nil ? Upscaler.jitter(frame: frameIndex, scale: 1)
            : supersampling ? Upscaler.jitter(frame: accumCount, scale: 11.32) : .zero
        u.jitter = SIMD4<Float>(lowHalf: p.jitter, highHalf: prevJitter)
        if size.upscaling { u.flags |= UniformFlags.upscale }
        if neuralDenoise { u.flags |= UniformFlags.hdrOutput }
        if settings.blueNoise && blueNoiseReady { u.flags |= UniformFlags.blueNoise }
        p.uniforms = u

        // Reference "Path traced": pathTraceKernel and the tone curve, nothing else.
        if referenceMode == .pathTraced, let accum = pathTraceTexture(width: width, height: height) {
            let r = settings.reference
            var pt = PathTracePlan(accum: accum)
            var flags = Renderer.pathTraceSobol ? GPUPathTraceParams.sobol : 0
            // The fog's medium, everywhere (no froxel grid). Until its noise is made, the frames don't count.
            if settings.fog.enabled {
                pt.fog = makeFogParams(grid: nil, historyValid: false, requireGrid: false)
                pt.fogNoise = fogNoise()
                if pt.fogNoise != nil { flags |= GPUPathTraceParams.fog } else { p.provisional = true }
            }
            // Many lights: drawn from the light tree, and met by the bounce rays at their proxies.
            var nodes: UInt32 = 0
            if scene.lights.count > Renderer.pathTraceLightHits, let tree = lightTreeBuffer(slot: slot) {
                pt.lightTree = tree.buffer
                nodes = UInt32(tree.nodes)
            }
            let count = p.provisional ? 0 : pathTraceCount   // read after pathTraceTexture: a new one starts over
            let left = r.maxSamples > 0 ? UInt32(r.maxSamples) - min(count, UInt32(r.maxSamples)) : UInt32.max
            pt.params.samples = SIMD4(count, min(UInt32(ReferenceSettings.samplesPerFrameRange.clamp(r.samplesPerFrame)), left),
                                      UInt32(ReferenceSettings.bounceRange.clamp(r.bounces)), nodes)
            pt.params.config = SIMD4(flags, UInt32(lightProxyCount), referenceEpoch, 0)
            pt.params.bounds = scene.sceneSphere
            p.pathTrace = pt
            p.uniforms.viewMode = 0   // the light, tone mapped
            p.splitPasses = profiling || benchmark != nil && Benchmark.splitPasses
            return p
        }

        // Radiance cascades and the direct-light denoiser don't touch each other's textures (unless the denoiser also
        // filters the cascades' output), so their dispatches can overlap on the GPU: the shared encoder is then
        // concurrent, with explicit barriers between dependent stages. Per-pass timing (benchmark or panel) keeps
        // everything serial, and METALRENDERER_OVERLAP=0 turns overlapping off for A/B timing.
        p.splitPasses = profiling || benchmark != nil && Benchmark.splitPasses
        p.overlap = !p.splitPasses && !profiling && Renderer.overlapEnabled && settings.giEnabled
            && p.giMode == .radianceCascades && !settings.cascades.denoiseIndirect

        p.lightGrid = lightGrid(directMode: directMode, camera: u.camPos)

        // Volumetric fog: this frame's parameters (the reflections read them too). The froxel history is reprojected
        // only from the frame just before, with the same far distance.
        if settings.fog.enabled, let grid = fogTargets(width: width, height: height), let noise = fogNoise() { p.fog = (grid, noise) }
        let fogHistory = p.fog != nil && fogLastFrame == frameIndex &- 1 && fogLastFar == settings.fog.maxDistance
        p.fogParams = makeFogParams(grid: p.fog?.grid, historyValid: fogHistory)
        // Reference "Accumulated passes" in the app: until the fog's noise is made, frames without the fog don't count.
        // (Benchmarks make it before their first frame.)
        p.provisional = accumulating && !benchmarkAccumulating && settings.fog.enabled && p.fog == nil
        p.fogSamples = accumCount
        if accumulating, p.fog != nil { p.fogReference = fogReferenceTexture(width: width, height: height) }

        // GI. Light-visibility maps serve the GI techniques and the path tracer's light-map variant.
        p.lightMaps = usesLightMaps
        p.cascades = settings.giEnabled && p.giMode == .radianceCascades
        p.restirGI = settings.giEnabled && p.giMode == .restirGI
        if p.restirGI { p.restirGIGrid = restirGITargets(width: width, height: height) }
        p.restirGIHistory = restirGIWritten   // read after restirGITargets: new reservoirs hold nothing
        // Only these write t.giDebug: with any other method the "GI debug" view would show what one of them left.
        if p.cascades || p.restirGIGrid != nil { p.uniforms.flags |= UniformFlags.giDebug }

        // Denoising (SVGF-style): temporal accumulation + edge-aware a-trous wavelet filter.
        //   Path-traced light is denoised either as one signal or as direct and indirect separately (sharper
        //   direct shadows, since indirect noise no longer inflates the variance that guides the luminance
        //   edge-stopping). Cascade output is already smooth: it skips the denoiser unless its
        //   "denoise indirect" option is on (then 1 a-trous pass). With GI off there's no indirect light to denoise.
        let techniqueGI = p.giMode != .pathTraced
        p.neuralDenoise = neuralDenoise
        p.svgf = denoiserOn && !accumulating
        p.denoiseIndirect = settings.giEnabled && (!techniqueGI || techniqueDenoisesIndirect)
        //   With the shadow denoiser (default), direct light goes through its own visibility filter instead,
        //   and SVGF handles only indirect light.
        //   ReSTIR's direct light is radiance, not per-group visibility: SVGF filters it (no loop over the lights).
        let shadowDenoiserOn = p.svgf && settings.denoiser.shadowDenoiser && Renderer.shadowDenoiserAllowed
        //   ReSTIR with the shadow denoiser (split): its visibility goes through the visibility filter, its unshadowed
        //   light through SVGF, and the composite multiplies them.
        p.restirSplit = p.restir && shadowDenoiserOn && settings.restir.splitVisibility
        p.shadowDenoiser = shadowDenoiserOn && (!p.restir || p.restirSplit)
        //   Every kernel of the frame is told, not only the composite: with the shadow denoiser the composite adds the
        //   analytic lights' direct specular (exact GGX x visibility), so the reflection pass must not add its own sample.
        if p.shadowDenoiser { p.uniforms.flags |= UniformFlags.shadowDenoiser }
        p.separate = settings.denoiser.separateSignals || techniqueGI || !settings.giEnabled || p.shadowDenoiser
        let passCount = settings.denoiser.passes(for: p.giMode)
        p.directPasses = p.restir ? DenoiserSettings.passRange.clamp(settings.restir.denoisePasses) : passCount
        p.indirectPasses = p.restirGI ? DenoiserSettings.passRange.clamp(settings.restirGI.denoisePasses) : techniqueGI ? 1 : passCount
        // Emissive-mesh lights' direct light: sampled per pixel, so noisy. With the shadow denoiser it's an SVGF signal
        // of its own; otherwise it joins the direct light. (ReSTIR samples their triangles itself.)
        p.meshLights = !scene.meshLights.isEmpty && !p.restir
        p.denoiseMeshLights = p.meshLights && p.shadowDenoiser

        // More than 4 lights: direct light from one sampled light per group (manyLightsKernel).
        p.manyLights = scene.lightGroupEnd[3] > 4 && u.flags & UniformFlags.allLights == 0 && !p.restir
        // Rooms to walk into: two rays a group. A big room under many ceiling lights (an open office) speckles with
        // one, even with its picks reused; two cost ~0.4 ms there, ReSTIR ~6 ms.
        p.manyLightRays = settings.manyLightRays == 1 && scene.interiorBox != nil ? 2 : settings.manyLightRays
        p.lightReuse = p.manyLights && settings.manyLightReuse > 0 && p.manyLightRays == 1
        p.lightPicksValid = p.lightReuse && reservoirsWritten && historyValid

        // ReSTIR DI. References with many lights accumulate its unbiased initial sampling alone (32 candidates).
        p.restirSettings = settings.restir
        if accumulating {
            p.restirSettings.candidates = 32; p.restirSettings.temporal = false; p.restirSettings.spatialPasses = 0
            p.restirSettings.visibilityReuse = false; p.restirSettings.chains = 4
        }
        if p.restir {
            p.restirGrid = restirTargets(width: width, height: height, chains: RestirSettings.chainRange.clamp(p.restirSettings.chains))
        }
        p.restirHistory = restirWritten       // read after restirTargets, as above

        if accumulating { p.accumulation = accumulationTextures(width: width, height: height) }
        p.accumCount = p.provisional ? 0 : accumCount   // read after accumulationTextures: new textures start a new average
        let maxSamples = settings.reference.maxSamples
        p.accumFull = !benchmarkAccumulating && maxSamples > 0 && accumCount >= UInt32(maxSamples)

        // The lens and the finish, on the output: the composite's light, or the denoising scaler's.
        let lens = settings.post
        if lens.isOn && RenderSettings.showsLight(settings.viewMode) && !accumulating && !supersampling {
            p.post = postTargets(width: size.outWidth, height: size.outHeight)
        }
        if let post = p.post {
            p.postParams = GPUPostParams(
                bloom: SIMD4(PostSettings.bloomRange.clamp(lens.bloom), lens.bloomThreshold, u.post.x,
                             Float(lens.classic ? min(post.down.count, PostSettings.classicBloomLevels) : post.down.count)),
                lens: SIMD4(PostSettings.apertureRange.clamp(lens.aperture), lens.focus, PostSettings.maxBlur, 0.1),
                finish: SIMD4(lens.vignette, lens.grain, lens.aberration, lens.classic ? 1 : 0),
                size: SIMD4(UInt32(size.outWidth), UInt32(size.outHeight), UInt32(width), UInt32(height)),
                frame: SIMD4(frameIndex, 0, 0, 0))
        }
        return p
    }

    /// The light grid (ReGIR) for this frame: where its cells are and how they are filled and read. It is rebuilt from
    /// this frame's lights before everything that samples them (ReSTIR DI's candidates, GI's next-event estimation, the
    /// reflections, the fog). Off in scenes without a light table; references set grid.enabled themselves (off for
    /// restirq's, on with every candidate for restircheck's "grid").
    private func lightGrid(directMode: DirectLightMode, camera: SIMD4<Float>) -> (params: GPURegirParams, buffer: MTLBuffer)? {
        let g = settings.restir.grid
        guard g.enabled && scene.lightTable.entries.count > 0 && (scene.usesLightTable || directMode == .restir),
              let buffer = regirGrid(count: g.reservoirCount) else { return nil }
        let restirCandidates = accumulating ? 32 : RestirSettings.candidateRange.clamp(settings.restir.candidates)
        let cells = RegirSettings.cellRange.clamp(g.cells), levels = RegirSettings.levelRange.clamp(g.levels)
        let cellSize = RegirSettings.cellSizeRange.clamp(g.cellSize), scale = RegirSettings.scaleRange.clamp(g.levelScale)
        let jitter = Renderer.regirJitter(frame: frameIndex)
        func origin(_ level: Int) -> SIMD4<Float> {   // a level's corner and its cell size, centred on the camera
            guard level < levels else { return SIMD4() }
            let size = cellSize * pow(scale, Float(level))
            return SIMD4(SIMD3(camera.x, camera.y, camera.z) - size * (Float(cells) * 0.5 + jitter), size)
        }
        var gp = GPURegirParams()
        (gp.origin0, gp.origin1, gp.origin2, gp.origin3) = (origin(0), origin(1), origin(2), origin(3))
        gp.config = SIMD4(UInt32(cells), UInt32(levels), UInt32(RegirSettings.slotRange.clamp(g.slots)),
                          UInt32(RegirSettings.candidateRange.clamp(g.candidates)))
        gp.consume = SIMD4(UInt32(max(min(RegirSettings.shareRange.clamp(g.share), restirCandidates), 1)), frameIndex, 0, 0)
        return (gp, buffer)
    }

    /// What the frame leaves for the next one's temporal reuse. Set here, in one place, once the frame is committed.
    private func finishFrame(_ plan: FramePlan) {
        restirGIWritten = plan.restirGIGrid != nil
        restirWritten = plan.restirGrid != nil
        reservoirsWritten = plan.lightReuse
        if plan.accumulation != nil && !plan.accumFull && !plan.provisional { accumCount += 1 }
        if let pt = plan.pathTrace, !plan.provisional { pathTraceCount += pt.params.samples.y }
        if plan.fog != nil && plan.fogReference == nil {   // the froxel grid was written
            fogLastFrame = frameIndex
            fogLastFar = settings.fog.maxDistance
        }
        prevCamera = camera
        prevJitter = plan.jitter
        taaHistory = plan.taa != nil
        historyValid = plan.svgf || plan.neuralDenoise || (plan.accumulating && settings.denoiser.enabled)
        frameIndex &+= 1
    }
}
