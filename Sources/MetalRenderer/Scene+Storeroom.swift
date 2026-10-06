import Foundation
import simd

extension Scene {
    static let storeroomRows = 7
    static let storeroomBay: Float = 6       // a row's depth along the aisle
    static let storeroomAisle: Float = 3     // the aisle's width
    static let storeroomWidth: Float = 22

    /// The storeroom: the models in `Assets/` again and again, on plinths in bays either side of a long aisle, the bays
    /// parted by full-height walls, and one in the aisle every other row. Looking down the aisle, every bay's walls hide the
    /// bays beyond, and the aisle's models what is behind them: most of the models are in the view but out of sight,
    /// whole or in part. Made for the raster clusters' occlusion (`METALRENDERER_BENCH=rastervg`), which the gallery,
    /// with everything in sight, can't show.
    func buildStoreroom() {
        let quad = addMesh(Scene.quadMesh())
        let cube = addMesh(Scene.cubeMesh())
        let sphere = addMesh(Scene.icosphere(subdivisions: 2))
        let floor = addPBRMaterial(baseColor: [0.30, 0.29, 0.28], metallic: 0, roughness: 0.4)
        let wall = addMaterial(albedo: [0.68, 0.67, 0.64])
        let plinth = addPBRMaterial(baseColor: [0.62, 0.62, 0.64], metallic: 1, roughness: 0.35)

        let rows = Scene.storeroomRows, bay = Scene.storeroomBay, aisle = Scene.storeroomAisle, w = Scene.storeroomWidth
        let h: Float = 5, length = Float(rows) * bay
        addInstance(quad, floor, translate([0, 0, 2 - length / 2]) * scale([w, 1, length + 4]))
        addInstance(quad, wall, translate([0, h / 2, -length]) * rotate(.pi / 2, [1, 0, 0]) * scale([w, 1, h]))
        for side: Float in [-1, 1] {
            addInstance(quad, wall, translate([side * w / 2, h / 2, 2 - length / 2]) * rotate(side * .pi / 2, [0, 0, 1])
                        * scale([h, 1, length + 4]))
            // The walls between the bays (and before the first), from the aisle to the side wall.
            let span = (w - aisle) / 2
            for r in 0..<rows {
                addInstance(cube, wall, translate([side * (aisle / 2 + span / 2), h / 2, -Float(r) * bay]) * scale([span, h, 0.2]))
            }
        }

        let files = Scene.galleryFiles()
        var models: [(GLTFModel, URL)] = []
        for url in files {
            do { models.append((try GLTFLoader.load(url), url)) } catch { print("Storeroom: skipping \(url.lastPathComponent): \(error)") }
        }
        guard !models.isEmpty else { print("Storeroom: no models in \(Scene.assetsDirectory.path)"); return }
        let plinthHeight: Float = 0.3
        var placed = 0
        func place(_ p: SIMD3<Float>, facing yaw: Float) {
            let (model, url) = models[placed % models.count]
            placed += 1
            addInstance(cube, plinth, translate(p + [0, plinthHeight / 2, 0]) * scale([1.3, plinthHeight, 1.3]))
            addModel(model, url: url, transform: translate(p + [0, plinthHeight, 0]) * rotate(yaw, [0, 1, 0]) * Scene.placement(model, size: 2))
        }
        for r in 0..<rows {
            let z = -(Float(r) + 0.5) * bay
            for side: Float in [-1, 1] {   // two a bay, facing the aisle
                for x: Float in [2.5, 6.5] { place([side * (aisle / 2 + x), 0, z], facing: side * .pi / 2) }
            }
            if r % 2 == 1 { place([0, 0, z], facing: 0) }   // one in the aisle, facing the way in
        }

        // A light over every bay and over the aisle every row, warm and cool.
        let warm = SIMD3<Float>(1.0, 0.85, 0.65), cool = SIMD3<Float>(0.75, 0.85, 1.0)
        for r in 0..<rows {
            let z = -(Float(r) + 0.5) * bay
            for p in [SIMD3<Float>(-(aisle / 2 + 4.5), 3.8, z), SIMD3<Float>(aisle / 2 + 4.5, 3.8, z), SIMD3<Float>(0, 4.2, z + bay / 2)] {
                let color = (p.x == 0 ? cool : warm) / dot(p.x == 0 ? cool : warm, [0.2126, 0.7152, 0.0722])
                addLight(color: color * 4, radius: 0.08, sphereMesh: sphere) { _ in p }
            }
        }
        print("Storeroom: \(placed) models (\(models.count) different) in \(rows) rows")
        defaultCamera = Scene.storeroomCamera
    }

    /// At the way in, looking down the aisle.
    static let storeroomCamera: Camera = {
        var c = Camera()
        c.position = [0, 1.7, 2.5]
        c.pitch = -0.04
        return c
    }()
}
