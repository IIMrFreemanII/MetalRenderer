import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Headless-ish benchmark mode, enabled with `METALRENDERER_BENCH=1 swift run -c release`.
///
/// Runs a fixed list of render settings with a deterministic animation clock, times every GPU
/// pass (each pass goes into its own command buffer so `gpuStartTime`/`gpuEndTime` isolate it),
/// prints a table and quits. Set `METALRENDERER_BENCH_DIR=<folder>` to also save a PNG per setting.
final class Benchmark {
    struct Config {
        var name: String
        var renderScale: CGFloat = 0.75
        var giEnabled = true
        var bounces = 2
        var denoiseEnabled = true
        var upscale: CGFloat = 0      // MetalFX factor, 0 = off
        var upscaler = UpscalerKind.custom   // the app default
        var viewMode = 0
        var blueNoise = true          // the app default (the shadow denoiser's history clamp relies on it)
        var paused = false            // freeze the animation at startTime
        var startTime: Float = 0
        var accumulate = false        // reference image: average raw frames instead of denoising
        var frames: Int? = nil        // measured frames, if not the default
        var capturePrevious = false   // also save the second-to-last frame (for frame-to-frame flicker)
        var denoiser = DenoiserSettings()
        var giMode = GIMode.pathTraced   // benchmark settings path trace unless they say otherwise (the app default is cascades)
        var lightMaps = false
        var surfels = SurfelSettings()
        var cascades = CascadeSettings()
        var cameraPath = false        // fly the camera along cameraPose(progress:), ending at the default pose
        var supersample = false       // with accumulate: jitter every frame and average the final colour (anti-aliased reference)
        var scene = SceneSettings()
        var rayTracer: RayTracerKind? = nil   // nil = METALRENDERER_RT / the default
        var virtualGeometry: VirtualGeometrySettings? = nil   // nil = the default (METALRENDERER_VG...)
        var camera: Camera? = nil                             // fixed camera instead of the scene's default
        var fog: FogSettings? = nil                           // nil = the scene's preset (FogSettings.preset)
        var sky: SkySettings? = nil                           // nil = the scene's preset (SkySettings.preset)
    }

    /// Close to the gallery's owl and its neighbours, looking down at the floor's reflections.
    static let galleryCloseup: Camera = {
        var c = Camera()
        c.position = [1.6, 1.35, -1.6]
        c.yaw = 0.62
        c.pitch = -0.22
        return c
    }()

    /// Scripted camera move for the "camera" settings: a yaw sweep plus dolly that ends at the default camera,
    /// still moving, so the last frame can be scored against the same t = 5 s references as the static frames.
    static func cameraPose(progress p: Float, scene: SceneKind = .cornell) -> Camera {
        var c = Camera(), start = Camera()
        if scene == .gallery {
            // From close to the left models, gliding back to the gallery overview.
            c = Scene.galleryCamera
            start.position = SIMD3<Float>(-3.2, 1.5, 0.2)
            start.yaw = -0.7
            start.pitch = -0.05
        } else if scene == .stress {
            // Low over the floor on the right, sweeping up to the overview.
            c = Scene.stressCamera
            start.position = SIMD3<Float>(7.0, 2.2, 12.0)
            start.yaw = -0.6
            start.pitch = -0.1
        } else if let demo = Scene.demoCamera(scene) {
            // A step to the side and back, turning toward the default view.
            c = demo
            start.position = demo.position + SIMD3<Float>(1.5, 0.3, 1.5)
            start.yaw = demo.yaw + 0.35
            start.pitch = demo.pitch - 0.05
        } else {
            start.position = SIMD3<Float>(2.6, 1.7, 2.2)
            start.yaw = -0.9
            start.pitch = -0.25
        }
        if ProcessInfo.processInfo.environment["METALRENDERER_PAN"] == "rotate" { start.position = c.position; start.pitch = c.pitch }   // yaw only
        c.position = start.position + (c.position - start.position) * p
        c.yaw = start.yaw + (c.yaw - start.yaw) * p
        c.pitch = start.pitch + (c.pitch - start.pitch) * p
        return c
    }

    /// Progress through the current setting, 0 at its first frame and 1 at its last.
    var progressInConfig: Float {
        let total = warmupFrames + (current.frames ?? measuredFrames)
        return Float(frameInConfig) / Float(max(total - 1, 1))
    }

    /// `METALRENDERER_GI="mode=surfels,rays=8,..."` overrides GI settings in every (non-reference) setting.
    /// Keys: mode (pt|surfels|cascades), lightmaps, bounces, rays, maxsurfels, radius, shistory, sdenoise,
    /// spacing, cascades, b1, feedback, cdenoise, blue (blue-noise sampling), scale (render scale), factor (upscale factor),
    /// upscaler (metalfx|spatial|custom), lightrays (shadow rays per light group with more than 4 lights),
    /// taauhistory, taauclip.
    static func applyGIOverride(to s: inout RenderSettings) {
        guard let spec = ProcessInfo.processInfo.environment["METALRENDERER_GI"] else { return }
        for item in spec.split(separator: ",") {
            let kv = item.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            let v = Float(kv[1]) ?? 0
            switch kv[0] {
            case "mode": s.giMode = ["pt": .pathTraced, "surfels": .surfels, "cascades": .radianceCascades][kv[1]] ?? s.giMode
            case "lightmaps": s.lightMaps = v != 0
            case "lightrays": s.manyLightRays = Int(v)
            case "lightreuse": s.manyLightReuse = Int(v)
            case "bounces": s.bounces = Int(v)
            case "rays": s.surfels.raysPerSurfel = Int(v)
            case "maxsurfels": s.surfels.maxSurfels = Int(v)
            case "radius": s.surfels.radiusPixels = v
            case "shistory": s.surfels.maxHistory = v
            case "sdenoise": s.surfels.denoiseIndirect = v != 0
            case "spacing": s.cascades.probeSpacing = Int(v)
            case "cascades": s.cascades.cascades = Int(v)
            case "b1": s.cascades.firstInterval = v
            case "feedback": s.cascades.feedback = v != 0
            case "cdenoise": s.cascades.denoiseIndirect = v != 0
            case "blue": s.blueNoise = v != 0
            case "scale": s.renderScale = CGFloat(v)
            case "factor": s.upscaleFactor = CGFloat(v)
            case "upscaler": s.upscaler = ["metalfx": .metalFX, "spatial": .metalFXSpatial, "custom": .custom][kv[1]] ?? s.upscaler
            case "taauhistory": s.taau.maxHistory = v
            case "taauclip": s.taau.clipWidth = v
            case "taaumotion": s.taau.motionCut = v
            case "taaucut": s.taau.clipCut = v
            case "taaukernel": s.taau.kernelSharpness = v
            case "taaukernelmv": s.taau.kernelSharpnessMoving = v
            case "taaudilate": s.taau.dilationRadius = v
            case "taaulanczos": s.taau.lanczosHistory = v != 0
            case "taaulzthresh": s.taau.lanczosThreshold = v
            case "taauedge": s.taau.edgeMotionCut = v
            default: print("METALRENDERER_GI: unknown key \(kv[0])")
            }
        }
    }

