import Characters
import EngineCore
import Foundation
import ImageIO
import Physics
import Plants
import simd

extension Scene {
    // MARK: - Animation

    /// Poses everything at time `t`; suns and the sky colour follow `dayTime` instead (Time of day offsets it).
    package func update(time t: Float, dayTime: Float? = nil) {
        let day = dayTime ?? t
        var changed = false
        // Through the array's buffer: `instances[i].animation` copied the whole instance (~290 bytes) out of the
        // class's array, past an exclusivity check, each time. (The animations are functions of `t` only.)
        func move<C: Sequence>(_ indices: C) where C.Element == Int {
            instances.withUnsafeMutableBufferPointer { inst in
                for i in indices {
                    inst[i].prevTransform = inst[i].transform
                    guard let animation = inst[i].animation else { continue }
                    let now = animation(t)
                    if now != inst[i].transform {
                        changed = true
                        inst[i].transform = now
                        inst[i].normalMatrix = now.inverse.transpose
                    }
                }
            }
        }
        defer {
            // (The loose furniture of an interior: only while some of it is awake.)
            let bodies = physics.map { p in settings.kind.simulates || p.bodies.contains { physicsBodyMoves(position: $0.position, info: $0.info) } || !p.particles.isEmpty
                || !p.cloths.isEmpty || !p.softVertices.isEmpty || !p.hairGroups.isEmpty } ?? false
            motionThisFrame = changed || crowd != nil || bodies || !deforming.isEmpty || animated == nil
        }
        // A light's pose; `placed`: its position and direction too (otherwise only its scale is taken).
        func pose(_ l: Int, placed: Bool) {
            let old = lights[l].current.scale
            let pose = lights[l].pose(lights[l].kind.isSun ? day : t)
            if placed {
                lights[l].current = pose
                let s = lights[l].proxyInstance
                if s >= 0 { setTransform(s, proxyTransform(lights[l].kind, pose)) }
            } else {
                lights[l].current.scale = pose.scale
            }
            let material = lights[l].proxyMaterial
            if material >= 0 && pose.scale != old {
                materials[material].emission = SIMD4(lights[l].proxyEmission * pose.scale, 1)
                materialsDirty = materialsDirty.map { min($0.lowerBound, material)..<max($0.upperBound, material + 1) }
                    ?? material..<material + 1
            }
        }
        if let animated {
            move(animated.instances)
            for l in animated.lights { pose(l, placed: true) }
            for l in animated.scaledLights { pose(l, placed: false) }
        } else {
            move(instances.indices)
            for l in lights.indices where !lights[l].isMesh { pose(l, placed: true) }
        }
        if let skyAnimation { skyColor = skyAnimation(day) }
        if worldPlace != nil {
            let now = Heavens(at: day)
            heavens = now
            setCityLights(sunElevation: now.sunElevation)
        }
        for i in fogVolumes.indices { if let motion = fogVolumes[i].motion { fogVolumes[i].center = motion(t) } }
        if let physics {
            if physicsOnGPU {
                let claim = physics.claim(to: t)
                physicsPending = claim.restart ? claim : (physicsPending.steps + claim.steps, physicsPending.restart)
            } else if physicsFromInstall {
                if physicsOrigin.map({ t < $0 }) ?? true { physicsOrigin = t }
                physics.advance(to: t - (physicsOrigin ?? t), atMost: 8)
                placeBodies()
            } else if physicsAsync {
                let stepper = physicsStepper ?? PhysicsStepper(world: physics)
                physicsStepper = stepper
                stepper.request(to: t)
                if physicsTime == t { stepper.waitIdle() }   // (paused, or a still: the frame shows where they are)
                physicsTime = t
                let drawn = stepper.latest
                placeBodies(drawn)
                behaviour?.drawn(self, bodies: drawn.bodies, state: drawn.demolition, step: drawn.stepIndex)
            } else {
                physics.advance(to: t)
                placeBodies()
                behaviour?.drawn(self, bodies: physics.bodies, state: physics.demolition, step: physics.stepIndex)
            }
        }
        if let particles {
            let claim = particles.claim(to: t)
            particlesPending = claim.restart ? (claim.steps, true) : (particlesPending.steps + claim.steps, particlesPending.restart)
        }
        if let crowd {
            // The slots' poses at this time, then the walkers along their lanes: only a transform's translation
            // changes (and with it the inverse's), so this stays cheap for tens of thousands of them.
            // Each walker is its own instance, so parts of them go side by side, through the buffers.
            crowd.viewer = viewer
            crowd.pose(at: t)
            let slots = crowd.slots
            crowd.walkers.withUnsafeBufferPointer { walkers in
                instances.withUnsafeMutableBufferPointer { inst in
                    let inst = inst, part = 8192
                    DispatchQueue.concurrentPerform(iterations: (walkers.count + part - 1) / part) { k in
                        for w in walkers[(k * part)..<min((k + 1) * part, walkers.count)] {
                            let (p, previous) = w.positions(slots[w.slot])
                            inst[w.instance].transform.columns.3 = SIMD4(p, 1)
                            inst[w.instance].prevTransform.columns.3 = SIMD4(previous, 1)
                            inst[w.instance].normalMatrix.columns.0.w = -dot(w.inverse0, p)
                            inst[w.instance].normalMatrix.columns.1.w = -dot(w.inverse1, p)
                            inst[w.instance].normalMatrix.columns.2.w = -dot(w.inverse2, p)
                        }
                    }
                }
            }
        }
    }

