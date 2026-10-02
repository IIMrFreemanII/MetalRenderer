import CoreGraphics
import Foundation

extension ClosedRange {
    func clamp(_ value: Bound) -> Bound { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

/// SVGF denoiser parameters. All but the pass counts and `separateSignals` reach the shaders through `Uniforms.denoise`.
///
/// Defaults were tuned with `METALRENDERER_BENCH=denoise` against converged reference images. Compared with the original
/// settings (5 passes, sigma 4, 32 frames, combined signal) they gain about 3 dB on static scenes and 4.7 dB on
/// moving ones, for ~0.4 ms more GPU time at 640x400 and slightly more frame-to-frame flicker.
struct DenoiserSettings: Equatable {
    var enabled = true
    var atrousPasses = 4            // 1...5 wavelet passes with step sizes 1, 2, 4, 8, 16 (fewer = sharper, noisier)
    var techniquePasses = 2         // the same with cascade GI, where only direct light is filtered: it is
                                    // much less noisy, and 2 passes look the same as 4 (measured) for half the cost
    var luminanceSigma: Float = 2   // luminance edge-stopping, in standard deviations (lower = sharper shadows, noisier)
    var maxHistory: Float = 16      // frames of temporal accumulation (lower = less lag, noisier)
    var antiLag: Float = 0          // 0 = off; higher shortens the history faster where the lighting changes
    var separateSignals = true      // filter direct and indirect light separately (sharper shadows, 2x the cost)
    // Shadow denoiser for direct light (up to 4 lights; see Shaders.metal 3b): filters each light's visibility
    // instead of the lit color, and clamps its history so moving shadows don't lag.
    var shadowDenoiser = true
    var shadowPasses = 3            // 3x3 a-trous passes, steps 1, 2, 4, ...
    var shadowHistory: Float = 32   // max frames averaged (the clamp keeps long histories from lagging)
    var shadowClamp: Float = 0.35   // history clamp width, in standard deviations of the neighbourhood's visibility
    var shadowSigma: Float = 3      // visibility edge-stopping, in standard errors

    static let passRange = 1...5

    /// Wavelet passes over direct light (or the combined signal) in GI mode `mode`.
    func passes(for mode: GIMode) -> Int { DenoiserSettings.passRange.clamp(mode == .pathTraced ? atrousPasses : techniquePasses) }
    static let luminanceSigmaRange: ClosedRange<Float> = 0.25...8
    static let maxHistoryRange: ClosedRange<Float> = 2...64
    static let antiLagRange: ClosedRange<Float> = 0...4
}

/// How direct light from the lights is computed.
enum DirectLightMode: Int, CaseIterable {
    case auto       // ReSTIR with many lights (Scene.lightTableThreshold, 256), otherwise grouped (exact up to 4)
    case exact      // one shadow ray per light (cost grows with the light count; references)
    case grouped    // one light per shadow-denoiser group, picked over all lights (manyLightsKernel; O(N) per pixel)
    case restir     // ReSTIR DI: candidates from the light table, temporal + spatial reuse, one shadow ray (O(1))

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .exact: return "Exact"
        case .grouped: return "Grouped"
        case .restir: return "ReSTIR"
        }
    }

    /// `METALRENDERER_DIRECT=auto|exact|grouped|restir`; `METALRENDERER_LIGHTS=all` is exact.
    static let initial: DirectLightMode = {
        let env = ProcessInfo.processInfo.environment
        if let v = env["METALRENDERER_DIRECT"], let m = allCases.first(where: { "\($0)" == v.lowercased() }) { return m }
        return env["METALRENDERER_LIGHTS"] == "all" ? .exact : .auto
    }()
}

