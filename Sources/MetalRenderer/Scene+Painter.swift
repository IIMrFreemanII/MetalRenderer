import Foundation
import simd

/// The painter workshop: one object on a plinth (`SceneSettings.painterWorkshop.subject`: a shape of the material
/// workshop's, the base character in its bind pose, or the largest part of a glTF model), painted with the
/// workshop's document whatever the assignments say (Scene.paintSubject), against the material workshop's backdrops.
/// The camera turns about it (`focus`, SceneKind.orbits).
extension Scene {
    func buildPainterWorkshop() {
        let kit = Kit(self)
        let w = settings.painterWorkshop
        materialBackdrop(w.backdrop, kit)
        let plinth = addPBRMaterial(baseColor: [0.16, 0.16, 0.17], metallic: 0, roughness: 0.5)
        let grey = addPBRMaterial(baseColor: [0.5, 0.5, 0.5], metallic: 0, roughness: 0.55)
        kit.box([0, 0.05, 0], [2, 0.1, 2], plinth)
        let (mesh, transform, size) = painterSubject(w)
        paintSubject = addInstance(mesh, grey, translate([0, 0.1, 0]) * transform)
        var bounds = AABB()
        bounds.grow([-size.x / 2, 0, -size.z / 2])
        bounds.grow([size.x / 2, 0.1 + size.y, size.z / 2])
        focus = bounds
        let distance = max(3.4, 1.9 * max(size.x, size.y))
        defaultCamera = Scene.camera([0, 0.1 + 0.6 * size.y, distance], pitch: -0.16)
    }

    /// The subject's mesh, its placement over the plinth and its size.
    private func painterSubject(_ w: PainterWorkshopSettings) -> (Int, float4x4, SIMD3<Float>) {
        switch w.subject {
        case .sphere: return materialShape(.sphere)
        case .cube: return materialShape(.cube)
        case .cylinder: return materialShape(.cylinder)
        case .plane: return materialShape(.plane)
        case .character:
            guard let c = CharacterKit.shared()?.base.character else { return materialShape(.sphere) }
            let mesh = addMesh((c.positions, c.normals, c.indices), uvs: c.uvs, name: "painter/character")
            return (mesh, .init(1), Scene.size(of: c.positions))
        case .model:
            guard let url = Scene.painterModel(w.model), let model = try? GLTFLoader.load(url),
                  let part = model.parts.max(by: { model.meshes[$0.mesh].indices.count < model.meshes[$1.mesh].indices.count })
            else { return materialShape(.sphere) }
            let m = model.meshes[part.mesh]
            // The part as it sits in the model, then scaled to stand 1.6 m at most on the plinth.
            let c = part.transform.columns
            let n3 = float3x3(SIMD3(c.0.x, c.0.y, c.0.z), SIMD3(c.1.x, c.1.y, c.1.z), SIMD3(c.2.x, c.2.y, c.2.z)).inverse.transpose
            let positions = m.positions.map { p -> SIMD3<Float> in let q = part.transform * SIMD4(p, 1); return SIMD3(q.x, q.y, q.z) }
            let normals = m.normals.map { simd_normalize(n3 * $0) }
            let size = Scene.size(of: positions)
            let s = 1.6 / max(size.max(), 1e-6)
            var lo = SIMD3<Float>(repeating: .infinity)
            for p in positions { lo = simd_min(lo, p) }
            let centre = SIMD3<Float>(lo.x + size.x / 2, lo.y, lo.z + size.z / 2)
            let mesh = addMesh((positions.map { ($0 - centre) * s }, normals, m.indices), uvs: m.uvs, name: "painter/\(url.lastPathComponent)")
            return (mesh, .init(1), size * s)
        }
    }

    /// A model's file: a path, or a name (or part of one) among the assets' models.
    static func painterModel(_ name: String) -> URL? {
        if name.isEmpty { return galleryFiles().first }
        if FileManager.default.fileExists(atPath: name) { return URL(fileURLWithPath: name) }
        return galleryFiles().first { $0.lastPathComponent.lowercased().contains(name.lowercased()) }
    }

    private static func size(of positions: [SIMD3<Float>]) -> SIMD3<Float> {
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return lo.x <= hi.x ? hi - lo : .zero
    }
}
