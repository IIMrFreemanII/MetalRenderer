import CoreGraphics
import Foundation

/// The benchmark modes: `METALRENDERER_BENCH=<name>` runs that mode's list of settings (`Benchmark.Config`).
/// Setting names become PNG names and the scorers in Tools/eval look them up, so they are part of the interface.
extension Benchmark {
    /// Every mode by name. Any other value of METALRENDERER_BENCH (the documented one is `1`) runs `standard`.
    static let modes: [String: () -> [Config]] = [
        "quick": quick, "stress": stress, "restir": restir, "rt": rt, "gallery": gallery, "gi": gi,
        "lights": lights, "fog": fog, "sky": sky,
        "stressq": stressq, "restirq": restirq, "marketq": marketq, "shadow": shadow, "upscale": upscale,
        "noise": noise, "denoise": denoise, "quality": quality,
        "restircheck": restircheck, "restirgicheck": restirgicheck, "lightcheck": lightcheck, "speccheck": speccheck, "fogcheck": fogcheck,
        "skycheck": skycheck, "vgdebug": vgdebug,
    ]

    static func configs(for mode: String) -> [Config] {
        if let build = modes[mode] { return build() }
        if mode != "1" && !mode.isEmpty {
            print("METALRENDERER_BENCH=\(mode) isn't a mode (\(modes.keys.sorted().joined(separator: ", "))): running the default list")
        }
        return standard()
    }

    // MARK: - Shared pieces

    private static let env = ProcessInfo.processInfo.environment
    /// Converged references are rendered unless `METALRENDERER_GI_REFS=0`: skip them once they exist.
    private static let wantReferences = env["METALRENDERER_GI_REFS"] != "0"
    private static func references(_ list: [Config]) -> [Config] { wantReferences ? list : [] }

    /// `kinds`, or those of them that `METALRENDERER_LIGHTS_SCENES="sun|mixed"` names.
    private static func picked(_ kinds: [SceneKind]) -> [SceneKind] {
        guard let only = env["METALRENDERER_LIGHTS_SCENES"]?.split(separator: "|").map(String.init) else { return kinds }
        return kinds.filter { only.contains("\($0)") }
    }

    private static func stressHall(objects: Int = 400, lights: Int = 32) -> SceneSettings {
        SceneSettings(kind: .stress, objects: objects, lights: lights)
    }

    /// The three frames a method is scored on, named by `name("static" | "moving" | "camera")`: a still at t = 5 s
    /// with the frame before it (flicker), the animation running, and the scripted camera move. The last two run 300
    /// frames from t = 0, so they end at t = 5 s with the default camera and score against the same reference.
    private static func scored(_ base: Config, _ name: (String) -> String) -> [Config] {
        [base.named(name("static")).still(previous: true), base.named(name("moving")), base.named(name("camera")).cameraMove()]
    }

    // MARK: - Timing

    /// The default list: GI bounces, denoiser, render scale, MetalFX.
    private static func standard() -> [Config] { [
        Config("0.75x, GI 2, denoise, no MetalFX"),
        Config("GI off", gi: nil),
        Config("denoiser off") { $0.denoiser.enabled = false },
        Config("GI 1 bounce") { $0.bounces = 1 },
        Config("GI 4 bounces") { $0.bounces = 4 },
        Config("GI 8 bounces") { $0.bounces = 8 },
        Config("scale 0.5x", scale: 0.5),
        Config("scale 1.0x", scale: 1.0),
        Config("scale 1.5x", scale: 1.5),
        Config("scale 2.0x (Retina native)", scale: 2.0),
        Config("MetalFX 2x from 0.75x", upscale: 2) { $0.upscaler = .metalFX },
        Config("default: 3x from 0.5x", scale: 0.5, upscale: 3, gi: .radianceCascades),
        Config("path traced, 3x from 0.5x", scale: 0.5, upscale: 3),
        Config("path traced + white noise", scale: 0.5, upscale: 3) { $0.blueNoise = false },
        Config("0.75x no MetalFX + blue noise"),
        Config("MetalFX 2x from 1.0x", scale: 1.0, upscale: 2) { $0.upscaler = .metalFX },
        Config("MetalFX 3x from 0.67x", scale: 2.0 / 3.0, upscale: 3) { $0.upscaler = .metalFX },
    ] }