    /// The rigid bodies' and particles' instances where the physics has them.
    package func placeBodies() {
        guard let physics else { return }
        // (PhysicsWorld.transform and drawnScale, through the physics' inlinable functions: they're another module's.)
        let fractured = physics.fractures
        for b in physics.bodies.indices {
            let body = physics.bodies[b], shape = physics.shapes[Int(body.info.x)]
            let scale: Float = !fractured ? 1 : body.info.y & physicsDisabledBit != 0 ? 0
                : b < physics.fractureState.count ? physics.fractureState[b].direction.w : 1
            setTransform(Int(body.info.z), physicsBodyTransform(position: dropW(body.position), rotation: body.rotation,
                                                                comPosition: shape.comPosition, comRotation: shape.comRotation, scale: scale))
        }
        for p in physics.particles.indices where physics.particles[p].info.x != physicsNone {   // (a cloth's vertex has none)
            setTransform(Int(physics.particles[p].info.x), translate(dropW(physics.particles[p].position)))
        }
    }

    /// ...where the stepper's latest steps left them (PhysicsStepper.Drawn).
    package func placeBodies(_ drawn: PhysicsStepper.Drawn) {
        guard let physics else { return }
        let fractured = physics.fractures
        for b in drawn.bodies.indices {
            let body = drawn.bodies[b]
            // (PhysicsWorld.drawnScale, from the drawn state.)
            let scale: Float = !fractured ? 1 : body.info.y & physicsDisabledBit != 0 ? 0
                : b < drawn.fractureState.count ? drawn.fractureState[b].direction.w : 1
            let shape = physics.shapes[Int(body.info.x)]
            setTransform(Int(body.info.z), physicsBodyTransform(position: dropW(body.position), rotation: body.rotation,
                                                                comPosition: shape.comPosition, comRotation: shape.comRotation, scale: scale))
        }
        for p in drawn.particles.indices where drawn.particles[p].info.x != physicsNone {
            setTransform(Int(drawn.particles[p].info.x), translate(dropW(drawn.particles[p].position)))
        }
    }

    /// The body the mouse holds: the stepper's copy (sent with each frame's steps) when it steps the world, the
    /// world's own otherwise.
    package var physicsGrab: GPUPhysicsGrab {
        get { physicsStepper?.grab ?? physics?.grab ?? GPUPhysicsGrab() }
        set {
            if let physicsStepper { physicsStepper.grab = newValue } else { physics?.grab = newValue }
        }
    }

    /// Command `c` for the world's next steps (its start step PhysicsWorld.none: where they begin), without waiting
    /// for the steps a stepper is running (PhysicsStepper.command).
    package func physicsCommand(_ c: GPUFractureCommand) {
        if let physicsStepper { physicsStepper.command(c) } else { physics?.add(c) }
    }

    /// `body` with the world, once the steps asked for are done when a stepper runs them (a pick, a command: they
    /// then land on the step they would have without it); nil without a world.
    package func withPhysics<R>(_ body: (PhysicsWorld) throws -> R) rethrows -> R? {
        guard let physics else { return nil }
        if let physicsStepper { return try physicsStepper.sync(body) }
        return try body(physics)
    }

    /// Where the CPU's steps broke pieces (PhysicsWorld.breakLog, breakSteps, breakTotal), for the dust: the stepper's
    /// latest, or the world's.
    package var physicsBreaks: (log: [GPUBreakEvent], steps: [Int], total: Int)? {
        if let physicsStepper {
            let drawn = physicsStepper.latest
            return (drawn.breakLog, drawn.breakSteps, drawn.breakTotal)
        }
        return physics.map { ($0.breakLog, $0.breakSteps, $0.breakTotal) }
    }

    /// What the GPU draws the CPU's cloths, soft bodies and hair from: the stepper's latest, or the world's.
    package var drawnPhysics: PhysicsStepper.Drawn? {
        if let physicsStepper { return physicsStepper.latest }
        return physics.map { PhysicsStepper.Drawn($0) }
    }