    /// `METALRENDERER_SCENE="stress,objects=400,lights=32"` loads the stress scene (with these sizes) in every setting
    /// (and is the app's starting scene outside benchmarks). Kinds: cornell, stress, gallery, and the light demos spots,
    /// sun, area, tubes, emissive, mixed; `model=<path>` adds a glTF model as File > Open does; `emissivelights=0`
    /// turns emissive-mesh lights off.
    /// `METALRENDERER_FOG_SET="density=0.03,g=0.6,..."` overrides fog settings in every setting (after `METALRENDERER_FOG=0/1`).
    /// Keys: on, density, falloff, base, g, ambient, noise, tile, far, volumes, reflections.
    static func applyFogOverride(to f: inout FogSettings) {
        guard let spec = ProcessInfo.processInfo.environment["METALRENDERER_FOG_SET"] else { return }
        for item in spec.split(separator: ",") {
            let kv = item.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let v = Float(kv[1]) else { continue }
            switch kv[0] {
            case "on": f.enabled = v != 0
            case "density": f.density = v
            case "falloff": f.heightFalloff = v
            case "base": f.baseHeight = v
            case "g": f.anisotropy = v
            case "ambient": f.ambient = v
            case "noise": f.noise = v
            case "tile": f.noiseScale = v
            case "far": f.maxDistance = v
            case "volumes": f.volumes = v != 0
            case "reflections": f.reflections = v != 0
            default: break
            }
        }
    }

    /// `METALRENDERER_SKY_SET="coverage=0.6,clouds=0,..."` overrides sky settings in every setting (after `METALRENDERER_SKY`).
    /// Keys: clouds, coverage, density, base, thickness, scale, erosion, wind, winddir, shadows, strength, exposure, over.
    static func applySkyOverride(to s: inout SkySettings) {
        guard let spec = ProcessInfo.processInfo.environment["METALRENDERER_SKY_SET"] else { return }
        for item in spec.split(separator: ",") {
            let kv = item.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let v = Float(kv[1]) else { continue }
            switch kv[0] {
            case "clouds": s.clouds = v != 0
            case "coverage": s.coverage = v
            case "density": s.density = v
            case "base": s.cloudBase = v
            case "thickness": s.cloudThickness = v
            case "scale": s.cloudScale = v
            case "erosion": s.erosion = v
            case "wind": s.windSpeed = v
            case "winddir": s.windDirection = v
            case "shadows": s.shadows = v != 0
            case "strength": s.shadowStrength = v
            case "exposure": s.imageExposure = v
            case "over": s.cloudsOverImage = v != 0
            default: break
            }
        }
    }

    static func applySceneOverride(to s: inout SceneSettings) {
        guard let spec = ProcessInfo.processInfo.environment["METALRENDERER_SCENE"] else { return }
        for item in spec.split(separator: ",") {
            let kv = item.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            switch kv[0] {
            case "stress": s.kind = .stress
            case "cornell": s.kind = .cornell
            case "gallery": s.kind = .gallery
            case "spots": s.kind = .spots
            case "sun": s.kind = .sun
            case "area": s.kind = .area
            case "tubes": s.kind = .tubes
            case "emissive": s.kind = .emissive
            case "mixed": s.kind = .mixed
            case "fog": s.kind = .fog
            case "valley": s.kind = .valley
            case "emissivelights" where kv.count == 2: s.emissiveLights = kv[1] != "0"
            case "check" where kv.count == 2: s.lightCheck = kv[1]   // Scene.buildLightCheck; "empty" = just the floor
            case "objects" where kv.count == 2: s.objects = Int(kv[1]) ?? s.objects
            case "lights" where kv.count == 2: s.lights = Int(kv[1]) ?? s.lights
            case "model" where kv.count == 2:   // as if opened: in front of the default camera
                s.extraModels.append(ExtraModel(path: kv[1], position: [Float(s.extraModels.count) * 1.8 - 0.9, 0, 2], yaw: 0))
            default: print("METALRENDERER_SCENE: unknown key \(kv[0])")
            }
        }
    }

    /// `METALRENDERER_DENOISE="passes=3,tpasses=2,sigma=1,history=16,antilag=1,separate=1"` overrides the denoiser in every setting,
    /// so parameter sweeps need no rebuild.
    static func applyDenoiserOverride(to d: inout DenoiserSettings) {
        guard let spec = ProcessInfo.processInfo.environment["METALRENDERER_DENOISE"] else { return }
        for item in spec.split(separator: ",") {
            let kv = item.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let v = Float(kv[1]) else { continue }
            switch kv[0] {
            case "passes": d.atrousPasses = Int(v)
            case "tpasses": d.techniquePasses = Int(v)
            case "sigma": d.luminanceSigma = v
            case "history": d.maxHistory = v
            case "antilag": d.antiLag = v
            case "separate": d.separateSignals = v != 0
            case "shadows": d.shadowDenoiser = v != 0
            case "spasses": d.shadowPasses = Int(v)
            case "shistory": d.shadowHistory = v
            case "sclamp": d.shadowClamp = v
            case "ssigma": d.shadowSigma = v
            default: print("METALRENDERER_DENOISE: unknown key \(kv[0])")
            }
        }
    }

    struct FrameRecord {
        var config: Int
        var passMs: [String: Double]
        var spanMs: Double          // first pass start -> last pass end
    }

    static let isEnabled = ProcessInfo.processInfo.environment["METALRENDERER_BENCH"] != nil
    /// Each pass in its own command buffer, for per-pass timings (default). `METALRENDERER_BENCH_SPLIT=0` encodes frames
    /// exactly like normal mode (one command buffer) and reports only the whole-frame GPU time.
    static let splitPasses = ProcessInfo.processInfo.environment["METALRENDERER_BENCH_SPLIT"] != "0"
    static let passOrder = ["tlas", "lightmap", "trace", "temporal", "atrous", "composite", "upscale"]

