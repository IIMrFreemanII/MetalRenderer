import Foundation
import simd

/// A scene's particle effects as graphs (VFXGraph.swift): it places effects (`addEffect`), names the colliders of its
/// own their Collide blocks meet (`addParticleCollider`), then makes one particle system of them (`addEffects`).
extension Scene {
    /// Places the built-in `builtIn`, or the effect of its name the scene's catalog has in its place (a saved file's,
    /// the editor's), moved from where that one is made (its origin) to where `builtIn` is.
    func addEffect(builtIn: VFXEffect, meshes: [String: (mesh: Int, material: Int)] = [:]) {
        guard let fx = VFXCatalog.resolve(settings.effects).effects[builtIn.name] else {
            addEffect(builtIn, meshes: meshes)
            return
        }
        addEffect(fx, at: VFXPlacement(offset: builtIn.origin - fx.origin), meshes: meshes)
    }

    /// Places `effect` (`at`: moved by; an effect written in the scene's own space is placed where it is), its Mesh
    /// blocks' names bound to the scene's meshes and materials.
    func addEffect(_ effect: VFXEffect, at place: VFXPlacement = .identity, meshes: [String: (mesh: Int, material: Int)] = [:]) {
        effects.append(VFXInstance(effect: effect, place: place, meshes: meshes))
    }

    /// A collider the effects' Collide blocks can name: the scene's floor, a crate, an SDF shape's instance.
    func addParticleCollider(_ name: String, _ collider: ParticleCollider) {
        effectColliders.append((name, collider))
    }

    /// The placed effects as the scene's particle system (once, after the last is placed).
    func addEffects() {
        let lowered = VFXLowering.system(effects, colliders: effectColliders)
        effectNotes = lowered.diagnostics
        for note in lowered.diagnostics { print("Effects: \(note)") }
        effectOwners = Scene.owners(lowered, effects, count: lowered.system.emitters.count)
        addParticles(lowered.system)
    }
}
