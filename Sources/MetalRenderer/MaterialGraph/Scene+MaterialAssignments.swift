import Characters
import Effects
import EngineCore
import Foundation
import Materials
import Physics
import Plants

extension Scene {
    /// The scene's assignments (SceneSettings.materialAssignments): each material whose fingerprint still matches
    /// becomes the procedural material of its graph. Warnings for the stale ones.
    package func applyMaterialAssignments() {
        guard !settings.kind.isWorld else { return }
        let entries = MaterialAssignments.resolve(settings.materialAssignments).scenes[MaterialAssignments.scope(settings)] ?? []
        guard !entries.isEmpty else { return }
        let catalog = MaterialCatalog.resolve(settings.materials)
        for e in entries {
            guard e.material < materials.count, MaterialAssignments.fingerprint(materials[e.material]) == e.fingerprint else {
                print("Materials: the assignment of \(e.graph) to material \(e.material) is stale (the scene's materials changed)")
                continue
            }
            makeProcedural(e.material, graph: e.graph, catalog: catalog)
        }
    }
}

extension MaterialAssignments {
    /// The scene `s` is: its kind, and what its materials' order depends on.
    package static func scope(_ s: SceneSettings) -> String { s.kind.definition.scope?(s) ?? s.kind.envName }
}

extension PaintAssignments {
    /// The entries of the scene `s` is.
    package func entries(_ s: SceneSettings) -> [Entry] { entries(scope: MaterialAssignments.scope(s)) }

    /// `s`'s instance `instance` painted with `document` (nil: not painted).
    package mutating func set(_ s: SceneSettings, instance: Int, fingerprint: String, document: String?) {
        set(scope: MaterialAssignments.scope(s), instance: instance, fingerprint: fingerprint, document: document)
    }
}

extension PaintMesh {
    /// Mesh `m` of a scene, out of the shared arrays: the vertices its triangles name (a pose slot's bind pose: the
    /// ones before its `vertexOffset`), renumbered from 0.
    package init(scene: Scene, mesh m: Int) {
        let mesh = scene.meshes[m]
        let range = Int(mesh.firstIndex)..<Int(mesh.firstIndex + mesh.indexCount)
        let own = scene.indices[range]
        let lo = Int(own.min() ?? 0), hi = Int(own.max() ?? 0)
        self.init(positions: Array(scene.positions[lo...hi]), normals: Array(scene.normals[lo...hi]),
                  uvs: Array(scene.uvs[lo...hi]), indices: own.map { $0 - UInt32(lo) })
    }
}
