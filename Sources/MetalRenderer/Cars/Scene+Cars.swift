import EngineCore
import Foundation
import Physics
import simd

/// Cars in a scene (the physics' side is Physics+Cars.swift): a car's nodes and beams in the world, its wheels as
/// bodies drawn as wheels, and its panels (CarSurface) as deforming meshes the GPU writes every frame where the nodes
/// are, the body's paint and lamps in one, its glass in another. A car is its style's model in the car pack (CarPack:
/// Assets/Cars), its crash frame fitted to it (CarSpec.fitted).
extension Scene {
    /// The cars a scene has (its gameplay's: CarPlayer), each with what draws it.
    package struct CarRig {
        package struct Car {
            /// Its car in the world (PhysicsWorld.carSystem.cars), its style, its body's and glass's instances, its
            /// wheels' instances, where it began.
            package var car: Int
            package var style: CarStyle
            package var body: Int
            package var glass: Int
            package var wheels: [Int]
            package var start: float4x4
        }
        package var cars: [Car] = []
        /// The car the player drives.
        package var player = 0
        /// The car pack's textures added so far (by image, x 2, + 1 for sRGB: indices into the scene's textures).
        package var packTextures: [Int: UInt32] = [:]
        /// Per kind of break its particle proxy (ParticlesGPU.breakProxies: an emitter whose events are those breaks): a
        /// fractured object's material's (the first 8), then each CarEvent's (from CarEvent.firstSlot);
        /// ParticleSystem.none for none; empty: no dust.
        package var breakProxies: [UInt32] = []
        package init() {}
    }

    /// A car's materials, each a run (as the panels' and wheels' per-triangle offsets name them).
    package struct CarMaterials {
        package var body: Int
        package var glass: Int
        package var wheel: Int
    }

    /// A model's materials (CarPack): the pack's own (its textures), copied into runs in the order its meshes name them
    /// by offset: the paint (made a clear coat over its texture: addPaintMaterial's) and the lamps; the glass (this
    /// renderer's); the wheels' materials.
    package func addCarMaterials(_ model: CarModel, pack: GLTFModel, url: URL) -> (materials: CarMaterials, wheelOffsets: [Int: UInt8]) {
        func copy(_ m: Int) -> Int { addMaterial(packMaterial(m, pack, url)) }
        var paint = packMaterial(model.paint.material, pack, url)
        paint.params.x = 2 + 0.35   // (the flakes' roughness: addPaintMaterial)
        paint.albedo.w = 0.4
        paint.emission.w = 0.04
        paint.textures.y = .max     // (the coat is glossy all over: the texture's roughness was its own)
        let body = addMaterial(paint)
        _ = copy(model.lamps.material)
        let glass = addGlassMaterial(tint: [0.42, 0.45, 0.47])
        var offsets: [Int: UInt8] = [:]
        var wheel = -1
        for m in Set(model.wheels.flatMap { $0.meshes.map(\.material) }).sorted() {
            let i = copy(m)
            if wheel < 0 { wheel = i }
            offsets[m] = UInt8(i - wheel)
        }
        return (CarMaterials(body: body, glass: glass, wheel: wheel), offsets)
    }

    /// Style `style`'s spec: its preset, fitted to its model when the car pack has it (what Scene.addCar builds).
    package static func carSpec(_ style: CarStyle) -> CarSpec {
        let spec = CarSpec.preset(style)
        return CarPack.shared?.models[style].map { spec.fitted(to: $0) } ?? spec
    }