    /// Fast smoke tests: the default setting, MetalFX temporal and spatial, camera moves, path traced, 0.75x native.
    private static func quick() -> [Config] {
        let shown = Config("", scale: 0.5, upscale: 3, gi: .radianceCascades)
        let metalFX = shown.with { $0.upscaler = .metalFX }
        return [
            shown.named("default: 3x from 0.5x"),
            metalFX.named("default, MetalFX temporal"),
            shown.named("default, MetalFX spatial").with { $0.upscaler = .metalFXSpatial },
            shown.named("camera move").cameraMove(),
            metalFX.named("camera move, MetalFX temporal").cameraMove(),
            Config("path traced, 3x from 0.5x", scale: 0.5, upscale: 3),
            Config("0.75x, no MetalFX"),
        ]
    }

    /// The stress scene at the default settings (cascades, TAAU 3x from 0.5x): frame time against light count, object
    /// count and GI method. `METALRENDERER_BENCH_SPLIT=0` for whole-frame times.
    private static func stress() -> [Config] {
        func hall(_ name: String, objects: Int = 400, lights: Int = 32, gi: GIMode = .radianceCascades) -> Config {
            Config(name, scale: 0.5, upscale: 3, gi: gi, scene: stressHall(objects: objects, lights: lights))
        }
        return [Config("cornell default", scale: 0.5, upscale: 3, gi: .radianceCascades)]
            + [1, 4, 8, 16, 32, 64, 128, 256].map { hall("\($0) lights, 400 objects", lights: $0) }
            + [0, 100, 1000, 2000].map { hall("32 lights, \($0) objects", objects: $0) }
            + [hall("path traced, 32 lights", gi: .pathTraced), hall("camera move, 32 lights").cameraMove()]
    }

    /// Frame time against light count for each direct-light method, the stress scene at the default settings
    /// (cascades, TAAU 3x from 0.5x), 1 to 16384 lights (exact up to 256, grouped up to 4096); then the night market.
    /// `METALRENDERER_BENCH_SPLIT=0` for whole-frame times.
    private static func restir() -> [Config] {
        func shown(_ name: String, _ scene: SceneSettings, _ mode: DirectLightMode) -> Config {
            Config(name, scale: 0.5, upscale: 3, gi: .radianceCascades, scene: scene).direct(mode)
        }
        var out: [Config] = []
        for lights in [1, 4, 32, 256, 1024, 4096, 16384] {
            let modes: [DirectLightMode] = (lights <= 256 ? [.exact] : []) + (lights <= 4096 ? [.grouped] : []) + [.restir]
            out += modes.map { shown("\($0.title.lowercased()), \(lights) lights", stressHall(lights: lights), $0) }
        }
        // The night market (its defaults: cascades, fog), paused so the PNGs compare.
        for lights in [1024, 4096, 16384] {
            for mode in lights <= 4096 ? [DirectLightMode.grouped, .restir] : [.restir] {
                out.append(shown("market \(mode.title.lowercased()), \(lights) bulbs", SceneSettings(kind: .market, lights: lights), mode).still())
            }
        }
        return out
    }

    /// Ray tracer comparison. Paused frames at t = 5 s in every GI mode with the METALRENDERER_RT tracer (run once per
    /// tracer and compare the PNGs with Tools/eval/pngdiff.py; frame indices must match, so not in one run), then
    /// moving frames for timing on both scenes at several stress-scene sizes, alternating the two tracers.
    private static func rt() -> [Config] {
        func scene(_ kind: SceneKind, objects: Int = 400) -> SceneSettings { SceneSettings(kind: kind, objects: objects, lights: 32) }
        let methods = [("pt", GIMode.pathTraced), ("cascades", .radianceCascades)]
        var out: [Config] = []
        for (tag, sc) in [("cornell", scene(.cornell)), ("stress", scene(.stress))] {
            out.append(Config("\(tag) direct static", scale: 0.5, gi: nil, scene: sc).still().frames(30))
            out += methods.map { Config("\(tag) \($0.0) static", scale: 0.5, gi: $0.1, scene: sc).still().frames(30) }
        }
        func moving(_ name: String, _ mode: GIMode, _ sc: SceneSettings) -> [Config] {
            RayTracerKind.allCases.map { tracer in
                Config("\(name) moving, \(tracer == .custom ? "custom" : "metal")", scale: 0.5, upscale: 3, gi: mode, scene: sc) {
                    $0.rayTracer = tracer
                }
            }
        }
        for objects in [0, 400, 1000, 2000] {
            for (tag, mode) in methods { out += moving("stress \(objects) \(tag)", mode, scene(.stress, objects: objects)) }
        }
        return out + moving("cornell cascades", .radianceCascades, scene(.cornell))
    }

