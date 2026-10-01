import Foundation
import simd

/// A small Cornell-style room with static objects, animated objects and moving sphere lights, or a stress-test
/// hall with hundreds of moving objects and tens to hundreds of moving lights (`SceneSettings`).
/// All geometry lives in one shared vertex/index buffer; each mesh gets its own
/// primitive acceleration structure and every object is an instance of a mesh.
typealias MeshGeometry = (positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32])

final class Scene {
    struct Instance {
        var mesh: Int
        var material: Int
        var mask: UInt32
        var transform: float4x4
        var prevTransform: float4x4
        var animation: ((Float) -> float4x4)?
    }

    /// An encoded image a material samples (decoded and uploaded by the renderer).
    struct TextureSource {
        var data: Data
        var srgb: Bool                        // colour data (base colour, emissive) vs linear (normal, metallic-roughness)
        var name: String
    }

    struct Light {
        var color: SIMD3<Float>               // radiant intensity (color * power)
        var radius: Float
        var path: (Float) -> SIMD3<Float>     // position over time
        var position = SIMD3<Float>(repeating: 0)
        var sphereInstance = -1               // visible emissive sphere that follows the light
        var group = 0                         // shadow-denoiser channel (see assignLightGroups)
    }

    /// Instance masks. Shadow and GI rays only test `geometry`, so the visible
    /// light spheres never block their own light.
    static let maskGeometry: UInt32 = 1
    static let maskLights: UInt32 = 2

    private(set) var positions: [SIMD3<Float>] = []
    private(set) var normals: [SIMD3<Float>] = []
    private(set) var uvs: [SIMD2<Float>] = []                 // per vertex (zeros for the generated meshes)
    private(set) var textures: [TextureSource] = []
    private(set) var indices: [UInt32] = []
    private(set) var meshes: [GPUMesh] = []
    private(set) var materials: [GPUMaterial] = []
    private(set) var instances: [Instance] = []
    private(set) var lights: [Light] = []
    private var meshBounds: [(SIMD3<Float>, SIMD3<Float>)] = []   // local AABB per mesh
    private(set) var defaultCamera = Camera()
    let settings: SceneSettings

    let skyColor = SIMD3<Float>(0.35, 0.45, 0.65) * 0.8

    init(_ settings: SceneSettings = SceneSettings()) {
        self.settings = settings
        switch settings.kind {
        case .cornell: buildCornell()
        case .stress: buildStress(objects: settings.objects, lights: settings.lights)
        case .gallery: buildGallery()
        }
        for extra in settings.extraModels { addExtraModel(extra) }
        assignLightGroups()
        update(time: 0)
        for i in instances.indices { instances[i].prevTransform = instances[i].transform }
    }

    // MARK: - Animation

    func update(time t: Float) {
        for i in instances.indices {
            instances[i].prevTransform = instances[i].transform
            if let animation = instances[i].animation {
                instances[i].transform = animation(t)
            }
        }
        for l in lights.indices {
            lights[l].position = lights[l].path(t)
            let s = lights[l].sphereInstance
            if s >= 0 {
                instances[s].transform = translate(lights[l].position) * scale(lights[l].radius)
            }
        }
    }

    /// Axis-aligned bounds of all geometry at the current animation time (surfel grid extent),
    /// from each instance's transformed mesh bounds.
    func bounds() -> (SIMD3<Float>, SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for inst in instances where inst.mask == Scene.maskGeometry {
            let (a, b) = meshBounds[inst.mesh]
            for corner in 0..<8 {
                let c = SIMD3<Float>(corner & 1 == 0 ? a.x : b.x, corner & 2 == 0 ? a.y : b.y, corner & 4 == 0 ? a.z : b.z)
                let p = inst.transform * SIMD4<Float>(c, 1)
                lo = simd_min(lo, SIMD3(p.x, p.y, p.z))
                hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
            }
        }
        return (lo, hi)
    }

    // MARK: - GPU data

