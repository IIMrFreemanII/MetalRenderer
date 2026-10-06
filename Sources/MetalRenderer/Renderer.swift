import AppKit
import MetalKit
import QuartzCore
import simd

enum RendererError: Error, CustomStringConvertible {
    case missingFunction(String)
    case resourceCreation(String)

    var description: String {
        switch self {
        case .missingFunction(let name): return "Shader function '\(name)' not found in the shaders"
        case .resourceCreation(let what): return "Failed to create \(what)"
        }
    }
}

/// All screen-sized textures. Recreated when the render resolution changes.
final class RenderTargets {
    let width: Int
    let height: Int
    let normalDepth: [MTLTexture]   // [2], ping-ponged: current + previous frame. xyz = normal, w = view depth (half: ~0.1% depth error)
    let albedo: MTLTexture
    let emission: MTLTexture
    let motion: MTLTexture          // xy = pixel position in previous frame, z = expected previous depth, w = valid
    let direct: MTLTexture          // raw 1-spp direct lighting (albedo removed)
    let indirect: MTLTexture        // raw 1-spp indirect lighting (albedo removed), or a GI technique's result
    let surfacePos: MTLTexture      // xyz = world position, w = instance id + 1 (0 = sky or emitter: no GI)
    let geoNormal: MTLTexture       // geometric normal, oriented toward the camera
    let giDebug: MTLTexture         // debug visualisation written by cascade GI (view mode "GI debug")
    let geometryDebug: MTLTexture   // geometry debug views (view modes 8-13), written by geometryDebugKernel
    let visibility: MTLTexture      // per light group (rgba = groups 0...3): visibility of this frame's shadow ray(s)
    let blocker: MTLTexture         // per light group: penumbra half width of the occluded samples, 0 = visible
    let material: MTLTexture        // specular materials: rgb = F0, a = roughness
    let specular: MTLTexture        // raw 1-spp specular light (reflections), divided by the specular albedo
    let meshDirect: MTLTexture      // raw 1-spp direct light from emissive-mesh lights (albedo removed)
    let shadow: ShadowTargets       // shadow denoiser state
    /// Denoiser state for [0] direct + indirect light combined (or direct alone), [1] indirect light alone,
    /// [2] specular light and [3] mesh-light direct light (with the shadow denoiser).
    let denoise: [DenoiseTargets]
    // MetalFX inputs (written only while upscaling is on)
    static let upscaleColorFormat = MTLPixelFormat.rgba16Float
    static let upscaleDepthFormat = MTLPixelFormat.r32Float
    static let upscaleMotionFormat = MTLPixelFormat.rg16Float
    static let gBufferFormat = MTLPixelFormat.rgba16Float      // albedo, normalDepth, specularAlbedo
    static let roughnessFormat = MTLPixelFormat.r16Float
    let upscaleColor: MTLTexture    // tonemapped linear color at render resolution
    let deviceDepth: MTLTexture     // reversed-Z depth (near / viewDepth)
    let pixelMotion: MTLTexture     // previous pixel position - this pixel position, unjittered
    // More guides for MetalFX's denoising scaler (written by the composite while it is the upscaler)
    let specularAlbedo: MTLTexture  // what the surface reflects toward the camera, 0 where nothing is specular
    let roughness: MTLTexture

    init(device: MTLDevice, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        func make(_ format: MTLPixelFormat, _ label: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        normalDepth = [try make(.rgba16Float, "normalDepth0"), try make(.rgba16Float, "normalDepth1")]
        albedo = try make(.rgba16Float, "albedo")
        emission = try make(.rgba16Float, "emission")
        motion = try make(.rgba32Float, "motion")
        direct = try make(.rgba16Float, "direct")
        indirect = try make(.rgba16Float, "indirect")
        surfacePos = try make(.rgba32Float, "surfacePos")
        geoNormal = try make(.rgba16Float, "geoNormal")
        giDebug = try make(.rgba16Float, "giDebug")
        geometryDebug = try make(.rgba8Unorm, "geometryDebug")
        visibility = try make(.rgba8Unorm, "visibility")
        blocker = try make(.rgba16Float, "blocker")
        material = try make(.rgba16Float, "material")
        specular = try make(.rgba16Float, "specular")
        meshDirect = try make(.rgba16Float, "meshDirect")
        shadow = try ShadowTargets(device: device, width: width, height: height, make)
        denoise = [try DenoiseTargets(make, "direct"), try DenoiseTargets(make, "indirect"), try DenoiseTargets(make, "specular"),
                   try DenoiseTargets(make, "meshDirect")]
        upscaleColor = try make(RenderTargets.upscaleColorFormat, "upscaleColor")
        deviceDepth = try make(RenderTargets.upscaleDepthFormat, "deviceDepth")
        pixelMotion = try make(RenderTargets.upscaleMotionFormat, "pixelMotion")
        specularAlbedo = try make(RenderTargets.gBufferFormat, "specularAlbedo")
        roughness = try make(RenderTargets.roughnessFormat, "roughness")
    }
}

/// Textures the denoiser keeps for one lighting signal.
final class DenoiseTargets {
    let history: MTLTexture     // denoised illumination fed back into next frame's temporal pass
    // history, pingA and pingB hold rgb = illumination, a = luminance standard deviation.
    let pingA: MTLTexture
    let pingB: MTLTexture
    let moments: [MTLTexture]   // [2], ping-ponged. x = fast mean luminance, y = fast mean luminance^2, z = history length, w = slow mean luminance (anti-lag)

    init(_ make: (MTLPixelFormat, String) throws -> MTLTexture, _ name: String) throws {
        // Half precision halves the a-trous filter's memory traffic. Alpha stores the standard deviation,
        // not the variance: variance (~luminance^2) overflows half (65504) near the lights.
        history = try make(.rgba16Float, "\(name) history")
        pingA = try make(.rgba16Float, "\(name) pingA")
        pingB = try make(.rgba16Float, "\(name) pingB")
        moments = [try make(.rgba32Float, "\(name) moments0"), try make(.rgba32Float, "\(name) moments1")]
    }

    /// The a-trous filter's ping-pong: pass `i` reads `src` and writes `dst`. Pass 0 writes into `history`, which
    /// feeds the next frame's temporal pass.
    func atrousPass(_ i: Int) -> (src: MTLTexture, dst: MTLTexture) {
        switch i {
        case 0: return (pingA, history)
        case 1: return (history, pingB)
        default: return i % 2 == 0 ? (pingB, pingA) : (pingA, pingB)
        }
    }
}

/// Textures the shadow denoiser keeps (visibility per light in rgba).
final class ShadowTargets {
    let history: MTLTexture     // filtered visibility fed back into next frame's temporal pass
    let pingA: MTLTexture
    let pingB: MTLTexture
    let meta: [MTLTexture]      // [2], ping-ponged. z = history length
    let penumbra: MTLTexture    // per light: penumbra half-width in pixels
    let tiles: MTLTexture       // per 8x8 tile: 1 = fully lit / shadowed everywhere, nothing to filter
    // More than 4 lights with light reuse: per group, last frame's light pick (manyLightsKernel), ping-ponged.
    let reservoir: [MTLTexture]         // [2] rgba32Uint: light index | confidence M << 16
    let reservoirWeight: [MTLTexture]   // [2] rgba32Float: the pick's contribution weight W

    init(device: MTLDevice, width: Int, height: Int, _ make: (MTLPixelFormat, String) throws -> MTLTexture) throws {
        history = try make(.rgba16Float, "shadow history")
        pingA = try make(.rgba16Float, "shadow pingA")
        pingB = try make(.rgba16Float, "shadow pingB")
        meta = [try make(.rgba16Float, "shadow meta0"), try make(.rgba16Float, "shadow meta1")]
        penumbra = try make(.rgba16Float, "shadow penumbra")
        reservoir = [try make(.rgba32Uint, "light reservoir0"), try make(.rgba32Uint, "light reservoir1")]
        reservoirWeight = [try make(.rgba32Float, "light reservoir weight0"), try make(.rgba32Float, "light reservoir weight1")]
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: (width + 7) / 8,
                                                         height: (height + 7) / 8, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let tiles = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture shadow tiles") }
        tiles.label = "shadow tiles"
        self.tiles = tiles
    }
}

/// The volumetric fog's froxel grid: 8x8 traced pixels per froxel, `slices` exponential depth slices.
final class FogTargets {
    let renderWidth: Int, renderHeight: Int
    let columns: Int, rows: Int, slices: Int
    let scatter: [MTLTexture]     // [2], ping-ponged: rgb = in-scattered light per metre, a = extinction (fogInjectKernel)
    let integrated: MTLTexture    // rgb = in-scatter from the camera to each slice's far side, a = transmittance

    init(device: MTLDevice, renderWidth: Int, renderHeight: Int, slices: Int) throws {
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
        let columns = (renderWidth + 7) / 8, rows = (renderHeight + 7) / 8
        self.columns = columns
        self.rows = rows
        self.slices = slices
        func make(_ label: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor()
            d.textureType = .type3D
            d.pixelFormat = .rgba16Float
            d.width = columns; d.height = rows; d.depth = slices
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        scatter = [try make("fog scatter0"), try make("fog scatter1")]
        integrated = try make("fog integrated")
    }
}

/// The lens and the finish (Shaders/Post.metal), at the output resolution.
final class PostTargets {
    let width: Int, height: Int
    let color: MTLTexture       // the composite's light, when MetalFX doesn't upscale it (FLAG_POST)
    let dof: MTLTexture         // after the depth of field
    let down: [MTLTexture]      // bloom's halvings, from half the output size...
    let up: [MTLTexture]        // ...and the way back up: up[i] = down[i] + up[i + 1] filtered (one fewer)
    let focus: MTLBuffer        // the autofocus distance, eased from frame to frame (0 = none yet)

    init(device: MTLDevice, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        func make(_ label: String, _ w: Int, _ h: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        color = try make("post color", width, height)
        dof = try make("post dof", width, height)
        var down: [MTLTexture] = [], (w, h) = (width, height)
        while down.count < PostSettings.bloomLevels && min(w, h) >= 16 {
            (w, h) = ((w + 1) / 2, (h + 1) / 2)
            down.append(try make("bloom down\(down.count)", w, h))
        }
        self.down = down
        up = try down.dropLast().enumerated().map { try make("bloom up\($0.offset)", $0.element.width, $0.element.height) }
        guard let focus = device.makeBuffer(length: 16, options: .storageModeShared) else { throw RendererError.resourceCreation("focus buffer") }
        memset(focus.contents(), 0, 16)
        self.focus = focus
    }
}

/// ReSTIR DI's per-pixel state (Shaders/RestirDI.metal).
final class RestirTargets {
    let width: Int, height: Int, chains: Int
    let reservoir: [MTLTexture]   // [2] rgba32Uint arrays (element, uv, W, M | flags; a slice per chain), ping-ponged
    let temporal: MTLTexture      // restirTemporalKernel's reservoirs
    let spatial: MTLTexture       // between two spatial passes
    let specular: MTLTexture      // direct specular light (rgba16F), which the reflection pass adds

    init(device: MTLDevice, width: Int, height: Int, chains: Int) throws {
        self.width = width
        self.height = height
        self.chains = chains
        func make(_ label: String, _ format: MTLPixelFormat) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            if format == .rgba32Uint { d.textureType = .type2DArray; d.arrayLength = chains }
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        reservoir = [try make("restir reservoir0", .rgba32Uint), try make("restir reservoir1", .rgba32Uint)]
        temporal = try make("restir temporal", .rgba32Uint)
        spatial = try make("restir spatial", .rgba32Uint)
        specular = try make("restir specular", .rgba16Float)
    }
}

/// MegaLights' state (Shaders/MegaLights.metal): the tiles' light lists, their visible-light hashes (ping-ponged: last
/// frame's steer this frame's picks) and the direct specular light the reflection pass adds.
final class MegaLightsTargets {
    let width: Int, height: Int, capacity: Int
    let tilesX: Int, tilesY: Int
    let lists: MTLBuffer          // per tile: count, lights reached, then `capacity` sorted 16-bit light indices
    let guide: [MTLBuffer]        // [2] per tile: 128 bits, the lights it found visible
    let specular: MTLTexture      // direct specular light (rgba16F)

    init(device: MTLDevice, width: Int, height: Int, capacity: Int) throws {
        self.width = width
        self.height = height
        self.capacity = capacity
        tilesX = (width + GPUMegaLightsParams.tile - 1) / GPUMegaLightsParams.tile
        tilesY = (height + GPUMegaLightsParams.tile - 1) / GPUMegaLightsParams.tile
        func buffer(_ label: String, _ length: Int) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: length, options: .storageModePrivate) else {
                throw RendererError.resourceCreation("buffer \(label)")
            }
            b.label = label
            return b
        }
        lists = try buffer("megalights lists", tilesX * tilesY * (capacity + 2) * MemoryLayout<UInt16>.stride)
        guide = [try buffer("megalights guide0", tilesX * tilesY * 16), try buffer("megalights guide1", tilesX * tilesY * 16)]
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture megalights specular") }
        t.label = "megalights specular"
        specular = t
    }
}

/// ReSTIR GI's per-pixel state (Shaders/RestirGI.metal). A reservoir is two textures: rgba32F (x_s, W) and rgba32Uint
/// (normal, light, M | age | flags).
final class RestirGITargets {
    let width: Int, height: Int
    let reservoir: [(a: MTLTexture, b: MTLTexture)]   // [2], ping-ponged: the final reservoirs, next frame's history
    let temporal: (a: MTLTexture, b: MTLTexture)      // restirGITemporalKernel's reservoirs
    let spatial: (a: MTLTexture, b: MTLTexture)       // the initial samples, then between two spatial passes
    let feedback: [MTLTexture]                        // [2] rgba16F, ping-ponged: the raw indirect light (multi-bounce)
    let ambient: [MTLBuffer]                          // [2], ping-ponged: the mean indirect light (rgb sums, count)

    init(device: MTLDevice, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        func make(_ label: String, _ format: MTLPixelFormat) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        func pair(_ label: String) throws -> (a: MTLTexture, b: MTLTexture) {
            (try make("\(label) a", .rgba32Float), try make("\(label) b", .rgba32Uint))
        }
        reservoir = [try pair("restir gi reservoir0"), try pair("restir gi reservoir1")]
        temporal = try pair("restir gi temporal")
        spatial = try pair("restir gi spatial")
        feedback = [try make("restir gi feedback0", .rgba16Float), try make("restir gi feedback1", .rgba16Float)]
        ambient = try (0..<2).map { _ in
            guard let b = device.makeBuffer(length: 16, options: .storageModePrivate) else {
                throw RendererError.resourceCreation("restir gi ambient")
            }
            return b
        }
    }
}


/// Makes the frames, on its own thread (`RenderThread`): once that runs, everything here belongs to it. The main thread
/// talks to it through `RendererController`, which posts work with `perform` and gets values back.
final class Renderer: NSObject {
    static let maxFramesInFlight = 3
    /// Layout of MTLAccelerationStructureInstanceDescriptor: packed 4x3 float matrix + 4 x uint32.
    /// Metal's TLAS instance descriptors: the default ones (64 bytes, the mesh's structure by index), or for Metal 4,
    /// which takes only indirect ones, those (72 bytes: a user ID and the structure's resource ID follow).
    private var instanceDescriptorStride: Int { SceneBuffers.descriptorStride(builtAPI) }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private weak var surface: RenderSurface?
    private var scene = Scene()
    /// The shaders' entry file: next to this source file, or `METALRENDERER_SHADERS=<path to a Shaders.metal>`, which
    /// lets one binary run another copy of the shaders (an A/B of a shader change without a second build).
    private let shaderURL = ProcessInfo.processInfo.environment["METALRENDERER_SHADERS"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Shaders.metal")

    /// Every compute pipeline, for the tracer and the light types of the scene being drawn (Pipelines.swift). Replaced
    /// whole, between two frames, by a scene load or a shader reload that built the next set in the background.
    private var pipelines: Pipelines!
    private var shaderGeneration = 0                // shader reloads so far: a set built from an older one is stale
    private var frozenLOD: (SIMD3<Float>, Float)?   // "Freeze LOD": camera position and pixel scale it was turned on at
    private var radianceCascades: RadianceCascades?   // created on first use of the radiance-cascades GI mode
    private var lumen: Lumen?                         // ...and of the Lumen GI mode
    private var lumenCards: LumenCards?               // Lumen's surface cache (for the scene it was made for)
    private weak var lumenCardsScene: Scene?
    private var lumenScene: LumenScene?               // the meshes' distance fields (for the scene it was made for)
    private weak var lumenSceneOf: Scene?
    private var lumenGlobal: LumenGlobalSDF?          // the global distance field (made with lumenScene)
    /// What Lumen's bakes read of a scene that let go of its arrays (the open world's), kept when it did.
    private var lumenKeptSource: LumenScene.Source?
    private weak var lumenKeptScene: Scene?

    /// The scene's geometry, its instances' records and Metal's structures over them (SceneBuffers.swift).
    private var sceneBuffers: SceneBuffers!
    private var positionBuffer: MTLBuffer { sceneBuffers.positions }
    private var normalBuffer: MTLBuffer { sceneBuffers.normals }
    private var indexBuffer: MTLBuffer { sceneBuffers.indices }
    private var meshBuffer: MTLBuffer { sceneBuffers.meshes }
    /// Per slot: animated light proxies change their materials' emission while older frames are still being drawn.
    private var materialBuffers: [MTLBuffer] { sceneBuffers.materials }
    /// For what is built off the frames (a scene's structures): the frames' queue runs its command buffers in order,
    /// and a frame would wait behind a build.
    private lazy var buildQueue: MTLCommandQueue = {
        let q = device.makeCommandQueue()!
        q.label = "builds"
        return q
    }()
    private var materialsPending: [Range<Int>?] = []   // per slot: the materials changed since it was last written
    private var lightTrianglesPending: [Range<Int>?] = []   // ...and the light table's triangles (the open world's dusk)
    private var frameDataWritten: [Bool] = []          // per slot: a frame's instances and lights have been written to it
    /// This frame's instance and light records, kept from frame to frame: only what moves or flickers is rewritten, then
    /// each goes to the slot's buffer in one copy. (Writing the records straight into the shared buffers costs the GPU
    /// 0.35 ms a frame with 16384 moving lights: they stay in the CPU's caches. A large memcpy doesn't leave them there.)
    private var lightStage: [GPULight] = []
    private var stageComplete = false                  // the stage holds every record
    private var uvBuffer: MTLBuffer { sceneBuffers.uvs }
    private var triangleMaterialBuffer: MTLBuffer { sceneBuffers.triangleMaterials }   // Scene.triangleMaterials (meshes of several materials)
    private var emissiveBuffer: MTLBuffer { sceneBuffers.emissive }                    // emissive-mesh lights' triangles (MSL EmissiveTriangle)
    private var materialTextures: [MTLTexture] = []   // Scene.textures, decoded (MaterialTextures.swift)
    private var textureTable: MTLBuffer!              // their MTLResourceIDs (MSL MaterialTexture array)
    private var shadingArgs: [MTLBuffer] = []         // per slot, MSL SceneShading: materials, UVs, textures, streaming (buffer 7)
    private var shadingResources: [MTLResource] = []
    private var textureStreamer: TextureStreamer?     // full-resolution textures, streamed per mip (sparse)
    private var staticMinLod: MTLBuffer!              // without streaming: every level resident (zeros)
    private var feedbackDummy: MTLBuffer!
    private var primitiveAS: [MTLAccelerationStructure] { sceneBuffers.primitives }   // Metal ray tracer only
    private var primitiveASResources: [MTLResource] = []
    private var namedPrimitives: [String: MTLAccelerationStructure] { sceneBuffers?.namedPrimitives ?? [:] }
    private var namedBlocks: [String: MeshBlock] { sceneBuffers?.namedBlocks ?? [:] }
    private var namedInstanceBlocks: [String: InstanceBlock] { sceneBuffers?.namedInstanceBlocks ?? [:] }
    /// The crowd's pose slots, if the scene has a crowd: the skinning, and for the Metal tracer their structures' refit.
    private var crowdSkinner: CrowdSkinner?
    /// The scene's rigid bodies on the GPU (PhysicsSettings.backend), or nil: then `Scene.update` steps them.
    private var physicsGPU: PhysicsGPU?
    private var primitiveRefit: PrimitiveRefit? { sceneBuffers.primitiveRefit }
    private var customRT: CustomRayTracer? {                           // custom ray tracer only
        didSet { traversalLast = nil }   // a new tracer's counters start at 0
    }
    /// The tracer the scene's structures were built for (and the pipelines compiled for).
    private var builtRayTracer = RayTracerKind.initial
    /// The API the frames go through, the pipelines were compiled for and the TLAS's instance descriptors are written for.
    private var builtAPI = RenderAPI.metal3
    private var metal4Storage: AnyObject?       // Metal4Frame, made the first time Metal 4 is asked for
    @available(macOS 26.0, *)
    private var metal4: Metal4Frame? {
        if metal4Storage == nil {
            metal4Storage = Metal4Frame(device: device, streamQueue: queue, framesInFlight: Renderer.maxFramesInFlight,
                                        layer: (surface as? LayerSurface)?.layer)
        }
        return metal4Storage as? Metal4Frame
    }
    /// Metal 4's compiler for `api` `.metal4` (pipelines, MetalFX's scalers), nil for Metal 3. Render thread.
    private func compiler(for api: RenderAPI) -> AnyObject? {
        guard api == .metal4, #available(macOS 26.0, *) else { return nil }
        return metal4?.compiler
    }
    private var blueNoiseTexture: MTLTexture!   // the blue-noise tile (zeros until `blueNoiseReady`)
    /// Light-map side: 128 for up to 16 lights, then smaller so all maps together cost about 16 128^2 maps to trace.
    static func lightMapSize(lightCount: Int) -> Int {
        lightCount <= 16 ? 128 : max(32, Int(128 * (16 / Double(lightCount)).squareRoot()) / 8 * 8)
    }
    private var lightMap: MTLTexture!           // per-light distance maps (texture array), see lightMapKernel
    private var blueNoiseReady = false
    // Volumetric fog (Shaders/Fog.metal), allocated when first turned on.
    private var fogNoiseTexture: MTLTexture?    // tiling 3D density noise (FogNoise)
    private var fogNoisePending = false         // being generated in the background
    private var fogGrid: FogTargets?            // froxel grid at the current render resolution
    private var fogReference: MTLTexture?       // per-pixel reference march (benchmark references)
    private var postTargetsCache: PostTargets?   // the lens and the finish, at the current output resolution
    private var fogLastFrame: UInt32?           // the frame that last wrote the froxel grid, and its far distance:
    private var fogLastFar: Float = 0           //   history is reprojected only from the frame just before
    private var dummy3D: MTLTexture!            // bound in place of the fog textures while fog is off
    private var dummy2D: MTLTexture!
    private var dummyArray: MTLTexture!         // in place of the sky texture with a constant sky
    // Sky and clouds (Shaders/Sky.metal), allocated when first used.
    private var skyMap: MTLTexture?             // [0] upper, [1] lower hemisphere (equal-area squares), mipmapped
    private var cloudShadowMap: MTLTexture?     // clouds' transmittance toward the sun over the ground around the scene
    private var cloudShape: MTLTexture?         // 128^3 Perlin-Worley + Worley octaves (cloudNoiseKernel)
    private var cloudDetail: MTLTexture?        // 32^3 Worley octaves
    private var cloudNoiseReady = false         // the noise and the atmosphere's tables have been drawn
    private var transmittanceLUT: MTLTexture?   // atmosphere transmittance to its top, by height and angle
    private var multiScatterLUT: MTLTexture?    // atmosphere multiple scattering, by height and sun angle
    private var skyMean: MTLBuffer?             // the sky's mean radiance per hemisphere (skyMeanKernel), for the next frame
    private var skyImage: (path: String, exposure: Float, image: SkyImage, texture: MTLTexture)?
    private var skyImageFailed: String?         // a path that didn't load (not retried every frame)
    private var skyImageLoading = false         // one is being decoded in the background
    private var skyParams = GPUSkyParams()      // this frame's (also written into the shading arguments)
    private var skyActive = false               // this frame uses the sky texture
    private var skyRefreshed: (sky: SkySettings, scene: ObjectIdentifier)?   // what the sky texture was fully drawn for
    private var atmosphereCache: (sun: SIMD3<Float>, ground: SIMD3<Float>)?
    /// Shading-argument layout (MSL SceneShading): seven buffer addresses, the sky and cloud-shadow textures, SkyParams
    /// (16-byte aligned), the virtual shadow maps' VSMScene.
    private static let shadingSkyOffset = 56, shadingParamsOffset = 80
    private static let shadingVSMOffset = 80 + MemoryLayout<GPUSkyParams>.stride   // VSMScene's address (or 0)
    private static let shadingArgsLength = shadingVSMOffset + 16   // 288: the shader asserts it

    // Per-frame-in-flight resources (the CPU writes these while the GPU may still read older ones)
    private var instanceDescBuffers: [MTLBuffer] { sceneBuffers.instanceDescriptors }
    private var instanceDataBuffers: [MTLBuffer] { sceneBuffers.instanceData }
    private var lightBuffers: [MTLBuffer] = []      // per slot: the lights, then the light table (LightTable)
    private var restirGrid: RestirTargets?
    private var regirBuffer: MTLBuffer?             // the light grid's reservoirs (GPURegirReservoir), GPU only
    private var regirParams = GPURegirParams()      // this frame's grid (consume.x = 0: off), bound with the scene
    private var restirWritten = false               // last frame's ReSTIR pass stored its reservoirs
    private var megaLightsGrid: MegaLightsTargets?
    private var lightTree: LightTree?               // MegaLights' far field: built on its first frame in a scene
    private var lightTreeRefitFrame: UInt32 = 0
    private var lightTreeBuffers: [MTLBuffer?] = [MTLBuffer?](repeating: nil, count: Renderer.maxFramesInFlight)
    private var lightTreeVersions = [Int](repeating: -1, count: Renderer.maxFramesInFlight)   // what each slot's holds
    private var megaLightsWritten = false           // last frame's MegaLights pass left its tiles' visible-light hashes
    private var restirGIGrid: RestirGITargets?
    private var restirGIWritten = false             // last frame's ReSTIR GI pass stored its reservoirs (and feedback)
    private var rasterScene: RasterScene?           // the raster visibility buffer's view of the scene (RasterScene.swift)
    private var rasterTargets: RasterTargets?
    private var rasterClusters: RasterClusters?     // virtual geometry drawn as Nanite's clusters (RasterClusters.swift)
    private lazy var rasterDepthState: MTLDepthStencilState? = {
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .greater   // reversed Z
        d.isDepthWriteEnabled = true
        return device.makeDepthStencilState(descriptor: d)
    }()
    private var vsmTargets: VSMTargets?             // the virtual shadow maps (VSM.swift)
    private weak var vsmSource: MTLBuffer?          // ...made for the scene buffers with this mesh table
    private var vsmFrame: VSMTargets?               // this frame's (bindScene declares what its samples reach)
    private lazy var vsmClearState: MTLDepthStencilState? = {
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .always    // a page's clear: the far end over whatever it held
        d.isDepthWriteEnabled = true
        return device.makeDepthStencilState(descriptor: d)
    }()
    private var instanceAS: [MTLAccelerationStructure] {
        sceneBuffers.voxelLOD.map { [MTLAccelerationStructure](repeating: $0.current, count: Renderer.maxFramesInFlight) }
            ?? sceneBuffers.instanceStructures
    }
    private var instanceScratch: [MTLBuffer] { sceneBuffers.instanceScratch }
    private var instanceASBuilt = Set<Int>()
    private let frameSemaphore = DispatchSemaphore(value: Renderer.maxFramesInFlight)

    private var targets: RenderTargets?

    // State
    private var camera = Camera()
    private var prevCamera = Camera()
    private var frameIndex: UInt32 = 0
    private var animTime: Float = 0
    private var previousAnimTime: Float = 0            // a frame ago: what moves by the clock alone (the wind) reprojects with it
    private var lastTime = CACurrentMediaTime()
    /// User-adjustable settings, shared by the keyboard shortcuts and the settings panel.
    var settings = RenderSettings() {
        didSet {
            guard settings != oldValue else { return }
            // What this GPU can't run (from the environment, saved settings or a key) falls back to what it can.
            let (supported, notes) = settings.clamped(to: Capabilities.current)
            if supported != settings {
                notes.forEach { print($0) }
                settings = supported
                return
            }
            if settings.giMode != oldValue.giMode { resetGIState() }
            // Any change can change the picture: the reference starts over (a benchmark's starts with its config).
            if !benchmarkAccumulating { resetReference() }
            publishSettings()
        }
    }
    private var persistSettings = false         // the app (not benchmarks), once the saved settings are loaded
    /// The last of the controller's settings edits applied (`applySettings`), sent back with the settings.
    private var settingsUpdate = 0
    /// GPU pass timings for the settings panel (GPUProfiler): per frame, then averaged over the stats interval.
    var profilePasses = false
    var passProfilingSupported: Bool { GPUProfiler.isSupported(on: device) }
    /// The Debug window is open: the stats tick brings its `DebugInfo`, and every frame its times (`onFrameTime`).
    var debugActive = false
    // What the renderer tells the main thread (RendererController), all called on the render thread. Set before the
    // render thread starts.
    /// After every settings change (edits, keyboard shortcuts, scene loads, fallbacks): the settings, the last edit
    /// applied, and whether to save them.
    var onSettings: ((_ settings: RenderSettings, _ update: Int, _ persist: Bool) -> Void)?
    /// Twice a second, when the stats (fps, GPU time, `statsLine`) are refreshed.
    var onTick: ((RendererStatus) -> Void)?
    /// Every frame once its GPU work is done, while `debugActive`: the CPU time since the previous frame started and
    /// the GPU time, both in ms. For the Debug window's graph.
    var onFrameTime: ((_ cpuMs: Double, _ gpuMs: Double) -> Void)?
    /// Called once, when the first frame has been drawn.
    var onFirstFrame: (() -> Void)?
    /// Where frames are made, and what runs `perform`'s work (RenderThread.swift).
    private let renderThread = RenderThread()
    /// What "Reset to Defaults" restores (differs from RenderSettings() on GPUs without MetalFX).
    private(set) var defaultSettings = RenderSettings()
    /// Resolution, fps and GPU time, refreshed twice a second.
    private(set) var statsLine = ""
    private var upscaler: Upscaler?           // MetalFX's denoising scaler, while upscaling
    private var upscalerReset = true          // drop the upscaler's history on the next frame
    private var supersampling = false         // benchmark reference: jitter + average the final colour
    private var colorAccum: MTLTexture?
    private var colorAccumCount: UInt32 = 0
    private var prevJitter = SIMD2<Float>(repeating: 0)
    // Benchmark reference: average raw frames of a paused scene instead of denoising.
    private var benchmarkAccumulating = false
    private var referenceGIMode: GIMode?                // benchmark references: accumulate this GI method instead of paths
    private var referenceDirectMode: DirectLightMode?   // benchmark references: this direct-light method instead of exact
    private var accumCount: UInt32 = 0
    private var accumTextures: (direct: MTLTexture, indirect: MTLTexture, specular: MTLTexture)?
    /// This frame's reference picture (Reference in the settings, or a benchmark's): what is averaged over frames.
    private var referenceMode: ReferenceMode { benchmarkAccumulating ? .accumulated : settings.reference.mode }
    /// Raw frames of the frame's own passes are averaged instead of denoised (a benchmark's reference, or Reference
    /// "Accumulated passes").
    private var accumulating: Bool { referenceMode == .accumulated }
    // Reference "Path traced": pathTraceKernel's running mean, the paths in it per pixel, and the view it was made from.
    private var pathTraceAccum: MTLTexture?
    private var pathTraceCount: UInt32 = 0
    private var referenceEpoch: UInt32 = 0      // which average this is: a new one draws new samples (its seed)
    private var referenceView: [SIMD4<Float>] = []
    private var lightProxies: MTLBuffer?        // makeLightProxies
    private var lightProxyCount = 0
    private(set) lazy var upscaleSupported = Capabilities.current.metalFXDenoiser
    private lazy var maxUpscale = CGFloat(Upscaler.maxScale(on: device))
    /// Upscale factors this GPU supports (for MetalFX's denoising scaler), with 0 meaning off.
    var upscaleSteps: [CGFloat] { upscaleSupported ? [0, 1.5, 2, 3].filter { $0 <= maxUpscale } : [0] }
    private var historyValid = false
    /// MetalFX's denoising scaler is this frame's upscaler: it denoises, so SVGF and the shadow denoiser stay off.
    private var neuralDenoise: Bool { upscaler != nil }
    /// This project's denoisers (SVGF, the shadow denoiser) are on.
    private var denoiserOn: Bool { settings.denoiser.enabled && !neuralDenoise }
    private var reservoirsWritten = false       // last frame's manyLightsKernel stored light picks (light reuse)
    private var heldKeys = Set<String>()
    private var shiftHeld = false
    /// The mouse holds a body: the cursor (0...1 across and down) and the grab plane's distance along the view.
    private var holding: (cursor: SIMD2<Float>, depth: Float)?
    /// The view's width over its height, for the cursor's ray.
    private var viewAspect: Float = 1.6
    private let benchmark: Benchmark? = Benchmark.isEnabled ? Benchmark() : nil

    // Stats
    private var gpuMs: Double = 0
    private var firstFrameDrawn = false
    private lazy var profiler = GPUProfiler(device: device, framesInFlight: Renderer.maxFramesInFlight)
    private var passTimeOrder: [String] = [], passTimeSums: [String: Double] = [:]
    private var passTimeFrameMs = 0.0, passTimeFrames = 0
    private var fpsFrames = 0
    private var fpsTime = CACurrentMediaTime()
    private var fps: Double = 0
    private var lastDrawTime: CFTimeInterval?
    private var frameIntervalMs = 0.0           // CPU time between the starts of the last two frames
    private var frameIntervalSum = 0.0, frameIntervalCount = 0
    private var cpuMs = 0.0                     // frameIntervalMs averaged over the stats interval
    /// The CPU's own work in `draw` (simulation, uploads, encoding; not the waits for a frame slot or the drawable),
    /// averaged over the stats interval. The frame interval is GPU-bound and hides it.
    private var encodeMs = 0.0, encodeSum = 0.0, encodeCount = 0
    // Traversal counters (Debug window, custom tracer): summed per frame, averaged per stats interval.
    private var traversalSum = TraversalStats(), traversalFrames = 0
    private var traversalLast: [UInt32]?
    private(set) var traversal: (stats: TraversalStats, frames: Int)?

    /// `surface`: the window's view (set up with `configureForRenderer`) or an `OffscreenSurface`; the caller keeps it.
    init(device: MTLDevice, surface: RenderSurface) throws {
        validateGPULayouts()
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.resourceCreation("command queue")
        }
        self.device = device
        self.queue = queue
        self.surface = surface
        super.init()
        // The starting tracer, upscaler and API come from the environment: fall back where this GPU lacks them.
        let (supported, notes) = settings.clamped(to: Capabilities.current)
        notes.forEach { print($0) }
        settings = supported
        defaultSettings = defaultSettings.clamped(to: Capabilities.current).settings

        try createDummyTextures()
        try createSceneResources()
        try createBlueNoiseTexture()
        if benchmark != nil {
            // Benchmarks start with everything in place: the same frames every run.
            pipelines = try Pipelines(device: device, source: shaderURL, kind: builtRayTracer, api: builtAPI,
                                      compiler: compiler(for: builtAPI), lightTypes: scene.lightTypeMask,
                                      stats: CustomRayTracer.statsEnabled)
            customRT?.pipelines = pipelines.rt
        } else {
            // The app compiles them in the background: a second or two after a shader edit (Metal's cache has them
            // otherwise), during which the window is up and the scene, the textures and the noise load.
            startCompilingShaders()
        }
        if !upscaleSupported {
            // Without MetalFX's denoising scaler, a 0.5x render would just be stretched, so render at 0.75x instead.
            print("The MetalFX denoiser is not supported on this GPU or system; rendering at 0.75x without upscaling")
            defaultSettings.renderScale = 0.75
            defaultSettings.upscaleFactor = 0
            settings = defaultSettings
        }
        if let benchmark {
            applyBenchmarkConfig(benchmark.current)
        } else {
            // Last session's settings, then the METALRENDERER_* overrides. A different scene loads in the background
            // like a switch in the panel.
            var s = SettingsStore.load(over: defaultSettings) ?? settings
            if !upscaleSteps.contains(s.upscaleFactor) { s.upscaleFactor = defaultSettings.upscaleFactor }
            SettingsEnv.applyAll(to: &s, defaults: defaultSettings)
            let (supported, notes) = s.clamped(to: Capabilities.current)
            notes.forEach { print($0) }
            settings = supported
            persistSettings = true
            SettingsStore.dumpIfRequested(settings)
            if settings.fog.enabled { _ = fogNoise() }   // starts making it now, not at the first frame
        }
        Launch.mark("renderer")
    }

