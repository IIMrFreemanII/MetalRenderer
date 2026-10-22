import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Landscape
import Materials
import Physics
import Plants

/// A scene's sun along its day: where it is between morning (0) and evening (1) at time t of the scene's day clock.
/// The scenes pose their suns with it (Scene+Lights, Scene+City), and the day bar reads it as a clock (`DayClock`).
package struct DaySweep: Equatable {
    /// Seconds from morning to evening.
    var length: Float
    /// The sun then goes back the way it came, in as long (the valley's, the city's); or else the day starts again at
    /// the morning, where the evening ended (the sun courtyard's).
    var back: Bool
    /// How far into its way out the sun is at t = 0, as a share of it (eased by a cosine when it goes back).
    var lead: Float

    /// The sun courtyard's: 60 s from morning to evening, the sun 8 degrees up at each end.
    package static let courtyard = DaySweep(length: 60, back: false, lead: 0.2)
    /// The valley's and the forest's, and the day city's: 90 s each way.
    package static let valley = DaySweep(length: 90, back: true, lead: 0.35)
    package static let city = DaySweep(length: 90, back: true, lead: 0.3)

    /// The whole day, there and back.
    var cycle: Float { back ? 2 * length : length }

    /// 0 = morning ... 1 = evening.
    package func phase(_ t: Float) -> Float {
        if back { return 0.5 - 0.5 * cos(.pi * (t / length + lead)) }
        let p = t / length + lead
        return p - p.rounded(.down)
    }

    /// The time on the way out at which the sun is at `phase`, in 0..<cycle.
    func time(_ phase: Float) -> Float {
        let p = min(max(phase, 0), 1)
        let t = length * ((back ? acos(1 - 2 * p) / .pi : p) - lead)
        return DayClock.wrap(t, cycle)
    }
}

/// The four times the day bar and the settings panel switch to.
package enum DayPreset: Int, CaseIterable {
    case dawn, noon, sunset, night

    package var title: String { ["Dawn", "Noon", "Sunset", "Night"][rawValue] }
}