    func gpuInstanceData() -> [GPUInstanceData] {
        instances.map {
            GPUInstanceData(transform: $0.transform,
                            prevTransform: $0.prevTransform,
                            normalMatrix: $0.transform.inverse.transpose,
                            meshIndex: UInt32($0.mesh),
                            materialIndex: UInt32($0.material),
                            pad0: $0.mask)
        }
    }

    func gpuLights() -> [GPULight] {
        lights.map {
            GPULight(positionRadius: SIMD4<Float>($0.position, $0.radius),
                     color: SIMD4<Float>($0.color, Float($0.group)))
        }
    }

    // MARK: - Scene construction

    private func buildCornell() {
        let quad = addMesh(Scene.quadMesh())
        let cube = addMesh(Scene.cubeMesh())
        let sphere = addMesh(Scene.icosphere(subdivisions: 3))

        let white = addMaterial(albedo: [0.75, 0.75, 0.75])
        let red = addMaterial(albedo: [0.65, 0.06, 0.05])
        let green = addMaterial(albedo: [0.12, 0.45, 0.15])
        let gold = addMaterial(albedo: [0.85, 0.62, 0.25])
        let blue = addMaterial(albedo: [0.15, 0.30, 0.75])

        // Room: 10 wide, 5 high, 10 deep, open at the front (+Z) so a little sky light leaks in.
        let w: Float = 10, h: Float = 5, d: Float = 10
        addInstance(quad, white, translate([0, 0, 0]) * scale([w, 1, d]))                                         // floor
        addInstance(quad, white, translate([0, h, 0]) * rotate(.pi, [1, 0, 0]) * scale([w, 1, d]))                // ceiling
        addInstance(quad, white, translate([0, h / 2, -d / 2]) * rotate(.pi / 2, [1, 0, 0]) * scale([w, 1, h]))   // back
        addInstance(quad, red, translate([-w / 2, h / 2, 0]) * rotate(-.pi / 2, [0, 0, 1]) * scale([h, 1, d]))    // left
        addInstance(quad, green, translate([w / 2, h / 2, 0]) * rotate(.pi / 2, [0, 0, 1]) * scale([h, 1, d]))    // right

        // Static objects
        addInstance(cube, white, translate([-2.0, 1.6, -2.2]) * rotate(0.35, [0, 1, 0]) * scale([1.4, 3.2, 1.4]))
        addInstance(cube, white, translate([2.2, 0.75, -1.2]) * rotate(-0.3, [0, 1, 0]) * scale(1.5))
        addInstance(sphere, blue, translate([0.6, 0.7, 0.8]) * scale(0.7))

        // Dynamic objects: their transforms change every frame, which only requires
        // rebuilding the (cheap) instance acceleration structure.
        addInstance(cube, gold, matrix_identity_float4x4) { t in
            translate([0, 2.8 + 0.25 * sin(1.3 * t), -2.0]) * rotate(0.8 * t, [1, 1, 0]) * scale(0.9)
        }
        addInstance(sphere, white, matrix_identity_float4x4) { t in
            translate([2.8 * sin(0.6 * t), 0.5, 2.0]) * scale(0.5)
        }

        // Moving sphere lights
        addLight(color: SIMD3<Float>(1.0, 0.80, 0.60) * 30, radius: 0.15, sphereMesh: sphere) { t in
            [2.2 * cos(0.5 * t), 4.0, -1.0 + 2.2 * sin(0.5 * t)]
        }
        addLight(color: SIMD3<Float>(0.30, 0.50, 1.0) * 20, radius: 0.12, sphereMesh: sphere) { t in
            [3.5 * sin(0.37 * t), 1.6 + 0.6 * sin(0.9 * t), -3.6]
        }
        addLight(color: SIMD3<Float>(1.0, 0.45, 0.15) * 15, radius: 0.12, sphereMesh: sphere) { t in
            [-3.9 + 0.5 * sin(0.7 * t), 0.6, 0.8 + 1.6 * cos(0.45 * t)]
        }
    }

