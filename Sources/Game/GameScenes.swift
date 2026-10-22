import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Landscape
import Materials
import MetalRenderer
import Physics
import Plants
import simd

/// The game: the demo scenes, what suits each (their fog, sky, lens, camera and day), their settings rows and the
/// benchmark modes that show them. The engine finds this class by its name (SceneProvider) and asks it to register them
/// before it asks for its first scene; the app also calls `register()` itself, at launch.
@objc(MetalRendererGameScenes) package final class GameScenes: NSObject, SceneProvider {
    package static func registerScenes() { register() }

    /// Registers the game once.
    package static func register() { _ = registered }

    private static let registered: Void = {
        for definition in scenes() { SceneRegistry.register(definition) }
        SettingsTable.sceneRows = sceneRows
        Benchmark.modes.merge(Benchmark.gameModes) { _, game in game }
        Benchmark.standardMode = Benchmark.standard
    }()
}

extension SceneKind {
    static let stress = SceneKind("stress")
    static let gallery = SceneKind("gallery")
    static let spots = SceneKind("spots")
    static let sun = SceneKind("sun")
    static let area = SceneKind("area")
    static let tubes = SceneKind("tubes")
    static let emissive = SceneKind("emissive")
    static let mixed = SceneKind("mixed")
    static let fog = SceneKind("fog")
    static let valley = SceneKind("valley")
    static let market = SceneKind("market")
    static let forest = SceneKind("forest")
    static let crowd = SceneKind("crowd")
    static let city = SceneKind("city")
    static let cityNight = SceneKind("cityNight")
    static let world = SceneKind("world")
    static let showcase = SceneKind("showcase")
    static let shapes = SceneKind("shapes")
    static let physics = SceneKind("physics")
    static let ragdolls = SceneKind("ragdolls")
    static let hair = SceneKind("hair")
    static let softBodies = SceneKind("softBodies")
    static let muscles = SceneKind("muscles")
    static let fluids = SceneKind("fluids")
    static let particles = SceneKind("particles")
    static let mireland = SceneKind("mireland")
    static let destruction = SceneKind("destruction")
    static let demolition = SceneKind("demolition")
    static let stage = SceneKind("stage")
}

extension GameScenes {
    /// The night market's bulbs, unless the Lights slider says otherwise.
    static let marketLights = 4096

    private static func fog(_ edit: (inout FogSettings) -> Void) -> FogSettings {
        var f = FogSettings()
        f.enabled = true
        edit(&f)
        return f
    }

    private static func sky(_ edit: (inout SkySettings) -> Void) -> SkySettings {
        var s = SkySettings()
        s.mode = .atmosphere
        edit(&s)
        return s
    }

    private static func scene(_ kind: SceneKind, _ title: String, _ builder: String, build: @escaping (Scene) -> Void,
                              _ edit: (SceneDefinition) -> Void = { _ in }) -> SceneDefinition {
        SceneDefinition(kind, title, builder: builder, build: build).with(edit)
    }

