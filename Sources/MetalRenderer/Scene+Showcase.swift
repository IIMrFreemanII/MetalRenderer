import Foundation
import simd

/// The showcase: one model of Assets/ (`SceneSettings.showcase`) on a set of its own, as its `ShowcaseLook` says. Every
/// set has the same rig: a plinth with a glowing ring, a key beam from above in front (its shaft shows in the fog, the
/// model's shadow cuts one behind it) and lights behind for its outline. The set adds its own lights, fog volumes and
/// what drifts in the air; the camera frames the model from its bounds.
extension Scene {
    /// What a set builder needs to know of the model it stands round.
    private struct Stand {
        let kit: Kit
        let look: ShowcaseLook
        let extent: SIMD3<Float>     // the placed model's size
        let base: Float              // where its feet are
        var radius: Float { max(extent.x, extent.z) / 2 }
        var target: SIMD3<Float> { [0, base + extent.y / 2, 0] }
    }

    func buildShowcase() {
        let look = ShowcaseLook.look(for: settings.showcase)
        let kit = Kit(self)
        skyColor = look.sky
        var model: GLTFModel?
        let url = Scene.showcaseFile(settings.showcase)
        if let url {
            do { model = try GLTFLoader.load(url) } catch { print("Showcase: can't load \(url.lastPathComponent): \(error)") }
        } else {
            print("Showcase: no model matches \"\(settings.showcase)\" in \(Scene.assetsDirectory.path)")
        }
        var extent = SIMD3<Float>(0.6, look.size, 0.6)
        if let model, !model.bounds.isEmpty {
            let d = model.bounds.hi - model.bounds.lo
            extent = d * (look.size / max(d.max(), 1e-6))
        }
        let floats = look.stage == .underwater
        let plinth: Float = 0.3
        let stand = Stand(kit: kit, look: look, extent: extent, base: floats ? 1.2 : plinth)

        if let model, let url {
            let place = Scene.placement(model, size: look.size), base = translate([0, stand.base, 0])
            if floats {   // adrift: a slow bob and roll
                addModel(model, url: url, transform: base * place) { t in
                    translate([0.15 * sin(0.21 * t), stand.base + 0.12 * sin(0.5 * t), 0])
                        * rotate(0.04 * sin(0.37 * t), [0, 0, 1]) * rotate(0.03 * sin(0.29 * t), [1, 0, 0]) * place
                }
            } else if look.spin != 0 {
                addModel(model, url: url, transform: base * place) { t in base * rotate(look.spin * t, [0, 1, 0]) * place }
            } else {
                addModel(model, url: url, transform: base * place)
            }
            print(String(format: "Showcase: %@ (%d triangles), %@ set", model.name, model.triangleCount, "\(look.stage)"))
        }
        if !floats { addPlinth(stand, height: plinth) }
        addKeyLight(stand)
        switch look.stage {
        case .studio: buildStudio(stand)
        case .crypt: buildCrypt(stand)
        case .forge: buildForge(stand)
        case .underwater: buildUnderwater(stand)
        case .neon: buildNeon(stand)
        case .workshop: buildWorkshop(stand)
        case .sanctum: buildSanctum(stand)
        }
        addParticles(stand)
        defaultCamera = Scene.showcaseCamera(stand.target, extent: extent, view: look.view)
    }

    /// The camera `view` radians round the model from its front, a little below its middle, far enough that it fills
    /// about 70% of the frame's height.
    private static func showcaseCamera(_ target: SIMD3<Float>, extent: SIMD3<Float>, view: Float) -> Camera {
        let fov = Camera().fovY
        let h = max(extent.y, max(extent.x, extent.z) * 0.6)
        let d = h / (2 * 0.7 * tan(fov / 2)) + 0.3 * max(extent.x, extent.z)
        let eye = max(target.y - 0.08 * h, 0.4)
        let position = SIMD3<Float>(target.x + sin(view) * d, eye, target.z + cos(view) * d)
        let f = normalize(target - position)
        return camera(position, yaw: atan2(f.x, -f.z), pitch: asin(f.y))
    }

    // MARK: - The rig