    /// Stress test: a 20 x 6 x 20 hall (open at the front) with 8 pillars, `objectCount` objects (~85% moving, in
    /// five motion families) and `lightCount` moving sphere lights in four colours. Seeded, so every run is identical.
    /// The lights' total power doesn't depend on their count, so the image brightness stays about the same.
    private func buildStress(objects objectCount: Int, lights lightCount: Int) {
        var rng = SplitMix64(seed: 0x5EED_1234)
        let quad = addMesh(Scene.quadMesh())
        let cube = addMesh(Scene.cubeMesh())
        // 320 triangles: the spheres are 10-30 cm, about a pixel off round even up close, and 5-6% faster to
        // trace than the Cornell room's 1280-triangle sphere (merging static objects into one tree didn't help).
        let sphere = addMesh(Scene.icosphere(subdivisions: 2))
        let lightSphere = sphere

        let white = addMaterial(albedo: [0.6, 0.6, 0.6])
        let warm = addMaterial(albedo: [0.5, 0.45, 0.4])
        let palette = [[0.80, 0.80, 0.80], [0.65, 0.06, 0.05], [0.12, 0.45, 0.15], [0.85, 0.62, 0.25],
                       [0.15, 0.30, 0.75], [0.55, 0.20, 0.60], [0.10, 0.55, 0.55], [0.30, 0.30, 0.32]]
            .map { addMaterial(albedo: SIMD3<Float>($0.map(Float.init))) }

        let w: Float = 20, h: Float = 6, d: Float = 20
        addInstance(quad, warm, translate([0, 0, 0]) * scale([w, 1, d]))                                          // floor
        addInstance(quad, white, translate([0, h, 0]) * rotate(.pi, [1, 0, 0]) * scale([w, 1, d]))                // ceiling
        addInstance(quad, white, translate([0, h / 2, -d / 2]) * rotate(.pi / 2, [1, 0, 0]) * scale([w, 1, h]))   // back
        addInstance(quad, palette[1], translate([-w / 2, h / 2, 0]) * rotate(-.pi / 2, [0, 0, 1]) * scale([h, 1, d]))
        addInstance(quad, palette[2], translate([w / 2, h / 2, 0]) * rotate(.pi / 2, [0, 0, 1]) * scale([h, 1, d]))
        for x: Float in [-6, -2, 2, 6] {
            for z: Float in [-5, 1] {
                addInstance(cube, white, translate([x, h / 2, z]) * scale([0.7, h, 0.7]))
            }
        }

        // Objects stay inside x, z in [-9, 9] and y in [0, 5.5].
        for _ in 0..<objectCount {
            let material = palette[rng.int(palette.count)]
            let mesh = rng.next() < 0.5 ? cube : sphere
            let size = rng.range(0.1, 0.3)                       // sphere radius, half a cube's edge
            let extent = mesh == sphere ? size : 2 * size        // scale for the unit-radius sphere or unit cube
            let phase = rng.range(0, 2 * .pi)
            let family = rng.next()
            if family < 0.15 {
                // Static clutter on the floor.
                let p = SIMD3<Float>(rng.range(-9, 9), size, rng.range(-9, 9))
                addInstance(mesh, material, translate(p) * rotate(rng.range(0, .pi), [0, 1, 0]) * scale(extent))
            } else if family < 0.45 {
                // Rings orbiting the hall's centre at several heights.
                let radius = rng.range(1.5, 8.5), y = rng.range(0.4, 5.0)
                let speed = rng.range(0.15, 0.5) * (rng.next() < 0.5 ? -1 : 1)
                addInstance(mesh, material, matrix_identity_float4x4) { t in
                    let a = phase + speed * t
                    return translate([radius * cos(a), y, radius * sin(a)]) * rotate(a, [0, 1, 0]) * scale(extent)
                }
            } else if family < 0.65 {
                // Balls bouncing on the floor.
                let x = rng.range(-9, 9), z = rng.range(-9, 9)
                let height = rng.range(0.5, 2.5), speed = rng.range(1.5, 3.0)
                addInstance(sphere, material, matrix_identity_float4x4) { t in
                    translate([x, size + height * abs(sin(speed * t + phase)), z]) * scale(size)
                }
            } else if family < 0.85 {
                // Tumbling cubes floating in place.
                let p = SIMD3<Float>(rng.range(-9, 9), rng.range(1.5, 5.0), rng.range(-9, 9))
                let axis = normalize(SIMD3<Float>(rng.range(-1, 1), rng.range(-1, 1), rng.range(-1, 1)) + [0, 0.01, 0])
                let spin = rng.range(0.5, 2.0), bob = rng.range(0.1, 0.4)
                addInstance(cube, material, matrix_identity_float4x4) { t in
                    translate(p + [0, bob * sin(1.1 * t + phase), 0]) * rotate(spin * t + phase, axis) * scale(2 * size)
                }
            } else {
                // Drifters on Lissajous paths.
                let c = SIMD3<Float>(rng.range(-5, 5), rng.range(1.5, 4.0), rng.range(-5, 5))
                let a = SIMD3<Float>(rng.range(1, 9 - abs(c.x)), rng.range(0.3, min(c.y - size, 5.5 - c.y)), rng.range(1, 9 - abs(c.z)))
                let f = SIMD3<Float>(rng.range(0.2, 0.6), rng.range(0.3, 0.9), rng.range(0.2, 0.6))
                addInstance(mesh, material, matrix_identity_float4x4) { t in
                    translate(c + a * SIMD3(sin(f.x * t + phase), sin(f.y * t + 2 * phase), cos(f.z * t + phase))) * scale(extent)
                }
            }
        }

        // Lights: four colours (one shadow-denoiser group each), Lissajous paths inside the hall.
        let colors: [SIMD3<Float>] = [[1.0, 0.85, 0.65], [1.0, 0.45, 0.12], [0.25, 0.60, 1.0], [0.85, 0.25, 0.90]]
        let totalPower: Float = 60
        for j in 0..<lightCount {
            let color = colors[j % colors.count] / dot(colors[j % colors.count], [0.2126, 0.7152, 0.0722])   // unit luminance
            let radius = rng.range(0.06, 0.12)
            let c = SIMD3<Float>(rng.range(-6, 6), rng.range(1.2, 4.6), rng.range(-6, 6))
            let a = SIMD3<Float>(rng.range(1, 9 - abs(c.x)), rng.range(0.2, min(c.y - 0.5, 5.6 - c.y)), rng.range(1, 9 - abs(c.z)))
            let f = SIMD3<Float>(rng.range(0.1, 0.4), rng.range(0.2, 0.7), rng.range(0.1, 0.4))
            let phase = rng.range(0, 2 * .pi)
            addLight(color: color * (totalPower / Float(lightCount)), radius: radius, sphereMesh: lightSphere) { t in
                c + a * SIMD3(sin(f.x * t + phase), sin(f.y * t + 3 * phase), cos(f.z * t + phase))
            }
        }

        defaultCamera = Scene.stressCamera
    }