/// ReSTIR DI (Shaders.metal "ReSTIR DI"): reservoir resampling of light samples, so a pixel's cost doesn't depend on the
/// light count. Defaults from METALRENDERER_BENCH=restirq.
struct RestirSettings: Equatable {
    var candidates = 8              // initial candidates per pixel from the light table (plus one per sun)
    var chains = 4                  // independent reservoirs per pixel, one shadow ray each (4 = the grouped path's rays)
    var temporal = true             // reuse last frame's reservoir (reprojected)
    var maxM: Float = 8             // confidence cap (samples' worth a reservoir may stand for): higher = steadier, laggier
    var spatialPasses = 1           // 0...2 passes of spatial reuse
    var spatialSamples = 4          // neighbours per pass
    var radius: Float = 24          // spatial neighbourhood radius, pixels at 960 wide (scales with the width)
    var visibilityReuse = false     // test the initial pick's visibility, so occluded samples aren't reused: less noise but
                                    // 10% darker (the target ignores visibility), so off
    var splitVisibility = false     // denoise visibility (shadow denoiser) and unshadowed light (SVGF) apart, multiply back:
                                    // one visibility channel can't keep coloured shadows (4% too bright), so off
    var denoiseSigma: Float = 3     // SVGF luminance edge-stopping for ReSTIR's direct light (in standard deviations)
    var denoisePasses = 4
    var denoiseHistory: Float = 8   // SVGF history (frames) for ReSTIR's direct light (with splitVisibility: its unshadowed light)
    var varianceBoost: Float = 2    // reused samples are correlated, so their temporal variance is low: scale it up

    static let candidateRange = 1...32
    static let chainRange = 1...4
    static let maxMRange: ClosedRange<Float> = 1...64
    static let spatialPassRange = 0...2
    static let spatialSampleRange = 1...8
    static let radiusRange: ClosedRange<Float> = 4...64
}

/// Which temporal upscaler turns the traced resolution into the output resolution (when upscaling is on).
enum UpscalerKind: Int, CaseIterable {
    case metalFX            // MetalFX temporal scaler
    case metalFXSpatial     // MetalFX spatial scaler: cheaper, but no temporal anti-aliasing (jitter off)
    case custom             // this project's TAAU pass (taauKernel), the default

    var title: String {
        switch self {
        case .metalFX: return "MetalFX temporal"
        case .metalFXSpatial: return "MetalFX spatial"
        case .custom: return "Custom (TAAU)"
        }
    }
}

/// Tuning for the custom upscaler.
struct UpscalerSettings: Equatable {
    var maxHistory: Float = 12      // max accumulated sample weight (~frames): higher = smoother, more lag
    var clipWidth: Float = 1.5      // history colour box, in standard deviations of the 3x3 input neighbourhood
    var motionCut: Float = 1        // history weight / (1 + motionCut * motion in output pixels), at 3x (scaled for others)
    var edgeMotionCut: Float = 8    // the same at depth edges, where camera motion uncovers background (parallax)
    var clipCut: Float = 16         // history weight / (1 + clipCut * how far outside the colour box it was)
    var kernelSharpness: Float = 4  // sample weight exp(-k d^2), d in output pixels, with a full history: higher = sharper
    var kernelSharpnessMoving: Float = 2     // the same where the history was cut (motion): wider = fewer gaps
    var dilationRadius: Float = 1.17   // across depth edges: closest surface among samples this close (input px); 0 = 3x3
    var lanczosHistory = true       // resample a moving history with Lanczos-3 (much less blur than Catmull-Rom)...
    var lanczosThreshold: Float = 0.03   // ...where the input neighbourhood's colour deviation exceeds this (edges, detail)
}

/// How indirect light (global illumination) is computed.
enum GIMode: Int, CaseIterable {
    case pathTraced         // per-pixel path tracing (1 spp) + SVGF denoising
    case radianceCascades   // screen-space probes with world-space ray intervals, merged across cascades

    var title: String {
        switch self {
        case .pathTraced: return "Path traced"
        case .radianceCascades: return "Radiance cascades"
        }
    }
}

