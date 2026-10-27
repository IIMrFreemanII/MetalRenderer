import EngineCore
import Foundation
import Modeling
import Procedural
import simd

/// Procedural assets (`Assets/Procedural/<slug>.proc.json`) in a scene: what a scene file's `proc:<slug>?…` object
/// places. Each is cooked with its values when the scene is built (from the generated cache when the same asset and
/// values were cooked before); copies with the same values share one mesh; the points that name an asset (their
/// `instance`) place it. An asset whose frames cook differently plays them: each distinct frame of its network's
/// range (`frames=a-b`) is cooked when the scene is built, and its instance takes each frame's mesh by the scene's
/// clock, 24 a second, round again. `frame=<n>` pins it to one frame.
extension Scene {
    /// A placed asset that plays its frames: its instance and each frame's mesh and material (frames that cook the same
    /// share them), and the frame shown.
    package struct ProcFlipbook {
        package var instance: Int
        package var frames: [(mesh: Int, material: Int)]
        package var shown = 0

        /// Frame `k` of `count` at the scene's time `t`.
        static func frame(at t: Float, count: Int) -> Int {
            let f = Int((t * ProcExprContext.fps).rounded(.down))
            return ((f % count) + count) % count
        }
    }

    /// The asset `reference` names (what follows `proc:`) at `transform`, with its materials (or `material`).
    /// `motion`: where it is at the scene's time, when what placed it moves (an asset's points that play their frames).
    package func addProcAsset(_ reference: String, transform: float4x4, material override: Int? = nil, depth: Int = 0,
                              motion: ((Float) -> float4x4)? = nil) {
        let ref = ProcAssetReference(reference)
        guard let asset = ProcStore.read(ref.slug) else {
            print("Scene file: no procedural asset \(ref.slug)")
            return
        }
        let values = asset.values(ref.values)
        // The frames it plays, by their cook keys: `pick[k]` is frame k's index into the frames cooked.
        var environment = ProcEnvironment.assets
        var cookFrames = [ref.frame], pick = [0]
        let range = ref.frames ?? asset.graph.frames
        if !ref.pinned, range.count > 1, let keys = asset.frameKeys(values, environment: environment, frames: range), Set(keys).count > 1 {
            cookFrames = []
            pick = []
            var first: [UInt64: Int] = [:]
            for (k, key) in keys.enumerated() {
                if let j = first[key] { pick.append(j); continue }
                first[key] = cookFrames.count
                pick.append(cookFrames.count)
                cookFrames.append(Float(range.lowerBound + k))
            }
        }
        let start = Date()
        var cooks: [ProcAsset.Cooked] = []
        var looks: [(mesh: Int, material: Int)?] = []
        for f in cookFrames {
            environment.frame = f
            guard let (key, cooked) = procCook(asset, ref, values, environment) else { return }
            cooks.append(cooked)
            looks.append(procMesh(key, cooked.rendered, slug: ref.slug).map { ($0.mesh, override ?? $0.material) })
        }
        if cookFrames.count > 1 {
            print(String(format: "Procedural: %@ plays %d frames, %d distinct, in %.0f ms", ref.asset, pick.count, cookFrames.count,
                         Date().timeIntervalSince(start) * 1000))
        }

        if cookFrames.count > 1, looks.contains(where: { $0 != nil }) {
            // Its frames with nothing to draw take a mesh of one empty triangle.
            let frames = pick.map { looks[$0] ?? (procEmpty(), looks.compactMap { $0 }.first?.material ?? 0) }
            let i = addInstance(frames[0].mesh, frames[0].material, motion?(0) ?? transform)
            instances[i].flipbook = true
            instances[i].animation = motion
            procFlipbooks.append(ProcFlipbook(instance: i, frames: frames))
        } else if let look = looks[0] {
            let i = addInstance(look.mesh, look.material, motion?(0) ?? transform)
            instances[i].animation = motion
        }

        // The assets its points place (not past a few levels of assets placing assets).
        guard depth < 4 else { return }
        let placements = cooks[0].instances
        guard cookFrames.count > 1 || motion != nil else {
            for (a, t) in placements { addPlaced(a, transform: transform * t, material: override, depth: depth) }
            return
        }
        // They follow its frames when every frame places the same assets in the same order.
        let follow = cooks.allSatisfy { $0.instances.map(\.asset) == placements.map(\.asset) }
        if !follow { print("Procedural: \(ref.asset)'s frames place different assets: they stay as on its first frame") }
        for (j, (a, t0)) in placements.enumerated() {
            let locals = follow ? pick.map { cooks[$0].instances[j].transform } : [t0]
            let place: (Float) -> float4x4 = { t in
                (motion?(t) ?? transform) * locals[ProcFlipbook.frame(at: t, count: locals.count)]
            }
            addPlaced(a, transform: place(0), material: override, depth: depth, motion: place)
        }
    }