    // MARK: - Setup

    private func makeBuffer<T>(_ array: [T], _ label: String) throws -> MTLBuffer {
        let length = max(MemoryLayout<T>.stride * array.count, 16)
        let buffer: MTLBuffer? = array.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else {
                return device.makeBuffer(length: length, options: .storageModeShared)
            }
            return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
        }
        guard let buffer else { throw RendererError.resourceCreation("buffer \(label)") }
        buffer.label = label
        return buffer
    }

    /// The slow, CPU-heavy part of a scene switch (loading models, building BVHs, decoding textures). Thread-safe, so
    /// interactive switches run it in the background while the old scene keeps rendering.
    private struct PreparedScene {
        let scene: Scene
        let rayTracer: RayTracerKind
        let api: RenderAPI
        let textures: [MTLTexture]
        let streamer: TextureStreamer?
        let customRT: CustomRayTracer?
        let buffers: SceneBuffers?  // of a scene made for this load (one being drawn gets them when it is installed)
        let pipelines: Pipelines?   // for its tracer and light types, when the ones in use don't fit...
        let shaderGeneration: Int   // ...built from this generation of the shaders
    }
    private var loading: (scene: SceneSettings, rayTracer: RayTracerKind, api: RenderAPI)?   // being prepared in the background
    /// A scene that has been replaced and what it was drawn with, on their way out (`install`).
    private final class Replaced {
        var parts: PreparedScene?
        init(_ parts: PreparedScene) { self.parts = parts }
    }

    /// What the open world's streaming cost while a benchmark measured: each scene made around another tile (in the
    /// background, then installed between two frames), and the longest frame, start to start.
    private struct Streaming {
        var preparedMs: [Double] = []
        var installedMs: [Double] = []
        var longestFrameMs = 0.0

        func summary(_ buffers: SceneBuffers) -> String {
            func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
            let m = buffers.megabytes
            return String(format: "Streaming: %d scenes, made in %.0f ms (median), installed in %.1f ms (the slowest %.1f), the longest frame %.1f ms; "
                          + "the scene on the GPU: geometry %.0f MB, instances %.0f MB, structures %.0f MB",
                          preparedMs.count, median(preparedMs), median(installedMs), installedMs.max() ?? 0, longestFrameMs,
                          m.geometry, m.instances, m.primitives + m.instanceStructures)
        }
    }
    private var streaming = Streaming()

    /// The virtual-geometry switch or pool size changed for a scene with glTF models (the cut threshold needs no rebuild).
    private var virtualGeometryChanged: Bool {
        let hasModels = scene.settings.kind == .gallery || !scene.settings.extraModels.isEmpty
        let poolChanged = customRT?.virtualGeometry.map { $0.poolBytes != max(settings.virtualGeometry.poolMB, 64) << 20 } ?? false
        return hasModels && (scene.usesVirtualGeometry != wantsVirtualGeometry(settings.rayTracer) || poolChanged)
    }

    /// Virtual geometry needs the custom tracer (Metal would need acceleration structures rebuilt for every cut).
    private func wantsVirtualGeometry(_ rayTracer: RayTracerKind) -> Bool {
        rayTracer == .custom && settings.virtualGeometry.enabled
    }

    /// What a scene load reads from the renderer, copied on the render thread: `prepareScene` runs in the background while
    /// the panel and the keyboard keep changing `settings` and a shader reload may replace the pipelines.
    private struct LoadOptions {
        var virtualGeometry: Bool
        var poolMB: Int
        var textureBudgetMB: Int
        var pipelines: Pipelines
        var shaderGeneration: Int
        var traversalStats: Bool
        var api: RenderAPI
        var compiler: AnyObject?    // Metal 4's, for `api`
        var primitives: [String: MTLAccelerationStructure]   // the scene's named meshes' structures (Metal's tracer)
        var blocks: [String: MeshBlock]                      // its borrowed meshes' buffers
        var instanceBlocks: [String: InstanceBlock]          // its instance groups' blocks
        var voxelGrids: VoxelGrids?                          // its plants' voxel grids (Metal's tracer)
        /// The open world's next scene (`settings.scene`, if it is that) is drawn with the textures this one has: they
        /// stay as they are streamed. By the sources' identities.
        var worldTextures: (identities: [String], textures: [MTLTexture], streamer: TextureStreamer?)?
    }
    private var loadOptions: LoadOptions {
        LoadOptions(virtualGeometry: settings.virtualGeometry.enabled, poolMB: settings.virtualGeometry.poolMB,
                    textureBudgetMB: settings.textureBudgetMB, pipelines: pipelines, shaderGeneration: shaderGeneration,
                    traversalStats: CustomRayTracer.statsEnabled, api: settings.api, compiler: compiler(for: settings.api),
                    primitives: builtRayTracer == .metal && builtAPI == settings.api ? namedPrimitives : [:], blocks: namedBlocks,
                    instanceBlocks: namedInstanceBlocks,
                    voxelGrids: builtRayTracer == .metal && builtAPI == settings.api ? sceneBuffers?.voxelLOD?.grids : nil,
                    worldTextures: settings.scene.isSameWorld(as: scene.settings) && builtAPI == settings.api
                        ? (scene.textures.map(\.identity), materialTextures, textureStreamer) : nil)
    }

    private func bufferOptions(rayTracer: RayTracerKind, api: RenderAPI, known: [String: MTLAccelerationStructure],
                               blocks: [String: MeshBlock], instanceBlocks: [String: InstanceBlock],
                               voxelGrids: VoxelGrids? = nil) -> SceneBuffers.Options {
        SceneBuffers.Options(rayTracer: rayTracer, api: api, slots: Renderer.maxFramesInFlight, fastIntersection: Renderer.fastIntersectionBLAS,
                             compact: Renderer.compactBLAS, instanceUsage: Renderer.tlasUsage, known: known, blocks: blocks,
                             instanceBlocks: instanceBlocks, voxelGrids: voxelGrids)
    }

    /// The pipelines for `kind` and `lightTypes`, compiled here (any thread) unless `current` already fits. Its
    /// library is reused when only the light types differ.
    private func makePipelines(kind: RayTracerKind, api: RenderAPI, compiler: AnyObject?, lightTypes: UInt32, stats: Bool,
                               current: Pipelines) throws -> Pipelines? {
        if current.kind == kind && current.api == api && current.lightTypes == lightTypes { return nil }
        return try Pipelines(device: device, source: shaderURL, kind: kind, api: api, compiler: compiler, lightTypes: lightTypes,
                             stats: stats, reusing: current.kind == kind && current.api == api ? current.library : nil)
    }

    /// `current`: the scene being drawn, reused when only the ray tracer changes; `instances` is then the render thread's
    /// copy of its instances (the frame loop keeps animating the scene while this runs).
    private func prepareScene(_ sceneSettings: SceneSettings, rayTracer: RayTracerKind, reuse current: Scene?,
                              instances: [Scene.Instance]? = nil, options: LoadOptions) throws -> PreparedScene {
        let virtual = rayTracer == .custom && options.virtualGeometry
        // Generated plants are assemblies for the custom tracer and baked meshes for Metal's: another scene.
        let assemblies = rayTracer == .custom
        // Metal's: far plants as voxels if asked for (SceneSettings.voxelBoxes), which makes the scene's plants differently too.
        let voxelBoxes = rayTracer == .metal && sceneSettings.voxelBoxes
        let reused = current.flatMap { !$0.geometryReleased && $0.usesVirtualGeometry == virtual
            && (!$0.hasPlants || ($0.usesAssemblies == (assemblies && !sceneSettings.bakedPlants) && $0.usesVoxelBoxes == voxelBoxes)) ? $0 : nil }
        let newScene = reused ?? Scene(sceneSettings, virtualGeometry: virtual, assemblies: assemblies, voxelBoxes: voxelBoxes)
        let kept = options.worldTextures.flatMap { $0.identities == newScene.textures.map(\.identity) ? $0 : nil }
        let streamer = kept != nil ? kept?.streamer
            : newScene.textures.isEmpty || !TextureStreamer.isSupported(device, api: options.api) ? nil
            : try TextureStreamer(sources: newScene.textures, device: device, queue: queue, budgetMB: options.textureBudgetMB,
                                  slots: Renderer.maxFramesInFlight, placement: options.api == .metal4)
        let textures = try kept?.textures ?? streamer?.textures ?? MaterialTextures.load(newScene.textures, device: device, queue: queue)
        // The scene's buffers and structures, unless the frames are still animating it.
        let buffers = reused != nil ? nil : try autoreleasepool {
            try SceneBuffers(device: device, queue: buildQueue, scene: newScene,
                             options: bufferOptions(rayTracer: rayTracer, api: options.api, known: options.primitives, blocks: options.blocks,
                                                    instanceBlocks: options.instanceBlocks, voxelGrids: options.voxelGrids))
        }
        let rt = rayTracer == .custom ? try CustomRayTracer(device: device, scene: newScene, instances: reused == nil ? nil : instances,
                                                            geometry: buffers, slots: Renderer.maxFramesInFlight, poolMB: options.poolMB) : nil
        // The shaders too, when the tracer changes (a recompile) or the new scene has other light types.
        let pipelines = try makePipelines(kind: rayTracer, api: options.api, compiler: options.compiler,
                                          lightTypes: newScene.lightTypeMask, stats: options.traversalStats, current: options.pipelines)
        if let buffers { SceneBuffers.touch(buffers.buffers + (rt?.buffers ?? []), device: device, queue: buildQueue) }
        // The open world's scene is made again for every tile the camera comes to, never built from twice: its vertex
        // arrays, now in the buffers, go.
        if buffers != nil, newScene.worldPlace != nil, !CustomRayTracer.checked {
            lumenKeptSource = LumenScene.Source(scene: newScene)   // Lumen's bakes still read them
            lumenKeptScene = newScene
            newScene.releaseGeometry()
        }
        return PreparedScene(scene: newScene, rayTracer: rayTracer, api: options.api, textures: textures, streamer: streamer, customRT: rt,
                             buffers: buffers, pipelines: pipelines, shaderGeneration: options.shaderGeneration)
    }

    private static let flightOverride: (velocity: SIMD3<Float>, turn: Int)? = {
        let parts = (ProcessInfo.processInfo.environment["METALRENDERER_FLIGHT"] ?? "").split(separator: ",").compactMap { Float($0) }
        return parts.count >= 3 ? (SIMD3(parts[0], parts[1], parts[2]), parts.count > 3 ? Int(parts[3]) : 0) : nil
    }()

