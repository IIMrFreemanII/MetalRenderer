import EngineCore
import Foundation
import ImageIO
import simd
import MetalRenderer

extension Scene {
    /// Gallery: the models in `Assets/` on plinths in an arc, 1.6 m at their largest side, under 8 moving lights.
    /// Two of them turn slowly (dynamic instances); the rest are static.
    func buildGallery() {
        let quad = addMesh(Scene.quadMesh(), label: "quad")
        let cube = addMesh(Scene.cubeMesh(), label: "box")
        let sphere = addMesh(Scene.icosphere(subdivisions: 2), label: "ball")
        let floor = addPBRMaterial(baseColor: [0.32, 0.31, 0.30], metallic: 0, roughness: 0.25)   // polished stone
        let wall = addMaterial(albedo: [0.70, 0.70, 0.68])
        let plinth = addPBRMaterial(baseColor: [0.62, 0.62, 0.64], metallic: 1, roughness: 0.35)   // brushed steel

        let w: Float = 26, h: Float = 7, d: Float = 18
        object("Hall/Floor") { addInstance(quad, floor, translate([0, 0, 0]) * scale([w, 1, d])) }
        object("Hall/Back wall") { addInstance(quad, wall, translate([0, h / 2, -d / 2]) * rotate(.pi / 2, [1, 0, 0]) * scale([w, 1, h])) }
        object("Hall/Left wall") { addInstance(quad, wall, translate([-w / 2, h / 2, 0]) * rotate(-.pi / 2, [0, 0, 1]) * scale([h, 1, d])) }
        object("Hall/Right wall") { addInstance(quad, wall, translate([w / 2, h / 2, 0]) * rotate(.pi / 2, [0, 0, 1]) * scale([h, 1, d])) }

        let files = Scene.galleryFiles()
        let plinthHeight: Float = 0.3
        let start = CFAbsoluteTimeGetCurrent()
        var triangles = 0
        loadStep?.set(done: 0, total: files.count)
        beginObject("Exhibits")
        defer { endObject() }
        for (i, url) in files.enumerated() {
            if loadStep?.isCancelled == true { break }   // another scene was asked for: this one is thrown away
            loadStep?.set(detail: url.deletingPathExtension().lastPathComponent)
            defer { loadStep?.advance() }
            let model: GLTFModel
            do {
                model = try GLTFLoader.load(url)
            } catch {
                print("Gallery: skipping \(url.lastPathComponent): \(error)")
                continue
            }
            triangles += model.triangleCount
            // Arc of radius 6 around (0, 0, 1), from -60 to +60 degrees, each model facing the arc's centre.
            let a = files.count > 1 ? (-60 + 120 * Float(i) / Float(files.count - 1)) * .pi / 180 : 0
            let p = SIMD3<Float>(6 * sin(a), 0, 1 - 6 * cos(a))
            object("Plinths/\(model.name)") { addInstance(cube, plinth, translate(p + [0, plinthHeight / 2, 0]) * scale([1.3, plinthHeight, 1.3])) }
            let base = translate(p + [0, plinthHeight, 0]) * rotate(-a, [0, 1, 0])
            let place = Scene.placement(model, size: 1.6)
            if i % 5 == 1 {   // turntables
                let speed: Float = i % 2 == 0 ? 0.25 : -0.2
                addModel(model, url: url, transform: base * place) { t in base * rotate(speed * t, [0, 1, 0]) * place }
            } else {
                addModel(model, url: url, transform: base * place)
            }
            print(String(format: "Gallery: %@ (%d triangles, %d images)", model.name, model.triangleCount, model.images.count))
        }
        print(String(format: "Gallery: %d models, %d triangles, loaded in %.1f s", files.count, triangles,
                     CFAbsoluteTimeGetCurrent() - start))

        // 8 lights drifting above the arc, warm and cool.
        var rng = SplitMix64(seed: 0x6A11_E7)
        let colors: [SIMD3<Float>] = [[1.0, 0.85, 0.65], [1.0, 0.55, 0.25], [0.45, 0.65, 1.0], [0.85, 0.75, 1.0]]
        beginObject("Lights")
        defer { endObject() }
        for j in 0..<8 {
            let color = colors[j % colors.count] / dot(colors[j % colors.count], [0.2126, 0.7152, 0.0722])
            let c = SIMD3<Float>(rng.range(-6, 6), rng.range(2.2, 3.6), rng.range(-4, 3))
            let amp = SIMD3<Float>(rng.range(1, 3), rng.range(0.2, 0.6), rng.range(0.5, 2))
            let f = SIMD3<Float>(rng.range(0.1, 0.3), rng.range(0.2, 0.5), rng.range(0.1, 0.3))
            let phase = rng.range(0, 2 * .pi)
            addLight(color: color * 5, radius: 0.08, sphereMesh: sphere) { t in
                c + amp * SIMD3(sin(f.x * t + phase), sin(f.y * t + 2 * phase), cos(f.z * t + phase))
            }
        }
        defaultCamera = Scene.galleryCamera
    }

    static let galleryCamera: Camera = {
        var c = Camera()
        c.position = [0, 1.8, 4.5]
        c.pitch = -0.1
        return c
    }()
}
