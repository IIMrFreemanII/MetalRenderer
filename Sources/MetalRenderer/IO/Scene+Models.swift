import Foundation
import ImageIO
import simd

extension Scene {
    // MARK: - glTF models

    /// Where the Gallery scene finds its models: `METALRENDERER_ASSETS`, or `Assets/` next to `Package.swift`.
    static let assetsDirectory: URL = {
        if let dir = ProcessInfo.processInfo.environment["METALRENDERER_ASSETS"] { return URL(fileURLWithPath: dir) }
        return SourceTree.packageRoot.appendingPathComponent("Assets")
    }()

    /// The glTF files in `assetsDirectory`, sorted by name. `METALRENDERER_GALLERY="owl|demon"` keeps the files whose names
    /// contain one of these strings (quicker test runs).
    static func galleryFiles() -> [URL] {
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
    static func placement(_ model: GLTFModel, size: Float) -> float4x4 {
        let b = model.bounds
        guard !b.isEmpty else { return matrix_identity_float4x4 }
        let s = size / max((b.hi - b.lo).max(), 1e-6)
        return scale(s) * translate([-(b.lo.x + b.hi.x) / 2, -b.lo.y, -(b.lo.z + b.hi.z) / 2])
    }

    /// Adds every part of `model` as an instance at `transform` (times the part's own transform), with the model's
    /// materials and textures. `animation`, if given, replaces `transform` over time.
    func addModel(_ model: GLTFModel, url: URL, transform: float4x4, animation: ((Float) -> float4x4)? = nil) {
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
    func addModelMaterials(_ model: GLTFModel, url: URL) -> Int {
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
    static let gltfLightScale: Float = 20

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
    func addExtraModel(_ extra: ExtraModel) {
        do {
            let model = try GLTFLoader.load(URL(fileURLWithPath: extra.path))
            addModel(model, url: URL(fileURLWithPath: extra.path),
                     transform: translate(extra.position) * rotate(extra.yaw, [0, 1, 0]) * Scene.placement(model, size: 1.6))
        } catch {
            print("Could not load \(extra.path): \(error)")
        }
    }

    /// Gallery: the models in `Assets/` on plinths in an arc, 1.6 m at their largest side, under 8 moving lights.
    /// Two of them turn slowly (dynamic instances); the rest are static.
    func buildGallery() {
        let quad = addMesh(Scene.quadMesh(), label: "quad")
        let cube = addMesh(Scene.cubeMesh(), label: "box")
        let sphere = addMesh(Scene.icosphere(subdivisions: 2), label: "ball")
        let floor = addPBRMaterial(baseColor: [0.32, 0.31, 0.30], metallic: 0, roughness: 0.25)   // polished stone
        let wall = addMaterial(albedo: [0.70, 0.70, 0.68])
        let plinth = addPBRMaterial(baseColor: [0.62, 0.62, 0.64], metallic: 1, roughness: 0.35)   // brushed steel

        let w: Float = 26, h: Float = 7, d: Float = 18
        object("Hall/Floor") { addInstance(quad, floor, translate([0, 0, 0]) * scale([w, 1, d])) }
        object("Hall/Back wall") { addInstance(quad, wall, translate([0, h / 2, -d / 2]) * rotate(.pi / 2, [1, 0, 0]) * scale([w, 1, h])) }
        object("Hall/Left wall") { addInstance(quad, wall, translate([-w / 2, h / 2, 0]) * rotate(-.pi / 2, [0, 0, 1]) * scale([h, 1, d])) }
        object("Hall/Right wall") { addInstance(quad, wall, translate([w / 2, h / 2, 0]) * rotate(.pi / 2, [0, 0, 1]) * scale([h, 1, d])) }

        let files = Scene.galleryFiles()
        let plinthHeight: Float = 0.3
        let start = CFAbsoluteTimeGetCurrent()
        var triangles = 0
        loadStep?.set(done: 0, total: files.count)
        beginObject("Exhibits")
        defer { endObject() }
        for (i, url) in files.enumerated() {
            if loadStep?.isCancelled == true { break }   // another scene was asked for: this one is thrown away
            loadStep?.set(detail: url.deletingPathExtension().lastPathComponent)
            defer { loadStep?.advance() }
            let model: GLTFModel
            do {
                model = try GLTFLoader.load(url)
            } catch {
                print("Gallery: skipping \(url.lastPathComponent): \(error)")
                continue
            }
            triangles += model.triangleCount
            // Arc of radius 6 around (0, 0, 1), from -60 to +60 degrees, each model facing the arc's centre.
            let a = files.count > 1 ? (-60 + 120 * Float(i) / Float(files.count - 1)) * .pi / 180 : 0
            let p = SIMD3<Float>(6 * sin(a), 0, 1 - 6 * cos(a))
            object("Plinths/\(model.name)") { addInstance(cube, plinth, translate(p + [0, plinthHeight / 2, 0]) * scale([1.3, plinthHeight, 1.3])) }
            let base = translate(p + [0, plinthHeight, 0]) * rotate(-a, [0, 1, 0])
            let place = Scene.placement(model, size: 1.6)
            if i % 5 == 1 {   // turntables
                let speed: Float = i % 2 == 0 ? 0.25 : -0.2
                addModel(model, url: url, transform: base * place) { t in base * rotate(speed * t, [0, 1, 0]) * place }
            } else {
                addModel(model, url: url, transform: base * place)
            }
            print(String(format: "Gallery: %@ (%d triangles, %d images)", model.name, model.triangleCount, model.images.count))
        }
        print(String(format: "Gallery: %d models, %d triangles, loaded in %.1f s", files.count, triangles,
                     CFAbsoluteTimeGetCurrent() - start))

        // 8 lights drifting above the arc, warm and cool.
        var rng = SplitMix64(seed: 0x6A11_E7)
        let colors: [SIMD3<Float>] = [[1.0, 0.85, 0.65], [1.0, 0.55, 0.25], [0.45, 0.65, 1.0], [0.85, 0.75, 1.0]]
        beginObject("Lights")
        defer { endObject() }
        for j in 0..<8 {
            let color = colors[j % colors.count] / dot(colors[j % colors.count], [0.2126, 0.7152, 0.0722])
            let c = SIMD3<Float>(rng.range(-6, 6), rng.range(2.2, 3.6), rng.range(-4, 3))
            let amp = SIMD3<Float>(rng.range(1, 3), rng.range(0.2, 0.6), rng.range(0.5, 2))
            let f = SIMD3<Float>(rng.range(0.1, 0.3), rng.range(0.2, 0.5), rng.range(0.1, 0.3))
            let phase = rng.range(0, 2 * .pi)
            addLight(color: color * 5, radius: 0.08, sphereMesh: sphere) { t in
                c + amp * SIMD3(sin(f.x * t + phase), sin(f.y * t + 2 * phase), cos(f.z * t + phase))
            }
        }
        defaultCamera = Scene.galleryCamera
    }

    static let galleryCamera: Camera = {
        var c = Camera()
        c.position = [0, 1.8, 4.5]
        c.pitch = -0.1
        return c
    }()
}