    /// A dark polished drum under the model, a thin ring of the accent colour round its top.
    private func addPlinth(_ s: Stand, height: Float) {
        let drum = addMesh(Scene.cylinderMesh())
        let r = max(s.radius * 1.15 + 0.2, 0.6)
        let stone = addPBRMaterial(baseColor: [0.05, 0.05, 0.055], metallic: 0, roughness: 0.2)
        addInstance(drum, stone, scale([r, height, r]))
        let ring = addMaterial(albedo: .zero, emission: Scene.hue(s.look.accent) * 3)
        addInstance(drum, ring, translate([0, height - 0.06, 0]) * scale([r + 0.015, 0.025, r + 0.015]))
    }

    /// The key: a spot high in front and to the right, its cone just wider than the model, about 5 W/m² on it.
    private func addKeyLight(_ s: Stand) {
        let dist = max(5, s.extent.y * 2.5)
        let at = s.target + normalize(SIMD3<Float>(0.35, 1, 0.6)) * dist
        let outer = atan(max(s.extent.y, 2 * s.radius) * 0.7 / dist) + Scene.degrees(2)
        addLight(.spot(radius: 0.06, inner: outer * 0.6, outer: outer), color: Scene.hue(s.look.key) * 5 * dist * dist,
                 motion: .constant) { _ in LightPose(position: at, direction: normalize(s.target - at)) }
    }

    /// Two spots high behind the model, left and right, `irradiance` W/m² on it: its outline, and two beams in the fog
    /// that meet at it.
    private func addRims(_ s: Stand, irradiance: Float = 3) {
        let dist = max(4, s.extent.y * 2)
        for side: Float in [-1, 1] {
            let at = s.target + normalize(SIMD3<Float>(side * 0.8, 0.9, -1)) * dist
            let outer = atan(max(s.extent.y, 2 * s.radius) * 0.6 / dist) + Scene.degrees(2)
            addLight(.spot(radius: 0.04, inner: outer * 0.5, outer: outer), color: Scene.hue(s.look.rim) * irradiance * dist * dist,
                     motion: .constant) { _ in LightPose(position: at, direction: normalize(s.target - at)) }
        }
    }

    // MARK: - Sets

    private func buildStudio(_ s: Stand) {
        let floor = addPBRMaterial(baseColor: [0.08, 0.08, 0.085], metallic: 0, roughness: 0.4)
        let wall = addMaterial(albedo: [0.1, 0.1, 0.1])
        addInstance(s.kit.quad, floor, scale([40, 1, 40]))
        addInstance(s.kit.quad, wall, translate([0, 6, -6]) * rotate(.pi / 2, [1, 0, 0]) * scale([40, 1, 12]))
        addRims(s, irradiance: 4)
    }