    /// `METALRENDERER_BENCH=quality` renders the same frames natively and upscaled (with PNGs) for image comparisons.
    /// `METALRENDERER_BENCH=noise` renders white- and blue-noise sampling next to converged references, all at t = 5 s.
    /// `METALRENDERER_BENCH=denoise` renders a few frames for scoring denoiser changes against saved `noise` references.
    /// `METALRENDERER_BENCH_ONLY="32 lights, 400|camera"` keeps only the settings whose names contain one of these substrings.
    let configs: [Config] = {
        let all = Benchmark.configs(for: ProcessInfo.processInfo.environment["METALRENDERER_BENCH"] ?? "")
        guard let only = ProcessInfo.processInfo.environment["METALRENDERER_BENCH_ONLY"] else { return all }
        let keys = only.split(separator: "|").map(String.init)
        return all.filter { c in keys.contains { c.name.contains($0) } }
    }()

    /// GI modes compared by `METALRENDERER_BENCH=gi` (`METALRENDERER_GI_MODES="pt,surfels"` picks a subset).
    private static let giModesUnderTest: [(tag: String, base: Config)] = {
        var pt = Config(name: "", renderScale: 0.5)
        var ptLM = pt; ptLM.lightMaps = true
        var surfels = pt; surfels.giMode = .surfels
        var cascades = pt; cascades.giMode = .radianceCascades
        var cascadesHQ = cascades; cascadesHQ.cascades.probeSpacing = 4; cascadesHQ.cascades.firstInterval = 0.25
        pt.name = "pt"; ptLM.name = "pt-lightmaps"; surfels.name = "surfels"; cascades.name = "cascades"; cascadesHQ.name = "cascades-hq"
        let all = [pt, ptLM, surfels, cascades, cascadesHQ].map { (tag: $0.name, base: $0) }
        guard let pick = ProcessInfo.processInfo.environment["METALRENDERER_GI_MODES"] else { return all }
        let tags = Set(pick.split(separator: ",").map(String.init))
        return all.filter { tags.contains($0.tag) }
    }()

    private static func giConfigs() -> [Config] {
        // 8-bounce, unclamped path-traced references at t = 5 s with the default camera. Skip them with
        // METALRENDERER_GI_REFS=0 once they exist.
        var refs: [Config] = []
        if ProcessInfo.processInfo.environment["METALRENDERER_GI_REFS"] != "0" {
            let ref = Config(name: "ref8 0.5x", renderScale: 0.5, bounces: 8, paused: true, startTime: 5, accumulate: true, frames: 4096)
            var refIndirect = ref; refIndirect.name = "ref8 indirect 0.5x"; refIndirect.viewMode = 6
            var refHQ = ref; refHQ.name = "ref8 1.5x"; refHQ.renderScale = 1.5; refHQ.frames = 1024
            refs = [ref, refIndirect, refHQ]
        }
        return refs + giModesUnderTest.flatMap { tag, base -> [Config] in
            var st = base; st.name = "\(tag) static"; st.paused = true; st.startTime = 5; st.capturePrevious = true
            var ind = st; ind.name = "\(tag) static indirect"; ind.viewMode = 6; ind.capturePrevious = false
            var mv = base; mv.name = "\(tag) moving"
            var cam = base; cam.name = "\(tag) camera"; cam.cameraPath = true
            var dflt = base; dflt.name = "\(tag) default moving"; dflt.upscale = 3
            var spatial = dflt; spatial.name = "\(tag) spatial moving"; spatial.upscaler = .metalFXSpatial
            return [st, ind, mv, cam, dflt, spatial]
        }
    }

