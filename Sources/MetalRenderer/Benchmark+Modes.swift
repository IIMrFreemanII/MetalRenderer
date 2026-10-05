import CoreGraphics
import Foundation

/// The benchmark modes: `METALRENDERER_BENCH=<name>` runs that mode's list of settings (`Benchmark.Config`).
/// Setting names become PNG names and the scorers in Tools/eval look them up, so they are part of the interface.
extension Benchmark {
    /// Every mode by name. Any other value of METALRENDERER_BENCH (the documented one is `1`) runs `standard`.
    static let modes: [String: () -> [Config]] = [
        "shot": shot, "quick": quick, "stress": stress, "restir": restir, "rt": rt, "gallery": gallery, "gi": gi,
        "lights": lights, "fog": fog, "sky": sky, "forest": forest, "forestcheck": forestcheck,
        "stressq": stressq, "restirq": restirq, "marketq": marketq, "shadow": shadow,
        "noise": noise, "denoise": denoise, "quality": quality,
        "hwrt": hwrt, "hwrtq": hwrtq, "api": api,
        "restircheck": restircheck, "restirgicheck": restirgicheck, "lightcheck": lightcheck, "speccheck": speccheck, "fogcheck": fogcheck,
        "skycheck": skycheck, "vgdebug": vgdebug, "debugviews": debugViews, "crowd": crowd, "city": city, "world": world, "worldnight": worldNight,
        "worlddusk": worldDusk, "worldground": worldGround, "worldroads": worldRoads, "showcase": showcase, "shapes": shapes,
        "showcasevideo": showcaseVideo, "shapesdemo": shapesDemo, "stressdemo": stressDemo,
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
        Config("MetalFX 2x from 0.75x", upscale: 2),
        Config("default: 3x from 0.5x", scale: 0.5, upscale: 3, gi: .radianceCascades),
        Config("path traced, 3x from 0.5x", scale: 0.5, upscale: 3),
        Config("path traced + white noise", scale: 0.5, upscale: 3) { $0.blueNoise = false },
        Config("0.75x no MetalFX + blue noise"),
        Config("MetalFX 2x from 1.0x", scale: 1.0, upscale: 2),
        Config("MetalFX 3x from 0.67x", scale: 2.0 / 3.0, upscale: 3),
    ] }

    /// One picture of the app's default look (cascades, MetalFX denoiser 3x from 0.5x), paused at t = 5 s, to check
    /// what a change does: the METALRENDERER_* lists pick anything else (scene, GI, view, ...). Its 60 warm-up frames, then
    /// `METALRENDERER_SHOT_FRAMES` (default 30).
    private static func shot() -> [Config] {
        let frames = env["METALRENDERER_SHOT_FRAMES"].flatMap { Int($0) }.map { max(1, $0) } ?? 30
        return [Config("shot", scale: 0.5, upscale: 3, gi: .radianceCascades).still().frames(frames)]
    }

    /// The showcase (Scene+Showcase.swift): every model of Assets/ on its set as the app shows it (cascades, MetalFX 3x
    /// from 0.5x, the look's lens), paused at t = 5 s. The first model also without the lens effects, at 0.75x without
    /// MetalFX (the lens on the composite's light), and with the camera moving. `METALRENDERER_GALLERY="owl|demon"`
    /// picks the models.
    private static func showcase() -> [Config] {
        func shown(_ name: String, _ model: String, scale: CGFloat = 0.5, upscale: CGFloat = 3) -> Config {
            Config(name, scale: scale, upscale: upscale, gi: .radianceCascades, scene: SceneSettings(kind: .showcase, showcase: model))
        }
        let names = Scene.galleryFiles().map(Scene.showcaseName)
        var out = names.map { shown("showcase \($0)", $0).still() }
        if let first = names.first {
            out.append(shown("showcase \(first) no lens", first).with { $0.post = PostSettings() }.still())
            out.append(shown("showcase \(first) native", first, scale: 0.75, upscale: 0).still())
            out.append(shown("showcase \(first) camera", first).cameraMove())
        }
        return out
    }

    /// A video of the showcase: every model for 6 s from t = 2 s, the camera orbiting it, every other frame saved
    /// (`recording`: 180 JPEGs at 30 fps in a folder per model). `METALRENDERER_GALLERY="owl|demon"` picks the models.
    private static func showcaseVideo() -> [Config] {
        Scene.galleryFiles().map(Scene.showcaseName).map { name in
            var c = Config("video \(name)", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: .showcase, showcase: name))
                .cameraMove().recording().frames(360)
            c.startTime = 2
            return c
        }
    }

    /// Fast smoke tests: the default setting, a camera move, path traced, 0.75x native.
    private static func quick() -> [Config] {
        let shown = Config("", scale: 0.5, upscale: 3, gi: .radianceCascades)
        return [
            shown.named("default: 3x from 0.5x"),
            shown.named("camera move").cameraMove(),
            Config("path traced, 3x from 0.5x", scale: 0.5, upscale: 3),
            Config("0.75x, no MetalFX"),
        ]
    }

    /// The stress scene at the default settings (cascades, MetalFX denoiser 3x from 0.5x): frame time against light
    /// count, object count and GI method. `METALRENDERER_BENCH_SPLIT=0` for whole-frame times.
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
    /// (cascades, MetalFX denoiser 3x from 0.5x), 1 to 16384 lights (exact up to 256, grouped up to 4096); then the
    /// night market.
    /// `METALRENDERER_BENCH_SPLIT=0` for whole-frame times.
    private static func restir() -> [Config] {
        func shown(_ name: String, _ scene: SceneSettings, _ mode: DirectLightMode) -> Config {
            Config(name, scale: 0.5, upscale: 3, gi: .radianceCascades, scene: scene).direct(mode)
        }
        var out: [Config] = []
        for lights in [1, 4, 32, 256, 1024, 4096, 16384] {
            let modes: [DirectLightMode] = (lights <= 256 ? [.exact] : []) + (lights <= 4096 ? [.grouped] : []) + [.restir, .megalights]
            out += modes.map { shown("\($0.title.lowercased()), \(lights) lights", stressHall(lights: lights), $0) }
        }
        // The night market (its defaults: cascades, fog), paused so the PNGs compare.
        for lights in [1024, 4096, 16384] {
            for mode in lights <= 4096 ? [DirectLightMode.grouped, .restir, .megalights] : [.restir, .megalights] {
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
            return list + [shown]
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

    /// The forest (generated plants on rolling ground) paused in the morning: from the clearing, from above, close to
    /// a trunk at the clearing's edge, and with four times the trees; then moving (timing), also at the app's 3x.
    /// `METALRENDERER_SCENE=trees=...,seed=...,undergrowth=...` changes the forest.
    private static func forest() -> [Config] {
        let base = Config("", gi: .radianceCascades, scene: SceneSettings(kind: .forest)).still().frames(60)
        let moving = base.named("forest moving").moving()
        return [
            base.named("forest static"),
            base.named("forest aerial").from(forestAerial),
            base.named("forest closeup").from(forestCamera([-6, 1.6, -9], yaw: -0.5, pitch: 0.35)),
            base.named("forest 10k trees").with { $0.scene.trees = 10000 },
            moving,
            moving.named("forest moving 3x").with { $0.renderScale = 0.5; $0.upscaleFactor = 3 },
        ]
    }

    /// The open world (World.swift), paused in the morning: from where it starts (the country outside the first city),
    /// from a street in that city, in the woods, and from above; then a flight of 600 m along the city's edge at
    /// 60 m/s, which crosses two tiles: the scene is made again around each (the log says how long that took); then
    /// the start with the scene's origin elsewhere, and a place 50 km out.
    /// `METALRENDERER_SCENE=seed=...,trees=...,undergrowth=...` changes the world.
    private static func world() -> [Config] {
        let settings = SceneSettings(kind: .world)
        let w = worldOfRun(), home = w.anchorTile, begin = w.start, city = w.city(cell: SIMD2(0, 0))!
        func at(_ x: Double, _ z: Double, up: Float, yaw: Float = 0, pitch: Float) -> Camera {
            worldCamera(w, x, z, up: up, yaw: yaw, pitch: pitch)
        }
        // The first place deep in the woods east of the start.
        var woods = begin.place.x
        while w.woods(woods, begin.place.z) < 0.95 && woods < begin.place.x + 3000 { woods += 16 }
        let base = Config("", gi: .radianceCascades, scene: settings).still().frames(60)
        let flight = base.named("world flight").moving().from(at(begin.place.x, begin.place.z, up: 70, yaw: .pi / 2, pitch: -0.12))
            .flying([60, 0, 0]).frames(600)
        return [
            base.named("world start"),
            base.named("world street").from(at(city.center.x, city.center.y + 40, up: 1.7, pitch: 0.12)),
            base.named("world woods").from(at(woods + 40, begin.place.z, up: 1.7, yaw: .pi / 2, pitch: 0.05)),
            base.named("world aerial").from(at(begin.place.x, begin.place.z + 200, up: 220, pitch: -0.3)),
            flight,
            flight.named("world flight 3x").with { $0.renderScale = 0.5; $0.upscaleFactor = 3 },
            // The scene's origin 2.9 km from where it is: the start again, which should look the same...
            base.named("world moved").with { $0.scene.worldAnchor = home &+ SIMD2(8, -8) },
            // ...and a scene 50 km out, around its own origin.
            base.named("world far").with { $0.scene.worldTile = home &+ SIMD2(160, -120); $0.scene.worldAnchor = home &+ SIMD2(160, -120) },
        ]
    }

    /// A camera `up` metres above the ground at world position (x, z) of `w`, in the coordinates of its start's scene.
    private static func worldCamera(_ w: World, _ x: Double, _ z: Double, up: Float, yaw: Float = 0, pitch: Float) -> Camera {
        let anchor = WorldTile.origin(w.anchorTile.x, w.anchorTile.y)
        var c = Camera()
        c.position = SIMD3(Float(x - anchor.x), w.height(x, z) + up, Float(z - anchor.y))
        c.yaw = yaw
        c.pitch = pitch
        return c
    }

    /// The world the run's scenes are of (`METALRENDERER_SCENE=seed=...`), for placing the cameras in it.
    private static func worldOfRun() -> World {
        var s = RenderSettings()
        SettingsEnv.apply(.scene, to: &s, from: env)
        return World(seed: UInt64(max(s.scene.seed, 0)))
    }

    /// The offset (`RenderSettings.timeOfDay`) that puts a paused setting's clock, at its 5 s, at `phase` of the
    /// open world's day (0 = midnight, 0.5 = noon; the sun sets at 0.81 and rises at 0.19).
    private static func worldTime(_ phase: Float) -> Float {
        let t = phase - Heavens.start - 5 / Heavens.day
        return t - t.rounded(.down)
    }

    /// A view of the open world from (x, z) of the world, `up` over its ground, at `phase` of its day, in a scene made
    /// around the tile it is in.
    private static func worldView(_ name: String, _ w: World, _ x: Double, _ z: Double, up: Float, yaw: Float = 0, pitch: Float,
                                  phase: Float) -> Config {
        let home = w.anchorTile, anchor = WorldTile.origin(home.x, home.y), side = Double(World.tileSize)
        var c = Camera()
        c.position = SIMD3(Float(x - anchor.x), w.height(x, z) + up, Float(z - anchor.y))
        c.yaw = yaw
        c.pitch = pitch
        return Config(name, scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: .world)).still().frames(60).from(c)
            .with {
                $0.scene.worldTile = SIMD2(Int((x / side).rounded(.down)), Int((z / side).rounded(.down)))
                $0.timeOfDay = worldTime(phase)
            }
    }

    /// The open world in the middle of its night, each view in a scene made around its own tile: a street of the
    /// first city, the city from above and from 2 km out (where its buildings are boxes with their lit windows on
    /// them), and a drive of 600 m down that street at 30 m/s, which crosses tiles: the scene's lights are other ones
    /// after each. `METALRENDERER_SHOT_SWAP=<k>` ends the drive `k` frames after its first crossing.
    private static func worldNight() -> [Config] {
        let w = worldOfRun(), city = w.city(cell: SIMD2(0, 0))!
        func view(_ name: String, _ x: Double, _ z: Double, up: Float, yaw: Float = 0, pitch: Float) -> Config {
            worldView(name, w, x, z, up: up, yaw: yaw, pitch: pitch, phase: 0)
        }
        let cx = city.center.x, cz = city.center.y, r = Double(city.radius)
        return [
            view("night street", cx, cz + 40, up: 1.7, pitch: 0.12),
            view("night crossing", cx + 30, cz + 3, up: 1.7, yaw: 0.9, pitch: 0.1),
            view("night aerial", cx, cz + r + 150, up: 180, pitch: -0.3),
            view("night far", cx, cz + r + 1700, up: 60, pitch: 0.0),
            view("night drive", cx, cz + r - 20, up: 1.7, pitch: 0.08).moving().flying([0, 0, -30]).frames(1200),
        ]
    }

    /// The open world's day from afternoon to night and on to the morning, paused at each time: the first city from
    /// above its southern edge, looking over it at the sky where the sun sets, and one of its streets. Then the dusk
    /// as it goes by, from the street and from above: 20 s from before the sun sets until dark, in which the scene is
    /// made again with the city's lights (the log says when) and they come on. `METALRENDERER_SHOT_SWAP=<k>` ends
    /// these `k` frames after that scene is in.
    private static func worldDusk() -> [Config] {
        let w = worldOfRun(), city = w.city(cell: SIMD2(0, 0))!
        let cx = city.center.x, cz = city.center.y, r = Double(city.radius)
        let times: [(String, Float)] = [("afternoon", 0.7), ("evening", 0.78), ("sunset", 0.803), ("lamps on", 0.812), ("dusk", 0.822),
                                        ("twilight", 0.84), ("last light", 0.87), ("midnight", 0), ("first light", 0.14),
                                        ("sunrise", 0.197), ("morning", 0.25)]
        var configs = times.map { worldView("above, \($0.0)", w, cx - 60, cz + r + 120, up: 150, yaw: 0.5, pitch: -0.18, phase: $0.1) }
        configs += times.map { worldView("street, \($0.0)", w, cx, cz + 40, up: 1.7, pitch: 0.12, phase: $0.1) }
        // The clock runs: 20 s of it, from the sun 9 degrees up to 9 under the horizon.
        configs += [
            worldView("street, dusk going by", w, cx, cz + 40, up: 1.7, pitch: 0.12, phase: 0.77).moving().frames(1200),
            worldView("above, dusk going by", w, cx - 60, cz + r + 120, up: 150, yaw: 0.5, pitch: -0.18, phase: 0.77).moving().frames(1200),
        ]
        return configs
    }

    /// The ground of the open world's first city, in the morning: a crossing of two streets from above and from its
    /// corner, a block with a courtyard from above, the city's edge where its last road meets the country, the roads
    /// from over the city and from 2 km out (the coarser tiles'), and the crossing at night.
    private static func worldGround() -> [Config] {
        let w = worldOfRun(), city = w.city(cell: SIMD2(0, 0))!
        let cx = city.center.x, cz = city.center.y, r = Double(city.radius), pitch = World.blockPitch
        // The last built block toward +x in the middle row: the edge is the road beyond it.
        var last = 0
        while w.built(city, last + 1, 0) { last += 1 }
        let edge = cx + Double(Float(last + 1) * pitch.x)
        func view(_ name: String, _ x: Double, _ z: Double, up: Float, yaw: Float = 0, pitch: Float, phase: Float = Heavens.start) -> Config {
            worldView(name, w, x, z, up: up, yaw: yaw, pitch: pitch, phase: phase)
        }
        // The block with a courtyard nearest the city's middle.
        let around = w.blocks(x0: cx - 400, z0: cz - 400, side: 800)?.blocks ?? []
        let court = around.filter { !$0.plan.courts.isEmpty }.map { $0.plan.blocks[0].rect.center }.min { ($0 * $0).sum() < ($1 * $1).sum() } ?? .zero
        return [
            view("ground crossing", cx, cz + 22, up: 30, pitch: -0.95),
            view("ground corner", cx + 4.5, cz + 14, up: 1.7, yaw: -0.5, pitch: -0.12),
            view("ground block", cx + Double(court.x), cz + Double(court.y) + 50, up: 120, pitch: -1.15),
            view("ground edge", edge + 3, cz + 100, up: 12, yaw: 0.25, pitch: -0.12),
            view("ground over", cx, cz + r * 0.5, up: 320, pitch: -0.7),
            view("ground far", cx, cz + r + 1500, up: 250, pitch: -0.12),
            view("ground fields", cx + r + 250, cz + r + 250, up: 90, yaw: -.pi / 4, pitch: -0.25),
            view("ground at night", cx + 4.5, cz + 14, up: 1.7, yaw: -0.5, pitch: -0.12, phase: 0),
        ]
    }

    /// The road from the open world's first city to the next one (World.Highway), in the morning: from the crossing
    /// it leaves the city by and from the fields beyond; before its deepest cutting and its highest bank;
    /// where it first goes into the woods; from above, halfway; all of it from over the city (the further tiles'
    /// roads lie on coarser ground) and from short of the other city; the crossing at night; and a flight of 600 m
    /// along it at 60 m/s, which crosses tiles.
    private static func worldRoads() -> [Config] {
        let w = worldOfRun(), city = w.city(cell: SIMD2(0, 0))!
        guard let road = city.highways.first else {
            print("worldroads: the first city of this world has no city next to it, so no road (try another seed)")
            return []
        }
        // Metres along the road's axis from this city's end of it.
        let out = road.u0 > city.center[road.axis], run = road.u1 - road.u0
        func at(_ along: Double) -> Double { out ? road.u0 + along : road.u1 - along }
        /// From over the road `along` it, looking the way out of the city.
        func view(_ name: String, _ along: Double, up: Float, pitch: Float, phase: Float = Heavens.start) -> Config {
            let (v, slope) = road.across(at(along)), p = road.place(at(along), v), way = road.place(out ? 1 : -1, out ? slope : -slope)
            return worldView(name, w, p.x, p.y, up: up, yaw: Float(atan2(way.x, -way.y)), pitch: pitch, phase: phase)
        }
        // How far the country is over the road (a cutting) or under it (a bank), along it.
        func over(_ along: Double) -> Float {
            let p = road.place(at(along), road.across(at(along)).v)
            return w.country(p.x, p.y) - road.bed(at(along)).level
        }
        let places = Array(stride(from: 150.0, to: run - 150, by: 16))
        let cutting = places.max { over($0) < over($1) } ?? run / 2, bank = places.min { over($0) < over($1) } ?? run / 2
        let woods = places.first { a in
            let p = road.place(at(a), road.across(at(a)).v)
            return w.woods(p.x, p.y) > 0.95
        } ?? run / 2
        let flight = view("road flight", 200, up: 40, pitch: -0.25).moving().flying(SIMD3(road.axis == 0 ? 60 : 0, 0, road.axis == 0 ? 0 : 60) * (out ? 1 : -1))
            .frames(600)
        return [
            view("road gate", -Double(World.Highway.stub) - 8, up: 1.7, pitch: -0.03),
            view("road fields", 120, up: 2.2, pitch: -0.03),
            view("road cutting", cutting - 110, up: 2.2, pitch: 0),
            view("road bank", bank - 220, up: 45, pitch: -0.25),
            view("road woods", woods + 60, up: 2.2, pitch: 0),
            view("road above", run / 2 - 250, up: 180, pitch: -0.55),
            view("road far", -40, up: 160, pitch: -0.2),
            view("road arrival", run - 400, up: 35, pitch: -0.12),
            view("road at night", -Double(World.Highway.stub) - 8, up: 1.7, pitch: -0.03, phase: 0),
            flight,
        ]
    }

    private static func forestCamera(_ position: SIMD3<Float>, yaw: Float = 0, pitch: Float) -> Camera {
        var c = Camera()
        c.position = position
        c.yaw = yaw
        c.pitch = pitch
        return c
    }
    private static let forestAerial = forestCamera([0, 55, 95], pitch: -0.5)

    /// Checks of the forest's plants, paused, without wind or voxels:
    /// * the plants as assemblies and baked into ordinary meshes, from the clearing and from above: the same pictures
    ///   but for float noise (compare the PNGs);
    /// * leaves lit from behind, looking up at the sun through a crown: a path-traced reference, then each GI method.
    ///   The reference shades leaves the same way (a share of them shows its far side's light, `orientNormals`), so
    ///   this checks that the methods agree on it, not the approximation itself;
    /// * the leaves as cards, from the clearing and against the sun;
    /// * the LOD view from above, with the voxels on.
    private static func forestcheck() -> [Config] {
        let still = Config("", gi: .radianceCascades, scene: SceneSettings(kind: .forest)) { $0.foliage.wind = 0; $0.foliage.lod = 0 }
            .still().frames(60)
        // Which leaves show their far side's light goes by the triangle's number, which baking changes: opaque leaves here.
        let parts = still.with { $0.foliage.translucency = 0 }
        let baked = parts.with { $0.scene.bakedPlants = true }
        let lit = still.with { $0.renderScale = 0.5 }.from(forestCamera([-11, 1.6, -30], pitch: 0.85))   // on the trail, under an oak
        return [
            parts.named("assemblies"), baked.named("baked"),
            parts.named("assemblies aerial").from(forestAerial), baked.named("baked aerial").from(forestAerial),
        ] + references([lit.named("backlit ref").with { $0.giMode = .pathTraced }.reference(frames: 512)]) + [
            lit.named("backlit pt").with { $0.giMode = .pathTraced },
            lit.named("backlit cascades"),
            lit.named("backlit restirgi").with { $0.giMode = .restirGI },
            lit.named("backlit opaque").with { $0.foliage.translucency = 0 },
            // Leaves as cards: the same views as "assemblies" and "backlit cascades", to compare with them.
            still.named("cards").with { $0.scene.leafCards = true },
            lit.named("backlit cards").with { $0.scene.leafCards = true },
            // What each plant is traced as: its triangles (blue) or a level of its voxels.
            still.named("lod view").with { $0.foliage.lod = 2 }.from(forestAerial).view(RenderSettings.viewModes.firstIndex(of: "LOD level")!),
            // Metal's tracer: the baked plants, far ones as their voxels (VoxelLOD; off by default), against all of
            // them as triangles.
            parts.named("metal triangles aerial").with { $0.rayTracer = .metal }.from(forestAerial),
            parts.named("metal voxels aerial").with { $0.rayTracer = .metal; $0.scene.voxelBoxes = true; $0.foliage.lod = 2 }
                .from(forestAerial),
            still.named("metal lod view").with { $0.rayTracer = .metal; $0.scene.voxelBoxes = true; $0.foliage.lod = 2 }
                .from(forestAerial).view(RenderSettings.viewModes.firstIndex(of: "LOD level")!),
        ]
    }

    // MARK: - Quality against references

    /// Stress-scene quality, all at t = 5 s against converged references (every light traced each frame; see
    /// Tools/eval/stress.py):
    /// * direct light only (640x400) at 32 and 128 lights;
    /// * the GI methods (640x400, no upscaling) against an 8-bounce path-traced reference;
    /// * MetalFX's denoising scaler (3x from 640x400) on albedo and direct light against supersampled 1920x1200 references.
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
    private static func restirq() -> [Config] {
        [32, 128, 1024, 4096].flatMap { lights -> [Config] in
            let base = Config("", scale: 0.5, gi: nil, scene: stressHall(lights: lights))
            let ref = base.named("ref direct \(lights)").reference(frames: lights <= 128 ? 1024 : lights <= 1024 ? 256 : 2048)
                .with { $0.restir.grid.enabled = false }   // the table alone
            let modes: [DirectLightMode] = (lights <= 128 ? [.exact] : []) + [.grouped, .restir, .megalights]
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
        // MegaLights the same way (its own sampling, no grid).
        let ml = base.direct(.megalights).named("megalights static market").still(previous: true)
        out += [ml, ml.named("megalights moving market").moving(), ml.named("megalights accum market").reference(frames: 64)]
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

    private static let tracers: [(tag: String, kind: RayTracerKind)] = [("custom", .custom), ("metal", .metal)]

    /// Hardware ray tracing against the custom BVH: each ray tracer (the custom BVH, Metal's acceleration structures),
    /// moving frames at 3x from 640x400 through MetalFX's denoising scaler, path traced and with radiance cascades, in
    /// the Cornell room and the stress hall. The tracers alternate, so heat affects them
    /// alike. Settings this GPU can't run are skipped (Capabilities).
    private static func hwrt() -> [Config] {
        var out: [Config] = []
        for (sceneTag, scene) in [("cornell", SceneSettings()), ("stress", stressHall())] {
            for (giTag, gi) in [("pt", GIMode.pathTraced), ("cascades", .radianceCascades)] {
                for tracer in tracers {
                    out.append(Config("\(sceneTag) \(giTag), \(tracer.tag)", scale: 0.5, upscale: 3, gi: gi, scene: scene) {
                        $0.rayTracer = tracer.kind
                    })
                }
            }
        }
        return out
    }

    /// MetalFX's denoising scaler's images, path traced at 3x from 640x400, against supersampled native 1920x1200 references at
    /// t = 5 s (2 bounces, as the frames trace): a still with the frame before it (flicker), the animation running and
    /// the camera move (Tools/eval/hwrt.py). The tracer is METALRENDERER_RT's.
    private static func hwrtq() -> [Config] {
        var out: [Config] = []
        for (sceneTag, scene) in [("cornell", SceneSettings()), ("stress", stressHall())] {
            out += references([Config("\(sceneTag) ref final", scale: 1.5, scene: scene).reference(frames: 1024, supersample: true)])
            let shown = Config("", scale: 0.5, upscale: 3, scene: scene)
            out += scored(shown) { "\(sceneTag) final \($0) denoiser" }
        }
        return out
    }

    /// Metal 3 against Metal 4 (RenderAPI). Paused frames at t = 5 s with METALRENDERER_API's API and METALRENDERER_RT's
    /// tracer (run once per API and compare the PNGs with Tools/eval/pngdiff.py; frame indices must
    /// match, so not in one run), then the same frames through each command model with each ray tracer, moving at 3x
    /// from 640x400 and alternating. Whole-frame times (METALRENDERER_BENCH_SPLIT=0) and the `cpu` column are what
    /// the command model can change.
    private static func api() -> [Config] {
        let scenes = [("cornell cascades", SceneSettings(), GIMode.radianceCascades), ("stress pt", stressHall(), .pathTraced)]
        var out: [Config] = []
        for (sceneTag, scene, gi) in scenes {
            out.append(Config("\(sceneTag) static", scale: 0.5, upscale: 3, gi: gi, scene: scene).still().frames(30))
        }
        for (sceneTag, scene, gi) in scenes {
            for tracer in tracers {
                out += RenderAPI.allCases.map { api in
                    Config("\(sceneTag), \(tracer.tag), \(api.envName)", scale: 0.5, upscale: 3, gi: gi, scene: scene) {
                        $0.rayTracer = tracer.kind
                        $0.api = api
                    }
                }
            }
        }
        return out
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
                Config("\(tag) MetalFX 0.75x x2", upscale: 2),
                Config("\(tag) MetalFX 0.5x x3", scale: 0.5, upscale: 3),
            ].map { tag == "albedo" ? $0.view(4) : $0 }
        }
    }

    // MARK: - Correctness checks

    /// ReSTIR's sampling is unbiased for every light type: accumulated direct light (GI off), every light traced
    /// against ReSTIR's initial sampling without reuse (32 candidates, 4 chains), from the table alone and from the
    /// light grid, in the light-check scenes (one rect / tube / sphere light, or its emissive-mesh twin) and in scenes
    /// with spots, tubes, rects, emissive meshes, a sun and every type together; MegaLights' sampling the same way. Mean
    /// luminance and PSNR should agree (Tools/eval/restir.py).
    private static func restircheck() -> [Config] {
        var scenes: [(String, SceneSettings)] = ["rect", "tube", "sphere", "rect-mesh", "tube-mesh", "sphere-mesh"].map {
            var s = SceneSettings(); s.lightCheck = $0; return ($0, s)
        }
        scenes += [SceneKind.spots, .tubes, .area, .emissive, .mixed].map { ("\($0)", SceneSettings(kind: $0)) }
        scenes.append(("stress32", stressHall()))
        return scenes.flatMap { tag, scene -> [Config] in
            [(DirectLightMode.exact, false), (.restir, false), (.restir, true), (.megalights, false)].map { mode, grid in
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

    /// The SDF shapes scene (Scene+Shapes.swift) on each tracer and API: paused frames to compare between them
    /// (Tools/eval/pngdiff.py: the tracers march the same shapes), path traced, each direct-light method on the glowing
    /// shapes (mesh lights), the normals, materials and traversal cost views, then moving frames and a camera move
    /// for timing.
    private static func shapes() -> [Config] {
        let scene = SceneSettings(kind: .shapes)
        var out: [Config] = []
        for tracer in tracers {
            for api in RenderAPI.allCases {
                let base = Config("", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: scene) {
                    $0.rayTracer = tracer.kind
                    $0.api = api
                }
                let tag = "\(tracer.tag) \(api.envName)"
                out.append(base.named("\(tag) cascades").still())
                guard api == .metal3 else { continue }
                out.append(base.named("\(tag) pt").with { $0.giMode = .pathTraced }.still())
                for mode in [DirectLightMode.restir, .megalights] {
                    out.append(base.named("\(tag) \(mode.title.lowercased())").direct(mode).still())
                }
                for view in ["Normals", "Triangles", "Traversal cost"] {
                    out.append(base.named("\(tag) \(view.lowercased())").view(RenderSettings.viewModes.firstIndex(of: view)!).still().frames(8))
                }
                out += [base.named("\(tag) moving"), base.named("\(tag) camera").cameraMove()]
            }
        }
        return out
    }

    /// The SDF shapes scene's demo video: 30 s along a camera track at the app's look (cascades, 3x from 0.5x to
    /// 1920x1200) with the showcase's lens (`recording`: 900 JPEGs at 30 fps; `.claude/skills/offscreen/scripts/video.sh
    /// -m shapesdemo` makes the mp4).
    /// A wide view, along the primitives, over to the cuts and blends and the baked knot, the glowing ring and lamp,
    /// and back out.
    private static func shapesDemo() -> [Config] {
        func key(_ time: Float, _ position: SIMD3<Float>, _ target: SIMD3<Float>) -> CameraTrack.Key {
            CameraTrack.Key(time: time, position: position, target: target)
        }
        let track = CameraTrack([
            key(0, [0, 4.2, 6.0], [0, 0.4, -2]),
            key(5, [-1.0, 2.6, 3.0], [-1.0, 0.5, -1.5]),
            key(8, [-5.6, 1.0, 1.6], [-3.2, 0.6, -0.6]),
            key(11, [-0.5, 0.9, 1.6], [0.8, 0.6, -0.6]),
            key(14, [4.6, 1.0, 1.4], [2.4, 0.6, -0.8]),
            key(17, [-1.6, 1.7, -1.2], [-2.4, 0.4, -3.0]),
            key(20, [2.2, 1.2, -1.6], [3.2, 0.6, -3.0]),
            key(23, [0.8, 1.4, -0.3], [4.0, 1.3, -4.4]),
            key(26, [-1.0, 1.8, -0.8], [-5.0, 1.2, -5.0]),
            key(30, [0, 4.0, 5.5], [0, 0.6, -2.5]),
        ])
        var demo = Config("shapes demo", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: .shapes)) {
            $0.post = ShowcaseLook.lens
        }.track(track).recording()
        demo.startTime = 2
        return [demo]
    }

    /// The stress building's demo video: a 58 s tour along a camera track at the app's look (cascades, 3x from 0.5x to
    /// 1920x1200, 400 objects, 32 lights) with the showcase's lens (`recording`: 1740 JPEGs at 30 fps;
    /// `.claude/skills/offscreen/scripts/video.sh -m stressdemo` makes the mp4).
    /// From the overview down into a warehouse aisle, across to the factory's walkway between the conveyors and arms,
    /// over into the office, up to the garage's upper deck, and back out. The track keeps above the forklifts' masts
    /// and the arms, over the partitions and under the overhead conveyor (Scene+Stress.swift's `Hall`), and
    /// looks past the walls rather than at them.
    private static func stressDemo() -> [Config] {
        func key(_ time: Float, _ position: SIMD3<Float>, _ target: SIMD3<Float>) -> CameraTrack.Key {
            CameraTrack.Key(time: time, position: position, target: target)
        }
        let track = CameraTrack([
            key(0, [0, 6.8, 19.3], [0, 1.5, 0]),
            key(6, [0, 3.2, 0.5], [-6, 1.5, -6]),
            key(10, [-11.5, 3.0, -3.0], [-11.5, 1.6, -15]),
            key(15, [-11.5, 3.0, -11], [-11.5, 2.0, -19]),
            key(19, [-8, 5.2, -5], [6, 1.5, -11]),
            key(24, [3, 2.6, -11], [12, 1.0, -11]),
            key(29, [9.5, 2.6, -11], [18, 1.2, -11]),
            key(33, [8, 5.6, -3], [10, 0.5, 14]),
            key(37, [12, 4.4, 4.5], [12, 0.8, 12]),
            key(41, [4.5, 2.2, 11.4], [15, 1.4, 11.4]),
            key(44, [2.5, 5.6, 11.5], [-10, 3.3, 13]),
            key(47, [0, 6.0, 12], [-10, 3.3, 13]),
            key(52, [-9.5, 5.4, 18.6], [-9.5, 3.5, 4]),
            key(58, [0, 6.8, 19.3], [0, 1.5, 0]),
        ])
        var demo = Config("stress demo", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: .stress)) {
            $0.post = ShowcaseLook.lens
        }.track(track).recording()
        demo.startTime = 2
        return [demo]
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
            let still = base.still(previous: true).frames(60)
            return references([base.named("\(kind) ref").reference(frames: 1024)]) + [
                still.named("\(kind) shadow denoiser"),
                still.named("\(kind) svgf").with { $0.denoiser.shadowDenoiser = false },
                still.named("\(kind) restir").direct(.restir),
                still.named("\(kind) megalights").direct(.megalights),
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

    /// The crowd scene (animated characters, Crowd.swift) at the default settings, the animation running: frame time
    /// against the number of poses the GPU animates ("skin": their matrices and vertices, "blas": their acceleration
    /// structures), against the number of characters on them ("tlas", "trace", and the CPU's share in "cpu") and
    /// against the poses' level of detail. Then the frames to look at: a still with the frame before it, and the
    /// camera moving through the crowd. `METALRENDERER_CROWD_CHECK=1` compares what the GPU skinned with the CPU's.
    private static func crowd() -> [Config] {
        func square(_ name: String, characters: Int = 2048, poses: Int = 64, detail: Int = 3) -> Config {
            Config(name, scale: 0.5, upscale: 3, gi: .radianceCascades,
                   scene: SceneSettings(kind: .crowd, characters: characters, poses: poses, detail: detail))
        }
        return [8, 32, 64, 128, 256].map { square("\($0) poses", poses: $0) }
            + [256, 8192, 32768, 131_072].map { square("\($0) characters", characters: $0) }
            + [1, 0].map { square("32 poses, detail \($0)", poses: 32, detail: $0) }
            + [square("still").still(previous: true), square("camera move").cameraMove()]
    }

    /// The generated city (Scene+City.swift, CityPlan, BuildingGenerator). First the frames to look at: the default
    /// city from above, from the road and in front of one building; a block of each style, close and whole; the same
    /// street with flat colours instead of the generated textures; the city at night, and with more rooms behind its
    /// windows (the frame before too: the windows' light is ReSTIR's). Then frame time against the city's size, by
    /// day ("glass" is its panes' pass) and at night, and the camera moving over it.
    private static func city() -> [Config] {
        func town(_ name: String, night: Bool = false, _ change: (inout CitySettings) -> Void = { _ in }) -> Config {
            var city = CitySettings()
            change(&city)
            return Config(name, scale: 0.5, upscale: 3, gi: .radianceCascades,
                          scene: SceneSettings(kind: night ? .cityNight : .city, city: city))
        }
        /// `c`, paused, seen from one of its city's own viewpoints.
        func seen(_ view: CityPlan.View, _ c: Config, previous: Bool = false) -> Config {
            c.from(CityPlan(c.settings.scene.city, seed: c.settings.scene.seed).camera(view)).still(previous: previous)
        }
        let styles = CityStyle.allCases.filter { $0 != .mixed }
        let looks = [seen(.overview, town("overview")), seen(.street, town("street")), seen(.facade, town("facade"))]
            + styles.map { style in seen(.facade, town("\(style)") { $0.blocks = 1; $0.style = style }) }
            + styles.map { style in seen(.overview, town("\(style) block") { $0.blocks = 1; $0.style = style }) }
            + [seen(.street, town("flat street") { $0.textures = false }),
               seen(.overview, town("night", night: true), previous: true),
               seen(.street, town("night street", night: true), previous: true),
               seen(.facade, town("night rooms", night: true) { $0.rooms = 0.5; $0.lit = 0.6 }, previous: true)]
        let sizes = [1, 2, 4, 6, 8, 10].map { n in town("\(n) x \(n) blocks") { $0.blocks = n } }
            + [4, 10].map { n in town("night, \(n) x \(n) blocks", night: true) { $0.blocks = n } }
        return looks + sizes + [town("camera move").cameraMove()]
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

    /// Every view mode, as the app draws it (radiance cascades, MetalFX denoiser 3x from 0.5x), on each ray tracer in
    /// the scenes with levels of detail: the gallery's virtual meshes, the forest's plants, the crowd's characters and the
    /// open world's tiles. Then the views that depend on the GI method with each method.
    private static func debugViews() -> [Config] {
        var out: [Config] = []
        let views = RenderSettings.viewModes.indices
        for tracer in tracers {
            for kind in [SceneKind.gallery, .forest, .crowd, .world] {
                for mode in views {
                    let name = "\(tracer.tag) \(kind.title.lowercased()) \(RenderSettings.viewModes[mode].lowercased())"
                    out.append(Config(name, scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: kind)) {
                        $0.rayTracer = tracer.kind
                    }.view(mode).still().frames(8))
                }
            }
        }
        // The open world from 900 m above its start, looking well down: its tiles' three levels in rings around the
        // camera's tile (the scene is made around that tile: a camera elsewhere would move its middle).
        let w = worldOfRun()
        let aerial = worldCamera(w, w.start.place.x, w.start.place.z, up: 900, pitch: -1.0)
        for tracer in tracers {
            for mode in [9, 11] {
                out.append(Config("\(tracer.tag) open world aerial \(RenderSettings.viewModes[mode].lowercased())", scale: 0.5, upscale: 3,
                                  gi: .radianceCascades, scene: SceneSettings(kind: .world)) { $0.rayTracer = tracer.kind }
                    .view(mode).still().frames(8).from(aerial))
            }
        }
        for (tag, gi) in [("pt", GIMode.pathTraced), ("restir gi", .restirGI), ("cascades", .radianceCascades)] {
            for mode in [1, 2, 5, 6, 7] {
                out.append(Config("\(tag) cornell \(RenderSettings.viewModes[mode].lowercased())", scale: 0.5, upscale: 3, gi: gi)
                    .view(mode).still().frames(8))
            }
        }
        return out
    }
}
