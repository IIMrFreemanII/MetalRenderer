import Characters
import Effects
import EngineCore
import Foundation
import Physics
import Plants
import simd
import MetalRenderer

/// The demolition scene's benchmark modes (Scene+Demolition.swift): its scripted demo paused along the way in the solid
/// look (the scene's), and in the full one; what it costs moving.
extension Benchmark {
    static let demolitionModes: [String: () -> [Config]] = [
        "demolition": demolition, "demolitionfull": demolitionFull, "demolitioncpu": demolitionCPU,
    ]

    /// The demo's moments: standing, the rocket's hit, the TNT inside, the hole and the walker in it, the burst, the
    /// corners blown, what is left.
    static let demolitionMoments: [Float] = [1, 2.6, 4.5, 6.8, 8.2, 11, 15]

    private static func demolitionBase(_ name: String) -> Config {
        Config(name, scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: .demolition)) {
            $0.scene.demolition.demo = true
            $0.solid = true
        }
    }

    /// The demo paused at each of its moments in the solid look, then its first 15 s moving.
    private static func demolition() -> [Config] {
        demolitionMoments.map { t in demolitionBase(String(format: "t%04.1f", t)).still(at: t) } + [demolitionBase("moving")]
    }

    /// ...in the full look (GI, reflections, the sky).
    private static func demolitionFull() -> [Config] {
        [Float(1), 4.5, 11].map { t in demolitionBase(String(format: "full t%04.1f", t)).with { $0.solid = false }.still(at: t) }
    }

    /// The CPU's step (the `cpu` column) moving: the office standing (asleep), and from 10 s, its corners blown.
    private static func demolitionCPU() -> [Config] {
        var late = demolitionBase("falling")
        late.startTime = 10
        return [demolitionBase("standing").with { $0.scene.demolition.demo = false }, late]
    }
}
