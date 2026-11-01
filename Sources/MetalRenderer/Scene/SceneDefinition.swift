import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Landscape
import Materials
import Physics
import Plants
import simd

/// Which scene is loaded: a name the registry knows (SceneRegistry). The engine's own scenes are the Cornell room (its
/// default, and its tests' fixture) and the editors' workshops; the demo scenes are the game's (Sources/Game), which
/// names its own the same way (`extension SceneKind { static let demolition = SceneKind("demolition") }`), so
/// `kind == .demolition` reads as it did when this was an enum.
package struct SceneKind: Hashable, Codable, CustomStringConvertible {
    /// The name it is known by in code, in saved settings and in outlines (`cityNight`, `softBodies`).
    package let name: String

    package init(_ name: String) { self.name = name }
    package var description: String { name }
    /// What the engine asks of it; a scene this build doesn't have is the Cornell room.
    package var definition: SceneDefinition { SceneRegistry.definition(self) }

    package static let cornell = SceneKind("cornell")
    package static let plants = SceneKind("plants")
    package static let buildings = SceneKind("buildings")
    package static let characters = SceneKind("characters")
    package static let vfxStage = SceneKind("vfxStage")
    package static let materials = SceneKind("materials")
    package static let painter = SceneKind("painter")
    package static let terrain = SceneKind("terrain")

    /// The scenes when they were an enum, in its order: settings saved then hold a case's number, and the settings
    /// panel lists the scenes in this order.
    package static let numbered = ["cornell", "stress", "gallery", "spots", "sun", "area", "tubes", "emissive", "mixed", "fog", "valley",
                           "market", "forest", "crowd", "city", "cityNight", "world", "showcase", "shapes", "physics", "ragdolls",
                           "hair", "softBodies", "muscles", "fluids", "particles", "plants", "buildings", "characters", "vfxStage",
                           "materials", "mireland", "painter", "terrain", "destruction", "demolition", "stage"]

    package init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) {
            self.init(SceneKind.numbered.indices.contains(n) ? SceneKind.numbered[n] : SceneKind.cornell.name)
        } else {
            self.init(try c.decode(String.self))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }

    // What the engine asks of a scene, by its kind (SceneDefinition).
    package var title: String { definition.title }
    package var simulates: Bool { definition.simulates }
    package var usesPhysicsLook: Bool { definition.physicsLook }
    package var hasLightCount: Bool { definition.lights != nil }
    package var dayCycle: Float? { definition.dayCycle }
    package var isCity: Bool { definition.isCity }
    package var isWorld: Bool { definition.isWorld }
    package var hasLitWindows: Bool { definition.hasLitWindows }
    package var cameraFromScene: Bool { definition.cameraFromScene || isWorkshop }
    /// The editors' scenes: one thing (a plant, a building) made again at every edit, an orbit camera round it.
    package var isWorkshop: Bool { self == .plants || self == .buildings || self == .characters }
    package var hasPlants: Bool { definition.hasPlants }
    package var hasForest: Bool { definition.hasForest }
    package var hasRealisticLook: Bool { definition.realisticLook || hasPlants }
}

/// Scenes the editors open to show their work in a world: the building editor's city, the plant editor's forest, the
/// Fracture Editor's courtyard. A build without such a scene leaves the editor's button off.
package enum SceneRole {
    case city, forest, fracture
}

