import EngineCore
import Foundation
import MetalRenderer
import simd

/// The VG lab: virtual geometry's test scene. Booths along +X, 30 m apart, on a grid floor under the sun, each testing
/// one thing with shapes whose answer is known (VGLabShapes) and the gallery's models; each has bookmarks
/// (`VGLab.bookmarks`), which the `vglab` benchmark renders.
enum VGLab {
    static let spacing: Float = 30
    /// Booth `n`'s centre on the X axis (1-based, as the bookmarks number them).
    static func x(_ booth: Int) -> Float { spacing * Float(booth - 1) }

    /// The gallery's models the booths use, by a part of their file name.
    enum Model: String, CaseIterable {
        case maiden = "android_battle_maiden", owl = "steampunk owl", bench = "vintage laboratory bench", golem = "grim dark armored golem"
    }

    /// The ladder's distances (m): every DAG level ends up on screen at once.
    static let ladder: [Float] = [1, 2, 4, 8, 16, 32, 64, 128, 256]
    /// Where the cold-cache booth's models stand: far enough that their cuts are their roots until the camera comes.
    static let coldDistance: Float = 200

    static func bookmark(_ name: String, _ group: String, _ booth: Int, _ position: SIMD3<Float>, _ lookAt: SIMD3<Float>) -> SceneBookmark {
        let o = SIMD3<Float>(x(booth), 0, 0)
        return SceneBookmark(name: name, group: group, position: o + position, lookAt: o + lookAt)
    }

    static func bookmarks() -> [SceneBookmark] {
        [
            bookmark("01 Ladder", "Distance ladder", 1, [0, 1.2, 1.5], [0, 0.6, -24]),
            bookmark("01 Ladder side", "Distance ladder", 1, [6, 3, -6], [0, 0.5, -14]),
            bookmark("02 Cracks", "Cracks", 2, [0, 1.3, 3.2], [0, 1.2, -2]),
            bookmark("02 Cracks far", "Cracks", 2, [0, 1.6, 16], [0, 1.2, -2]),
            bookmark("03 Seams", "Seams and thin", 3, [1, 1.5, 3], [1, 1, -2]),
            bookmark("03 Needles", "Seams and thin", 3, [0, 1.0, -0.9], [0, 1.0, -2]),
            bookmark("04 Grazing", "Grazing", 4, [0, 1.2, 2], [0, 0.6, -60]),
            bookmark("04 Grazing high", "Grazing", 4, [0, 25, 12], [0, 0, -28]),
            bookmark("05 Field", "Instance field", 5, [0, 14, 12], [0, 0, -18]),
            bookmark("05 Field inside", "Instance field", 5, [-1, 1.6, -4], [8, 1, -30]),
            bookmark("06 Movers", "Movers", 6, [0, 2.2, 5], [0, 1.5, -6]),
            bookmark("07 Real", "Real content", 7, [0, 1.6, 4.5], [0, 0.9, -1]),
            bookmark("07 Real close", "Real content", 7, [-3, 1.5, 0.2], [-3, 1.4, -1]),
            bookmark("08 Cold far", "Cold cache", 8, [0, 1.6, 4], [0, 1, -coldDistance]),
            bookmark("08 Cold near", "Cold cache", 8, [0, 1.5, -coldDistance + 3.5], [0, 0.9, -coldDistance]),
        ]
    }
}

