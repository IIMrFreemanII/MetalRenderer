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
    // MARK: - Procedural materials

    /// The Material Designer's edit (`settings.scene.materials`, a catalog's key): baked in place when every
    /// procedural material's graph keeps its channels (what the scene was made for: its opacity decides how it is
    /// traced, its textures' slots are there); otherwise the scene is made again, as for any other change.
    package func editMaterials() {
        var same = settings.scene
        same.materials = scene.settings.materials
        guard same == scene.settings else { return }
        let catalog = MaterialCatalog.resolve(settings.scene.materials)
        for pm in scene.procedural {
            let g = catalog.graph(pm.graph)
            let channels = Set(g?.channels.keys.map { $0 } ?? [])
            guard channels.contains(.opacity) == pm.channels.contains(.opacity) else { return }
            // As code: only an edit that keeps its code (its values) runs in place; another compiles it into the shading.
            guard Renderer.programCode(g, pm, catalog) == pm.code else { return }
            // Displacement switched on or off, another detail, or further than the meshes' bounds were grown by:
            // other meshes (the scene is made again). Its amount within them: moved in place.
            let was = pm.made?.surface ?? MatSurface(), now = g?.surface ?? MatSurface()
            guard (was.displacement > 0) == (now.displacement > 0) else { return }
            if now.displacement > 0 {
                guard was.displacementDetail == now.displacementDetail, now.displacementReach <= was.displacementRoom else { return }
            }
        }
        scene.adoptMaterials(settings.scene.materials)
    }

    /// `g`'s program as `pm`'s would be (its number and where its parameters start kept), if `g` runs as code.
    private static func programCode(_ g: MaterialGraph?, _ pm: ProceduralMaterial, _ catalog: MaterialCatalog) -> String? {
        guard let g, g.surface.shaderMode, let plan = try? MatPlan(g, library: { catalog.graph($0) }),
              let p = try? MatShaderCode.program(plan, number: pm.program ?? 0, base: pm.paramBase) else { return nil }
        return p.functions + p.body
    }

    /// What `slot`'s table holds of the procedural materials' bakes (what its frames declare).
    package func proceduralResources(slot: Int) -> [MTLResource] { Array(slotTextures[slot].values) }

    /// The procedural materials as their graphs are now: each whose graph's key isn't the one it shows gets its bake's
    /// textures and values (a benchmark bakes it there and then; the app asks for it and takes it a frame when it is
    /// ready). Then `slot`'s table and extras catch up, and textures no frame can read any more go.
    package func updateProcedural(slot: Int) {
        if !scene.procedural.isEmpty {
            let key = scene.settings.materials
            if proceduralKeys.catalog != key { proceduralKeys = (key, [:]) }
            let catalog = MaterialCatalog.resolve(key)
            let bake = MaterialBake.shared(device)
            for pm in scene.procedural {
                guard let g = catalog.graph(pm.graph) else { continue }
                let k = proceduralKeys.keys[pm.graph] ?? MaterialBake.key(g, catalog: catalog)
                proceduralKeys.keys[pm.graph] = k
                guard proceduralApplied[pm.material] != k else { continue }
                if let number = pm.program, let plan = try? MatPlan(g, library: { catalog.graph($0) }),
                   let p = try? MatShaderCode.program(plan, number: number, base: pm.paramBase), p.functions + p.body == pm.code,
                   pm.paramBase + p.params.count <= scene.proceduralParams.count {
                    // As code: its values into the parameters (its bake still gives the height's parallax and the opacity).
                    scene.proceduralParams.replaceSubrange(pm.paramBase..<(pm.paramBase + p.params.count), with: p.params)
                    scene.proceduralParamsVersion += 1
                }
                if let o = bake.baked(k) ?? (benchmark != nil ? bake.bakeNow(g, key: k, catalog: catalog) : nil) {
                    applyProcedural(pm, outputs: o, key: k)
                } else {
                    bake.request(g, key: k, catalog: catalog) {}
                }
            }
        }
        updatePainted()
        guard slot < textureTables.count else { return }
        if !tablePending[slot].isEmpty {
            let table = textureTables[slot].contents().bindMemory(to: MTLResourceID.self, capacity: materialTextures.count)
            for (i, t) in tablePending[slot] where Int(i) < materialTextures.count {
                table[Int(i)] = t.gpuResourceID
                slotTextures[slot][i] = t
            }
            tablePending[slot] = [:]
        }
        if extrasWritten[slot] != scene.extrasVersion {
            let extras = scene.extrasArray(), opacity = scene.opacityRecords()
            if extras.count * MemoryLayout<GPUMaterialExtra>.stride <= extrasBuffers[slot].length {
                extras.withUnsafeBytes { extrasBuffers[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            }
            if !opacity.isEmpty, opacity.count * 16 <= opacityBuffers[slot].length {
                opacity.withUnsafeBytes { opacityBuffers[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            }
            extrasWritten[slot] = scene.extrasVersion
        }
        if procParamsWritten[slot] != scene.proceduralParamsVersion {
            let params = scene.proceduralParams
            if !params.isEmpty, params.count * 16 <= procParamBuffers[slot].length {
                params.withUnsafeBytes { procParamBuffers[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            }
            procParamsWritten[slot] = scene.proceduralParamsVersion
        }
        retiredTextures.removeAll { frameIndex &- $0.frame > UInt32(2 * Renderer.maxFramesInFlight + 1) }
    }

    /// The displaced meshes whose material's height (or its displacement's values) changed: their vertices moved from
    /// where they were (MaterialShaders/MatDisplace.metal), then their structures built again, and the top level's
    /// (every slot's, as it comes).
    package func encodeDisplacement(passes: FrameEncoder) {
        guard !displacePending.isEmpty, let buffers = displaceBuffers, var build = sceneBuffers.displacedBuild,
              let pipeline = try? MatCompiler.shared.state("matDisplace", device: device) else { return }
        defer { displacePending = [] }
        guard let enc = passes.compute("displace", serial: true) else { return }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(buffers.vertices, offset: 0, index: 1)
        enc.setBuffer(buffers.members, offset: 0, index: 2)
        enc.setBuffer(uvBuffer, offset: 0, index: 3)
        enc.setBuffer(positionBuffer, offset: 0, index: 4)
        enc.useResources([buffers.vertices, buffers.members, uvBuffer], usage: .read)
        enc.useResource(positionBuffer, usage: [.read, .write])
        for d in scene.displaced where displacePending.contains(d.material) {
            guard let (height, s) = displaceSource[d.material] else { continue }
            // The height's level whose texels are about as far apart as the vertices.
            let spacing = 0.5 * d.edge * d.uvPerMetre * s.uvScale * Float(height.width)
            var args = MatDisplaceArgs(first: UInt32(d.first), count: UInt32(d.count), records: UInt32(d.records), members: UInt32(d.members),
                                       amount: s.displacement / d.scale, mid: s.displacementMid, uvScale: s.uvScale,
                                       lod: min(max(log2(max(spacing, 1)), 0), Float(height.mipmapLevelCount - 1)))
            enc.setBytes(&args, length: MemoryLayout<MatDisplaceArgs>.stride, index: 0)
            enc.setTexture(height, index: 0)
            enc.useResource(height, usage: .read)
            enc.dispatchThreads(MTLSize(width: d.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            build.meshes.append(d.mesh)
        }
        passes.endCompute()
        guard !build.meshes.isEmpty else { return }
        passes.updatePrimitives(build, pass: "displace")
        instanceASBuilt.removeAll()
    }

    /// Instances moved for good (Scene.moveInstances: a terrain's scatter, what stands on it): their records and
    /// descriptors written again, the top level refitted. A still scene's are one set for every slot: written once.
    package func writeInstanceEdits(slot: Int, still: Bool) {
        let edits = scene.takeInstanceEdits()
        while pendingInstanceEdits.count < Renderer.maxFramesInFlight { pendingInstanceEdits.append([]) }
        if !edits.isEmpty { for s in pendingInstanceEdits.indices { pendingInstanceEdits[s].formUnion(edits) } }
        let list = pendingInstanceEdits[slot]
        guard !list.isEmpty else { return }
        if still { for s in pendingInstanceEdits.indices { pendingInstanceEdits[s] = [] } } else { pendingInstanceEdits[slot] = [] }
        let records = instanceDataBuffers[slot].contents().bindMemory(to: GPUInstanceData.self, capacity: scene.instances.count)
        for i in list where i < scene.instances.count {
            scene.writeInstanceData(into: records, all: true, range: i..<(i + 1))
            sceneBuffers.writeInstanceDescriptors(slot: slot, scene: scene, api: builtAPI, all: true, range: i..<(i + 1))
        }
        if still { stillRefitPending = true } else { instanceASStale[slot] = true }
    }

    /// The terrain's sectors the brushes changed (Renderer+Terrain.swift): their new vertices copied into their
    /// buffers, their structures built again, the top level's after them (a still scene's refitted, another's built
    /// again in every slot as it comes); the reference starts over.
    package func encodeTerrain(slot: Int, passes: FrameEncoder) {
        guard let work = prepareTerrainFrame(slot: slot, buffers: sceneBuffers), !work.meshes.isEmpty, var build = sceneBuffers.terrainBuild else {
            // (Instances moved for good in a still scene: its one top level refitted.)
            if stillRefitPending, let refit = sceneBuffers.stillRefit { passes.updateTLAS(refit, pass: "terrain tlas") }
            stillRefitPending = false
            return
        }
        stillRefitPending = false
        passes.copyBuffers(work.copies, pass: "terrain copy")
        build.meshes = work.meshes
        passes.updatePrimitives(build, pass: "terrain")
        if let refit = sceneBuffers.stillRefit { passes.updateTLAS(refit, pass: "terrain tlas") } else { instanceASBuilt.removeAll() }
        resetReference()
    }

    /// An RGBA8 texture's sRGB view (made once a texture).
    package func srgbView(_ t: MTLTexture) -> MTLTexture {
        if let v = srgbViews[ObjectIdentifier(t)] { return v }
        let v = t.makeTextureView(pixelFormat: .rgba8Unorm_srgb) ?? t
        srgbViews[ObjectIdentifier(t)] = v
        if srgbViews.count > 64 {   // views of textures the bakes and the painter let go of
            let live = Set(proceduralTextures.values.map { ObjectIdentifier($0) })
            srgbViews = srgbViews.filter { live.contains(ObjectIdentifier($0.value)) || $0.value === v }
        }
        return v
    }

    /// Texture slot `index` (Scene.textures) holds `t` from now on: each frame slot's table takes it as it is next
    /// written; what it held goes once no frame in flight can read it.
    package func installTexture(_ t: MTLTexture, slot index: UInt32) {
        guard proceduralTextures[index] !== t else { return }
        if let old = proceduralTextures[index] { retiredTextures.append((frameIndex, old)) }
        proceduralTextures[index] = t
        for s in tablePending.indices { tablePending[s][index] = t }
    }

    /// `pm`'s material as its graph's bake `o` says: its textures in its slots (each frame slot takes them as it is
    /// next written), its values (a texture's channel is the value; a channel without one, a neutral value), its
    /// extras (parallax, opacity cutoff, UV scale, occlusion).
    private func applyProcedural(_ pm: ProceduralMaterial, outputs o: MatOutputs, key: String) {
        let textures: [MTLTexture?] = [o.baseColor.map(srgbView), o.orm, o.normal, o.emissive.map(srgbView), o.height, o.opacity]
        for (k, t) in textures.enumerated() {
            guard let t, k < pm.slots.count else { continue }
            installTexture(t, slot: pm.slots[k])
        }
        let code = pm.program != nil
        // As code, the graph's channels are the shading's (its bake's textures stand by unread, but height and opacity).
        func has(_ c: ProcSlot) -> Bool {
            if code && c != .height && c != .opacity {
                switch c {
                case .baseColor: return pm.channels.contains(.baseColor)
                case .orm: return !pm.channels.isDisjoint(with: [.ambientOcclusion, .roughness, .metallic])
                case .normal: return pm.channels.contains(.normal)
                default: return pm.channels.contains(.emissive)
                }
            }
            return textures[c.rawValue] != nil
        }
        func slot(_ c: ProcSlot) -> UInt32 { has(c) && !code ? pm.slots[c.rawValue] : .max }
        let s = o.surface
        var m = scene.materials[pm.material]
        m.textures = SIMD4(slot(.baseColor), slot(.orm), slot(.normal), slot(.emissive))
        m.albedo = SIMD4(has(.baseColor) ? SIMD3(repeating: 1) : SIMD3(repeating: 0.5), has(.orm) ? 1 : 0)
        m.emission = SIMD4(has(.emissive) ? SIMD3(repeating: s.emissiveIntensity) : .zero, has(.orm) ? 1 : 0.6)
        m.params = SIMD4(1, s.normalStrength, 0, 0)
        scene.setMaterial(pm.material, m)
        // A material whose every instance is displaced: its height moves them (encodeDisplacement), and isn't the
        // parallax's too.
        let displaced = scene.displacedMaterials.contains(pm.material) && s.displacement > 0
        let depth = displaced ? 0 : s.heightDepth
        var e = GPUMaterialExtra()
        e.textures = SIMD4(has(.height) && depth > 0 ? pm.slots[ProcSlot.height.rawValue] : .max,
                           pm.channels.contains(.opacity) ? pm.slots[ProcSlot.opacity.rawValue] : .max, 1, pm.program.map(UInt32.init) ?? .max)
        e.surface = SIMD4(depth, s.uvScale, s.alphaCutoff, pm.channels.contains(.ambientOcclusion) ? s.aoStrength : 0)
        if let h = o.height, scene.displaced.contains(where: { $0.material == pm.material }) {
            let was = displaceSource[pm.material]
            if was?.height !== h || was?.surface.displacement != s.displacement || was?.surface.displacementMid != s.displacementMid
                || was?.surface.uvScale != s.uvScale {
                displaceSource[pm.material] = (h, s)
                displacePending.insert(pm.material)
            }
        }
        if scene.materialExtras[pm.material] != e {
            scene.materialExtras[pm.material] = e
            scene.extrasVersion += 1
        }
        proceduralApplied[pm.material] = key
    }

    /// The pending edit's system in the particles' place, with its code's `kernels`, replayed from the start.
    package func adoptEffects(_ pending: (system: ParticleSystem, effects: [VFXInstance], owners: [String], notes: [String]),
                              kernels: ParticleKernels?) {
        pendingEffects = nil
        guard let gpu = particlesGPU else { return }
        do {
            try gpu.adopt(pending.system.continuing(gpu.system), kernels: kernels, device: device)
        } catch {
            print("Effects: the edit isn't run (\(error))")
            return
        }
        scene.adoptEffects(scene.settings.effects, system: pending.system, effects: pending.effects, owners: pending.owners, notes: pending.notes)
        scene.replayParticles()
        particlesVersion += 1
    }

    /// What the VFX editor shows of the scene's effects (nil: it has none).
    package func effectsStatus() -> VFXStatus? {
        guard let gpu = particlesGPU else { return nil }
        var s = VFXStatus()
        let system = gpu.system
        s.emitters = system.emitters.indices.map { i in
            VFXStatus.Emitter(effect: scene.effectOwners[safe: i] ?? "", name: system.emitters[i].name,
                              program: system.programs[i] != nil, capacity: system.emitters[i].capacity)
        }
        if let source = pendingEffects?.system.programSource ?? system.programSource {
            s.failure = VFXCompiler.shared.failure(for: source, setup: vfxSetup)
            s.compiling = s.failure == nil && (pendingEffects != nil || gpu.programKernels == nil)
        }
        s.compileMs = VFXCompiler.shared.lastMilliseconds
        s.notes = scene.effectNotes
        s.key = scene.settings.effects
        for (i, n) in gpu.aliveCounts().enumerated() where i < s.emitters.count { s.emitters[i].alive = n }
        s.time = animTime
        return s
    }

    /// What the VFX editor's gizmos show (nil: none).
    package func setGizmos(_ target: VFXGizmos.Target?) {
        gizmoTarget = target
        if target?.emitter == nil { gizmoHandle = nil }
    }

    /// The scene's clock at `t` (s): the VFX editor's timeline (the particles replay from the start to go back).
    package func setTime(_ t: Float) {
        animTime = max(t, 0)
        previousAnimTime = animTime
    }

    /// The gizmos over the finished frame `output` (Shaders/Gizmo.metal).
    /// Arms click-to-pick (the controller's, for the Material Designer).
    package func armPick() { pickArmed = true }
    package func disarmPick() {
        pickArmed = false
        if !pickSelects { pickRequest = nil }
    }

    /// The pick's ray, traced this frame (one thread: pickKernel): its answer is read when this slot is next written.
    package func encodePick(_ plan: FramePlan, passes: FrameEncoder) {
        guard let cursor = pickRequest else { return }
        pickRequest = nil
        if pickBuffer == nil {
            pickBuffer = device.makeBuffer(length: 48, options: .storageModeShared)
            pickBuffer?.label = "pick"
        }
        guard let buffer = pickBuffer, let enc = passes.compute("pick") else { return }
        var ray = (SIMD4<Float>(camera.position, 0), SIMD4<Float>(cursorRay(cursor), 0))
        bind(enc, .pick, plan.uniforms, sceneSlot: plan.slot)
        enc.setBytes(&ray, length: 32, index: 9)
        enc.setBuffer(buffer, offset: 0, index: 10)
        enc.useResource(buffer, usage: [.read, .write])
        dispatch(enc, .pick, width: 1, height: 1)
        passes.endCompute()
        pickPending = plan.slot
    }

    /// A pick traced in `slot`'s last frame (which is done): what it found.
    package func readPick(slot: Int) {
        guard pickPending == slot, let buffer = pickBuffer else { return }
        pickPending = nil
        let v = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 3)
        if pickSelects {
            pickSelects = false
            let i = v[0].x >= 0 ? Int(v[0].x) : nil
            select(i.map { FrameTarget(kind: scene.settings.kind, scope: MaterialAssignments.scope(scene.settings), instances: [$0], box: nil) })
            onSelectedInView?(i)
            return
        }
        guard v[0].x >= 0 else { onMaterialPicked?(nil); return }
        let material = Int(v[0].y)
        // Its fingerprint as the scene made it: a procedural one's from before it was (Scene.makeProcedural).
        let procedural = scene.procedural.first { $0.material == material }
        let fingerprint = procedural?.fingerprint ?? (material < scene.materials.count ? MaterialAssignments.fingerprint(scene.materials[material]) : "")
        onMaterialPicked?(MaterialPick(instance: Int(v[0].x), material: material, fingerprint: fingerprint, graph: procedural?.graph,
                                       albedo: SIMD3(v[1].x, v[1].y, v[1].z), position: SIMD3(v[2].x, v[2].y, v[2].z)))
    }

    package func encodeGizmos(_ outputs: [MTLTexture], slot: Int, passes: FrameEncoder) {
        guard let output = outputs.first else { return }
        // The brushes, what the graph showed, the placed object's arrows.
        var segments = painterRingSegments() + terrainRingSegments() + selectionSegments() + placementSegments()
        if let target = gizmoTarget, let gpu = particlesGPU {
            let (s, handle) = VFXGizmos.segments(gpu.system, owners: scene.effectOwners, target: target)
            gizmoHandle = handle
            segments += s
        } else {
            gizmoHandle = nil
        }
        gizmoViewSize = SIMD2(Float(output.width), Float(output.height))
        guard !segments.isEmpty else { return }
        let bytes = segments.count * MemoryLayout<VFXGizmos.Segment>.stride
        if (gizmoBuffers[slot]?.length ?? 0) < bytes {
            gizmoBuffers[slot] = device.makeBuffer(length: max(bytes * 2, 4096), options: .storageModeShared)
            gizmoBuffers[slot]?.label = "gizmos\(slot)"
        }
        guard let buffer = gizmoBuffers[slot], let enc = passes.compute("gizmos") else { return }
        segments.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        let c = camera
        var view = VFXGizmos.View(position: SIMD4(c.position, 0), right: SIMD4(c.right, 0), up: SIMD4(c.up, 0), forward: SIMD4(c.forward, 0),
                                  size: gizmoViewSize, tanY: tan(c.fovY / 2), aspect: gizmoViewSize.x / max(gizmoViewSize.y, 1),
                                  count: UInt32(segments.count), samples: VFXGizmos.samples)
        enc.setComputePipelineState(pipelines[.gizmoLines])
        enc.setBytes(&view, length: MemoryLayout<VFXGizmos.View>.stride, index: 0)
        enc.setBuffer(buffer, offset: 0, index: 1)
        for output in outputs {   // the frame's picture, and the in-between one before it
            enc.setTexture(output, index: 0)
            dispatch(enc, .gizmoLines, width: Int(VFXGizmos.samples), height: segments.count)
        }
        passes.endCompute()
    }

    /// Replaces the scene with `settings.scene` right away (benchmarks; the app loads in the background).
    package func rebuildScene(resetCamera: Bool) {
        loading = nil   // a scene still loading is for settings this one replaces
        let remake = sceneRemake
        sceneRemake = nil
        if let remake { print("\(settings.scene.kind.title) made again: \(remake)") }
        do {
            let reuse = remake == nil && settings.scene == scene.settings ? scene : nil
            install(try prepareScene(settings.scene, reuse: reuse, options: loadOptions), resetCamera: resetCamera)
        } catch {
            print("Scene rebuild failed, keeping the previous scene: \(error)")
            settings.scene = scene.settings
            settings.api = builtAPI
        }
    }

    /// Swaps in a prepared scene. Waits for in-flight frames, since they still read the old buffers.
    package func install(_ prepared: PreparedScene, resetCamera: Bool) {
        for _ in 0..<Renderer.maxFramesInFlight { frameSemaphore.wait() }
        defer { for _ in 0..<Renderer.maxFramesInFlight { frameSemaphore.signal() } }
        let oldAPI = builtAPI, oldPipelines = pipelines
        // What the scene being replaced is drawn with: to go back to if this fails, and to let go of if it doesn't. In
        // a box, which is emptied off this thread: letting go of an open world's scene takes 13 ms.
        let old = Replaced(PreparedScene(scene: scene, api: oldAPI, textures: materialTextures, streamer: textureStreamer,
                                         virtualTracing: virtualTracing, buffers: sceneBuffers, pipelines: nil,
                                         shaderGeneration: shaderGeneration))
        let oldSettings = scene.settings, oldPlace = scene.worldPlace
        let start = CACurrentMediaTime()
        scene = prepared.scene
        do {
            if let ready = prepared.pipelines, prepared.shaderGeneration == shaderGeneration {
                pipelines = ready
            } else if let made = try makePipelines(api: prepared.api, compiler: compiler(for: prepared.api),
                                                   lightTypes: scene.lightTypeMask, stats: TraceSceneArgs.statsEnabled,
                                                   generation: shaderGeneration, procedural: scene.proceduralCode, current: pipelines) {
                pipelines = made   // here only if the shaders were reloaded while the scene was loading
            }
            try createSceneResources(prepared)
            terrain.sceneChanged(scene, blocks: sceneBuffers.blocks)
        } catch {
            print("Scene rebuild failed, keeping the previous scene: \(error)")
            scene = old.parts!.scene
            settings.scene = oldSettings
            settings.api = oldAPI
            pipelines = oldPipelines
            try? createSceneResources(old.parts)
        }
        // The open world made around another tile is the same world in the same place: what the frames have gathered
        // of it holds.
        // ...and the city with another building's interior in it: the same city where it was.
        let sameWorld = scene.settings.isSameWorld(as: oldSettings) || scene.settings.isSameCity(as: oldSettings)
        // The workshop edited: the same few plants a little changed, where they were. What the frames gathered of the
        // light mostly holds (the plants are new, but the sky, the ground and the camera aren't).
        let sameWorkshop = scene.settings.isSameWorkshop(as: oldSettings)
        var moved = SIMD2<Float>()
        if sameWorld, let was = oldPlace, let now = scene.worldPlace {
            // The scene's origin has moved: the camera is where it was in the world.
            moved = SIMD2(Float(was.anchor.x - now.anchor.x), Float(was.anchor.y - now.anchor.y))
            for c in [\Renderer.camera, \Renderer.prevCamera] {
                self[keyPath: c].position.x += moved.x
                self[keyPath: c].position.z += moved.y
            }
            // ...and so is where Freeze LOD holds the detail for.
            frozenLOD?.0 += SIMD3(moved.x, 0, moved.y)
        }
        if sameWorkshop {
            resetReference()
        } else if !(sameWorld && moved == .zero) {
            resetGIState()
            upscalerReset = true
            resetReference()
        } else if !scene.meshLights.isEmpty || old.parts?.scene.meshLights.isEmpty == false {
            // At night the tiles' lights are other ones: what the pixels kept of the lights (a reservoir names its
            // light by its place in the scene's table) is of the scene before.
            restirWritten = false
            reservoirsWritten = false
        }
        if resetCamera {
            camera = scene.defaultCamera
            prevCamera = camera
        }
        // Walking: on in what it was on (the same workshop or city a little changed), off otherwise.
        walkGrid = scene.walkColliders.isEmpty && scene.walkGround == nil ? nil : ColliderGrid(scene.walkColliders)
        if walkGrid == nil || !(sameWorkshop || scene.settings.isSameCity(as: oldSettings)) { walker = nil }
        lastLiftY = scene.interiorControls?.lifts.map(\.y) ?? []
        // The workshops and the VFX stage: the camera turns about what they show, framed on it when that changes (the
        // stage's effects, not their edits: a capacity's edit makes the scene again).
        let stageChanged = scene.settings.kind == .vfxStage
            && (oldSettings.kind != .vfxStage || oldSettings.stage.effects != scene.settings.stage.effects)
        // (Another scene's selection names other instances.)
        if let s = selection, !inScene(s.target) { select(nil) }
        if walker != nil {
            orbit = nil
        } else if !scene.settings.kind.orbits {
            if resetCamera { orbit = nil }   // (the pivot navigation set stays while the camera does)
        } else if resetCamera || stageChanged || (scene.settings.kind.isWorkshop && (!sameWorkshop
                    || oldSettings.plants.layout != scene.settings.plants.layout || oldSettings.plants.species != scene.settings.plants.species
                    || oldSettings.buildings.view != scene.settings.buildings.view)) {
            frameWorkshop()
        } else if orbit == nil, let focus = scene.focus {
            orbit = (focus.centroid, length(camera.position - focus.centroid))
        }
        // ...and its sky is the same sky: no need to draw all of it again (a sixteenth a frame keeps it up to date).
        if sameWorld || sameWorkshop, let drawn = skyRefreshed { skyRefreshed = (drawn.sky, scene.serial) }
        if #available(macOS 26.0, *) { (metal4Storage as? Metal4Frame)?.noteSceneChange() }
        DispatchQueue.global(qos: .utility).async { old.parts = nil }
        let installedMs = (CACurrentMediaTime() - start) * 1000
        if sameWorld, benchmark?.isMeasuring == true { streaming.installedMs.append(installedMs) }
        if sameWorld { benchmark?.noteSwap() }
        if benchmark == nil {
            let now = CACurrentMediaTime()
            settlingStreams = (now, now + Renderer.settlingStreamsSeconds)
        }
        print(String(format: "Scene: %@, %d instances, %d lights, %@ (installed in %.0f ms)", scene.settings.kind.title,
                     sceneBuffers.instanceCount, scene.lights.count, builtAPI.title, installedMs))
        if let target = pendingFrame, target.scope == MaterialAssignments.scope(scene.settings) || target.kind == scene.settings.kind {
            frame(target)
        }
        // The Project Graph's outline of it (not of the open world's next tile, or the city's next interior).
        if !(sameWorld && scene.settings.kind == oldSettings.kind) { publishOutline() }
    }

    /// The scene's outline to the Project Graph and its file.
    package func publishOutline() {
        guard OutlineStore.writes else { return }
        let outline = scene.makeOutline()
        onOutline?(outline)
        OutlineStore.save(outline, wait: benchmark != nil)
    }

    /// What shading reads besides the scene's buffers: the textures and their table, and each slot's arguments.
    package func createShadingResources(textures: [MTLTexture]?) throws {
        // The materials are the scene's as the buffers were made; what has changed since goes to every slot.
        materialsPending = [Range<Int>?](repeating: scene.takeMaterialsDirty(), count: Renderer.maxFramesInFlight)
        materialTextures = try textures ?? MaterialTextures.load(scene.textures, device: device, queue: queue)
        textureTables = try (0..<Renderer.maxFramesInFlight).map { try makeBuffer(materialTextures.map(\.gpuResourceID), "textureTable\($0)") }
        let extras = scene.extrasArray(), opacity = scene.opacityRecords()
        extrasBuffers = try (0..<Renderer.maxFramesInFlight).map { try makeBuffer(extras, "materialExtras\($0)") }
        opacityBuffers = try (0..<Renderer.maxFramesInFlight).map { try makeBuffer(opacity, "opacity\($0)") }
        extrasWritten = [Int](repeating: scene.extrasVersion, count: Renderer.maxFramesInFlight)
        procParamBuffers = try (0..<Renderer.maxFramesInFlight).map { try makeBuffer(scene.proceduralParams, "proceduralParams\($0)") }
        procParamsWritten = [Int](repeating: scene.proceduralParamsVersion, count: Renderer.maxFramesInFlight)
        proceduralTextures = [:]
        slotTextures = Array(repeating: [:], count: Renderer.maxFramesInFlight)
        tablePending = Array(repeating: [:], count: Renderer.maxFramesInFlight)
        proceduralApplied = [:]
        painter.sceneChanged()
        displaceBuffers = nil
        if !scene.displaced.isEmpty {
            displaceBuffers = (try makeBuffer(scene.displaceVertices, "displaceVertices"), try makeBuffer(scene.displaceMembers, "displaceMembers"))
        }
        displaceSource = [:]
        displacePending = []
        staticMinLod = try makeBuffer([Float](repeating: 0, count: max(materialTextures.count, 1)), "textureMinLod")
        feedbackDummy = try makeBuffer([UInt32](repeating: 0, count: max(materialTextures.count, 1) * TextureStreamer.levelBins),
                                       "textureFeedback")
        shadingArgs = []
        for slot in 0..<Renderer.maxFramesInFlight {
            guard let args = device.makeBuffer(length: Renderer.shadingArgsLength, options: .storageModeShared) else {
                throw RendererError.resourceCreation("buffer shadingArgs")
            }
            args.label = "shadingArgs\(slot)"
            let p = args.contents()
            p.storeBytes(of: materialBuffers[slot].gpuAddress, toByteOffset: 0, as: UInt64.self)
            p.storeBytes(of: uvBuffer.gpuAddress, toByteOffset: 8, as: UInt64.self)
            p.storeBytes(of: textureTables[slot].gpuAddress, toByteOffset: 16, as: UInt64.self)
            p.storeBytes(of: (textureStreamer?.minLodBuffer(slot: slot) ?? staticMinLod).gpuAddress, toByteOffset: 24, as: UInt64.self)
            p.storeBytes(of: (textureStreamer?.feedbackBuffer(slot: slot) ?? feedbackDummy).gpuAddress, toByteOffset: 32, as: UInt64.self)
            p.storeBytes(of: emissiveBuffer.gpuAddress, toByteOffset: 40, as: UInt64.self)
            p.storeBytes(of: triangleMaterialBuffer.gpuAddress, toByteOffset: 48, as: UInt64.self)
            p.storeBytes(of: extrasBuffers[slot].gpuAddress, toByteOffset: Renderer.shadingExtrasOffset, as: UInt64.self)
            p.storeBytes(of: procParamBuffers[slot].gpuAddress, toByteOffset: Renderer.shadingProcParamsOffset, as: UInt64.self)
            p.storeBytes(of: sceneBuffers.damage?.gpuAddress ?? 0, toByteOffset: Renderer.shadingDamageOffset, as: UInt64.self)
            shadingArgs.append(args)
            writeSkyArguments(slot: slot)
        }
        // The textures too, unless they are a sparse heap's (Metal 3's streamer: `bindScene` declares the heap).
        // Metal 4's streamed ones are placement-sparse textures of the device's, each its own allocation: its
        // residency set forgets what no frame declares, and a texture whose levels have settled is never uploaded to.
        // And the borrowed meshes' buffers, which a hit reaches through the mesh table, the instance blocks'
        // records, which it reaches through theirs, and the SDF shapes, which the ray queries reach through their boxes'
        // data.
        // One += per part: a single expression of them all took the type checker over half a second.
        var resources: [MTLResource] = []
        for perSlot in [materialBuffers, textureTables, extrasBuffers, opacityBuffers, procParamBuffers] { resources += perSlot }
        let shared: [MTLResource] = [uvBuffer, staticMinLod, feedbackDummy, emissiveBuffer, triangleMaterialBuffer]
        resources += shared
        if let damage = sceneBuffers.damage { resources.append(damage) }
        if textureStreamer?.placement != false { resources += materialTextures }
        resources += sceneBuffers.blockBuffers
        resources += sceneBuffers.instanceResources
        let voxels: [MTLBuffer] = sceneBuffers.voxelLOD?.grids.buffers ?? sceneBuffers.plants?.voxels?.buffers ?? []
        resources += voxels
        if sceneBuffers.sdf.shapeCount > 0 { resources += sceneBuffers.sdf.buffers }
        shadingResources = resources
    }

    /// The blue-noise tile as a texture; without `values`, zeros (bound until the tile is ready). Any thread.
    private static func blueNoiseTexture(_ device: MTLDevice, values: [Float]?) throws -> MTLTexture {
        let n = BlueNoise.size
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: n, height: n, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture blueNoise") }
        texture.label = "blueNoise"
        (values ?? [Float](repeating: 0, count: n * n)).withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: n * MemoryLayout<Float>.stride)
        }
        return texture
    }

    /// The tile comes from the cache file. Without one (the first launch) generating it takes about half a second:
    /// the app does that in the background and samples with white noise until the tile is in (`blueNoiseReady`);
    /// a benchmark waits for it.
    package func createBlueNoiseTexture() throws {
        if let values = benchmark != nil ? BlueNoise.tile() : BlueNoise.cached() {
            blueNoiseTexture = try Renderer.blueNoiseTexture(device, values: values)
            blueNoiseReady = true
            return
        }
        blueNoiseTexture = try Renderer.blueNoiseTexture(device, values: nil)
        let device = device
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let texture = try? Renderer.blueNoiseTexture(device, values: BlueNoise.tile())
            self?.renderThread.perform {
                guard let self, let texture else { return }
                self.blueNoiseTexture = texture   // frames in flight keep the old one
                self.blueNoiseReady = true
                self.skyRefreshed = nil           // the sky's bake reads the tile whatever the setting
            }
        }
    }

    /// 1-texel stand-ins for optional textures, so every texture a kernel declares is bound.
    package func createDummyTextures() throws {
        let d3 = MTLTextureDescriptor()
        d3.textureType = .type3D
        d3.pixelFormat = .rgba16Float
        d3.width = 1; d3.height = 1; d3.depth = 1
        d3.usage = .shaderRead
        d3.storageMode = .private
        let d2 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        d2.usage = .shaderRead
        d2.storageMode = .private
        let da = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        da.textureType = .type2DArray
        da.arrayLength = 2
        da.usage = .shaderRead
        da.storageMode = .private
        guard let t3 = device.makeTexture(descriptor: d3), let t2 = device.makeTexture(descriptor: d2),
              let ta = device.makeTexture(descriptor: da) else {
            throw RendererError.resourceCreation("dummy textures")
        }
        dummy3D = t3
        dummy2D = t2
        dummyArray = ta
    }

    /// The fog's 3D noise (~50 ms to generate). Any thread.
    private static func fogNoiseTexture(_ device: MTLDevice) -> MTLTexture? {
        let n = FogNoise.size
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .r8Unorm
        d.width = n; d.height = n; d.depth = n
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        texture.label = "fogNoise"
        FogNoise.generate().withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: n, bytesPerImage: n * n)
        }
        return texture
    }

    /// The fog's noise, made the first time fog is on: in the background (nil until it is ready, so the fog shows a
    /// few frames late), or right here in a benchmark.
    package func fogNoise() -> MTLTexture? {
        if let fogNoiseTexture { return fogNoiseTexture }
        if benchmark != nil {
            fogNoiseTexture = Renderer.fogNoiseTexture(device)
            return fogNoiseTexture
        }
        if !fogNoisePending {
            fogNoisePending = true
            let device = device
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let texture = Renderer.fogNoiseTexture(device)
                self?.renderThread.perform {
                    self?.fogNoiseTexture = texture
                    self?.fogNoisePending = false
                }
            }
        }
        return nil
    }

    package func fogTargets(width: Int, height: Int) -> FogTargets? {
        if let g = fogGrid, g.renderWidth == width, g.renderHeight == height { return g }
        fogGrid = try? FogTargets(device: device, renderWidth: width, renderHeight: height, slices: FogSettings.slices)
        fogLastFrame = nil
        return fogGrid
    }

    package func taaTargets(width: Int, height: Int) -> TAATargets? {
        if let t = taaTargetsCache, t.width == width, t.height == height { return t }
        taaTargetsCache = nil   // (the old ones go first)
        taaTargetsCache = try? TAATargets(device: device, width: width, height: height)
        taaHistory = false
        return taaTargetsCache
    }

    package func postTargets(width: Int, height: Int) -> PostTargets? {
        if let t = postTargetsCache, t.width == width, t.height == height { return t }
        postTargetsCache = try? PostTargets(device: device, width: width, height: height)
        return postTargetsCache
    }

    package func fogReferenceTexture(width: Int, height: Int) -> MTLTexture? {
        if let t = fogReference, t.width == width, t.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        fogReference = device.makeTexture(descriptor: d)
        fogReference?.label = "fogReference"
        return fogReference
    }

    /// This frame's fog parameters for the shaders (flags 0 while fog is off).
    /// `requireGrid`: none without the froxel grid (the frame's fog); the path tracer reads the medium alone.
    package func makeFogParams(grid: FogTargets?, historyValid: Bool, requireGrid: Bool = true) -> GPUFogParams {
        var p = GPUFogParams()
        let f = settings.fog
        guard f.enabled, grid != nil || !requireGrid else { return p }
        let near: Float = 0.2, far = max(f.maxDistance, 1)
        p.medium = SIMD4(FogSettings.densityRange.clamp(f.density) * (f.density > 0 ? 1 : 0), max(f.heightFalloff, 0),
                         f.baseHeight, FogSettings.anisotropyRange.clamp(f.anisotropy))
        p.albedo = SIMD4(f.albedo, max(f.ambient, 0))
        p.noise = SIMD4(f.noise, max(f.noiseScale, 0.1), animTime, 0.1)
        p.wind = SIMD4(f.wind, FogSettings.hazeRange.clamp(f.haze))
        p.grid = SIMD4(near, far, log(far / near), Float(grid?.slices ?? 0))
        let volumes = f.volumes ? Array(scene.fogVolumes.prefix(GPUFogParams.maxVolumes)) : []
        for (i, v) in volumes.enumerated() { p.setVolume(i, v.gpu) }
        (p.interiorLo, p.interiorHi) = Renderer.interiorBox(scene)
        p.counts = SIMD4(UInt32(grid?.columns ?? 0), UInt32(grid?.rows ?? 0), UInt32(volumes.count),
                         GPUFogParams.enabled | (historyValid ? GPUFogParams.historyValid : 0)
                         | (f.reflections ? GPUFogParams.reflections : 0) | (f.lights ? 0 : GPUFogParams.skyLight))
        return p
    }
}
