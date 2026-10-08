import CoreGraphics
import Foundation
import simd

extension ClosedRange {
    func clamp(_ value: Bound) -> Bound { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

/// SVGF denoiser parameters. All but the pass counts and `separateSignals` reach the shaders through `Uniforms.denoise`.
///
/// Defaults were tuned with `METALRENDERER_BENCH=denoise` against converged reference images. Compared with the original
/// settings (5 passes, sigma 4, 32 frames, combined signal) they gain about 3 dB on static scenes and 4.7 dB on
/// moving ones, for ~0.4 ms more GPU time at 640x400 and slightly more frame-to-frame flicker.
struct DenoiserSettings: Equatable, Codable {
    var enabled = true
    var atrousPasses = 4            // 1...5 wavelet passes with step sizes 1, 2, 4, 8, 16 (fewer = sharper, noisier)
    var techniquePasses = 2         // the same with cascade GI, where only direct light is filtered: it is
                                    // much less noisy, and 2 passes look the same as 4 (measured) for half the cost
    var luminanceSigma: Float = 2   // luminance edge-stopping, in standard deviations (lower = sharper shadows, noisier)
    var maxHistory: Float = 16      // frames of temporal accumulation (lower = less lag, noisier)
    var antiLag: Float = 0          // 0 = off; higher shortens the history faster where the lighting changes
    var separateSignals = true      // filter direct and indirect light separately (sharper shadows, 2x the cost)
    // Shadow denoiser for direct light (up to 4 lights; see Shaders/Denoise.metal, 3b): filters each light's visibility
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
    static let shadowClampRange: ClosedRange<Float> = 0.05...2
    static let shadowSigmaRange: ClosedRange<Float> = 0.5...8
    static let varianceBoostRange: ClosedRange<Float> = 1...8   // ReSTIR's denoiser inputs (RestirSettings, RestirGISettings)
}

/// How direct light from the lights is computed.
enum DirectLightMode: Int, CaseIterable, Codable {
    case auto       // ReSTIR with many lights (Scene.lightTableThreshold, 256), otherwise grouped (exact up to 4)
    case exact      // one shadow ray per light (cost grows with the light count; references)
    case grouped    // one light per shadow-denoiser group, picked over all lights (manyLightsKernel; O(N) per pixel)
    case restir     // ReSTIR DI: candidates from the light table, temporal + spatial reuse, one shadow ray (O(1))
    case megalights // MegaLights-style: lights culled into screen tiles, a few MIS-combined samples per pixel, no reuse

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .exact: return "Exact"
        case .grouped: return "Grouped"
        case .restir: return "ReSTIR"
        case .megalights: return "MegaLights"
        }
    }

    /// `METALRENDERER_DIRECT=auto|exact|grouped|restir|megalights`; `METALRENDERER_LIGHTS=all` is exact.
    static let initial: DirectLightMode = {
        let env = ProcessInfo.processInfo.environment
        if let v = env["METALRENDERER_DIRECT"], let m = allCases.first(where: { "\($0)" == v.lowercased() }) { return m }
        return env["METALRENDERER_LIGHTS"] == "all" ? .exact : .auto
    }()
}

/// ReSTIR DI (Shaders/RestirDI.metal): reservoir resampling of light samples, so a pixel's cost doesn't depend on the
/// light count. Defaults from METALRENDERER_BENCH=restirq.
struct RestirSettings: Equatable, Codable {
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
    var grid = RegirSettings()      // the light grid the candidates come from (ReGIR)

    static let candidateRange = 1...32
    static let chainRange = 1...4
    static let maxMRange: ClosedRange<Float> = 1...64
    static let spatialPassRange = 0...2
    static let spatialSampleRange = 1...8
    static let radiusRange: ClosedRange<Float> = 4...64
}

/// MegaLights-style direct light (Shaders/MegaLights.metal, after Unreal Engine 5.5's MegaLights): the lights are culled
/// into 16x16-pixel tiles by how far their light reaches, and each pixel shades `samples` light samples with one shadow
/// ray each: some picked from its tile's list by unshadowed luminance (steered toward the lights the tile found visible
/// last frame), `treeSamples` drawn from the light tree (LightTree: the far field), combined by multiple importance
/// sampling, so the cutoff, a full list and the guiding change only the noise, never the brightness. SVGF then denoises
/// the direct light as radiance.
struct MegaLightsSettings: Equatable, Codable {
    var samples = 4                 // light samples (shadow rays) per pixel, the suns' aside
    var treeSamples = 2             // ...of which from the light tree (the rest from the tile's list)
    var capacity = 256              // lights a tile's list holds (more: the tree samples still reach them)
    var cutoff: Float = 0.002       // a light reaches as far as its unshadowed light, exposed, stays above this
    var partition = true            // each light from one strategy (the list its lights in reach, the tree the rest):
                                    // no tree walks for list samples; off = MIS (balance heuristic) between the two
    var guiding = true              // pick the lights the tile saw lit last frame more often
    var guideWeight: Float = 0.25   // ...the others' weight
    var denoiseSigma: Float = 3     // SVGF for MegaLights' direct light, as RestirSettings'
    var denoisePasses = 4
    var denoiseHistory: Float = 8
    var varianceBoost: Float = 1    // independent samples every frame: their temporal variance is what it is

    static let sampleRange = 1...8
    static let treeSampleRange = 1...8   // at most `samples`
    static let capacityOptions = [64, 128, 256]   // powers of two (the tile's sort), at most ML_MAX_CAPACITY
    static let cutoffRange: ClosedRange<Float> = 0.0001...0.1
    static let guideWeightRange: ClosedRange<Float> = 0.05...1
    /// Lights a scene may have (a tile's list holds 16-bit indices); with more, MegaLights falls back to ReSTIR, as it
    /// does with more suns than it lights apart (LightTable.maxSuns: the tree leaves the suns out).
    static let maxLights = 0xFFFF
}

/// The light grid (Shaders/Regir.metal): a camera-centred world-space grid of light reservoirs, rebuilt every
/// frame on the GPU, that ReSTIR DI draws most of its candidates from, so they are the lights near the pixel rather
/// than the whole table by power. `levels` cascaded levels of `cells`^3 cells, the first `cellSize` m wide and each
/// next `levelScale` times wider; `slots` reservoirs per cell, each the pick of `candidates` table draws; `share` of
/// RestirSettings.candidates come from the grid, the rest from the table.
struct RegirSettings: Equatable, Codable {
    var enabled = true
    var cells = 16
    var levels = 2
    var cellSize: Float = 1
    var levelScale: Float = 3
    var slots = 32
    var candidates = 8
    var share = 6

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
enum ToneMap: Int, CaseIterable, Codable {
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

/// How indirect light (global illumination) is computed.
enum GIMode: Int, CaseIterable, Codable {
    case pathTraced         // per-pixel path tracing (1 spp) + SVGF denoising
    case radianceCascades   // screen-space probes with world-space ray intervals, merged across cascades
    case restirGI           // ReSTIR GI: per-pixel paths whose first bounce is reused over time and space, + SVGF
    case lumen              // Lumen-style: screen probes on the G-buffer, filtered, resolved through SH, accumulated

