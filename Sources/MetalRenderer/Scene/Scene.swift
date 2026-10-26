import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import ImageIO
import Landscape
import Materials
import Physics
import Plants
import Procedural
import simd

/// A small Cornell-style room with static objects, animated objects and moving sphere lights, or one of the other
/// scenes (`SceneSettings`; the stress building is in Scene+Stress.swift).
/// All geometry lives in one shared vertex/index buffer; each mesh gets its own
/// primitive acceleration structure and every object is an instance of a mesh.
package final class Scene {
    package struct Instance {
        package var mesh: Int
        package var material: Int
        package var mask: UInt32
        package var transform: float4x4
        package var prevTransform: float4x4
        package var animation: ((Float) -> float4x4)?
        package var virtualMesh = -1                  // >= 0: index into `virtualMeshes` (then `mesh` is -1)
        package var assembly = -1                     // >= 0: index into `assemblies` (then `mesh` is -1 and `material` is its
                                              // wood's, with its leaves' right after it)
        /// `transform.inverse.transpose`, kept up to date with the transform (the GPU's normal matrix; its columns are
        /// the rows of the world -> object matrix, which the shading reads them as).
        package var normalMatrix = matrix_identity_float4x4
        /// A light's proxy whose light moves (`LightMotion.animated`): `Scene.update` re-poses it every frame.
        package var poseAnimated = false
        /// Its mesh deforms every frame on the GPU: a crowd member's pose slot (Crowd), or a cloth (Physics.swift).
        package var deforms = false
        /// ...that walks: `Scene.update` moves it along its lane.
        package var travels = false
        /// >= 0: an SDF shape's instance, index into `sdfShapes` (then `mesh` is -1 and `material` is its nodes' first).
        package var sdf = -1
        /// A rigid body's: the physics (Physics.swift) moves it.
        package var simulated = false

        /// Never moves or deforms: its transform is the one it was added with (a still scene's structure is built once).
        package var isStatic: Bool { animation == nil && !poseAnimated && !deforms && !simulated }
        /// Its transform changes from frame to frame.
        package var moves: Bool { animation != nil || poseAnimated || travels || simulated }
        /// Solid geometry, which shadow and GI rays meet.
        package var isGeometry: Bool { mask == Scene.maskGeometry }
    }

    /// A plant as parts (Foliage.Plant): meshes placed in the plant's own space, many of them the same few meshes
    /// (the species' boughs). Every instance of the plant shares it, through the structures over its parts (PlantTracing).
    package struct Assembly {
        /// What a part turns about in the wind (Shaders/Foliage.metal). `angle`: its largest turn, at full wind; 0 = it doesn't.
        package struct Bone {
            package var pivot = SIMD3<Float>()        // plant space, at rest
            package var angle: Float = 0
            package var axis = SIMD3<Float>(1, 0, 0)
            package var phase: Float = 0
        }
        /// The whole plant's largest lean about its foot, at full wind (WIND_ROOT_SWAY in Shaders/Foliage.metal).
        static let rootSway: Float = 0.022
        package struct Part {
            var mesh: Int
            var transform: float4x4           // into plant space: a rotation, a uniform scale and a translation
            var firstLeaf: UInt32             // the mesh's triangles from here on take the leaves' material
            var leafCount: UInt32 = 0         // how many they are (autumn drops them from the end); 0 = it keeps them
            var bone: Int
            package var bounds: AABB                  // of the placed mesh, in plant space (its vertices', not its box's)
            var windPad: Float = 0            // how far its bones' largest turns (full wind) can move any of it
            var limb = Bone()                 // the limb it is, or hangs on
            var bough = Bone()                // itself on that limb, if it is a bough

            /// (As the memberwise initializer, for the modules above this one.)
            package init(mesh: Int, transform: float4x4, firstLeaf: UInt32, leafCount: UInt32 = 0, bone: Int, bounds: AABB, windPad: Float = 0, limb: Bone = Bone(), bough: Bone = Bone()) {
                self.mesh = mesh
                self.transform = transform
                self.firstLeaf = firstLeaf
                self.leafCount = leafCount
                self.bone = bone
                self.bounds = bounds
                self.windPad = windPad
                self.limb = limb
                self.bough = bough
            }
        }
        var parts: [Part]
        var bounds: AABB
        var evergreen = false
        /// Not a plant: a building of modules (Building.Module). It has no wind, no leaves and no voxels, and one
        /// variant (PlantTracing).
        var rigid = false

        /// (As the memberwise initializer, for the modules above this one.)
        package init(parts: [Part], bounds: AABB, evergreen: Bool = false, rigid: Bool = false) {
            self.parts = parts
            self.bounds = bounds
            self.evergreen = evergreen
            self.rigid = rigid
        }
    }

    /// A leaf material as `setLeaves` changes it: its summer colour, what it turns to in autumn and when in the year
    /// (0...1), if it turns at all, and how much light it lets through.
    package struct LeafMaterial {
        var material: Int
        var summer: SIMD3<Float>
        var autumn: SIMD3<Float>? = nil
        var turn: Float = 0
        var translucency: Float
        var gain = SIMD3<Float>.one           // the material's colour is the leaf's times this (1 / its texture's mean)
    }

    /// An encoded image a material samples (TextureSource, in the core).
    package typealias TextureSource = EngineCore.TextureSource

    /// A light's shape. Angles in radians.
    package enum LightKind {
        case sphere(radius: Float)                              // color = radiant intensity
        case spot(radius: Float, inner: Float, outer: Float)    // a sphere light inside a cone (half angles), same units
        case sun(angularRadius: Float)                          // color = irradiance, from LightPose.direction
        case rect(width: Float, height: Float)                  // one-sided panel, color = radiance
        case tube(length: Float, radius: Float)                 // capsule, color = intensity (as a sphere of that power)
        case mesh(Int)                                          // an emissive instance: index into `meshLights`

        var isSun: Bool { if case .sun = self { return true } else { return false } }
    }

    /// Where a light is and how bright, at one time.
    package struct LightPose {
        var position: SIMD3<Float>
        var direction = SIMD3<Float>(0, -1, 0)   // spot axis, rect normal, toward the sun, tube axis
        var tangent: SIMD3<Float>? = nil         // rect: its width's direction (default: horizontal)
        var scale = SIMD3<Float>(repeating: 1)   // multiplies the colour (flicker, the sun's colour over the day)

        /// (As the memberwise initializer, for the modules above this one.)
        package init(position: SIMD3<Float>, direction: SIMD3<Float> = SIMD3<Float>(0, -1, 0), tangent: SIMD3<Float>? = nil, scale: SIMD3<Float> = SIMD3<Float>(repeating: 1)) {
            self.position = position
            self.direction = direction
            self.tangent = tangent
            self.scale = scale
        }
    }

    /// What of a light's pose changes over time: `update` re-evaluates only that, and only an `animated` light's proxy
    /// is a moving instance for the ray tracers. (Suns are always re-posed: they follow the time of day.)
    package enum LightMotion {
        case animated      // position / direction (and maybe scale)
        case scaleOnly     // fixed in place, its brightness or colour changes (flicker, chases)
        case constant      // nothing
    }

    package struct Light {
        package var kind: LightKind
        package var color: SIMD3<Float>               // see LightKind for the units
        package var pose: (Float) -> LightPose
        package var motion = LightMotion.animated
        package var current = LightPose(position: .zero)
        package var proxyInstance = -1                // visible emissive shape that follows the light (maskLights)
        package var proxyMaterial = -1
        package var proxyEmission = SIMD3<Float>(repeating: 0)   // its radiance at scale 1
        package var group = 0                         // shadow-denoiser channel (see assignLightGroups)
        /// A rect light's reach (GPULight axis.w; 0: all space): how far below it, and beyond its edges, it lights.
        package var reach: Float = 0
        /// Its place among the lights as they were added (assignLightGroups sorts them): what the outline names it by.
        package var order = 0

        package var isMesh: Bool { if case .mesh = kind { return true }; return false }
    }

    /// An emissive instance's light (MeshLight, in the core).
    package typealias MeshLight = EngineCore.MeshLight

    /// A mesh light's triangles as they are put together (MeshLightDraft, in the core).
    package typealias MeshLightDraft = EngineCore.MeshLightDraft

    /// A mesh light made already (an open world's tile has its own in its file): `light.instance` is the instance of
    /// the borrowed mesh it is of, its triangles are `triangles[range]`.
    package struct BorrowedLight {
        var light: MeshLight
        var triangles: Stored<GPUEmissiveTriangle>
        var range: Range<Int>
    }

    /// A local fog volume (FogVolume in Shaders/Types.metal): a soft-edged box or sphere of denser fog, optionally moving.
    package struct FogVolume {
        package enum Shape {
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

        /// (As the memberwise initializer, for the modules above this one.)
        package init(shape: Shape, center: SIMD3<Float>, density: Float, albedo: SIMD3<Float> = SIMD3<Float>(repeating: 0.9), edge: Float = 0.5, noise: Float = 0.6, heightFalloff: Float = 0, motion: ((Float) -> SIMD3<Float>)? = nil) {
            self.shape = shape
            self.center = center
            self.density = density
            self.albedo = albedo
            self.edge = edge
            self.noise = noise
            self.heightFalloff = heightFalloff
            self.motion = motion
        }
    }

    /// Instance masks. Shadow and GI rays only test `geometry`, so the visible
    /// light spheres never block their own light.
    package static let maskGeometry: UInt32 = 1
    package static let maskLights: UInt32 = 2
    /// Window glass: only camera rays meet it (they pass through it and take its reflection, traceKernel); to shadow
    /// and GI rays it isn't there, so light goes through windows.
    package static let maskGlass: UInt32 = 4
    /// A far plant as its voxels (VoxelLOD): met by the rays that meet `geometry` (MASK_VOXELS).
    package static let maskVoxels: UInt32 = 8
    /// A liquid's surface (FluidSurface.swift): only liquidKernel's rays meet it, which bend the camera's through it.
    package static let maskLiquid: UInt32 = 32
    /// An effect's glowing shape (the demolition scene's fireballs): camera rays meet it, shadow and GI rays don't.
    package static let maskEffect: UInt32 = 64
    /// Not a mask: what an SDF shape's instance has besides its mask in its record's (GPUInstanceData.pad0). No ray's
    /// mask has it, so no ray tests it as one.
    package static let instanceSDF: UInt32 = 0x2000_0000

    /// Tells this scene from every other one the process makes. (Not its ObjectIdentifier: that is its address, which
    /// the next scene often gets once this one is freed, so "the same scene" would depend on the allocator.)
    package let serial: Int = {
        Scene.serials.lock(); defer { Scene.serials.unlock() }
        Scene.lastSerial += 1
        return Scene.lastSerial
    }()
    private static let serials = NSLock()
    private static var lastSerial = 0

    package var positions: [SIMD3<Float>] = []
    package var normals: [SIMD3<Float>] = []
    package var uvs: [SIMD2<Float>] = []                 // per vertex (zeros for the generated meshes)
    package var textures: [TextureSource] = []
    /// Large glTF meshes as streamed, level-of-detail cluster DAGs (VirtualTracing: VirtualBLAS, VirtualGeometry).
    package var virtualMeshes: [VirtualMesh] = []
    package var virtualMeshNames: [String] = []
    package let usesVirtualGeometry: Bool
    /// Virtual geometry is traced as this frame's cut of clusters (VirtualGeometry), not a BLAS per instance.
    package var tracesClusters: Bool { !virtualMeshes.isEmpty && VirtualGeometry.clusterMode }
    /// Generated plants as assemblies of shared parts (PlantTracing), unless baked into meshes of their own (bakedPlants).
    package var assemblies: [Assembly] = []
    package let usesAssemblies: Bool
    /// The scene has generated plants: it is built differently with assemblies and without.
    package var hasPlants = false
    /// The plants that are voxels when far (FoliageVoxels): one per assembly, in its order; or one per baked plant
    /// with boughs, its wood and leaf meshes in `meshVoxels`.
    package var voxelPlants: [FoliageVoxels.Plant] = []
    /// A baked plant's mesh -> its voxel plant (`voxelPlants`), | `meshVoxelsLeaves` for its leaves.
    package var meshVoxels: [Int: UInt32] = [:]
    package static let meshVoxelsLeaves: UInt32 = 0x8000_0000
    /// Far plants as their voxels (SceneSettings.voxelBoxes): the plants have grids.
    package let usesVoxelBoxes: Bool
    /// ...and it does: a still scene with baked plants that have them (VoxelLOD rebuilds a still scene's structure),
    /// or a moving one with assemblies (their instances name a grid's level when far: PlantTracing). (Not the open
    /// world's assemblies: a still scene's plants stay as they were built.)
    package var hasVoxelBoxes: Bool { usesVoxelBoxes && (isStill ? !meshVoxels.isEmpty : !assemblies.isEmpty) }
    package var hasSwayingMeshes = false
    /// Leaf cards' alpha layers (FoliageTextures.CardSheet), each FoliageTextures.cardSheetSize squared: the ray
    /// queries test a card's hits against its layer (rtCutout). `coverage`: the share of a card that is there.
    package var cutouts: [(alpha: [UInt8], coverage: Float)] = []
    /// Plants' leaves as cards (`settings.leafCards`, with assemblies).
    package let usesCards: Bool
    /// Something the wind moves and the shaders' FOLIAGE paths trace: plants as assemblies, or ground cover that leans.
    package var hasFoliage: Bool { assemblies.contains { !$0.rigid } || hasSwayingMeshes }
    /// Assemblies that are not plants (Scene.Assembly.rigid): the shaders walk their parts without FOLIAGE's code.
    package var hasRigidAssemblies: Bool { assemblies.contains(where: \.rigid) }
    package var leafMaterials: [LeafMaterial] = []
    package var leafState = SIMD2<Float>(-1, -1)   // the season and translucency they are set to
    /// Some material has a specular lobe (glTF materials; the generated scenes are diffuse only). Set once, by init.
    private(set) var hasSpecular = false
    package var indices: [UInt32] = []
    /// For meshes of several materials (the city's buildings): per triangle of `indices`, what to add to its
    /// instance's material index. Empty if no mesh has more than one; otherwise one entry per triangle.
    package var triangleMaterials: [UInt8] = []
    private(set) var hasMaterialOffsets = false    // some mesh has several materials (set once, by init)
    package var borrowed: [BorrowedMesh] = []
    private(set) var hasBorrowedMeshes = false     // (set once, by init: `borrowed` is let go of with the geometry)
    /// Instances that stay together from scene to scene: the plants of an open world's tile. They are not among
    /// `instances`. The renderer keeps a group's records, and the ray tracers what they build over them, for as long
    /// as some scene has a group of that name (`InstanceBlock` in SceneBuffers.swift), so `make` is only asked of a
    /// group that is new. They never move, and there are no lights among them.
    package struct InstanceGroup {
        /// What the group is made from, said in full: a group of the same name in another scene is the same
        /// instances, of meshes, assemblies and materials with the same numbers.
        let name: String
        /// How many instances `make` gives (the renderer makes room for them before it asks).
        let count: Int
        let make: () -> [Instance]
    }
    package var groups: [InstanceGroup] = []
    private(set) var hasGroups = false             // (set once, by init: `groups` are let go of with the geometry)
    package func addGroup(name: String, count: Int, make: @escaping () -> [Instance]) {
        groups.append(InstanceGroup(name: name, count: count, make: make))
    }

    /// What the builders say the scene's things are (the Project Graph's outline, Scene+Outline.swift): named objects
    /// (`object`), each the instances, lights and effects added while it was open; and the meshes', assemblies' and SDF
    /// shapes' names. Builders only append, so an object's things are ranges. Its lights are by `Light.order`.
    package struct ObjectTag {
        var path: [String]
        var instances: Range<Int>
        var lights: Range<Int>
        var effects: Range<Int>
        /// What it is made from (a model file, a building's style).
        var assets: [AssetKey]
    }
    private(set) var objectTags: [ObjectTag] = []
    private var openTags: [(name: String, assets: [AssetKey], instances: Int, lights: Int, effects: Int)] = []
    /// `shared`: the same mesh in every scene that has it (a model file's), not the scene's own. `asset`: what it is
    /// part of (a plant species' wood).
    package var meshLabels: [Int: (name: String, shared: Bool, asset: AssetKey?)] = [:]
    private(set) var assemblyLabels: [Int: String] = [:]
    package var sdfLabels: [Int: String] = [:]

    /// What `body` adds is the object `path` ("Harbor/Crane": an object in a folder), inside the one open now, if any.
    @discardableResult
    package func object<T>(_ path: String, assets: [AssetKey] = [], _ body: () throws -> T) rethrows -> T {
        beginObject(path, assets: assets)
        defer { endObject() }
        return try body()
    }

    package func beginObject(_ path: String, assets: [AssetKey] = []) {
        openTags.append((path, assets, instances.count, lights.count, effects.count))
    }

    /// A builder's next part ("Stage", "Props", "Lights"): what it adds from here, until the next `section` (or the end of
    /// the builder), is that object. It closes the section open before it, and what was opened in that.
    package func section(_ name: String, assets: [AssetKey] = []) {
        if let d = sectionDepth { while openTags.count > d { endObject() } }
        let depth = openTags.count
        beginObject(name, assets: assets)
        sectionDepth = depth
    }
    private var sectionDepth: Int?

    package func endObject() {
        guard let open = openTags.popLast() else { return }
        if let d = sectionDepth, openTags.count <= d { sectionDepth = nil }
        let parent = openTags.flatMap { $0.name.split(separator: "/").map(String.init) }
        objectTags.append(ObjectTag(path: parent + open.name.split(separator: "/").map(String.init),
                                    instances: open.instances..<instances.count, lights: open.lights..<lights.count,
                                    effects: open.effects..<effects.count, assets: open.assets))
    }

    /// What the Project Graph's edits did to the scene (Scene.applySceneOverrides).
    package var sceneOverrides = AppliedOverrides()

    /// The edits' way in (SceneOverrides.swift): an instance changed, one appended, lights taken out.
    package func editInstance(_ i: Int, _ change: (inout Instance) -> Void) { change(&instances[i]) }
    @discardableResult
    package func appendInstance(_ instance: Instance) -> Int {
        instances.append(instance)
        return instances.count - 1
    }
    package func removeLights(where shouldRemove: (Light) -> Bool) { lights.removeAll(where: shouldRemove) }

    /// Names a mesh, an assembly or an SDF shape for the outline ("oak", "lamp post"): unlike `meshNames`, only a label.
    package func label(mesh: Int, _ name: String, shared: Bool = false, asset: AssetKey? = nil) {
        if mesh >= 0 { meshLabels[mesh] = (name, shared, asset) }
    }
    package func label(assembly: Int, _ name: String) { if assembly >= 0 { assemblyLabels[assembly] = name } }
    package func label(sdf: Int, _ name: String) { if sdf >= 0 { sdfLabels[sdf] = name } }
    package var meshes: [GPUMesh] = []
    /// Shapes given by signed distance fields (SDFShapes.swift), the baked grids their nodes may be, and each shape's box.
    package var sdfShapes: [SDFShape] = []
    package var sdfVolumes: [SDFVolume] = []
    package var sdfBounds: [AABB] = []
    /// Some instance is an SDF shape's (set once, by init): the shaders are compiled with SDF_SHAPES.
    private(set) var hasSDFShapes = false
    /// What some meshes are made from, said in full (an open world's tile and chunk, a plant of a library): a mesh
    /// of the same name in another scene is the same triangles in the same order, so what was built for it holds
    /// there too (Metal's per-mesh structures: SceneBuffers).
    package var meshNames: [Int: String] = [:]
    package var materials: [GPUMaterial] = []
    /// Procedural materials' extras (GPUMaterialExtra), by material index: height, opacity, UV scale, occlusion
    /// (Scene+Procedural.swift). A scene with any compiles MATERIAL_EXTRAS in; one whose graphs give opacity, OPACITY.
    package var materialExtras: [Int: GPUMaterialExtra] = [:]
    /// The materials a Material Designer graph bakes (Scene+Procedural.swift), and a count of their extras' edits.
    package var procedural: [ProceduralMaterial] = []
    package var extrasVersion = 0
    /// Those that run as code (MatShaderCode): their programs spliced together (the pipelines compile it in), their
    /// parameters (SceneShading.procParams), and a count of the parameters' edits.
    package var proceduralCode = ""
    package var proceduralParams: [SIMD4<Float>] = []
    package var proceduralParamsVersion = 0
    /// The meshes a procedural material's height moves (Scene+Displacement.swift): their subdivided copies, and what
    /// the GPU moves their vertices from (`displaceVertices`, two a vertex: where it is and its group's first member,
    /// the way it moves and its group's size; `displaceMembers`: the groups' vertices).
    package var displaced: [DisplacedMesh] = []
    package var displaceVertices: [SIMD4<Float>] = []
    package var displaceMembers: [UInt32] = []
    /// The materials whose every instance is displaced (their height isn't the parallax's too), and what the
    /// displacement had to leave out or cap (the Material Designer's status).
    package var displacedMaterials: Set<Int> = []
    package var displacementNotes: [String] = []
    /// Procedural materials a scene keeps undisplaced (their parallax instead), so its triangles go where relief shows:
    /// the swamp's ground, its flat patches and its far trees, leaving them to its near gnarly trunks.
    package var undisplacedMaterials: Set<Int> = []
    /// Objects the Material Painter paints (Scene+Painted.swift): each its instance's texture set's slots and layout,
    /// and the UVs of their corners, three per triangle, after the meshes' own on the GPU (the painted materials' extras
    /// say where theirs start). The painter workshop's object (Scene+Painter.swift), painted whatever is assigned.
    package var painted: [PaintedObject] = []
    package var paintUVs: [SIMD2<Float>] = []
    package var paintSubject: Int? = nil
    package var instances: [Instance] = []
    package var lights: [Light] = []
    package var meshLights: [MeshLight] = []
    package var borrowedLights: [BorrowedLight] = []
    package var emissiveTriangles: [GPUEmissiveTriangle] = []
    /// The materials changed since the renderer last took this (light proxies whose brightness is animated): the
    /// smallest range that holds them all.
    package var materialsDirty: Range<Int>?
    /// What `update` has to touch every frame, found once by init (nil while it builds the scene: everything then).
    package var animated: (instances: [Int], lights: [Int], scaledLights: [Int])?
    /// Nothing in the scene moves or deforms: its instances' records and the structure over them are made once.
    private(set) var isStill = false
    /// The lights whose GPU record changes from frame to frame (moving, flickering, the mesh lights of moving
    /// instances), and each instance's rank + 1 among the virtual ones (0 = not virtual).
    package var changingLights: [Int] = []
    /// Of those, what a light tree refits (LightTree.refit): the ones that move or change shape (not the suns), and
    /// the ones only their brightness changes.
    private(set) var lightTreeChanges: (moved: [Int], scaled: [Int]) = ([], [])
    package var virtualRank: [UInt32] = []
    /// The first sun among the lights (the sky follows it), if any.
    private(set) var firstSun: Int?
    package var meshBounds: [(SIMD3<Float>, SIMD3<Float>)] = []   // local AABB per mesh
    /// Mesh `m`'s own bounds (the painter's orbit).
    package func meshBounds(_ m: Int) -> (SIMD3<Float>, SIMD3<Float>) { meshBounds.indices.contains(m) ? meshBounds[m] : (.zero, .zero) }
    /// The deforming meshes other than the crowd's: each one's mesh and its vertices (`addDeformingMesh`).
    package var deforming: [(mesh: Int, first: Int, count: Int)] = []
    /// glTF parts with emissive materials: their geometry, for mesh lights (virtual meshes keep none of it).
    package var emitterSources: [Int: (positions: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32])] = [:]
    package var defaultCamera = Camera()
    /// The plant workshop's: what its camera orbits and frames, and what its plant costs (Scene+Plants.swift).
    package var focus: AABB?
    package var plantStats: PlantStats?
    /// The building workshop's: what its building is, and its plan (the building editor's Floor Plan window).
    package var buildingStats: BuildingStats?
    package var buildingPlan: BuildingPlan?
    /// The character workshop's: what its character is (Scene+Characters.swift).
    package var characterStats: CharacterStats?
    /// What the walker (Walker.swift) meets: the interiors' walls, floors, stairs and furniture, the ground round
    /// them; and the buildings that can be walked in, where they stand.
    package var walkColliders: [Interior.Collider] = []
    package var walkAreas: [WalkArea] = []
    /// The ground under what the colliders don't cover (the open world's terrain: its height at x, z).
    package var walkGround: ((Float, Float) -> Float)?
    /// The scene's terrain, if its ground is one (Scene+Terrain.swift): its sectors' meshes and instances.
    package var terrain: SceneTerrain?
    /// The scene's water, if it has some (Scene+Water.swift): its looks, which materials are its surfaces', and where
    /// it is (the water map's field).
    package var water: SceneWater?
    /// The city's buildings: which (LotRef.key), where (the world's x, z) and how tall: the renderer makes the interior
    /// of the one the camera comes near (SceneSettings.interior).
    package var lotAreas: [(key: String, rect: CityPlan.Rect, height: Float)] = []
    /// What moves and switches in its interiors (doors, lights, lifts, the flashlight): read by their poses.
    package var interiorControls: InteriorControls?
    /// Made again at every edit (the workshop): its structures are built to be ready soon, not to trace fastest or
    /// keep least (uncompacted), and its plants keep all their leaves (no leaf fall's variants).
    package var remadeOften = false
    /// Its settings; only the effects' key changes after it is made (`adoptEffects`).
    package var settings: SceneSettings
    /// While `init` builds the scene: the load's step that the builders report models to (the loading overlay).
    package private(set) var loadStep: LoadStep?
    /// Some instance is window glass (maskGlass). Set by `addGlassMaterial`.
    package var hasGlass = false
    /// The open world: what counts as the scene for the sun's light map, the fog and the clouds' shadows is what is
    /// around the camera (to 16 m, so the map's texels stay where they are from frame to frame).
    package func follow(_ camera: SIMD3<Float>) {
        sceneSphere = SIMD4((camera / 16).rounded(.toNearestOrAwayFromZero) * 16, 1.5 * World.tileSize)
    }

    /// The scene's animated characters, if it has any (Scene+Crowd.swift).
    package var crowd: Crowd?
    /// Where the camera is (the renderer sets it before `update`): the workshop's faces look at it.
    package var viewer: SIMD3<Float>?
    /// The scene's rigid bodies, if it has any (Physics.swift): `update` steps them on the CPU unless `physicsOnGPU`.
    package var physics: PhysicsWorld?
    /// The destruction scene's shots (Scene+Destruction.swift), if it is that scene.
    package var destructionRig: DestructionRig?
    /// The demolition scene's tools (Scene+Demolition.swift), if it is that scene.
    package var demolitionRig: DemolitionRig?
    /// The cars (Scene+Cars.swift), if it has any.
    package var carRig = CarRig()
    /// Its gameplay (SceneDefinition.behaviour: the destruction's tools, the demolition's player), made once it is built.
    package var behaviour: SceneBehaviour?
    /// What its scene file placed (Scene.place), for the editor to move; nil when it had none.
    package var placed: PlacedFile?
    /// Procedural assets cooked for this scene, and their meshes (with their first material), by their cache name:
    /// copies with the same values share them (Scene+ProcAsset).
    var proceduralCooks: [String: ProcAsset.Cooked] = [:]
    var proceduralMeshes: [String: (mesh: Int, material: Int)] = [:]
    /// The kit's meshes (Scene.kitMesh) and the materials a scene file's objects name (Scene.nameMaterial).
    package var kitMeshes: [Int: Int] = [:]
    package var namedMaterials: [String: Int] = [:]
    /// Per material, what the solid look should know of it (Scene.cutFace): a fractured object's broken inside.
    private(set) var materialFlags: [UInt8] = []
    package static let cutFace: UInt8 = 1

    /// Material `m` is a fractured object's broken inside (the solid look draws it darker and warmer).
    package func markCutFace(_ m: Int) {
        if materialFlags.count <= m { materialFlags.append(contentsOf: repeatElement(0, count: m + 1 - materialFlags.count)) }
        materialFlags[m] |= Scene.cutFace
    }
    package var physicsOnGPU = false
    /// The GPU's: the steps `update` asked for since the renderer last took them, and whether from the start.
    package var physicsPending = (steps: 0, restart: false)
    /// The scene's particle effects, if it has any (Particles.swift): always on the GPU (ParticlesGPU), which the rays
    /// meet through a structure of their own (Shaders/ParticleTrace.metal).
    package var particles: ParticleSystem?
    /// The effects placed in it (Scene+Effects.swift: addEffect), and the colliders of its own their Collide blocks
    /// name; what of them couldn't be done (VFXLowering's notes).
    package var effects: [VFXInstance] = []
    package var effectColliders: [(name: String, collider: ParticleCollider)] = []
    package var effectNotes: [String] = []
    /// Per emitter of `particles`, the effect it is one of (the editor's status).
    package var effectOwners: [String] = []
    /// Reflection rays see them (ParticleSettings.reflections).
    package var particlesReflected: Bool { particles != nil && settings.particles.reflections }
    /// The steps `update` asked for since the renderer last took them, and whether from the start.
    package var particlesPending = (steps: 0, restart: true)
    package var hasParticles: Bool { particles != nil }
    /// The interiors' loose furniture (Scene+Interiors.swift): its clock starts at the scene's first update, not at the
    /// renderer's zero (a scene made ten minutes in doesn't step ten minutes first), and a slow frame skips time rather
    /// than catching up.
    package var physicsFromInstall = false
    package var physicsOrigin: Float?
    /// The CPU's steps on a thread of their own, behind the frame (PhysicsStepper): the renderer turns it on
    /// (PhysicsSettings.asynchronous, for a scene that simulates on the CPU, not a benchmark's unless asked).
    package var physicsAsync = false
    package var physicsStepper: PhysicsStepper?
    /// The time the CPU's steps were last asked for (a frame at the same time: paused, a still, waits for them).
    package var physicsTime: Float?
    /// With cars: what this frame draws, between the stepper's last two steps (`Scene.drawnBetween`), and how far
    /// behind the frame the latest steps are on average (s).
    package var drawnFrame: PhysicsStepper.Drawn?
    package var physicsLag: Float = 0
    /// The time that frame drew the steps at, and the frame's own time.
    package var physicsShown: (shown: Float, at: Float)?
    /// The open world's scene: which part of the world it holds, and where (Scene+World.swift).
    package var worldPlace: WorldPlace?
    /// ...and where its sun and moon are now (`update`).
    package var heavens: Heavens?
    /// Its materials that are lights at night, each with what it emits when it is on, and which it is: a street lamp
    /// (`window` nil), or a window that comes on at its own time in the dusk (`World.lightOn`).
    package struct CityLight {
        var material: Int
        var emission: SIMD3<Float>
        var window: Float?
        /// How far on it is, 0...1, and the light table's triangles that have its material (where the scene samples
        /// its lights).
        var on: Float = 0
        var triangles: [Range<Int>] = []
    }
    /// (Added with their materials, which emit nothing until `setCityLights` says so.)
    package var cityLights: [CityLight] = []
    package var cityLightsElevation: Float?
    /// What each of the light table's triangles emits when its light is on.
    package var cityLightRadiance: [Float] = []
    package var lightTrianglesDirty: Range<Int>?

    package var skyColor = SIMD3<Float>(0.35, 0.45, 0.65) * 0.8
    package var skyAnimation: ((Float) -> SIMD3<Float>)?
    /// Local fog volumes (used while the fog and its volumes are on), at most GPUFogParams.maxVolumes.
    package var fogVolumes: [FogVolume] = []
    /// Bounding sphere of the static scene (the sun's orthographic light map covers it).
    private(set) var sceneSphere = SIMD4<Float>(0, 0, 0, 1)
    /// The walkable interiors' box, world space (BuildingKit.addInterior): where GI's hits see the sun through rays and the
    /// fog's sky light is occluded (Renderer.interiorBox). Nil: no interiors.
    package var interiorBox: (lo: SIMD3<Float>, hi: SIMD3<Float>)?
    /// Every light and emissive triangle by power, for ReSTIR DI's candidates (built once, after the lights).
    package var lightTable = LightTable()

    /// `virtualGeometry`: big glTF meshes become virtual meshes (built once, then read from their cache files) instead
    /// of ordinary full-detail meshes.
    /// `building`: what is in the scene, instead of what `settings.kind` builds (tests).
    /// `voxelBoxes`: far baked plants are traced as their voxels (VoxelLOD).
    /// `load`: the load to report the build to; a gallery stops loading models when it is cancelled.
    deinit { physicsStepper?.stop() }

    package init(_ settings: SceneSettings = SceneSettings(), virtualGeometry: Bool = false, assemblies: Bool = false, voxelBoxes: Bool = false,
         load: LoadJob? = nil, building: ((Scene) -> Void)? = nil) {
        self.settings = settings
        loadStep = load?.step("Scene", detail: settings.kind.title)
        self.usesVirtualGeometry = virtualGeometry
        self.usesAssemblies = assemblies && !settings.bakedPlants
        self.usesCards = assemblies && settings.leafCards
        self.usesVoxelBoxes = voxelBoxes
        if let building { building(self) } else if let check = settings.lightCheck { buildLightCheck(check) } else {
        settings.kind.definition.build(self)
        // What was placed by hand (Assets/Scenes/<scene>.scene), on what the builder made.
        if let file = SceneFile(settings.kind) { place(file) }
        behaviour = settings.kind.definition.behaviour?(self)
        while !openTags.isEmpty { endObject() }   // (the builder's last section, and anything it left open)
        applyMaterialAssignments()
        buildProceduralPrograms()
        finishTerrainLayers()
        finishTerrainScatter()
        addTerrainColliders()
        displaceProcedural()
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
        finishLiquids()
        physics?.finish()
        applyPaintAssignments()
        applySceneOverrides()
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
        // (A displaced mesh's structure is built again when a bake moves its vertices: the top level's then too.)
            && displaced.isEmpty
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

    // MARK: - Animation: state

    package var instanceEdits = Set<Int>()
    /// Something moved in the last `update` (the renderer refits the top level only then: a door that stands still,
    /// a lift that waits, don't cost a refit every frame).
    package var motionThisFrame = true

    // MARK: - GPU data: state

    private(set) var usesLightTable = false
    /// Set by a scene's builder: the light table whatever the count. (The city at night: a building's lit windows are
    /// one mesh light wrapped around it, which the per-light loops of a scene with few lights sample badly.)
    package var forcesLightTable = false

    // MARK: - Scene construction: state

    /// Where each shadow-denoiser group's lights end in `lights` (sorted by group): group g = [end[g-1], end[g]).
    package var lightGroupEnd = SIMD4<UInt32>(repeating: 0)
    package var geometryReleased = false

    // MARK: - Crowd: state

    package var hasSkinned = false
    /// The meshes that are strands (hair), drawn as round Catmull-Rom curves (HAIR_CURVES): to everything that reads
    /// triangles they are meshes with none.
    package var curveMeshes: [Int: CurveMesh] = [:]
    package var curveRadii: [Float] = []
    /// The hair's groups of drawn strands and their curve meshes (Scene+Hair.swift): once the meshes are done, each
    /// group is told where its mesh's control points are (`finishHair`).
    package var hairMeshes: [(group: Int, mesh: Int)] = []

    // MARK: - Physics: state

    /// The cloths' meshes, in the physics' order.
    package var clothMeshes: [Int] = []
    /// The soft bodies' meshes, in the physics' order.
    package var softMeshes: [Int] = []
    /// The liquids' surfaces: each system's mesh (its system, its mesh), and the meshes whose structures are built
    /// again every frame (their triangles change).
    package var liquidMeshes: [(system: Int, mesh: Int, first: Int)] = []
    package var rebuiltMeshes: Set<Int> = []
    /// Deforming meshes whose structures are refitted but sometimes built again (a car's panels once it has come
    /// apart: PhysicsGPU.nextRebuild): the refit keeps a scratch buffer as big as their builds need.
    package var rebuiltOnDemand: Set<Int> = []
    /// Some instance is a liquid's surface (maskLiquid). Set by `addLiquidMaterial`.
    package var hasLiquid = false
    /// It has water (Scene+Water.swift). Set by `addWaterLook`.
    package var hasWater = false
    /// Some material is skin (GPUMaterial.params.w < 0): the shaders are compiled with SKIN.
    package var hasSkin = false
    /// Some leaves are a scanned leaf sheet's (the realistic look): LEAF_TRANSMIT lights them from both sides.
    package var hasLeafSheets = false
    /// The scans' textures this scene has (albedo, normal, occlusion-roughness-height), by set and roughness floor:
    /// each once, whatever number of materials wear it (TextureSets.swift).
    package var scanTextures: [String: SIMD3<UInt32>] = [:]
    /// Where the realistic look's near ground is (realism high: Scene.refineTerrain): scene x, z; nil: the scene's
    /// demo camera's place, else the origin.
    package var terrainDetailCenter: SIMD2<Float>?
    package var lightSphereMesh = -1, lightQuadMesh = -1          // the proxies' shared shapes
    package var lightCapsuleMeshes: [SIMD2<Float>: Int] = [:]     // by (length, radius)
}
