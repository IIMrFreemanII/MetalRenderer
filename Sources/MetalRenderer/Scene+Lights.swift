import Foundation
import simd

/// Demo scenes for the light types: one per type (spot, sun, rect, tube, emissive mesh), one with all of them, a
/// misty hall for the volumetric fog, an open valley for the sky and clouds, and a night market for many lights. Procedural geometry only, so they load at once; every light moves, sweeps or
/// flickers. Their fog settings are presets (FogSettings.preset); the local fog volumes are set up here.
extension Scene {
    /// Shared meshes and a box helper for the builders below (and the showcase's and Scene+Shapes.swift's).
    struct Kit {
        let scene: Scene
        let quad: Int, cube: Int, sphere: Int

        init(_ scene: Scene) {
            self.scene = scene
            quad = scene.addMesh(Scene.quadMesh())
            cube = scene.addMesh(Scene.cubeMesh())
            sphere = scene.addMesh(Scene.icosphere(subdivisions: 3))
        }

        /// An axis-aligned box (rotated about Y by `yaw`) given by its centre and size.
        @discardableResult
        func box(_ center: SIMD3<Float>, _ size: SIMD3<Float>, _ material: Int, yaw: Float = 0) -> Int {
            scene.addInstance(cube, material, translate(center) * rotate(yaw, [0, 1, 0]) * scale(size))
        }

        /// A box from its min and max corners.
        @discardableResult
        func slab(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, _ material: Int) -> Int {
            box((lo + hi) / 2, hi - lo, material)
        }

        @discardableResult
        func ball(_ center: SIMD3<Float>, _ radius: Float, _ material: Int) -> Int {
            scene.addInstance(sphere, material, translate(center) * scale(radius))
        }

        /// Floor, back and side walls (and a ceiling if `ceiling`) of a room open toward +Z.
        func room(width w: Float, height h: Float, depth d: Float, floor: Int, walls: Int, ceiling: Bool) {
            scene.addInstance(quad, floor, scale([w, 1, d]))
            scene.addInstance(quad, walls, translate([0, h / 2, -d / 2]) * rotate(.pi / 2, [1, 0, 0]) * scale([w, 1, h]))
            scene.addInstance(quad, walls, translate([-w / 2, h / 2, 0]) * rotate(-.pi / 2, [0, 0, 1]) * scale([h, 1, d]))
            scene.addInstance(quad, walls, translate([w / 2, h / 2, 0]) * rotate(.pi / 2, [0, 0, 1]) * scale([h, 1, d]))
            if ceiling { scene.addInstance(quad, walls, translate([0, h, 0]) * rotate(.pi, [1, 0, 0]) * scale([w, 1, d])) }
        }
    }

    static func camera(_ position: SIMD3<Float>, yaw: Float = 0, pitch: Float) -> Camera {
        var c = Camera()
        c.position = position
        c.yaw = yaw
        c.pitch = pitch
        return c
    }

    /// The light demo scenes' default cameras (nil for the other scenes).
    static func demoCamera(_ kind: SceneKind) -> Camera? {
        switch kind {
        case .spots: return camera([0, 2.6, 8], pitch: -0.14)
        case .sun: return camera([0.5, 1.8, 11], pitch: -0.06)
        case .area: return camera([0, 2.0, 6.5], pitch: -0.12)
        case .tubes: return camera([2.0, 1.6, 7], yaw: -0.2, pitch: -0.08)
        case .emissive: return camera([0, 2.2, 6.5], pitch: -0.14)
        case .mixed: return camera([-3.4, 1.7, 3.7], yaw: 0.42, pitch: -0.14)
        case .fog: return camera([1.2, 1.7, 2.6], yaw: -0.04, pitch: 0.1)
        case .valley: return camera([4, 2.2, 38], yaw: -0.15, pitch: 0.12)
        case .market: return camera([0.6, 1.7, 30], yaw: 0.02, pitch: 0.12)
        case .forest: return camera([1.5, 1.7, 10], yaw: 0.06, pitch: 0.1)
        case .shapes: return camera([0, 3.9, 4.4], pitch: -0.58)
        case .physics: return camera([0, 4.2, 8.2], pitch: -0.42)
        case .ragdolls: return camera([3.2, 3.4, 7.6], yaw: -0.36, pitch: -0.3)
        case .hair: return camera([0.1, 1.9, 4.8], yaw: -0.02, pitch: -0.21)
        case .softBodies: return camera([0, 2.3, 3.0], pitch: -0.42)
        case .muscles: return camera([0, 2.4, 8.2], pitch: -0.24)
        case .fluids: return camera([0, 1.25, 1.05], pitch: -0.64)
        case .particles: return camera([0.3, 1.7, 6.2], yaw: 0.02, pitch: -0.12)
        case .vfxStage: return camera([0, 2.4, 10.5], pitch: 0.02)
        case .materials: return camera([0, 2.0, 6.6], pitch: -0.17)
        case .painter: return camera([0, 1.5, 3.4], pitch: -0.16)
        case .cornell, .stress, .gallery, .crowd, .city, .cityNight, .world, .showcase, .plants, .buildings, .characters, .mireland:
            return nil   // the crowd's, the city's, the world's and the showcase's are their scenes' to say
        }
    }

    static func degrees(_ d: Float) -> Float { d * .pi / 180 }

    /// Unit-luminance colour.
    static func hue(_ c: SIMD3<Float>) -> SIMD3<Float> { c / dot(c, [0.2126, 0.7152, 0.0722]) }

    // MARK: - Light check

    /// Benchmark scene (METALRENDERER_BENCH=lightcheck): a floor, a box, and one light — "rect", "tube" or "sphere" — or,
    /// with a "-mesh" suffix, an emissive mesh of the same shape and radiance, sampled as a mesh light. The mesh
    /// estimator is unbiased, so converged images of the two check the analytic light's closed form.
    func buildLightCheck(_ check: String) {
        let kit = Kit(self)
        skyColor = .zero
        let white = addMaterial(albedo: [0.8, 0.8, 0.8])
        addInstance(kit.quad, white, scale([12, 1, 12]))
        kit.box([0.6, 0.4, -0.4], [0.8, 0.8, 0.8], white, yaw: 0.5)
        let mesh = check.hasSuffix("-mesh")
        let center = SIMD3<Float>(-0.3, 1.4, 0)
        switch check.replacingOccurrences(of: "-mesh", with: "") {
        case "rect":
            // 1.2 x 0.6, tilted 30 degrees, facing down and toward +X.
            let n = normalize(SIMD3<Float>(sin(0.52), -cos(0.52), 0)), radiance = SIMD3<Float>(4, 4, 4)
            let pose = LightPose(position: center, direction: n, tangent: [0, 0, 1])
            if mesh {
                let (t, nn, b) = (SIMD3<Float>(0, 0, 1), n, cross(SIMD3<Float>(0, 0, 1), n))
                addInstance(kit.quad, addMaterial(albedo: .zero, emission: radiance),
                            float4x4(SIMD4(t * 1.2, 0), SIMD4(nn, 0), SIMD4(b * 0.6, 0), SIMD4(center, 1)))
            } else {
                addLight(.rect(width: 1.2, height: 0.6), color: radiance, motion: .constant) { _ in pose }
            }
        case "tube":
            let intensity = SIMD3<Float>(3, 3, 3), length: Float = 1.6, r: Float = 0.05
            let axis = normalize(SIMD3<Float>(0.3, 0.2, 1))
            if mesh {
                addInstance(addMesh(Scene.capsuleMesh(halfLength: length / 2, radius: r)),
                            addMaterial(albedo: .zero, emission: 2 * intensity / (.pi * r * length)),
                            translate(center) * Scene.alignY(axis))
            } else {
                addLight(.tube(length: length, radius: r), color: intensity, motion: .constant) { _ in LightPose(position: center, direction: axis) }
            }
        case "empty":
            break
        default:   // sphere
            let intensity = SIMD3<Float>(3, 3, 3), r: Float = 0.25
            if mesh {
                addInstance(kit.sphere, addMaterial(albedo: .zero, emission: intensity / (.pi * r * r)), translate(center) * scale(r))
            } else {
                addLight(.sphere(radius: r), color: intensity, motion: .constant) { _ in LightPose(position: center) }
            }
        }
        defaultCamera = Scene.camera([0, 3.2, 4.2], pitch: -0.55)
    }