    /// A stone hall, its left wall cut by three tall windows; a low sun (or moon) lays shafts across the floor through
    /// the mist, through the model and past it.
    private func buildCrypt(_ s: Stand) {
        let kit = s.kit
        let floor = addPBRMaterial(baseColor: [0.25, 0.24, 0.22], metallic: 0, roughness: 0.3)
        let stone = addMaterial(albedo: [0.42, 0.4, 0.37])
        let (x0, x1, z0, z1, h): (Float, Float, Float, Float, Float) = (-7, 7, -9, 7, 9)
        addInstance(kit.quad, floor, translate([0, 0, (z0 + z1) / 2]) * scale([x1 - x0, 1, z1 - z0]))
        kit.slab([x0 - 0.4, 0, z0 - 0.4], [x1 + 0.4, h, z0], stone)            // far wall
        kit.slab([x1, 0, z0], [x1 + 0.4, h, z1], stone)                        // right wall
        kit.slab([x0 - 0.4, h, z0 - 0.4], [x1 + 0.4, h + 0.4, z1], stone)      // ceiling
        // The left wall: sills at 2.5 m, lintels at 7.5 m, three openings.
        let (sill, lintel): (Float, Float) = (2.5, 7.5)
        kit.slab([x0 - 0.4, 0, z0], [x0, sill, z1], stone)
        kit.slab([x0 - 0.4, lintel, z0], [x0, h, z1], stone)
        var at = z0
        for (a, b): (Float, Float) in [(-6.4, -4.8), (-2.8, -1.2), (0.8, 2.4)] {
            kit.slab([x0 - 0.4, sill, at], [x0, lintel, a], stone)
            kit.slab([x0 - 0.35, sill, (a + b) / 2 - 0.06], [x0 - 0.05, lintel, (a + b) / 2 + 0.06], stone)   // mullion
            at = b
        }
        kit.slab([x0 - 0.4, sill, at], [x0, lintel, z1], stone)
        for cz: Float in [-6.5, -2] {
            for cx: Float in [-4.6, 4.6] { kit.box([cx, h / 2, cz], [0.8, h, 0.8], stone) }
        }
        // The sun beyond the windows, low, swinging a little: its shafts sweep slowly over the model.
        let e = Scene.degrees(34)
        addLight(.sun(angularRadius: Scene.degrees(0.27)), color: Scene.hue(s.look.key) * 4) { t in
            let a = Scene.degrees(-72 + 6 * sin(0.1 * t))   // from the left, a little behind
            return LightPose(position: .zero, direction: normalize(SIMD3(cos(e) * sin(a), sin(e), -0.5 * cos(e) * cos(a))))
        }
        addRims(s, irradiance: 2.5)
        fogVolumes.append(FogVolume(shape: .box(halfExtents: [7, 0.8, 8]), center: [0, 0.2, -1], density: 0.5,
                                    albedo: [0.85, 0.88, 0.9], edge: 0.8, noise: 0.9, heightFalloff: 2))
    }

    /// Dark brick round a glowing pit at the model's left: embers rise from it into a column of smoke; a light over it
    /// flickers.
    private func buildForge(_ s: Stand) {
        let kit = s.kit
        let floor = addPBRMaterial(baseColor: [0.08, 0.07, 0.065], metallic: 0, roughness: 0.45)
        let brick = addMaterial(albedo: [0.12, 0.08, 0.065])
        let iron = addPBRMaterial(baseColor: [0.3, 0.3, 0.32], metallic: 1, roughness: 0.45)
        kit.room(width: 12, height: 6, depth: 16, floor: floor, walls: brick, ceiling: true)
        let pit = SIMD3<Float>(-(s.radius + 1.6), 0, -1.6)
        let drum = addMesh(Scene.cylinderMesh())
        addInstance(drum, addMaterial(albedo: [0.1, 0.09, 0.08]), translate(pit) * scale([1.0, 0.35, 1.0]))
        addInstance(drum, addMaterial(albedo: .zero, emission: Scene.hue(s.look.accent) * 5), translate(pit) * scale([0.82, 0.37, 0.82]))
        addLight(.sphere(radius: 0.15), color: Scene.hue(s.look.accent) * 12, motion: .scaleOnly) { t in
            let flicker = 0.8 + 0.12 * sin(13 * t) + 0.08 * sin(29 * t + 1)
            return LightPose(position: pit + [0, 0.9, 0], scale: SIMD3(repeating: flicker))
        }
        // An anvil and a rack of tools on the right, chains from the ceiling.
        kit.box([s.radius + 1.8, 0.35, -1.0], [0.5, 0.7, 0.5], iron)
        kit.box([s.radius + 1.8, 0.78, -1.0], [0.9, 0.16, 0.36], iron)
        for (i, x): (Int, Float) in [(0, -1.2), (1, 0.4), (2, 2.0)] {
            kit.box([x, 4.6, -4.5 + Float(i) * 0.4], [0.05, 2.8, 0.05], iron)
        }
        addRims(s, irradiance: 2)
        fogVolumes.append(FogVolume(shape: .sphere(radius: 1.6), center: pit + [0, 1.0, 0], density: 0.25,
                                    albedo: [1, 0.65, 0.4], edge: 1, noise: 0.8))
        fogVolumes.append(FogVolume(shape: .box(halfExtents: [1.0, 2.2, 1.0]), center: pit + [0, 3.4, 0], density: 0.15,
                                    albedo: [0.6, 0.55, 0.5], edge: 0.8, noise: 0.9) { t in pit + [0.2 * sin(0.3 * t), 3.4, 0] })
    }

