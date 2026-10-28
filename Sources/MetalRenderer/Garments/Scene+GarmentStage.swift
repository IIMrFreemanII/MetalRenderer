import Characters
import EngineCore
import Foundation
import Garments
import Physics
import QuartzCore
import simd

extension SceneKind {
    package static let garmentStage = SceneKind("garmentStage")
}

/// The garment workshop's garment and what its cloth needs: the build the solver steps, where its particles start,
/// the avatar wearing it (its frame of slots and its body as a distance), and the cloth's clock. The scene's, made
/// with it; the renderer's solver (GarmentSolverGPU, Renderer+Garment.swift) reads it at install and every frame.
package final class GarmentStage {
    package let garment: Garment
    package let build: GarmentBuild
    package let start: [SIMD3<Float>]
    package let avatarName: String
    package let avatar: SkinnedCharacter?
    package let frame: AvatarFrame?
    package let body: BodySurface?
    /// The garment's mesh in the scene, and its first vertex.
    package let mesh: Int
    package let vertexBase: Int
    package var simulate: Bool
    package var substeps: Int
    /// Simulated time since the garment was placed (the seams close over the first second, gravity comes in after).
    package var sewTime: Float = 0
    /// Simulated time since the drape began from a drape carried over (an edit's): no sewing then.
    package var carried: Bool
    /// The mouse's hold: a particle and where it is pulled to.
    package var grab: (particle: Int, target: SIMD3<Float>)?
    /// The avatar's bones, when it moves (a clip): the cloth's colliders, posed each frame from the crowd's slot 0.
    package var rig: CharacterRig?
    /// The drape recorded frame by frame (a bake: GarmentModel.bake), while it is.
    package var recording: [[SIMD3<Float>]]?
    /// When the last frame stepped it (the clock in the window).
    package var lastFrame: CFTimeInterval?
    /// How long the scene took to make.
    package var buildMs = 0.0

    init(garment: Garment, build: GarmentBuild, start: [SIMD3<Float>], avatarName: String, avatar: SkinnedCharacter?, frame: AvatarFrame?,
         body: BodySurface?, mesh: Int, vertexBase: Int, simulate: Bool, substeps: Int, carried: Bool) {
        self.garment = garment
        self.build = build
        self.start = start
        self.avatarName = avatarName
        self.avatar = avatar
        self.frame = frame
        self.body = body
        self.mesh = mesh
        self.vertexBase = vertexBase
        self.simulate = simulate
        self.substeps = substeps
        self.carried = carried
    }

    /// `indices` wound so that most of the mesh's area faces away from its middle's vertical axis.
    static func facingOut(_ positions: [SIMD3<Float>], _ indices: [UInt32]) -> [UInt32] {
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let mid = (lo + hi) / 2
        var facing: Float = 0
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = positions[Int(indices[t])], b = positions[Int(indices[t + 1])], c = positions[Int(indices[t + 2])]
            let n = simd_cross(b - a, c - a), centre = (a + b + c) / 3
            facing += simd_dot(n, SIMD3(centre.x - mid.x, 0, centre.z - mid.z))
        }
        guard facing < 0 else { return indices }
        var out = indices
        for t in stride(from: 0, to: out.count, by: 3) { out.swapAt(t + 1, t + 2) }
        return out
    }

    /// The seams' compliance now: soft while the panels come together, stiff once they have.
    package var seamCompliance: Float { carried ? 1e-9 : max(1e-9, 2e-4 * exp(-sewTime * 9)) }
    /// Bending across the seams, scaled: none while they close (it would hold the panels apart at their angle).
    package var seamBendScale: Float { carried || sewTime > 0.9 ? 1 : 1e9 }
    /// Gravity's share now: none while sewing, then all of it.
    package var gravityScale: Float { carried ? 1 : max(0, min(1, (sewTime - 0.6) / 0.5)) }
}

