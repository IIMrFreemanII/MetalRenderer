import Characters
import CoreGraphics
import EngineCore
import Foundation
import Physics
import Plants
import simd
import MetalRenderer

/// The benchmark modes: `METALRENDERER_BENCH=<name>` runs that mode's list of settings (`Benchmark.Config`).
/// Setting names become PNG names and the scorers in Tools/eval look them up, so they are part of the interface.
extension Benchmark {
    /// Every mode by name (registered with the scenes, as `Benchmark.modes`). Any other value of METALRENDERER_BENCH
    /// (the documented one is `1`) runs `standard`.
    static let gameModes: [String: () -> [Config]] = [
        "shot": shot, "solid": solid, "quick": quick, "stress": stress, "restir": restir, "gallery": gallery, "gi": gi,
        "lights": lights, "fog": fog, "sky": sky, "forest": forest, "forestcheck": forestcheck,
        "stressq": stressq, "restirq": restirq, "marketq": marketq, "shadow": shadow,
        "noise": noise, "denoise": denoise, "quality": quality, "taa": taa,
        "hwrt": hwrt, "hwrtq": hwrtq, "api": api, "interp": interp,
        "restircheck": restircheck, "restirgicheck": restirgicheck, "lightcheck": lightcheck, "speccheck": speccheck, "fogcheck": fogcheck,
        "skycheck": skycheck, "vgdebug": vgdebug, "debugviews": debugViews, "crowd": crowd, "city": city, "world": world, "worldnight": worldNight,
        "worlddusk": worldDusk, "worldground": worldGround, "worldroads": worldRoads,
        "showcase": showcase, "shapes": shapes, "showcasevideo": showcaseVideo, "shapesdemo": shapesDemo, "stressdemo": stressDemo,
        "pathref": pathref,
        "physics": physics, "physicsdemo": physicsDemo, "ragdolls": ragdolls, "ragdollsdemo": ragdollsDemo,
        "hair": hair, "hairdemo": hairDemo, "hairviews": hairViews, "soft": soft, "softdemo": softDemo, "muscles": muscles, "musclesdemo": musclesDemo,
        "fluids": fluids, "fluidsdemo": fluidsDemo,
        "particles": particles, "particlesdemo": particlesDemo, "plants": plants, "buildings": buildings, "buildingsdemo": buildingsDemo,
        "interiormotion": interiorMotion, "exposurewalk": exposureWalk, "darkroom": darkRoom,
        "characters": characters, "charactercrowd": characterCrowd, "vfx": vfx, "vfxdemo": vfxDemo, "vfxedit": vfxEdit,
        "vfxstage": vfxStage, "vfxstagedemo": vfxStageDemo,
        "outlines": outlines, "materials": materials, "matedit": matEdit, "mireland": mireland, "painter": painterModes, "paintersmart": painterSmart, "painterstrokes": painterStrokes,
    ].merging(terrainModes) { a, _ in a }.merging(waterModes) { a, _ in a }.merging(realismModes) { a, _ in a }
     .merging(destructionModes) { a, _ in a }.merging(demolitionModes) { a, _ in a }

    /// Every scene made once, a frame each: their outlines for the Project Graph (OutlineStore writes them).
    private static func outlines() -> [Config] {
        SceneKind.allCases.map { kind in
            var c = Config("outline \(kind.envName)", scale: 0.25, gi: nil, scene: SceneSettings(kind: kind)).still(at: 0)
            c.frames = 1
            return c
        }
    }

    // MARK: - Shared pieces

    static let env = ProcessInfo.processInfo.environment
    /// Converged references are rendered unless `METALRENDERER_GI_REFS=0`: skip them once they exist.
    private static let wantReferences = env["METALRENDERER_GI_REFS"] != "0"
    static func references(_ list: [Config]) -> [Config] { wantReferences ? list : [] }

    /// `kinds`, or those of them that `METALRENDERER_LIGHTS_SCENES="sun|mixed"` names.
    static func picked(_ kinds: [SceneKind]) -> [SceneKind] {
        guard let only = env["METALRENDERER_LIGHTS_SCENES"]?.split(separator: "|").map(String.init) else { return kinds }
        return kinds.filter { only.contains("\($0)") }
    }

    static func stressHall(objects: Int = 400, lights: Int = 32) -> SceneSettings {
        SceneSettings(kind: .stress, objects: objects, lights: lights)
    }

    /// The three frames a method is scored on, named by `name("static" | "moving" | "camera")`: a still at t = 5 s
    /// with the frame before it (flicker), the animation running, and the scripted camera move. The last two run 300
    /// frames from t = 0, so they end at t = 5 s with the default camera and score against the same reference.
    static func scored(_ base: Config, _ name: (String) -> String) -> [Config] {
        [base.named(name("static")).still(previous: true), base.named(name("moving")), base.named(name("camera")).cameraMove()]
    }
}