    /// The sea floor in deep water: sand, rocks, swaying weed, narrow shafts from the surface far above that sway too.
    private func buildUnderwater(_ s: Stand) {
        let kit = s.kit
        let sand = addMaterial(albedo: [0.3, 0.29, 0.24])
        let rock = addMaterial(albedo: [0.12, 0.13, 0.12])
        let weed = addMaterial(albedo: [0.03, 0.12, 0.05])
        addInstance(kit.quad, sand, scale([60, 1, 60]))
        var rng = SplitMix64(seed: 0x5EA)
        for _ in 0..<24 {
            let a = rng.range(0, 2 * .pi), r = rng.range(s.radius + 2, 14), size = rng.range(0.3, 1.4)
            addInstance(kit.sphere, rock, translate([r * sin(a), 0, r * cos(a)]) * rotate(rng.range(0, 3), [0, 1, 0])
                            * scale([size * rng.range(1, 1.8), size * 0.6, size]))
        }
        for _ in 0..<40 {
            let a = rng.range(0, 2 * .pi), r = rng.range(s.radius + 1.5, 10), h = rng.range(0.8, 2.6), phase = rng.range(0, 6)
            let p = SIMD3<Float>(r * sin(a), 0, r * cos(a))
            let blade = SIMD3<Float>(0.16, h, 0.03), yaw = rng.range(0, .pi)
            addInstance(kit.cube, weed, translate(p) * scale(blade)) { t in
                translate(p) * rotate(yaw, [0, 1, 0]) * rotate(0.15 * sin(0.8 * t + phase), [1, 0, 0])
                    * translate([0, h / 2, 0]) * scale(blade)
            }
        }
        // Shafts: narrow spots 14 m up, each swaying on its own.
        for i in 0..<5 {
            let a = Float(i) * 1.3, r: Float = i == 0 ? 0 : 2.5 + Float(i) * 0.6
            let top = SIMD3<Float>(r * sin(a), 14, r * cos(a) - 1), phase = Float(i) * 1.7
            addLight(.spot(radius: 0.3, inner: Scene.degrees(3), outer: Scene.degrees(6)), color: Scene.hue(s.look.key) * 500) { t in
                let ground = SIMD3<Float>(top.x + 1.5 * sin(0.17 * t + phase), 0, top.z + 1.2 * sin(0.13 * t + 2 * phase))
                return LightPose(position: top, direction: normalize(ground - top))
            }
        }
        // Two lamps behind for the outline, as a diver's would be.
        for side: Float in [-1, 1] {
            let at = SIMD3<Float>(side * (s.radius + 1), s.target.y + 0.6, -(s.radius + 1.5))
            addLight(.sphere(radius: 0.08), color: Scene.hue(s.look.rim) * 12, motion: .constant) { _ in LightPose(position: at) }
        }
    }

    /// A glossy black floor between coloured light panels, strips of tube light along the walls, and a scanner beam
    /// sweeping the model from above.
    private func buildNeon(_ s: Stand) {
        let kit = s.kit
        let floor = addPBRMaterial(baseColor: [0.02, 0.02, 0.025], metallic: 0, roughness: 0.08)
        let wall = addMaterial(albedo: [0.04, 0.04, 0.045])
        addInstance(kit.quad, floor, scale([40, 1, 40]))
        addInstance(kit.quad, wall, translate([0, 6, -6]) * rotate(.pi / 2, [1, 0, 0]) * scale([40, 1, 12]))
        let h = max(s.extent.y * 1.4, 2.2)
        for (side, color): (Float, SIMD3<Float>) in [(-1, s.look.rim), (1, s.look.accent)] {
            let at = SIMD3<Float>(side * (s.radius + 1.8), h / 2 + 0.1, -0.6)
            addLight(.rect(width: 0.35, height: h), color: Scene.hue(color) * 8, motion: .constant) { _ in
                LightPose(position: at, direction: normalize(SIMD3(-side, 0, 0.35)))
            }
        }
        addLight(.tube(length: 12, radius: 0.025), color: Scene.hue(s.look.accent) * 20, motion: .constant) { _ in
            LightPose(position: [0, 0.04, -5.9], direction: [1, 0, 0])
        }
        for x: Float in [-3.5, 3.5] {
            addLight(.tube(length: 3.5, radius: 0.025), color: Scene.hue(s.look.rim) * 12, motion: .constant) { _ in
                LightPose(position: [x, 2.0, -5.9], direction: [0, 1, 0])
            }
        }
        let scanner = SIMD3<Float>(0, 6, -2.5)
        addLight(.spot(radius: 0.05, inner: Scene.degrees(2), outer: Scene.degrees(4)), color: Scene.hue(s.look.key) * 300) { t in
            let target = s.target + SIMD3<Float>(1.4 * sin(0.6 * t), 0.6 * sin(0.37 * t), 0)
            return LightPose(position: scanner, direction: normalize(target - scanner))
        }
    }

