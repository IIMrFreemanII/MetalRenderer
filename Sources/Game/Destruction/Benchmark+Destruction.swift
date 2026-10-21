import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Materials
import Physics
import Plants
import simd
import MetalRenderer

/// The destruction scene's benchmark modes (Scene+Destruction.swift, Physics+Fracture.swift): its demo paused at
/// moments along the way, on each API and on the CPU; what it costs moving; its video; and the massive setting.
extension Benchmark {
    static let destructionModes: [String: () -> [Config]] = [
        "destruction": destruction, "destructiontimes": destructionTimes, "destructionpreview": destructionPreview,
        "destructionmassive": destructionMassive, "destructiondemo": destructionDemo,
        "destructionbuildingdemo": destructionBuildingDemo, "destructioncpu": destructionCPU,
    ]

    /// The demo's moments: before anything, the wrecking ball's hit, the shots, the weight's fall, the dust settled.
    static let destructionMoments: [Float] = [1, 2.7, 3.2, 4.0, 5.0, 6.6, 7.4, 9.0, 12, 19]

    private static func destructionBase(_ name: String) -> Config {
        Config(name, scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: .destruction))
    }

    /// Paused at 9 s with the GPU's steps on each API and with the CPU's (Automatic's: PhysicsSettings.runsOnGPU), the
    /// same breaks on all (Tools/eval/pngdiff.py), then the first 10 s moving for timing at a few piece counts.
    private static func destruction() -> [Config] {
        var out: [Config] = []
        for api in RenderAPI.allCases {
            out.append(destructionBase(api.envName).with { $0.api = api; $0.scene.physics.backend = .gpu }.still(at: 9))
        }
        out.append(destructionBase("cpu").with { $0.scene.physics.backend = .cpu }.still(at: 9))
        for pieces: Float in [1, 2] {
            out.append(destructionBase("gpu \(pieces)x moving").with { $0.scene.destruction.pieces = pieces; $0.scene.physics.backend = .gpu })
        }
        return out
    }

    /// The CPU backend's step (PhysicsCPU.swift, on PhysicsThreads' workers), moving at the physics look (the GPU's part
    /// small; the `cpu` column holds the steps): the courtyard, the massive setting's building, and three of them (over
    /// 10,000 bodies; on the GPU too, for comparison). The steps' worker count is METALRENDERER_PHYSICS_THREADS (1: one
    /// thread).
    private static func destructionCPU() -> [Config] {
        /// From 10 s, the buildings down and their heaps settling (PhysicsCPU.settle: what sleeps).
        func settling(_ c: Config) -> Config { var c = c; c.startTime = 10; return c }
        let base = Config("", scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: SceneSettings(kind: .destruction)) {
            $0.usePhysicsLook()
            $0.scene.physics.backend = .cpu
        }
        let massive = base.with { $0.scene.destruction.massive = true }
        let three = massive.with { $0.scene.destruction.buildings = 3 }
        func gpu(_ c: Config) -> Config { c.with { $0.scene.physics.backend = .gpu } }
        return [base.named("courtyard cpu moving"), gpu(base.named("courtyard gpu moving")),
                massive.named("massive cpu moving"), gpu(massive.named("massive gpu moving")),
                settling(massive.named("massive cpu settling")), settling(gpu(massive.named("massive gpu settling"))),
                three.named("3 buildings cpu moving"), gpu(three.named("3 buildings gpu moving")),
                settling(three.named("3 buildings cpu settling")), settling(gpu(three.named("3 buildings gpu settling")))]
    }

    /// The demo paused at each of its moments (the default API).
    private static func destructionTimes() -> [Config] {
        destructionMoments.map { t in destructionBase(String(format: "t%04.1f", t)).still(at: t) }
    }

    /// The Fracture Editor's preview (DestructionSettings.preview): objects' pieces held apart, at each level.
    private static func destructionPreview() -> [Config] {
        [("Tower", 1), ("Tower", 2), ("Golem", 1), ("Golem", 2), ("Brick wall", 1), ("Pane 1", 1)].map { name, level in
            destructionBase("\(name.lowercased().replacingOccurrences(of: " ", with: "-")) level \(level)").with {
                $0.scene.destruction.preview = FracturePreview(object: name, level: level, explode: 0.35)
            }.still(at: 1)
        }
    }

    /// Massive (DestructionSettings.massive): the courtyard and a building of fractured walls and floors, 4,000 bodies
    /// and more, at the physics look (no GI or reflections: the physics takes the frame). Paused along the building's
    /// fall, then its first 8 s moving for timing. Offline: the M1 Max doesn't keep 60 fps here.
    private static func destructionMassive() -> [Config] {
        let base = Config("", scale: RenderSettings.physicsScale, upscale: 3, gi: nil, scene: SceneSettings(kind: .destruction)) {
            $0.usePhysicsLook()
            $0.scene.destruction.massive = true
        }
        var out = [Float(1), 3, 5, 8, 14].map { t in base.named(String(format: "massive t%04.1f", t)).still(at: t) }
        out.append(base.named("massive moving"))
        return out
    }

    /// The demo's video: its first 20 s along a camera track (`recording`: 600 JPEGs at 30 fps;
    /// `.claude/skills/offscreen/scripts/video.sh -m destructiondemo` makes the mp4). Wide as the ball is let go, in on
    /// the concrete wall as it hits, along the panes and the brick wall as the shots come, up to the tower as the weight
    /// falls, round to the pillars and the golem, and back out over the rubble.
    private static func destructionDemo() -> [Config] {
        func key(_ time: Float, _ position: SIMD3<Float>, _ target: SIMD3<Float>) -> CameraTrack.Key {
            CameraTrack.Key(time: time, position: position, target: target)
        }
        let track = CameraTrack([
            key(0, [0, 2.6, 13.5], [0, 1.4, -2]),
            key(2, [-2.2, 2.2, 6.5], [-4.6, 1.6, -3]),
            key(4, [-1.5, 1.7, 5.2], [-1.2, 1.1, -2.5]),
            key(5.5, [0.6, 1.6, 4.5], [1.2, 0.9, -5]),
            key(7.5, [4.0, 3.2, 3.5], [7.2, 2.6, -5.4]),
            key(9.5, [6.0, 2.0, 4.5], [4.6, 1.4, -2.2]),
            key(12, [4.4, 1.6, 5.5], [2.6, 0.9, 1.4]),
            key(16, [0, 3.4, 11], [0, 1, -3]),
            key(20, [0, 2.6, 13.5], [0, 1.2, -2]),
        ])
        var demo = destructionBase("destruction demo").with { $0.post = ShowcaseLook.lens.with { $0.aperture = 0 } }.track(track).recording()
        demo.startTime = -Float(60) / 60   // Benchmark.warmupFrames x fixedDt
        return [demo]
    }

    /// The massive setting's building coming down, as a video at the scene's full look (`recording`: 540 JPEGs at 30
    /// fps; `.claude/skills/offscreen/scripts/video.sh -m destructionbuildingdemo`): wide over the courtyard, in over the
    /// panes as the blasts take its front corners (2.5 s, 3.5 s), over the tower to its side as the storeys fall, up over
    /// the rubble, and back out. Offline: over 4,000 bodies.
    private static func destructionBuildingDemo() -> [Config] {
        func key(_ time: Float, _ position: SIMD3<Float>, _ target: SIMD3<Float>) -> CameraTrack.Key {
            CameraTrack.Key(time: time, position: position, target: target)
        }
        // (Along the courtyard's right, over the panes, the pillars and the tower: the wrecking ball's gantry on the left
        // is in the way.)
        let track = CameraTrack([
            key(0, [0, 6, 14], [0, 4.5, -15]),
            key(2.4, [1.5, 4.0, 1.0], [0, 3, -13]),
            key(5, [5.5, 5.4, -4], [0, 3.5, -15]),
            key(8, [8.5, 6, -11], [0, 2.5, -15]),
            key(12, [4, 9, -6], [0, 1, -15]),
            key(18, [0, 6.5, 12], [0, 2, -13]),
        ])
        var demo = destructionBase("building demo").with {
            $0.scene.destruction.massive = true
            $0.post = ShowcaseLook.lens.with { $0.aperture = 0 }
        }.track(track).recording()
        demo.startTime = -Float(60) / 60   // Benchmark.warmupFrames x fixedDt
        return [demo]
    }
}
