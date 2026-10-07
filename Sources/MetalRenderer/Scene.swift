import Foundation
import ImageIO
import simd

/// A small Cornell-style room with static objects, animated objects and moving sphere lights, or one of the other
/// scenes (`SceneSettings`; the stress building is in Scene+Stress.swift).
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
        var virtualMesh = -1                  // >= 0: index into `virtualMeshes` (then `mesh` is -1)
        var assembly = -1                     // >= 0: index into `assemblies` (then `mesh` is -1 and `material` is its
                                              // wood's, with its leaves' right after it)
        /// `transform.inverse.transpose`, kept up to date with the transform (the GPU's normal matrix; its columns are
        /// the rows of the world -> object matrix, which the shading reads them as).
        var normalMatrix = matrix_identity_float4x4
        /// A light's proxy whose light moves (`LightMotion.animated`): `Scene.update` re-poses it every frame.
        var poseAnimated = false
        /// Its mesh deforms every frame on the GPU: a crowd member's pose slot (Crowd), or a cloth (Physics.swift).
        var deforms = false
        /// ...that walks: `Scene.update` moves it along its lane.
        var travels = false
        /// >= 0: an SDF shape's instance, index into `sdfShapes` (then `mesh` is -1 and `material` is its nodes' first).
        var sdf = -1
        /// A rigid body's: the physics (Physics.swift) moves it.
        var simulated = false

        /// Never moves or deforms: its transform is the one it was added with (a still scene's structure is built once).
        var isStatic: Bool { animation == nil && !poseAnimated && !deforms && !simulated }
        /// Its transform changes from frame to frame.
        var moves: Bool { animation != nil || poseAnimated || travels || simulated }
        /// Solid geometry, which shadow and GI rays meet (with `maskShadowTraced` or not).
        var isGeometry: Bool { mask & ~Scene.maskShadowTraced == Scene.maskGeometry }
    }

    /// A plant as parts (Foliage.Plant): meshes placed in the plant's own space, many of them the same few meshes
    /// (the species' boughs). Every instance of the plant shares it, through the structures over its parts (PlantTracing).
    struct Assembly {
        /// What a part turns about in the wind (Shaders/Foliage.metal). `angle`: its largest turn, at full wind; 0 = it doesn't.
        struct Bone {
            var pivot = SIMD3<Float>()        // plant space, at rest
            var angle: Float = 0
            var axis = SIMD3<Float>(1, 0, 0)
            var phase: Float = 0
        }
        /// The whole plant's largest lean about its foot, at full wind (WIND_ROOT_SWAY in Shaders/Foliage.metal).
        static let rootSway: Float = 0.022
        struct Part {
            var mesh: Int
            var transform: float4x4           // into plant space: a rotation, a uniform scale and a translation
            var firstLeaf: UInt32             // the mesh's triangles from here on take the leaves' material
            var leafCount: UInt32 = 0         // how many they are (autumn drops them from the end); 0 = it keeps them
            var bone: Int
            var bounds: AABB                  // of the placed mesh, in plant space (its vertices', not its box's)
            var windPad: Float = 0            // how far its bones' largest turns (full wind) can move any of it
            var limb = Bone()                 // the limb it is, or hangs on
            var bough = Bone()                // itself on that limb, if it is a bough
        }
        var parts: [Part]
        var bounds: AABB
        var evergreen = false
        /// Not a plant: a building of modules (Building.Module). It has no wind, no leaves and no voxels, and one
        /// variant (PlantTracing).
        var rigid = false
    }

    /// A leaf material as `setLeaves` changes it: its summer colour, what it turns to in autumn and when in the year
    /// (0...1), if it turns at all, and how much light it lets through.
    struct LeafMaterial {
        var material: Int
        var summer: SIMD3<Float>
        var autumn: SIMD3<Float>? = nil
        var turn: Float = 0
        var translucency: Float
        var gain: Float = 1                   // the material's colour is the leaf's times this (1 / its texture's mean)
    }

    /// An encoded image a material samples (decoded and uploaded by the renderer).
    struct TextureSource {
        var data: Data
        var srgb: Bool                        // colour data (base colour, emissive) vs linear (normal, metallic-roughness)
        var name: String
        var modelPath: String                 // the glTF file (texture streaming caches per file)
        var cacheKey: String                  // unique within the file: image index + colour space
        /// Generated (`addGeneratedTexture`): `data` is this many RGBA8 pixels, not an encoded image.
        var raw: (width: Int, height: Int)? = nil
        /// ...or they are drawn by this when someone needs them (a texture the caches already hold never is).
        var pixels: (() -> Data)? = nil

        /// A generated texture's pixels, drawn now if they are behind `pixels`.
        var rawPixels: Data { pixels?() ?? data }
        /// Which image it is, for telling that two scenes' textures are the same ones (an open world's next scene
        /// keeps the textures it is drawn with): its file and its key in it, which for a generated one says what
        /// it is made from.
        var identity: String { "\(modelPath)|\(cacheKey)|\(name)|\(srgb)|\(raw?.width ?? 0)x\(raw?.height ?? 0)|\(data.count)" }
    }

    /// A light's shape. Angles in radians.
    enum LightKind {
        case sphere(radius: Float)                              // color = radiant intensity
        case spot(radius: Float, inner: Float, outer: Float)    // a sphere light inside a cone (half angles), same units
        case sun(angularRadius: Float)                          // color = irradiance, from LightPose.direction
        case rect(width: Float, height: Float)                  // one-sided panel, color = radiance
        case tube(length: Float, radius: Float)                 // capsule, color = intensity (as a sphere of that power)
        case mesh(Int)                                          // an emissive instance: index into `meshLights`

        var isSun: Bool { if case .sun = self { return true } else { return false } }
    }

    /// Where a light is and how bright, at one time.
    struct LightPose {
        var position: SIMD3<Float>
        var direction = SIMD3<Float>(0, -1, 0)   // spot axis, rect normal, toward the sun, tube axis
        var tangent: SIMD3<Float>? = nil         // rect: its width's direction (default: horizontal)
        var scale = SIMD3<Float>(repeating: 1)   // multiplies the colour (flicker, the sun's colour over the day)
    }

    /// What of a light's pose changes over time: `update` re-evaluates only that, and only an `animated` light's proxy
    /// is a moving instance for the ray tracers. (Suns are always re-posed: they follow the time of day.)
    enum LightMotion {
        case animated      // position / direction (and maybe scale)
        case scaleOnly     // fixed in place, its brightness or colour changes (flicker, chases)
        case constant      // nothing
    }

    struct Light {
        var kind: LightKind
        var color: SIMD3<Float>               // see LightKind for the units
        var pose: (Float) -> LightPose
        var motion = LightMotion.animated
        var current = LightPose(position: .zero)
        var proxyInstance = -1                // visible emissive shape that follows the light (maskLights)
        var proxyMaterial = -1
        var proxyEmission = SIMD3<Float>(repeating: 0)   // its radiance at scale 1
        var group = 0                         // shadow-denoiser channel (see assignLightGroups)

        var isMesh: Bool { if case .mesh = kind { return true }; return false }
    }

    /// An emissive instance sampled as a light: its triangles are `emissiveTriangles[first ..< first + count]`.
    struct MeshLight {
        var instance: Int
        var firstTriangle: Int
        var triangleCount: Int
        var center: SIMD3<Float>              // object space bounding sphere of the triangles
        var radius: Float
        var normal: SIMD3<Float>              // object space, area-weighted mean normal (zero if closed)
        var flatness: Float                   // |sum of area x normal| / area: 1 = flat, 0 = closed or round
        var power: SIMD3<Float>               // sum of emitted radiance x area (object space)
        /// Its material, from its instance's: the triangles of a mesh of several materials that have this one.
        var materialOffset = 0
    }

    /// A mesh light's triangles as they are put together: each weighed by area x emitted luminance, and the bounding
    /// sphere / mean normal the shaders weigh the whole light by.
    struct MeshLightDraft {
        private(set) var triangles: [GPUEmissiveTriangle] = []
        private var weights: [Float] = []
        private var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        private var areaNormal = SIMD3<Float>(repeating: 0), area: Float = 0
        private var power = SIMD3<Float>(repeating: 0)

        /// A triangle that emits `le` (its mean radiance); nothing if it has no area or emits nothing.
        mutating func add(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, uv0: SIMD2<Float> = .zero, uv1: SIMD2<Float> = .zero,
                          uv2: SIMD2<Float> = .zero, emission le: SIMD3<Float>) {
            let e1 = p1 - p0, e2 = p2 - p0
            let cr = cross(e1, e2)
            let triArea = length(cr) / 2
            guard triArea > 0 else { return }
            let w = triArea * dot(le, SIMD3<Float>(0.2126, 0.7152, 0.0722))
            guard w > 0 else { return }
            weights.append(w)
            triangles.append(GPUEmissiveTriangle(v0: SIMD4(p0, 0), e1: SIMD4(e1, uv0.x), e2: SIMD4(e2, uv0.y),
                                                 uv12: SIMD4(uv1.x, uv1.y, uv2.x, uv2.y)))
            for p in [p0, p1, p2] { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            areaNormal += cr / 2
            area += triArea
            power += le * triArea
        }

        /// The light of `instance`, its triangles from `firstTriangle` (their `v0.w` now the running share of its
        /// power); nil if nothing was added.
        mutating func finish(instance: Int, firstTriangle: Int) -> MeshLight? {
            guard !weights.isEmpty else { return nil }
            let total = weights.reduce(0, +)
            var running: Float = 0
            for (k, w) in weights.enumerated() {
                running += w
                triangles[k].v0.w = k == weights.count - 1 ? 1 : running / total
            }
            return MeshLight(instance: instance, firstTriangle: firstTriangle, triangleCount: weights.count, center: (lo + hi) / 2,
                             radius: max(length(hi - lo) / 2, 1e-3), normal: length(areaNormal) > 0 ? normalize(areaNormal) : .zero,
                             flatness: min(length(areaNormal) / area, 1), power: power)
        }
    }

    /// A mesh light made already (an open world's tile has its own in its file): `light.instance` is the instance of
    /// the borrowed mesh it is of, its triangles are `triangles[range]`.
    struct BorrowedLight {
        var light: MeshLight
        var triangles: Stored<GPUEmissiveTriangle>
        var range: Range<Int>
    }

    /// A local fog volume (FogVolume in Shaders/Types.metal): a soft-edged box or sphere of denser fog, optionally moving.
    struct FogVolume {
        enum Shape {
            case box(halfExtents: SIMD3<Float>)
            case sphere(radius: Float)
        }
        var shape: Shape
        var center: SIMD3<Float>
        var density: Float                      // extinction at its bottom (1/m)
        var albedo = SIMD3<Float>(repeating: 0.9)
        var edge: Float = 0.5                   // the density ramps up over this depth inside (m)
        var noise: Float = 0.6                  // how much the drifting noise modulates it
        var heightFalloff: Float = 0            // per metre above its bottom (ground mist)
        var motion: ((Float) -> SIMD3<Float>)? = nil   // centre over time

        var gpu: GPUFogVolume {
            let (extent, shapeID): (SIMD3<Float>, Float)
            switch shape {
            case .box(let e): (extent, shapeID) = (e, 0)
            case .sphere(let r): (extent, shapeID) = (SIMD3(r, r, r), 1)
            }
            return GPUFogVolume(centerShape: SIMD4(center, shapeID), extentDensity: SIMD4(extent, density),
                                albedoEdge: SIMD4(albedo, edge), params: SIMD4(noise, heightFalloff, 0, 0))
        }
    }

    /// Instance masks. Shadow and GI rays only test `geometry`, so the visible
    /// light spheres never block their own light.
    static let maskGeometry: UInt32 = 1
    static let maskLights: UInt32 = 2
    /// Window glass: only camera rays meet it (they pass through it and take its reflection, traceKernel); to shadow
    /// and GI rays it isn't there, so light goes through windows.
    static let maskGlass: UInt32 = 4
    /// A far plant as its voxels (VoxelLOD): met by the rays that meet `geometry` (MASK_VOXELS).
    static let maskVoxels: UInt32 = 8
    /// Geometry the raster can't draw (RasterScene.kind's `skip`: an assembly's parts, leaf cards, ground cover that
    /// sways, SDF shapes), and the crowd, which deforms every frame: Virtual Shadow Maps leave it out, and their shadow samples
    /// trace a ray that meets only this (MASK_SHADOW_TRACED). Always with `geometry`.
    static let maskShadowTraced: UInt32 = 16

    /// An instance's mask: `mask`, with `shadowTraced` on geometry the raster can't draw.
    func instanceMask(_ mask: UInt32, mesh: Int, assembly: Bool) -> UInt32 {
        guard mask == Scene.maskGeometry else { return mask }
        let skipped = assembly || (mesh >= 0 && (meshes[mesh].cutout != 0 || meshes[mesh].sways != 0))
        return skipped ? mask | Scene.maskShadowTraced : mask
    }

    /// Not a mask: what an SDF shape's instance has besides its mask in its record's (GPUInstanceData.pad0). No ray's
    /// mask has it, so no ray tests it as one.
    static let instanceSDF: UInt32 = 0x2000_0000

    private(set) var positions: [SIMD3<Float>] = []
    private(set) var normals: [SIMD3<Float>] = []
    private(set) var uvs: [SIMD2<Float>] = []                 // per vertex (zeros for the generated meshes)
    private(set) var textures: [TextureSource] = []
    /// Large glTF meshes as streamed, level-of-detail cluster DAGs (VirtualTracing: VirtualBLAS, VirtualGeometry).
    private(set) var virtualMeshes: [VirtualMesh] = []
    private(set) var virtualMeshNames: [String] = []
    let usesVirtualGeometry: Bool
    /// Virtual geometry is traced as this frame's cut of clusters (VirtualGeometry), not a BLAS per instance.
    var tracesClusters: Bool { !virtualMeshes.isEmpty && VirtualGeometry.clusterMode }
    /// Generated plants as assemblies of shared parts (PlantTracing), unless baked into meshes of their own (bakedPlants).
    private(set) var assemblies: [Assembly] = []
    let usesAssemblies: Bool
    /// The scene has generated plants: it is built differently with assemblies and without.
    private(set) var hasPlants = false
    /// The plants that are voxels when far (FoliageVoxels): one per assembly, in its order; or one per baked plant
    /// with boughs, its wood and leaf meshes in `meshVoxels`.
    private(set) var voxelPlants: [FoliageVoxels.Plant] = []
    /// A baked plant's mesh -> its voxel plant (`voxelPlants`), | `meshVoxelsLeaves` for its leaves.
    private(set) var meshVoxels: [Int: UInt32] = [:]
    static let meshVoxelsLeaves: UInt32 = 0x8000_0000
    /// Far plants as their voxels (SceneSettings.voxelBoxes): the plants have grids.
    let usesVoxelBoxes: Bool
    /// ...and it does: a still scene with baked plants that have them (VoxelLOD rebuilds a still scene's structure),
    /// or a moving one with assemblies (their instances name a grid's level when far: PlantTracing). (Not the open
    /// world's assemblies: a still scene's plants stay as they were built.)
    var hasVoxelBoxes: Bool { usesVoxelBoxes && (isStill ? !meshVoxels.isEmpty : !assemblies.isEmpty) }
    private(set) var hasSwayingMeshes = false
    /// Leaf cards' alpha layers (FoliageTextures.CardSheet), each FoliageTextures.cardSheetSize squared: the ray
    /// queries test a card's hits against its layer (rtCutout). `coverage`: the share of a card that is there.
    private(set) var cutouts: [(alpha: [UInt8], coverage: Float)] = []
    /// Plants' leaves as cards (`settings.leafCards`, with assemblies).
    let usesCards: Bool
    /// Something the wind moves and the shaders' FOLIAGE paths trace: plants as assemblies, or ground cover that leans.
    var hasFoliage: Bool { assemblies.contains { !$0.rigid } || hasSwayingMeshes }
    /// Assemblies that are not plants (Scene.Assembly.rigid): the shaders walk their parts without FOLIAGE's code.
    var hasRigidAssemblies: Bool { assemblies.contains(where: \.rigid) }
    /// Some instances may have `maskShadowTraced` (the plants, leaf cards, SDF shapes: what the raster can't draw; the
    /// crowd, cloths, soft bodies and hair, which deform every frame).
    var hasShadowTraced: Bool { hasFoliage || usesCards || hasSkinned || hasSDFShapes || !deforming.isEmpty }
    private var leafMaterials: [LeafMaterial] = []
    private var leafState = SIMD2<Float>(-1, -1)   // the season and translucency they are set to
    /// Some material has a specular lobe (glTF materials; the generated scenes are diffuse only). Set once, by init.
    private(set) var hasSpecular = false
    private(set) var indices: [UInt32] = []
    /// For meshes of several materials (the city's buildings): per triangle of `indices`, what to add to its
    /// instance's material index. Empty if no mesh has more than one; otherwise one entry per triangle.
    private(set) var triangleMaterials: [UInt8] = []
    private(set) var hasMaterialOffsets = false    // some mesh has several materials (set once, by init)
    private(set) var borrowed: [BorrowedMesh] = []
    private(set) var hasBorrowedMeshes = false     // (set once, by init: `borrowed` is let go of with the geometry)
    /// Instances that stay together from scene to scene: the plants of an open world's tile. They are not among
    /// `instances`. The renderer keeps a group's records, and the ray tracers what they build over them, for as long
    /// as some scene has a group of that name (`InstanceBlock` in SceneBuffers.swift), so `make` is only asked of a
    /// group that is new. They never move, and there are no lights among them.
    struct InstanceGroup {
        /// What the group is made from, said in full: a group of the same name in another scene is the same
        /// instances, of meshes, assemblies and materials with the same numbers.
        let name: String
        /// How many instances `make` gives (the renderer makes room for them before it asks).
        let count: Int
        let make: () -> [Instance]
    }
    private(set) var groups: [InstanceGroup] = []
    private(set) var hasGroups = false             // (set once, by init: `groups` are let go of with the geometry)
    func addGroup(name: String, count: Int, make: @escaping () -> [Instance]) {
        groups.append(InstanceGroup(name: name, count: count, make: make))
    }
    private(set) var meshes: [GPUMesh] = []
    /// Shapes given by signed distance fields (SDFShapes.swift), the baked grids their nodes may be, and each shape's box.
    private(set) var sdfShapes: [SDFShape] = []
    private(set) var sdfVolumes: [SDFVolume] = []
    private(set) var sdfBounds: [AABB] = []
    /// Some instance is an SDF shape's (set once, by init): the shaders are compiled with SDF_SHAPES.
    private(set) var hasSDFShapes = false
    /// What some meshes are made from, said in full (an open world's tile and chunk, a plant of a library): a mesh
    /// of the same name in another scene is the same triangles in the same order, so what was built for it holds
    /// there too (Metal's per-mesh structures: SceneBuffers).
    private(set) var meshNames: [Int: String] = [:]
    private(set) var materials: [GPUMaterial] = []
    private(set) var instances: [Instance] = []
    private(set) var lights: [Light] = []
    private(set) var meshLights: [MeshLight] = []
    private var borrowedLights: [BorrowedLight] = []
    private(set) var emissiveTriangles: [GPUEmissiveTriangle] = []
    /// The materials changed since the renderer last took this (light proxies whose brightness is animated): the
    /// smallest range that holds them all.
    private var materialsDirty: Range<Int>?
    /// What `update` has to touch every frame, found once by init (nil while it builds the scene: everything then).
    private var animated: (instances: [Int], lights: [Int], scaledLights: [Int])?
    /// Nothing in the scene moves or deforms: its instances' records and the structure over them are made once.
    private(set) var isStill = false
    /// The lights whose GPU record changes from frame to frame (moving, flickering, the mesh lights of moving
    /// instances), and each instance's rank + 1 among the virtual ones (0 = not virtual).
    private var changingLights: [Int] = []
    /// Of those, what a light tree refits (LightTree.refit): the ones that move or change shape (not the suns), and
    /// the ones only their brightness changes.
    private(set) var lightTreeChanges: (moved: [Int], scaled: [Int]) = ([], [])
    private var virtualRank: [UInt32] = []
    /// The first sun among the lights (the sky follows it), if any.
    private(set) var firstSun: Int?
    private var meshBounds: [(SIMD3<Float>, SIMD3<Float>)] = []   // local AABB per mesh
    /// The deforming meshes other than the crowd's: each one's mesh and its vertices (`addDeformingMesh`).
    private(set) var deforming: [(mesh: Int, first: Int, count: Int)] = []
    /// glTF parts with emissive materials: their geometry, for mesh lights (virtual meshes keep none of it).
    private var emitterSources: [Int: (positions: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32])] = [:]
    var defaultCamera = Camera()
    let settings: SceneSettings
    /// While `init` builds the scene: the load's step that the builders report models to (the loading overlay).
    private(set) var loadStep: LoadStep?
    /// Some instance is window glass (maskGlass). Set by `addGlassMaterial`.
    private(set) var hasGlass = false
    /// The open world: what counts as the scene for the sun's light map, the fog and the clouds' shadows is what is
    /// around the camera (to 16 m, so the map's texels stay where they are from frame to frame).
    func follow(_ camera: SIMD3<Float>) {
        sceneSphere = SIMD4((camera / 16).rounded(.toNearestOrAwayFromZero) * 16, 1.5 * World.tileSize)
    }

    /// The scene's animated characters, if it has any (Scene+Crowd.swift).
    private(set) var crowd: Crowd?
    /// The scene's rigid bodies, if it has any (Physics.swift): `update` steps them on the CPU unless `physicsOnGPU`.
    private(set) var physics: PhysicsWorld?
    private(set) var physicsOnGPU = false
    /// The GPU's: the steps `update` asked for since the renderer last took them, and whether from the start.
    private var physicsPending = (steps: 0, restart: false)
    /// The open world's scene: which part of the world it holds, and where (Scene+World.swift).
    var worldPlace: WorldPlace?
    /// ...and where its sun and moon are now (`update`).
    private(set) var heavens: Heavens?
    /// Its materials that are lights at night, each with what it emits when it is on, and which it is: a street lamp
    /// (`window` nil), or a window that comes on at its own time in the dusk (`World.lightOn`).
    struct CityLight {
        var material: Int
        var emission: SIMD3<Float>
        var window: Float?
        /// How far on it is, 0...1, and the light table's triangles that have its material (where the scene samples
        /// its lights).
        var on: Float = 0
        var triangles: [Range<Int>] = []
    }
    /// (Added with their materials, which emit nothing until `setCityLights` says so.)
    var cityLights: [CityLight] = []
    private var cityLightsElevation: Float?
    /// What each of the light table's triangles emits when its light is on.
    private var cityLightRadiance: [Float] = []
    private var lightTrianglesDirty: Range<Int>?

    var skyColor = SIMD3<Float>(0.35, 0.45, 0.65) * 0.8
    var skyAnimation: ((Float) -> SIMD3<Float>)?
    /// Local fog volumes (used while the fog and its volumes are on), at most GPUFogParams.maxVolumes.
    var fogVolumes: [FogVolume] = []
    /// Bounding sphere of the static scene (the sun's orthographic light map covers it).
    private(set) var sceneSphere = SIMD4<Float>(0, 0, 0, 1)
    /// Every light and emissive triangle by power, for ReSTIR DI's candidates (built once, after the lights).
    private(set) var lightTable = LightTable()

    /// `virtualGeometry`: big glTF meshes become virtual meshes (built once, then read from their cache files) instead
    /// of ordinary full-detail meshes.
    /// `building`: what is in the scene, instead of what `settings.kind` builds (tests).
    /// `voxelBoxes`: far baked plants are traced as their voxels (VoxelLOD).
    /// `load`: the load to report the build to; a gallery stops loading models when it is cancelled.
    init(_ settings: SceneSettings = SceneSettings(), virtualGeometry: Bool = false, assemblies: Bool = false, voxelBoxes: Bool = false,
         load: LoadJob? = nil, building: ((Scene) -> Void)? = nil) {
        self.settings = settings
        loadStep = load?.step("Scene", detail: settings.kind.title)
        self.usesVirtualGeometry = virtualGeometry
        self.usesAssemblies = assemblies && !settings.bakedPlants
        self.usesCards = assemblies && settings.leafCards
        self.usesVoxelBoxes = voxelBoxes
        if let building { building(self) } else if let check = settings.lightCheck { buildLightCheck(check) } else {
        switch settings.kind {
        case .cornell: buildCornell()
        case .stress: buildStress(objects: settings.objects, lights: settings.lights)
        case .gallery: buildGallery()
        case .spots: buildSpots()
        case .sun: buildSun()
        case .area: buildArea()
        case .tubes: buildTubes()
        case .emissive: buildEmissive()
        case .mixed: buildMixed()
        case .fog: buildFogHall()
        case .valley: buildValley()
        case .market: buildMarket()
        case .forest: buildForest()
        case .crowd: buildCrowd(characters: settings.characters, poses: settings.poses, detail: settings.detail)
        case .city: buildCity(settings.city, seed: settings.seed, night: false)
        case .cityNight: buildCity(settings.city, seed: settings.seed, night: true)
        case .world: buildWorld()
        case .showcase: buildShowcase()
        case .shapes: buildShapes()
        case .physics: buildPhysics(settings.physics)
        case .ragdolls: buildRagdolls(settings.physics)
        case .hair: buildHair(settings.physics)
        case .softBodies: buildSoftBodies(settings.physics)
        }
        }
        if !settings.extraModels.isEmpty { loadStep?.set(done: 0, total: settings.extraModels.count) }
        for extra in settings.extraModels {
            loadStep?.set(detail: URL(fileURLWithPath: extra.path).lastPathComponent)
            addExtraModel(extra)
            loadStep?.advance()
        }
        loadStep?.set(detail: "lights")
        finishCrowd()
        finishDeforming()
        finishHair()
        finishSoftBodies()
        physics?.finish()
        hasBorrowedMeshes = !borrowed.isEmpty
        hasGroups = !groups.isEmpty
        hasSDFShapes = instances.contains { $0.sdf >= 0 }
        precondition(!hasSDFShapes || !hasGroups, "SDF shapes in a scene with instance groups (SceneBuffers.InstanceBlock has no SDF instances)")
        assignLightGroups()
        if settings.emissiveLights { buildMeshLights() }
        if let place = worldPlace {
            // The open world has no bounds worth a light map: what counts is what is near its middle tile.
            sceneSphere = SIMD4(place.middle, 1.5 * World.tileSize)
        } else {
            let (lo, hi) = bounds()
            if lo.x <= hi.x { sceneSphere = SIMD4((lo + hi) / 2, max(length(hi - lo) / 2, 1)) }
        }
        lightTable = LightTable(scene: self)
        bindCityLights()
        update(time: 0)
        for i in instances.indices { instances[i].prevTransform = instances[i].transform }

        // Nothing is added from here on: what the frame loop asks for every frame is fixed.
        if !triangleMaterials.isEmpty {
            triangleMaterials += [UInt8](repeating: 0, count: indices.count / 3 - triangleMaterials.count)
        }
        hasMaterialOffsets = !triangleMaterials.isEmpty || borrowed.contains { $0.materials != nil }
        if !hasPlants { Flora.forget() }
        hasSpecular = materials.contains { $0.params.x > 0 }
        switch ProcessInfo.processInfo.environment["METALRENDERER_LIGHT_TABLE"] {
        case "1": usesLightTable = true
        case "0": usesLightTable = false
        default: usesLightTable = forcesLightTable || lights.count > Scene.lightTableThreshold
        }
        firstSun = lights.firstIndex { $0.kind.isSun }
        var rank: UInt32 = 0
        virtualRank = instances.map { inst in
            guard inst.virtualMesh >= 0 else { return 0 }
            rank += 1
            return rank
        }
        func moves(_ l: Light) -> Bool { l.kind.isSun || l.motion == .animated }
        animated = (instances: instances.indices.filter { instances[$0].moves },
                    lights: lights.indices.filter { !lights[$0].isMesh && moves(lights[$0]) },
                    scaledLights: lights.indices.filter { !lights[$0].isMesh && !moves(lights[$0]) && lights[$0].motion == .scaleOnly })
        // (Virtual geometry's cuts change the structure under its instances, and the wind the plants' and the ground
        // cover's: the frames update it. Not the open world's, whose instance blocks need a still scene: its plants
        // stand still.)
        isStill = instances.allSatisfy(\.isStatic) && virtualMeshes.isEmpty && (!hasFoliage || hasGroups)
        changingLights = lights.indices.filter {
            if case .mesh(let m) = lights[$0].kind { return !instances[meshLights[m].instance].isStatic }
            return moves(lights[$0]) || lights[$0].motion == .scaleOnly
        }
        lightTreeChanges = (moved: changingLights.filter { !lights[$0].kind.isSun && (lights[$0].isMesh || moves(lights[$0])) },
                            scaled: changingLights.filter { !lights[$0].isMesh && !moves(lights[$0]) })
        materialsDirty = nil
        loadStep?.finish()
        loadStep = nil
    }

    // MARK: - Animation

    /// Poses everything at time `t`; suns and the sky colour follow `dayTime` instead (Time of day offsets it).
    func update(time t: Float, dayTime: Float? = nil) {
        let day = dayTime ?? t
        func move(_ i: Int) {
            instances[i].prevTransform = instances[i].transform
            if let animation = instances[i].animation { setTransform(i, animation(t)) }
        }
        // A light's pose; `placed`: its position and direction too (otherwise only its scale is taken).
        func pose(_ l: Int, placed: Bool) {
            let old = lights[l].current.scale
            let pose = lights[l].pose(lights[l].kind.isSun ? day : t)
            if placed {
                lights[l].current = pose
                let s = lights[l].proxyInstance
                if s >= 0 { setTransform(s, proxyTransform(lights[l].kind, pose)) }
            } else {
                lights[l].current.scale = pose.scale
            }
            let material = lights[l].proxyMaterial
            if material >= 0 && pose.scale != old {
                materials[material].emission = SIMD4(lights[l].proxyEmission * pose.scale, 1)
                materialsDirty = materialsDirty.map { min($0.lowerBound, material)..<max($0.upperBound, material + 1) }
                    ?? material..<material + 1
            }
        }
        if let animated {
            for i in animated.instances { move(i) }
            for l in animated.lights { pose(l, placed: true) }
            for l in animated.scaledLights { pose(l, placed: false) }
        } else {
            for i in instances.indices { move(i) }
            for l in lights.indices where !lights[l].isMesh { pose(l, placed: true) }
        }
        if let skyAnimation { skyColor = skyAnimation(day) }
        if worldPlace != nil {
            let now = Heavens(at: day)
            heavens = now
            setCityLights(sunElevation: now.sunElevation)
        }
        for i in fogVolumes.indices { if let motion = fogVolumes[i].motion { fogVolumes[i].center = motion(t) } }
        if let physics {
            if physicsOnGPU {
                let claim = physics.claim(to: t)
                physicsPending = claim.restart ? claim : (physicsPending.steps + claim.steps, physicsPending.restart)
            } else {
                physics.advance(to: t)
                placeBodies()
            }
        }
        if let crowd {
            // The slots' poses at this time, then the walkers along their lanes: only a transform's translation
            // changes (and with it the inverse's), so this stays cheap for tens of thousands of them.
            crowd.pose(at: t)
            for w in crowd.walkers {
                let (p, previous) = w.positions(crowd.slots[w.slot])
                instances[w.instance].transform.columns.3 = SIMD4(p, 1)
                instances[w.instance].prevTransform.columns.3 = SIMD4(previous, 1)
                instances[w.instance].normalMatrix.columns.0.w = -dot(w.inverse0, p)
                instances[w.instance].normalMatrix.columns.1.w = -dot(w.inverse1, p)
                instances[w.instance].normalMatrix.columns.2.w = -dot(w.inverse2, p)
            }
        }
    }

    /// The rigid bodies' and particles' instances where the physics has them.
    func placeBodies() {
        guard let physics else { return }
        for b in physics.bodies.indices { setTransform(Int(physics.bodies[b].info.z), physics.transform(b)) }
        for p in physics.particles.indices where physics.particles[p].info.x != PhysicsWorld.none {   // (a cloth's vertex has none)
            setTransform(Int(physics.particles[p].info.x), physics.particleTransform(p))
        }
    }

    /// ...where the GPU had them (`poses`: position, rotation per body): the CPU's copy, for what reads it here
    /// (bounds, moving lights). The frame's records are the GPU's own (PhysicsGPU.encodePose).
    func placeBodies(poses: UnsafeBufferPointer<SIMD4<Float>>) {
        guard let physics else { return }
        physics.drawnPoses = Array(poses)   // what picking sees
        for b in physics.bodies.indices {
            let i = Int(physics.bodies[b].info.z)
            instances[i].prevTransform = instances[i].transform
            setTransform(i, physics.transform(b, position: PhysicsMath.xyz(poses[2 * b]), rotation: poses[2 * b + 1]))
        }
    }

    /// The renderer runs the physics on the GPU from now on, from the start up to where it is.
    func runPhysicsOnGPU() {
        guard let physics else { return }
        physicsOnGPU = true
        physicsPending = (physics.stepIndex, true)
    }

    /// The steps to encode this frame (the renderer's), which are then forgotten.
    func takePhysicsSteps() -> (steps: Int, restart: Bool) {
        defer { physicsPending = (0, false) }
        return physicsPending
    }

    private func setTransform(_ i: Int, _ transform: float4x4) {
        instances[i].transform = transform
        instances[i].normalMatrix = transform.inverse.transpose
    }

    /// The instances whose transform changes from frame to frame.
    var movingInstances: [Int] { animated?.instances ?? Array(instances.indices) }

    /// The range of materials changed since the last call (nil: none), which is then forgotten.
    func takeMaterialsDirty() -> Range<Int>? {
        defer { materialsDirty = nil }
        return materialsDirty
    }

    /// Unit direction perpendicular to `n`: horizontal if possible.
    static func perpendicular(_ n: SIMD3<Float>) -> SIMD3<Float> {
        let h = cross(SIMD3<Float>(0, 1, 0), n)
        return length(h) > 1e-4 ? normalize(h) : normalize(cross(SIMD3<Float>(1, 0, 0), n))
    }

    /// Rotation taking +Y to `d` (unit).
    static func alignY(_ d: SIMD3<Float>) -> float4x4 {
        if dot(d, [0, 1, 0]) < -0.9999 { return rotate(.pi, [1, 0, 0]) }
        return float4x4(simd_quatf(from: [0, 1, 0], to: d))
    }

    /// Rect lights: width axis (unit), normal, height axis.
    private static func rectFrame(_ pose: LightPose) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let n = normalize(pose.direction)
        var t = pose.tangent.map { normalize($0 - n * dot($0, n)) } ?? perpendicular(n)
        if !t.x.isFinite { t = perpendicular(n) }
        return (t, n, cross(t, n))
    }

    private func proxyTransform(_ kind: LightKind, _ pose: LightPose) -> float4x4 {
        switch kind {
        case .sphere(let r), .spot(let r, _, _):
            return translate(pose.position) * scale(r)
        case .rect(let w, let h):
            let (t, n, b) = Scene.rectFrame(pose)   // the unit quad lies in XZ, facing +Y
            return float4x4(SIMD4(t * w, 0), SIMD4(n, 0), SIMD4(b * h, 0), SIMD4(pose.position, 1))
        case .tube:
            return translate(pose.position) * Scene.alignY(normalize(pose.direction))
        case .sun, .mesh:
            return matrix_identity_float4x4
        }
    }

    /// An instance's bounds in its own space: its mesh's, virtual mesh's or assembly's.
    func localBounds(of inst: Instance) -> (SIMD3<Float>, SIMD3<Float>) {
        inst.virtualMesh >= 0 ? (virtualMeshes[inst.virtualMesh].bounds.lo, virtualMeshes[inst.virtualMesh].bounds.hi)
            : inst.assembly >= 0 ? (assemblies[inst.assembly].bounds.lo, assemblies[inst.assembly].bounds.hi)
            : inst.sdf >= 0 ? (sdfBounds[inst.sdf].lo, sdfBounds[inst.sdf].hi) : meshBounds[inst.mesh]
    }

    /// Axis-aligned bounds of all geometry at the current animation time (the scene sphere),
    /// from each instance's transformed mesh bounds.
    func bounds() -> (SIMD3<Float>, SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for inst in instances where inst.isGeometry {
            let (a, b) = localBounds(of: inst)
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

    /// Virtual instances: meshIndex points past the ordinary meshes (the raster's mesh table lists the virtual meshes'
    /// bounds there) and pad1 = 1 + the instance's rank among the virtual ones (its BLAS / cluster records).
    /// Assembly instances: meshIndex points past those too (the table then lists the assemblies), and SDF shapes'
    /// instances past those (the shapes), with `Scene.instanceSDF` in pad0.
    /// Into the renderer's records, kept from frame to frame. `all`: every instance (a scene's first frame); otherwise
    /// only the ones that move, the rest being unchanged.
    /// `range`: of all the instances, these (a part of them, for a caller that writes the parts side by side).
    func writeInstanceData(into out: UnsafeMutablePointer<GPUInstanceData>, all: Bool, range: Range<Int>? = nil) {
        func write(_ i: Int) {
            let inst = instances[i]
            out[i] = GPUInstanceData(transform: inst.transform,
                                     prevTransform: inst.prevTransform,
                                     normalMatrix: inst.normalMatrix,
                                     meshIndex: inst.mesh >= 0 ? UInt32(inst.mesh)
                                         : inst.assembly >= 0 ? UInt32(meshes.count + virtualMeshes.count + inst.assembly)
                                         : inst.sdf >= 0 ? UInt32(meshes.count + virtualMeshes.count + assemblies.count + inst.sdf)
                                         : UInt32(meshes.count + inst.virtualMesh),
                                     materialIndex: UInt32(inst.material),
                                     pad0: inst.mask | (inst.sdf >= 0 ? Scene.instanceSDF : 0),
                                     pad1: virtualRank[i])
        }
        if !all, let animated {
            for i in animated.instances { write(i) }
        } else {
            for i in range ?? instances.indices { write(i) }
        }
    }

    /// More lights than this (analytic + emissive meshes): nothing may loop over the lights or keep something per light
    /// (LIGHT_TABLE in Shaders/Types.metal): no light maps, GI and the path tracer sample the light table.
    /// `METALRENDERER_LIGHT_TABLE=1` / `=0` forces it on / off. Set once, by init.
    static let lightTableThreshold = 256
    private(set) var usesLightTable = false
    /// Set by a scene's builder: the light table whatever the count. (The city at night: a building's lit windows are
    /// one mesh light wrapped around it, which the per-light loops of a scene with few lights sample badly.)
    var forcesLightTable = false

    /// One bit per light type present (GPULight.sphere ...): the shaders are specialised for it. Bit 31: usesLightTable.
    /// The bits under it: the features the scene's shaders are compiled with.
    var lightTypeMask: UInt32 {
        // Bits 30 and 29: FOLIAGE, the scene has assemblies or leaning ground cover, and ALPHA_TEST, it has leaf cards.
        // Bit 28: DEFORMING_MESHES, it has meshes that deform (a crowd's pose slots, cloths). Bit 27: GLASS. Bit 26:
        // MULTI_MATERIAL, some mesh has several materials. Bit 25: STREAMED, some meshes are borrowed, and so in
        // buffers of their own. Bit 24: GROUPED, some instances are in groups. Bit 23: VOXEL_BOXES, far plants are
        // voxel boxes. Bit 22: SDF_SHAPES, some instances are SDF shapes. Bit 21: VG_CLUSTERS, virtual geometry is
        // traced as its cut of clusters (VirtualGeometry.clusterMode). Bit 20: HAIR_CURVES, some meshes are curves.
        // Bit 19: RIGID_ASSEMBLIES, some assemblies are buildings of modules. (Shaders/Types.metal.)
        let features: UInt32 = (hasFoliage ? 0x4000_0000 : 0) | (cutouts.isEmpty ? 0 : 0x2000_0000)
            | (hasDeformingMeshes ? 0x1000_0000 : 0) | (hasGlass ? 0x0800_0000 : 0) | (hasMaterialOffsets ? 0x0400_0000 : 0)
            | (hasBorrowedMeshes ? 0x0200_0000 : 0) | (hasGroups ? 0x0100_0000 : 0) | (hasVoxelBoxes ? 0x0080_0000 : 0)
            | (hasSDFShapes ? 0x0040_0000 : 0) | (tracesClusters ? 0x0020_0000 : 0) | (hasCurves ? 0x0010_0000 : 0)
            | (hasRigidAssemblies ? 0x0008_0000 : 0)
        return lights.reduce((usesLightTable ? 0x8000_0001 : UInt32(1)) | features) { mask, l in   // spheres always: an empty scene needs some type
            let type: Float
            switch l.kind {
            case .sphere: type = GPULight.sphere
            case .spot: type = GPULight.spot
            case .sun: type = GPULight.sun
            case .rect: type = GPULight.rect
            case .tube: type = GPULight.tube
            case .mesh: type = GPULight.mesh
            }
            return mask | 1 << UInt32(type)
        }
    }

    /// `all`: every light (a scene's first frame); otherwise only the ones whose record changes over time.
    func writeLights(into out: UnsafeMutableBufferPointer<GPULight>, all: Bool) {
        if all {
            for l in lights.indices { out[l] = gpuLight(l) }
        } else {
            for l in changingLights { out[l] = gpuLight(l) }
        }
    }

    private func gpuLight(_ index: Int) -> GPULight {
        let l = lights[index]
        let p = l.current
        func color(_ type: Float) -> SIMD4<Float> { SIMD4(l.color * p.scale, Float(l.group) + 4 * type) }
        switch l.kind {
        case .sphere(let r):
            return GPULight(positionRadius: SIMD4(p.position, r), color: color(GPULight.sphere),
                            axis: .zero, params: .zero)
        case .spot(let r, let inner, let outer):
            return GPULight(positionRadius: SIMD4(p.position, r), color: color(GPULight.spot),
                            axis: SIMD4(normalize(p.direction), 0),
                            params: SIMD4(cos(outer), cos(max(inner, 0)) + (inner >= outer ? 1e-4 : 0), 0, 0))
        case .sun(let angle):
            return GPULight(positionRadius: SIMD4(0, 0, 0, angle), color: color(GPULight.sun),
                            axis: SIMD4(normalize(p.direction), 0), params: sceneSphere)
        case .rect(let w, let h):
            let (t, n, _) = Scene.rectFrame(p)
            return GPULight(positionRadius: SIMD4(p.position, 0), color: color(GPULight.rect),
                            axis: SIMD4(n, 0), params: SIMD4(t * (w / 2), h / 2))
        case .tube(let length, let r):
            return GPULight(positionRadius: SIMD4(p.position, r), color: color(GPULight.tube),
                            axis: SIMD4(normalize(p.direction) * (length / 2), 0), params: .zero)
        case .mesh(let i):
            let m = meshLights[i]
            let t = instances[m.instance].transform
            let linear = float3x3(SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z),
                                  SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                                  SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z))
            let maxScale = max(length(linear.columns.0), length(linear.columns.1), length(linear.columns.2))
            let areaScale = pow(abs(linear.determinant), 2.0 / 3.0)
            let c = t * SIMD4(m.center, 1)
            let n = m.flatness > 0 ? normalize(linear.inverse.transpose * m.normal) : SIMD3<Float>(0, 1, 0)
            return GPULight(positionRadius: SIMD4(c.x, c.y, c.z, m.radius * maxScale),
                            color: SIMD4(m.power * areaScale, 4 * GPULight.mesh),
                            axis: SIMD4(n, Float(m.materialOffset)),
                            params: SIMD4(Float(bitPattern: UInt32(m.firstTriangle)), Float(bitPattern: UInt32(m.triangleCount)),
                                          m.flatness, Float(bitPattern: UInt32(m.instance))))
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
        let chroma = lights.map { $0.color / max($0.color.sum(), 1e-6) }   // analytic lights (mesh lights come later)
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

    /// `materials`: for a mesh of several materials, each triangle's material as an offset from the material its
    /// instance names (which is then the first of a run of materials added one after the other).
    /// `name`: see `meshNames`.
    func addMesh(_ mesh: MeshGeometry, uvs meshUVs: [SIMD2<Float>]? = nil, materials offsets: [UInt8]? = nil, name: String? = nil) -> Int {
        if let name { meshNames[meshes.count] = name }
        let baseVertex = UInt32(positions.count)
        let firstIndex = UInt32(indices.count)
        if let offsets {
            precondition(offsets.count == mesh.indices.count / 3, "one material per triangle")
            triangleMaterials += [UInt8](repeating: 0, count: indices.count / 3 - triangleMaterials.count)   // the meshes before it
            triangleMaterials += offsets
        }
        positions += mesh.positions
        normals += mesh.normals
        uvs += meshUVs ?? [SIMD2<Float>](repeating: .zero, count: mesh.positions.count)
        indices += mesh.indices.map { $0 + baseVertex }   // indices are absolute into the shared vertex buffer
        meshes.append(GPUMesh(firstIndex: firstIndex, indexCount: UInt32(mesh.indices.count)))
        meshBounds.append((mesh.positions.reduce(SIMD3(repeating: .infinity), simd_min),
                           mesh.positions.reduce(SIMD3(repeating: -.infinity), simd_max)))
        return meshes.count - 1
    }

    /// A mesh whose arrays stay where they are (an open world's tile: in its file, mapped) instead of being copied
    /// into the scene's. On the GPU it is in a buffer of its own, which the scenes that have a mesh of its name share
    /// (MeshBlock in SceneBuffers.swift): the renderer copies it from here into that buffer the first time, and
    /// whoever needs its triangles after that reads them there.
    struct BorrowedMesh {
        var positions: Stored<SIMD3<Float>>
        var normals: Stored<SIMD3<Float>>
        var uvs: Stored<SIMD2<Float>>
        var indices: Stored<UInt32>             // into its own vertices
        var materials: Stored<UInt8>? = nil     // per triangle, as `triangleMaterials` (nil: it has one material)
        var mesh = 0                            // in `meshes`
    }

    /// Adds a borrowed mesh, with its bounds as they are known. `sways`, `cutout`: as `addMesh(_: Foliage.Mesh)`'s,
    /// the cutout as the table has it.
    func addMesh(borrowing mesh: BorrowedMesh, bounds: AABB, name: String, sways: Bool = false, cutout: UInt32 = 0) -> Int {
        precondition(mesh.normals.count == mesh.positions.count && mesh.uvs.count == mesh.positions.count
                     && (mesh.materials.map { $0.count * 3 == mesh.indices.count } ?? true), "a vertex's arrays, and a material per triangle")
        var mesh = mesh
        mesh.mesh = meshes.count
        borrowed.append(mesh)
        meshNames[meshes.count] = name
        meshes.append(GPUMesh(firstIndex: 0, indexCount: UInt32(mesh.indices.count), sways: sways ? 1 : 0, cutout: cutout,
                              vertexCount: UInt32(mesh.positions.count)))
        if sways { hasSwayingMeshes = true }
        meshBounds.append((bounds.lo, bounds.hi))
        return meshes.count - 1
    }

    /// Lets go of the vertex and index arrays, of the borrowed meshes and of the instance groups, once the renderer
    /// has them in its buffers and their structures: for a scene that is made again when anything about
    /// it changes, never built from twice (the open world's). The meshes' table, bounds and names stay.
    func releaseGeometry() {
        (positions, normals, uvs, indices, triangleMaterials, borrowed) = ([], [], [], [], [], [])
        groups = []
        geometryReleased = true
    }
    private(set) var geometryReleased = false

    // MARK: - Crowd

    /// Takes `crowd` as this scene's: its characters' bind-pose meshes and a mesh per pose slot.
    func adopt(_ crowd: Crowd) {
        self.crowd = crowd
        for p in crowd.parts.indices {
            let geometry = crowd.geometry(part: p)
            crowd.parts[p].bindVertex = positions.count
            crowd.parts[p].mesh = addMesh((geometry.positions, geometry.normals, geometry.indices), uvs: geometry.uvs)
        }
        for i in crowd.slots.indices {
            // A pose: its character's triangles over vertices of its own, which `finishCrowd` places. Its bounds are
            // those of every pose the character takes.
            let part = crowd.parts[crowd.slots[i].part], character = crowd.characters[part.character]
            meshes.append(GPUMesh(firstIndex: meshes[part.mesh].firstIndex, indexCount: meshes[part.mesh].indexCount))
            meshBounds.append((character.boundsMin, character.boundsMax))
            crowd.slots[i].mesh = meshes.count - 1
            setDetailLevel(meshes.count - 1, part.level)
        }
    }

    /// Mesh `m` was made at level of detail `level` (0 = the finest) of a system that has levels: the LOD debug view
    /// shows it (GPUMesh.lod).
    func setDetailLevel(_ m: Int, _ level: Int) {
        guard m >= 0 else { return }
        meshes[m].lod = UInt32(level + 1)
    }

    /// Mesh `m`'s bounds in its own space: for a pose slot, of every pose it may take.
    func localBounds(mesh m: Int) -> AABB { AABB(lo: meshBounds[m].0, hi: meshBounds[m].1) }

    /// Marks instance `i` as a member of the crowd (its mesh is a pose slot's).
    func setSkinned(_ i: Int, travels: Bool) {
        instances[i].deforms = true
        instances[i].travels = travels
        // Virtual shadow maps would draw it again every frame wherever it casts a shadow: its shadows are traced.
        if instances[i].isGeometry { instances[i].mask |= Scene.maskShadowTraced }
        hasSkinned = true
    }
    private(set) var hasSkinned = false

    /// A mesh whose vertices the GPU rewrites every frame (a cloth's: PhysicsGPU), within `bounds` whatever it does.
    /// Its vertices are its own (`vertexOffset` 0), and `finishDeforming` puts last frame's after everything else.
    func addDeformingMesh(_ mesh: MeshGeometry, uvs: [SIMD2<Float>]? = nil, bounds: AABB) -> Int {
        let m = addMesh(mesh, uvs: uvs)
        meshBounds[m] = (bounds.lo, bounds.hi)
        deforming.append((mesh: m, first: positions.count - mesh.positions.count, count: mesh.positions.count))
        return m
    }

    /// An instance of a deforming mesh (placed where its vertices are: they are in the scene's space).
    @discardableResult
    func addDeformingInstance(_ mesh: Int, _ material: Int) -> Int {
        let i = addInstance(mesh, material, matrix_identity_float4x4)
        instances[i].deforms = true
        // Like the crowd's: virtual shadow maps would draw it again every frame (and can't draw curves): traced.
        if instances[i].isGeometry { instances[i].mask |= Scene.maskShadowTraced }
        return i
    }

    /// A curve mesh's segments and its control points' radii (`curveRadii`).
    struct CurveMesh {
        var segments: Int
        var radii: Range<Int>
    }
    /// The meshes that are strands (hair), drawn as round Catmull-Rom curves (HAIR_CURVES): to everything that reads
    /// triangles they are meshes with none.
    private(set) var curveMeshes: [Int: CurveMesh] = [:]
    private(set) var curveRadii: [Float] = []
    var hasCurves: Bool { !curveMeshes.isEmpty }
    /// The hair's groups of drawn strands and their curve meshes (Scene+Hair.swift): once the meshes are done, each
    /// group is told where its mesh's control points are (`finishHair`).
    var hairMeshes: [(group: Int, mesh: Int)] = []
    func hasCurveMesh(_ m: Int) -> Bool { curveMeshes[m] != nil }

    /// Strands as curves: `points` control points, `perStrand` of them a strand (a Catmull-Rom curve passes through
    /// all but its first and last), each with its radius (`radii`). The GPU rewrites them every frame (hair:
    /// PhysicsGPU), within `bounds` whatever they do; `finishDeforming` puts last frame's after everything else. The
    /// mesh's vertices start at its `vertexOffset`; its indices, from `firstIndex`, are each segment's first point
    /// counted from there (`indexCount` stays 0: it has no triangles).
    func addCurves(points: [SIMD3<Float>], perStrand: Int, radii: [Float], bounds: AABB) -> Int {
        precondition(perStrand >= 4 && points.count % perStrand == 0 && radii.count == points.count, "whole strands of 4 points or more")
        let first = positions.count
        let firstIndex = indices.count
        positions += points
        normals += [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: points.count)
        uvs += [SIMD2<Float>](repeating: .zero, count: points.count)
        for s in 0..<(points.count / perStrand) {
            for k in 0..<(perStrand - 3) { indices.append(UInt32(s * perStrand + k)) }
        }
        meshes.append(GPUMesh(firstIndex: UInt32(firstIndex), indexCount: 0, vertexOffset: UInt32(first)))
        meshBounds.append((bounds.lo, bounds.hi))
        let m = meshes.count - 1
        curveMeshes[m] = CurveMesh(segments: indices.count - firstIndex, radii: curveRadii.count..<(curveRadii.count + radii.count))
        curveRadii += radii
        deforming.append((mesh: m, first: first, count: points.count))
        return m
    }

    /// The hair's groups: where their meshes' control points are, and last frame's.
    private func finishHair() {
        guard let physics else { return }
        for (g, m) in hairMeshes {
            physics.hairGroups[g].mesh.x = meshes[m].vertexOffset
            physics.hairGroups[g].mesh.y = meshes[m].prevOffset
        }
    }

    /// Once every mesh is in (after the crowd's): the deforming meshes' last-frame vertices, after everything, as the
    /// first frame's (the same as the current ones).
    private func finishDeforming() {
        for d in deforming {
            let previous = positions.count
            positions += positions[d.first..<(d.first + d.count)]
            meshes[d.mesh].prevOffset = UInt32(previous - d.first)
        }
    }

    /// Some mesh deforms (DEFORMING_MESHES): the crowd's pose slots, cloths.
    var hasDeformingMeshes: Bool { crowd?.slots.isEmpty == false || !deforming.isEmpty }

    /// Once every mesh is in: the pose slots' vertices go after them (each slot's current positions and normals,
    /// then every slot's previous positions), skinned on the CPU to the pose at time 0. The GPU rewrites them every
    /// frame from then on; these are what the acceleration structures are first built from.
    private func finishCrowd() {
        guard let crowd, !crowd.slots.isEmpty else { return }
        var next = positions.count
        for p in crowd.parts.indices {
            crowd.parts[p].currentBase = next
            next += crowd.parts[p].slotCount * crowd.parts[p].vertexCount
        }
        let currentEnd = next
        for p in crowd.parts.indices {
            crowd.parts[p].previousBase = next
            next += crowd.parts[p].slotCount * crowd.parts[p].vertexCount
        }
        positions += [SIMD3<Float>](repeating: .zero, count: next - positions.count)
        normals += [SIMD3<Float>](repeating: .zero, count: currentEnd - normals.count)
        crowd.pose(at: 0)
        let geometry = crowd.parts.indices.map { crowd.geometry(part: $0) }
        positions.withUnsafeMutableBufferPointer { p in
            normals.withUnsafeMutableBufferPointer { n in
                DispatchQueue.concurrentPerform(iterations: crowd.slots.count) { i in
                    let character = geometry[crowd.slots[i].part]
                    let range = crowd.vertexRange(slot: i)
                    SkinnedCharacter.skin(positions: character.positions, normals: character.normals, skin: character.skin,
                                          palette: crowd.palette(slot: i), into: p.baseAddress! + range.current,
                                          n.baseAddress! + range.current)
                    (p.baseAddress! + range.previous).update(from: p.baseAddress! + range.current, count: range.count)
                }
            }
        }
        for i in crowd.slots.indices {
            let range = crowd.vertexRange(slot: i), part = crowd.parts[crowd.slots[i].part]
            meshes[crowd.slots[i].mesh].vertexOffset = UInt32(range.current - part.bindVertex)
            meshes[crowd.slots[i].mesh].prevOffset = UInt32(range.previous - range.current)
        }
    }

    /// How far ground cover leans at full wind, per unit of its height (WIND_COVER_LEAN in Shaders/Foliage.metal).
    static let coverLean: Float = 0.2

    /// A generated mesh (Foliage, Terrain): its arrays appended whole, its bounds as it counted them. `sways`: ground
    /// cover standing along +y, which leans in the wind (every instance of it: its transform, PlantTracing).
    /// `cutout`: the alpha layer (`addCutout`) that cuts out its leaves, if they are cards.
    /// `name`: see `meshNames`.
    func addMesh(_ mesh: Foliage.Mesh, sways: Bool = false, cutout: Int? = nil, name: String? = nil) -> Int {
        if let name { meshNames[meshes.count] = name }
        let baseVertex = UInt32(positions.count)
        let firstIndex = UInt32(indices.count)
        positions += mesh.positions
        normals += mesh.normals
        uvs += mesh.uvs
        indices.reserveCapacity(indices.count + mesh.indices.count)
        for i in mesh.indices { indices.append(i + baseVertex) }
        meshes.append(GPUMesh(firstIndex: firstIndex, indexCount: UInt32(mesh.indices.count), sways: sways ? 1 : 0,
                              cutout: cutout.map { UInt32($0 + 1) << 24 | UInt32(mesh.leafIndex / 3) } ?? 0))
        if sways { hasSwayingMeshes = true }
        meshBounds.append((mesh.bounds.lo, mesh.bounds.hi))
        return meshes.count - 1
    }

    func addCutout(alpha: [UInt8], coverage: Float) -> Int {
        precondition(alpha.count == FoliageTextures.cardSheetSize * FoliageTextures.cardSheetSize && cutouts.count < 15,
                     "Scene.addCutout: a layer is a card sheet's alpha, and a triangle names one of 15")
        cutouts.append((alpha, coverage))
        return cutouts.count - 1
    }

    func addAssembly(_ assembly: Assembly) -> Int {
        assemblies.append(assembly)
        return assemblies.count - 1
    }

    func addVoxelPlant(_ plant: FoliageVoxels.Plant) -> Int {
        voxelPlants.append(plant)
        return voxelPlants.count - 1
    }

    /// Mesh `mesh` is voxel plant `plant`'s wood, or its leaves (VoxelLOD).
    func setMeshVoxels(_ mesh: Int, plant: Int, leaves: Bool) {
        guard mesh >= 0 else { return }
        meshVoxels[mesh] = UInt32(plant) | (leaves ? Scene.meshVoxelsLeaves : 0)
    }

    /// An instance of an assembly: `material` is its wood's, and the next material its leaves'.
    @discardableResult
    func addInstance(assembly: Int, _ material: Int, _ transform: float4x4) -> Int {
        instances.append(Instance(mesh: -1, material: material, mask: instanceMask(Scene.maskGeometry, mesh: -1, assembly: true),
                                  transform: transform, prevTransform: transform,
                                  animation: nil, assembly: assembly, normalMatrix: transform.inverse.transpose))
        return instances.count - 1
    }

    /// An SDF shape for instances to place (`addInstance(sdf:)`).
    func addSDFShape(_ shape: SDFShape) -> Int {
        sdfShapes.append(shape)
        sdfBounds.append(shape.bounds(volumes: sdfVolumes))
        return sdfShapes.count - 1
    }

    /// A baked distance grid for SDF shapes' `.volume` nodes (added before the shapes that use it).
    func addSDFVolume(_ volume: SDFVolume) -> Int {
        sdfVolumes.append(volume)
        return sdfVolumes.count - 1
    }

    /// An instance of SDF shape `sdf`: `material` is its nodes' with offset 0, the others' after it.
    @discardableResult
    func addInstance(sdf: Int, _ material: Int, _ transform: float4x4, mask: UInt32 = Scene.maskGeometry,
                     animation: ((Float) -> float4x4)? = nil) -> Int {
        // (The raster can't draw a shape: virtual shadow maps trace it.)
        instances.append(Instance(mesh: -1, material: material, mask: instanceMask(mask, mesh: -1, assembly: true),
                                  transform: transform, prevTransform: transform, animation: animation,
                                  normalMatrix: transform.inverse.transpose, sdf: sdf))
        return instances.count - 1
    }

    // MARK: - Physics

    private func physicsWorld() -> PhysicsWorld {
        if let physics { return physics }
        let world = PhysicsWorld(substeps: settings.physics.substeps)
        physics = world
        return world
    }

    /// A rigid body: an instance of SDF shape `sdf` that the physics moves, starting at `transform` (a rotation and a
    /// translation). `density` kg/m^3; `friction` and `restitution` are mixed with what it touches (the geometric
    /// mean and the larger).
    @discardableResult
    func addBody(sdf: Int, _ material: Int, _ transform: float4x4, density: Float = 500, friction: Float = 0.5,
                 restitution: Float = 0.2, velocity: SIMD3<Float> = .zero, spin: SIMD3<Float> = .zero) -> Int {
        let i = addInstance(sdf: sdf, material, transform)
        instances[i].simulated = true
        let world = physicsWorld()
        world.setVolumes(sdfVolumes)
        world.addBody(sdf: sdf, sdfShapes[sdf], transform: transform, instance: i, density: density, friction: friction,
                      restitution: restitution, velocity: velocity, spin: spin)
        return i
    }

    /// The cloths' meshes, in the physics' order.
    private(set) var clothMeshes: [Int] = []

    /// A cloth: `columns` x `rows` vertices from `origin` along `across` and `down` (its whole width and height),
    /// `pinned` ones (row-major) held where they are; the physics moves the rest, the GPU writes the mesh every frame.
    func addCloth(_ material: Int, origin: SIMD3<Float>, across: SIMD3<Float>, down: SIMD3<Float>, columns: Int, rows: Int,
                  pinned: Set<Int>, thickness: Float = 0.008, friction: Float = 0.6) {
        var positions: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        let normal = normalize(cross(down, across))
        for r in 0..<rows {
            for c in 0..<columns {
                let u = Float(c) / Float(columns - 1), v = Float(r) / Float(rows - 1)
                positions.append(origin + across * u + down * v)
                uvs.append(SIMD2(u, v))
            }
        }
        // Wound as PhysicsGPU's normals face: along a row, then down a column.
        for r in 0..<(rows - 1) {
            for c in 0..<(columns - 1) {
                let a = UInt32(r * columns + c), b = a + 1, d = a + UInt32(columns), e = d + 1
                indices += [a, d, b, b, d, e]
            }
        }
        // As far as it can get: its size every way from where it starts, and down to the floor.
        var box = AABB()
        for p in positions { box.grow(p) }
        let reach = max(length(across), length(down)) + 0.1
        box.lo = simd_min(box.lo - reach, SIMD3(box.lo.x - reach, -0.1, box.lo.z - reach))
        box.hi += reach
        let mesh = addDeformingMesh((positions, [SIMD3<Float>](repeating: normal, count: positions.count), indices), uvs: uvs, bounds: box)
        addDeformingInstance(mesh, material)
        clothMeshes.append(mesh)
        physicsWorld().addCloth(origin: origin, across: across, down: down, columns: columns, rows: rows, pinned: pinned,
                                thickness: thickness, friction: friction, vertexBase: deforming.last!.first)
    }

    /// The soft bodies' meshes, in the physics' order.
    private(set) var softMeshes: [Int] = []

    /// A soft body made of `model` (PhysicsSoft.swift), placed by `transform` (a rotation and a translation): the
    /// physics moves its lattice, the GPU writes its surface every frame. `edge` and `volume`: its links' and tets'
    /// compliance; `bounds`: where it can get to (the mesh's box whatever it does).
    func addSoftBody(_ model: SoftModel, _ material: Int, _ transform: float4x4, bounds: AABB, velocity: SIMD3<Float> = .zero,
                     density: Float = 1000, edge: Float = 1e-3, volume: Float = 1e-9, damping: Float = PhysicsWorld.softLinkDamping,
                     friction: Float = 0.6) {
        let rotation = simd_float3x3(columns: (PhysicsMath.xyz(transform.columns.0), PhysicsMath.xyz(transform.columns.1),
                                               PhysicsMath.xyz(transform.columns.2)))
        let positions = model.surface.positions.map { PhysicsMath.xyz(transform * SIMD4($0, 1)) }
        let mesh = addDeformingMesh((positions, model.surface.normals.map { rotation * $0 }, model.surface.indices), bounds: bounds)
        addDeformingInstance(mesh, material)
        softMeshes.append(mesh)
        physicsWorld().addSoftBody(model, transform: transform, vertexBase: deforming.last!.first, velocity: velocity, density: density,
                                   edge: edge, volume: volume, damping: damping, friction: friction)
    }

    /// The soft bodies' drawn vertices: where their meshes' last-frame vertices are (once `finishDeforming` put them).
    private func finishSoftBodies() {
        guard let physics, !softMeshes.isEmpty else { return }
        for v in physics.softVertices.indices {
            physics.softVertices[v].info.y = meshes[softMeshes[Int(physics.softVertices[v].info.z)]].prevOffset
        }
    }

    /// Particles: balls of `radius` at `positions` that the physics moves (each an instance of one sphere shape).
    func addParticles(_ material: Int, radius: Float, positions: [SIMD3<Float>], density: Float = 1500, friction: Float = 0.5) {
        guard !positions.isEmpty else { return }
        let sphere = addSDFShape(SDFShape(.sphere(radius: radius)))
        let world = physicsWorld()
        for p in positions {
            let i = addInstance(sdf: sphere, material, translate(p))
            instances[i].simulated = true
            world.addParticle(at: p, radius: radius, instance: i, density: density, friction: friction)
        }
    }

    /// Something bodies bounce off that never moves: SDF shape `sdf` at `transform` (draw it, or not, apart).
    func addStaticCollider(sdf: Int, _ transform: float4x4, friction: Float = 0.6, restitution: Float = 0.2) {
        let world = physicsWorld()
        world.setVolumes(sdfVolumes)
        world.addStatic(sdf: sdf, sdfShapes[sdf], transform: transform, friction: friction, restitution: restitution)
    }

    /// An endless static plane bodies rest on.
    func addStaticPlane(point: SIMD3<Float>, normal: SIMD3<Float>, friction: Float = 0.6, restitution: Float = 0.2) {
        physicsWorld().addPlane(point: point, normal: normal, friction: friction, restitution: restitution)
    }

    /// Generated plants were placed (Flora): see `hasPlants`.
    func notePlants() { hasPlants = true }

    /// A metallic-roughness material with a specular lobe (the gallery's floor and plinths).
    func addPBRMaterial(baseColor: SIMD3<Float>, metallic: Float, roughness: Float) -> Int {
        materials.append(GPUMaterial(albedo: SIMD4<Float>(baseColor, metallic), emission: SIMD4<Float>(.zero, roughness),
                                     params: SIMD4(1, 1, 0, 0)))
        return materials.count - 1
    }

    /// Window glass tinted `tint` (white = clear), for instances with `maskGlass`.
    func addGlassMaterial(tint: SIMD3<Float>) -> Int {
        hasGlass = true
        return addMaterial(GPUMaterial(albedo: SIMD4(tint, 0), emission: SIMD4(.zero, 0), params: SIMD4(0, 1, 0, 0)))
    }

    /// Any material, as it is.
    func addMaterial(_ material: GPUMaterial) -> Int {
        materials.append(material)
        return materials.count - 1
    }

    /// An image for materials to sample: its index for `GPUMaterial.textures`.
    func addTexture(_ source: TextureSource) -> UInt32 {
        textures.append(source)
        return UInt32(textures.count - 1)
    }

    /// Room for this much more geometry (a builder that knows how much it is about to add): an array that grows by
    /// itself doubles, and ends up to twice as large as what it holds.
    func reserveGeometry(vertices: Int, indices count: Int, instances more: Int = 0) {
        positions.reserveCapacity(positions.count + vertices)
        normals.reserveCapacity(normals.count + vertices)
        uvs.reserveCapacity(uvs.count + vertices)
        indices.reserveCapacity(indices.count + count)
        // In steps of 65536: a scene made again with a few more instances then asks for a block of the size the last
        // one let go of, which the allocator hands back, instead of a new one (it keeps what was freed).
        if more > 0 { instances.reserveCapacity((instances.count + more + 0xFFFF) & ~0xFFFF) }
    }

    /// A diffuse material (metallic 0, roughness 1, no specular: how every generated object has always looked).
    /// `translucency`: a leaf's, the share of its light that comes through from the far side.
    /// `texture`: its base colour's detail (the colour is multiplied by it), from `addGeneratedTexture`.
    func addMaterial(albedo: SIMD3<Float>, emission: SIMD3<Float> = .zero, translucency: Float = 0, texture: UInt32 = .max) -> Int {
        materials.append(GPUMaterial(albedo: SIMD4<Float>(albedo, 0), emission: SIMD4<Float>(emission, 1), params: SIMD4(0, 1, 0, translucency),
                                     textures: SIMD4(texture, .max, .max, .max)))
        return materials.count - 1
    }

    /// A strand's (Hair.metal): its colour, the one it is seen to have (the pigment's absorption is fitted to it).
    /// Marked by params.z < 0 (an emissive-mesh light's is > 0).
    func addHairMaterial(color: SIMD3<Float>) -> Int {
        materials.append(GPUMaterial(albedo: SIMD4<Float>(color, 0), emission: SIMD4<Float>(.zero, 1), params: SIMD4(0, 1, -1, 0)))
        return materials.count - 1
    }

    func addLeafMaterial(_ material: LeafMaterial) { leafMaterials.append(material) }

    /// A texture made here rather than read from a model (FoliageTextures): the index a material names it by. The
    /// streamer keeps one cache file for all of a scene kind's, named by their pixels, so a change remakes it.
    func addGeneratedTexture(_ image: FoliageTextures.Image, name: String) -> UInt32 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in image.pixels { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        // (With the cache off, a file of its own: the mip chains named by parameters stay as they are.)
        textures.append(TextureSource(data: Data(image.pixels), srgb: true, name: "generated/\(name)",
                                      modelPath: GeneratedCache.folder.appendingPathComponent("\(settings.kind)\(GeneratedCache.enabled ? "" : "-uncached")").path,
                                      cacheKey: "\(name)-\(image.width)x\(image.height)-\(String(hash, radix: 16))",
                                      raw: (image.width, image.height)))
        return UInt32(textures.count - 1)
    }

    /// A generated texture that `draw` draws only if no cache holds it: the caches name it by `key`, which says
    /// everything its pixels depend on (the generator's version, a seed). With the cache off it is drawn here and
    /// named by its pixels, as above.
    func addGeneratedTexture(name: String, width: Int, height: Int, key: String, _ draw: @escaping () -> FoliageTextures.Image) -> UInt32 {
        guard GeneratedCache.enabled else { return addGeneratedTexture(draw(), name: name) }
        textures.append(TextureSource(data: Data(), srgb: true, name: "generated/\(name)",
                                      modelPath: GeneratedCache.folder.appendingPathComponent("\(settings.kind)").path,
                                      cacheKey: "\(name)-\(width)x\(height)-\(key)", raw: (width, height),
                                      pixels: { Data(draw().pixels) }))
        return UInt32(textures.count - 1)
    }

    /// The share of the deciduous plants' leaves that have fallen at `season` (the plants' variants drop them).
    static func leafFall(season: Float) -> Float {
        let t = min(max((season - 0.62) / 0.33, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The leaves at `season`: 0 = spring (fresh, light), 0.3 = summer, from 0.5 they turn, each material in its own
    /// time, and by winter (1) what is left is brown; evergreens stay as they are. `translucency` scales how much
    /// light every leaf lets through (0 = none: opaque leaves). Only the materials change (the renderer uploads the range).
    func setLeaves(season s: Float, translucency: Float = 1) {
        guard leafState != SIMD2(s, translucency), !leafMaterials.isEmpty else { return }
        leafState = SIMD2(s, translucency)
        func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }
        var lo = Int.max, hi = 0
        for m in leafMaterials {
            var color = m.summer
            if let autumn = m.autumn {
                color *= 1 + SIMD3<Float>(0.25, 0.3, 0.1) * (1 - smooth(0, 0.25, s))
                color += (autumn - color) * smooth(m.turn - 0.1, m.turn + 0.1, s)
                color += (SIMD3<Float>(0.2, 0.13, 0.07) - color) * smooth(0.82, 1, s) * 0.8
            }
            let albedo = SIMD4(color * m.gain, materials[m.material].albedo.w), through = m.translucency * translucency
            guard materials[m.material].albedo != albedo || materials[m.material].params.w != through else { continue }
            materials[m.material].albedo = albedo
            materials[m.material].params.w = through
            lo = min(lo, m.material); hi = max(hi, m.material + 1)
        }
        guard lo < hi else { return }
        materialsDirty = materialsDirty.map { min($0.lowerBound, lo)..<max($0.upperBound, hi) } ?? lo..<hi
    }

    /// The open world's lights, as far on as they are with the sun `sunElevation` high (radians): what their
    /// materials emit. (A light the scene samples takes what it emits from its material; how likely it is to be
    /// picked stays what it is when it is on.)
    /// The same goes into the light table's triangles (`GPUTriangleInfo.radianceLum`), which say how bright a light
    /// is to whoever picks one among many: a light that is off is not picked.
    func setCityLights(sunElevation: Float) {
        // Above and below the heights between which lights come on, nothing changes.
        let degree = Float.pi / 180, elevation = min(max(sunElevation, -9 * degree), 4 * degree)
        guard cityLightsElevation != elevation, !cityLights.isEmpty else { return }
        cityLightsElevation = elevation
        var lo = Int.max, hi = 0, first = Int.max, last = 0
        for i in cityLights.indices {
            let light = cityLights[i], on = World.lightOn(elevation: elevation, window: light.window)
            guard on != light.on else { continue }
            cityLights[i].on = on
            materials[light.material].emission = SIMD4(light.emission * on, materials[light.material].emission.w)
            lo = min(lo, light.material); hi = max(hi, light.material + 1)
            for range in light.triangles {
                for t in range { lightTable.triangles[t].radianceLum = cityLightRadiance[t] * on }
                first = min(first, range.lowerBound); last = max(last, range.upperBound)
            }
        }
        if lo < hi { materialsDirty = materialsDirty.map { min($0.lowerBound, lo)..<max($0.upperBound, hi) } ?? lo..<hi }
        if first < last {
            lightTrianglesDirty = lightTrianglesDirty.map { min($0.lowerBound, first)..<max($0.upperBound, last) } ?? first..<last
        }
    }

    /// Which of the light table's triangles each city light has: its material's mesh lights'. They start as their
    /// lights do, off.
    private func bindCityLights() {
        guard !cityLights.isEmpty, !meshLights.isEmpty else { return }
        let index = Dictionary(uniqueKeysWithValues: cityLights.enumerated().map { ($1.material, $0) })
        cityLightRadiance = lightTable.triangles.map(\.radianceLum)
        for light in meshLights {
            guard let c = index[instances[light.instance].material + light.materialOffset] else { continue }
            let range = light.firstTriangle..<(light.firstTriangle + light.triangleCount)
            cityLights[c].triangles.append(range)
            for t in range { lightTable.triangles[t].radianceLum = cityLightRadiance[t] * cityLights[c].on }
        }
    }

    /// The light table's triangles changed since the last call (`setCityLights`), for the renderer to write again.
    func takeLightTrianglesDirty() -> Range<Int>? {
        defer { lightTrianglesDirty = nil }
        return lightTrianglesDirty
    }

    @discardableResult
    func addInstance(_ mesh: Int, _ material: Int, _ transform: float4x4,
                             mask: UInt32 = Scene.maskGeometry,
                             animation: ((Float) -> float4x4)? = nil) -> Int {
        instances.append(Instance(mesh: mesh, material: material, mask: instanceMask(mask, mesh: mesh, assembly: false),
                                  transform: transform, prevTransform: transform, animation: animation,
                                  normalMatrix: transform.inverse.transpose))
        return instances.count - 1
    }

    /// A moving sphere light (the original scenes' lights), drawn with `sphereMesh`.
    func addLight(color: SIMD3<Float>, radius: Float, sphereMesh: Int, path: @escaping (Float) -> SIMD3<Float>) {
        addLight(.sphere(radius: radius), color: color, proxyMesh: sphereMesh) { LightPose(position: path($0)) }
    }

    private var lightSphereMesh = -1, lightQuadMesh = -1          // the proxies' shared shapes
    private var lightCapsuleMeshes: [SIMD2<Float>: Int] = [:]     // by (length, radius)

    /// Adds a light and, but for the sun, the emissive shape that shows it (maskLights: it never blocks light).
    /// The shape's radiance makes it look as bright as the light is: I / (pi r^2) for a sphere of intensity I,
    /// the radiance itself for a rect, 2 I / (pi r length) for a tube (a cylinder whose broadside intensity per unit
    /// length, radiance x 2r, is the 4 I / (pi length) the shaders give it).
    @discardableResult
    func addLight(_ kind: LightKind, color: SIMD3<Float>, proxyMesh: Int? = nil, motion: LightMotion = .animated,
                  pose: @escaping (Float) -> LightPose) -> Int {
        var light = Light(kind: kind, color: color, pose: pose, motion: motion)
        var mesh = -1, emission = SIMD3<Float>(repeating: 0)
        switch kind {
        case .sphere(let r), .spot(let r, _, _):
            if proxyMesh == nil && lightSphereMesh < 0 { lightSphereMesh = addMesh(Scene.icosphere(subdivisions: 2)) }
            mesh = proxyMesh ?? lightSphereMesh
            emission = color / (.pi * r * r)
        case .rect:
            if proxyMesh == nil && lightQuadMesh < 0 { lightQuadMesh = addMesh(Scene.quadMesh()) }
            mesh = proxyMesh ?? lightQuadMesh
            emission = color
        case .tube(let length, let r):
            if proxyMesh == nil && lightCapsuleMeshes[SIMD2(length, r)] == nil {
                lightCapsuleMeshes[SIMD2(length, r)] = addMesh(Scene.capsuleMesh(halfLength: length / 2, radius: r))
            }
            mesh = proxyMesh ?? lightCapsuleMeshes[SIMD2(length, r)]!
            emission = 2 * color / (.pi * r * length)
        case .sun, .mesh:
            break
        }
        if mesh >= 0 {
            light.proxyMaterial = addMaterial(albedo: .zero, emission: emission)
            light.proxyEmission = emission
            light.proxyInstance = addInstance(mesh, light.proxyMaterial, matrix_identity_float4x4, mask: Scene.maskLights)
            instances[light.proxyInstance].poseAnimated = motion == .animated   // otherwise init's first update places it for good
        }
        lights.append(light)
        return lights.count - 1
    }

    // MARK: - Emissive-mesh lights

    /// A light that comes with a borrowed mesh, made already: sampled as the scene's own emissive instances are.
    func addMeshLight(_ light: BorrowedLight) { borrowedLights.append(light) }

    /// Every geometry instance with an emissive material becomes a mesh light (after the analytic lights, which
    /// assignLightGroups has sorted): its triangles, each weighted by area x emitted luminance (an emissive texture's
    /// luminance from a small decoded copy), and the bounding sphere / mean normal proxy the shaders weigh it by.
    private func buildMeshLights() {
        // (A borrowed mesh's lights may be off as the scene is made: the open world's by day.)
        guard !borrowedLights.isEmpty || materials.contains(where: { $0.emission.x > 0 || $0.emission.y > 0 || $0.emission.z > 0 }) else { return }
        emissiveTriangles.reserveCapacity(borrowedLights.reduce(0) { $0 + $1.range.count })
        var textureCache: [Int: ((SIMD2<Float>) -> SIMD3<Float>)?] = [:]
        func emissiveTexture(_ index: UInt32) -> ((SIMD2<Float>) -> SIMD3<Float>)? {
            guard index != .max else { return nil }
            if let cached = textureCache[Int(index)] { return cached }
            let sampler = Scene.thumbnailSampler(textures[Int(index)].data)
            textureCache[Int(index)] = sampler
            return sampler
        }
        var flagged = Set<Int>()
        let lent = Set(borrowed.map(\.mesh))   // their lights come with them (`addMeshLight`)
        var sdfLights: [Int: (positions: [SIMD3<Float>], indices: [UInt32], materials: [Int])] = [:]
        for (i, inst) in instances.enumerated() where inst.isGeometry && !inst.deforms {
            if inst.sdf >= 0 {
                // An SDF shape: a light per material of its that emits, its triangles those of the shape's surface
                // (made once per shape, just outside it: SDFShape.triangles) where that material is.
                let shape = sdfShapes[inst.sdf]
                for offset in 0..<shape.materialCount {
                    let e = materials[inst.material + offset].emission
                    let le = SIMD3(e.x, e.y, e.z)
                    guard le.max() > 0 else { continue }
                    if sdfLights[inst.sdf] == nil { sdfLights[inst.sdf] = shape.triangles(volumes: sdfVolumes) }
                    let mesh = sdfLights[inst.sdf]!
                    var draft = MeshLightDraft()
                    for t in mesh.materials.indices where mesh.materials[t] == offset {
                        draft.add(mesh.positions[Int(mesh.indices[3 * t])], mesh.positions[Int(mesh.indices[3 * t + 1])],
                                  mesh.positions[Int(mesh.indices[3 * t + 2])], emission: le)
                    }
                    guard var light = draft.finish(instance: i, firstTriangle: emissiveTriangles.count) else { continue }
                    light.materialOffset = offset
                    emissiveTriangles += draft.triangles
                    meshLights.append(light)
                    lights.append(Light(kind: .mesh(meshLights.count - 1), color: light.power, pose: { _ in LightPose(position: .zero) }))
                    flagged.insert(inst.material + offset)
                }
                continue
            }
            let material = materials[inst.material]
            let factor = SIMD3(material.emission.x, material.emission.y, material.emission.z)
            guard factor.max() > 0 else { continue }
            let positions: [SIMD3<Float>], uvsOf: [SIMD2<Float>], tris: ArraySlice<UInt32>
            if let src = emitterSources[i] {
                (positions, uvsOf, tris) = (src.positions, src.uvs, src.indices[...])
            } else if inst.mesh >= 0, !lent.contains(inst.mesh), Int(meshes[inst.mesh].firstIndex) < indices.count {
                let m = meshes[inst.mesh]
                (positions, uvsOf, tris) = (self.positions, uvs, indices[Int(m.firstIndex) ..< Int(m.firstIndex + m.indexCount)])
            } else {
                continue
            }
            let texture = emissiveTexture(material.textures.w)
            var draft = MeshLightDraft()
            let t = Array(tris)
            for f in stride(from: 0, to: t.count - 2, by: 3) {
                let (a, b, c) = (Int(t[f]), Int(t[f + 1]), Int(t[f + 2]))
                let uv0 = a < uvsOf.count ? uvsOf[a] : .zero, uv1 = b < uvsOf.count ? uvsOf[b] : .zero
                let uv2 = c < uvsOf.count ? uvsOf[c] : .zero
                var le = factor
                if let texture {
                    le *= (texture((uv0 + uv1 + uv2) / 3) * 2 + texture(uv0) + texture(uv1) + texture(uv2)) / 5
                }
                draft.add(positions[a], positions[b], positions[c], uv0: uv0, uv1: uv1, uv2: uv2, emission: le)
            }
            guard let light = draft.finish(instance: i, firstTriangle: emissiveTriangles.count) else { continue }
            emissiveTriangles += draft.triangles
            meshLights.append(light)
            lights.append(Light(kind: .mesh(meshLights.count - 1), color: light.power, pose: { _ in LightPose(position: .zero) }))
            flagged.insert(inst.material)
        }
        // The lights that came with borrowed meshes: their triangles as they are.
        for borrowed in borrowedLights {
            var light = borrowed.light
            light.firstTriangle = emissiveTriangles.count
            borrowed.triangles.withUnsafeBufferPointer { emissiveTriangles.append(contentsOf: UnsafeBufferPointer(rebasing: $0[borrowed.range])) }
            meshLights.append(light)
            lights.append(Light(kind: .mesh(meshLights.count - 1), color: light.power, pose: { _ in LightPose(position: .zero) }))
            flagged.insert(instances[light.instance].material + light.materialOffset)
        }
        borrowedLights = []
        for m in flagged { materials[m].params.z = 1 }
        if !meshLights.isEmpty {
            print(String(format: "Emissive lights: %d meshes, %d triangles", meshLights.count, emissiveTriangles.count))
        }
    }

    /// A 64-pixel copy of an encoded image, sampled (repeat, nearest) as linear RGB; nil if it doesn't decode.
    private static func thumbnailSampler(_ data: Data) -> ((SIMD2<Float>) -> SIMD3<Float>)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary)
        else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let linear = (0..<256).map { i -> Float in
            let c = Float(i) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let texels = w * h
        let rgb: [SIMD3<Float>] = (0..<texels).map { (i: Int) -> SIMD3<Float> in
            let r: Float = linear[Int(pixels[4 * i])], g: Float = linear[Int(pixels[4 * i + 1])], b: Float = linear[Int(pixels[4 * i + 2])]
            return SIMD3<Float>(r, g, b)
        }
        return { uv in
            let x = Int((uv.x - uv.x.rounded(.down)) * Float(w)) % w, y = Int((uv.y - uv.y.rounded(.down)) * Float(h)) % h
            return rgb[max(y, 0) * w + max(x, 0)]
        }
    }

    // MARK: - glTF models

    /// Where the Gallery scene finds its models: `METALRENDERER_ASSETS`, or `Assets/` next to `Package.swift`.
    static let assetsDirectory: URL = {
        if let dir = ProcessInfo.processInfo.environment["METALRENDERER_ASSETS"] { return URL(fileURLWithPath: dir) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Assets")
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
    private func addExtraModel(_ extra: ExtraModel) {
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
    private func buildGallery() {
        let quad = addMesh(Scene.quadMesh())
        let cube = addMesh(Scene.cubeMesh())
        let sphere = addMesh(Scene.icosphere(subdivisions: 2))
        let floor = addPBRMaterial(baseColor: [0.32, 0.31, 0.30], metallic: 0, roughness: 0.25)   // polished stone
        let wall = addMaterial(albedo: [0.70, 0.70, 0.68])
        let plinth = addPBRMaterial(baseColor: [0.62, 0.62, 0.64], metallic: 1, roughness: 0.35)   // brushed steel

        let w: Float = 26, h: Float = 7, d: Float = 18
        addInstance(quad, floor, translate([0, 0, 0]) * scale([w, 1, d]))
        addInstance(quad, wall, translate([0, h / 2, -d / 2]) * rotate(.pi / 2, [1, 0, 0]) * scale([w, 1, h]))
        addInstance(quad, wall, translate([-w / 2, h / 2, 0]) * rotate(-.pi / 2, [0, 0, 1]) * scale([h, 1, d]))
        addInstance(quad, wall, translate([w / 2, h / 2, 0]) * rotate(.pi / 2, [0, 0, 1]) * scale([h, 1, d]))

        let files = Scene.galleryFiles()
        let plinthHeight: Float = 0.3
        let start = CFAbsoluteTimeGetCurrent()
        var triangles = 0
        loadStep?.set(done: 0, total: files.count)
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
            addInstance(cube, plinth, translate(p + [0, plinthHeight / 2, 0]) * scale([1.3, plinthHeight, 1.3]))
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

    /// Capsule along Y: a cylinder of `halfLength` either side of the origin with hemispherical caps, smooth normals.
    static func capsuleMesh(halfLength: Float, radius: Float, segments: Int = 24, rings: Int = 6) -> MeshGeometry {
        var p: [SIMD3<Float>] = [], n: [SIMD3<Float>] = [], idx: [UInt32] = []
        // Rows from the bottom pole to the top pole; the two equator rows sit at -halfLength and +halfLength.
        var rows: [(y: Float, r: Float, ny: Float)] = []
        for i in 0...rings {   // bottom cap
            let a = -Float.pi / 2 + Float.pi / 2 * Float(i) / Float(rings)
            rows.append((-halfLength + radius * sin(a), radius * cos(a), sin(a)))
        }
        for i in 0...rings {   // top cap
            let a = Float.pi / 2 * Float(i) / Float(rings)
            rows.append((halfLength + radius * sin(a), radius * cos(a), sin(a)))
        }
        for row in rows {
            for s in 0...segments {
                let phi = 2 * Float.pi * Float(s) / Float(segments)
                let dir = SIMD3<Float>(cos(phi), 0, sin(phi))
                p.append(SIMD3(dir.x * row.r, row.y, dir.z * row.r))
                let r = (1 - row.ny * row.ny).squareRoot()
                n.append(normalize(SIMD3(dir.x * r, row.ny, dir.z * r) + [0, 1e-6, 0]))
            }
        }
        let stride = UInt32(segments + 1)
        for r in 0..<UInt32(rows.count - 1) {
            for s in 0..<UInt32(segments) {
                let a = r * stride + s, b = a + stride
                idx += [a, b, a + 1, a + 1, b, b + 1]
            }
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
