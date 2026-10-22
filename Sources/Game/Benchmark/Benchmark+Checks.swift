import CoreGraphics
import EngineCore
import Foundation
import simd
import MetalRenderer

extension Benchmark {
    // MARK: - Correctness checks

    /// ReSTIR's sampling is unbiased for every light type: accumulated direct light (GI off), every light traced
    /// against ReSTIR's initial sampling without reuse (32 candidates, 4 chains), from the table alone and from the
    /// light grid, in the light-check scenes (one rect / tube / sphere light, or its emissive-mesh twin) and in scenes
    /// with spots, tubes, rects, emissive meshes, a sun and every type together. Mean
    /// luminance and PSNR should agree (Tools/eval/restir.py).
    static func restircheck() -> [Config] {
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
    static func restirgicheck() -> [Config] {
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

    /// The SDF shapes scene (Scene+Shapes.swift) on each API: paused frames to compare between them
    /// (Tools/eval/pngdiff.py), path traced, each direct-light method on the glowing shapes (mesh lights), the
    /// normals, materials and traversal cost views, then moving frames and a camera move for timing.
    static func shapes() -> [Config] {
        let scene = SceneSettings(kind: .shapes)
        var out: [Config] = []
        for api in RenderAPI.allCases {
            let base = Config("", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: scene) { $0.api = api }
            let tag = api.envName
            out.append(base.named("\(tag) cascades").still())
            guard api == .metal3 else { continue }
            out.append(base.named("\(tag) pt").with { $0.giMode = .pathTraced }.still())
            out.append(base.named("\(tag) restir").direct(.restir).still())
            for view in ["Normals", "Triangles", "Traversal cost"] {
                out.append(base.named("\(tag) \(view.lowercased())").view(RenderSettings.viewModes.firstIndex(of: view)!).still().frames(8))
            }
            out += [base.named("\(tag) moving"), base.named("\(tag) camera").cameraMove()]
        }
        return out
    }

    /// The physics scene (Scene+Physics.swift) at its look (RenderSettings.usePhysicsLook): paused at 5 s on each
    /// API (the GPU's steps put the bodies in the same places on both; Tools/eval/pngdiff.py), the
    /// CPU's steps there too (their own pile: 300 steps
    /// of a pile tell float rounding apart), then the first 5 s moving for timing: the "physics" pass at a few body
    /// counts on the GPU, and the CPU's steps (the frame's "cpu" column) at the same counts (Settings' PhysicsSettings.runsOnGPU).
    static func physics() -> [Config] {
        let scene = SceneSettings(kind: .physics)
        var out: [Config] = []
        for api in RenderAPI.allCases {
            out.append(Config(api.envName, scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: scene) {
                $0.usePhysicsLook()
                $0.api = api
            }.still())
        }
        let base = Config("", scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: scene) { $0.usePhysicsLook() }
        out.append(base.named("cpu").with { $0.scene.physics.backend = .cpu }.still())
        for bodies in [96, 512, 2048] {
            out.append(base.named("gpu \(bodies) moving").with { $0.scene.physics.bodies = bodies; $0.scene.physics.backend = .gpu })
        }
        for bodies in [96, 512, 2048] {
            out.append(base.named("cpu \(bodies) moving").with { $0.scene.physics.bodies = bodies; $0.scene.physics.backend = .cpu })
        }
        return out
    }

    /// The physics scene's demo video: its first 30 s along a camera track at the scene's look with the showcase's lens
    /// but no depth of field (`recording`: 900 JPEGs at 30 fps; `.claude/skills/offscreen/scripts/video.sh -m physicsdemo` makes the mp4).
    /// Wide while the bodies drop and the ball rolls in, down to the bin as the particles pour, round to the cloth
    /// falling over its ball, past the tower and the pile, and back out. The clock starts at -1 s, so that the warm-up's
    /// second ends as the first frame is recorded, with everything still in the air (the physics waits until 0).
    static func physicsDemo() -> [Config] {
        func key(_ time: Float, _ position: SIMD3<Float>, _ target: SIMD3<Float>) -> CameraTrack.Key {
            CameraTrack.Key(time: time, position: position, target: target)
        }
        let track = CameraTrack([
            key(0, [0, 4.2, 8.2], [0, 0.6, -1]),
            key(4, [-0.5, 3.0, 5.5], [-0.8, 0.6, -1.0]),
            key(8, [-1.2, 1.4, 4.4], [-2.4, 0.3, 2.3]),
            key(12, [0.2, 1.3, 4.6], [0.9, 0.6, 2.2]),
            key(16, [2.2, 1.6, 3.6], [0.9, 0.7, 2.0]),
            key(20, [3.6, 1.8, 1.0], [2.2, 0.8, -0.6]),
            key(24, [1.5, 2.2, 1.8], [-1.0, 0.5, -2.2]),
            key(30, [0, 4.2, 8.2], [0, 0.6, -1]),
        ])
        var demo = Config("physics demo", scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: SceneSettings(kind: .physics)) {
            $0.usePhysicsLook()
            $0.post = ShowcaseLook.lens.with { $0.aperture = 0 }   // sharp throughout: no depth of field
        }.track(track).recording()
        demo.startTime = -Float(60) / 60   // Benchmark.warmupFrames x fixedDt
        return [demo]
    }

    /// The ragdoll scene (Scene+Ragdolls.swift) at the physics look: paused at 5 s on each API, the CPU's
    /// steps there too, then the first 5 s moving for timing at a few ragdoll counts on the GPU (11 bodies each) and on
    /// the CPU where it keeps up.
    static func ragdolls() -> [Config] {
        let scene = SceneSettings(kind: .ragdolls)
        var out: [Config] = []
        for api in RenderAPI.allCases {
            out.append(Config(api.envName, scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: scene) {
                $0.usePhysicsLook()
                $0.api = api
            }.still())
        }
        let base = Config("", scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: scene) { $0.usePhysicsLook() }
        out.append(base.named("cpu").with { $0.scene.physics.backend = .cpu }.still())
        for ragdolls in [8, 24, 96] {
            out.append(base.named("gpu \(ragdolls) moving").with { $0.scene.physics.ragdolls = ragdolls; $0.scene.physics.backend = .gpu })
        }
        for ragdolls in [8, 24, 96] {
            out.append(base.named("cpu \(ragdolls) moving").with { $0.scene.physics.ragdolls = ragdolls; $0.scene.physics.backend = .cpu })
        }
        return out
    }

    /// The hair scene (Scene+Hair.swift) at the physics look: paused at 5 s on each API and with the CPU's steps; then the first 5 s moving for timing at a few
    /// densities of drawn strands on the GPU, and on the CPU at the fewest.
    static func hair() -> [Config] {
        let scene = SceneSettings(kind: .hair)
        var out: [Config] = []
        for api in RenderAPI.allCases {
            out.append(Config(api.envName, scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: scene) {
                $0.usePhysicsLook()
                $0.api = api
            }.still())
        }
        let base = Config("", scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: scene) { $0.usePhysicsLook() }
        out.append(base.named("cpu").with { $0.scene.physics.backend = .cpu }.still())
        for hair in [4, 12, 24] {
            out.append(base.named("gpu \(hair) moving").with { $0.scene.physics.hair = hair; $0.scene.physics.backend = .gpu })
        }
        out.append(base.named("cpu 4 moving").with { $0.scene.physics.hair = 4; $0.scene.physics.backend = .cpu })
        return out
    }

    /// The hair scene's demo video: its first 20 s along a camera track at the physics look with the
    /// showcase's lens but no depth of field (`recording`; `.claude/skills/offscreen/scripts/video.sh -m hairdemo` makes the mp4). Wide as
    /// the furry bodies drop onto the ramp, along it as they roll, down to the pile at its foot, round the mannequin
    /// with long hair in the breeze, and back out. The clock starts at -1 s, as the physics demo's does.
    static func hairDemo() -> [Config] {
        func key(_ time: Float, _ position: SIMD3<Float>, _ target: SIMD3<Float>) -> CameraTrack.Key {
            CameraTrack.Key(time: time, position: position, target: target)
        }
        let track = CameraTrack([
            key(0, [0.1, 1.9, 4.8], [0, 0.9, -0.2]),
            key(3, [3.2, 1.8, 1.2], [1.2, 0.9, -1.6]),
            key(6, [2.6, 0.8, 3.9], [1.2, 0.3, 2.2]),
            key(10, [0.2, 1.6, 2.4], [-1.1, 1.35, 0.35]),
            key(14, [-2.6, 1.6, 1.4], [-1.1, 1.3, 0.3]),
            key(17, [-0.6, 1.2, 3.4], [0.6, 0.4, 1.8]),
            key(20, [0.1, 1.9, 4.8], [0, 0.9, -0.2]),
        ])
        var demo = Config("hair demo", scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: SceneSettings(kind: .hair)) {
            $0.usePhysicsLook()
            $0.post = ShowcaseLook.lens.with { $0.aperture = 0 }   // sharp throughout: no depth of field
        }.track(track).recording()
        demo.startTime = -Float(60) / 60   // Benchmark.warmupFrames x fixedDt
        return [demo]
    }

    /// The hair scene paused at 5 s in the views that show how its strands are lit: the picture,
    /// the direct light (albedo divided out), the albedo, the normals.
    static func hairViews() -> [Config] {
        let base = Config("", scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: SceneSettings(kind: .hair)) { $0.usePhysicsLook() }
        var head = base.named("head").still()
        head.camera = Scene.camera([-0.6, 1.75, 1.9], yaw: -0.32, pitch: -0.1)
        var fur = base.named("fur").still()
        fur.camera = Scene.camera([2.0, 0.8, 3.6], yaw: -0.55, pitch: -0.35)
        return [base.named("final").still(), head, fur, base.named("direct").view(1).still(), base.named("albedo").view(4).still(),
                base.named("normals").view(3).still()]
    }

    /// The soft body scene (Scene+Soft.swift) at the physics look: paused at 1.5, 3 and 5 s, at 5 s
    /// on each API, the CPU's steps there too, its normals and direct light, then the first 5 s moving for
    /// timing at a few soft body counts on the GPU, a finer lattice, and on the CPU where it keeps up.
    static func soft() -> [Config] {
        let scene = SceneSettings(kind: .softBodies)
        let base = Config("", scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: scene) { $0.usePhysicsLook() }
        var out: [Config] = []
        for time: Float in [1.5, 3] { out.append(base.named(String(format: "%.1fs", time)).still(at: time)) }
        for api in RenderAPI.allCases { out.append(base.named(api.envName).with { $0.api = api }.still()) }
        out.append(base.named("cpu").with { $0.scene.physics.backend = .cpu }.still())
        out.append(base.named("normals").view(3).still())
        out.append(base.named("direct").view(1).still())
        for bodies in [16, 48, 128] {
            out.append(base.named("gpu \(bodies) moving").with { $0.scene.physics.softBodies = bodies; $0.scene.physics.backend = .gpu })
        }
        out.append(base.named("gpu 16 cells 10 moving").with { $0.scene.physics.softCells = 10; $0.scene.physics.backend = .gpu })
        for bodies in [16, 48] {
            out.append(base.named("cpu \(bodies) moving").with { $0.scene.physics.softBodies = bodies; $0.scene.physics.backend = .cpu })
        }
        return out
    }

    /// The fluids scene (Scene+Fluids.swift) at the physics look: paused at 2, 4 and 6 s (the boxes dropped at 4 and
    /// 5 s), at 6 s on each API, each liquid alone, all by one solver, in its normals and albedo, and path traced (the
    /// reference: refraction and absorption as they are); then 5 s moving for timing: the first on the GPU, from 12 s
    /// (the pours longer) at a few particle counts a liquid, and the first small on the CPU.
    static func fluids() -> [Config] {
        let base = Config("", scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: SceneSettings(kind: .fluids)) { $0.usePhysicsLook() }
        var out: [Config] = []
        for time: Float in [2, 4, 6] { out.append(base.named(String(format: "%.0fs", time)).still(at: time)) }
        for api in RenderAPI.allCases { out.append(base.named(api.envName).with { $0.api = api }.still(at: 6)) }
        for liquids in [PhysicsSettings.Liquids.water, .blood, .honey] {
            out.append(base.named(liquids.envName).with { $0.scene.physics.liquids = liquids }.still(at: 6))
        }
        out.append(base.named("all pbf").with { $0.scene.physics.solver = .pbf }.still(at: 6))
        out.append(base.named("all mpm").with { $0.scene.physics.solver = .mpm }.still(at: 6))
        out.append(base.named("normals").view(3).still(at: 6))
        out.append(base.named("albedo").view(4).still(at: 6))
        out.append(base.named("path traced").with { $0.reference.mode = .pathTraced }.still(at: 6).frames(256))
        out.append(base.named("gpu moving").with { $0.scene.physics.backend = .gpu })
        for particles in [16384, 32768, 65536] {
            var c = base.named("gpu \(particles / 1024)k moving").with { $0.scene.physics.fluidParticles = particles; $0.scene.physics.backend = .gpu }
            c.startTime = 12   // by then the pours have filled 16k a liquid (the warm-up catches up 19 steps a frame)
            out.append(c)
        }
        out.append(base.named("cpu 2k moving").with { $0.scene.physics.fluidParticles = 2048; $0.scene.physics.backend = .cpu })
        return out
    }

    /// The particles scene (Scene+Particles.swift) as the app shows it (cascades, MetalFX 3x from 0.5x): paused at 2, 5
    /// and 8 s, at 5 s on each API, natively at 0.75x without MetalFX (the composite puts the particles' layer over the
    /// scene, SVGF denoises), and path traced at 0.75x (the reference: its particles stop paths by their opacity, scatter
    /// or glow); without particle shadows, without particles in reflections; then 5 s moving for timing at a quarter,
    /// once and four times the particles (ParticleSettings.budget).
    static func particles() -> [Config] {
        let base = Config("", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: .particles))
        var out: [Config] = []
        for time: Float in [2, 5, 8] { out.append(base.named(String(format: "%.0fs", time)).still(at: time)) }
        for api in RenderAPI.allCases { out.append(base.named(api.envName).with { $0.api = api }.still(at: 5)) }
        let native = Config("", scale: 0.75, upscale: 0, gi: .radianceCascades, scene: SceneSettings(kind: .particles))
        out.append(native.named("native").still(at: 5))
        out.append(native.named("path traced").with { $0.reference.mode = .pathTraced }.still(at: 5).frames(256))
        out.append(base.named("no shadows").with { $0.scene.particles.shadows = false }.still(at: 5))
        out.append(base.named("no reflections").with { $0.scene.particles.reflections = false }.still(at: 5))
        out.append(base.named("half layer").with { $0.particleScale = 0.5 }.still(at: 5))
        out.append(native.named("native half layer").with { $0.particleScale = 0.5 }.still(at: 5))
        for budget: Float in [0.25, 1, 4] {
            out.append(base.named(String(format: "moving %gx", budget)).with { $0.scene.particles.budget = budget })
        }
        return out
    }

    /// The particles scene's demo video: 24 s along a camera track from 3 s in (the effects under way) at the
    /// `particles` mode's settings with the showcase's lens but no depth of field (`recording`;
    /// `.claude/skills/offscreen/scripts/video.sh -m particlesdemo` makes the mp4). Wide, then to the brazier's fire and
    /// smoke, down to the rubble's bursts and dust, round to the plinth's motes and wisps, across the grinder's sparks
    /// on the crate, over to the rain under its lamp, and back out.
    static func particlesDemo() -> [Config] {
        func key(_ time: Float, _ position: SIMD3<Float>, _ target: SIMD3<Float>) -> CameraTrack.Key {
            CameraTrack.Key(time: time, position: position, target: target)
        }
        let track = CameraTrack([
            key(0, [0.3, 1.9, 6.2], [0, 1.0, 0]),
            key(4, [-1.2, 1.5, 1.9], [-2.6, 1.3, -0.5]),
            key(8, [-0.6, 1.0, 4.0], [-1.9, 0.4, 2.2]),
            key(12, [0.9, 1.6, -0.6], [0, 1.2, -2.6]),
            key(16, [1.0, 1.3, 3.4], [0.5, 0.7, 0.8]),
            key(20, [0.2, 2.0, 5.6], [3.4, 0.9, 0.6]),
            key(24, [0.3, 1.9, 6.2], [0, 1.0, 0]),
        ])
        var demo = Config("particles demo", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: .particles)) {
            $0.post = ShowcaseLook.lens.with { $0.aperture = 0 }   // sharp throughout: no depth of field
        }.track(track).recording()
        demo.startTime = 2   // 3 s in at the first recorded frame, after Benchmark.warmupFrames
        return [demo]
    }