    /// A room at dusk: the low sun through a window behind the model lays a shaft over it; a tube flickers at the back;
    /// jars glow on the shelves.
    private func buildWorkshop(_ s: Stand) {
        let kit = s.kit
        let floor = addPBRMaterial(baseColor: [0.35, 0.22, 0.12], metallic: 0, roughness: 0.45)
        let plaster = addMaterial(albedo: [0.22, 0.2, 0.18])
        let wood = addMaterial(albedo: [0.3, 0.18, 0.1])
        let (x0, x1, z0, z1, h): (Float, Float, Float, Float, Float) = (-5, 5, -6, 6, 4.5)
        addInstance(kit.quad, floor, translate([0, 0, (z0 + z1) / 2]) * scale([x1 - x0, 1, z1 - z0]))
        kit.slab([x0 - 0.3, 0, z0], [x0, h, z1], plaster)                      // left wall
        kit.slab([x1, 0, z0], [x1 + 0.3, h, z1], plaster)                      // right wall
        kit.slab([x0 - 0.3, h, z0 - 0.3], [x1 + 0.3, h + 0.3, z1], plaster)    // ceiling
        // The back wall with a window at the left: x -3 ... -1, y 1.2 ... 3.6, a cross of glazing bars.
        let (wx0, wx1, wy0, wy1): (Float, Float, Float, Float) = (-3, -1, 1.2, 3.6)
        kit.slab([x0 - 0.3, 0, z0 - 0.3], [x1 + 0.3, wy0, z0], plaster)
        kit.slab([x0 - 0.3, wy1, z0 - 0.3], [x1 + 0.3, h, z0], plaster)
        kit.slab([x0 - 0.3, wy0, z0 - 0.3], [wx0, wy1, z0], plaster)
        kit.slab([wx1, wy0, z0 - 0.3], [x1 + 0.3, wy1, z0], plaster)
        kit.slab([(wx0 + wx1) / 2 - 0.03, wy0, z0 - 0.2], [(wx0 + wx1) / 2 + 0.03, wy1, z0 - 0.1], wood)
        kit.slab([wx0, (wy0 + wy1) / 2 - 0.03, z0 - 0.2], [wx1, (wy0 + wy1) / 2 + 0.03, z0 - 0.1], wood)
        // The low sun behind the window: its shaft comes forward and down over the model.
        addLight(.sun(angularRadius: Scene.degrees(0.27)), color: Scene.hue(s.look.key) * 3) { t in
            LightPose(position: .zero, direction: normalize(SIMD3<Float>(-0.32 + 0.03 * sin(0.1 * t), 0.36, -1)))
        }
        // Shelves on the right wall with glowing jars, a bench at the back.
        for y: Float in [1.2, 2.0, 2.8] { kit.slab([x1 - 0.45, y, -4.5], [x1, y + 0.05, -1], wood) }
        var rng = SplitMix64(seed: 0x1AB)
        for y: Float in [1.25, 2.05] {
            for _ in 0..<3 {
                let jar = addMaterial(albedo: .zero, emission: Scene.hue(s.look.accent) * rng.range(1.5, 4))
                kit.ball([x1 - 0.22, y + 0.1, rng.range(-4.3, -1.2)], 0.08, jar)
            }
        }
        kit.slab([1.2, 0, z0 + 0.1], [4.6, 0.9, z0 + 0.9], wood)
        addLight(.tube(length: 1.2, radius: 0.025), color: Scene.hue(s.look.rim) * 25, motion: .scaleOnly) { t in
            let on: Float = sin(7 * t) + sin(2.3 * t + 1) > -1.6 ? 1 : 0.15   // now and then it stutters
            return LightPose(position: [2.2, h - 0.15, -3.5], direction: [1, 0, 0], scale: SIMD3(repeating: on))
        }
        // A desk lamp low in front and to the left: the model's face, against the window behind it.
        let lamp = s.target + normalize(SIMD3<Float>(-0.7, 0.35, 0.8)) * 2.5
        kit.box(lamp + [0, 0.12, 0], [0.22, 0.12, 0.22], wood)
        addLight(.spot(radius: 0.05, inner: Scene.degrees(20), outer: Scene.degrees(35)), color: SIMD3<Float>(1, 0.8, 0.55) * 2.5 * 6.25,
                 motion: .constant) { _ in LightPose(position: lamp, direction: normalize(s.target - lamp)) }
        addRims(s, irradiance: 2.5)
    }