    /// An asset a point names, at `transform` (`motion`: at the scene's time). A model's or a prefab's instances are
    /// moved with it.
    private func addPlaced(_ a: String, transform: float4x4, material override: Int?, depth: Int, motion: ((Float) -> float4x4)? = nil) {
        if a.hasPrefix("proc:") {
            addProcAsset(String(a.dropFirst(5)), transform: transform, material: override, depth: depth + 1, motion: motion)
            return
        }
        let before = instances.count
        if a.hasPrefix("mesh:") {
            addModelAsset(String(a.dropFirst(5)), transform: transform, material: override)
        } else if a.hasPrefix("prefab:"), let make = SceneFile.prefab(String(a.dropFirst(7))) {
            _ = make(self, transform, override)
        }
        guard let motion else { return }
        let back = transform.inverse
        for i in before..<instances.count {
            let own = instances[i].animation, at = instances[i].transform
            instances[i].animation = { t in motion(t) * back * (own?(t) ?? at) }
        }
    }

    /// The asset cooked at `environment`'s frame, from this scene's cooks, the generated cache or a cook; its cache name.
    private func procCook(_ asset: ProcAsset, _ ref: ProcAssetReference, _ values: [String: ProcParam],
                          _ environment: ProcEnvironment) -> (String, ProcAsset.Cooked)? {
        let key = asset.cacheName(values, environment: environment)
        if let c = proceduralCooks[key] { return (key, c) }
        let start = Date()
        switch asset.cached(values, environment: environment) {
        case .success(let c):
            proceduralCooks[key] = c
            let ms = Date().timeIntervalSince(start) * 1000
            if ms > 50 { print(String(format: "Procedural: %@ in %.0f ms", ref.asset, ms)) }
            return (key, c)
        case .failure(let e):
            print("Procedural: \(ref.asset): \(e.message)")
            return nil
        }
    }

    /// The mesh of a cook (by its cache name: copies share it) and its first material; nil: no triangles.
    private func procMesh(_ key: String, _ r: ModelAsset.Rendered, slug: String) -> (mesh: Int, material: Int)? {
        guard r.triangleCount > 0 else { return nil }
        if let m = proceduralMeshes[key] { return m }
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
        // Named by the cook's cache name (the asset, its values, the frame): the same name is the same triangles.
        let mesh = addMesh((r.positions, r.normals, r.indices), uvs: r.uvs, materials: offsets, name: "proc:\(key)", label: slug)
        let m = (mesh, several ? first : first + Int(r.triangleMaterial.first ?? 0))
        proceduralMeshes[key] = m
        return m
    }

    /// A mesh of one triangle with no area: a playing asset's frames with nothing to draw.
    private func procEmpty() -> Int {
        if let m = procEmptyMesh { return m }
        let m = addMesh(([SIMD3<Float>](repeating: .zero, count: 3), [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: 3), [0, 1, 2]),
                        name: "proc:empty", label: "empty frame")
        procEmptyMesh = m
        return m
    }

    /// The playing assets' instances given their frame's mesh at the scene's time `t` (Scene.update); true if one
    /// changed.
    func showProcFrames(at t: Float) -> Bool {
        var changed = false
        for k in procFlipbooks.indices {
            let f = ProcFlipbook.frame(at: t, count: procFlipbooks[k].frames.count)
            guard f != procFlipbooks[k].shown else { continue }
            let i = procFlipbooks[k].instance, look = procFlipbooks[k].frames[f]
            procFlipbooks[k].shown = f
            if instances[i].mesh != look.mesh || instances[i].material != look.material {
                instances[i].mesh = look.mesh
                instances[i].material = look.material
                changed = true
            }
        }
        return changed
    }
}
