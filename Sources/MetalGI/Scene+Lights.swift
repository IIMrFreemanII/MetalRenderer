import Foundation
import simd

/// Demo scenes for the light types: one per type (spot, sun, rect, tube, emissive mesh) and one with all of them.
/// Procedural geometry only, so they load at once; every light moves, sweeps or flickers.
extension Scene {
    /// Shared meshes and a box helper for the builders below.
    private struct Kit {
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

    private static func camera(_ position: SIMD3<Float>, yaw: Float = 0, pitch: Float) -> Camera {
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
        case .cornell, .stress, .gallery: return nil
        }
    }

    private static func degrees(_ d: Float) -> Float { d * .pi / 180 }

    /// Unit-luminance colour.
    private static func hue(_ c: SIMD3<Float>) -> SIMD3<Float> { c / dot(c, [0.2126, 0.7152, 0.0722]) }

    // MARK: - Light check

    /// Benchmark scene (METALGI_BENCH=lightcheck): a floor, a box, and one light — "rect", "tube" or "sphere" — or,
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
                addLight(.rect(width: 1.2, height: 0.6), color: radiance) { _ in pose }
            }
        case "tube":
            let intensity = SIMD3<Float>(3, 3, 3), length: Float = 1.6, r: Float = 0.05
            let axis = normalize(SIMD3<Float>(0.3, 0.2, 1))
            if mesh {
                addInstance(addMesh(Scene.capsuleMesh(halfLength: length / 2, radius: r)),
                            addMaterial(albedo: .zero, emission: 2 * intensity / (.pi * r * length)),
                            translate(center) * Scene.alignY(axis))
            } else {
                addLight(.tube(length: length, radius: r), color: intensity) { _ in LightPose(position: center, direction: axis) }
            }
        case "empty":
            break
        default:   // sphere
            let intensity = SIMD3<Float>(3, 3, 3), r: Float = 0.25
            if mesh {
                addInstance(kit.sphere, addMaterial(albedo: .zero, emission: intensity / (.pi * r * r)), translate(center) * scale(r))
            } else {
                addLight(.sphere(radius: r), color: intensity) { _ in LightPose(position: center) }
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
        addLight(.rect(width: 1.6, height: 1.2), color: SIMD3<Float>(1.0, 0.92, 0.82) * 7) { _ in
            LightPose(position: left, direction: normalize(target - left))
        }
        addLight(.rect(width: 1.2, height: 1.2), color: SIMD3<Float>(0.85, 0.9, 1.0) * 6) { t in
            let a = 0.9 + 0.7 * sin(0.3 * t)
            let p = target + SIMD3<Float>(4.2 * sin(a), 2.0 + 0.6 * sin(0.5 * t), 4.2 * cos(a))
            return LightPose(position: p, direction: normalize(target - p))
        }
        addLight(.rect(width: 5, height: 0.5), color: SIMD3<Float>(1.0, 0.97, 0.92) * 6) { _ in
            LightPose(position: [0, 5.97, -2.5], direction: [0, -1, 0], tangent: [1, 0, 0])
        }
        addLight(.rect(width: 3.2, height: 2.2), color: SIMD3<Float>(0.75, 0.85, 1.0) * 2.2) { _ in
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
                addLight(.tube(length: 1.5, radius: 0.025), color: SIMD3<Float>(0.95, 0.97, 1.0) * 2.2) { _ in
                    LightPose(position: [x, 3.3, z], direction: [1, 0, 0])
                }
            }
        }
        // Neon: pink along the back wall, a cyan upright on the left (flickering), an amber one on the right.
        addLight(.tube(length: 4, radius: 0.03), color: Scene.hue([1.0, 0.2, 0.6]) * 2.5) { _ in
            LightPose(position: [0, 2.5, -7.9], direction: [1, 0, 0])
        }
        addLight(.tube(length: 2, radius: 0.03), color: Scene.hue([0.15, 0.9, 1.0]) * 2) { t in
            // Mostly on, with bursts of quick dropouts.
            let k = Float(Int(t * 12) &* 7919 % 101) / 101
            let burst = sin(0.9 * t) > 0.6
            return LightPose(position: [-9.9, 1.6, -2], direction: [0, 1, 0], scale: SIMD3(repeating: burst && k < 0.45 ? 0.08 : 1))
        }
        addLight(.tube(length: 3, radius: 0.03), color: Scene.hue([1.0, 0.55, 0.1]) * 2) { t in
            LightPose(position: [9.9, 2.2, -3], direction: [0, 0.15 * sin(0.4 * t), 1])
        }
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
        addLight(.rect(width: 1.2, height: 0.6), color: SIMD3<Float>(1.0, 0.85, 0.65) * 4) { _ in
            LightPose(position: [0, h - 0.02, 0], direction: [0, -1, 0], tangent: [1, 0, 0])
        }
        let lamp = SIMD3<Float>(4.4, 1.35, -3.6)
        kit.box(lamp + [0, 0.1, 0], [0.18, 0.12, 0.18], black)
        kit.slab([4.38, 0.8, -3.62], [4.42, 1.3, -3.58], black)
        addLight(.spot(radius: 0.03, inner: Scene.degrees(18), outer: Scene.degrees(32)), color: SIMD3<Float>(1.0, 0.85, 0.6) * 4) { t in
            let target = SIMD3<Float>(3.5 + 0.4 * sin(0.3 * t), 0.8, -3.3)
            return LightPose(position: lamp, direction: normalize(target - lamp))
        }
        addLight(.tube(length: 2.4, radius: 0.02), color: SIMD3<Float>(0.8, 0.9, 1.0) * 1.2) { _ in
            LightPose(position: [-0.3, 1.86, -3.8], direction: [1, 0, 0])
        }
        kit.slab([-3.82, 0, -3.22], [-3.78, 1.55, -3.18], black)                    // floor lamp stand
        addLight(.sphere(radius: 0.12), color: SIMD3<Float>(1.0, 0.7, 0.4) * 3) { _ in LightPose(position: [-3.8, 1.7, -3.2]) }
        defaultCamera = Scene.demoCamera(.mixed)!
    }
}