    /// Overview from just outside the hall's open front (objects never come this close).
    static let stressCamera: Camera = {
        var c = Camera()
        c.position = [0, 4.6, 12.5]
        c.pitch = -0.25
        return c
    }()

    /// Where each shadow-denoiser group's lights end in `lights` (sorted by group): group g = [end[g-1], end[g]).
    private(set) var lightGroupEnd = SIMD4<UInt32>(repeating: 0)

    /// Lights share the shadow denoiser's 4 visibility channels by group. Up to 4 lights get one channel each;
    /// more are clustered by chromaticity (k-means, k = 4), so each channel's lights have similar colours.
    /// Lights are then sorted by group, so the shaders can walk one group's lights.
    private func assignLightGroups() {
        defer {
            lights.sort { $0.group < $1.group }   // stable: lights keep their order within a group
            for g in 0..<4 { lightGroupEnd[g] = UInt32(lights.filter { $0.group <= g }.count) }
        }
        guard lights.count > 4 else {
            for i in lights.indices { lights[i].group = i }
            return
        }
        let chroma = lights.map { $0.color / max($0.color.sum(), 1e-6) }
        // Farthest-point initialisation, deterministic.
        var centers = [chroma[0]]
        while centers.count < 4 {
            let far = chroma.indices.max { a, b in
                centers.map { distance_squared(chroma[a], $0) }.min()! < centers.map { distance_squared(chroma[b], $0) }.min()!
            }!
            centers.append(chroma[far])
        }
        for _ in 0..<10 {
            for i in lights.indices {
                lights[i].group = centers.indices.min { distance_squared(chroma[i], centers[$0]) < distance_squared(chroma[i], centers[$1]) }!
            }
            for g in centers.indices {
                let members = lights.indices.filter { lights[$0].group == g }
                if !members.isEmpty { centers[g] = members.map { chroma[$0] }.reduce(.zero, +) / Float(members.count) }
            }
        }
    }