    var title: String {
        switch self {
        case .pathTraced: return "Path traced"
        case .radianceCascades: return "Radiance cascades"
        case .restirGI: return "ReSTIR GI"
        case .lumen: return "Lumen"
        }
    }
}

/// A converged reference picture for debugging (README "Reference rendering"): samples averaged over frames, the
/// average restarted whenever the picture would change (the camera, a setting, the scene animating).
enum ReferenceMode: Int, CaseIterable, Codable {
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
struct ReferenceSettings: Equatable, Codable {
    var mode = ReferenceMode.off
    var bounces = 8             // path length (both modes)
    var samplesPerFrame = 1     // path traced: paths per pixel per frame
    var maxSamples = 0          // stop adding samples at this many per pixel; 0 = never

    static let bounceRange = 1...16
    static let samplesPerFrameRange = 1...16
    static let maxSampleOptions = [0, 64, 256, 1024, 4096, 16384]
}

/// ReSTIR GI (Shaders/RestirGI.metal): one path per pixel (or per 2x2 block) whose first bounce is resampled over
/// time (and optionally across neighbours). Defaults from METALRENDERER_BENCH=gi and stressq (README "ReSTIR GI").
struct RestirGISettings: Equatable, Codable {
    var quarterBudget = false       // one fresh path per 2x2 block per frame (a rotating pixel): 4x cheaper paths, but
                                    // pixels that lost their history wait up to 4 frames (-5 to -15 dB in motion), so off
    var bounces = 2                 // path length (the first bounce is the reused sample)
    var lightMaps = false           // light the paths' hits from the light maps instead of shadow rays
    var feedback = true             // multi-bounce: the paths' last hits add last frame's indirect light where on screen
                                    // (+16 dB in Cornell with the fallback: 2 bounces miss a quarter of the light)
    var denoisedFeedback = true     // ...the denoised indirect light (else the raw one)
    var feedbackFallback = true     // ...and off screen, last frame's mean indirect light
    var temporal = true             // reuse last frame's reservoir (reprojected): half the flicker
    var maxM: Float = 2             // confidence cap: higher = steadier, laggier (16: -0.5 dB still, -2 to -4.5 dB moving)
    var maxAge = 30                 // the pixel's fresh paths a sample may outlive (its light is from when it was traced)
    var spatialPasses = 0           // 0...2 passes of spatial reuse: unbiased, but after the denoiser no better (and 2-13
                                    // ms at 640x400), so off
    var spatialSamples = 2          // neighbours per pass (1 scored as 5)
    var unbiased = true             // spatial reuse: visibility in the targets, two rays per neighbour (without: cheaper,
                                    // but 8-17% darker in the old stress hall, where neighbours saw different light)
    var radius: Float = 30          // spatial neighbourhood radius, pixels at 960 wide (scales with the width)
    var minDistance: Float = 0.02   // floor of the sample distance in the target (m): no spikes from very close samples
    var denoise = true              // SVGF on the result
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
struct CascadeSettings: Equatable, Codable {
    var probeSpacing = 8            // cascade-0 probe spacing in traced pixels (4 or 8)
    var cascades = 4
    var firstInterval: Float = 0.4  // cascade-0 ray length in meters; each cascade's interval is 4x longer
    var feedback = true             // multi-bounce: shade ray hits with last frame's indirect light where visible
    var denoiseIndirect = false     // smooth the result with the SVGF temporal pass

    static let spacingOptions = [4, 8]
    static let cascadeRange = 2...5
    static let firstIntervalRange: ClosedRange<Float> = 0.1...1.0
}

/// What Lumen's rays trace past the screen: triangles (the ray tracer's), or the meshes' distance fields near the
/// probe and triangles beyond (software Lumen).
enum LumenTrace: Int, CaseIterable, Codable {
    case triangles
    case sdf
}

/// Lumen-style GI (Lumen.swift, Shaders/Lumen.metal): a probe on the G-buffer in every tile of `probeSpacing` pixels,
/// each tracing `probeSpacing`^2 octahedral directions (64 at 8 px), jittered every frame; the probes' radiance is
/// filtered across their neighbours, projected onto SH, resolved per pixel and accumulated over frames.
struct LumenSettings: Equatable, Codable {
    var probeSpacing = 8            // screen-probe tile, traced pixels (its side is also the probe's direction tile)
    var feedback = true             // multi-bounce: ray hits add last frame's indirect light where it was on screen
    var filter = true               // spatial filter: each probe direction averaged with its neighbours' (plane-weighted)
    var temporal = true             // per-pixel history, reprojected
    var history: Float = 16         // the history's length at most (frames)
    var denoiseIndirect = false     // smooth the result with the SVGF temporal pass
    var screenTraces = true         // rays march the screen first (last frame's lit surfaces), then the world
    var screenSteps = 24            // the screen march's samples
    var thickness: Float = 0.03     // a screen hit lies at most this fraction of the depth behind the surface
    var screenReach: Float = 50     // the screen march's reach (m)
    var debug = 0                   // "GI debug" view: 0 = probes, 1 = what answered the rays (screen, world, sky)
    var cards = true                // the surface cache: world hits read cards lit ahead of time (else lit at the hit)
    var radiosity = true            // the cards' own indirect light (rays from the cards), instead of screen feedback
    var radiosityRays = 8           // a radiosity probe's rays a frame (a probe per 4x4 card texels)
    var radiosityBudget = 256       // card texels (thousands) whose radiosity is updated a frame, new cards first: 1024
                                    // (every card a frame) is 0.05 dB better still, 0.1-0.3 dB in motion, 3-24 ms slower
    var radiosityThroughSDF = false // with `.sdf`: radiosity's rays trace the global field too (Lumen's way), not triangles:
                                    // -1 dB in Cornell, -1.4 dB in the stress hall (it loses the near contact)
    var trace = LumenTrace.sdf      // software Lumen; `.triangles` is ~0-2 dB closer to the references, as an A/B
    var meshReach: Float = 2        // with `.sdf`: how far rays trace the mesh fields (m)
    var globalVoxel: Float = 0      // the global field's finest voxel (m); 0: by the scene (0.1, or 0.2 outdoors)

