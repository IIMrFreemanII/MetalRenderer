import AppKit
import EngineCore
import MetalKit
import Plants
import QuartzCore
import simd

extension Renderer {
    // MARK: - Setup

    package func makeBuffer<T>(_ array: [T], _ label: String) throws -> MTLBuffer {
        let length = max(MemoryLayout<T>.stride * array.count, 16)
        let buffer: MTLBuffer? = array.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else {
                return device.makeBuffer(length: length, options: .storageModeShared)
            }
            return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
        }
        guard let buffer else { throw RendererError.resourceCreation("buffer \(label)") }
        buffer.label = label
        return buffer
    }

    /// The slow, CPU-heavy part of a scene switch (loading models, building BVHs, decoding textures). Thread-safe, so
    /// interactive switches run it in the background while the old scene keeps rendering.
    package struct PreparedScene {
        let scene: Scene
        let api: RenderAPI
        let textures: [MTLTexture]
        let streamer: TextureStreamer?
        let virtualTracing: VirtualTracing?
        let buffers: SceneBuffers?  // of a scene made for this load (one being drawn gets them when it is installed)
        let pipelines: Pipelines?   // for its API and light types, when the ones in use don't fit...
        let shaderGeneration: Int   // ...built from this generation of the shaders
    }
    /// A scene that has been replaced and what it was drawn with, on their way out (`install`).
    package final class Replaced {
        var parts: PreparedScene?
        package init(_ parts: PreparedScene) { self.parts = parts }
    }

    /// What the open world's streaming cost while a benchmark measured: each scene made around another tile (in the
    /// background, then installed between two frames), and the longest frame, start to start.
    package struct Streaming {
        package var preparedMs: [Double] = []
        package var installedMs: [Double] = []
        package var longestFrameMs = 0.0

        package func summary(_ buffers: SceneBuffers) -> String {
            func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
            let m = buffers.megabytes
            return String(format: "Streaming: %d scenes, made in %.0f ms (median), installed in %.1f ms (the slowest %.1f), the longest frame %.1f ms; "
                          + "the scene on the GPU: geometry %.0f MB, instances %.0f MB, structures %.0f MB",
                          preparedMs.count, median(preparedMs), median(installedMs), installedMs.max() ?? 0, longestFrameMs,
                          m.geometry, m.instances, m.primitives + m.instanceStructures)
        }
    }

    /// The virtual-geometry switch or pool size changed for a scene with glTF models (the cut threshold needs no rebuild).
    package var virtualGeometryChanged: Bool {
        let hasModels = scene.settings.kind.definition.loadsModels || !scene.settings.extraModels.isEmpty
        let poolChanged = virtualTracing?.clusters.map { $0.poolBytes != max(settings.virtualGeometry.poolMB, 64) << 20 } ?? false
        return hasModels && (scene.usesVirtualGeometry != settings.virtualGeometry.enabled || poolChanged)
    }

    /// A still scene's plants (the open world's) name the variants of the season they were built for: another season
    /// is another scene. So is one whose leaves start or stop falling: the open world's plants are baked without.
    package var plantSeasonChanged: Bool {
        guard let buffers = sceneBuffers, buffers.still else { return false }
        let fall = Scene.leafFall(season: settings.foliage.season)
        if scene.hasPlants && !scene.settings.bakedPlants
            && scene.usesAssemblies == Scene.bakesPlants(scene.settings, leafFall: fall) { return true }
        return buffers.plants != nil && buffers.leafFall != fall
    }

    /// What a scene load reads from the renderer, copied on the render thread: `prepareScene` runs in the background while
    /// the panel and the keyboard keep changing `settings` and a shader reload may replace the pipelines.
    package struct LoadOptions {
        var virtualGeometry: Bool
        var poolMB: Int
        var textureBudgetMB: Int
        var pipelines: Pipelines
        var shaderGeneration: Int
        var traversalStats: Bool
        var api: RenderAPI
        var compiler: AnyObject?    // Metal 4's, for `api`
        var primitives: [String: MTLAccelerationStructure]   // the scene's named meshes' structures
        var blocks: [String: MeshBlock]                      // its borrowed meshes' buffers
        var instanceBlocks: [String: InstanceBlock]          // its instance groups' blocks
        var voxelGrids: VoxelGrids?                          // its plants' voxel grids
        var leafFall: Float                                  // the season's (a still scene's plants are built for it)
        /// The open world's next scene (`settings.scene`, if it is that) is drawn with the textures this one has: they
        /// stay as they are streamed. By the sources' identities.
        var worldTextures: (identities: [String], textures: [MTLTexture], streamer: TextureStreamer?)?
    }
    package var loadOptions: LoadOptions {
        LoadOptions(virtualGeometry: settings.virtualGeometry.enabled, poolMB: settings.virtualGeometry.poolMB,
                    textureBudgetMB: settings.textureBudgetMB, pipelines: pipelines, shaderGeneration: shaderGeneration,
                    traversalStats: TraceSceneArgs.statsEnabled, api: settings.api, compiler: compiler(for: settings.api),
                    primitives: builtAPI == settings.api ? namedPrimitives : [:], blocks: namedBlocks,
                    instanceBlocks: namedInstanceBlocks,
                    voxelGrids: builtAPI == settings.api ? sceneBuffers?.voxelLOD?.grids ?? sceneBuffers?.plants?.voxels : nil,
                    leafFall: Scene.leafFall(season: settings.foliage.season),
                    worldTextures: (settings.scene.isSameWorld(as: scene.settings) || settings.scene.isSameWorkshop(as: scene.settings)
                                    || settings.scene.isSameCity(as: scene.settings))
                        && builtAPI == settings.api
                        ? (scene.textures.map(\.identity), materialTextures, textureStreamer) : nil)
    }

    private func bufferOptions(api: RenderAPI, known: [String: MTLAccelerationStructure], blocks: [String: MeshBlock],
                               instanceBlocks: [String: InstanceBlock], voxelGrids: VoxelGrids? = nil,
                               extraInstances: Int = 0, leafFall: Float) -> SceneBuffers.Options {
        SceneBuffers.Options(api: api, slots: Renderer.maxFramesInFlight, fastIntersection: Renderer.fastIntersectionBLAS,
                             compact: Renderer.compactBLAS, instanceUsage: Renderer.tlasUsage, known: known, blocks: blocks,
                             instanceBlocks: instanceBlocks, voxelGrids: voxelGrids, extraInstances: extraInstances, leafFall: leafFall)
    }

    /// The pipelines for `api`, `stats` and `lightTypes` of shader generation `generation`, unless `current` already fits:
    /// a set made for them before (`pipelineCache`), or compiled here (any thread). Its library is reused when only the
    /// light types differ.
    package func makePipelines(api: RenderAPI, compiler: AnyObject?, lightTypes: UInt32, stats: Bool, generation: Int,
                               procedural: String, current: Pipelines, load: LoadJob? = nil) throws -> Pipelines? {
        let sameCode = current.procedural == procedural
        if current.stats == stats && current.api == api && current.lightTypes == lightTypes && sameCode { return nil }
        let key = PipelineCache<Pipelines>.Key(api: api, stats: stats, lightTypes: lightTypes, generation: generation, procedural: procedural)
        if let kept = pipelineCache.get(key) {
            load?.step("Shaders", detail: "kept from before").finish()
            return kept
        }
        let made = try Pipelines(device: device, source: shaderURL, api: api, compiler: compiler, lightTypes: lightTypes,
                                 stats: stats, procedural: procedural,
                                 reusing: current.stats == stats && current.api == api && sameCode ? current.library : nil,
                                 load: load)
        pipelineCache.put(key, made)
        return made
    }

    /// Keeps `made`, of shader generation `generation`, for a later scene with its light types.
    package func keepPipelines(_ made: Pipelines, generation: Int) {
        pipelineCache.put(PipelineCache<Pipelines>.Key(api: made.api, stats: made.stats, lightTypes: made.lightTypes, generation: generation,
                                                       procedural: made.procedural), made)
    }

    /// The scene's virtual geometry for the tracer, if it has virtual meshes (any thread).
    private func makeVirtualTracing(_ scene: Scene, poolMB: Int) throws -> VirtualTracing? {
        scene.virtualMeshes.isEmpty ? nil
            : try VirtualTracing(device: device, queue: buildQueue, scene: scene, poolMB: poolMB, slots: Renderer.maxFramesInFlight)
    }

    /// `current`: the scene being drawn, reused when only the API changes; `instances` is then the render thread's copy
    /// of its instances (the frame loop keeps animating the scene while this runs).
    /// `load`: the load to report the steps to (the loading overlay).
    package func prepareScene(_ sceneSettings: SceneSettings, reuse current: Scene?, instances: [Scene.Instance]? = nil,
                              options: LoadOptions, load: LoadJob? = nil) throws -> PreparedScene {
        let virtual = options.virtualGeometry
        // Generated plants are assemblies (unless SceneSettings.bakedPlants, or the open world's: Scene.bakesPlants); baked
        // ones far away are voxels if asked for (SceneSettings.voxelBoxes), which makes the scene's plants differently too.
        let assemblies = !Scene.bakesPlants(sceneSettings, leafFall: options.leafFall)
        let voxelBoxes = sceneSettings.voxelBoxes
        let reused = current.flatMap { !$0.geometryReleased && $0.usesVirtualGeometry == virtual
            && (!$0.hasPlants || ($0.usesAssemblies == (assemblies && !sceneSettings.bakedPlants) && $0.usesVoxelBoxes == voxelBoxes)) ? $0 : nil }
        let newScene = reused ?? Scene(sceneSettings, virtualGeometry: virtual, assemblies: assemblies, voxelBoxes: voxelBoxes,
                                       load: load)
        if load?.isCancelled == true { throw CancellationError() }   // another scene was asked for meanwhile
        let kept = options.worldTextures.flatMap { $0.identities == newScene.textures.map(\.identity) ? $0 : nil }
        let streamer = kept != nil ? kept?.streamer
            : newScene.textures.isEmpty || !TextureStreamer.isSupported(device, api: options.api) ? nil
            : try TextureStreamer(sources: newScene.textures, device: device, queue: queue, budgetMB: options.textureBudgetMB,
                                  slots: Renderer.maxFramesInFlight, placement: options.api == .metal4, load: load)
        let textures = try kept?.textures ?? streamer?.textures
            ?? MaterialTextures.load(newScene.textures, device: device, queue: queue, load: load)
        // The scene's buffers and structures, unless the frames are still animating it.
        let buffers = reused != nil ? nil : try autoreleasepool {
            var made = bufferOptions(api: options.api, known: options.primitives, blocks: options.blocks,
                                     instanceBlocks: options.instanceBlocks, voxelGrids: options.voxelGrids,
                                     extraInstances: newScene.tracesClusters ? 1 : 0, leafFall: options.leafFall)
            made.load = load
            return try SceneBuffers(device: device, queue: buildQueue, scene: newScene, options: made)
        }
        if buffers != nil && !newScene.virtualMeshes.isEmpty {
            load?.step("Virtual geometry", detail: "\(newScene.virtualMeshes.count) meshes")
        }
        let virtualTracing = buffers == nil ? nil : try makeVirtualTracing(newScene, poolMB: options.poolMB)
        // The shaders too, when the API changes (a recompile) or the new scene has other light types.
        let pipelines = try makePipelines(api: options.api, compiler: options.compiler, lightTypes: newScene.lightTypeMask,
                                          stats: options.traversalStats, generation: options.shaderGeneration,
                                          procedural: newScene.proceduralCode, current: options.pipelines, load: load)
        if let buffers { SceneBuffers.touch(buffers.buffers, device: device, queue: buildQueue) }
        // The open world's scene is made again for every tile the camera comes to, never built from twice: its vertex
        // arrays, now in the buffers, go.
        if buffers != nil, newScene.worldPlace != nil {
            newScene.releaseGeometry()
        }
        return PreparedScene(scene: newScene, api: options.api, textures: textures, streamer: streamer, virtualTracing: virtualTracing,
                             buffers: buffers, pipelines: pipelines, shaderGeneration: options.shaderGeneration)
    }

    package static let flightOverride: (velocity: SIMD3<Float>, turn: Int)? = {
        let parts = (ProcessInfo.processInfo.environment["METALRENDERER_FLIGHT"] ?? "").split(separator: ",").compactMap { Float($0) }
        return parts.count >= 3 ? (SIMD3(parts[0], parts[1], parts[2]), parts.count > 3 ? Int(parts[3]) : 0) : nil
    }()

    /// Starts preparing `settings.scene` / `settings.api` in the background; `install` swaps it in when done.
    package func startLoadingScene() {
        let wanted = (scene: settings.scene, api: settings.api)
        if let loading, loading == wanted { return }
        // The workshop, edited: one load at a time, the latest settings when it is in (the editor sends many).
        if let loading, loading.api == wanted.api, loading.scene.isSameWorkshop(as: wanted.scene), wanted.scene.isSameWorkshop(as: scene.settings) {
            return
        }
        // Only the effects' catalog changed (the VFX editor's draft, restored at launch): the load goes on, and the
        // scene it makes takes the catalog when it is in (editEffects), in place if it can.
        if let loading, loading.api == wanted.api, wanted.scene.effects != loading.scene.effects {
            var same = wanted.scene
            same.effects = loading.scene.effects
            if same == loading.scene { return }
        }
        loading = wanted
        // Why the scene is made again (not a workshop's edit or the world's next tile: those are expected).
        if wanted.scene.kind == scene.settings.kind, benchmark == nil, !wanted.scene.isSameWorkshop(as: scene.settings),
           !wanted.scene.isSameWorld(as: scene.settings), !wanted.scene.isSameCity(as: scene.settings) {
            let changes = wanted.scene.changes(from: scene.settings) + (wanted.api != builtAPI ? ["api"] : [])
            print("\(wanted.scene.kind.title) made again: \(changes.isEmpty ? "virtual geometry or the season" : changes.joined(separator: ", ")) changed")
        }
        let reuse = wanted.scene == scene.settings ? scene : nil   // only the API changes
        let instances = reuse?.instances, options = loadOptions    // read here: the background must not touch them
        // The loading overlay's job (the one it replaces stops where it can: its scene would be thrown away).
        loadJob?.cancel()
        let job = benchmark != nil || wanted.scene.isSameWorkshop(as: scene.settings) || wanted.scene.isSameCity(as: scene.settings)
            ? nil : loadActivity.begin(reuse != nil ? "\(wanted.scene.kind.title) for \(wanted.api.title)"
            : wanted.scene.isSameWorld(as: scene.settings) ? "\(wanted.scene.kind.title): the next tile" : wanted.scene.kind.title)
        loadJob = job
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let start = CACurrentMediaTime()
            let result = Result {
                try self.prepareScene(wanted.scene, reuse: reuse, instances: instances, options: options, load: job)
            }
            let preparedMs = (CACurrentMediaTime() - start) * 1000
            self.renderThread.perform {
                guard let loading = self.loading, loading == wanted else {
                    return   // superseded by a newer request
                }
                self.loading = nil
                if self.loadJob === job { self.loadJob = nil }
                switch result {
                case .success(let prepared):
                    if self.benchmark?.isMeasuring == true { self.streaming.preparedMs.append(preparedMs) }
                    job?.step("Install", detail: "waiting for the frames in flight")
                    self.install(prepared, resetCamera: prepared.scene.settings.kind != self.scene.settings.kind)
                    job?.finish()
                case .failure(let error):
                    job?.fail()
                    print("Scene load failed, keeping the previous scene: \(error)")
                    self.settings.scene = self.scene.settings
                    self.settings.api = self.builtAPI
                }
            }
        }
    }

    /// Everything sized by the scene: geometry, acceleration structures, per-frame instance / light buffers, light maps.
    package func createSceneResources(_ prepared: PreparedScene? = nil) throws {
        builtAPI = prepared?.api ?? settings.api
        virtualTracing = nil
        plantsWritten = [WindFrame.PlantKey?](repeating: nil, count: Renderer.maxFramesInFlight)
        crowdSkinner = nil
        physicsGPU = nil
        particlesGPU = nil
        pendingEffects = nil
        particlesBuilt = [Int?](repeating: nil, count: Renderer.maxFramesInFlight)
        holding = nil
        lightBuffers = []
        frameDataWritten = [Bool](repeating: false, count: Renderer.maxFramesInFlight)
        lightStage = [GPULight](repeating: GPULight(positionRadius: .zero, color: .zero, axis: .zero, params: .zero),
                                count: scene.lights.count)
        stageComplete = false
        restirWritten = false
        restirGIWritten = false
        instanceASBuilt = []
        textureStreamer = prepared?.streamer
        let buffers = try prepared?.buffers ?? SceneBuffers(device: device, queue: buildQueue, scene: scene,
                                                            options: bufferOptions(api: builtAPI, known: namedPrimitives, blocks: namedBlocks,
                                                                                   instanceBlocks: namedInstanceBlocks,
                                                                                   extraInstances: scene.tracesClusters ? 1 : 0,
                                                                                   leafFall: Scene.leafFall(season: settings.foliage.season)))
        sceneBuffers = buffers
        makeLightProxies()
        primitiveASResources = buffers.primitives.map { $0 as MTLResource }
        try createShadingResources(textures: prepared?.textures)
        if let crowd = scene.crowd, !crowd.slots.isEmpty {
            let curves = crowd.hair.map { (first: scene.meshes[$0.mesh].vertexOffset, previous: scene.meshes[$0.mesh].prevOffset) }
            crowdSkinner = try CrowdSkinner(device: device, crowd: crowd, frameSlots: Renderer.maxFramesInFlight, curves: curves)
        }
        // The physics on the GPU, or only its cloths', soft bodies' and hair's meshes when the CPU steps it (they are drawn
        // from the GPU's buffers).
        if let physics = scene.physics {
            let liquid = physics.fluid?.systems.reduce(0) { $0 + $1.capacity } ?? 0
            // (An interior's loose furniture is stepped on the CPU: a few dozen bodies, asleep most of the time.)
            // (The demolition scene's rockets and walker are the CPU's step's alone: Physics+Demolition.swift.)
            let onGPU = scene.settings.kind.simulates && !scene.settings.kind.definition.cpuPhysics
                && scene.settings.physics.runsOnGPU(bodies: physics.bodies.count + physics.particles.count + physics.hairStrands.count + liquid,
                                                    fractures: physics.fractures)
            if onGPU || !physics.cloths.isEmpty || !physics.softVertices.isEmpty || !physics.hairGroups.isEmpty {
                physicsGPU = try PhysicsGPU(device: device, world: physics, sdfScene: buffers.sdf.scene, sdfResources: buffers.sdf.buffers,
                                            slots: Renderer.maxFramesInFlight, simulates: onGPU,
                                            clothPrevOffsets: scene.clothMeshes.map { scene.meshes[$0].prevOffset })
                if onGPU { scene.runPhysicsOnGPU() }
            }
            // The CPU's steps on their own thread, behind the frame (not a benchmark's, whose stills and timings are
            // the frame's own, unless METALRENDERER_PHYSICS_ASYNC=1 asks).
            PhysicsPool.shared.enabled = scene.settings.physics.everyCore
            scene.physicsAsync = !onGPU && scene.settings.kind.simulates && scene.settings.physics.asynchronous
                && (benchmark == nil || ProcessInfo.processInfo.environment["METALRENDERER_PHYSICS_ASYNC"] == "1")
        }
        if let particles = scene.particles {
            particlesGPU = try ParticlesGPU(device: device, system: particles, slots: Renderer.maxFramesInFlight)
            particlesGPU?.sdfScene = buffers.sdf.scene
            cpuBreakRing = nil
            if let proxies = scene.destructionRig?.dustProxies ?? scene.demolitionRig?.dustProxies, !proxies.isEmpty,
               scene.physics?.fractures == true {
                if let ring = physicsGPU?.breakRing, physicsGPU?.simulates == true {
                    particlesGPU?.breakRing = ring
                } else {
                    let ring = device.makeBuffer(length: PhysicsWorld.ringSlots * (16 + PhysicsWorld.ringEvents * MemoryLayout<GPUBreakEvent>.stride),
                                                 options: .storageModeShared)
                    if let ring { memset(ring.contents(), 0, ring.length) }
                    cpuBreakRing = ring
                    cpuBreaksTaken = 0
                    particlesGPU?.breakRing = ring
                }
                particlesGPU?.breakProxies = proxies
            }
            scene.replayParticles()
        }
        try createLightBuffers()
        virtualTracing = try prepared?.virtualTracing ?? makeVirtualTracing(scene, poolMB: settings.virtualGeometry.poolMB)
        let lmd = MTLTextureDescriptor()
        lmd.textureType = .type2DArray
        lmd.pixelFormat = .r32Float
        // With many lights (LIGHT_TABLE) nothing reads light maps: a placeholder (more than 2048 slices can't exist).
        lmd.width = scene.usesLightTable ? 8 : Renderer.lightMapSize(lightCount: scene.lights.count)
        lmd.height = lmd.width
        lmd.arrayLength = scene.usesLightTable ? 1 : max(scene.lights.count, 1)
        lmd.usage = [.shaderRead, .shaderWrite]
        lmd.storageMode = .private
        guard let lm = device.makeTexture(descriptor: lmd) else { throw RendererError.resourceCreation("texture lightMap") }
        lm.label = "lightMap"
        lightMap = lm
    }

    /// The VFX editor's edit (`settings.scene.effects`, a catalog's key): run in the scene's particles' place when only
    /// the effects differ and their layout stays (VFXLive.swift): their values at once, new code once it compiles (the
    /// old running meanwhile). Otherwise the scene is made again, as for any other change of its settings.
    package func editEffects() {
        var same = settings.scene
        same.effects = scene.settings.effects
        guard same == scene.settings else { return }
        // A scene that placed no effects (but the stage, which places what the catalog names) is the same with any
        // catalog: only its key changes (the VFX editor's draft, restored at launch, set it).
        if scene.effects.isEmpty && scene.settings.kind != .vfxStage {
            scene.adoptEffects(settings.scene.effects, system: nil, effects: [], owners: [], notes: [])
            return
        }
        guard let gpu = particlesGPU,
              let next = scene.particleSystem(replacing: VFXCatalog.resolve(scene.settings.effects),
                                              with: VFXCatalog.resolve(settings.scene.effects)) else { return }
        let running = pendingEffects?.system ?? gpu.system
        let kind = running.edit(to: next.system)
        if benchmark != nil { print("Effects: the edit is \(kind == .values ? "run in place" : kind == .code ? "new code" : "a new scene")") }
        guard kind != .rebuild else { pendingEffects = nil; return }
        _ = next.system.continuing(gpu.system)
        let key = settings.scene.effects
        if kind == .values && pendingEffects == nil {
            do {
                try gpu.adopt(next.system, kernels: nil, device: device)
            } catch {
                print("Effects: the edit isn't run in place (\(error)); the scene is made again")
                return
            }
            scene.adoptEffects(key, system: next.system, effects: next.effects, owners: next.owners, notes: next.notes)
            particlesVersion += 1   // posed again, paused too
        } else {
            pendingEffects = next   // compiled while the running ones go on (the frame's particles step adopts it)
            scene.adoptEffects(key, system: nil, effects: [], owners: [], notes: [])
        }
    }
}