extension Scene {
    /// The VG lab (`VGLab`). `settings.objects` is the instance field's count (1 to SceneSettings.objectRange's top).
    func buildVGLab() {
        let kit = Kit(self)
        let floor = addGridMaterial(GridLook(tile: [0.36, 0.36, 0.37], subgrid: 0))
        object("Floor") { addInstance(kit.quad, floor, scale([20_000, 1, 20_000])) }
        let toSun = normalize(SIMD3<Float>(0.35, 0.8, 0.5))
        addLight(.sun(angularRadius: Scene.degrees(0.27)), color: [1, 1, 1]) { _ in LightPose(position: .zero, direction: toSun) }
        let matte = addPBRMaterial(baseColor: [0.62, 0.62, 0.6], metallic: 0, roughness: 0.7)
        let warm = addPBRMaterial(baseColor: [0.7, 0.55, 0.4], metallic: 0, roughness: 0.6)
        let backdrop = addMaterial(albedo: [0.02, 0.02, 0.02])
        let plinth = addPBRMaterial(baseColor: [0.5, 0.5, 0.52], metallic: 0, roughness: 0.5)

        let sphere = VGLabShapes.icosphere(), knot = VGLabShapes.torusKnot(), cube = VGLabShapes.seamCube()
        let comb = VGLabShapes.needleComb(), sheet = VGLabShapes.thinSheet(), plane = VGLabShapes.displacedPlane()
        func add(_ shape: VGLabShape, _ name: String, _ material: Int, _ transforms: [float4x4],
                 animations: [((Float) -> float4x4)?]? = nil) {
            addVirtualMesh(name: name, cacheKey: shape.key, material: material, transforms: transforms,
                           watertight: shape.watertight, animations: animations, build: shape.build)
        }
        let models = loadModels()
        // Every booth's copies of a model, added together at the end: one set of (virtual) meshes per model.
        var placed: [VGLab.Model: [(transform: float4x4, animation: ((Float) -> float4x4)?)]] = [:]
        func place(_ model: VGLab.Model, _ name: String, _ placements: [(transform: float4x4, animation: ((Float) -> float4x4)?)]) {
            placed[model, default: []] += placements
        }
        func sign(_ booth: Int) {   // a post at the booth's front left, a cube a booth: count them to tell booths apart
            for k in 0..<booth {
                object("Signs/Booth \(booth)") {
                    addInstance(kit.cube, warm, translate([VGLab.x(booth) - 4, 0.15 + 0.32 * Float(k), 1.5]) * scale([0.25, 0.25, 0.25]))
                }
            }
        }

        // 1. Distance ladder: the sphere and the golem at 1, 2, 4 ... 256 m.
        let x1 = VGLab.x(1)
        add(sphere, "01 Ladder/Spheres", matte, VGLab.ladder.map { translate([x1 - 1.2, 0.5, -$0]) * scale([0.5, 0.5, 0.5]) })
        place(.golem, "01 Ladder/Golems", VGLab.ladder.map { (translate([x1 + 1.2, 0, -$0]), nil) })
        sign(1)

        // 2. Cracks: closed shapes against a black wall; a hole shows their inside (the Cracks view).
        let x2 = VGLab.x(2)
        object("02 Cracks/Backdrop") {
            addInstance(kit.quad, backdrop, translate([x2, 4, -6]) * rotate(.pi / 2, [1, 0, 0]) * scale([14, 1, 8]))
        }
        add(sphere, "02 Cracks/Sphere", matte, [translate([x2 - 2.6, 1.2, -2])])
        add(knot, "02 Cracks/Torus knot", matte, [translate([x2, 1.2, -2]) * scale([1.6, 1.6, 1.6])])
        add(cube, "02 Cracks/Seam cube", matte, [translate([x2 + 2.6, 1.2, -2]) * rotate(0.6, [0, 1, 0]) * scale([0.8, 0.8, 0.8])])
        sign(2)

        // 3. Seams and thin features: the seam cube's split normals and UVs, needles, a 1 cm sheet, the maiden.
        let x3 = VGLab.x(3)
        add(cube, "03 Seams/Seam cube", warm, [translate([x3 - 2.2, 1, -2]) * rotate(0.5, [0, 1, 0]) * scale([0.7, 0.7, 0.7])])
        add(comb, "03 Seams/Needle comb", matte, [translate([x3, 0.8, -2])])
        add(sheet, "03 Seams/Thin sheet", matte, [translate([x3 + 1.4, 0.3, -2.2]) * rotate(-.pi / 2, [1, 0, 0]) * scale([1.4, 1.4, 1.4])])
        place(.maiden, "03 Seams/Maiden", [(translate([x3 + 4, 0, -2]), nil)])
        sign(3)

        // 4. Grazing: a 64 m hilly plane, seen from low along it.
        let x4 = VGLab.x(4)
        add(plane, "04 Grazing/Plane", matte, [translate([x4, -0.05, -34])])
        sign(4)

        // 5. Instance field: `objects` torus knots on a grid 2 m apart, and a row of lab benches.
        let x5 = VGLab.x(5)
        let n = max(1, min(SceneSettings.objectRange.upperBound, settings.objects)), side = Int(Float(n).squareRoot().rounded(.up))
        let field = (0..<n).map { i -> float4x4 in
            let gx = Float(i % side) - Float(side - 1) / 2, gz = Float(i / side)
            return translate([x5 + 2 * gx, 0.8, -4 - 2 * gz]) * rotate(Float(i) * 0.7, [0, 1, 0])
        }
        add(knot, "05 Field/Torus knots", matte, field)
        place(.bench, "05 Field/Benches", (0..<8).map { (translate([x5 - 7 + 2 * Float($0), 0, 1.5]), nil) })
        sign(5)

        // 6. Movers: orbiting, spinning, squashed and stretched, and one that comes and goes from 2 to 60 m.
        let x6 = VGLab.x(6)
        let c6 = SIMD3<Float>(x6, 1.5, -6)
        let movers: [((Float) -> float4x4)?] = [
            { t in translate(c6 + [3 * cos(0.5 * t), 0, 3 * sin(0.5 * t)]) * rotate(t, [0, 1, 0]) },
            { t in translate(c6 + [-1.5, 0, 0]) * rotate(1.3 * t, [0.3, 1, 0.2]) },
            { t in translate(c6 + [1.5, 0, 0]) * scale([1 + 0.5 * sin(t), 1, 1 - 0.3 * sin(t)]) },
            { t in translate([x6 + 0.5, 1.2, -2 - 29 * (1 - cos(0.3 * t))]) },
        ]
        add(knot, "06 Movers/Torus knots", warm, movers.map { $0!(0) }, animations: movers)
        place(.owl, "06 Movers/Owl", [(translate(c6 + [0, -1.5, 3]), { t in translate(c6 + [0, -1.5, 3]) * rotate(0.4 * t, [0, 1, 0]) })])
        sign(6)

        // 7. Real content: the four models on plinths.
        let x7 = VGLab.x(7)
        for (k, model) in VGLab.Model.allCases.enumerated() {
            let p = SIMD3<Float>(x7 - 3 + 2 * Float(k), 0, -1)
            object("07 Real/Plinths") { addInstance(kit.cube, plinth, translate(p + [0, 0.1, 0]) * scale([1.2, 0.2, 1.2])) }
            place(model, "07 Real/\(model.rawValue)", [(translate(p + [0, 0.2, 0]), nil)])
        }
        sign(7)

        // 8. Cold cache: the owl and the golem far down the booth's line, for the benchmark to evict and fly to.
        let x8 = VGLab.x(8)
        place(.owl, "08 Cold/Owl", [(translate([x8 - 0.9, 0, -VGLab.coldDistance]), nil)])
        place(.golem, "08 Cold/Golem", [(translate([x8 + 0.9, 0, -VGLab.coldDistance]), nil)])
        sign(8)

        for model in VGLab.Model.allCases {
            guard let (m, url) = models[model], let placements = placed[model] else { continue }
            let fit = Scene.placement(m, size: 1.6)
            object("Models/\(model.rawValue)") {
                addModel(m, url: url, placements: placements.map { p in (p.transform * fit, p.animation.map { a in { a($0) * fit } }) })
            }
        }

        if let first = VGLab.bookmarks().first, let (yaw, pitch) = SceneCommand.angles(from: first.position, to: first.lookAt) {
            var c = Camera()
            c.position = first.position
            c.yaw = yaw
            c.pitch = pitch
            defaultCamera = c
        }
    }

    /// The lab's models, by the part of their file name in `Assets/` (a missing one is left out, with a note).
    private func loadModels() -> [VGLab.Model: (GLTFModel, URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Scene.assetsDirectory, includingPropertiesForKeys: nil)) ?? []
        var out: [VGLab.Model: (GLTFModel, URL)] = [:]
        for model in VGLab.Model.allCases {
            if loadStep?.isCancelled == true { break }
            guard let url = files.first(where: { $0.lastPathComponent.lowercased().contains(model.rawValue) }) else {
                print("VG lab: no model matching \"\(model.rawValue)\" in \(Scene.assetsDirectory.path)")
                continue
            }
            loadStep?.set(detail: url.deletingPathExtension().lastPathComponent)
            do { out[model] = (try GLTFLoader.load(url), url) } catch { print("VG lab: skipping \(url.lastPathComponent): \(error)") }
        }
        return out
    }
}