    static let spacingOptions = [4, 8, 16]
    static let historyRange: ClosedRange<Float> = 1...64
    static let screenStepRange = 4...64
    static let radiosityRayRange = 1...32
    static let radiosityBudgetRange = 16...1024
    static let thicknessRange: ClosedRange<Float> = 0.005...0.2
    static let screenReachRange: ClosedRange<Float> = 1...500
    static let debugViews = ["Probes", "Trace kinds", "Card albedo", "Card light", "SDF normals", "SDF depth check", "Global SDF"]
    static let meshReachRange: ClosedRange<Float> = 0.25...20
    static let globalVoxelRange: ClosedRange<Float> = 0...1
}

/// Which scene is loaded.
enum SceneKind: Int, CaseIterable, Codable {
    case cornell            // small Cornell-style room: 5 objects (2 moving), 3 moving lights
    case stress             // stress test: a warehouse, factory, garage and office with `objects` props and `lights` lights
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
    case forest             // generated trees, bushes, ferns and grass (`trees`, `seed`) on rolling ground, a day cycle
    case crowd              // a square under the sun with `characters` animated characters on `poses` pose slots
    case city               // a generated city (`CitySettings`) under the sun: blocks of procedural buildings, a day cycle
    case cityNight          // the same city at night: lit windows and rooms, street lamps, the moon
    case world              // the open world (World.swift): hills, forest and cities without end, made around the camera;
                            // its day goes through dusk into a night of lit windows, street lamps and the moon
    case showcase           // one model of Assets/ (`SceneSettings.showcase`) staged on a set of its own (ShowcaseLook):
                            // volumetric beams, mist, accent lights, particles, with bloom and depth of field
    case shapes             // SDF shapes (SDFShapes.swift): primitives, cuts and blends, a baked mesh, glowing shapes as lights
    case physics            // rigid SDF shapes (Physics.swift) poured into an arena: a ramp, a pile, a tower knocked over
    case ragdolls           // `ragdolls` ragdolls (jointed bodies, Physics.swift) dropped down a staircase
    case hair               // hair and fur (PhysicsHair.swift): furry bodies rolling down a ramp, a long-haired head
                            // swinging, in a breeze; strands drawn as curves (Metal's ray tracer)
    case softBodies         // `softBodies` soft bodies (PhysicsSoft.swift): jellies dropped onto steps, pegs and a bowl
    case muscles            // flesh, muscles and skin (PhysicsFlesh.swift) on a character walking and running round a
                            // circle among balls, and on ragdolls tumbling down steps
    case fluids             // liquids (PhysicsFluid.swift): water, blood and honey poured side by side down steps into a
                            // tray, boxes floating and sinking in them, a paddle in each to stir it
    case plants             // the plant workshop (Scene+Plants.swift): one species' plants on a lawn under the sun, as the
                            // plant editor shapes them (`SceneSettings.plants`)
    case buildings          // the building workshop (Scene+Buildings.swift): one building, inside and out, on its lot, as
                            // the building editor shapes it (`SceneSettings.buildings`)
    case characters         // the character workshop (Scene+Characters.swift): generated people (CharacterDNA) in a studio,
                            // as the character editor shapes them (`SceneSettings.characterWorkshop`)

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
        case .forest: return "Forest"
        case .crowd: return "Crowd"
        case .city: return "City"
        case .cityNight: return "City at night"
        case .world: return "Open world"
        case .showcase: return "Showcase (one model)"
        case .shapes: return "SDF shapes"
        case .physics: return "Physics"
        case .ragdolls: return "Ragdolls"
        case .hair: return "Hair and fur"
        case .softBodies: return "Soft bodies"
        case .muscles: return "Muscles and skin"
        case .fluids: return "Fluids"
        case .plants: return "Plant workshop"
        case .buildings: return "Building workshop"
        case .characters: return "Character workshop"
        }
    }

    /// The scenes the physics steps (Physics.swift): they share its settings and look (RenderSettings.usePhysicsLook).
    var simulates: Bool {
        self == .physics || self == .ragdolls || self == .hair || self == .softBodies || self == .muscles || self == .fluids
    }
    /// Scenes built with `SceneSettings.lights` lights (the panel's Lights slider).
    var hasLightCount: Bool { self == .stress || self == .market }
    /// Length of the sun's day cycle in seconds (Scene+Lights: the sun scene's `day`, the valley's two `half`s; the
    /// open world's whole day, with its night), or nil.
    var dayCycle: Float? {
        self == .sun ? 60 : self == .valley || self == .forest || self == .city ? 180 : self == .world ? Heavens.day : nil
    }
    /// The generated city, by day or by night (Scene+City.swift): the scenes `SceneSettings.city` describes.
    var isCity: Bool { self == .city || self == .cityNight }
    /// The scene's default camera depends on how it was built (its size), so it is asked of the scene itself.
    /// The open world (Scene+World.swift).
    var isWorld: Bool { self == .world }
    /// Scenes with a share of their windows lit at night (`CitySettings.lit`).
    var hasLitWindows: Bool { self == .cityNight || self == .world }
    var cameraFromScene: Bool { self == .crowd || isCity || isWorld || self == .showcase || isWorkshop }   // these frame what they hold
    /// The editors' scenes: one thing (a plant, a building) made again at every edit, an orbit camera round it.
    var isWorkshop: Bool { self == .plants || self == .buildings || self == .characters }
    /// Scenes with generated plants (Foliage): `SceneSettings.seed` picks them.
    var hasPlants: Bool { self == .forest || self == .valley || isWorld || self == .plants }
    /// Scenes whose amount of plants is `SceneSettings.trees` and `undergrowth`.
    var hasForest: Bool { self == .forest || isWorld }
}

/// Which buildings the city is made of: every style by district, or one of them everywhere.
enum CityStyle: Int, CaseIterable, Codable {
    case mixed              // towers in the centre, mid-rise blocks around them, old town and warehouses at the edge
    case oldtown            // narrow plastered houses with pitched roofs and shutters
    case residential        // brick apartment blocks with balconies around courtyards
    case warehouse          // low, wide brick halls with big windows and loading doors
    case office             // glass towers on podiums, with setbacks
    case modern             // concrete and panel mid-rise blocks with ribbon windows

    var title: String {
        switch self {
        case .mixed: return "Mixed districts"
        case .oldtown: return "Old town"
        case .residential: return "Residential blocks"
        case .warehouse: return "Warehouses"
        case .office: return "Office towers"
        case .modern: return "Modern mid-rise"
        }
    }
}

/// The generated city (the City scenes): changing any of it builds the city again.
/// (Which city is `SceneSettings.seed`'s to say, as for the plants.)
struct CitySettings: Equatable, Codable {
    /// Blocks along each side of the street grid (1 = a single block).
    var blocks = 4
    var style = CityStyle.mixed
    /// At night: the share of windows with a light on behind them.
    var lit: Float = 0.35
    /// The share of windows with a room behind the glass instead of a blind (at night the lit ones have a lamp).
    var rooms: Float = 0.15
    /// Generated brick, plaster, concrete, tile and paving textures (ProceduralTextures); off: flat colours.
    var textures = true
    /// A window's shell (reveal, frame, sill, lintel, shutters) is made once and placed at every window like it
    /// (Building.Module), a building an assembly of them (Scene.Assembly.rigid); off: every building one mesh of its own.
    var modules = false
    /// The building the camera comes near (within `interiorReach` metres) has its interior made, in the background:
    /// rooms, stairs, furniture, lights you can walk among (Scene+Interiors.swift). Off: every building a shell.
    var interiors = true
    var interiorReach: Float = 30

    static let blockRange = 1...10
    static let litRange: ClosedRange<Float> = 0...1
    static let roomRange: ClosedRange<Float> = 0...0.5
}

/// Where the camera's surfaces come from: one traced ray per pixel, or a raster visibility buffer (Shaders/Raster.metal,
/// in the manner of Unreal's Nanite: GPU-driven, culled by chunks of 128 triangles against the view and a depth pyramid),
/// whose triangles the primary rays then only meet. The rest of the frame is the same.
enum PrimaryVisibility: Int, CaseIterable, Codable {
    case traced
    case raster

    var title: String { self == .traced ? "Traced" : "Raster (visibility buffer)" }

    /// `METALRENDERER_PRIMARY=raster|traced` picks the starting one (benchmarks: for every setting).
    static let initial: PrimaryVisibility = ProcessInfo.processInfo.environment["METALRENDERER_PRIMARY"] == "raster" ? .raster : .traced
}

/// What shadows the direct light of the camera's surfaces: a ray toward a point on the light per sample, or for suns,
/// spot and sphere lights Virtual Shadow Maps (VSM.swift, Shaders/VSM.metal, in the manner of Unreal's: pages of a
/// huge virtual depth map rendered where pixels look, cached while nothing moves), through which the same jittered
/// segment is marched. What the raster can't draw (leaf cards, plants in the wind) is still traced; so is every sample
/// whose pages aren't ready. Bounces, reflections and the fog keep their rays.
enum ShadowMethod: Int, CaseIterable, Codable {
    case rays
    case virtualMaps

