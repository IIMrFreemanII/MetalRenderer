import Buildings
import Characters
import CoreGraphics
import Effects
import EngineCore
import Foundation
import Landscape
import Materials
import Physics
import Plants
import simd
import MetalRenderer

extension Benchmark {
    // MARK: - Quality against references

    /// Stress-scene quality, all at t = 5 s against converged references (every light traced each frame; see
    /// Tools/eval/stress.py):
    /// * direct light only (640x400) at 32 and 128 lights;
    /// * the GI methods (640x400, no upscaling) against an 8-bounce path-traced reference;
    /// * MetalFX's denoising scaler (3x from 640x400) on albedo and direct light against supersampled 1920x1200 references.
    /// Run again with `METALRENDERER_LIGHTS=all` for the brute-force baseline, `METALRENDERER_DENOISE=shadows=0` for SVGF.
    static func stressq() -> [Config] {
        let direct = [32, 128].flatMap { lights -> [Config] in
            let base = Config("", scale: 0.5, gi: nil, scene: stressHall(lights: lights))
            return references([base.named("ref direct \(lights)").reference(frames: 1024)]) + scored(base) { "direct \($0) \(lights)" }
        }

        let ref8 = Config("ref8 final 32", scale: 0.5, scene: stressHall()) { $0.bounces = 8 }.reference(frames: 1024)
        var gi = references([ref8, ref8.named("ref8 indirect 32").view(6)])
        let hall = stressHall()
        let methods = [
            Config("cascades", scale: 0.5, gi: .radianceCascades, scene: hall),
            Config("cascades-hq", scale: 0.5, gi: .radianceCascades, scene: hall) { $0.cascades.probeSpacing = 4; $0.cascades.firstInterval = 0.25 },
            Config("pt", scale: 0.5, scene: hall),
            Config("restirgi", scale: 0.5, gi: .restirGI, scene: hall),
            Config("restirgi-q", scale: 0.5, gi: .restirGI, scene: hall) { $0.restirGI.quarterBudget = true },
        ]
        for method in methods {
            let tag = method.name
            var list = scored(method) { "\(tag) \($0) 32" }
            list.insert(method.named("\(tag) indirect 32").view(6).still(), at: 1)
            gi += list
        }

        let big = Config("", scale: 1.5, scene: hall)
        var up = references([big.named("ref albedo 1.5x").view(4).reference(frames: 512, supersample: true),
                             big.named("ref direct 1.5x").with { $0.giEnabled = false }.reference(frames: 512, supersample: true)])
        let shown = Config("", scale: 0.5, upscale: 3, scene: hall)
        let upDirect = shown.with { $0.giEnabled = false }
        up += scored(shown.view(4)) { "albedo \($0) denoiser" }
        up += [upDirect.named("direct static denoiser").still(), upDirect.named("direct moving denoiser")]
        return direct + gi + up
    }

    /// Direct light (GI off, 640x400) in the stress scene at t = 5 s against references, for each direct-light method:
    /// static (+ previous frame, for flicker) and moving frames, at 32 to 4096 lights. References trace every light up
    /// to Renderer.exactReferenceLights (1024), and accumulate ReSTIR's unbiased initial sampling above
    /// (Tools/eval/restir.py).
    static func restirq() -> [Config] {
        [32, 128, 1024, 4096].flatMap { lights -> [Config] in
            let base = Config("", scale: 0.5, gi: nil, scene: stressHall(lights: lights))
            let ref = base.named("ref direct \(lights)").reference(frames: lights <= 128 ? 1024 : lights <= 1024 ? 256 : 2048)
                .with { $0.restir.grid.enabled = false }   // the table alone
            let modes: [DirectLightMode] = (lights <= 128 ? [.exact] : []) + [.grouped, .restir]
            return references([ref]) + modes.flatMap { mode -> [Config] in
                let method = base.direct(mode), tag = mode.title.lowercased()
                return [method.named("\(tag) static \(lights)").still(previous: true), method.named("\(tag) moving \(lights)")]
            }
        }
    }

