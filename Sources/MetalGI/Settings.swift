import CoreGraphics

extension ClosedRange {
    func clamp(_ value: Bound) -> Bound { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

/// SVGF denoiser parameters. All but the pass counts and `separateSignals` reach the shaders through `Uniforms.denoise`.
///
/// Defaults were tuned with `METALGI_BENCH=denoise` against converged reference images. Compared with the original
/// settings (5 passes, sigma 4, 32 frames, combined signal) they gain about 3 dB on static scenes and 4.7 dB on
/// moving ones, for ~0.4 ms more GPU time at 640x400 and slightly more frame-to-frame flicker.
struct DenoiserSettings: Equatable {
    var enabled = true
    var atrousPasses = 4            // 1...5 wavelet passes with step sizes 1, 2, 4, 8, 16 (fewer = sharper, noisier)
    var techniquePasses = 2         // the same with surfel / cascade GI, where only direct light is filtered: it is
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
    case surfels            // surfel radiance cache (EA SEED GIBS-style)
    case radianceCascades   // screen-space probes with world-space ray intervals, merged across cascades

    var title: String {
        switch self {
        case .pathTraced: return "Path traced"
        case .surfels: return "Surfels"
        case .radianceCascades: return "Radiance cascades"
        }
    }
}

/// Surfel GI parameters.
struct SurfelSettings: Equatable {
    var raysPerSurfel = 16          // per visible surfel per frame (off-screen surfels trace every 4th frame)
    var maxSurfels = 32768
    var radiusPixels: Float = 8     // target surfel footprint on screen
    var maxHistory: Float = 64      // frames of temporal accumulation per surfel (cut short when the light changes)
    var denoiseIndirect = false     // also run the SVGF temporal pass over the gathered result

    static let raysRange = 1...32
    static let maxSurfelsOptions = [8192, 16384, 32768, 65536]
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

    var title: String {
        switch self {
        case .cornell: return "Cornell room"
        case .stress: return "Stress test"
        }
    }
}

/// Scene choice and the stress test's size. Changing it rebuilds the scene (geometry, acceleration structures).
struct SceneSettings: Equatable {
    var kind = SceneKind.cornell
    var objects = 400
    var lights = 32

    static let objectRange = 0...2000
    static let lightRange = 1...256
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
    var manyLightRays = 1              // more than 4 lights: shadow rays per light group (2 = less noise and flicker, slower)
    var manyLightReuse = 4             // more than 4 lights, 1 ray: reuse light picks for up to this many frames (0 = off):
                                       // a third less flicker on still frames for ~0.7 ms and ~0.7 dB (manyLightsReuseKernel)
    var surfels = SurfelSettings()
    var cascades = CascadeSettings()
    var scene = SceneSettings()

    /// Applies the GI defaults that suit `scene.kind` (the settings panel calls this when the scene changes and on
    /// Reset to Defaults). Radiance cascades suit the open Cornell room. In the cluttered stress hall their
    /// screen-space probes lose ~10 dB to surfels (Tools/eval/stress.py), so it uses surfels; 8 rays per surfel lose
    /// 0.04 dB against 16 for 2 ms less, and a 64k pool keeps up with camera moves (+2.1 dB).
    mutating func applySceneDefaults(from defaults: RenderSettings) {
        switch scene.kind {
        case .cornell:
            giMode = defaults.giMode
            surfels = defaults.surfels
        case .stress:
            giMode = .surfels
            surfels = defaults.surfels
            surfels.raysPerSurfel = 8
            surfels.maxSurfels = 65536
        }
    }

    static let renderScaleRange: ClosedRange<CGFloat> = 0.25...2.0
    static let renderScaleStep: CGFloat = 0.125
    static let bounceRange = 1...8
    static let viewModes = ["Final", "Raw direct", "Raw indirect", "Normals", "Albedo", "History length",
                            "Indirect only", "GI debug"]
}