    var title: String { self == .rays ? "Rays" : "Virtual shadow maps" }

    /// `METALRENDERER_SHADOW_METHOD=vsm|rays` picks the starting one (benchmarks: for every setting).
    static let initial: ShadowMethod = ProcessInfo.processInfo.environment["METALRENDERER_SHADOW_METHOD"] == "vsm" ? .virtualMaps : .rays
}

/// Virtual Shadow Maps' budgets and tuning (ShadowMethod.virtualMaps).
struct VSMSettings: Equatable, Codable {
    var pool = 1024                 // physical pages of 128 x 128 texels (depth32Float: 64 KB each)
    var budget = 256                // pages rendered a frame at most (the rest: rays until their turn)
    var levels = 12                 // the sun's clipmap levels, 16 m wide and doubling (32 km)
    var maxLights = 64              // spot and sphere lights with maps (the others: rays)
    var steps = 8                   // the march's steps toward the light
    var bias: Float = 0.5           // depth bias, in texels of the page's level (x (1 + the slope)): 0.5 is nearest the
                                    // rays (pixels > 8 levels off in the city: 1.6% against 3.0% at 1.5), no acne
    /// Virtual geometry (with the per-instance BLAS) drawn as clusters with a cut of each view's own (RasterClusters),
    /// whatever the camera draws it from: its pages then stay drawn while the camera moves. Off: the BLAS's triangles,
    /// all of them into every page the instance covers, every frame.
    var clusters = true

    static let poolOptions = [256, 512, 1024, 2048]
    static let budgetRange = 16...1024
    static let levelRange = 1...12
    static let maxLightRange = 0...256
    static let stepRange = 1...16
    static let biasRange: ClosedRange<Float> = 0...8
}

/// A glTF model the user opened or dropped into the scene.
struct ExtraModel: Equatable, Codable {
    var path: String
    var position: SIMD3<Float>
    var yaw: Float
}

/// The physics scene's (Physics.swift). Changing any of it rebuilds the scene, which starts the simulation again.
struct PhysicsSettings: Equatable, Codable {
    /// Where the steps run: the GPU (Shaders/Physics.metal), the CPU (PhysicsCPU.swift), or whichever suits the
    /// scene's size (the CPU below `PhysicsSettings.gpuFrom` bodies, where a dispatch costs more than the work).
    enum Backend: Int, CaseIterable, Codable {
        case auto, gpu, cpu
        var title: String { ["Automatic", "GPU", "CPU"][rawValue] }
    }
    var backend = Backend.auto
    /// Substeps a step (1/60 s): more hold stacks stiffer, for more work (8 lets a tower of 8 crossed layers sink
    /// through the floor; 12 holds it to 3 mm).
    var substeps = 16
    /// Rigid bodies poured in, and particles poured into a bin.
    var bodies = 96
    var particles = 2048
    /// The cloth's vertices along a side (0: no cloth).
    var cloth = 36
    /// Ragdolls dropped down the ragdoll scene's stairs (11 bodies each).
    var ragdolls = 24
    /// The hair scene: strands drawn around each simulated one (guide), and furry bodies dropped down its ramp.
    var hair = 12
    var furBodies = 6
    /// The soft body scene: soft bodies dropped in, and their lattices' cubes along each one's longest side.
    var softBodies = 16
    var softCells = 6
    /// The muscles scene (Scene+Muscles.swift): the character, the ragdolls with flesh, the flesh's lattice spacing
    /// (cm), its skin, and how much its muscles contract.
    var muscleCharacter = true
    var muscleRagdolls = 3
    var fleshCell: Float = 3.5
    /// The skin: the drawn surface in the flesh's outer tets (stiffer: its tension), or on a shell of its own that
    /// slides over the flesh (PhysicsSkin.swift; the character's).
    enum Skin: Int, CaseIterable, Codable {
        case embedded, sliding
        var title: String { ["Embedded", "Sliding"][rawValue] }
    }
    var skin = Skin.embedded
    var muscleGain: Float = 1
    /// What the character is drawn as: its skin, or its muscles (an écorché: MuscleAtlas.swift) on the same flesh.
    enum Body: Int, CaseIterable, Codable {
        case skin, muscles
        var title: String { ["Skin", "Muscles"][rawValue] }
    }
    var body = Body.skin
    /// The fluids scene (Scene+Fluids.swift): which liquids it pours, the solver each is stepped by (PhysicsFluid.swift),
    /// or one for all of them, and how many particles each pours at most. Honey by MPM (its viscosity is what MPM is
    /// for), water and blood by PBF: MPM's push on a body is weak in a thin liquid (a light box bobbed and sank in MPM
    /// water and blood; PBF's boundary density holds it up).
    enum Liquids: Int, CaseIterable, Codable {
        case all, water, blood, honey
        var title: String { ["All three", "Water", "Blood", "Honey"][rawValue] }
    }
    var liquids = Liquids.all
    enum Solver: Int, CaseIterable, Codable {
        case pbf, mpm
        var title: String { ["Position based (PBF)", "Material point (MLS-MPM)"][rawValue] }
    }
    enum Solvers: Int, CaseIterable, Codable {
        case auto, pbf, mpm
        var title: String { ["Each liquid's own", "PBF for all", "MPM for all"][rawValue] }
    }
    var solver = Solvers.auto
    var waterSolver = Solver.pbf
    var bloodSolver = Solver.pbf
    var honeySolver = Solver.mpm
    var fluidParticles = 32768

    static let substepRange = 1...32
    static let bodyRange = 0...4096
    static let particleRange = 0...16384
    static let clothRange = 0...96
    static let ragdollRange = 1...256
    static let hairRange = 1...32
    static let furBodyRange = 0...32
    static let softBodyRange = 1...128
    static let softCellRange = 3...12
    static let muscleRagdollRange = 0...12
    static let fleshCellRange: ClosedRange<Float> = 2...6
    static let muscleGainRange: ClosedRange<Float> = 0...2
    static let fluidRange = 1024...262144
    static let gpuFrom = 64

    /// Whether a world of `bodies` bodies and particles is stepped on the GPU.
    func runsOnGPU(bodies: Int) -> Bool { backend == .gpu || (backend == .auto && bodies >= PhysicsSettings.gpuFrom) }
}

/// Scene choice and the stress test's size. Changing it rebuilds the scene (geometry, acceleration structures).
struct SceneSettings: Equatable, Codable {
    var kind = SceneKind.cornell
    var objects = 400
    var lights = 32
    /// The crowd scene: how many characters, and how many poses the GPU animates for them each frame (Crowd).
    var characters = 2048
    var poses = 64
    /// ...and at which level of detail they are skinned and traced: 0 = the full mesh, each level half the one before.
    var detail = 3
    /// ...and who they are: the character library's (the Y and X Bots) or the character catalog's people, made from
    /// their DNA (CharacterBuilder).
    var crowdBodies = CrowdBodies.library
    var city = CitySettings()
    /// The showcase: which model of `Scene.galleryFiles()`, as a part of its file name (any case); "" = the first.
    var showcase = ""
    var extraModels: [ExtraModel] = []   // added with File > Open or drag and drop (cleared when the scene changes)
    /// Emissive surfaces are lights: sampled for direct light with shadow rays (and seen by GI through light maps).
    /// Off: they only light what GI rays happen to hit, as before.
    var emissiveLights = ProcessInfo.processInfo.environment["METALRENDERER_EMISSIVE_LIGHTS"] != "0"
    /// Benchmarks only (METALRENDERER_BENCH=lightcheck): one light, or its emissive-mesh twin, over a floor instead of `kind`.
    var lightCheck: String? = nil