/// Radiance cascades parameters.
struct CascadeSettings: Equatable {
    var probeSpacing = 8            // cascade-0 probe spacing in traced pixels (4 or 8)
    var cascades = 4
    var firstInterval: Float = 0.4  // cascade-0 ray length in meters; each cascade's interval is 4x longer
    var feedback = true             // multi-bounce: shade ray hits with last frame's indirect light where visible
    var denoiseIndirect = false     // smooth the result with the SVGF temporal pass

    static let spacingOptions = [4, 8]
    static let cascadeRange = 2...5
    static let firstIntervalRange: ClosedRange<Float> = 0.1...1.0
}

/// Which scene is loaded.
enum SceneKind: Int, CaseIterable {
    case cornell            // small Cornell-style room: 5 objects (2 moving), 3 moving lights
    case stress             // stress test: a hall with `objects` (mostly moving) objects and `lights` moving lights
    case gallery            // the glTF models in Assets/ on plinths, 8 moving lights
    case spots              // a stage under six sweeping spot lights
    case sun                // a courtyard and a covered room under the sun, with a day cycle
    case area               // a studio with softboxes and light panels (rect area lights) over glossy objects
    case tubes              // a garage with fluorescent and neon tube lights
    case emissive           // a dark room lit only by emissive meshes (neon shapes, a screen, a spinning ring)
    case mixed              // a room at dusk with every light type
    case fog                // a misty hall: sun shafts through tall windows, a searchlight, ground mist
    case valley             // an open valley under the sky: a day cycle, drifting clouds and their shadows
    case market             // a night market: thousands of festoon bulbs (`lights`), lanterns, lit windows, neon signs

    var title: String {
        switch self {
        case .cornell: return "Cornell room"
        case .stress: return "Stress test"
        case .gallery: return "Gallery (Assets)"
        case .spots: return "Spot lights"
        case .sun: return "Sun and sky"
        case .area: return "Area lights"
        case .tubes: return "Tube lights"
        case .emissive: return "Emissive meshes"
        case .mixed: return "Mixed lights"
        case .fog: return "Misty hall"
        case .valley: return "Open valley"
        case .market: return "Night market"
        }
    }

    /// Scenes built with `SceneSettings.lights` lights (the panel's Lights slider).
    var hasLightCount: Bool { self == .stress || self == .market }
}

/// What answers ray queries. Changing it recompiles the shaders (CUSTOM_RT macro) and rebuilds the scene's structures.
enum RayTracerKind: Int, CaseIterable {
    case custom             // this project's BVHs: per-mesh BLAS + static TLAS (CPU, once) + dynamic TLAS (every frame)
    case metal              // Metal's acceleration structures and intersector

    var title: String {
        switch self {
        case .custom: return "Custom BVH"
        case .metal: return "Metal"
        }
    }

    /// `METALRENDERER_RT=metal|custom` picks the starting tracer (benchmarks: for every setting).
    static let initial: RayTracerKind = ProcessInfo.processInfo.environment["METALRENDERER_RT"] == "metal" ? .metal : .custom
}

/// A glTF model the user opened or dropped into the scene.
struct ExtraModel: Equatable {
    var path: String
    var position: SIMD3<Float>
    var yaw: Float
}

/// Scene choice and the stress test's size. Changing it rebuilds the scene (geometry, acceleration structures).
struct SceneSettings: Equatable {
    var kind = SceneKind.cornell
    var objects = 400
    var lights = 32
    var extraModels: [ExtraModel] = []   // added with File > Open or drag and drop (cleared when the scene changes)
    /// Emissive surfaces are lights: sampled for direct light with shadow rays (and seen by GI through light maps).
    /// Off: they only light what GI rays happen to hit, as before.
    var emissiveLights = ProcessInfo.processInfo.environment["METALRENDERER_EMISSIVE_LIGHTS"] != "0"
    /// Benchmarks only (METALRENDERER_BENCH=lightcheck): one light, or its emissive-mesh twin, over a floor instead of `kind`.
    var lightCheck: String? = nil

