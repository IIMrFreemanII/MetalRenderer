import Foundation
import simd

/// The destruction scene's benchmark modes (Scene+Destruction.swift, Physics+Fracture.swift): its demo paused at
/// moments along the way, on each API and on the CPU; what it costs moving; its video; and the massive setting.
extension Benchmark {
    static let destructionModes: [String: () -> [Config]] = [
        "destruction": destruction, "destructiontimes": destructionTimes,
    ]

    /// The demo's moments: before anything, the wrecking ball's hit, the shots, the weight's fall, the dust settled.
    static let destructionMoments: [Float] = [1, 2.7, 3.2, 4.0, 5.0, 6.6, 7.4, 9.0, 12, 19]

    private static func destructionBase(_ name: String) -> Config {
        Config(name, scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: .destruction))
    }

    /// Paused at 9 s on each API and on the CPU (the same breaks on all: Tools/eval/pngdiff.py), then the first 10 s
    /// moving for timing at a few piece counts.
    private static func destruction() -> [Config] {
        var out: [Config] = []
        for api in RenderAPI.allCases {
            out.append(destructionBase(api.envName).with { $0.api = api }.still(at: 9))
        }
        out.append(destructionBase("cpu").with { $0.scene.physics.backend = .cpu }.still(at: 9))
        for pieces: Float in [1, 2] {
            out.append(destructionBase("gpu \(pieces)x moving").with { $0.scene.destruction.pieces = pieces; $0.scene.physics.backend = .gpu })
        }
        return out
    }

    /// The demo paused at each of its moments (the default API).
    private static func destructionTimes() -> [Config] {
        destructionMoments.map { t in destructionBase(String(format: "t%04.1f", t)).still(at: t) }
    }
}