    /// Starts preparing `settings.scene` / `settings.rayTracer` in the background; `install` swaps it in when done.
    private func startLoadingScene() {
        let wanted = (scene: settings.scene, rayTracer: settings.rayTracer, api: settings.api)
        if let loading, loading == wanted { return }
        loading = wanted
        let reuse = wanted.scene == scene.settings ? scene : nil   // only the tracer changes
        let instances = reuse?.instances, options = loadOptions    // read here: the background must not touch them
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let start = CACurrentMediaTime()
            let result = Result {
                try self.prepareScene(wanted.scene, rayTracer: wanted.rayTracer, reuse: reuse, instances: instances, options: options)
            }
            let preparedMs = (CACurrentMediaTime() - start) * 1000
            self.renderThread.perform {
                guard let loading = self.loading, loading == wanted else {
                    return   // superseded by a newer request
                }
                self.loading = nil
                switch result {
                case .success(let prepared):
                    if self.benchmark?.isMeasuring == true { self.streaming.preparedMs.append(preparedMs) }
                    self.install(prepared, resetCamera: prepared.scene.settings.kind != self.scene.settings.kind)
                case .failure(let error):
                    print("Scene load failed, keeping the previous scene: \(error)")
                    self.settings.scene = self.scene.settings
                    self.settings.rayTracer = self.builtRayTracer
                    self.settings.api = self.builtAPI
                }
            }
        }
    }

    /// Everything sized by the scene: geometry, acceleration structures, per-frame instance / light buffers, light maps.
    private func createSceneResources(_ prepared: PreparedScene? = nil) throws {
        builtRayTracer = prepared?.rayTracer ?? settings.rayTracer
        builtAPI = prepared?.api ?? settings.api
        customRT = nil
        crowdSkinner = nil
        physicsGPU = nil
        holding = nil
        lightBuffers = []
        frameDataWritten = [Bool](repeating: false, count: Renderer.maxFramesInFlight)
        lightStage = [GPULight](repeating: GPULight(positionRadius: .zero, color: .zero, axis: .zero, params: .zero),
                                count: scene.lights.count)
        stageComplete = false
        restirWritten = false
        megaLightsWritten = false
        restirGIWritten = false
        instanceASBuilt = []
        textureStreamer = prepared?.streamer
        let buffers = try prepared?.buffers ?? SceneBuffers(device: device, queue: buildQueue, scene: scene,
                                                            options: bufferOptions(rayTracer: builtRayTracer, api: builtAPI,
                                                                                   known: builtRayTracer == .metal ? namedPrimitives : [:],
                                                                                   blocks: namedBlocks,
                                                                                   instanceBlocks: namedInstanceBlocks))
        sceneBuffers = buffers
        makeLightProxies()
        primitiveASResources = buffers.primitives.map { $0 as MTLResource }
        try createShadingResources(textures: prepared?.textures)
        if let crowd = scene.crowd, !crowd.slots.isEmpty {
            crowdSkinner = try CrowdSkinner(device: device, crowd: crowd, frameSlots: Renderer.maxFramesInFlight)
        }
        // The physics on the GPU, or only its cloths', soft bodies' and hair's meshes when the CPU steps it (they are drawn
        // from the GPU's buffers).
        if let physics = scene.physics {
            let onGPU = scene.settings.physics.runsOnGPU(bodies: physics.bodies.count + physics.particles.count + physics.hairStrands.count)
            if onGPU || !physics.cloths.isEmpty || !physics.softVertices.isEmpty || !physics.hairGroups.isEmpty {
                physicsGPU = try PhysicsGPU(device: device, world: physics, sdfScene: buffers.sdf.scene, sdfResources: buffers.sdf.buffers,
                                            slots: Renderer.maxFramesInFlight, simulates: onGPU,
                                            clothPrevOffsets: scene.clothMeshes.map { scene.meshes[$0].prevOffset })
                if onGPU { scene.runPhysicsOnGPU() }
            }
        }
        try createLightBuffers()
        if builtRayTracer == .custom {
            customRT = try prepared?.customRT ?? CustomRayTracer(device: device, scene: scene, geometry: buffers, slots: Renderer.maxFramesInFlight,
                                                                 poolMB: settings.virtualGeometry.poolMB)
            if let pipelines { customRT?.pipelines = pipelines.rt }   // nil at launch: set when they arrive
        }
        let lmd = MTLTextureDescriptor()
        lmd.textureType = .type2DArray
        lmd.pixelFormat = .r32Float
        // With many lights (LIGHT_TABLE) nothing reads light maps: a placeholder (more than 2048 slices can't exist).
        lmd.width = scene.usesLightTable ? 8 : Renderer.lightMapSize(lightCount: scene.lights.count)
        lmd.height = lmd.width
        lmd.arrayLength = scene.usesLightTable ? 1 : max(scene.lights.count, 1)
        lmd.usage = [.shaderRead, .shaderWrite]
        lmd.storageMode = .private
        guard let lm = device.makeTexture(descriptor: lmd) else { throw RendererError.resourceCreation("texture lightMap") }
        lm.label = "lightMap"
        lightMap = lm
    }

    /// Replaces the scene with `settings.scene` right away (benchmarks; the app loads in the background).
    private func rebuildScene(resetCamera: Bool) {
        loading = nil   // a scene still loading is for settings this one replaces
        do {
            let reuse = settings.scene == scene.settings ? scene : nil
            install(try prepareScene(settings.scene, rayTracer: settings.rayTracer, reuse: reuse, options: loadOptions),
                    resetCamera: resetCamera)
        } catch {
            print("Scene rebuild failed, keeping the previous scene: \(error)")
            settings.scene = scene.settings
            settings.rayTracer = builtRayTracer
            settings.api = builtAPI
        }
    }

    /// Swaps in a prepared scene. Waits for in-flight frames, since they still read the old buffers.
    private func install(_ prepared: PreparedScene, resetCamera: Bool) {
        for _ in 0..<Renderer.maxFramesInFlight { frameSemaphore.wait() }
        defer { for _ in 0..<Renderer.maxFramesInFlight { frameSemaphore.signal() } }
        let oldRayTracer = builtRayTracer, oldAPI = builtAPI, oldPipelines = pipelines
        // What the scene being replaced is drawn with: to go back to if this fails, and to let go of if it doesn't. In
        // a box, which is emptied off this thread: letting go of an open world's scene takes 13 ms.
        let old = Replaced(PreparedScene(scene: scene, rayTracer: oldRayTracer, api: oldAPI, textures: materialTextures,
                                         streamer: textureStreamer, customRT: customRT, buffers: sceneBuffers, pipelines: nil,
                                         shaderGeneration: shaderGeneration))
        let oldSettings = scene.settings, oldPlace = scene.worldPlace
        let start = CACurrentMediaTime()
        scene = prepared.scene
        do {
            if let ready = prepared.pipelines, prepared.shaderGeneration == shaderGeneration {
                pipelines = ready
            } else if let made = try makePipelines(kind: prepared.rayTracer, api: prepared.api, compiler: compiler(for: prepared.api),
                                                   lightTypes: scene.lightTypeMask, stats: CustomRayTracer.statsEnabled,
                                                   current: pipelines) {
                pipelines = made   // here only if the shaders were reloaded while the scene was loading
            }
            try createSceneResources(prepared)
        } catch {
            print("Scene rebuild failed, keeping the previous scene: \(error)")
            scene = old.parts!.scene
            settings.scene = oldSettings
            settings.rayTracer = oldRayTracer
            settings.api = oldAPI
            pipelines = oldPipelines
            try? createSceneResources(old.parts)
        }
        // The open world made around another tile is the same world in the same place: what the frames have gathered
        // of it holds.
        let sameWorld = scene.settings.isSameWorld(as: oldSettings)
        var moved = SIMD2<Float>()
        if sameWorld, let was = oldPlace, let now = scene.worldPlace {
            // The scene's origin has moved: the camera is where it was in the world.
            moved = SIMD2(Float(was.anchor.x - now.anchor.x), Float(was.anchor.y - now.anchor.y))
            for c in [\Renderer.camera, \Renderer.prevCamera] {
                self[keyPath: c].position.x += moved.x
                self[keyPath: c].position.z += moved.y
            }
            // ...and so is where Freeze LOD holds the detail for.
            frozenLOD?.0 += SIMD3(moved.x, 0, moved.y)
        }
        if !(sameWorld && moved == .zero && oldRayTracer == builtRayTracer) {
            resetGIState()
            upscalerReset = true
            resetReference()
        } else if !scene.meshLights.isEmpty || old.parts?.scene.meshLights.isEmpty == false {
            // At night the tiles' lights are other ones: what the pixels kept of the lights (a reservoir names its
            // light by its place in the scene's table) is of the scene before.
            restirWritten = false
            megaLightsWritten = false
            reservoirsWritten = false
        }
        if resetCamera {
            camera = scene.defaultCamera
            prevCamera = camera
        }
        // ...and its sky is the same sky: no need to draw all of it again (a sixteenth a frame keeps it up to date).
        if sameWorld, let drawn = skyRefreshed { skyRefreshed = (drawn.sky, ObjectIdentifier(scene)) }
        if #available(macOS 26.0, *) { (metal4Storage as? Metal4Frame)?.noteSceneChange() }
        DispatchQueue.global(qos: .utility).async { old.parts = nil }
        let installedMs = (CACurrentMediaTime() - start) * 1000
        if sameWorld, benchmark?.isMeasuring == true { streaming.installedMs.append(installedMs) }
        if sameWorld { benchmark?.noteSwap() }
        print(String(format: "Scene: %@, %d instances, %d lights, %@ ray tracing, %@ (installed in %.0f ms)", scene.settings.kind.title,
                     sceneBuffers.instanceCount, scene.lights.count, builtRayTracer.title, builtAPI.title, installedMs))
    }

    /// What shading reads besides the scene's buffers: the textures and their table, and each slot's arguments.
    private func createShadingResources(textures: [MTLTexture]?) throws {
        // The materials are the scene's as the buffers were made; what has changed since goes to every slot.
        materialsPending = [Range<Int>?](repeating: scene.takeMaterialsDirty(), count: Renderer.maxFramesInFlight)
        materialTextures = try textures ?? MaterialTextures.load(scene.textures, device: device, queue: queue)
        textureTable = try makeBuffer(materialTextures.map(\.gpuResourceID), "textureTable")
        staticMinLod = try makeBuffer([Float](repeating: 0, count: max(materialTextures.count, 1)), "textureMinLod")
        feedbackDummy = try makeBuffer([UInt32](repeating: 0, count: max(materialTextures.count, 1) * TextureStreamer.levelBins),
                                       "textureFeedback")
        shadingArgs = []
        for slot in 0..<Renderer.maxFramesInFlight {
            guard let args = device.makeBuffer(length: Renderer.shadingArgsLength, options: .storageModeShared) else {
                throw RendererError.resourceCreation("buffer shadingArgs")
            }
            args.label = "shadingArgs\(slot)"
            let p = args.contents()
            p.storeBytes(of: materialBuffers[slot].gpuAddress, toByteOffset: 0, as: UInt64.self)
            p.storeBytes(of: uvBuffer.gpuAddress, toByteOffset: 8, as: UInt64.self)
            p.storeBytes(of: textureTable.gpuAddress, toByteOffset: 16, as: UInt64.self)
            p.storeBytes(of: (textureStreamer?.minLodBuffer(slot: slot) ?? staticMinLod).gpuAddress, toByteOffset: 24, as: UInt64.self)
            p.storeBytes(of: (textureStreamer?.feedbackBuffer(slot: slot) ?? feedbackDummy).gpuAddress, toByteOffset: 32, as: UInt64.self)
            p.storeBytes(of: emissiveBuffer.gpuAddress, toByteOffset: 40, as: UInt64.self)
            p.storeBytes(of: triangleMaterialBuffer.gpuAddress, toByteOffset: 48, as: UInt64.self)
            shadingArgs.append(args)
            writeSkyArguments(slot: slot)
        }
        // The textures too, unless they are a sparse heap's (Metal 3's streamer: `bindScene` declares the heap).
        // Metal 4's streamed ones are placement-sparse textures of the device's, each its own allocation: its
        // residency set forgets what no frame declares, and a texture whose levels have settled is never uploaded to.
        // And the borrowed meshes' buffers, which a hit reaches through the mesh table, the instance blocks'
        // records, which it reaches through theirs, and the SDF shapes, which the ray queries reach through RTScene or
        // their boxes' data.
        shadingResources = materialBuffers + [uvBuffer, textureTable, staticMinLod, feedbackDummy, emissiveBuffer, triangleMaterialBuffer]
            + (textureStreamer?.placement == false ? [] : materialTextures) + sceneBuffers.blockBuffers
        shadingResources += sceneBuffers.instanceResources + (sceneBuffers.voxelLOD?.grids.buffers ?? [])
            + (sceneBuffers.sdf.shapeCount > 0 ? sceneBuffers.sdf.buffers : [])
    }

    /// The blue-noise tile as a texture; without `values`, zeros (bound until the tile is ready). Any thread.
    private static func blueNoiseTexture(_ device: MTLDevice, values: [Float]?) throws -> MTLTexture {
        let n = BlueNoise.size
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: n, height: n, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture blueNoise") }
        texture.label = "blueNoise"
        (values ?? [Float](repeating: 0, count: n * n)).withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: n * MemoryLayout<Float>.stride)
        }
        return texture
    }

    /// The tile comes from the cache file. Without one (the first launch) generating it takes about half a second:
    /// the app does that in the background and samples with white noise until the tile is in (`blueNoiseReady`);
    /// a benchmark waits for it.
    private func createBlueNoiseTexture() throws {
        if let values = benchmark != nil ? BlueNoise.tile() : BlueNoise.cached() {
            blueNoiseTexture = try Renderer.blueNoiseTexture(device, values: values)
            blueNoiseReady = true
            return
        }
        blueNoiseTexture = try Renderer.blueNoiseTexture(device, values: nil)
        let device = device
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let texture = try? Renderer.blueNoiseTexture(device, values: BlueNoise.tile())
            self?.renderThread.perform {
                guard let self, let texture else { return }
                self.blueNoiseTexture = texture   // frames in flight keep the old one
                self.blueNoiseReady = true
                self.skyRefreshed = nil           // the sky's bake reads the tile whatever the setting
            }
        }
    }

    /// 1-texel stand-ins for optional textures, so every texture a kernel declares is bound.
    private func createDummyTextures() throws {
        let d3 = MTLTextureDescriptor()
        d3.textureType = .type3D
        d3.pixelFormat = .rgba16Float
        d3.width = 1; d3.height = 1; d3.depth = 1
        d3.usage = .shaderRead
        d3.storageMode = .private
        let d2 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        d2.usage = .shaderRead
        d2.storageMode = .private
        let da = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        da.textureType = .type2DArray
        da.arrayLength = 2
        da.usage = .shaderRead
        da.storageMode = .private
        guard let t3 = device.makeTexture(descriptor: d3), let t2 = device.makeTexture(descriptor: d2),
              let ta = device.makeTexture(descriptor: da) else {
            throw RendererError.resourceCreation("dummy textures")
        }
        dummy3D = t3
        dummy2D = t2
        dummyArray = ta
    }

    /// The fog's 3D noise (~50 ms to generate). Any thread.
    private static func fogNoiseTexture(_ device: MTLDevice) -> MTLTexture? {
        let n = FogNoise.size
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .r8Unorm
        d.width = n; d.height = n; d.depth = n
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        texture.label = "fogNoise"
        FogNoise.generate().withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: n, bytesPerImage: n * n)
        }
        return texture
    }

    /// The fog's noise, made the first time fog is on: in the background (nil until it is ready, so the fog shows a
    /// few frames late), or right here in a benchmark.
    private func fogNoise() -> MTLTexture? {
        if let fogNoiseTexture { return fogNoiseTexture }
        if benchmark != nil {
            fogNoiseTexture = Renderer.fogNoiseTexture(device)
            return fogNoiseTexture
        }
        if !fogNoisePending {
            fogNoisePending = true
            let device = device
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let texture = Renderer.fogNoiseTexture(device)
                self?.renderThread.perform {
                    self?.fogNoiseTexture = texture
                    self?.fogNoisePending = false
                }
            }
        }
        return nil
    }

    private func fogTargets(width: Int, height: Int) -> FogTargets? {
        if let g = fogGrid, g.renderWidth == width, g.renderHeight == height { return g }
        fogGrid = try? FogTargets(device: device, renderWidth: width, renderHeight: height, slices: FogSettings.slices)
        fogLastFrame = nil
        return fogGrid
    }

    private func postTargets(width: Int, height: Int) -> PostTargets? {
        if let t = postTargetsCache, t.width == width, t.height == height { return t }
        postTargetsCache = try? PostTargets(device: device, width: width, height: height)
        return postTargetsCache
    }

    private func fogReferenceTexture(width: Int, height: Int) -> MTLTexture? {
        if let t = fogReference, t.width == width, t.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        fogReference = device.makeTexture(descriptor: d)
        fogReference?.label = "fogReference"
        return fogReference
    }

    /// This frame's fog parameters for the shaders (flags 0 while fog is off).
    /// `requireGrid`: none without the froxel grid (the frame's fog); the path tracer reads the medium alone.
    private func makeFogParams(grid: FogTargets?, historyValid: Bool, requireGrid: Bool = true) -> GPUFogParams {
        var p = GPUFogParams()
        let f = settings.fog
        guard f.enabled, grid != nil || !requireGrid else { return p }
        let near: Float = 0.2, far = max(f.maxDistance, 1)
        p.medium = SIMD4(FogSettings.densityRange.clamp(f.density) * (f.density > 0 ? 1 : 0), max(f.heightFalloff, 0),
                         f.baseHeight, FogSettings.anisotropyRange.clamp(f.anisotropy))
        p.albedo = SIMD4(f.albedo, max(f.ambient, 0))
        p.noise = SIMD4(f.noise, max(f.noiseScale, 0.1), animTime, 0.1)
        p.wind = SIMD4(f.wind, FogSettings.hazeRange.clamp(f.haze))
        p.grid = SIMD4(near, far, log(far / near), Float(grid?.slices ?? 0))
        let volumes = f.volumes ? Array(scene.fogVolumes.prefix(GPUFogParams.maxVolumes)) : []
        for (i, v) in volumes.enumerated() { p.setVolume(i, v.gpu) }
        p.counts = SIMD4(UInt32(grid?.columns ?? 0), UInt32(grid?.rows ?? 0), UInt32(volumes.count),
                         GPUFogParams.enabled | (historyValid ? GPUFogParams.historyValid : 0)
                         | (f.reflections ? GPUFogParams.reflections : 0) | (f.lights ? 0 : GPUFogParams.skyLight))
        return p
    }

    // MARK: - Sky

    /// The sky texture, the cloud noise and the cloud-shadow map, allocated the first time the sky is used.
    private func ensureSkyTextures() -> Bool {
        if skyMap != nil { return true }
        let n = SkySettings.mapSize
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: n, height: n, mipmapped: true)
        d.textureType = .type2DArray
        d.arrayLength = 2
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        let m = SkySettings.shadowMapSize
        let ds = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: m, height: m, mipmapped: false)
        ds.usage = [.shaderRead, .shaderWrite]
        ds.storageMode = .private
        func volume(_ side: Int) -> MTLTextureDescriptor {
            let v = MTLTextureDescriptor()
            v.textureType = .type3D
            v.pixelFormat = .rgba8Unorm
            v.width = side; v.height = side; v.depth = side
            v.mipmapLevelCount = Int(log2(Double(side))) + 1   // the clouds read coarser levels for longer steps
            v.usage = [.shaderRead, .shaderWrite, .renderTarget]
            v.storageMode = .private
            return v
        }
        func lut(_ w: Int, _ h: Int) -> MTLTextureDescriptor {
            let l = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            l.usage = [.shaderRead, .shaderWrite]
            l.storageMode = .private
            return l
        }
        guard let sky = device.makeTexture(descriptor: d), let shadow = device.makeTexture(descriptor: ds),
              let shape = device.makeTexture(descriptor: volume(128)), let detail = device.makeTexture(descriptor: volume(32)),
              let tLUT = device.makeTexture(descriptor: lut(256, 64)), let msLUT = device.makeTexture(descriptor: lut(32, 32)),
              let mean = device.makeBuffer(length: 32, options: .storageModeShared) else {
            return false
        }
        memset(mean.contents(), 0, 32)
        transmittanceLUT = tLUT
        multiScatterLUT = msLUT
        skyMean = mean
        sky.label = "sky"; shadow.label = "cloud shadow"; shape.label = "cloud shape noise"; detail.label = "cloud detail noise"
        skyMap = sky
        cloudShadowMap = shadow
        cloudShape = shape
        cloudDetail = detail
        cloudNoiseReady = false
        return true
    }

    /// The environment image for `path` (loaded once, its sun cut out), as an equirectangular texture.
    private func skyImageFor(_ path: String, exposure: Float) -> (image: SkyImage, texture: MTLTexture)? {
        if let s = skyImage, s.path == path, s.exposure == exposure { return (s.image, s.texture) }
        if skyImageFailed == path { return nil }
        if benchmark != nil {
            // A benchmark loads it here, so its first frame has it.
            switch Result(catching: { try Renderer.loadSkyImage(device, path: path, exposure: exposure) }) {
            case .success(let loaded): skyImage = (path, exposure, loaded.image, loaded.texture)
            case .failure(let error):
                print("Sky image failed to load (\(path)): \(error)")
                skyImageFailed = path
            }
            return skyImage.map { ($0.image, $0.texture) }
        }
        // The app decodes it in the background (a 2K image takes a few hundred ms), one load at a time: until it is in,
        // the sky is the image at its last exposure, or the constant colour.
        if !skyImageLoading {
            skyImageLoading = true
            let device = device
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try Renderer.loadSkyImage(device, path: path, exposure: exposure) }
                self?.renderThread.perform {
                    guard let self else { return }
                    self.skyImageLoading = false
                    switch result {
                    case .success(let loaded):
                        self.skyImage = (path, exposure, loaded.image, loaded.texture)
                        self.skyRefreshed = nil   // a full bake with the new image
                    case .failure(let error):
                        print("Sky image failed to load (\(path)): \(error)")
                        self.skyImageFailed = path
                    }
                }
            }
        }
        if let s = skyImage, s.path == path { return (s.image, s.texture) }
        return nil
    }

    /// Decodes the image and uploads it. Any thread.
    private static func loadSkyImage(_ device: MTLDevice, path: String, exposure: Float) throws -> (image: SkyImage, texture: MTLTexture) {
        let image = try SkyImage.load(path: path, exposure: exposure)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: image.width, height: image.height,
                                                         mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture sky image") }
        texture.label = "sky image"
        image.pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: image.width * 16)
        }
        let sun = image.sunDirection.map { String(format: "sun toward (%.3f, %.3f, %.3f), %.2f° across, irradiance %.2f", $0.x, $0.y, $0.z, 2 * image.sunAngularRadius * 180 / .pi, 0.2126 * image.sunIrradiance.x + 0.7152 * image.sunIrradiance.y + 0.0722 * image.sunIrradiance.z) } ?? "no sun"
        print("Sky image: \((path as NSString).lastPathComponent), \(image.width)×\(image.height), \(sun)")
        return (image, texture)
    }

    /// This frame's sky: the sun (from the atmosphere, or the image's), which also sets the scene's sun light (its
    /// colour, and with an image its direction), and the clouds. False for a constant sky (or an image that failed).
    private func updateSky(lights: UnsafeMutableBufferPointer<GPULight>) -> Bool {
        let sky = settings.sky
        guard sky.mode != .constant, ensureSkyTextures() else { return false }
        var image: SkyImage?
        if sky.mode == .image {
            guard let path = sky.imagePath, let loaded = skyImageFor(path, exposure: sky.imageExposure) else { return false }
            image = loaded.image
        }
        let sunIndex = scene.firstSun
        var sunDir = normalize(SIMD3<Float>(0.4, 0.5, -0.6)), sunRadius: Float = 0.27 * .pi / 180
        if let d = image?.sunDirection {
            sunDir = d
            sunRadius = image!.sunAngularRadius
        } else if let i = sunIndex {
            sunDir = normalize(SIMD3(lights[i].axis.x, lights[i].axis.y, lights[i].axis.z))
            sunRadius = lights[i].positionRadius.w
        }
        let sunGround: SIMD3<Float>
        var sunTop = Atmosphere.solarIrradiance, glow = SIMD3<Float>(0, 1, 0), glowTop = SIMD3<Float>(), stars: Float = 0
        if let image {
            sunGround = image.sunDirection == nil ? .zero : image.sunIrradiance
        } else if let heavens = scene.heavens {
            // The open world: the light is the sun, or the moon once the sun has set; the sun then still lights the
            // sky from under the horizon.
            var light = Atmosphere.solarIrradiance * heavens.adaptation * heavens.sunUp
            sunTop = Atmosphere.solarIrradiance * heavens.adaptation
            stars = heavens.stars
            if heavens.lightIsMoon {
                glow = heavens.sun
                if heavens.sunElevation > Heavens.twilightEnd { glowTop = sunTop }
                sunTop = Heavens.nightSkyIrradiance * heavens.moonlight
                light = Heavens.moonIrradiance * (heavens.moonlight * heavens.moonUp)
            }
            if atmosphereCache == nil || length(atmosphereCache!.sun - sunDir) > 1e-4 {
                atmosphereCache = (sunDir, Atmosphere.sunIrradiance(toward: sunDir))
            }
            sunGround = atmosphereCache!.ground / Atmosphere.solarIrradiance * light
        } else {
            if atmosphereCache == nil || length(atmosphereCache!.sun - sunDir) > 1e-4 {
                atmosphereCache = (sunDir, Atmosphere.sunIrradiance(toward: sunDir))
            }
            sunGround = atmosphereCache!.ground
        }
        if let i = sunIndex {
            lights[i].color = SIMD4(sunGround, lights[i].color.w)
            lights[i].axis = SIMD4(sunDir, 0)
            lights[i].positionRadius.w = sunRadius
        }
        let full = skyRefreshed == nil || skyRefreshed!.sky != sky || skyRefreshed!.scene != ObjectIdentifier(scene)
        skyRefreshed = (sky, ObjectIdentifier(scene))
        let windAngle = sky.windDirection * .pi / 180
        let sphere = scene.sceneSphere
        var p = GPUSkyParams()
        p.sun = SIMD4(sunDir, sunRadius)
        p.sunTop = SIMD4(sunTop, 0)
        p.sunGround = SIMD4(sunGround, 0)
        p.glow = SIMD4(glow, stars)
        p.glowTop = SIMD4(glowTop, 0)
        p.cloudLayer = SIMD4(sky.cloudBase, sky.cloudBase + max(sky.cloudThickness, 100),
                             SkySettings.coverageRange.clamp(sky.coverage), SkySettings.densityRange.clamp(sky.density))
        p.cloudShape = SIMD4(max(sky.cloudScale, 100), sky.erosion, animTime, sky.shadowStrength)
        p.wind = SIMD4(SIMD3(cos(windAngle), 0, sin(windAngle)) * sky.windSpeed, full ? 1 : 0.5)
        p.shadowMap = SIMD4(sphere.x, sphere.z, max(1.2 * sphere.w, 150), 0)
        if let place = scene.worldPlace {
            // The open world: cloud shadows over everything in sight, the clouds where the world has them.
            p.shadowMap.z = 9 * World.tileSize
            p.place = SIMD4(Float(place.anchor.x), Float(place.anchor.y), camera.position.x, camera.position.z)
        }
        p.ground = SIMD4(SIMD3(repeating: 0.25), Atmosphere.observerAltitude)
        let clouds = sky.clouds && (image == nil || sky.cloudsOverImage)
        p.flags = SIMD4(image == nil ? GPUSkyParams.atmosphere : GPUSkyParams.image,
                        (sky.clouds ? GPUSkyParams.clouds : 0) | (clouds && sky.shadows ? GPUSkyParams.shadows : 0)
                            | (full ? GPUSkyParams.updateAll : 0) | (sky.cloudsOverImage ? GPUSkyParams.cloudsOverImage : 0),
                        frameIndex % 16, frameIndex)
        skyParams = p
        return true
    }

    /// The sky's part of the shading arguments (MSL SceneShading): its textures (stand-ins without a sky) and SkyParams.
    private func writeSkyArguments(slot: Int) {
        guard slot < shadingArgs.count else { return }
        let p = shadingArgs[slot].contents()
        let sky = skyActive ? skyMap ?? dummyArray! : dummyArray!, shadow = skyActive ? cloudShadowMap ?? dummy2D! : dummy2D!
        p.storeBytes(of: sky.gpuResourceID, toByteOffset: Renderer.shadingSkyOffset, as: MTLResourceID.self)
        p.storeBytes(of: shadow.gpuResourceID, toByteOffset: Renderer.shadingSkyOffset + 8, as: MTLResourceID.self)
        p.storeBytes(of: skyActive ? skyParams : GPUSkyParams(), toByteOffset: Renderer.shadingParamsOffset, as: GPUSkyParams.self)
    }

    /// The sky's passes, ahead of the frame's main encoder: the cloud noise and the atmosphere's tables (once), then
    /// this frame's sky texels, the cloud-shadow map and the sky texture's mips (encodeSkyTexels).
    private func encodeSky(_ passes: FrameEncoder) {
        guard let sky = skyMap, let shape = cloudShape, let detail = cloudDetail, let shadow = cloudShadowMap,
              let tLUT = transmittanceLUT, let msLUT = multiScatterLUT, let mean = skyMean,
              var enc = passes.compute("sky", serial: true) else { return }
        if !cloudNoiseReady {   // once: the cloud noise and the atmosphere's tables (the second reads the first)
            enc.setComputePipelineState(pipelines[.cloudNoise])
            enc.setTexture(shape, index: 0)
            enc.setTexture(detail, index: 1)
            enc.dispatchThreads(MTLSize(width: shape.width, height: shape.height, depth: shape.depth),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
            enc.setComputePipelineState(pipelines[.transmittanceLUT])
            enc.setTexture(tLUT, index: 0)
            dispatch(enc, .transmittanceLUT, width: tLUT.width, height: tLUT.height)
            enc.setComputePipelineState(pipelines[.multiScatterLUT])
            setTextures(enc, [tLUT, msLUT])
            dispatch(enc, .multiScatterLUT, width: msLUT.width, height: msLUT.height)
            passes.generateMipmaps([shape, detail], pass: "sky")
            cloudNoiseReady = true
            guard let next = passes.compute("sky", serial: true) else { return }
            enc = next
        }
        var p = skyParams
        // The clear sky's mean radiance (lights the clouds and the ground), then this frame's sky texels.
        enc.setComputePipelineState(pipelines[.skyMean])
        enc.setBytes(&p, length: MemoryLayout<GPUSkyParams>.stride, index: 0)
        enc.setBuffer(mean, offset: 0, index: 1)
        setTextures(enc, [skyImage?.texture ?? dummy2D, tLUT, msLUT])
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        enc.setComputePipelineState(pipelines[.sky])
        enc.setBytes(&p, length: MemoryLayout<GPUSkyParams>.stride, index: 0)
        enc.setBuffer(mean, offset: 0, index: 1)
        setTextures(enc, [shape, detail, blueNoiseTexture, skyImage?.texture ?? dummy2D, sky, tLUT, msLUT])
        let part = p.flags.y & GPUSkyParams.updateAll != 0 ? 1 : 4   // this frame's texels: every one, or 1 in 4x4
        enc.dispatchThreads(MTLSize(width: sky.width / part, height: sky.height / part, depth: 2),
                            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        if p.flags.y & GPUSkyParams.shadows != 0 {
            enc.setComputePipelineState(pipelines[.cloudShadow])
            enc.setBytes(&p, length: MemoryLayout<GPUSkyParams>.stride, index: 0)
            setTextures(enc, [shape, detail, shadow])
            dispatch(enc, .cloudShadow, width: shadow.width, height: shadow.height)
        }
        passes.generateMipmaps([sky], pass: "sky")
    }

    /// Per slot: the lights, then the light table.
    private func createLightBuffers() throws {
        _ = scene.takeLightTrianglesDirty()   // written here as they are now
        lightTree = nil                       // the scene's lights: made again from them when MegaLights first runs
        lightTreeVersions = [Int](repeating: -1, count: Renderer.maxFramesInFlight)
        lightTrianglesPending = [Range<Int>?](repeating: nil, count: Renderer.maxFramesInFlight)
        for _ in 0..<Renderer.maxFramesInFlight {
            guard let lights = device.makeBuffer(length: max(scene.lights.count * MemoryLayout<GPULight>.stride + scene.lightTable.byteCount, 64),
                                                 options: .storageModeShared) else {
                throw RendererError.resourceCreation("per-frame buffers")
            }
            // The light table, after the lights: written once (but for the triangles of lights that go on and off
            // with the time of day: writeFrameData).
            var offset = scene.lights.count * MemoryLayout<GPULight>.stride
            scene.lightTable.entries.withUnsafeBytes { raw in
                if raw.count > 0 { lights.contents().advanced(by: offset).copyMemory(from: raw.baseAddress!, byteCount: raw.count) }
                offset += raw.count
            }
            scene.lightTable.triangles.withUnsafeBytes { raw in
                if raw.count > 0 { lights.contents().advanced(by: offset).copyMemory(from: raw.baseAddress!, byteCount: raw.count) }
            }
            lights.label = "lights"
            lightBuffers.append(lights)
        }
    }

    // MARK: - Per-frame CPU work

    private func writeFrameData(slot: Int) {
        // Instances: a slot's first frame of a scene writes every record, straight into its buffers; after that only
        // the ones that move, the rest being as they were (a crowd is tens of thousands of records).
        // (A still scene's were written with its buffers.)
        let first = !frameDataWritten[slot], still = sceneBuffers.still
        // The GPU's bodies where they were when this slot's last frame was done: the CPU's copy (the frame's own
        // records are the pose kernel's); and the body the mouse holds, for this frame's steps.
        if let physicsGPU {
            if physicsGPU.simulates {
                scene.placeBodies(poses: physicsGPU.snapshot(slot: slot))
                if let physics = scene.physics { physicsGPU.setGrab(slot: slot, physics.grab) }
            } else {
                physicsGPU.upload(slot: slot)
            }
        }
        if let customRT {
            customRT.update(slot: slot, scene: scene)
        } else if !still {
            sceneBuffers.writeInstanceDescriptors(slot: slot, scene: scene, api: builtAPI, all: first)
        }
        crowdSkinner?.write(slot: slot)
        if !scene.instances.isEmpty, !still {
            scene.writeInstanceData(into: instanceDataBuffers[slot].contents().bindMemory(to: GPUInstanceData.self, capacity: scene.instances.count),
                                    all: first)
        }
        // Lights: after a scene's first frame only what moves or flickers is rewritten in the stage.
        let all = !stageComplete
        stageComplete = true
        frameDataWritten[slot] = true
        // Animated light proxies (flicker, chases, the sun's colour) change their materials: each slot catches up with
        // the ranges changed since it was last written.
        if let dirty = scene.takeMaterialsDirty() {
            for s in materialsPending.indices {
                materialsPending[s] = materialsPending[s].map { min($0.lowerBound, dirty.lowerBound)..<max($0.upperBound, dirty.upperBound) } ?? dirty
            }
        }
        if let range = materialsPending[slot] {
            let stride = MemoryLayout<GPUMaterial>.stride
            scene.materials.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                materialBuffers[slot].contents().advanced(by: range.lowerBound * stride)
                    .copyMemory(from: base.advanced(by: range.lowerBound * stride), byteCount: range.count * stride)
            }
            materialsPending[slot] = nil
        }
        // The open world's lights as they come on: how bright the light table says their triangles are.
        if let dirty = scene.takeLightTrianglesDirty() {
            for s in lightTrianglesPending.indices {
                lightTrianglesPending[s] = lightTrianglesPending[s].map { min($0.lowerBound, dirty.lowerBound)..<max($0.upperBound, dirty.upperBound) } ?? dirty
            }
        }
        if let range = lightTrianglesPending[slot] {
            let table = scene.lightTable, stride = MemoryLayout<GPUTriangleInfo>.stride
            let offset = scene.lights.count * MemoryLayout<GPULight>.stride + table.entries.count * MemoryLayout<GPULightTableEntry>.stride
            table.triangles.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                lightBuffers[slot].contents().advanced(by: offset + range.lowerBound * stride)
                    .copyMemory(from: base.advanced(by: range.lowerBound * stride), byteCount: range.count * stride)
            }
            lightTrianglesPending[slot] = nil
        }
        var sky = false
        lightStage.withUnsafeMutableBufferPointer { lights in
            scene.writeLights(into: lights, all: all)
            sky = updateSky(lights: lights)   // may recolour the first sun (rewritten every frame)
            if let base = lights.baseAddress {
                lightBuffers[slot].contents().copyMemory(from: base, byteCount: lights.count * MemoryLayout<GPULight>.stride)
            }
        }
        skyActive = sky
        writeSkyArguments(slot: slot)
    }

    private func updateCamera(dt: Float) {
        var move = SIMD3<Float>(repeating: 0)
        let forward = camera.forward, right = camera.right
        if heldKeys.contains("w") { move += forward }
        if heldKeys.contains("s") { move -= forward }
        if heldKeys.contains("d") { move += right }
        if heldKeys.contains("a") { move -= right }
        if heldKeys.contains("e") { move.y += 1 }
        if heldKeys.contains("q") { move.y -= 1 }
        if length(move) > 0 {
            let speed = settings.moveSpeed * (shiftHeld ? 3.2 : 1)
            camera.position += normalize(move) * speed * dt
        }
    }

    private func makeUniforms(width: Int, height: Int, giMode: GIMode, directMode: DirectLightMode) -> Uniforms {
        let aspect = Float(width) / Float(height)
        func pack(_ c: Camera) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
            let tanY = tan(c.fovY / 2)
            return (SIMD4<Float>(c.position, 0),
                    SIMD4<Float>(c.right, tanY * aspect),
                    SIMD4<Float>(c.up, tanY),
                    SIMD4<Float>(c.forward, 0))
        }
        var u = Uniforms()
        (u.camPos, u.camRight, u.camUp, u.camForward) = pack(camera)
        (u.prevCamPos, u.prevCamRight, u.prevCamUp, u.prevCamForward) = pack(prevCamera)
        u.skyColor = SIMD4<Float>(scene.skyColor, 0)
        u.post = SIMD4<Float>(exp2(RenderSettings.exposureRange.clamp(settings.exposure)), Float(settings.toneMap.rawValue), 0, 0)
        u.width = UInt32(width)
        u.height = UInt32(height)
        u.frameIndex = frameIndex
        u.lightCount = UInt32(scene.lights.count)
        // (Reference "Accumulated passes" in the app: its own path length. A benchmark's: its settings'.)
        let bounces = accumulating && !benchmarkAccumulating ? settings.reference.bounces : settings.bounces
        u.bounces = settings.giEnabled && giMode == .pathTraced ? UInt32(bounces) : 0
        u.flags = (historyValid ? UniformFlags.historyValid : 0) | (denoiserOn ? UniformFlags.denoise : 0)
        if accumulating { u.flags |= UniformFlags.noClamp | UniformFlags.reference }
        if usesSpecular { u.flags |= UniformFlags.specular }
        // Exact: one shadow ray per light (references, up to Renderer.exactReferenceLights). ReSTIR and MegaLights:
        // their own kernels.
        switch directMode {
        case .exact: u.flags |= UniformFlags.allLights
        case .restir, .megalights: u.flags |= UniformFlags.restir
        default: break
        }
        if settings.lightMaps && giMode == .pathTraced && !accumulating { u.flags |= UniformFlags.lightMaps }
        u.viewMode = UInt32(settings.viewMode)
        let d = settings.denoiser
        u.denoise = SIMD4<Float>(DenoiserSettings.luminanceSigmaRange.clamp(d.luminanceSigma),
                                 DenoiserSettings.maxHistoryRange.clamp(d.maxHistory),
                                 DenoiserSettings.antiLagRange.clamp(d.antiLag), 0)
        u.instanceCount = UInt32(sceneBuffers.instanceCount)
        u.lightGroupEnd = scene.lightGroupEnd
        let table = scene.lightTable
        u.lightTable = SIMD4(UInt32(table.entries.count), UInt32(table.suns.count),
                             table.suns.first ?? 0, table.suns.count > 1 ? table.suns[1] : 0)
        if skyActive { u.flags |= UniformFlags.skyMap }
        if settings.foliage.wind > 0 && scene.hasFoliage { u.flags |= UniformFlags.wind }
        return u
    }

    // MARK: - Render thread

    /// Starts making frames on the render thread (main thread, once, after `init` and the `on…` callbacks are set).
    func startRenderThread() {
        renderThread.start { [weak self] in self?.drawFrame() ?? false }
    }

    /// Stops the frames, once the one being encoded is committed (main thread, at quit).
    func stopRenderThread() { renderThread.stop() }

    /// Runs `work` on the render thread before its next frame. Any thread.
    func perform(_ work: @escaping (Renderer) -> Void) {
        renderThread.perform { [weak self] in if let self { work(self) } }
    }

    /// Applies the controller's settings edit number `update` (render thread). The settings go back with that number
    /// even if the edit changes nothing, so the panel knows its edits are all in.
    func applySettings(update: Int, _ change: (inout RenderSettings) -> Void) {
        settingsUpdate = update
        let before = settings
        change(&settings)
        if settings == before { publishSettings() }
    }

    private func publishSettings() { onSettings?(settings, settingsUpdate, persistSettings) }

    /// One frame: the scene's next state and its upload, the frame's plan, the stages the plan asks for, their
    /// encoding, the output, and what the frame leaves for the next one. Each step is a function below. Returns false
    /// if it drew nothing.
    private func drawFrame() -> Bool {
        // Launch: the shaders are still compiling (startCompilingShaders). And nothing while the window is hidden.
        guard pipelines != nil, let surface, surface.isVisible, benchmark?.isFinished != true else { return false }
        noteFrameStart()
        let size = frameSize(on: surface)
        guard let t = renderTargets(for: size) else { return false }
        // The open world: the scene is made around the tile the camera is in (Scene+World.swift).
        if let place = scene.worldPlace, settings.scene.kind.isWorld, loading == nil {
            let wanted = place.wanted(for: camera.position)
            if wanted != place.tile {
                settings.scene.worldTile = wanted
                let anchor = place.anchorTile(around: wanted)
                if anchor != place.anchorTile { settings.scene.worldAnchor = anchor }
            }
        }
        if scene.worldPlace != nil { scene.follow(camera.position) }
        setWorldLights()
        if settings.scene != scene.settings || settings.rayTracer != builtRayTracer || settings.api != builtAPI || virtualGeometryChanged {
            // A benchmark makes its scenes right here, but the world's next one as the app does, in the background: its
            // frames then show what a tile crossing costs.
            let streamed = settings.scene.isSameWorld(as: scene.settings) && settings.rayTracer == builtRayTracer && settings.api == builtAPI
            if benchmark != nil && !streamed { rebuildScene(resetCamera: false) } else { startLoadingScene() }
        }
        frameSemaphore.wait()
        let encodeStart = CACurrentMediaTime()
        guard prepareUpscalers(for: size) else {
            frameSemaphore.signal()
            return false
        }

        // The CPU's part: move the camera and the scene, pick virtual geometry's detail, write the slot's buffers.
        simulate(size)
        let slot = Int(frameIndex) % Renderer.maxFramesInFlight
        let lod = detailView(height: size.height)
        updateVoxelLOD(lod)
        customRT?.virtualGeometry?.update(frame: frameIndex, framesInFlight: Renderer.maxFramesInFlight)
        currentRasterClusters()?.update(frame: frameIndex, slot: slot, framesInFlight: Renderer.maxFramesInFlight)
        customRT?.virtualBLAS?.update(frame: frameIndex, slot: slot, framesInFlight: Renderer.maxFramesInFlight,
                                      camPos: lod.camPos, pixelScale: lod.pixelScale, tau: lod.tau, sceneInstances: scene.instances)
        writeFrameData(slot: slot)
        // GPU pass timings (the settings panel): an encoder per pass, timestamped at its start and end.
        // (Metal 3: the profiler times encoders, and a Metal 4 frame is a single one.)
        let profile = profilePasses && benchmark == nil && builtAPI == .metal3 ? profiler?.beginFrame(slot: slot) : nil
        let plan = planFrame(size: size, slot: slot, profiling: profile != nil)
        regirParams = plan.lightGrid?.params ?? GPURegirParams()   // bound with the scene (bindScene)
        guard let passes = makeFrame(plan, profile: profile) else {
            frameSemaphore.signal()
            return false
        }
        encodeSceneUpdate(slot: slot, lod: lod, passes: passes)
        if skyActive { encodeSky(passes) }
        writeVSMArgument(plan)
        if let vsm = plan.vsm { encodeVSM(plan, vsm, passes: passes) }

        // The stages, in the order their results land in the composite's inputs (each denoiser replaces what the one
        // before it set).
        var composite = CompositeInputs(uniforms: plan.uniforms, illumination: [t.denoise[0].pingA], specular: t.specular,
                                        meshDirect: t.meshDirect)
        var stages = FrameStages()
        if plan.pathTrace != nil {
            // Reference "Path traced": one kernel makes the whole picture.
            stages.head = pathTraceStages(plan)
        } else {
            stages.lightGrid = lightGridStages(plan)
            stages.head = headStages(plan, targets: t)
            stages.gi = giStages(plan, targets: t)
            (stages.reflections, stages.reflectionDenoise) = reflectionStages(plan, targets: t, composite: &composite)
            stages.restir = restirStages(plan, targets: t) + megaLightsStages(plan, targets: t)
            stages.denoise = sampledLightStages(plan, targets: t)
            stages.denoise += shadowDenoiseStages(plan, targets: t, composite: &composite)
            stages.denoise += accumulateStages(plan, targets: t, composite: &composite)
            stages.denoise += svgfStages(plan, targets: t, composite: &composite)
            stages.fog = fogStages(plan, targets: t, composite: &composite)
        }

        if let raster = plan.raster { encodeRaster(plan, raster, passes: passes) }
        encode(stages, plan: plan, passes: passes)
        let output = encodeOutput(plan, composite: composite, targets: t, surface: surface, passes: passes)
        commit(plan, passes: passes, profile: profile, output: output.output, encodeStart: encodeStart + output.wait)

        finishFrame(plan)
        updateTitle(width: size.width, height: size.height, outWidth: size.outWidth, outHeight: size.outHeight)
        if let benchmark { advanceBenchmark(benchmark) }
        return true
    }

    // MARK: - Frame setup

    /// The traced size and the size the drawable shows.
    private struct FrameSize {
        let width: Int, height: Int, outWidth: Int, outHeight: Int
        var upscaling: Bool { outWidth > width }
    }

    /// The time since the last frame started (the Debug window's CPU graph) and the traversal counters.
    private func noteFrameStart() {
        let drawStart = CACurrentMediaTime()
        if let last = lastDrawTime {
            frameIntervalMs = (drawStart - last) * 1000
            frameIntervalSum += frameIntervalMs
            frameIntervalCount += 1
        }
        lastDrawTime = drawStart
        if let benchmark, benchmark.isMeasuring, benchmark.frameInConfig > benchmark.warmupFrames {
            streaming.longestFrameMs = max(streaming.longestFrameMs, frameIntervalMs)
        }
        if benchmark == nil, CustomRayTracer.statsEnabled, let customRT {
            let counts = customRT.readCounters()   // what the frames finished since the last read added (in-flight ones in part)
            if let last = traversalLast {
                traversalSum = traversalSum + TraversalStats(counts: zip(counts, last).map { UInt64($0 &- $1) })
                traversalFrames += 1
            }
            traversalLast = counts
        }
    }

    /// Render resolution = window size in points * renderScale. Without upscaling the layer stretches it to the window.
    /// With upscaling, MetalFX outputs renderScale * upscaleFactor, capped at the window's size in physical pixels.
    private func frameSize(on surface: RenderSurface) -> FrameSize {
        let points = surface.pointSize
        let width = max(64, Int((points.width * settings.renderScale).rounded()))
        let height = max(64, Int((points.height * settings.renderScale).rounded()))
        var outWidth = width, outHeight = height
        // (Not under a reference picture: the denoising scaler would blend in its own history.)
        if settings.upscaleFactor > 1 && upscaleSupported && settings.reference.mode == .off {
            let backing = surface.backingScale
            let maxWidth = points.width * backing, maxHeight = points.height * backing
            let factor = min(settings.upscaleFactor, maxUpscale, maxWidth / CGFloat(width), maxHeight / CGFloat(height))
            if factor > 1.01 {
                outWidth = Int((CGFloat(width) * factor).rounded())
                outHeight = Int((CGFloat(height) * factor).rounded())
            }
        }
        surface.outputSize = CGSize(width: outWidth, height: outHeight)
        return FrameSize(width: width, height: height, outWidth: outWidth, outHeight: outHeight)
    }

    /// The screen-sized textures, recreated (without history) when the render resolution changed.
    private func renderTargets(for size: FrameSize) -> RenderTargets? {
        if let t = targets, t.width == size.width, t.height == size.height { return t }
        do {
            targets = try RenderTargets(device: device, width: size.width, height: size.height)
            historyValid = false
        } catch {
            print(error)
            return nil
        }
        return targets
    }

    /// Makes MetalFX's denoising scaler while upscaling, if it isn't there at this size. False when it couldn't be
    /// made: upscaling is then turned off (SVGF denoises instead) and the frame skipped.
    private func prepareUpscalers(for size: FrameSize) -> Bool {
        let width = size.width, height = size.height, outWidth = size.outWidth, outHeight = size.outHeight
        if !size.upscaling {
            upscaler = nil
        } else if upscaler == nil || upscaler!.inputWidth != width || upscaler!.inputHeight != height
                    || upscaler!.outputWidth != outWidth || upscaler!.outputHeight != outHeight {
            do {
                upscaler = try Upscaler(device: device, inputWidth: width, inputHeight: height,
                                        outputWidth: outWidth, outputHeight: outHeight, synchronous: benchmark != nil)
                upscalerReset = true
                historyValid = false   // the denoising scaler comes or goes: SVGF's history is not this frame's
            } catch {
                print(error)
                upscaler = nil
                settings.upscaleFactor = 0
                return false
            }
        }
        return true
    }

    /// Advances the clock, the camera and the scene's animation by one frame.
    private func simulate(_ size: FrameSize) {
        let now = CACurrentMediaTime()
        var dt = Float(min(now - lastTime, 0.1))
        lastTime = now
        if let benchmark {
            let (width, height) = (size.width, size.height)
            benchmark.noteDraw(resolution: size.upscaling ? "\(width)×\(height) → \(size.outWidth)×\(size.outHeight)" : "\(width)×\(height)")
            dt = benchmark.fixedDt   // deterministic animation so every setting renders the same frames
            if benchmark.current.cameraPath {
                camera = Benchmark.cameraPose(progress: benchmark.progressInConfig, scene: settings.scene.kind, sceneCamera: scene.defaultCamera)
            }
            if let track = benchmark.current.track { camera = track.camera(at: benchmark.trackTime) }
            // A flight: the setting's, or METALRENDERER_FLIGHT="x,y,z,frames" for every setting (metres a second; with
            // `frames`, there and back again, turning every so many frames).
            if let velocity = benchmark.current.flight ?? Renderer.flightOverride?.velocity {
                let back = Renderer.flightOverride.map { $0.turn > 0 && (benchmark.frameInConfig / $0.turn) % 2 == 1 } ?? false
                camera.position += velocity * (back ? -dt : dt)
            }
        }
        updateCamera(dt: dt)
        camera.fovY = settings.fovDegrees * .pi / 180
        viewAspect = Float(size.outWidth) / Float(max(size.outHeight, 1))
        moveGrab()
        previousAnimTime = animTime
        if !settings.paused { animTime += dt * settings.timeScale }
        scene.update(time: animTime, dayTime: dayTime)
        scene.setLeaves(season: settings.foliage.season, translucency: settings.foliage.translucency)
    }

    /// The open world's scene is one with its cities' lights from a little before the sun sets until a little after
    /// it has risen (`SceneSettings.worldLit`).
    private func setWorldLights() {
        if settings.scene.kind.isWorld { settings.scene.worldLit = Heavens(at: dayTime).sunElevation < World.lightsReady }
    }

    /// The sun's day cycle can be offset (Time of day); everything else keeps the animation time.
    private var dayTime: Float { animTime + settings.timeOfDay * (settings.scene.kind.dayCycle ?? 0) }

    /// The wind on the plants this frame (custom ray tracer: Shaders/Foliage.metal).
    private var windFrame: WindFrame {
        let f = settings.foliage, a = f.windDirection * .pi / 180
        return WindFrame(wind: SIMD4(cos(a), sin(a), f.wind, f.gusts), time: animTime, previousTime: previousAnimTime, lodBias: f.lod,
                         leafFall: Scene.leafFall(season: f.season))
    }

    /// The viewpoint virtual geometry picks its detail for: the camera, or where it was when "Freeze LOD" was turned on.
    private func detailView(height: Int) -> VGView {
        let live = (camera.position, Float(height) / (2 * tan(camera.fovY / 2)))
        if !settings.virtualGeometry.freeze { frozenLOD = nil } else if frozenLOD == nil { frozenLOD = live }
        let lod = frozenLOD ?? live
        return VGView(camPos: lod.0, pixelScale: lod.1, tau: settings.virtualGeometry.pixelError, frame: frameIndex)
    }

    /// Metal's tracer: where the far baked plants' voxel levels are (VoxelLOD). A rebuild runs on `voxelQueue` and
    /// tells the render thread when it is done; the structure it built is swapped in at a frame's start, and the next
    /// may start once no frame in flight traces the structure it builds into: `maxFramesInFlight - 1` frames after a
    /// swap.
    private struct VoxelLevels {
        weak var owner: VoxelLOD?
        var running = false
        var ready = false
        var swapFrame: UInt32?
        var started: CFTimeInterval = 0
        var swaps = 0                   // background rebuilds swapped in (benchmark summary)
    }
    private var voxelLevels = VoxelLevels()
    private let voxelQueue = DispatchQueue(label: "voxel levels", qos: .utility)
    /// A rebuild once the view has moved this far (m), at most this often (s): METALRENDERER_VOXEL_STEP / _INTERVAL.
    private static let voxelStep = Float(ProcessInfo.processInfo.environment["METALRENDERER_VOXEL_STEP"] ?? "") ?? 1
    private static let voxelInterval = Double(ProcessInfo.processInfo.environment["METALRENDERER_VOXEL_INTERVAL"] ?? "") ?? 0.25
    /// METALRENDERER_VOXEL_ASYNC=1: benchmarks rebuild in the background too, as the app does (its pictures then
    /// depend on how long the builds take).
    private static let voxelAsync = ProcessInfo.processInfo.environment["METALRENDERER_VOXEL_ASYNC"] == "1"

    /// Swaps in a finished rebuild of the voxel levels and starts the next if the view moved (or the bias changed).
    /// Benchmarks rebuild here and wait: their pictures don't depend on how long a build takes.
    private func updateVoxelLOD(_ lod: VGView) {
        guard let voxels = sceneBuffers.voxelLOD else { return }
        if voxelLevels.owner !== voxels { voxelLevels = VoxelLevels(owner: voxels) }
        if voxelLevels.ready {
            voxels.swap()
            voxelLevels.ready = false
            voxelLevels.swapFrame = frameIndex
            voxelLevels.swaps += 1
        }
        // Not while a rebuild runs: it writes the levels and `pickedView`.
        guard !voxelLevels.running else { return }
        let view = SIMD4(lod.camPos, settings.foliage.lod / max(lod.pixelScale, 1e-6))
        if let picked = voxels.pickedView, picked.w == view.w,
           distance(SIMD3(picked.x, picked.y, picked.z), lod.camPos) < Renderer.voxelStep { return }
        guard voxelLevels.swapFrame.map({ frameIndex >= $0 &+ UInt32(Renderer.maxFramesInFlight - 1) }) ?? true else { return }
        let queue = buildQueue
        if benchmark != nil && !Renderer.voxelAsync {
            if voxels.rebuild(for: view, queue: queue) {
                voxels.swap()
                voxelLevels.swapFrame = frameIndex
            }
            return
        }
        let now = CACurrentMediaTime()
        guard now - voxelLevels.started >= Renderer.voxelInterval else { return }
        voxelLevels.running = true
        voxelLevels.started = now
        voxelQueue.async { [weak self] in
            let built = voxels.rebuild(for: view, queue: queue)
            self?.renderThread.perform {   // the frames' thread: the one `voxelLevels` belongs to
                guard let self, self.voxelLevels.owner === voxels else { return }
                self.voxelLevels.running = false
                self.voxelLevels.ready = built
            }
        }
    }

    // MARK: - Frame plan

    /// Everything one frame does, decided once from the settings, the scene and what the last frame left, before
    /// anything is encoded. The stage builders read this, and none of the renderer's state that changes with a frame.
    private struct FramePlan {
        let size: FrameSize
        let slot: Int                           // the frame-in-flight slot its buffers come from
        let cur: Int                            // this frame's side of the ping-pong textures...
        var prev: Int { cur ^ 1 }               // ...and the last frame's
        var jitter = SIMD2<Float>()
        var uniforms = Uniforms()               // what every kernel gets (the composite adds flags: CompositeInputs)
        var view = Upscaler.View()              // the camera as matrices (MetalFX's denoising scaler)
        var accumulating = false                // benchmark reference: raw frames are averaged instead of denoised
        var splitPasses = false                 // benchmark: a command buffer per pass, so its GPU time can be read back
        var overlap = false                     // one concurrent encoder: the cascades and the denoisers overlap on the GPU

        // Lighting
        var giMode = GIMode.pathTraced
        var cascades = false                    // radiance-cascade GI runs
        var lumen = false                       // Lumen GI runs
        var vsm: VSMTargets?                    // the camera's surfaces' shadows through virtual shadow maps
        var restirGI = false                    // ReSTIR GI runs...
        var restirGIGrid: RestirGITargets?      // ...on these reservoirs (nil if they couldn't be allocated: no stages)...
        var restirGIHistory = false             // ...which the last frame filled
        var restir = false                      // ReSTIR DI lights the scene, as above
        var restirGrid: RestirTargets?
        var restirHistory = false
        var restirSettings = RestirSettings()   // references: unbiased initial sampling alone
        var megaLights = false                  // MegaLights lights the scene...
        var megaLightsGrid: MegaLightsTargets?  // ...with these tiles (nil if they couldn't be allocated: no stages)...
        var megaLightsHistory = false           // ...whose visible-light hashes the last frame filled
        var megaLightsSettings = MegaLightsSettings()
        var lightTree: (buffer: MTLBuffer, nodes: Int)?   // its far field, this frame's
        var lightGrid: (params: GPURegirParams, buffer: MTLBuffer)?   // the light grid (ReGIR), rebuilt this frame
        var lightMaps = false
        var raster: (scene: RasterScene, targets: RasterTargets)?   // primary hits from the raster visibility buffer
        var specular = false                    // reflections (glTF specular materials)
        var glass = false                       // window panes over the traced G-buffer (glassKernel)
        var manyLights = false                  // more than 4 lights: one sampled light per group...
        var lightReuse = false                  // ...whose picks are kept for the next frame...
        var lightPicksValid = false             // ...and the last frame's are there to reuse
        var meshLights = false                  // emissive-mesh lights, sampled per pixel

        // Denoisers
        var history = false                     // the last frame left denoiser history
        var svgf = false                        // the denoiser is on (never for references)
        var neuralDenoise = false               // MetalFX's denoising scaler denoises instead, as it upscales
        var shadowDenoiser = false              // direct light's visibility goes through its own filter
        var restirSplit = false                 // ReSTIR's visibility too, and its unshadowed light through SVGF
        var separate = false                    // direct and indirect light are separate signals
        var denoiseIndirect = false
        var denoiseMeshLights = false           // mesh lights' direct light is an SVGF signal of its own
        var directPasses = 0, indirectPasses = 0
        var accumulation: (direct: MTLTexture, indirect: MTLTexture, specular: MTLTexture)?   // references
        var accumCount: UInt32 = 0              // frames averaged so far
        var accumFull = false                   // ...as many as Reference's max samples: shown, not added to
        // A reference frame made without what the picture needs yet (the fog's noise, made in the background): it
        // replaces the average instead of joining it.
        var provisional = false
        var pathTrace: PathTracePlan?           // Reference "Path traced": nothing else runs

        // Volumetric fog
        var fog: (grid: FogTargets, noise: MTLTexture)?
        var fogParams = GPUFogParams()
        var fogReference: MTLTexture?           // references: every camera ray is marched instead
        var fogSamples: UInt32 = 0              // ...and this many frames are averaged so far

        // The lens and the finish (not in references, nor in the views that aren't light)
        var post: PostTargets?
        var postParams = GPUPostParams()
    }

    /// Reference "Path traced": pathTraceKernel adds `params.samples.y` paths per pixel to the mean of `samples.x` in
    /// `accum` (none once it has max samples), and the frame is that mean tone mapped.
    private struct PathTracePlan {
        let accum: MTLTexture
        var params = GPUPathTraceParams()
        var fog = GPUFogParams()
        var fogNoise: MTLTexture?
        var lightTree: MTLBuffer?               // with more than PT_LIGHT_HITS lights
    }

    /// Resolves this frame's modes and allocates what they need that isn't there yet.
    private func planFrame(size: FrameSize, slot: Int, profiling: Bool) -> FramePlan {
        let width = size.width, height = size.height
        var p = FramePlan(size: size, slot: slot, cur: Int(frameIndex & 1))
        checkReferenceView(width: width, height: height)
        p.accumulating = accumulating
        p.giMode = activeGIMode
        let directMode = activeDirectMode
        p.restir = directMode == .restir
        p.megaLights = directMode == .megalights
        p.specular = usesSpecular
        p.glass = scene.hasGlass
        p.history = historyValid

        var u = makeUniforms(width: width, height: height, giMode: p.giMode, directMode: directMode)
        // The denoising scaler gathers jittered samples; supersampled references average 1024 jittered frames.
        if neuralDenoise {
            p.view = Upscaler.View(worldToView: camera.worldToView, viewToClip: camera.viewToClip(aspect: Float(width) / Float(height)))
        }
        p.jitter = size.upscaling
            ? Upscaler.jitter(frame: frameIndex, scale: Float(size.outWidth) / Float(width))
            : supersampling && !size.upscaling ? Upscaler.jitter(frame: accumCount, scale: 11.32) : .zero
        u.jitter = SIMD4<Float>(lowHalf: p.jitter, highHalf: prevJitter)
        if size.upscaling { u.flags |= UniformFlags.upscale }
        if neuralDenoise { u.flags |= UniformFlags.hdrOutput }
        if settings.blueNoise && blueNoiseReady { u.flags |= UniformFlags.blueNoise }
        p.uniforms = u

        // Reference "Path traced": pathTraceKernel and the tone curve, nothing else.
        if referenceMode == .pathTraced, let accum = pathTraceTexture(width: width, height: height) {
            let r = settings.reference
            var pt = PathTracePlan(accum: accum)
            var flags = Renderer.pathTraceSobol ? GPUPathTraceParams.sobol : 0
            // The fog's medium, everywhere (no froxel grid). Until its noise is made, the frames don't count.
            if settings.fog.enabled {
                pt.fog = makeFogParams(grid: nil, historyValid: false, requireGrid: false)
                pt.fogNoise = fogNoise()
                if pt.fogNoise != nil { flags |= GPUPathTraceParams.fog } else { p.provisional = true }
            }
            // Many lights: drawn from the light tree, and met by the bounce rays at their proxies.
            var nodes: UInt32 = 0
            if scene.lights.count > Renderer.pathTraceLightHits, let tree = lightTreeBuffer(slot: slot) {
                pt.lightTree = tree.buffer
                nodes = UInt32(tree.nodes)
            }
            let count = p.provisional ? 0 : pathTraceCount   // read after pathTraceTexture: a new one starts over
            let left = r.maxSamples > 0 ? UInt32(r.maxSamples) - min(count, UInt32(r.maxSamples)) : UInt32.max
            pt.params.samples = SIMD4(count, min(UInt32(ReferenceSettings.samplesPerFrameRange.clamp(r.samplesPerFrame)), left),
                                      UInt32(ReferenceSettings.bounceRange.clamp(r.bounces)), nodes)
            pt.params.config = SIMD4(flags, UInt32(lightProxyCount), referenceEpoch, 0)
            pt.params.bounds = scene.sceneSphere
            p.pathTrace = pt
            p.uniforms.viewMode = 0   // the light, tone mapped
            p.splitPasses = benchmark != nil && Benchmark.splitPasses
            vsmFrame = nil
            return p
        }

        // Radiance cascades and the direct-light denoiser don't touch each other's textures (unless the denoiser also
        // filters the cascades' output), so their dispatches can overlap on the GPU: the shared encoder is then
        // concurrent, with explicit barriers between dependent stages. Per-pass timing (benchmark or panel) keeps
        // everything serial, and METALRENDERER_OVERLAP=0 turns overlapping off for A/B timing.
        p.splitPasses = benchmark != nil && Benchmark.splitPasses
        p.overlap = !p.splitPasses && !profiling && Renderer.overlapEnabled && settings.giEnabled
            && p.giMode == .radianceCascades && !settings.cascades.denoiseIndirect

        p.lightGrid = lightGrid(directMode: directMode, camera: u.camPos)

        // Volumetric fog: this frame's parameters (the reflections read them too). The froxel history is reprojected
        // only from the frame just before, with the same far distance.
        if settings.fog.enabled, let grid = fogTargets(width: width, height: height), let noise = fogNoise() { p.fog = (grid, noise) }
        let fogHistory = p.fog != nil && fogLastFrame == frameIndex &- 1 && fogLastFar == settings.fog.maxDistance
        p.fogParams = makeFogParams(grid: p.fog?.grid, historyValid: fogHistory)
        // Reference "Accumulated passes" in the app: until the fog's noise is made, frames without the fog don't count.
        // (Benchmarks make it before their first frame.)
        p.provisional = accumulating && !benchmarkAccumulating && settings.fog.enabled && p.fog == nil
        p.fogSamples = accumCount
        if accumulating, p.fog != nil { p.fogReference = fogReferenceTexture(width: width, height: height) }

        // The raster visibility buffer: the primary rays meet the triangles it drew. Not with far plants as voxel boxes
        // (Metal's tracer swaps them in instance by instance, which the raster doesn't follow).
        if settings.primary == .raster, !scene.hasVoxelBoxes, let rs = currentRasterScene(),
           let rt = rasterTargets(width: width, height: height, scene: rs) {
            p.raster = (rs, rt)
            p.uniforms.flags |= UniformFlags.visBuffer
            if rs.virtualClusters { p.uniforms.camForward.w = RasterClusters.bias }
        }

        // Virtual shadow maps for the suns, spots and sphere lights. Not with the cluster tree, whose geometry neither
        // the raster nor the rays that meet what it doesn't draw reach.
        if settings.shadowMethod == .virtualMaps, !CustomRayTracer.clusterMode, currentRasterScene() != nil,
           let vsm = vsmTargets(slot: slot, analytic: Int(u.lightGroupEnd.w)) {
            p.vsm = vsm
            p.uniforms.flags |= UniformFlags.vsm
        }
        vsmFrame = p.vsm

        // GI. Light-visibility maps serve the GI techniques and the path tracer's light-map variant.
        p.lightMaps = usesLightMaps
        p.cascades = settings.giEnabled && p.giMode == .radianceCascades
        p.restirGI = settings.giEnabled && p.giMode == .restirGI
        p.lumen = settings.giEnabled && p.giMode == .lumen
        if p.lumen && settings.lumen.screenTraces { p.uniforms.flags |= UniformFlags.giRadiance }
        if p.restirGI { p.restirGIGrid = restirGITargets(width: width, height: height) }
        p.restirGIHistory = restirGIWritten   // read after restirGITargets: new reservoirs hold nothing
        // Only these write t.giDebug: with any other method the "GI debug" view would show what one of them left.
        if p.cascades || p.lumen || p.restirGIGrid != nil { p.uniforms.flags |= UniformFlags.giDebug }

        // Denoising (SVGF-style): temporal accumulation + edge-aware a-trous wavelet filter.
        //   Path-traced light is denoised either as one signal or as direct and indirect separately (sharper
        //   direct shadows, since indirect noise no longer inflates the variance that guides the luminance
        //   edge-stopping). Cascade output is already smooth: it skips the denoiser unless its
        //   "denoise indirect" option is on (then 1 a-trous pass). With GI off there's no indirect light to denoise.
        let techniqueGI = p.giMode != .pathTraced
        p.neuralDenoise = neuralDenoise
        p.svgf = denoiserOn && !accumulating
        p.denoiseIndirect = settings.giEnabled && (!techniqueGI || techniqueDenoisesIndirect)
        //   With the shadow denoiser (default), direct light goes through its own visibility filter instead,
        //   and SVGF handles only indirect light.
        //   ReSTIR's direct light is radiance, not per-group visibility: SVGF filters it (no loop over the lights).
        let shadowDenoiserOn = p.svgf && settings.denoiser.shadowDenoiser && Renderer.shadowDenoiserAllowed
        //   ReSTIR with the shadow denoiser (split): its visibility goes through the visibility filter, its unshadowed
        //   light through SVGF, and the composite multiplies them.
        p.restirSplit = p.restir && shadowDenoiserOn && settings.restir.splitVisibility
        p.shadowDenoiser = shadowDenoiserOn && !p.megaLights && (!p.restir || p.restirSplit)
        //   Every kernel of the frame is told, not only the composite: with the shadow denoiser the composite adds the
        //   analytic lights' direct specular (exact GGX x visibility), so the reflection pass must not add its own sample.
        if p.shadowDenoiser { p.uniforms.flags |= UniformFlags.shadowDenoiser }
        p.separate = settings.denoiser.separateSignals || techniqueGI || !settings.giEnabled || p.shadowDenoiser
        let passCount = settings.denoiser.passes(for: p.giMode)
        p.directPasses = p.restir ? DenoiserSettings.passRange.clamp(settings.restir.denoisePasses)
            : p.megaLights ? DenoiserSettings.passRange.clamp(settings.megaLights.denoisePasses) : passCount
        p.indirectPasses = p.restirGI ? DenoiserSettings.passRange.clamp(settings.restirGI.denoisePasses) : techniqueGI ? 1 : passCount
        // Emissive-mesh lights' direct light: sampled per pixel, so noisy. With the shadow denoiser it's an SVGF signal
        // of its own; otherwise it joins the direct light. (ReSTIR and MegaLights sample their triangles themselves.)
        p.meshLights = !scene.meshLights.isEmpty && !p.restir && !p.megaLights
        p.denoiseMeshLights = p.meshLights && p.shadowDenoiser

        // More than 4 lights: direct light from one sampled light per group (manyLightsKernel).
        p.manyLights = scene.lightGroupEnd[3] > 4 && u.flags & UniformFlags.allLights == 0 && !p.restir && !p.megaLights
        p.lightReuse = p.manyLights && settings.manyLightReuse > 0 && settings.manyLightRays == 1
        p.lightPicksValid = p.lightReuse && reservoirsWritten && historyValid

        // ReSTIR DI. References with many lights accumulate its unbiased initial sampling alone (32 candidates).
        p.restirSettings = settings.restir
        if accumulating {
            p.restirSettings.candidates = 32; p.restirSettings.temporal = false; p.restirSettings.spatialPasses = 0
            p.restirSettings.visibilityReuse = false; p.restirSettings.chains = 4
        }
        if p.restir {
            p.restirGrid = restirTargets(width: width, height: height, chains: RestirSettings.chainRange.clamp(p.restirSettings.chains))
        }
        p.restirHistory = restirWritten       // read after restirTargets, as above

        // MegaLights. Its sampling is unbiased as it is: references keep it (but its firefly clamp).
        p.megaLightsSettings = settings.megaLights
        if p.megaLights {
            let options = MegaLightsSettings.capacityOptions
            let capacity = options.first { $0 >= settings.megaLights.capacity } ?? options.last!
            p.megaLightsGrid = megaLightsTargets(width: width, height: height, capacity: capacity)
            p.lightTree = lightTreeBuffer(slot: slot)
        }
        p.megaLightsHistory = megaLightsWritten   // read after megaLightsTargets: new hashes hold nothing

        if accumulating { p.accumulation = accumulationTextures(width: width, height: height) }
        p.accumCount = p.provisional ? 0 : accumCount   // read after accumulationTextures: new textures start a new average
        let maxSamples = settings.reference.maxSamples
        p.accumFull = !benchmarkAccumulating && maxSamples > 0 && accumCount >= UInt32(maxSamples)

        // The lens and the finish, on the output: the composite's light, or the denoising scaler's.
        let lens = settings.post
        if lens.isOn && RenderSettings.showsLight(settings.viewMode) && !accumulating && !supersampling {
            p.post = postTargets(width: size.outWidth, height: size.outHeight)
        }
        if let post = p.post {
            p.postParams = GPUPostParams(
                bloom: SIMD4(PostSettings.bloomRange.clamp(lens.bloom), lens.bloomThreshold, u.post.x, Float(post.down.count)),
                lens: SIMD4(PostSettings.apertureRange.clamp(lens.aperture), lens.focus, PostSettings.maxBlur, 0.1),
                finish: SIMD4(lens.vignette, lens.grain, lens.aberration, 0),
                size: SIMD4(UInt32(size.outWidth), UInt32(size.outHeight), UInt32(width), UInt32(height)),
                frame: SIMD4(frameIndex, 0, 0, 0))
        }
        return p
    }

    /// The light grid (ReGIR) for this frame: where its cells are and how they are filled and read. It is rebuilt from
    /// this frame's lights before everything that samples them (ReSTIR DI's candidates, GI's next-event estimation, the
    /// reflections, the fog). Off in scenes without a light table; references set grid.enabled themselves (off for
    /// restirq's, on with every candidate for restircheck's "grid").
    private func lightGrid(directMode: DirectLightMode, camera: SIMD4<Float>) -> (params: GPURegirParams, buffer: MTLBuffer)? {
        let g = settings.restir.grid
        guard g.enabled && scene.lightTable.entries.count > 0 && (scene.usesLightTable || directMode == .restir),
              let buffer = regirGrid(count: g.reservoirCount) else { return nil }
        let restirCandidates = accumulating ? 32 : RestirSettings.candidateRange.clamp(settings.restir.candidates)
        let cells = RegirSettings.cellRange.clamp(g.cells), levels = RegirSettings.levelRange.clamp(g.levels)
        let cellSize = RegirSettings.cellSizeRange.clamp(g.cellSize), scale = RegirSettings.scaleRange.clamp(g.levelScale)
        let jitter = Renderer.regirJitter(frame: frameIndex)
        func origin(_ level: Int) -> SIMD4<Float> {   // a level's corner and its cell size, centred on the camera
            guard level < levels else { return SIMD4() }
            let size = cellSize * pow(scale, Float(level))
            return SIMD4(SIMD3(camera.x, camera.y, camera.z) - size * (Float(cells) * 0.5 + jitter), size)
        }
        var gp = GPURegirParams()
        (gp.origin0, gp.origin1, gp.origin2, gp.origin3) = (origin(0), origin(1), origin(2), origin(3))
        gp.config = SIMD4(UInt32(cells), UInt32(levels), UInt32(RegirSettings.slotRange.clamp(g.slots)),
                          UInt32(RegirSettings.candidateRange.clamp(g.candidates)))
        gp.consume = SIMD4(UInt32(max(min(RegirSettings.shareRange.clamp(g.share), restirCandidates), 1)), frameIndex, 0, 0)
        return (gp, buffer)
    }

    /// What the frame leaves for the next one's temporal reuse. Set here, in one place, once the frame is committed.
    private func finishFrame(_ plan: FramePlan) {
        restirGIWritten = plan.restirGIGrid != nil
        restirWritten = plan.restirGrid != nil
        megaLightsWritten = plan.megaLightsGrid != nil
        reservoirsWritten = plan.lightReuse
        if plan.accumulation != nil && !plan.accumFull && !plan.provisional { accumCount += 1 }
        if let pt = plan.pathTrace, !plan.provisional { pathTraceCount += pt.params.samples.y }
        if plan.fog != nil && plan.fogReference == nil {   // the froxel grid was written
            fogLastFrame = frameIndex
            fogLastFar = settings.fog.maxDistance
        }
        prevCamera = camera
        prevJitter = plan.jitter
        historyValid = plan.svgf || plan.neuralDenoise || (plan.accumulating && settings.denoiser.enabled)
        frameIndex &+= 1
    }

    // MARK: - Frame encoding

    /// The frame's encoder (ComputePass.swift) for the API in use.
    private func makeFrame(_ plan: FramePlan, profile: GPUProfiler.Frame?) -> FrameEncoder? {
        if builtAPI == .metal4, #available(macOS 26.0, *) {
            return metal4?.begin(slot: plan.slot, split: plan.splitPasses, overlap: plan.overlap)
        }
        return Metal3Frame(queue: queue, profile: profile, split: plan.splitPasses, overlap: plan.overlap)
    }

    /// The frame's compute stages by group, each group in the order it runs.
    private struct FrameStages {
        var lightGrid: [ComputeStage] = []           // 1a. the light grid, before everything that samples lights
        var head: [ComputeStage] = []                // 1b, 2. light maps, the trace
        var gi: [ComputeStage] = []                  // 2b. radiance cascades or ReSTIR GI (they write t.indirect)
        var restir: [ComputeStage] = []              // 2e. ReSTIR DI or MegaLights
        var reflections: [ComputeStage] = []         // 2d. after the GI (they read its result)
        var fog: [ComputeStage] = []                 // 3d. first of the stages below
        var denoise: [ComputeStage] = []             // 2c, 3. sampled direct light, the denoisers
        var reflectionDenoise: [ComputeStage] = []
    }

    /// What the composite reads. The stage builders fill it in as they decide where each signal ends up.
    private struct CompositeInputs {
        var uniforms: Uniforms            // the frame's, plus the flags that tell the composite how to read the rest
        var illumination: [MTLTexture]    // denoised light: one signal, or direct then indirect (the indirect is last)
        var specular: MTLTexture
        var meshDirect: MTLTexture
        var fogReference: MTLTexture?
    }

    /// The scene's structures for this frame, ahead of everything that traces rays.
    private func encodeSceneUpdate(slot: Int, lod: VGView, passes: FrameEncoder) {
        // Rigid bodies: the steps since last frame (or a replay from the start), then every body's instance record,
        // and Metal's descriptor, where they are now. Ahead of everything that reads the instances.
        // Cloths too: their vertices, from where the physics (or the CPU's) left them.
        var deformed = false
        if let physicsGPU, let enc = passes.compute("physics", serial: true) {
            if physicsGPU.simulates {
                let (steps, restart) = scene.takePhysicsSteps()
                if restart { physicsGPU.encodeReset(enc, pipelines: pipelines) }
                physicsGPU.encodeSteps(enc, pipelines: pipelines, steps: steps, slot: slot)
                let descriptors = builtRayTracer == .metal && !sceneBuffers.still ? instanceDescBuffers[slot] : nil
                physicsGPU.encodePose(enc, pipelines: pipelines, slot: slot, instances: instanceDataBuffers[slot], descriptors: descriptors,
                                      descriptorStride: instanceDescriptorStride)
            }
            physicsGPU.encodeClothMesh(enc, pipelines: pipelines, slot: slot, positions: positionBuffer, normals: normalBuffer)
            physicsGPU.encodeSoftMesh(enc, pipelines: pipelines, slot: slot, positions: positionBuffer, normals: normalBuffer)
            physicsGPU.encodeHairCurves(enc, pipelines: pipelines, slot: slot, positions: positionBuffer)
            deformed = physicsGPU.hasCloth || physicsGPU.hasSoftBodies || physicsGPU.hasHair
            passes.endCompute()
        }
        // 0. The crowd: this frame's poses and skinned vertices. Then the deforming meshes' (the pose slots', cloths')
        //    bottom-level structures around them (a refit: a pose keeps its triangles, so its tree keeps its shape).
        //    Ahead of the top level, which takes the new bounds.
        if let crowdSkinner, !CrowdSkinner.frozen {
            if let enc = passes.compute("skin", serial: true) {
                crowdSkinner.encode(enc, pose: pipelines[.crowdPose], skin: pipelines[.crowdSkin], slot: slot,
                                    positions: positionBuffer, normals: normalBuffer)
                passes.endCompute()
            }
            deformed = true
        }
        if deformed {
            if let primitiveRefit { passes.refitPrimitives(primitiveRefit, pass: "blas") }
            if let customRT, let enc = passes.compute("blas", serial: true) {
                customRT.encodeDeformRefit(enc, positions: positionBuffer, indices: indexBuffer, meshes: meshBuffer)
                passes.endCompute()
            }
        }
        // 1. Update the top-level acceleration structure with this frame's instance transforms. Metal: a refit (new bounds,
        //    same tree) costs a quarter of a rebuild, but the tree degrades as objects drift from where they were when
        //    it was built: in the old stress hall (400 moving objects) rays got 35% slower after 256 refits. A rebuild
        //    every 16 frames (per slot) traces as fast as one every frame, for the refit's median cost.
        //    A still scene's was built with its buffers, and stays.
        if builtRayTracer == .metal, !sceneBuffers.still {
            if Int(frameIndex) % Renderer.tlasRebuildInterval < Renderer.maxFramesInFlight { instanceASBuilt.remove(slot) }
            let refit = instanceASBuilt.contains(slot)
            passes.updateTLAS(TLASUpdate(structure: instanceAS[slot], scratch: instanceScratch[slot], refit: refit,
                                         instanceCount: scene.instances.count, usage: Renderer.tlasUsage,
                                         instances: instanceDescBuffers[slot], instanceStride: instanceDescriptorStride,
                                         primitives: primitiveAS), pass: "tlas")
            instanceASBuilt.insert(slot)
        }
        // Streamed textures: map and upload the levels last frame's hits asked for, ahead of this frame's work.
        if let textureStreamer {
            passes.streamTextures(textureStreamer, frame: frameIndex, slot: slot, framesInFlight: Renderer.maxFramesInFlight)
        }
        // Custom ray tracer: rebuild the moving instances' TLAS (a few small dispatches, in order).
        // Virtual geometry: this frame's level-of-detail cut and its cluster tree, in the same pass.
        if let customRT, let enc = passes.compute("tlas", serial: true) {
            customRT.encodeBuild(enc, slot: slot, instanceData: instanceDataBuffers[slot], view: lod, wind: windFrame)
            passes.endCompute()
        }
    }

    /// Encodes the stages: one after another, or with `plan.overlap` the cascades next to the denoisers.
    private func encode(_ s: FrameStages, plan: FramePlan, passes: FrameEncoder) {
        guard plan.overlap, let enc = passes.compute("trace") else {
            passes.run(s.lightGrid)
            passes.run(s.head)
            passes.run(s.gi)
            passes.run(s.restir)
            passes.run(s.reflections)
            passes.run(s.fog)
            passes.run(s.denoise)
            passes.run(s.reflectionDenoise)
            return
        }
        // The light grid first (the trace's bounces read it); light map, trace and cascade probes need only the
        // TLAS; then the cascade chain and the denoiser chain advance in lock-step, one barrier per step.
        // Reflections read the cascades' result: after both. ReSTIR leads the denoiser chain (after the fog).
        if !s.lightGrid.isEmpty {
            for stage in s.lightGrid { stage.encode(enc) }
            enc.memoryBarrier(scope: .buffers)
        }
        for stage in s.head + s.gi.prefix(1) { stage.encode(enc) }
        enc.memoryBarrier(scope: [.buffers, .textures])
        let gi = Array(s.gi.dropFirst()), chain = s.fog + s.restir + s.denoise
        for i in 0..<max(gi.count, chain.count) {
            if i < chain.count { chain[i].encode(enc) }
            if i < gi.count { gi[i].encode(enc) }
            enc.memoryBarrier(scope: [.buffers, .textures])
        }
        for stage in s.reflections + s.reflectionDenoise {
            stage.encode(enc)
            enc.memoryBarrier(scope: [.buffers, .textures])
        }
    }

    /// 3c-5. The geometry debug view, the composite and the upscale into the drawable (or the offscreen texture standing
    /// in for it). Returns it (nil if the surface had none of the right size) and how long the surface took to hand it out.
    private func encodeOutput(_ plan: FramePlan, composite c: CompositeInputs, targets t: RenderTargets, surface: RenderSurface,
                              passes: FrameEncoder) -> (output: FrameOutput?, wait: CFTimeInterval) {
        let size = plan.size, cur = plan.cur, overlap = plan.overlap
        // Reference "Path traced": the paths' mean, exposed and tone mapped into the drawable.
        if let pt = plan.pathTrace {
            let drawableStart = CACurrentMediaTime()
            var drawable = surface.nextOutput()
            let drawableWait = CACurrentMediaTime() - drawableStart
            if let d = drawable, d.texture.width != size.outWidth || d.texture.height != size.outHeight { drawable = nil }
            if let drawable, let enc = passes.compute("composite") {
                bind(enc, .tonemap, c.uniforms)
                setTextures(enc, [pt.accum, drawable.texture])
                dispatch(enc, .tonemap, width: size.outWidth, height: size.outHeight)
                passes.endCompute()
            }
            return (drawable, drawableWait)
        }
        // 3c. Geometry debug views: their own pass, only while one is shown.
        if RenderSettings.geometryViews.contains(settings.viewMode), let enc = passes.compute("geometry debug") {
            bind(enc, .geometryDebug, c.uniforms, sceneSlot: plan.slot)
            enc.setTexture(t.geometryDebug, index: 0)
            enc.setTexture(plan.raster?.targets.visibility, index: 1)   // (the raster's triangles, where it drew them)
            if let rs = plan.raster?.scene, rs.virtualClusters, let rc = rasterClusters { enc.useResources(rc.resources(slot: plan.slot), usage: .read) }
            dispatch(enc, .geometryDebug, width: size.width, height: size.height)
            if overlap { enc.memoryBarrier(scope: [.textures]) }   // concurrent encoder: before the composite reads it
        }

        // The visibility buffer's view: its own pass too (black with the primary visibility traced).
        if settings.viewMode == RenderSettings.visibilityBufferView, let enc = passes.compute("geometry debug") {
            bind(enc, .rasterDebug, c.uniforms)
            enc.setTexture(plan.raster?.targets.visibility, index: 0)
            enc.setBuffer(plan.raster?.targets.counters, offset: 0, index: 13)
            enc.setTexture(t.normalDepth[cur], index: 1)
            enc.setTexture(t.geometryDebug, index: 2)
            dispatch(enc, .rasterDebug, width: size.width, height: size.height)
            if overlap { enc.memoryBarrier(scope: [.textures]) }
        }

        // The virtual shadow maps' pages: their own pass too (black with shadow rays).
        if settings.viewMode == RenderSettings.shadowPagesView, let enc = passes.compute("geometry debug") {
            bind(enc, .vsmDebug, c.uniforms, sceneSlot: plan.slot)
            enc.setTexture(t.surfacePos, index: 0)
            enc.setTexture(t.normalDepth[cur], index: 1)
            enc.setTexture(t.geometryDebug, index: 2)
            dispatch(enc, .vsmDebug, width: size.width, height: size.height)
            if overlap { enc.memoryBarrier(scope: [.textures]) }
        }

        // Indirect light the composite adds when signals are separate: denoised, or raw (GI technique / GI off).
        let compositeIndirect = plan.accumulating || (plan.svgf && plan.separate && plan.denoiseIndirect)
            ? c.illumination.last! : t.indirect

        // 4. Composite: albedo * illumination + emission, tonemap, write to the drawable
        //    (or, with upscaling, to MetalFX's input color texture).
        let drawableStart = CACurrentMediaTime()
        var drawable = surface.nextOutput()
        let drawableWait = CACurrentMediaTime() - drawableStart
        // Right after a size change the view can still hand out a drawable of the old size: skip drawing this frame.
        if let d = drawable, d.texture.width != size.outWidth || d.texture.height != size.outHeight { drawable = nil }
        if let drawable, let enc = passes.compute("composite") {
            let output = size.upscaling || supersampling ? t.upscaleColor : plan.post?.color ?? drawable.texture
            var uniforms = c.uniforms
            if plan.post != nil && !size.upscaling { uniforms.flags |= UniformFlags.post }
            bind(enc, .composite, uniforms)
            setTextures(enc, [c.illumination[0], t.direct, t.indirect, t.albedo, t.emission, t.normalDepth[cur],
                              plan.shadowDenoiser ? t.shadow.meta[cur] : t.denoise[0].moments[cur], output, compositeIndirect,
                              t.giDebug, t.surfacePos, t.geoNormal, t.material, c.specular, t.geometryDebug, c.meshDirect,
                              plan.fog?.grid.integrated ?? dummy3D, c.fogReference ?? dummy2D, t.specularAlbedo, t.roughness,
                              plan.lumen ? lumen?.giRadiance ?? dummy2D : dummy2D])
            enc.setBuffer(lightBuffers[plan.slot], offset: 0, index: 1)
            var fp = plan.fogParams
            enc.setBytes(&fp, length: MemoryLayout<GPUFogParams>.stride, index: 2)
            dispatch(enc, .composite, width: output.width, height: output.height)
        }

        // 4b. Supersampled reference: average the composited frames (from halfway through, once lighting has converged).
        if let drawable, supersampling, !size.upscaling, let accum = colorAccumTexture(width: size.width, height: size.height),
           let enc = passes.compute("composite") {
            if overlap { enc.memoryBarrier(scope: .textures) }
            let half = UInt32((benchmark?.current.frames ?? 0) / 2)
            let averaged = plan.accumCount + (plan.accumulation != nil ? 1 : 0)   // with this frame
            var params = SIMD2<UInt32>(colorAccumCount, averaged > half ? 1 : 0)
            if params.y != 0 { colorAccumCount += 1 }
            enc.setComputePipelineState(pipelines[.accumulateColor])
            enc.setBytes(&params, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
            setTextures(enc, [t.upscaleColor, accum, drawable.texture])
            dispatch(enc, .accumulateColor, width: size.width, height: size.height)
        }

        // 5. Upscale: MetalFX's denoising scaler denoises the raw light as it upscales.
        passes.endCompute()
        if let drawable, let post = plan.post, !size.upscaling {
            encodePost(plan, post: post, input: post.color, normalDepth: t.normalDepth[cur], uniforms: c.uniforms,
                       output: drawable.texture, passes: passes)
        }
        if let drawable, let upscaler {
            passes.upscale(upscaler, UpscaleInputs(targets: t, normalDepth: t.normalDepth[cur], view: plan.view, jitter: plan.jitter,
                                                   reset: upscalerReset), pass: "upscale")
            upscalerReset = false
            // It leaves linear, unbounded light: the lens and the finish, or only the exposure and the tone curve, into
            // the drawable.
            if let post = plan.post {
                encodePost(plan, post: post, input: upscaler.hdrOutput, normalDepth: t.normalDepth[cur], uniforms: c.uniforms,
                           output: drawable.texture, passes: passes)
            } else if let enc = passes.compute("upscale") {
                bind(enc, .tonemap, c.uniforms)
                setTextures(enc, [upscaler.hdrOutput, drawable.texture])
                dispatch(enc, .tonemap, width: size.outWidth, height: size.outHeight)
                passes.endCompute()
            }
        }
        return (drawable, drawableWait)
    }

    /// 6. The lens and the finish (Shaders/Post.metal): `input`, the frame's linear light at the output size, through the
    /// depth of field and the glow, then exposed, tone mapped, vignetted and grained into `output`. In order, in one
    /// serial pass.
    private func encodePost(_ plan: FramePlan, post: PostTargets, input: MTLTexture, normalDepth: MTLTexture, uniforms: Uniforms,
                            output: MTLTexture, passes: FrameEncoder) {
        guard let enc = passes.compute("post", serial: true) else { return }
        var params = plan.postParams
        func start(_ kernel: Kernel) {
            bind(enc, kernel, uniforms)
            enc.setBytes(&params, length: MemoryLayout<GPUPostParams>.stride, index: 1)
            enc.setBuffer(post.focus, offset: 0, index: 2)
        }
        var light = input
        if params.lens.x > 0 {
            start(.focus)
            enc.setTexture(normalDepth, index: 0)
            dispatch(enc, .focus, width: 1, height: 1)
            start(.dof)
            setTextures(enc, [light, normalDepth, post.dof])
            dispatch(enc, .dof, width: post.width, height: post.height)
            light = post.dof
        }
        if params.bloom.x > 0, !post.down.isEmpty {
            for (i, level) in post.down.enumerated() {
                params.frame.y = UInt32(i)
                start(.bloomDown)
                setTextures(enc, [i == 0 ? light : post.down[i - 1], level])
                dispatch(enc, .bloomDown, width: level.width, height: level.height)
            }
            for i in post.up.indices.reversed() {
                start(.bloomUp)
                setTextures(enc, [i == post.up.count - 1 ? post.down[i + 1] : post.up[i + 1], post.down[i], post.up[i]])
                dispatch(enc, .bloomUp, width: post.up[i].width, height: post.up[i].height)
            }
        }
        start(.finish)
        setTextures(enc, [light, post.up.first ?? post.down.first ?? light, output])
        dispatch(enc, .finish, width: output.width, height: output.height)
        passes.endCompute()
    }

    /// Presents the drawable and commits the frame; its completion handler frees the frame slot and reports the timings.
    /// `encodeStart`: when the CPU started on this frame, not counting its waits.
    private func commit(_ plan: FramePlan, passes: FrameEncoder, profile: GPUProfiler.Frame?, output: FrameOutput?,
                        encodeStart: CFTimeInterval) {
        let slot = plan.slot
        var writeCapture: (() -> Void)?
        if let benchmark, benchmark.shouldCapture, let vg = customRT?.virtualGeometry { print("  " + vg.summary) }
        if let benchmark, benchmark.shouldCapture, let v = sceneBuffers.voxelLOD, !voxelLevels.running {
            print(String(format: "  Voxel levels: last rebuild picked in %.2f ms, built in %.2f ms, %d instances changed",
                         v.last.pickMs, v.last.buildMs, v.last.changed)
                  + (Renderer.voxelAsync ? ", \(voxelLevels.swaps) background rebuilds swapped in" : ""))
        }
        if let benchmark, benchmark.shouldCapture, let vg = customRT?.virtualBLAS { print("  " + vg.summary) }
        if let benchmark, benchmark.shouldCapture, plan.raster != nil || plan.vsm != nil, let rc = rasterClusters { print("  " + rc.summary) }
        if let benchmark, benchmark.shouldCapture, let ts = textureStreamer {
            print("  " + ts.summary)
            if ProcessInfo.processInfo.environment["METALRENDERER_TEXTURE_DEBUG"] != nil { print(ts.details) }
        }
        if let benchmark, benchmark.shouldCapture, !streaming.preparedMs.isEmpty, !streaming.installedMs.isEmpty {
            print("  " + streaming.summary(sceneBuffers))
        }
        if let benchmark, benchmark.isMeasuring, CustomRayTracer.statsEnabled, let customRT {
            // One frame's counters: reset at the first measured frame, read at the capture frame (single-frame runs).
            if benchmark.shouldCapture { print("  " + customRT.takeStats().description) } else { _ = customRT.takeStats() }
        }
        if let benchmark, let output, benchmark.shouldCapture || benchmark.shouldRecord,
           let capture = benchmark.capture(of: output.texture, device: device, sequence: !benchmark.shouldCapture) {
            passes.capture(output.texture, into: capture.buffer)
            writeCapture = capture.write
        }
        let checkCrowd = benchmark?.shouldCapture == true && CrowdSkinner.checked && !CrowdSkinner.frozen
        let semaphore = frameSemaphore
        let bench = benchmark, benchConfig = benchmark?.configIndex ?? 0
        let recordFrame = benchmark?.isMeasuring ?? false
        let vg = customRT?.virtualGeometry, vgFrame = frameIndex, streamer = textureStreamer
        // The clusters' counters and requests are this frame's only from what drew them.
        let vgCamera = plan.raster?.scene.virtualClusters == true, vgShadows = plan.vsm != nil && settings.vsm.clusters
        let rasterVG = vgCamera || vgShadows ? rasterClusters : nil
        let cpuInterval = frameIntervalMs
        let encodeNow = (CACurrentMediaTime() - encodeStart) * 1000
        encodeSum += encodeNow
        encodeCount += 1
        // Benchmark: finish this frame before encoding the next (`wait`), so passes from consecutive frames
        // never overlap on the GPU and inflate each other's timings.
        passes.commit(presenting: output?.drawable, wait: benchmark != nil) { [weak self] frame in
            if !Benchmark.isEnabled {
                vg?.collect(slot: slot, frame: vgFrame)
                rasterVG?.collect(slot: slot, frame: vgFrame, camera: vgCamera, shadows: vgShadows)
                streamer?.collect(slot: slot)
            }
            if let bench, recordFrame {
                var passMs: [String: Double] = [:]
                var start = Double.infinity, end = 0.0
                for p in frame.passes {
                    passMs[p.name, default: 0] += (p.end - p.start) * 1000   // a name can recur
                    start = min(start, p.start)
                    end = max(end, p.end)
                }
                if frame.passes.isEmpty {   // METALRENDERER_BENCH_SPLIT=0: the whole frame is one command buffer, as in normal mode
                    passMs["frame"] = (frame.end - frame.start) * 1000
                    start = frame.start
                    end = frame.end
                }
                bench.record(.init(config: benchConfig, passMs: passMs, spanMs: (end - start) * 1000, cpuMs: encodeNow))
            }
            writeCapture?()
            let times = profile?.resolve()
            semaphore.signal()
            let ms = (frame.end - frame.start) * 1000
            self?.perform { r in
                if !r.firstFrameDrawn {
                    r.firstFrameDrawn = true
                    DispatchQueue.main.async { Launch.firstFrame() }
                    r.onFirstFrame?()
                }
                r.gpuMs = ms
                if r.debugActive { r.onFrameTime?(cpuInterval, ms) }
                if let times { r.addPassTimes(times, frameMs: ms) }
            }
        }
        sceneDeclaredIn = nil
        if benchmark != nil {
            vg?.collect(slot: slot, frame: vgFrame)   // here, not in the handler: the next frame must see the requests
            rasterVG?.collect(slot: slot, frame: vgFrame, camera: vgCamera, shadows: vgShadows)
            streamer?.collect(slot: slot)
        }
        if checkCrowd, let crowdSkinner {   // the frame is done (benchmarks wait for it)
            let skin = crowdSkinner.check(positions: positionBuffer, normals: normalBuffer)
            var line = String(format: "  Crowd check: %d poses, GPU against CPU: positions within %.2g m, normals within %.2g",
                              crowdSkinner.crowd.slots.count, skin.position, skin.normal)
            if let customRT {
                let wrong = customRT.checkCrowdRefit(scene: scene, positions: positionBuffer)
                line += ", refitted trees: \(wrong.triangles) wrong triangles, \(wrong.boxes) wrong boxes, \(wrong.bounds) wrong bounds"
            }
            print(line)
        }
    }

    // MARK: - Frame stages

    /// Starts a kernel's dispatch: its pipeline, the uniforms, and for kernels that trace rays the scene.
    /// `pass`: the kernel's own flags, for the kernels with variants (Kernel.fixedPassFlags).
    private func bind(_ enc: ComputePass, _ kernel: Kernel, _ uniforms: Uniforms, pass: UInt32 = 0, sceneSlot: Int? = nil) {
        var u = uniforms
        // While the blue-noise tile is on its way (a first launch), the general pipelines: a variant for the flags
        // of those few frames would be compiled for nothing.
        let awaitingNoise = settings.blueNoise && !blueNoiseReady
        enc.setComputePipelineState(awaitingNoise ? pipelines[kernel]
                                                  : pipelines.state(kernel, flags: u.flags, pass: pass, wait: benchmark != nil))
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        if let sceneSlot { bindScene(enc, slot: sceneSlot) }
    }

    /// 1a. The light grid's build. It reads only the light and instance buffers, which the CPU wrote.
    private func lightGridStages(_ plan: FramePlan) -> [ComputeStage] {
        guard let grid = plan.lightGrid else { return [] }
        let uniforms = plan.uniforms, slot = plan.slot
        return [ComputeStage(pass: "regir") { [self] enc in
            bind(enc, .regirBuild, uniforms, sceneSlot: slot)
            dispatch(enc, .regirBuild, width: grid.buffer.length / MemoryLayout<GPURegirReservoir>.stride, height: 1)
        }]
    }

    /// 1b. Light-visibility maps. 2. Ray trace: primary visibility (G-buffer), direct light with shadow rays,
    /// path-traced indirect light.
    private func headStages(_ plan: FramePlan, targets t: RenderTargets) -> [ComputeStage] {
        let uniforms = plan.uniforms, slot = plan.slot, cur = plan.cur, size = plan.size, raster = plan.raster
        var stages: [ComputeStage] = []
        if plan.lightMaps {
            stages.append(ComputeStage(pass: "lightmap") { [self] enc in
                bind(enc, .lightMap, uniforms, sceneSlot: slot)
                enc.setTexture(lightMap, index: 0)
                enc.dispatchThreads(MTLSize(width: lightMap.width, height: lightMap.height, depth: scene.lights.count),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            })
        }
        stages.append(ComputeStage(pass: "trace") { [self] enc in
            bind(enc, .trace, uniforms, pass: uniforms.tracePassFlags, sceneSlot: slot)
            setTextures(enc, [t.normalDepth[cur], t.albedo, t.emission, t.motion, t.direct, t.indirect,
                              t.deviceDepth, t.pixelMotion, blueNoiseTexture, t.surfacePos, t.geoNormal, lightMap,
                              t.visibility, t.blocker, t.material])
            if let raster {
                enc.setTexture(raster.targets.visibility, index: 15)
                enc.setBuffer(raster.targets.counters, offset: 0, index: 13)
            }
            dispatch(enc, .trace, width: size.width, height: size.height)
        })
        if plan.glass {
            stages.append(ComputeStage(pass: "glass") { [self] enc in
                bind(enc, .glass, uniforms, sceneSlot: slot)
                setTextures(enc, [t.normalDepth[cur], t.albedo, t.emission, t.material, blueNoiseTexture])
                dispatch(enc, .glass, width: size.width, height: size.height)
            })
        }
        return stages
    }

    /// 2b. The GI technique, if one runs: it writes t.indirect (the path tracer already did, inside traceKernel), after
    /// the trace (its G-buffer) and before the reflections (they read it).
    private func giStages(_ plan: FramePlan, targets t: RenderTargets) -> [ComputeStage] {
        if plan.cascades { return radianceCascadeStages(plan, targets: t) }
        if plan.lumen { return lumenStages(plan, targets: t) }
        if let grid = plan.restirGIGrid { return restirGIStages(plan, grid: grid, targets: t) }
        return []
    }

    /// 2d. Reflections (glTF specular materials): after the GI (they read its result), before the denoisers. The second
    /// group is their own denoiser.
    private func reflectionStages(_ plan: FramePlan, targets t: RenderTargets,
                                  composite: inout CompositeInputs) -> (trace: [ComputeStage], denoise: [ComputeStage]) {
        guard plan.specular else { return ([], []) }
        let uniforms = plan.uniforms, slot = plan.slot, cur = plan.cur, prev = plan.prev, size = plan.size
        let fogParams = plan.fogParams, fogNoise = plan.fog?.noise, restirSpecular = plan.restirGrid?.specular ?? plan.megaLightsGrid?.specular
        let trace = [ComputeStage(pass: "reflections") { [self] enc in
            bind(enc, .reflection, uniforms, pass: fogParams.reflectionPassFlags, sceneSlot: slot)
            var fp = fogParams
            enc.setBytes(&fp, length: MemoryLayout<GPUFogParams>.stride, index: 9)
            setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, t.material, blueNoiseTexture, t.indirect, t.specular,
                              fogNoise ?? dummy3D, restirSpecular ?? dummy2D])
            dispatch(enc, .reflection, width: size.width, height: size.height)
        }]
        guard plan.svgf else { return (trace, []) }
        let d = t.denoise[2]
        var denoise = [ComputeStage(pass: "reflections") { [self] enc in
            var inputCount: UInt32 = 1
            bind(enc, .temporal, uniforms)
            enc.setBytes(&inputCount, length: MemoryLayout<UInt32>.stride, index: 1)
            setTextures(enc, [t.specular, t.specular, t.motion, t.normalDepth[cur], t.normalDepth[prev],
                              d.history, d.moments[prev], d.pingA, d.moments[cur]])
            dispatch(enc, .temporal, width: size.width, height: size.height)
        }]
        for i in 0..<2 {
            let pass = d.atrousPass(i)
            denoise.append(ComputeStage(pass: "reflections") { [self] enc in
                var step = Int32(1 << i)
                bind(enc, .atrous, uniforms)
                enc.setBytes(&step, length: MemoryLayout<Int32>.stride, index: 1)
                setTextures(enc, [pass.src, t.normalDepth[cur], pass.dst])
                dispatch(enc, .atrous, width: size.width, height: size.height)
            })
        }
        composite.specular = d.pingB
        return (trace, denoise)
    }

    /// 2e. ReSTIR DI: after the trace (its G-buffer), before the reflections (they add its direct specular) and the
    /// denoiser.
    private func restirStages(_ plan: FramePlan, targets t: RenderTargets) -> [ComputeStage] {
        guard let rg = plan.restirGrid else { return [] }
        let uniforms = plan.uniforms, slot = plan.slot, cur = plan.cur, prev = plan.prev, size = plan.size
        let r = plan.restirSettings
        let temporalValid = r.temporal && plan.restirHistory   // (not the denoiser's history: that follows the denoiser)
        var flags: UInt32 = (temporalValid ? GPURestirParams.temporalValid : 0) | (r.visibilityReuse ? GPURestirParams.visibilityReuse : 0)
            | (plan.restirSplit ? GPURestirParams.split : 0)
        let maxM = UInt32(RestirSettings.maxMRange.clamp(r.maxM))
        let samples = UInt32(RestirSettings.spatialSampleRange.clamp(r.spatialSamples))
        let radius = RestirSettings.radiusRange.clamp(r.radius) * Float(size.width) / 960
        let clamp: Float = plan.accumulating ? 0 : 4 * 10   // 4 x the firefly clamp, as the mesh-light pass
        let candidates = RestirSettings.candidateRange.clamp(r.candidates)
        let params = GPURestirParams(config: SIMD4(UInt32(candidates), maxM, flags, samples),
                                     tuning: SIMD4(radius, 0, clamp, Float(rg.chains)))
        // Last frame's lights, for the temporal reuse: what the frame before wrote into its slot (the GPU reads that
        // buffer for two more frames before the CPU comes back to it). This frame's on a scene's first frame.
        let previousSlot = (slot + Renderer.maxFramesInFlight - 1) % Renderer.maxFramesInFlight
        let previousLights = lightBuffers[frameDataWritten[previousSlot] ? previousSlot : slot]
        var stages = [ComputeStage(pass: "restir") { [self] enc in
            var p = params
            bind(enc, .restirTemporal, uniforms, pass: p.config.z, sceneSlot: slot)
            enc.setBytes(&p, length: MemoryLayout<GPURestirParams>.stride, index: 9)
            enc.setBuffer(previousLights, offset: 0, index: 10)
            setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, t.albedo, t.material, t.motion, t.normalDepth[prev],
                              rg.reservoir[prev], rg.temporal])
            dispatch(enc, .restirTemporal, width: size.width, height: size.height)
        }]
        let passes = RestirSettings.spatialPassRange.clamp(r.spatialPasses)
        flags &= ~GPURestirParams.temporalValid
        for i in 0..<max(passes, 1) {
            let last = i == max(passes, 1) - 1
            let src = i == 0 ? rg.temporal : rg.spatial, dst = last ? rg.reservoir[cur] : rg.spatial
            var p = params
            p.config.z = flags | (last ? GPURestirParams.shade : 0)
            p.config.w = passes == 0 ? 0 : samples
            p.tuning.y = Float(i)
            stages.append(ComputeStage(pass: "restir") { [self] enc in
                var p = p
                bind(enc, .restirSpatial, uniforms, pass: p.config.z, sceneSlot: slot)
                enc.setBytes(&p, length: MemoryLayout<GPURestirParams>.stride, index: 9)
                setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, t.albedo, t.material, src, dst, t.direct, rg.specular,
                                  t.visibility, t.blocker])
                dispatch(enc, .restirSpatial, width: size.width, height: size.height)
            })
        }
        return stages
    }

    /// 2e. MegaLights: after the trace (its G-buffer), before the reflections (they add its direct specular) and the
    /// denoiser. The tiles' light lists, then each pixel's samples, shaded.
    private func megaLightsStages(_ plan: FramePlan, targets t: RenderTargets) -> [ComputeStage] {
        guard let mg = plan.megaLightsGrid else { return [] }
        let uniforms = plan.uniforms, slot = plan.slot, cur = plan.cur, prev = plan.prev, size = plan.size
        let m = plan.megaLightsSettings
        let flags: UInt32 = (m.guiding && plan.megaLightsHistory ? GPUMegaLightsParams.guideValid : 0)
            | (m.partition ? GPUMegaLightsParams.partition : 0)
        // The firefly clamp at 4 x the built-in one, as ReSTIR's; none for references.
        let clamp: Float = plan.accumulating ? 0 : 4 * 10
        // The cutoff is of exposed light: what it changes on screen doesn't depend on the scene's brightness.
        let cutoff = MegaLightsSettings.cutoffRange.clamp(m.cutoff) / max(uniforms.post.x, 1e-6)
        let samples = MegaLightsSettings.sampleRange.clamp(m.samples)
        let treeSamples = min(MegaLightsSettings.treeSampleRange.clamp(m.treeSamples), samples)
        let tree = plan.lightTree
        let params = GPUMegaLightsParams(config: SIMD4(UInt32(samples - treeSamples), UInt32(mg.capacity), flags, UInt32(mg.tilesX)),
                                         tree: SIMD4(UInt32(treeSamples), UInt32(tree?.nodes ?? 0), 0, 0),
                                         tuning: SIMD4(cutoff, MegaLightsSettings.guideWeightRange.clamp(m.guideWeight), clamp, 0))
        let guide = mg.guide[cur], prevGuide = mg.guide[prev]
        return [ComputeStage(pass: "megalights") { [self] enc in
            var p = params
            bind(enc, .megaLightsCull, uniforms, sceneSlot: slot)
            enc.setBytes(&p, length: MemoryLayout<GPUMegaLightsParams>.stride, index: 9)
            enc.setBuffer(mg.lists, offset: 0, index: 10)
            enc.setBuffer(guide, offset: 0, index: 13)
            setTextures(enc, [t.surfacePos, t.normalDepth[cur]])
            dispatch(enc, .megaLightsCull, width: mg.tilesX * GPUMegaLightsParams.tile, height: mg.tilesY * GPUMegaLightsParams.tile)
        }, ComputeStage(pass: "megalights") { [self] enc in
            var p = params
            bind(enc, .megaLightsSample, uniforms, pass: p.config.z, sceneSlot: slot)
            enc.setBytes(&p, length: MemoryLayout<GPUMegaLightsParams>.stride, index: 9)
            enc.setBuffer(mg.lists, offset: 0, index: 10)
            enc.setBuffer(guide, offset: 0, index: 13)
            enc.setBuffer(prevGuide, offset: 0, index: 14)
            enc.setBuffer(tree?.buffer ?? prevGuide, offset: 0, index: 15)   // (no tree: no lights but suns, not read)
            setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, t.albedo, t.material, t.direct, mg.specular])
            dispatch(enc, .megaLightsSample, width: size.width, height: size.height)
        }]
    }

    /// 2c. Direct light that is sampled per pixel: one light per group with more than 4 lights (manyLightsKernel), and
    /// the emissive-mesh lights. After the trace and before anything that reads direct light or visibility.
    private func sampledLightStages(_ plan: FramePlan, targets t: RenderTargets) -> [ComputeStage] {
        let uniforms = plan.uniforms, slot = plan.slot, cur = plan.cur, prev = plan.prev, size = plan.size
        var stages: [ComputeStage] = []
        if plan.manyLights {
            let reuse = plan.lightReuse
            let config = SIMD4<UInt32>(UInt32(settings.manyLightRays), UInt32(max(settings.manyLightReuse, 0)),
                                       plan.lightPicksValid ? 1 : 0, 0)
            stages.append(ComputeStage(pass: "many lights") { [self] enc in
                var config = config
                bind(enc, reuse ? .manyLightsReuse : .manyLights, uniforms, sceneSlot: slot)
                enc.setBytes(&config, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 9)
                setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, blueNoiseTexture, t.direct, t.visibility, t.blocker,
                                  t.motion, t.normalDepth[prev], t.shadow.reservoir[prev], t.shadow.reservoirWeight[prev],
                                  t.shadow.reservoir[cur], t.shadow.reservoirWeight[cur], t.albedo])
                dispatch(enc, .manyLights, width: size.width, height: size.height)
            })
        }
        if plan.meshLights {
            let shadowDenoiser = plan.shadowDenoiser
            stages.append(ComputeStage(pass: "mesh lights") { [self] enc in
                var addToDirect: UInt32 = shadowDenoiser ? 0 : 1
                bind(enc, .meshLights, uniforms, sceneSlot: slot)
                enc.setBytes(&addToDirect, length: MemoryLayout<UInt32>.stride, index: 9)
                setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, blueNoiseTexture, t.direct, t.meshDirect, t.albedo])
                dispatch(enc, .meshLights, width: size.width, height: size.height)
            })
        }
        return stages
    }

    /// 3b. The shadow denoiser: direct light's per-group visibility through its own temporal and spatial filter.
    private func shadowDenoiseStages(_ plan: FramePlan, targets t: RenderTargets, composite: inout CompositeInputs) -> [ComputeStage] {
        guard plan.shadowDenoiser else { return [] }
        let uniforms = plan.uniforms, cur = plan.cur, prev = plan.prev, size = plan.size
        let d = settings.denoiser, s = t.shadow
        let maxHistory = DenoiserSettings.maxHistoryRange.clamp(d.shadowHistory)
        var stages = [ComputeStage(pass: "shadow temporal") { [self] enc in
            var params = SIMD4<Float>(maxHistory, d.shadowClamp, d.shadowSigma, 0)
            bind(enc, .shadowTemporal, uniforms)
            enc.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            setTextures(enc, [t.visibility, t.blocker, t.motion, t.normalDepth[cur], t.normalDepth[prev], s.history,
                              s.meta[prev], s.pingA, s.meta[cur], s.penumbra, s.tiles])
            // Whole 8x8 threadgroups: each one classifies its tile.
            enc.dispatchThreadgroups(MTLSize(width: (size.width + 7) / 8, height: (size.height + 7) / 8, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        }]
        // Pass 0 writes `history`, which feeds next frame's temporal pass (as in SVGF).
        let chain: [(src: MTLTexture, dst: MTLTexture)] = [(s.pingA, s.history), (s.history, s.pingB), (s.pingB, s.pingA),
                                                           (s.pingA, s.pingB), (s.pingB, s.pingA)]
        let passes = DenoiserSettings.passRange.clamp(d.shadowPasses)
        for (i, pass) in chain.prefix(passes).enumerated() {
            stages.append(ComputeStage(pass: "shadow filter") { [self] enc in
                var params = SIMD4<Float>(maxHistory, d.shadowClamp, d.shadowSigma, Float(1 << i))
                bind(enc, .shadowFilter, uniforms)
                enc.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                setTextures(enc, [pass.src, t.normalDepth[cur], s.penumbra, s.meta[cur], s.tiles, pass.dst])
                dispatch(enc, .shadowFilter, width: size.width, height: size.height)
            })
        }
        composite.illumination = [chain[passes - 1].dst]
        composite.uniforms.flags |= UniformFlags.shadowDenoiser | UniformFlags.separateSignals
        return stages
    }

    /// Reference "Path traced": this frame's paths join the running mean (Shaders/PathTrace.metal), which encodeOutput
    /// tone maps. Nothing to add once it has max samples.
    private func pathTraceStages(_ plan: FramePlan) -> [ComputeStage] {
        guard let pt = plan.pathTrace, pt.params.samples.y > 0 else { return [] }
        let uniforms = plan.uniforms, size = plan.size, slot = plan.slot
        return [ComputeStage(pass: "path trace") { [self] enc in
            var params = pt.params, fog = pt.fog
            bind(enc, .pathTrace, uniforms, sceneSlot: slot)
            enc.setBytes(&fog, length: MemoryLayout<GPUFogParams>.stride, index: 9)
            enc.setBytes(&params, length: MemoryLayout<GPUPathTraceParams>.stride, index: 13)
            enc.setBuffer(lightProxies ?? lightBuffers[slot], offset: 0, index: 14)
            enc.setBuffer(pt.lightTree ?? lightBuffers[slot], offset: 0, index: 15)   // (unread without the tree)
            setTextures(enc, [pt.accum, pt.fogNoise ?? dummy3D])
            dispatch(enc, .pathTrace, width: size.width, height: size.height)
        }]
    }

    /// Benchmark references: this frame's raw light joins the average, which the composite shows.
    private func accumulateStages(_ plan: FramePlan, targets t: RenderTargets, composite: inout CompositeInputs) -> [ComputeStage] {
        guard let accum = plan.accumulation else { return [] }
        let uniforms = plan.uniforms, size = plan.size, averaged = plan.accumCount
        composite.illumination = [accum.direct, accum.indirect]
        composite.specular = accum.specular
        // Tells the composite pass to read the illumination as separate direct + indirect light.
        composite.uniforms.flags |= UniformFlags.denoise | UniformFlags.separateSignals
        if plan.accumFull { return [] }   // Reference's max samples: the average as it is
        return [ComputeStage(pass: "accumulate") { [self] enc in
            var count = averaged
            bind(enc, .accumulate, uniforms)
            enc.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 1)
            setTextures(enc, [t.direct, t.indirect, accum.direct, accum.indirect, t.specular, accum.specular])
            dispatch(enc, .accumulate, width: size.width, height: size.height)
        }]
    }

    /// A signal SVGF filters: its noisy input (two are summed), its history and ping-pong textures, how many a-trous
    /// passes it gets and the uniforms that carry its filter settings.
    private struct DenoiseSignal {
        let noisy: [MTLTexture]
        let targets: DenoiseTargets
        let passes: Int
        let uniforms: Uniforms
    }

    /// The signals SVGF filters this frame, in the order the composite's illumination lists them.
    private func denoiseSignals(_ plan: FramePlan, targets t: RenderTargets) -> [DenoiseSignal] {
        // ReSTIR's direct light: its own edge-stopping, and its variance scaled up (reused samples are correlated).
        var restirUniforms = plan.uniforms
        restirUniforms.denoise.x = DenoiserSettings.luminanceSigmaRange.clamp(settings.restir.denoiseSigma)
        restirUniforms.denoise.w = max(settings.restir.varianceBoost, 1)
        restirUniforms.denoise.y = DenoiserSettings.maxHistoryRange.clamp(settings.restir.denoiseHistory)
        // MegaLights' direct light: the same, with its own settings.
        let ml = settings.megaLights
        var megaLightsUniforms = plan.uniforms
        megaLightsUniforms.denoise.x = DenoiserSettings.luminanceSigmaRange.clamp(ml.denoiseSigma)
        megaLightsUniforms.denoise.w = max(ml.varianceBoost, 1)
        megaLightsUniforms.denoise.y = DenoiserSettings.maxHistoryRange.clamp(ml.denoiseHistory)
        // ReSTIR GI's indirect light: the same, with its own settings.
        let rgi = settings.restirGI
        var restirGIUniforms = plan.uniforms
        restirGIUniforms.denoise.x = DenoiserSettings.luminanceSigmaRange.clamp(rgi.denoiseSigma)
        restirGIUniforms.denoise.w = max(rgi.varianceBoost, 1)
        restirGIUniforms.denoise.y = DenoiserSettings.maxHistoryRange.clamp(rgi.denoiseHistory)
        restirGIUniforms.denoise.z = DenoiserSettings.antiLagRange.clamp(rgi.antiLag)
        func signal(_ noisy: [MTLTexture], _ d: DenoiseTargets, _ passes: Int) -> DenoiseSignal {
            let restirs = plan.restir && d === (plan.restirSplit ? t.denoise[3] : t.denoise[0])
            let uniforms = plan.restirGI && d === t.denoise[1] ? restirGIUniforms : restirs ? restirUniforms
                : plan.megaLights && d === t.denoise[0] ? megaLightsUniforms : plan.uniforms
            return DenoiseSignal(noisy: noisy, targets: d, passes: passes, uniforms: uniforms)
        }
        var signals: [DenoiseSignal] = []
        // First, so the indirect light stays last: ReSTIR's unshadowed light (no edges to keep), or the mesh lights'.
        if plan.restirSplit { signals.append(signal([t.direct], t.denoise[3], plan.directPasses)) }
        if plan.denoiseMeshLights { signals.append(signal([t.meshDirect], t.denoise[3], settings.denoiser.passes(for: .pathTraced))) }
        if !plan.shadowDenoiser {
            signals.append(signal(plan.separate ? [t.direct] : [t.direct, t.indirect], t.denoise[0], plan.directPasses))
        }
        if plan.separate && plan.denoiseIndirect { signals.append(signal([t.indirect], t.denoise[1], plan.indirectPasses)) }
        return signals
    }

    /// 3. SVGF: one temporal pass and up to five a-trous passes over every signal.
    private func svgfStages(_ plan: FramePlan, targets t: RenderTargets, composite: inout CompositeInputs) -> [ComputeStage] {
        guard plan.svgf else { return [] }
        let signals = denoiseSignals(plan, targets: t)
        guard !signals.isEmpty else { return [] }
        let cur = plan.cur, prev = plan.prev, size = plan.size
        var stages = [ComputeStage(pass: "temporal") { [self] enc in
            for s in signals {
                let d = s.targets
                var inputCount = UInt32(s.noisy.count)
                bind(enc, .temporal, s.uniforms)
                enc.setBytes(&inputCount, length: MemoryLayout<UInt32>.stride, index: 1)
                setTextures(enc, [s.noisy[0], s.noisy.last!, t.motion, t.normalDepth[cur], t.normalDepth[prev],
                                  d.history, d.moments[prev], d.pingA, d.moments[cur]])
                dispatch(enc, .temporal, width: size.width, height: size.height)
            }
        }]
        for i in 0..<(signals.map(\.passes).max() ?? 0) {
            stages.append(ComputeStage(pass: "atrous") { [self] enc in
                var step = Int32(1 << i)
                for s in signals where i < s.passes {
                    let pass = s.targets.atrousPass(i)
                    bind(enc, .atrous, s.uniforms)
                    enc.setBytes(&step, length: MemoryLayout<Int32>.stride, index: 1)
                    setTextures(enc, [pass.src, t.normalDepth[cur], pass.dst])
                    dispatch(enc, .atrous, width: size.width, height: size.height)
                }
            })
        }
        composite.illumination = (plan.shadowDenoiser ? composite.illumination : [])
            + signals.map { $0.targets.atrousPass($0.passes - 1).dst }
        if plan.denoiseMeshLights {
            composite.meshDirect = composite.illumination[1]
            composite.uniforms.flags |= UniformFlags.meshLights
        }
        if plan.restirSplit { composite.meshDirect = composite.illumination[1] }
        if plan.separate { composite.uniforms.flags |= UniformFlags.separateSignals }
        return stages
    }

    /// 3d. Volumetric fog: light the froxel grid in front of the surfaces and integrate it (or, for references, march
    /// every camera ray). It needs the TLAS, the lights and the G-buffer's depth.
    private func fogStages(_ plan: FramePlan, targets t: RenderTargets, composite: inout CompositeInputs) -> [ComputeStage] {
        guard let (g, noise) = plan.fog else { return [] }
        let uniforms = plan.uniforms, slot = plan.slot, cur = plan.cur, prev = plan.prev, size = plan.size
        let fogParams = plan.fogParams, samples = plan.fogSamples
        if let ref = plan.fogReference {
            composite.fogReference = ref
            composite.uniforms.flags |= UniformFlags.fog | UniformFlags.fogReference
            if plan.accumFull { return [] }   // Reference's max samples: the march's average as it is
            return [ComputeStage(pass: "fog") { [self] enc in
                var fp = fogParams, count = samples
                bind(enc, .fogReference, uniforms, sceneSlot: slot)
                enc.setBytes(&fp, length: MemoryLayout<GPUFogParams>.stride, index: 9)
                enc.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 10)
                setTextures(enc, [noise, t.normalDepth[cur], ref])
                dispatch(enc, .fogReference, width: size.width, height: size.height)
            }]
        }
        composite.uniforms.flags |= UniformFlags.fog
        return [
            ComputeStage(pass: "fog") { [self] enc in
                var fp = fogParams
                bind(enc, .fogInject, uniforms, sceneSlot: slot)
                enc.setBytes(&fp, length: MemoryLayout<GPUFogParams>.stride, index: 9)
                setTextures(enc, [blueNoiseTexture, noise, g.scatter[prev], g.scatter[cur], t.normalDepth[cur]])
                enc.dispatchThreads(MTLSize(width: g.columns, height: g.rows, depth: g.slices),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            },
            ComputeStage(pass: "fog") { [self] enc in
                var fp = fogParams
                bind(enc, .fogIntegrate, uniforms)
                enc.setBytes(&fp, length: MemoryLayout<GPUFogParams>.stride, index: 9)
                setTextures(enc, [g.scatter[cur], g.integrated])
                dispatch(enc, .fogIntegrate, width: g.columns, height: g.rows)
            },
        ]
    }

    // MARK: - GI techniques

    /// Scene buffers at the indices every ray-tracing kernel uses (1 = TLAS, 2...8 = geometry, instances, lights).
    private func bindScene(_ enc: ComputePass, slot: Int) {
        // What the scene's argument buffers point at is declared once per encoder (it holds for every dispatch in
        // it, and the frame's stages mostly share one); the bindings are set every time, since the kernels in
        // between use the same indices for their own buffers.
        let declare = sceneDeclaredIn !== enc.declarationScope
        if let customRT {
            customRT.bind(enc, slot: slot, declare: declare)
        } else {
            enc.setAccelerationStructure(instanceAS[slot], bufferIndex: 1)
            if declare { enc.useResources(primitiveASResources, usage: .read) }   // BLASes referenced indirectly by the TLAS
        }
        enc.setBuffer(positionBuffer, offset: 0, index: 2)
        enc.setBuffer(normalBuffer, offset: 0, index: 3)
        enc.setBuffer(indexBuffer, offset: 0, index: 4)
        enc.setBuffer(meshBuffer, offset: 0, index: 5)
        // (Metal's tracer in a scene with blocks of instances: the table a hit finds a record through, the scene's
        // own records being its first.)
        enc.setBuffer(sceneBuffers.instanceTable ?? instanceDataBuffers[slot], offset: 0, index: 6)
        enc.setBuffer(shadingArgs[slot], offset: 0, index: 7)
        var gp = regirParams   // the light grid (ReGIR): ReSTIR DI's, GI's, the reflections' and the fog's candidates
        enc.setBuffer(regirBuffer ?? regirGrid(count: 1), offset: 0, index: 11)
        enc.setBytes(&gp, length: MemoryLayout<GPURegirParams>.stride, index: 12)
        enc.setBuffer(lightBuffers[slot], offset: 0, index: 8)
        guard declare else { return }
        sceneDeclaredIn = enc.declarationScope
        enc.useResources(shadingResources, usage: .read)
        enc.useResources([skyActive ? skyMap ?? dummyArray : dummyArray, skyActive ? cloudShadowMap ?? dummy2D : dummy2D], usage: .read)
        if let vsm = vsmFrame {
            enc.useResources([vsm.pool, vsm.table, vsm.tags, vsm.lightTable, vsm.views[slot], vsm.sceneArgs[slot]], usage: .read)
            enc.useResource(vsm.requests, usage: [.read, .write])
        }
        if let textureStreamer {
            enc.useHeap(textureStreamer.heap)
            enc.useResource(textureStreamer.minLodBuffer(slot: slot), usage: .read)
            enc.useResource(textureStreamer.feedbackBuffer(slot: slot), usage: [.read, .write])
        }
    }
    /// The encoder `bindScene` last declared the scene's resources in (Metal 4: the frame; kept so its address can't
    /// be another's; dropped when the frame is committed).
    private var sceneDeclaredIn: AnyObject?

    /// Specular shading is on and the scene has materials with a specular lobe (glTF ones).
    private var usesSpecular: Bool { settings.specular && scene.hasSpecular }

    private var usesLightMaps: Bool {
        let wanted: Bool
        switch activeGIMode {
        case .pathTraced: wanted = settings.lightMaps
        case .radianceCascades, .lumen: wanted = true
        case .restirGI: wanted = settings.restirGI.lightMaps
        }
        return settings.giEnabled && !accumulating && wanted && !scene.usesLightTable
    }

    /// References always path trace, so they stay ground truth whatever GI mode is selected (but
    /// METALRENDERER_BENCH=restirgicheck, which accumulates ReSTIR GI against them).
    private var activeGIMode: GIMode { accumulating ? referenceGIMode ?? .pathTraced : settings.giMode }

    private var techniqueDenoisesIndirect: Bool {
        switch activeGIMode {
        case .pathTraced: return true
        case .radianceCascades: return settings.cascades.denoiseIndirect
        case .restirGI: return settings.restirGI.denoise
        case .lumen: return settings.lumen.denoiseIndirect
        }
    }

    private func restirGITargets(width: Int, height: Int) -> RestirGITargets? {
        if let r = restirGIGrid, r.width == width, r.height == height { return r }
        restirGIGrid = try? RestirGITargets(device: device, width: width, height: height)
        restirGIWritten = false
        return restirGIGrid
    }

    /// ReSTIR GI's stages for this frame: initial paths, temporal reuse, spatial reuse (the last pass writes t.indirect).
    private func restirGIStages(_ plan: FramePlan, grid g: RestirGITargets, targets t: RenderTargets) -> [ComputeStage] {
        let uniforms = plan.uniforms, slot = plan.slot, cur = plan.cur, prev = plan.prev
        let r = settings.restirGI
        let width = t.width, height = t.height
        let lightMaps = plan.lightMaps && r.lightMaps
        // Multi-bounce feedback: last frame's indirect light, denoised (still in the denoiser's ping-pong textures until
        // this frame's denoiser runs) or raw (kept by the last spatial pass).
        let denoisedFeedback = t.denoise[1].atrousPass(DenoiserSettings.passRange.clamp(r.denoisePasses) - 1).dst
        let useDenoised = r.denoisedFeedback && r.denoise && plan.svgf
        let feedbackSource = useDenoised ? denoisedFeedback : g.feedback[prev]
        let feedback = r.feedback && plan.restirGIHistory && (plan.history || !useDenoised)
        var flags: UInt32 = (r.temporal && plan.restirGIHistory ? GPURestirGIParams.temporalValid : 0)
            | (lightMaps ? GPURestirGIParams.lightMaps : 0) | (feedback ? GPURestirGIParams.feedback : 0)
            | (r.feedback ? GPURestirGIParams.feedbackSet : 0)
            | (r.unbiased ? GPURestirGIParams.unbiased : 0) | (r.feedback && !useDenoised ? GPURestirGIParams.keepFeedback : 0)
            | (r.feedback && r.feedbackFallback ? GPURestirGIParams.fallback : 0)
        let maxM = UInt32(RestirGISettings.maxMRange.clamp(r.maxM))
        let samples = UInt32(RestirGISettings.spatialSampleRange.clamp(r.spatialSamples))
        let radius = RestirGISettings.radiusRange.clamp(r.radius) * Float(width) / 960
        let clamp: Float = plan.accumulating ? 0 : 4 * 10   // 4 x the firefly clamp, as ReSTIR DI
        let params = GPURestirGIParams(config: SIMD4(flags, maxM, samples, 0),
                                       tuning: SIMD4(radius, max(r.minDistance, 0), clamp, 0),
                                       extra: SIMD4(r.quarterBudget ? 1 : 0, UInt32(RenderSettings.bounceRange.clamp(r.bounces)),
                                                    UInt32(RestirGISettings.maxAgeRange.clamp(r.maxAge)), 0))
        var stages: [ComputeStage] = []
        stages.append(ComputeStage(pass: "restir gi initial") { [self] enc in
            var p = params
            bind(enc, .restirGIInitial, uniforms, pass: p.initialPassFlags, sceneSlot: slot)
            enc.setBytes(&p, length: MemoryLayout<GPURestirGIParams>.stride, index: 9)
            setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, blueNoiseTexture, lightMap, t.normalDepth[prev],
                              feedbackSource, g.spatial.a, g.spatial.b])
            enc.setBuffer(g.ambient[prev], offset: 0, index: 10)
            if r.quarterBudget { dispatch(enc, .restirGIInitial, width: (width + 1) / 2, height: (height + 1) / 2) }
            else { dispatch(enc, .restirGIInitial, width: width, height: height) }
        })
        stages.append(ComputeStage(pass: "restir gi temporal") { [self] enc in
            var p = params
            bind(enc, .restirGITemporal, uniforms)
            enc.setBytes(&p, length: MemoryLayout<GPURestirGIParams>.stride, index: 9)
            setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, t.motion, t.normalDepth[prev], g.spatial.a, g.spatial.b,
                              g.reservoir[prev].a, g.reservoir[prev].b, g.temporal.a, g.temporal.b])
            enc.setBuffer(g.ambient[cur], offset: 0, index: 10)
            dispatch(enc, .restirGITemporal, width: width, height: height)
        })
        let passes = RestirGISettings.spatialPassRange.clamp(r.spatialPasses)
        flags &= ~GPURestirGIParams.temporalValid
        for i in 0..<max(passes, 1) {
            let last = i == max(passes, 1) - 1
            let src = i == 0 ? g.temporal : g.spatial, dst = last ? g.reservoir[cur] : g.spatial
            var p = params
            p.config.x = flags | (last ? GPURestirGIParams.shade : 0)
            p.config.z = passes == 0 ? 0 : samples
            p.config.w = UInt32(i)
            stages.append(ComputeStage(pass: "restir gi spatial") { [self] enc in
                var p = p
                bind(enc, .restirGISpatial, uniforms, sceneSlot: slot)
                enc.setBytes(&p, length: MemoryLayout<GPURestirGIParams>.stride, index: 9)
                setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, src.a, src.b, dst.a, dst.b, t.indirect, t.giDebug,
                                  g.feedback[cur]])
                enc.setBuffer(g.ambient[cur], offset: 0, index: 10)
                dispatch(enc, .restirGISpatial, width: width, height: height)
            })
        }
        return stages
    }

    /// Radiance-cascade stages for this frame (they write t.indirect and t.giDebug); empty if allocation failed.
    private func radianceCascadeStages(_ plan: FramePlan, targets t: RenderTargets) -> [ComputeStage] {
        let slot = plan.slot
        if radianceCascades == nil || radianceCascades!.width != t.width || radianceCascades!.height != t.height
            || radianceCascades!.settings != settings.cascades {
            do {
                radianceCascades = try RadianceCascades(device: device, width: t.width, height: t.height,
                                                        settings: settings.cascades)
            } catch {
                print(error)
                return []
            }
        }
        return radianceCascades!.stages(pipelines: pipelines.rc, uniforms: plan.uniforms,
                                        bindScene: { [unowned self] in bindScene($0, slot: slot) }, lightMap: lightMap,
                                        normalDepth: t.normalDepth[plan.cur], prevNormalDepth: t.normalDepth[plan.prev], targets: t)
    }

    /// Lumen's stages for this frame (they write t.indirect and t.giDebug); empty if allocation failed.
    private func lumenStages(_ plan: FramePlan, targets t: RenderTargets) -> [ComputeStage] {
        let slot = plan.slot, spacing = LumenSettings.spacingOptions.contains(settings.lumen.probeSpacing) ? settings.lumen.probeSpacing : 8
        if lumen == nil || lumen!.width != t.width || lumen!.height != t.height || lumen!.spacing != spacing {
            do {
                lumen = try Lumen(device: device, width: t.width, height: t.height, spacing: spacing)
            } catch {
                print(error)
                return []
            }
        }
        var cards: LumenCards?
        if settings.lumen.cards {
            if lumenCards == nil || lumenCardsScene !== scene {
                lumenCards = try? LumenCards(device: device, frameSlots: Renderer.maxFramesInFlight)
                lumenCardsScene = scene
            }
            lumenCards?.update(scene: scene, eligible: lumenCardEligible, foliage: lumenFoliage, camera: camera,
                               viewportHeight: t.height, slot: slot,
                               radiosityBudget: LumenSettings.radiosityBudgetRange.clamp(settings.lumen.radiosityBudget) << 10)
            cards = lumenCards
        }
        var sdfScene: LumenScene?
        var global: (field: LumenGlobalSDF, levels: [GPULumenClipLevel])?
        var bakeSeconds: Double?    // benchmarks: how long they waited for the bakes
        if settings.lumen.trace == .sdf || settings.lumen.debug >= 4 {
            if lumenScene == nil || lumenSceneOf !== scene {
                lumenScene?.cancel()
                let large: Set<SceneKind> = [.city, .cityNight, .forest, .valley, .world]
                let layout = LumenGlobalSDF.layout(bounds: scene.bounds(), large: large.contains(settings.scene.kind),
                                                   voxel: LumenSettings.globalVoxelRange.clamp(settings.lumen.globalVoxel))
                lumenGlobal = try? LumenGlobalSDF(device: device, levels: layout.levels, voxel: layout.voxel,
                                                  frameSlots: Renderer.maxFramesInFlight)
                if lumenKeptScene == nil { lumenKeptSource = nil }   // the scene it was kept for is gone
                let kept = lumenKeptScene === scene ? lumenKeptSource : nil
                lumenScene = try? LumenScene(device: device, scene: scene, fields: lumenSDFFields(), source: kept,
                                             frameSlots: Renderer.maxFramesInFlight)
                lumenSceneOf = scene
                if benchmark != nil {
                    let start = CACurrentMediaTime()
                    lumenScene?.waitForBakes()
                    bakeSeconds = CACurrentMediaTime() - start
                }
            }
            lumenScene?.update(scene: scene, eligible: lumenSDFEligible, slot: slot)
            if let bakeSeconds, let lumenScene {
                print(String(format: "Lumen: %d mesh fields in %.2f s; %d MB of fields, %d MB global field, %d MB cards",
                             lumenScene.toBake, bakeSeconds, lumenScene.megabytes, lumenGlobal?.megabytes ?? 0,
                             lumenCards?.megabytes ?? 0))
            }
            sdfScene = lumenScene
            if let lumenGlobal, let lumenScene {
                global = (lumenGlobal, lumenGlobal.update(camera: camera.position, changed: lumenScene.movedBoxes,
                                                         everything: lumenScene.fieldsChanged, slot: slot))
            }
        }
        return lumen!.stages(pipelines: pipelines.lumen, settings: settings.lumen, uniforms: plan.uniforms,
                             bindScene: { [unowned self] in bindScene($0, slot: slot) }, lightMap: lightMap,
                             normalDepth: t.normalDepth[plan.cur], prevNormalDepth: t.normalDepth[plan.prev],
                             cards: cards, cardInstances: scene.instances.count, scene: sdfScene, global: global, slot: slot,
                             targets: t)
    }

    /// Instances with cards in the surface cache: geometry that doesn't deform, and not plants (assemblies, leaf cards,
    /// ground cover). A card sees a canopy's outer, sunlit leaves, and the hits inside it read them: the backlit forest
    /// was 2% too bright with them. Plants' hits are lit where they are.
    private func lumenCardEligible(_ inst: Scene.Instance) -> Bool {
        inst.isGeometry && !inst.deforms && !lumenFoliage(inst)
    }

    /// Plants: assemblies, leaf cards, ground cover.
    private func lumenFoliage(_ inst: Scene.Instance) -> Bool {
        guard inst.isGeometry else { return false }
        if inst.assembly >= 0 { return true }
        guard inst.mesh >= 0 else { return false }
        let m = scene.meshes[inst.mesh]
        return m.cutout != 0 || m.sways != 0
    }

    /// Instances traced through a distance field: geometry that doesn't deform (the crowd: screen traces only) or
    /// sway (ground cover); meshes, virtual meshes and plants' assemblies. Not SDF shapes (cards and screen traces).
    private func lumenSDFEligible(_ inst: Scene.Instance) -> Bool {
        guard inst.isGeometry, !inst.deforms, inst.sdf < 0 else { return false }
        guard inst.mesh >= 0 else { return true }
        let m = scene.meshes[inst.mesh]
        return m.sways == 0 && m.vertexOffset == 0
    }

    /// The fields to bake, the most used first.
    private func lumenSDFFields() -> [Int] {
        var uses: [Int: Int] = [:]
        for inst in scene.instances where lumenSDFEligible(inst) { uses[LumenScene.field(of: inst, in: scene), default: 0] += 1 }
        return uses.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Drops all temporal GI state (cascade feedback, denoiser history).
    private func resetGIState() {
        historyValid = false
        restirWritten = false
        megaLightsWritten = false
        restirGIWritten = false
        skyRefreshed = nil
        fogLastFrame = nil
        radianceCascades?.reset()
        lumen?.reset()
    }

    // MARK: - Benchmark

    private func applyBenchmarkConfig(_ c: Benchmark.Config) {
        settings = c.resolvedSettings()
        animTime = c.startTime
        previousAnimTime = c.startTime
        setWorldLights()   // the scene it starts with is the one its time of day asks for
        if settings.scene != scene.settings || settings.rayTracer != builtRayTracer || settings.api != builtAPI || virtualGeometryChanged {
            rebuildScene(resetCamera: false)
        }
        camera = c.track?.camera(at: 0)
            ?? (c.cameraPath ? Benchmark.cameraPose(progress: 0, scene: settings.scene.kind, sceneCamera: scene.defaultCamera) : c.camera ?? scene.defaultCamera)
        prevCamera = camera
        benchmarkAccumulating = c.accumulate
        referenceGIMode = c.accumulate && c.accumulateTechnique ? c.settings.giMode : nil
        referenceDirectMode = c.accumulate && [.exact, .restir, .megalights].contains(c.directLight) ? c.directLight : nil
        supersampling = c.accumulate && c.supersample
        resetReference()
        resetGIState()
        upscalerReset = true
        streaming = Streaming()
        print("benchmark: \(c.name)")
    }

    private func advanceBenchmark(_ benchmark: Benchmark) {
        if benchmark.hold(settled: streamingSettled) { return }
        guard benchmark.advance() else { return }
        guard benchmark.isFinished else {
            applyBenchmarkConfig(benchmark.current)
            return
        }
        // Wait for every in-flight frame so all records are in, then print and quit.
        for _ in 0..<Renderer.maxFramesInFlight { frameSemaphore.wait() }
        for _ in 0..<Renderer.maxFramesInFlight { frameSemaphore.signal() }
        print(benchmark.report(gpuName: device.name))
        fflush(stdout)
        DispatchQueue.main.async { NSApp.terminate(nil) }   // drawFrame draws no more frames
    }

    /// Virtual geometry has what the view asks for: no group waiting to stream in, no BLAS being built over a cut.
    private var streamingSettled: Bool {
        guard let customRT else { return true }
        return (customRT.virtualGeometry?.streamer.isSettled ?? true) && !(customRT.virtualBLAS?.isBusy ?? false)
            && (rasterClusters?.streamer.isSettled ?? true)
    }

    private func colorAccumTexture(width: Int, height: Int) -> MTLTexture? {
        if let t = colorAccum, t.width == width, t.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        colorAccum = device.makeTexture(descriptor: d)
        colorAccumCount = 0
        return colorAccum
    }

    /// Reference "Path traced": for each of the scene's own instances, the light it is the visible shape of (its
    /// index in the lights), ~1 for the other camera-only shapes (maskLights: the motes), ~0 for geometry. A bounce
    /// ray that meets a light's shape asks this which light it met, and passes through the motes.
    private func makeLightProxies() {
        var map = scene.instances.map { $0.mask & Scene.maskLights != 0 ? UInt32.max - 1 : UInt32.max }
        if map.isEmpty { map = [.max] }
        for (i, light) in scene.lights.enumerated() where map.indices.contains(light.proxyInstance) {
            map[light.proxyInstance] = UInt32(i)
        }
        lightProxies = device.makeBuffer(bytes: map, length: map.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        lightProxies?.label = "light proxies"
        lightProxyCount = scene.instances.count
    }

    /// The reference picture starts over: no frame or path of it is kept.
    private func resetReference() {
        accumCount = 0
        colorAccumCount = 0
        pathTraceCount = 0
        referenceEpoch &+= 1
    }

    /// Reference pictures in the app (not a benchmark's, which its config keeps still) start over when the view
    /// changes (the camera, the field of view, the size) or the scene moves (its clock runs).
    private func checkReferenceView(width: Int, height: Int) {
        guard referenceMode != .off && !benchmarkAccumulating else {
            referenceView = []
            return
        }
        let view = [SIMD4(camera.position, camera.fovY), SIMD4(camera.forward, Float(width)), SIMD4(camera.up, Float(height))]
        if view != referenceView || animTime != previousAnimTime { resetReference() }
        referenceView = view
    }

    /// Reference "Path traced": the paths' running mean.
    private func pathTraceTexture(width: Int, height: Int) -> MTLTexture? {
        if let t = pathTraceAccum, t.width == width, t.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        pathTraceAccum = device.makeTexture(descriptor: d)
        pathTraceCount = 0
        return pathTraceAccum
    }

    private func accumulationTextures(width: Int, height: Int) -> (direct: MTLTexture, indirect: MTLTexture, specular: MTLTexture)? {
        if let t = accumTextures, t.direct.width == width, t.direct.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let direct = device.makeTexture(descriptor: d), let indirect = device.makeTexture(descriptor: d),
              let specular = device.makeTexture(descriptor: d) else { return nil }
        accumTextures = (direct, indirect, specular)
        accumCount = 0
        return accumTextures
    }

    private func setTextures(_ enc: ComputePass, _ textures: [MTLTexture]) {
        for (i, texture) in textures.enumerated() { enc.setTexture(texture, index: i) }
    }

    /// sRGB, so shaders and MetalFX write linear color and the GPU encodes it.
    static let drawableFormat = MTLPixelFormat.bgra8Unorm_srgb
    private static let shadowDenoiserAllowed = ProcessInfo.processInfo.environment["METALRENDERER_SHADOWS"] != "0"
    /// References trace every light up to this many; above, they accumulate ReSTIR's unbiased initial sampling (no reuse).
    static let exactReferenceLights = 1024

    /// This frame's direct-light method: Auto resolved (ReSTIR with many lights), references exact or sampled.
    private var activeDirectMode: DirectLightMode {
        if accumulating {
            if let forced = referenceDirectMode { return forced }   // METALRENDERER_BENCH=restircheck
            return scene.lights.count > Renderer.exactReferenceLights ? .restir : .exact
        }
        switch settings.directLight {
        case .auto: return scene.usesLightTable ? .restir : .grouped   // ReSTIR wins above ~256 lights (METALRENDERER_BENCH=restir)
        case .megalights where scene.lights.count > MegaLightsSettings.maxLights
                            || scene.lights.lazy.filter({ $0.kind.isSun }).count > LightTable.maxSuns: return .restir
        case let mode: return mode
        }
    }

    /// The light grid's buffer for `count` reservoirs (reallocated only when the count changes: a settings change).
    private func regirGrid(count: Int) -> MTLBuffer? {
        let length = max(count, 1) * MemoryLayout<GPURegirReservoir>.stride
        if let b = regirBuffer, b.length == length { return b }
        regirBuffer = device.makeBuffer(length: length, options: .storageModePrivate)
        regirBuffer?.label = "regirGrid"
        return regirBuffer
    }
    private func restirTargets(width: Int, height: Int, chains: Int) -> RestirTargets? {
        if let r = restirGrid, r.width == width, r.height == height, r.chains == chains { return r }
        restirGrid = try? RestirTargets(device: device, width: width, height: height, chains: chains)
        restirWritten = false
        return restirGrid
    }
    /// The light tree in this frame's slot: built from this frame's light records on MegaLights' first frame in a scene,
    /// refit once a frame for the lights that change, and copied into the slot's buffer when that one is behind.
    private func lightTreeBuffer(slot: Int) -> (buffer: MTLBuffer, nodes: Int)? {
        if lightTree == nil {
            lightTree = LightTree(lights: lightStage)
        } else if lightTreeRefitFrame != frameIndex {
            let changes = scene.lightTreeChanges
            lightTree?.refit(lights: lightStage, moved: changes.moved, scaled: changes.scaled)
        }
        lightTreeRefitFrame = frameIndex
        guard let tree = lightTree, !tree.nodes.isEmpty else { return nil }
        if (lightTreeBuffers[slot]?.length ?? 0) < tree.byteCount {
            lightTreeBuffers[slot] = device.makeBuffer(length: tree.byteCount, options: .storageModeShared)
            lightTreeBuffers[slot]?.label = "light tree"
            lightTreeVersions[slot] = -1
        }
        guard let buffer = lightTreeBuffers[slot] else { return nil }
        if lightTreeVersions[slot] != tree.version {
            let nodeBytes = tree.nodes.count * MemoryLayout<GPULightTreeNode>.stride
            tree.nodes.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            tree.paths.withUnsafeBytes { buffer.contents().advanced(by: nodeBytes).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            lightTreeVersions[slot] = tree.version
        }
        return (buffer, tree.nodes.count)
    }
    // MARK: - Raster visibility buffer

    /// The raster's view of the scene being drawn: made on the first raster frame of a scene's buffers.
    private func currentRasterScene() -> RasterScene? {
        let clusters = rasterClusters != nil && cameraClusters   // (the shadow maps may have them on their own)
        if let r = rasterScene, r.source === sceneBuffers.meshes, r.virtualClusters == clusters { return r }
        rasterScene = nil
        do {
            rasterScene = try RasterScene(device: device, scene: scene, buffers: sceneBuffers, customTracer: builtRayTracer == .custom,
                                          virtualBLAS: customRT?.virtualBLAS != nil, clusters: clusters)
        } catch {
            print("Raster visibility buffer: \(error); the primary rays are traced")
        }
        return rasterScene
    }

    /// Virtual geometry's clusters, when the raster or the shadow maps draw them (made on the first such frame of a
    /// scene, with their own streaming pool): nil otherwise, which frees the pool.
    @discardableResult
    private func currentRasterClusters() -> RasterClusters? {
        guard cameraClusters || shadowClusters, let customRT, let blas = customRT.virtualBLAS, !scene.hasVoxelBoxes else {
            if rasterClusters != nil {
                customRT?.rasterClusters = nil
                rasterClusters = nil
            }
            return nil
        }
        let poolBytes = max(settings.virtualGeometry.rasterPoolMB, 64) << 20
        if let r = rasterClusters, r.source === blas, r.streamer.poolBytes == poolBytes { return r }
        customRT.rasterClusters = nil
        rasterClusters = nil
        let instances = scene.instances.indices.filter { scene.instances[$0].virtualMesh >= 0 }.map { ($0, scene.instances[$0].virtualMesh) }
        do {
            let r = try RasterClusters(device: device, meshes: scene.virtualMeshes, instances: instances,
                                       poolMB: settings.virtualGeometry.rasterPoolMB, slots: Renderer.maxFramesInFlight)
            r.source = blas
            rasterClusters = r
            customRT.rasterClusters = r
        } catch {
            print("Raster clusters: \(error); virtual geometry is drawn from its BLAS")
        }
        return rasterClusters
    }

    /// The camera's raster draws virtual geometry as clusters (VirtualGeometrySettings.raster).
    private var cameraClusters: Bool { settings.primary == .raster && settings.virtualGeometry.raster.drawsClusters }
    /// The shadow maps draw virtual geometry as clusters (VSMSettings.clusters).
    private var shadowClusters: Bool {
        settings.shadowMethod == .virtualMaps && settings.vsm.clusters && !CustomRayTracer.clusterMode
    }

    private func rasterTargets(width: Int, height: Int, scene rs: RasterScene) -> RasterTargets? {
        if let r = rasterTargets, r.width == width, r.height == height, r.maxGroups >= rs.instanceCount + r.maxDraws / 64 + 1,
           r.maxDraws >= min(rs.chunkCount, 1 << 22) {
            return r
        }
        rasterTargets = nil   // (the old ones go first: a size change can be large)
        rasterTargets = try? RasterTargets(device: device, width: width, height: height, chunks: rs.chunkCount, instances: rs.instanceCount)
        return rasterTargets
    }

    /// What the raster's vertices and culling reach through addresses: the borrowed meshes' buffers, the instance
    /// blocks' records and the cut's BLASes.
    private func rasterResources(slot: Int) -> [MTLResource] {
        sceneBuffers.blockBuffers + sceneBuffers.instanceResources + (customRT?.virtualBLAS?.resources(slot: slot) ?? [])
            + (rasterScene?.virtualClusters == true ? rasterClusters?.resources(slot: slot) ?? [] : [])
    }

    /// 1c. The raster visibility buffer (Shaders/Raster.metal), ahead of the trace that reads it. The chunks' bounds the
    /// first time; then two culling passes (what was visible last frame, then the rest against the depth pyramid of the
    /// first), each with its draw, and the pyramid between them.
    private func encodeRaster(_ plan: FramePlan, _ raster: (scene: RasterScene, targets: RasterTargets), passes: FrameEncoder) {
        let rs = raster.scene, rt = raster.targets, slot = plan.slot
        guard let depthState = rasterDepthState else { return }
        var u = plan.uniforms
        var params = GPURasterParams(instanceCount: UInt32(rs.instanceCount), meshCount: UInt32(rs.meshCount),
                                     chunkCount: UInt32(rs.chunkCount),
                                     flags: (rs.ids != nil ? GPURasterParams.ids : 0) | GPURasterParams.hzb,
                                     maxDraws: UInt32(rt.maxDraws), maxGroups: UInt32(rt.maxGroups), hzbLevels: UInt32(rt.hzb.mipmapLevelCount),
                                     pass: 0, hzbSize: SIMD2(UInt32(rt.hzb.width), UInt32(rt.hzb.height)),
                                     firstAssembly: UInt32(rs.firstAssembly))
        let instances = sceneBuffers.instanceTable ?? instanceDataBuffers[slot]
        let vgTable = customRT?.virtualBLAS?.table(slot: slot) ?? rs.meshes   // (a stand-in nothing reads)
        let clusters = rs.virtualClusters ? rasterClusters : nil
        params.virtualCount = UInt32(clusters?.instanceCount ?? 0)
        let meshPipeline = settings.virtualGeometry.raster == .mesh ? pipelines.clusterMesh : nil
        let vgParams = clusters?.params(view: detailView(height: plan.size.height), previous: rt.prevFrame == frameIndex &- 1,
                                        mesh: meshPipeline != nil)
        let pages = clusters?.streamer.bindPages(slot: slot)
        let resources = rasterResources(slot: slot)
        let group = MTLSize(width: 64, height: 1, depth: 1)

        /// The buffers every raster kernel reads at the indices Raster.metal gives them, for `pass`.
        func bind(_ enc: ComputePass, pass: Int) {
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setBuffer(positionBuffer, offset: 0, index: 2)
            enc.setBuffer(indexBuffer, offset: 0, index: 4)
            enc.setBuffer(meshBuffer, offset: 0, index: 5)
            enc.setBuffer(instances, offset: 0, index: 6)
            params.pass = UInt32(pass)
            enc.setBytes(&params, length: MemoryLayout<GPURasterParams>.stride, index: 9)
            enc.setBuffer(rs.ids ?? rs.meshes, offset: 0, index: 10)
            enc.setBuffer(rs.visible, offset: 0, index: 11)
            enc.setBuffer(rt.groups, offset: pass * rt.maxGroups * 16, index: 12)
            enc.setBuffer(rt.counters, offset: 0, index: 13)
            enc.setBuffer(rs.meshes, offset: 0, index: 14)
            enc.setBuffer(rs.chunkBounds, offset: 0, index: 15)
            enc.setBuffer(vgTable, offset: 0, index: 16)
            enc.setBuffer(rt.draws, offset: pass * rt.maxDraws * 16, index: 17)
            enc.setBuffer(rs.chunkMeshes, offset: 0, index: 18)
            enc.setBuffer(rt.records, offset: pass * rt.maxGroups * RasterTargets.recordSize, index: 19)
            enc.setTexture(rt.hzb, index: 0)
            enc.setTexture(rt.hzbPrev, index: 1)
            // The raster clusters (Shaders/RasterClusters.metal); their state is cleared and set aside even without them.
            enc.setBuffer(clusters?.state(slot: slot) ?? rs.noClusterState, offset: 0, index: 26)
            if let clusters, let pages, var p = vgParams {
                enc.setBuffer(clusters.streamer.pool, offset: 0, index: 20)
                enc.setBytes(&p, length: MemoryLayout<RasterClusters.Params>.stride, index: 21)
                enc.setBuffer(clusters.vinstances, offset: 0, index: 22)
                enc.setBuffer(clusters.groupRecords, offset: 0, index: 23)
                enc.setBuffer(clusters.streamer.clusterBuffer, offset: 0, index: 24)
                enc.setBuffer(pages, offset: 0, index: 25)
                enc.setBuffer(clusters.listBuffers[slot], offset: 0, index: 27)
                enc.setBuffer(clusters.requests(slot: slot), offset: 0, index: 28)
                enc.setBuffer(clusters.streamer.requestStamp, offset: 0, index: 29)
                enc.setBuffer(clusters.streamer.lastUsed, offset: 0, index: 30)
            }
        }

        for pass in 0..<2 {
            guard let enc = passes.compute("raster cull", serial: true) else { return }
            enc.useResources(resources, usage: .read)
            bind(enc, pass: pass)
            if pass == 0 {
                if !rs.boundsReady && rs.chunkCount > 0 {
                    enc.setComputePipelineState(pipelines[.rasterBounds])
                    enc.dispatchThreads(MTLSize(width: rs.chunkCount, height: 1, depth: 1), threadsPerThreadgroup: group)
                    rs.boundsReady = true
                }
                enc.setComputePipelineState(pipelines[.rasterReset])
                enc.dispatchThreads(MTLSize(width: max(16, Int(params.virtualCount)), height: 1, depth: 1), threadsPerThreadgroup: group)
            }
            enc.setComputePipelineState(pipelines[.rasterCull])
            enc.dispatchThreads(MTLSize(width: max(rs.instanceCount, 1), height: 1, depth: 1), threadsPerThreadgroup: group)
            // Virtual geometry's clusters: the cut and what the last frame's depth doesn't hide, then what it did that
            // this frame's (pass 1's) doesn't.
            if let clusters, clusters.workCount > 0 {
                enc.setComputePipelineState(pipelines[pass == 0 ? .rasterVGCut : .rasterVGRetest])
                enc.dispatchThreads(MTLSize(width: pass == 0 ? clusters.workCount : RasterClusters.capacity, height: 1, depth: 1),
                                    threadsPerThreadgroup: group)
                if meshPipeline != nil {
                    enc.setComputePipelineState(pipelines[.rasterVGMeshArgs])
                    enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
                }
            }
            enc.setComputePipelineState(pipelines[.rasterChunks])
            enc.dispatchThreadgroups(indirectBuffer: rt.counters, indirectBufferOffset: pass * RasterTargets.countersStride + 16,
                                     threadsPerThreadgroup: group)
            passes.endCompute()

            let clear = MTLClearColor(red: Double(UInt32.max), green: Double(UInt32.max), blue: 0, alpha: 0)
            passes.render("raster", RenderAttachments(color: rt.visibility, depth: rt.depth, clear: pass == 0, clearColor: clear)) { [self] r in
                r.setRenderPipelineState(pipelines.visibility)
                r.setDepthStencilState(depthState)
                // (the records' corners and indices point into these)
                r.useResources(resources + [positionBuffer, indexBuffer, rs.meshes])
                r.setBytes(&params, length: MemoryLayout<GPURasterParams>.stride, index: 9)
                r.setBuffer(rt.draws, offset: pass * rt.maxDraws * 16, index: 17)
                r.setBuffer(rt.records, offset: pass * rt.maxGroups * RasterTargets.recordSize, index: 19)
                if let clusters {   // a cluster's vertices: its triangles and positions in the pool, its instances' records
                    r.setBuffer(clusters.streamer.pool, offset: 0, index: 20)
                    r.setBuffer(clusters.state(slot: slot), offset: 0, index: 26)
                    r.setBuffer(clusters.listBuffers[slot], offset: RasterClusters.ownersOffset, index: 27)
                }
                r.drawTriangles(indirectBuffer: rt.counters, indirectBufferOffset: pass * RasterTargets.countersStride)
                if let meshPipeline, let clusters, var p = vgParams {   // the pass's clusters, a threadgroup each
                    r.setRenderPipelineState(meshPipeline)
                    r.setMeshBytes(&params, length: MemoryLayout<GPURasterParams>.stride, index: 9)
                    r.setMeshBuffer(clusters.streamer.pool, offset: 0, index: 20)
                    r.setMeshBytes(&p, length: MemoryLayout<RasterClusters.Params>.stride, index: 21)
                    r.setMeshBuffer(clusters.state(slot: slot), offset: 0, index: 26)
                    r.setMeshBuffer(clusters.listBuffers[slot], offset: 0, index: 27)
                    r.drawMeshThreadgroups(indirectBuffer: clusters.state(slot: slot), indirectBufferOffset: RasterClusters.meshArgsOffset(pass: pass),
                                           threads: RasterScene.chunk)
                }
            }

            // The pyramid of pass 1's depth, which pass 2 tests against; with raster clusters, after pass 2 the final
            // depth's, which the next frame's clusters test against first.
            let pyramid = pass == 0 ? rt.hzb : clusters != nil ? rt.hzbPrev : nil
            if let pyramid, let enc = passes.compute("hzb", serial: true) {
                enc.setComputePipelineState(pipelines[.hzbInit])
                enc.setTexture(rt.depth, index: 0)
                enc.setTexture(pyramid, index: 1)
                dispatch(enc, .hzbInit, width: pyramid.width, height: pyramid.height)
                enc.setComputePipelineState(pipelines[.hzbReduce])
                enc.setTexture(pyramid, index: 0)
                for level in 1..<pyramid.mipmapLevelCount {
                    var l = UInt32(level)
                    enc.setBytes(&l, length: 4, index: 0)
                    dispatch(enc, .hzbReduce, width: max(pyramid.width >> level, 1), height: max(pyramid.height >> level, 1))
                }
                passes.endCompute()
            }
        }
        rt.prevFrame = clusters != nil ? frameIndex : .max
    }

    // MARK: - Virtual shadow maps

    /// Drawn pages are kept until their light or something over them moves; `METALRENDERER_VSM_CACHE=0` draws every page
    /// a sample asks for every frame (an A/B of the cache).
    private static let vsmCache = ProcessInfo.processInfo.environment["METALRENDERER_VSM_CACHE"] != "0"

    /// The scene's virtual shadow maps for this frame's lights (the first `analytic` of the slot's light buffer, as
    /// writeFrameData left them): made again for other buffers, other mapped lights or other pool or level settings.
    private func vsmTargets(slot: Int, analytic: Int) -> VSMTargets? {
        let lights = Array(UnsafeBufferPointer(start: lightBuffers[slot].contents().bindMemory(to: GPULight.self, capacity: analytic),
                                               count: analytic))
        let s = settings.vsm
        if let v = vsmTargets, vsmSource === sceneBuffers.meshes, v.settings.pool == s.pool, v.settings.levels == s.levels,
           v.settings.maxLights == s.maxLights, v.lights == VSMTargets.mapped(lights, settings: s) {
            return v
        }
        vsmTargets = nil   // (the old pool goes first)
        vsmTargets = VSMTargets(device: device, lights: lights, settings: s, frameSlots: Renderer.maxFramesInFlight)
        vsmSource = sceneBuffers.meshes
        return vsmTargets
    }

    /// SceneShading.vsm: this frame's VSMScene, or none.
    private func writeVSMArgument(_ plan: FramePlan) {
        let slot = plan.slot
        guard slot < shadingArgs.count else { return }
        var address: UInt64 = 0
        if let vsm = plan.vsm {
            let analytic = Int(plan.uniforms.lightGroupEnd.w)
            let lights = Array(UnsafeBufferPointer(start: lightBuffers[slot].contents().bindMemory(to: GPULight.self, capacity: analytic),
                                                   count: analytic))
            let u = plan.uniforms
            vsm.writeViews(slot: slot, lights: lights, camera: SIMD3(u.camPos.x, u.camPos.y, u.camPos.z))
            vsm.writeScene(slot: slot, lightCount: analytic, traced: scene.hasShadowTraced, settings: settings.vsm, uniforms: u)
            address = vsm.sceneArgs[slot].gpuAddress
        }
        shadingArgs[slot].contents().storeBytes(of: address, toByteOffset: Renderer.shadingVSMOffset, as: UInt64.self)
    }

    /// 1b. The virtual shadow maps' pages (Shaders/VSM.metal), ahead of the trace whose shadow samples read them: the
    /// pages last frame's samples asked for get physical pages and, if not drawn, their turn; the instances and chunks
    /// in front of those are culled into a draw list; one render pass clears and draws the pages.
    private func encodeVSM(_ plan: FramePlan, _ vsm: VSMTargets, passes: FrameEncoder) {
        guard let rs = currentRasterScene(), let depthState = rasterDepthState, let clearState = vsmClearState else { return }
        let slot = plan.slot
        let instances = sceneBuffers.instanceTable ?? instanceDataBuffers[slot]
        let vgTable = customRT?.virtualBLAS?.table(slot: slot) ?? rs.meshes   // (a stand-in nothing reads)
        let resources = rasterResources(slot: slot)
        var params = GPUVSMParams(entries: UInt32(vsm.entries), pool: UInt32(vsm.poolPages),
                                  budget: UInt32(min(settings.vsm.budget, VSMSettings.budgetRange.upperBound)),
                                  frame: plan.uniforms.frameIndex, keep: 30, instanceCount: UInt32(rs.instanceCount),
                                  meshCount: UInt32(rs.meshCount), maxDraws: UInt32(VSMTargets.maxDraws),
                                  maxGroups: UInt32(VSMTargets.maxGroups),
                                  flags: (rs.ids != nil ? GPUVSMParams.ids : 0) | (Renderer.vsmCache ? GPUVSMParams.cache : 0),
                                  views: UInt32(vsm.viewCount), moving: UInt32(rs.movingCount))
        // Virtual geometry as the raster's clusters: their own cut a view (vsmVGCutKernel); else zeros (VSMClusterArgs).
        let clusters = settings.vsm.clusters ? rasterClusters : nil
        let clusterArgs = clusters?.shadowArgs(slot: slot, views: vsm.viewCount, tau: settings.virtualGeometry.pixelError)
        var vgArgs = clusterArgs?.bytes ?? [UInt64](repeating: 0, count: 12)
        let group = MTLSize(width: 64, height: 1, depth: 1), one = MTLSize(width: 1, height: 1, depth: 1)
        guard let enc = passes.compute("vsm", serial: true) else { return }
        enc.useResources(resources, usage: .read)
        if let clusterArgs { enc.useResources(clusterArgs.resources, usage: [.read, .write]) }
        if !rs.boundsReady && rs.chunkCount > 0 {   // the chunks' bounds, once a scene (as encodeRaster)
            var rp = GPURasterParams(instanceCount: 0, meshCount: UInt32(rs.meshCount), chunkCount: UInt32(rs.chunkCount))
            enc.setBytes(&rp, length: MemoryLayout<GPURasterParams>.stride, index: 9)
            enc.setBuffer(positionBuffer, offset: 0, index: 2)
            enc.setBuffer(indexBuffer, offset: 0, index: 4)
            enc.setBuffer(meshBuffer, offset: 0, index: 5)
            enc.setBuffer(rs.meshes, offset: 0, index: 14)
            enc.setBuffer(rs.chunkBounds, offset: 0, index: 15)
            enc.setBuffer(rs.chunkMeshes, offset: 0, index: 18)
            enc.setComputePipelineState(pipelines[.rasterBounds])
            enc.dispatchThreads(MTLSize(width: rs.chunkCount, height: 1, depth: 1), threadsPerThreadgroup: group)
            rs.boundsReady = true
        }
        enc.setBuffer(positionBuffer, offset: 0, index: 2)
        enc.setBuffer(indexBuffer, offset: 0, index: 4)
        enc.setBuffer(meshBuffer, offset: 0, index: 5)
        enc.setBuffer(instances, offset: 0, index: 6)
        enc.setBytes(&vgArgs, length: vgArgs.count * 8, index: 7)
        enc.setBytes(&params, length: MemoryLayout<GPUVSMParams>.stride, index: 9)
        enc.setBuffer(rs.ids ?? rs.meshes, offset: 0, index: 10)
        enc.setBuffer(rs.moving, offset: 0, index: 11)
        enc.setBuffer(vsm.groups, offset: 0, index: 12)
        enc.setBuffer(vsm.counters, offset: 0, index: 13)
        enc.setBuffer(rs.meshes, offset: 0, index: 14)
        enc.setBuffer(rs.chunkBounds, offset: 0, index: 15)
        enc.setBuffer(vgTable, offset: 0, index: 16)
        enc.setBuffer(vsm.records, offset: 0, index: 17)
        enc.setBuffer(vsm.draws, offset: 0, index: 18)
        enc.setBuffer(vsm.activeViews, offset: 0, index: 19)
        enc.setBuffer(vsm.rects, offset: 0, index: 20)
        enc.setBuffer(vsm.active, offset: 0, index: 21)
        enc.setBuffer(vsm.views[slot], offset: 0, index: 22)
        enc.setBuffer(vsm.entryView, offset: 0, index: 23)
        enc.setBuffer(vsm.table, offset: 0, index: 24)
        enc.setBuffer(vsm.tags, offset: 0, index: 25)
        enc.setBuffer(vsm.pages, offset: 0, index: 26)
        enc.setBuffer(vsm.freeList, offset: 0, index: 27)
        enc.setBuffer(vsm.requests, offset: 0, index: 28)
        enc.setBuffer(vsm.slots, offset: 0, index: 29)
        enc.setBuffer(vsm.renderList, offset: 0, index: 30)
        let entries = MTLSize(width: vsm.entries, height: 1, depth: 1)
        enc.setComputePipelineState(pipelines[.vsmReset])
        enc.dispatchThreads(one, threadsPerThreadgroup: one)
        enc.setComputePipelineState(pipelines[.vsmViewReset])
        enc.dispatchThreads(MTLSize(width: vsm.viewCount, height: 1, depth: 1), threadsPerThreadgroup: group)
        enc.setComputePipelineState(pipelines[.vsmFree])
        enc.dispatchThreads(entries, threadsPerThreadgroup: group)
        if Renderer.vsmCache && rs.movingCount > 0 {
            enc.setComputePipelineState(pipelines[.vsmInvalidate])
            enc.dispatchThreads(MTLSize(width: rs.movingCount, height: vsm.viewCount, depth: 1), threadsPerThreadgroup: group)
        }
        enc.setComputePipelineState(pipelines[.vsmAlloc])
        enc.dispatchThreads(entries, threadsPerThreadgroup: group)
        enc.setComputePipelineState(pipelines[.vsmSettle])
        enc.dispatchThreads(one, threadsPerThreadgroup: one)
        enc.setComputePipelineState(pipelines[.vsmCull])
        enc.dispatchThreadgroups(indirectBuffer: vsm.counters, indirectBufferOffset: 48, threadsPerThreadgroup: group)
        if let clusters, clusters.workCount > 0 {   // (after the cull: it reads the records the cull left)
            enc.setComputePipelineState(pipelines[.vsmVGCut])
            enc.dispatchThreads(MTLSize(width: clusters.workCount, height: vsm.viewCount, depth: 1), threadsPerThreadgroup: group)
        }
        enc.setComputePipelineState(pipelines[.vsmChunks])
        enc.dispatchThreadgroups(indirectBuffer: vsm.counters, indirectBufferOffset: 16, threadsPerThreadgroup: group)
        passes.endCompute()

        passes.render("vsm draw", RenderAttachments(color: nil, depth: vsm.pool, clear: false, layers: vsm.poolPages)) { [self] r in
            r.useResources(resources + [positionBuffer, indexBuffer, rs.meshes] + (clusterArgs?.resources ?? []))   // (the records point into these)
            r.setBytes(&vgArgs, length: vgArgs.count * 8, index: 7)
            r.setBytes(&params, length: MemoryLayout<GPUVSMParams>.stride, index: 9)
            r.setBuffer(vsm.records, offset: 0, index: 17)
            r.setBuffer(vsm.draws, offset: 0, index: 18)
            r.setBuffer(vsm.renderList, offset: 0, index: 30)
            r.setRenderPipelineState(pipelines.vsmClear)
            r.setDepthStencilState(clearState)
            r.drawTriangles(indirectBuffer: vsm.counters, indirectBufferOffset: 32)
            r.setRenderPipelineState(pipelines.vsm)
            r.setDepthStencilState(depthState)
            r.clampDepth()
            r.drawTriangles(indirectBuffer: vsm.counters, indirectBufferOffset: 0)
        }
    }

    private func megaLightsTargets(width: Int, height: Int, capacity: Int) -> MegaLightsTargets? {
        if let m = megaLightsGrid, m.width == width, m.height == height, m.capacity == capacity { return m }
        megaLightsGrid = try? MegaLightsTargets(device: device, width: width, height: height, capacity: capacity)
        megaLightsWritten = false
        return megaLightsGrid
    }
    private static let overlapEnabled = ProcessInfo.processInfo.environment["METALRENDERER_OVERLAP"] != "0"
    /// Reference "Path traced": METALRENDERER_PT_SOBOL=0 draws white noise instead of Owen-scrambled Sobol (A/B).
    private static let pathTraceSobol = ProcessInfo.processInfo.environment["METALRENDERER_PT_SOBOL"] != "0"
    /// Reference "Path traced": up to this many lights (PT_LIGHT_HITS in PathTrace.metal), each is weighed at every
    /// point and bounce rays test them one by one; above, the light tree draws them and rays meet their proxies.
    static let pathTraceLightHits = 32
    /// Frames between full TLAS rebuilds (refits in between). `METALRENDERER_TLAS=1` rebuilds every frame.
    private static let tlasRebuildInterval = max(1, Int(ProcessInfo.processInfo.environment["METALRENDERER_TLAS"] ?? "") ?? 16)
    /// The Metal TLAS is refit most frames (see encodeSceneUpdate), so it is built for a fast build. A quality build
    /// (`METALRENDERER_TLAS_BUILD=default`) traces no faster on an M4 Max, and one for fast intersection (`fast`,
    /// macOS 26) 5% slower with 2000 moving objects.
    private static let tlasUsage: MTLAccelerationStructureUsage = {
        switch ProcessInfo.processInfo.environment["METALRENDERER_TLAS_BUILD"] {
        case "default": return [.refit]
        case "fast": if #available(macOS 26.0, *) { return [.preferFastIntersection, .refit] } else { return [.refit] }
        default: return [.preferFastBuild, .refit]
        }
    }()
    /// Metal's per-mesh structures: built for fast intersection (macOS 26) and compacted. `METALRENDERER_BLAS=default`
    /// builds them as before, `fast` or `compact` turns on one of the two, for A/B timing.
    private static let blasMode = ProcessInfo.processInfo.environment["METALRENDERER_BLAS"] ?? "fast+compact"
    private static let fastIntersectionBLAS = blasMode.contains("fast")
    private static let compactBLAS = blasMode.contains("compact")

    /// Threadgroup size per kernel (8x8 unless set here), indexed by `Kernel`. `METALRENDERER_TG="trace=16x8,atrous=32x4"`
    /// overrides it for sweeps: a kernel goes by its `Kernel` case, capitals and spaces aside ("restir gi initial").
    /// Measured on an M1 Max: trace 16x8 is ~2% faster than 8x8, atrous 16x16 ~5%; others don't care.
    /// The shadow temporal kernel's 8x8 group is its tile (it declares max_total_threads_per_threadgroup(64)): leave it.
    private static let threadgroupSizes: [MTLSize] = {
        var sizes = [MTLSize](repeating: MTLSize(width: 8, height: 8, depth: 1), count: Kernel.allCases.count)
        sizes[Kernel.trace.rawValue] = MTLSize(width: 16, height: 8, depth: 1)
        sizes[Kernel.atrous.rawValue] = MTLSize(width: 16, height: 16, depth: 1)
        sizes[Kernel.regirBuild.rawValue] = MTLSize(width: 64, height: 1, depth: 1)
        sizes[Kernel.megaLightsCull.rawValue] = MTLSize(width: 16, height: 16, depth: 1)   // its tile: leave it
        sizes[Kernel.focus.rawValue] = MTLSize(width: 1, height: 1, depth: 1)   // one thread
        for item in (ProcessInfo.processInfo.environment["METALRENDERER_TG"] ?? "").split(separator: ",") {
            let kv = item.split(separator: "="), wh = kv.count == 2 ? kv[1].split(separator: "x").compactMap { Int($0) } : []
            let name = (kv.first ?? "").lowercased().filter { $0 != " " }
            if wh.count == 2, let kernel = Kernel.allCases.first(where: { "\($0)".lowercased() == name }) {
                sizes[kernel.rawValue] = MTLSize(width: wh[0], height: wh[1], depth: 1)
            } else {
                print("METALRENDERER_TG: can't read \(item) (kernel=WxH, kernels as in Pipelines.swift)")
            }
        }
        return sizes
    }()

    /// The light grid's per-frame origin jitter, in cells ([0, 1)^3), from a hash of the frame index.
    private static func regirJitter(frame: UInt32) -> SIMD3<Float> {
        func hash(_ v: UInt32) -> UInt32 {
            let s = v &* 747796405 &+ 2891336453
            let w = ((s >> ((s >> 28) &+ 4)) ^ s) &* 277803737
            return (w >> 22) ^ w
        }
        let h0 = hash(frame), h1 = hash(h0), h2 = hash(h1)
        return SIMD3(Float(h0 >> 8), Float(h1 >> 8), Float(h2 >> 8)) * (1.0 / 16777216.0)
    }

    private func dispatch(_ enc: ComputePass, _ kernel: Kernel, width: Int, height: Int) {
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                            threadsPerThreadgroup: Renderer.threadgroupSizes[kernel.rawValue])
    }

    private func updateTitle(width: Int, height: Int, outWidth: Int, outHeight: Int) {
        fpsFrames += 1
        let now = CACurrentMediaTime()
        guard now - fpsTime >= 0.5 else { return }
        fps = Double(fpsFrames) / (now - fpsTime)
        fpsFrames = 0
        fpsTime = now
        let s = settings
        func withBounces(_ name: String, _ n: Int) -> String { "GI \(name), \(n) bounce\(n == 1 ? "" : "s")" }
        let gi = !s.giEnabled ? "GI off" : s.giMode == .pathTraced ? withBounces("path traced", s.bounces)
            : s.giMode == .restirGI ? withBounces("ReSTIR", s.restirGI.bounces) : "GI \(s.giMode.title.lowercased())"
        let res = outWidth > width ? String(format: "%ld×%ld → MetalFX denoiser %ld×%ld", width, height, outWidth, outHeight)
                                   : String(format: "%ld×%ld", width, height)
        var stats = String(format: "%@ — %.0f fps — GPU %.1f ms", res, fps, gpuMs)
        switch referenceMode {
        case .pathTraced: stats += " — reference: \(pathTraceCount) paths/pixel"
        case .accumulated where benchmark == nil: stats += " — reference: \(accumCount) frames"
        default: break
        }
        var sceneName = s.scene.kind == .stress ? " — stress: \(s.scene.objects) objects, \(s.scene.lights) lights" : ""
        if scene.lights.count > 4 { sceneName += " — direct: \(activeDirectMode.title)" }
        if let loading { sceneName += " — loading \(loading.scene.kind.title)…" }
        if let vg = customRT?.virtualGeometry {
            sceneName += String(format: " — %d clusters, %.0f MB", vg.stats.selected, vg.residentMB)
        }
        if let vg = customRT?.virtualBLAS {
            sceneName += String(format: " — VG %.1fM triangles, %.0f MB", Double(vg.stats.triangles) / 1e6, vg.stats.megabytes)
        }
        if let ts = textureStreamer { sceneName += String(format: " — textures %.0f MB", ts.stats.residentMB) }
        if frozenLOD != nil && lodFreezes { sceneName += " — LOD frozen" }
        surface?.title = String(format: "MetalRenderer%@ — %@ — %@ — %@ RT — %@ noise — denoiser %@ — %@%@",
                                sceneName, stats, gi, s.rayTracer == .custom ? "custom" : "Metal",
                                s.blueNoise ? "blue" : "white", s.denoiser.enabled ? "on" : "off",
                                RenderSettings.viewModes[s.viewMode].lowercased(), s.paused ? " — paused" : "")
        statsLine = stats
        cpuMs = frameIntervalCount > 0 ? frameIntervalSum / Double(frameIntervalCount) : 0
        frameIntervalSum = 0
        frameIntervalCount = 0
        encodeMs = encodeCount > 0 ? encodeSum / Double(encodeCount) : 0
        encodeSum = 0
        encodeCount = 0
        if traversalFrames > 0 { traversal = (traversalSum, traversalFrames) }
        traversalSum = TraversalStats()
        traversalFrames = 0
        var status = RendererStatus(directMode: activeDirectMode, traversalCounters: traversalCounters,
                                    debugInfo: debugActive ? debugInfo() : nil)
        if passTimeFrames > 0 {
            let n = Double(passTimeFrames)
            var times = passTimeOrder.map { (name: $0, ms: passTimeSums[$0]! / n) }
            let other = passTimeFrameMs / n - times.reduce(0) { $0 + $1.ms }
            if other > 0.005 { times.append((name: "other", ms: other)) }   // MetalFX, its copy, texture streaming
            status.passTimes = times
            passTimeOrder = []
            passTimeSums = [:]
            passTimeFrameMs = 0
            passTimeFrames = 0
        }
        onTick?(status)
    }

    /// One frame's pass timings, summed until the stats line shows their average.
    private func addPassTimes(_ times: [(name: String, ms: Double)], frameMs: Double) {
        guard profilePasses else { return }
        for t in times {
            if passTimeSums[t.name] == nil { passTimeOrder.append(t.name) }
            passTimeSums[t.name, default: 0] += t.ms
        }
        passTimeFrameMs += frameMs
        passTimeFrames += 1
    }

    /// Recompiles the shaders and remakes every pipeline (R key, traversal counters), in the background: frames keep
    /// the old pipelines until the new set is ready, and for good if the compile fails. `done` gets the outcome (render
    /// thread).
    func reloadShaders(then done: ((Bool) -> Void)? = nil) {
        // Without pipelines yet (the launch's compile failed, or is still running): for the scene as it was built.
        let device = device, url = shaderURL
        let kind = pipelines?.kind ?? builtRayTracer, lightTypes = pipelines?.lightTypes ?? scene.lightTypeMask
        let api = pipelines?.api ?? builtAPI, compiler = compiler(for: api)
        let stats = CustomRayTracer.statsEnabled
        shaderQueue.async { [weak self] in
            let result = Result {
                try Pipelines(device: device, source: url, kind: kind, api: api, compiler: compiler, lightTypes: lightTypes, stats: stats)
            }
            self?.renderThread.perform {
                guard let self else { return }
                switch result {
                case .success(let made):
                    // A scene with another tracer or other light types came in meanwhile: compile again, for that one.
                    if let current = self.pipelines,
                       made.kind != current.kind || made.api != current.api || made.lightTypes != current.lightTypes {
                        return self.reloadShaders(then: done)
                    }
                    self.pipelines = made
                    self.shaderGeneration += 1
                    self.customRT?.pipelines = made.rt
                    self.resetGIState()
                    if !self.benchmarkAccumulating { self.resetReference() }
                    self.upscalerReset = true
                    done?(true)
                case .failure(let error):
                    print(self.pipelines == nil ? "Shaders failed to compile (fix them and press R):\n\(error)"
                                                : "Shader reload failed (keeping previous version):\n\(error)")
                    if self.pipelines == nil { self.surface?.title = "MetalRenderer — the shaders failed to compile (see the console, then press R)" }
                    done?(false)
                }
            }
        }
    }

    /// The launch's compile, in the background (the app; a benchmark compiles in `init`). Until it is done `draw`
    /// returns at once, and with it everything that needs pipelines: scene loads start there. A failure is printed
    /// and leaves the window empty; R compiles again.
    private func startCompilingShaders() {
        surface?.title = "MetalRenderer — compiling shaders…"
        reloadShaders { ok in
            DispatchQueue.main.async { Launch.mark(ok ? "shaders" : "shaders (failed)") }
        }
    }
    private let shaderQueue = DispatchQueue(label: "MetalRenderer.shaders", qos: .userInitiated)   // reloads, one at a time

    /// The custom tracer's traversal counters (RT_STATS).
    var traversalCounters: Bool { CustomRayTracer.statsEnabled }

    /// Turns the traversal counters on or off: that recompiles the shaders (in the background, `done` when ready).
    func setTraversalCounters(_ on: Bool, then done: (() -> Void)? = nil) {
        guard on != CustomRayTracer.statsEnabled else { done?(); return }
        CustomRayTracer.statsEnabled = on
        reloadShaders { [weak self] ok in
            if !ok { CustomRayTracer.statsEnabled = !on }
            self?.traversalLast = nil
            self?.traversal = nil
            self?.traversalSum = TraversalStats()
            self?.traversalFrames = 0
            done?()
        }
    }

    /// Freeze LOD does something: it holds the custom tracer's cut of the virtual meshes and its plants' voxel levels
    /// (`detailView`). The open world's tiles follow the camera regardless.
    private var lodFreezes: Bool {
        (customRT != nil && (scene.usesVirtualGeometry || (scene.hasPlants && scene.usesAssemblies))) || sceneBuffers?.voxelLOD != nil
    }

    /// Why the view shown has nothing (or less than its name says) to show for this scene and these settings; nil if
    /// it shows what it says.
    private var viewNote: String? {
        let virtual = scene.instances.contains { $0.virtualMesh >= 0 }
        switch settings.viewMode {
        case 5 where neuralDenoise:
            return "History length is the SVGF denoiser's: MetalFX's denoising scaler keeps its own history."
        case 5 where !denoiserOn:
            return "The denoiser is off: no history."
        case 7 where !settings.giEnabled || ![.radianceCascades, .restirGI, .lumen].contains(activeGIMode):
            return "GI debug is drawn by radiance cascades, ReSTIR GI and Lumen only."
        case 9...10 where !virtual:
            return "Clusters and groups belong to virtual geometry (custom tracer, glTF meshes of 64K+ triangles: the "
                + "gallery or added models). Other geometry shows its level of detail, faded."
        case 11 where !virtual && !(scene.hasPlants && scene.usesAssemblies) && !scene.meshes.contains(where: { $0.lod != 0 }):
            return "Nothing in this scene has levels of detail: virtual geometry needs the custom tracer and big glTF "
                + "meshes; plants, crowds and the open world's tiles have theirs."
        case 13 where builtRayTracer == .metal:
            return "Metal's tracer can't count its traversal: magenta. Switch to the custom tracer for the cost."
        case 14 where !settings.fog.enabled:
            return "Fog is off."
        default:
            return nil
        }
    }

    /// What the Debug window shows (built when it asks, on the stats tick).
    func debugInfo() -> DebugInfo {
        var d = DebugInfo()
        d.stats = statsLine
        d.cpuMs = cpuMs
        d.encodeMs = encodeMs
        d.sceneTitle = settings.scene.kind.title
        d.instances = sceneBuffers.instanceCount
        d.virtualInstances = scene.instances.filter { $0.virtualMesh >= 0 }.count
        let assemblyTriangles = scene.assemblies.map { $0.parts.reduce(0) { $0 + Int(scene.meshes[$1.mesh].indexCount) / 3 } }
        d.triangles = scene.instances.reduce(0) {
            $0 + ($1.mesh >= 0 ? Int(scene.meshes[$1.mesh].indexCount) / 3 : $1.assembly >= 0 ? assemblyTriangles[$1.assembly] : 0)
        }
        d.triangles += sceneBuffers.instanceBlocks.reduce(0) { sum, block in
            sum + block.triangles { mesh, assembly in mesh.map { Int(scene.meshes[$0].indexCount) / 3 } ?? assemblyTriangles[assembly!] }
        }
        d.suns = scene.lights.filter { $0.kind.isSun }.count
        d.analyticLights = Int(scene.lightGroupEnd.w) - d.suns   // spheres, spots, rects, tubes
        d.meshLights = scene.meshLights.count
        d.lightTable = scene.usesLightTable
        d.lightTableEntries = scene.lightTable.entries.count
        d.directMode = activeDirectMode == .grouped && scene.lightGroupEnd.w <= 4 ? "Exact (4 lights or fewer)" : activeDirectMode.title
        d.giMode = !settings.giEnabled ? "Off" : activeGIMode.title
        d.rayTracer = builtRayTracer.title
        d.customTracer = customRT != nil
        if let vg = customRT?.virtualBLAS {
            d.vg = .blas(meshes: vg.meshCount, instances: vg.instanceCount, sourceTriangles: vg.sourceTriangles,
                         triangles: vg.stats.triangles, clusters: vg.stats.clusters, megabytes: vg.stats.megabytes,
                         rebuilds: vg.stats.rebuilds, lastBuildMs: vg.stats.lastBuildMs, lastRefineMs: vg.stats.lastRefineMs,
                         lastCutMs: vg.stats.lastCutMs, skipped: vg.stats.skippedInstances,
                         builder: VirtualBLAS.builder.rawValue, busy: vg.isBusy)
        } else if let vg = customRT?.virtualGeometry {
            d.vg = .clusters(meshes: vg.meshCount, instances: vg.instanceCount, clusters: vg.clusterCount, groups: vg.groupCount,
                             sourceTriangles: vg.sourceTriangles, triangles: vg.stats.triangles, selected: vg.stats.selected, capacity: VirtualGeometry.capacity, overflow: vg.stats.overflow,
                             residentGroups: vg.stats.residentGroups, residentMB: vg.residentMB, poolMB: vg.poolBytes >> 20,
                             pending: vg.stats.pending, loadedThisFrame: vg.stats.loadedThisFrame)
        }
        if let rc = rasterClusters, rasterScene?.virtualClusters == true || shadowClusters {
            let s = rc.stats
            d.rasterClusters = (rc.drawnByCamera, s.drawn, RasterClusters.capacity, s.overflow, s.retested, s.triangles, s.residentGroups, rc.streamer.groupCount,
                                rc.streamer.residentMB, rc.streamer.poolBytes >> 20, s.pending, s.loadedThisFrame)
        }
        d.vgPixelError = settings.virtualGeometry.pixelError
        d.vgFrozen = frozenLOD != nil && lodFreezes
        d.lodFreezes = lodFreezes
        d.viewNote = viewNote
        if let ts = textureStreamer {
            d.textures = (ts.stats.residentMB, ts.budgetBytes >> 20, ts.stats.levelsMapped, ts.stats.uploadedMB)
        }
        d.allocatedMB = Double(device.currentAllocatedSize) / 1_048_576
        d.workingSetMB = Double(device.recommendedMaxWorkingSetSize) / 1_048_576
        d.traversal = traversal
        return d
    }

    /// Adds glTF models to the scene, side by side 2.5 m in front of the camera on the floor, facing it
    /// (glTF models face +Z); the scene reloads in the background. An HDR image (.hdr, .exr) becomes the sky.
    func addModels(_ urls: [URL]) {
        if let image = urls.last(where: { SkyImage.fileExtensions.contains($0.pathExtension.lowercased()) }) {
            settings.sky.mode = .image
            settings.sky.imagePath = image.path
            skyImageFailed = nil
        }
        let urls = urls.filter { !SkyImage.fileExtensions.contains($0.pathExtension.lowercased()) }
        guard !urls.isEmpty else { return }
        var forward = camera.forward
        forward.y = 0
        forward = length(forward) > 1e-4 ? normalize(forward) : SIMD3(0, 0, -1)
        let right = SIMD3<Float>(-forward.z, 0, forward.x)
        var center = camera.position + forward * 2.5
        center.y = 0
        for (i, url) in urls.enumerated() {
            let offset = (Float(i) - Float(urls.count - 1) / 2) * 1.8
            settings.scene.extraModels.append(ExtraModel(path: url.path, position: center + right * offset, yaw: -camera.yaw))
        }
    }

    // MARK: - Input (from RendererController)

    /// A key went down: `key` is its character without modifiers, lowercased.
    func keyDown(_ key: String, isRepeat: Bool) {
        if ["w", "a", "s", "d", "q", "e"].contains(key) {
            heldKeys.insert(key)
            return
        }
        if isRepeat { return }
        switch key {
        case " ": settings.paused.toggle()
        case "g": settings.giEnabled.toggle()
        case "m": settings.giMode = GIMode(rawValue: (settings.giMode.rawValue + 1) % GIMode.allCases.count) ?? .pathTraced
        case "b": settings.blueNoise.toggle()
        case "n": settings.denoiser.enabled.toggle()
        case "[", "]":
            let step = key == "[" ? -1 : 1
            if settings.giMode == .restirGI { settings.restirGI.bounces = RenderSettings.bounceRange.clamp(settings.restirGI.bounces + step) }
            else { settings.bounces = RenderSettings.bounceRange.clamp(settings.bounces + step) }
        case "-": settings.renderScale = max(RenderSettings.renderScaleRange.lowerBound, settings.renderScale - RenderSettings.renderScaleStep)
        case "=", "+": settings.renderScale = min(RenderSettings.renderScaleRange.upperBound, settings.renderScale + RenderSettings.renderScaleStep)
        case "1", "2", "3", "4", "5", "6", "7", "8": settings.viewMode = Int(key)! - 1
        case "9":   // cycle the geometry debug views
            let views = RenderSettings.geometryViews
            settings.viewMode = views.contains(settings.viewMode) && settings.viewMode < views.upperBound
                ? settings.viewMode + 1 : views.lowerBound
        case "0": settings.viewMode = 0
        case "l": settings.virtualGeometry.freeze.toggle()
        case "t":   // Reference: off, accumulated passes, path traced
            settings.reference.mode = ReferenceMode(rawValue: (settings.reference.mode.rawValue + 1) % ReferenceMode.allCases.count) ?? .off
        case "u":
            guard upscaleSupported else { print("The MetalFX denoiser is not supported on this GPU or system"); break }
            let steps = upscaleSteps
            settings.upscaleFactor = steps[((steps.firstIndex(of: settings.upscaleFactor) ?? 0) + 1) % steps.count]
        case "r": reloadShaders { if $0 { print("Shaders reloaded") } }
        default: break
        }
    }

    func keyUp(_ key: String) { heldKeys.remove(key) }

    /// Shift: faster movement.
    func setShift(_ held: Bool) { shiftHeld = held }

    /// A click on a body grabs it where the cursor meets it (Physics.swift's `grab`); anywhere else, the drag turns the
    /// camera.
    func mouseDown(at cursor: SIMD2<Float>) {
        holding = nil
        guard let physics = scene.physics else { return }
        let direction = cursorRay(cursor)
        guard let hit = physics.pick(origin: camera.position, direction: direction) else { return }
        let point = camera.position + direction * hit.distance
        physics.grab = GPUPhysicsGrab(target: SIMD4(point, 1), anchor: SIMD4(hit.anchor, 0), body: UInt32(hit.body))
        holding = (cursor, dot(point - camera.position, camera.forward))
    }

    func mouseDragged(dx: Float, dy: Float, at cursor: SIMD2<Float>) {
        if holding != nil {
            holding?.cursor = cursor
            return
        }
        camera.yaw += dx * 0.004
        camera.pitch = min(max(camera.pitch - dy * 0.004, -1.5), 1.5)
    }

    /// Lets go: the body keeps its speed (a flick throws it).
    func mouseUp() {
        holding = nil
        scene.physics?.grab.target.w = 0
    }

    /// While holding: the body nearer (down) or farther (up).
    func scrolled(dy: Float) {
        guard let depth = holding?.depth else { return }
        holding?.depth = max(depth * exp(dy * 0.05), 0.3)
    }

    /// The ray from the camera through `cursor` (0...1 across and down), unjittered.
    private func cursorRay(_ cursor: SIMD2<Float>) -> SIMD3<Float> {
        let t = tan(camera.fovY / 2)
        return normalize(camera.forward + camera.right * ((2 * cursor.x - 1) * t * viewAspect) + camera.up * ((1 - 2 * cursor.y) * t))
    }

    /// The held body's target this frame: under the cursor, on the plane facing the camera at the grab's depth (so it
    /// follows the camera as it moves too).
    private func moveGrab() {
        guard let holding, let physics = scene.physics, physics.grab.target.w > 0 else { return }
        let direction = cursorRay(holding.cursor)
        let along = holding.depth / max(dot(direction, camera.forward), 0.1)
        physics.grab.target = SIMD4(camera.position + direction * along, 1)
    }
}