/// What the engine asks of a scene: how to build it, what it is and what suits it (its fog, sky, lens, camera and
/// day). Registered once at launch by whoever has the scene (SceneRegistry); read when a scene is chosen, built and
/// shown, a few times a frame at most.
package final class SceneDefinition {
    package let kind: SceneKind
    package let title: String
    /// Its name in METALRENDERER_SCENE and in outlines.
    package let envName: String
    /// Its builder's name, for the Project Graph to find its source (SourceIndex).
    package let builder: String
    /// Fills the scene, as `scene.settings` says (Scene.init).
    package let build: (Scene) -> Void

    // What it is.
    /// The physics steps it (Physics.swift): it shares the physics' settings.
    package var simulates = false
    /// ...drawn in the physics' plain look (RenderSettings.usePhysicsLook).
    package var physicsLook = false
    /// Its physics stays on the CPU when the backend is Automatic (fractured worlds: the GPU is latency-bound there).
    package var cpuPhysics = false
    /// Built with `SceneSettings.lights` lights (the panel's Lights slider): how many it starts with.
    package var lights: Int? = nil
    /// Length of the sun's day cycle in seconds, or nil; and the day bar's clock of it.
    package var dayCycle: Float? = nil
    package var dayClock: DayClock? = nil
    /// The generated city (`SceneSettings.city`), the open world, a share of their windows lit at night.
    package var isCity = false
    package var isWorld = false
    package var hasLitWindows = false
    /// Its default camera depends on how it was built: the scene says it.
    package var cameraFromScene = false
    /// Generated plants (Foliage), and as many as `SceneSettings.trees` and `undergrowth` say.
    package var hasPlants = false
    package var hasForest = false
    /// The realistic look changes it (SceneSettings.realism), besides the scenes with plants: the ones outdoors.
    package var realisticLook = false
    /// `SceneSettings.seed` makes it (the panel's Plant seed slider), besides the scenes with plants.
    package var seeded = false
    /// It has particle effects (the panel's particle budget and layer), and their shadows and reflections can be turned
    /// off (the showcase's are its look's).
    package var hasParticles = false
    package var particleShadows = false
    /// It holds the glTF models of Assets/ (the gallery).
    package var loadsModels = false
    /// It opens in the solid look (RenderSettings.solid), and leaving it gives the look back.
    package var solid = false
    package var roles: Set<SceneRole> = []
    /// The built-in effects it places (VFXLibrary), for the VFX editor to preview them there.
    package var effects: Set<String> = []

    /// A first launch opens it (RenderSettings.firstLaunch).
    package var opensFirst = false

    // What suits it.
    /// The fog, before METALRENDERER_FOG; off unless set.
    package var fog = FogSettings()
    /// The sky, before METALRENDERER_SKY; a constant colour unless set.
    package var sky = SkySettings()
    /// Its fog for its settings, on top of `fog` (the showcase's model's).
    package var tuneFog: ((SceneSettings, inout FogSettings) -> Void)? = nil
    /// Its own lens and finish (the showcase model's, the city's exposure); nil: off, or the realistic look's.
    package var post: ((SceneSettings) -> PostSettings)? = nil
    /// Its own in the classic look alone (PostSettings.classic), when that isn't `post`.
    package var classicPost: ((SceneSettings) -> PostSettings)? = nil
    /// With the realistic look: whether the distance fades (aerial perspective: the fog's), how much haze it has, how
    /// warm the grade is.
    package var realisticAir = true
    /// Radiance cascades: whether a probe ray that misses, with no coarser probe on its surface to take light from,
    /// asks whether it reaches the sky (RadianceCascades.metal RC_SKY_GAPS). A lone tree under an open sky needs it
    /// (its crown's leaves came out a third darker than path traced). It costs a forest ~0.8 ms.
    package var cascadeSkyGaps = false
    /// Radiance cascades: a hit whose own light isn't known takes CascadeSettings.hiddenLight of the probes' mean rather
    /// than all of it. For one thing on an open stage: the mean is the stage's, and such hits lie inside the thing.
    package var cascadeHiddenLight = false
    package var realisticHaze: Float = 0.55
    package var realisticWarmth: Float = 0.06
    /// Its default camera, unless the scene says (`cameraFromScene`).
    package var camera: Camera? = nil
    /// The benchmarks' camera move at progress p (0...1), given the scene's own camera; nil (or a nil camera): a step
    /// to the side and back toward the default view (Benchmark.cameraPose).
    package var cameraMove: ((Float, Camera?) -> Camera?)? = nil
    /// What its materials' order depends on (MaterialAssignments.scope): its name, unless given.
    package var scope: ((SceneSettings) -> String)? = nil
    /// Its gameplay (SceneBehaviour), made with the scene once it is built.
    package var behaviour: ((Scene) -> SceneBehaviour)? = nil
    /// What the benchmark's table adds to its name (the stress test's counts).
    package var detail: ((SceneSettings) -> String)? = nil

    package init(_ kind: SceneKind, _ title: String, builder: String, envName: String? = nil, build: @escaping (Scene) -> Void) {
        self.kind = kind
        self.title = title
        self.builder = builder
        self.envName = envName ?? kind.name.lowercased()
        self.build = build
    }

    /// The fog and sky presets read as they are set: `fog.enabled = true; fog.density = …`.
    @discardableResult
    package func with(_ edit: (SceneDefinition) -> Void) -> SceneDefinition {
        edit(self)
        return self
    }
}

/// The game's entry: a class named `MetalRendererGameScenes` that registers the game's scenes (and their benchmark
/// modes and settings rows). The engine finds it by name, so it needn't import the game: the app and the tests link
/// both, and whichever asks for a scene first registers them.
@objc package protocol SceneProvider {
    static func registerScenes()
}