    // MARK: - Spot lights

    /// A stage: glossy floor, back wall, props, and six coloured spot lights on a truss sweeping their beams over
    /// it, from tight crisp cones to wide soft ones.
    func buildSpots() {
        let kit = Kit(self)
        skyColor = [0.02, 0.025, 0.04]
        let stage = addPBRMaterial(baseColor: [0.10, 0.10, 0.11], metallic: 0, roughness: 0.3)
        let wall = addMaterial(albedo: [0.55, 0.55, 0.58])
        let white = addMaterial(albedo: [0.8, 0.8, 0.8])
        let red = addMaterial(albedo: [0.7, 0.12, 0.1])
        let steel = addPBRMaterial(baseColor: [0.8, 0.8, 0.82], metallic: 1, roughness: 0.25)
        let gold = addPBRMaterial(baseColor: [1.0, 0.78, 0.35], metallic: 1, roughness: 0.4)
        let truss = addMaterial(albedo: [0.15, 0.15, 0.15])

        kit.room(width: 24, height: 9, depth: 16, floor: stage, walls: wall, ceiling: false)
        // Steps up to a riser at the back.
        kit.slab([-6, 0, -8], [6, 0.4, -5], white)
        kit.slab([-4, 0.4, -8], [4, 0.8, -6.2], white)
        // Props.
        for x: Float in [-5, 5] { kit.box([x, 2.0, -6.5], [0.6, 4, 0.6], white) }
        kit.ball([-2.2, 0.7, -1.5], 0.7, steel)
        kit.ball([1.2, 1.3, -6.8], 0.5, gold)
        kit.box([2.4, 0.6, -0.5], [1.2, 1.2, 1.2], red, yaw: 0.5)
        kit.box([-0.2, 0.9, -3.4], [0.5, 1.8, 0.5], white, yaw: 0.3)
        kit.ball([4.5, 0.45, 1.5], 0.45, white)
        kit.box([-5, 0.35, 1], [0.7, 0.7, 0.7], gold, yaw: 0.8)
        // Truss the spots hang from.
        kit.box([0, 6.0, 1.5], [15, 0.25, 0.25], truss)

        let colors: [SIMD3<Float>] = [[1.0, 0.9, 0.75], [1.0, 0.25, 0.15], [0.3, 1.0, 0.35], [0.25, 0.45, 1.0],
                                      [0.95, 0.3, 1.0], [1.0, 0.65, 0.2]]
        for i in 0..<6 {
            let x = -6.25 + 2.5 * Float(i)
            let position = SIMD3<Float>(x, 5.75, 1.5)
            let outer = Scene.degrees(i % 2 == 0 ? 16 : 28), inner = Scene.degrees(i % 2 == 0 ? 13 : 10)
            let phase = Float(i) * 1.1
            let speed: Float = 0.25 + 0.04 * Float(i)
            addLight(.spot(radius: 0.06, inner: inner, outer: outer), color: Scene.hue(colors[i]) * 150) { t in
                let target = SIMD3<Float>(x * 0.45 + 3.2 * sin(speed * t + phase), 0, -2.5 + 3 * cos(0.8 * speed * t + 2 * phase))
                return LightPose(position: position, direction: normalize(target - position))
            }
        }
        // Stage haze, thickest low over the stage.
        fogVolumes.append(FogVolume(shape: .box(halfExtents: [10, 3.5, 7]), center: [0, 3.5, -2], density: 0.05,
                                    edge: 2, noise: 0.7, heightFalloff: 0.15))
        defaultCamera = Scene.demoCamera(.spots)!
    }

    // MARK: - Sun and sky

    /// A courtyard: walls, a colonnade under a roof, a room whose only light comes in through its windows, and a
    /// day cycle (a minute long) that swings the sun from a low morning sun to noon and back, warming and
    /// dimming it and the sky near the horizon.
    func buildSun() {
        let kit = Kit(self)
        let ground = addMaterial(albedo: [0.45, 0.4, 0.33])
        let stone = addMaterial(albedo: [0.72, 0.66, 0.56])
        let plaster = addMaterial(albedo: [0.82, 0.8, 0.76])
        let terracotta = addMaterial(albedo: [0.62, 0.3, 0.18])
        let green = addMaterial(albedo: [0.2, 0.42, 0.18])
        let blue = addMaterial(albedo: [0.15, 0.3, 0.65])

        addInstance(kit.quad, ground, scale([60, 1, 60]))
        // Courtyard walls (open toward the camera).
        kit.slab([-10, 0, -10.4], [10, 4.5, -10], plaster)
        kit.slab([-10.4, 0, -10.4], [-10, 4.5, 4], plaster)
        kit.slab([10, 0, -10.4], [10.4, 3, 0], plaster)
        // Colonnade: a roof on eight columns.
        kit.slab([-9.6, 3.6, -6], [1, 3.9, -2.4], terracotta)
        for x: Float in stride(from: -9, through: 0.5, by: 1.35) { kit.box([x, 1.8, -2.7], [0.35, 3.6, 0.35], stone) }
        kit.slab([-9.6, 0, -6], [1, 0.12, -2.4], stone)
        // A room on the right: thick walls, a roof, two windows and a door toward the courtyard.
        let (x0, x1, z0, z1, h): (Float, Float, Float, Float, Float) = (3, 10, -10, -4, 3.4)
        kit.slab([x0, h, z0], [x1, h + 0.3, z1], terracotta)
        kit.slab([x0, 0, z0], [x0 + 0.3, h, z1], plaster)                          // left wall
        // Front wall (z1): pieces around a door (x 3.6-4.6) and two windows (x 5.4-6.8, 7.6-9.0, y 1-2.4).
        kit.slab([x0, 0, z1 - 0.3], [3.6, h, z1], plaster)
        kit.slab([3.6, 2.3, z1 - 0.3], [4.6, h, z1], plaster)
        kit.slab([4.6, 0, z1 - 0.3], [5.4, h, z1], plaster)
        kit.slab([6.8, 0, z1 - 0.3], [7.6, h, z1], plaster)
        kit.slab([9.0, 0, z1 - 0.3], [x1, h, z1], plaster)
        for (a, b) in [(Float(5.4), Float(6.8)), (7.6, 9.0)] {
            kit.slab([a, 0, z1 - 0.3], [b, 1.0, z1], plaster)
            kit.slab([a, 2.4, z1 - 0.3], [b, h, z1], plaster)
        }
        kit.box([6.5, 0.4, -8], [2, 0.8, 1], blue)                                   // furniture inside
        kit.ball([8.6, 0.5, -8.6], 0.5, plaster)
        // Courtyard: a fountain, planters, a few objects.
        kit.box([-3, 0.3, 0.5], [3, 0.6, 3], stone)
        kit.box([-3, 0.9, 0.5], [0.4, 1.2, 0.4], stone)
        kit.ball([-3, 1.7, 0.5], 0.4, stone)
        for x: Float in [-8, 7.5] {
            kit.box([x, 0.4, 2], [1, 0.8, 1], terracotta)
            kit.ball([x, 1.4, 2], 0.7, green)
        }
        kit.box([3.5, 0.5, 1.5], [1, 1, 1], blue, yaw: 0.6)
        kit.ball([1, 0.6, 3.5], 0.6, plaster)

        // The day: elevation 8 to 62 degrees and back, the azimuth swinging with it.
        let day: Float = 60
        func elevation(_ t: Float) -> Float { Scene.degrees(35 - 27 * cos(2 * .pi * (t + 12) / day)) }   // t = 0: mid-morning
        func warmth(_ t: Float) -> Float { simd_smoothstep(Scene.degrees(6), Scene.degrees(35), elevation(t)) }
        addLight(.sun(angularRadius: Scene.degrees(0.27)), color: [1, 1, 1]) { t in
            let e = elevation(t), az = -0.9 + 1.4 * sin(2 * .pi * (t + 12) / day)
            let tint = simd_mix(SIMD3<Float>(1.0, 0.5, 0.25) * 1.4, SIMD3<Float>(1.0, 0.95, 0.88) * 1.8, SIMD3(repeating: warmth(t)))
            return LightPose(position: .zero, direction: [cos(e) * sin(az), sin(e), cos(e) * cos(az)], scale: tint)
        }
        skyAnimation = { t in simd_mix(SIMD3<Float>(0.38, 0.28, 0.3) * 0.25, SIMD3<Float>(0.3, 0.45, 0.8) * 0.24,
                                       SIMD3(repeating: warmth(t))) }
        // Dust in the room, so the sun's shafts through its windows show.
        fogVolumes.append(FogVolume(shape: .box(halfExtents: [3.5, 1.7, 3]), center: [6.5, 1.7, -7], density: 0.08,
                                    edge: 0.3, noise: 0.5))
        defaultCamera = Scene.demoCamera(.sun)!
    }

