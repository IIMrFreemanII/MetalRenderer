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
    // MARK: - Timing

    /// The default list: GI bounces, denoiser, render scale, MetalFX.
    static func standard() -> [Config] { [
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
    static func shot() -> [Config] {
        let frames = env["METALRENDERER_SHOT_FRAMES"].flatMap { Int($0) }.map { max(1, $0) } ?? 30
        return [Config("shot", scale: 0.75, upscale: 2, gi: .radianceCascades).still().frames(frames).appLook()]
    }

    /// The dev build's hot reload, checked offscreen: `shot`'s picture again and again (`METALRENDERER_RELOAD_SHOTS`,
    /// default 6, each after `METALRENDERER_RELOAD_FRAMES`, default 600), with METALRENDERER_HOTRELOAD=1 so the
    /// watcher runs. A save between two shows in the next ones (DevReload).
    static func reload() -> [Config] {
        let shots = env["METALRENDERER_RELOAD_SHOTS"].flatMap { Int($0) }.map { max(1, $0) } ?? 6
        let frames = env["METALRENDERER_RELOAD_FRAMES"].flatMap { Int($0) }.map { max(1, $0) } ?? 600
        return (1...shots).map { Config("reload \($0)", scale: 0.75, upscale: 2, gi: .radianceCascades).still().frames(frames).appLook() }
    }

    /// Solid shading (RenderSettings.solid) against the look each scene opens with, moving: the physics scene (its
    /// physics look), the destruction courtyard, the city, the crowd (skinned characters) and the stress building's
    /// rooms, then those rooms again with the look back on (the scene stays: solid shading turned off live). Time whole
    /// frames with METALRENDERER_BENCH_SPLIT=0; each setting leaves its last frame.
    static func solid() -> [Config] {
        func app(_ kind: SceneKind) -> Config { Config("", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: kind)) }
        let looks: [(String, Config)] = [
            ("physics", Config("", scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: SceneSettings(kind: .physics)) { $0.usePhysicsLook() }),
            ("destruction", app(.destruction)), ("city", app(.city)), ("crowd", app(.crowd)), ("stress", app(.stress)),
        ]
        return looks.flatMap { name, look in [look.named(name), look.named("\(name) solid").with { $0.solid = true }] }
            + [app(.stress).named("stress after solid")]
    }

    /// The showcase (Scene+Showcase.swift): every model of Assets/ on its set as the app shows it (cascades, MetalFX 3x
    /// from 0.5x, the look's lens), paused at t = 5 s. The first model also without the lens effects, at 0.75x without
    /// MetalFX (the lens on the composite's light), and with the camera moving. `METALRENDERER_GALLERY="owl|demon"`
    /// picks the models.
    static func showcase() -> [Config] {
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
    static func showcaseVideo() -> [Config] {
        Scene.galleryFiles().map(Scene.showcaseName).map { name in
            var c = Config("video \(name)", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: .showcase, showcase: name))
                .cameraMove().recording().frames(360)
            c.startTime = 2
            return c
        }
    }

    /// Fast smoke tests: the default setting, a camera move, path traced, 0.75x native.
    static func quick() -> [Config] {
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
    static func stress() -> [Config] {
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
    static func restir() -> [Config] {
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

    /// The glTF gallery: full-detail meshes against virtual geometry at several error thresholds, alternating so heat
    /// affects them alike. Paused frames at t = 5 s (PNGs for diffs), then the scripted camera move and close-ups.
    static func gallery() -> [Config] {
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
    static func gi() -> [Config] {
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

    /// The app's Reference pictures (README "Reference rendering"), paused at t = 5 with the default camera: "Path
    /// traced" and "Accumulated passes" side by side in scenes with glossy materials, every light type, emissive
    /// meshes, window glass, fog and thousands of lights; then the path tracer with the clock running and with the
    /// camera moving, where every frame starts over (one path per pixel). `METALRENDERER_PATHREF_FRAMES` sets the
    /// stills' frames (512).
    static func pathref() -> [Config] {
        let frames = Int(env["METALRENDERER_PATHREF_FRAMES"] ?? "") ?? 512
        let kinds: [SceneKind] = [.cornell, .gallery, .area, .mixed, .emissive, .stress, .fog, .market]
        let stills = kinds.flatMap { kind -> [Config] in
            let scene = kind == .stress ? stressHall() : SceneSettings(kind: kind)
            let pt = Config("\(kind) pt", scale: 0.5, scene: scene) { $0.reference.mode = .pathTraced }.still().frames(frames)
            return [pt, pt.named("\(kind) accumulated").with { $0.reference.mode = .accumulated }]
        }
        var moving = Config("cornell pt moving", scale: 0.5) { $0.reference.mode = .pathTraced }.frames(30)
        moving.capturePrevious = true   // (each frame's paths are new ones: the two frames' noise differs)
        return stills + [moving, moving.named("cornell pt camera").cameraMove()]
    }

    /// The light demo scenes, paused at t = 5: direct light only, each GI technique, then moving (timing).
    /// `METALRENDERER_LIGHTS_SCENES="sun|mixed"` limits the scenes.
    static func lights() -> [Config] {
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
    static func fog() -> [Config] {
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
    static func sky() -> [Config] {
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
    static func forest() -> [Config] {
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

    /// The building workshop (Scene+Buildings.swift) as the building editor shows it (cascades, MetalFX 3x from 0.5x),
    /// paused: each style's building from outside, a street of them, the cutaway and the dollhouse, and inside: a
    /// living room by day and by night, the stair, an office floor.
    static func buildings() -> [Config] {
        func shown(_ name: String, _ change: (inout BuildingSceneSettings) -> Void = { _ in }) -> Config {
            var scene = SceneSettings(kind: .buildings)
            change(&scene.buildings)
            return Config("buildings \(name)", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: scene).still().frames(30)
        }
        /// Standing in a corner of the first room of `type` on `storey` (a lit one, if `lit`), looking across it to the
        /// far corner; `transform`: the lot's into the world.
        func inside(_ spec: BuildingSpec, _ type: RoomType, storey: Int, lit: Bool = false, transform: float4x4 = matrix_identity_float4x4) -> Camera {
            let plan = BuildingGenerator.generate(spec).plan
            let f = plan.storeys[min(storey, plan.storeys.count - 1)]
            let rooms = f.rooms.filter { $0.type == type }
            let r = ((lit ? rooms.first { $0.lit } : nil) ?? rooms.max { $0.area < $1.area } ?? f.rooms.max { $0.area < $1.area }!).rect
            let a = transform * SIMD4(r.lo.x + 0.5, f.floor + 1.6, r.lo.y + 0.5, 1), b = transform * SIMD4(r.hi.x - 0.3, f.floor + 1.0, r.hi.y - 0.3, 1)
            let v = SIMD3(b.x - a.x, b.y - a.y, b.z - a.z), d = v / (v * v).sum().squareRoot()
            var c = Camera()
            c.position = SIMD3(a.x, a.y, a.z)
            c.yaw = atan2(d.x, -d.z)
            c.pitch = asin(d.y)
            return c
        }
        func inside(_ p: BuildingSceneSettings, _ type: RoomType, storey: Int, lit: Bool = false) -> Camera {
            inside(Scene.workshopSpec(p, catalog: .builtIn).spec, type, storey: storey, lit: lit)
        }
        // A city, and the building of its first residential lot on a street with its interior: from inside it.
        var city = CitySettings()
        (city.blocks, city.style) = (2, .residential)
        let cityPlan = CityPlan(city, seed: 1)
        let lotIndex = cityPlan.lots.firstIndex { $0.edges[0] == .street } ?? 0
        let lot = cityPlan.lots[lotIndex]
        var inCity = SceneSettings(kind: .city, city: city, seed: 1)
        inCity.interior = LotRef.city(city, seed: 1, lot: lotIndex, lot).key
        var citySpec = BuildingSpec(lot: lot, city: city, night: false, catalog: .builtIn)
        citySpec.interior = true
        var home = BuildingSceneSettings()
        (home.style, home.lot, home.floors) = ("residential", SIMD2(22, 14), 5)
        var office = BuildingSceneSettings()
        (office.style, office.lot, office.sides, office.floors) = ("office", SIMD2(34, 30), .free, 12)
        var night = home
        night.night = true
        return [
            shown("residential") { $0 = home },
            shown("oldtown") { $0.style = "oldtown"; $0.lot = SIMD2(9, 12); $0.floors = 3 },
            shown("modern street") { $0.style = "modern"; $0.lot = SIMD2(24, 15); $0.floors = 6; $0.layout = .street },
            shown("office") { $0 = office },
            shown("warehouse") { $0.style = "warehouse"; $0.lot = SIMD2(34, 28); $0.sides = .free; $0.floors = 2 },
            shown("cutaway") { $0 = home; $0.view = .cutaway; $0.cut = 1 },
            shown("dollhouse") { $0 = home; $0.view = .dollhouse; $0.cut = 1 },
            shown("living room") { $0 = home }.from(inside(home, .living, storey: 1)),
            shown("living room night") { $0 = night }.from(inside(night, .living, storey: 1, lit: true)),
            shown("bedroom night") { $0 = night }.from(inside(night, .bedroom, storey: 2, lit: true)),
            shown("stair") { $0 = home }.from(inside(home, .corridor, storey: 1)),
            shown("storeroom") { $0 = home }.from(inside(home, .storage, storey: storageStorey(home))),
            shown("office floor") { $0 = office }.from(inside(office, .openOffice, storey: 3)),
            Config("buildings city interior", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: inCity).still().frames(30)
                .from(inside(citySpec, .living, storey: 1, transform: lot.transform)),
        ] + worldInterior { inside($0, $1, storey: $2, lit: $3, transform: $4) }
    }

    /// The lowest storey of the workshop's building `p` with a storeroom (0 if none has one).
    private static func storageStorey(_ p: BuildingSceneSettings) -> Int {
        let plan = BuildingGenerator.generate(Scene.workshopSpec(p, catalog: .builtIn).spec).plan
        return plan.storeys.firstIndex { $0.rooms.contains { $0.type == .storage } } ?? 0
    }

    /// Inside the workshop's home while the camera turns fast, as the window shows it moved by hand at 11-14 fps (5 and 12
    /// degrees a frame on the 60 Hz clock): round living rooms, through their doors, and round storerooms' racks (one
    /// with a window, one lit only through its door). Recorded.
    /// "user": the look the window ran with (traced at the window's 1280x800, MetalFX 2x); "default": the app's (0.5x,
    /// MetalFX 3x), both with Auto direct light. The cascades' interior history and the room lights at GI's hits under
    /// the shelves show here.
    static func interiorMotion() -> [Config] {
        var home = BuildingSceneSettings()
        (home.style, home.lot, home.floors) = ("residential", SIMD2(20, 14), 5)
        var scene = SceneSettings(kind: .buildings)
        scene.buildings = home
        let plan = BuildingGenerator.generate(Scene.workshopSpec(home, catalog: .builtIn).spec).plan
        /// Standing in a corner of the room, the view swings 46 degrees either side of its far corner, back and forth,
        /// every `sweep` seconds, for 10 sweeps (0.3 s: 5 degrees a frame; 0.13 s: 12, a quick turn at the window's 14 fps).
        func pan(_ r: CityPlan.Rect, floor: Float, sweep: Float) -> CameraTrack {
            let eye = SIMD3(r.lo.x + 0.5, floor + 1.6, r.lo.y + 0.5)
            let far = SIMD3(r.hi.x - 0.3, floor + 1.0, r.hi.y - 0.3) - eye
            let yaw = atan2(far.z, far.x), swing: Float = 0.8
            let keys = (0...10).map { k -> CameraTrack.Key in
                let a = yaw + (k % 2 == 0 ? -swing : swing)
                return CameraTrack.Key(time: Float(k) * sweep, position: eye, target: eye + SIMD3(cos(a), -0.15, sin(a)))
            }
            return CameraTrack(keys, linear: true)
        }
        /// The biggest room of `type` on the lowest storey with one that `keep` takes.
        func room(_ type: RoomType, _ keep: (PlanRoom, FloorPlan) -> Bool = { _, _ in true }) -> (CityPlan.Rect, Float)? {
            for f in plan.storeys {
                if let r = f.rooms.filter({ $0.type == type && keep($0, f) }).max(by: { $0.area < $1.area }) { return (r.rect, f.floor) }
            }
            return nil
        }
        /// No outer wall, so no window: lit only through its door (a dark storeroom).
        func inner(_ r: PlanRoom, _ f: FloorPlan) -> Bool {
            let lo = f.usable.map(\.lo).reduce(SIMD2<Float>(repeating: .infinity)) { simd_min($0, $1) }
            let hi = f.usable.map(\.hi).reduce(SIMD2<Float>(repeating: -.infinity)) { simd_max($0, $1) }
            return all(r.rect.lo .> lo + 0.2) && all(r.rect.hi .< hi - 0.2)
        }
        let rooms: [(String, (CityPlan.Rect, Float)?)] = [
            ("living room", room(.living)), ("storeroom", room(.storage)), ("dark storeroom", room(.storage, inner)),
            ("top living room", plan.storeys.reversed().lazy.compactMap { f in
                f.rooms.filter { $0.type == .living }.max { $0.area < $1.area }.map { ($0.rect, f.floor) } }.first),
        ]
        var out: [Config] = []
        for (name, found) in rooms {
            guard let (r, floor) = found else { continue }
            let track = pan(r, floor: floor, sweep: 0.3)
            out.append(Config("interior motion \(name) user", scale: 1, upscale: 2, gi: .radianceCascades, scene: scene)
                .track(track).recording())
            out.append(Config("interior motion \(name) user fast", scale: 1, upscale: 2, gi: .radianceCascades, scene: scene)
                .track(pan(r, floor: floor, sweep: 0.13)).recording())
            out.append(Config("interior motion \(name) default", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: scene)
                .track(track).recording())
        }
        return out
    }

    /// A walk in the workshop's home from a living room (sunlit) through the doors into a storeroom with no window (lit
    /// only through its door), 3 s there, and back: auto exposure going from a bright room to a dark one and back.
    /// "user": the window's look (traced at 1280x800, MetalFX 2x); "default": the app's. Recorded.
    static func exposureWalk() -> [Config] {
        var home = BuildingSceneSettings()
        (home.style, home.lot, home.floors) = ("residential", SIMD2(20, 14), 5)
        var scene = SceneSettings(kind: .buildings)
        scene.buildings = home
        let plan = BuildingGenerator.generate(Scene.workshopSpec(home, catalog: .builtIn).spec).plan
        func inner(_ r: PlanRoom, _ f: FloorPlan) -> Bool {
            let lo = f.usable.map(\.lo).reduce(SIMD2<Float>(repeating: .infinity)) { simd_min($0, $1) }
            let hi = f.usable.map(\.hi).reduce(SIMD2<Float>(repeating: -.infinity)) { simd_max($0, $1) }
            return all(r.rect.lo .> lo + 0.2) && all(r.rect.hi .< hi - 0.2)
        }
        for (s, f) in plan.storeys.enumerated() {
            guard let dark = f.rooms.firstIndex(where: { $0.type == .storage && inner($0, f) }),
                  let lit = f.rooms.indices.filter({ f.rooms[$0].type == .living }).max(by: { f.rooms[$0].area < f.rooms[$1].area })
            else { continue }
            var walk = DemoWalk(plan: plan)
            walk.go(f.rooms[lit].rect.center, storey: s)
            walk.wait(1.5)
            walk.route(storey: s, from: lit, to: dark)
            walk.go(f.rooms[dark].rect.center, storey: s)
            walk.wait(3)
            walk.route(storey: s, from: dark, to: lit)
            walk.go(f.rooms[lit].rect.center, storey: s)
            walk.wait(2)
            let track = walk.track(.identity).track
            return [
                Config("exposure walk user", scale: 1, upscale: 2, gi: .radianceCascades, scene: scene)
                    .track(track).walking().recording(),
                Config("exposure walk default", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: scene)
                    .track(track).walking().recording(),
            ]
        }
        return []
    }

    /// The workshop's home's storeroom with no window (lit only through its door), paused, with the window's look
    /// (traced at 1280x800, MetalFX 2x) and the app's: across to its racks (shiny shelves in the dark) and up
    /// at a ceiling corner (the light of the rooms round it must not come through its walls); "indirect": that corner's
    /// raw indirect light (view 2).
    static func darkRoom() -> [Config] {
        var home = BuildingSceneSettings()
        (home.style, home.lot, home.floors) = ("residential", SIMD2(20, 14), 5)
        var scene = SceneSettings(kind: .buildings)
        scene.buildings = home
        let plan = BuildingGenerator.generate(Scene.workshopSpec(home, catalog: .builtIn).spec).plan
        for f in plan.storeys {
            let lo = f.usable.map(\.lo).reduce(SIMD2<Float>(repeating: .infinity)) { simd_min($0, $1) }
            let hi = f.usable.map(\.hi).reduce(SIMD2<Float>(repeating: -.infinity)) { simd_max($0, $1) }
            guard let r = f.rooms.first(where: { $0.type == .storage && all($0.rect.lo .> lo + 0.2) && all($0.rect.hi .< hi - 0.2) })?.rect
            else { continue }
            func look(from a: SIMD3<Float>, at b: SIMD3<Float>) -> Camera {
                let d = simd_normalize(b - a)
                var c = Camera()
                c.position = a
                c.yaw = atan2(d.x, -d.z)
                c.pitch = asin(d.y)
                return c
            }
            let racks = look(from: SIMD3(r.lo.x + 0.4, f.floor + 1.6, r.lo.y + 0.4), at: SIMD3(r.hi.x - 0.3, f.floor + 1.0, r.hi.y - 0.3))
            let corner = look(from: SIMD3(r.center.x, f.floor + 1.5, r.center.y), at: SIMD3(r.hi.x, f.ceiling, r.hi.y))
            func shown(_ name: String, user: Bool) -> Config {
                user ? Config("dark room \(name) user", scale: 1, upscale: 2, gi: .radianceCascades, scene: scene).still().frames(30)
                     : Config("dark room \(name) default", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: scene).still().frames(30)
            }
            return [shown("racks", user: true).from(racks), shown("ceiling", user: true).from(corner),
                    shown("ceiling indirect", user: true).from(corner).view(2),
                    shown("racks", user: false).from(racks), shown("ceiling", user: false).from(corner)]
        }
        return []
    }

    /// The open world with the building nearest where it starts walkable: from inside it (its tile without its shell).
    private static func worldInterior(_ inside: (BuildingSpec, RoomType, Int, Bool, float4x4) -> Camera) -> [Config] {
        guard let (scene, spec, transform) = worldInteriorLot() else { return [] }
        return [Config("buildings world interior", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: scene).still().frames(30)
            .from(inside(spec, .living, 1, false, transform))]
    }

    /// The open world's scene with the building (3 floors or more) nearest where the world starts walkable, that
    /// building's spec (with its interior), and its lot's place in the scene.
    static func worldInteriorLot() -> (scene: SceneSettings, spec: BuildingSpec, transform: float4x4)? {
        var scene = SceneSettings(kind: .world)
        let world = World(seed: UInt64(max(scene.seed, 0)))
        let side = Double(World.tileSize), begin = world.start.place
        let home = SIMD2(Int((begin.x / side).rounded(.down)), Int((begin.z / side).rounded(.down)))
        let anchor = WorldTile.origin(world.anchorTile.x, world.anchorTile.y)
        var best: (distance: Double, ref: LotRef, lot: CityPlan.Lot, city: World.City)?
        for j in -1...1 {
            for i in -1...1 {
                let o = WorldTile.origin(home.x + i, home.y + j)
                guard let (city, blocks) = world.blocks(x0: o.x, z0: o.y, side: side) else { continue }
                for block in blocks {
                    for (k, lot) in block.plan.lots.enumerated() where lot.floors >= 3 && lot.style != .warehouse {
                        let c = city.center + SIMD2(Double(lot.rect.center.x), Double(lot.rect.center.y))
                        let d = ((c.x - begin.x) * (c.x - begin.x) + (c.y - begin.z) * (c.y - begin.z)).squareRoot()
                        if d < best?.distance ?? .infinity { best = (d, world.lotRef(city, block, k), lot, city) }
                    }
                }
            }
        }
        guard let (_, ref, lot, city) = best else { return nil }
        scene.interior = ref.key
        var spec = BuildingSpec(lot: lot, city: scene.city, night: true, catalog: .builtIn)
        spec.interior = true
        let c = SIMD2(Float(city.center.x - anchor.x), Float(city.center.y - anchor.y))
        return (scene, spec, translate([c.x, city.level, c.y]) * lot.transform)
    }

    /// The plant workshop (Scene+Plants.swift) as the plant editor shows it (cascades, MetalFX 3x from 0.5x), paused:
    /// an oak, a birch's ages and variants, a conifer's skeleton, a bush, ferns, grass, and a species of a catalog of
    /// its own (a willow: a birch whose twigs hang). `METALRENDERER_PLANTS=builtin` leaves out what Assets/Plants holds.
    /// The character workshop: each built-in character in the A pose, the first's face close, everyone side by side,
    /// and the first walking and in a clip of the library.
    static func characters() -> [Config] {
        func shown(_ name: String, _ change: (inout CharacterSceneSettings) -> Void = { _ in }) -> Config {
            var scene = SceneSettings(kind: .characters)
            scene.characterCatalog = "builtin"
            change(&scene.characterWorkshop)
            // Close-ups at full resolution (pores and wrinkles are a texel or two of an upscaled frame).
            let close = scene.characterWorkshop.view == .face
            return Config("characters \(name)", scale: close ? 1.5 : 0.5, upscale: close ? 0 : 3, gi: .radianceCascades, scene: scene)
                .still().frames(30)
        }
        // A built-in changed (hair styles, beards, marks the built-ins don't have), its face close.
        func styled(_ name: String, from id: String, _ change: (inout CharacterDNA) -> Void) -> Config {
            var d = BuiltInCharacters.all.first { $0.id == id }!
            change(&d)
            var c = shown("hair \(name)") { $0.character = id; $0.view = .face }
            c.settings.scene.characterCatalog = CharacterCatalog.register(CharacterCatalog(characters: [d]))
            return c
        }
        return BuiltInCharacters.all.map { def in shown(def.id) { $0.character = def.id } } + [
            shown("man face") { $0.view = .face },
            shown("woman face") { $0.character = "woman"; $0.view = .face },
            shown("elder face") { $0.character = "elder"; $0.view = .face },
            shown("heavy face") { $0.character = "heavy"; $0.view = .face },
            shown("man smiling") { $0.view = .face; $0.expression = .smile },
            shown("man frowning") { $0.view = .face; $0.expression = .frown },
            shown("man surprised") { $0.view = .face; $0.expression = .surprise },
            shown("man talking") { $0.view = .face; $0.expression = .talk },
            viewed(shown("man face three quarters") { $0.view = .face }, look(from: [0.3, 1.7, 0.42], at: [0, 1.66, 0.04])),
            viewed(shown("man face side") { $0.view = .face }, look(from: [0.5, 1.68, 0.05], at: [0, 1.665, 0.03])),
            viewed(shown("man ear") { $0.view = .face }, look(from: [0.3, 1.7, -0.25], at: [0.07, 1.67, -0.01])),
            viewed(shown("woman face three quarters") { $0.character = "woman"; $0.view = .face }, look(from: [-0.3, 1.62, 0.4], at: [0, 1.58, 0.04])),
            shown("everyone") { $0.layout = .lineup },
            shown("everyone caps") { $0.layout = .lineup; $0.hair = .caps },
            styled("long", from: "woman") { $0.hair.style = "long"; $0.look.hairMelanin = 0.3 },
            styled("slicked stubble", from: "man") { $0.hair.style = "slicked"; $0.hair.beard = "stubble" },
            styled("goatee", from: "athlete") { $0.hair.beard = "goatee" },
            styled("moustache grey", from: "man") { $0.hair.style = "sidePart"; $0.hair.beard = "moustache"; $0.macro.age = 62 },
            styled("curly red freckles", from: "woman") { $0.hair.style = "curly"; $0.look.hairRed = 0.9; $0.look.hairMelanin = 0.35; $0.look.freckles = 1 },
            viewed(styled("long behind", from: "woman") { $0.hair.style = "long"; $0.look.hairMelanin = 0.3 },
                   look(from: [0.35, 1.55, -0.6], at: [0, 1.45, 0])),
            shown("woman face caps") { $0.character = "woman"; $0.view = .face; $0.hair = .caps },
            shown("man t pose") { $0.pose = .tPose },
            shown("man walking") { $0.pose = .walk },
            shown("woman dancing") { $0.character = "woman"; $0.pose = .clip; $0.clip = "Hip Hop Dancing" },
            viewed(shown("man side") { $0.pose = .tPose }, look(from: [3.2, 1.1, 0], at: [0, 1.0, 0])),
            viewed(shown("man back") { $0.pose = .tPose }, look(from: [0.3, 1.3, -3.4], at: [0, 1.0, 0])),
            viewed(shown("man hand") { $0.pose = .tPose }, look(from: [0.75, 1.75, 0.35], at: [0.75, 1.42, 0])),
            viewed(shown("man hand below") { $0.pose = .tPose }, look(from: [0.72, 1.1, 0.25], at: [0.75, 1.42, 0])),
            viewed(shown("woman waist") { $0.character = "woman"; $0.pose = .tPose }, look(from: [0.55, 1.15, 0.75], at: [0.1, 1.08, 0])),
            viewed(shown("woman shoulder") { $0.character = "woman"; $0.pose = .tPose }, look(from: [0.35, 1.75, 0.6], at: [0.1, 1.42, 0])),
        ]
    }

    /// `config` seen from `camera`.
    static func viewed(_ config: Config, _ camera: Camera) -> Config {
        var c = config
        c.camera = camera
        return c
    }

    /// A camera at `from` looking at `at`.
    static func look(from: SIMD3<Float>, at: SIMD3<Float>) -> Camera {
        let d = simd_normalize(at - from)
        var c = Camera()
        c.position = from
        c.yaw = atan2(d.x, -d.z)
        c.pitch = asin(d.y)
        return c
    }

    static func plants() -> [Config] {
        func shown(_ name: String, _ change: (inout PlantSceneSettings) -> Void = { _ in }) -> Config {
            var scene = SceneSettings(kind: .plants)
            change(&scene.plants)
            return Config("plants \(name)", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: scene).still().frames(30)
        }
        var willow = PlantCatalog.launch
        var def = PlantCatalog.builtIn[.birch]
        def.id = "willow"
        def.name = "Willow"
        def.seedIndex = 100
        // (A weeping birch: branches that turn to the ground and sag, twigs that hang straight down.)
        def.growth?.branch?.gravitropism = -0.35
        def.growth?.branch?.phototropism = 0
        def.growth?.branch?.axilAngle = 0.6
        def.growth?.gravity = 1.2
        def.twigs?.growth.trunk.gravitropism = -0.7
        def.twigs?.growth.branch?.gravitropism = -0.7
        def.twigs?.angle = 0.35
        willow = willow.merging([def])
        let catalog = PlantCatalog.register(willow)
        return [
            shown("oak"),
            shown("oak to scale") { $0.figure = true; $0.ruler = true },
            // (Leaves at arm's length, in the crown's lower edge: their shapes and shading.)
            viewed(shown("oak leaves"), look(from: [3.4, 7.8, 3.6], at: [1.2, 8.4, 1.0])),
            shown("birch lineup") { $0.species = "birch"; $0.layout = .lineup },
            shown("conifer skeleton") { $0.species = "conifer"; $0.view = .skeleton },
            shown("bush") { $0.species = "bush" },
            shown("fern") { $0.species = "fern" },
            shown("grass") { $0.species = "grass" },
            shown("willow") { $0.species = "willow" }.with { $0.scene.plantCatalog = catalog },
        ]
    }

    /// The open world (World.swift), paused in the morning: from where it starts (the country outside the first city),
    /// from a street in that city, in the woods, and from above; then a flight of 600 m along the city's edge at
    /// 60 m/s, which crosses two tiles: the scene is made again around each (the log says how long that took); then
    /// the start with the scene's origin elsewhere, and a place 50 km out.
    /// `METALRENDERER_SCENE=seed=...,trees=...,undergrowth=...` changes the world.
    static func world() -> [Config] {
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
    static func worldCamera(_ w: World, _ x: Double, _ z: Double, up: Float, yaw: Float = 0, pitch: Float) -> Camera {
        let anchor = WorldTile.origin(w.anchorTile.x, w.anchorTile.y)
        var c = Camera()
        c.position = SIMD3(Float(x - anchor.x), w.height(x, z) + up, Float(z - anchor.y))
        c.yaw = yaw
        c.pitch = pitch
        return c
    }

    /// The world the run's scenes are of (`METALRENDERER_SCENE=seed=...`), for placing the cameras in it.
    static func worldOfRun() -> World {
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
    static func worldNight() -> [Config] {
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
    static func worldDusk() -> [Config] {
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
    static func worldGround() -> [Config] {
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
        let centers: [SIMD2<Float>] = around.filter { !$0.plan.courts.isEmpty }.map { $0.plan.blocks[0].rect.center }
        let court: SIMD2<Float> = centers.min { (a: SIMD2<Float>, b: SIMD2<Float>) -> Bool in (a * a).sum() < (b * b).sum() } ?? .zero
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
    static func worldRoads() -> [Config] {
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
    static func forestcheck() -> [Config] {
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
            // The baked plants, far ones as their voxels (VoxelLOD; off by default), against all of them as triangles.
            baked.named("baked voxels aerial").with { $0.scene.voxelBoxes = true; $0.foliage.lod = 2 }.from(forestAerial),
            still.named("baked lod view").with { $0.scene.bakedPlants = true; $0.scene.voxelBoxes = true; $0.foliage.lod = 2 }
                .from(forestAerial).view(RenderSettings.viewModes.firstIndex(of: "LOD level")!),
        ]
    }
}
