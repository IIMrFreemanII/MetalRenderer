import EngineCore
import Foundation
import Modeling
import simd

/// Model assets (the Modeller's, `Assets/Models/<slug>.mrmesh`) in a scene: what a scene file's `mesh:<slug>` object
/// places, and a scene's meshes taken out again to edit.
extension Scene {
    /// The asset's rendered mesh at `transform`, with its materials (or `material` in their place).
    package func addModelAsset(_ slug: String, transform: float4x4, material override: Int? = nil) {
        guard let url = ModelStore.url(slug), let r = ModelAsset.readRendered(url), r.triangleCount > 0 else {
            print("Scene file: no model asset \(slug)")
            return
        }
        let first = materials.count
        for slot in r.materials {
            materials.append(GPUMaterial(albedo: SIMD4(SIMD3(slot.baseColor.x, slot.baseColor.y, slot.baseColor.z), slot.metallic),
                                         emission: SIMD4(slot.emission, slot.roughness),
                                         params: SIMD4(1, 1, 0, 0),
                                         textures: SIMD4(repeating: .max)))
        }
        if r.materials.isEmpty { _ = addMaterial(albedo: [0.7, 0.7, 0.7]) }
        let several = Set(r.triangleMaterial).count > 1
        let offsets: [UInt8]? = several ? r.triangleMaterial.map { UInt8(min(255, Int($0))) } : nil
        let mesh = addMesh((r.positions, r.normals, r.indices), uvs: r.uvs, materials: offsets, name: "mesh:\(slug)", label: slug)
        let base = several ? first : first + Int(r.triangleMaterial.first ?? 0)
        _ = addInstance(mesh, override ?? base, transform)
    }

    /// Instances as a model to edit: each its mesh (welded back into a surface) at its world transform, with its
    /// material. Nil if the scene has let go of its arrays (the open world), or none of them is a plain mesh.
    package func modelingDocument(of instances: [Int], name: String) -> ModelingDocument? {
        guard !positions.isEmpty else { return nil }
        var doc = ModelingDocument()
        doc.name = name
        for (k, i) in instances.enumerated() where i < self.instances.count {
            let inst = self.instances[i]
            guard inst.virtualMesh < 0, inst.mesh >= 0, inst.mesh < meshes.count, !borrowed.contains(where: { $0.mesh == inst.mesh }) else { continue }
            let m = meshes[inst.mesh]
            let range = Int(m.firstIndex)..<Int(m.firstIndex + m.indexCount)
            guard range.upperBound <= indices.count, !range.isEmpty else { continue }
            let own = indices[range]
            let lo = Int(own.min()!), hi = Int(own.max()!)
            let welded = GLTFModels.weld(positions: Array(positions[lo...hi]), normals: Array(normals[lo...hi]), uvs: Array(uvs[lo...hi]),
                                         indices: own.map { $0 - UInt32(lo) })
            var object = ModelObject(name: instances.count > 1 ? "\(name).\(k)" : name, mesh: welded)
            // Per triangle materials, as slots.
            var slots: [Int: UInt16] = [:]
            var list: [MaterialSlot] = []
            let triFirst = Int(m.firstIndex) / 3
            for f in 0..<object.mesh.faceCount {
                let t = triFirst + f
                let off = t < triangleMaterials.count ? Int(triangleMaterials[t]) : 0
                let mi = inst.material + off
                if slots[mi] == nil {
                    slots[mi] = UInt16(list.count)
                    let gm = mi < materials.count ? materials[mi] : GPUMaterial(albedo: [0.7, 0.7, 0.7, 0], emission: [0, 0, 0, 0.5], params: [1, 1, 0, 0], textures: SIMD4(repeating: .max))
                    list.append(MaterialSlot(name: "Material.\(list.count)", baseColor: SIMD4(gm.albedo.x, gm.albedo.y, gm.albedo.z, 1),
                                             metallic: gm.albedo.w, roughness: gm.emission.w, emission: SIMD3(gm.emission.x, gm.emission.y, gm.emission.z)))
                }
                if f < object.mesh.faceCount { object.mesh.faceMaterial[f] = slots[mi]! }
            }
            if !list.isEmpty { object.materials = list }
            let t = inst.transform
            let c0 = SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z), c1 = SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z)
            let c2 = SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            let s = SIMD3(simd_length(c0), simd_length(c1), simd_length(c2))
            object.transform = ObjectTransform(location: SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z),
                                               rotation: ObjectTransform.euler(float3x3(c0 / max(s.x, 1e-9), c1 / max(s.y, 1e-9), c2 / max(s.z, 1e-9))),
                                               scale: s)
            doc.objects.append(object)
        }
        guard !doc.objects.isEmpty else { return nil }
        doc.active = 0
        doc.selection = Set(doc.objects.map(\.id))
        return doc
    }
}