    /// The glTF gallery: full-detail meshes against virtual geometry at several error thresholds, alternating so heat
    /// affects them alike. Paused frames at t = 5 s (PNGs for diffs), then the scripted camera move and close-ups.
    private static func gallery() -> [Config] {
        typealias Detail = (tag: String, virtual: Bool, pixelError: Float)
        let full: Detail = ("full", false, 1), vg1: Detail = ("vg1", true, 1)
        /// The gallery with `detail`, at 0.5x.
        func gallery(_ name: String, _ detail: Detail, upscale: CGFloat = 0, gi: GIMode? = .pathTraced) -> Config {
            Config(name, scale: 0.5, upscale: upscale, gi: gi, scene: SceneSettings(kind: .gallery)) {
                $0.virtualGeometry.enabled = detail.virtual
                $0.virtualGeometry.pixelError = detail.pixelError
            }
        }
        // Path-traced references (full BRDF, full-detail meshes, 4 bounces) for Tools/eval/gallery.py.
        let ref = gallery("ref overview", full).with { $0.bounces = 4 }.reference(frames: 1024)
        var out = references([ref, ref.named("ref closeup").from(galleryCloseup)])
        let sweep: [Detail] = [full, vg1, full, ("vg0.5", true, 0.5), ("vg2", true, 2)]
        for detail in sweep {
            out.append(gallery("\(detail.tag) direct static", detail, gi: nil).still().frames(60))
            out.append(gallery("\(detail.tag) cascades static", detail, gi: .radianceCascades).still().frames(60))
            out.append(gallery("\(detail.tag) albedo static", detail).view(4).still().frames(30))
        }
        for detail in [full, vg1] {
            out.append(gallery("\(detail.tag) camera", detail, upscale: 3, gi: .radianceCascades).cameraMove())
            for (tag, mode) in [("cascades", GIMode.radianceCascades), ("pt", .pathTraced), ("restirgi", .restirGI)] {
                out.append(gallery("\(detail.tag) \(tag) closeup", detail, gi: mode).still(previous: true).from(galleryCloseup))
            }
            out.append(gallery("\(detail.tag) closeup 3x", detail, upscale: 3, gi: .radianceCascades).still().from(galleryCloseup))
        }
        return out
    }

    /// The GI methods `gi` compares, named by their tag (`METALRENDERER_GI_MODES="pt,cascades"` picks a subset).
    private static let giMethods: [Config] = {
        let all = [
            Config("pt", scale: 0.5),
            Config("pt-lightmaps", scale: 0.5) { $0.lightMaps = true },
            Config("cascades", scale: 0.5, gi: .radianceCascades),
            Config("cascades-hq", scale: 0.5, gi: .radianceCascades) { $0.cascades.probeSpacing = 4; $0.cascades.firstInterval = 0.25 },
            Config("restirgi", scale: 0.5, gi: .restirGI),
            Config("restirgi-q", scale: 0.5, gi: .restirGI) { $0.restirGI.quarterBudget = true },
        ]
        guard let pick = env["METALRENDERER_GI_MODES"] else { return all }
        let tags = Set(pick.split(separator: ",").map(String.init))
        return all.filter { tags.contains($0.name) }
    }()