    /// Every scene of the game, in the order the settings panel lists them.
    static func scenes() -> [SceneDefinition] {
        let seeded: (SceneSettings) -> String = { "\($0.kind.envName),seed=\($0.seed)" }
        let city: (SceneSettings) -> String = { "\($0.kind.envName),seed=\($0.seed),style=\($0.city.style.envName)" }
        // A courtyard (a lot) under an afternoon sun, a few clouds.
        let courtyard = sky { $0.coverage = 0.25; $0.cloudBase = 1300; $0.cloudThickness = 1000; $0.cloudScale = 2600 }
        let physics: (SceneDefinition) -> Void = { $0.simulates = true; $0.physicsLook = true }
        return [
            scene(.stress, "Stress test", "buildStress", build: { $0.buildStress(objects: $0.settings.objects, lights: $0.settings.lights) }) {
                $0.lights = SceneSettings().lights
                $0.detail = { "stress: \($0.objects) objects, \($0.lights) lights" }
                // Low in the central aisle, turned toward the office, rising and backing up to the overview.
                $0.cameraMove = { p, _ in
                    var start = Camera()
                    start.position = [0, 2.4, 12.0]
                    start.yaw = 0.35
                    start.pitch = -0.05
                    return Benchmark.glide(from: start, to: Scene.stressCamera, p)
                }
            },
            scene(.gallery, "Gallery (Assets)", "buildGallery", build: { $0.buildGallery() }) {
                $0.loadsModels = true
                // From close to the left models, gliding back to the gallery overview.
                $0.cameraMove = { p, _ in
                    var start = Camera()
                    start.position = [-3.2, 1.5, 0.2]
                    start.yaw = -0.7
                    start.pitch = -0.05
                    return Benchmark.glide(from: start, to: Scene.galleryCamera, p)
                }
            },
            scene(.spots, "Spot lights", "buildSpots", build: { $0.buildSpots() }) {
                $0.fog = fog { $0.density = 0.03; $0.heightFalloff = 0.05; $0.anisotropy = 0.55; $0.maxDistance = 30 }
                $0.camera = Scene.camera([0, 2.6, 8], pitch: -0.14)
            },
            scene(.sun, "Sun and sky", "buildSun", build: { $0.buildSun() }) {
                $0.dayCycle = 60
                $0.dayClock = DayClock(path: .sweep(.courtyard), hours: 7...19, otherScene: nil)
                $0.realisticLook = true
                $0.fog = fog { $0.density = 0.012; $0.heightFalloff = 0.1; $0.anisotropy = 0.3; $0.noise = 0.3; $0.maxDistance = 100 }
                $0.sky = sky { $0.coverage = 0.35; $0.cloudBase = 1200; $0.cloudThickness = 1200; $0.cloudScale = 2500 }
                $0.camera = Scene.camera([0.5, 1.8, 11], pitch: -0.06)
            },
            scene(.area, "Area lights", "buildArea", build: { $0.buildArea() }) {
                $0.camera = Scene.camera([0, 2.0, 6.5], pitch: -0.12)
            },
            scene(.tubes, "Tube lights", "buildTubes", build: { $0.buildTubes() }) {
                $0.fog = fog { $0.density = 0.05; $0.heightFalloff = 0; $0.anisotropy = 0.3; $0.maxDistance = 30 }
                $0.camera = Scene.camera([2.0, 1.6, 7], yaw: -0.2, pitch: -0.08)
            },
            scene(.emissive, "Emissive meshes", "buildEmissive", build: { $0.buildEmissive() }) {
                $0.fog = fog { $0.density = 0.02; $0.heightFalloff = 0; $0.anisotropy = 0.3; $0.maxDistance = 30 }
                $0.camera = Scene.camera([0, 2.2, 6.5], pitch: -0.14)
            },
            scene(.mixed, "Mixed lights", "buildMixed", build: { $0.buildMixed() }) {
                $0.fog = fog { $0.density = 0.03; $0.heightFalloff = 0; $0.anisotropy = 0.2; $0.maxDistance = 30 }
                $0.sky = sky { $0.coverage = 0.25; $0.shadows = false }   // the sun is low: clouds near the horizon
                $0.camera = Scene.camera([-3.4, 1.7, 3.7], yaw: 0.42, pitch: -0.14)
            },
            scene(.fog, "Misty hall", "buildFogHall", build: { $0.buildFogHall() }) {
                $0.fog = fog { $0.density = 0.045; $0.heightFalloff = 0.04; $0.anisotropy = 0.7; $0.ambient = 0.25; $0.noise = 0.6; $0.maxDistance = 60 }
                $0.camera = Scene.camera([1.2, 1.7, 2.6], yaw: -0.04, pitch: 0.1)
            },
            scene(.valley, "Open valley", "buildValley", build: { $0.buildValley() }) {
                $0.dayCycle = 180
                $0.dayClock = DayClock(path: .sweep(.valley), hours: 7...19, otherScene: nil)
                $0.hasPlants = true
                $0.scope = seeded
                $0.fog = fog { $0.density = 0.0015; $0.heightFalloff = 0.02; $0.anisotropy = 0.5; $0.noise = 0.2; $0.maxDistance = 150 }
                // Small, low clouds (a stylised scale), so their shadows visibly cross the 400 m valley.
                $0.sky = sky {
                    $0.coverage = 0.4; $0.cloudBase = 700; $0.cloudThickness = 800; $0.cloudScale = 800
                    $0.density = 0.04; $0.windSpeed = 14; $0.shadowStrength = 0.7
                }
                $0.camera = Scene.camera([4, 2.2, 38], yaw: -0.15, pitch: 0.12)
            },
            scene(.market, "Night market", "buildMarket", build: { $0.buildMarket() }) {
                $0.lights = marketLights
                $0.fog = fog { $0.density = 0.012; $0.heightFalloff = 0.08; $0.anisotropy = 0.4; $0.ambient = 0.5; $0.maxDistance = 60 }
                $0.camera = Scene.camera([0.6, 1.7, 30], yaw: 0.02, pitch: 0.12)
            },
            scene(.forest, "Forest", "buildForest", build: { $0.buildForest() }) {
                $0.dayCycle = 180
                $0.dayClock = DayClock(path: .sweep(.valley), hours: 7...19, otherScene: nil)
                $0.hasPlants = true
                $0.hasForest = true
                $0.roles = [.forest]
                $0.scope = seeded
                $0.realisticHaze = 0.3
                $0.realisticWarmth = 0.12
                $0.fog = fog { $0.density = 0.004; $0.heightFalloff = 0.03; $0.anisotropy = 0.7; $0.noise = 0.3; $0.maxDistance = 150 }
                $0.sky = sky {
                    $0.coverage = 0.3; $0.cloudBase = 900; $0.cloudThickness = 900; $0.cloudScale = 1400
                    $0.density = 0.04; $0.windSpeed = 8; $0.shadowStrength = 0.6
                }
                $0.camera = Scene.camera([1.5, 1.7, 10], yaw: 0.06, pitch: 0.1)
            },
            scene(.crowd, "Crowd", "buildCrowd", build: {
                $0.buildCrowd(characters: $0.settings.characters, poses: $0.settings.poses, detail: $0.settings.detail)
            }) {
                $0.cameraFromScene = true
                $0.realisticLook = true
                $0.sky = sky { $0.coverage = 0.3; $0.cloudBase = 1200; $0.cloudThickness = 1000; $0.cloudScale = 2500 }
            },
            scene(.city, "City", "buildCity", build: { $0.buildCity($0.settings.city, seed: $0.settings.seed, night: false) }) {
                $0.dayCycle = 180
                $0.dayClock = DayClock(path: .sweep(.city), hours: 7...19, otherScene: .cityNight)
                $0.isCity = true
                $0.cameraFromScene = true
                $0.roles = [.city]
                $0.scope = city
                // Haze: the far end of an avenue fades toward the sky.
                $0.fog = fog { $0.density = 0.0012; $0.heightFalloff = 0.01; $0.anisotropy = 0.5; $0.noise = 0.15; $0.maxDistance = 150 }
                $0.sky = sky {
                    $0.coverage = 0.3; $0.cloudBase = 1400; $0.cloudThickness = 1200; $0.cloudScale = 3000; $0.shadowStrength = 0.6
                }
                // Its rooms to walk into (CitySettings.interiors): exposure that follows the light (at the street's, a
                // room lit by its windows is black).
                $0.post = { _ in
                    var p = PostSettings()
                    p.autoExposure = true
                    return p
                }
            },
            // At night thousands of lit windows scatter in the fog in blotches: no fog.
            scene(.cityNight, "City at night", "buildCity", build: { $0.buildCity($0.settings.city, seed: $0.settings.seed, night: true) }) {
                $0.dayClock = DayClock(path: .night, hours: 0...24, otherScene: .city)
                $0.isCity = true
                $0.hasLitWindows = true
                $0.cameraFromScene = true
                $0.scope = city
            },
            scene(.world, "Open world", "buildWorld", build: { $0.buildWorld() }) {
                $0.dayCycle = Heavens.day
                $0.dayClock = DayClock(path: .heavens, hours: 0...24, otherScene: nil)
                $0.isWorld = true
                $0.hasLitWindows = true
                $0.cameraFromScene = true
                $0.hasPlants = true
                $0.hasForest = true
                // The noise's tile divides the tiles' 256 m, so the fog stays as it is when the scene's origin moves.
                $0.fog = fog {
                    $0.density = 0.002; $0.heightFalloff = 0.012; $0.anisotropy = 0.6; $0.noise = 0.2; $0.noiseScale = 8
                    $0.maxDistance = 150; $0.haze = 0.4
                    // At night a froxel's one sample among a city's thousands of lamps and windows scatters in blotches.
                    $0.lights = false
                }
                $0.sky = sky {
                    $0.coverage = 0.3; $0.cloudBase = 1300; $0.cloudThickness = 1100; $0.cloudScale = 2800
                    $0.density = 0.04; $0.windSpeed = 10; $0.shadowStrength = 0.6
                }
            },
            scene(.showcase, "Showcase (one model)", "buildShowcase", build: { $0.buildShowcase() }) {
                $0.cameraFromScene = true
                $0.hasParticles = true
                $0.effects = ["embers", "bubbles", "dust", "runes"]
                $0.scope = { "showcase,model=\($0.showcase)" }
                // The base every model's look tunes (ShowcaseLook.fog), and the model's lens.
                $0.fog = fog {
                    $0.density = 0.03; $0.heightFalloff = 0.15; $0.anisotropy = 0.65; $0.ambient = 0.15; $0.noise = 0.5
                    $0.noiseScale = 4; $0.wind = [0.15, 0.04, 0.08]; $0.maxDistance = 30
                }
                $0.tuneFog = { s, f in ShowcaseLook.look(for: s.showcase).fog(&f) }
                $0.post = { ShowcaseLook.look(for: $0.showcase).post }
                // An orbit round the model (it stands on the vertical axis): from 40 degrees round to the default view.
                $0.cameraMove = { p, sceneCamera in
                    guard let sceneCamera else { return nil }
                    let a = -40 * (1 - p) * .pi / 180
                    let turn = simd_quatf(angle: a, axis: [0, 1, 0])
                    let f = turn.act(sceneCamera.forward)
                    var c = sceneCamera
                    c.position = turn.act(sceneCamera.position)
                    c.yaw = atan2(f.x, -f.z)
                    return c
                }
            },
            scene(.shapes, "SDF shapes", "buildShapes", build: { $0.buildShapes() }) {
                $0.camera = Scene.camera([0, 3.9, 4.4], pitch: -0.58)
            },
            scene(.physics, "Physics", "buildPhysics", build: { $0.buildPhysics($0.settings.physics) }) {
                physics($0)
                $0.camera = Scene.camera([0, 4.2, 8.2], pitch: -0.42)
            },
            scene(.ragdolls, "Ragdolls", "buildRagdolls", build: { $0.buildRagdolls($0.settings.physics) }) {
                physics($0)
                $0.camera = Scene.camera([3.2, 3.4, 7.6], yaw: -0.36, pitch: -0.3)
            },
            scene(.hair, "Hair and fur", "buildHair", build: { $0.buildHair($0.settings.physics) }) {
                physics($0)
                $0.camera = Scene.camera([0.1, 1.9, 4.8], yaw: -0.02, pitch: -0.21)
            },
            scene(.softBodies, "Soft bodies", "buildSoftBodies", build: { $0.buildSoftBodies($0.settings.physics) }) {
                physics($0)
                $0.camera = Scene.camera([0, 2.3, 3.0], pitch: -0.42)
            },
            scene(.muscles, "Muscles and skin", "buildMuscles", build: { $0.buildMuscles($0.settings.physics) }) {
                physics($0)
                $0.camera = Scene.camera([0, 2.4, 8.2], pitch: -0.24)
            },
            scene(.fluids, "Fluids", "buildFluids", build: { $0.buildFluids($0.settings.physics) }) {
                physics($0)
                $0.camera = Scene.camera([0, 1.25, 1.05], pitch: -0.64)
            },
            scene(.particles, "Particles", "buildParticles", build: { $0.buildParticles() }) {
                $0.hasParticles = true
                $0.particleShadows = true
                $0.effects = ["campfire", "grinder", "magic", "rain", "rubble"]
                $0.camera = Scene.camera([0.3, 1.7, 6.2], yaw: 0.02, pitch: -0.12)
            },
            scene(.mireland, "Mireland swamp", "buildMireland", build: { $0.buildMireland() }) {
                $0.cameraFromScene = true
                $0.seeded = true
                $0.scope = seeded
                // A misty morning: the far trees grey, the low sun's beams through the mist.
                $0.fog = fog {
                    $0.density = 0.05; $0.heightFalloff = 0.1; $0.anisotropy = 0.75; $0.ambient = 0.35; $0.noise = 0.5; $0.maxDistance = 90
                }
                $0.sky = sky {
                    $0.coverage = 0.45; $0.cloudBase = 800; $0.cloudThickness = 900; $0.cloudScale = 1400
                    $0.density = 0.04; $0.windSpeed = 4; $0.shadowStrength = 0.5
                }
            },
            // Its glass needs reflections: the full look, not the physics'.
            scene(.destruction, "Destruction", "buildDestruction", build: { $0.buildDestruction($0.settings.destruction) }) {
                $0.simulates = true
                $0.roles = [.fracture]
                $0.behaviour = { _ in DestructionPlayer() }
                $0.sky = courtyard
                $0.camera = Scene.camera([0, 2.6, 13.5], pitch: -0.1)
            },
            // In the solid look; its rockets and walker are the CPU's step's alone (Physics+Demolition.swift).
            scene(.demolition, "Demolition", "buildDemolition", build: { $0.buildDemolition($0.settings.demolition) }) {
                $0.simulates = true
                $0.behaviour = { DemolitionPlayer($0) }
                $0.solid = true
                $0.cpuPhysics = true
                $0.sky = courtyard
                $0.camera = Scene.camera([0, 11, 44], pitch: -0.2)
            },
            // An empty floor under the sun, for scripts to build on (README, "Scripts").
            scene(.stage, "Stage (scripts)", "buildStage", build: { $0.buildStage() }) {
                $0.sky = courtyard
                $0.camera = Scene.camera([0, 4, 14], pitch: -0.2)
            },
        ]
    }
}
