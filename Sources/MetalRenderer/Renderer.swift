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
    let giDebug: MTLTexture         // debug visualisation written by surfel / cascade GI (view mode "GI debug")
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
    private var surfelPipelines: SurfelPipelines!
    private var surfelGI: SurfelGI?                    // created on first use of the surfel GI mode
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
    private var customRT: CustomRayTracer?                             // custom ray tracer only
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
    private var lightBuffers: [MTLBuffer] = []
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
            if settings.giMode != oldValue.giMode || settings.surfels.maxSurfels != oldValue.surfels.maxSurfels {
                resetGIState()
            }
            onSettingsChanged?(settings)
        }
    }
    var onSettingsChanged: ((RenderSettings) -> Void)?
    var onTogglePanel: (() -> Void)?            // Tab key
    /// What "Reset to Defaults" restores (differs from RenderSettings() on GPUs without MetalFX).
    private(set) var defaultSettings = RenderSettings()
    var onStats: ((String) -> Void)?            // twice a second: resolution, fps and GPU time
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
    private var fpsFrames = 0
    private var fpsTime = CACurrentMediaTime()
    private var fps: Double = 0

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
        } else if ProcessInfo.processInfo.environment["METALRENDERER_SCENE"] != nil {
            // Starting scene: loads in the background like a switch in the panel.
            var s = settings
            Benchmark.applySceneOverride(to: &s.scene)
            s.applySceneDefaults(from: defaultSettings)
            settings = s
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
        let surfel = SurfelPipelines(clear: try pipeline("surfelClearKernel"), begin: try pipeline("surfelBeginKernel"),
                                     transform: try pipeline("surfelTransformKernel"), scan: try pipeline("surfelScanKernel"),
                                     scatter: try pipeline("surfelScatterKernel"), trace: try pipeline("surfelTraceKernel"),
                                     gatherSpawn: try pipeline("surfelGatherSpawnKernel"),
                                     lifecycle: try pipeline("surfelLifecycleKernel"))
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
        surfelPipelines = surfel
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
        lmd.width = Renderer.lightMapSize(lightCount: scene.lights.count)
        lmd.height = lmd.width
        lmd.arrayLength = max(scene.lights.count, 1)
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
        surfelGI = nil   // its grid covers the old scene's bounds
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
    private func encodeSky(_ cb: MTLCommandBuffer) {
        guard let sky = skyMap, let shape = cloudShape, let detail = cloudDetail, let shadow = cloudShadowMap,
              let tLUT = transmittanceLUT, let msLUT = multiScatterLUT, let mean = skyMean,
              let enc = cb.makeComputeCommandEncoder() else { return }
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
            enc.endEncoding()
            if let blit = cb.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: shape)
                blit.generateMipmaps(for: detail)
                blit.endEncoding()
            }
            cloudNoiseReady = true
            guard let next = cb.makeComputeCommandEncoder() else { return }
            encodeSkyTexels(next, sky: sky, shape: shape, detail: detail, shadow: shadow, tLUT: tLUT, msLUT: msLUT, mean: mean, cb: cb)
            return
        }
        encodeSkyTexels(enc, sky: sky, shape: shape, detail: detail, shadow: shadow, tLUT: tLUT, msLUT: msLUT, mean: mean, cb: cb)
    }

    private func encodeSkyTexels(_ enc: MTLComputeCommandEncoder, sky: MTLTexture, shape: MTLTexture, detail: MTLTexture,
                                 shadow: MTLTexture, tLUT: MTLTexture, msLUT: MTLTexture, mean: MTLBuffer, cb: MTLCommandBuffer) {
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
        enc.endEncoding()
        if let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: sky)
            blit.endEncoding()
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
                  let lights = device.makeBuffer(length: max(scene.lights.count, 1) * MemoryLayout<GPULight>.stride, options: .storageModeShared) else {
                throw RendererError.resourceCreation("per-frame buffers")
            }
            instanceDescBuffers.append(desc)
            instanceDataBuffers.append(data)
            lightBuffers.append(lights)

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
            let speed: Float = NSEvent.modifierFlags.contains(.shift) ? 8 : 2.5
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
        u.width = UInt32(width)
        u.height = UInt32(height)
        u.frameIndex = frameIndex
        u.lightCount = UInt32(scene.lights.count)
        u.bounces = settings.giEnabled && activeGIMode == .pathTraced ? UInt32(settings.bounces) : 0
        u.flags = (historyValid ? UniformFlags.historyValid : 0) | (settings.denoiser.enabled ? UniformFlags.denoise : 0)
        if accumulating { u.flags |= UniformFlags.noClamp | UniformFlags.reference }
        if usesSpecular { u.flags |= UniformFlags.specular }
        // References trace every light (lower variance per frame); METALRENDERER_LIGHTS=all does it everywhere (baseline).
        if accumulating || Renderer.allLights { u.flags |= UniformFlags.allLights }
        if settings.lightMaps && activeGIMode == .pathTraced && !accumulating { u.flags |= UniformFlags.lightMaps }
        u.viewMode = UInt32(settings.viewMode)
        let d = settings.denoiser
        u.denoise = SIMD4<Float>(DenoiserSettings.luminanceSigmaRange.clamp(d.luminanceSigma),
                                 DenoiserSettings.maxHistoryRange.clamp(d.maxHistory),
                                 DenoiserSettings.antiLagRange.clamp(d.antiLag), 0)
        u.instanceCount = UInt32(scene.instances.count)
        u.lightGroupEnd = scene.lightGroupEnd
        if skyActive { u.flags |= UniformFlags.skyMap }
        return u
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
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
        if !settings.paused { animTime += dt }
        scene.update(time: animTime)

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
        // Radiance cascades and the direct-light denoiser don't touch each other's textures (unless the denoiser also
        // filters the cascades' output), so their dispatches can overlap on the GPU: the shared encoder is then
        // concurrent, with explicit barriers between dependent stages. Benchmark per-pass timing keeps everything serial,
        // and METALRENDERER_OVERLAP=0 turns overlapping off for A/B timing.
        let splitPasses = benchmark != nil && Benchmark.splitPasses
        let overlap = !splitPasses && Renderer.overlapEnabled && settings.giEnabled && activeGIMode == .radianceCascades
            && !settings.cascades.denoiseIndirect
        var openEncoder: MTLComputeCommandEncoder?
        func beginComputePass(_ name: String) -> MTLComputeCommandEncoder? {
            if openEncoder != nil && !splitPasses { return openEncoder }   // normal mode: one shared encoder
            openEncoder?.endEncoding()
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
        if builtRayTracer == .metal, let asEncoder = passBuffer("tlas").makeAccelerationStructureCommandEncoder() {
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
            asEncoder.endEncoding()
        }
        // Streamed textures: map and upload the levels last frame's hits asked for, ahead of this frame's work.
        textureStreamer?.update(frame: frameIndex, slot: slot, framesInFlight: Renderer.maxFramesInFlight, cmd: passBuffer("textures"))
        // Custom ray tracer: rebuild the moving instances' TLAS (a few small dispatches, in order).
        // Virtual geometry: this frame's level-of-detail cut and its cluster tree, in the same pass.
        if let customRT, let enc = passBuffer("tlas").makeComputeCommandEncoder() {
            let view = VGView(camPos: lod.0, pixelScale: lod.1, tau: settings.virtualGeometry.pixelError, frame: frameIndex)
            customRT.encodeBuild(enc, slot: slot, instanceData: instanceDataBuffers[slot], view: view)
            enc.endEncoding()
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
        if skyActive { encodeSky(passBuffer("sky")) }

        // 1b. Light-visibility maps, for GI techniques and the path tracer's light-map variant.
        let frameUniforms = uniforms
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

        // 2b. Surfel or radiance-cascade GI writes t.indirect (the path tracer already did, inside traceKernel).
        let giMode = activeGIMode
        var giStages: [ComputeStage] = []
        if settings.giEnabled && giMode == .radianceCascades {
            giStages = radianceCascadeStages(uniforms: uniforms, targets: t, slot: slot)
        }

        // 3. Denoise (SVGF-style): temporal accumulation + edge-aware a-trous wavelet filter.
        //    Path-traced light is denoised either as one signal or as direct and indirect separately (sharper
        //    direct shadows, since indirect noise no longer inflates the variance that guides the luminance
        //    edge-stopping). Surfel / cascade output is already smooth: it skips the denoiser unless its
        //    "denoise indirect" option is on (then 1 a-trous pass). With GI off there's no indirect light to denoise.
        let techniqueGI = giMode != .pathTraced
        let denoiseIndirect = settings.giEnabled && (!techniqueGI || techniqueDenoisesIndirect)
        //    With the shadow denoiser (default), direct light goes through its own visibility filter instead (3b),
        //    and SVGF handles only indirect light.
        let shadowDenoiser = settings.denoiser.enabled && settings.denoiser.shadowDenoiser && !accumulating
            && Renderer.shadowDenoiserAllowed
        let separate = settings.denoiser.separateSignals || techniqueGI || !settings.giEnabled || shadowDenoiser
        let passCount = settings.denoiser.passes(for: giMode)
        var signals: [(noisy: [MTLTexture], targets: DenoiseTargets, passes: Int)] =
            shadowDenoiser ? [] : separate ? [([t.direct], t.denoise[0], passCount)] : [([t.direct, t.indirect], t.denoise[0], passCount)]
        if separate && denoiseIndirect { signals.append(([t.indirect], t.denoise[1], techniqueGI ? 1 : passCount)) }
        // Emissive-mesh lights' direct light: sampled per pixel, so noisy. With the shadow denoiser it's an SVGF signal
        // of its own (first, so finalIllumination keeps the indirect light last); otherwise it joins the direct light.
        let meshLights = !scene.meshLights.isEmpty
        let denoiseMeshLights = meshLights && shadowDenoiser
        if denoiseMeshLights { signals.insert(([t.meshDirect], t.denoise[3], settings.denoiser.passes(for: .pathTraced)), at: 0) }
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
                                  fogNoiseTex ?? dummy3D])
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
        let manyLights = scene.lightGroupEnd[3] > 4 && frameUniforms.flags & UniformFlags.allLights == 0
        let reuse = manyLights && settings.manyLightReuse > 0 && settings.manyLightRays == 1
        let reservoirsValid = reuse && reservoirsWritten && historyValid
        reservoirsWritten = reuse
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
                var u = frameUniforms
                enc.setComputePipelineState(temporalPSO)
                enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                for (noisy, d, _) in signals {
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
                    var u = frameUniforms, step = Int32(1 << i)
                    enc.setComputePipelineState(atrousPSO)
                    enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.setBytes(&step, length: MemoryLayout<Int32>.stride, index: 1)
                    for (_, d, passes) in signals where i < passes {
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

        if overlap, let enc = beginComputePass("trace") {
            // Light map, trace and cascade probes need only the TLAS; then the cascade chain and the denoiser chain
            // advance in lock-step, one barrier per step. Reflections read the cascades' result: after both.
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
            runSerial(headStages)
            if settings.giEnabled && giMode == .surfels {
                encodeSurfels(beginComputePass: beginComputePass, uniforms: &uniforms, targets: t, slot: slot)
            }
            runSerial(giStages)
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
        var drawable = view.currentDrawable
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
            openEncoder?.endEncoding()
            openEncoder = nil
            upscaler.encode(into: passBuffer("upscale"), targets: t, drawable: drawable.texture, jitter: jitter, reset: upscalerReset)
            upscalerReset = false
        }
        openEncoder?.endEncoding()

        var writeCapture: (() -> Void)?
        if let benchmark, benchmark.shouldCapture, let vg = customRT?.virtualGeometry { print("  " + vg.summary) }
        if let benchmark, benchmark.shouldCapture, let vg = customRT?.virtualBLAS { print("  " + vg.summary) }
        if let benchmark, benchmark.shouldCapture, let ts = textureStreamer {
            print("  " + ts.summary)
            if ProcessInfo.processInfo.environment["METALRENDERER_TEXTURE_DEBUG"] != nil { print(ts.details) }
        }
        if let benchmark, benchmark.isMeasuring, CustomRayTracer.statsEnabled, let customRT {
            // One frame's counters: reset at the first measured frame, read at the capture frame (single-frame runs).
            if benchmark.shouldCapture { print("  " + customRT.takeStats()) } else { _ = customRT.takeStats() }
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
        cmd.addCompletedHandler { [weak self] cb in
            if !Benchmark.isEnabled { vg?.collect(slot: slot, frame: vgFrame); streamer?.collect(slot: slot) }
            if let bench, recordFrame {
                var passMs: [String: Double] = [:]
                var start = Double.infinity, end = 0.0
                for p in passes {
                    p.cmd.waitUntilCompleted()
                    passMs[p.name] = (p.cmd.gpuEndTime - p.cmd.gpuStartTime) * 1000
                    start = min(start, p.cmd.gpuStartTime)
                    end = max(end, p.cmd.gpuEndTime)
                }
                if passes.isEmpty {   // METALRENDERER_BENCH_SPLIT=0: the whole frame is one command buffer, as in normal mode
                    passMs["frame"] = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                    start = cb.gpuStartTime
                    end = cb.gpuEndTime
                }
                bench.record(.init(config: benchConfig, passMs: passMs, spanMs: (end - start) * 1000))
            }
            writeCapture?()
            semaphore.signal()
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            DispatchQueue.main.async { self?.gpuMs = ms }
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
        settings.giEnabled && !accumulating && (activeGIMode != .pathTraced || settings.lightMaps)
    }

    /// References always path trace, so they stay ground truth whatever GI mode is selected.
    private var activeGIMode: GIMode { accumulating ? .pathTraced : settings.giMode }

    private var techniqueDenoisesIndirect: Bool {
        switch activeGIMode {
        case .pathTraced: return true
        case .surfels: return settings.surfels.denoiseIndirect
        case .radianceCascades: return settings.cascades.denoiseIndirect
        }
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

    /// Encodes surfel GI, which writes t.indirect (and t.giDebug).
    private func encodeSurfels(beginComputePass: (String) -> MTLComputeCommandEncoder?,
                               uniforms: inout Uniforms, targets t: RenderTargets, slot: Int) {
        let cur = Int(frameIndex & 1)
        let maxSurfels = SurfelSettings.maxSurfelsOptions.contains(settings.surfels.maxSurfels) ? settings.surfels.maxSurfels : 32768
        if surfelGI == nil || surfelGI!.maxSurfels != maxSurfels {
            do {
                surfelGI = try SurfelGI(device: device, maxSurfels: maxSurfels, sceneBounds: scene.bounds())
            } catch {
                print(error)
                return
            }
        }
        surfelGI!.encode(beginPass: beginComputePass, pipelines: surfelPipelines, uniforms: &uniforms,
                         settings: settings.surfels, bindScene: { self.bindScene($0, slot: slot) }, lightMap: lightMap,
                         normalDepth: t.normalDepth[cur], targets: t)
    }

    /// Drops all temporal GI state (surfel pool, cascade feedback, denoiser history).
    private func resetGIState() {
        historyValid = false
        skyRefreshed = nil
        fogLastFrame = nil
        radianceCascades?.reset()
        surfelGI?.reset()
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
                               surfels: c.surfels, cascades: c.cascades, scene: c.scene)
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
        settings = s
        if settings.scene != scene.settings || settings.rayTracer != builtRayTracer || virtualGeometryChanged { rebuildScene(resetCamera: false) }
        camera = c.cameraPath ? Benchmark.cameraPose(progress: 0, scene: settings.scene.kind) : c.camera ?? scene.defaultCamera
        prevCamera = camera
        accumulating = c.accumulate
        accumCount = 0
        supersampling = c.accumulate && c.supersample
        colorAccumCount = 0
        animTime = c.startTime
        resetGIState()
        upscalerReset = true
        print("benchmark: \(c.name)")
    }

    private func advanceBenchmark(_ benchmark: Benchmark) {
        if benchmark.current.giMode == .surfels, let surfelGI, benchmark.progressInConfig >= 1 {
            let s = surfelGI.stats   // frames are serialized in benchmark mode, so this frame has completed
            let total = s.alive + s.spawned - s.killed + s.free
            print("  surfels: \(s.alive) alive (+\(s.spawned) spawned, -\(s.killed) freed this frame), \(s.free) free; pool "
                  + (total == surfelGI.maxSurfels ? "consistent" : "INCONSISTENT (\(total) != \(surfelGI.maxSurfels))"))
        }
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
    private static let allLights = ProcessInfo.processInfo.environment["METALRENDERER_LIGHTS"] == "all"
    private static let overlapEnabled = ProcessInfo.processInfo.environment["METALRENDERER_OVERLAP"] != "0"
    /// Frames between full TLAS rebuilds (refits in between). `METALRENDERER_TLAS=1` rebuilds every frame.
    private static let tlasRebuildInterval = max(1, Int(ProcessInfo.processInfo.environment["METALRENDERER_TLAS"] ?? "") ?? 16)

    /// Threadgroup size per kernel name (8x8 if not listed). `METALRENDERER_TG="trace=16x8,atrous=32x4"` overrides it for sweeps.
    /// Measured on an M1 Max: trace 16x8 is ~2% faster than 8x8, atrous 16x16 ~5%; others don't care.
    private static let threadgroupSizes: [String: MTLSize] = {
        var sizes: [String: MTLSize] = ["trace": MTLSize(width: 16, height: 8, depth: 1),
                                        "atrous": MTLSize(width: 16, height: 16, depth: 1)]
        for item in (ProcessInfo.processInfo.environment["METALRENDERER_TG"] ?? "").split(separator: ",") {
            let kv = item.split(separator: "="), wh = kv.count == 2 ? kv[1].split(separator: "x").compactMap { Int($0) } : []
            if wh.count == 2 { sizes[String(kv[0])] = MTLSize(width: wh[0], height: wh[1], depth: 1) }
        }
        return sizes
    }()

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
        let gi = !s.giEnabled ? "GI off" : s.giMode == .pathTraced ? "GI path traced, \(s.bounces) bounce\(s.bounces == 1 ? "" : "s")"
                                                                   : "GI \(s.giMode.title.lowercased())"
        let upscalerName = s.upscaler == .custom ? "TAAU" : s.upscaler == .metalFXSpatial ? "MetalFX spatial" : "MetalFX"
        let res = outWidth > width ? String(format: "%ld×%ld → %@ %ld×%ld", width, height, upscalerName, outWidth, outHeight)
                                   : String(format: "%ld×%ld", width, height)
        let stats = String(format: "%@ — %.0f fps — GPU %.1f ms", res, fps, gpuMs)
        var sceneName = s.scene.kind == .stress ? " — stress: \(s.scene.objects) objects, \(s.scene.lights) lights" : ""
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
        onStats?(stats)
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
        case " ": settings.paused.toggle()
        case "g": settings.giEnabled.toggle()
        case "m": settings.giMode = GIMode(rawValue: (settings.giMode.rawValue + 1) % GIMode.allCases.count) ?? .pathTraced
        case "b": settings.blueNoise.toggle()
        case "n": settings.denoiser.enabled.toggle()
        case "[": settings.bounces = max(RenderSettings.bounceRange.lowerBound, settings.bounces - 1)
        case "]": settings.bounces = min(RenderSettings.bounceRange.upperBound, settings.bounces + 1)
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
        case "r":
            do {
                try loadShaders(for: builtRayTracer, lightTypes: builtLightTypes, recompile: true)
                resetGIState()
                upscalerReset = true
                print("Shaders reloaded")
            } catch {
                print("Shader reload failed (keeping previous version):\n\(error)")
            }
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