    /// Each GI method against 8-bounce, unclamped path-traced references at t = 5 s with the default camera
    /// (Tools/eval/gi.py).
    private static func gi() -> [Config] {
        let ref = Config("ref8 0.5x", scale: 0.5) { $0.bounces = 8 }.reference(frames: 4096)
        let refs = [ref, ref.named("ref8 indirect 0.5x").view(6), ref.named("ref8 1.5x").with { $0.renderScale = 1.5 }.frames(1024)]
        return references(refs) + giMethods.flatMap { method -> [Config] in
            let tag = method.name
            var list = scored(method) { "\(tag) \($0)" }
            list.insert(method.named("\(tag) static indirect").view(6).still(), at: 1)
            let shown = method.named("\(tag) default moving").with { $0.upscaleFactor = 3 }
            return list + [shown, shown.named("\(tag) spatial moving").with { $0.upscaler = .metalFXSpatial }]
        }
    }

    /// The light demo scenes, paused at t = 5: direct light only, each GI technique, then moving (timing).
    /// `METALRENDERER_LIGHTS_SCENES="sun|mixed"` limits the scenes.
    private static func lights() -> [Config] {
        picked([.spots, .sun, .area, .tubes, .emissive, .mixed]).flatMap { kind -> [Config] in
            let scene = SceneSettings(kind: kind)
            return [
                Config("\(kind) direct", gi: nil, scene: scene).still().frames(30),
                Config("\(kind) cascades", gi: .radianceCascades, scene: scene).still().frames(30),
                Config("\(kind) path traced", scene: scene).still().frames(30),
                Config("\(kind) moving", gi: .radianceCascades, scene: scene),
            ]
        }
    }

    /// The fog scenes, paused at t = 5 with cascade GI: fog off, the preset, without volumes, without fogged
    /// reflections, path-traced GI, the scattering alone; then moving (timing). `METALRENDERER_LIGHTS_SCENES="fog|sun"`
    /// limits them.
    private static func fog() -> [Config] {
        picked([.fog, .spots, .sun, .tubes, .emissive, .mixed]).flatMap { kind -> [Config] in
            let base = Config("", gi: .radianceCascades, scene: SceneSettings(kind: kind)).still().frames(60)
            let moving = base.named("\(kind) fog moving").moving()
            return [
                base.named("\(kind) fog off").fog { $0.enabled = false },
                base.named("\(kind) fog").fog { _ in },   // this scene's preset, as is
                base.named("\(kind) fog no volumes").fog { $0.volumes = false },
                base.named("\(kind) fog no reflections").fog { $0.reflections = false },
                base.named("\(kind) fog path traced").with { $0.giMode = .pathTraced },
                base.named("\(kind) fog scattering").view(14),
                moving,
                moving.named("\(kind) fog moving 3x").with { $0.renderScale = 0.5; $0.upscaleFactor = 3 },
            ]
        }
    }

    /// The sky scenes paused at sunrise, mid-morning, noon and evening (the valley's day; the sun scene's and the
    /// mixed room's own times), with clouds on and off, cloud shadows off, then moving (timing).
    /// `METALRENDERER_LIGHTS_SCENES="valley|sun"` limits the scenes; `METALRENDERER_SKY=<image>` tests an image sky.
    private static func sky() -> [Config] {
        picked([.valley, .sun, .mixed]).flatMap { kind -> [Config] in
            let base = Config("", gi: .radianceCascades, scene: SceneSettings(kind: kind)).still().frames(60)
            let times: [(String, Float)] = kind == .valley
                ? [("morning", -31.5), ("forenoon", 5), ("noon", 13.5), ("afternoon", 40), ("evening", 58.5)] : [("t5", 5), ("t20", 20)]
            var out = times.map { base.named("\(kind) \($0.0)").still(at: $0.1) }
            out += [
                base.named("\(kind) clear").sky { $0.clouds = false },
                base.named("\(kind) no cloud shadows").sky { $0.shadows = false },
                base.named("\(kind) constant sky").sky { $0.mode = .constant },
            ]
            if kind == .valley {   // from above, to see the clouds' shadows on the fields
                var aerial = Camera()
                aerial.position = [0, 70, 110]
                aerial.pitch = -0.45
                out.append(base.named("\(kind) aerial").from(aerial))
            }
            let moving = base.named("\(kind) moving").moving()
            return out + [moving, moving.named("\(kind) moving 3x").with { $0.renderScale = 0.5; $0.upscaleFactor = 3 }]
        }
    }