/// A scene's day as a clock (the day bar's, the settings panel's Dawn/Noon/Sunset/Night): the open world's goes round
/// the 24 hours with its night (Heavens); the scenes whose sun only goes from morning to evening and back (the sun
/// courtyard, the valley, the forest, the city) show that as 07:00 to 19:00, and the city's night is the night city,
/// another scene.
package struct DayClock {
    package enum Path {
        case heavens                // the open world's
        case sweep(DaySweep)        // morning to evening (and back)
        case night                  // the night city's: always night, no clock
    }
    package let path: Path
    /// The hours the clock shows, from its morning to its evening.
    package let hours: ClosedRange<Float>
    /// The scene Night switches to (the day city's), or the one the day's times switch back to (the night city's).
    package let otherScene: SceneKind?

    /// A day that jumps this much of its cycle (half an hour of the open world's) starts the light over: what the
    /// frames before gathered of it (ReSTIR's reservoirs, the cascades, the denoiser's history) would
    /// smear the old light into the new. Less than that moves as the sun does when the day runs.
    package static let lightJump: Float = 1 / 48

    /// Scene `kind`'s clock (its definition's), if it has one.
    package static func of(_ kind: SceneKind) -> DayClock? { kind.definition.dayClock }

    /// Seconds of the scene's day clock (`SceneKind.dayCycle`); 0 for the night city's.
    package var cycle: Float {
        switch path {
        case .heavens: return Heavens.day
        case .sweep(let s): return s.cycle
        case .night: return 0
        }
    }

    /// Whether the clock runs: not the night city's.
    package var runs: Bool { if case .night = path { return false } else { return true } }

    /// The hour (0..<24) at `dayTime` seconds of the scene's day clock; nil for the night city's.
    package func hour(dayTime: Float) -> Float? {
        switch path {
        case .heavens: return 24 * Heavens.phase(at: dayTime)
        case .sweep(let s): return hours.lowerBound + (hours.upperBound - hours.lowerBound) * s.phase(dayTime)
        case .night: return nil
        }
    }

    /// The time of the scene's day clock (0..<cycle) at `hour`, clamped to the clock's hours; on the way out for a sun
    /// that goes back.
    package func dayTime(hour: Float) -> Float {
        switch path {
        case .heavens: return DayClock.wrap((hour / 24 - Heavens.start) * Heavens.day, Heavens.day)
        case .sweep(let s): return s.time((hour - hours.lowerBound) / (hours.upperBound - hours.lowerBound))
        case .night: return 0
        }
    }

    /// The hour `preset` is at on this clock; nil where it isn't one (Night by day, which is another scene; the day's
    /// times by night).
    package func hour(of preset: DayPreset) -> Float? {
        switch path {
        case .heavens:   // the sun just up, high, just down (Benchmark+Modes' worldDusk), and midnight
            return [0.205, 0.5, 0.803, 0][preset.rawValue] * 24
        case .sweep:
            let lo = hours.lowerBound, hi = hours.upperBound
            return preset == .night ? nil : [lo, (lo + hi) / 2, hi][preset.rawValue]
        case .night:
            return nil
        }
    }

    /// Whether `preset` can be picked here (in this scene or by switching to the other): by night, every one.
    package func offers(_ preset: DayPreset) -> Bool {
        !runs || hour(of: preset) != nil || (preset == .night && otherScene != nil)
    }

    /// Whether picking `preset` goes to the other scene: Night by day, the day's times by night.
    package func switches(_ preset: DayPreset) -> Bool {
        otherScene != nil && (runs ? preset == .night && hour(of: preset) == nil : preset != .night)
    }

    /// The preset at `hour` (within half a minute), for the controls to show it picked; the night city's is Night.
    package func preset(at hour: Float?) -> DayPreset? {
        guard let hour else { return runs ? nil : .night }
        return DayPreset.allCases.first { p in
            guard let h = self.hour(of: p) else { return false }
            let d = abs(h - hour)
            return min(d, 24 - d) < 0.5 / 60
        }
    }

    /// Whether the scene is lit by night at `hour`: the open world's sun under the horizon; the night city's always.
    package func isNight(hour: Float?) -> Bool {
        switch path {
        case .heavens: return hour.map { Heavens(at: dayTime(hour: $0)).sunElevation < 0 } ?? false
        case .sweep: return false
        case .night: return true
        }
    }

    /// "14:30".
    package static func label(_ hour: Float) -> String {
        let minutes = Int((hour * 60).rounded()) % (24 * 60)
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// `t` in 0..<length.
    package static func wrap(_ t: Float, _ length: Float) -> Float {
        guard length > 0 else { return 0 }
        let r = t - length * (t / length).rounded(.down)
        return r < length ? r : 0
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(path: Path, hours: ClosedRange<Float>, otherScene: SceneKind?) {
        self.path = path
        self.hours = hours
        self.otherScene = otherScene
    }
}

extension RenderSettings {
    /// The time on the scene's day clock with the animation's at `animTime`: offset by `timeOfDay`, or held at it
    /// (`dayHeld`). A scene without a day cycle keeps the animation's time.
    package func dayTime(animTime: Float) -> Float {
        guard let cycle = scene.kind.dayCycle else { return animTime }
        return (dayHeld ? 0 : animTime) + timeOfDay * cycle
    }

    /// The day as a clock's hour, where the settings hold it; nil while it runs (the renderer tells the time then).
    package var heldHour: Float? {
        guard dayHeld, let clock = DayClock.of(scene.kind), let cycle = scene.kind.dayCycle else { return nil }
        return clock.hour(dayTime: timeOfDay * cycle)
    }

    /// `dayHeld` turned on or off since `old`, `timeOfDay` left as it was: `timeOfDay` changes with it so that the day
    /// stays where it was, at `animTime` (the panel's checkbox, the day bar's play button).
    package mutating func keepDay(from old: RenderSettings, animTime: Float) {
        guard dayHeld != old.dayHeld, timeOfDay == old.timeOfDay, scene.kind == old.scene.kind,
              let cycle = scene.kind.dayCycle, cycle > 0 else { return }
        let t = (dayHeld ? old.dayTime(animTime: animTime) : old.dayTime(animTime: animTime) - animTime) / cycle
        timeOfDay = t - t.rounded(.down)
    }

    /// Holds the day at `hour` of the scene's clock.
    package mutating func holdDay(hour: Float) {
        guard let clock = DayClock.of(scene.kind), clock.runs, clock.cycle > 0 else { return }
        dayHeld = true
        timeOfDay = clock.dayTime(hour: hour) / clock.cycle
    }

    /// Holds the day at `preset`: in the night city for the day city's Night, and back in the day city for the
    /// night's other times (a new scene, with its defaults, as the panel's scene popup makes it).
    package mutating func holdDay(_ preset: DayPreset, defaults: RenderSettings) {
        guard let clock = DayClock.of(scene.kind) else { return }
        if clock.switches(preset), let other = clock.otherScene {
            scene.kind = other
            scene.extraModels = []
            applySceneDefaults(from: defaults)
        }
        guard let now = DayClock.of(scene.kind), let hour = now.hour(of: preset) else { return }
        holdDay(hour: hour)
    }
}