    /// The forest: how many trees, and bushes, ferns and grass as a percentage of the usual; the seed of the plants
    /// (and of the forest's ground and where everything stands).
    var trees = 2500
    var undergrowth = 100
    var seed = 1
    /// The open world: the tile the scene is made around (nil: the one the world starts in). The renderer's to set, as
    /// the camera moves; not a preference.
    var worldTile: SIMD2<Int>? = nil
    /// ...and the tile whose corner is the scene's origin (nil: the first city's). It follows the camera from afar, so
    /// that the scene's coordinates stay small however far the camera has gone.
    var worldAnchor: SIMD2<Int>? = nil
    /// ...and whether its cities' lights are the scene's lights: the renderer's to set too, with the time of day
    /// (`World.lightsReady`). By day nothing samples them, and they are off.
    var worldLit = false
    /// Plants baked into meshes of their own instead of assemblies: no wind or leaf fall, and eight times the
    /// triangles (METALRENDERER_BENCH=forestcheck compares the two).
    var bakedPlants = false
    /// The trees' and bushes' leaves as cards: a few rectangles a bough, each showing a twig with its leaves, cut out
    /// by an alpha mask the ray queries test. Off: every leaf is a mesh of its own.
    var leafCards = false
    /// Far baked plants as their voxel grids (VoxelLOD) instead of their triangles. Off: it is slower wherever it was
    /// measured. In software (M1 Max) the ray queries a voxel box needs
    /// cost every ray about 30%; in hardware (M4 Max) each box a ray meets hands it back to the shader, and the
    /// forest takes 1.3 to 2.1 times as long, the open world 3 times.
    var voxelBoxes = false
    /// The physics scene: its bodies and how they are simulated.
    var physics = PhysicsSettings()
    /// The plant workshop: what it shows.
    var plants = PlantSceneSettings()
    /// The species the plants are grown from: a key of PlantCatalog's registry, which the plant editor sets as it
    /// edits; "" the saved species (Assets/Plants), "builtin" the built-in ones. Session state, not a preference.
    var plantCatalog = ""
    /// The building workshop: what it shows.
    var buildings = BuildingSceneSettings()
    /// The building styles and single buildings scenes are built with: a key of BuildingCatalog's registry, which the
    /// building editor sets as it edits; "" the saved ones (Assets/Buildings), "builtin" the built-in ones. Session state.
    var buildingCatalog = ""
    /// The character workshop: who it shows, and how.
    var characterWorkshop = CharacterSceneSettings()
    /// The characters scenes are made with: a key of CharacterCatalog's registry, which the character editor sets as it
    /// edits; "" the saved ones (Assets/CharacterDefs), "builtin" the built-in ones. Session state.
    var characterCatalog = ""
    /// The city's building whose interior the scene has (LotRef.key; nil: none): the renderer's to set, as the camera
    /// comes near a building and leaves it (Scene+Interiors.swift). Session state.
    var interior: String? = nil

    static let objectRange = 0...2000
    static let treeRange = 0...20000
    static let undergrowthRange = 0...200
    static let seedRange = 0...999
    static let lightRange = 1...16384
    static let characterRange = 1...131_072
    static let poseRange = 1...512
    static let detailRange = 0...CharacterLibrary.coarserLevels
    static let marketLights = 4096       // the night market's default bulb count

    /// The plant workshop both, showing the same species the same way (only the species' definitions and which of its
    /// plants differ): what an edit changes.
    func isSameWorkshop(as other: SceneSettings) -> Bool {
        if kind == .characters && other.kind == .characters {
            let a = characterWorkshop, b = other.characterWorkshop
            return a.layout == b.layout && a.pose == b.pose && a.clip == b.clip && a.view == b.view
        }
        if kind == .buildings && other.kind == .buildings {
            return buildings.layout == other.buildings.layout && buildings.style == other.buildings.style
                && buildings.pinned == other.buildings.pinned
        }
        return kind == .plants && other.kind == .plants && plants.layout == other.plants.layout && plants.view == other.plants.view
            && plants.species == other.plants.species && leafCards == other.leafCards && bakedPlants == other.bakedPlants
    }

    /// The same city, with another building's interior in it (or none): the same streets and buildings, where they
    /// were (Renderer: what the frames have gathered holds).
    func isSameCity(as other: SceneSettings) -> Bool {
        var a = self, b = other
        (a.interior, b.interior) = (nil, nil)
        return (kind.isCity || kind.isWorld) && a == b && interior != other.interior
    }

    /// The same open world, whatever tile the scene is made around, wherever its origin is and whatever the time of day.
    func isSameWorld(as other: SceneSettings) -> Bool {
        var a = self, b = other
        (a.worldTile, b.worldTile, a.worldAnchor, b.worldAnchor) = (nil, nil, nil, nil)
        (a.worldLit, b.worldLit) = (false, false)
        (a.interior, b.interior) = (nil, nil)
        return kind.isWorld && a == b
    }
}

/// The building workshop (Scene+Buildings.swift): which building it shows, and how.
struct BuildingSceneSettings: Equatable, Codable {
    /// The style's id (BuildingCatalog), the lot (its width across the front, its depth), what its sides look onto,
    /// its floors and seed.
    var style = "residential"
    var lot = SIMD2<Float>(20, 14)
    var sides = Sides.row
    var floors = 5
    var seed = 1
    var layout = Layout.single
    var view = View.full
    /// The cutaway's and the dollhouse's top storey (0: the ground floor).
    var cut = 1
    var night = false
    /// A single building of a city to show instead (the editor's Pin), nil: the workshop's own.
    var pinned: LotRef? = nil
    /// Registry keys (BuildingCatalog.register), session state: the editor's variations of the style to show beside it
    /// (layout `mutate`), and the definitions to show in its place (comparing with the saved ones). "" = none.
    var mutants = ""
    var compare = ""

    enum Sides: Int, CaseIterable, Codable {
        case row            // between neighbours, a yard behind
        case backToBack     // between neighbours, a neighbour behind too
        case corner         // a street in front and on its right
        case free           // streets and open ground all round
        var edges: [CityPlan.Edge] {
            switch self {
            case .row: return [.street, .party, .open, .party]
            case .backToBack: return [.street, .party, .party, .party]
            case .corner: return [.street, .street, .party, .party]
            case .free: return [.street, .open, .open, .street]
            }
        }
        var title: String { ["In a row", "Back to back", "On a corner", "Free-standing"][rawValue] }
    }
    enum Layout: Int, CaseIterable, Codable {
        case single         // the building on its lot
        case street         // between two neighbours of its style
        case mutate         // it and the editor's variations of it, along a street
        var title: String { ["One building", "In its street", "Variations"][rawValue] }
    }
    enum View: Int, CaseIterable, Codable {
        case full
        case cutaway        // no roof and nothing above storey `cut`
        case dollhouse      // ...and no front wall up to it either
        var title: String { ["Whole", "Cutaway", "Dollhouse"][rawValue] }
    }