    private static func configs(for mode: String) -> [Config] {
        switch mode {
        case "gi": return giConfigs()
        case "upscale":
            // Upscalers against supersampled native 1920x1200 references at t = 5 s (skip them with METALRENDERER_GI_REFS=0
            // once they exist): the albedo view isolates edges and anti-aliasing, direct light adds shading.
            // METALRENDERER_UPSCALERS="metalfx,custom,spatial" picks the upscalers.
            var refs: [Config] = []
            if ProcessInfo.processInfo.environment["METALRENDERER_GI_REFS"] != "0" {
                refs = [Config(name: "ref albedo", renderScale: 1.5, viewMode: 4, paused: true, startTime: 5, accumulate: true,
                               frames: 512, supersample: true),
                        Config(name: "ref direct", renderScale: 1.5, giEnabled: false, paused: true, startTime: 5, accumulate: true,
                               frames: 1024, supersample: true)]
            }
            let kinds: [(String, UpscalerKind)] = [("metalfx", .metalFX), ("custom", .custom), ("spatial", .metalFXSpatial)]
            let pick = ProcessInfo.processInfo.environment["METALRENDERER_UPSCALERS"].map { Set($0.split(separator: ",").map(String.init)) }
            return refs + kinds.filter { pick?.contains($0.0) ?? true }.flatMap { tag, kind -> [Config] in [
                Config(name: "albedo static \(tag)", renderScale: 0.5, upscale: 3, upscaler: kind, viewMode: 4, paused: true,
                       startTime: 5, capturePrevious: true),
                Config(name: "albedo moving \(tag)", renderScale: 0.5, upscale: 3, upscaler: kind, viewMode: 4),
                Config(name: "albedo camera \(tag)", renderScale: 0.5, upscale: 3, upscaler: kind, viewMode: 4, cameraPath: true),
                // The same camera move over the frozen scene: camera motion alone, no moving objects.
                Config(name: "albedo pan \(tag)", renderScale: 0.5, upscale: 3, upscaler: kind, viewMode: 4, paused: true,
                       startTime: 5, cameraPath: true),
                Config(name: "direct static \(tag)", renderScale: 0.5, giEnabled: false, upscale: 3, upscaler: kind, paused: true, startTime: 5),
                Config(name: "direct moving \(tag)", renderScale: 0.5, giEnabled: false, upscale: 3, upscaler: kind),
            ] }
        case "shadow":
            // Direct light only (GI off), for the shadow denoiser: a converged reference at t = 5 s (skip it with
            // METALRENDERER_GI_REFS=0 once it exists), then static (+ previous frame), moving and camera-move frames that
            // all end at t = 5 s with the default camera.
            var refs: [Config] = []
            if ProcessInfo.processInfo.environment["METALRENDERER_GI_REFS"] != "0" {
                refs = [Config(name: "ref direct", renderScale: 0.5, giEnabled: false, paused: true, startTime: 5,
                               accumulate: true, frames: 4096)]
            }
            return refs + [
                Config(name: "direct static", renderScale: 0.5, giEnabled: false, paused: true, startTime: 5, capturePrevious: true),
                Config(name: "direct moving", renderScale: 0.5, giEnabled: false),
                Config(name: "direct camera", renderScale: 0.5, giEnabled: false, cameraPath: true),
                Config(name: "default moving", renderScale: 0.5, upscale: 3, giMode: .radianceCascades),
            ]
        case "stress":
            // Stress scene at the default settings (cascades, TAAU 3x from 0.5x): frame time against light count,
            // object count and GI method. METALRENDERER_BENCH_SPLIT=0 for whole-frame times.
            func stress(_ name: String, objects: Int = 400, lights: Int = 32, giMode: GIMode = .radianceCascades) -> Config {
                Config(name: name, renderScale: 0.5, upscale: 3, giMode: giMode,
                       scene: SceneSettings(kind: .stress, objects: objects, lights: lights))
            }
            // The stress scene's own GI defaults (RenderSettings.applySceneDefaults): surfels, 8 rays, 64k pool.
            var stressDefault = stress("stress defaults (surfels), 32 lights", giMode: .surfels)
            stressDefault.surfels.raysPerSurfel = 8
            stressDefault.surfels.maxSurfels = 65536
            let lightSweep = [1, 4, 8, 16, 32, 64, 128, 256].map { stress("\($0) lights, 400 objects", lights: $0) }
            let objectSweep = [0, 100, 1000, 2000].map { stress("32 lights, \($0) objects", objects: $0) }
            return [Config(name: "cornell default", renderScale: 0.5, upscale: 3, giMode: .radianceCascades)] + lightSweep + objectSweep + [
                stress("path traced, 32 lights", giMode: .pathTraced),
                stress("surfels, 32 lights", giMode: .surfels),
                stressDefault,
                { var c = stress("camera move, 32 lights"); c.cameraPath = true; return c }(),
            ]
        case "stressq":
            // Stress-scene quality, all at t = 5 s against converged references (every light traced each frame; skip
            // them with METALRENDERER_GI_REFS=0 once they exist, see Tools/eval/stress.py):
            // * direct light only (640x400) at 32 and 128 lights;
            // * the GI methods (640x400, no upscaling) against an 8-bounce path-traced reference;
            // * the upscalers (3x from 640x400) on albedo and direct light against supersampled 1920x1200 references.
            // Run again with METALRENDERER_LIGHTS=all for the brute-force baseline, METALRENDERER_DENOISE=shadows=0 for SVGF.
            let refs = ProcessInfo.processInfo.environment["METALRENDERER_GI_REFS"] != "0"
            func stress(_ lights: Int = 32) -> SceneSettings { SceneSettings(kind: .stress, objects: 400, lights: lights) }
            let direct = [32, 128].flatMap { lights -> [Config] in
                let base = Config(name: "", renderScale: 0.5, giEnabled: false, scene: stress(lights))
                var ref = base; ref.name = "ref direct \(lights)"; ref.paused = true; ref.startTime = 5; ref.accumulate = true
                ref.frames = 1024
                var st = base; st.name = "direct static \(lights)"; st.paused = true; st.startTime = 5; st.capturePrevious = true
                var mv = base; mv.name = "direct moving \(lights)"
                var cam = base; cam.name = "direct camera \(lights)"; cam.cameraPath = true
                return (refs ? [ref] : []) + [st, mv, cam]
            }
            var gi: [Config] = refs ? [Config(name: "ref8 final 32", renderScale: 0.5, bounces: 8, paused: true, startTime: 5,
                                              accumulate: true, frames: 1024, scene: stress())] : []
            var cascadesHQ = CascadeSettings(); cascadesHQ.probeSpacing = 4; cascadesHQ.firstInterval = 0.25
            let methods: [(String, GIMode, CascadeSettings)] = [("cascades", .radianceCascades, CascadeSettings()),
                                                                 ("cascades-hq", .radianceCascades, cascadesHQ),
                                                                 ("surfels", .surfels, CascadeSettings()),
                                                                 ("pt", .pathTraced, CascadeSettings())]
            for (tag, mode, cascades) in methods {
                let base = Config(name: "", renderScale: 0.5, giMode: mode, cascades: cascades, scene: stress())
                var st = base; st.name = "\(tag) static 32"; st.paused = true; st.startTime = 5; st.capturePrevious = true
                var mv = base; mv.name = "\(tag) moving 32"
                var cam = base; cam.name = "\(tag) camera 32"; cam.cameraPath = true
                gi += [st, mv, cam]
            }
            var up: [Config] = refs ? [
                Config(name: "ref albedo 1.5x", renderScale: 1.5, viewMode: 4, paused: true, startTime: 5, accumulate: true,
                       frames: 512, supersample: true, scene: stress()),
                Config(name: "ref direct 1.5x", renderScale: 1.5, giEnabled: false, paused: true, startTime: 5, accumulate: true,
                       frames: 512, supersample: true, scene: stress()),
            ] : []
            for (tag, kind) in [("custom", UpscalerKind.custom), ("metalfx", .metalFX)] {
                let base = Config(name: "", renderScale: 0.5, upscale: 3, upscaler: kind, viewMode: 4, scene: stress())
                var st = base; st.name = "albedo static \(tag)"; st.paused = true; st.startTime = 5; st.capturePrevious = true
                var mv = base; mv.name = "albedo moving \(tag)"
                var cam = base; cam.name = "albedo camera \(tag)"; cam.cameraPath = true
                var ds = base; ds.name = "direct static \(tag)"; ds.viewMode = 0; ds.giEnabled = false; ds.paused = true; ds.startTime = 5
                var dm = base; dm.name = "direct moving \(tag)"; dm.viewMode = 0; dm.giEnabled = false
                up += [st, mv, cam, ds, dm]
            }
            return direct + gi + up
        case "rt":
            // Ray tracer comparison. Paused frames at t = 5 s in every GI mode with the METALRENDERER_RT tracer (run once per
            // tracer and compare the PNGs with Tools/eval/pngdiff.py; frame indices must match, so not in one run),
            // then moving frames for timing on both scenes at several stress-scene sizes, alternating the two tracers.
            func scene(_ kind: SceneKind, objects: Int = 400) -> SceneSettings { SceneSettings(kind: kind, objects: objects, lights: 32) }
            var out: [Config] = []
            for (tag, sc) in [("cornell", scene(.cornell)), ("stress", scene(.stress))] {
                out.append(Config(name: "\(tag) direct static", renderScale: 0.5, giEnabled: false, paused: true, startTime: 5,
                                  frames: 30, scene: sc))
                for (gtag, mode) in [("pt", GIMode.pathTraced), ("surfels", .surfels), ("cascades", .radianceCascades)] {
                    out.append(Config(name: "\(tag) \(gtag) static", renderScale: 0.5, paused: true, startTime: 5, frames: 30,
                                      giMode: mode, scene: sc))
                }
            }
            func moving(_ name: String, _ mode: GIMode, _ sc: SceneSettings) -> [Config] {
                RayTracerKind.allCases.map { rt in
                    Config(name: "\(name) moving, \(rt == .custom ? "custom" : "metal")", renderScale: 0.5, upscale: 3, giMode: mode,
                           scene: sc, rayTracer: rt)
                }
            }
            for objects in [0, 400, 1000, 2000] {
                for (gtag, mode) in [("pt", GIMode.pathTraced), ("surfels", .surfels), ("cascades", .radianceCascades)] {
                    out += moving("stress \(objects) \(gtag)", mode, scene(.stress, objects: objects))
                }
            }
            out += moving("cornell cascades", .radianceCascades, scene(.cornell))
            return out
        case "gallery":
            // The glTF gallery: full-detail meshes against virtual geometry at several error thresholds, alternating
            // so heat affects them alike. Paused frames at t = 5 s (PNGs for diffs), then the scripted camera move.
            func vg(_ on: Bool, _ tau: Float = 1) -> VirtualGeometrySettings {
                var v = VirtualGeometrySettings(); v.enabled = on; v.pixelError = tau; return v
            }
            let variants: [(String, VirtualGeometrySettings)] = [("full", vg(false)), ("vg1", vg(true, 1)), ("full", vg(false)),
                                                                 ("vg0.5", vg(true, 0.5)), ("vg2", vg(true, 2))]
            let gallery = SceneSettings(kind: .gallery)
            var out: [Config] = []
            // Path-traced references (full BRDF, full-detail meshes, 4 bounces) for Tools/eval/gallery.py; skip them
            // with METALRENDERER_GI_REFS=0 once they exist.
            if ProcessInfo.processInfo.environment["METALRENDERER_GI_REFS"] != "0" {
                out.append(Config(name: "ref overview", renderScale: 0.5, bounces: 4, paused: true, startTime: 5, accumulate: true,
                                  frames: 1024, scene: gallery, virtualGeometry: vg(false)))
                var refClose = Config(name: "ref closeup", renderScale: 0.5, bounces: 4, paused: true, startTime: 5, accumulate: true,
                                      frames: 1024, scene: gallery, virtualGeometry: vg(false))
                refClose.camera = Benchmark.galleryCloseup
                out.append(refClose)
            }
            for (tag, v) in variants {
                out.append(Config(name: "\(tag) direct static", renderScale: 0.5, giEnabled: false, paused: true, startTime: 5,
                                  frames: 60, scene: gallery, virtualGeometry: v))
                out.append(Config(name: "\(tag) surfels static", renderScale: 0.5, paused: true, startTime: 5, frames: 60,
                                  giMode: .surfels, scene: gallery, virtualGeometry: v))
                out.append(Config(name: "\(tag) albedo static", renderScale: 0.5, viewMode: 4, paused: true, startTime: 5, frames: 30,
                                  scene: gallery, virtualGeometry: v))
            }
            for (tag, v) in [("full", vg(false)), ("vg1", vg(true, 1))] {
                out.append(Config(name: "\(tag) camera", renderScale: 0.5, upscale: 3, giMode: .surfels, cameraPath: true,
                                  scene: gallery, virtualGeometry: v))
                for (gtag, mode) in [("surfels", GIMode.surfels), ("cascades", .radianceCascades), ("pt", .pathTraced)] {
                    var close = Config(name: "\(tag) \(gtag) closeup", renderScale: 0.5, paused: true, startTime: 5, capturePrevious: true,
                                       giMode: mode, scene: gallery, virtualGeometry: v)
                    close.camera = Benchmark.galleryCloseup
                    out.append(close)
                }
                var shown = Config(name: "\(tag) closeup 3x", renderScale: 0.5, upscale: 3, paused: true, startTime: 5, giMode: .surfels,
                                   scene: gallery, virtualGeometry: v)
                shown.camera = Benchmark.galleryCloseup
                out.append(shown)
            }
            return out
        case "lights":
            // The light demo scenes, paused at t = 5: direct light only, each GI technique, then moving (timing).
            // METALRENDERER_LIGHTS_SCENES="sun|mixed" limits the scenes.
            var out: [Config] = []
            let only = ProcessInfo.processInfo.environment["METALRENDERER_LIGHTS_SCENES"]?.split(separator: "|").map(String.init)
            for kind in [SceneKind.spots, .sun, .area, .tubes, .emissive, .mixed] where only?.contains("\(kind)") ?? true {
                let scene = SceneSettings(kind: kind)
                let tag = "\(kind)"
                out.append(Config(name: "\(tag) direct", giEnabled: false, paused: true, startTime: 5, frames: 30, scene: scene))
                for (name, mode) in [("surfels", GIMode.surfels), ("cascades", .radianceCascades), ("path traced", .pathTraced)] {
                    var c = Config(name: "\(tag) \(name)", paused: true, startTime: 5, frames: 30, giMode: mode, scene: scene)
                    c.surfels.raysPerSurfel = 8
                    c.surfels.maxSurfels = 65536
                    out.append(c)
                }
                var moving = Config(name: "\(tag) moving", giMode: .surfels, scene: scene)
                moving.surfels.raysPerSurfel = 8
                moving.surfels.maxSurfels = 65536
                out.append(moving)
            }
            return out
        case "fog":
            // The fog scenes, paused at t = 5 with surfel GI: fog off, the preset, without volumes, without fogged
            // reflections, the other GI techniques; then moving (timing). METALRENDERER_LIGHTS_SCENES="fog|sun" limits them.
            var out: [Config] = []
            let only = ProcessInfo.processInfo.environment["METALRENDERER_LIGHTS_SCENES"]?.split(separator: "|").map(String.init)
            for kind in [SceneKind.fog, .spots, .sun, .tubes, .emissive, .mixed] where only?.contains("\(kind)") ?? true {
                let tag = "\(kind)", preset = FogSettings.preset(for: kind)
                var base = Config(name: "", paused: true, startTime: 5, frames: 60, giMode: .surfels, scene: SceneSettings(kind: kind))
                base.surfels.raysPerSurfel = 8
                base.surfels.maxSurfels = 65536
                var off = preset; off.enabled = false
                var noVolumes = preset; noVolumes.volumes = false
                var noReflections = preset; noReflections.reflections = false
                for (name, fog) in [("fog off", off), ("fog", preset), ("fog no volumes", noVolumes), ("fog no reflections", noReflections)] {
                    var c = base; c.name = "\(tag) \(name)"; c.fog = fog
                    out.append(c)
                }
                for (name, mode) in [("cascades", GIMode.radianceCascades), ("path traced", .pathTraced)] {
                    var c = base; c.name = "\(tag) fog \(name)"; c.giMode = mode
                    out.append(c)
                }
                var view = base; view.name = "\(tag) fog scattering"; view.viewMode = 14
                var moving = base; moving.name = "\(tag) fog moving"; moving.paused = false; moving.frames = nil
                var shown = moving; shown.name = "\(tag) fog moving 3x"; shown.renderScale = 0.5; shown.upscale = 3
                out += [view, moving, shown]
            }
            return out
        case "fogcheck":
            // The froxel grid against the per-pixel reference march (fogReferenceKernel, 512 frames averaged), direct
            // light only: the fog's scattering alone (view 14) and the final image. Compare with Tools/eval/pngdiff.py.
            var out: [Config] = []
            let only = ProcessInfo.processInfo.environment["METALRENDERER_LIGHTS_SCENES"]?.split(separator: "|").map(String.init)
            for kind in [SceneKind.fog, .spots, .sun] where only?.contains("\(kind)") ?? true {
                let scene = SceneSettings(kind: kind), tag = "\(kind)"
                for (name, view) in [("scattering", 14), ("final", 0)] {
                    out.append(Config(name: "\(tag) ref \(name)", giEnabled: false, viewMode: view, paused: true, startTime: 5,
                                      accumulate: true, frames: 512, scene: scene))
                    out.append(Config(name: "\(tag) grid \(name)", giEnabled: false, viewMode: view, paused: true, startTime: 5,
                                      frames: 120, scene: scene))
                }
            }
            return out
        case "sky":
            // The sky scenes paused at sunrise, mid-morning, noon and evening (the valley's day; the sun scene's and
            // the mixed room's own times), with clouds on and off, cloud shadows off, then moving (timing).
            // METALRENDERER_LIGHTS_SCENES="valley|sun" limits the scenes; METALRENDERER_SKY=<image> tests an image sky.
            var out: [Config] = []
            let only = ProcessInfo.processInfo.environment["METALRENDERER_LIGHTS_SCENES"]?.split(separator: "|").map(String.init)
            for kind in [SceneKind.valley, .sun, .mixed] where only?.contains("\(kind)") ?? true {
                let tag = "\(kind)", preset = SkySettings.preset(for: kind)
                var base = Config(name: "", paused: true, startTime: 5, frames: 60, scene: SceneSettings(kind: kind))
                base.giMode = kind == .valley ? .radianceCascades : .surfels
                base.surfels.raysPerSurfel = 8
                base.surfels.maxSurfels = 65536
                let times: [(String, Float)] = kind == .valley ? [("morning", -31.5), ("forenoon", 5), ("noon", 13.5), ("afternoon", 40), ("evening", 58.5)]
                                                             : [("t5", 5), ("t20", 20)]
                for (name, t) in times {
                    var c = base; c.name = "\(tag) \(name)"; c.startTime = t
                    out.append(c)
                }
                var clear = preset; clear.clouds = false
                var noShadows = preset; noShadows.shadows = false
                var constant = preset; constant.mode = .constant
                for (name, sky) in [("clear", clear), ("no cloud shadows", noShadows), ("constant sky", constant)] {
                    var c = base; c.name = "\(tag) \(name)"; c.sky = sky
                    out.append(c)
                }
                if kind == .valley {   // from above, to see the clouds' shadows on the fields
                    var aerial = base; aerial.name = "\(tag) aerial"
                    var cam = Camera(); cam.position = [0, 70, 110]; cam.pitch = -0.45
                    aerial.camera = cam
                    out.append(aerial)
                }
                var moving = base; moving.name = "\(tag) moving"; moving.paused = false; moving.frames = nil
                var shown = moving; shown.name = "\(tag) moving 3x"; shown.renderScale = 0.5; shown.upscale = 3
                out += [moving, shown]
            }
            return out
        case "skycheck":
            // Cloud shadows through every sun-visibility path (shadow rays, the shadow denoiser, light maps): the valley
            // in the afternoon, a cloud shadow's edge in view, each GI method against a 4-bounce path-traced reference
            // (512 frames), final image and indirect light, with cloud shadows on and off. Each method's error should
            // not depend on the shadows.
            var out: [Config] = []
            let scene = SceneSettings(kind: .valley)
            for shadows in [true, false] {
                var sky = SkySettings.preset(for: .valley); sky.shadows = shadows
                let tag = shadows ? "shadows" : "no shadows"
                for (name, view) in [("final", 0), ("indirect", 6)] {
                    var ref = Config(name: "\(tag) ref \(name)", bounces: 4, viewMode: view, paused: true, startTime: 40,
                                     accumulate: true, frames: 512, scene: scene)
                    ref.sky = sky
                    out.append(ref)
                    for (mode, giMode, lightMaps) in [("pt", GIMode.pathTraced, false), ("pt-lightmaps", .pathTraced, true),
                                                       ("surfels", .surfels, false), ("cascades", .radianceCascades, false)] {
                        var c = Config(name: "\(tag) \(mode) \(name)", viewMode: view, paused: true, startTime: 40, frames: 90,
                                       giMode: giMode, lightMaps: lightMaps, scene: scene)
                        c.surfels.raysPerSurfel = 8
                        c.surfels.maxSurfels = 65536
                        c.sky = sky
                        out.append(c)
                    }
                }
            }
            return out
        case "lightcheck":
            // Each analytic area light against its emissive-mesh twin (Scene.buildLightCheck), converged direct light.
            var out: [Config] = []
            for shape in ["rect", "tube", "sphere"] {
                for variant in [shape, shape + "-mesh"] {
                    var scene = SceneSettings()
                    scene.lightCheck = variant
                    out.append(Config(name: "check \(variant)", giEnabled: false, paused: true, startTime: 5, accumulate: true,
                                      frames: 1024, scene: scene))
                }
            }
            return out
        case "vgdebug":
            // The geometry debug views at the gallery overview and close-up, native resolution (crisp PNGs), with
            // virtual geometry, plus full-detail meshes for the views that show all geometry.
            var out: [Config] = []
            for (cam, camera) in [("overview", Scene.galleryCamera), ("closeup", Benchmark.galleryCloseup)] {
                for (tag, on) in [("vg", true), ("full", false)] {
                    var v = VirtualGeometrySettings(); v.enabled = on
                    for mode in RenderSettings.geometryViews where on || [8, 12, 13].contains(mode) {
                        let name = RenderSettings.viewModes[mode].lowercased()
                        out.append(Config(name: "\(tag) \(name) \(cam)", renderScale: 1, giEnabled: false, viewMode: mode, paused: true,
                                          startTime: 5, frames: 8, scene: SceneSettings(kind: .gallery), virtualGeometry: v, camera: camera))
                    }
                }
            }
            return out
        case "quick": return [
            Config(name: "default: 3x from 0.5x", renderScale: 0.5, upscale: 3, giMode: .radianceCascades),
            Config(name: "default, MetalFX temporal", renderScale: 0.5, upscale: 3, upscaler: .metalFX, giMode: .radianceCascades),
            Config(name: "default, MetalFX spatial", renderScale: 0.5, upscale: 3, upscaler: .metalFXSpatial, giMode: .radianceCascades),
            Config(name: "camera move", renderScale: 0.5, upscale: 3, giMode: .radianceCascades, cameraPath: true),
            Config(name: "camera move, MetalFX temporal", renderScale: 0.5, upscale: 3, upscaler: .metalFX,
                   giMode: .radianceCascades, cameraPath: true),
            Config(name: "default, surfel GI", renderScale: 0.5, upscale: 3, giMode: .surfels),
            Config(name: "path traced, 3x from 0.5x", renderScale: 0.5, upscale: 3),
            Config(name: "0.75x, no MetalFX"),
        ]
        case "denoise": return [
            Config(name: "static 0.5x", renderScale: 0.5, paused: true, startTime: 5, capturePrevious: true),
            Config(name: "moving 0.5x", renderScale: 0.5),
            Config(name: "static direct 0.5x", renderScale: 0.5, giEnabled: false, paused: true, startTime: 5),
            Config(name: "static default", renderScale: 0.5, upscale: 3, paused: true, startTime: 5, capturePrevious: true),
            Config(name: "moving default", renderScale: 0.5, upscale: 3),
        ]
        case "noise": return [
            // 640x400, no upscaling. "moving" runs 300 frames from t = 0, so its last frame is also at t = 5 s.
            Config(name: "ref 0.5x", renderScale: 0.5, paused: true, startTime: 5, accumulate: true, frames: 4096),
            Config(name: "static white denoised 0.5x", renderScale: 0.5, blueNoise: false, paused: true, startTime: 5),
            Config(name: "static blue denoised 0.5x", renderScale: 0.5, blueNoise: true, paused: true, startTime: 5),
            Config(name: "static white raw 0.5x", renderScale: 0.5, denoiseEnabled: false, blueNoise: false, paused: true, startTime: 5),
            Config(name: "static blue raw 0.5x", renderScale: 0.5, denoiseEnabled: false, blueNoise: true, paused: true, startTime: 5),
            Config(name: "moving white denoised 0.5x", renderScale: 0.5, blueNoise: false),
            Config(name: "moving blue denoised 0.5x", renderScale: 0.5, blueNoise: true),
            // Direct light only (GI off): 6 random dimensions per pixel, the textbook case for blue noise.
            Config(name: "ref direct 0.5x", renderScale: 0.5, giEnabled: false, paused: true, startTime: 5, accumulate: true, frames: 4096),
            Config(name: "static white raw direct 0.5x", renderScale: 0.5, giEnabled: false, denoiseEnabled: false, blueNoise: false, paused: true, startTime: 5),
            Config(name: "static blue raw direct 0.5x", renderScale: 0.5, giEnabled: false, denoiseEnabled: false, blueNoise: true, paused: true, startTime: 5),
            Config(name: "static white denoised direct 0.5x", renderScale: 0.5, giEnabled: false, blueNoise: false, paused: true, startTime: 5),
            Config(name: "static blue denoised direct 0.5x", renderScale: 0.5, giEnabled: false, blueNoise: true, paused: true, startTime: 5),
            Config(name: "moving white denoised direct 0.5x", renderScale: 0.5, giEnabled: false, blueNoise: false),
            Config(name: "moving blue denoised direct 0.5x", renderScale: 0.5, giEnabled: false, blueNoise: true),
            // Default setting (MetalFX 3x to 1920x1200) against a native 1920x1200 reference.
            Config(name: "ref 1.5x", renderScale: 1.5, paused: true, startTime: 5, accumulate: true, frames: 1024),
            Config(name: "static white default", renderScale: 0.5, upscale: 3, blueNoise: false, paused: true, startTime: 5),
            Config(name: "static blue default", renderScale: 0.5, upscale: 3, blueNoise: true, paused: true, startTime: 5),
            Config(name: "moving white default", renderScale: 0.5, upscale: 3, blueNoise: false),
            Config(name: "moving blue default", renderScale: 0.5, upscale: 3, blueNoise: true),
        ]
        case "quality": return [
            Config(name: "albedo native 1.5x", renderScale: 1.5, viewMode: 4),
            Config(name: "albedo native 0.75x", viewMode: 4),
            Config(name: "albedo MetalFX 0.75x x2", upscale: 2, upscaler: .metalFX, viewMode: 4),
            Config(name: "albedo MetalFX 0.5x x3", renderScale: 0.5, upscale: 3, upscaler: .metalFX, viewMode: 4),
            Config(name: "final native 1.5x", renderScale: 1.5),
            Config(name: "final native 0.75x"),
            Config(name: "final MetalFX 0.75x x2", upscale: 2, upscaler: .metalFX),
            Config(name: "final MetalFX 0.5x x3", renderScale: 0.5, upscale: 3, upscaler: .metalFX),
        ]
        default: return [
            Config(name: "0.75x, GI 2, denoise, no MetalFX"),
            Config(name: "GI off", giEnabled: false),
            Config(name: "denoiser off", denoiseEnabled: false),
            Config(name: "GI 1 bounce", bounces: 1),
            Config(name: "GI 4 bounces", bounces: 4),
            Config(name: "GI 8 bounces", bounces: 8),
            Config(name: "scale 0.5x", renderScale: 0.5),
            Config(name: "scale 1.0x", renderScale: 1.0),
            Config(name: "scale 1.5x", renderScale: 1.5),
            Config(name: "scale 2.0x (Retina native)", renderScale: 2.0),
            Config(name: "MetalFX 2x from 0.75x", upscale: 2, upscaler: .metalFX),
            Config(name: "default: 3x from 0.5x", renderScale: 0.5, upscale: 3, giMode: .radianceCascades),
            Config(name: "default, surfel GI", renderScale: 0.5, upscale: 3, giMode: .surfels),
            Config(name: "path traced, 3x from 0.5x", renderScale: 0.5, upscale: 3),
            Config(name: "path traced + white noise", renderScale: 0.5, upscale: 3, blueNoise: false),
            Config(name: "0.75x no MetalFX + blue noise", blueNoise: true),
            Config(name: "MetalFX 2x from 1.0x", renderScale: 1.0, upscale: 2, upscaler: .metalFX),
            Config(name: "MetalFX 3x from 0.67x", renderScale: 2.0 / 3.0, upscale: 3, upscaler: .metalFX),
        ]
        }
    }