    // MARK: - Area lights

    /// A studio: two softboxes (one orbiting), a long ceiling panel and a window-like panel light a roughness ramp
    /// of glossy spheres and a few metals on a dark glossy floor, which shows the rectangular highlights.
    func buildArea() {
        let kit = Kit(self)
        skyColor = [0.03, 0.03, 0.035]
        let floor = addPBRMaterial(baseColor: [0.12, 0.12, 0.13], metallic: 0, roughness: 0.15)
        let wall = addMaterial(albedo: [0.68, 0.68, 0.7])
        let white = addMaterial(albedo: [0.8, 0.8, 0.8])
        kit.room(width: 16, height: 6, depth: 14, floor: floor, walls: wall, ceiling: true)

        // A ramp of red dielectric spheres from mirror-smooth to rough, then metals.
        for (i, r) in [Float(0.05), 0.15, 0.3, 0.5, 0.8].enumerated() {
            kit.ball([-3.2 + 1.6 * Float(i), 0.55, -1.5], 0.55, addPBRMaterial(baseColor: [0.75, 0.1, 0.08], metallic: 0, roughness: r))
        }
        kit.ball([-1.6, 0.6, -4], 0.6, addPBRMaterial(baseColor: [1.0, 0.78, 0.35], metallic: 1, roughness: 0.2))
        kit.box([1.6, 0.6, -4], [1.2, 1.2, 1.2], addPBRMaterial(baseColor: [0.95, 0.95, 0.97], metallic: 1, roughness: 0.05), yaw: 0.6)
        kit.box([0, 0.15, -4.3], [1.2, 0.3, 1.2], white)
        kit.ball([0, 0.75, -4.3], 0.45, white)
        kit.box([-4.6, 1.0, -4.5], [0.6, 2, 0.6], white, yaw: 0.4)

        // Softboxes face the objects; the window panel sits on the back wall, the long panel on the ceiling.
        let target = SIMD3<Float>(0, 0.6, -2.6)
        let left = SIMD3<Float>(-4.5, 3.2, 1.2)
        addLight(.rect(width: 1.6, height: 1.2), color: SIMD3<Float>(1.0, 0.92, 0.82) * 7, motion: .constant) { _ in
            LightPose(position: left, direction: normalize(target - left))
        }
        addLight(.rect(width: 1.2, height: 1.2), color: SIMD3<Float>(0.85, 0.9, 1.0) * 6) { t in
            let a = 0.9 + 0.7 * sin(0.3 * t)
            let p = target + SIMD3<Float>(4.2 * sin(a), 2.0 + 0.6 * sin(0.5 * t), 4.2 * cos(a))
            return LightPose(position: p, direction: normalize(target - p))
        }
        addLight(.rect(width: 5, height: 0.5), color: SIMD3<Float>(1.0, 0.97, 0.92) * 6, motion: .constant) { _ in
            LightPose(position: [0, 5.97, -2.5], direction: [0, -1, 0], tangent: [1, 0, 0])
        }
        addLight(.rect(width: 3.2, height: 2.2), color: SIMD3<Float>(0.75, 0.85, 1.0) * 2.2, motion: .constant) { _ in
            LightPose(position: [3.5, 2.6, -6.97], direction: [0, 0, 1], tangent: [1, 0, 0])
        }
        defaultCamera = Scene.demoCamera(.area)!
    }

    // MARK: - Tube lights