    /// ...where the GPU had them (`poses`: position, rotation per body): the CPU's copy, for what reads it here
    /// (bounds, moving lights). The frame's records are the GPU's own (PhysicsGPU.encodePose).
    package func placeBodies(poses: UnsafeBufferPointer<SIMD4<Float>>) {
        guard let physics else { return }
        // What picking sees: over the last frame's copy (made anew only when the count changes).
        if physics.drawnPoses.count == poses.count {
            physics.drawnPoses.withUnsafeMutableBufferPointer { _ = $0.update(fromContentsOf: poses) }
        } else {
            physics.drawnPoses = Array(poses)
        }
        // Through the instances' buffer (as setTransform does, without its exclusivity check per body).
        let count = physics.bodies.count
        instances.withUnsafeMutableBufferPointer { inst in
            for b in 0..<count {
                let i = Int(physics.bodies[b].info.z), shape = physics.shapes[Int(physics.bodies[b].info.x)]
                // (w: how far it is hidden, 1 for a disabled body: PhysicsGPU's pose kernel.)
                let m = physicsBodyTransform(position: dropW(poses[2 * b]), rotation: poses[2 * b + 1], comPosition: shape.comPosition,
                                             comRotation: shape.comRotation, scale: 1 - poses[2 * b].w)
                inst[i].prevTransform = inst[i].transform
                inst[i].transform = m
                inst[i].normalMatrix = m.inverse.transpose
            }
        }
    }

    /// The renderer runs the physics on the GPU from now on, from the start up to where it is.
    package func runPhysicsOnGPU() {
        guard let physics else { return }
        physicsOnGPU = true
        physicsPending = (physics.stepIndex, true)
    }

    /// The particles' steps to encode this frame, `limit` at most (the rest wait for the next frames), and whether
    /// from the start (a new scene, or time run back).
    package func takeParticleSteps(limit: Int = .max) -> (steps: Int, restart: Bool) {
        let taken = (steps: min(particlesPending.steps, limit), restart: particlesPending.restart)
        particlesPending = (particlesPending.steps - taken.steps, false)
        return taken
    }

    /// The renderer made the particles' buffers anew: it replays them from the start up to where they are.
    package func replayParticles() {
        guard let particles else { return }
        particlesPending = (particles.stepIndex, true)
    }

    /// The scene's particle effects (a builder's, once): see `particles`.
    /// A mesh emitter's particles are instances, one a slot, reserved here (the GPU poses them: ParticlesGPU
    /// .encodeMeshPose); they move every frame, so the scene isn't still.
    package func addParticles(_ system: ParticleSystem) {
        precondition(particles == nil, "a scene has one particle system")
        let p = ParticleSystem(emitters: settings.particles.applied(to: system.emitters), colliders: system.colliders,
                               fields: Array(system.fields.prefix(system.bakedCurlField ?? system.fields.count)),
                               programs: system.programs)
        for (i, e) in p.emitters.enumerated() {
            guard let (mesh, material) = e.mesh else { continue }
            let hidden = translate(e.position) * scale(1e-4)
            p.meshInstances[i] = instances.count
            for _ in 0..<e.capacity { instances[addInstance(mesh, material, hidden)].simulated = true }
        }
        particles = p
    }

    /// The VFX editor's edit, run in place of the scene's particles (VFXLive.swift): `system` (made `continuing` the
    /// one it replaces) from `effects`, as `key` names them (SceneSettings.effects), so the scene isn't made again.
    /// Without `system` only the key: the edit's code compiles meanwhile.
    /// The Material Designer's edit, baked in place (Renderer.editMaterials): its graphs' catalog's key.
    package func adoptMaterials(_ key: String) { settings.materials = key }

    package func adoptEffects(_ key: String, system: ParticleSystem?, effects: [VFXInstance], owners: [String], notes: [String]) {
        settings.effects = key
        guard let system else { return }   // the running ones until their new code is ready (Renderer.editEffects)
        particles = system
        self.effects = effects
        effectOwners = owners
        effectNotes = notes
    }

    /// The steps to encode this frame (the renderer's), `limit` at most: the rest wait for the next frames.
    package func takePhysicsSteps(limit: Int = .max) -> (steps: Int, restart: Bool) {
        let taken = (steps: min(physicsPending.steps, limit), restart: physicsPending.restart)
        physicsPending = (physicsPending.steps - taken.steps, false)
        return taken
    }

    @inline(__always) package func setTransform(_ i: Int, _ transform: float4x4) {
        instances[i].transform = transform
        instances[i].normalMatrix = transform.inverse.transpose
    }

