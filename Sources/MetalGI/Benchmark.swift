import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Headless-ish benchmark mode, enabled with `METALGI_BENCH=1 swift run -c release`.
///
/// Runs a fixed list of render settings with a deterministic animation clock, times every GPU
/// pass (each pass goes into its own command buffer so `gpuStartTime`/`gpuEndTime` isolate it),
/// prints a table and quits. Set `METALGI_BENCH_DIR=<folder>` to also save a PNG per setting.
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
    }

    /// Scripted camera move for the "camera" settings: a yaw sweep plus dolly that ends at the default camera,
    /// still moving, so the last frame can be scored against the same t = 5 s references as the static frames.
    static func cameraPose(progress p: Float, scene: SceneKind = .cornell) -> Camera {
        var c = Camera(), start = Camera()
        if scene == .stress {
            // Low over the floor on the right, sweeping up to the overview.
            c = Scene.stressCamera
            start.position = SIMD3<Float>(7.0, 2.2, 12.0)
            start.yaw = -0.6
            start.pitch = -0.1
        } else {
            start.position = SIMD3<Float>(2.6, 1.7, 2.2)
            start.yaw = -0.9
            start.pitch = -0.25
        }
        if ProcessInfo.processInfo.environment["METALGI_PAN"] == "rotate" { start.position = c.position; start.pitch = c.pitch }   // yaw only
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

    /// `METALGI_GI="mode=surfels,rays=8,..."` overrides GI settings in every (non-reference) setting.
    /// Keys: mode (pt|surfels|cascades), lightmaps, bounces, rays, maxsurfels, radius, shistory, sdenoise,
    /// spacing, cascades, b1, feedback, cdenoise, blue (blue-noise sampling), scale (render scale), factor (upscale factor),
    /// upscaler (metalfx|spatial|custom), lightrays (shadow rays per light group with more than 4 lights),
    /// taauhistory, taauclip.
    static func applyGIOverride(to s: inout RenderSettings) {
        guard let spec = ProcessInfo.processInfo.environment["METALGI_GI"] else { return }
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
            default: print("METALGI_GI: unknown key \(kv[0])")
            }
        }
    }

    /// `METALGI_SCENE="stress,objects=400,lights=32"` loads the stress scene (with these sizes) in every setting.
    static func applySceneOverride(to s: inout SceneSettings) {
        guard let spec = ProcessInfo.processInfo.environment["METALGI_SCENE"] else { return }
        for item in spec.split(separator: ",") {
            let kv = item.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            switch kv[0] {
            case "stress": s.kind = .stress
            case "cornell": s.kind = .cornell
            case "objects" where kv.count == 2: s.objects = Int(kv[1]) ?? s.objects
            case "lights" where kv.count == 2: s.lights = Int(kv[1]) ?? s.lights
            default: print("METALGI_SCENE: unknown key \(kv[0])")
            }
        }
    }

    /// `METALGI_DENOISE="passes=3,tpasses=2,sigma=1,history=16,antilag=1,separate=1"` overrides the denoiser in every setting,
    /// so parameter sweeps need no rebuild.
    static func applyDenoiserOverride(to d: inout DenoiserSettings) {
        guard let spec = ProcessInfo.processInfo.environment["METALGI_DENOISE"] else { return }
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
            default: print("METALGI_DENOISE: unknown key \(kv[0])")
            }
        }
    }

    struct FrameRecord {
        var config: Int
        var passMs: [String: Double]
        var spanMs: Double          // first pass start -> last pass end
    }

    static let isEnabled = ProcessInfo.processInfo.environment["METALGI_BENCH"] != nil
    /// Each pass in its own command buffer, for per-pass timings (default). `METALGI_BENCH_SPLIT=0` encodes frames
    /// exactly like normal mode (one command buffer) and reports only the whole-frame GPU time.
    static let splitPasses = ProcessInfo.processInfo.environment["METALGI_BENCH_SPLIT"] != "0"
    static let passOrder = ["tlas", "lightmap", "trace", "temporal", "atrous", "composite", "upscale"]

    /// `METALGI_BENCH=quality` renders the same frames natively and upscaled (with PNGs) for image comparisons.
    /// `METALGI_BENCH=noise` renders white- and blue-noise sampling next to converged references, all at t = 5 s.
    /// `METALGI_BENCH=denoise` renders a few frames for scoring denoiser changes against saved `noise` references.
    /// `METALGI_BENCH_ONLY="32 lights, 400|camera"` keeps only the settings whose names contain one of these substrings.
    let configs: [Config] = {
        let all = Benchmark.configs(for: ProcessInfo.processInfo.environment["METALGI_BENCH"] ?? "")
        guard let only = ProcessInfo.processInfo.environment["METALGI_BENCH_ONLY"] else { return all }
        let keys = only.split(separator: "|").map(String.init)
        return all.filter { c in keys.contains { c.name.contains($0) } }
    }()

    /// GI modes compared by `METALGI_BENCH=gi` (`METALGI_GI_MODES="pt,surfels"` picks a subset).
    private static let giModesUnderTest: [(tag: String, base: Config)] = {
        var pt = Config(name: "", renderScale: 0.5)
        var ptLM = pt; ptLM.lightMaps = true
        var surfels = pt; surfels.giMode = .surfels
        var cascades = pt; cascades.giMode = .radianceCascades
        var cascadesHQ = cascades; cascadesHQ.cascades.probeSpacing = 4; cascadesHQ.cascades.firstInterval = 0.25
        pt.name = "pt"; ptLM.name = "pt-lightmaps"; surfels.name = "surfels"; cascades.name = "cascades"; cascadesHQ.name = "cascades-hq"
        let all = [pt, ptLM, surfels, cascades, cascadesHQ].map { (tag: $0.name, base: $0) }
        guard let pick = ProcessInfo.processInfo.environment["METALGI_GI_MODES"] else { return all }
        let tags = Set(pick.split(separator: ",").map(String.init))
        return all.filter { tags.contains($0.tag) }
    }()

    private static func giConfigs() -> [Config] {
        // 8-bounce, unclamped path-traced references at t = 5 s with the default camera. Skip them with
        // METALGI_GI_REFS=0 once they exist.
        var refs: [Config] = []
        if ProcessInfo.processInfo.environment["METALGI_GI_REFS"] != "0" {
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
            // Upscalers against supersampled native 1920x1200 references at t = 5 s (skip them with METALGI_GI_REFS=0
            // once they exist): the albedo view isolates edges and anti-aliasing, direct light adds shading.
            // METALGI_UPSCALERS="metalfx,custom,spatial" picks the upscalers.
            var refs: [Config] = []
            if ProcessInfo.processInfo.environment["METALGI_GI_REFS"] != "0" {
                refs = [Config(name: "ref albedo", renderScale: 1.5, viewMode: 4, paused: true, startTime: 5, accumulate: true,
                               frames: 512, supersample: true),
                        Config(name: "ref direct", renderScale: 1.5, giEnabled: false, paused: true, startTime: 5, accumulate: true,
                               frames: 1024, supersample: true)]
            }
            let kinds: [(String, UpscalerKind)] = [("metalfx", .metalFX), ("custom", .custom), ("spatial", .metalFXSpatial)]
            let pick = ProcessInfo.processInfo.environment["METALGI_UPSCALERS"].map { Set($0.split(separator: ",").map(String.init)) }
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
            // METALGI_GI_REFS=0 once it exists), then static (+ previous frame), moving and camera-move frames that
            // all end at t = 5 s with the default camera.
            var refs: [Config] = []
            if ProcessInfo.processInfo.environment["METALGI_GI_REFS"] != "0" {
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
            // object count and GI method. METALGI_BENCH_SPLIT=0 for whole-frame times.
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
            // them with METALGI_GI_REFS=0 once they exist, see Tools/eval/stress.py):
            // * direct light only (640x400) at 32 and 128 lights;
            // * the GI methods (640x400, no upscaling) against an 8-bounce path-traced reference;
            // * the upscalers (3x from 640x400) on albedo and direct light against supersampled 1920x1200 references.
            // Run again with METALGI_LIGHTS=all for the brute-force baseline, METALGI_DENOISE=shadows=0 for SVGF.
            let refs = ProcessInfo.processInfo.environment["METALGI_GI_REFS"] != "0"
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
    let captureDir = ProcessInfo.processInfo.environment["METALGI_BENCH_DIR"].map { URL(fileURLWithPath: $0) }

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
        var out = "\nMetalGI benchmark — \(gpuName) — \(warmupFrames) warm-up + \(measuredFrames) measured frames per setting\n"
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