    static let floorRange = 1...40
    static let widthRange: ClosedRange<Float> = 6...48
    static let depthRange: ClosedRange<Float> = 8...48
}

/// Who the crowd scene's characters are.
enum CrowdBodies: Int, CaseIterable, Codable {
    case library        // Assets/Characters: the Mixamo mannequins
    case generated      // the character catalog's people (CharacterCatalog, CharacterBuilder)
    var title: String { ["Mannequins", "Generated people"][rawValue] }
}

/// The character workshop (Scene+Characters.swift): who it shows, in what pose, and how.
struct CharacterSceneSettings: Equatable, Codable {
    /// The character's id (CharacterCatalog).
    var character = "man"
    var layout = Layout.single
    var pose = Pose.aPose
    /// Pose `clip`: the clip's name (any clip of the character library).
    var clip = ""
    var view = View.body
    /// What the faces do (blinks always), and whether their eyes follow the camera.
    var expression = FaceExpression.neutral
    var lookAt = true
    /// Registry keys (CharacterCatalog.register), session state: the editor's variations of the character to show
    /// beside it (layout `mutate`), and the definitions to show in its place (comparing with the saved ones). "" = none.
    var mutants = ""
    var compare = ""

    enum Layout: Int, CaseIterable, Codable {
        case single         // the character
        case lineup         // every character of the catalog, side by side
        case mutate         // the character and the editor's variations of it, in a row
        var title: String { ["One character", "Everyone", "Variations"][rawValue] }
    }
    enum Pose: Int, CaseIterable, Codable {
        case tPose, aPose, idle, walk, clip
        var title: String { ["T pose", "A pose", "Idle", "Walking", "Clip"][rawValue] }
        /// The clip it plays (CharacterKit's names), for every pose but `clip`.
        var clipName: String? { [Optional("T-Pose"), "A-Pose", "Idle", "Walking", nil][rawValue] }
    }
    enum View: Int, CaseIterable, Codable {
        case body           // the whole character
        case face           // its head, close
        var title: String { ["Body", "Face"][rawValue] }
    }
}

/// The plant workshop (Scene+Plants.swift): which plants it shows, and how.
struct PlantSceneSettings: Equatable, Codable {
    /// The species' id (PlantCatalog), and the age and seeded variant of the one plant shown.
    var species = "oak"
    var age = Foliage.Age.mature
    var variant = 0
    /// What the variants are grown from: the library's seed (SceneSettings.seed), so the workshop's oak 2 at seed 1 is
    /// the forest's.
    var seed = 1
    var layout = Layout.single
    var view = View.plant
    /// Registry keys (PlantCatalog.register), session state: the editor's variations of the species to show beside it
    /// (layout `mutate`), and the definition to show in its place (comparing with the saved one). "" = none.
    var mutants = ""
    var compare = ""

    enum Layout: Int, CaseIterable, Codable {
        case single         // the one plant
        case lineup         // every age (rows) and variant (columns)
        case mutate         // the plant and the editor's variations of it, in a row

        var title: String { ["One plant", "Ages and variants", "Variations"][rawValue] }
    }
    enum View: Int, CaseIterable, Codable {
        case plant
        case skeleton       // the stems as thin lines, a colour to a level; no leaves

        var title: String { ["Plant", "Skeleton"][rawValue] }
    }

    static let variantRange = 0...7
}

/// Virtual geometry: big glTF meshes as streamed cluster DAGs with a per-frame level-of-detail cut.
struct VirtualGeometrySettings: Equatable, Codable {
    var enabled = ProcessInfo.processInfo.environment["METALRENDERER_VG"] != "0"
    var pixelError: Float = Float(ProcessInfo.processInfo.environment["METALRENDERER_VG_TAU"] ?? "") ?? 1   // traced pixels
    var poolMB = Int(ProcessInfo.processInfo.environment["METALRENDERER_VG_POOL"] ?? "") ?? 768
    /// How the raster visibility buffer draws it (with the per-instance BLAS; the cluster tree's mode traces it).
    var raster = RasterVirtual(envText: ProcessInfo.processInfo.environment["METALRENDERER_RASTER_VG"] ?? "") ?? .blas
    /// The raster clusters' own streaming pool (the rays keep the BLAS): 512 MB holds what the gallery's shadow maps and
    /// camera ask for (about 390 MB settled).
    var rasterPoolMB = Int(ProcessInfo.processInfo.environment["METALRENDERER_RASTER_VG_POOL"] ?? "") ?? 512
    /// Keep choosing detail for the camera position at the moment this was turned on (debugging: fly up to a model
    /// to see the cut it got from far away).
    var freeze = false

    static let pixelErrorRange: ClosedRange<Float> = 0.25...8
    static let poolOptions = [256, 512, 768, 1024, 2048]
    static let rasterPoolOptions = [128, 256, 512, 768]
}

/// How the raster visibility buffer draws virtual geometry: the triangles of its instance's BLAS over the CPU's cut,
/// 128 at a time and culled by instance only; or Nanite's way, clusters of the DAG picked, culled and streamed on the GPU
/// every frame (RasterClusters), drawn by vertex pulling or by mesh shaders.
enum RasterVirtual: Int, CaseIterable, Codable {
    case blas
    case clusters
    case mesh

    var title: String { ["BLAS triangles", "Clusters", "Clusters (mesh shaders)"][rawValue] }
    var drawsClusters: Bool { self != .blas }
}

/// Volumetric fog (Shaders/Fog.metal): exponential height fog with drifting noise, plus the scene's
/// local fog volumes. Each scene kind has a preset (`preset(for:)`); the volumes themselves come with the scene.
struct FogSettings: Equatable, Codable {
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
    var maxDistance: Float = 40         // the froxel grid's far end (view depth); beyond, no more fog accumulates...
    var haze: Float = 0                 // ...but the height fog at this share of its density, as far as the eye sees (0 = none)
    var volumes = true                  // the scene's local fog volumes
    var reflections = true              // fog along reflection rays (one more shadow ray per reflection)
    var lights = true                   // the scene's lights scatter in it; off: only the sun (or the moon) and the sky

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

    /// The fog that suits scene `kind`: off in the Cornell room, stress test, gallery and studio.
    static func preset(for kind: SceneKind) -> FogSettings {
        var f = FogSettings()
        switch kind {
        case .cornell, .stress, .gallery, .area, .crowd, .cityNight, .shapes, .physics, .ragdolls, .hair, .softBodies, .muscles, .fluids,
             .plants, .buildings, .characters:   // at night: thousands of lit windows scatter in blotches
            break
        case .city:
            // Haze: the far end of an avenue fades toward the sky.
            f.enabled = true; f.density = 0.0012; f.heightFalloff = 0.01; f.anisotropy = 0.5; f.noise = 0.15
            f.maxDistance = 150
        case .market:
            f.enabled = true; f.density = 0.012; f.heightFalloff = 0.08; f.anisotropy = 0.4; f.ambient = 0.5; f.maxDistance = 60
        case .valley:
            f.enabled = true; f.density = 0.0015; f.heightFalloff = 0.02; f.anisotropy = 0.5; f.noise = 0.2
            f.maxDistance = 150
        case .forest:
            f.enabled = true; f.density = 0.004; f.heightFalloff = 0.03; f.anisotropy = 0.7; f.noise = 0.3
            f.maxDistance = 150
        case .world:
            // The noise's tile divides the tiles' 256 m, so the fog stays as it is when the scene's origin moves.
            f.enabled = true; f.density = 0.002; f.heightFalloff = 0.012; f.anisotropy = 0.6; f.noise = 0.2; f.noiseScale = 8
            f.maxDistance = 150; f.haze = 0.4
            // At night a froxel's one sample among a city's thousands of lamps and windows scatters in blotches.
            f.lights = false
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
        case .showcase:   // the base every model's look tunes (ShowcaseLook.fog)
            f.enabled = true; f.density = 0.03; f.heightFalloff = 0.15; f.anisotropy = 0.65; f.ambient = 0.15; f.noise = 0.5
            f.noiseScale = 4; f.wind = [0.15, 0.04, 0.08]; f.maxDistance = 30
        }
        if let override { f.enabled = override }
        return f
    }

