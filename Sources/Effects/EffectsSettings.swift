import Characters
import CoreGraphics
import EngineCore
import Foundation
import Physics
import Plants
import simd

/// A scene's particle effects (Particles.swift; the particles scene's, the showcase's motes). Changing any of it
/// rebuilds the scene, which starts them again.
package struct ParticleSettings: Equatable, Codable {
    /// Every emitter's rate, bursts and pool times this: the effects thinner or denser (timing).
    package var budget: Float = 1
    /// The particles that cast shadows do (shadow rays look through them); off, none does.
    package var shadows = true
    /// Reflection rays see the particles in front of what they reflect (particleGather); off, mirrors miss them.
    package var reflections = true
    package static let budgetRange: ClosedRange<Float> = 0.25...4

    /// `emitters` as these settings make them.
    package func applied(to emitters: [ParticleEmitter]) -> [ParticleEmitter] {
        emitters.map { e in
            var e = e
            e.capacity = max(Int((Float(e.capacity) * budget).rounded()), 1)
            e.rate *= budget
            if let b = e.burst { e.burst = (b.time, max(Int((Float(b.count) * budget).rounded()), 1), b.period, b.repeats) }
            if !shadows { e.castsShadows = false }
            return e
        }
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(budget: Float = 1, shadows: Bool = true, reflections: Bool = true) {
        self.budget = budget
        self.shadows = shadows
        self.reflections = reflections
    }
}

/// The VFX stage (Scene+Stage.swift): the effects it lines up, by name (VFXLibrary's, or the catalog's: Scene.effect).
package struct VFXStageSettings: Equatable, Codable {
    package var effects = ["fireworks"]
    package var backdrop = VFXBackdrop.dark

    /// (As the memberwise initializer, for the modules above this one.)
    package init(effects: [String] = ["fireworks"], backdrop: VFXBackdrop = VFXBackdrop.dark) {
        self.effects = effects
        self.backdrop = backdrop
    }
}

/// What the VFX stage's effects are shown against.
package enum VFXBackdrop: String, Codable, CaseIterable {
    /// A dark room, a key light and a cool one over it; a grey cyclorama (a floor curving up into a wall), softly lit;
    /// nothing at all, black; a plain under the sun and a blue sky; the plain at night, under the moon.
    case dark, grey, black, outdoor, night
    package var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}
