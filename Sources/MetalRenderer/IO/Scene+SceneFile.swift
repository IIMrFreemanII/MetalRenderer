import EngineCore
import Foundation
import Physics
import Plants
import simd

/// What a scene file (SceneFile) places in a scene, and what the editor needs to move it: each object's instances,
/// so a moved object moves them (Scene.moveInstances) and the file can be written again.
extension Scene {
    /// The kit's shapes, made once a scene (SceneFile's prefabs).
    package enum KitShape: Int { case quad, box, ball }

    /// Shape `shape`'s mesh in this scene, made the first time it is asked for.
    package func kitMesh(_ shape: KitShape) -> Int {
        if let m = kitMeshes[shape.rawValue] { return m }
        let m: Int
        switch shape {
        case .quad: m = addMesh(Scene.quadMesh(), label: "quad")
        case .box: m = addMesh(Scene.cubeMesh(), label: "box")
        case .ball: m = addMesh(Scene.icosphere(subdivisions: 3), label: "ball")
        }
        kitMeshes[shape.rawValue] = m
        return m
    }

    /// A plain grey material, made the first time it is asked for: a placed object's when neither it nor its asset
    /// names one.
    package func defaultMaterial() -> Int {
        if let m = namedMaterials[""] { return m }
        let m = addMaterial(albedo: [0.7, 0.7, 0.7])
        namedMaterials[""] = m
        return m
    }

    /// Material `index` under `name`, for a scene file's objects to name (SceneFile.Object.material).
    package func nameMaterial(_ name: String, _ index: Int) { namedMaterials[name] = index }

    /// Places what `file` lists: each object by its asset at its world transform, in the outline under its name; the
    /// lights; the camera. Remembers them (`placed`) for the editor. Returns each object's instances.
    @discardableResult
    package func place(_ file: SceneFile) -> [[Int]] {
        var made: [[Int]] = []
        for o in file.objects {
            let transform = o.world(in: file.objects)
            let material = o.material.isEmpty ? nil : namedMaterials[o.material]
            if !o.material.isEmpty && material == nil { print("Scene file: \(o.name): no material named \(o.material)") }
            let first = instances.count
            object(o.name) {
                if o.asset.hasPrefix("prefab:"), let make = SceneFile.prefab(String(o.asset.dropFirst("prefab:".count))) {
                    _ = make(self, transform, material)
                } else if o.asset.hasPrefix("model:") {
                    let url = Scene.assetsDirectory.appendingPathComponent(String(o.asset.dropFirst("model:".count)))
                    do {
                        let model = try GLTFLoader.load(url)
                        addModel(model, url: url, transform: transform)
                    } catch {
                        print("Scene file: \(o.name): could not load \(url.path): \(error)")
                    }
                } else {
                    print("Scene file: \(o.name): no asset \(o.asset)")
                }
            }
            made.append(Array(first..<instances.count))
        }
        for l in file.lights {
            let kind: LightKind
            switch l.kind {
            case .sphere: kind = .sphere(radius: l.size.x)
            case .spot: kind = .spot(radius: l.size.x, inner: l.size.y, outer: l.size.z)
            case .rect: kind = .rect(width: l.size.x, height: l.size.y)
            case .tube: kind = .tube(length: l.size.x, radius: l.size.y)
            case .sun: kind = .sun(angularRadius: l.size.x)
            }
            let pose = LightPose(position: l.position, direction: normalize(l.direction))
            section(l.name)
            addLight(kind, color: l.color, motion: .constant) { _ in pose }
        }
        if let camera = file.camera { defaultCamera = camera }
        placed = PlacedFile(file: file, instances: made, worlds: file.objects.map { $0.world(in: file.objects) })
        return made
    }
}

/// A scene file as it was placed in its scene: the editor moves an object's instances and writes the file again.
package struct PlacedFile {
    package var file: SceneFile
    /// Each object's instances, in the file's order, and the world transform they stand at.
    package var instances: [[Int]]
    package var worlds: [float4x4]

    /// The object an instance belongs to, if one does.
    package func object(of instance: Int) -> Int? { instances.firstIndex { $0.contains(instance) } }
}
