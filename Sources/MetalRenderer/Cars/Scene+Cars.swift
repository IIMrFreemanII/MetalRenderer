import EngineCore
import Foundation
import Physics
import simd

/// Cars in a scene (the physics' side is Physics+Cars.swift): a car's nodes and beams in the world, its wheels as
/// bodies drawn as wheels, and its panels (CarSurface) as deforming meshes the GPU writes every frame where the nodes
/// are, the body in one, its glass in another. A car is its style's model (CarPack: Assets/Cars), its crash frame
/// fitted to it (CarSpec.fitted).
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
            /// Its far model's body and glass instances (CarPack.coarse; empty: none), and the soft bodies of each
            /// model's panels (Scene.softMeshes' indices); whether the far one is drawn (`updateCarDetail`).
            package var coarse: [Int] = []
            package var fineBodies: [Int] = []
            package var coarseBodies: [Int] = []
            package var showsCoarse = false
        }
        package var cars: [Car] = []
        /// The car the player drives.
        package var player = 0
        /// The models' textures added so far (by file, image and sRGB or not: indices into the scene's textures).
        package var packTextures: [String: UInt32] = [:]
        /// The cars' panels' soft bodies that aren't drawn (the other model of each car), whose skinning and refits wait,
        /// and those just shown, skinned twice this frame (their last frame's positions their own: no streak).
        package var dormant: Set<Int> = []
        package var fresh: Set<Int> = []
        /// Per kind of break its particle proxy (ParticlesGPU.breakProxies: an emitter whose events are those breaks): a
        /// fractured object's material's (the first 8), then each CarEvent's (from CarEvent.firstSlot);
        /// ParticleSystem.none for none; empty: no dust.
        package var breakProxies: [UInt32] = []
        package init() {}
    }

    /// A model's materials (CarPack), one run in the model's order (the panels' and wheels' per-triangle offsets are
    /// their places in it), each as the model has it but its paint (made a clear coat over its texture:
    /// addPaintMaterial's) and its glass (this renderer's: the windows tinted, a lamp's glass as clear as the model's).
    /// Returns the run's first.
    package func addCarMaterials(_ model: CarModel, pack: GLTFModel, url: URL) -> Int {
        var roles: [Int: CarModel.Role] = [:]
        for m in model.meshes where m.material >= 0 && roles[m.material] == nil { roles[m.material] = m.role }
        let first = materials.count
        for m in 0..<max(pack.materials.count, 1) {
            switch roles[m] ?? .other {
            case .paint:
                var paint = packMaterial(m, pack, url)
                paint.params.x = 2 + 0.35   // (the flakes' roughness: addPaintMaterial)
                paint.albedo.w = 0.4
                paint.emission.w = 0.04
                paint.textures.y = .max     // (the coat is glossy all over: the texture's roughness was its own)
                _ = addMaterial(paint)
            case .window, .glass:
                _ = addGlassMaterial(tint: [0.42, 0.45, 0.47])
            case .lampGlass:
                let c = pack.materials[m].baseColor
                _ = addGlassMaterial(tint: simd_clamp(SIMD3(c.x, c.y, c.z), SIMD3(repeating: 0.3), SIMD3(repeating: 0.95)))
            case .lamp, .other:
                _ = addMaterial(packMaterial(m, pack, url))
            }
        }
        return first
    }

    /// Style `style`'s spec: its preset, fitted to its model when it has one (what Scene.addCar builds).
    package static func carSpec(_ style: CarStyle) -> CarSpec {
        let spec = CarSpec.preset(style)
        return CarPack.model(style).map { spec.fitted(to: $0.model) } ?? spec
    }

    /// The model's material `m` (as addModelMaterials makes a model's), its textures added once a scene (only those of
    /// the cars it has).
    private func packMaterial(_ m: Int, _ pack: GLTFModel, _ url: URL) -> GPUMaterial {
        guard pack.materials.indices.contains(m) else { return GPUMaterial(albedo: SIMD4(0.5, 0.5, 0.5, 0), emission: SIMD4(0, 0, 0, 0.6)) }
        let mat = pack.materials[m]
        func texture(_ ref: GLTFModel.TextureRef?, srgb: Bool) -> UInt32 {
            guard let ref else { return .max }
            let key = "\(url.lastPathComponent)#\(ref.image)-\(srgb ? "srgb" : "linear")"
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

    /// A car of `spec`'s style (its model), placed by `transform` (a rotation and a translation: the
    /// car's origin is on the ground between its axles, its front toward +z), moving at `velocity`; its panels may go
    /// anywhere within `bounds`. Returns its rig entry (also in `carRig`), or nil when its model isn't there.
    @discardableResult
    package func addCar(_ spec: CarSpec, _ transform: float4x4, velocity: SIMD3<Float> = .zero, bounds: AABB, name: String = "Car") -> CarRig.Car? {
        guard let (model, gltf, url) = CarPack.model(spec.style) else { return nil }
        let world = physicsWorld()
        world.setVolumes(sdfVolumes)
        section("Cars/\(name)")
        let blueprint = CarBlueprint(spec.fitted(to: model)), surface = CarSurface.cached(blueprint, model: model)
        let material = addCarMaterials(model, pack: gltf, url: url)
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
                offsets += [UInt8](repeating: UInt8(clamping: max(m.material, 0)), count: m.indices.count / 3)
            }
            let mesh = addMesh((positions, normals, indices), uvs: uvs, materials: offsets, label: "wheel")
            let i = addInstance(mesh, material, transform * translate(corner.centre) * turn)
            instances[i].simulated = true
            return i
        }
        let car = world.addCar(blueprint, transform: transform, rimSDF: rimSDF, wheelInstances: wheels, velocity: velocity, panes: surface.panes)
        // The panels, in the scene's space where the nodes put them: the model's, and its far one's (hidden for now).
        let rotation = simd_float3x3(columns: (dropW(transform.columns.0), dropW(transform.columns.1), dropW(transform.columns.2)))
        func panels(_ s: CarSurface, shown: Bool, label: String) -> (instances: [Int], bodies: [Int]) {
            var out: ([Int], [Int]) = ([], [])
            for (part, mask) in [(s.body, Scene.maskGeometry), (s.glass, Scene.maskGlass)] {
                let positions = part.mesh.positions.map { dropW(transform * SIMD4($0, 1)) }
                let mesh = addDeformingMesh((positions, part.mesh.normals.map { rotation * $0 }, part.mesh.indices), uvs: part.uvs, materials: part.materials,
                                            bounds: bounds, label: "\(label) \(mask == Scene.maskGlass ? "glass" : "body")")
                let i = addDeformingInstance(mesh, material, mask: mask)
                if !shown { hide(i, at: dropW(transform.columns.3)) }
                out.0.append(i)
                softMeshes.append(mesh)
                rebuiltOnDemand.insert(mesh)
                out.1.append(world.addCarSurface(part, car: car, hull: blueprint.hull, vertexBase: deforming.last!.first))
            }
            return out
        }
        let fine = panels(surface, shown: true, label: "car")
        var entry = CarRig.Car(car: car, style: spec.style, body: fine.instances[0], glass: fine.instances[1], wheels: wheels, start: transform)
        entry.fineBodies = fine.bodies
        // (Its panes are the model's: the far one's must name the same, else it has none.)
        if let coarse = CarPack.coarseModel(spec.style).map({ CarSurface.cached(blueprint, model: $0) }), coarse.panes.count == surface.panes.count {
            let far = panels(coarse, shown: false, label: "far car")
            entry.coarse = far.instances
            entry.coarseBodies = far.bodies
            carRig.dormant.formUnion(far.bodies)
        }
        carRig.cars.append(entry)
        return entry
    }

    /// Instance `i` (a car's model's panels, in the world's space) drawn: its mask, its transform none.
    private func show(_ i: Int, mask: UInt32) {
        editInstance(i) {
            $0.mask = mask
            $0.transform = matrix_identity_float4x4
            $0.prevTransform = matrix_identity_float4x4
            $0.normalMatrix = matrix_identity_float4x4
        }
    }

    /// ...not drawn: masked out and shrunk to nothing at `centre` (masked alone, its box still covered its car's in the
    /// top level, and every ray near the car walked it too: 0.3-0.6 ms a frame).
    private func hide(_ i: Int, at centre: SIMD3<Float>) {
        let gone = translate(centre) * scale(1e-4)
        editInstance(i) {
            $0.mask = 0
            $0.transform = gone
            $0.prevTransform = gone
            $0.normalMatrix = gone.inverse.transpose
        }
    }

    /// How far (m) from the camera a car (not the player's) is drawn as its far model, and how near it comes back.
    package static let carCoarseFrom: Float = 25, carFineWithin: Float = 20

    /// Each frame (Renderer.writeFrameData): which of each car's models is drawn, by its distance from the camera
    /// (`viewer`), the player's always its own. A switch sets the two's masks (their records written again:
    /// `instanceEdits`) and marks the shown one fresh; the hidden one's skinning and refits wait (`CarRig.dormant`).
    package func updateCarDetail(_ drawn: PhysicsStepper.Drawn) {
        carRig.fresh = []
        guard let eye = viewer else { return }
        for k in carRig.cars.indices where !carRig.cars[k].coarse.isEmpty {
            let c = carRig.cars[k]
            guard drawn.cars.indices.contains(c.car) else { continue }
            let d = simd_distance(eye, drawn.cars[c.car].centre)
            let far = k != carRig.player && (c.showsCoarse ? d > Scene.carFineWithin : d > Scene.carCoarseFrom)
            guard far != c.showsCoarse else { continue }
            carRig.cars[k].showsCoarse = far
            let (shown, hidden) = far ? (c.coarse, [c.body, c.glass]) : ([c.body, c.glass], c.coarse)
            for (i, mask) in zip(shown, [Scene.maskGeometry, Scene.maskGlass]) { show(i, mask: mask) }
            for i in hidden { hide(i, at: drawn.cars[c.car].centre) }
            instanceEdits.formUnion(shown + hidden)
            let (on, off) = far ? (c.coarseBodies, c.fineBodies) : (c.fineBodies, c.coarseBodies)
            carRig.dormant.subtract(on)
            carRig.dormant.formUnion(off)
            carRig.fresh.formUnion(on)
        }
    }
}
