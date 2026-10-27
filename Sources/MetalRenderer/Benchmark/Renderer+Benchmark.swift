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
    // MARK: - Benchmark

    /// The current setting's events that its track has reached, its lift ride, its flashlight (Config.events, ride).
    package func benchmarkActs(_ benchmark: Benchmark) {
        let c = benchmark.current
        for (k, e) in c.events.enumerated() where !benchmarkFired.contains(k) && benchmark.trackTime >= e.time {
            if case .script(let path, let arguments) = e.event {
                benchmarkFired.insert(k)
                runBenchmarkScript(path, arguments: arguments)
            }
            // (A key from the setting's second frame: its first has moved the scene to its start time.)
            if case .key(let key) = e.event, benchmark.frameInConfig > 0, let behaviour = scene.behaviour {
                benchmarkFired.insert(k)
                _ = behaviour.keyDown(self, key, isRepeat: false)
                behaviour.keyUp(self, key)
            }
        }
        for (k, e) in c.events.enumerated() where !benchmarkFired.contains(k) && benchmark.trackTime >= e.time && benchmark.frameInConfig > 2 {
            if case .paint(let steps) = e.event {
                benchmarkFired.insert(k)
                painterScript += steps
            }
        }
        runPainterScript()
        for (k, e) in c.events.enumerated() where !benchmarkFired.contains(k) && benchmark.trackTime >= e.time && benchmark.frameInConfig > 2 {
            if case .terrain(let steps) = e.event {
                benchmarkFired.insert(k)
                terrainScript += steps
            }
        }
        runTerrainScript()
        guard let controls = scene.interiorControls else { return }
        for (k, e) in c.events.enumerated() where !benchmarkFired.contains(k) && benchmark.trackTime >= e.time && benchmark.frameInConfig > 0 {
            // (A painting's or a terrain edit's steps: theirs to fire, above, a few frames in.)
            if case .paint = e.event { continue }
            if case .terrain = e.event { continue }
            if case .script = e.event { continue }
            if case .key = e.event { continue }
            benchmarkFired.insert(k)
            switch e.event {
            case .callLift(let n, let floor): if controls.lifts.indices.contains(n) { controls.lifts[n].call(floor) }
            case .lights(let on, let within): controls.setSwitches(near: camera.position, within: within, on: on)
            case .flashlight(let on): controls.flashlight.on = on
            case .paint, .terrain, .script, .key: break
            }
        }
        if let n = c.ride, controls.lifts.indices.contains(n), let base = controls.lifts[n].floors.first {
            camera.position.y += controls.lifts[n].y - base
        }
        if controls.flashlight.on {
            controls.flashlight.position = camera.position + camera.right * 0.18 - camera.up * 0.12
            controls.flashlight.direction = camera.forward
        }
    }

    package func applyBenchmarkConfig(_ c: Benchmark.Config) {
        benchmarkFired = []
        benchmarkBody = nil
        settings = c.resolvedSettings()
        animTime = c.startTime
        previousAnimTime = c.startTime
        setWorldLights()   // the scene it starts with is the one its time of day asks for
        if settings.scene.effects != scene.settings.effects { editEffects() }   // the VFX editor's edits, as the app runs them
        if settings.scene.materials != scene.settings.materials { editMaterials() }   // the Material Designer's
        if settings.scene != scene.settings || virtualGeometryChanged || plantSeasonChanged {
            rebuildScene()
        }
        camera = c.track?.camera(at: 0)
            ?? (c.cameraPath ? Benchmark.cameraPose(progress: 0, scene: settings.scene.kind, sceneCamera: scene.defaultCamera) : c.camera ?? scene.defaultCamera)
        prevCamera = camera
        benchmarkAccumulating = c.accumulate
        referenceGIMode = c.accumulate && c.accumulateTechnique ? c.settings.giMode : nil
        referenceDirectMode = c.accumulate && [.exact, .restir].contains(c.directLight) ? c.directLight : nil
        supersampling = c.accumulate && c.supersample
        resetReference()
        resetGIState()
        upscalerReset = true
        streaming = Streaming()
        print("benchmark: \(c.name)")
    }

    /// A benchmark's script (Config.Event.script): its output to the run's.
    private func runBenchmarkScript(_ path: String, arguments: [String]) {
        guard let scripts else { print("script: scripts are off (METALRENDERER_SCRIPTS=0)"); return }
        scripts.run(path: path, arguments: arguments, output: ScriptOutput { _ in })
    }

    package func advanceBenchmark(_ benchmark: Benchmark) {
        // A script running, or the scene it asked for still to make: the frame holds (its clock too).
        if scripts?.isBusy == true || placedPending != nil || sceneRemake != nil { return }
        if benchmark.current.serves {
            Thread.sleep(forTimeInterval: 1.0 / 30)   // idle: the tools want a frame now and then, not the GPU
            return
        }
        if benchmark.hold(settled: streamingSettled) { return }
        guard benchmark.advance() else { return }
        guard benchmark.isFinished else {
            applyBenchmarkConfig(benchmark.current)
            return
        }
        // Wait for every in-flight frame so all records are in, then print and quit.
        for _ in 0..<Renderer.maxFramesInFlight { frameSemaphore.wait() }
        for _ in 0..<Renderer.maxFramesInFlight { frameSemaphore.signal() }
        print(benchmark.report(gpuName: device.name))
        fflush(stdout)
        DispatchQueue.main.async { NSApp.terminate(nil) }   // drawFrame draws no more frames
    }

    /// Virtual geometry has what the view asks for: no group waiting to stream in, no BLAS being built over a cut.
    private var streamingSettled: Bool {
        (virtualTracing?.clusters?.streamer.isSettled ?? true) && !(virtualTracing?.blas?.isBusy ?? false)
    }

    /// How long after a scene is installed its texture levels and virtual geometry pages may show as loading at most
    /// (a texture budget too small for what the view wants never settles).
    package static let settlingStreamsSeconds = 20.0

    /// What is still coming in now that the scene is installed, for the loading overlay (`loadActivity`), ten times a
    /// second: texture levels and virtual geometry pages while a new scene settles; the sky image, the
    /// noise tiles and shader variants whenever they are being made.
    /// The CPU's breaks not yet had (Scene.physicsBreaks) into `cpuBreakRing`'s slots for particle steps `first` on,
    /// each in its step's, as the GPU's steps write theirs (physicsFractureEventsKernel); those of steps before `first`
    /// (the stepper's, a frame behind) in its: the dust at most a frame late. Those of later steps wait.
    package func writeCPUBreaks(first: Int, count: Int) {
        guard let ring = cpuBreakRing, let (log, steps, total) = scene.physicsBreaks else { return }
        if total < cpuBreaksTaken { cpuBreaksTaken = 0 }   // (the world started again)
        let stride = MemoryLayout<GPUBreakEvent>.stride, headers = PhysicsWorld.ringSlots * 16
        var k = max(log.count - (total - cpuBreaksTaken), 0)   // (the first not had)
        log.withUnsafeBytes { raw in
            for step in first..<(first + count) {
                let slot = step % PhysicsWorld.ringSlots
                let events = ring.contents().advanced(by: headers + slot * PhysicsWorld.ringEvents * stride)
                var n = 0
                while k < log.count && steps[k] <= step {
                    if n < PhysicsWorld.ringEvents {
                        events.advanced(by: n * stride).copyMemory(from: raw.baseAddress!.advanced(by: k * stride), byteCount: stride)
                        n += 1
                    }
                    k += 1
                }
                ring.contents().storeBytes(of: SIMD4<UInt32>(UInt32(step + 1), UInt32(n), 0, 0), toByteOffset: slot * 16, as: SIMD4<UInt32>.self)
            }
        }
        cpuBreaksTaken = total - (log.count - k)
    }

    package func publishStreams() {
        let now = CACurrentMediaTime()
        guard now - streamsPublished >= 0.1 else { return }
        streamsPublished = now
        typealias Stream = LoadActivity.Stream
        var streams: [Stream] = []
        if let settling = settlingStreams {
            var settlers: [Stream] = []
            if let ts = textureStreamer {
                let p = ts.levelProgress
                if p.done < p.total {
                    settlers.append(Stream(name: "Texture levels", done: p.done, total: p.total,
                                           detail: String(format: "%.0f MB resident", ts.stats.residentMB)))
                }
            }
            if let streamer = virtualTracing?.clusters?.streamer, !streamer.isSettled {
                let st = streamer.stats
                settlers.append(Stream(name: "Virtual geometry pages", done: st.residentGroups, total: st.residentGroups + st.pending,
                                       detail: String(format: "%d waiting, %.0f MB resident", st.pending, streamer.residentMB)))
            }
            if let blas = virtualTracing?.blas, blas.isBusy {
                settlers.append(Stream(name: "Virtual geometry BLAS", done: 0, total: 0,
                                       detail: String(format: "%.1fM triangles", Double(blas.stats.triangles) / 1e6)))
            }
            // (A streamer may not have asked for anything in the first frames: a moment before they count as settled.)
            if (settlers.isEmpty && now - settling.from > 0.5) || now > settling.until { settlingStreams = nil }
            else { streams += settlers }
        }
        if skyImageLoading { streams.append(Stream(name: "Sky image", done: 0, total: 0, detail: "decoding")) }
        if !blueNoiseReady { streams.append(Stream(name: "Blue noise tile", done: 0, total: 0, detail: "first launch")) }
        if fogNoisePending { streams.append(Stream(name: "Fog noise", done: 0, total: 0)) }
        if let pending = pipelines?.variants.pending, pending > 0 {
            streams.append(Stream(name: "Shader variants", done: 0, total: 0, detail: "\(pending) compiling"))
        }
        loadActivity.setStreams(streams)
    }

    package func colorAccumTexture(width: Int, height: Int) -> MTLTexture? {
        if let t = colorAccum, t.width == width, t.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        colorAccum = device.makeTexture(descriptor: d)
        colorAccumCount = 0
        return colorAccum
    }

    /// Reference "Path traced": for each of the scene's own instances, the light it is the visible shape of (its
    /// index in the lights), ~1 for the other camera-only shapes (maskLights: the motes), ~0 for geometry. A bounce
    /// ray that meets a light's shape asks this which light it met, and passes through the motes.
    package func makeLightProxies() {
        var map = scene.instances.map { $0.mask & Scene.maskLights != 0 ? UInt32.max - 1 : UInt32.max }
        if map.isEmpty { map = [.max] }
        for (i, light) in scene.lights.enumerated() where map.indices.contains(light.proxyInstance) {
            map[light.proxyInstance] = UInt32(i)
        }
        lightProxies = device.makeBuffer(bytes: map, length: map.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        lightProxies?.label = "light proxies"
        lightProxyCount = scene.instances.count
    }

    /// The reference picture starts over: no frame or path of it is kept.
    package func resetReference() {
        accumCount = 0
        colorAccumCount = 0
        pathTraceCount = 0
        referenceEpoch &+= 1
    }

    /// Reference pictures in the app (not a benchmark's, which its config keeps still) start over when the view
    /// changes (the camera, the field of view, the size) or the scene moves (its clock runs).
    package func checkReferenceView(width: Int, height: Int) {
        guard referenceMode != .off && !benchmarkAccumulating else {
            referenceView = []
            return
        }
        let view = [SIMD4(camera.position, camera.fovY), SIMD4(camera.forward, Float(width)), SIMD4(camera.up, Float(height))]
        if view != referenceView || animTime != previousAnimTime { resetReference() }
        referenceView = view
    }

    /// Reference "Path traced": the paths' running mean.
    package func pathTraceTexture(width: Int, height: Int) -> MTLTexture? {
        if let t = pathTraceAccum, t.width == width, t.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        pathTraceAccum = device.makeTexture(descriptor: d)
        pathTraceCount = 0
        return pathTraceAccum
    }

    package func particleLayerTarget(width: Int, height: Int) -> (color: MTLTexture, depth: MTLTexture)? {
        if let t = particleLayerTexture, t.color.width == width, t.color.height == height { return t }
        func make(_ format: MTLPixelFormat, _ label: String) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            let t = device.makeTexture(descriptor: d)
            t?.label = label
            return t
        }
        guard let color = make(.rgba16Float, "particleLayer"), let depth = make(.rg32Float, "particleLayerDepth") else { return nil }
        particleLayerTexture = (color, depth)
        return particleLayerTexture
    }

    package func particleHazeTarget(width: Int, height: Int) -> MTLTexture? {
        if let t = particleHazeTexture, t.width == width, t.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        particleHazeTexture = device.makeTexture(descriptor: d)
        particleHazeTexture?.label = "particleHaze"
        return particleHazeTexture
    }

    package func liquidTargets(width: Int, height: Int) -> LiquidTargets? {
        if let t = liquidTextures, t.ray.width == width, t.ray.height == height { return t }
        func make(_ format: MTLPixelFormat, _ label: String) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            let t = device.makeTexture(descriptor: d)
            t?.label = label
            return t
        }
        guard let ray = make(.rgba32Float, "liquidRay"), let direction = make(.rgba32Float, "liquidDirection"),
              let through = make(.rgba16Float, "liquidThrough"), let reflection = make(.rgba16Float, "liquidReflection"),
              let scatter = make(.rgba16Float, "waterScatter"),
              let r0 = make(.rgba16Float, "waterReflections0"), let r1 = make(.rgba16Float, "waterReflections1") else { return nil }
        liquidTextures = LiquidTargets(ray: ray, direction: direction, through: through, reflection: reflection, scatter: scatter,
                                       reflections: [r0, r1])
        return liquidTextures
    }

    package func accumulationTextures(width: Int, height: Int) -> (direct: MTLTexture, indirect: MTLTexture, specular: MTLTexture)? {
        if let t = accumTextures, t.direct.width == width, t.direct.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let direct = device.makeTexture(descriptor: d), let indirect = device.makeTexture(descriptor: d),
              let specular = device.makeTexture(descriptor: d) else { return nil }
        accumTextures = (direct, indirect, specular)
        accumCount = 0
        return accumTextures
    }

    package func setTextures(_ enc: ComputePass, _ textures: [MTLTexture]) {
        for (i, texture) in textures.enumerated() { enc.setTexture(texture, index: i) }
    }

    /// sRGB, so shaders and MetalFX write linear color and the GPU encodes it.
    package static let drawableFormat = MTLPixelFormat.bgra8Unorm_srgb
    package static let shadowDenoiserAllowed = ProcessInfo.processInfo.environment["METALRENDERER_SHADOWS"] != "0"
    /// References trace every light up to this many; above, they accumulate ReSTIR's unbiased initial sampling (no reuse).
    package static let exactReferenceLights = 1024

    /// This frame's direct-light method: Auto resolved (ReSTIR with many lights), references exact or sampled.
    package var activeDirectMode: DirectLightMode {
        if accumulating {
            if let forced = referenceDirectMode { return forced }   // METALRENDERER_BENCH=restircheck
            return scene.lights.count > Renderer.exactReferenceLights ? .restir : .exact
        }
        switch settings.directLight {
        case .auto: return scene.usesLightTable ? .restir : .grouped   // ReSTIR wins above ~256 lights (METALRENDERER_BENCH=restir)
        case let mode: return mode
        }
    }

    /// The light grid's buffer for `count` reservoirs (reallocated only when the count changes: a settings change).
    package func regirGrid(count: Int) -> MTLBuffer? {
        let length = max(count, 1) * MemoryLayout<GPURegirReservoir>.stride
        if let b = regirBuffer, b.length == length { return b }
        regirBuffer = device.makeBuffer(length: length, options: .storageModePrivate)
        regirBuffer?.label = "regirGrid"
        return regirBuffer
    }
    package func restirTargets(width: Int, height: Int, chains: Int) -> RestirTargets? {
        if let r = restirGrid, r.width == width, r.height == height, r.chains == chains { return r }
        restirGrid = try? RestirTargets(device: device, width: width, height: height, chains: chains)
        restirWritten = false
        return restirGrid
    }
    /// The light tree in this frame's slot: built from this frame's light records on the path tracer's first frame with it,
    /// refit once a frame for the lights that change, and copied into the slot's buffer when that one is behind.
    package func lightTreeBuffer(slot: Int) -> (buffer: MTLBuffer, nodes: Int)? {
        if lightTree == nil {
            lightTree = LightTree(lights: lightStage)
        } else if lightTreeRefitFrame != frameIndex {
            let changes = scene.lightTreeChanges
            lightTree?.refit(lights: lightStage, moved: changes.moved, scaled: changes.scaled)
        }
        lightTreeRefitFrame = frameIndex
        guard let tree = lightTree, !tree.nodes.isEmpty else { return nil }
        if (lightTreeBuffers[slot]?.length ?? 0) < tree.byteCount {
            lightTreeBuffers[slot] = device.makeBuffer(length: tree.byteCount, options: .storageModeShared)
            lightTreeBuffers[slot]?.label = "light tree"
            lightTreeVersions[slot] = -1
        }
        guard let buffer = lightTreeBuffers[slot] else { return nil }
        if lightTreeVersions[slot] != tree.version {
            let nodeBytes = tree.nodes.count * MemoryLayout<GPULightTreeNode>.stride
            tree.nodes.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            tree.paths.withUnsafeBytes { buffer.contents().advanced(by: nodeBytes).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            lightTreeVersions[slot] = tree.version
        }
        return (buffer, tree.nodes.count)
    }
    package static let overlapEnabled = ProcessInfo.processInfo.environment["METALRENDERER_OVERLAP"] != "0"
    /// Reference "Path traced": METALRENDERER_PT_SOBOL=0 draws white noise instead of Owen-scrambled Sobol (A/B).
    package static let pathTraceSobol = ProcessInfo.processInfo.environment["METALRENDERER_PT_SOBOL"] != "0"
    /// Reference "Path traced": up to this many lights (PT_LIGHT_HITS in PathTrace.metal), each is weighed at every
    /// point and bounce rays test them one by one; above, the light tree draws them and rays meet their proxies.
    package static let pathTraceLightHits = 32
    /// Frames between full TLAS rebuilds (refits in between). `METALRENDERER_TLAS=1` rebuilds every frame.
    package static let tlasRebuildInterval = max(1, Int(ProcessInfo.processInfo.environment["METALRENDERER_TLAS"] ?? "") ?? 16)
    /// The Metal TLAS is refit most frames (see encodeSceneUpdate), so it is built for a fast build. A quality build
    /// (`METALRENDERER_TLAS_BUILD=default`) traces no faster on an M4 Max, and one for fast intersection (`fast`) 5% slower with 2000 moving objects.
    package static let tlasUsage: MTLAccelerationStructureUsage = {
        switch ProcessInfo.processInfo.environment["METALRENDERER_TLAS_BUILD"] {
        case "default": return [.refit]
        case "fast": return [.preferFastIntersection, .refit]
        default: return [.preferFastBuild, .refit]
        }
    }()
    /// Metal's per-mesh structures: built for fast intersection and compacted. `METALRENDERER_BLAS=default`
    /// builds them as before, `fast` or `compact` turns on one of the two, for A/B timing.
    private static let blasMode = ProcessInfo.processInfo.environment["METALRENDERER_BLAS"] ?? "fast+compact"
    package static let fastIntersectionBLAS = blasMode.contains("fast")
    package static let compactBLAS = blasMode.contains("compact")

    /// Threadgroup size per kernel (8x8 unless set here), indexed by `Kernel`. `METALRENDERER_TG="trace=16x8,atrous=32x4"`
    /// overrides it for sweeps: a kernel goes by its `Kernel` case, capitals and spaces aside ("restir gi initial").
    /// Measured on an M1 Max: trace 16x8 is ~2% faster than 8x8, atrous 16x16 ~5%; others don't care.
    /// The shadow temporal kernel's 8x8 group is its tile (it declares max_total_threads_per_threadgroup(64)): leave it.
    private static let threadgroupSizes: [MTLSize] = {
        var sizes = [MTLSize](repeating: MTLSize(width: 8, height: 8, depth: 1), count: Kernel.allCases.count)
        sizes[Kernel.trace.rawValue] = MTLSize(width: 16, height: 8, depth: 1)
        sizes[Kernel.atrous.rawValue] = MTLSize(width: 16, height: 16, depth: 1)
        sizes[Kernel.regirBuild.rawValue] = MTLSize(width: 64, height: 1, depth: 1)
        sizes[Kernel.particleLight.rawValue] = MTLSize(width: 64, height: 1, depth: 1)   // a thread a particle
        sizes[Kernel.focus.rawValue] = MTLSize(width: 1, height: 1, depth: 1)   // one thread
        for item in (ProcessInfo.processInfo.environment["METALRENDERER_TG"] ?? "").split(separator: ",") {
            let kv = item.split(separator: "="), wh = kv.count == 2 ? kv[1].split(separator: "x").compactMap { Int($0) } : []
            let name = (kv.first ?? "").lowercased().filter { $0 != " " }
            if wh.count == 2, let kernel = Kernel.allCases.first(where: { "\($0)".lowercased() == name }) {
                sizes[kernel.rawValue] = MTLSize(width: wh[0], height: wh[1], depth: 1)
            } else {
                print("METALRENDERER_TG: can't read \(item) (kernel=WxH, kernels as in Pipelines.swift)")
            }
        }
        return sizes
    }()

    /// Whether a frame resolves jittered frames with the temporal AA: set, without upscaling (MetalFX's scaler does it
    /// then), not in a reference picture (`accumulating`: those average their own jittered frames), and only in the
    /// views that show the light.
    package static func usesTAA(_ settings: RenderSettings, upscaling: Bool, accumulating: Bool) -> Bool {
        settings.taa && !upscaling && !accumulating && RenderSettings.showsLight(settings.viewMode)
    }

    /// The light grid's per-frame origin jitter, in cells ([0, 1)^3), from a hash of the frame index.
    package static func regirJitter(frame: UInt32) -> SIMD3<Float> {
        func hash(_ v: UInt32) -> UInt32 {
            let s = v &* 747796405 &+ 2891336453
            let w = ((s >> ((s >> 28) &+ 4)) ^ s) &* 277803737
            return (w >> 22) ^ w
        }
        let h0 = hash(frame), h1 = hash(h0), h2 = hash(h1)
        return SIMD3(Float(h0 >> 8), Float(h1 >> 8), Float(h2 >> 8)) * (1.0 / 16777216.0)
    }

    package func dispatch(_ enc: ComputePass, _ kernel: Kernel, width: Int, height: Int) {
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                            threadsPerThreadgroup: Renderer.threadgroupSizes[kernel.rawValue])
    }

    package func updateTitle(width: Int, height: Int, outWidth: Int, outHeight: Int) {
        fpsFrames += 1
        let now = CACurrentMediaTime()
        guard now - fpsTime >= 0.5 else { return }
        fps = Double(fpsFrames) / (now - fpsTime)
        fpsFrames = 0
        fpsTime = now
        let s = settings
        func withBounces(_ name: String, _ n: Int) -> String { "GI \(name), \(n) bounce\(n == 1 ? "" : "s")" }
        let gi = !s.giEnabled ? "GI off" : s.giMode == .pathTraced ? withBounces("path traced", s.bounces)
            : s.giMode == .restirGI ? withBounces("ReSTIR", s.restirGI.bounces) : "GI \(s.giMode.title.lowercased())"
        let res = outWidth > width ? String(format: "%ld×%ld → MetalFX denoiser %ld×%ld", width, height, outWidth, outHeight)
                                   : String(format: "%ld×%ld", width, height)
        var stats = String(format: "%@ — %.0f fps — GPU %.1f ms", res, fps, gpuMs)
        switch referenceMode {
        case .pathTraced: stats += " — reference: \(pathTraceCount) paths/pixel"
        case .accumulated where benchmark == nil: stats += " — reference: \(accumCount) frames"
        default: break
        }
        var sceneName = s.scene.kind.definition.detail.map { " — \($0(s.scene))" } ?? ""
        if scene.lights.count > 4 { sceneName += " — direct: \(activeDirectMode.title)" }
        if let loading { sceneName += " — loading \(loading.kind.title)…" }
        if let vg = virtualTracing?.clusters {
            sceneName += String(format: " — %d clusters, %.0f MB", vg.stats.selected, vg.residentMB)
        }
        if let vg = virtualTracing?.blas {
            sceneName += String(format: " — VG %.1fM triangles, %.0f MB", Double(vg.stats.triangles) / 1e6, vg.stats.megabytes)
        }
        if let ts = textureStreamer { sceneName += String(format: " — textures %.0f MB", ts.stats.residentMB) }
        if frozenLOD != nil && lodFreezes { sceneName += " — LOD frozen" }
        surface?.title = String(format: "MetalRenderer%@ — %@ — %@ — %@ noise — denoiser %@ — %@%@",
                                sceneName, stats, gi, s.blueNoise ? "blue" : "white", s.denoiser.enabled ? "on" : "off",
                                s.solid ? "solid" : RenderSettings.viewModes[s.viewMode].lowercased(), s.paused ? " — paused" : "")
        statsLine = stats
        cpuMs = frameIntervalCount > 0 ? frameIntervalSum / Double(frameIntervalCount) : 0
        frameIntervalSum = 0
        frameIntervalCount = 0
        encodeMs = encodeCount > 0 ? encodeSum / Double(encodeCount) : 0
        encodeSum = 0
        encodeCount = 0
        if traversalFrames > 0 { traversal = (traversalSum, traversalFrames) }
        traversalSum = TraversalStats()
        traversalFrames = 0
        var status = RendererStatus(directMode: activeDirectMode, traversalCounters: traversalCounters,
                                    debugInfo: debugActive ? debugInfo() : nil)
        status.plantStats = scene.plantStats
        status.effects = effectsStatus()
        status.buildingStats = scene.buildingStats
        status.characterStats = scene.characterStats
        status.displacement = scene.displacementSummary
        status.buildingPlan = scene.buildingPlan
        status.walker = walkerStatus
        status.hud = scene.behaviour?.hud
        status.destruction = scene.destructionRig.map { DestructionStatus(objects: $0.info) }
        status.cameraPosition = camera.position
        if let k = placedSelection, let placed = scene.placed {
            status.placed = PlacedStatus(kind: scene.settings.kind, index: k, object: placed.file.objects[k])
        }
        if passTimeFrames > 0 {
            let n = Double(passTimeFrames)
            var times = passTimeOrder.map { (name: $0, ms: passTimeSums[$0]! / n) }
            let other = passTimeFrameMs / n - times.reduce(0) { $0 + $1.ms }
            if other > 0.005 { times.append((name: "other", ms: other)) }   // MetalFX, its copy, texture streaming
            status.passTimes = times
            for t in times where t.name.hasPrefix("particle") || t.name == "gizmos" { status.effects?.passMs[t.name] = t.ms }
            passTimeOrder = []
            passTimeSums = [:]
            passTimeFrameMs = 0
            passTimeFrames = 0
        }
        onTick?(status)
        if scene.terrain != nil { reportTerrain() }   // (the Terrain Editor's map follows the camera)
    }

    /// One frame's pass timings, summed until the stats line shows their average.
    package func addPassTimes(_ times: [(name: String, ms: Double)], frameMs: Double) {
        guard profilePasses else { return }
        for t in times {
            if passTimeSums[t.name] == nil { passTimeOrder.append(t.name) }
            passTimeSums[t.name, default: 0] += t.ms
        }
        passTimeFrameMs += frameMs
        passTimeFrames += 1
    }

    /// Recompiles the shaders and remakes every pipeline (R key, traversal counters), in the background: frames keep
    /// the old pipelines until the new set is ready, and for good if the compile fails. `done` gets the outcome (render
    /// thread).
    package func reloadShaders(then done: ((Bool) -> Void)? = nil) {
        // Without pipelines yet (the launch's compile failed, or is still running): for the scene as it was built.
        let device = device, url = shaderURL
        let lightTypes = pipelines?.lightTypes ?? scene.lightTypeMask
        let procedural = pipelines?.procedural ?? scene.proceduralCode
        let compiler = compiler
        let stats = TraceSceneArgs.statsEnabled
        let job = benchmark != nil ? nil : loadActivity.begin("shaders", verbs: ("Compiling", "Compiled"))
        shaderQueue.async { [weak self] in
            let result = Result {
                try Pipelines(device: device, source: url, compiler: compiler, lightTypes: lightTypes, stats: stats, procedural: procedural,
                              load: job)
            }
            if case .failure = result { job?.fail() } else { job?.finish() }
            self?.renderThread.perform {
                guard let self else { return }
                switch result {
                case .success(let made):
                    // A scene with other light types came in meanwhile: compile again, for that one.
                    if let current = self.pipelines, made.lightTypes != current.lightTypes
                        || made.procedural != current.procedural {
                        return self.reloadShaders(then: done)
                    }
                    self.pipelines = made
                    self.shaderGeneration += 1
                    self.keepPipelines(made, generation: self.shaderGeneration)
                    self.resetGIState()
                    if !self.benchmarkAccumulating { self.resetReference() }
                    self.upscalerReset = true
                    done?(true)
                case .failure(let error):
                    print(self.pipelines == nil ? "Shaders failed to compile (fix them and press R):\n\(error)"
                                                : "Shader reload failed (keeping previous version):\n\(error)")
                    if self.pipelines == nil { self.surface?.title = "MetalRenderer — the shaders failed to compile (see the console, then press R)" }
                    done?(false)
                }
            }
        }
    }

    /// The launch's compile, in the background (the app; a benchmark compiles in `init`). Until it is done `draw`
    /// returns at once, and with it everything that needs pipelines: scene loads start there. A failure is printed
    /// and leaves the window empty; R compiles again.
    package func startCompilingShaders() {
        surface?.title = "MetalRenderer — compiling shaders…"
        reloadShaders { ok in
            DispatchQueue.main.async { Launch.mark(ok ? "shaders" : "shaders (failed)") }
        }
    }

    /// The ray queries' counters (RT_STATS).
    package var traversalCounters: Bool { TraceSceneArgs.statsEnabled }

    /// Turns the ray queries' counters on or off: that recompiles the shaders (in the background, `done` when ready).
    package func setTraversalCounters(_ on: Bool, then done: (() -> Void)? = nil) {
        guard on != TraceSceneArgs.statsEnabled else { done?(); return }
        TraceSceneArgs.statsEnabled = on
        reloadShaders { [weak self] ok in
            if !ok { TraceSceneArgs.statsEnabled = !on }
            self?.traversalLast = nil
            self?.traversal = nil
            self?.traversalSum = TraversalStats()
            self?.traversalFrames = 0
            done?()
        }
    }

    /// Freeze LOD does something: it holds the cut of the virtual meshes and the plants' voxel levels (`detailView`).
    /// The open world's tiles follow the camera regardless.
    private var lodFreezes: Bool { virtualTracing != nil || sceneBuffers?.voxelLOD != nil }

    /// Why the view shown has nothing (or less than its name says) to show for this scene and these settings; nil if
    /// it shows what it says.
    private var viewNote: String? {
        let virtual = scene.instances.contains { $0.virtualMesh >= 0 }
        switch settings.viewMode {
        case 5 where neuralDenoise:
            return "History length is the SVGF denoiser's: MetalFX's denoising scaler keeps its own history."
        case 5 where !denoiserOn:
            return "The denoiser is off: no history."
        case 7 where !settings.giEnabled || ![.radianceCascades, .restirGI].contains(activeGIMode):
            return "GI debug is drawn by radiance cascades and ReSTIR GI only."
        case 9...10 where !virtual:
            return "Clusters and groups belong to virtual geometry (glTF meshes of 64K+ triangles: the gallery or added "
                + "models). Other geometry shows its level of detail, faded."
        case 11 where !virtual && !(scene.hasPlants && scene.usesAssemblies) && !scene.meshes.contains(where: { $0.lod != 0 }):
            return "Nothing in this scene has levels of detail: virtual geometry needs big glTF meshes; plants, crowds "
                + "and the open world's tiles have theirs."
        case 13:
            return "Metal's traversal can't count its nodes: the cost is the triangles and boxes it hands each ray's query."
        case 14 where !settings.fog.enabled:
            return "Fog is off."
        default:
            return nil
        }
    }

    /// What the Debug window shows (built when it asks, on the stats tick).
    package func debugInfo() -> DebugInfo {
        var d = DebugInfo()
        d.stats = statsLine
        d.cpuMs = cpuMs
        d.encodeMs = encodeMs
        d.sceneTitle = settings.scene.kind.title
        d.instances = sceneBuffers.instanceCount
        d.virtualInstances = scene.instances.filter { $0.virtualMesh >= 0 }.count
        let assemblyTriangles = scene.assemblies.map { $0.parts.reduce(0) { $0 + Int(scene.meshes[$1.mesh].indexCount) / 3 } }
        d.triangles = scene.instances.reduce(0) {
            $0 + ($1.mesh >= 0 ? Int(scene.meshes[$1.mesh].indexCount) / 3 : $1.assembly >= 0 ? assemblyTriangles[$1.assembly] : 0)
        }
        d.triangles += sceneBuffers.instanceBlocks.reduce(0) { sum, block in
            sum + block.triangles { mesh, assembly in mesh.map { Int(scene.meshes[$0].indexCount) / 3 } ?? assemblyTriangles[assembly!] }
        }
        d.suns = scene.lights.filter { $0.kind.isSun }.count
        d.analyticLights = Int(scene.lightGroupEnd.w) - d.suns   // spheres, spots, rects, tubes
        d.meshLights = scene.meshLights.count
        d.lightTable = scene.usesLightTable
        d.lightTableEntries = scene.lightTable.entries.count
        d.directMode = activeDirectMode == .grouped && scene.lightGroupEnd.w <= 4 ? "Exact (4 lights or fewer)" : activeDirectMode.title
        d.giMode = !settings.giEnabled ? "Off" : activeGIMode.title
        if let vg = virtualTracing?.blas {
            d.vg = .blas(meshes: vg.meshCount, instances: vg.instanceCount, sourceTriangles: vg.sourceTriangles,
                         triangles: vg.stats.triangles, clusters: vg.stats.clusters, megabytes: vg.stats.megabytes,
                         rebuilds: vg.stats.rebuilds, lastBuildMs: vg.stats.lastBuildMs, lastCutMs: vg.stats.lastCutMs,
                         skipped: vg.stats.skippedInstances, busy: vg.isBusy)
        } else if let vg = virtualTracing?.clusters {
            d.vg = .clusters(meshes: vg.meshCount, instances: vg.instanceCount, clusters: vg.clusterCount, groups: vg.groupCount,
                             sourceTriangles: vg.sourceTriangles, triangles: vg.stats.triangles, selected: vg.stats.selected, capacity: VirtualGeometry.capacity, overflow: vg.stats.overflow,
                             residentGroups: vg.stats.residentGroups, residentMB: vg.residentMB, poolMB: vg.poolBytes >> 20,
                             pending: vg.stats.pending, loadedThisFrame: vg.stats.loadedThisFrame)
        }
        d.vgPixelError = settings.virtualGeometry.pixelError
        d.vgFrozen = frozenLOD != nil && lodFreezes
        d.lodFreezes = lodFreezes
        d.viewNote = viewNote
        if let ts = textureStreamer {
            d.textures = (ts.stats.residentMB, ts.budgetBytes >> 20, ts.stats.levelsMapped, ts.stats.uploadedMB)
        }
        d.allocatedMB = Double(device.currentAllocatedSize) / 1_048_576
        d.workingSetMB = Double(device.recommendedMaxWorkingSetSize) / 1_048_576
        d.traversal = traversal
        return d
    }

    /// Adds glTF models to the scene, side by side 2.5 m in front of the camera on the floor, facing it
    /// (glTF models face +Z); the scene reloads in the background. An HDR image (.hdr, .exr) becomes the sky.
    package func addModels(_ urls: [URL]) {
        if let image = urls.last(where: { SkyImage.fileExtensions.contains($0.pathExtension.lowercased()) }) {
            settings.sky.mode = .image
            settings.sky.imagePath = image.path
            skyImageFailed = nil
        }
        let urls = urls.filter { !SkyImage.fileExtensions.contains($0.pathExtension.lowercased()) }
        guard !urls.isEmpty else { return }
        var forward = camera.forward
        forward.y = 0
        forward = length(forward) > 1e-4 ? normalize(forward) : SIMD3(0, 0, -1)
        let right = SIMD3<Float>(-forward.z, 0, forward.x)
        var center = camera.position + forward * 2.5
        center.y = 0
        for (i, url) in urls.enumerated() {
            let offset = (Float(i) - Float(urls.count - 1) / 2) * 1.8
            settings.scene.extraModels.append(ExtraModel(path: url.path, position: center + right * offset, yaw: -camera.yaw))
        }
    }
}