    /// A garage: rows of fluorescent tubes on a low ceiling and neon tubes on the walls (one flickering) over a
    /// glossy concrete floor, where the tubes leave long streaky reflections; a parked "car" and pillars.
    func buildTubes() {
        let kit = Kit(self)
        skyColor = [0.01, 0.012, 0.02]
        let concrete = addPBRMaterial(baseColor: [0.36, 0.36, 0.35], metallic: 0, roughness: 0.22)
        let wall = addMaterial(albedo: [0.55, 0.56, 0.58])
        let paint = addPBRMaterial(baseColor: [0.55, 0.07, 0.06], metallic: 0, roughness: 0.25)
        let glass = addPBRMaterial(baseColor: [0.02, 0.02, 0.03], metallic: 0, roughness: 0.05)
        let tyre = addMaterial(albedo: [0.04, 0.04, 0.04])
        let yellow = addMaterial(albedo: [0.8, 0.65, 0.1])
        kit.room(width: 20, height: 3.4, depth: 16, floor: concrete, walls: wall, ceiling: true)
        for x: Float in [-5, 5] {
            for z: Float in [-5, 1] { kit.box([x, 1.7, z], [0.5, 3.4, 0.5], wall) }
        }
        // Parking lines.
        for x: Float in [-2.6, 2.6] { kit.slab([x - 0.06, 0, -6], [x + 0.06, 0.005, 0], yellow) }
        // The car.
        kit.box([0, 0.75, -3], [1.9, 0.7, 4.2], paint)
        kit.box([0, 1.35, -3.2], [1.7, 0.55, 2.2], glass)
        for (x, z) in [(Float(-0.9), Float(-1.6)), (0.9, -1.6), (-0.9, -4.4), (0.9, -4.4)] {
            addInstance(kit.sphere, tyre, translate([x, 0.36, z]) * rotate(.pi / 2, [0, 0, 1]) * scale([0.36, 0.15, 0.36]))
        }
        kit.box([-7, 0.5, -6.5], [1.2, 1, 1.6], wall, yaw: 0.2)

        // Fluorescent tubes: three rows of two along X, just below the ceiling.
        for z: Float in [-5, -2, 1] {
            for x: Float in [-3.2, 3.2] {
                addLight(.tube(length: 1.5, radius: 0.025), color: SIMD3<Float>(0.95, 0.97, 1.0) * 2.2, motion: .constant) { _ in
                    LightPose(position: [x, 3.3, z], direction: [1, 0, 0])
                }
            }
        }
        // Neon: pink along the back wall, a cyan upright on the left (flickering), an amber one on the right.
        addLight(.tube(length: 4, radius: 0.03), color: Scene.hue([1.0, 0.2, 0.6]) * 2.5, motion: .constant) { _ in
            LightPose(position: [0, 2.5, -7.9], direction: [1, 0, 0])
        }
        addLight(.tube(length: 2, radius: 0.03), color: Scene.hue([0.15, 0.9, 1.0]) * 2, motion: .scaleOnly) { t in
            // Mostly on, with bursts of quick dropouts.
            let k = Float(Int(t * 12) &* 7919 % 101) / 101
            let burst = sin(0.9 * t) > 0.6
            return LightPose(position: [-9.9, 1.6, -2], direction: [0, 1, 0], scale: SIMD3(repeating: burst && k < 0.45 ? 0.08 : 1))
        }
        addLight(.tube(length: 3, radius: 0.03), color: Scene.hue([1.0, 0.55, 0.1]) * 2) { t in
            LightPose(position: [9.9, 2.2, -3], direction: [0, 0.15 * sin(0.4 * t), 1])
        }
        // Low mist over the floor (the box reaches below it, so its soft edge doesn't thin the mist at the floor).
        fogVolumes.append(FogVolume(shape: .box(halfExtents: [10, 1, 8]), center: [0, 0.5, 0], density: 0.9,
                                    edge: 0.5, noise: 0.9, heightFalloff: 2.2))
        defaultCamera = Scene.demoCamera(.tubes)!
    }

    // MARK: - Emissive meshes

    /// A dark room lit only by emissive geometry: neon "GI" letters on the back wall, a glowing orb, a screen and a
    /// spinning ring of coloured cubes that throws moving shadows of the objects in the middle.
    func buildEmissive() {
        let kit = Kit(self)
        skyColor = [0.005, 0.005, 0.01]
        let floor = addPBRMaterial(baseColor: [0.16, 0.16, 0.17], metallic: 0, roughness: 0.25)
        let wall = addMaterial(albedo: [0.5, 0.5, 0.52])
        let white = addMaterial(albedo: [0.8, 0.8, 0.8])
        let steel = addPBRMaterial(baseColor: [0.8, 0.8, 0.82], metallic: 1, roughness: 0.3)
        kit.room(width: 16, height: 5, depth: 14, floor: floor, walls: wall, ceiling: true)

        // "GI" in neon bars, 1.2 m tall, on the back wall.
        let pink = addMaterial(albedo: .zero, emission: Scene.hue([1.0, 0.15, 0.55]) * 6)
        let cyan = addMaterial(albedo: .zero, emission: Scene.hue([0.1, 0.85, 1.0]) * 6)
        let (z, t): (Float, Float) = (-6.9, 0.08)
        let g: [(SIMD3<Float>, SIMD3<Float>)] = [([-2.2, 2.0, z], [0.8, t, t]), ([-2.6, 2.6, z], [t, 1.2, t]),
                                                 ([-2.2, 3.2, z], [0.8, t, t]), ([-1.8, 2.3, z], [t, 0.6, t]),
                                                 ([-1.95, 2.6, z], [0.35, t, t])]
        for (c, s) in g { kit.box(c, s, pink) }
        kit.box([-0.6, 2.6, z], [t, 1.2, t], cyan)
        kit.box([-0.6, 3.2, z], [0.5, t, t], cyan)
        kit.box([-0.6, 2.0, z], [0.5, t, t], cyan)

        // A warm orb on a plinth, and a cool screen on the right wall.
        kit.box([-5, 0.5, -3], [0.8, 1, 0.8], white)
        kit.ball([-5, 1.45, -3], 0.4, addMaterial(albedo: .zero, emission: [1.0, 0.55, 0.2] * 5))
        fogVolumes.append(FogVolume(shape: .sphere(radius: 1.8), center: [-5, 1.45, -3], density: 0.15, edge: 1, noise: 0.8))
        addInstance(kit.quad, addMaterial(albedo: .zero, emission: [0.55, 0.7, 1.0] * 2.5),
                    translate([7.95, 2.2, -2.5]) * rotate(.pi / 2, [0, 0, 1]) * scale([1.8, 1, 3.2]))

        // Objects in the middle, and a ring of emissive cubes spinning around them.
        kit.box([0, 0.9, -2.5], [0.6, 1.8, 0.6], white, yaw: 0.4)
        kit.ball([1.2, 0.5, -1.5], 0.5, steel)
        kit.box([-1.3, 0.4, -1.2], [0.8, 0.8, 0.8], white, yaw: 0.9)
        kit.ball([0.8, 0.35, -3.8], 0.35, white)
        let ringColors: [SIMD3<Float>] = [[1, 0.2, 0.15], [1, 0.6, 0.1], [0.9, 1, 0.2], [0.2, 1, 0.3],
                                          [0.1, 0.9, 1], [0.2, 0.35, 1], [0.7, 0.2, 1], [1, 0.2, 0.7]]
        for (i, c) in ringColors.enumerated() {
            let m = addMaterial(albedo: .zero, emission: Scene.hue(c) * 4)
            let phase = 2 * Float.pi * Float(i) / Float(ringColors.count)
            addInstance(kit.cube, m, matrix_identity_float4x4) { t in
                let a = phase + 0.35 * t
                return translate([2.6 * cos(a), 1.3 + 0.35 * sin(2 * a + t), -2.5 + 2.6 * sin(a)]) * rotate(t + phase, [1, 1, 0]) * scale(0.22)
            }
        }
        defaultCamera = Scene.demoCamera(.emissive)!
    }

    // MARK: - Misty hall

