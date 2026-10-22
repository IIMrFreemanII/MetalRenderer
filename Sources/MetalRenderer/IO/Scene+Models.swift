import Characters
import EngineCore
import Foundation
import ImageIO
import Physics
import Plants
import simd

extension Scene {
    // MARK: - glTF models

    /// Where the Gallery scene finds its models (Assets.directory, in the core).
    package static var assetsDirectory: URL { Assets.directory }

    /// The glTF files in `assetsDirectory`, sorted by name. `METALRENDERER_GALLERY="owl|demon"` keeps the files whose names
    /// contain one of these strings (quicker test runs).
    package static func galleryFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: assetsDirectory, includingPropertiesForKeys: nil)) ?? []
        var models = files.filter { ["glb", "gltf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let only = ProcessInfo.processInfo.environment["METALRENDERER_GALLERY"] {
            let keys = only.split(separator: "|").map { $0.lowercased() }
            models = models.filter { url in keys.contains { url.lastPathComponent.lowercased().contains($0) } }
        }
        return models
    }

    /// Model-space bounds of the loaded models' parts, scaled so the largest side is `size`, standing on y = 0 and
    /// centred on x = z = 0.
    package static func placement(_ model: GLTFModel, size: Float) -> float4x4 {
        let b = model.bounds
        guard !b.isEmpty else { return matrix_identity_float4x4 }
        let s = size / max((b.hi - b.lo).max(), 1e-6)
        return scale(s) * translate([-(b.lo.x + b.hi.x) / 2, -b.lo.y, -(b.lo.z + b.hi.z) / 2])
    }

    /// Adds every part of `model` as an instance at `transform` (times the part's own transform), with the model's
    /// materials and textures. `animation`, if given, replaces `transform` over time.
    package func addModel(_ model: GLTFModel, url: URL, transform: float4x4, animation: ((Float) -> float4x4)? = nil) {
        beginObject(model.name, assets: [AssetKey(kind: .model, name: url.lastPathComponent)])   // the outline's: its parts, its lights
        defer { endObject() }
        let firstMaterial = addModelMaterials(model, url: url)
        let fallback = addMaterial(albedo: [0.7, 0.7, 0.7])   // parts without a material
        addModelLights(model, transform: transform, animation: animation)
        // Big meshes become virtual (cached cluster DAGs); the rest are ordinary meshes.
        let virtualIndices = usesVirtualGeometry
            ? model.meshes.indices.filter { model.meshes[$0].indices.count / 3 >= VirtualGeometryBuilder.minTriangles } : []
        var meshOf: [Int: (mesh: Int, virtual: Int)] = [:]
        if !virtualIndices.isEmpty {
            let built = VirtualGeometryBuilder.meshes(for: url, model: model, indices: virtualIndices, load: loadStep)
            for i in virtualIndices {
                guard let vm = built[i] else { continue }
                virtualMeshes.append(vm)
                virtualMeshNames.append("\(model.name)#\(i)")
                meshOf[i] = (-1, virtualMeshes.count - 1)
            }
        }
        for (i, mesh) in model.meshes.enumerated() where meshOf[i] == nil {
            meshOf[i] = (addMesh((mesh.positions, mesh.normals, mesh.indices), uvs: mesh.uvs), -1)
            label(mesh: meshOf[i]!.mesh, "\(model.name)#\(i)", shared: true)
        }
        for part in model.parts {
            let material = model.meshes[part.mesh].material.map { firstMaterial + $0 } ?? fallback
            let (mesh, virtual) = meshOf[part.mesh]!
            let index: Int
            if let animation {
                index = addInstance(mesh, material, transform * part.transform) { t in animation(t) * part.transform }
            } else {
                index = addInstance(mesh, material, transform * part.transform)
            }
            instances[index].virtualMesh = virtual
            if materials[material].emission.x + materials[material].emission.y + materials[material].emission.z > 0 {
                let m = model.meshes[part.mesh]
                emitterSources[index] = (m.positions, m.uvs, m.indices)
            }
        }
    }

    /// `model`'s materials (and their textures) one after another; the first's index.
    package func addModelMaterials(_ model: GLTFModel, url: URL) -> Int {
        var textureIndex: [Int: UInt32] = [:]   // image * 2 + srgb -> index into `textures`
        func texture(_ ref: GLTFModel.TextureRef?, srgb: Bool) -> UInt32 {
            guard let ref else { return .max }
            let key = ref.image * 2 + (srgb ? 1 : 0)
            if let i = textureIndex[key] { return i }
            textures.append(TextureSource(data: model.images[ref.image].data, srgb: srgb,
                                          name: "\(model.name)/\(model.images[ref.image].name)",
                                          modelPath: url.path, cacheKey: "\(ref.image)-\(srgb ? "srgb" : "linear")"))
            textureIndex[key] = UInt32(textures.count - 1)
            return UInt32(textures.count - 1)
        }
        let firstMaterial = materials.count
        for m in model.materials {
            materials.append(GPUMaterial(
                albedo: SIMD4(SIMD3(m.baseColor.x, m.baseColor.y, m.baseColor.z), m.metallic),
                emission: SIMD4(m.emissive, m.roughness),
                params: SIMD4(1, m.normalScale, 0, 0),
                textures: SIMD4(texture(m.baseColorTexture, srgb: true), texture(m.metallicRoughnessTexture, srgb: false),
                                texture(m.normalTexture, srgb: false), texture(m.emissiveTexture, srgb: true))))
        }
        return firstMaterial
    }

    /// glTF punctual lights to this renderer's units: candela (point, spot) and lux (directional) are photometric,
    /// so / 683 lm/W gives watts per steradian / square metre; this scale then puts them on the scale of the scenes'
    /// lights (a 100 W bulb's 135 cd comes out a little dimmer than the gallery's lights).
    package static let gltfLightScale: Float = 20

    /// Adds `model`'s punctual lights at `transform` (following `animation` if given): points as small sphere lights,
    /// spots as spot lights, directional lights as suns.
    private func addModelLights(_ model: GLTFModel, transform: float4x4, animation: ((Float) -> float4x4)?) {
        for l in model.lights {
            let color = l.color * l.intensity / 683 * Scene.gltfLightScale
            let kind: LightKind
            switch l.kind {
            case .point: kind = .sphere(radius: 0.05)
            case .spot(let inner, let outer): kind = .spot(radius: 0.05, inner: inner, outer: outer)
            case .directional: kind = .sun(angularRadius: 0.27 * .pi / 180)
            }
            let local = l.transform
            func pose(_ m: float4x4) -> LightPose {
                let p = m * local, z = -SIMD3(p.columns.2.x, p.columns.2.y, p.columns.2.z)
                let forward = length(z) > 0 ? normalize(z) : SIMD3<Float>(0, -1, 0)
                if case .directional = l.kind {   // the sun's direction points toward it
                    return LightPose(position: .zero, direction: -forward)
                }
                return LightPose(position: SIMD3(p.columns.3.x, p.columns.3.y, p.columns.3.z), direction: forward)
            }
            if let animation {
                addLight(kind, color: color) { pose(animation($0)) }
            } else {
                let fixed = pose(transform)
                addLight(kind, color: color, motion: .constant) { _ in fixed }
            }
        }
    }

    /// A model the user opened or dropped (`SceneSettings.extraModels`), 1.6 m tall at its position.
    package func addExtraModel(_ extra: ExtraModel) {
        do {
            let model = try GLTFLoader.load(URL(fileURLWithPath: extra.path))
            addModel(model, url: URL(fileURLWithPath: extra.path),
                     transform: translate(extra.position) * rotate(extra.yaw, [0, 1, 0]) * Scene.placement(model, size: 1.6))
        } catch {
            print("Could not load \(extra.path): \(error)")
        }
    }
}

extension Scene {
    /// A file or setting name as the showcase compares them: lower case, underscores as spaces.
    package static func showcaseKey(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "_", with: " ")
    }

    /// The model the showcase shows for `name` (`SceneSettings.showcase`): the first of `galleryFiles()` whose name
    /// contains it, without regard to case ("" = the first one). nil if there is none.
    package static func showcaseFile(_ name: String) -> URL? {
        let files = galleryFiles(), key = showcaseKey(name).trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? files.first : files.first { showcaseKey($0.lastPathComponent).contains(key) }
    }

    /// A model's name for the panel and for `SceneSettings.showcase`: its file name without the extensions and the
    /// " 3d model" the downloads came with ("steampunk owl", "Winged Harpy Warrior").
    package static func showcaseName(_ url: URL) -> String {
        var name = url.lastPathComponent
        while let dot = name.lastIndex(of: "."), ["glb", "gltf"].contains(name[name.index(after: dot)...].lowercased()) {
            name = String(name[..<dot])
        }
        if name.lowercased().hasSuffix(" 3d model") { name = String(name.dropLast(" 3d model".count)) }
        return name.replacingOccurrences(of: "_", with: " ")
    }
}