    // MARK: - Quality against references

    /// Stress-scene quality, all at t = 5 s against converged references (every light traced each frame; see
    /// Tools/eval/stress.py):
    /// * direct light only (640x400) at 32 and 128 lights;
    /// * the GI methods (640x400, no upscaling) against an 8-bounce path-traced reference;
    /// * the upscalers (3x from 640x400) on albedo and direct light against supersampled 1920x1200 references.
    /// Run again with `METALRENDERER_LIGHTS=all` for the brute-force baseline, `METALRENDERER_DENOISE=shadows=0` for SVGF.
    private static func stressq() -> [Config] {
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
        for (tag, kind) in [("custom", UpscalerKind.custom), ("metalfx", .metalFX)] {
            let shown = Config("", scale: 0.5, upscale: 3, scene: hall) { $0.upscaler = kind }
            let direct = shown.with { $0.giEnabled = false }
            up += scored(shown.view(4)) { "albedo \($0) \(tag)" }
            up += [direct.named("direct static \(tag)").still(), direct.named("direct moving \(tag)")]
        }
        return direct + gi + up
    }

    /// Direct light (GI off, 640x400) in the stress scene at t = 5 s against references, for each direct-light method:
    /// static (+ previous frame, for flicker) and moving frames, at 32 to 4096 lights. References trace every light up
    /// to Renderer.exactReferenceLights (1024), and accumulate ReSTIR's unbiased initial sampling above
    /// (Tools/eval/restir.py).
    private static func restirq() -> [Config] {
        [32, 128, 1024, 4096].flatMap { lights -> [Config] in
            let base = Config("", scale: 0.5, gi: nil, scene: stressHall(lights: lights))
            let ref = base.named("ref direct \(lights)").reference(frames: lights <= 128 ? 1024 : lights <= 1024 ? 256 : 2048)
                .with { $0.restir.grid.enabled = false }   // the table alone
            let modes: [DirectLightMode] = lights <= 128 ? [.exact, .grouped, .restir] : [.grouped, .restir]
            return references([ref]) + modes.flatMap { mode -> [Config] in
                let method = base.direct(mode), tag = mode.title.lowercased()
                return [method.named("\(tag) static \(lights)").still(previous: true), method.named("\(tag) moving \(lights)")]
            }
        }
    }