    static let objectRange = 0...2000
    static let lightRange = 1...16384
    static let marketLights = 4096       // the night market's default bulb count
}

/// Virtual geometry (custom ray tracer): big glTF meshes as streamed cluster DAGs with a per-frame level-of-detail cut.
struct VirtualGeometrySettings: Equatable {
    var enabled = ProcessInfo.processInfo.environment["METALRENDERER_VG"] != "0"
    var pixelError: Float = Float(ProcessInfo.processInfo.environment["METALRENDERER_VG_TAU"] ?? "") ?? 1   // traced pixels
    var poolMB = Int(ProcessInfo.processInfo.environment["METALRENDERER_VG_POOL"] ?? "") ?? 768
    /// Keep choosing detail for the camera position at the moment this was turned on (debugging: fly up to a model
    /// to see the cut it got from far away).
    var freeze = false

    static let pixelErrorRange: ClosedRange<Float> = 0.25...8
    static let poolOptions = [256, 512, 768, 1024, 2048]
}

/// Volumetric fog (Shaders.metal "Volumetric fog"): exponential height fog with drifting noise, plus the scene's
/// local fog volumes. Each scene kind has a preset (`preset(for:)`); the volumes themselves come with the scene.
struct FogSettings: Equatable {
    var enabled = false
    var density: Float = 0.02           // height fog's extinction at and below its base height (1/m); 0 = volumes only
    var heightFalloff: Float = 0.1      // per metre above the base height (0 = the same density everywhere)
    var baseHeight: Float = 0
    var anisotropy: Float = 0.5         // Henyey-Greenstein g: > 0 scatters forward (brightest looking toward a light)
    var ambient: Float = 1              // the sky colour x this lights the fog evenly (stands in for indirect light)
    var albedo = SIMD3<Float>(repeating: 0.9)
    var noise: Float = 0.4              // how much the drifting noise modulates the height fog (volumes have their own)
    var noiseScale: Float = 6           // noise tile size (m)
    var wind = SIMD3<Float>(0.35, 0.05, 0.15)   // m/s
    var maxDistance: Float = 40         // the froxel grid's far end (view depth); beyond, no more fog accumulates
    var volumes = true                  // the scene's local fog volumes
    var reflections = true              // fog along reflection rays (one more shadow ray per reflection)

    static let densityRange: ClosedRange<Float> = 0.002...0.3   // log slider
    static let falloffRange: ClosedRange<Float> = 0...1
    static let anisotropyRange: ClosedRange<Float> = -0.3...0.9
    static let ambientRange: ClosedRange<Float> = 0...4
    static let noiseRange: ClosedRange<Float> = 0...1
    static let distanceRange: ClosedRange<Float> = 10...150
    static let slices = 64              // froxel depth slices (the grid is 8x8 traced pixels per froxel)
    /// `METALRENDERER_FOG=0/1` turns fog off or on in every preset.
    static let override: Bool? = ProcessInfo.processInfo.environment["METALRENDERER_FOG"].map { $0 != "0" }