    /// A long stone hall in fog: a low sun beyond the far wall shines in through its three tall mullioned windows,
    /// straight down the hall toward the camera, cutting shafts through the fog onto the floor (and thin ones through
    /// the side windows), swinging slowly; a searchlight high on the left wall sweeps the right half of the hall; mist
    /// pools over the floor around a lantern; a glowing orb sits in a cloud of its own.
    func buildFogHall() {
        let kit = Kit(self)
        skyColor = [0.12, 0.13, 0.16]
        let floor = addPBRMaterial(baseColor: [0.32, 0.31, 0.3], metallic: 0, roughness: 0.18)   // polished stone
        let stone = addMaterial(albedo: [0.62, 0.58, 0.52])
        let dark = addMaterial(albedo: [0.25, 0.23, 0.21])
        let wood = addMaterial(albedo: [0.4, 0.26, 0.15])
        let bronze = addPBRMaterial(baseColor: [0.85, 0.6, 0.35], metallic: 1, roughness: 0.3)
        let (x0, x1, z0, z1, h): (Float, Float, Float, Float, Float) = (-6, 6, -24, 4, 9)
        addInstance(kit.quad, floor, translate([0, 0, (z0 + z1) / 2]) * scale([x1 - x0, 1, z1 - z0]))
        kit.slab([x0 - 0.4, h, z0 - 0.4], [x1 + 0.3, h + 0.3, z1 + 0.3], stone)   // ceiling
        kit.slab([x0, 0, z1], [x1, h, z1 + 0.3], stone)                           // wall behind the camera
        kit.slab([x1, 0, z0], [x1 + 0.3, h, z1], stone)                           // right wall
        /// A wall with window openings: `openings` = (low, high) along the wall's axis, sills at y 2.5 ... 8; each
        /// opening gets a mullion and a transom. `wall(lo, hi)` places a slab spanning [lo, hi] along that axis.
        func windowWall(_ from: Float, _ to: Float, openings: [(Float, Float)], wall: (Float, Float, Float, Float) -> Void,
                        bar: (Float, Float, Float, Float) -> Void) {
            wall(from, to, 0, 2.5)
            wall(from, to, 8, h)
            var at = from
            for (a, b) in openings {
                wall(at, a, 2.5, 8)
                bar((a + b) / 2 - 0.06, (a + b) / 2 + 0.06, 2.5, 8)    // mullion
                bar(a, b, 5.6, 5.72)                                 // transom
                at = b
            }
            wall(at, to, 2.5, 8)
        }
        // Far wall (z0): three tall windows.
        windowWall(x0 - 0.4, x1 + 0.3, openings: [(-3.6, -1.8), (-0.9, 0.9), (1.8, 3.6)],
                   wall: { a, b, y0, y1 in kit.slab([a, y0, z0 - 0.4], [b, y1, z0], stone) },
                   bar: { a, b, y0, y1 in kit.slab([a, y0, z0 - 0.3], [b, y1, z0 - 0.1], dark) })
        // Left wall (x0): five windows.
        windowWall(z0, z1, openings: [-20, -15, -10, -5, 0].map { ($0 - 0.8, $0 + 0.8) },
                   wall: { a, b, y0, y1 in kit.slab([x0 - 0.4, y0, a], [x0, y1, b], stone) },
                   bar: { a, b, y0, y1 in kit.slab([x0 - 0.3, y0, a], [x0 - 0.1, y1, b], dark) })
        // Columns along both sides, a balcony on the right, benches and a statue.
        for cz: Float in [-22, -17, -12, -7, -2] {
            for cx: Float in [-4.6, 4.6] { kit.box([cx, h / 2, cz], [0.7, h, 0.7], stone) }
        }
        kit.slab([4.95, 4.0, -20], [x1, 4.25, -8], stone)
        kit.slab([4.95, 4.25, -20], [5.05, 4.7, -8], dark)                      // its railing
        for bz: Float in [-4.5, -9.5] {
            kit.box([-1.6, 0.25, bz], [0.5, 0.5, 2.4], wood)
            kit.box([1.6, 0.25, bz], [0.5, 0.5, 2.4], wood)
        }
        kit.box([0, 0.5, -13], [1.4, 1, 1.4], stone)
        kit.box([0, 1.6, -13], [0.5, 1.2, 0.5], bronze, yaw: 0.4)
        kit.ball([0, 2.55, -13], 0.35, bronze)
        // The far end: a low dais with a glowing orb in its own cloud.
        kit.slab([x0, 0, z0], [x1, 0.3, -21.5], stone)
        kit.box([3.4, 0.8, -20.5], [0.6, 1, 0.6], stone)
        kit.ball([3.4, 1.7, -20.5], 0.4, addMaterial(albedo: .zero, emission: [1.0, 0.6, 0.3] * 6))

        // The low sun beyond the far wall, a little to the left, swinging +-10 degrees.
        let e = Scene.degrees(24)
        addLight(.sun(angularRadius: Scene.degrees(0.27)), color: SIMD3<Float>(1.0, 0.88, 0.72) * 5) { t in
            let a = Scene.degrees(-14 + 10 * sin(0.12 * t))
            return LightPose(position: .zero, direction: [cos(e) * sin(a), sin(e), -cos(e) * cos(a)])
        }
        // A searchlight high on the left wall, between two columns, sweeping the right half of the hall.
        let searchlight = SIMD3<Float>(-3.9, 7.3, -14.5)
        kit.box(searchlight + [-0.45, 0.1, 0], [0.5, 0.4, 0.4], dark)
        kit.slab([-5.4, 7.1, -14.6], [-4.6, 7.2, -14.4], dark)                   // its bracket
        addLight(.spot(radius: 0.15, inner: Scene.degrees(4), outer: Scene.degrees(7)), color: SIMD3<Float>(0.8, 0.9, 1.0) * 450) { t in
            let target = SIMD3<Float>(2.2 + 1.6 * sin(0.33 * t), 0, -6 + 3 * sin(0.21 * t + 1))
            return LightPose(position: searchlight, direction: normalize(target - searchlight))
        }
        // A lantern in the mist, bobbing a little.
        addLight(.sphere(radius: 0.08), color: SIMD3<Float>(1.0, 0.6, 0.25) * 5) { t in
            LightPose(position: [-3, 1.0 + 0.1 * sin(0.8 * t), -17])
        }
        fogVolumes.append(FogVolume(shape: .box(halfExtents: [6, 1.2, 5]), center: [0, 0.4, -17], density: 0.6,
                                    edge: 0.8, noise: 0.9, heightFalloff: 2))
        fogVolumes.append(FogVolume(shape: .sphere(radius: 2), center: [3.4, 1.7, -20.5], density: 0.12,
                                    albedo: [1.0, 0.9, 0.8], edge: 1.2, noise: 0.8))
        defaultCamera = Scene.demoCamera(.fog)!
    }

    // MARK: - Open valley