extension Scene {
    /// The garment workshop: a studio, the avatar in its bind pose, and the garment `settings.garmentWorkshop` names,
    /// placed round it (or where its last drape left it) for the cloth to sew and drape.
    package func buildGarmentStage() {
        let begun = CACurrentMediaTime()
        remadeOften = true
        let w = settings.garmentWorkshop
        section("Studio")
        let kit = Kit(self)
        addInstance(kit.quad, addMaterial(albedo: [0.3, 0.3, 0.31]), scale([20_000, 1, 20_000]))
        addLight(.sun(angularRadius: Scene.degrees(0.6)), color: [1, 1, 1]) { _ in
            let e = Scene.degrees(38), a = Scene.degrees(235)
            return LightPose(position: .zero, direction: [cos(e) * cos(a), sin(e), -cos(e) * sin(a)])
        }
        let catalog = CharacterCatalog.resolve(settings.characterCatalog)
        let avatar = GarmentAvatars.character(w.avatar, catalog: catalog)
        var frame: AvatarFrame?, body: BodySurface?
        var bounds = AABB(lo: [-0.9, 0, -0.3], hi: [0.9, 1.8, 0.3])
        var rig: CharacterRig?
        if var c = avatar {
            section("Avatar")
            let f = AvatarFrame(c)
            frame = f
            bounds = AABB(lo: f.bounds.lo, hi: f.bounds.hi)
            let level = c.level(0)
            let skin = GarmentAvatar.mannequins.contains(w.avatar) ? SIMD3<Float>(0.16, 0.17, 0.19) : c.color
            // Moving: the bind pose held while it is sewn, then into the clip (GarmentMotion), skinned by the crowd's
            // skinning; the cloth meets its bones as capsules (Renderer+Garment).
            if !w.clip.isEmpty, let index = c.clipIndex(named: w.clip),
               let motion = GarmentMotion.clip(c, index: index), let r = CharacterRig(c) {
                c.clips.append(motion)
                rig = r
                let crowd = Crowd(characters: [c], clips: [c.clips.count - 1])
                adopt(crowd)
                beginObject("Avatar", assets: [])
                let instance = addInstance(crowd.slots[0].mesh, addPBRMaterial(baseColor: skin, metallic: 0, roughness: 0.6), matrix_identity_float4x4)
                setSkinned(instance, travels: false)
                endObject()
            } else {
            body = GarmentAvatars.body(c, key: w.avatar)
            beginObject("Avatar", assets: [])
            // (Its triangles turned to face out, and its normals made from them: the X Bot's are wound inside out.)
            let indices = GarmentStage.facingOut(level.positions, level.indices)
            let mesh = addMesh((level.positions, MuscleAtlas.normals(level.positions, indices), indices), uvs: level.uvs, name: "garmentAvatar-\(w.avatar)")
            addInstance(mesh, addPBRMaterial(baseColor: skin, metallic: 0, roughness: 0.6), matrix_identity_float4x4)
            endObject()
            }
        }
        // The garment.
        let measurements = frame?.measurements ?? BodyMeasurements()
        var garment = GarmentCatalog.resolve(w.garment)
        // A template's kind, or kinds worn one over the next ("tshirt+coat").
        if garment == nil {
            let kinds = w.garment.split(separator: "+").compactMap { GarmentTemplate.Kind(rawValue: String($0)) }
            for (layer, kind) in kinds.enumerated() {
                let made = GarmentTemplate.make(kind, GarmentTemplate.params(kind, body: measurements, ease: 0.1 + 0.06 * Float(layer)), body: measurements)
                garment = garment.map { $0.adding(made, layer: layer) } ?? made
            }
        }
        var g = garment ?? GarmentTemplate.make(.tshirt, GarmentTemplate.params(.tshirt, body: measurements), body: measurements)
        let build = GarmentBuild.make(g)
        var start = frame?.place(build, g) ?? build.rest2D.map { SIMD3($0.x, $0.y, 0) }
        var carried = false
        // A drape carried over (an edit's): where it has places; the panels it hadn't, placed round the body to sew.
        if let drape = g.drape, drape.count == build.particleCount {
            var all = true
            for i in drape.indices {
                if drape[i].x.isFinite { start[i] = drape[i] } else { all = false }
            }
            carried = all
        }
        g.drape = nil
        section("Garment")
        var materials: [Int] = []
        for f in g.fabrics { materials.append(addFabricMaterial(f)) }
        if materials.isEmpty { materials.append(addFabricMaterial(.preset(.cotton))) }
        let several = Set(build.triangleFabric).count > 1
        let reach = AABB(lo: simd_min(bounds.lo, SIMD3(-1.5, 0, -1.5)) - 1, hi: simd_max(bounds.hi, SIMD3(1.5, 2.2, 1.5)) + 1)
        beginObject(g.name, assets: [AssetKey(kind: .garment, name: w.garment)])
        let normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: start.count)
        let mesh = addDeformingMesh((start, normals, build.triangles), uvs: build.uvs.map { $0 * 4 },
                                    materials: several ? build.triangleFabric : nil, bounds: reach, label: "garment")
        addDeformingInstance(mesh, materials[0])
        endObject()
        let stage = GarmentStage(garment: g, build: build, start: start, avatarName: w.avatar, avatar: avatar, frame: frame, body: body,
                                 mesh: mesh, vertexBase: deforming.last!.first, simulate: w.simulate, substeps: max(1, w.substeps),
                                 carried: carried)
        stage.rig = rig
        stage.buildMs = (CACurrentMediaTime() - begun) * 1000
        garment = nil
        self.garment = stage
        focus = bounds
        defaultCamera = Camera.framing(bounds, fovY: Camera().fovY, pitch: -0.1).camera
    }

    /// A fabric's look: its colour and roughness, and its sheen (Fabric.metal) packed in the metallic lane, which a
    /// fabric doesn't use: -(1 + sheen's 256ths + spread's 65536ths). Leaves translucent: the material's leaf lane.
    package func addFabricMaterial(_ f: Fabric) -> Int {
        var metallic: Float = 0
        if f.sheen > 0.004 {
            let q = (max(0, min(1, f.sheen)) * 255).rounded(), r = (max(0, min(1, f.sheenRoughness)) * 255).rounded()
            metallic = -(1 + q / 256 + r / 65536)
        }
        return addMaterial(GPUMaterial(albedo: SIMD4(f.color, metallic), emission: SIMD4(.zero, f.roughness), params: SIMD4(1, 1, 0, 0)))
    }
}