    private func addMesh(_ mesh: MeshGeometry, uvs meshUVs: [SIMD2<Float>]? = nil) -> Int {
        let baseVertex = UInt32(positions.count)
        let firstIndex = UInt32(indices.count)
        positions += mesh.positions
        normals += mesh.normals
        uvs += meshUVs ?? [SIMD2<Float>](repeating: .zero, count: mesh.positions.count)
        indices += mesh.indices.map { $0 + baseVertex }   // indices are absolute into the shared vertex buffer
        meshes.append(GPUMesh(firstIndex: firstIndex, indexCount: UInt32(mesh.indices.count)))
        meshBounds.append((mesh.positions.reduce(SIMD3(repeating: .infinity), simd_min),
                           mesh.positions.reduce(SIMD3(repeating: -.infinity), simd_max)))
        return meshes.count - 1
    }

    /// A diffuse material (metallic 0, roughness 1, no specular: how every generated object has always looked).
    private func addMaterial(albedo: SIMD3<Float>, emission: SIMD3<Float> = .zero) -> Int {
        materials.append(GPUMaterial(albedo: SIMD4<Float>(albedo, 0), emission: SIMD4<Float>(emission, 1)))
        return materials.count - 1
    }

    @discardableResult
    private func addInstance(_ mesh: Int, _ material: Int, _ transform: float4x4,
                             mask: UInt32 = Scene.maskGeometry,
                             animation: ((Float) -> float4x4)? = nil) -> Int {
        instances.append(Instance(mesh: mesh, material: material, mask: mask,
                                  transform: transform, prevTransform: transform, animation: animation))
        return instances.count - 1
    }

    private func addLight(color: SIMD3<Float>, radius: Float, sphereMesh: Int, path: @escaping (Float) -> SIMD3<Float>) {
        // Radiance of a sphere with radiant intensity I and radius r is I / (pi r^2).
        let material = addMaterial(albedo: .zero, emission: color / (.pi * radius * radius))
        let sphere = addInstance(sphereMesh, material, matrix_identity_float4x4, mask: Scene.maskLights)
        lights.append(Light(color: color, radius: radius, path: path, sphereInstance: sphere))
    }

    // MARK: - glTF models