    /// The VFX stage (Scene+Stage.swift) at the particles mode's settings: the fireworks alone (generated code:
    /// VFXProgram) paused at 1, 2.5 and 4 s, then beside the campfire and the magic (the fixed emitters' code), paused and
    /// moving for timing. Benchmarks wait for the VFX library's compile.
    static func vfx() -> [Config] {
        let base = Config("", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: .vfxStage))
        var out: [Config] = []
        for time: Float in [1, 2.5, 4] { out.append(base.named(String(format: "fireworks %gs", time)).still(at: time)) }
        let lineUp = base.with { $0.scene.stage.effects = ["campfire", "fireworks", "magic"] }
        out.append(lineUp.named("line-up").still(at: 4))
        out.append(lineUp.named("line-up moving"))
        return out
    }

    /// The VFX editor's edits reaching the running stage (Renderer.editEffects), the fireworks paused at 3 s: as built in;
    /// the stars brighter and heavier (values: in place, the same particles); their size wired to a node (code: compiled,
    /// then replayed from the start); the magic (the scene made again); the wired fireworks made from scratch, which
    /// "code" should match within the run-to-run noise.
    static func vfxEdit() -> [Config] {
        let base = Config("", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: .vfxStage)).still(at: 3)
        var fireworks = VFXLibrary.named("fireworks")!
        fireworks.setParam("starColor", "emission", .float(20))
        fireworks.setParam("stars.gravity", "share", .float(1))
        let values = VFXCatalog.register(VFXCatalog(effects: ["fireworks": fireworks]))
        fireworks.nodes.append(VFXNode(.float, ["value": .float(0.12)], id: "big", at: [40, 520]))
        fireworks.links.append(VFXLink("big", to: "stars.size", "size"))
        let code = VFXCatalog.register(VFXCatalog(effects: ["fireworks": fireworks]))
        return [base.named("before"), base.named("values").with { $0.scene.effects = values },
                base.named("code").with { $0.scene.effects = code },
                base.named("other").with { $0.scene.stage.effects = ["magic"] },
                base.named("code fresh").with { $0.scene.effects = code }]
    }

    /// The material workshop (Scene+Materials.swift): every built-in graph on the line-up in the studio, path traced at
    /// three quarters of the window (each graph baked when its scene is made: its bake's time printed), then the first
    /// on each shape alone and against each backdrop.
    static func materials() -> [Config] {
        let base = Config("", scale: 0.75, gi: .pathTraced, scene: SceneSettings(kind: .materials)).still(at: 1)
        var out = MaterialLibrary.names.map { name in base.named(VFXEffect.slug(name)).with { $0.scene.materialWorkshop.graph = name } }
        let first = MaterialLibrary.names[0]
        for layout in MaterialWorkshopSettings.Layout.allCases where layout != .lineup {
            out.append(base.named("\(VFXEffect.slug(first)) \(layout.rawValue)").with {
                $0.scene.materialWorkshop.graph = first
                $0.scene.materialWorkshop.layout = layout
            })
        }
        // The cut-outs (an opacity output: a plant, a decal) as a card and a tile on the ground.
        for g in MaterialLibrary.all where g.channels[.opacity] != nil && g.name.hasPrefix("Swamp") {
            out.append(base.named("\(VFXEffect.slug(g.name)) card").with {
                $0.scene.materialWorkshop.graph = g.name
                $0.scene.materialWorkshop.layout = .card
            })
        }
        for backdrop in MaterialWorkshopSettings.Backdrop.allCases where backdrop != .studio {
            out.append(base.named("\(VFXEffect.slug(first)) \(backdrop.rawValue)").with {
                $0.scene.materialWorkshop.graph = first
                $0.scene.materialWorkshop.backdrop = backdrop
            })
        }
        return out
    }

    /// The painter workshop: each object it paints, its texture set a brick graph laid on its layout (UV projection: the
    /// unwrap's charts, Painter/UVUnwrap.swift, as seams; their texels per metre as the bricks' size).
    static func painterModes() -> [Config] {
        var d = PaintDocument(name: "Bench layout")
        var bricks = PaintLayer.fill("Bricks", PaintValues(), channels: [.color, .roughness, .metallic, .height])
        bricks.graph = "Red Bricks"
        bricks.projection = .uv
        bricks.tiling = 2
        d.layers = [PaintDocument.baseLayer, bricks]
        PaintDocuments.shared.update(d)
        let base = Config("", scale: 0.75, gi: .pathTraced, scene: SceneSettings(kind: .painter)).still(at: 1)
        return PainterWorkshopSettings.Subject.allCases.map { subject in
            base.named(subject.rawValue).with {
                $0.scene.painterWorkshop.subject = subject
                $0.scene.painterWorkshop.model = "demon"
                $0.scene.painterWorkshop.document = d.name
            }
        }
    }

    /// The smart materials (SmartMaterial.builtIn), each on another object: their masks generated from its bakes
    /// (curvature, occlusion: PaintBake).
    static func painterSmart() -> [Config] {
        let subjects: [PainterWorkshopSettings.Subject] = [.cube, .model, .sphere, .character, .cylinder]
        let base = Config("", scale: 0.75, gi: .pathTraced, scene: SceneSettings(kind: .painter)).still(at: 1)
        return SmartMaterial.builtIn.enumerated().map { k, m in
            var d = PaintDocument(name: "Bench \(m.name)")
            d.layers = [PaintDocument.baseLayer] + m.instantiate()
            PaintDocuments.shared.update(d)
            return base.named(VFXEffect.slug(m.name)).with {
                $0.scene.painterWorkshop.subject = subjects[k % subjects.count]
                $0.scene.painterWorkshop.model = "demon"
                $0.scene.painterWorkshop.document = d.name
            }
        }
    }

    /// Strokes in paint mode (Renderer.runPainterScript): red across the sphere (over its seams), blue mirrored
    /// (symmetry X), leaves stamped and scattered, the eraser through the red, gold revealed through a black mask,
    /// a UV island filled green; then the same on the demon model.
    static func painterStrokes() -> [Config] {
        var d = PaintDocument(name: "Bench strokes")
        var paint = PaintLayer(name: "Paint")
        paint.channels = [.color, .roughness, .metallic, .height]
        var gold = PaintLayer.fill("Gold", PaintValues(color: [1, 0.72, 0.3], roughness: 0.25, metallic: 1), channels: [.color, .roughness, .metallic])
        gold.mask = PaintMask(base: 0, generator: nil, painted: true)
        var fills = PaintLayer(name: "Fills")
        fills.channels = [.color, .roughness]
        d.layers = [PaintDocument.baseLayer, paint, gold, fills]
        PaintDocuments.shared.update(d)
        func brush(_ c: SIMD3<Float>, size: Float = 22, _ change: (inout PaintBrush) -> Void = { _ in }) -> PaintBrush {
            var b = PaintBrush()
            b.size = size
            b.values.color = c
            b.values.roughness = 0.35
            b.values.height = 0.8
            b.channels = [.color, .roughness, .height]
            b.flow = 1
            change(&b)
            return b
        }
        func line(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ n: Int = 24) -> [SIMD2<Float>] { (0...n).map { a + (b - a) * Float($0) / Float(n) } }
        let steps: [PainterStep] = [
            .mode(0),
            .brush(brush([0.8, 0.05, 0.03]), layer: 1, mask: false, tool: .brush), .stroke(line([0.3, 0.42], [0.7, 0.46])),
            .brush(brush([0.05, 0.15, 0.8]) { $0.symmetry = .x }, layer: 1, mask: false, tool: .brush), .stroke(line([0.4, 0.3], [0.44, 0.36])),
            .brush(brush([0.2, 0.45, 0.08], size: 30) { $0.stamp = 3; $0.scatter = 0.6; $0.angleJitter = 180; $0.spacing = 0.6 },
                   layer: 1, mask: false, tool: .brush), .stroke(line([0.35, 0.3], [0.65, 0.32])),
            .brush(brush(.zero, size: 12) { $0.eraser = true }, layer: 1, mask: false, tool: .brush), .stroke(line([0.5, 0.36], [0.52, 0.52])),
            .brush(brush([1, 1, 1], size: 26), layer: 2, mask: true, tool: .brush), .stroke(line([0.38, 0.53], [0.62, 0.52])),
            .brush(brush([0.1, 0.7, 0.2]) { $0.channels = [.color, .roughness] }, layer: 3, mask: false, tool: .fillIsland), .fill([0.5, 0.58]),
            .wait, .wait,
        ]
        let base = Config("", scale: 0.75, gi: .pathTraced, scene: SceneSettings(kind: .painter)).still(at: 1)
        let sphere = base.named("sphere").with { $0.scene.painterWorkshop.subject = .sphere; $0.scene.painterWorkshop.document = d.name }
        let model = base.named("model").with {
            $0.scene.painterWorkshop.subject = .model
            $0.scene.painterWorkshop.model = "demon"
            $0.scene.painterWorkshop.document = d.name
        }
        return [sphere, model].map { c in var c = c; c.events = [(0, .paint(steps))]; return c }
    }

    /// The Mireland swamp (every material procedural): from the bank, closer to the water's edge, and wide.
    static func mireland() -> [Config] {
        let base = Config("", scale: 0.75, gi: .pathTraced, scene: SceneSettings(kind: .mireland)).still(at: 1)
        var edge = base.named("edge"), wide = base.named("wide")
        edge.camera = Scene.camera([3, 0.9, 9], yaw: 0.5, pitch: -0.12)
        wide.camera = Scene.camera([-12, 4, 22], yaw: -0.45, pitch: -0.14)
        return [base.named("bank"), edge, wide]
    }

    /// The Material Designer's edits reaching the renderer: the workshop's bricks as built in, then with more rows and
    /// rounder bricks (an edit of values: baked again in place, Renderer.editMaterials); the sun courtyard as made, then
    /// with its ground's material given the bricks and a wall's the perforated metal (assignments: the scene made again,
    /// the materials procedural); the cobblestone displaced, deeper and flat; the marble on a sphere as code
    /// (MatShaderCode, compiled into the shading) and baked.
    static func matEdit() -> [Config] {
        let base = Config("", scale: 0.75, gi: .pathTraced, scene: SceneSettings(kind: .materials)).still(at: 1)
        var bricks = MaterialLibrary.named("Red Bricks")!
        if let k = bricks.nodes.firstIndex(where: { $0.kind == .bricks }) {
            bricks.nodes[k].params["rows"] = .int(16)
            bricks.nodes[k].params["roundness"] = .float(0.8)
        }
        let edited = MaterialCatalog.register(MaterialCatalog(graphs: ["Red Bricks": bricks]))
        // The sun scene's two most used materials (its ground, a wall), by their fingerprints as it makes them.
        let sun = SceneSettings(kind: .sun)
        let made = Scene(sun)
        var uses: [Int: Int] = [:]
        for i in made.instances where i.mesh >= 0 { uses[i.material, default: 0] += 1 }
        let top = uses.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(2).map(\.key)
        var a = MaterialAssignments()
        a.scenes[MaterialAssignments.scope(sun)] = zip(top, ["Red Bricks", "Perforated Metal"]).map {
            .init(material: $0.0, fingerprint: MaterialAssignments.fingerprint(made.materials[$0.0]), graph: $0.1)
        }
        let assigned = MaterialAssignments.register(a)
        let court = Config("", scale: 0.75, gi: .pathTraced, scene: sun).still(at: 20)
        // The marble as code (its graph's own setting), then baked: the same material, the code sharper up close.
        var baked = MaterialLibrary.marble()
        baked.surface.shaderMode = false
        let bakedMarble = MaterialCatalog.register(MaterialCatalog(graphs: ["Marble": baked]))
        let marble = base.with { $0.scene.materialWorkshop.graph = "Marble"; $0.scene.materialWorkshop.layout = .sphere }
        // The cobblestone's displacement: as built in, deeper (within the room its meshes were made with: moved in
        // place), and off (parallax only: the scene made again).
        func cobbles(_ change: (inout MaterialGraph) -> Void) -> String {
            var g = MaterialLibrary.cobblestone()
            change(&g)
            return MaterialCatalog.register(MaterialCatalog(graphs: ["Cobblestone": g]))
        }
        let deeper = cobbles { $0.surface.displacement = 0.06 }, flat = cobbles { $0.surface.displacement = 0 }
        let stones = base.with { $0.scene.materialWorkshop.graph = "Cobblestone" }
        return [base.named("bricks"), base.named("bricks edited").with { $0.scene.materials = edited },
                stones.named("cobbles displaced"), stones.named("cobbles deeper").with { $0.scene.materials = deeper },
                stones.named("cobbles flat").with { $0.scene.materials = flat },
                marble.named("marble code"), marble.named("marble baked").with { $0.scene.materials = bakedMarble },
                court.named("sun"), court.named("sun assigned").with { $0.scene.materialAssignments = assigned }]
    }

    /// The VFX stage's backdrops: the campfire, the fireworks and the magic at 3.5 s in front of each, from the stage's
    /// default camera (`METALRENDERER_GIZMOS=fireworks/rockets` draws the editor's gizmos).
    static func vfxStage() -> [Config] {
        var stage = SceneSettings(kind: .vfxStage)
        stage.stage.effects = ["campfire", "fireworks", "magic"]
        let base = Config("", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: stage).still(at: 3.5)
        return VFXBackdrop.allCases.map { b in base.named(b.rawValue).with { $0.scene.stage.backdrop = b } }
    }

    /// The VFX stage's backdrops as a video (`recording`; `video.sh -m vfxstagedemo`, run with
    /// `METALRENDERER_GIZMOS=fireworks/rockets` for the editor's gizmos): 4 s on each, the camera arcing round the
    /// line-up, the clock from 1.5 s.
    static func vfxStageDemo() -> [Config] {
        var stage = SceneSettings(kind: .vfxStage)
        stage.stage.effects = ["campfire", "fireworks", "magic"]
        return VFXBackdrop.allCases.enumerated().map { k, b in
            let side: Float = k % 2 == 0 ? 1 : -1
            let track = CameraTrack([
                CameraTrack.Key(time: 0, position: [-3.5 * side, 2.2, 9.8], target: [0, 2.4, 0]),
                CameraTrack.Key(time: 4, position: [3.5 * side, 2.6, 9.8], target: [0, 2.4, 0]),
            ])
            var c = Config(b.rawValue, scale: 0.5, upscale: 3, gi: .radianceCascades, scene: stage) {
                $0.scene.stage.backdrop = b
                $0.post = ShowcaseLook.lens.with { $0.aperture = 0 }
            }.track(track).recording()
            c.startTime = 1.5
            return c
        }
    }

    /// The VFX stage's demo video: 16 s of the line-up (the campfire, the fireworks, the magic) along a camera track
    /// from 1 s in (`recording`; `video.sh -m vfxdemo`): wide, in to the fireworks' bursts from below, across to the
    /// fire, round to the motes, and back out.
    static func vfxDemo() -> [Config] {
        func key(_ time: Float, _ position: SIMD3<Float>, _ target: SIMD3<Float>) -> CameraTrack.Key {
            CameraTrack.Key(time: time, position: position, target: target)
        }
        let track = CameraTrack([
            key(0, [0, 2.4, 10.5], [0, 2.6, 0]),
            key(4, [1.2, 1.2, 5.5], [0, 3.8, 0]),
            key(8, [-2.2, 1.6, 4.2], [-4, 1.4, 0]),
            key(12, [2.6, 1.7, 3.6], [4, 1.2, 0]),
            key(16, [0, 2.4, 10.5], [0, 2.6, 0]),
        ])
        var stage = SceneSettings(kind: .vfxStage)
        stage.stage.effects = ["campfire", "fireworks", "magic"]
        var demo = Config("vfx demo", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: stage) {
            $0.post = ShowcaseLook.lens.with { $0.aperture = 0 }
        }.track(track).recording()
        demo.startTime = 0
        return [demo]
    }

    /// The fluids scene's demo video: its first 20 s along a camera track at the physics look with the showcase's lens
    /// but no depth of field (`recording`; `.claude/skills/offscreen/scripts/video.sh -m fluidsdemo` makes the mp4). Wide
    /// as the three start pouring, down to the water as it runs off the steps, along to the blood and the honey as the
    /// boxes drop in, across the basins from the right as they float and sink, and back out. The clock starts at -1 s.
    static func fluidsDemo() -> [Config] {
        func key(_ time: Float, _ position: SIMD3<Float>, _ target: SIMD3<Float>) -> CameraTrack.Key {
            CameraTrack.Key(time: time, position: position, target: target)
        }
        let track = CameraTrack([
            key(0, [0, 1.25, 1.05], [0, 0.15, -0.45]),
            key(4, [-0.9, 0.75, 0.55], [-0.64, 0.15, -0.5]),
            key(8, [0.1, 0.65, 0.6], [0.1, 0.1, -0.35]),
            key(12, [0.95, 0.55, 0.45], [0.55, 0.1, -0.3]),
            key(16, [1.45, 0.62, 0.25], [0.05, 0.05, -0.45]),
            key(20, [0, 1.25, 1.05], [0, 0.15, -0.45]),
        ])
        var demo = Config("fluids demo", scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: SceneSettings(kind: .fluids)) {
            $0.usePhysicsLook()
            $0.post = ShowcaseLook.lens.with { $0.aperture = 0 }   // sharp throughout: no depth of field
        }.track(track).recording()
        demo.startTime = -Float(60) / 60   // Benchmark.warmupFrames x fixedDt
        return [demo]
    }

    /// A camera at `from` looking at `to`.
    private static func look(_ from: SIMD3<Float>, _ to: SIMD3<Float>) -> Camera {
        let d = to - from
        return Scene.camera(from, yaw: atan2(d.x, -d.z), pitch: atan2(d.y, (d.x * d.x + d.z * d.z).squareRoot()))
    }

    /// The muscles scene (Scene+Muscles.swift) at the physics look: wide at 2 and 5 s, at 5 s on each API, with the
    /// CPU's steps, in its normals and direct light; close to the character as it idles (1 s) and as it dances
    /// (15 s), and to the ragdolls on the steps; each skin; then the first 5 s moving for timing at a few lattice
    /// spacings and ragdoll counts, and the sliding skin.
    static func muscles() -> [Config] {
        let scene = SceneSettings(kind: .muscles)
        let base = Config("", scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: scene) { $0.usePhysicsLook() }
        var out: [Config] = [base.named("2s").still(at: 2)]
        for api in RenderAPI.allCases { out.append(base.named(api.envName).with { $0.api = api }.still()) }
        out.append(base.named("cpu").with { $0.scene.physics.backend = .cpu }.still())
        out.append(base.named("normals").view(3).still())
        out.append(base.named("direct").view(1).still())
        for skin in PhysicsSettings.Skin.allCases {
            var start = base.named("character \(skin.envName)").with { $0.scene.physics.skin = skin }.still(at: 1)
            start.camera = look([3.0, 1.5, 4.9], [1.2, 1.0, 3.1])
            var close = base.named("character normals \(skin.envName)").with { $0.scene.physics.skin = skin }.view(3).still(at: 1)
            close.camera = start.camera
            out += [start, close]
        }
        // The character as its muscles and bones (MuscleAtlas.swift, SkeletonAtlas.swift): from its front, its back and
        // its side as it idles, close up, in its normals, and as it dances.
        let ecorche = base.with { $0.scene.physics.body = .muscles }
        for (name, from, to) in [("front", SIMD3<Float>(3.4, 1.3, 3.1), SIMD3<Float>(1.2, 1.0, 3.1)), ("back", [-1.0, 1.3, 3.1], [1.2, 1.0, 3.1]),
                                 ("side", [3.0, 1.5, 4.9], [1.2, 1.0, 3.1]), ("chest", [2.3, 1.3, 3.1], [1.2, 1.2, 3.1]),
                                 ("hips", [0.2, 1.05, 3.1], [1.2, 0.95, 3.1]), ("shoulder", [0.5, 1.55, 2.4], [1.2, 1.4, 2.95]),
                                 ("skull", [1.75, 1.7, 3.3], [1.2, 1.66, 3.1]), ("knee", [2.0, 0.55, 3.0], [1.2, 0.4, 3.1]),
                                 ("hand", [1.6, 0.95, 2.3], [1.2, 0.85, 2.9]), ("spine", [0.2, 1.35, 3.1], [1.2, 1.25, 3.1])] {
            var still = ecorche.named("ecorche \(name)").still(at: 1)
            still.camera = look(from, to)
            out.append(still)
        }
        var ecorcheNormals = ecorche.named("ecorche normals").view(3).still(at: 1)
        ecorcheNormals.camera = look([3.4, 1.3, 3.1], [1.2, 1.0, 3.1])
        out.append(ecorcheNormals)
        var dancing = ecorche.named("ecorche dancing").still(at: 15)
        dancing.camera = look([4.6, 1.6, 4.2], [2.2, 1.0, 2.9])
        out.append(dancing)
        var ragdolls = base.named("ragdolls").still()
        ragdolls.camera = look([-1.6, 2.4, -0.8], [-4.6, 0.7, -4.0])
        out.append(ragdolls)
        for cell: Float in [5, 4, 3.5, 3] {
            out.append(base.named(String(format: "gpu flesh %.1f cm moving", cell)).with { $0.scene.physics.fleshCell = cell; $0.scene.physics.backend = .gpu })
        }
        for count in [0, 6] {
            out.append(base.named("gpu \(count) ragdolls moving").with { $0.scene.physics.muscleRagdolls = count; $0.scene.physics.backend = .gpu })
        }
        out.append(base.named("gpu sliding moving").with { $0.scene.physics.skin = .sliding; $0.scene.physics.backend = .gpu })
        out.append(base.named("gpu ecorche moving").with { $0.scene.physics.body = .muscles; $0.scene.physics.backend = .gpu })
        out.append(base.named("cpu moving").with { $0.scene.physics.backend = .cpu })
        return out
    }

    /// The muscles scene's demo video: its first 48.3 s (the character's whole routine, PhysicsRig.swift) along a camera
    /// track at the physics look with the showcase's lens but no depth of field (`recording`;
    /// `.claude/skills/offscreen/scripts/video.sh -m musclesdemo`): close as the character idles and starts its hip hop,
    /// back over it and the ragdolls tumbling down the steps, low for the first breakdance freeze, round it through
    /// the long hip hop, low again for the second freeze, wide round the last hip hop, and back out as it idles. The
    /// clock starts at -1 s, as the physics demo's does.
    static func musclesDemo() -> [Config] {
        func key(_ time: Float, _ position: SIMD3<Float>, _ target: SIMD3<Float>) -> CameraTrack.Key {
            CameraTrack.Key(time: time, position: position, target: target)
        }
        let track = CameraTrack([
            key(0, [3.4, 1.4, 4.6], [1.2, 1.0, 3.1]),
            key(2.5, [3.8, 1.6, 4.2], [1.3, 1.0, 3.0]),
            key(5, [5.2, 2.4, 6.4], [-0.6, 0.8, 0.0]),
            key(8, [2.6, 1.1, 5.6], [2.2, 0.5, 2.3]),
            key(10.5, [3.8, 1.0, 4.6], [2.0, 0.6, 2.0]),
            key(14, [4.6, 1.6, 4.2], [2.2, 1.0, 2.9]),
            key(18, [2.2, 1.7, 6.0], [2.0, 1.0, 2.6]),
            key(22, [-0.6, 1.8, 3.6], [2.0, 1.0, 2.3]),
            key(25, [0.4, 1.0, 1.0], [1.9, 0.5, 2.6]),
            key(28.5, [2.0, 0.9, 5.8], [1.6, 0.5, 3.4]),
            key(32, [5.0, 2.0, 5.6], [1.4, 1.0, 3.4]),
            key(38, [4.0, 1.8, 1.4], [1.6, 1.0, 3.3]),
            key(43, [-1.8, 2.2, 1.8], [1.0, 1.0, 3.5]),
            key(48.3, [3.4, 1.8, 6.4], [1.2, 1.0, 3.2]),
        ])
        var demo = Config("muscles demo", scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: SceneSettings(kind: .muscles)) {
            $0.usePhysicsLook()
            $0.post = ShowcaseLook.lens.with { $0.aperture = 0 }   // sharp throughout: no depth of field
        }.track(track).recording()
        demo.startTime = -Float(60) / 60   // Benchmark.warmupFrames x fixedDt
        // The same with the character drawn as its muscles (MuscleAtlas.swift).
        var ecorche = demo.named("ecorche demo").with { $0.scene.physics.body = .muscles }
        return [demo, ecorche]
    }

    /// The soft body scene's demo video: its first 20 s along a camera track at the physics look with the showcase's
    /// lens but no depth of field (`recording`: 600 JPEGs at 30 fps; `.claude/skills/offscreen/scripts/video.sh -m
    /// softdemo` makes the mp4). Wide as the jellies drop onto the landing, down to the steps as they flop down them,
    /// round to the pegs and the ring as they squeeze through, and back out over the pile. The clock starts at -1 s, as
    /// the physics demo's does.
    static func softDemo() -> [Config] {
        func key(_ time: Float, _ position: SIMD3<Float>, _ target: SIMD3<Float>) -> CameraTrack.Key {
            CameraTrack.Key(time: time, position: position, target: target)
        }
        let track = CameraTrack([
            key(0, [0, 2.6, 4.2], [0, 1.0, -4]),
            key(4, [2.4, 2.4, 1.2], [0, 1.0, -4.2]),
            key(8, [-2.6, 1.4, 0.6], [0, 0.5, -2.4]),
            key(12, [-2.2, 1.2, 3.6], [0, 0.2, 0.2]),
            key(16, [2.0, 2.2, 3.8], [0, 0.3, -1.0]),
            key(20, [0, 2.6, 4.2], [0, 0.6, -2]),
        ])
        var demo = Config("soft demo", scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: SceneSettings(kind: .softBodies)) {
            $0.usePhysicsLook()
            $0.post = ShowcaseLook.lens.with { $0.aperture = 0 }   // sharp throughout: no depth of field
        }.track(track).recording()
        demo.startTime = -Float(60) / 60   // Benchmark.warmupFrames x fixedDt
        return [demo]
    }

    /// The ragdoll scene's demo video: its first 20 s along a camera track at the physics look with the showcase's lens
    /// but no depth of field (`recording`: 600 JPEGs at 30 fps; `.claude/skills/offscreen/scripts/video.sh -m ragdollsdemo` makes the mp4).
    /// Wide as they drop onto the stairs, down to the foot as they tumble off the last steps into the posts and the
    /// bench, up along the side of the stairs, and back out over the pile. The clock starts at -1 s, as the physics
    /// demo's does.
    static func ragdollsDemo() -> [Config] {
        func key(_ time: Float, _ position: SIMD3<Float>, _ target: SIMD3<Float>) -> CameraTrack.Key {
            CameraTrack.Key(time: time, position: position, target: target)
        }
        let track = CameraTrack([
            key(0, [3.2, 3.4, 7.6], [0, 1.6, -3]),
            key(4, [2.6, 2.2, 4.6], [0, 1.2, -2.2]),
            key(8, [-2.4, 1.3, 3.8], [0, 0.5, -0.6]),
            key(12, [-4.0, 3.4, 0.8], [0, 1.2, -2.6]),
            key(16, [-2.0, 3.6, -0.4], [0.4, 1.6, -3.6]),
            key(20, [3.2, 3.4, 7.6], [0, 1.0, -2]),
        ])
        var demo = Config("ragdolls demo", scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: SceneSettings(kind: .ragdolls)) {
            $0.usePhysicsLook()
            $0.post = ShowcaseLook.lens.with { $0.aperture = 0 }   // sharp throughout: no depth of field
        }.track(track).recording()
        demo.startTime = -Float(60) / 60   // Benchmark.warmupFrames x fixedDt
        return [demo]
    }

    /// The SDF shapes scene's demo video: 30 s along a camera track at the app's look (cascades, 3x from 0.5x to
    /// 1920x1200) with the showcase's lens (`recording`: 900 JPEGs at 30 fps; `.claude/skills/offscreen/scripts/video.sh
    /// -m shapesdemo` makes the mp4).
    /// A wide view, along the primitives, over to the cuts and blends and the baked knot, the glowing ring and lamp,
    /// and back out.
    static func shapesDemo() -> [Config] {
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
    static func stressDemo() -> [Config] {
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
    static func lightcheck() -> [Config] {
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
    static func speccheck() -> [Config] {
        picked([.area, .spots, .tubes]).flatMap { kind -> [Config] in
            let base = Config("", gi: nil, scene: SceneSettings(kind: kind)) { $0.toneMap = .none; $0.exposure = -2 }
                .sky { $0 = SkySettings() }
            let still = base.still(previous: true).frames(60)
            return references([base.named("\(kind) ref").reference(frames: 1024)]) + [
                still.named("\(kind) shadow denoiser"),
                still.named("\(kind) svgf").with { $0.denoiser.shadowDenoiser = false },
                still.named("\(kind) restir").direct(.restir),
            ]
        }
    }

    /// The froxel grid against the per-pixel reference march (fogReferenceKernel, 512 frames averaged), direct light
    /// only: the fog's scattering alone (view 14) and the final image. Compare with Tools/eval/pngdiff.py.
    static func fogcheck() -> [Config] {
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
    static func skycheck() -> [Config] {
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
    /// The crowd of generated people (SceneSettings.crowdBodies): the catalog's built-in characters on the square.
    static func characterCrowd() -> [Config] {
        func square(_ name: String, characters: Int, poses: Int = 64, detail: Int = 3) -> Config {
            var scene = SceneSettings(kind: .crowd, characters: characters, poses: poses, detail: detail, crowdBodies: .generated)
            scene.characterCatalog = "builtin"
            return Config("generated crowd \(name)", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: scene)
        }
        return [square("256", characters: 256), square("2048", characters: 2048), square("2048 detail 1", characters: 2048, detail: 1),
                square("still", characters: 2048).still(previous: true)]
    }

    static func crowd() -> [Config] {
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
    static func city() -> [Config] {
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
    static func vgdebug() -> [Config] {
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

    /// Every view mode, as the app draws it (radiance cascades, MetalFX denoiser 3x from 0.5x), in the scenes with
    /// levels of detail: the gallery's virtual meshes, the forest's plants, the crowd's characters and the open world's
    /// tiles. Then the views that depend on the GI method with each method.
    static func debugViews() -> [Config] {
        var out: [Config] = []
        let views = RenderSettings.viewModes.indices
        for kind in [SceneKind.gallery, .forest, .crowd, .world] {
            for mode in views {
                let name = "\(kind.title.lowercased()) \(RenderSettings.viewModes[mode].lowercased())"
                out.append(Config(name, scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: kind)).view(mode).still().frames(8))
            }
        }
        // The open world from 900 m above its start, looking well down: its tiles' three levels in rings around the
        // camera's tile (the scene is made around that tile: a camera elsewhere would move its middle).
        let w = worldOfRun()
        let aerial = worldCamera(w, w.start.place.x, w.start.place.z, up: 900, pitch: -1.0)
        for mode in [9, 11] {
            out.append(Config("open world aerial \(RenderSettings.viewModes[mode].lowercased())", scale: 0.5, upscale: 3,
                              gi: .radianceCascades, scene: SceneSettings(kind: .world)).view(mode).still().frames(8).from(aerial))
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