    let warmupFrames = 60
    let measuredFrames = 240
    let fixedDt: Float = 1.0 / 60.0
    let captureDir = ProcessInfo.processInfo.environment["METALRENDERER_BENCH_DIR"].map { URL(fileURLWithPath: $0) }

    private(set) var configIndex = 0
    private(set) var frameInConfig = 0
    private var resolutions: [String] = []
    private let lock = NSLock()
    private var records: [FrameRecord] = []

    init() {
        resolutions = Array(repeating: "", count: configs.count)
    }

    var current: Config { configs[configIndex] }
    var isFinished: Bool { configIndex >= configs.count }
    var isMeasuring: Bool { frameInConfig >= warmupFrames }
    private var framesLeftInConfig: Int { warmupFrames + (current.frames ?? measuredFrames) - frameInConfig }
    var shouldCapture: Bool { framesLeftInConfig == 1 || (current.capturePrevious && framesLeftInConfig == 2) }

    func noteDraw(resolution: String) {
        resolutions[configIndex] = resolution
    }

    /// Returns true when the config changed (the caller should reset its animation clock).
    func advance() -> Bool {
        frameInConfig += 1
        guard frameInConfig >= warmupFrames + (current.frames ?? measuredFrames) else { return false }
        frameInConfig = 0
        configIndex += 1
        return true
    }

