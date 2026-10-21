import EngineCore
import Foundation
import Plants
import simd

/// What every scene's builder shares: a kit of meshes and boxes, a camera from a position and angles, the day sun,
/// and the light check (a benchmark fixture, METALRENDERER_SCENE check=<light>). The demo scenes that use them are the
/// game's (Sources/Game); the editors' workshops use them too.
extension Scene {
    /// Shared meshes and a box helper for the builders below (and the showcase's and Scene+Shapes.swift's).
    package struct Kit {
        let scene: Scene
        package let quad: Int, cube: Int, sphere: Int

        package init(_ scene: Scene) {
            self.scene = scene
            quad = scene.addMesh(Scene.quadMesh(), label: "quad")
            cube = scene.addMesh(Scene.cubeMesh(), label: "box")
            sphere = scene.addMesh(Scene.icosphere(subdivisions: 3), label: "ball")
        }

        /// An axis-aligned box (rotated about Y by `yaw`) given by its centre and size.
        @discardableResult
        package func box(_ center: SIMD3<Float>, _ size: SIMD3<Float>, _ material: Int, yaw: Float = 0) -> Int {
            scene.addInstance(cube, material, translate(center) * rotate(yaw, [0, 1, 0]) * scale(size))
        }

        /// A box from its min and max corners.
        @discardableResult
        package func slab(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, _ material: Int) -> Int {
            box((lo + hi) / 2, hi - lo, material)
        }

        @discardableResult
        package func ball(_ center: SIMD3<Float>, _ radius: Float, _ material: Int) -> Int {
            scene.addInstance(sphere, material, translate(center) * scale(radius))
        }

        /// Floor, back and side walls (and a ceiling if `ceiling`) of a room open toward +Z.
        package func room(width w: Float, height h: Float, depth d: Float, floor: Int, walls: Int, ceiling: Bool) {
            scene.object("Room") {
                scene.object("Floor") { scene.addInstance(quad, floor, scale([w, 1, d])) }
                scene.object("Back wall") { scene.addInstance(quad, walls, translate([0, h / 2, -d / 2]) * rotate(.pi / 2, [1, 0, 0]) * scale([w, 1, h])) }
                scene.object("Left wall") { scene.addInstance(quad, walls, translate([-w / 2, h / 2, 0]) * rotate(-.pi / 2, [0, 0, 1]) * scale([h, 1, d])) }
                scene.object("Right wall") { scene.addInstance(quad, walls, translate([w / 2, h / 2, 0]) * rotate(.pi / 2, [0, 0, 1]) * scale([h, 1, d])) }
                if ceiling { scene.object("Ceiling") { scene.addInstance(quad, walls, translate([0, h, 0]) * rotate(.pi, [1, 0, 0]) * scale([w, 1, d])) } }
            }
        }
    }

    package static func camera(_ position: SIMD3<Float>, yaw: Float = 0, pitch: Float) -> Camera {
        var c = Camera()
        c.position = position
        c.yaw = yaw
        c.pitch = pitch
        return c
    }

    /// Scene `kind`'s default camera (its definition's), unless the scene says its own.
    package static func demoCamera(_ kind: SceneKind) -> Camera? { kind.definition.camera }

    package static func degrees(_ d: Float) -> Float { d * .pi / 180 }

    /// Unit-luminance colour.
    package static func hue(_ c: SIMD3<Float>) -> SIMD3<Float> { c / dot(c, [0.2126, 0.7152, 0.0722]) }

    // MARK: - Light check

    /// Benchmark scene (METALRENDERER_BENCH=lightcheck): a floor, a box, and one light — "rect", "tube" or "sphere" — or,
    /// with a "-mesh" suffix, an emissive mesh of the same shape and radiance, sampled as a mesh light. The mesh
    /// estimator is unbiased, so converged images of the two check the analytic light's closed form.
    package func buildLightCheck(_ check: String) {
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

    /// The valley's and the forest's sun: morning in the east (+x) to evening in the west (-x), passing ahead of the
    /// camera (-z), and back, 90 seconds each way (`DaySweep.valley`); t = 0 is mid-morning. Its colour comes from the
    /// atmosphere.
    package func addDaySun() {
        addLight(.sun(angularRadius: Scene.degrees(0.27)), color: [1, 1, 1]) { t in
            let phase = DaySweep.valley.phase(t)   // 0 = morning, 1 = evening
            let e = Scene.degrees(10 + 50 * sin(.pi * phase)), a = Scene.degrees(20 + 140 * phase)
            return LightPose(position: .zero, direction: [cos(e) * cos(a), sin(e), -cos(e) * sin(a)])
        }
    }

    /// A stone chunk about a unit across: an icosphere pushed in and out by a hash of its corners, its faces flat.
    package static func rock(seed: UInt32) -> MeshGeometry {
        let ball = icosphere(subdivisions: 1)
        let corners = ball.positions.enumerated().map { i, p -> SIMD3<Float> in
            var r = ParticleMath.Rng(state: ParticleMath.hash(seed &+ UInt32(i) &* 0x9E37_79B9))
            return p * (0.7 + 0.45 * r.next()) * SIMD3(1, 0.75, 0.9)
        }
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        for f in stride(from: 0, to: ball.indices.count, by: 3) {
            let a = corners[Int(ball.indices[f])], b = corners[Int(ball.indices[f + 1])], c = corners[Int(ball.indices[f + 2])]
            let n = normalize(cross(b - a, c - a))
            for p in [a, b, c] {
                indices.append(UInt32(positions.count))
                positions.append(p)
                normals.append(n)
            }
        }
        return (positions, normals, indices)
    }
}
