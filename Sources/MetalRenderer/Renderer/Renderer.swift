import AppKit
import Buildings
import Characters
import Effects
import EngineCore
import Garments
import Landscape
import Materials
import MetalKit
import Physics
import Plants
import QuartzCore
import simd

/// Makes the frames, on its own thread (`RenderThread`): once that runs, everything here belongs to it. The main thread
/// talks to it through `RendererController`, which posts work with `perform` and gets values back.
package final class Renderer: NSObject {
    package static let maxFramesInFlight = GPUFrames.maxInFlight
    /// Metal 4's TLAS instance descriptors, the indirect ones: a packed 4x3 float matrix and 4 x uint32 (64 bytes), then
    /// a user ID and the mesh's structure's resource ID (72 bytes).
    package var instanceDescriptorStride: Int { sceneBuffers.descriptorStride }

    package let device: MTLDevice
    /// The GPU it draws with (the Material Designer bakes on it). Any thread.
    package var metalDevice: MTLDevice { device }
    package let queue: MTLCommandQueue
    package weak var surface: RenderSurface?
    package var scene = Scene()
    /// The shaders' entry file: at the top of the sources (`SourceTree.target`), or
    /// `METALRENDERER_SHADERS=<path to a Shaders.metal>`, which lets one binary run another copy of the shaders (an A/B
    /// of a shader change without a second build).
    package let shaderURL = ProcessInfo.processInfo.environment["METALRENDERER_SHADERS"].map { URL(fileURLWithPath: $0) }
        ?? SourceTree.target.appendingPathComponent("Shaders.metal")

    /// Every compute pipeline, for the tracer and the light types of the scene being drawn (Pipelines.swift). Replaced
    /// whole, between two frames, by a scene load or a shader reload that built the next set in the background.
    package var pipelines: Pipelines!
    package var shaderGeneration = 0                // shader reloads so far: a set built from an older one is stale
    package let pipelineCache = PipelineCache<Pipelines>()   // the sets for the light types of the scenes before (makePipelines)
    package var frozenLOD: (SIMD3<Float>, Float)?   // "Freeze LOD": camera position and pixel scale it was turned on at
    package var radianceCascades: RadianceCascades?   // created on first use of the radiance-cascades GI mode

    /// The scene's geometry, its instances' records and Metal's structures over them (SceneBuffers.swift).
    package var sceneBuffers: SceneBuffers!
    package var positionBuffer: MTLBuffer { sceneBuffers.positions }
    package var normalBuffer: MTLBuffer { sceneBuffers.normals }
    package var indexBuffer: MTLBuffer { sceneBuffers.indices }
    package var meshBuffer: MTLBuffer { sceneBuffers.meshes }
    /// Per slot: animated light proxies change their materials' emission while older frames are still being drawn.
    package var materialBuffers: [MTLBuffer] { sceneBuffers.materials }
    /// For what is built off the frames (a scene's structures): the frames' queue runs its command buffers in order,
    /// and a frame would wait behind a build.
    package lazy var buildQueue: MTLCommandQueue = {
        let q = device.makeCommandQueue()!
        q.label = "builds"
        return q
    }()
    package var materialsPending: [Range<Int>?] = []   // per slot: the materials changed since it was last written
    package var lightTrianglesPending: [Range<Int>?] = []   // ...and the light table's triangles (the open world's dusk)
    package var frameDataWritten: [Bool] = []          // per slot: a frame's instances and lights have been written to it
    /// This frame's instance and light records, kept from frame to frame: only what moves or flickers is rewritten, then
    /// each goes to the slot's buffer in one copy. (Writing the records straight into the shared buffers costs the GPU
    /// 0.35 ms a frame with 16384 moving lights: they stay in the CPU's caches. A large memcpy doesn't leave them there.)
    package var lightStage: [GPULight] = []
    package var stageComplete = false                  // the stage holds every record
    package var uvBuffer: MTLBuffer { sceneBuffers.uvs }
    package var triangleMaterialBuffer: MTLBuffer { sceneBuffers.triangleMaterials }   // Scene.triangleMaterials (meshes of several materials)
    package var emissiveBuffer: MTLBuffer { sceneBuffers.emissive }                    // emissive-mesh lights' triangles (MSL EmissiveTriangle)
    package var materialTextures: [MTLTexture] = []   // Scene.textures, decoded (MaterialTextures.swift)
    package var textureTables: [MTLBuffer] = []       // per slot, their MTLResourceIDs (MSL MaterialTexture array):
                                                      // a slot's own, as a procedural material's bake replaces its texture
                                                      // in the slots one by one (applyProcedural)
    package var shadingArgs: [MTLBuffer] = []         // per slot, MSL SceneShading: materials, UVs, textures, streaming (buffer 7)
    package var shadingResources: [MTLResource] = []
    /// Procedural materials (Scene+Procedural): per slot their extras (MSL MaterialExtra) and the instances' alpha tests
    /// (TraceScene.opacity), written when the scene's `extrasVersion` has moved on; the bakes' textures by their slot in
    /// the table (the latest, and per frame slot what its table holds: what its frames declare), the table entries a slot
    /// has still to take, and the textures replaced, kept until no frame in flight can read them.
    package var extrasBuffers: [MTLBuffer] = []
    package var opacityBuffers: [MTLBuffer] = []
    package var extrasWritten: [Int] = []
    package var procParamBuffers: [MTLBuffer] = []
    package var procParamsWritten: [Int] = []
    package var proceduralTextures: [UInt32: MTLTexture] = [:]
    package var slotTextures: [[UInt32: MTLTexture]] = []
    package var tablePending: [[UInt32: MTLTexture]] = []
    package var retiredTextures: [(frame: UInt32, texture: MTLTexture)] = []
    /// Per procedural material, the bake's key its textures are; per graph name in the catalog shown, its key.
    package var proceduralApplied: [Int: String] = [:]
    package var proceduralKeys: (catalog: String, keys: [String: String]) = ("", [:])
    package var srgbViews: [ObjectIdentifier: MTLTexture] = [:]
    /// The Material Painter's GPU side (Renderer+Painter.swift): per painted object its session (texture set, layers).
    package var painter = PainterGPU()
    /// A benchmark's painting still to do (Benchmark.Config.Event.paint), a step a frame.
    package var painterScript: [PainterStep] = []
    /// The Terrain Editor's side (Renderer+Terrain.swift): sculpt mode, the brush, the sectors' buffers' revisions.
    package var terrain = TerrainGPU()
    /// The scene's water on the GPU (Renderer+Water.swift): its map, waves and per-frame record; nil without water.
    package var water: WaterSystem?
    /// Its status, when it changes (on the render thread).
    package var onTerrain: ((TerrainStatus) -> Void)?
    /// A benchmark's terrain edits still to do (Benchmark.Config.Event.terrain), frames to wait, the changes undone.
    package var terrainScript: [TerrainStep] = []
    package var terrainScriptWait = 0
    package var terrainUndone = Set<Int>()
    /// The displaced meshes' records (Scene.displaceVertices, displaceMembers), and per displacing material the height
    /// its meshes were last moved by (and the surface's values then), and the materials whose meshes wait to be moved.
    package var displaceBuffers: (vertices: MTLBuffer, members: MTLBuffer)?
    package var displaceSource: [Int: (height: MTLTexture, surface: MatSurface)] = [:]
    package var displacePending = Set<Int>()
    package var textureStreamer: TextureStreamer?     // full-resolution textures, streamed per mip (sparse)
    package var staticMinLod: MTLBuffer!              // without streaming: every level resident (zeros)
    package var feedbackDummy: MTLBuffer!
    package var primitiveAS: [MTLAccelerationStructure] { sceneBuffers.primitives }
    package var primitiveASResources: [MTLResource] = []
    package var namedPrimitives: [String: MTLAccelerationStructure] { sceneBuffers?.namedPrimitives ?? [:] }
    package var namedBlocks: [String: MeshBlock] { sceneBuffers?.namedBlocks ?? [:] }
    package var namedInstanceBlocks: [String: InstanceBlock] { sceneBuffers?.namedInstanceBlocks ?? [:] }
    /// The crowd's pose slots, if the scene has a crowd: the skinning, then their structures' refit.
    package var crowdSkinner: CrowdSkinner?
    /// The scene's rigid bodies on the GPU (PhysicsSettings.backend), or nil: then `Scene.update` steps them.
    package var physicsGPU: PhysicsGPU?
    /// The garment workshop's cloth on the GPU (Renderer+Garment.swift).
    package var garmentGPU: GarmentSolverGPU?
    /// The scene's particle effects on the GPU, if it has any, and per slot the steps its structure was last built at
    /// (a still frame has nothing to pose or build).
    package var particlesGPU: ParticlesGPU?
    /// With fractured objects stepped on the CPU: the dust's ring of breaks (PhysicsGPU.breakRing's layout), written
    /// here from the steps' PhysicsWorld.breakLog, and how many of those it has had.
    package var cpuBreakRing: MTLBuffer?
    package var cpuBreaksTaken = 0
    /// The VFX library's (VFXCompiler): its entry next to Shaders.metal, compiled as the pipelines in use are.
    package var vfxSetup: VFXCompiler.Setup {
        VFXCompiler.Setup(entry: shaderURL.deletingLastPathComponent().appendingPathComponent("ShadersVFX.metal"),
                          lightTypes: pipelines.lightTypes, stats: pipelines.stats,
                          generation: shaderGeneration)
    }
    package var particlesBuilt = [Int?](repeating: nil, count: Renderer.maxFramesInFlight)
    package var particlesVersion = 0
    /// The VFX editor's gizmos (VFX/VFXGizmos.swift): what they show, the selected emitter's handle (where it was last
    /// drawn), the drag of one of its arrows (its axis, and how far along it the cursor was), and where a drag goes.
    /// `METALRENDERER_GIZMOS=<effect>[/<emitter>]`: the gizmos from the start (offscreen pictures of them).
    package var gizmoTarget: VFXGizmos.Target? = ProcessInfo.processInfo.environment["METALRENDERER_GIZMOS"].map {
        let parts = $0.split(separator: "/", maxSplits: 1).map(String.init)
        return VFXGizmos.Target(effect: parts.first ?? "", emitter: parts.count > 1 ? parts[1] : nil)
    }
    package var gizmoHandle: SIMD3<Float>?
    package var gizmoBuffers = [MTLBuffer?](repeating: nil, count: Renderer.maxFramesInFlight)
    package var gizmoViewSize = SIMD2<Float>(1280, 800)
    /// A handle dragged: the effect, the emitter, the move (m) since the last call, the phase (0 begins, 1 moves, 2 ends).
    package var onGizmoMoved: ((_ effect: String, _ emitter: String, _ delta: SIMD3<Float>, _ phase: Int) -> Void)?
    /// The Material Painter's status, when it changes (Renderer+Painter.swift; on the render thread).
    package var onPainter: ((PainterStatus) -> Void)?
    /// A pen's pressure for the next press or drag (1 for a mouse).
    package var penPressure: Float = 1
    /// The VFX editor's last edit that needs new code (VFXLive.swift), until its library is compiled.
    package var pendingEffects: (system: ParticleSystem, effects: [VFXInstance], owners: [String], notes: [String])?
    package var particlesCamera = SIMD4<Float>.zero
    package var primitiveRefit: PrimitiveRefit? { sceneBuffers.primitiveRefit }
    /// The scene's virtual geometry, if it has any: what its instances' descriptors name, and its tables.
    package var virtualTracing: VirtualTracing?
    /// Per slot: the wind, time, leaf fall and sway its plants' descriptors were last written for (WindFrame.plantKey).
    package var plantsWritten = [WindFrame.PlantKey?](repeating: nil, count: Renderer.maxFramesInFlight)
    /// What the ray-tracing kernels get at buffer 1 (MSL TraceScene), per slot.
    package var traceScene: TraceSceneArgs!
    /// What the frames go through: Metal 4's command queue, argument table and residency set (Metal4Backend.swift).
    package let metal4: Metal4Frame
    /// Metal 4's compiler: the pipelines', MetalFX's scalers'.
    package var compiler: MTL4Compiler { metal4.compiler }
    package var blueNoiseTexture: MTLTexture!   // the blue-noise tile (zeros until `blueNoiseReady`)
    /// Light-map side: 128 for up to 16 lights, then smaller so all maps together cost about 16 128^2 maps to trace.
    package static func lightMapSize(lightCount: Int) -> Int {
        lightCount <= 16 ? 128 : max(32, Int(128 * (16 / Double(lightCount)).squareRoot()) / 8 * 8)
    }
    /// The walkable interiors' box for the GPU (Uniforms / GPUFogParams interiorLo, interiorHi; empty: lo > hi). In it
    /// GI's hits see the sun through a shadow ray and the fog's sky light is occluded: the sun's light map, over the
    /// whole scene, has texels metres wide, sees no wall or ceiling, and lit every room inside as if the sun shone on
    /// its walls.
    package static func interiorBox(_ scene: Scene) -> (lo: SIMD4<Float>, hi: SIMD4<Float>) {
        guard let box = scene.interiorBox else { return (SIMD4(1, 1, 1, 0), SIMD4(-1, -1, -1, 0)) }
        return (SIMD4(box.lo, 1), SIMD4(box.hi, 1))
    }
    package var lightMap: MTLTexture!           // per-light distance maps (texture array), see lightMapKernel
    package var blueNoiseReady = false
    // Volumetric fog (Shaders/Fog.metal), allocated when first turned on.
    package var fogNoiseTexture: MTLTexture?    // tiling 3D density noise (FogNoise)
    package var fogNoisePending = false         // being generated in the background
    package var fogGrid: FogTargets?            // froxel grid at the current render resolution
    package var fogReference: MTLTexture?       // per-pixel reference march (benchmark references)
    package var postTargetsCache: PostTargets?   // the lens and the finish, at the current output resolution
    package var taaTargetsCache: TAATargets?     // temporal AA without upscaling, at the traced resolution...
    package var taaHistory = false               // ...and the last frame left its resolved light in them
    package var fogLastFrame: UInt32?           // the frame that last wrote the froxel grid, and its far distance:
    package var fogLastFar: Float = 0           //   history is reprojected only from the frame just before
    package var dummy3D: MTLTexture!            // bound in place of the fog textures while fog is off
    package var dummy2D: MTLTexture!
    package var dummyArray: MTLTexture!         // in place of the sky texture with a constant sky
    // Sky and clouds (Shaders/Sky.metal), allocated when first used.
    package var skyMap: MTLTexture?             // [0] upper, [1] lower hemisphere (equal-area squares), mipmapped
    package var cloudShadowMap: MTLTexture?     // clouds' transmittance toward the sun over the ground around the scene
    package var cloudShape: MTLTexture?         // 128^3 Perlin-Worley + Worley octaves (cloudNoiseKernel)
    package var cloudDetail: MTLTexture?        // 32^3 Worley octaves
    package var cloudNoiseReady = false         // the noise and the atmosphere's tables have been drawn
    package var transmittanceLUT: MTLTexture?   // atmosphere transmittance to its top, by height and angle
    package var multiScatterLUT: MTLTexture?    // atmosphere multiple scattering, by height and sun angle
    package var skyMean: MTLBuffer?             // the sky's mean radiance per hemisphere (skyMeanKernel), for the next frame
    package var skyImage: (path: String, exposure: Float, image: SkyImage, texture: MTLTexture)?
    package var skyImageFailed: String?         // a path that didn't load (not retried every frame)
    package var skyImageLoading = false         // one is being decoded in the background
    package var skyParams = GPUSkyParams()      // this frame's (also written into the shading arguments)
    package var skyActive = false               // this frame uses the sky texture
    package var skyRefreshed: (sky: SkySettings, scene: Int)?   // what the sky texture was fully drawn for
    package var atmosphereCache: (sun: SIMD3<Float>, ground: SIMD3<Float>)?
    /// Shading-argument layout (MSL SceneShading): seven buffer addresses, the sky and cloud-shadow textures, SkyParams
    /// (16-byte aligned), then the extras', the programs' parameters', the water's and the cars' damage's addresses.
    package static let shadingSkyOffset = 56, shadingParamsOffset = 80
    package static let shadingExtrasOffset = 80 + MemoryLayout<GPUSkyParams>.stride   // MaterialExtra's address (MATERIAL_EXTRAS)
    package static let shadingProcParamsOffset = shadingExtrasOffset + 8   // the programs' parameters (PROCEDURAL_CODE)
    package static let shadingWaterOffset = shadingExtrasOffset + 16   // WaterScene's address (WATER), or 0
    package static let shadingDamageOffset = shadingExtrasOffset + 24   // the cars' damage's address (SceneBuffers.damage), or 0
    package static let shadingArgsLength = shadingExtrasOffset + 32   // 304 (16-byte aligned): the shader asserts it

    // Per-frame-in-flight resources (the CPU writes these while the GPU may still read older ones)
    package var instanceDescBuffers: [MTLBuffer] { sceneBuffers.instanceDescriptors }
    package var instanceDataBuffers: [MTLBuffer] { sceneBuffers.instanceData }
    package var lightBuffers: [MTLBuffer] = []      // per slot: the lights, then the light table (LightTable)
    package var restirGrid: RestirTargets?
    package var regirBuffer: MTLBuffer?             // the light grid's reservoirs (GPURegirReservoir), GPU only
    package var regirParams = GPURegirParams()      // this frame's grid (consume.x = 0: off), bound with the scene
    package var restirWritten = false               // last frame's ReSTIR pass stored its reservoirs
    package var lightTree: LightTree?               // the path tracer's many lights: built on its first such frame in a scene
    package var lightTreeRefitFrame: UInt32 = 0
    package var lightTreeBuffers: [MTLBuffer?] = [MTLBuffer?](repeating: nil, count: Renderer.maxFramesInFlight)
    package var lightTreeVersions = [Int](repeating: -1, count: Renderer.maxFramesInFlight)   // what each slot's holds
    package var restirGIGrid: RestirGITargets?
    package var restirGIWritten = false             // last frame's ReSTIR GI pass stored its reservoirs (and feedback)
    package var instanceAS: [MTLAccelerationStructure] {
        sceneBuffers.voxelLOD.map { [MTLAccelerationStructure](repeating: $0.current, count: Renderer.maxFramesInFlight) }
            ?? sceneBuffers.instanceStructures
    }
    package var instanceScratch: [MTLBuffer] { sceneBuffers.instanceScratch }
    package var instanceASBuilt = Set<Int>()
    /// Per slot: its instances' descriptors changed this frame (something moved, a cut, the wind), so its top-level
    /// structure is updated. One that stays as it is isn't refitted for nothing (a forest without wind).
    package var instanceASStale = [Bool](repeating: true, count: Renderer.maxFramesInFlight)
    package let frameSemaphore = DispatchSemaphore(value: Renderer.maxFramesInFlight)
    /// Auto exposure's histograms (PostSettings.autoExposure: AutoExposure.swift).
    package lazy var exposureMeter = AutoExposure(device: device, framesInFlight: Renderer.maxFramesInFlight)

    package var targets: RenderTargets?

    // State
    package var camera = Camera()
    package var prevCamera = Camera()
    package var frameIndex: UInt32 = 0
    package var animTime: Float = 0
    package var previousAnimTime: Float = 0            // a frame ago: what moves by the clock alone (the wind) reprojects with it
    package var lastTime = CACurrentMediaTime()
    package var frameDt: Float = 1.0 / 60   // this frame's step of the clock (simulate): auto exposure eases by it
    /// User-adjustable settings, shared by the keyboard shortcuts and the settings panel.
    package var settings = RenderSettings() {
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
            // Solid shading leaves no history: the light's starts over on the way back (upscalerReset: MetalFX's too).
            if settings.solid != oldValue.solid { resetGIState(); upscalerReset = true }
            dayChanged(from: oldValue)
            // Any change can change the picture: the reference starts over (a benchmark's starts with its config).
            if !benchmarkAccumulating { resetReference() }
            publishSettings()
        }
    }
    package var persistSettings = false         // the app (not benchmarks), once the saved settings are loaded
    /// The last of the controller's settings edits applied (`applySettings`), sent back with the settings.
    package var settingsUpdate = 0
    /// GPU pass timings for the Debug window (a command buffer per pass): per frame, then averaged over the stats
    /// interval.
    package var profilePasses = false
    /// The Debug window is open: the stats tick brings its `DebugInfo`, and every frame its times (`onFrameTime`).
    package var debugActive = false
    // What the renderer tells the main thread (RendererController), all called on the render thread. Set before the
    // render thread starts.
    /// After every settings change (edits, keyboard shortcuts, scene loads, fallbacks): the settings, the last edit
    /// applied, and whether to save them.
    package var onSettings: ((_ settings: RenderSettings, _ update: Int, _ persist: Bool) -> Void)?
    /// Twice a second, when the stats (fps, GPU time, `statsLine`) are refreshed.
    package var onTick: ((RendererStatus) -> Void)?
    /// A scene installed: its outline (the Project Graph's).
    package var onOutline: ((SceneOutline) -> Void)?
    /// Every frame once its GPU work is done, while `debugActive`: the CPU time since the previous frame started and
    /// the GPU time, both in ms. For the Debug window's graph.
    package var onFrameTime: ((_ cpuMs: Double, _ gpuMs: Double) -> Void)?
    /// Called once, when the first frame has been drawn.
    package var onFirstFrame: (() -> Void)?
    /// What is loading in the background and how far it is, for the loading overlay (any thread reads it). The app
    /// reports to it; benchmarks don't.
    package let loadActivity = LoadActivity()
    package var loadJob: LoadJob?                   // the scene load running in the background
    /// After a scene is installed: until when texture levels and virtual geometry pages count as loading (until they
    /// settle; while the camera moves later they stream on without showing).
    package var settlingStreams: (from: Double, until: Double)?
    package var streamsPublished = 0.0
    /// Where frames are made, and what runs `perform`'s work (RenderThread.swift).
    package let renderThread = RenderThread()
    /// What "Reset to Defaults" restores (differs from RenderSettings() on GPUs without MetalFX).
    package private(set) var defaultSettings = RenderSettings()
    /// Resolution, fps and GPU time, refreshed twice a second.
    package var statsLine = ""
    package var upscaler: Upscaler?           // MetalFX's denoising scaler, while upscaling
    package var upscalerReset = true          // drop the upscaler's history on the next frame
    package var interpolator: FrameInterpolator?   // MetalFX's frame interpolator, while upscaling with it on
    package var interpolating = false         // the last frame presented an in-between picture (Auto's switch)
    /// The solid look's targets (its colour and sun, its normal, depth and AO, its objects' ids: solidTraceKernel's)
    /// while it is on, and the scene's material flags (Scene.materialFlags) as the kernel reads them.
    package var solidTargetsStore: [MTLTexture] = []
    package var solidFlagsStore: MTLBuffer?
    package var solidFlagsCopyStore: [UInt8] = []
    /// Presents interpolated frames' pictures once they are done (FrameInterpolator.Presenter): the window's layer only.
    package lazy var presenter = (surface as? LayerSurface).flatMap { FrameInterpolator.Presenter(device: device, layer: $0.layer) }
    /// The GPU's time a frame, smoothed: Auto's switch and how long each picture is held. Not the time between frames,
    /// which the holds themselves stretch (the frames wait for drawables): held for half of that, they slowed down
    /// until each was held five refreshes.
    package var smoothedGPUMs = 0.0
    package var supersampling = false         // benchmark reference: jitter + average the final colour
    package var colorAccum: MTLTexture?
    package var colorAccumCount: UInt32 = 0
    package var prevJitter = SIMD2<Float>(repeating: 0)
    // Benchmark reference: average raw frames of a paused scene instead of denoising.
    package var benchmarkAccumulating = false
    package var referenceGIMode: GIMode?                // benchmark references: accumulate this GI method instead of paths
    package var referenceDirectMode: DirectLightMode?   // benchmark references: this direct-light method instead of exact
    package var accumCount: UInt32 = 0
    package var accumTextures: (direct: MTLTexture, indirect: MTLTexture, specular: MTLTexture)?
    /// This frame's reference picture (Reference in the settings, or a benchmark's): what is averaged over frames.
    package var referenceMode: ReferenceMode { benchmarkAccumulating ? .accumulated : settings.reference.mode }
    /// Raw frames of the frame's own passes are averaged instead of denoised (a benchmark's reference, or Reference
    /// "Accumulated passes").
    package var accumulating: Bool { referenceMode == .accumulated }
    // Reference "Path traced": pathTraceKernel's running mean, the paths in it per pixel, and the view it was made from.
    package var pathTraceAccum: MTLTexture?
    /// What liquidKernel leaves the trace and liquidApplyKernel (Shaders/Liquid.metal): per pixel the bent ray (its
    /// origin, w = 1 where it is bent; its direction, w = how far the liquid is), what comes through and the reflection.
    /// Water's (waterKernel, Shaders/Water.metal) the same, w = 2 and up, and its own light in `scatter`.
    package struct LiquidTargets {
        let ray: MTLTexture
        let direction: MTLTexture
        let through: MTLTexture
        let reflection: MTLTexture
        let scatter: MTLTexture
        /// Water's reflections, this frame's and the last's by turns (rgb: what the surface's mirror ray found, a: the
        /// surface's distance): half of them are traced a frame, the others taken from the last frame's.
        let reflections: [MTLTexture]
    }
    package var liquidTextures: LiquidTargets?
    package var particleLayerTexture: (color: MTLTexture, depth: MTLTexture)?
    package var particleHazeTexture: MTLTexture?
    package var pathTraceCount: UInt32 = 0
    package var referenceEpoch: UInt32 = 0      // which average this is: a new one draws new samples (its seed)
    package var referenceView: [SIMD4<Float>] = []
    package var lightProxies: MTLBuffer?        // makeLightProxies
    package var lightProxyCount = 0
    private(set) lazy var upscaleSupported = Capabilities.current.metalFXDenoiser
    package lazy var maxUpscale = CGFloat(Upscaler.maxScale(on: device))
    /// Upscale factors this GPU supports (for MetalFX's denoising scaler), with 0 meaning off.
    package var upscaleSteps: [CGFloat] { upscaleSupported ? [0, 1.5, 2, 3].filter { $0 <= maxUpscale } : [0] }
    package var historyValid = false
    /// MetalFX's denoising scaler is this frame's upscaler: it denoises, so SVGF and the shadow denoiser stay off.
    package var neuralDenoise: Bool { upscaler != nil }
    /// This project's denoisers (SVGF, the shadow denoiser) are on.
    package var denoiserOn: Bool { settings.denoiser.enabled && !neuralDenoise }
    package var reservoirsWritten = false       // last frame's manyLightsKernel stored light picks (light reuse)
    package var heldKeys = Set<String>()
    /// Every key down now, whatever took it (releaseKeys lets them all go).
    package var downKeys = Set<String>()
    /// The arrow keys (AppKit's function-key characters): up, down, left, right; held, they turn the camera.
    package static let arrowKeys = ["\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}"]
    /// How fast an arrow turns the camera, in drag points a second (Camera.turnRate: about 90° a second).
    package static let arrowTurnSpeed: Float = 400
    package var shiftHeld = false
    /// The mouse holds a body: the cursor (0...1 across and down) and the grab plane's distance along the view.
    package var holding: (cursor: SIMD2<Float>, depth: Float)?
    /// What the camera turns about (the scene view's pivot, `pivot`): the point it looks at, and how far it is from it.
    /// The workshops frame theirs on what they show; elsewhere navigation sets it (nil: 8 m in front).
    package var orbit: (target: SIMD3<Float>, distance: Float)?
    /// The scene view's mouse (SceneNavigation.swift): what a drag does, chosen when its button went down, and where
    /// the cursor last was; the right button held (W A S D Q E fly only then); Command held (Option-Command-drag pans).
    package enum NavDrag { case orbit, look, pan, dolly }
    package var navDrag: NavDrag?
    package var rightDrag: NavDrag?
    package var navCursor: SIMD2<Float>?
    package var rightHeld = false
    /// The left button looks around: pressed on nothing that took the press (a stroke, a handle, a body).
    package var leftLook = false
    /// A button that looks around is held: W A S D Q E fly, the scroll wheel sets their speed.
    package var lookHeld: Bool { rightHeld || leftLook || scene.behaviour?.captured == true }
    package var commandHeld = false
    /// Walk mode (V): the walker the camera is the eyes of, what it walks among, and what it is told.
    package var walker: Walker?
    /// The frame something last moved in, and each slot's last top-level refit (`writeFrameData`).
    package var lastMotionFrame = 0
    package var slotRefitFrame = [Int](repeating: -1, count: 8)
    package var walkGrid: ColliderGrid?
    package var walkRemainder: Float = 0
    package var crouchHeld = false, jumpPending = false
    package var lastLiftY: [Float] = []
    package var walkMessage: String?
    package var clickAt: SIMD2<Float>?
    /// Click-to-pick (the Material Designer's): armed, the next click (not a drag) is picked: its ray traced at the end
    /// of a frame (encodePick), read back when that frame's slot comes round again, and told to `onMaterialPicked`.
    package var pickArmed = false
    package var pickRequest: SIMD2<Float>?
    package var pickBuffer: MTLBuffer?
    /// The pick is a plain click's: what it finds is selected (`selectedInView`), not told to `onMaterialPicked`.
    package var pickSelects = false
    package var onMaterialPicked: ((MaterialPick?) -> Void)?
    /// A click in the view selected instance `i` (nil: nothing, the sky); the Project Graph selects its node.
    package var onSelectedInView: ((Int?) -> Void)?
    /// The camera's yaw and pitch, each frame they change (the scene gizmo).
    package var onCameraTurned: ((_ yaw: Float, _ pitch: Float) -> Void)?
    package var sentAngles: SIMD2<Float>?
    /// The time on the scene's day clock (`dayTime`), when it has moved a minute of the day (the day bar).
    package var onDayTime: ((Float) -> Void)?
    package var sentDayTime: Float?
    /// The view's width over its height, for the cursor's ray.
    package var viewAspect: Float = 1.6
    /// The benchmark this renderer runs (`METALRENDERER_BENCH`); nil in the app, and for a second renderer that
    /// isn't the benchmark's (the Modeller's stage in a headless app).
    package let benchmark: Benchmark?

    // Stats
    package var gpuMs: Double = 0
    package var firstFrameDrawn = false
    package var passTimeOrder: [String] = [], passTimeSums: [String: Double] = [:]
    package var passTimeFrameMs = 0.0, passTimeFrames = 0
    package var fpsFrames = 0
    package var fpsTime = CACurrentMediaTime()
    package var fps: Double = 0
    package var lastDrawTime: CFTimeInterval?
    package var frameIntervalMs = 0.0           // CPU time between the starts of the last two frames
    package var frameIntervalSum = 0.0, frameIntervalCount = 0
    package var cpuMs = 0.0                     // frameIntervalMs averaged over the stats interval
    /// The CPU's own work in `draw` (simulation, uploads, encoding; not the waits for a frame slot or the drawable),
    /// averaged over the stats interval. The frame interval is GPU-bound and hides it.
    package var encodeMs = 0.0, encodeSum = 0.0, encodeCount = 0
    // The ray queries' counters (Debug window, RT_STATS): summed per frame, averaged per stats interval.
    package var traversalSum = TraversalStats(), traversalFrames = 0
    package var traversalLast: [UInt32]?
    package var traversal: (stats: TraversalStats, frames: Int)?

    /// `surface`: the window's view (set up with `configureForRenderer`) or an `OffscreenSurface`; the caller keeps it.
    /// `benchmarked`: whether it runs the process's benchmark, if there is one (false: it starts as the app's does).
    package init(device: MTLDevice, surface: RenderSurface, benchmarked: Bool = true) throws {
        benchmark = benchmarked && Benchmark.isEnabled ? Benchmark() : nil
        validateGPULayouts()
        // Every ray is traced through Metal's acceleration structures, and every frame goes through Metal 4: there is
        // nothing to fall back to.
        guard Capabilities.current.metalRayTracing else { throw RendererError.unsupported("Metal ray tracing") }
        guard Capabilities.current.metal4RayTracing else { throw RendererError.unsupported("Metal 4 ray tracing (an M3 or later)") }
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.resourceCreation("command queue")
        }
        guard let metal4 = Metal4Frame(device: device, framesInFlight: Renderer.maxFramesInFlight,
                                       layer: (surface as? LayerSurface)?.layer) else {
            throw RendererError.resourceCreation("Metal 4 command queue")
        }
        self.device = device
        self.queue = queue
        self.metal4 = metal4
        self.surface = surface
        super.init()
        // The starting tracer and upscaler come from the environment: fall back where this GPU lacks them.
        let (supported, notes) = settings.clamped(to: Capabilities.current)
        notes.forEach { print($0) }
        settings = supported
        defaultSettings = defaultSettings.clamped(to: Capabilities.current).settings

        traceScene = try TraceSceneArgs(device: device, slots: Renderer.maxFramesInFlight)
        try createDummyTextures()
        try createSceneResources()
        try createBlueNoiseTexture()
        if benchmark != nil {
            // Benchmarks start with everything in place: the same frames every run.
            pipelines = try Pipelines(device: device, source: shaderURL, compiler: compiler,
                                      lightTypes: scene.lightTypeMask, stats: TraceSceneArgs.statsEnabled, procedural: scene.proceduralCode)
            keepPipelines(pipelines, generation: shaderGeneration)
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

    // MARK: - What the painter (Renderer+Painter.swift) reads of the renderer

    package var renderTargetsForPainter: RenderTargets? { targets }
    package var materialTexturesForPainter: [MTLTexture] { materialTextures }
    package func resetReferenceForPainting() { resetReference() }
    package func cursorRayForPainter(_ cursor: SIMD2<Float>) -> SIMD3<Float> { cursorRay(cursor) }
    /// The render's size in pixels, and its pixels per point of the view (a brush's size is in points).
    package var renderSizeForPainter: SIMD2<Float> {
        guard let t = targets else { return SIMD2(1280, 800) }
        return SIMD2(Float(t.width), Float(t.height))
    }
    package var renderPixelsPerPoint: Float { renderSizeForPainter.y / max(painter.viewPoints.y, 1) }
    package var orbitForPainter: (target: SIMD3<Float>, distance: Float)? {
        get { orbit }
        set { orbit = newValue }
    }
    /// The camera turned to look at `p` (from where it is), then placed on its orbit.
    package func lookAtForPainter(_ p: SIMD3<Float>) {
        let d = p - camera.position
        guard simd_length(d) > 1e-4 else { return }
        let n = simd_normalize(d)
        camera.pitch = asin(min(max(n.y, -1), 1))
        camera.yaw = atan2(n.x, -n.z)
        placeOrbitingCamera()
    }
    package func placeOrbitForPainter() { placeOrbitingCamera() }

    /// The ray from the camera through `cursor` (0...1 across and down), unjittered.
    package func cursorRay(_ cursor: SIMD2<Float>) -> SIMD3<Float> {
        let t = tan(camera.fovY / 2)
        return normalize(camera.forward + camera.right * ((2 * cursor.x - 1) * t * viewAspect) + camera.up * ((1 - 2 * cursor.y) * t))
    }

    /// The held body's target this frame: under the cursor, on the plane facing the camera at the grab's depth (so it
    /// follows the camera as it moves too).
    package func moveGrab() {
        guard let holding, scene.physics != nil, scene.physicsGrab.target.w > 0 else { return }
        let direction = cursorRay(holding.cursor)
        let along = holding.depth / max(dot(direction, camera.forward), 0.1)
        scene.physicsGrab.target = SIMD4(camera.position + direction * along, 1)
    }

    // MARK: - Setup: state

    /// The scene loads: one prepared in the background at a time (on `sceneLoads`), only the latest put in.
    package var loads = SceneLoadQueue()
    package var loading: SceneSettings? { loads.loading }   // being prepared in the background
    package let sceneLoads = DispatchQueue(label: "scene loads", qos: .userInitiated)
    package var sceneRemake: String?                // the scene's builder runs again, with the same settings: why
    package var devReload: DevReload?               // the dev build's hot reload (startDevReload)
    package var streaming = Streaming()

    // MARK: - Scripts: state

    package var scripts: ScriptRunner?              // compiles and runs Swift scripts (Renderer+Scripting)
    package var scriptServer: ScriptServer?         // the socket Tools/script.py and the MCP server reach
    package var frameCaptures: [FrameCapture] = []  // the next frame's picture, asked for (captureFrame)
    package var placedPending: SceneFile?           // a scene file edited while a scene loads: made once it is in
    package var placedReselect: (kind: SceneKind, object: Int)?   // the placed object selected again once its scene is made

    // MARK: - Procedural materials: state


    // MARK: - Interiors on demand: state

    package var lastCameraPosition: SIMD3<Float>?

    // MARK: - The selection, and where the camera flies: state

    /// What names the scene or was begun in it (picks, drags, a flight, the scripts' closures): what of it a scene put
    /// in keeps is its SceneChange's (SceneSession.after).
    package var session = SceneSession()
    /// The target asked for before its scene was in.
    package var pendingFrame: FrameTarget?
    /// What is selected in the view (a click, the Project Graph): its instances, and the box round them now (drawn
    /// while it is selected); Shift-F's lock: where the box's centre was last frame (the camera follows it).
    package var selection: (target: FrameTarget, box: AABB)?
    package var pivotLock: SIMD3<Float>?

    // MARK: - Frame setup: state

    package var voxelLevels = VoxelLevels()
    package let voxelQueue = DispatchQueue(label: "voxel levels", qos: .utility)

    // MARK: - GI techniques: state

    /// The encoder `bindScene` last declared the scene's resources in (Metal 4: the frame; kept so its address can't
    /// be another's; dropped when the frame is committed).
    package var sceneDeclaredIn: AnyObject?

    // MARK: - Benchmark: state

    package var benchmarkFired = Set<Int>()
    package var benchmarkBody: SIMD3<Float>?
    package let shaderQueue = DispatchQueue(label: "MetalRenderer.shaders", qos: .userInitiated)   // reloads, one at a time

    // MARK: - Input (from RendererController): state

    package var controlHeld = false
    package var optionHeld = false
}
