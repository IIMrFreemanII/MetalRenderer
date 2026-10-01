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
    let visibility: MTLTexture      // per light group (rgba = groups 0...3): visibility of this frame's shadow ray(s)
    let blocker: MTLTexture         // per light group: penumbra half width of the occluded samples, 0 = visible
    let shadow: ShadowTargets       // shadow denoiser state
    /// Denoiser state for [0] direct + indirect light combined (or direct alone) and [1] indirect light alone.
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
        visibility = try make(.rgba8Unorm, "visibility")
        blocker = try make(.rgba16Float, "blocker")
        shadow = try ShadowTargets(device: device, width: width, height: height, make)
        denoise = [try DenoiseTargets(make, "direct"), try DenoiseTargets(make, "indirect")]
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
    private var temporalPSO: MTLComputePipelineState!
    private var atrousPSO: MTLComputePipelineState!
    private var shadowTemporalPSO: MTLComputePipelineState!
    private var shadowFilterPSO: MTLComputePipelineState!
    private var compositePSO: MTLComputePipelineState!
    private var accumulatePSO: MTLComputePipelineState!
    private var lightMapPSO: MTLComputePipelineState!
    private var manyLightsPSO: MTLComputePipelineState!
    private var manyLightsReusePSO: MTLComputePipelineState!
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
    private var materialTextures: [MTLTexture] = []   // Scene.textures, decoded (MaterialTextures.swift)
    private var textureTable: MTLBuffer!              // their MTLResourceIDs (MSL MaterialTexture array)
    private var shadingArgs: MTLBuffer!               // MSL SceneShading: materials, UVs, texture table (buffer 7)
    private var shadingResources: [MTLResource] = []
    private var primitiveAS: [MTLAccelerationStructure] = []           // Metal ray tracer only
    private var primitiveASResources: [MTLResource] = []
    private var customRT: CustomRayTracer?                             // custom ray tracer only
    private var rtPipelines: RTPipelines?
    /// The tracer the shaders were compiled for and the scene's structures were built for.
    private var builtRayTracer = RayTracerKind.initial
    private var blueNoiseTexture: MTLTexture!   // filled the first time blue noise is turned on
    /// Light-map side: 128 for up to 16 lights, then smaller so all maps together cost about 16 128^2 maps to trace.
    static func lightMapSize(lightCount: Int) -> Int {
        lightCount <= 16 ? 128 : max(32, Int(128 * (16 / Double(lightCount)).squareRoot()) / 8 * 8)
    }
    private var lightMap: MTLTexture!           // per-light distance maps (texture array), see lightMapKernel
    private var blueNoiseFilled = false

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
    private var accumTextures: (direct: MTLTexture, indirect: MTLTexture)?
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

        try loadShaders(for: settings.rayTracer)
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
        } else if ProcessInfo.processInfo.environment["METALGI_SCENE"] != nil {
            // Starting scene: loads in the background like a switch in the panel.
            var s = settings
            Benchmark.applySceneOverride(to: &s.scene)
            s.applySceneDefaults(from: defaultSettings)
            settings = s
        }
    }

    // MARK: - Setup

    /// Compiles Shaders.metal for `kind` (CUSTOM_RT macro). The custom tracer's build kernels exist only in its variant.
    private func loadShaders(for kind: RayTracerKind) throws {
        let source = try String(contentsOf: shaderURL, encoding: .utf8)
        let options = MTLCompileOptions()
        // MSL 3.2 for device-scope fences and coherent buffers (rtFitKernel, custom ray tracer). Older systems keep
        // 3.0 and then need METALGI_RT=metal.
        if #available(macOS 15.0, *) { options.languageVersion = .version3_2 } else { options.languageVersion = .version3_0 }
        options.preprocessorMacros = ["CUSTOM_RT": NSNumber(value: kind == .custom ? 1 : 0)]
        let library = try device.makeLibrary(source: source, options: options)

        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw RendererError.missingFunction(name) }
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
        let rt = kind != .custom ? nil :
            RTPipelines(prep: try pipeline("rtPrepKernel"), keys: try pipeline("rtKeysKernel"),
                        sortLocal: try pipeline("rtSortLocalKernel"), sortGlobal: try pipeline("rtSortGlobalKernel"),
                        hierarchy: try pipeline("rtHierarchyKernel"), fit: try pipeline("rtFitKernel"))
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
        rcPipelines = rc
        rtPipelines = rt
        if let rt { customRT?.pipelines = rt }
        surfelPipelines = surfel
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
        let customRT: CustomRayTracer?
    }
    private var loading: (scene: SceneSettings, rayTracer: RayTracerKind)?   // being prepared in the background

    private func prepareScene(_ sceneSettings: SceneSettings, rayTracer: RayTracerKind, reuse current: Scene?) throws -> PreparedScene {
        let newScene = current ?? Scene(sceneSettings)
        let textures = try MaterialTextures.load(newScene.textures, device: device, queue: queue)
        let rt = rayTracer == .custom ? try CustomRayTracer(device: device, scene: newScene, slots: Renderer.maxFramesInFlight) : nil
        return PreparedScene(scene: newScene, rayTracer: rayTracer, textures: textures, customRT: rt)
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
        try createGeometryBuffers(textures: prepared?.textures)
        if builtRayTracer == .metal { try buildPrimitiveAccelerationStructures() }
        try createPerFrameResources()
        if builtRayTracer == .custom {
            customRT = try prepared?.customRT ?? CustomRayTracer(device: device, scene: scene, slots: Renderer.maxFramesInFlight)
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
            if prepared.rayTracer != builtRayTracer { try loadShaders(for: prepared.rayTracer) }
            try createSceneResources(prepared)
        } catch {
            print("Scene rebuild failed, keeping the previous scene: \(error)")
            scene = old
            settings.scene = old.settings
            settings.rayTracer = oldRayTracer
            try? loadShaders(for: oldRayTracer)
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
        materialTextures = try textures ?? MaterialTextures.load(scene.textures, device: device, queue: queue)
        textureTable = try makeBuffer(materialTextures.map(\.gpuResourceID), "textureTable")
        guard let args = device.makeBuffer(length: 32, options: .storageModeShared) else {
            throw RendererError.resourceCreation("buffer shadingArgs")
        }
        args.label = "shadingArgs"
        args.contents().storeBytes(of: materialBuffer.gpuAddress, toByteOffset: 0, as: UInt64.self)
        args.contents().storeBytes(of: uvBuffer.gpuAddress, toByteOffset: 8, as: UInt64.self)
        args.contents().storeBytes(of: textureTable.gpuAddress, toByteOffset: 16, as: UInt64.self)
        shadingArgs = args
        shadingResources = [materialBuffer, uvBuffer, textureTable] + materialTextures
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
        let lights = scene.gpuLights()
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
        if accumulating { u.flags |= UniformFlags.noClamp }
        // References trace every light (lower variance per frame); METALGI_LIGHTS=all does it everywhere (baseline).
        if accumulating || Renderer.allLights { u.flags |= UniformFlags.allLights }
        if settings.lightMaps && activeGIMode == .pathTraced && !accumulating { u.flags |= UniformFlags.lightMaps }
        u.viewMode = UInt32(settings.viewMode)
        let d = settings.denoiser
        u.denoise = SIMD4<Float>(DenoiserSettings.luminanceSigmaRange.clamp(d.luminanceSigma),
                                 DenoiserSettings.maxHistoryRange.clamp(d.maxHistory),
                                 DenoiserSettings.antiLagRange.clamp(d.antiLag), 0)
        u.instanceCount = UInt32(scene.instances.count)
        u.lightGroupEnd = scene.lightGroupEnd
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

        if settings.scene != scene.settings || settings.rayTracer != builtRayTracer {
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
        // and METALGI_OVERLAP=0 turns overlapping off for A/B timing.
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
        // Custom ray tracer: rebuild the moving instances' TLAS (a few small dispatches, in order).
        if let customRT, let enc = passBuffer("tlas").makeComputeCommandEncoder() {
            customRT.encodeBuild(enc, slot: slot, instanceData: instanceDataBuffers[slot])
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

        // 1b. Light-visibility maps, for GI techniques and the path tracer's light-map variant.
        let frameUniforms = uniforms
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
                              t.visibility, t.blocker])
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
        var finalIllumination = [t.denoise[0].pingA]
        var denoiseStages: [ComputeStage] = []
        // 2c. More than 4 lights: direct light from one sampled light per group (manyLightsKernel), after the trace
        //     and before anything that reads direct light or visibility.
        let manyLights = scene.lights.count > 4 && frameUniforms.flags & UniformFlags.allLights == 0
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
                setTextures(enc, [t.direct, t.indirect, accum.direct, accum.indirect])
                dispatch(enc, "accumulate", width: width, height: height)
            })
            accumCount += 1
            finalIllumination = [accum.direct, accum.indirect]
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
            if separate { uniforms.flags |= UniformFlags.separateSignals }
        }

        if overlap, let enc = beginComputePass("trace") {
            // Light map, trace and cascade probes need only the TLAS; then the cascade chain and the denoiser chain
            // advance in lock-step, one barrier per step.
            for stage in headStages + giStages.prefix(1) { stage.encode(enc) }
            enc.memoryBarrier(scope: [.buffers, .textures])
            let gi = Array(giStages.dropFirst())
            for i in 0..<max(gi.count, denoiseStages.count) {
                if i < denoiseStages.count { denoiseStages[i].encode(enc) }
                if i < gi.count { gi[i].encode(enc) }
                enc.memoryBarrier(scope: [.buffers, .textures])
            }
        } else {
            runSerial(headStages)
            if settings.giEnabled && giMode == .surfels {
                encodeSurfels(beginComputePass: beginComputePass, uniforms: &uniforms, targets: t, slot: slot)
            }
            runSerial(giStages)
            runSerial(denoiseStages)
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
                              t.giDebug, t.surfacePos, t.geoNormal])
            enc.setBuffer(lightBuffers[slot], offset: 0, index: 1)
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
        if let benchmark, let drawable, benchmark.shouldCapture {
            writeCapture = benchmark.encodeCapture(of: drawable.texture, into: cmd, device: device)
        }
        if let drawable { cmd.present(drawable) }
        let semaphore = frameSemaphore
        let bench = benchmark, benchConfig = benchmark?.configIndex ?? 0
        let recordFrame = benchmark?.isMeasuring ?? false
        let passes = passBuffers
        cmd.addCompletedHandler { [weak self] cb in
            if let bench, recordFrame {
                var passMs: [String: Double] = [:]
                var start = Double.infinity, end = 0.0
                for p in passes {
                    p.cmd.waitUntilCompleted()
                    passMs[p.name] = (p.cmd.gpuEndTime - p.cmd.gpuStartTime) * 1000
                    start = min(start, p.cmd.gpuStartTime)
                    end = max(end, p.cmd.gpuEndTime)
                }
                if passes.isEmpty {   // METALGI_BENCH_SPLIT=0: the whole frame is one command buffer, as in normal mode
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
        if benchmark != nil { cmd.waitUntilCompleted() }

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
        enc.setBuffer(shadingArgs, offset: 0, index: 7)
        enc.useResources(shadingResources, usage: .read)
        enc.setBuffer(lightBuffers[slot], offset: 0, index: 8)
    }

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
        if let rt = c.rayTracer { s.rayTracer = rt }
        s.denoiser.enabled = c.denoiseEnabled
        Benchmark.applyDenoiserOverride(to: &s.denoiser)
        if !c.accumulate { Benchmark.applyGIOverride(to: &s) }
        settings = s
        if settings.scene != scene.settings || settings.rayTracer != builtRayTracer { rebuildScene(resetCamera: false) }
        camera = c.cameraPath ? Benchmark.cameraPose(progress: 0, scene: settings.scene.kind) : scene.defaultCamera
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

    private func accumulationTextures(width: Int, height: Int) -> (direct: MTLTexture, indirect: MTLTexture)? {
        if let t = accumTextures, t.direct.width == width, t.direct.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let direct = device.makeTexture(descriptor: d), let indirect = device.makeTexture(descriptor: d) else { return nil }
        accumTextures = (direct, indirect)
        accumCount = 0
        return accumTextures
    }

    private func setTextures(_ enc: MTLComputeCommandEncoder, _ textures: [MTLTexture]) {
        for (i, texture) in textures.enumerated() { enc.setTexture(texture, index: i) }
    }

    /// sRGB, so shaders and MetalFX write linear color and the GPU encodes it.
    static let drawableFormat = MTLPixelFormat.bgra8Unorm_srgb
    private static let shadowDenoiserAllowed = ProcessInfo.processInfo.environment["METALGI_SHADOWS"] != "0"
    private static let allLights = ProcessInfo.processInfo.environment["METALGI_LIGHTS"] == "all"
    private static let overlapEnabled = ProcessInfo.processInfo.environment["METALGI_OVERLAP"] != "0"
    /// Frames between full TLAS rebuilds (refits in between). `METALGI_TLAS=1` rebuilds every frame.
    private static let tlasRebuildInterval = max(1, Int(ProcessInfo.processInfo.environment["METALGI_TLAS"] ?? "") ?? 16)

    /// Threadgroup size per kernel name (8x8 if not listed). `METALGI_TG="trace=16x8,atrous=32x4"` overrides it for sweeps.
    /// Measured on an M1 Max: trace 16x8 is ~2% faster than 8x8, atrous 16x16 ~5%; others don't care.
    private static let threadgroupSizes: [String: MTLSize] = {
        var sizes: [String: MTLSize] = ["trace": MTLSize(width: 16, height: 8, depth: 1),
                                        "atrous": MTLSize(width: 16, height: 16, depth: 1)]
        for item in (ProcessInfo.processInfo.environment["METALGI_TG"] ?? "").split(separator: ",") {
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
        view?.window?.title = String(format: "MetalGI%@ — %@ — %@ — %@ RT — %@ noise — denoiser %@ — %@%@",
                                     sceneName, stats, gi, s.rayTracer == .custom ? "custom" : "Metal",
                                     s.blueNoise ? "blue" : "white", s.denoiser.enabled ? "on" : "off",
                                     RenderSettings.viewModes[s.viewMode].lowercased(), s.paused ? " — paused" : "")
        onStats?(stats)
    }

    /// Adds glTF models to the scene, side by side 2.5 m in front of the camera on the floor, facing it
    /// (glTF models face +Z). The scene reloads in the background.
    func addModels(_ urls: [URL]) {
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
        case "u":
            guard upscaleSupported else { print("MetalFX temporal upscaling is not supported on this GPU"); break }
            let steps = upscaleSteps
            settings.upscaleFactor = steps[((steps.firstIndex(of: settings.upscaleFactor) ?? 0) + 1) % steps.count]
        case "r":
            do {
                try loadShaders(for: builtRayTracer)
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