    func record(_ r: FrameRecord) {
        lock.lock(); records.append(r); lock.unlock()
    }

    func report(gpuName: String) -> String {
        lock.lock(); let all = records; lock.unlock()
        var out = "\nMetalRenderer benchmark — \(gpuName) — \(warmupFrames) warm-up + \(measuredFrames) measured frames per setting\n"
        out += "GPU times are medians in ms (p95 for the total). Frames are serialized so passes never overlap.\n\"span\" = first pass start to last pass end, including gaps between command buffers.\n\n"
        // One column per pass that ran: passOrder first, then any others (e.g. GI technique passes) by name.
        let seen = Set(all.flatMap { $0.passMs.keys })
        let passes = Benchmark.passOrder.filter(seen.contains) + seen.subtracting(Benchmark.passOrder).sorted()
        let header = ["setting", "res"] + passes.map { $0 == "upscale" ? "MetalFX" : $0 } + ["GPU total", "p95", "max fps", "span"]
        var rows: [[String]] = [header]
        for (i, c) in configs.enumerated() {
            let frames = all.filter { $0.config == i }
            guard !frames.isEmpty else { continue }
            var row = [c.name, resolutions[i]]
            for pass in passes {
                let v = frames.compactMap { $0.passMs[pass] }
                row.append(v.isEmpty ? "—" : String(format: "%.2f", percentile(v, 0.5)))
            }
            let totals = frames.map { $0.passMs.values.reduce(0, +) }
            let med = percentile(totals, 0.5)
            row.append(String(format: "%.2f", med))
            row.append(String(format: "%.2f", percentile(totals, 0.95)))
            row.append(String(format: "%.0f", 1000 / med))
            row.append(String(format: "%.2f", percentile(frames.map { $0.spanMs }, 0.5)))
            rows.append(row)
        }
        let widths = (0..<header.count).map { col in rows.map { $0[col].count }.max() ?? 0 }
        for (r, row) in rows.enumerated() {
            out += row.enumerated().map { col, s in
                col == 0 ? s.padding(toLength: widths[col], withPad: " ", startingAt: 0)
                         : String(repeating: " ", count: widths[col] - s.count) + s
            }.joined(separator: "  ") + "\n"
            if r == 0 { out += widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ") + "\n" }
        }
        return out
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let s = values.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
    }

    // MARK: - Frame capture

    /// Encodes a copy of `texture` (bgra8Unorm_srgb: the bytes are already sRGB-encoded) into a shared buffer and returns a closure that writes it as PNG.
    func encodeCapture(of texture: MTLTexture, into cmd: MTLCommandBuffer, device: MTLDevice) -> (() -> Void)? {
        guard let dir = captureDir,
              let blit = cmd.makeBlitCommandEncoder() else { return nil }
        let w = texture.width, h = texture.height, rowBytes = w * 4
        guard let buffer = device.makeBuffer(length: rowBytes * h, options: .storageModeShared) else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * h)
        blit.endEncoding()
        let fileName = String(format: "%02d-", configIndex) + current.name
            .replacingOccurrences(of: "[^A-Za-z0-9.]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")) + (framesLeftInConfig == 2 ? "-prev" : "") + ".png"
        let url = dir.appendingPathComponent(fileName)
        return {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            guard let ctx = CGContext(data: buffer.contents(), width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: bitmapInfo),
                  let image = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}