    /// The fog that suits `scene`: its kind's, and in the showcase the model's look on top.
    static func preset(for scene: SceneSettings) -> FogSettings {
        var f = preset(for: scene.kind)
        if scene.kind == .showcase { ShowcaseLook.look(for: scene.showcase).fog(&f) }
        return f
    }
}

/// Where the sky comes from (Shaders/Sky.metal).
enum SkyMode: Int, CaseIterable, Codable {
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
struct SkySettings: Equatable, Codable {
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
    static let cloudThicknessRange: ClosedRange<Float> = 200...4000
    static let cloudScaleRange: ClosedRange<Float> = 500...16000
    static let mapSize = 1024           // sky texture side, per hemisphere
    static let shadowMapSize = 256
    /// `METALRENDERER_SKY=constant|atmosphere|<image path>` overrides every preset's mode.
    static let override: String? = ProcessInfo.processInfo.environment["METALRENDERER_SKY"]

    /// The sky that suits scene `kind`: the atmosphere for the outdoor and window-lit scenes, a constant colour inside.
    /// ...and for the scene's own settings: the building workshop at night has the city's night sky.
    static func preset(for scene: SceneSettings) -> SkySettings {
        var s = preset(for: scene.kind)
        if scene.kind == .buildings && scene.buildings.night { s = preset(for: .cityNight) }
        return s
    }

