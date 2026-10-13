import Foundation
import simd

/// The VFX stage: effects lined up (`SceneSettings.stage.effects`, by name: VFXLibrary's built-in ones, or the effects
/// catalog's), 4 m apart, each at its own height over a floor they bounce off ("floor") and in which they show, against
/// a backdrop (`stage.backdrop`):
/// - dark: a dark room, a key light from the front and above, a cool light over them;
/// - grey: a grey cyclorama (the floor curving up into a wall), a key light and a fill;
/// - black: a black floor and nothing else, one dim light over them;
/// - outdoor: a plain under the sun and a blue sky;
/// - night: the plain under the moon.
/// Where the VFX editor shows what it edits; its camera turns about the effects (`focus`, SceneKind.orbits).
extension Scene {
    func buildVFXStage() {
        let kit = Kit(self)
        let backdrop = settings.stage.backdrop
        buildBackdrop(backdrop, kit)
        let rock = addMesh(Scene.rock(seed: 7))
        let stone = addPBRMaterial(baseColor: [0.5, 0.48, 0.45], metallic: 0, roughness: 0.7)
        addParticleCollider("floor", .plane(normal: [0, 1, 0], point: [0, 0.001, 0]))
        let names = settings.stage.effects
        var bounds = AABB()
        for (i, name) in names.enumerated() {
            guard let fx = stageEffect(name) else {
                effectNotes.append("the stage has no effect \"\(name)\"")
                continue
            }
            let x = (Float(i) - Float(names.count - 1) / 2) * 4
            let place = VFXPlacement(offset: [x - fx.origin.x, 0, -fx.origin.z])
            addEffect(fx, at: place, meshes: ["rock": (rock, stone)])
            let b = Scene.previewBounds(fx)
            bounds.grow(place.point(b.lo))
            bounds.grow(place.point(b.hi))
        }
        let missing = effectNotes
        addEffects()
        effectNotes = missing + effectNotes
        if bounds.isEmpty { bounds = AABB(lo: [-1, 0, -1], hi: [1, 2, 1]) }
        bounds.grow(SIMD3(bounds.lo.x, 0, bounds.lo.z))   // down to the floor
        focus = bounds
        defaultCamera = Scene.demoCamera(.vfxStage)!
    }

    private func buildBackdrop(_ backdrop: VFXBackdrop, _ kit: Kit) {
        switch backdrop {
        case .dark:
            skyColor = [0.01, 0.012, 0.018]
            let floor = addPBRMaterial(baseColor: [0.07, 0.07, 0.08], metallic: 0, roughness: 0.22)
            let wall = addMaterial(albedo: [0.3, 0.3, 0.32])
            kit.room(width: 28, height: 12, depth: 18, floor: floor, walls: wall, ceiling: false)
            addLight(.rect(width: 4, height: 2), color: SIMD3<Float>(1, 0.95, 0.9) * 8, motion: .constant) { _ in
                LightPose(position: [0, 8, 5], direction: normalize(SIMD3<Float>(0, -1, -0.5)), tangent: [1, 0, 0])
            }
            addLight(.rect(width: 6, height: 1.5), color: SIMD3<Float>(0.6, 0.75, 1) * 5, motion: .constant) { _ in
                LightPose(position: [0, 10.5, 0], direction: [0, -1, 0], tangent: [1, 0, 0])   // over them: out of the camera's view
            }
        case .grey:
            skyColor = [0.12, 0.12, 0.13]
            let grey = addPBRMaterial(baseColor: [0.42, 0.42, 0.43], metallic: 0, roughness: 0.6)
            cyclorama(kit, grey)
            addLight(.rect(width: 5, height: 3), color: SIMD3<Float>(1, 0.97, 0.92) * 7, motion: .constant) { _ in
                LightPose(position: [-4, 7, 6], direction: normalize(SIMD3<Float>(0.4, -0.8, -0.6)), tangent: [1, 0, 0])
            }
            addLight(.rect(width: 4, height: 2), color: SIMD3<Float>(0.8, 0.88, 1) * 3, motion: .constant) { _ in
                LightPose(position: [13, 9, 0], direction: normalize(SIMD3<Float>(-0.75, -0.5, -0.4)), tangent: [0, 0, 1])   // out of view
            }
        case .black:
            skyColor = .zero
            let floor = addPBRMaterial(baseColor: [0.01, 0.01, 0.012], metallic: 0, roughness: 0.3)
            addInstance(kit.quad, floor, scale([60, 1, 60]))
            addLight(.rect(width: 6, height: 2), color: SIMD3<Float>(1, 1, 1) * 3, motion: .constant) { _ in
                LightPose(position: [0, 10, 2], direction: [0, -1, 0], tangent: [1, 0, 0])
            }
        case .outdoor, .night:
            let night = backdrop == .night
            let ground = addMaterial(albedo: night ? [0.25, 0.25, 0.27] : [0.42, 0.39, 0.33])
            addInstance(kit.quad, ground, scale([200, 1, 200]))
            skyColor = night ? [0.004, 0.006, 0.016] : SIMD3<Float>(0.3, 0.45, 0.8) * 0.24
            let color: SIMD3<Float> = night ? SIMD3(0.55, 0.65, 1) * 0.2 : SIMD3(1, 0.95, 0.88) * 1.8
            let e = Scene.degrees(night ? 50 : 38), az: Float = night ? -0.5 : 0.6
            addLight(.sun(angularRadius: Scene.degrees(0.27)), color: color, motion: .constant) { _ in
                LightPose(position: .zero, direction: [cos(e) * sin(az), sin(e), cos(e) * cos(az)])
            }
        }
    }