    /// A round dais in the dark under one beam from high above, a ring of columns round it, a glowing cloud round
    /// the model with runes circling in it.
    private func buildSanctum(_ s: Stand) {
        let kit = s.kit
        let floor = addPBRMaterial(baseColor: [0.06, 0.06, 0.07], metallic: 0, roughness: 0.35)
        let stone = addMaterial(albedo: [0.3, 0.29, 0.32])
        addInstance(kit.quad, floor, scale([40, 1, 40]))
        let drum = addMesh(Scene.cylinderMesh())
        let r = max(3.2, s.radius + 2)
        addInstance(drum, stone, scale([r, 0.15, r]))
        addInstance(drum, addMaterial(albedo: .zero, emission: Scene.hue(s.look.accent) * 2),
                    translate([0, 0.1, 0]) * scale([r + 0.03, 0.03, r + 0.03]))
        for i in 0..<8 {
            let a = Float(i) / 8 * 2 * .pi + 0.2
            kit.box([(r + 3.3) * sin(a), 3.5, (r + 3.3) * cos(a)], [0.7, 7, 0.7], stone, yaw: a)
        }
        let top = SIMD3<Float>(0, 12, 0)
        let outer = atan((s.radius + 0.6) / (top.y - s.target.y))
        addLight(.spot(radius: 0.1, inner: outer * 0.7, outer: outer), color: Scene.hue(s.look.key) * 2.5 * top.y * top.y,
                 motion: .constant) { _ in LightPose(position: top, direction: [0, -1, 0]) }
        addRims(s, irradiance: 3)
        let cloud = (s.look.accent + 1) / 2
        fogVolumes.append(FogVolume(shape: .sphere(radius: s.radius + 1.6), center: s.target, density: 0.08,
                                    albedo: cloud, edge: 1.2, noise: 0.8) { t in s.target + [0, 0.15 * sin(0.3 * t), 0] })
    }

    // MARK: - Particles