    /// An open valley under the sky (the atmosphere and clouds preset): fields, a road and a small village with a
    /// church tower, trees and fences, hills around, and a day cycle from morning to evening and back (90 s each
    /// way; the sun stays 10 degrees or more above the horizon, as the exposure is fixed). Low, small clouds drift
    /// over it, so their shadows cross the fields.
    func buildValley() {
        let kit = Kit(self)
        let grass = addMaterial(albedo: [0.22, 0.36, 0.13])
        let wheat = addMaterial(albedo: [0.62, 0.52, 0.24])
        let meadow = addMaterial(albedo: [0.3, 0.42, 0.16])
        let road = addMaterial(albedo: [0.32, 0.3, 0.28])
        let wall = addMaterial(albedo: [0.78, 0.74, 0.66])
        let roof = addMaterial(albedo: [0.55, 0.2, 0.12])
        let slate = addMaterial(albedo: [0.25, 0.26, 0.3])
        let hill = addMaterial(albedo: [0.24, 0.34, 0.15])
        let wood = addMaterial(albedo: [0.45, 0.33, 0.2])
        let pond = addPBRMaterial(baseColor: [0.03, 0.05, 0.06], metallic: 0, roughness: 0.04)

        addInstance(kit.quad, grass, scale([400, 1, 400]))
        // Fields and the road.
        for (lo, hi, m) in [(SIMD3<Float>(-90, 0, -60), SIMD3<Float>(-20, 0.02, 10), wheat),
                            (SIMD3<Float>(25, 0, -80), SIMD3<Float>(110, 0.02, -15), wheat),
                            (SIMD3<Float>(25, 0, 5), SIMD3<Float>(90, 0.02, 60), meadow)] as [(SIMD3<Float>, SIMD3<Float>, Int)] {
            kit.slab(lo, hi, m)
        }
        kit.slab([-200, 0, -3], [200, 0.04, 3], road)
        kit.slab([-3, 0, -200], [3, 0.04, -3], road)
        kit.slab([-40, 0, 18], [-22, 0.05, 30], pond)
        // Hills on three sides (flattened spheres sunk into the ground).
        for (c, sz) in [(SIMD3<Float>(-150, -20, -170), SIMD3<Float>(140, 70, 70)), (SIMD3<Float>(60, -25, -190), SIMD3<Float>(170, 80, 60)),
                        (SIMD3<Float>(190, -15, -40), SIMD3<Float>(60, 55, 140)), (SIMD3<Float>(-190, -18, 20), SIMD3<Float>(50, 50, 120))] {
            addInstance(kit.sphere, hill, translate(c) * scale(sz))
        }
        // The village around the crossroads: houses with pitched roofs, and a church with a tower.
        func house(_ x: Float, _ z: Float, _ yaw: Float, _ w: Float = 6, _ d: Float = 8, _ h: Float = 4) {
            let t = translate([x, 0, z]) * rotate(yaw, [0, 1, 0])
            addInstance(kit.cube, wall, t * translate([0, h / 2, 0]) * scale([w, h, d]))
            for side: Float in [-1, 1] {   // two roof planes meeting at the ridge
                addInstance(kit.cube, roof, t * translate([side * w / 4, h + w / 4 * 0.75, 0]) * rotate(side * -0.64, [0, 0, 1])
                            * scale([w * 0.62, 0.25, d + 0.6]))
            }
        }
        for (x, z, yaw) in [(Float(-12), Float(-12), Float(0)), (-24, -14, 0.1), (-13, 12, 0), (12, -13, 0.05), (24, -12, -0.1),
                            (13, 13, 0), (-36, -11, 0.2), (36, 12, -0.15)] {
            house(x, z, yaw)
        }
        addInstance(kit.cube, wall, translate([-8, 4, -36]) * scale([10, 8, 18]))                    // church
        addInstance(kit.cube, slate, translate([-8, 9.2, -36]) * rotate(.pi / 4, [0, 0, 1]) * scale([7.4, 7.4, 18.4]))
        addInstance(kit.cube, wall, translate([-8, 10, -24]) * scale([5, 20, 5]))                    // tower
        addInstance(kit.cube, slate, translate([-8, 22, -24]) * rotate(.pi / 4, [0, 1, 0]) * scale([3.2, 4, 3.2]))
        // Trees (Foliage): young oaks and birches along the road, grown trees in a copse and alone in the fields.
        let flora = Flora(self, seed: UInt64(max(settings.seed, 0)), catalog: PlantCatalog.resolve(settings.plantCatalog),
                          species: [.oak, .birch, .conifer])
        var pick = SplitMix64(seed: 0x7EE5 &+ UInt64(max(settings.seed, 0)))
        func tree(_ x: Float, _ z: Float, _ species: Foliage.Species, _ age: Foliage.Age, _ size: Float) {
            let plants = flora.plants(species, age)
            flora.place(species, plants[pick.int(plants.count)], at: [x, -0.1, z], yaw: pick.range(0, 2 * .pi), size: size,
                        shade: pick.int(16))
        }
        for i in 0..<8 { tree(-60 + Float(i) * 14, 6, i % 2 == 0 ? .oak : .birch, .young, 0.75 + 0.08 * Float(i % 3)) }
        for (i, (x, z)) in [(Float(55), Float(-30)), (60, -24), (66, -32), (58, -38), (70, -26), (-60, 40), (80, 30), (-110, -20)].enumerated() {
            tree(x, z, [.oak, .conifer, .birch, .oak][i % 4], .mature, 0.6)
        }
        // A fence along the meadow, close to the camera.
        for i in 0..<16 { kit.box([10 + Float(i) * 2.5, 0.6, 22], [0.12, 1.2, 0.12], wood) }
        kit.box([28.75, 0.9, 22], [37.5, 0.08, 0.08], wood)
        kit.box([28.75, 0.5, 22], [37.5, 0.08, 0.08], wood)

        addDaySun(half: 90)
        defaultCamera = Scene.demoCamera(.valley)!
    }

    /// The valley's and the forest's sun: morning in the east (+x) to evening in the west (-x), passing ahead of the
    /// camera (-z), and back, `half` seconds each way; t = 0 is mid-morning. Its colour comes from the atmosphere.
    func addDaySun(half: Float) {
        addLight(.sun(angularRadius: Scene.degrees(0.27)), color: [1, 1, 1]) { t in
            let phase = 0.5 - 0.5 * cos(.pi * (t / half + 0.35))   // 0 = morning, 1 = evening
            let e = Scene.degrees(10 + 50 * sin(.pi * phase)), a = Scene.degrees(20 + 140 * phase)
            return LightPose(position: .zero, direction: [cos(e) * cos(a), sin(e), -cos(e) * sin(a)])
        }
    }

    // MARK: - Mixed