    /// A floor that curves up into a back wall (a quarter circle of `radius` m), 30 m wide: no corner behind the effects.
    func cyclorama(_ kit: Kit, _ material: Int) {
        let w: Float = 30, back: Float = -6, radius: Float = 3, height: Float = 14, steps = 10
        addInstance(kit.quad, material, translate([0, 0, (back + 12) / 2]) * scale([w, 1, 12 - back]))
        for k in 0..<steps {
            let a0 = Float(k) / Float(steps) * .pi / 2, a1 = Float(k + 1) / Float(steps) * .pi / 2
            func at(_ a: Float) -> SIMD3<Float> { [0, radius - radius * cos(a), back - radius * sin(a)] }
            let p0 = at(a0), p1 = at(a1), mid = (a0 + a1) / 2
            addInstance(kit.quad, material, translate((p0 + p1) / 2) * rotate(mid, [1, 0, 0]) * scale([w, 1, simd_length(p1 - p0) * 1.02]))
        }
        addInstance(kit.quad, material, translate([0, radius + (height - radius) / 2, back - radius]) * rotate(.pi / 2, [1, 0, 0])
                    * scale([w, 1, height - radius]))
    }

    /// The effect of that name: the catalog's (a saved file's, the editor's), else the built-in one.
    func stageEffect(_ name: String) -> VFXEffect? {
        VFXCatalog.resolve(settings.effects).effects[name] ?? VFXLibrary.named(name)
    }

    /// Where `effect`'s particles go in its first `seconds` (the CPU's interpreter of its graph, without the scene to
    /// collide with), padded: what the stage's camera frames.
    static func previewBounds(_ effect: VFXEffect, seconds: Float = 4) -> AABB {
        let system = VFXLowering.system([VFXInstance(effect: effect, place: .identity)]).system
        var box = AABB()
        box.grow(effect.origin)
        let cpu = VFXInterpreter(system)
        let steps = Int(seconds / ParticleSystem.stepLength)
        for k in 0..<steps {
            cpu.step()
            guard k % 6 == 5 else { continue }
            for q in cpu.current { box.grow(SIMD3(q.position.x, q.position.y, q.position.z)) }
        }
        // Not past what a scene's camera can frame (a stray particle flung far).
        box.lo = simd_max(box.lo, effect.origin - 8)
        box.hi = simd_min(box.hi, effect.origin + 8)
        box.lo -= 0.3
        box.hi += 0.3
        return box
    }
}
