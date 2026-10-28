import EngineCore
import Foundation
import Garments
import Metal
import Physics
import QuartzCore
import simd

extension Renderer {
    /// The garment workshop's solver, made with the scene's resources (its particles where the scene put them).
    func makeGarmentSolver() throws {
        guard let stage = scene.garment else { return }
        let b = stage.build
        let solver = try GarmentSolverGPU(device: device, positions: stage.start, invMass: b.invMass, constraints: b.constraints,
                                          colourStarts: b.colourStarts, triangles: b.triangles, vertexBase: stage.vertexBase,
                                          prevOffset: Int(scene.meshes[stage.mesh].prevOffset), slots: Renderer.maxFramesInFlight)
        if let body = stage.body {
            let grid = body.grid
            solver.setBody(device: device, lo: grid.lo, cell: grid.cell, counts: grid.counts, values: grid.values)
        }
        configure(solver, stage)
        // Self-collision: within two thicknesses and a few millimetres.
        let thickness = stage.garment.fabrics.map(\.thickness).max() ?? 0.002
        solver.enableSelfCollision(device: device, rest: b.selfRest, partners: b.seamPartners, distance: max(0.006, thickness * 2 + 0.004))
        garmentGPU = solver
    }

    /// The cloth's parameters from the garment's fabrics (their thickness, friction and damping; the heaviest's).
    func configure(_ solver: GarmentSolverGPU, _ stage: GarmentStage) {
        let fabrics = stage.garment.fabrics.isEmpty ? [Fabric.preset(.cotton)] : stage.garment.fabrics
        let thickness = fabrics.map(\.thickness).max() ?? 0.002
        let friction = fabrics.map(\.friction).reduce(0, +) / Float(fabrics.count)
        let damping = fabrics.map(\.damping).reduce(0, +) / Float(fabrics.count)
        solver.params.collide = SIMD4(thickness, friction, 0.004, 0.6 + damping * 4)
        solver.params.floor = SIMD4(0, 0, 0, 0)
    }

    /// A frame of the garment's cloth: its substeps (while it simulates), then its mesh. True if its vertices were
    /// written (its structure is refitted with the others').
    func encodeGarment(slot: Int, passes: FrameEncoder) -> Bool {
        guard let solver = garmentGPU, let stage = scene.garment, let enc = passes.compute("garment", serial: true) else { return false }
        // A 60th of a second a frame in a benchmark (its stills the same every run); the clock's time otherwise, within
        // a 30th (a slow frame doesn't throw the cloth).
        let now = CACurrentMediaTime()
        let dt: Float = benchmark != nil ? 1 / 60 : Float(max(1 / 240, min(1 / 30, now - (stage.lastFrame ?? now - 1 / 60))))
        stage.lastFrame = now
        let stopAt = scene.settings.garmentWorkshop.stopAt
        let substeps = stage.simulate && (stopAt <= 0 || stage.sewTime < stopAt - 1e-4) ? stage.substeps : 0
        if substeps > 0 {
            stage.sewTime += dt
            solver.params.seams.x = stage.seamCompliance
            solver.params.seams.z = stage.seamBendScale
            solver.params.gravity = SIMD4(0, -9.81 * stage.gravityScale, 0, 0)
        }
        if let grab = stage.grab {
            solver.params.grab = SIMD4(grab.target, 1)
            solver.params.grabInfo.x = UInt32(grab.particle)
        } else {
            solver.params.grab.w = 0
        }
        // A moving avatar: its bones where the crowd's skinning puts them this frame.
        if let rig = stage.rig, let crowd = scene.crowd, !crowd.slots.isEmpty {
            let friction = solver.params.collide.y
            let caps = GarmentMotion.capsules(rig, palette: crowd.palette(slot: 0))
            solver.setSpheres(device: device, caps.map { GPUGarmentSphere(a: SIMD4($0.a, $0.r), b: SIMD4($0.b, friction)) }, slot: slot)
        }
        if stage.recording != nil, substeps > 0 { stage.recording?.append(solver.positions()) }
        solver.encode(enc, pipelines: pipelines, slot: slot, substeps: substeps, dt: dt)
        solver.encodeMesh(enc, pipelines: pipelines, positions: positionBuffer, normals: normalBuffer)
        passes.endCompute()
        return true
    }
}

/// What the garment workshop reports to the designer.
package struct GarmentReport: Equatable {
    package var particles = 0
    package var constraints = 0
    package var colours = 0
    package var buildMs = 0.0
    package var simulating = false
    package var sewTime: Float = 0
    /// The garment's key the scene was made with.
    package var garment = ""
}