    /// Instances put elsewhere for good (a terrain's scatter and what stands on it, after a brush moved the ground: no
    /// motion between frames). `record`: the renderer writes their records again (takeInstanceEdits).
    package func moveInstances(_ moves: [(Int, float4x4)], record: Bool) {
        for (i, m) in moves where instances.indices.contains(i) {
            setTransform(i, m)
            instances[i].prevTransform = m
            if record { instanceEdits.insert(i) }
        }
    }

    /// The instances moved for good since the last call (moveInstances), which are then forgotten.
    package func takeInstanceEdits() -> Set<Int> {
        defer { instanceEdits = [] }
        return instanceEdits
    }


    /// The instances whose transform changes from frame to frame.
    package var movingInstances: [Int] { animated?.instances ?? Array(instances.indices) }

    /// The range of materials changed since the last call (nil: none), which is then forgotten.
    /// Material `i` changed (a procedural one's bake): the renderer copies it to every slot.
    package func markMaterialDirty(_ i: Int) {
        materialsDirty = materialsDirty.map { min($0.lowerBound, i)..<max($0.upperBound, i + 1) } ?? i..<(i + 1)
    }

    /// Material `i` replaced (a procedural one's values as its graph's bake gives them).
    package func setMaterial(_ i: Int, _ m: GPUMaterial) {
        guard materials.indices.contains(i) else { return }
        materials[i] = m
        markMaterialDirty(i)
    }

    package func takeMaterialsDirty() -> Range<Int>? {
        defer { materialsDirty = nil }
        return materialsDirty
    }

    /// Unit direction perpendicular to `n`: horizontal if possible.
    package static func perpendicular(_ n: SIMD3<Float>) -> SIMD3<Float> {
        let h = cross(SIMD3<Float>(0, 1, 0), n)
        return length(h) > 1e-4 ? normalize(h) : normalize(cross(SIMD3<Float>(1, 0, 0), n))
    }

    /// Rotation taking +Y to `d` (unit).
    package static func alignY(_ d: SIMD3<Float>) -> float4x4 {
        if dot(d, [0, 1, 0]) < -0.9999 { return rotate(.pi, [1, 0, 0]) }
        return float4x4(simd_quatf(from: [0, 1, 0], to: d))
    }

    /// Rect lights: width axis (unit), normal, height axis.
    package static func rectFrame(_ pose: LightPose) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let n = normalize(pose.direction)
        var t = pose.tangent.map { normalize($0 - n * dot($0, n)) } ?? perpendicular(n)
        if !t.x.isFinite { t = perpendicular(n) }
        return (t, n, cross(t, n))
    }

    private func proxyTransform(_ kind: LightKind, _ pose: LightPose) -> float4x4 {
        switch kind {
        case .sphere(let r), .spot(let r, _, _):
            return translate(pose.position) * scale(r)
        case .rect(let w, let h):
            let (t, n, b) = Scene.rectFrame(pose)   // the unit quad lies in XZ, facing +Y
            return float4x4(SIMD4(t * w, 0), SIMD4(n, 0), SIMD4(b * h, 0), SIMD4(pose.position, 1))
        case .tube:
            return translate(pose.position) * Scene.alignY(normalize(pose.direction))
        case .sun, .mesh:
            return matrix_identity_float4x4
        }
    }

    /// An instance's bounds in its own space: its mesh's, virtual mesh's or assembly's.
    package func localBounds(of inst: Instance) -> (SIMD3<Float>, SIMD3<Float>) {
        inst.virtualMesh >= 0 ? (virtualMeshes[inst.virtualMesh].bounds.lo, virtualMeshes[inst.virtualMesh].bounds.hi)
            : inst.assembly >= 0 ? (assemblies[inst.assembly].bounds.lo, assemblies[inst.assembly].bounds.hi)
            : inst.sdf >= 0 ? (sdfBounds[inst.sdf].lo, sdfBounds[inst.sdf].hi) : meshBounds[inst.mesh]
    }

    /// Axis-aligned bounds of all geometry at the current animation time (the scene sphere),
    /// from each instance's transformed mesh bounds.
    package func bounds() -> (SIMD3<Float>, SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for inst in instances where inst.isGeometry {
            let (a, b) = localBounds(of: inst)
            for corner in 0..<8 {
                let c = SIMD3<Float>(corner & 1 == 0 ? a.x : b.x, corner & 2 == 0 ? a.y : b.y, corner & 4 == 0 ? a.z : b.z)
                let p = inst.transform * SIMD4<Float>(c, 1)
                lo = simd_min(lo, SIMD3(p.x, p.y, p.z))
                hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
            }
        }
        return (lo, hi)
    }
}