    /// What drifts in the air: small glowing shapes that only the camera sees (maskLights: no shadows, not lights).
    private func addParticles(_ s: Stand) {
        let mote = addMesh(Scene.icosphere(subdivisions: 1))
        var rng = SplitMix64(seed: 0xD057)
        switch s.look.particles {
        case .none:
            break
        case .embers:   // from the pit (Forge), rising and swaying, round again
            let pit = SIMD3<Float>(-(s.radius + 1.6), 0.4, -1.6)
            for _ in 0..<160 {
                let start = pit + SIMD3(rng.range(-0.6, 0.6), 0, rng.range(-0.6, 0.6))
                let speed = rng.range(0.35, 0.9), phase = rng.range(0, 1), size = rng.range(0.006, 0.016)
                let ember = addMaterial(albedo: .zero, emission: SIMD3<Float>(1, 0.42, 0.1) * rng.range(15, 40))
                addInstance(mote, ember, translate(start) * scale(size), mask: Scene.maskLights) { t in
                    let y = (t * speed / 4.5 + phase).truncatingRemainder(dividingBy: 1) * 4.5
                    let drift = SIMD3<Float>(0.25 * sin(1.7 * t + phase * 9) + 0.4 * y / 4.5, y, 0.2 * cos(1.3 * t + phase * 7))
                    return translate(start + drift) * scale(size * (1 - 0.7 * y / 4.5))
                }
            }
        case .bubbles:   // from the sea floor round the model, up and wobbling
            let glow = addMaterial(albedo: .zero, emission: [0.6, 0.9, 1] * 0.35)
            for _ in 0..<120 {
                let a = rng.range(0, 2 * .pi), r = rng.range(0.5, s.radius + 3)
                let start = SIMD3<Float>(r * sin(a), 0, r * cos(a))
                let speed = rng.range(0.5, 1.2), phase = rng.range(0, 1), size = rng.range(0.006, 0.02)
                addInstance(mote, glow, translate(start) * scale(size), mask: Scene.maskLights) { t in
                    let y = (t * speed / 10 + phase).truncatingRemainder(dividingBy: 1) * 10
                    return translate(start + [0.05 * sin(5 * t + phase * 20), y, 0.05 * cos(4 * t + phase * 13)]) * scale(size)
                }
            }
        case .dust:   // motes drifting round the model, lit as if by the beams
            let speck = addMaterial(albedo: .zero, emission: Scene.hue(s.look.key) * 1.5)
            for _ in 0..<200 {
                let c = s.target + SIMD3(rng.range(-3, 3), rng.range(-1.2, 1.8), rng.range(-3, 2.5))
                let amp = SIMD3(rng.range(0.1, 0.4), rng.range(0.05, 0.2), rng.range(0.1, 0.4))
                let f = SIMD3(rng.range(0.05, 0.2), rng.range(0.05, 0.15), rng.range(0.05, 0.2)), phase = rng.range(0, 6)
                let size = rng.range(0.003, 0.007)
                addInstance(mote, speck, translate(c) * scale(size), mask: Scene.maskLights) { t in
                    translate(c + amp * SIMD3(sin(f.x * t + phase), sin(f.y * t + 2 * phase), cos(f.z * t + phase))) * scale(size)
                }
            }
        case .runes:   // glowing tablets circling the model low, below its knees: never in front of its face
            let rune = addMaterial(albedo: .zero, emission: Scene.hue(s.look.accent) * 3)
            let count = 12, radius = s.radius + 0.35, height = s.base + 0.2 * s.extent.y
            for i in 0..<count {
                let phase = Float(i) / Float(count) * 2 * .pi
                addInstance(s.kit.cube, rune, matrix_identity_float4x4, mask: Scene.maskLights) { t in
                    let a = phase + 0.3 * t
                    return translate([radius * sin(a), height + 0.08 * sin(0.7 * t + 2 * phase), radius * cos(a)])
                        * rotate(a, [0, 1, 0]) * scale([0.05, 0.075, 0.006])
                }
            }
        }
    }

    // MARK: - Meshes

    /// A drum of radius 1 from y = 0 to 1: its side (smooth) and top (flat); no bottom.
    static func cylinderMesh(segments: Int = 64) -> MeshGeometry {
        var p: [SIMD3<Float>] = [], n: [SIMD3<Float>] = [], idx: [UInt32] = []
        for i in 0...segments {
            let a = Float(i) / Float(segments) * 2 * .pi, d = SIMD3<Float>(sin(a), 0, cos(a))
            p += [d, d + [0, 1, 0]]
            n += [d, d]
        }
        for i in 0..<UInt32(segments) {
            let b = i * 2
            idx += [b, b + 2, b + 1, b + 1, b + 2, b + 3]
        }
        let centre = UInt32(p.count)
        p.append([0, 1, 0]); n.append([0, 1, 0])
        for i in 0...segments {
            let a = Float(i) / Float(segments) * 2 * .pi
            p.append([sin(a), 1, cos(a)]); n.append([0, 1, 0])
        }
        for i in 0..<UInt32(segments) { idx += [centre, centre + 1 + i, centre + 2 + i] }
        return (p, n, idx)
    }
}
