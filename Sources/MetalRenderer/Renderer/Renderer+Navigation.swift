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
    // MARK: - Walking

    /// Walk mode on or off. On: the walker stands under the camera (in the building workshop, outside, at the
    /// building's door, if the camera isn't in the building).
    package func toggleWalk() {
        if walker != nil {
            walker = nil
            scene.interiorControls?.flashlight.on = false
            walkMessage = "Flying"
            return
        }
        guard let grid = walkGrid else { walkMessage = "Nothing to walk on here"; return }
        var feet = camera.position
        let inside = scene.walkAreas.contains { area in
            let p = area.at.inverse * SIMD4(camera.position, 1)
            return area.rect.contains(SIMD2(p.x, p.z)) && p.y < area.building.height
        }
        if scene.settings.kind == .buildings, !inside, let area = scene.walkAreas.first,
           let door = area.building.plan.outsideDoors(0).first {
            // In front of the door, facing it.
            let room = area.building.plan.storeys[0].rooms[door.a].rect.center
            var out = door.alongX ? SIMD2<Float>(0, door.at.y > room.y ? 1 : -1) : SIMD2<Float>(door.at.x > room.x ? 1 : -1, 0)
            let p = door.at + out * 1.6
            let w = area.at * SIMD4(p.x, 1, p.y, 1)
            feet = SIMD3(w.x, w.y, w.z)
            let o4 = area.at * SIMD4(out.x, 0, out.y, 0)
            out = SIMD2(o4.x, o4.z)
            camera.yaw = atan2(-out.x, out.y)
            camera.pitch = 0
        }
        if let down = grid.raycast(feet + SIMD3(0, 0.5, 0), [0, -1, 0], limit: 300) { feet.y += 0.5 - down }
        else if let ground = scene.walkGround { feet.y = ground(feet.x, feet.z) }
        else { feet.y -= Walker.eyeStanding }
        walker = Walker(feet: feet)
        orbit = nil
        camera.pitch = min(max(camera.pitch, -0.7), 0.7)
        walkMessage = "Walking: W A S D, Shift runs, Space jumps, C crouches, E or a click uses, F the flashlight, V flies"
    }

    /// A walking frame: the walker told what is held, the doors and lifts moved on, the camera at its eyes.
    package func walk(_ dt: Float) {
        guard var w = walker, let grid = walkGrid else { walker = nil; return }
        let controls = scene.interiorControls
        let fw = camera.forward
        let ahead = length(SIMD2(fw.x, fw.z)) > 1e-4 ? normalize(SIMD2(fw.x, fw.z)) : SIMD2<Float>(0, -1)
        let right = SIMD2(-ahead.y, ahead.x)
        var move = SIMD2<Float>.zero
        if heldKeys.contains("w") { move += ahead }
        if heldKeys.contains("s") { move -= ahead }
        if heldKeys.contains("d") { move += right }
        if heldKeys.contains("a") { move -= right }
        if length(move) > 0 { move = normalize(move) }
        let input = Walker.Input(move: move, run: shiftHeld, crouch: crouchHeld || controlHeld, jump: jumpPending)
        jumpPending = false
        controls?.advance(dt, walker: w.feet)
        let lifts = controls?.lifts.map(\.y) ?? []
        var moved = zip(lifts, lastLiftY).map { $0 - $1 }
        lastLiftY = lifts
        controls?.push(scene.physics, feet: w.feet, velocity: w.velocity, height: w.height)
        let obstacles = (controls?.obstacles ?? []) + (controls?.propObstacles(scene.physics) ?? [])
        w.advance(dt, input: input, world: grid, moving: obstacles, carry: { p in
            defer { if p < moved.count { moved[p] = 0 } }
            return p < moved.count ? SIMD3(0, moved[p], 0) : .zero
        }, terrain: scene.walkGround, remainder: &walkRemainder)
        // Fallen out of the world: back where it started.
        if w.feet.y < -50 { w = Walker(feet: camera.position) }
        walker = w
        camera.position = w.eyePosition
        if let c = controls, c.flashlight.on {
            c.flashlight.position = camera.position + camera.right * 0.18 - camera.up * 0.12
            c.flashlight.direction = camera.forward
        }
    }

    /// Uses what is along `ray` from the eyes: a door, a switch, a lift's button.
    package func use(_ ray: SIMD3<Float>) {
        guard let c = scene.interiorControls else { return }
        let blocked = walkGrid?.raycast(camera.position, ray, limit: 3)
        if let what = c.use(from: camera.position, along: ray, blocked: blocked) { walkMessage = what }
    }

    /// The storey the walker is on, of the building it is in (its plan's), if it is in one.
    package var walkerStatus: WalkerStatus? {
        guard let w = walker else { return nil }
        var status = WalkerStatus(position: w.feet, yaw: camera.yaw, building: nil, storey: nil, local: nil, message: walkMessage,
                                  flashlight: scene.interiorControls?.flashlight.on ?? false, crouched: w.crouched)
        for (i, area) in scene.walkAreas.enumerated() {
            let p = area.at.inverse * SIMD4(w.feet, 1)
            guard area.rect.contains(SIMD2(p.x, p.z), margin: 0.5) else { continue }
            status.building = i
            status.local = SIMD3(p.x, p.y, p.z)
            status.storey = area.building.plan.storeys.lastIndex { $0.floor <= p.y + 0.3 } ?? 0
        }
        return status
    }

    // MARK: - The selection, and where the camera flies

    package static let flightSeconds = 0.6, turnSeconds = 0.25

    /// The pivot: the workshops' orbit, or the one navigation set, or 8 m in front.
    package var pivot: ViewPivot {
        get { orbit.map { ViewPivot(target: $0.target, distance: $0.distance) } ?? camera.pivot() }
        set { orbit = (newValue.target, newValue.distance) }
    }

    /// `target` is of the scene that is in.
    package func inScene(_ target: FrameTarget) -> Bool {
        MaterialAssignments.scope(scene.settings) == target.scope || scene.settings.kind == target.kind
    }

    /// Where `target` is now: its instances that are shown (at most `limit` of them), or failing those its box.
    private func bounds(of target: FrameTarget, limit: Int = .max) -> AABB {
        var box = AABB()
        for i in target.instances.prefix(limit) where scene.instances.indices.contains(i) && scene.instances[i].mask != 0 {
            box.grow(scene.worldBounds(of: i))
        }
        if box.isEmpty, let b = target.box { box = b.aabb }
        return box
    }

    /// Selects `target` in the view (nil: nothing); another scene's is ignored. It ends Shift-F's lock.
    package func select(_ target: FrameTarget?) {
        pivotLock = nil
        guard let target, inScene(target) else { selection = nil; return }
        let box = bounds(of: target)
        selection = box.isEmpty || !box.lo.x.isFinite || !box.hi.x.isFinite ? nil : (target, box)
    }

    /// The camera at `target`: now if its scene is in, otherwise once it is. It is selected.
    package func frame(_ target: FrameTarget) {
        guard MaterialAssignments.scope(scene.settings) == target.scope || scene.settings.kind == target.kind && loading == nil else {
            pendingFrame = target
            return
        }
        pendingFrame = nil
        select(target)
        guard let box = selection?.box else { return }
        if walker != nil { toggleWalk() }
        let pitch = min(max(camera.pitch, -0.6), -0.1)
        let framed = Camera.framing(box, fovY: camera.fovY, aspect: viewAspect, yaw: camera.yaw, pitch: pitch)
        session.flight = (camera, framed.camera, framed.target, framed.distance, CACurrentMediaTime(), Renderer.flightSeconds, false)
    }

    /// F: the camera at the selection (nothing selected: the workshop's at what it shows). Shift-F: and it follows the
    /// selection as it moves, until Shift-F again (or a pan, a flight, another selection).
    package func frameSelection(lock: Bool) {
        if lock, pivotLock != nil { pivotLock = nil; return }
        guard let s = selection else { frameWorkshop(); return }
        frame(s.target)
        if lock, let box = selection?.box { pivotLock = box.centroid }
    }

    /// Shift-F's lock: the camera and its pivot moved as the selection's centre moved since the last frame.
    package func followLocked() {
        guard let last = pivotLock, let s = selection else { return }
        let box = bounds(of: s.target, limit: 64)
        guard !box.isEmpty else { return }
        let d = box.centroid - last
        pivotLock = box.centroid
        guard d != .zero else { return }
        camera.position += d
        orbit?.target += d
    }

    /// The scene gizmo: the view from `axis`'s side (its cone clicked), or 45° steps on (dragged), turning about the
    /// pivot.
    package func snapView(_ axis: ViewAxis) { turnView(to: Camera.angles(viewing: axis, yaw: camera.yaw)) }
    package func stepView(yawSteps: Int, pitchSteps: Int) {
        turnView(to: Camera.stepped(yaw: camera.yaw, pitch: camera.pitch, yawSteps: yawSteps, pitchSteps: pitchSteps))
    }
    private func turnView(to angles: (yaw: Float, pitch: Float)) {
        guard walker == nil, painter.active == nil else { return }
        let p = pivot
        var to = camera
        to.yaw = angles.yaw
        to.pitch = angles.pitch
        to.position = p.target - to.forward * p.distance
        session.flight = (camera, to, p.target, p.distance, CACurrentMediaTime(), Renderer.turnSeconds, true)
    }

    /// The flight's next step (the frame's camera), and where it ends: the pivot.
    package func fly() {
        guard let f = session.flight else { return }
        let t = Float(min((CACurrentMediaTime() - f.start) / f.seconds, 1))
        let e = t * t * (3 - 2 * t)
        var c = f.to
        var dyaw = (f.to.yaw - f.from.yaw).truncatingRemainder(dividingBy: 2 * .pi)
        if dyaw > .pi { dyaw -= 2 * .pi } else if dyaw < -.pi { dyaw += 2 * .pi }
        c.yaw = f.from.yaw + dyaw * e
        c.pitch = f.from.pitch + (f.to.pitch - f.from.pitch) * e
        // Turning about the pivot: on its sphere all the way; flying to a thing: straight there.
        c.position = f.about ? f.target - c.forward * f.distance : f.from.position + (f.to.position - f.from.position) * e
        camera = c
        guard t >= 1 else { return }
        session.flight = nil
        camera.yaw = f.from.yaw + dyaw   // (the yaw it was asked for, give or take whole turns)
        orbit = (f.target, f.distance)
    }

    /// The box round the selection, as gizmo lines (a few hundred instances' boxes are measured again each frame, so it
    /// follows them as they move).
    package func selectionSegments() -> [VFXGizmos.Segment] {
        guard var s = selection else { return [] }
        if s.target.instances.count <= 256 {
            let box = bounds(of: s.target)
            if !box.isEmpty { s.box = box; selection = s }
        }
        return VFXGizmos.box(s.box.centroid, (s.box.hi - s.box.lo) / 2, [1, 0.72, 0.25, 1], 2)
    }

    /// The workshop's camera at what it shows, all of it in view, from in front and a little above.
    package func frameWorkshop() {
        guard scene.settings.kind.orbits, let focus = scene.focus else { return }
        let framed = Camera.framing(focus, fovY: settings.fovDegrees * .pi / 180, aspect: viewAspect)
        camera = framed.camera
        prevCamera = camera
        orbit = (framed.target, framed.distance)
    }

    package func placeOrbitingCamera() {
        guard let orbit else { return }
        camera.position = orbit.target - camera.forward * orbit.distance
    }

    /// Auto exposure's scale for this frame (AutoExposure).
    private func meterExposure() -> Float { exposureMeter.next(dt: frameDt, classic: settings.post.classic) }

    package func makeUniforms(width: Int, height: Int, giMode: GIMode, directMode: DirectLightMode) -> Uniforms {
        let aspect = Float(width) / Float(height)
        func pack(_ c: Camera) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
            let tanY = tan(c.fovY / 2)
            return (SIMD4<Float>(c.position, 0),
                    SIMD4<Float>(c.right, tanY * aspect),
                    SIMD4<Float>(c.up, tanY),
                    SIMD4<Float>(c.forward, 0))
        }
        var u = Uniforms()
        (u.camPos, u.camRight, u.camUp, u.camForward) = pack(camera)
        (u.prevCamPos, u.prevCamRight, u.prevCamUp, u.prevCamForward) = pack(prevCamera)
        u.skyColor = SIMD4<Float>(scene.skyColor, 0)
        if let backdrop = scene.backdrop { u.backdrop = SIMD4(backdrop, 1) }
        let lens = settings.post
        u.post = SIMD4<Float>(exp2(RenderSettings.exposureRange.clamp(settings.exposure)), Float(settings.toneMap.rawValue), 0, lens.filmWhiteClip)
        u.film = SIMD4(lens.filmSlope, lens.filmToe, lens.filmShoulder, lens.filmBlackClip)
        if lens.grades {
            u.post.z += Uniforms.gradeOn
            let w = max(min(lens.warmth, 1), -1)
            u.grade = SIMD4(1 + 0.1 * w, 1 - 0.14 * w, max(lens.saturation, 0), max(lens.contrast, 0.2))
        }
        if lens.autoExposure || (upscaler != nil && settings.denoiserMetered) {   // (MetalFX's denoiser has its exposure from the meter too)
            u.post.z += Uniforms.meterOn
            let metered = meterExposure()
            if lens.autoExposure { u.post.x *= metered }
        } else {
            exposureMeter.reset()
        }
        u.width = UInt32(width)
        u.height = UInt32(height)
        u.frameIndex = frameIndex
        u.lightCount = UInt32(scene.lights.count)
        // (Reference "Accumulated passes" in the app: its own path length. A benchmark's: its settings'.)
        let bounces = accumulating && !benchmarkAccumulating ? settings.reference.bounces : settings.bounces
        u.bounces = settings.giEnabled && giMode == .pathTraced ? UInt32(bounces) : 0
        u.flags = (historyValid ? UniformFlags.historyValid : 0) | (denoiserOn ? UniformFlags.denoise : 0)
        if accumulating { u.flags |= UniformFlags.noClamp | UniformFlags.reference }
        if usesSpecular { u.flags |= UniformFlags.specular }
        // Exact: one shadow ray per light (references, up to Renderer.exactReferenceLights). ReSTIR: its own kernels.
        switch directMode {
        case .exact: u.flags |= UniformFlags.allLights
        case .restir: u.flags |= UniformFlags.restir
        default: break
        }
        if settings.lightMaps && giMode == .pathTraced && !accumulating { u.flags |= UniformFlags.lightMaps }
        (u.interiorLo, u.interiorHi) = Renderer.interiorBox(scene)
        u.viewMode = UInt32(settings.viewMode)
        let d = settings.denoiser
        u.denoise = SIMD4<Float>(DenoiserSettings.luminanceSigmaRange.clamp(d.luminanceSigma),
                                 DenoiserSettings.maxHistoryRange.clamp(d.maxHistory),
                                 DenoiserSettings.antiLagRange.clamp(d.antiLag), 0)
        u.instanceCount = UInt32(sceneBuffers.instanceCount)
        u.lightGroupEnd = scene.lightGroupEnd
        let table = scene.lightTable
        u.lightTable = SIMD4(UInt32(table.entries.count), UInt32(table.suns.count),
                             table.suns.first ?? 0, table.suns.count > 1 ? table.suns[1] : 0)
        if skyActive { u.flags |= UniformFlags.skyMap }
        if settings.foliage.wind > 0 && scene.hasFoliage { u.flags |= UniformFlags.wind }
        return u
    }
}
