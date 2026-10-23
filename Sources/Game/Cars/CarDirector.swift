import EngineCore
import Foundation
import Physics
import simd

/// The crash demos' director (CarPlayer, while CarSettings.demo crashes and no key has been pressed): the run-up in real
/// time; the hit, found from the player's car (its speed falling fast, or its beams bending), and the crash from there
/// in slow motion; then real time again. Each frame's state is the drawn one, so it does the same in every run.
struct CarDirector {
    enum Stage: Equatable { case runUp, slow, done }
    private(set) var stage = Stage.runUp
    /// The hit: when (the world's time, s) and the car's way then (on the ground).
    private(set) var hit: (time: Float, way: SIMD3<Float>)?
    /// The player's car's speed over the last `window` (the world's time, s; m/s along its forward), its beams bent and
    /// broken at the start.
    private var samples: [SIMD2<Float>] = []
    private var damage: Int32?

    /// A hit: the speed down by `drop` (m/s) within `window` (s), or `beams` more bent or broken; not before `settle`
    /// (s: the run-up's start, its suspension settling).
    static let drop: Float = 2.5, window: Float = 0.1, beams: Int32 = 25, settle: Float = 0.3
    /// How long the crash plays slowed from the hit (the world's time, s), and how slow.
    static let slowFor: Float = 1.2, slow: Float = 0.3

    /// The clock's rate (SceneBehaviour.timeScale): slow from the hit.
    var timeScale: Float { stage == .slow ? CarDirector.slow : 1 }

    /// The run-up's watch for the hit: true (and `hit` set) on the frame it finds it.
    mutating func watch(_ t: CarTelemetry, time: Float) -> Bool {
        guard hit == nil, time > CarDirector.settle else { return false }
        samples.append(SIMD2(time, abs(t.speed)))
        samples.removeAll { $0.x < time - CarDirector.window }
        let beams = t.bent + t.broken
        if damage == nil { damage = beams }
        guard samples[0].y - abs(t.speed) > CarDirector.drop || beams - damage! > CarDirector.beams else { return false }
        var way = SIMD3<Float>(t.forward.x, 0, t.forward.z)
        way = length(way) > 1e-3 ? normalize(way) : [0, 0, 1]
        hit = (time, way)
        return true
    }

    /// A frame: the player's car `t` as drawn at the world's time `time`.
    mutating func update(_ t: CarTelemetry, time: Float) {
        switch stage {
        case .runUp:
            if watch(t, time: time) { stage = .slow }
        case .slow:
            if let hit, time - hit.time >= CarDirector.slowFor { stage = .done }
        case .done:
            break
        }
    }
}