    /// The fog that suits scene `kind`: off in the Cornell room, stress test, gallery and studio.
    static func preset(for kind: SceneKind) -> FogSettings {
        var f = FogSettings()
        switch kind {
        case .cornell, .stress, .gallery, .area:
            break
        case .market:
            f.enabled = true; f.density = 0.012; f.heightFalloff = 0.08; f.anisotropy = 0.4; f.ambient = 0.5; f.maxDistance = 60
        case .valley:
            f.enabled = true; f.density = 0.0015; f.heightFalloff = 0.02; f.anisotropy = 0.5; f.noise = 0.2
            f.maxDistance = 150
        case .spots:
            f.enabled = true; f.density = 0.03; f.heightFalloff = 0.05; f.anisotropy = 0.55; f.maxDistance = 30
        case .sun:
            f.enabled = true; f.density = 0.012; f.heightFalloff = 0.1; f.anisotropy = 0.3; f.noise = 0.3
            f.maxDistance = 100
        case .tubes:
            f.enabled = true; f.density = 0.05; f.heightFalloff = 0; f.anisotropy = 0.3; f.maxDistance = 30
        case .emissive:
            f.enabled = true; f.density = 0.02; f.heightFalloff = 0; f.anisotropy = 0.3; f.maxDistance = 30
        case .mixed:
            f.enabled = true; f.density = 0.03; f.heightFalloff = 0; f.anisotropy = 0.2; f.maxDistance = 30
        case .fog:
            f.enabled = true; f.density = 0.045; f.heightFalloff = 0.04; f.anisotropy = 0.7; f.ambient = 0.25; f.noise = 0.6
            f.maxDistance = 60
        }
        if let override { f.enabled = override }
        return f
    }
}

/// Where the sky comes from (Shaders.metal "Sky and clouds").
enum SkyMode: Int, CaseIterable {
    case constant           // one colour (the scene's), as indoor scenes use
    case atmosphere         // physically based atmosphere; the sun light's colour follows it
    case image              // an HDR environment image (.hdr, .exr); its sun drives the sun light

    var title: String {
        switch self {
        case .constant: return "Constant colour"
        case .atmosphere: return "Atmosphere"
        case .image: return "HDR image"
        }
    }
}

/// The sky and its clouds. Each scene kind has a preset (`preset(for:)`).
struct SkySettings: Equatable {
    var mode = SkyMode.constant
    var imagePath: String? = nil        // .image: the environment file
    var imageExposure: Float = 0        // .image: stops on top of the automatic scale
    var clouds = true
    var cloudsOverImage = false         // .image: the volumetric clouds in front of the image too
    var coverage: Float = 0.35          // 0 = clear, ~0.3 scattered cumulus, 1 = overcast
    var density: Float = 0.03           // extinction inside a cloud (1/m)
    var cloudBase: Float = 1500         // altitude of the layer's bottom (m)
    var cloudThickness: Float = 1500
    var cloudScale: Float = 4000        // shape noise tile (m): smaller = smaller clouds
    var erosion: Float = 0.35           // detail noise eating the edges
    var windSpeed: Float = 12           // m/s, blowing toward windDirection (degrees from +x toward +z)
    var windDirection: Float = 30
    var shadows = true                  // the clouds shadow the scene
    var shadowStrength: Float = 1

    static let coverageRange: ClosedRange<Float> = 0...1
    static let densityRange: ClosedRange<Float> = 0.005...0.1
    static let cloudBaseRange: ClosedRange<Float> = 300...4000
    static let windRange: ClosedRange<Float> = 0...40
    static let mapSize = 1024           // sky texture side, per hemisphere
    static let shadowMapSize = 256
    /// `METALRENDERER_SKY=constant|atmosphere|<image path>` overrides every preset's mode.
    static let override: String? = ProcessInfo.processInfo.environment["METALRENDERER_SKY"]

    /// The sky that suits scene `kind`: the atmosphere for the outdoor and window-lit scenes, a constant colour inside.
    static func preset(for kind: SceneKind) -> SkySettings {
        var s = SkySettings()
        switch kind {
        case .cornell, .stress, .gallery, .spots, .area, .tubes, .emissive, .fog, .market:
            break
        case .sun:
            s.mode = .atmosphere; s.coverage = 0.35; s.cloudBase = 1200; s.cloudThickness = 1200; s.cloudScale = 2500
        case .mixed:
            s.mode = .atmosphere; s.coverage = 0.25; s.shadows = false   // the sun is low: clouds near the horizon
        case .valley:
            // Small, low clouds (a stylised scale), so their shadows visibly cross the 400 m valley.
            s.mode = .atmosphere; s.coverage = 0.4; s.cloudBase = 700; s.cloudThickness = 800; s.cloudScale = 800
            s.density = 0.04; s.windSpeed = 14; s.shadowStrength = 0.7
        }
        if let o = override {
            switch o {
            case "constant": s.mode = .constant
            case "atmosphere": s.mode = .atmosphere
            default: s.mode = .image; s.imagePath = o
            }
        }
        return s
    }
}

