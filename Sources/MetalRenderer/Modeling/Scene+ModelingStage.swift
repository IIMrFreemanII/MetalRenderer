import EngineCore
import Foundation
import Modeling
import simd

/// The Modeller's Rendered view: a stage scene (the material workshop's studio, its floor under the model) with the
/// model being edited on it, path traced by a renderer of its own in the Modeller's window. The model comes through
/// `ModelingStage` (set by the window, read when the scene is made): a new revision makes the scene again.
package enum ModelingStage {
    private static let lock = NSLock()
    private static var model: ModelAsset.Rendered?
    private static var count = 0

    /// The model the next stage is made with; returns its revision.
    @discardableResult
    package static func set(_ m: ModelAsset.Rendered) -> Int {
        lock.lock()
        defer { lock.unlock() }
        model = m
        count += 1
        return count
    }

    /// Without a window's model (a benchmark's shot): `METALRENDERER_MODEL=<slug>`, a model asset, or a primitive's
    /// name (`head`, `torus` …) subdivided twice.
    static func fromEnvironment() -> ModelAsset.Rendered? {
        guard let name = ProcessInfo.processInfo.environment["METALRENDERER_MODEL"], !name.isEmpty else { return nil }
        if let p = Primitive(rawValue: name) {
            var m = CatmullClark.subdivide(p.mesh(), levels: 2)
            m.setSmooth(true, onlySelected: false)
            let t = TriangleMesh(m)
            return ModelAsset.Rendered(positions: t.positions, normals: t.normals, uvs: t.uvs.map { SIMD2($0.x, 1 - $0.y) }, indices: t.indices,
                                       triangleMaterial: t.triangleMaterial,
                                       materials: [MaterialSlot(name: "Clay", baseColor: [0.8, 0.45, 0.3, 1], roughness: 0.45)])
        }
        return ModelStore.url(name).flatMap(ModelAsset.readRendered)
    }

    package static var current: (model: ModelAsset.Rendered?, revision: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (model, count)
    }
}

extension SceneKind {
    package static let modelingStage = SceneKind("modelingStage")
}

extension Scene {
    package func buildModelingStage() {
        let kit = Kit(self)
        let model = ModelingStage.current.model ?? ModelingStage.fromEnvironment()
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for p in model?.positions ?? [] { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        if lo.x > hi.x { lo = [-1, -1, -1]; hi = [1, 1, 1] }
        // The studio a little under the model (the editor's floor is at 0; a model often goes below it).
        let floor = min(0, lo.y) - 0.001
        object("Backdrop") {
            let first = instances.count
            materialBackdrop(.studio, kit)
            var lift = matrix_identity_float4x4
            lift.columns.3 = [0, floor, 0, 1]
            for i in first..<instances.count { instances[i].transform = lift * instances[i].transform; instances[i].prevTransform = instances[i].transform }
        }
        if let model, model.triangleCount > 0 {
            object("Model") {
                let first = materials.count
                for slot in model.materials {
                    materials.append(GPUMaterial(albedo: SIMD4(SIMD3(slot.baseColor.x, slot.baseColor.y, slot.baseColor.z), slot.metallic),
                                                 emission: SIMD4(slot.emission, slot.roughness), params: SIMD4(1, 1, 0, 0),
                                                 textures: SIMD4(repeating: .max)))
                }
                if model.materials.isEmpty { _ = addMaterial(albedo: [0.7, 0.7, 0.7]) }
                let several = Set(model.triangleMaterial).count > 1
                let mesh = addMesh((model.positions, model.normals, model.indices), uvs: model.uvs,
                                   materials: several ? model.triangleMaterial.map { UInt8(min(255, Int($0))) } : nil, name: "modelingStage")
                _ = addInstance(mesh, several ? first : first + Int(model.triangleMaterial.first ?? 0), matrix_identity_float4x4)
            }
        }
        var bounds = AABB()
        bounds.grow(lo)
        bounds.grow(hi)
        focus = bounds
    }
}

extension Renderer {
    /// The stage's camera: the Modeller's view (its eye, its direction, its vertical field of view).
    package func setStageCamera(eye: SIMD3<Float>, forward f: SIMD3<Float>, fovY: Float) {
        camera.position = eye
        camera.pitch = asin(max(-1, min(1, f.y)))
        camera.yaw = atan2(f.x, -f.z)
        camera.fovY = fovY
    }

    /// The stage made again with the model as it now is.
    package func remakeStage() {
        if settings.scene.kind != .modelingStage { settings.scene.kind = .modelingStage } else { remakeScene(because: "the model changed") }
    }
}