    /// Direct light in the Night market (4096 bulbs, GI and fog off, 640x400) against an accumulated reference
    /// (ReSTIR's unbiased initial sampling, as restirq's above 1024 lights): ReSTIR's candidates from the table alone
    /// and from the light grid, static (+ previous frame, for flicker) and moving (Tools/eval/restir.py).
    private static func marketq() -> [Config] {
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
    private static func shadow() -> [Config] {
        let direct = Config("", scale: 0.5, gi: nil)
        return references([direct.named("ref direct").reference(frames: 4096)])
            + scored(direct) { "direct \($0)" }
            + [Config("default moving", scale: 0.5, upscale: 3, gi: .radianceCascades)]
    }

    /// Upscalers against supersampled native 1920x1200 references at t = 5 s: the albedo view isolates edges and
    /// anti-aliasing, direct light adds shading (Tools/eval/upscale.py). `METALRENDERER_UPSCALERS="metalfx,custom,spatial"`
    /// picks the upscalers.
    private static func upscale() -> [Config] {
        let refs = [Config("ref albedo", scale: 1.5).view(4).reference(frames: 512, supersample: true),
                    Config("ref direct", scale: 1.5, gi: nil).reference(frames: 1024, supersample: true)]
        let kinds: [(String, UpscalerKind)] = [("metalfx", .metalFX), ("custom", .custom), ("spatial", .metalFXSpatial)]
        let pick = env["METALRENDERER_UPSCALERS"].map { Set($0.split(separator: ",").map(String.init)) }
        return references(refs) + kinds.filter { pick?.contains($0.0) ?? true }.flatMap { tag, kind -> [Config] in
            let shown = Config("", scale: 0.5, upscale: 3) { $0.upscaler = kind }
            let albedo = shown.view(4), direct = shown.with { $0.giEnabled = false }
            return scored(albedo) { "albedo \($0) \(tag)" } + [
                // The same camera move over the frozen scene: camera motion alone, no moving objects.
                albedo.named("albedo pan \(tag)").still().cameraMove(),
                direct.named("direct static \(tag)").still(),
                direct.named("direct moving \(tag)"),
            ]
        }
    }

    /// White- and blue-noise sampling next to converged references, all at t = 5 s (Tools/eval/noise.py). "moving" runs
    /// 300 frames from t = 0, so its last frame is also at t = 5 s.
    private static func noise() -> [Config] {
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
    private static func denoise() -> [Config] {
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
    private static func quality() -> [Config] {
        ["albedo", "final"].flatMap { tag -> [Config] in
            [
                Config("\(tag) native 1.5x", scale: 1.5),
                Config("\(tag) native 0.75x"),
                Config("\(tag) MetalFX 0.75x x2", upscale: 2) { $0.upscaler = .metalFX },
                Config("\(tag) MetalFX 0.5x x3", scale: 0.5, upscale: 3) { $0.upscaler = .metalFX },
            ].map { tag == "albedo" ? $0.view(4) : $0 }
        }
    }

    // MARK: - Correctness checks

    /// ReSTIR's sampling is unbiased for every light type: accumulated direct light (GI off), every light traced
    /// against ReSTIR's initial sampling without reuse (32 candidates, 4 chains), from the table alone and from the
    /// light grid, in the light-check scenes (one rect / tube / sphere light, or its emissive-mesh twin) and in scenes
    /// with spots, tubes, rects, emissive meshes, a sun and every type together. Mean luminance and PSNR should agree
    /// (Tools/eval/restir.py).
    private static func restircheck() -> [Config] {
        var scenes: [(String, SceneSettings)] = ["rect", "tube", "sphere", "rect-mesh", "tube-mesh", "sphere-mesh"].map {
            var s = SceneSettings(); s.lightCheck = $0; return ($0, s)
        }
        scenes += [SceneKind.spots, .tubes, .area, .emissive, .mixed].map { ("\($0)", SceneSettings(kind: $0)) }
        scenes.append(("stress32", stressHall()))
        return scenes.flatMap { tag, scene -> [Config] in
            [(DirectLightMode.exact, false), (.restir, false), (.restir, true)].map { mode, grid in
                Config("\(tag) \(mode.title.lowercased())" + (grid ? " grid" : ""), gi: nil, scene: scene) {
                    $0.restir.grid.enabled = grid
                    $0.restir.grid.share = 32      // every candidate
                }
                .sky { $0 = SkySettings() }        // constant sky: the sky's own noise stays out of the comparison
                .reference(frames: 1024).direct(mode)
            }
        }
    }

    /// ReSTIR GI is unbiased: accumulated indirect light (the "Indirect only" view, 2 bounces, unclamped) of path
    /// tracing against ReSTIR GI without reuse (the same paths, as reservoirs), with temporal and (unbiased) spatial
    /// reuse, and with the quarter budget, in Cornell and the stress hall (Tools/eval/restirgi.py).
    private static func restirgicheck() -> [Config] {
        [("cornell", SceneSettings()), ("stress", stressHall())].flatMap { tag, scene -> [Config] in
            let pt = Config("\(tag) pt", scale: 0.5, scene: scene).sky { $0 = SkySettings() }.view(6).reference(frames: 1024)
            // No multi-bounce feedback (it isn't in the paths).
            var noReuse = pt.named("\(tag) restirgi noreuse").with {
                $0.giMode = .restirGI
                $0.restirGI.feedback = false; $0.restirGI.temporal = false; $0.restirGI.spatialPasses = 0
            }
            noReuse.accumulateTechnique = true
            // Spatial reuse on is unbiased by default.
            let reuse = noReuse.named("\(tag) restirgi reuse").with { $0.restirGI.temporal = true; $0.restirGI.spatialPasses = 1 }
            return [pt, noReuse, reuse, reuse.named("\(tag) restirgi quarter").with { $0.restirGI.quarterBudget = true }]
        }
    }

    /// Each analytic area light against its emissive-mesh twin (Scene.buildLightCheck), converged direct light.
    private static func lightcheck() -> [Config] {
        ["rect", "tube", "sphere"].flatMap { [$0, $0 + "-mesh"] }.map { variant in
            var scene = SceneSettings()
            scene.lightCheck = variant
            return Config("check \(variant)", gi: nil, scene: scene).reference(frames: 1024)
        }
    }

    /// Direct specular light is counted once: the glossy light scenes with direct light only (so the reflections see lit
    /// surfaces and nothing else), each direct-light path against the accumulated reference (Tools/eval/specular.py).
    /// The shadow denoiser adds direct specular in the composite, SVGF and references in the reflection pass, ReSTIR
    /// from its reservoirs. No tone curve and 2 stops down, so highlights compare linearly instead of clipping.
    private static func speccheck() -> [Config] {
        picked([.area, .spots, .tubes]).flatMap { kind -> [Config] in
            let base = Config("", gi: nil, scene: SceneSettings(kind: kind)) { $0.toneMap = .none; $0.exposure = -2 }
                .sky { $0 = SkySettings() }
            let still = base.still().frames(60)
            return references([base.named("\(kind) ref").reference(frames: 1024)]) + [
                still.named("\(kind) shadow denoiser"),
                still.named("\(kind) svgf").with { $0.denoiser.shadowDenoiser = false },
                still.named("\(kind) restir").direct(.restir),
            ]
        }
    }

    /// The froxel grid against the per-pixel reference march (fogReferenceKernel, 512 frames averaged), direct light
    /// only: the fog's scattering alone (view 14) and the final image. Compare with Tools/eval/pngdiff.py.
    private static func fogcheck() -> [Config] {
        picked([.fog, .spots, .sun]).flatMap { kind -> [Config] in
            let direct = Config("", gi: nil, scene: SceneSettings(kind: kind))
            return [("scattering", 14), ("final", 0)].flatMap { name, view -> [Config] in
                [direct.named("\(kind) ref \(name)").view(view).reference(frames: 512),
                 direct.named("\(kind) grid \(name)").view(view).still().frames(120)]
            }
        }
    }

    /// Cloud shadows through every sun-visibility path (shadow rays, the shadow denoiser, light maps): the valley in
    /// the afternoon, a cloud shadow's edge in view, each GI method against a 4-bounce path-traced reference (512
    /// frames), final image and indirect light, with cloud shadows on and off. Each method's error should not depend
    /// on the shadows.
    private static func skycheck() -> [Config] {
        let valley = SceneSettings(kind: .valley)
        let methods: [(String, GIMode, Bool)] = [("pt", .pathTraced, false), ("pt-lightmaps", .pathTraced, true),
                                                 ("cascades", .radianceCascades, false), ("restirgi", .restirGI, false)]
        var out: [Config] = []
        for shadows in [true, false] {
            let tag = shadows ? "shadows" : "no shadows"
            for (name, view) in [("final", 0), ("indirect", 6)] {
                let base = Config("", scene: valley).sky { $0.shadows = shadows }.view(view)
                out.append(base.named("\(tag) ref \(name)").with { $0.bounces = 4 }.reference(frames: 512, at: 40))
                out += methods.map { method, gi, lightMaps in
                    base.named("\(tag) \(method) \(name)").with { $0.giMode = gi; $0.lightMaps = lightMaps }.still(at: 40).frames(90)
                }
            }
        }
        return out
    }

    /// The geometry debug views at the gallery overview and close-up, native resolution (crisp PNGs), with virtual
    /// geometry, plus full-detail meshes for the views that show all geometry.
    private static func vgdebug() -> [Config] {
        var out: [Config] = []
        for (place, camera) in [("overview", Scene.galleryCamera), ("closeup", galleryCloseup)] {
            for (tag, virtual) in [("vg", true), ("full", false)] {
                for mode in RenderSettings.geometryViews where virtual || [8, 12, 13].contains(mode) {
                    let name = RenderSettings.viewModes[mode].lowercased()
                    out.append(Config("\(tag) \(name) \(place)", scale: 1, gi: nil, scene: SceneSettings(kind: .gallery)) {
                        $0.virtualGeometry.enabled = virtual
                    }.view(mode).still().frames(8).from(camera))
                }
            }
        }
        return out
    }
}