    /// Direct light in the Night market (4096 bulbs, GI and fog off, 640x400) against an accumulated reference
    /// (ReSTIR's unbiased initial sampling, as restirq's above 1024 lights): ReSTIR's candidates from the table alone
    /// and from the light grid, static (+ previous frame, for flicker) and moving (Tools/eval/restir.py).
    static func marketq() -> [Config] {
        let market = SceneSettings(kind: .market, lights: 4096)
        let sources = [("table", false), ("grid", true)]
        // Fog off: direct light alone.
        let base = Config("", scale: 0.5, gi: nil, scene: market).fog { $0 = FogSettings() }.direct(.restir)
        var out = references([base.named("ref direct market").reference(frames: 2048).with { $0.restir.grid.enabled = false }])
        for (tag, grid) in sources {
            let st = base.named("restir \(tag) static market").still(previous: true).with { $0.restir.grid.enabled = grid }
            // The candidates alone (no reuse, no denoiser), 64 frames averaged: the sampler's own variance.
            let accum = st.named("restir \(tag) accum market").reference(frames: 64).with { $0.restir.grid.share = 32 }
            out += [st, st.named("restir \(tag) moving market").moving(), accum]
        }
        // The grid at the secondary hits and in the fog: indirect light alone (view 6, path traced and cascades)
        // against an accumulated path-traced reference, and the fog's scattering alone (view 14) against the
        // per-pixel reference march, with GI's and the fog's candidates from the table and from the grid.
        let indirect = base.with { $0.giEnabled = true }.view(6).still()
        let fog = base.fog { $0 = FogSettings.preset(for: .market) }.view(14).still()
        out += references([indirect.named("ref indirect market").reference(frames: 2048).with { $0.restir.grid.enabled = false },
                           fog.named("ref scattering market").reference(frames: 512).with { $0.restir.grid.enabled = false }])
        for (tag, grid) in sources {
            let pt = indirect.named("pt \(tag) indirect market").with { $0.restir.grid.enabled = grid }
            let fg = fog.named("fog \(tag) scattering market").with { $0.restir.grid.enabled = grid }.frames(120)
            out += [pt, pt.named("cascades \(tag) indirect market").with { $0.giMode = .radianceCascades }, fg,
                    // Accumulated (unclamped, no denoiser): the candidates' own variance and bias.
                    pt.named("pt \(tag) accum indirect market").reference(frames: 256),
                    fg.named("fog \(tag) accum scattering market").reference(frames: 128)]
        }
        return out
    }

    /// Direct light only (GI off), for the shadow denoiser: a converged reference at t = 5 s, then static (+ previous
    /// frame), moving and camera-move frames that all end at t = 5 s with the default camera (Tools/eval/shadow.py).
    static func shadow() -> [Config] {
        let direct = Config("", scale: 0.5, gi: nil)
        return references([direct.named("ref direct").reference(frames: 4096)])
            + scored(direct) { "direct \($0)" }
            + [Config("default moving", scale: 0.5, upscale: 3, gi: .radianceCascades)]
    }

    /// Ray tracing's cost: moving frames at 3x from 640x400 through MetalFX's denoising scaler, path traced and with
    /// radiance cascades, in the Cornell room and the stress hall (in hardware from Apple9 GPUs on, in software before).
    static func hwrt() -> [Config] {
        var out: [Config] = []
        for (sceneTag, scene) in [("cornell", SceneSettings()), ("stress", stressHall())] {
            for (giTag, gi) in [("pt", GIMode.pathTraced), ("cascades", .radianceCascades)] {
                out.append(Config("\(sceneTag) \(giTag)", scale: 0.5, upscale: 3, gi: gi, scene: scene))
            }
        }
        return out
    }

    /// MetalFX's denoising scaler's images, path traced at 3x from 640x400, against supersampled native 1920x1200 references at
    /// t = 5 s (2 bounces, as the frames trace): a still with the frame before it (flicker), the animation running and
    /// the camera move (Tools/eval/hwrt.py). The gallery's glTF models are the ones with reflections (its own camera move,
    /// an orbit).
    static func hwrtq() -> [Config] {
        var out: [Config] = []
        for (sceneTag, scene) in [("cornell", SceneSettings()), ("stress", stressHall()), ("gallery", SceneSettings(kind: .gallery))] {
            out += references([Config("\(sceneTag) ref final", scale: 1.5, scene: scene).reference(frames: 1024, supersample: true)])
            let shown = Config("", scale: 0.5, upscale: 3, scene: scene)
            out += scored(shown) { "\(sceneTag) final \($0) denoiser" }
        }
        return out
    }