    static func preset(for kind: SceneKind) -> SkySettings {
        var s = SkySettings()
        switch kind {
        case .cornell, .stress, .gallery, .spots, .area, .tubes, .emissive, .fog, .market, .cityNight, .showcase, .shapes, .physics, .ragdolls, .hair,
             .softBodies, .muscles, .fluids:
            break
        case .sun:
            s.mode = .atmosphere; s.coverage = 0.35; s.cloudBase = 1200; s.cloudThickness = 1200; s.cloudScale = 2500
        case .mixed:
            s.mode = .atmosphere; s.coverage = 0.25; s.shadows = false   // the sun is low: clouds near the horizon
        case .crowd:
            s.mode = .atmosphere; s.coverage = 0.3; s.cloudBase = 1200; s.cloudThickness = 1000; s.cloudScale = 2500
        case .city:
            s.mode = .atmosphere; s.coverage = 0.3; s.cloudBase = 1400; s.cloudThickness = 1200; s.cloudScale = 3000
            s.shadowStrength = 0.6
        case .valley:
            // Small, low clouds (a stylised scale), so their shadows visibly cross the 400 m valley.
            s.mode = .atmosphere; s.coverage = 0.4; s.cloudBase = 700; s.cloudThickness = 800; s.cloudScale = 800
            s.density = 0.04; s.windSpeed = 14; s.shadowStrength = 0.7
        case .forest:
            s.mode = .atmosphere; s.coverage = 0.3; s.cloudBase = 900; s.cloudThickness = 900; s.cloudScale = 1400
            s.density = 0.04; s.windSpeed = 8; s.shadowStrength = 0.6
        case .world:
            s.mode = .atmosphere; s.coverage = 0.3; s.cloudBase = 1300; s.cloudThickness = 1100; s.cloudScale = 2800
            s.density = 0.04; s.windSpeed = 10; s.shadowStrength = 0.6
        case .plants, .buildings, .characters:   // a few high clouds, no shadows of them: the plant is what is looked at
            s.mode = .atmosphere; s.coverage = 0.15; s.cloudBase = 1500; s.cloudThickness = 900; s.cloudScale = 2500; s.shadows = false
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

/// The camera's lens and the image's finish (Shaders/Post.metal), on the light at the output resolution before and
/// after the tone curve: depth of field, bloom, chromatic aberration, vignette and film grain. Each is off at 0, and
/// all are off but in the showcase (`preset(for:)`), so the other scenes' frames are what they were.
struct PostSettings: Equatable, Codable {
    var bloom: Float = 0                // the share of the light spread out as glow (0 = no bloom)
    var bloomThreshold: Float = 1       // the brightness (after exposure) where glow starts, with a soft knee below it
    var aperture: Float = 0             // the blur circle's radius in output pixels far behind the focus (as much at half
                                        // the focus distance, more nearer, at most `maxBlur`); 0 = no depth of field
    var focus: Float = 0                // focus distance (m); 0 = autofocus on what is at the centre of the frame
    var vignette: Float = 0             // how much the corners darken
    var grain: Float = 0                // film grain's strength
    var aberration: Float = 0           // chromatic aberration: red and blue apart by this share of the width at the corners

    var isOn: Bool { bloom > 0 || aperture > 0 || vignette > 0 || grain > 0 || aberration > 0 }

    static let bloomRange: ClosedRange<Float> = 0...0.3
    static let thresholdRange: ClosedRange<Float> = 0...8
    static let apertureRange: ClosedRange<Float> = 0...24
    static let focusRange: ClosedRange<Float> = 0...30
    static let vignetteRange: ClosedRange<Float> = 0...1
    static let grainRange: ClosedRange<Float> = 0...0.2
    static let aberrationRange: ClosedRange<Float> = 0...0.01
    static let maxBlur: Float = 24      // the depth of field's widest blur circle (output pixels)
    static let bloomLevels = 6          // the glow's halvings, from half the output size

    /// Off, but in the showcase: the model's look.
    static func preset(for scene: SceneSettings) -> PostSettings {
        scene.kind == .showcase ? ShowcaseLook.look(for: scene.showcase).post : PostSettings()
    }
}

/// How frames reach the GPU. Changing it recompiles the shaders and rebuilds the scene's structures.
enum RenderAPI: Int, CaseIterable, Codable {
    case metal3             // MTLCommandQueue, one compute encoder per frame
    case metal4             // Metal 4: MTL4CommandQueue, argument tables, residency sets (macOS 26; Capabilities.metal4)

    var title: String { self == .metal3 ? "Metal 3" : "Metal 4" }

    /// `METALRENDERER_API=metal4|metal3` picks the starting API (benchmarks: for every setting).
    static let initial: RenderAPI = ProcessInfo.processInfo.environment["METALRENDERER_API"] == "metal4" ? .metal4 : .metal3
}

/// Everything the settings panel and the keyboard shortcuts can change.
/// Generated plants (the forest, the valley's trees). The wind turns their limbs and boughs about bones (plants as
/// assemblies; baked plants stand still).
struct FoliageSettings: Equatable, Codable {
    var wind: Float = 0                 // 0 = still ... 1 = a strong wind
    var windDirection: Float = 25       // where it blows to, degrees from +x toward +z
    var gusts: Float = 0.7              // 0 = steady ... 1 = it comes in waves
    /// Far plants are traced as voxels (FoliageVoxels) from where a voxel is this many traced pixels: 0 = never.
    /// At 2 the forest's far trees change over about 90 m out, where they cost less as voxels than as triangles.
    var lod: Float = 2
    /// How far from the camera the plants' limbs move in the wind, in metres (0 = everywhere). Farther plants still lean
    /// as a whole; their limbs' structures stand at rest and aren't refitted every frame. At 20 m the moving forest is
    /// 7-16% faster than with every limb moving (M1 Max, Metal 3); from above, where every crown is farther, only whole trees lean.
    var swayReach: Float = 20
    /// The time of year: 0 = spring, 0.3 = summer, 0.5...0.8 = the leaves turn and fall, 1 = winter.
    var season: Float = 0.3
    /// How much of the light leaves let through, as a share of each species' own: 0 = opaque leaves.
    var translucency: Float = 1

    static let windRange: ClosedRange<Float> = 0...1
    static let directionRange: ClosedRange<Float> = -180...180
    static let gustRange: ClosedRange<Float> = 0...1
    static let lodRange: ClosedRange<Float> = 0...4
    static let swayRange: ClosedRange<Float> = 0...200
    static let seasonRange: ClosedRange<Float> = 0...1
    static let translucencyRange: ClosedRange<Float> = 0...1

    /// A breeze where there are plants.
    static func preset(for kind: SceneKind) -> FoliageSettings {
        var f = FoliageSettings()
        if kind.hasPlants { f.wind = 0.4 }
        if kind == .plants { f.lod = 0 }   // the workshop's plants are never voxels
        return f
    }
}

struct RenderSettings: Equatable, Codable {
    var renderScale: CGFloat = 0.5     // traced resolution, as a fraction of the window's size in points
    var upscaleFactor: CGFloat = 3     // output / traced resolution, through MetalFX's denoising scaler; 0 = off
    var giEnabled = true
    var bounces = 2
    var blueNoise = true               // stratified samples steady the shadow denoiser's history clamp (less flicker)
    var paused = false
    var viewMode = 0
    var reference = ReferenceSettings()   // a converged picture instead of the realtime one (session state: off at launch)
    var denoiser = DenoiserSettings()
    var giMode = GIMode.radianceCascades   // ~45% cheaper than path tracing here, ~11 dB closer to an 8-bounce reference, no flicker
    var lightMaps = false              // path tracer: light bounce hits from per-light shadow maps instead of shadow rays
    var directLight = DirectLightMode.initial
    var restir = RestirSettings()
    var megaLights = MegaLightsSettings()
    var restirGI = RestirGISettings()
    var manyLightRays = 1              // more than 4 lights: shadow rays per light group (2 = less noise and flicker, slower)
    var manyLightReuse = 4             // more than 4 lights, 1 ray: reuse light picks for up to this many frames (0 = off):
                                       // a third less flicker on still frames for ~0.7 ms and ~0.7 dB (manyLightsReuseKernel)
    var cascades = CascadeSettings()
    var lumen = LumenSettings()
    var scene = SceneSettings()
    var api = RenderAPI.initial
    var primary = PrimaryVisibility.initial
    var shadowMethod = ShadowMethod.initial
    var vsm = VSMSettings()
    var virtualGeometry = VirtualGeometrySettings()
    var specular = ProcessInfo.processInfo.environment["METALRENDERER_SPECULAR"] != "0"   // GGX specular for glTF materials
    var textureBudgetMB = Int(ProcessInfo.processInfo.environment["METALRENDERER_TEXTURE_BUDGET"] ?? "") ?? 1024   // streamed textures
    var fog = FogSettings.preset(for: .cornell)
    var sky = SkySettings.preset(for: .cornell)
    var foliage = FoliageSettings.preset(for: .cornell)
    var post = PostSettings()
    // Camera and animation
    var exposure: Float = 0            // stops (EV) before the tone curve
    var toneMap = ToneMap.aces
    var fovDegrees: Float = 60         // vertical field of view
    var moveSpeed: Float = 2.5         // WASD, m/s (Shift: 3.2x)
    var timeScale: Float = 1           // animation speed (Pause stops it too)
    var timeOfDay: Float = 0           // scenes with a day cycle: offset into it, as a fraction of it

    /// The physics scene's traced resolution (`usePhysicsLook`).
    static let physicsScale: CGFloat = 0.375

    /// The physics scene's look, which leaves the GPU to the simulation: no GI and no reflections, traced at 0.375 of
    /// the window (3x upscaled, 1440x900 out). On the M1 Max its frame renders in 5 ms against the app look's 15
    /// (reflections 4.7 ms, cascades 2.9, and the smaller frame halves the trace and the upscaler). The panel can turn
    /// either back on.
    mutating func usePhysicsLook() {
        giEnabled = false
        specular = false
        renderScale = RenderSettings.physicsScale
    }

    /// Applies the defaults that suit `scene.kind` (the settings panel calls this when the scene changes and on
    /// Reset to Defaults): the GI method, the night market's light count, the fog, the sky and the lens (the showcase's
    /// model brings its own fog and lens), and the physics scene's look (leaving it, the defaults again).
    mutating func applySceneDefaults(from defaults: RenderSettings) {
        giMode = defaults.giMode
        if scene.kind.simulates {
            usePhysicsLook()
        } else if !giEnabled && !specular && renderScale == RenderSettings.physicsScale {
            giEnabled = defaults.giEnabled
            specular = defaults.specular
            renderScale = defaults.renderScale
        }
        if scene.kind == .market && scene.lights == SceneSettings().lights { scene.lights = SceneSettings.marketLights }
        fog = FogSettings.preset(for: scene)
        post = PostSettings.preset(for: scene)
        foliage = FoliageSettings.preset(for: scene.kind)
        let image = sky.mode == .image ? sky : nil   // an image the user opened stays
        sky = SkySettings.preset(for: scene)
        if let image { sky.mode = .image; sky.imagePath = image.imagePath; sky.imageExposure = image.imageExposure }
    }

    static let exposureRange: ClosedRange<Float> = -4...4
    static let fovRange: ClosedRange<Float> = 30...110
    static let moveSpeedRange: ClosedRange<Float> = 0.5...100
    static let timeScaleRange: ClosedRange<Float> = 0...4
    static let manyLightReuseRange = 0...8
    static let textureBudgetOptions = [256, 512, 1024, 2048, 4096]
    static let renderScaleRange: ClosedRange<CGFloat> = 0.25...2.0
    static let renderScaleStep: CGFloat = 0.125
    static let bounceRange = 1...8
    static let viewModes = ["Final", "Raw direct", "Raw indirect", "Normals", "Albedo", "History length",
                            "Indirect only", "GI debug",
                            "Triangles", "Clusters", "Groups", "LOD level", "Triangle size", "Traversal cost",
                            "Fog scattering", "Visibility buffer", "Virtual shadow pages"]
    /// The raster visibility buffer's chunks (rasterDebugKernel), with the primary visibility on raster.
    static let visibilityBufferView = 15
    /// The virtual shadow maps' pages (vsmDebugKernel), with the shadows through virtual shadow maps.
    static let shadowPagesView = 16
    /// Whether view mode `mode` shows the light (tone mapped, with the lens effects) rather than a value to read as it
    /// is (normals, albedo, the geometry views, the visibility buffer's and the shadow pages' colours...): viewIsHDR in
    /// Shaders/Output.metal.
    static func showsLight(_ mode: Int) -> Bool {
        ![3, 4, 5].contains(mode) && !(7...13).contains(mode) && ![visibilityBufferView, shadowPagesView].contains(mode)
    }
    /// The geometry debug views (geometryDebugKernel): triangles, virtual-geometry clusters / groups / DAG levels,
    /// projected triangle size, and the primary rays' traversal cost.
    static let geometryViews = 8...13
}