    /// The pack's material `m` (as addModelMaterials makes a model's), its textures added once a scene (only those of
    /// the cars it has: the pack's are 39 of 2048 x 2048).
    private func packMaterial(_ m: Int, _ pack: GLTFModel, _ url: URL) -> GPUMaterial {
        guard pack.materials.indices.contains(m) else { return GPUMaterial(albedo: SIMD4(0.5, 0.5, 0.5, 0), emission: SIMD4(0, 0, 0, 0.6)) }
        let mat = pack.materials[m]
        func texture(_ ref: GLTFModel.TextureRef?, srgb: Bool) -> UInt32 {
            guard let ref else { return .max }
            let key = ref.image * 2 + (srgb ? 1 : 0)
            if let i = carRig.packTextures[key] { return i }
            textures.append(TextureSource(data: pack.images[ref.image].data, srgb: srgb, name: "\(pack.name)/\(pack.images[ref.image].name)",
                                          modelPath: url.path, cacheKey: "\(ref.image)-\(srgb ? "srgb" : "linear")"))
            carRig.packTextures[key] = UInt32(textures.count - 1)
            return UInt32(textures.count - 1)
        }
        return GPUMaterial(albedo: SIMD4(SIMD3(mat.baseColor.x, mat.baseColor.y, mat.baseColor.z), mat.metallic), emission: SIMD4(mat.emissive, mat.roughness),
                           params: SIMD4(1, mat.normalScale, 0, 0),
                           textures: SIMD4(texture(mat.baseColorTexture, srgb: true), texture(mat.metallicRoughnessTexture, srgb: false),
                                           texture(mat.normalTexture, srgb: false), texture(mat.emissiveTexture, srgb: true)))
    }

    /// A car of `spec`'s style (its model in the car pack), placed by `transform` (a rotation and a translation: the
    /// car's origin is on the ground between its axles, its front toward +z), moving at `velocity`; its panels may go
    /// anywhere within `bounds`. Returns its rig entry (also in `carRig`), or nil when the pack hasn't the style.
    @discardableResult
    package func addCar(_ spec: CarSpec, _ transform: float4x4, velocity: SIMD3<Float> = .zero, bounds: AABB, name: String = "Car") -> CarRig.Car? {
        guard let pack = CarPack.shared, let model = pack.models[spec.style] else { return nil }
        let world = physicsWorld()
        world.setVolumes(sdfVolumes)
        section("Cars/\(name)")
        let blueprint = CarBlueprint(spec.fitted(to: model)), surface = CarSurface(blueprint, model: model)
        let (materials, wheelOffsets) = addCarMaterials(model, pack: pack.gltf, url: pack.url)
        // The wheels: the model's, one mesh per corner, moved by their bodies.
        let rimSDF = addSDFShape(blueprint.rimShape)
        let turn = float4x4(simd_quatf(angle: -.pi / 2, axis: [0, 0, 1]))
        let wheels = zip(blueprint.corners, model.wheels).map { corner, w -> Int in
            var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
            var offsets: [UInt8] = []
            for m in w.meshes {
                let first = UInt32(positions.count)
                positions += m.positions
                normals += m.normals
                uvs += m.uvs
                indices += m.indices.map { $0 + first }
                offsets += [UInt8](repeating: wheelOffsets[m.material] ?? 0, count: m.indices.count / 3)
            }
            let mesh = addMesh((positions, normals, indices), uvs: uvs, materials: offsets, label: "wheel")
            let i = addInstance(mesh, materials.wheel, transform * translate(corner.centre) * turn)
            instances[i].simulated = true
            return i
        }
        let car = world.addCar(blueprint, transform: transform, rimSDF: rimSDF, wheelInstances: wheels, velocity: velocity, panes: surface.panes)
        // The panels, in the scene's space where the nodes put them.
        let rotation = simd_float3x3(columns: (dropW(transform.columns.0), dropW(transform.columns.1), dropW(transform.columns.2)))
        var drawn: [Int] = []
        for (part, material, mask) in [(surface.body, materials.body, Scene.maskGeometry), (surface.glass, materials.glass, Scene.maskGlass)] {
            let positions = part.mesh.positions.map { dropW(transform * SIMD4($0, 1)) }
            let mesh = addDeformingMesh((positions, part.mesh.normals.map { rotation * $0 }, part.mesh.indices), uvs: part.uvs, materials: part.materials,
                                        bounds: bounds, label: mask == Scene.maskGlass ? "car glass" : "car body")
            drawn.append(addDeformingInstance(mesh, material, mask: mask))
            softMeshes.append(mesh)
            world.addCarSurface(part, car: car, hull: blueprint.hull, vertexBase: deforming.last!.first)
        }
        let entry = CarRig.Car(car: car, style: spec.style, body: drawn[0], glass: drawn[1], wheels: wheels, start: transform)
        carRig.cars.append(entry)
        return entry
    }
}
