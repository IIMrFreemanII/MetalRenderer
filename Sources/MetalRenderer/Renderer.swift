import AppKit
import MetalKit
import QuartzCore
import simd

enum RendererError: Error, CustomStringConvertible {
    case missingFunction(String)
    case resourceCreation(String)

    var description: String {
        switch self {
        case .missingFunction(let name): return "Shader function '\(name)' not found in Shaders.metal"
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
    let upscaleColor: MTLTexture    // tonemapped linear color at render resolution
    let deviceDepth: MTLTexture     // reversed-Z depth (near / viewDepth)
    let pixelMotion: MTLTexture     // previous pixel position - this pixel position, unjittered

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

/// ReSTIR DI's per-pixel state (Shaders.metal "ReSTIR DI").
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

/// ReSTIR GI's per-pixel state (Shaders.metal "ReSTIR GI"). A reservoir is two textures: rgba32F (x_s, W) and rgba32Uint
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

/// Dispatches that depend only on earlier stages, never on each other. `pass` names the benchmark timing column.
struct ComputeStage {
    let pass: String
    let encode: (MTLComputeCommandEncoder) -> Void
}

final class Renderer: NSObject, MTKViewDelegate, InputHandler {
    private static let maxFramesInFlight = 3
    /// Layout of MTLAccelerationStructureInstanceDescriptor: packed 4x3 float matrix + 4 x uint32.
    private static let instanceDescriptorStride = 64

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private weak var view: MTKView?
    private var scene = Scene()
    private let shaderURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Shaders.metal")

    // Pipelines
    private var tracePSO: MTLComputePipelineState!
    private var geometryDebugPSO: MTLComputePipelineState!
    private var frozenLOD: (SIMD3<Float>, Float)?   // "Freeze LOD": camera position and pixel scale it was turned on at
    private var temporalPSO: MTLComputePipelineState!
    private var atrousPSO: MTLComputePipelineState!
    private var shadowTemporalPSO: MTLComputePipelineState!
    private var shadowFilterPSO: MTLComputePipelineState!
    private var compositePSO: MTLComputePipelineState!
    private var accumulatePSO: MTLComputePipelineState!
    private var lightMapPSO: MTLComputePipelineState!
    private var manyLightsPSO: MTLComputePipelineState!
    private var manyLightsReusePSO: MTLComputePipelineState!
    private var regirBuildPSO: MTLComputePipelineState!
    private var restirTemporalPSO: MTLComputePipelineState!
    private var restirSpatialPSO: MTLComputePipelineState!
    private var restirGIInitialPSO: MTLComputePipelineState!
    private var restirGITemporalPSO: MTLComputePipelineState!
    private var restirGISpatialPSO: MTLComputePipelineState!
    private var meshLightsPSO: MTLComputePipelineState!
    private var reflectionPSO: MTLComputePipelineState!
    private var fogInjectPSO: MTLComputePipelineState!
    private var fogIntegratePSO: MTLComputePipelineState!
    private var fogReferencePSO: MTLComputePipelineState!
    private var skyPSO: MTLComputePipelineState!
    private var cloudShadowPSO: MTLComputePipelineState!
    private var cloudNoisePSO: MTLComputePipelineState!
    private var skyMeanPSO: MTLComputePipelineState!
    private var transmittanceLUTPSO: MTLComputePipelineState!
    private var multiScatterLUTPSO: MTLComputePipelineState!
    private var rcPipelines: RCPipelines!
    private var radianceCascades: RadianceCascades?   // created on first use of the radiance-cascades GI mode

    // Static geometry
    private var positionBuffer: MTLBuffer!
    private var normalBuffer: MTLBuffer!
    private var indexBuffer: MTLBuffer!
    private var meshBuffer: MTLBuffer!
    private var materialBuffer: MTLBuffer!
    private var uvBuffer: MTLBuffer!
    private var emissiveBuffer: MTLBuffer!            // emissive-mesh lights' triangles (MSL EmissiveTriangle)
    private var materialTextures: [MTLTexture] = []   // Scene.textures, decoded (MaterialTextures.swift)
    private var textureTable: MTLBuffer!              // their MTLResourceIDs (MSL MaterialTexture array)
    private var shadingArgs: [MTLBuffer] = []         // per slot, MSL SceneShading: materials, UVs, textures, streaming (buffer 7)
    private var shadingResources: [MTLResource] = []
    private var textureStreamer: TextureStreamer?     // full-resolution textures, streamed per mip (sparse)
    private var staticMinLod: MTLBuffer!              // without streaming: every level resident (zeros)
    private var feedbackDummy: MTLBuffer!
    private var primitiveAS: [MTLAccelerationStructure] = []           // Metal ray tracer only
    private var primitiveASResources: [MTLResource] = []
    private var customRT: CustomRayTracer? {                           // custom ray tracer only
        didSet { traversalLast = nil }   // a new tracer's counters start at 0
    }
    private var rtPipelines: RTPipelines?
    /// The tracer the shaders were compiled for and the scene's structures were built for.
    private var builtRayTracer = RayTracerKind.initial
    private var shaderLibrary: (kind: RayTracerKind, library: MTLLibrary)?
    private var builtLightTypes: UInt32 = 0   // the light types the pipelines are specialised for
    private var blueNoiseTexture: MTLTexture!   // filled the first time blue noise is turned on
    /// Light-map side: 128 for up to 16 lights, then smaller so all maps together cost about 16 128^2 maps to trace.
    static func lightMapSize(lightCount: Int) -> Int {
        lightCount <= 16 ? 128 : max(32, Int(128 * (16 / Double(lightCount)).squareRoot()) / 8 * 8)
    }
    private var lightMap: MTLTexture!           // per-light distance maps (texture array), see lightMapKernel
    private var blueNoiseFilled = false
    // Volumetric fog (Shaders.metal "Volumetric fog"), allocated when first turned on.
    private var fogNoiseTexture: MTLTexture?    // tiling 3D density noise (FogNoise)
    private var fogGrid: FogTargets?            // froxel grid at the current render resolution
    private var fogReference: MTLTexture?       // per-pixel reference march (benchmark references)
    private var fogLastFrame: UInt32?           // the frame that last wrote the froxel grid, and its far distance:
    private var fogLastFar: Float = 0           //   history is reprojected only from the frame just before
    private var dummy3D: MTLTexture!            // bound in place of the fog textures while fog is off
    private var dummy2D: MTLTexture!
    private var dummyArray: MTLTexture!         // in place of the sky texture with a constant sky
    // Sky and clouds (Shaders.metal "Sky and clouds"), allocated when first used.
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
    private var skyParams = GPUSkyParams()      // this frame's (also written into the shading arguments)
    private var skyActive = false               // this frame uses the sky texture
    private var skyRefreshed: (sky: SkySettings, scene: ObjectIdentifier)?   // what the sky texture was fully drawn for
    private var atmosphereCache: (sun: SIMD3<Float>, ground: SIMD3<Float>)?
    /// Shading-argument layout (MSL SceneShading): six buffer addresses, the sky and cloud-shadow textures, SkyParams.
    private static let shadingSkyOffset = 48, shadingParamsOffset = 64
    private static let shadingArgsLength = 64 + MemoryLayout<GPUSkyParams>.stride

    // Per-frame-in-flight resources (the CPU writes these while the GPU may still read older ones)
    private var instanceDescBuffers: [MTLBuffer] = []
    private var instanceDataBuffers: [MTLBuffer] = []
    private var lightBuffers: [MTLBuffer] = []      // per slot: the lights, then the light table (LightTable)
    private var prevLightBuffers: [MTLBuffer] = []  // per slot: the frame before's lights (ReSTIR's temporal reuse)
    private var lastFrameLights: [GPULight] = []
    private var restirGrid: RestirTargets?
    private var regirBuffer: MTLBuffer?             // the light grid's reservoirs (GPURegirReservoir), GPU only
    private var regirParams = GPURegirParams()      // this frame's grid (consume.x = 0: off), bound with the scene
    private var restirWritten = false               // last frame's ReSTIR pass stored its reservoirs
    private var restirGIGrid: RestirGITargets?
    private var restirGIWritten = false             // last frame's ReSTIR GI pass stored its reservoirs (and feedback)
    private var instanceAS: [MTLAccelerationStructure] = []
    private var instanceScratch: [MTLBuffer] = []
    private var instanceASBuilt = Set<Int>()
    private let frameSemaphore = DispatchSemaphore(value: Renderer.maxFramesInFlight)

    private var targets: RenderTargets?

    // State
    private var camera = Camera()
    private var prevCamera = Camera()
    private var frameIndex: UInt32 = 0
    private var animTime: Float = 0
    private var lastTime = CACurrentMediaTime()
    /// User-adjustable settings, shared by the keyboard shortcuts and the settings panel.
    var settings = RenderSettings() {
        didSet {
            guard settings != oldValue else { return }
            if settings.giMode != oldValue.giMode { resetGIState() }
            if persistSettings { SettingsStore.save(settings) }
            for observer in settingsObservers { observer(settings) }
        }
    }
    private var persistSettings = false         // the app (not benchmarks), once the saved settings are loaded
    /// GPU pass timings for the settings panel (GPUProfiler): per frame, then averaged over the stats interval.
    var profilePasses = false
    var onPassTimes: (([(name: String, ms: Double)]) -> Void)?
    var passProfilingSupported: Bool { GPUProfiler.isSupported(on: device) }
    /// This frame's direct-light method with Auto resolved, for the panel's denoiser caption.
    var directModeInUse: DirectLightMode { activeDirectMode }
    private var settingsObservers: [(RenderSettings) -> Void] = []
    private var tickObservers: [() -> Void] = []
    /// Calls `observer` with the settings after every change (panel edits, keyboard shortcuts, scene loads).
    func observeSettings(_ observer: @escaping (RenderSettings) -> Void) { settingsObservers.append(observer) }
    /// Calls `observer` twice a second, when the stats (fps, GPU time, `statsLine`) are refreshed.
    func observeTick(_ observer: @escaping () -> Void) { tickObservers.append(observer) }
    var onTogglePanel: (() -> Void)?            // Tab key
    var onToggleDebug: (() -> Void)?            // I key
    /// Every frame once its GPU work is done (main thread): the CPU time since the previous frame started and the GPU
    /// time, both in ms. For the Debug window's graph; nil while it's hidden.
    var onFrameTime: ((_ cpuMs: Double, _ gpuMs: Double) -> Void)?
    /// What "Reset to Defaults" restores (differs from RenderSettings() on GPUs without MetalFX).
    private(set) var defaultSettings = RenderSettings()
    /// Resolution, fps and GPU time, refreshed twice a second.
    private(set) var statsLine = ""
    private var upscaler: Upscaler?           // MetalFX (temporal or spatial)
    private var customUpscaler: TemporalUpscaler?
    private var upscalerReset = true          // drop the upscaler's history on the next frame
    private var taauPSO: MTLComputePipelineState!
    private var accumulateColorPSO: MTLComputePipelineState!
    private var supersampling = false         // benchmark reference: jitter + average the final colour
    private var colorAccum: MTLTexture?
    private var colorAccumCount: UInt32 = 0
    private var prevJitter = SIMD2<Float>(repeating: 0)
    // Benchmark reference: average raw frames of a paused scene instead of denoising.
    private var accumulating = false
    private var referenceGIMode: GIMode?                // benchmark references: accumulate this GI method instead of paths
    private var referenceDirectMode: DirectLightMode?   // benchmark references: this direct-light method instead of exact
    private var accumCount: UInt32 = 0
    private var accumTextures: (direct: MTLTexture, indirect: MTLTexture, specular: MTLTexture)?
    private(set) lazy var upscaleSupported = Upscaler.isSupported(on: device)
    private lazy var maxUpscale = CGFloat(Upscaler.maxScale(on: device))
    /// MetalFX factors this GPU supports, with 0 meaning off.
    var upscaleSteps: [CGFloat] { upscaleSupported ? [0, 1.5, 2, 3].filter { $0 <= maxUpscale } : [0] }
    private var historyValid = false
    private var reservoirsWritten = false       // last frame's manyLightsKernel stored light picks (light reuse)
    private var heldKeys = Set<String>()
    private let benchmark: Benchmark? = Benchmark.isEnabled ? Benchmark() : nil

    // Stats
    private var gpuMs: Double = 0
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
    // Traversal counters (Debug window, custom tracer): summed per frame, averaged per stats interval.
    private var traversalSum = TraversalStats(), traversalFrames = 0
    private var traversalLast: [UInt32]?
    private(set) var traversal: (stats: TraversalStats, frames: Int)?

    init(view: RenderView) throws {
        validateGPULayouts()
        guard let device = view.device, let queue = device.makeCommandQueue() else {
            throw RendererError.resourceCreation("command queue")
        }
        self.device = device
        self.queue = queue
        self.view = view
        super.init()

        view.colorPixelFormat = Renderer.drawableFormat
        view.framebufferOnly = false        // the composite kernel or MetalFX writes to the drawable
        view.autoResizeDrawable = false     // we pick the render resolution ourselves
        view.preferredFramesPerSecond = 120
        if benchmark != nil {
            // Benchmark: render back to back without vsync, so the GPU never idles between frames and its clock
            // stays steady (idle gaps let it clock down and inflate the timings of short passes unevenly).
            (view.layer as? CAMetalLayer)?.displaySyncEnabled = false
            view.isPaused = true
            view.enableSetNeedsDisplay = false
            DispatchQueue.main.async { [weak self, weak view] in
                guard let view else { return }
                self?.runBenchmarkLoop(view)
            }
        }

        try loadShaders(for: settings.rayTracer, lightTypes: scene.lightTypeMask)
        try createDummyTextures()
        try createSceneResources()
        try createBlueNoiseTexture()
        if !upscaleSupported {
            // Without MetalFX, a 0.5x render would just be stretched, so render at 0.75x instead.
            print("MetalFX temporal upscaling is not supported on this GPU; rendering at 0.75x without it")
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
            Benchmark.applyInteractiveOverrides(to: &s, defaults: defaultSettings)
            settings = s
            persistSettings = true
            SettingsStore.dumpIfRequested(settings)
        }
    }

    // MARK: - Setup

    /// Compiles Shaders.metal for `kind` (CUSTOM_RT macro). The custom tracer's build kernels exist only in its variant.
    /// Compiles Shaders.metal for `kind` (kept until the tracer changes or `recompile`, the hot reload) and makes
    /// every pipeline, specialised for the scene's light types (function constant 0, see Scene.lightTypeMask).
    private func loadShaders(for kind: RayTracerKind, lightTypes: UInt32, recompile: Bool = false) throws {
        let library: MTLLibrary
        if let cached = shaderLibrary, cached.kind == kind, !recompile {
            library = cached.library
        } else {
            let source = try String(contentsOf: shaderURL, encoding: .utf8)
            let options = MTLCompileOptions()
            // MSL 3.2 for device-scope fences and coherent buffers (rtFitKernel, custom ray tracer). Older systems keep
            // 3.0 and then need METALRENDERER_RT=metal.
            if #available(macOS 15.0, *) { options.languageVersion = .version3_2 } else { options.languageVersion = .version3_0 }
            options.preprocessorMacros = ["CUSTOM_RT": NSNumber(value: kind == .custom ? 1 : 0),
                                          "RT_STATS": NSNumber(value: CustomRayTracer.statsEnabled ? 1 : 0)]
            library = try device.makeLibrary(source: source, options: options)
        }
        let constants = MTLFunctionConstantValues()
        var types = lightTypes
        constants.setConstantValue(&types, type: .uint, index: 0)

        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            let function = try library.makeFunction(name: name, constantValues: constants)
            return try device.makeComputePipelineState(function: function)
        }
        // Build everything first so a failed hot-reload keeps the old pipelines.
        let trace = try pipeline("traceKernel")
        let temporal = try pipeline("temporalKernel")
        let atrous = try pipeline("atrousKernel")
        let shadowTemporal = try pipeline("shadowTemporalKernel")
        let taau = try pipeline("taauKernel")
        let accumulateColor = try pipeline("accumulateColorKernel")
        let shadowFilter = try pipeline("shadowFilterKernel")
        let composite = try pipeline("compositeKernel")
        let accumulate = try pipeline("accumulateKernel")
        let lightMap = try pipeline("lightMapKernel")
        let manyLights = try pipeline("manyLightsKernel")
        let manyLightsReuse = try pipeline("manyLightsReuseKernel")
        let regirBuild = try pipeline("regirBuildKernel")
        let restirTemporal = try pipeline("restirTemporalKernel")
        let restirSpatial = try pipeline("restirSpatialKernel")
        let restirGIInitial = try pipeline("restirGIInitialKernel")
        let restirGITemporal = try pipeline("restirGITemporalKernel")
        let restirGISpatial = try pipeline("restirGISpatialKernel")
        let meshLights = try pipeline("meshLightsKernel")
        let reflection = try pipeline("reflectionKernel")
        let fogInject = try pipeline("fogInjectKernel")
        let fogIntegrate = try pipeline("fogIntegrateKernel")
        let fogReference = try pipeline("fogReferenceKernel")
        let sky = try pipeline("skyKernel")
        let cloudShadow = try pipeline("cloudShadowKernel")
        let cloudNoise = try pipeline("cloudNoiseKernel")
        let skyMeanP = try pipeline("skyMeanKernel")
        let transmittanceLUTP = try pipeline("transmittanceLUTKernel")
        let multiScatterLUTP = try pipeline("multiScatterLUTKernel")
        let geometryDebug = try pipeline("geometryDebugKernel")
        let rt = kind != .custom ? nil :
            RTPipelines(prep: try pipeline("rtPrepKernel"), keys: try pipeline("rtKeysKernel"),
                        sortLocal: try pipeline("rtSortLocalKernel"), sortGlobal: try pipeline("rtSortGlobalKernel"),
                        hierarchy: try pipeline("rtHierarchyKernel"), fit: try pipeline("rtFitKernel"),
                        vg: VGPipelines(reset: try pipeline("vgResetKernel"), cut: try pipeline("vgCutKernel"),
                                        finish: try pipeline("vgFinishKernel"), pad: try pipeline("vgPadKernel"),
                                        hierarchy: try pipeline("vgHierarchyKernel"), fit: try pipeline("vgFitKernel")))
        let rc = RCPipelines(probe: try pipeline("rcProbeKernel"), traceMerge: try pipeline("rcTraceMergeKernel"),
                             sh: try pipeline("rcSHKernel"), clearAmbient: try pipeline("rcClearAmbientKernel"),
                             resolve: try pipeline("rcResolveKernel"))
        tracePSO = trace
        temporalPSO = temporal
        atrousPSO = atrous
        shadowTemporalPSO = shadowTemporal
        taauPSO = taau
        accumulateColorPSO = accumulateColor
        shadowFilterPSO = shadowFilter
        compositePSO = composite
        accumulatePSO = accumulate
        lightMapPSO = lightMap
        manyLightsPSO = manyLights
        manyLightsReusePSO = manyLightsReuse
        regirBuildPSO = regirBuild
        restirTemporalPSO = restirTemporal
        restirSpatialPSO = restirSpatial
        restirGIInitialPSO = restirGIInitial
        restirGITemporalPSO = restirGITemporal
        restirGISpatialPSO = restirGISpatial
        meshLightsPSO = meshLights
        reflectionPSO = reflection
        fogInjectPSO = fogInject
        fogIntegratePSO = fogIntegrate
        fogReferencePSO = fogReference
        skyPSO = sky
        cloudShadowPSO = cloudShadow
        cloudNoisePSO = cloudNoise
        skyMeanPSO = skyMeanP
        transmittanceLUTPSO = transmittanceLUTP
        multiScatterLUTPSO = multiScatterLUTP
        geometryDebugPSO = geometryDebug
        rcPipelines = rc
        rtPipelines = rt
        if let rt { customRT?.pipelines = rt }
        shaderLibrary = (kind, library)
        builtLightTypes = lightTypes
    }

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
        let textures: [MTLTexture]
        let streamer: TextureStreamer?
        let customRT: CustomRayTracer?
    }
    private var loading: (scene: SceneSettings, rayTracer: RayTracerKind)?   // being prepared in the background

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

    private func prepareScene(_ sceneSettings: SceneSettings, rayTracer: RayTracerKind, reuse current: Scene?) throws -> PreparedScene {
        let virtual = wantsVirtualGeometry(rayTracer)
        let newScene = current.flatMap { $0.usesVirtualGeometry == virtual ? $0 : nil } ?? Scene(sceneSettings, virtualGeometry: virtual)
        let streamer = newScene.textures.isEmpty || !TextureStreamer.isSupported(device) ? nil
            : try TextureStreamer(sources: newScene.textures, device: device, queue: queue, budgetMB: settings.textureBudgetMB,
                                  slots: Renderer.maxFramesInFlight)
        let textures = try streamer?.textures ?? MaterialTextures.load(newScene.textures, device: device, queue: queue)
        let rt = rayTracer == .custom ? try CustomRayTracer(device: device, scene: newScene, slots: Renderer.maxFramesInFlight,
                                                            poolMB: settings.virtualGeometry.poolMB) : nil
        return PreparedScene(scene: newScene, rayTracer: rayTracer, textures: textures, streamer: streamer, customRT: rt)
    }

    /// Starts preparing `settings.scene` / `settings.rayTracer` in the background; `install` swaps it in when done.
    private func startLoadingScene() {
        let wanted = (scene: settings.scene, rayTracer: settings.rayTracer)
        if let loading, loading.scene == wanted.scene, loading.rayTracer == wanted.rayTracer { return }
        loading = wanted
        let reuse = wanted.scene == scene.settings ? scene : nil   // only the tracer changes
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.prepareScene(wanted.scene, rayTracer: wanted.rayTracer, reuse: reuse) }
            DispatchQueue.main.async {
                guard let loading = self.loading, loading.scene == wanted.scene, loading.rayTracer == wanted.rayTracer else {
                    return   // superseded by a newer request
                }
                self.loading = nil
                switch result {
                case .success(let prepared):
                    self.install(prepared, resetCamera: prepared.scene.settings.kind != self.scene.settings.kind)
                case .failure(let error):
                    print("Scene load failed, keeping the previous scene: \(error)")
                    self.settings.scene = self.scene.settings
                    self.settings.rayTracer = self.builtRayTracer
                }
            }
        }
    }

    /// Everything sized by the scene: geometry, acceleration structures, per-frame instance / light buffers, light maps.
    private func createSceneResources(_ prepared: PreparedScene? = nil) throws {
        builtRayTracer = prepared?.rayTracer ?? settings.rayTracer
        customRT = nil
        primitiveAS = []
        primitiveASResources = []
        instanceDescBuffers = []
        instanceDataBuffers = []
        lightBuffers = []
        prevLightBuffers = []
        lastFrameLights = []
        restirWritten = false
        restirGIWritten = false
        instanceAS = []
        instanceScratch = []
        instanceASBuilt = []
        textureStreamer = prepared?.streamer
        try createGeometryBuffers(textures: prepared?.textures)
        if builtRayTracer == .metal { try buildPrimitiveAccelerationStructures() }
        try createPerFrameResources()
        if builtRayTracer == .custom {
            customRT = try prepared?.customRT ?? CustomRayTracer(device: device, scene: scene, slots: Renderer.maxFramesInFlight,
                                                                 poolMB: settings.virtualGeometry.poolMB)
            customRT?.pipelines = rtPipelines
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
        do {
            let reuse = settings.scene == scene.settings ? scene : nil
            install(try prepareScene(settings.scene, rayTracer: settings.rayTracer, reuse: reuse), resetCamera: resetCamera)
        } catch {
            print("Scene rebuild failed, keeping the previous scene: \(error)")
            settings.scene = scene.settings
            settings.rayTracer = builtRayTracer
        }
    }

    /// Swaps in a prepared scene. Waits for in-flight frames, since they still read the old buffers.
    private func install(_ prepared: PreparedScene, resetCamera: Bool) {
        for _ in 0..<Renderer.maxFramesInFlight { frameSemaphore.wait() }
        defer { for _ in 0..<Renderer.maxFramesInFlight { frameSemaphore.signal() } }
        let old = scene
        let oldRayTracer = builtRayTracer
        let start = CACurrentMediaTime()
        scene = prepared.scene
        do {
            if prepared.rayTracer != builtRayTracer || scene.lightTypeMask != builtLightTypes {
                try loadShaders(for: prepared.rayTracer, lightTypes: scene.lightTypeMask)
            }
            try createSceneResources(prepared)
        } catch {
            print("Scene rebuild failed, keeping the previous scene: \(error)")
            scene = old
            settings.scene = old.settings
            settings.rayTracer = oldRayTracer
            try? loadShaders(for: oldRayTracer, lightTypes: old.lightTypeMask)
            try? createSceneResources()
        }
        resetGIState()
        upscalerReset = true
        accumCount = 0
        colorAccumCount = 0
        if resetCamera {
            camera = scene.defaultCamera
            prevCamera = camera
        }
        print(String(format: "Scene: %@, %d instances, %d lights, %@ ray tracing (installed in %.0f ms)", scene.settings.kind.title,
                     scene.instances.count, scene.lights.count, builtRayTracer.title, (CACurrentMediaTime() - start) * 1000))
    }

    private func createGeometryBuffers(textures: [MTLTexture]?) throws {
        positionBuffer = try makeBuffer(scene.positions, "positions")
        normalBuffer = try makeBuffer(scene.normals, "normals")
        indexBuffer = try makeBuffer(scene.indices, "indices")
        meshBuffer = try makeBuffer(scene.meshes, "meshes")
        materialBuffer = try makeBuffer(scene.materials, "materials")
        uvBuffer = try makeBuffer(scene.uvs, "uvs")
        emissiveBuffer = try makeBuffer(scene.emissiveTriangles, "emissiveTriangles")
        scene.materialsChanged = false
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
            p.storeBytes(of: materialBuffer.gpuAddress, toByteOffset: 0, as: UInt64.self)
            p.storeBytes(of: uvBuffer.gpuAddress, toByteOffset: 8, as: UInt64.self)
            p.storeBytes(of: textureTable.gpuAddress, toByteOffset: 16, as: UInt64.self)
            p.storeBytes(of: (textureStreamer?.minLodBuffer(slot: slot) ?? staticMinLod).gpuAddress, toByteOffset: 24, as: UInt64.self)
            p.storeBytes(of: (textureStreamer?.feedbackBuffer(slot: slot) ?? feedbackDummy).gpuAddress, toByteOffset: 32, as: UInt64.self)
            p.storeBytes(of: emissiveBuffer.gpuAddress, toByteOffset: 40, as: UInt64.self)
            shadingArgs.append(args)
            writeSkyArguments(slot: slot)
        }
        shadingResources = [materialBuffer, uvBuffer, textureTable, staticMinLod, feedbackDummy, emissiveBuffer]
            + (textureStreamer == nil ? materialTextures : [])
    }

    /// One bottom-level (primitive) acceleration structure per mesh, built once.
    /// For skinned/deforming meshes you would update the vertex buffer and call
    /// `refit(sourceAccelerationStructure:descriptor:destinationAccelerationStructure:scratchBuffer:scratchBufferOffset:)` each frame.
    private func buildPrimitiveAccelerationStructures() throws {
        guard let cmd = queue.makeCommandBuffer(),
              let encoder = cmd.makeAccelerationStructureCommandEncoder() else {
            throw RendererError.resourceCreation("acceleration structure command encoder")
        }
        var scratchBuffers: [MTLBuffer] = []
        for mesh in scene.meshes {
            let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
            geometry.vertexBuffer = positionBuffer
            geometry.vertexBufferOffset = 0
            geometry.vertexStride = MemoryLayout<SIMD3<Float>>.stride
            geometry.indexBuffer = indexBuffer
            geometry.indexBufferOffset = Int(mesh.firstIndex) * MemoryLayout<UInt32>.stride
            geometry.indexType = .uint32
            geometry.triangleCount = Int(mesh.indexCount) / 3
            geometry.opaque = true

            let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
            descriptor.geometryDescriptors = [geometry]

            let sizes = device.accelerationStructureSizes(descriptor: descriptor)
            guard let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
                  let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, 16), options: .storageModePrivate) else {
                throw RendererError.resourceCreation("primitive acceleration structure")
            }
            encoder.build(accelerationStructure: accel, descriptor: descriptor, scratchBuffer: scratch, scratchBufferOffset: 0)
            primitiveAS.append(accel)
            scratchBuffers.append(scratch)
        }
        encoder.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        primitiveASResources = primitiveAS.map { $0 as MTLResource }
    }

    private func createBlueNoiseTexture() throws {
        let n = BlueNoise.size
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: n, height: n, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture blueNoise") }
        texture.label = "blueNoise"
        blueNoiseTexture = texture
    }

    /// Generating the tile takes ~0.5 s, so it only happens once blue noise is first used.
    private func fillBlueNoiseTextureIfNeeded() {
        guard !blueNoiseFilled else { return }
        let n = BlueNoise.size
        let values = BlueNoise.generate()
        values.withUnsafeBytes { raw in
            blueNoiseTexture.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0,
                                     withBytes: raw.baseAddress!, bytesPerRow: n * MemoryLayout<Float>.stride)
        }
        blueNoiseFilled = true
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

    /// The fog's 3D noise, generated the first time fog is on (~50 ms).
    private func fogNoise() -> MTLTexture? {
        if let fogNoiseTexture { return fogNoiseTexture }
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
        fogNoiseTexture = texture
        return texture
    }

    private func fogTargets(width: Int, height: Int) -> FogTargets? {
        if let g = fogGrid, g.renderWidth == width, g.renderHeight == height { return g }
        fogGrid = try? FogTargets(device: device, renderWidth: width, renderHeight: height, slices: FogSettings.slices)
        fogLastFrame = nil
        return fogGrid
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
    private func makeFogParams(grid: FogTargets?, historyValid: Bool) -> GPUFogParams {
        var p = GPUFogParams()
        let f = settings.fog
        guard f.enabled, let grid else { return p }
        let near: Float = 0.2, far = max(f.maxDistance, 1)
        p.medium = SIMD4(FogSettings.densityRange.clamp(f.density) * (f.density > 0 ? 1 : 0), max(f.heightFalloff, 0),
                         f.baseHeight, FogSettings.anisotropyRange.clamp(f.anisotropy))
        p.albedo = SIMD4(f.albedo, max(f.ambient, 0))
        p.noise = SIMD4(f.noise, max(f.noiseScale, 0.1), animTime, 0.1)
        p.wind = SIMD4(f.wind, 0)
        p.grid = SIMD4(near, far, log(far / near), Float(grid.slices))
        let volumes = f.volumes ? Array(scene.fogVolumes.prefix(GPUFogParams.maxVolumes)) : []
        for (i, v) in volumes.enumerated() { p.setVolume(i, v.gpu) }
        p.counts = SIMD4(UInt32(grid.columns), UInt32(grid.rows), UInt32(volumes.count),
                         GPUFogParams.enabled | (historyValid ? GPUFogParams.historyValid : 0)
                         | (f.reflections ? GPUFogParams.reflections : 0))
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
        do {
            let image = try SkyImage.load(path: path, exposure: exposure)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: image.width, height: image.height,
                                                             mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: d) else { return nil }
            texture.label = "sky image"
            image.pixels.withUnsafeBytes { raw in
                texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                                withBytes: raw.baseAddress!, bytesPerRow: image.width * 16)
            }
            skyImage = (path, exposure, image, texture)
            let sun = image.sunDirection.map { String(format: "sun toward (%.3f, %.3f, %.3f), %.2f° across, irradiance %.2f", $0.x, $0.y, $0.z, 2 * image.sunAngularRadius * 180 / .pi, 0.2126 * image.sunIrradiance.x + 0.7152 * image.sunIrradiance.y + 0.0722 * image.sunIrradiance.z) } ?? "no sun"
            print("Sky image: \((path as NSString).lastPathComponent), \(image.width)×\(image.height), \(sun)")
            return (image, texture)
        } catch {
            print("Sky image failed to load (\(path)): \(error)")
            skyImageFailed = path
            return nil
        }
    }

    /// This frame's sky: the sun (from the atmosphere, or the image's), which also sets the scene's sun light (its
    /// colour, and with an image its direction), and the clouds. False for a constant sky (or an image that failed).
    private func updateSky(lights: inout [GPULight]) -> Bool {
        let sky = settings.sky
        guard sky.mode != .constant, ensureSkyTextures() else { return false }
        var image: SkyImage?
        if sky.mode == .image {
            guard let path = sky.imagePath, let loaded = skyImageFor(path, exposure: sky.imageExposure) else { return false }
            image = loaded.image
        }
        let sunIndex = lights.firstIndex { Int($0.color.w) >> 2 == Int(GPULight.sun) }
        var sunDir = normalize(SIMD3<Float>(0.4, 0.5, -0.6)), sunRadius: Float = 0.27 * .pi / 180
        if let d = image?.sunDirection {
            sunDir = d
            sunRadius = image!.sunAngularRadius
        } else if let i = sunIndex {
            sunDir = normalize(SIMD3(lights[i].axis.x, lights[i].axis.y, lights[i].axis.z))
            sunRadius = lights[i].positionRadius.w
        }
        let sunGround: SIMD3<Float>
        if let image {
            sunGround = image.sunDirection == nil ? .zero : image.sunIrradiance
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
        p.sunTop = SIMD4(Atmosphere.solarIrradiance, 0)
        p.sunGround = SIMD4(sunGround, 0)
        p.cloudLayer = SIMD4(sky.cloudBase, sky.cloudBase + max(sky.cloudThickness, 100),
                             SkySettings.coverageRange.clamp(sky.coverage), SkySettings.densityRange.clamp(sky.density))
        p.cloudShape = SIMD4(max(sky.cloudScale, 100), sky.erosion, animTime, sky.shadowStrength)
        p.wind = SIMD4(SIMD3(cos(windAngle), 0, sin(windAngle)) * sky.windSpeed, full ? 1 : 0.5)
        p.shadowMap = SIMD4(sphere.x, sphere.z, max(1.2 * sphere.w, 150), 0)
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
    private func encodeSky(_ cb: MTLCommandBuffer, profile: GPUProfiler.Frame?) {
        func compute() -> MTLComputeCommandEncoder? { profile?.compute(cb, "sky") ?? cb.makeComputeCommandEncoder() }
        guard let sky = skyMap, let shape = cloudShape, let detail = cloudDetail, let shadow = cloudShadowMap,
              let tLUT = transmittanceLUT, let msLUT = multiScatterLUT, let mean = skyMean,
              let enc = compute() else { return }
        if !cloudNoiseReady {   // once: the cloud noise and the atmosphere's tables (the second reads the first)
            enc.setComputePipelineState(cloudNoisePSO)
            enc.setTexture(shape, index: 0)
            enc.setTexture(detail, index: 1)
            enc.dispatchThreads(MTLSize(width: shape.width, height: shape.height, depth: shape.depth),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
            enc.setComputePipelineState(transmittanceLUTPSO)
            enc.setTexture(tLUT, index: 0)
            dispatch(enc, "transmittance", width: tLUT.width, height: tLUT.height)
            enc.setComputePipelineState(multiScatterLUTPSO)
            setTextures(enc, [tLUT, msLUT])
            dispatch(enc, "multiple scattering", width: msLUT.width, height: msLUT.height)
            profile.end(enc)
            if let blit = profile?.blit(cb, "sky") ?? cb.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: shape)
                blit.generateMipmaps(for: detail)
                profile.end(blit)
            }
            cloudNoiseReady = true
            guard let next = compute() else { return }
            encodeSkyTexels(next, sky: sky, shape: shape, detail: detail, shadow: shadow, tLUT: tLUT, msLUT: msLUT, mean: mean, cb: cb,
                            profile: profile)
            return
        }
        encodeSkyTexels(enc, sky: sky, shape: shape, detail: detail, shadow: shadow, tLUT: tLUT, msLUT: msLUT, mean: mean, cb: cb,
                        profile: profile)
    }

    private func encodeSkyTexels(_ enc: MTLComputeCommandEncoder, sky: MTLTexture, shape: MTLTexture, detail: MTLTexture,
                                 shadow: MTLTexture, tLUT: MTLTexture, msLUT: MTLTexture, mean: MTLBuffer, cb: MTLCommandBuffer,
                                 profile: GPUProfiler.Frame?) {
        var p = skyParams
        // The clear sky's mean radiance (lights the clouds and the ground), then this frame's sky texels.
        enc.setComputePipelineState(skyMeanPSO)
        enc.setBytes(&p, length: MemoryLayout<GPUSkyParams>.stride, index: 0)
        enc.setBuffer(mean, offset: 0, index: 1)
        setTextures(enc, [skyImage?.texture ?? dummy2D, tLUT, msLUT])
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        enc.setComputePipelineState(skyPSO)
        enc.setBytes(&p, length: MemoryLayout<GPUSkyParams>.stride, index: 0)
        enc.setBuffer(mean, offset: 0, index: 1)
        setTextures(enc, [shape, detail, blueNoiseTexture, skyImage?.texture ?? dummy2D, sky, tLUT, msLUT])
        let part = p.flags.y & GPUSkyParams.updateAll != 0 ? 1 : 4   // this frame's texels: every one, or 1 in 4x4
        enc.dispatchThreads(MTLSize(width: sky.width / part, height: sky.height / part, depth: 2),
                            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        if p.flags.y & GPUSkyParams.shadows != 0 {
            enc.setComputePipelineState(cloudShadowPSO)
            enc.setBytes(&p, length: MemoryLayout<GPUSkyParams>.stride, index: 0)
            setTextures(enc, [shape, detail, shadow])
            dispatch(enc, "cloud shadow", width: shadow.width, height: shadow.height)
        }
        profile.end(enc)
        if let blit = profile?.blit(cb, "sky") ?? cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: sky)
            profile.end(blit)
        }
    }

    private func instanceASDescriptor(slot: Int) -> MTLInstanceAccelerationStructureDescriptor {
        let d = MTLInstanceAccelerationStructureDescriptor()
        d.instancedAccelerationStructures = primitiveAS
        d.instanceCount = scene.instances.count
        d.instanceDescriptorBuffer = instanceDescBuffers[slot]
        d.instanceDescriptorBufferOffset = 0
        d.instanceDescriptorStride = Renderer.instanceDescriptorStride
        d.instanceDescriptorType = .default
        d.usage = [.preferFastBuild, .refit]   // refit most frames; see draw() (a quality build traces no faster here)
        return d
    }

    private func createPerFrameResources() throws {
        precondition(MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride == Renderer.instanceDescriptorStride)
        let instanceCount = scene.instances.count
        for slot in 0..<Renderer.maxFramesInFlight {
            guard let desc = device.makeBuffer(length: instanceCount * Renderer.instanceDescriptorStride, options: .storageModeShared),
                  let data = device.makeBuffer(length: instanceCount * MemoryLayout<GPUInstanceData>.stride, options: .storageModeShared),
                  let lights = device.makeBuffer(length: max(scene.lights.count * MemoryLayout<GPULight>.stride + scene.lightTable.byteCount, 64),
                                                 options: .storageModeShared),
                  let prevLights = device.makeBuffer(length: max(scene.lights.count, 1) * MemoryLayout<GPULight>.stride,
                                                     options: .storageModeShared) else {
                throw RendererError.resourceCreation("per-frame buffers")
            }
            // The light table, after the lights: written once (it doesn't change while the scene lives).
            var offset = scene.lights.count * MemoryLayout<GPULight>.stride
            scene.lightTable.entries.withUnsafeBytes { raw in
                if raw.count > 0 { lights.contents().advanced(by: offset).copyMemory(from: raw.baseAddress!, byteCount: raw.count) }
                offset += raw.count
            }
            scene.lightTable.triangles.withUnsafeBytes { raw in
                if raw.count > 0 { lights.contents().advanced(by: offset).copyMemory(from: raw.baseAddress!, byteCount: raw.count) }
            }
            lights.label = "lights"
            instanceDescBuffers.append(desc)
            instanceDataBuffers.append(data)
            lightBuffers.append(lights)
            prevLightBuffers.append(prevLights)

            guard builtRayTracer == .metal else { continue }
            let sizes = device.accelerationStructureSizes(descriptor: instanceASDescriptor(slot: slot))
            guard let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
                  let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, sizes.refitScratchBufferSize, 16), options: .storageModePrivate) else {
                throw RendererError.resourceCreation("instance acceleration structure")
            }
            instanceAS.append(accel)
            instanceScratch.append(scratch)
        }
    }

    // MARK: - Per-frame CPU work

    private func writeFrameData(slot: Int) {
        if let customRT { customRT.update(slot: slot, scene: scene) } else { writeInstanceDescriptors(slot: slot) }
        let data = scene.gpuInstanceData()
        data.withUnsafeBytes { raw in
            instanceDataBuffers[slot].contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }
        if scene.materialsChanged {
            // Animated light proxies (flicker, the sun's colour): frames in flight may see the new values a frame early.
            scene.materials.withUnsafeBytes { raw in
                materialBuffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
            scene.materialsChanged = false
        }
        var lights = scene.gpuLights()
        skyActive = updateSky(lights: &lights)
        writeSkyArguments(slot: slot)
        if !lights.isEmpty {
            lights.withUnsafeBytes { raw in
                lightBuffers[slot].contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
            // Last frame's lights, for ReSTIR's temporal reuse (this frame's on the first frame).
            let previous = lastFrameLights.count == lights.count ? lastFrameLights : lights
            previous.withUnsafeBytes { raw in
                prevLightBuffers[slot].contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
            lastFrameLights = lights
        }
    }

    /// Instance descriptors for Metal's top-level acceleration structure.
    private func writeInstanceDescriptors(slot: Int) {
        let descBase = instanceDescBuffers[slot].contents()
        let options = MTLAccelerationStructureInstanceOptions([.opaque, .disableTriangleCulling]).rawValue
        for (i, instance) in scene.instances.enumerated() {
            let p = descBase.advanced(by: i * Renderer.instanceDescriptorStride)
            let m = instance.transform
            var offset = 0
            for column in 0..<4 {           // packed column-major 4x3 matrix
                for row in 0..<3 {
                    p.storeBytes(of: m[column][row], toByteOffset: offset, as: Float.self)
                    offset += 4
                }
            }
            p.storeBytes(of: options, toByteOffset: 48, as: UInt32.self)
            p.storeBytes(of: instance.mask, toByteOffset: 52, as: UInt32.self)
            p.storeBytes(of: UInt32(0), toByteOffset: 56, as: UInt32.self)              // intersection function table offset
            p.storeBytes(of: UInt32(instance.mesh), toByteOffset: 60, as: UInt32.self)  // index into primitiveAS
        }
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
            let speed = settings.moveSpeed * (NSEvent.modifierFlags.contains(.shift) ? 3.2 : 1)
            camera.position += normalize(move) * speed * dt
        }
    }

    private func makeUniforms(width: Int, height: Int) -> Uniforms {
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
        u.bounces = settings.giEnabled && activeGIMode == .pathTraced ? UInt32(settings.bounces) : 0
        u.flags = (historyValid ? UniformFlags.historyValid : 0) | (settings.denoiser.enabled ? UniformFlags.denoise : 0)
        if accumulating { u.flags |= UniformFlags.noClamp | UniformFlags.reference }
        if usesSpecular { u.flags |= UniformFlags.specular }
        // Exact: one shadow ray per light (references, up to Renderer.exactReferenceLights). ReSTIR: restir kernels.
        switch activeDirectMode {
        case .exact: u.flags |= UniformFlags.allLights
        case .restir: u.flags |= UniformFlags.restir
        default: break
        }
        if settings.lightMaps && activeGIMode == .pathTraced && !accumulating { u.flags |= UniformFlags.lightMaps }
        u.viewMode = UInt32(settings.viewMode)
        let d = settings.denoiser
        u.denoise = SIMD4<Float>(DenoiserSettings.luminanceSigmaRange.clamp(d.luminanceSigma),
                                 DenoiserSettings.maxHistoryRange.clamp(d.maxHistory),
                                 DenoiserSettings.antiLagRange.clamp(d.antiLag), 0)
        u.instanceCount = UInt32(scene.instances.count)
        u.lightGroupEnd = scene.lightGroupEnd
        let table = scene.lightTable
        u.lightTable = SIMD4(UInt32(table.entries.count), UInt32(table.suns.count),
                             table.suns.first ?? 0, table.suns.count > 1 ? table.suns[1] : 0)
        if skyActive { u.flags |= UniformFlags.skyMap }
        return u
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let drawStart = CACurrentMediaTime()
        if let last = lastDrawTime {
            frameIntervalMs = (drawStart - last) * 1000
            frameIntervalSum += frameIntervalMs
            frameIntervalCount += 1
        }
        lastDrawTime = drawStart
        if benchmark == nil, CustomRayTracer.statsEnabled, let customRT {
            let counts = customRT.readCounters()   // what the frames finished since the last read added (in-flight ones in part)
            if let last = traversalLast {
                traversalSum = traversalSum + TraversalStats(counts: zip(counts, last).map { UInt64($0 &- $1) })
                traversalFrames += 1
            }
            traversalLast = counts
        }
        // Render resolution = window size in points * renderScale. Without upscaling the layer stretches
        // it to the window. With upscaling, MetalFX outputs renderScale * upscaleFactor, capped at the
        // window's size in physical pixels.
        let width = max(64, Int((view.bounds.width * settings.renderScale).rounded()))
        let height = max(64, Int((view.bounds.height * settings.renderScale).rounded()))
        var outWidth = width, outHeight = height
        if settings.upscaleFactor > 1 && upscaleSupported {
            // Not view.convertToBacking: MTKView scales its layer to match drawableSize, so that returns the render size.
            let backing = view.window?.backingScaleFactor ?? 2
            let maxWidth = view.bounds.width * backing, maxHeight = view.bounds.height * backing
            let factor = min(settings.upscaleFactor, maxUpscale, maxWidth / CGFloat(width), maxHeight / CGFloat(height))
            if factor > 1.01 {
                outWidth = Int((CGFloat(width) * factor).rounded())
                outHeight = Int((CGFloat(height) * factor).rounded())
            }
        }
        let upscaling = outWidth > width
        let desired = CGSize(width: outWidth, height: outHeight)
        if view.drawableSize != desired { view.drawableSize = desired }

        if targets == nil || targets!.width != width || targets!.height != height {
            do {
                targets = try RenderTargets(device: device, width: width, height: height)
                historyValid = false
            } catch {
                print(error)
                return
            }
        }
        guard let t = targets else { return }

        if settings.scene != scene.settings || settings.rayTracer != builtRayTracer || virtualGeometryChanged {
            if benchmark != nil { rebuildScene(resetCamera: false) } else { startLoadingScene() }
        }
        frameSemaphore.wait()
        let encodeStart = CACurrentMediaTime()

        let custom = upscaling && settings.upscaler == .custom
        if !upscaling || custom {
            upscaler = nil
        } else if upscaler == nil || upscaler!.inputWidth != width || upscaler!.inputHeight != height
                    || upscaler!.outputWidth != outWidth || upscaler!.outputHeight != outHeight
                    || upscaler!.spatial != (settings.upscaler == .metalFXSpatial) {
            do {
                upscaler = try Upscaler(device: device, inputWidth: width, inputHeight: height,
                                        outputWidth: outWidth, outputHeight: outHeight,
                                        spatial: settings.upscaler == .metalFXSpatial, synchronous: benchmark != nil)
                upscalerReset = true
            } catch {
                print(error)
                upscaler = nil
                settings.upscaleFactor = 0
                frameSemaphore.signal()
                return
            }
        }
        if !custom {
            customUpscaler = nil
        } else if customUpscaler == nil || customUpscaler!.inputWidth != width || customUpscaler!.inputHeight != height
                    || customUpscaler!.outputWidth != outWidth || customUpscaler!.outputHeight != outHeight {
            do {
                customUpscaler = try TemporalUpscaler(device: device, inputWidth: width, inputHeight: height,
                                                      outputWidth: outWidth, outputHeight: outHeight)
                upscalerReset = true
            } catch {
                print(error)
                customUpscaler = nil
                settings.upscaleFactor = 0
                frameSemaphore.signal()
                return
            }
        }

        let now = CACurrentMediaTime()
        var dt = Float(min(now - lastTime, 0.1))
        lastTime = now
        if let benchmark {
            benchmark.noteDraw(resolution: upscaling ? "\(width)×\(height) → \(outWidth)×\(outHeight)" : "\(width)×\(height)")
            dt = benchmark.fixedDt   // deterministic animation so every setting renders the same frames
            if benchmark.current.cameraPath {
                camera = Benchmark.cameraPose(progress: benchmark.progressInConfig, scene: settings.scene.kind)
            }
        }
        updateCamera(dt: dt)
        camera.fovY = settings.fovDegrees * .pi / 180
        if !settings.paused { animTime += dt * settings.timeScale }
        // The sun's day cycle can be offset (Time of day); everything else keeps the animation time.
        scene.update(time: animTime, dayTime: animTime + settings.timeOfDay * (settings.scene.kind.dayCycle ?? 0))

        let slot = Int(frameIndex) % Renderer.maxFramesInFlight
        // Viewpoint virtual geometry picks its detail for: the camera, or where it was when "Freeze LOD" was turned on.
        let liveLOD = (camera.position, Float(height) / (2 * tan(camera.fovY / 2)))
        if !settings.virtualGeometry.freeze { frozenLOD = nil } else if frozenLOD == nil { frozenLOD = liveLOD }
        let lod = frozenLOD ?? liveLOD
        customRT?.virtualGeometry?.update(frame: frameIndex, framesInFlight: Renderer.maxFramesInFlight)
        customRT?.virtualBLAS?.update(frame: frameIndex, slot: slot, framesInFlight: Renderer.maxFramesInFlight,
                                      camPos: lod.0, pixelScale: lod.1,
                                      tau: settings.virtualGeometry.pixelError, transforms: scene.instances.map(\.transform))
        writeFrameData(slot: slot)

        guard let cmd = queue.makeCommandBuffer() else {
            frameSemaphore.signal()
            return
        }

        // Benchmark mode puts each pass in its own command buffer so its GPU time can be read back.
        var passBuffers: [(name: String, cmd: MTLCommandBuffer)] = []
        func passBuffer(_ name: String) -> MTLCommandBuffer {
            guard benchmark != nil, Benchmark.splitPasses, let cb = queue.makeCommandBuffer() else { return cmd }
            cb.label = name
            passBuffers.append((name, cb))
            return cb
        }
        // GPU pass timings (the settings panel): an encoder per pass, timestamped at its start and end.
        let frameProfile = profilePasses && benchmark == nil ? profiler?.beginFrame(slot: slot) : nil
        // Radiance cascades and the direct-light denoiser don't touch each other's textures (unless the denoiser also
        // filters the cascades' output), so their dispatches can overlap on the GPU: the shared encoder is then
        // concurrent, with explicit barriers between dependent stages. Per-pass timing (benchmark or panel) keeps
        // everything serial, and METALRENDERER_OVERLAP=0 turns overlapping off for A/B timing.
        let splitPasses = benchmark != nil && Benchmark.splitPasses
        let overlap = !splitPasses && frameProfile == nil && Renderer.overlapEnabled && settings.giEnabled
            && activeGIMode == .radianceCascades && !settings.cascades.denoiseIndirect
        var openEncoder: MTLComputeCommandEncoder?
        var openPass = ""
        func beginComputePass(_ name: String) -> MTLComputeCommandEncoder? {
            // Normal mode: one shared encoder (profiling: one per pass name).
            if openEncoder != nil && !splitPasses && (frameProfile == nil || name == openPass) { return openEncoder }
            if let openEncoder { frameProfile.end(openEncoder) }
            openPass = name
            if let frameProfile { openEncoder = frameProfile.compute(cmd, name); return openEncoder }
            openEncoder = overlap ? cmd.makeComputeCommandEncoder(dispatchType: .concurrent)
                                  : passBuffer(name).makeComputeCommandEncoder()
            return openEncoder
        }
        /// Runs stages in order, each in its named benchmark pass (consecutive stages of one pass share it).
        func runSerial(_ stages: [ComputeStage]) {
            var pass: String?
            var enc: MTLComputeCommandEncoder?
            for stage in stages {
                if stage.pass != pass { enc = beginComputePass(stage.pass); pass = stage.pass }
                if let enc { stage.encode(enc) }
            }
        }

        // 1. Update the top-level acceleration structure with this frame's instance transforms. Metal: a refit (new bounds,
        //    same tree) costs a quarter of a rebuild, but the tree degrades as objects drift from where they were when
        //    it was built: in the stress scene (400 moving objects) rays got 35% slower after 256 refits. A rebuild
        //    every 16 frames (per slot) traces as fast as one every frame, for the refit's median cost.
        if builtRayTracer == .metal,
           let asEncoder = frameProfile?.accelerationStructure(cmd, "tlas") ?? passBuffer("tlas").makeAccelerationStructureCommandEncoder() {
            if Int(frameIndex) % Renderer.tlasRebuildInterval < Renderer.maxFramesInFlight { instanceASBuilt.remove(slot) }
            if instanceASBuilt.contains(slot) {
                asEncoder.refit(sourceAccelerationStructure: instanceAS[slot], descriptor: instanceASDescriptor(slot: slot),
                                destinationAccelerationStructure: instanceAS[slot], scratchBuffer: instanceScratch[slot],
                                scratchBufferOffset: 0)
            } else {
                asEncoder.build(accelerationStructure: instanceAS[slot],
                                descriptor: instanceASDescriptor(slot: slot),
                                scratchBuffer: instanceScratch[slot],
                                scratchBufferOffset: 0)
                instanceASBuilt.insert(slot)
            }
            frameProfile.end(asEncoder)
        }
        // Streamed textures: map and upload the levels last frame's hits asked for, ahead of this frame's work.
        textureStreamer?.update(frame: frameIndex, slot: slot, framesInFlight: Renderer.maxFramesInFlight, cmd: passBuffer("textures"))
        // Custom ray tracer: rebuild the moving instances' TLAS (a few small dispatches, in order).
        // Virtual geometry: this frame's level-of-detail cut and its cluster tree, in the same pass.
        if let customRT, let enc = frameProfile?.compute(cmd, "tlas") ?? passBuffer("tlas").makeComputeCommandEncoder() {
            let view = VGView(camPos: lod.0, pixelScale: lod.1, tau: settings.virtualGeometry.pixelError, frame: frameIndex)
            customRT.encodeBuild(enc, slot: slot, instanceData: instanceDataBuffers[slot], view: view)
            frameProfile.end(enc)
        }

        var uniforms = makeUniforms(width: width, height: height)
        // Temporal upscalers gather jittered samples; supersampled references average 1024 jittered frames.
        let jitter = upscaling && settings.upscaler != .metalFXSpatial
            ? Upscaler.jitter(frame: frameIndex, scale: Float(outWidth) / Float(width))
            : supersampling && !upscaling ? Upscaler.jitter(frame: accumCount, scale: 11.32) : .zero
        uniforms.jitter = SIMD4<Float>(lowHalf: jitter, highHalf: prevJitter)
        if upscaling { uniforms.flags |= UniformFlags.upscale }
        if settings.blueNoise {
            fillBlueNoiseTextureIfNeeded()
            uniforms.flags |= UniformFlags.blueNoise
        }
        let cur = Int(frameIndex & 1), prev = cur ^ 1
        if skyActive { encodeSky(passBuffer("sky"), profile: frameProfile) }

        let frameUniforms = uniforms

        // 1a. The light grid (ReGIR): rebuilt from this frame's lights before everything that samples them (ReSTIR
        //     DI's candidates, GI's next-event estimation, the reflections, the fog). It reads only the light and
        //     instance buffers, which the CPU wrote. Off in scenes without a light table; references set
        //     grid.enabled themselves (off for restirq's, on with every candidate for restircheck's "grid").
        var regirStages: [ComputeStage] = []
        regirParams = GPURegirParams()
        do {
            let g = settings.restir.grid
            let restirCandidates = accumulating ? 32 : RestirSettings.candidateRange.clamp(settings.restir.candidates)
            let regirOn = g.enabled && scene.lightTable.entries.count > 0 && (scene.usesLightTable || activeDirectMode == .restir)
            if regirOn, let grid = regirGrid(count: g.reservoirCount) {
                let cells = RegirSettings.cellRange.clamp(g.cells), levels = RegirSettings.levelRange.clamp(g.levels)
                let cellSize = RegirSettings.cellSizeRange.clamp(g.cellSize), scale = RegirSettings.scaleRange.clamp(g.levelScale)
                let jitter = Renderer.regirJitter(frame: frameIndex)
                var origins = [SIMD4<Float>](repeating: SIMD4<Float>(), count: 4)
                for level in 0..<levels {
                    let size = cellSize * pow(scale, Float(level))
                    let cam = frameUniforms.camPos
                    let origin = SIMD3(cam.x, cam.y, cam.z) - size * (Float(cells) * 0.5 + jitter)
                    origins[level] = SIMD4(origin, size)
                }
                var gp = GPURegirParams()
                (gp.origin0, gp.origin1, gp.origin2, gp.origin3) = (origins[0], origins[1], origins[2], origins[3])
                gp.config = SIMD4(UInt32(cells), UInt32(levels), UInt32(RegirSettings.slotRange.clamp(g.slots)),
                                  UInt32(RegirSettings.candidateRange.clamp(g.candidates)))
                gp.consume = SIMD4(UInt32(max(min(RegirSettings.shareRange.clamp(g.share), restirCandidates), 1)), frameIndex, 0, 0)
                regirParams = gp
                regirStages.append(ComputeStage(pass: "regir") { [self] enc in
                    var u = frameUniforms
                    enc.setComputePipelineState(regirBuildPSO)
                    enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    bindScene(enc, slot: slot)
                    dispatch(enc, "regir build", width: grid.length / MemoryLayout<GPURegirReservoir>.stride, height: 1)
                })
            }
        }

        // 1b. Light-visibility maps, for GI techniques and the path tracer's light-map variant.
        // Volumetric fog: this frame's parameters (the reflections read them too). The froxel history is reprojected
        // only from the frame just before, with the same far distance.
        let fogGridTargets = settings.fog.enabled ? fogTargets(width: width, height: height) : nil
        let fogNoiseTex = fogGridTargets != nil ? fogNoise() : nil
        let fogOn = fogGridTargets != nil && fogNoiseTex != nil
        let fogHistory = fogOn && fogLastFrame == frameIndex &- 1 && fogLastFar == settings.fog.maxDistance
        let fogParams = makeFogParams(grid: fogOn ? fogGridTargets : nil, historyValid: fogHistory)
        let fogSampleCount = accumCount   // references: frames the fog march has averaged
        var headStages: [ComputeStage] = []
        if usesLightMaps {
            headStages.append(ComputeStage(pass: "lightmap") { [self] enc in
                var u = frameUniforms
                enc.setComputePipelineState(lightMapPSO)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                bindScene(enc, slot: slot)
                enc.setTexture(lightMap, index: 0)
                enc.dispatchThreads(MTLSize(width: lightMap.width, height: lightMap.height, depth: scene.lights.count),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            })
        }

        // 2. Ray trace: primary visibility (G-buffer), direct light with shadow rays, path-traced indirect light.
        headStages.append(ComputeStage(pass: "trace") { [self] enc in
            var u = frameUniforms
            enc.setComputePipelineState(tracePSO)
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            bindScene(enc, slot: slot)
            setTextures(enc, [t.normalDepth[cur], t.albedo, t.emission, t.motion, t.direct, t.indirect,
                              t.deviceDepth, t.pixelMotion, blueNoiseTexture, t.surfacePos, t.geoNormal, lightMap,
                              t.visibility, t.blocker, t.material])
            dispatch(enc, "trace", width: width, height: height)
        })

        // 2b. Radiance-cascade GI writes t.indirect (the path tracer already did, inside traceKernel).
        let giMode = activeGIMode
        var giStages: [ComputeStage] = []
        if settings.giEnabled && giMode == .radianceCascades {
            giStages = radianceCascadeStages(uniforms: uniforms, targets: t, slot: slot)
        }
        // ReSTIR GI writes t.indirect too: after the trace (its G-buffer), before the reflections (they read it).
        let restirGIOn = settings.giEnabled && giMode == .restirGI
        if restirGIOn, let gg = restirGITargets(width: width, height: height) {
            giStages = restirGIStages(grid: gg, uniforms: frameUniforms, targets: t, slot: slot)
        }
        restirGIWritten = restirGIOn && restirGIGrid != nil

        // 3. Denoise (SVGF-style): temporal accumulation + edge-aware a-trous wavelet filter.
        //    Path-traced light is denoised either as one signal or as direct and indirect separately (sharper
        //    direct shadows, since indirect noise no longer inflates the variance that guides the luminance
        //    edge-stopping). Cascade output is already smooth: it skips the denoiser unless its
        //    "denoise indirect" option is on (then 1 a-trous pass). With GI off there's no indirect light to denoise.
        let techniqueGI = giMode != .pathTraced
        let denoiseIndirect = settings.giEnabled && (!techniqueGI || techniqueDenoisesIndirect)
        //    With the shadow denoiser (default), direct light goes through its own visibility filter instead (3b),
        //    and SVGF handles only indirect light.
        //    ReSTIR's direct light is radiance, not per-group visibility: SVGF filters it (no loop over the lights).
        let directMode = activeDirectMode
        let restirOn = directMode == .restir
        let shadowDenoiserOn = settings.denoiser.enabled && settings.denoiser.shadowDenoiser && !accumulating
            && Renderer.shadowDenoiserAllowed
        //    ReSTIR with the shadow denoiser (split): its visibility goes through the visibility filter, its unshadowed
        //    light through SVGF, and the composite multiplies them.
        let restirSplit = restirOn && shadowDenoiserOn && settings.restir.splitVisibility
        let shadowDenoiser = shadowDenoiserOn && (!restirOn || restirSplit)
        let separate = settings.denoiser.separateSignals || techniqueGI || !settings.giEnabled || shadowDenoiser
        let passCount = settings.denoiser.passes(for: giMode)
        let directPasses = restirOn ? DenoiserSettings.passRange.clamp(settings.restir.denoisePasses) : passCount
        var signals: [(noisy: [MTLTexture], targets: DenoiseTargets, passes: Int)] =
            shadowDenoiser ? [] : separate ? [([t.direct], t.denoise[0], directPasses)] : [([t.direct, t.indirect], t.denoise[0], directPasses)]
        // ReSTIR's direct light: its own edge-stopping, and its variance scaled up (reused samples are correlated).
        var restirDenoiseUniforms = frameUniforms
        restirDenoiseUniforms.denoise.x = DenoiserSettings.luminanceSigmaRange.clamp(settings.restir.denoiseSigma)
        restirDenoiseUniforms.denoise.w = max(settings.restir.varianceBoost, 1)
        restirDenoiseUniforms.denoise.y = DenoiserSettings.maxHistoryRange.clamp(settings.restir.denoiseHistory)
        // ReSTIR GI's indirect light: the same, with its own settings.
        let rgi = settings.restirGI
        var restirGIDenoiseUniforms = frameUniforms
        restirGIDenoiseUniforms.denoise.x = DenoiserSettings.luminanceSigmaRange.clamp(rgi.denoiseSigma)
        restirGIDenoiseUniforms.denoise.w = max(rgi.varianceBoost, 1)
        restirGIDenoiseUniforms.denoise.y = DenoiserSettings.maxHistoryRange.clamp(rgi.denoiseHistory)
        restirGIDenoiseUniforms.denoise.z = DenoiserSettings.antiLagRange.clamp(rgi.antiLag)
        func denoiseUniforms(_ d: DenoiseTargets) -> Uniforms {
            if restirGIOn && d === t.denoise[1] { return restirGIDenoiseUniforms }
            return restirOn && d === (restirSplit ? t.denoise[3] : t.denoise[0]) ? restirDenoiseUniforms : frameUniforms
        }
        let indirectPasses = restirGIOn ? DenoiserSettings.passRange.clamp(rgi.denoisePasses) : techniqueGI ? 1 : passCount
        if separate && denoiseIndirect { signals.append(([t.indirect], t.denoise[1], indirectPasses)) }
        // Emissive-mesh lights' direct light: sampled per pixel, so noisy. With the shadow denoiser it's an SVGF signal
        // of its own (first, so finalIllumination keeps the indirect light last); otherwise it joins the direct light.
        let meshLights = !scene.meshLights.isEmpty && !restirOn   // ReSTIR samples their triangles from the light table
        let denoiseMeshLights = meshLights && shadowDenoiser
        if denoiseMeshLights { signals.insert(([t.meshDirect], t.denoise[3], settings.denoiser.passes(for: .pathTraced)), at: 0) }
        if restirSplit { signals.insert(([t.direct], t.denoise[3], directPasses), at: 0) }   // unshadowed: no edges to keep
        var finalMeshDirect = t.meshDirect
        var finalIllumination = [t.denoise[0].pingA]
        var denoiseStages: [ComputeStage] = []
        // 2d. Reflections (glTF specular materials): after the GI (they read its result), before the denoisers.
        var finalSpecular = t.specular
        var specularStages: [ComputeStage] = [], specularDenoise: [ComputeStage] = []
        if usesSpecular {
            specularStages.append(ComputeStage(pass: "reflections") { [self] enc in
                var u = frameUniforms
                enc.setComputePipelineState(reflectionPSO)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                bindScene(enc, slot: slot)
                var fp = fogParams
                enc.setBytes(&fp, length: MemoryLayout<GPUFogParams>.stride, index: 9)
                setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, t.material, blueNoiseTexture, t.indirect, t.specular,
                                  fogNoiseTex ?? dummy3D, restirOn ? restirGrid?.specular ?? dummy2D : dummy2D])
                dispatch(enc, "reflections", width: width, height: height)
            })
            if settings.denoiser.enabled && !accumulating {
                let d = t.denoise[2]
                specularDenoise.append(ComputeStage(pass: "reflections") { [self] enc in
                    var u = frameUniforms, inputCount: UInt32 = 1
                    enc.setComputePipelineState(temporalPSO)
                    enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.setBytes(&inputCount, length: MemoryLayout<UInt32>.stride, index: 1)
                    setTextures(enc, [t.specular, t.specular, t.motion, t.normalDepth[cur], t.normalDepth[prev],
                                      d.history, d.moments[prev], d.pingA, d.moments[cur]])
                    dispatch(enc, "temporal", width: width, height: height)
                })
                for (i, pass) in [(d.pingA, d.history), (d.history, d.pingB)].enumerated() {
                    specularDenoise.append(ComputeStage(pass: "reflections") { [self] enc in
                        var u = frameUniforms, step = Int32(1 << i)
                        enc.setComputePipelineState(atrousPSO)
                        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                        enc.setBytes(&step, length: MemoryLayout<Int32>.stride, index: 1)
                        setTextures(enc, [pass.0, t.normalDepth[cur], pass.1])
                        dispatch(enc, "atrous", width: width, height: height)
                    })
                }
                finalSpecular = d.pingB
            }
        }
        // 2c. More than 4 lights: direct light from one sampled light per group (manyLightsKernel), after the trace
        //     and before anything that reads direct light or visibility.
        let manyLights = scene.lightGroupEnd[3] > 4 && frameUniforms.flags & UniformFlags.allLights == 0 && !restirOn
        let reuse = manyLights && settings.manyLightReuse > 0 && settings.manyLightRays == 1
        let reservoirsValid = reuse && reservoirsWritten && historyValid
        reservoirsWritten = reuse
        // 2e. ReSTIR DI: after the trace (its G-buffer), before the reflections (they add its direct specular) and the
        //     denoiser. References with many lights accumulate its unbiased initial sampling alone (32 candidates).
        var restirStages: [ComputeStage] = []
        var restirSettings = settings.restir
        if accumulating {   // references: unbiased initial sampling alone
            restirSettings.candidates = 32; restirSettings.temporal = false; restirSettings.spatialPasses = 0
            restirSettings.visibilityReuse = false; restirSettings.chains = 4
        }
        let restirGridNow = restirOn ? restirTargets(width: width, height: height,
                                                     chains: RestirSettings.chainRange.clamp(restirSettings.chains)) : nil
        if let rg = restirGridNow {
            let r = restirSettings
            let temporalValid = r.temporal && restirWritten   // (not historyValid: that follows the denoiser)
            var flags: UInt32 = (temporalValid ? GPURestirParams.temporalValid : 0) | (r.visibilityReuse ? GPURestirParams.visibilityReuse : 0)
                | (restirSplit ? GPURestirParams.split : 0)
            let maxM = UInt32(RestirSettings.maxMRange.clamp(r.maxM))
            let samples = UInt32(RestirSettings.spatialSampleRange.clamp(r.spatialSamples))
            let radius = RestirSettings.radiusRange.clamp(r.radius) * Float(width) / 960
            let clamp: Float = accumulating ? 0 : 4 * 10   // 4 x the firefly clamp, as the mesh-light pass
            let candidates = RestirSettings.candidateRange.clamp(r.candidates)
            let params = GPURestirParams(config: SIMD4(UInt32(candidates), maxM, flags, samples),
                                         tuning: SIMD4(radius, 0, clamp, Float(rg.chains)))
            restirStages.append(ComputeStage(pass: "restir") { [self] enc in
                var u = frameUniforms, p = params
                enc.setComputePipelineState(restirTemporalPSO)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                bindScene(enc, slot: slot)
                enc.setBytes(&p, length: MemoryLayout<GPURestirParams>.stride, index: 9)
                enc.setBuffer(prevLightBuffers[slot], offset: 0, index: 10)
                setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, t.albedo, t.material, t.motion, t.normalDepth[prev],
                                  rg.reservoir[prev], rg.temporal])
                dispatch(enc, "restir temporal", width: width, height: height)
            })
            let passes = RestirSettings.spatialPassRange.clamp(r.spatialPasses)
            flags &= ~GPURestirParams.temporalValid
            for i in 0..<max(passes, 1) {
                let last = i == max(passes, 1) - 1
                let src = i == 0 ? rg.temporal : rg.spatial, dst = last ? rg.reservoir[cur] : rg.spatial
                var p = params
                p.config.z = flags | (last ? GPURestirParams.shade : 0)
                p.config.w = passes == 0 ? 0 : samples
                p.tuning.y = Float(i)
                restirStages.append(ComputeStage(pass: "restir") { [self] enc in
                    var u = frameUniforms, p = p
                    enc.setComputePipelineState(restirSpatialPSO)
                    enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    bindScene(enc, slot: slot)
                    enc.setBytes(&p, length: MemoryLayout<GPURestirParams>.stride, index: 9)
                    setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, t.albedo, t.material, src, dst, t.direct, rg.specular,
                                      t.visibility, t.blocker])
                    dispatch(enc, "restir spatial", width: width, height: height)
                })
            }
        }
        restirWritten = restirGridNow != nil
        if manyLights {
            denoiseStages.append(ComputeStage(pass: "many lights") { [self] enc in
                var u = frameUniforms
                enc.setComputePipelineState(reuse ? manyLightsReusePSO : manyLightsPSO)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                bindScene(enc, slot: slot)
                var config = SIMD4<UInt32>(UInt32(settings.manyLightRays), UInt32(max(settings.manyLightReuse, 0)),
                                           reservoirsValid ? 1 : 0, 0)
                enc.setBytes(&config, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 9)
                setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, blueNoiseTexture, t.direct, t.visibility, t.blocker,
                                  t.motion, t.normalDepth[prev], t.shadow.reservoir[prev], t.shadow.reservoirWeight[prev],
                                  t.shadow.reservoir[cur], t.shadow.reservoirWeight[cur]])
                dispatch(enc, "many lights", width: width, height: height)
            })
        }
        if meshLights {
            denoiseStages.append(ComputeStage(pass: "mesh lights") { [self] enc in
                var u = frameUniforms, addToDirect: UInt32 = shadowDenoiser ? 0 : 1
                enc.setComputePipelineState(meshLightsPSO)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                bindScene(enc, slot: slot)
                enc.setBytes(&addToDirect, length: MemoryLayout<UInt32>.stride, index: 9)
                setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, blueNoiseTexture, t.direct, t.meshDirect])
                dispatch(enc, "mesh lights", width: width, height: height)
            })
        }
        if shadowDenoiser {
            let d = settings.denoiser, s = t.shadow
            let maxHistory = DenoiserSettings.maxHistoryRange.clamp(d.shadowHistory)
            denoiseStages.append(ComputeStage(pass: "shadow temporal") { [self] enc in
                var u = frameUniforms, params = SIMD4<Float>(maxHistory, d.shadowClamp, d.shadowSigma, 0)
                enc.setComputePipelineState(shadowTemporalPSO)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                setTextures(enc, [t.visibility, t.blocker, t.motion, t.normalDepth[cur], t.normalDepth[prev], s.history,
                                  s.meta[prev], s.pingA, s.meta[cur], s.penumbra, s.tiles])
                // Whole 8x8 threadgroups: each one classifies its tile.
                enc.dispatchThreadgroups(MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            })
            // Pass 0 writes `history`, which feeds next frame's temporal pass (as in SVGF).
            let chain: [(src: MTLTexture, dst: MTLTexture)] = [(s.pingA, s.history), (s.history, s.pingB), (s.pingB, s.pingA),
                                                               (s.pingA, s.pingB), (s.pingB, s.pingA)]
            let passes = DenoiserSettings.passRange.clamp(d.shadowPasses)
            for (i, pass) in chain.prefix(passes).enumerated() {
                denoiseStages.append(ComputeStage(pass: "shadow filter") { [self] enc in
                    var u = frameUniforms, params = SIMD4<Float>(maxHistory, d.shadowClamp, d.shadowSigma, Float(1 << i))
                    enc.setComputePipelineState(shadowFilterPSO)
                    enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                    setTextures(enc, [pass.src, t.normalDepth[cur], s.penumbra, s.meta[cur], s.tiles, pass.dst])
                    dispatch(enc, "shadow filter", width: width, height: height)
                })
            }
            finalIllumination = [chain[passes - 1].dst]
            uniforms.flags |= UniformFlags.shadowDenoiser | UniformFlags.separateSignals
        }
        if accumulating, let accum = accumulationTextures(width: width, height: height) {
            let count = accumCount
            denoiseStages.append(ComputeStage(pass: "accumulate") { [self] enc in
                var u = frameUniforms, count = count
                enc.setComputePipelineState(accumulatePSO)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 1)
                setTextures(enc, [t.direct, t.indirect, accum.direct, accum.indirect, t.specular, accum.specular])
                dispatch(enc, "accumulate", width: width, height: height)
            })
            accumCount += 1
            finalIllumination = [accum.direct, accum.indirect]
            finalSpecular = accum.specular
            // Tells the composite pass to read finalIllumination as separate direct + indirect light.
            uniforms.flags |= UniformFlags.denoise | UniformFlags.separateSignals
        }
        if settings.denoiser.enabled && !accumulating && !signals.isEmpty {
            denoiseStages.append(ComputeStage(pass: "temporal") { [self] enc in
                enc.setComputePipelineState(temporalPSO)
                for (noisy, d, _) in signals {
                    var u = denoiseUniforms(d)
                    enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    var inputCount = UInt32(noisy.count)
                    enc.setBytes(&inputCount, length: MemoryLayout<UInt32>.stride, index: 1)
                    setTextures(enc, [noisy[0], noisy.last!, t.motion, t.normalDepth[cur], t.normalDepth[prev],
                                      d.history, d.moments[prev], d.pingA, d.moments[cur]])
                    dispatch(enc, "temporal", width: width, height: height)
                }
            })
            // Iteration 0 writes into `history`, which feeds next frame's temporal pass.
            func atrousPasses(_ d: DenoiseTargets) -> [(src: MTLTexture, dst: MTLTexture)] {
                [(d.pingA, d.history), (d.history, d.pingB), (d.pingB, d.pingA), (d.pingA, d.pingB), (d.pingB, d.pingA)]
            }
            for i in 0..<(signals.map(\.passes).max() ?? 0) {
                denoiseStages.append(ComputeStage(pass: "atrous") { [self] enc in
                    var step = Int32(1 << i)
                    enc.setComputePipelineState(atrousPSO)
                    enc.setBytes(&step, length: MemoryLayout<Int32>.stride, index: 1)
                    for (_, d, passes) in signals where i < passes {
                        var u = denoiseUniforms(d)
                        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                        let pass = atrousPasses(d)[i]
                        setTextures(enc, [pass.src, t.normalDepth[cur], pass.dst])
                        dispatch(enc, "atrous", width: width, height: height)
                    }
                })
            }
            finalIllumination = (shadowDenoiser ? finalIllumination : [])
                + signals.map { _, d, passes in atrousPasses(d)[passes - 1].dst }
            if denoiseMeshLights {
                finalMeshDirect = finalIllumination[1]
                uniforms.flags |= UniformFlags.meshLights
            }
            if restirSplit { finalMeshDirect = finalIllumination[1] }
            if separate { uniforms.flags |= UniformFlags.separateSignals }
        }

        // 3d. Volumetric fog: light the froxel grid in front of the surfaces and integrate it (or, for references,
        //     march every camera ray). It needs the TLAS, the lights and the G-buffer's depth: first among these stages.
        var fogReferenceTex: MTLTexture?
        if fogOn, let g = fogGridTargets, let noise = fogNoiseTex {
            var fogStages: [ComputeStage] = []
            if accumulating, let ref = fogReferenceTexture(width: width, height: height) {
                fogReferenceTex = ref
                fogStages.append(ComputeStage(pass: "fog") { [self] enc in
                    var u = frameUniforms, fp = fogParams, count = fogSampleCount
                    enc.setComputePipelineState(fogReferencePSO)
                    enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    bindScene(enc, slot: slot)
                    enc.setBytes(&fp, length: MemoryLayout<GPUFogParams>.stride, index: 9)
                    enc.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 10)
                    setTextures(enc, [noise, t.normalDepth[cur], ref])
                    dispatch(enc, "fog reference", width: width, height: height)
                })
                uniforms.flags |= UniformFlags.fog | UniformFlags.fogReference
            } else {
                fogStages.append(ComputeStage(pass: "fog") { [self] enc in
                    var u = frameUniforms, fp = fogParams
                    enc.setComputePipelineState(fogInjectPSO)
                    enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    bindScene(enc, slot: slot)
                    enc.setBytes(&fp, length: MemoryLayout<GPUFogParams>.stride, index: 9)
                    setTextures(enc, [blueNoiseTexture, noise, g.scatter[prev], g.scatter[cur], t.normalDepth[cur]])
                    enc.dispatchThreads(MTLSize(width: g.columns, height: g.rows, depth: g.slices),
                                        threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                })
                fogStages.append(ComputeStage(pass: "fog") { [self] enc in
                    var u = frameUniforms, fp = fogParams
                    enc.setComputePipelineState(fogIntegratePSO)
                    enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.setBytes(&fp, length: MemoryLayout<GPUFogParams>.stride, index: 9)
                    setTextures(enc, [g.scatter[cur], g.integrated])
                    dispatch(enc, "fog integrate", width: g.columns, height: g.rows)
                })
                fogLastFrame = frameIndex
                fogLastFar = settings.fog.maxDistance
                uniforms.flags |= UniformFlags.fog
            }
            denoiseStages.insert(contentsOf: fogStages, at: 0)
        }
        // Overlapped encoding runs the reflections after the denoise chain: ReSTIR leads it (after the fog).
        if overlap { denoiseStages.insert(contentsOf: restirStages, at: fogOn ? (accumulating ? 1 : 2) : 0) }

        if overlap, let enc = beginComputePass("trace") {
            // The light grid first (the trace's bounces read it); light map, trace and cascade probes need only the
            // TLAS; then the cascade chain and the denoiser chain advance in lock-step, one barrier per step.
            // Reflections read the cascades' result: after both.
            if !regirStages.isEmpty {
                for stage in regirStages { stage.encode(enc) }
                enc.memoryBarrier(scope: .buffers)
            }
            for stage in headStages + giStages.prefix(1) { stage.encode(enc) }
            enc.memoryBarrier(scope: [.buffers, .textures])
            let gi = Array(giStages.dropFirst())
            for i in 0..<max(gi.count, denoiseStages.count) {
                if i < denoiseStages.count { denoiseStages[i].encode(enc) }
                if i < gi.count { gi[i].encode(enc) }
                enc.memoryBarrier(scope: [.buffers, .textures])
            }
            for stage in specularStages + specularDenoise {
                stage.encode(enc)
                enc.memoryBarrier(scope: [.buffers, .textures])
            }
        } else {
            runSerial(regirStages)
            runSerial(headStages)
            runSerial(giStages)
            runSerial(restirStages)
            runSerial(specularStages)
            runSerial(denoiseStages)
            runSerial(specularDenoise)
        }
        // 3c. Geometry debug views: their own pass, only while one is shown.
        if RenderSettings.geometryViews.contains(settings.viewMode), let enc = beginComputePass("geometry debug") {
            enc.setComputePipelineState(geometryDebugPSO)
            enc.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            bindScene(enc, slot: slot)
            enc.setTexture(t.geometryDebug, index: 0)
            dispatch(enc, "geometry debug", width: width, height: height)
            if overlap { enc.memoryBarrier(scope: [.textures]) }   // concurrent encoder: before the composite reads it
        }

        // Indirect light the composite adds when signals are separate: denoised, or raw (GI technique / GI off).
        let compositeIndirect = accumulating || (settings.denoiser.enabled && separate && denoiseIndirect)
            ? finalIllumination.last! : t.indirect

        // 4. Composite: albedo * illumination + emission, tonemap, write to the drawable
        //    (or, with upscaling, to MetalFX's input color texture).
        let drawableStart = CACurrentMediaTime()
        var drawable = view.currentDrawable
        let drawableWait = CACurrentMediaTime() - drawableStart
        // Right after a size change the view can still hand out a drawable of the old size: skip drawing this frame.
        if let d = drawable, d.texture.width != outWidth || d.texture.height != outHeight { drawable = nil }
        if let drawable, let enc = beginComputePass("composite") {
            let output = upscaling ? upscaler?.spatialInput ?? t.upscaleColor
                : supersampling ? t.upscaleColor : drawable.texture
            enc.setComputePipelineState(compositePSO)
            enc.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            setTextures(enc, [finalIllumination[0], t.direct, t.indirect, t.albedo, t.emission, t.normalDepth[cur],
                              shadowDenoiser ? t.shadow.meta[cur] : t.denoise[0].moments[cur], output, compositeIndirect,
                              t.giDebug, t.surfacePos, t.geoNormal, t.material, finalSpecular, t.geometryDebug, finalMeshDirect,
                              fogOn ? fogGridTargets!.integrated : dummy3D, fogReferenceTex ?? dummy2D])
            enc.setBuffer(lightBuffers[slot], offset: 0, index: 1)
            var fp = fogParams
            enc.setBytes(&fp, length: MemoryLayout<GPUFogParams>.stride, index: 2)
            dispatch(enc, "composite", width: output.width, height: output.height)
        }

        // 4b. Supersampled reference: average the composited frames (from halfway through, once lighting has converged).
        if let drawable, supersampling, !upscaling, let accum = colorAccumTexture(width: width, height: height),
           let enc = beginComputePass("composite") {
            if overlap { enc.memoryBarrier(scope: .textures) }
            let half = UInt32((benchmark?.current.frames ?? 0) / 2)
            var params = SIMD2<UInt32>(colorAccumCount, accumCount > half ? 1 : 0)
            if params.y != 0 { colorAccumCount += 1 }
            enc.setComputePipelineState(accumulateColorPSO)
            enc.setBytes(&params, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
            setTextures(enc, [t.upscaleColor, accum, drawable.texture])
            dispatch(enc, "accumulate color", width: width, height: height)
        }

        // 5. Upscale into the drawable: the custom TAAU pass, or MetalFX (copied in; both sRGB formats, so the GPU
        //    encodes on write).
        if let drawable, let customUpscaler, let enc = beginComputePass("upscale") {
            if overlap { enc.memoryBarrier(scope: .textures) }   // the composite pass wrote its input
            customUpscaler.encode(enc, pipeline: taauPSO, targets: t, drawable: drawable.texture, jitter: jitter,
                                  reset: upscalerReset, settings: settings.taau)
            upscalerReset = false
        }
        if let drawable, let upscaler {
            if let openEncoder { frameProfile.end(openEncoder) }
            openEncoder = nil
            upscaler.encode(into: passBuffer("upscale"), targets: t, drawable: drawable.texture, jitter: jitter, reset: upscalerReset)
            upscalerReset = false
        }
        if let openEncoder { frameProfile.end(openEncoder) }

        var writeCapture: (() -> Void)?
        if let benchmark, benchmark.shouldCapture, let vg = customRT?.virtualGeometry { print("  " + vg.summary) }
        if let benchmark, benchmark.shouldCapture, let vg = customRT?.virtualBLAS { print("  " + vg.summary) }
        if let benchmark, benchmark.shouldCapture, let ts = textureStreamer {
            print("  " + ts.summary)
            if ProcessInfo.processInfo.environment["METALRENDERER_TEXTURE_DEBUG"] != nil { print(ts.details) }
        }
        if let benchmark, benchmark.isMeasuring, CustomRayTracer.statsEnabled, let customRT {
            // One frame's counters: reset at the first measured frame, read at the capture frame (single-frame runs).
            if benchmark.shouldCapture { print("  " + customRT.takeStats().description) } else { _ = customRT.takeStats() }
        }
        if let benchmark, let drawable, benchmark.shouldCapture {
            writeCapture = benchmark.encodeCapture(of: drawable.texture, into: cmd, device: device)
        }
        if let drawable { cmd.present(drawable) }
        let semaphore = frameSemaphore
        let bench = benchmark, benchConfig = benchmark?.configIndex ?? 0
        let recordFrame = benchmark?.isMeasuring ?? false
        let passes = passBuffers
        let vg = customRT?.virtualGeometry, vgFrame = frameIndex, streamer = textureStreamer
        let cpuInterval = frameIntervalMs
        let encodeNow = (CACurrentMediaTime() - encodeStart - drawableWait) * 1000
        cmd.addCompletedHandler { [weak self] cb in
            if !Benchmark.isEnabled { vg?.collect(slot: slot, frame: vgFrame); streamer?.collect(slot: slot) }
            if let bench, recordFrame {
                var passMs: [String: Double] = [:]
                var start = Double.infinity, end = 0.0
                for p in passes {
                    p.cmd.waitUntilCompleted()
                    passMs[p.name, default: 0] += (p.cmd.gpuEndTime - p.cmd.gpuStartTime) * 1000   // a name can recur
                    start = min(start, p.cmd.gpuStartTime)
                    end = max(end, p.cmd.gpuEndTime)
                }
                if passes.isEmpty {   // METALRENDERER_BENCH_SPLIT=0: the whole frame is one command buffer, as in normal mode
                    passMs["frame"] = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                    start = cb.gpuStartTime
                    end = cb.gpuEndTime
                }
                bench.record(.init(config: benchConfig, passMs: passMs, spanMs: (end - start) * 1000, cpuMs: encodeNow))
            }
            writeCapture?()
            let times = frameProfile?.resolve()
            semaphore.signal()
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            DispatchQueue.main.async {
                self?.gpuMs = ms
                if let self, let onFrameTime = self.onFrameTime { onFrameTime(cpuInterval, ms) }
                if let times { self?.addPassTimes(times, frameMs: ms) }
            }
        }
        for p in passBuffers { p.cmd.commit() }
        cmd.commit()
        // Benchmark: finish this frame before encoding the next, so passes from consecutive frames
        // never overlap on the GPU and inflate each other's timings.
        if benchmark != nil {
            cmd.waitUntilCompleted()
            vg?.collect(slot: slot, frame: vgFrame)   // here, not in the handler: the next frame must see the requests
            streamer?.collect(slot: slot)
        }

        prevCamera = camera
        prevJitter = jitter
        historyValid = settings.denoiser.enabled
        frameIndex &+= 1
        updateTitle(width: width, height: height, outWidth: outWidth, outHeight: outHeight)
        if let benchmark { advanceBenchmark(benchmark) }
    }

    // MARK: - GI techniques

    /// Scene buffers at the indices every ray-tracing kernel uses (1 = TLAS, 2...8 = geometry, instances, lights).
    private func bindScene(_ enc: MTLComputeCommandEncoder, slot: Int) {
        if let customRT {
            customRT.bind(enc, slot: slot)
        } else {
            enc.setAccelerationStructure(instanceAS[slot], bufferIndex: 1)
            enc.useResources(primitiveASResources, usage: .read)   // BLASes referenced indirectly by the TLAS
        }
        enc.setBuffer(positionBuffer, offset: 0, index: 2)
        enc.setBuffer(normalBuffer, offset: 0, index: 3)
        enc.setBuffer(indexBuffer, offset: 0, index: 4)
        enc.setBuffer(meshBuffer, offset: 0, index: 5)
        enc.setBuffer(instanceDataBuffers[slot], offset: 0, index: 6)
        enc.setBuffer(shadingArgs[slot], offset: 0, index: 7)
        var gp = regirParams   // the light grid (ReGIR): ReSTIR DI's, GI's, the reflections' and the fog's candidates
        enc.setBuffer(regirBuffer ?? regirGrid(count: 1), offset: 0, index: 11)
        enc.setBytes(&gp, length: MemoryLayout<GPURegirParams>.stride, index: 12)
        enc.useResources(shadingResources, usage: .read)
        enc.useResources([skyActive ? skyMap ?? dummyArray : dummyArray, skyActive ? cloudShadowMap ?? dummy2D : dummy2D], usage: .read)
        if let textureStreamer {
            enc.useHeap(textureStreamer.heap)
            enc.useResource(textureStreamer.minLodBuffer(slot: slot), usage: .read)
            enc.useResource(textureStreamer.feedbackBuffer(slot: slot), usage: [.read, .write])
        }
        enc.setBuffer(lightBuffers[slot], offset: 0, index: 8)
    }

    /// Specular shading is on and the scene has materials with a specular lobe (glTF ones).
    private var usesSpecular: Bool { settings.specular && scene.hasSpecular }

    private var usesLightMaps: Bool {
        let wanted: Bool
        switch activeGIMode {
        case .pathTraced: wanted = settings.lightMaps
        case .radianceCascades: wanted = true
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
        }
    }

    private func restirGITargets(width: Int, height: Int) -> RestirGITargets? {
        if let r = restirGIGrid, r.width == width, r.height == height { return r }
        restirGIGrid = try? RestirGITargets(device: device, width: width, height: height)
        restirGIWritten = false
        return restirGIGrid
    }

    /// ReSTIR GI's stages for this frame: initial paths, temporal reuse, spatial reuse (the last pass writes t.indirect).
    private func restirGIStages(grid g: RestirGITargets, uniforms: Uniforms, targets t: RenderTargets, slot: Int) -> [ComputeStage] {
        let cur = Int(frameIndex & 1), prev = cur ^ 1
        let r = settings.restirGI
        let width = t.width, height = t.height
        let lightMaps = usesLightMaps && r.lightMaps
        // Multi-bounce feedback: last frame's indirect light, denoised (still in the denoiser's ping-pong textures until
        // this frame's denoiser runs) or raw (kept by the last spatial pass).
        let denoised = t.denoise[1]
        let denoisedFeedback = [denoised.history, denoised.pingB, denoised.pingA, denoised.pingB, denoised.pingA][
            DenoiserSettings.passRange.clamp(r.denoisePasses) - 1]
        let useDenoised = r.denoisedFeedback && r.denoise && settings.denoiser.enabled && !accumulating
        let feedbackSource = useDenoised ? denoisedFeedback : g.feedback[prev]
        let feedback = r.feedback && restirGIWritten && (historyValid || !useDenoised)
        var flags: UInt32 = (r.temporal && restirGIWritten ? GPURestirGIParams.temporalValid : 0)
            | (lightMaps ? GPURestirGIParams.lightMaps : 0) | (feedback ? GPURestirGIParams.feedback : 0)
            | (r.unbiased ? GPURestirGIParams.unbiased : 0) | (r.feedback && !useDenoised ? GPURestirGIParams.keepFeedback : 0)
            | (r.feedback && r.feedbackFallback ? GPURestirGIParams.fallback : 0)
        let maxM = UInt32(RestirGISettings.maxMRange.clamp(r.maxM))
        let samples = UInt32(RestirGISettings.spatialSampleRange.clamp(r.spatialSamples))
        let radius = RestirGISettings.radiusRange.clamp(r.radius) * Float(width) / 960
        let clamp: Float = accumulating ? 0 : 4 * 10   // 4 x the firefly clamp, as ReSTIR DI
        let params = GPURestirGIParams(config: SIMD4(flags, maxM, samples, 0),
                                       tuning: SIMD4(radius, max(r.minDistance, 0), clamp, 0),
                                       extra: SIMD4(r.quarterBudget ? 1 : 0, UInt32(RenderSettings.bounceRange.clamp(r.bounces)),
                                                    UInt32(RestirGISettings.maxAgeRange.clamp(r.maxAge)), 0))
        var stages: [ComputeStage] = []
        stages.append(ComputeStage(pass: "restir gi initial") { [self] enc in
            var u = uniforms, p = params
            enc.setComputePipelineState(restirGIInitialPSO)
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            bindScene(enc, slot: slot)
            enc.setBytes(&p, length: MemoryLayout<GPURestirGIParams>.stride, index: 9)
            setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, blueNoiseTexture, lightMap, t.normalDepth[prev],
                              feedbackSource, g.spatial.a, g.spatial.b])
            enc.setBuffer(g.ambient[prev], offset: 0, index: 10)
            if r.quarterBudget { dispatch(enc, "restir gi initial", width: (width + 1) / 2, height: (height + 1) / 2) }
            else { dispatch(enc, "restir gi initial", width: width, height: height) }
        })
        stages.append(ComputeStage(pass: "restir gi temporal") { [self] enc in
            var u = uniforms, p = params
            enc.setComputePipelineState(restirGITemporalPSO)
            enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setBytes(&p, length: MemoryLayout<GPURestirGIParams>.stride, index: 9)
            setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, t.motion, t.normalDepth[prev], g.spatial.a, g.spatial.b,
                              g.reservoir[prev].a, g.reservoir[prev].b, g.temporal.a, g.temporal.b])
            enc.setBuffer(g.ambient[cur], offset: 0, index: 10)
            dispatch(enc, "restir gi temporal", width: width, height: height)
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
                var u = uniforms, p = p
                enc.setComputePipelineState(restirGISpatialPSO)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                bindScene(enc, slot: slot)
                enc.setBytes(&p, length: MemoryLayout<GPURestirGIParams>.stride, index: 9)
                setTextures(enc, [t.surfacePos, t.normalDepth[cur], t.geoNormal, src.a, src.b, dst.a, dst.b, t.indirect, t.giDebug,
                                  g.feedback[cur]])
                enc.setBuffer(g.ambient[cur], offset: 0, index: 10)
                dispatch(enc, "restir gi spatial", width: width, height: height)
            })
        }
        return stages
    }

    /// Radiance-cascade stages for this frame (they write t.indirect and t.giDebug); empty if allocation failed.
    private func radianceCascadeStages(uniforms: Uniforms, targets t: RenderTargets, slot: Int) -> [ComputeStage] {
        let cur = Int(frameIndex & 1), prev = cur ^ 1
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
        return radianceCascades!.stages(pipelines: rcPipelines, uniforms: uniforms,
                                        bindScene: { [unowned self] in bindScene($0, slot: slot) }, lightMap: lightMap,
                                        normalDepth: t.normalDepth[cur], prevNormalDepth: t.normalDepth[prev], targets: t)
    }

    /// Drops all temporal GI state (cascade feedback, denoiser history).
    private func resetGIState() {
        historyValid = false
        restirWritten = false
        restirGIWritten = false
        skyRefreshed = nil
        fogLastFrame = nil
        radianceCascades?.reset()
    }

    // MARK: - Benchmark

    private func runBenchmarkLoop(_ view: MTKView) {
        guard let benchmark, !benchmark.isFinished else { return }
        view.draw()
        DispatchQueue.main.async { [weak self, weak view] in
            guard let view else { return }
            self?.runBenchmarkLoop(view)
        }
    }

    private func applyBenchmarkConfig(_ c: Benchmark.Config) {
        var s = RenderSettings(renderScale: c.renderScale, upscaleFactor: c.upscale, upscaler: c.upscaler,
                               giEnabled: c.giEnabled,
                               bounces: c.bounces, blueNoise: c.blueNoise, paused: c.paused, viewMode: c.viewMode,
                               denoiser: c.denoiser, giMode: c.giMode, lightMaps: c.lightMaps,
                               cascades: c.cascades, scene: c.scene)
        Benchmark.applySceneOverride(to: &s.scene)
        s.fog = c.fog ?? FogSettings.preset(for: s.scene.kind)
        Benchmark.applyFogOverride(to: &s.fog)
        s.sky = c.sky ?? SkySettings.preset(for: s.scene.kind)
        Benchmark.applySkyOverride(to: &s.sky)
        if let rt = c.rayTracer { s.rayTracer = rt }
        if let v = c.virtualGeometry { s.virtualGeometry = v }
        s.denoiser.enabled = c.denoiseEnabled
        Benchmark.applyDenoiserOverride(to: &s.denoiser)
        if !c.accumulate { Benchmark.applyGIOverride(to: &s) }
        if let d = c.directLight { s.directLight = d }
        s.restir = c.restir ?? RestirSettings()
        Benchmark.applyRestirOverride(to: &s.restir)
        s.restirGI = c.restirGI ?? RestirGISettings()
        Benchmark.applyRestirGIOverride(to: &s.restirGI)
        Benchmark.applyViewOverride(to: &s, interactive: false)
        settings = s
        if settings.scene != scene.settings || settings.rayTracer != builtRayTracer || virtualGeometryChanged { rebuildScene(resetCamera: false) }
        camera = c.cameraPath ? Benchmark.cameraPose(progress: 0, scene: settings.scene.kind) : c.camera ?? scene.defaultCamera
        prevCamera = camera
        accumulating = c.accumulate
        referenceGIMode = c.accumulate && c.accumulateTechnique ? c.giMode : nil
        referenceDirectMode = c.accumulate && (c.directLight == .exact || c.directLight == .restir) ? c.directLight : nil
        accumCount = 0
        supersampling = c.accumulate && c.supersample
        colorAccumCount = 0
        animTime = c.startTime
        resetGIState()
        upscalerReset = true
        print("benchmark: \(c.name)")
    }

    private func advanceBenchmark(_ benchmark: Benchmark) {
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
        view?.isPaused = true
        NSApp.terminate(nil)
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

    private func setTextures(_ enc: MTLComputeCommandEncoder, _ textures: [MTLTexture]) {
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
    private static let overlapEnabled = ProcessInfo.processInfo.environment["METALRENDERER_OVERLAP"] != "0"
    /// Frames between full TLAS rebuilds (refits in between). `METALRENDERER_TLAS=1` rebuilds every frame.
    private static let tlasRebuildInterval = max(1, Int(ProcessInfo.processInfo.environment["METALRENDERER_TLAS"] ?? "") ?? 16)

    /// Threadgroup size per kernel name (8x8 if not listed). `METALRENDERER_TG="trace=16x8,atrous=32x4"` overrides it for sweeps.
    /// Measured on an M1 Max: trace 16x8 is ~2% faster than 8x8, atrous 16x16 ~5%; others don't care.
    private static let threadgroupSizes: [String: MTLSize] = {
        var sizes: [String: MTLSize] = ["trace": MTLSize(width: 16, height: 8, depth: 1),
                                        "atrous": MTLSize(width: 16, height: 16, depth: 1),
                                        "regir build": MTLSize(width: 64, height: 1, depth: 1)]
        for item in (ProcessInfo.processInfo.environment["METALRENDERER_TG"] ?? "").split(separator: ",") {
            let kv = item.split(separator: "="), wh = kv.count == 2 ? kv[1].split(separator: "x").compactMap { Int($0) } : []
            if wh.count == 2 { sizes[String(kv[0])] = MTLSize(width: wh[0], height: wh[1], depth: 1) }
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

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ kernel: String, width: Int, height: Int) {
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                            threadsPerThreadgroup: Renderer.threadgroupSizes[kernel] ?? MTLSize(width: 8, height: 8, depth: 1))
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
        let upscalerName = s.upscaler == .custom ? "TAAU" : s.upscaler == .metalFXSpatial ? "MetalFX spatial" : "MetalFX"
        let res = outWidth > width ? String(format: "%ld×%ld → %@ %ld×%ld", width, height, upscalerName, outWidth, outHeight)
                                   : String(format: "%ld×%ld", width, height)
        let stats = String(format: "%@ — %.0f fps — GPU %.1f ms", res, fps, gpuMs)
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
        if frozenLOD != nil && scene.usesVirtualGeometry { sceneName += " — LOD frozen" }
        view?.window?.title = String(format: "MetalRenderer%@ — %@ — %@ — %@ RT — %@ noise — denoiser %@ — %@%@",
                                     sceneName, stats, gi, s.rayTracer == .custom ? "custom" : "Metal",
                                     s.blueNoise ? "blue" : "white", s.denoiser.enabled ? "on" : "off",
                                     RenderSettings.viewModes[s.viewMode].lowercased(), s.paused ? " — paused" : "")
        statsLine = stats
        cpuMs = frameIntervalCount > 0 ? frameIntervalSum / Double(frameIntervalCount) : 0
        frameIntervalSum = 0
        frameIntervalCount = 0
        if traversalFrames > 0 { traversal = (traversalSum, traversalFrames) }
        traversalSum = TraversalStats()
        traversalFrames = 0
        for observer in tickObservers { observer() }
        if passTimeFrames > 0 {
            let n = Double(passTimeFrames)
            var times = passTimeOrder.map { (name: $0, ms: passTimeSums[$0]! / n) }
            let other = passTimeFrameMs / n - times.reduce(0) { $0 + $1.ms }
            if other > 0.005 { times.append((name: "other", ms: other)) }   // MetalFX, its copy, texture streaming
            onPassTimes?(times)
            passTimeOrder = []
            passTimeSums = [:]
            passTimeFrameMs = 0
            passTimeFrames = 0
        }
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

    /// Recompiles Shaders.metal and remakes every pipeline (R key, traversal counters). On failure the old pipelines stay.
    @discardableResult
    func reloadShaders() -> Bool {
        do {
            try loadShaders(for: builtRayTracer, lightTypes: builtLightTypes, recompile: true)
            resetGIState()
            upscalerReset = true
            return true
        } catch {
            print("Shader reload failed (keeping previous version):\n\(error)")
            return false
        }
    }

    /// The custom tracer's traversal counters (RT_STATS): turning them on or off recompiles the shaders.
    var traversalCounters: Bool {
        get { CustomRayTracer.statsEnabled }
        set {
            guard newValue != CustomRayTracer.statsEnabled else { return }
            CustomRayTracer.statsEnabled = newValue
            if !reloadShaders() { CustomRayTracer.statsEnabled = !newValue }
            traversalLast = nil
            traversal = nil
            traversalSum = TraversalStats()
            traversalFrames = 0
        }
    }

    /// What the Debug window shows (built when it asks, on the stats tick).
    func debugInfo() -> DebugInfo {
        var d = DebugInfo()
        d.stats = statsLine
        d.cpuMs = cpuMs
        d.sceneTitle = settings.scene.kind.title
        d.instances = scene.instances.count
        d.virtualInstances = scene.instances.filter { $0.virtualMesh >= 0 }.count
        d.triangles = scene.instances.reduce(0) { $0 + ($1.mesh >= 0 ? Int(scene.meshes[$1.mesh].indexCount) / 3 : 0) }
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
                             selected: vg.stats.selected, capacity: VirtualGeometry.capacity, overflow: vg.stats.overflow,
                             residentGroups: vg.stats.residentGroups, residentMB: vg.residentMB, poolMB: vg.poolBytes >> 20,
                             pending: vg.stats.pending, loadedThisFrame: vg.stats.loadedThisFrame)
        }
        d.vgPixelError = settings.virtualGeometry.pixelError
        d.vgFrozen = frozenLOD != nil && scene.usesVirtualGeometry
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

    // MARK: - InputHandler

    func keyDown(_ event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return }
        if ["w", "a", "s", "d", "q", "e"].contains(key) {
            heldKeys.insert(key)
            return
        }
        if event.isARepeat { return }
        switch key {
        case "\t": onTogglePanel?()
        case "i": onToggleDebug?()
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
        case "u":
            guard upscaleSupported else { print("MetalFX temporal upscaling is not supported on this GPU"); break }
            let steps = upscaleSteps
            settings.upscaleFactor = steps[((steps.firstIndex(of: settings.upscaleFactor) ?? 0) + 1) % steps.count]
        case "r": if reloadShaders() { print("Shaders reloaded") }
        default: break
        }
    }

    func keyUp(_ event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return }
        heldKeys.remove(key)
    }

    func mouseDragged(dx: Float, dy: Float) {
        camera.yaw += dx * 0.004
        camera.pitch = min(max(camera.pitch - dy * 0.004, -1.5), 1.5)
    }
}