    /// A living room at dusk with every light type: a low sun through the window, a ceiling panel, a desk spot
    /// lamp, a tube under a shelf, a TV (emissive mesh) and a sphere-light floor lamp.
    func buildMixed() {
        let kit = Kit(self)
        let floor = addPBRMaterial(baseColor: [0.42, 0.28, 0.17], metallic: 0, roughness: 0.35)   // wood
        let wall = addMaterial(albedo: [0.78, 0.74, 0.68])
        let fabric = addMaterial(albedo: [0.2, 0.32, 0.45])
        let wood = addMaterial(albedo: [0.45, 0.3, 0.18])
        let white = addMaterial(albedo: [0.82, 0.82, 0.82])
        let rug = addMaterial(albedo: [0.6, 0.18, 0.12])
        let black = addPBRMaterial(baseColor: [0.03, 0.03, 0.03], metallic: 0, roughness: 0.2)
        let ground = addMaterial(albedo: [0.35, 0.33, 0.3])
        let (w, h, d): (Float, Float, Float) = (10, 3.2, 8)
        addInstance(kit.quad, ground, translate([0, -0.01, 0]) * scale([60, 1, 60]))
        addInstance(kit.quad, floor, scale([w, 1, d]))
        addInstance(kit.quad, wall, translate([0, h, 0]) * rotate(.pi, [1, 0, 0]) * scale([w, 1, d]))
        kit.slab([-w / 2, 0, -d / 2 - 0.2], [w / 2, h, -d / 2], wall)            // back
        kit.slab([w / 2, 0, -d / 2], [w / 2 + 0.2, h, d / 2], wall)              // right
        // Left wall with a big window (z -2.5 ... 1, y 0.8 ... 2.5).
        let x = -w / 2 - 0.2
        kit.slab([x, 0, -d / 2], [-w / 2, h, -2.5], wall)
        kit.slab([x, 0, 1], [-w / 2, h, d / 2], wall)
        kit.slab([x, 0, -2.5], [-w / 2, 0.8, 1], wall)
        kit.slab([x, 2.5, -2.5], [-w / 2, h, 1], wall)

        // Furniture.
        kit.slab([1.0, 0, -1.6], [4.4, 0.01, 1.2], rug)
        kit.slab([1.6, 0, -1.3], [2.4, 0.45, 0.9], fabric)                          // sofa facing the TV
        kit.slab([1.3, 0, -1.3], [1.6, 1.0, 0.9], fabric)
        kit.slab([3.0, 0, -0.7], [3.8, 0.4, 0.3], wood)                             // coffee table
        kit.ball([3.4, 0.55, -0.2], 0.15, white)
        kit.slab([2.6, 0.75, -3.9], [4.8, 0.8, -2.9], wood)                         // desk
        for (a, b) in [(Float(2.65), Float(-3.85)), (4.7, -3.85), (2.65, -2.95), (4.7, -2.95)] {
            kit.slab([a - 0.04, 0, b - 0.04], [a + 0.04, 0.75, b + 0.04], wood)
        }
        kit.box([3.2, 0.95, -3.5], [0.4, 0.3, 0.3], white, yaw: 0.3)
        kit.slab([-1.8, 1.9, -4.0], [1.2, 1.95, -3.7], wood)                        // shelf
        for i in 0..<6 { kit.box([-1.5 + 0.45 * Float(i), 2.12, -3.85], [0.12, 0.35 + 0.05 * Float(i % 3), 0.22], i % 2 == 0 ? fabric : rug) }
        // TV on the right wall: a black frame and an emissive screen (an emissive-mesh light).
        kit.slab([4.9, 1.0, -1.2], [5.0, 2.1, 0.8], black)
        addInstance(kit.quad, addMaterial(albedo: .zero, emission: [0.5, 0.65, 1.0] * 1.2),
                    translate([4.89, 1.55, -0.2]) * rotate(.pi / 2, [0, 0, 1]) * scale([1.0, 1, 1.9]))

        // The lights.
        addLight(.sun(angularRadius: Scene.degrees(0.27)), color: SIMD3<Float>(1.0, 0.55, 0.3) * 3.5) { t in
            let e = Scene.degrees(11 + 2 * sin(0.1 * t)), az = Scene.degrees(-100 + 6 * sin(0.07 * t))
            return LightPose(position: .zero, direction: [cos(e) * sin(az), sin(e), cos(e) * cos(az)])
        }
        skyColor = SIMD3<Float>(0.35, 0.3, 0.45) * 0.3
        addLight(.rect(width: 1.2, height: 0.6), color: SIMD3<Float>(1.0, 0.85, 0.65) * 4, motion: .constant) { _ in
            LightPose(position: [0, h - 0.02, 0], direction: [0, -1, 0], tangent: [1, 0, 0])
        }
        let lamp = SIMD3<Float>(4.4, 1.35, -3.6)
        kit.box(lamp + [0, 0.1, 0], [0.18, 0.12, 0.18], black)
        kit.slab([4.38, 0.8, -3.62], [4.42, 1.3, -3.58], black)
        addLight(.spot(radius: 0.03, inner: Scene.degrees(18), outer: Scene.degrees(32)), color: SIMD3<Float>(1.0, 0.85, 0.6) * 4) { t in
            let target = SIMD3<Float>(3.5 + 0.4 * sin(0.3 * t), 0.8, -3.3)
            return LightPose(position: lamp, direction: normalize(target - lamp))
        }
        addLight(.tube(length: 2.4, radius: 0.02), color: SIMD3<Float>(0.8, 0.9, 1.0) * 1.2, motion: .constant) { _ in
            LightPose(position: [-0.3, 1.86, -3.8], direction: [1, 0, 0])
        }
        kit.slab([-3.82, 0, -3.22], [-3.78, 1.55, -3.18], black)                    // floor lamp stand
        addLight(.sphere(radius: 0.12), color: SIMD3<Float>(1.0, 0.7, 0.4) * 3, motion: .constant) { _ in LightPose(position: [-3.8, 1.7, -3.2]) }
        defaultCamera = Scene.demoCamera(.mixed)!
    }

    // MARK: - Night market

