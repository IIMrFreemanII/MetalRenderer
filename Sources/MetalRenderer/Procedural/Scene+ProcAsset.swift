import EngineCore
import Foundation
import Modeling
import Procedural
import simd

/// Procedural assets (`Assets/Procedural/<slug>.proc.json`) in a scene: what a scene file's `proc:<slug>?…` object
/// places. Each is cooked with its values when the scene is built (from the generated cache when the same asset and
/// values were cooked before); copies with the same values share one mesh; the points that name an asset (their
/// `instance`) place it.
extension Scene {
    /// The asset `reference` names (what follows `proc:`) at `transform`, with its materials (or `material`).
    package func addProcAsset(_ reference: String, transform: float4x4, material override: Int? = nil, depth: Int = 0) {
        let ref = ProcAssetReference(reference)
        guard let asset = ProcStore.read(ref.slug) else {
            print("Scene file: no procedural asset \(ref.slug)")
            return
        }
        let values = asset.values(ref.values)
        let key = asset.cacheName(values, environment: .assets)
        let cooked: ProcAsset.Cooked
        if let c = proceduralCooks[key] {
            cooked = c
        } else {
            let start = Date()
            switch asset.cached(values) {
            case .success(let c):
                cooked = c
                proceduralCooks[key] = c
                let ms = Date().timeIntervalSince(start) * 1000
                if ms > 50 { print(String(format: "Procedural: %@ in %.0f ms", ref.asset, ms)) }
            case .failure(let e):
                print("Procedural: \(ref.asset): \(e.message)")
                return
            }
        }
        let r = cooked.rendered
        if r.triangleCount > 0 {
            if proceduralMeshes[key] == nil {
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
                let mesh = addMesh((r.positions, r.normals, r.indices), uvs: r.uvs, materials: offsets, name: "proc:\(ref.slug)", label: ref.slug)
                proceduralMeshes[key] = (mesh, several ? first : first + Int(r.triangleMaterial.first ?? 0))
            }
            let (mesh, base) = proceduralMeshes[key]!
            _ = addInstance(mesh, override ?? base, transform)
        }
        // The assets its points place (not past a few levels of assets placing assets).
        guard depth < 4 else { return }
        for (a, t) in cooked.instances {
            let world = transform * t
            if a.hasPrefix("proc:") {
                addProcAsset(String(a.dropFirst(5)), transform: world, material: override, depth: depth + 1)
            } else if a.hasPrefix("mesh:") {
                addModelAsset(String(a.dropFirst(5)), transform: world, material: override)
            } else if a.hasPrefix("prefab:"), let make = SceneFile.prefab(String(a.dropFirst(7))) {
                _ = make(self, world, override)
            }
        }
    }
}