    /// Frame interpolation (FrameInterpolator): what it costs, and how close its in-between picture comes to a frame
    /// really rendered at that moment (Tools/eval/interp.py). Per scene, the app's look, the animation running and the
    /// camera on a 4 s track (eased at its keys, so at full speed at 2 s):
    /// * "<scene> 30 fps": frames 1/30 s apart, interpolated. Its last frame is at 2 s of the track, the one before it
    ///   is `-prev`, and the in-between picture before the last is `-interp` (at 2 s - 1/60).
    /// * "<scene> 60 fps between": frames 1/60 s apart, not interpolated, ending where the in-between picture is.
    /// * "<scene> 60 fps last": the same one frame longer, ending with the 30 fps setting's last frame: how close two
    ///   runs come at the same moment (the scores' ceiling).
    /// The 60 fps settings start their animation so that it is where the 30 fps one's is at the same moment.
    static func interp() -> [Config] {
        let n = 61   // measured 30 fps frames: the last at 2 s of the track
        let warmup = 60   // Benchmark.warmupFrames
        func key(_ time: Float, _ c: Camera) -> CameraTrack.Key { .init(time: time, position: c.position, target: c.position + c.forward) }
        func set(_ name: String, _ base: Config, _ track: CameraTrack) -> [Config] {
            var fast = base.named("\(name) 30 fps").track(track).step(1.0 / 30).frames(n).with { $0.frameInterpolation = .on }
            fast.capturePrevious = true
            // Frame k of a setting (warm-up included) shows the animation at startTime + (k + 1) steps.
            let end = base.startTime + Float(warmup + n) / 30
            var slow = base.track(track).with { $0.frameInterpolation = .off }
            slow.startTime = end - Float(warmup + 2 * n - 1) / 60
            return [fast, slow.named("\(name) 60 fps between").frames(2 * n - 2), slow.named("\(name) 60 fps last").frames(2 * n - 1)]
        }
        let cornell = Config("", scale: 0.5, upscale: 3, gi: .radianceCascades)
        let forest = Config("", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: .forest))
        let walk = CameraTrack([.init(time: 0, position: [-8, 1.6, -7.5], target: [10, 3, -30]),
                                .init(time: 4, position: [0, 1.6, -13.5], target: [10, 3, -30])])
        return set("cornell", cornell, CameraTrack([key(0, cameraPose(progress: 0)), key(4, cameraPose(progress: 1))]))
            + set("forest", forest, walk)
    }

    /// White- and blue-noise sampling next to converged references, all at t = 5 s (Tools/eval/noise.py). "moving" runs
    /// 300 frames from t = 0, so its last frame is also at t = 5 s.
    static func noise() -> [Config] {
        /// White and blue noise for one setting: `name` with "white" or "blue" in place of its `%@`.
        func pair(_ name: String, _ base: Config) -> [Config] {
            [("white", false), ("blue", true)].map { tag, blue in
                base.named(String(format: name, tag)).with { $0.blueNoise = blue }
            }
        }
        let half = Config("", scale: 0.5), raw = half.with { $0.denoiser.enabled = false }
        let direct = Config("", scale: 0.5, gi: nil), rawDirect = direct.with { $0.denoiser.enabled = false }
        let shown = Config("", scale: 0.5, upscale: 3)
        return
            // 640x400, no upscaling.
            [half.named("ref 0.5x").reference(frames: 4096)]
            + pair("static %@ denoised 0.5x", half.still()) + pair("static %@ raw 0.5x", raw.still()) + pair("moving %@ denoised 0.5x", half)
            // Direct light only (GI off): 6 random dimensions per pixel, the textbook case for blue noise.
            + [direct.named("ref direct 0.5x").reference(frames: 4096)]
            + pair("static %@ raw direct 0.5x", rawDirect.still()) + pair("static %@ denoised direct 0.5x", direct.still())
            + pair("moving %@ denoised direct 0.5x", direct)
            // Default setting (MetalFX 3x to 1920x1200) against a native 1920x1200 reference.
            + [Config("ref 1.5x", scale: 1.5).reference(frames: 1024)]
            + pair("static %@ default", shown.still()) + pair("moving %@ default", shown)
    }

    /// A few frames for scoring denoiser changes against saved `noise` references.
    static func denoise() -> [Config] {
        let half = Config("", scale: 0.5), shown = Config("", scale: 0.5, upscale: 3)
        return [
            half.named("static 0.5x").still(previous: true),
            half.named("moving 0.5x"),
            Config("static direct 0.5x", scale: 0.5, gi: nil).still(),
            shown.named("static default").still(previous: true),
            shown.named("moving default"),
        ]
    }

    /// The same frames natively and upscaled (with PNGs), for image comparisons.
    static func quality() -> [Config] {
        ["albedo", "final"].flatMap { tag -> [Config] in
            [
                Config("\(tag) native 1.5x", scale: 1.5),
                Config("\(tag) native 0.75x"),
                Config("\(tag) native 0.75x TAA") { $0.taa = true },
                Config("\(tag) MetalFX 0.75x x2", upscale: 2),
                Config("\(tag) MetalFX 0.5x x3", scale: 0.5, upscale: 3),
            ].map { tag == "albedo" ? $0.view(4) : $0 }
        }
    }

    /// Temporal AA without upscaling, in the scene METALRENDERER_SCENE picks (cascades, the traced resolution the
    /// window's size in points): without it and with it, each paused with the frame before saved too (what changes from
    /// one frame to the next is the shimmer), against a supersampled reference; then both with the camera moving (the
    /// ghosts and the blur).
    static func taa() -> [Config] {
        let off = Config("native", scale: 1, gi: .radianceCascades), on = off.named("native taa").with { $0.taa = true }
        return [
            off.still(previous: true).frames(60),
            on.still(previous: true).frames(60),
            off.named("supersampled").reference(frames: 512, supersample: true),
            off.named("native moving").cameraMove(),
            on.named("native taa moving").cameraMove(),
        ]
    }
}