    /// A street market at night, for many lights (ReSTIR DI): 32 festoon strings strung across a 64 m street carry
    /// `settings.lights` small bulbs between them (4096 by default, up to 16384; a quarter of the strings chase), with
    /// 80 swaying paper lanterns, 40 lit canopies over the stalls, about 120 lit windows (some flickering), 24 neon signs
    /// (emissive meshes, sampled per triangle) and the moon; 60 shoppers walk up and down the street.
    func buildMarket() {
        let kit = Kit(self)
        var rng = SplitMix64(seed: 0x0BA2_AA2E)
        skyColor = [0.006, 0.009, 0.02]
        let cobbles = addPBRMaterial(baseColor: [0.2, 0.19, 0.18], metallic: 0, roughness: 0.35)   // damp stone
        let plaster = [[0.62, 0.55, 0.46], [0.5, 0.42, 0.36], [0.58, 0.6, 0.62], [0.45, 0.32, 0.26], [0.66, 0.62, 0.52]]
            .map { addMaterial(albedo: SIMD3<Float>($0.map(Float.init))) }
        let wood = addMaterial(albedo: [0.36, 0.24, 0.14])
        let cloth = [[0.7, 0.18, 0.12], [0.85, 0.75, 0.6], [0.2, 0.35, 0.6], [0.25, 0.5, 0.3], [0.8, 0.55, 0.15]]
            .map { addMaterial(albedo: SIMD3<Float>($0.map(Float.init))) }
        let coat = [[0.2, 0.2, 0.25], [0.45, 0.3, 0.2], [0.15, 0.25, 0.4], [0.5, 0.15, 0.15], [0.35, 0.35, 0.3]]
            .map { addMaterial(albedo: SIMD3<Float>($0.map(Float.init))) }
        let wire = addMaterial(albedo: [0.05, 0.05, 0.05])
        let (halfWidth, halfLength): (Float, Float) = (5, 32)

        addInstance(kit.quad, cobbles, scale([2 * halfWidth + 6, 1, 2 * halfLength + 10]))
        // Facades: eight buildings a side, 6-12 m tall, each with a grid of lit windows (rect lights facing the street).
        let warmWindow: [SIMD3<Float>] = [[1.0, 0.72, 0.4], [1.0, 0.82, 0.55], [0.9, 0.9, 1.0]]
        for side: Float in [-1, 1] {
            for b in 0..<8 {
                let z0 = -halfLength + Float(b) * 8, height = rng.range(6, 12)
                kit.slab([side < 0 ? -halfWidth - 3 : halfWidth, 0, z0], [side < 0 ? -halfWidth : halfWidth + 3, height, z0 + 8],
                         plaster[rng.int(plaster.count)])
                for floorY in stride(from: Float(3.4), to: height - 1, by: 2.8) {
                    for w in 0..<3 where rng.next() < 0.6 {
                        let z = z0 + 1.6 + Float(w) * 2.4
                        let c = warmWindow[rng.int(warmWindow.count)] * rng.range(0.25, 0.7)
                        let flicker = rng.next() < 0.15, phase = rng.range(0, 6.28)
                        addLight(.rect(width: 1.0, height: 1.3), color: c, motion: flicker ? .scaleOnly : .constant) { t in
                            LightPose(position: [side * (halfWidth - 0.01), floorY, z], direction: [-side, 0, 0], tangent: [0, 0, 1],
                                      scale: SIMD3(repeating: flicker ? 0.75 + 0.25 * sin(7 * t + phase) * sin(3.1 * t) : 1))
                        }
                    }
                }
            }
        }
        // Stalls along both sides: a counter, posts and a tilted canopy with a warm panel under it.
        for side: Float in [-1, 1] {
            for k in 0..<20 {
                let z = -halfLength + 2 + Float(k) * 3.1, x = side * 3.7
                kit.box([x, 0.5, z], [1.0, 1.0, 2.2], wood)
                for dz: Float in [-1.05, 1.05] {
                    kit.box([x - side * 0.45, 1.25, z + dz], [0.06, 2.5, 0.06], wood)
                    kit.box([x + side * 0.45, 1.05, z + dz], [0.06, 2.1, 0.06], wood)
                }
                addInstance(kit.cube, cloth[rng.int(cloth.count)],
                            translate([x, 2.35, z]) * rotate(side * 0.2, [0, 0, 1]) * scale([1.4, 0.04, 2.4]))
                addLight(.rect(width: 1.1, height: 1.8), color: SIMD3<Float>(1.0, 0.78, 0.5) * rng.range(0.5, 1.0), motion: .constant) { _ in
                    LightPose(position: [x, 2.28, z], direction: [0, -1, 0], tangent: [0, 0, 1])
                }
                // Goods on the counter.
                for _ in 0..<3 { kit.box([x + rng.range(-0.3, 0.3), 1.1, z + rng.range(-0.9, 0.9)], SIMD3(repeating: rng.range(0.12, 0.25)),
                                         cloth[rng.int(cloth.count)], yaw: rng.range(0, 3)) }
            }
        }
        // Festoon strings across the street: a sagging wire between the facades and the bulbs along it.
        let strings = 32
        let perString = max(1, settings.lights / strings)
        let bulbPower: Float = 24 / Float(strings * perString)   // the strings' total intensity doesn't depend on the count
        let palette: [SIMD3<Float>] = [[1.0, 0.15, 0.1], [0.15, 1.0, 0.25], [0.2, 0.35, 1.0], [1.0, 0.6, 0.1]]
        let bulbRadius: Float = perString > 128 ? 0.025 : 0.04
        for i in 0..<strings {
            let z = -halfLength + 1 + Float(i) * (2 * halfLength - 2) / Float(strings - 1)
            let y0 = rng.range(5.0, 6.2), sag = rng.range(0.5, 1.0), skew = rng.range(-1.5, 1.5)
            let chase = i % 4 == 1
            func point(_ s: Float) -> SIMD3<Float> {   // s in [0, 1] across the street
                SIMD3(-halfWidth + 2 * halfWidth * s, y0 - 4 * sag * s * (1 - s), z + skew * (s - 0.5))
            }
            for seg in 0..<8 {   // the wire, as 8 thin boxes
                let a = point(Float(seg) / 8), b = point(Float(seg + 1) / 8), d = b - a
                addInstance(kit.cube, wire, translate((a + b) / 2) * float4x4(simd_quatf(from: [1, 0, 0], to: normalize(d)))
                                                * scale([length(d), 0.012, 0.012]))
            }
            for j in 0..<perString {
                let s = (Float(j) + 0.5) / Float(perString)
                let p = point(s) - [0, 0.06, 0]
                let color = (rng.next() < 0.6 ? Scene.hue([1.0, 0.72, 0.42]) : Scene.hue(palette[rng.int(palette.count)])) * bulbPower
                let phase = Float(j) * 0.35
                addLight(.sphere(radius: bulbRadius), color: color, proxyMesh: kit.sphere, motion: chase ? .scaleOnly : .constant) { t in
                    LightPose(position: p, scale: SIMD3(repeating: chase ? 0.55 + 0.45 * max(0, sin(3 * t - phase)) : 1))
                }
            }
        }
        // Paper lanterns over the stalls, swaying.
        for k in 0..<80 {
            let side: Float = k % 2 == 0 ? -1 : 1
            let anchor = SIMD3<Float>(side * rng.range(2.6, 4.4), rng.range(2.7, 3.3), -halfLength + 1.5 + Float(k / 2) * 1.55)
            let phase = rng.range(0, 6.28), speed = rng.range(0.8, 1.4)
            let color = Scene.hue(rng.next() < 0.7 ? [1.0, 0.25, 0.08] : [1.0, 0.55, 0.15]) * 0.12
            addLight(.sphere(radius: 0.14), color: color) { t in
                let a = 0.12 * sin(speed * t + phase)
                return LightPose(position: anchor + [0.5 * sin(a), -0.5 * (1 - cos(a)), 0.3 * sin(0.7 * speed * t + phase)])
            }
        }
        // Neon signs on the facades: three tubes each (emissive capsules, sampled per triangle as mesh lights).
        let tube = addMesh(Scene.capsuleMesh(halfLength: 0.45, radius: 0.035, segments: 10, rings: 3))
        let neon: [SIMD3<Float>] = [[1.0, 0.1, 0.5], [0.1, 0.8, 1.0], [0.3, 1.0, 0.2], [1.0, 0.45, 0.05], [0.7, 0.2, 1.0]]
        for k in 0..<24 {
            let side: Float = k % 2 == 0 ? -1 : 1
            let center = SIMD3<Float>(side * (halfWidth - 0.08), rng.range(3.6, 4.8), -halfLength + 2.5 + Float(k / 2) * 5.2)
            let m = addMaterial(albedo: .zero, emission: Scene.hue(neon[rng.int(neon.count)]) * 3)
            for (offset, angle) in [(SIMD3<Float>(0, 0.35, 0), Float.pi / 2), (SIMD3<Float>(0, -0.35, 0), Float.pi / 2), (SIMD3<Float>(0, 0, -0.5), 0)] {
                addInstance(tube, m, translate(center + offset) * rotate(angle, [1, 0, 0]))
            }
        }
        // Shoppers: capsules walking up and down the street (moving occluders).
        let body = addMesh(Scene.capsuleMesh(halfLength: 0.55, radius: 0.24, segments: 12, rings: 3))
        for _ in 0..<60 {
            let x = rng.range(-2.4, 2.4), z0 = rng.range(-halfLength, halfLength), speed = rng.range(0.6, 1.4) * (rng.next() < 0.5 ? -1 : 1)
            let m = coat[rng.int(coat.count)]
            addInstance(body, m, matrix_identity_float4x4) { t in
                var z = z0 + speed * t
                z = (z + halfLength).truncatingRemainder(dividingBy: 2 * halfLength)
                if z < 0 { z += 2 * halfLength }
                return translate([x, 0.8, z - halfLength])
            }
        }
        // The moon.
        addLight(.sun(angularRadius: 0.0045), color: [0.035, 0.045, 0.07]) { _ in
            LightPose(position: .zero, direction: normalize([0.3, 0.8, -0.5]))
        }
        defaultCamera = Scene.demoCamera(.market)!
    }
}
