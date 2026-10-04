import Foundation
import ImageIO
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
        var virtualMesh = -1                  // >= 0: index into `virtualMeshes` (then `mesh` is -1)
        var assembly = -1                     // >= 0: index into `assemblies` (then `mesh` is -1 and `material` is its
                                              // wood's, with its leaves' right after it)
        /// `transform.inverse.transpose`, kept up to date with the transform (the GPU's normal matrix; the custom ray
        /// tracer reads its rows as the world -> object matrix).
        var normalMatrix = matrix_identity_float4x4
        /// A light's proxy whose light moves (`LightMotion.animated`): `Scene.update` re-poses it every frame.
        var poseAnimated = false

        /// Never moves: its transform is the one it was added with (the ray tracers' static trees).
        var isStatic: Bool { animation == nil && !poseAnimated }
    }

    /// A plant as parts (Foliage.Plant): meshes placed in the plant's own space, many of them the same few meshes
    /// (the species' boughs). Every instance of the plant shares it; the custom ray tracer walks a tree over the parts.
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
    }

    /// A leaf material that changes with the season (`setSeason`): its summer and autumn colours, and when in the
    /// year (0...1) it turns.
    struct SeasonalMaterial {
        var material: Int
        var summer: SIMD3<Float>
        var autumn: SIMD3<Float>
        var turn: Float
    }

    /// An encoded image a material samples (decoded and uploaded by the renderer).
    struct TextureSource {
        var data: Data
        var srgb: Bool                        // colour data (base colour, emissive) vs linear (normal, metallic-roughness)
        var name: String
        var modelPath: String                 // the glTF file (texture streaming caches per file)
        var cacheKey: String                  // unique within the file: image index + colour space
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

    private(set) var positions: [SIMD3<Float>] = []
    private(set) var normals: [SIMD3<Float>] = []
    private(set) var uvs: [SIMD2<Float>] = []                 // per vertex (zeros for the generated meshes)
    private(set) var textures: [TextureSource] = []
    /// Large glTF meshes as streamed, level-of-detail cluster DAGs (custom ray tracer only; see VirtualGeometry).
    private(set) var virtualMeshes: [VirtualMesh] = []
    private(set) var virtualMeshNames: [String] = []
    let usesVirtualGeometry: Bool
    /// Generated plants as assemblies of shared parts (custom ray tracer only); otherwise each is baked into meshes of its own.
    private(set) var assemblies: [Assembly] = []
    let usesAssemblies: Bool
    /// `METALRENDERER_ASSEMBLIES=0`: plants baked flat on the custom tracer too (to compare the two).
    static let assembliesEnabled = ProcessInfo.processInfo.environment["METALRENDERER_ASSEMBLIES"] != "0"
    /// The scene has generated plants: it is built differently for a tracer that walks assemblies and one that doesn't.
    private(set) var hasPlants = false
    private var seasonal: [SeasonalMaterial] = []
    private var season: Float = -1
    /// Some material has a specular lobe (glTF materials; the generated scenes are diffuse only). Set once, by init.
    private(set) var hasSpecular = false
    private(set) var indices: [UInt32] = []
    private(set) var meshes: [GPUMesh] = []
    private(set) var materials: [GPUMaterial] = []
    private(set) var instances: [Instance] = []
    private(set) var lights: [Light] = []
    private(set) var meshLights: [MeshLight] = []
    private(set) var emissiveTriangles: [GPUEmissiveTriangle] = []
    /// The materials changed since the renderer last took this (light proxies whose brightness is animated): the
    /// smallest range that holds them all.
    private var materialsDirty: Range<Int>?
    /// What `update` has to touch every frame, found once by init (nil while it builds the scene: everything then).
    private var animated: (instances: [Int], lights: [Int], scaledLights: [Int])?
    /// The instances that move (everything else keeps the records of its first frame).
    var animatedInstances: [Int] { animated?.instances ?? Array(instances.indices) }
    /// The lights whose GPU record changes from frame to frame (moving, flickering, the mesh lights of moving
    /// instances), and each instance's rank + 1 among the virtual ones (0 = not virtual).
    private var changingLights: [Int] = []
    private var virtualRank: [UInt32] = []
    /// The first sun among the lights (the sky follows it), if any.
    private(set) var firstSun: Int?
    private var meshBounds: [(SIMD3<Float>, SIMD3<Float>)] = []   // local AABB per mesh
    /// glTF parts with emissive materials: their geometry, for mesh lights (virtual meshes keep none of it).
    private var emitterSources: [Int: (positions: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32])] = [:]
    var defaultCamera = Camera()
    let settings: SceneSettings

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
    init(_ settings: SceneSettings = SceneSettings(), virtualGeometry: Bool = false, assemblies: Bool = false) {
        self.settings = settings
        self.usesVirtualGeometry = virtualGeometry
        self.usesAssemblies = assemblies && Scene.assembliesEnabled
        if let check = settings.lightCheck { buildLightCheck(check) } else {
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
        }
        }
        for extra in settings.extraModels { addExtraModel(extra) }
        assignLightGroups()
        if settings.emissiveLights { buildMeshLights() }
        let (lo, hi) = bounds()
        if lo.x <= hi.x { sceneSphere = SIMD4((lo + hi) / 2, max(length(hi - lo) / 2, 1)) }
        lightTable = LightTable(scene: self)
        update(time: 0)
        for i in instances.indices { instances[i].prevTransform = instances[i].transform }

        // Nothing is added from here on: what the frame loop asks for every frame is fixed.
        hasSpecular = materials.contains { $0.params.x > 0 }
        switch ProcessInfo.processInfo.environment["METALRENDERER_LIGHT_TABLE"] {
        case "1": usesLightTable = true
        case "0": usesLightTable = false
        default: usesLightTable = lights.count > Scene.lightTableThreshold
        }
        firstSun = lights.firstIndex { $0.kind.isSun }
        var rank: UInt32 = 0
        virtualRank = instances.map { inst in
            guard inst.virtualMesh >= 0 else { return 0 }
            rank += 1
            return rank
        }
        func moves(_ l: Light) -> Bool { l.kind.isSun || l.motion == .animated }
        animated = (instances: instances.indices.filter { !instances[$0].isStatic },
                    lights: lights.indices.filter { !lights[$0].isMesh && moves(lights[$0]) },
                    scaledLights: lights.indices.filter { !lights[$0].isMesh && !moves(lights[$0]) && lights[$0].motion == .scaleOnly })
        changingLights = lights.indices.filter {
            if case .mesh(let m) = lights[$0].kind { return !instances[meshLights[m].instance].isStatic }
            return moves(lights[$0]) || lights[$0].motion == .scaleOnly
        }
        materialsDirty = nil
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
        for i in fogVolumes.indices { if let motion = fogVolumes[i].motion { fogVolumes[i].center = motion(t) } }
    }

    private func setTransform(_ i: Int, _ transform: float4x4) {
        instances[i].transform = transform
        instances[i].normalMatrix = transform.inverse.transpose
    }

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

    /// Axis-aligned bounds of all geometry at the current animation time (the scene sphere),
    /// from each instance's transformed mesh bounds.
    func bounds() -> (SIMD3<Float>, SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for inst in instances where inst.mask == Scene.maskGeometry {
            let (a, b) = inst.virtualMesh >= 0 ? (virtualMeshes[inst.virtualMesh].bounds.lo, virtualMeshes[inst.virtualMesh].bounds.hi)
                : inst.assembly >= 0 ? (assemblies[inst.assembly].bounds.lo, assemblies[inst.assembly].bounds.hi) : meshBounds[inst.mesh]
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

    /// Virtual instances: meshIndex points past the ordinary meshes (the ray tracer's mesh table lists the virtual
    /// meshes' bounds there) and pad1 = 1 + the instance's rank among the virtual ones (its BLAS / cluster records).
    /// Assembly instances: meshIndex points past those too (the table then lists the assemblies).
    /// Into the renderer's records, kept from frame to frame. `all`: every instance (a scene's first frame); otherwise
    /// only the ones that move, the rest being unchanged.
    func writeInstanceData(into out: UnsafeMutablePointer<GPUInstanceData>, all: Bool) {
        func write(_ i: Int) {
            let inst = instances[i]
            out[i] = GPUInstanceData(transform: inst.transform,
                                     prevTransform: inst.prevTransform,
                                     normalMatrix: inst.normalMatrix,
                                     meshIndex: inst.mesh >= 0 ? UInt32(inst.mesh)
                                         : inst.assembly >= 0 ? UInt32(meshes.count + virtualMeshes.count + inst.assembly)
                                         : UInt32(meshes.count + inst.virtualMesh),
                                     materialIndex: UInt32(inst.material),
                                     pad0: inst.mask,
                                     pad1: virtualRank[i])
        }
        if !all, let animated {
            for i in animated.instances { write(i) }
        } else {
            for i in instances.indices { write(i) }
        }
    }

    /// More lights than this (analytic + emissive meshes): nothing may loop over the lights or keep something per light
    /// (LIGHT_TABLE in Shaders/Types.metal): no light maps, GI and the path tracer sample the light table.
    /// `METALRENDERER_LIGHT_TABLE=1` / `=0` forces it on / off. Set once, by init.
    static let lightTableThreshold = 256
    private(set) var usesLightTable = false

    /// One bit per light type present (GPULight.sphere ...): the shaders are specialised for it. Bit 31: usesLightTable.
    var lightTypeMask: UInt32 {
        // Bit 30: FOLIAGE, the scene has assemblies (Shaders/Types.metal).
        lights.reduce((usesLightTable ? 0x8000_0001 : UInt32(1)) | (assemblies.isEmpty ? 0 : 0x4000_0000)) { mask, l in   // spheres always: an empty scene needs some type
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
                            axis: SIMD4(n, 0),
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
            // Thousands of lights: smaller bulbs (same draws, so up to 256 lights the scene is unchanged).
            let r = lightCount > 256 ? radius * pow(256 / Float(lightCount), 1.0 / 3) : radius
            addLight(color: color * (totalPower / Float(lightCount)), radius: r, sphereMesh: lightSphere) { t in
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

    func addMesh(_ mesh: MeshGeometry, uvs meshUVs: [SIMD2<Float>]? = nil) -> Int {
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

    /// A generated mesh (Foliage, Terrain): its arrays appended whole, its bounds as it counted them.
    func addMesh(_ mesh: Foliage.Mesh) -> Int {
        let baseVertex = UInt32(positions.count)
        let firstIndex = UInt32(indices.count)
        positions += mesh.positions
        normals += mesh.normals
        uvs += mesh.uvs
        indices.reserveCapacity(indices.count + mesh.indices.count)
        for i in mesh.indices { indices.append(i + baseVertex) }
        meshes.append(GPUMesh(firstIndex: firstIndex, indexCount: UInt32(mesh.indices.count)))
        meshBounds.append((mesh.bounds.lo, mesh.bounds.hi))
        return meshes.count - 1
    }

    func addAssembly(_ assembly: Assembly) -> Int {
        assemblies.append(assembly)
        return assemblies.count - 1
    }

    /// An instance of an assembly: `material` is its wood's, and the next material its leaves'.
    @discardableResult
    func addInstance(assembly: Int, _ material: Int, _ transform: float4x4) -> Int {
        instances.append(Instance(mesh: -1, material: material, mask: Scene.maskGeometry, transform: transform, prevTransform: transform,
                                  animation: nil, assembly: assembly, normalMatrix: transform.inverse.transpose))
        return instances.count - 1
    }

    /// Generated plants were placed (Flora): see `hasPlants`.
    func notePlants() { hasPlants = true }

    /// A metallic-roughness material with a specular lobe (the gallery's floor and plinths).
    func addPBRMaterial(baseColor: SIMD3<Float>, metallic: Float, roughness: Float) -> Int {
        materials.append(GPUMaterial(albedo: SIMD4<Float>(baseColor, metallic), emission: SIMD4<Float>(.zero, roughness),
                                     params: SIMD4(1, 1, 0, 0)))
        return materials.count - 1
    }

    /// A diffuse material (metallic 0, roughness 1, no specular: how every generated object has always looked).
    /// `translucency`: a leaf's, the share of its light that comes through from the far side.
    func addMaterial(albedo: SIMD3<Float>, emission: SIMD3<Float> = .zero, translucency: Float = 0) -> Int {
        materials.append(GPUMaterial(albedo: SIMD4<Float>(albedo, 0), emission: SIMD4<Float>(emission, 1), params: SIMD4(0, 1, 0, translucency)))
        return materials.count - 1
    }

    func addSeasonal(_ material: SeasonalMaterial) { seasonal.append(material) }

    /// The share of the deciduous plants' leaves that have fallen at `season` (the custom ray tracer drops them).
    static func leafFall(season: Float) -> Float {
        let t = min(max((season - 0.62) / 0.33, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The leaves' colours at `season`: 0 = spring (fresh, light), 0.3 = summer, from 0.5 they turn, each material in
    /// its own time, and by winter (1) what is left is brown. Only the materials change (the renderer uploads the range).
    func setSeason(_ s: Float) {
        guard s != season, !seasonal.isEmpty else { return }
        season = s
        func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }
        var lo = Int.max, hi = 0
        for m in seasonal {
            let spring = 1 - smooth(0, 0.25, s)
            var color = m.summer * (1 + SIMD3<Float>(0.25, 0.3, 0.1) * spring)
            color += (m.autumn - color) * smooth(m.turn - 0.1, m.turn + 0.1, s)
            color += (SIMD3<Float>(0.2, 0.13, 0.07) - color) * smooth(0.82, 1, s) * 0.8
            materials[m.material].albedo = SIMD4(color, materials[m.material].albedo.w)
            lo = min(lo, m.material); hi = max(hi, m.material + 1)
        }
        materialsDirty = materialsDirty.map { min($0.lowerBound, lo)..<max($0.upperBound, hi) } ?? lo..<hi
    }

    @discardableResult
    func addInstance(_ mesh: Int, _ material: Int, _ transform: float4x4,
                             mask: UInt32 = Scene.maskGeometry,
                             animation: ((Float) -> float4x4)? = nil) -> Int {
        instances.append(Instance(mesh: mesh, material: material, mask: mask,
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

    /// Every geometry instance with an emissive material becomes a mesh light (after the analytic lights, which
    /// assignLightGroups has sorted): its triangles, each weighted by area x emitted luminance (an emissive texture's
    /// luminance from a small decoded copy), and the bounding sphere / mean normal proxy the shaders weigh it by.
    private func buildMeshLights() {
        var textureCache: [Int: ((SIMD2<Float>) -> SIMD3<Float>)?] = [:]
        func emissiveTexture(_ index: UInt32) -> ((SIMD2<Float>) -> SIMD3<Float>)? {
            guard index != .max else { return nil }
            if let cached = textureCache[Int(index)] { return cached }
            let sampler = Scene.thumbnailSampler(textures[Int(index)].data)
            textureCache[Int(index)] = sampler
            return sampler
        }
        let lumWeights = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        var flagged = Set<Int>()
        for (i, inst) in instances.enumerated() where inst.mask == Scene.maskGeometry {
            let material = materials[inst.material]
            let factor = SIMD3(material.emission.x, material.emission.y, material.emission.z)
            guard factor.max() > 0 else { continue }
            let positions: [SIMD3<Float>], uvsOf: [SIMD2<Float>], tris: ArraySlice<UInt32>
            if let src = emitterSources[i] {
                (positions, uvsOf, tris) = (src.positions, src.uvs, src.indices[...])
            } else if inst.mesh >= 0 {
                let m = meshes[inst.mesh]
                (positions, uvsOf, tris) = (self.positions, uvs, indices[Int(m.firstIndex) ..< Int(m.firstIndex + m.indexCount)])
            } else {
                continue
            }
            let texture = emissiveTexture(material.textures.w)
            var light = MeshLight(instance: i, firstTriangle: emissiveTriangles.count, triangleCount: 0,
                                  center: .zero, radius: 0, normal: .zero, flatness: 0, power: .zero)
            var weights: [Float] = []
            var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
            var areaNormal = SIMD3<Float>(repeating: 0), area: Float = 0
            let t = Array(tris)
            for f in stride(from: 0, to: t.count - 2, by: 3) {
                let (a, b, c) = (Int(t[f]), Int(t[f + 1]), Int(t[f + 2]))
                let p0 = positions[a], e1 = positions[b] - p0, e2 = positions[c] - p0
                let cr = cross(e1, e2)
                let triArea = length(cr) / 2
                guard triArea > 0 else { continue }
                let uv0 = a < uvsOf.count ? uvsOf[a] : .zero, uv1 = b < uvsOf.count ? uvsOf[b] : .zero
                let uv2 = c < uvsOf.count ? uvsOf[c] : .zero
                var le = factor
                if let texture {
                    le *= (texture((uv0 + uv1 + uv2) / 3) * 2 + texture(uv0) + texture(uv1) + texture(uv2)) / 5
                }
                let w = triArea * dot(le, lumWeights)
                guard w > 0 else { continue }
                weights.append(w)
                emissiveTriangles.append(GPUEmissiveTriangle(v0: SIMD4(p0, 0), e1: SIMD4(e1, uv0.x), e2: SIMD4(e2, uv0.y),
                                                             uv12: SIMD4(uv1.x, uv1.y, uv2.x, uv2.y)))
                for p in [p0, positions[b], positions[c]] { lo = simd_min(lo, p); hi = simd_max(hi, p) }
                areaNormal += cr / 2
                area += triArea
                light.power += le * triArea
            }
            guard !weights.isEmpty else { continue }
            let total = weights.reduce(0, +)
            var running: Float = 0
            for (k, w) in weights.enumerated() {
                running += w
                emissiveTriangles[light.firstTriangle + k].v0.w = k == weights.count - 1 ? 1 : running / total
            }
            light.triangleCount = weights.count
            light.center = (lo + hi) / 2
            light.radius = max(length(hi - lo) / 2, 1e-3)
            light.flatness = min(length(areaNormal) / area, 1)
            light.normal = length(areaNormal) > 0 ? normalize(areaNormal) : .zero
            meshLights.append(light)
            lights.append(Light(kind: .mesh(meshLights.count - 1), color: light.power, pose: { _ in LightPose(position: .zero) }))
            flagged.insert(inst.material)
        }
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
    private static func placement(_ model: GLTFModel, size: Float) -> float4x4 {
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
            let built = VirtualGeometryBuilder.meshes(for: url, model: model, indices: virtualIndices)
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
