import AppKit
import MetalKit
import QuartzCore
import simd

extension Renderer {
    // MARK: - Per-frame CPU work

    func writeFrameData(slot: Int, lod: VGView) {
        // Instances: a slot's first frame of a scene writes every record, straight into its buffers; after that only
        // the ones that move, the rest being as they were (a crowd is tens of thousands of records).
        // (A still scene's were written with its buffers.)
        let first = !frameDataWritten[slot], still = sceneBuffers.still
        // The GPU's bodies where they were when this slot's last frame was done: the CPU's copy (the frame's own
        // records are the pose kernel's); and the body the mouse holds, for this frame's steps.
        if let physicsGPU {
            if physicsGPU.simulates {
                scene.placeBodies(poses: physicsGPU.snapshot(slot: slot))
                if scene.physics != nil { physicsGPU.setGrab(slot: slot, scene.physicsGrab) }
            } else if let drawn = scene.drawnPhysics {
                physicsGPU.upload(slot: slot, drawn)
            }
        }
        if !still { sceneBuffers.writeInstanceDescriptors(slot: slot, scene: scene, api: builtAPI, all: first) }
        // Deforming meshes (the crowd's, cloths, soft bodies, hair) change their structures' bounds: the top level's too.
        // (What moves only now and then, doors and lifts: only once each slot has caught up with its last move.)
        if scene.motionThisFrame { lastMotionFrame = Int(frameIndex) }
        let moved = !scene.movingInstances.isEmpty && slotRefitFrame[slot] <= lastMotionFrame
        instanceASStale[slot] = first || moved || virtualTracing != nil || scene.hasDeformingMeshes
        writeInstanceEdits(slot: slot, still: still)   // (after: it may make the slot's structure stale)
        // Virtual geometry's instances name their cuts' structures: a new one means a new top-level structure, not a refit.
        if let virtualTracing, virtualTracing.writeDescriptors(slot: slot, into: instanceDescBuffers[slot], stride: instanceDescriptorStride,
                                                               first: sceneBuffers.instanceCount, scene: scene) {
            instanceASBuilt.remove(slot)
        }
        // The plants and the ground cover in the wind, and the plants' variants for the season: every frame it blows.
        if let plants = sceneBuffers.plants, !still {
            var wind = windFrame
            // Limbs move near the camera only: it is placed on a grid, so that the plants' choices (and the top-level
            // structure's build they take) change only as it crosses a cell.
            if settings.foliage.swayReach > 0 {
                wind.sway = SIMD4((lod.camPos / Renderer.swayStep).rounded(.down) * Renderer.swayStep, settings.foliage.swayReach)
            }
            let state = wind.plantKey
            // Far plants as voxels: their levels follow the view the virtual geometry is cut for (Freeze LOD holds it).
            let voxels = plants.voxels != nil && settings.foliage.lod > 0
            if first || voxels || plantsWritten[slot] != state {
                let view = voxels ? SIMD4(lod.camPos, settings.foliage.lod / max(lod.pixelScale, 1e-6)) : nil
                if plants.writeDescriptors(slot: slot, into: instanceDescBuffers[slot], stride: instanceDescriptorStride, scene: scene,
                                           wind: wind, view: view) {
                    instanceASBuilt.remove(slot)   // other variants or levels: a build
                }
                instanceASStale[slot] = true
                plantsWritten[slot] = state
            }
        }
        readPick(slot: slot)
        updateProcedural(slot: slot)
        writeTraceScene(slot: slot)
        crowdSkinner?.write(slot: slot)
        if !scene.instances.isEmpty, !still {
            scene.writeInstanceData(into: instanceDataBuffers[slot].contents().bindMemory(to: GPUInstanceData.self, capacity: scene.instances.count),
                                    all: first)
        }
        // Lights: after a scene's first frame only what moves or flickers is rewritten in the stage.
        let all = !stageComplete
        stageComplete = true
        frameDataWritten[slot] = true
        // Animated light proxies (flicker, chases, the sun's colour) change their materials: each slot catches up with
        // the ranges changed since it was last written.
        if let dirty = scene.takeMaterialsDirty() {
            for s in materialsPending.indices {
                materialsPending[s] = materialsPending[s].map { min($0.lowerBound, dirty.lowerBound)..<max($0.upperBound, dirty.upperBound) } ?? dirty
            }
        }
        if let range = materialsPending[slot] {
            let stride = MemoryLayout<GPUMaterial>.stride
            scene.materials.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                materialBuffers[slot].contents().advanced(by: range.lowerBound * stride)
                    .copyMemory(from: base.advanced(by: range.lowerBound * stride), byteCount: range.count * stride)
            }
            materialsPending[slot] = nil
        }
        // The open world's lights as they come on: how bright the light table says their triangles are.
        if let dirty = scene.takeLightTrianglesDirty() {
            for s in lightTrianglesPending.indices {
                lightTrianglesPending[s] = lightTrianglesPending[s].map { min($0.lowerBound, dirty.lowerBound)..<max($0.upperBound, dirty.upperBound) } ?? dirty
            }
        }
        if let range = lightTrianglesPending[slot] {
            let table = scene.lightTable, stride = MemoryLayout<GPUTriangleInfo>.stride
            let offset = scene.lights.count * MemoryLayout<GPULight>.stride + table.entries.count * MemoryLayout<GPULightTableEntry>.stride
            table.triangles.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                lightBuffers[slot].contents().advanced(by: offset + range.lowerBound * stride)
                    .copyMemory(from: base.advanced(by: range.lowerBound * stride), byteCount: range.count * stride)
            }
            lightTrianglesPending[slot] = nil
        }
        var sky = false
        lightStage.withUnsafeMutableBufferPointer { lights in
            scene.writeLights(into: lights, all: all)
            sky = updateSky(lights: lights)   // may recolour the first sun (rewritten every frame)
            if let base = lights.baseAddress {
                lightBuffers[slot].contents().copyMemory(from: base, byteCount: lights.count * MemoryLayout<GPULight>.stride)
            }
        }
        skyActive = sky
        writeSkyArguments(slot: slot)
    }

    func updateCamera(dt: Float) {
        turnByArrows(dt)
        if flight != nil { fly(); return }
        if updateDemolition(dt) { return }
        if walker != nil {
            walk(dt)
            return
        }
        followLocked()
        // (A benchmark's walking camera: a body for the doors and the furniture.)
        let body = benchmark?.current.body == true ? camera.position - SIMD3(0, Walker.eyeStanding, 0) : nil
        scene.interiorControls?.advance(dt, walker: body)
        if let body {
            if let last = benchmarkBody, dt > 0 {
                scene.interiorControls?.push(scene.physics, feet: body, velocity: (body - last) / dt, height: Walker.standing)
            }
            benchmarkBody = body
        }
        var move = SIMD3<Float>(repeating: 0)
        let forward = camera.forward, right = camera.right
        if heldKeys.contains("w") { move += forward }
        if heldKeys.contains("s") { move -= forward }
        if heldKeys.contains("d") { move += right }
        if heldKeys.contains("a") { move -= right }
        if heldKeys.contains("e") { move.y += 1 }
        if heldKeys.contains("q") { move.y -= 1 }
        // Flythrough: only while the right button is held, as in Unity's scene view.
        if length(move) > 0, lookHeld {
            let speed = settings.moveSpeed * (shiftHeld ? 3.2 : 1)
            camera.position += normalize(move) * speed * dt
            orbit?.target += normalize(move) * speed * dt   // it moves what it turns about with it
            pivotLock = nil
        }
    }

    /// The arrow keys held: the camera looks around as a right drag would (Option: orbits the pivot; Shift: faster);
    /// walking, the head turns.
    private func turnByArrows(_ dt: Float) {
        let keys = Self.arrowKeys
        var d = SIMD2<Float>.zero
        if heldKeys.contains(keys[0]) { d.y -= 1 }
        if heldKeys.contains(keys[1]) { d.y += 1 }
        if heldKeys.contains(keys[2]) { d.x -= 1 }
        if heldKeys.contains(keys[3]) { d.x += 1 }
        guard d != .zero else { return }
        let step = d * Self.arrowTurnSpeed * dt * (shiftHeld ? 2.5 : 1)
        if walker != nil { walkLook(dx: step.x, dy: step.y); return }
        navigate(optionHeld ? .orbit : .look, dx: step.x, dy: step.y, at: navCursor ?? SIMD2(0.5, 0.5))
    }
}
