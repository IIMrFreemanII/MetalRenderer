import EngineCore
import MetalRenderer
import simd

extension Scene {
    /// Booth 1, sphere sizes: 1 mm, 5 cm and 0.5 m spheres (tiny-light sampling, proxy size).
    /// Same intensity (so the same power) each, 1.5 m up over a ball on a plinth: the shadows' edges differ.
    func boothSphereSizes(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self)
        let grey = addMaterial(albedo: SIMD3(repeating: 0.5))
        let radii: [Float] = [0.001, 0.05, 0.5]
        for (i, r) in radii.enumerated() {
            let x = -1.2 + 1.2 * Float(i)
            object(String(format: "Sphere r %g", r)) {
                let pose = LightPose(position: b.p(x, 1.5, 2.5))
                addLight(.sphere(radius: r), color: SIMD3(repeating: 4), motion: .constant) { _ in pose }
                // (a 0.4 m plinth: with 0.5 m the ball's top would touch the big sphere's underside)
                labSlab(kit, b, [x - 0.15, 0, 2.35], [x + 0.15, 0.4, 2.65], grey)
                kit.ball(b.p(x, 0.65, 2.5), 0.25, grey)
            }
        }
    }

    /// Booth 2, near field: a sphere, a rect and a tube 5 mm to 5 cm from a wall (singularities, fireflies, the clamp).
    func boothNearField(_ b: BoothFrame, _ lab: LightLabSettings) {
        object("Sphere 5 mm from the back wall") {
            // r 0.02, its surface 5 mm off the wall (the back wall's face is at z = 4)
            let pose = LightPose(position: b.p(0.8, 1.5, 4 - 0.005 - 0.02))
            addLight(.sphere(radius: 0.02), color: SIMD3(repeating: 3), motion: .constant) { _ in pose }
        }
        object("Rect 2 cm from the left wall") {
            // 0.2 x 0.2, facing the wall (-x) tilted 80 degrees from it, toward the back
            let a = Scene.degrees(80)
            let pose = LightPose(position: b.p(-2 + 0.02, 1.4, 2.0), direction: b.dir([-cos(a), 0, sin(a)]), tangent: b.dir([0, 1, 0]))
            addLight(.rect(width: 0.2, height: 0.2), color: SIMD3(repeating: 10), motion: .constant) { _ in pose }
        }
        object("Tube 5 cm above the floor") {
            let pose = LightPose(position: b.p(0, 0.05, 2.5), direction: b.dir([1, 0, 0]))
            addLight(.tube(length: 0.6, radius: 0.01), color: SIMD3(repeating: 1), motion: .constant) { _ in pose }
        }
    }

    /// Booth 3, spot cones: 1, 15 and 40 degrees, and a hard edge grazing a wall (cone edges, falloff, the cull's cone bounds).
    func boothSpotCones(_ b: BoothFrame, _ lab: LightLabSettings) {
        let intensity = SIMD3<Float>(repeating: 15)
        object("Spots") {
            for (i, outer) in [Float(1), 15, 40].enumerated() {
                let o = Scene.degrees(outer)
                let pose = LightPose(position: b.p(-1.5 + 1.0 * Float(i), 2.9, 2.4), direction: b.dir([0, -1, 0]))
                addLight(.spot(radius: 0.03, inner: 0.8 * o, outer: o), color: intensity, motion: .constant) { _ in pose }
            }
            // a hard edge (inner = outer = 25 degrees), its axis 75 degrees from the right wall's normal
            let a = Scene.degrees(75)
            let axis = normalize(SIMD3<Float>(cos(a), -0.5, 0.82))
            let pose = LightPose(position: b.p(1.0, 2.9, 0.5), direction: b.dir(axis))
            let hard = Scene.degrees(25)
            addLight(.spot(radius: 0.03, inner: hard, outer: hard), color: intensity, motion: .constant) { _ in pose }
        }
    }

    /// Booth 4, rects: back face, edge-on, whole-ceiling, tiny, a reach cut-off (one-sidedness, solid-angle sampling, reach).
    func boothRects(_ b: BoothFrame, _ lab: LightLabSettings) {
        object("Rect facing away") {   // its back face is to the camera: dark
            let pose = LightPose(position: b.p(-1.2, 1.6, 2.0), direction: b.dir([0, 0, 1]), tangent: b.dir([1, 0, 0]))
            addLight(.rect(width: 0.8, height: 0.6), color: SIMD3(repeating: 3), motion: .constant) { _ in pose }
        }
        object("Rect edge-on") {   // on the camera's vertical plane, perpendicular to the back wall, touching it
            let pose = LightPose(position: b.p(0, 1.0, 3.5), direction: b.dir([1, 0, 0]), tangent: b.dir([0, 0, 1]))
            addLight(.rect(width: 1.0, height: 0.5), color: SIMD3(repeating: 3), motion: .constant) { _ in pose }
        }
        object("Rect whole ceiling") {
            let pose = LightPose(position: b.p(0, 2.95, 2.0), direction: b.dir([0, -1, 0]), tangent: b.dir([1, 0, 0]))
            addLight(.rect(width: 3.6, height: 3.6), color: SIMD3(repeating: 0.15), motion: .constant) { _ in pose }
        }
        object("Rect tiny, reach 1.5") {   // bright, so it shows; lights the floor only 1.5 m out from the wall
            let pose = LightPose(position: b.p(-1.0, 1.0, 3.98), direction: b.dir([0, 0, -1]), tangent: b.dir([1, 0, 0]))
            addLight(.rect(width: 0.05, height: 0.05), color: SIMD3(repeating: 400), reach: 1.5, motion: .constant) { _ in pose }
        }
    }

    /// Booth 5, tubes: long thin, short fat, touching the floor, end-on (the capsule's sampling).
    func boothTubes(_ b: BoothFrame, _ lab: LightLabSettings) {
        object("Tube long thin") {
            let pose = LightPose(position: b.p(0, 2.85, 2.0), direction: b.dir([1, 0, 0]))
            addLight(.tube(length: 3, radius: 0.01), color: SIMD3(repeating: 12), motion: .constant) { _ in pose }
        }
        object("Tube short fat") {
            let pose = LightPose(position: b.p(1.2, 1.2, 2.5), direction: b.dir([1, 0, 0]))
            addLight(.tube(length: 0.3, radius: 0.12), color: SIMD3(repeating: 6), motion: .constant) { _ in pose }
        }
        object("Tube on the floor") {
            let pose = LightPose(position: b.p(-0.8, 0.03, 1.5), direction: b.dir([0, 0, 1]))
            addLight(.tube(length: 1.5, radius: 0.03), color: SIMD3(repeating: 2), motion: .constant) { _ in pose }
        }
        object("Tube end-on") {   // along z at the camera's height and across: seen end-on from the doorway
            let pose = LightPose(position: b.p(0, 1.6, 3.4), direction: b.dir([0, 0, 1]))
            addLight(.tube(length: 1.0, radius: 0.03), color: SIMD3(repeating: 3), motion: .constant) { _ in pose }
        }
    }

    /// Booth 6, dynamic range: a 1e-3 light beside a 1e4 one (RIS imbalance, the firefly clamp).
    /// The "usual" intensity here is 0.3 (so the 1e4 one is 3000: 1e4 x 15 would be white over the whole booth).
    func boothDynamicRange(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self)
        let usual: Float = 0.01   // the bright one (1e4 x) lights the booth; 0.3 left it white under the app's exposure
        object("Bright light behind a slab") {
            labSlab(kit, b, [0.4, 0, 2.5], [1.9, 1.0, 2.6], addMaterial(albedo: SIMD3(repeating: 0.5)))
            let pose = LightPose(position: b.p(1.2, 0.5, 2.9))
            addLight(.sphere(radius: 0.03), color: SIMD3(repeating: 1e4 * usual), motion: .constant) { _ in pose }
        }
        object("Dim light over a white card") {
            labSlab(kit, b, [-1.6, 0, 1.0], [-1.0, 0.01, 1.6], addMaterial(albedo: SIMD3(repeating: 0.9)))
            let pose = LightPose(position: b.p(-1.3, 0.2, 1.3))
            addLight(.sphere(radius: 0.03), color: SIMD3(repeating: 1e-3 * usual), motion: .constant) { _ in pose }
        }
    }

    /// Booth 7, emitters at the cascade reach: sizes around cascadeEmitterSize, walls at reach +- 10% (the cascadeCut split).
    /// Four square emissive quads (side = s sqrt(pi), reach 4 s^2) with two grey cards each, just inside and just outside.
    func boothCascadeReach(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self)
        let glow = addMaterial(albedo: .zero, emission: SIMD3(repeating: 3))
        let grey = addMaterial(albedo: SIMD3(repeating: 0.5))
        let hx = b.size.x / 2, d = b.size.z, y: Float = 1.4

        // A square emitter of `side` at a local centre, facing along local `normal` (horizontal).
        func panel(_ center: SIMD3<Float>, _ normal: SIMD3<Float>, side: Float) {
            let n = b.dir(normal), t = normalize(cross(SIMD3<Float>(0, 1, 0), n)), bt = cross(t, n)
            addInstance(kit.quad, glow, float4x4(SIMD4(t * side, 0), SIMD4(n, 0), SIMD4(bt * side, 0), SIMD4(b.p(center.x, center.y, center.z), 1)))
        }
        // A 0.15 m card on a thin post, at local x, z; it faces along x (`alongX`) or z.
        func card(_ x: Float, _ z: Float, alongX: Bool) {
            let h: Float = 0.075
            if alongX {
                labSlab(kit, b, [x - 0.005, y - h, z - h], [x + 0.005, y + h, z + h], grey)
            } else {
                labSlab(kit, b, [x - h, y - h, z - 0.005], [x + h, y + h, z + 0.005], grey)
            }
            labSlab(kit, b, [x - 0.01, 0, z - 0.01], [x + 0.01, y - h, z + 0.01], grey)
        }
        let sqrtPi = Float.pi.squareRoot()

        object("Emitter s 0.8 (reach 2.56 m), back wall") {
            panel([0.5, y, d - 0.003], [0, 0, -1], side: 0.8 * sqrtPi)
            card(0.3, d - 2.3, alongX: false)
            card(0.7, d - 2.8, alongX: false)
        }
        object("Emitter s 0.5 (reach 1.0 m), left wall") {
            panel([-hx + 0.003, y, 2.5], [1, 0, 0], side: 0.5 * sqrtPi)
            card(-hx + 0.9, 2.35, alongX: true)
            card(-hx + 1.1, 2.65, alongX: true)
        }
        object("Emitter s 0.3 (reach 0.36 m), right wall") {
            panel([hx - 0.003, y, 2.0], [-1, 0, 0], side: 0.3 * sqrtPi)
            card(hx - 0.3, 1.9, alongX: true)
            card(hx - 0.45, 2.1, alongX: true)
        }
        object("Emitter s 0.08 (reach 0.03 m), back wall") {
            panel([-1.5, y, d - 0.003], [0, 0, -1], side: 0.08 * sqrtPi)
            card(-1.6, d - 0.2, alongX: false)
            card(-1.4, d - 0.5, alongX: false)
        }
    }
}