/// The scenes this build has, by kind: the engine's own (below) and the game's (SceneProvider). Registered before the
/// first scene is asked for, read from any thread after.
package enum SceneRegistry {
    private static var definitions: [SceneKind: SceneDefinition] = [:]
    private static var ordered: [SceneKind] = []

    package static func register(_ definition: SceneDefinition) {
        if definitions[definition.kind] == nil { ordered.append(definition.kind) }
        definitions[definition.kind] = definition
        let rank = { (k: SceneKind) in SceneKind.numbered.firstIndex(of: k.name) ?? Int.max }
        ordered = ordered.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// Every scene, in the settings panel's order.
    package static var kinds: [SceneKind] {
        found
        return ordered
    }

    package static func definition(_ kind: SceneKind) -> SceneDefinition {
        found
        if let d = definitions[kind] { return d }
        return definitions[.cornell]!
    }

    package static func has(_ kind: SceneKind) -> Bool {
        found
        return definitions[kind] != nil
    }

    /// The scene an editor opens to show its work in a world, if this build has one.
    package static func kind(for role: SceneRole) -> SceneKind? { kinds.first { definitions[$0]!.roles.contains(role) } }

    /// The scene named `name` (its envName, without regard to case).
    package static func kind(named name: String) -> SceneKind? {
        let n = name.lowercased()
        return kinds.first { definitions[$0]!.envName == n }
    }

    private static let found: Void = {
        registerEngineScenes()
        (NSClassFromString("MetalRendererGameScenes") as? SceneProvider.Type)?.registerScenes()
    }()

    /// The Cornell room and the editors' workshops.
    private static func registerEngineScenes() {
        register(SceneDefinition(.cornell, "Cornell room", builder: "buildCornell") { $0.buildCornell() })
        // A few high clouds, no shadows of them: what the editor shapes is what is looked at.
        var studioSky = SkySettings()
        studioSky.mode = .atmosphere; studioSky.coverage = 0.15; studioSky.cloudBase = 1500; studioSky.cloudThickness = 900
        studioSky.cloudScale = 2500; studioSky.shadows = false
        // The plant workshop, as Unreal's tree preview (its Grey Ambient profile): a constant grey sky lights the plant
        // (Scene.previewSky; its camera sees a dark grey backdrop, Scene.backdrop), no air in the distance, a fixed
        // exposure and a mild grade, lights its behaviour turns.
        var previewSky = SkySettings()
        previewSky.mode = .constant; previewSky.clouds = false; previewSky.coverage = 0; previewSky.shadows = false
        register(SceneDefinition(.plants, "Plant workshop", builder: "buildPlantWorkshop") { $0.buildPlantWorkshop() }.with {
            $0.hasPlants = true; $0.sky = previewSky; $0.realisticAir = false; $0.cascadeSkyGaps = true; $0.cascadeHiddenLight = true
            $0.post = { scene in
                var p = PostSettings()
                guard scene.realism != .off else { return p }
                p.saturation = 1.03; p.contrast = 1.05; p.bloom = 0.15; p.bloomThreshold = 1.6; p.vignette = 0.16
                return p
            }
            $0.behaviour = { PlantPreviewPlayer($0) }
        })
        register(SceneDefinition(.buildings, "Building workshop", builder: "buildBuildingWorkshop") { $0.buildBuildingWorkshop() }.with {
            $0.realisticLook = true; $0.sky = studioSky; $0.cascadeHiddenLight = true
        })
        register(SceneDefinition(.characters, "Character workshop", builder: "buildCharacterWorkshop", envName: "people") {
            $0.buildCharacterWorkshop()
        }.with { $0.sky = studioSky })
        register(SceneDefinition(.vfxStage, "VFX stage", builder: "buildVFXStage") { $0.buildVFXStage() }.with {
            $0.hasParticles = true; $0.particleShadows = true; $0.camera = Scene.camera([0, 2.4, 10.5], pitch: 0.02)
        })
        register(SceneDefinition(.materials, "Material workshop", builder: "buildMaterialWorkshop") { $0.buildMaterialWorkshop() }.with {
            $0.camera = Scene.camera([0, 2.0, 6.6], pitch: -0.17); $0.scope = { _ in "materials" }
        })
        register(SceneDefinition(.painter, "Painter workshop", builder: "buildPainterWorkshop") { $0.buildPainterWorkshop() }.with {
            $0.camera = Scene.camera([0, 1.5, 3.4], pitch: -0.16)
            $0.scope = { s in "painter,subject=\(s.painterWorkshop.subject.rawValue),model=\(s.painterWorkshop.model)" }
        })
        register(SceneDefinition(.modelingStage, "Modeller stage", builder: "buildModelingStage") { $0.buildModelingStage() }.with {
            $0.sky = studioSky; $0.camera = Scene.camera([0, 1.4, 6.5], pitch: -0.14)
        })
        register(SceneDefinition(.terrain, "Terrain workshop", builder: "buildTerrainWorkshop") { $0.buildTerrainWorkshop() }.with {
            $0.dayCycle = 180; $0.cameraFromScene = true; $0.realisticLook = true
            // A light haze: the far side of kilometres of ground fades.
            $0.fog.enabled = true; $0.fog.density = 0.0003; $0.fog.heightFalloff = 0.006; $0.fog.anisotropy = 0.5; $0.fog.noise = 0.1
            $0.fog.maxDistance = 400; $0.fog.haze = 0.25
            $0.sky.mode = .atmosphere; $0.sky.coverage = 0.3; $0.sky.cloudBase = 1300; $0.sky.cloudThickness = 1100
            $0.sky.cloudScale = 2800; $0.sky.density = 0.04; $0.sky.windSpeed = 8; $0.sky.shadowStrength = 0.6
        })
    }
}