extension Renderer {
    /// The workshop's garment as it stands (render thread).
    package var garmentReport: GarmentReport? {
        guard let stage = scene.garment else { return nil }
        return GarmentReport(particles: stage.build.particleCount, constraints: stage.build.constraints.count, colours: stage.build.colourCount,
                             buildMs: stage.buildMs, simulating: stage.simulate, sewTime: stage.sewTime,
                             garment: scene.settings.garmentWorkshop.garment)
    }

    /// The cloth on or still (the designer's Space), without making the scene again.
    package func setGarmentSimulating(_ on: Bool) {
        scene.garment?.simulate = on
        settings.scene.garmentWorkshop.simulate = on
        scene.settings.garmentWorkshop.simulate = on
    }

    /// The build the scene's cloth was made from and where its particles are now (a frame or two behind).
    package func garmentDrape() -> (build: GarmentBuild, positions: [SIMD3<Float>])? {
        guard let stage = scene.garment, let solver = garmentGPU else { return nil }
        return (stage.build, solver.positions())
    }

    /// The particle nearest the ray from `origin` along `direction` (within 4 cm of it), the nearest along it first.
    package func garmentPick(origin: SIMD3<Float>, direction: SIMD3<Float>) -> Int? {
        guard let solver = garmentGPU else { return nil }
        let p = solver.positions()
        var best: (i: Int, t: Float)?
        for (i, q) in p.enumerated() {
            let t = simd_dot(q - origin, direction)
            guard t > 0 else { continue }
            let d = simd_distance(origin + direction * t, q)
            if d < 0.04, best == nil || t < best!.t - 0.02 || (abs(t - best!.t) <= 0.02 && d < 0.02) { best = (i, t) }
        }
        return best?.i
    }

    /// Holds particle `i`, pulled toward `target` (nil lets go). The cloth simulates while it is held.
    package func garmentGrab(_ i: Int?, target: SIMD3<Float>) {
        guard let stage = scene.garment else { return }
        if let i { stage.grab = (i, target); stage.simulate = true } else { stage.grab = nil }
    }

    /// Starts recording the drape a frame at a time (nil stops it); `take` hands the frames over and stops.
    package func garmentRecord(_ on: Bool) { scene.garment?.recording = on ? [] : nil }
    package func garmentTakeRecording() -> (frames: [[SIMD3<Float>]], triangles: [UInt32])? {
        guard let stage = scene.garment, let frames = stage.recording else { return nil }
        stage.recording = nil
        return (frames, stage.build.triangles)
    }

    /// The panels `frozen` (ids) held where they are, the rest free.
    package func garmentFreeze(_ frozen: Set<Int>) {
        guard let stage = scene.garment, let solver = garmentGPU else { return }
        var mass = stage.build.invMass
        let b = stage.build
        for (pi, id) in b.panelIDs.enumerated() where frozen.contains(id) {
            for i in b.panelFirst[pi]..<(b.panelFirst[pi] + b.panelCount[pi]) { mass[i] = 0 }
        }
        solver.loadMasses(mass)
    }

    /// The ray through the point (`x`, `y`: 0...1 from the top left) of the frame, from the camera.
    package func cameraRay(x: Float, y: Float, aspect: Float) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let c = camera
        let t = tan(c.fovY / 2)
        let d = c.forward + c.right * ((x * 2 - 1) * t * aspect) + c.up * ((1 - y * 2) * t)
        return (c.position, simd_normalize(d))
    }
}

extension Renderer {
    /// Where the ray from `origin` along `direction` first meets the avatar's body (marched through its distance), if it does.
    package func garmentBodyHit(origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float>? {
        guard let body = scene.garment?.body else { return nil }
        let box = body.bounds
        // Into the field's box first.
        var tNear: Float = 0, tFar: Float = 100
        for k in 0..<3 where abs(direction[k]) > 1e-6 {
            let a = (box.lo[k] - origin[k]) / direction[k], b = (box.hi[k] - origin[k]) / direction[k]
            tNear = max(tNear, min(a, b)); tFar = min(tFar, max(a, b))
        }
        guard tNear < tFar else { return nil }
        var t = tNear
        while t < tFar {
            let p = origin + direction * t
            let d = body.distance(p)
            if d < 0.002 { return p }
            t += max(0.002, d * 0.8)
        }
        return nil
    }
}
