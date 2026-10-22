import CoreGraphics
import EngineCore
import Foundation
import Plants
import simd

extension ClosedRange {
    package func clamp(_ value: Bound) -> Bound { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

/// SVGF denoiser parameters. All but the pass counts and `separateSignals` reach the shaders through `Uniforms.denoise`.
///
/// Defaults were tuned with `METALRENDERER_BENCH=denoise` against converged reference images. Compared with the original
/// settings (5 passes, sigma 4, 32 frames, combined signal) they gain about 3 dB on static scenes and 4.7 dB on
/// moving ones, for ~0.4 ms more GPU time at 640x400 and slightly more frame-to-frame flicker.
package struct DenoiserSettings: Equatable, Codable {
    package var enabled = true
    var atrousPasses = 4            // 1...5 wavelet passes with step sizes 1, 2, 4, 8, 16 (fewer = sharper, noisier)
    var techniquePasses = 2         // the same with cascade GI, where only direct light is filtered: it is
                                    // much less noisy, and 2 passes look the same as 4 (measured) for half the cost
    var luminanceSigma: Float = 2   // luminance edge-stopping, in standard deviations (lower = sharper shadows, noisier)
    var maxHistory: Float = 16      // frames of temporal accumulation (lower = less lag, noisier)
    var antiLag: Float = 0          // 0 = off; higher shortens the history faster where the lighting changes
    package var separateSignals = true      // filter direct and indirect light separately (sharper shadows, 2x the cost)
    // Shadow denoiser for direct light (up to 4 lights; see Shaders/Denoise.metal, 3b): filters each light's visibility
    // instead of the lit color, and clamps its history so moving shadows don't lag.
    package var shadowDenoiser = true
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
    static let shadowClampRange: ClosedRange<Float> = 0.05...2
    static let shadowSigmaRange: ClosedRange<Float> = 0.5...8
    static let varianceBoostRange: ClosedRange<Float> = 1...8   // ReSTIR's denoiser inputs (RestirSettings, RestirGISettings)
}

/// How direct light from the lights is computed.
package enum DirectLightMode: Int, CaseIterable, Codable {
    case auto       // ReSTIR with many lights (Scene.lightTableThreshold, 256), otherwise grouped (exact up to 4)
    case exact      // one shadow ray per light (cost grows with the light count; references)
    case grouped    // one light per shadow-denoiser group, picked over all lights (manyLightsKernel; O(N) per pixel)
    case restir     // ReSTIR DI: candidates from the light table, temporal + spatial reuse, one shadow ray (O(1))

    package var title: String {
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

/// ReSTIR DI (Shaders/RestirDI.metal): reservoir resampling of light samples, so a pixel's cost doesn't depend on the
/// light count. Defaults from METALRENDERER_BENCH=restirq.
package struct RestirSettings: Equatable, Codable {
    var candidates = 8              // initial candidates per pixel from the light table (plus one per sun)
    var chains = 4                  // independent reservoirs per pixel, one shadow ray each (4 = the grouped path's rays)
    var temporal = true             // reuse last frame's reservoir (reprojected)
    var maxM: Float = 8             // confidence cap (samples' worth a reservoir may stand for): higher = steadier, laggier
    var spatialPasses = 1           // 0...2 passes of spatial reuse
    var spatialSamples = 4          // neighbours per pass
    var radius: Float = 24          // spatial neighbourhood radius, pixels at 960 wide (scales with the width)
    var visibilityReuse = false     // test the initial pick's visibility, so occluded samples aren't reused: less noise but
                                    // 10% darker (the target ignores visibility), so off
    package var splitVisibility = false     // denoise visibility (shadow denoiser) and unshadowed light (SVGF) apart, multiply back:
                                    // one visibility channel can't keep coloured shadows (4% too bright), so off
    var denoiseSigma: Float = 3     // SVGF luminance edge-stopping for ReSTIR's direct light (in standard deviations)
    var denoisePasses = 4
    var denoiseHistory: Float = 8   // SVGF history (frames) for ReSTIR's direct light (with splitVisibility: its unshadowed light)
    var varianceBoost: Float = 2    // reused samples are correlated, so their temporal variance is low: scale it up
    package var grid = RegirSettings()      // the light grid the candidates come from (ReGIR)

    static let candidateRange = 1...32
    static let chainRange = 1...4
    static let maxMRange: ClosedRange<Float> = 1...64
    static let spatialPassRange = 0...2
    static let spatialSampleRange = 1...8
    static let radiusRange: ClosedRange<Float> = 4...64
}

/// The light grid (Shaders/Regir.metal): a camera-centred world-space grid of light reservoirs, rebuilt every
/// frame on the GPU, that ReSTIR DI draws most of its candidates from, so they are the lights near the pixel rather
/// than the whole table by power. `levels` cascaded levels of `cells`^3 cells, the first `cellSize` m wide and each
/// next `levelScale` times wider; `slots` reservoirs per cell, each the pick of `candidates` table draws; `share` of
/// RestirSettings.candidates come from the grid, the rest from the table.
package struct RegirSettings: Equatable, Codable {
    package var enabled = true
    var cells = 16
    var levels = 2
    var cellSize: Float = 1
    var levelScale: Float = 3
    var slots = 32
    var candidates = 8
    package var share = 6

    static let cellRange = 8...32
    static let levelRange = 1...4
    static let cellSizeRange: ClosedRange<Float> = 0.25...8
    static let scaleRange: ClosedRange<Float> = 2...4
    static let slotRange = 8...64
    static let candidateRange = 2...16
    static let shareRange = 0...32

    /// Reservoirs in the grid (its buffer holds 16 bytes each), with the settings clamped to their ranges.
    var reservoirCount: Int {
        RegirSettings.levelRange.clamp(levels) * Int(pow(Double(RegirSettings.cellRange.clamp(cells)), 3)) * RegirSettings.slotRange.clamp(slots)
    }
}

/// The curve that maps the composited HDR colour to the display (compositeKernel). ACES was the only one before.
package enum ToneMap: Int, CaseIterable, Codable {
    case aces       // Narkowicz's ACES fit: contrasty, saturated highlights shift toward white
    case agx        // AgX (Troy Sobotka), polynomial fit: softer, keeps bright saturated lights from going flat
    case reinhard   // luminance Reinhard: gentle, keeps hue
    case none       // clamp: linear up to 1

    var title: String {
        switch self {
        case .aces: return "ACES"
        case .agx: return "AgX"
        case .reinhard: return "Reinhard"
        case .none: return "None (clamp)"
        }
    }
}

/// How real the outdoor scenes look (SceneSettings.realism): off, the generated textures as they always were; on,
/// photo-scanned ground, rocks and plants (TextureSet) height-blended into each other, with the lighting's realistic
/// looks; high, also the costly parts (stochastic tiling, the ground displaced near the camera, denser grass).
package enum Realism: Int, CaseIterable, Codable {
    case off, on, high

    var title: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .high: return "High"
        }
    }
}

/// How indirect light (global illumination) is computed.
package enum GIMode: Int, CaseIterable, Codable {
    case pathTraced         // per-pixel path tracing (1 spp) + SVGF denoising
    case radianceCascades   // screen-space probes with world-space ray intervals, merged across cascades
    case restirGI           // ReSTIR GI: per-pixel paths whose first bounce is reused over time and space, + SVGF

    var title: String {
        switch self {
        case .pathTraced: return "Path traced"
        case .radianceCascades: return "Radiance cascades"
        case .restirGI: return "ReSTIR GI"
        }
    }
}

/// A converged reference picture for debugging (README "Reference rendering"): samples averaged over frames, the
/// average restarted whenever the picture would change (the camera, a setting, the scene animating).
package enum ReferenceMode: Int, CaseIterable, Codable {
    case off
    case accumulated    // the frame's own passes (path traced GI, exact direct light, raw specular) averaged: the benchmarks' references
    case pathTraced     // one kernel traces whole paths (PathTrace.metal): glossy bounces, glass, lights met by rays

    var title: String {
        switch self {
        case .off: return "Off"
        case .accumulated: return "Accumulated passes"
        case .pathTraced: return "Path traced"
        }
    }
}

/// The reference modes' parameters.
package struct ReferenceSettings: Equatable, Codable {
    package var mode = ReferenceMode.off
    var bounces = 8             // path length (both modes)
    var samplesPerFrame = 1     // path traced: paths per pixel per frame
    var maxSamples = 0          // stop adding samples at this many per pixel; 0 = never

    static let bounceRange = 1...16
    static let samplesPerFrameRange = 1...16
    static let maxSampleOptions = [0, 64, 256, 1024, 4096, 16384]
}

/// ReSTIR GI (Shaders/RestirGI.metal): one path per pixel (or per 2x2 block) whose first bounce is resampled over
/// time (and optionally across neighbours). Defaults from METALRENDERER_BENCH=gi and stressq (README "ReSTIR GI").
package struct RestirGISettings: Equatable, Codable {
    package var quarterBudget = false       // one fresh path per 2x2 block per frame (a rotating pixel): 4x cheaper paths, but
                                    // pixels that lost their history wait up to 4 frames (-5 to -15 dB in motion), so off
    var bounces = 2                 // path length (the first bounce is the reused sample)
    var lightMaps = false           // light the paths' hits from the light maps instead of shadow rays
    package var feedback = true             // multi-bounce: the paths' last hits add last frame's indirect light where on screen
                                    // (+16 dB in Cornell with the fallback: 2 bounces miss a quarter of the light)
    var denoisedFeedback = true     // ...the denoised indirect light (else the raw one)
    var feedbackFallback = true     // ...and off screen, last frame's mean indirect light
    package var temporal = true             // reuse last frame's reservoir (reprojected): half the flicker
    var maxM: Float = 2             // confidence cap: higher = steadier, laggier (16: -0.5 dB still, -2 to -4.5 dB moving)
    var maxAge = 30                 // the pixel's fresh paths a sample may outlive (its light is from when it was traced)
    package var spatialPasses = 0           // 0...2 passes of spatial reuse: unbiased, but after the denoiser no better (and 2-13
                                    // ms at 640x400), so off
    var spatialSamples = 2          // neighbours per pass (1 scored as 5)
    var unbiased = true             // spatial reuse: visibility in the targets, two rays per neighbour (without: cheaper,
                                    // but 8-17% darker in the old stress hall, where neighbours saw different light)
    var radius: Float = 30          // spatial neighbourhood radius, pixels at 960 wide (scales with the width)
    var minDistance: Float = 0.02   // floor of the sample distance in the target (m): no spikes from very close samples
    package var denoise = true              // SVGF on the result
    var denoiseSigma: Float = 3     // SVGF luminance edge-stopping (in standard deviations)
    var denoisePasses = 2
    var denoiseHistory: Float = 8   // SVGF history (frames)
    var varianceBoost: Float = 2    // reused samples are correlated, so their temporal variance is low: scale it up
    var antiLag: Float = 0          // SVGF anti-lag for the result (DenoiserSettings.antiLag)

    static let maxMRange: ClosedRange<Float> = 1...64
    static let maxAgeRange = 1...255
    static let spatialPassRange = 0...2
    static let spatialSampleRange = 1...8
    static let radiusRange: ClosedRange<Float> = 4...64
    static let minDistanceRange: ClosedRange<Float> = 0.001...0.2
}

/// Radiance cascades parameters.
package struct CascadeSettings: Equatable, Codable {
    package var probeSpacing = 8            // cascade-0 probe spacing in traced pixels (4 or 8)
    var cascades = 4
    package var firstInterval: Float = 0.4  // cascade-0 ray length in meters; each cascade's interval is 4x longer
    var feedback = true             // multi-bounce: shade ray hits with last frame's indirect light where visible
    package var denoiseIndirect = false     // smooth the result with the SVGF temporal pass

    static let spacingOptions = [4, 8]
    static let cascadeRange = 2...5
    static let firstIntervalRange: ClosedRange<Float> = 0.1...1.0
}

/// Solid shading's look (RenderSettings.solidLook): what tells things apart in it. `classic` is the old one, every
/// surface the same grey under a light on the camera.
package struct SolidLook: Equatable, Codable {
    var classic = false
    /// Each surface its material's colour (its texture's too), each object a little lighter or darker than the next,
    /// a fractured object's broken faces darker and warmer (Scene.markCutFace).
    var materials = true
    var tint: Float = 0.08
    var cutFaces = true
    /// Lines where one object meets another, or a surface turns or steps (the width in pixels).
    var edges = true
    var edgeWidth = 1
    /// The sun's shadows (the scene's sun, else one from the upper left), and the dark in corners and gaps (rays out
    /// to `aoRadius` metres, filtered over 4 x 4 pixels).
    var shadows = true
    var ao = true
    var aoRays = 1
    var aoRadius: Float = 0.8

    static let tintRange: ClosedRange<Float> = 0...0.3
    static let edgeRange = 1...3
    static let aoRayRange = 1...16
    static let aoRadiusRange: ClosedRange<Float> = 0.1...4
}

/// Virtual geometry: big glTF meshes as streamed cluster DAGs with a per-frame level-of-detail cut.
package struct VirtualGeometrySettings: Equatable, Codable {
    package var enabled = ProcessInfo.processInfo.environment["METALRENDERER_VG"] != "0"
    package var pixelError: Float = Float(ProcessInfo.processInfo.environment["METALRENDERER_VG_TAU"] ?? "") ?? 1   // traced pixels
    var poolMB = Int(ProcessInfo.processInfo.environment["METALRENDERER_VG_POOL"] ?? "") ?? 768
    /// Keep choosing detail for the camera position at the moment this was turned on (debugging: fly up to a model
    /// to see the cut it got from far away).
    package var freeze = false

    static let pixelErrorRange: ClosedRange<Float> = 0.25...8
    static let poolOptions = [256, 512, 768, 1024, 2048]
}

/// Volumetric fog (Shaders/Fog.metal): exponential height fog with drifting noise, plus the scene's
/// local fog volumes. Each scene kind has a preset (`preset(for:)`); the volumes themselves come with the scene.
package struct FogSettings: Equatable, Codable {
    package var enabled = false
    package var density: Float = 0.02           // height fog's extinction at and below its base height (1/m); 0 = volumes only
    package var heightFalloff: Float = 0.1      // per metre above the base height (0 = the same density everywhere)
    package var baseHeight: Float = 0
    package var anisotropy: Float = 0.5         // Henyey-Greenstein g: > 0 scatters forward (brightest looking toward a light)
    package var ambient: Float = 1              // the sky colour x this lights the fog evenly (stands in for indirect light)
    package var albedo = SIMD3<Float>(repeating: 0.9)
    package var noise: Float = 0.4              // how much the drifting noise modulates the height fog (volumes have their own)
    package var noiseScale: Float = 6           // noise tile size (m)
    package var wind = SIMD3<Float>(0.35, 0.05, 0.15)   // m/s
    package var maxDistance: Float = 40         // the froxel grid's far end (view depth); beyond, no more fog accumulates...
    package var haze: Float = 0                 // ...but the height fog at this share of its density, as far as the eye sees (0 = none)
    package var volumes = true                  // the scene's local fog volumes
    package var reflections = true              // fog along reflection rays (one more shadow ray per reflection)
    package var lights = true                   // the scene's lights scatter in it; off: only the sun (or the moon) and the sky

    static let densityRange: ClosedRange<Float> = 0.002...0.3   // log slider
    static let falloffRange: ClosedRange<Float> = 0...1
    static let anisotropyRange: ClosedRange<Float> = -0.3...0.9
    static let ambientRange: ClosedRange<Float> = 0...4
    static let noiseRange: ClosedRange<Float> = 0...1
    static let distanceRange: ClosedRange<Float> = 10...150
    static let hazeRange: ClosedRange<Float> = 0...1
    static let baseHeightRange: ClosedRange<Float> = -10...20
    static let noiseScaleRange: ClosedRange<Float> = 1...30
    static let windSpeedRange: ClosedRange<Float> = 0...3

    /// The wind's horizontal speed and heading (degrees from +x toward +z), for the panel; its vertical part stays.
    var windSpeed: Float {
        get { simd_length(SIMD2(wind.x, wind.z)) }
        set { let a = windDirection * .pi / 180; wind.x = newValue * cos(a); wind.z = newValue * sin(a) }
    }
    var windDirection: Float {
        get { atan2(wind.z, wind.x) * 180 / .pi }
        set { let v = windSpeed, a = newValue * .pi / 180; wind.x = v * cos(a); wind.z = v * sin(a) }
    }
    static let slices = 64              // froxel depth slices (the grid is 8x8 traced pixels per froxel)
    /// `METALRENDERER_FOG=0/1` turns fog off or on in every preset.
    static let override: Bool? = ProcessInfo.processInfo.environment["METALRENDERER_FOG"].map { $0 != "0" }

    /// The fog that suits scene `kind` (its definition's): off unless the scene sets it.
    package static func preset(for kind: SceneKind) -> FogSettings {
        var f = kind.definition.fog
        if let override { f.enabled = override }
        return f
    }

    /// The fog that suits `scene`: its kind's, and in the showcase the model's look on top.
    package static func preset(for scene: SceneSettings) -> FogSettings {
        var f = preset(for: scene.kind)
        scene.kind.definition.tuneFog?(scene, &f)
        if scene.realism != .off && scene.kind.hasRealisticLook {
            // Air: the distance fades blue-grey (aerial perspective), a light haze in the forest's shade.
            if !f.enabled {
                f.enabled = true
                f.density = 0.0025
                f.heightFalloff = 0.025
                f.anisotropy = 0.6
                f.noise = 0.15
                f.maxDistance = 90
            }
            f.haze = max(f.haze, scene.kind.definition.realisticHaze)
        }
        return f
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(enabled: Bool = false, density: Float = 0.02, heightFalloff: Float = 0.1, baseHeight: Float = 0, anisotropy: Float = 0.5, ambient: Float = 1, albedo: SIMD3<Float> = SIMD3<Float>(repeating: 0.9), noise: Float = 0.4, noiseScale: Float = 6, wind: SIMD3<Float> = SIMD3<Float>(0.35, 0.05, 0.15), maxDistance: Float = 40, haze: Float = 0, volumes: Bool = true, reflections: Bool = true, lights: Bool = true) {
        self.enabled = enabled
        self.density = density
        self.heightFalloff = heightFalloff
        self.baseHeight = baseHeight
        self.anisotropy = anisotropy
        self.ambient = ambient
        self.albedo = albedo
        self.noise = noise
        self.noiseScale = noiseScale
        self.wind = wind
        self.maxDistance = maxDistance
        self.haze = haze
        self.volumes = volumes
        self.reflections = reflections
        self.lights = lights
    }
}

/// Where the sky comes from (Shaders/Sky.metal).
package enum SkyMode: Int, CaseIterable, Codable {
    case constant           // one colour (the scene's), as indoor scenes use
    case atmosphere         // physically based atmosphere; the sun light's colour follows it
    case image              // an HDR environment image (.hdr, .exr); its sun drives the sun light

    package var title: String {
        switch self {
        case .constant: return "Constant colour"
        case .atmosphere: return "Atmosphere"
        case .image: return "HDR image"
        }
    }
}

/// The sky and its clouds. Each scene kind has a preset (`preset(for:)`).
package struct SkySettings: Equatable, Codable {
    package var mode = SkyMode.constant
    package var imagePath: String? = nil        // .image: the environment file
    package var imageExposure: Float = 0        // .image: stops on top of the automatic scale
    package var clouds = true
    package var cloudsOverImage = false         // .image: the volumetric clouds in front of the image too
    package var coverage: Float = 0.35          // 0 = clear, ~0.3 scattered cumulus, 1 = overcast
    package var density: Float = 0.03           // extinction inside a cloud (1/m)
    package var cloudBase: Float = 1500         // altitude of the layer's bottom (m)
    package var cloudThickness: Float = 1500
    package var cloudScale: Float = 4000        // shape noise tile (m): smaller = smaller clouds
    package var erosion: Float = 0.35           // detail noise eating the edges
    package var windSpeed: Float = 12           // m/s, blowing toward windDirection (degrees from +x toward +z)
    package var windDirection: Float = 30
    package var shadows = true                  // the clouds shadow the scene
    package var shadowStrength: Float = 1

    package static let coverageRange: ClosedRange<Float> = 0...1
    package static let densityRange: ClosedRange<Float> = 0.005...0.1
    package static let cloudBaseRange: ClosedRange<Float> = 300...4000
    package static let windRange: ClosedRange<Float> = 0...40
    package static let cloudThicknessRange: ClosedRange<Float> = 200...4000
    package static let cloudScaleRange: ClosedRange<Float> = 500...16000
    package static let mapSize = 1024           // sky texture side, per hemisphere
    package static let shadowMapSize = 256
    /// `METALRENDERER_SKY=constant|atmosphere|<image path>` overrides every preset's mode.
    package static let override: String? = ProcessInfo.processInfo.environment["METALRENDERER_SKY"]

    /// The sky that suits scene `kind`: the atmosphere for the outdoor and window-lit scenes, a constant colour inside.
    /// ...and for the scene's own settings: the building workshop at night has the city's night sky.
    package static func preset(for scene: SceneSettings) -> SkySettings {
        var s = preset(for: scene.kind)
        if scene.kind == .buildings && scene.buildings.night { s = overridden(SkySettings()) }   // the night city's
        return s
    }

    package static func preset(for kind: SceneKind) -> SkySettings { overridden(kind.definition.sky) }

    /// `s` with METALRENDERER_SKY's mode.
    private static func overridden(_ sky: SkySettings) -> SkySettings {
        var s = sky
        if let o = override {
            switch o {
            case "constant": s.mode = .constant
            case "atmosphere": s.mode = .atmosphere
            default: s.mode = .image; s.imagePath = o
            }
        }
        return s
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(mode: SkyMode = SkyMode.constant, imagePath: String? = nil, imageExposure: Float = 0, clouds: Bool = true, cloudsOverImage: Bool = false, coverage: Float = 0.35, density: Float = 0.03, cloudBase: Float = 1500, cloudThickness: Float = 1500, cloudScale: Float = 4000, erosion: Float = 0.35, windSpeed: Float = 12, windDirection: Float = 30, shadows: Bool = true, shadowStrength: Float = 1) {
        self.mode = mode
        self.imagePath = imagePath
        self.imageExposure = imageExposure
        self.clouds = clouds
        self.cloudsOverImage = cloudsOverImage
        self.coverage = coverage
        self.density = density
        self.cloudBase = cloudBase
        self.cloudThickness = cloudThickness
        self.cloudScale = cloudScale
        self.erosion = erosion
        self.windSpeed = windSpeed
        self.windDirection = windDirection
        self.shadows = shadows
        self.shadowStrength = shadowStrength
    }
}

/// The camera's lens and the image's finish (Shaders/Post.metal), on the light at the output resolution before and
/// after the tone curve: depth of field, bloom, chromatic aberration, vignette and film grain. Each is off at 0, and
/// all are off but in the showcase (`preset(for:)`), so the other scenes' frames are what they were.
package struct PostSettings: Equatable, Codable {
    package var bloom: Float = 0                // the share of the light spread out as glow (0 = no bloom)
    var bloomThreshold: Float = 1       // the brightness (after exposure) where glow starts, with a soft knee below it
    package var aperture: Float = 0             // the blur circle's radius in output pixels far behind the focus (as much at half
                                        // the focus distance, more nearer, at most `maxBlur`); 0 = no depth of field
    var focus: Float = 0                // focus distance (m); 0 = autofocus on what is at the centre of the frame
    package var vignette: Float = 0             // how much the corners darken
    package var grain: Float = 0                // film grain's strength
    package var aberration: Float = 0           // chromatic aberration: red and blue apart by this share of the width at the corners
    /// The exposure follows the frame's light (a histogram's middle, eased toward): `exposure` then shifts it.
    package var autoExposure = false
    /// The colour grade (applied when any is off its neutral value): warmth (-1 cooler ... 1 warmer: white balance),
    /// saturation (1 as it is) and contrast about middle grey (1 as it is).
    var warmth: Float = 0
    var saturation: Float = 1
    var contrast: Float = 1
    var grades: Bool { warmth != 0 || saturation != 1 || contrast != 1 }

    var isOn: Bool { bloom > 0 || aperture > 0 || vignette > 0 || grain > 0 || aberration > 0 }

    static let bloomRange: ClosedRange<Float> = 0...0.3
    static let thresholdRange: ClosedRange<Float> = 0...8
    static let apertureRange: ClosedRange<Float> = 0...24
    static let focusRange: ClosedRange<Float> = 0...30
    static let vignetteRange: ClosedRange<Float> = 0...1
    static let grainRange: ClosedRange<Float> = 0...0.2
    static let aberrationRange: ClosedRange<Float> = 0...0.01
    static let warmthRange: ClosedRange<Float> = -1...1
    static let saturationRange: ClosedRange<Float> = 0...2
    static let contrastRange: ClosedRange<Float> = 0.5...1.5
    static let maxBlur: Float = 24      // the depth of field's widest blur circle (output pixels)
    static let bloomLevels = 6          // the glow's halvings, from half the output size

    /// Off, but in a scene with its own (the showcase's model's look, the city's exposure); and with the realistic look
    /// outdoors, a camera's: exposure that follows the light, a gentle filmic grade, a little bloom and vignette.
    static func preset(for scene: SceneSettings) -> PostSettings {
        if let own = scene.kind.definition.post { return own(scene) }
        guard scene.realism != .off, scene.kind.hasRealisticLook else { return PostSettings() }
        var p = PostSettings()
        p.autoExposure = true
        p.saturation = 1.06
        p.contrast = 1.1
        p.warmth = scene.kind.definition.realisticWarmth
        p.bloom = 0.035
        p.bloomThreshold = 1.6
        p.vignette = 0.16
        return p
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(bloom: Float = 0, bloomThreshold: Float = 1, aperture: Float = 0, focus: Float = 0, vignette: Float = 0, grain: Float = 0, aberration: Float = 0, autoExposure: Bool = false, warmth: Float = 0, saturation: Float = 1, contrast: Float = 1) {
        self.bloom = bloom
        self.bloomThreshold = bloomThreshold
        self.aperture = aperture
        self.focus = focus
        self.vignette = vignette
        self.grain = grain
        self.aberration = aberration
        self.autoExposure = autoExposure
        self.warmth = warmth
        self.saturation = saturation
        self.contrast = contrast
    }
}

/// Everything the settings panel and the keyboard shortcuts can change.
/// Generated plants (the forest, the valley's trees). The wind turns their limbs and boughs about bones (plants as
/// assemblies; baked plants stand still).
package struct FoliageSettings: Equatable, Codable {
    package var wind: Float = 0                 // 0 = still ... 1 = a strong wind
    package var windDirection: Float = 25       // where it blows to, degrees from +x toward +z
    package var gusts: Float = 0.7              // 0 = steady ... 1 = it comes in waves
    /// Far plants are traced as voxels (FoliageVoxels) from where a voxel is this many traced pixels: 0 = never.
    /// At 2 the forest's far trees change over about 90 m out, where they cost less as voxels than as triangles.
    package var lod: Float = 2
    /// How far from the camera the plants' limbs move in the wind, in metres (0 = everywhere). Farther plants still lean
    /// as a whole; their limbs' structures stand at rest and aren't refitted every frame. At 20 m the moving forest is
    /// 7-16% faster than with every limb moving (M1 Max, Metal 3); from above, where every crown is farther, only whole trees lean.
    package var swayReach: Float = 20
    /// The time of year: 0 = spring, 0.3 = summer, 0.5...0.8 = the leaves turn and fall, 1 = winter.
    package var season: Float = 0.3
    /// How much of the light leaves let through, as a share of each species' own: 0 = opaque leaves.
    package var translucency: Float = 1

    package static let windRange: ClosedRange<Float> = 0...1
    package static let directionRange: ClosedRange<Float> = -180...180
    package static let gustRange: ClosedRange<Float> = 0...1
    package static let lodRange: ClosedRange<Float> = 0...4
    package static let swayRange: ClosedRange<Float> = 0...200
    package static let seasonRange: ClosedRange<Float> = 0...1
    package static let translucencyRange: ClosedRange<Float> = 0...1

    /// A breeze where there are plants.
    package static func preset(for kind: SceneKind) -> FoliageSettings {
        var f = FoliageSettings()
        if kind.hasPlants { f.wind = 0.4 }
        if kind == .plants { f.lod = 0 }   // the workshop's plants are never voxels
        return f
    }
}

package struct RenderSettings: Equatable, Codable {
    package var renderScale: CGFloat = 0.5     // traced resolution, as a fraction of the window's size in points
    package var upscaleFactor: CGFloat = 3     // output / traced resolution, through MetalFX's denoising scaler; 0 = off
    /// With upscaling: MetalFX's in-between picture each frame, presented half a frame before the frame's own
    /// (FrameInterpolator). Auto only while frames take over three of the display's refreshes; never offscreen.
    package var frameInterpolation = FrameInterpolation.auto
    package var giEnabled = true
    package var bounces = 2
    package var blueNoise = true               // stratified samples steady the shadow denoiser's history clamp (less flicker)
    package var taa = true                     // without upscaling: jittered rays and a temporal resolve (Post.metal taaResolveKernel)
    package var paused = false
    package var viewMode = 0
    /// Solid shading, like Blender's viewport: every surface flat grey under a fixed studio light, one camera ray a
    /// pixel and nothing else (no shadows, GI, reflections, fog, sky, denoisers, MetalFX or lens). For iterating on
    /// scenes and physics fast (Renderer: FramePlan.solid, Shaders/Output.metal solidKernel).
    package var solid = false
    /// What solid shading draws (Shaders/Output.metal solidTraceKernel, solidResolveKernel).
    package var solidLook = SolidLook()
    /// `solid` was turned on by entering a scene in the solid look (applySceneDefaults turns it back when leaving).
    package var solidFromScene = false
    package var reference = ReferenceSettings()   // a converged picture instead of the realtime one (session state: off at launch)
    package var denoiser = DenoiserSettings()
    package var giMode = GIMode.radianceCascades   // ~45% cheaper than path tracing here, ~11 dB closer to an 8-bounce reference, no flicker
    package var lightMaps = false              // path tracer: light bounce hits from per-light shadow maps instead of shadow rays
    package var directLight = DirectLightMode.initial
    package var restir = RestirSettings()
    package var restirGI = RestirGISettings()
    package var manyLightRays = 1              // more than 4 lights: shadow rays per light group (2 = less noise and flicker, slower)
    package var manyLightReuse = 4             // more than 4 lights, 1 ray: reuse light picks for up to this many frames (0 = off):
                                       // a third less flicker on still frames for ~0.7 ms and ~0.7 dB (manyLightsReuseKernel)
    package var cascades = CascadeSettings()
    package var scene = SceneSettings()
    package var api = RenderAPI.initial
    package var virtualGeometry = VirtualGeometrySettings()
    package var specular: Bool = ProcessInfo.processInfo.environment["METALRENDERER_SPECULAR"] != "0"   // GGX specular for glTF materials
    package var textureBudgetMB = Int(ProcessInfo.processInfo.environment["METALRENDERER_TEXTURE_BUDGET"] ?? "") ?? 1024   // streamed textures
    package var fog = FogSettings.preset(for: .cornell)
    package var sky = SkySettings.preset(for: .cornell)
    package var foliage = FoliageSettings.preset(for: .cornell)
    package var post = PostSettings()
    // Camera and animation
    package var exposure: Float = 0            // stops (EV) before the tone curve
    package var toneMap = ToneMap.aces
    package var fovDegrees: Float = 60         // vertical field of view
    package var moveSpeed: Float = 2.5         // WASD, m/s (Shift: 3.2x)
    package var timeScale: Float = 1           // animation speed (Pause stops it too)
    package var timeOfDay: Float = 0           // scenes with a day cycle: offset into it, as a fraction of it
    /// The day is held where `timeOfDay` puts it (the day bar, DayClock): `timeOfDay` is then the time of the day
    /// itself, as a fraction of the cycle, and the rest of the scene goes on moving.
    package var dayHeld = false
    /// The particles' layer's size, as a share of the traced frame's (1 or 0.5): upsampled by depth over the picture.
    package var particleScale: Float = 1

    /// The physics scene's traced resolution (`usePhysicsLook`).
    package static let physicsScale: CGFloat = 0.375

    /// The physics scene's look, which leaves the GPU to the simulation: no GI and no reflections, traced at 0.375 of
    /// the window (3x upscaled, 1440x900 out). On the M1 Max its frame renders in 5 ms against the app look's 15
    /// (reflections 4.7 ms, cascades 2.9, and the smaller frame halves the trace and the upscaler). The panel can turn
    /// either back on.
    package mutating func usePhysicsLook() {
        giEnabled = false
        specular = false
        renderScale = RenderSettings.physicsScale
    }

    /// Applies the defaults that suit `scene.kind` (the settings panel calls this when the scene changes and on
    /// Reset to Defaults): the GI method, the night market's light count, the fog, the sky and the lens (the showcase's
    /// model brings its own fog and lens), and the physics scene's look (leaving it, the defaults again).
    package mutating func applySceneDefaults(from defaults: RenderSettings) {
        giMode = defaults.giMode
        // A scene in the solid look (the demolition's: the look is the user's again when they leave it).
        let solidScene = scene.kind.definition.solid
        if solidScene && !solid {
            solid = true
            solidFromScene = true
        } else if !solidScene && solidFromScene {
            solid = defaults.solid
            solidFromScene = false
        }
        if scene.kind.usesPhysicsLook {
            usePhysicsLook()
        } else if !giEnabled && !specular && renderScale == RenderSettings.physicsScale {
            giEnabled = defaults.giEnabled
            specular = defaults.specular
            renderScale = defaults.renderScale
        }
        scene.startLights()
        fog = FogSettings.preset(for: scene)
        post = PostSettings.preset(for: scene)
        foliage = FoliageSettings.preset(for: scene.kind)
        let image = sky.mode == .image ? sky : nil   // an image the user opened stays
        sky = SkySettings.preset(for: scene)
        if let image { sky.mode = .image; sky.imagePath = image.imagePath; sky.imageExposure = image.imageExposure }
    }

    package static let exposureRange: ClosedRange<Float> = -4...4
    package static let fovRange: ClosedRange<Float> = 30...110
    package static let moveSpeedRange: ClosedRange<Float> = 0.5...100
    package static let timeScaleRange: ClosedRange<Float> = 0...4
    package static let manyLightReuseRange = 0...8
    package static let textureBudgetOptions = [256, 512, 1024, 2048, 4096]
    package static let renderScaleRange: ClosedRange<CGFloat> = 0.25...2.0
    package static let renderScaleStep: CGFloat = 0.125
    package static let bounceRange = 1...8
    package static let viewModes = ["Final", "Raw direct", "Raw indirect", "Normals", "Albedo", "History length",
                            "Indirect only", "GI debug",
                            "Triangles", "Clusters", "Groups", "LOD level", "Triangle size", "Traversal cost",
                            "Fog scattering"]
    /// Whether view mode `mode` shows the light (tone mapped, with the lens effects) rather than a value to read as it
    /// is (normals, albedo, the geometry views...): viewIsHDR in
    /// Shaders/Output.metal.
    package static func showsLight(_ mode: Int) -> Bool {
        ![3, 4, 5].contains(mode) && !(7...13).contains(mode)
    }
    /// The geometry debug views (geometryDebugKernel): triangles, virtual-geometry clusters / groups / DAG levels,
    /// projected triangle size, and the primary rays' traversal cost.
    package static let geometryViews = 8...13

    /// (As the memberwise initializer, for the modules above this one.)
    package init(renderScale: CGFloat = 0.5, upscaleFactor: CGFloat = 3, frameInterpolation: FrameInterpolation = FrameInterpolation.auto, giEnabled: Bool = true, bounces: Int = 2, blueNoise: Bool = true, taa: Bool = true, paused: Bool = false, viewMode: Int = 0, solid: Bool = false, solidLook: SolidLook = SolidLook(), solidFromScene: Bool = false, reference: ReferenceSettings = ReferenceSettings(), denoiser: DenoiserSettings = DenoiserSettings(), giMode: GIMode = GIMode.radianceCascades, lightMaps: Bool = false, directLight: DirectLightMode = DirectLightMode.initial, restir: RestirSettings = RestirSettings(), restirGI: RestirGISettings = RestirGISettings(), manyLightRays: Int = 1, manyLightReuse: Int = 4, cascades: CascadeSettings = CascadeSettings(), scene: SceneSettings = SceneSettings(), api: RenderAPI = RenderAPI.initial, virtualGeometry: VirtualGeometrySettings = VirtualGeometrySettings(), specular: Bool = ProcessInfo.processInfo.environment["METALRENDERER_SPECULAR"] != "0", textureBudgetMB: Int = Int(ProcessInfo.processInfo.environment["METALRENDERER_TEXTURE_BUDGET"] ?? "") ?? 1024, fog: FogSettings = FogSettings.preset(for: .cornell), sky: SkySettings = SkySettings.preset(for: .cornell), foliage: FoliageSettings = FoliageSettings.preset(for: .cornell), post: PostSettings = PostSettings(), exposure: Float = 0, toneMap: ToneMap = ToneMap.aces, fovDegrees: Float = 60, moveSpeed: Float = 2.5, timeScale: Float = 1, timeOfDay: Float = 0, dayHeld: Bool = false, particleScale: Float = 1) {
        self.renderScale = renderScale
        self.upscaleFactor = upscaleFactor
        self.frameInterpolation = frameInterpolation
        self.giEnabled = giEnabled
        self.bounces = bounces
        self.blueNoise = blueNoise
        self.taa = taa
        self.paused = paused
        self.viewMode = viewMode
        self.solid = solid
        self.solidLook = solidLook
        self.solidFromScene = solidFromScene
        self.reference = reference
        self.denoiser = denoiser
        self.giMode = giMode
        self.lightMaps = lightMaps
        self.directLight = directLight
        self.restir = restir
        self.restirGI = restirGI
        self.manyLightRays = manyLightRays
        self.manyLightReuse = manyLightReuse
        self.cascades = cascades
        self.scene = scene
        self.api = api
        self.virtualGeometry = virtualGeometry
        self.specular = specular
        self.textureBudgetMB = textureBudgetMB
        self.fog = fog
        self.sky = sky
        self.foliage = foliage
        self.post = post
        self.exposure = exposure
        self.toneMap = toneMap
        self.fovDegrees = fovDegrees
        self.moveSpeed = moveSpeed
        self.timeScale = timeScale
        self.timeOfDay = timeOfDay
        self.dayHeld = dayHeld
        self.particleScale = particleScale
    }
}