/// Everything the settings panel and the keyboard shortcuts can change.
struct RenderSettings: Equatable {
    var renderScale: CGFloat = 0.5     // traced resolution, as a fraction of the window's size in points
    var upscaleFactor: CGFloat = 3     // MetalFX output / traced resolution; 0 = off
    var upscaler = UpscalerKind.custom  // sharper and steadier than MetalFX here, as good in motion at 3x, ~0.6 ms cheaper
    var taau = UpscalerSettings()
    var giEnabled = true
    var bounces = 2
    var blueNoise = true               // stratified samples steady the shadow denoiser's history clamp (less flicker)
    var paused = false
    var viewMode = 0
    var denoiser = DenoiserSettings()
    var giMode = GIMode.radianceCascades   // ~45% cheaper than path tracing here, ~11 dB closer to an 8-bounce reference, no flicker
    var lightMaps = false              // path tracer: light bounce hits from per-light shadow maps instead of shadow rays
    var directLight = DirectLightMode.initial
    var restir = RestirSettings()
    var manyLightRays = 1              // more than 4 lights: shadow rays per light group (2 = less noise and flicker, slower)
    var manyLightReuse = 4             // more than 4 lights, 1 ray: reuse light picks for up to this many frames (0 = off):
                                       // a third less flicker on still frames for ~0.7 ms and ~0.7 dB (manyLightsReuseKernel)
    var cascades = CascadeSettings()
    var scene = SceneSettings()
    var rayTracer = RayTracerKind.initial
    var virtualGeometry = VirtualGeometrySettings()
    var specular = ProcessInfo.processInfo.environment["METALRENDERER_SPECULAR"] != "0"   // GGX specular for glTF materials
    var textureBudgetMB = Int(ProcessInfo.processInfo.environment["METALRENDERER_TEXTURE_BUDGET"] ?? "") ?? 1024   // streamed textures
    var fog = FogSettings.preset(for: .cornell)
    var sky = SkySettings.preset(for: .cornell)

    /// Applies the defaults that suit `scene.kind` (the settings panel calls this when the scene changes and on
    /// Reset to Defaults): the GI method, the night market's light count, the fog and the sky.
    mutating func applySceneDefaults(from defaults: RenderSettings) {
        giMode = defaults.giMode
        if scene.kind == .market && scene.lights == SceneSettings().lights { scene.lights = SceneSettings.marketLights }
        fog = FogSettings.preset(for: scene.kind)
        let image = sky.mode == .image ? sky : nil   // an image the user opened stays
        sky = SkySettings.preset(for: scene.kind)
        if let image { sky.mode = .image; sky.imagePath = image.imagePath; sky.imageExposure = image.imageExposure }
    }

    static let renderScaleRange: ClosedRange<CGFloat> = 0.25...2.0
    static let renderScaleStep: CGFloat = 0.125
    static let bounceRange = 1...8
    static let viewModes = ["Final", "Raw direct", "Raw indirect", "Normals", "Albedo", "History length",
                            "Indirect only", "GI debug",
                            "Triangles", "Clusters", "Groups", "LOD level", "Triangle size", "Traversal cost",
                            "Fog scattering"]
    /// The geometry debug views (geometryDebugKernel): triangles, virtual-geometry clusters / groups / DAG levels,
    /// projected triangle size, and the primary rays' traversal cost.
    static let geometryViews = 8...13
}