    /// Where the Gallery scene finds its models: `METALGI_ASSETS`, or `Assets/` next to `Package.swift`.
    static let assetsDirectory: URL = {
        if let dir = ProcessInfo.processInfo.environment["METALGI_ASSETS"] { return URL(fileURLWithPath: dir) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Assets")
    }()

    /// The glTF files in `assetsDirectory`, sorted by name. `METALGI_GALLERY="owl|demon"` keeps the files whose names
    /// contain one of these strings (quicker test runs).
    static func galleryFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: assetsDirectory, includingPropertiesForKeys: nil)) ?? []
        var models = files.filter { ["glb", "gltf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let only = ProcessInfo.processInfo.environment["METALGI_GALLERY"] {
            let keys = only.split(separator: "|").map { $0.lowercased() }
            models = models.filter { url in keys.contains { url.lastPathComponent.lowercased().contains($0) } }
        }
        return models
    }

    /// Model-space bounds of the loaded models' parts, scaled so the largest side is `size`, standing on y = 0 and
    /// centred on x = z = 0.
    private static func placement(_ model: GLTFModel, size: Float) -> float4x4 {
        let b = model.bounds
        guard !b.isEmpty else { return matrix_identity_float4x4 }
        let s = size / max((b.hi - b.lo).max(), 1e-6)
        return scale(s) * translate([-(b.lo.x + b.hi.x) / 2, -b.lo.y, -(b.lo.z + b.hi.z) / 2])
    }

    /// Adds every part of `model` as an instance at `transform` (times the part's own transform), with the model's
    /// materials and textures. `animation`, if given, replaces `transform` over time.
    private func addModel(_ model: GLTFModel, transform: float4x4, animation: ((Float) -> float4x4)? = nil) {
        var textureIndex: [Int: UInt32] = [:]   // image * 2 + srgb -> index into `textures`
        func texture(_ ref: GLTFModel.TextureRef?, srgb: Bool) -> UInt32 {
            guard let ref else { return .max }
            let key = ref.image * 2 + (srgb ? 1 : 0)
            if let i = textureIndex[key] { return i }
            textures.append(TextureSource(data: model.images[ref.image].data, srgb: srgb,
                                          name: "\(model.name)/\(model.images[ref.image].name)"))
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
        let fallback = addMaterial(albedo: [0.7, 0.7, 0.7])   // parts without a material
        let meshBase = meshes.count
        for mesh in model.meshes {
            _ = addMesh((mesh.positions, mesh.normals, mesh.indices), uvs: mesh.uvs)
        }
        for part in model.parts {
            let material = model.meshes[part.mesh].material.map { firstMaterial + $0 } ?? fallback
            if let animation {
                addInstance(meshBase + part.mesh, material, transform * part.transform) { t in animation(t) * part.transform }
            } else {
                addInstance(meshBase + part.mesh, material, transform * part.transform)
            }
        }
    }

    /// A model the user opened or dropped (`SceneSettings.extraModels`), 1.6 m tall at its position.
    private func addExtraModel(_ extra: ExtraModel) {
        do {
            let model = try GLTFLoader.load(URL(fileURLWithPath: extra.path))
            addModel(model, transform: translate(extra.position) * rotate(extra.yaw, [0, 1, 0]) * Scene.placement(model, size: 1.6))
        } catch {
            print("Could not load \(extra.path): \(error)")
        }
    }

    /// Gallery: the models in `Assets/` on plinths in an arc, 1.6 m at their largest side, under 8 moving lights.
    /// Two of them turn slowly (dynamic instances); the rest are static.
    private func buildGallery() {
        let quad = addMesh(Scene.quadMesh())
        let cube = addMesh(Scene.cubeMesh())
        let sphere = addMesh(Scene.icosphere(subdivisions: 2))
        let floor = addMaterial(albedo: [0.45, 0.43, 0.40])
        let wall = addMaterial(albedo: [0.70, 0.70, 0.68])
        let plinth = addMaterial(albedo: [0.30, 0.30, 0.32])

        let w: Float = 26, h: Float = 7, d: Float = 18
        addInstance(quad, floor, translate([0, 0, 0]) * scale([w, 1, d]))
        addInstance(quad, wall, translate([0, h / 2, -d / 2]) * rotate(.pi / 2, [1, 0, 0]) * scale([w, 1, h]))
        addInstance(quad, wall, translate([-w / 2, h / 2, 0]) * rotate(-.pi / 2, [0, 0, 1]) * scale([h, 1, d]))
        addInstance(quad, wall, translate([w / 2, h / 2, 0]) * rotate(.pi / 2, [0, 0, 1]) * scale([h, 1, d]))

        let files = Scene.galleryFiles()
        let plinthHeight: Float = 0.3
        let start = CFAbsoluteTimeGetCurrent()
        var triangles = 0
        for (i, url) in files.enumerated() {
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
            addInstance(cube, plinth, translate(p + [0, plinthHeight / 2, 0]) * scale([1.3, plinthHeight, 1.3]))
            let base = translate(p + [0, plinthHeight, 0]) * rotate(-a, [0, 1, 0])
            let place = Scene.placement(model, size: 1.6)
            if i % 5 == 1 {   // turntables
                let speed: Float = i % 2 == 0 ? 0.25 : -0.2
                addModel(model, transform: base * place) { t in base * rotate(speed * t, [0, 1, 0]) * place }
            } else {
                addModel(model, transform: base * place)
            }
            print(String(format: "Gallery: %@ (%d triangles, %d images)", model.name, model.triangleCount, model.images.count))
        }
        print(String(format: "Gallery: %d models, %d triangles, loaded in %.1f s", files.count, triangles,
                     CFAbsoluteTimeGetCurrent() - start))

        // 8 lights drifting above the arc, warm and cool.
        var rng = SplitMix64(seed: 0x6A11_E7)
        let colors: [SIMD3<Float>] = [[1.0, 0.85, 0.65], [1.0, 0.55, 0.25], [0.45, 0.65, 1.0], [0.85, 0.75, 1.0]]
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

    // MARK: - Mesh generators

    /// Unit quad in the XZ plane, facing +Y.
    static func quadMesh() -> MeshGeometry {
        let p: [SIMD3<Float>] = [[-0.5, 0, -0.5], [0.5, 0, -0.5], [0.5, 0, 0.5], [-0.5, 0, 0.5]]
        let n = [SIMD3<Float>](repeating: [0, 1, 0], count: 4)
        return (p, n, [0, 1, 2, 0, 2, 3])
    }

    /// Unit cube centered at the origin with flat face normals.
    static func cubeMesh() -> MeshGeometry {
        let faces: [(n: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
            ([1, 0, 0], [0, 1, 0], [0, 0, 1]), ([-1, 0, 0], [0, 0, 1], [0, 1, 0]),
            ([0, 1, 0], [0, 0, 1], [1, 0, 0]), ([0, -1, 0], [1, 0, 0], [0, 0, 1]),
            ([0, 0, 1], [1, 0, 0], [0, 1, 0]), ([0, 0, -1], [0, 1, 0], [1, 0, 0]),
        ]
        var p: [SIMD3<Float>] = [], n: [SIMD3<Float>] = [], idx: [UInt32] = []
        for f in faces {
            let base = UInt32(p.count)
            let c = f.n * 0.5
            p += [c - f.u * 0.5 - f.v * 0.5, c + f.u * 0.5 - f.v * 0.5,
                  c + f.u * 0.5 + f.v * 0.5, c - f.u * 0.5 + f.v * 0.5]
            n += [SIMD3<Float>](repeating: f.n, count: 4)
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return (p, n, idx)
    }

    /// Unit-radius icosphere with smooth normals.
    static func icosphere(subdivisions: Int) -> MeshGeometry {
        let t: Float = (1 + Float(5).squareRoot()) / 2
        let base: [SIMD3<Float>] = [
            [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0],
            [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t],
            [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1],
        ]
        var verts = base.map { normalize($0) }
        var tris: [UInt32] = [
            0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
            1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
            3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
            4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
        ]
        for _ in 0..<subdivisions {
            var cache: [UInt64: UInt32] = [:]
            func midpoint(_ a: UInt32, _ b: UInt32) -> UInt32 {
                let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
                if let i = cache[key] { return i }
                verts.append(normalize((verts[Int(a)] + verts[Int(b)]) * 0.5))
                let i = UInt32(verts.count - 1)
                cache[key] = i
                return i
            }
            var next: [UInt32] = []
            next.reserveCapacity(tris.count * 4)
            for f in stride(from: 0, to: tris.count, by: 3) {
                let a = tris[f], b = tris[f + 1], c = tris[f + 2]
                let ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a)
                next += [a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca]
            }
            tris = next
        }
        return (verts, verts, tris)
    }
}

/// Small seeded RNG for deterministic scene generation.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func next() -> Float { Float(nextUInt64() >> 40) / Float(1 << 24) }
    mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * next() }
    mutating func int(_ n: Int) -> Int { Int(nextUInt64() % UInt64(n)) }
}
