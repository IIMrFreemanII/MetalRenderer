import Foundation
import simd

/// How an edit of the placed effects reaches a scene's running particles (Renderer.editEffects), the cheapest that
/// does it:
/// - `values`: the same pool, structures and code, other numbers: the descriptors, colliders, fields and programs'
///   parameters are written anew and the particles go on as they are (a slider's drag, a curve's key);
/// - `code`: the programs changed (a wire, a node, a block that needs code): the VFX library is compiled for the new
///   ones in the background while the old keep running, then swapped in and the particles replayed from the start;
/// - `rebuild`: the pool's layout, its structures or the meshes' instances change (a capacity, a renderer, shadows on or
///   off, an emitter more): the scene is made again, as any change of its settings makes it.
enum VFXEditKind: Equatable {
    case values, code, rebuild
}

extension ParticleSystem {
    /// What it takes to run `new` in place of this one.
    func edit(to new: ParticleSystem) -> VFXEditKind {
        guard new.emitters.count == emitters.count, new.bases == bases, new.capacity == capacity,
              new.casterCapacity == casterCapacity, new.distortCapacity == distortCapacity, new.meshCapacity == meshCapacity,
              new.trailBases == trailBases, new.trailPoints == trailPoints, new.bakedCurlField == bakedCurlField,
              new.fields.map(\.samples.count) == fields.map(\.samples.count) else { return .rebuild }
        for (a, b) in zip(emitters, new.emitters) {
            guard a.mesh?.mesh == b.mesh?.mesh, a.mesh?.material == b.mesh?.material else { return .rebuild }
        }
        return new.programSource == programSource && new.attributeStride == attributeStride ? .values : .code
    }

    /// `self` with what the scene gave the one it replaces: its meshes' instances, its clock and its gravity.
    func continuing(_ old: ParticleSystem) -> ParticleSystem {
        meshInstances = old.meshInstances
        gravity = old.gravity
        setStepIndex(old.stepIndex)
        return self
    }
}

extension Scene {
    /// The scene's particle system with its placed effects as `catalog` has them (an effect it doesn't name stays as
    /// placed), and the effects; nil when that isn't the same placement (an effect's origin moved, the stage's, or one
    /// edited before goes back to its built-in self): the scene is then made again.
    func particleSystem(replacing old: VFXCatalog, with catalog: VFXCatalog)
        -> (system: ParticleSystem, effects: [VFXInstance], owners: [String], notes: [String])? {
        guard particles != nil, !effects.isEmpty else { return nil }
        var placed = effects
        for i in placed.indices {
            let name = placed[i].effect.name
            if let fx = catalog.effects[name] {
                guard fx.origin == placed[i].effect.origin else { return nil }
                placed[i].effect = fx
            } else if old.effects[name] != nil {
                return nil
            }
        }
        let lowered = VFXLowering.system(placed, colliders: effectColliders)
        let s = lowered.system
        let system = ParticleSystem(emitters: settings.particles.applied(to: s.emitters), colliders: s.colliders,
                                    fields: Array(s.fields.prefix(s.bakedCurlField ?? s.fields.count)), programs: s.programs)
        return (system, placed, Scene.owners(lowered, placed, count: system.emitters.count), lowered.diagnostics)
    }
}

extension Scene {
    /// Per emitter of a lowered system, the name of the effect it is one of.
    static func owners(_ lowered: VFXLowering.Result, _ placed: [VFXInstance], count: Int) -> [String] {
        var owners = [String](repeating: "", count: count)
        for (i, places) in lowered.emitters.enumerated() { for k in places where k < count { owners[k] = placed[i].effect.name } }
        return owners
    }
}

/// What the VFX editor shows of the effects running in the scene (RendererStatus.effects).
struct VFXStatus: Equatable {
    struct Emitter: Equatable {
        var effect: String
        var name: String
        /// It runs generated code (VFXProgram), not only the fixed emitter.
        var program: Bool
        var capacity: Int
        /// Alive as of the last step the GPU finished.
        var alive = 0
    }
    var emitters: [Emitter] = []
    /// The VFX library: compiling for an edit (or the scene's programs), or why it didn't compile.
    var compiling = false
    var failure: String?
    var compileMs: Double?
    /// What the lowering left out or couldn't do (VFXLowering's diagnostics).
    var notes: [String] = []
    /// The settings' effects key the scene runs (SceneSettings.effects).
    var key = ""
    /// The scene's clock (s), and the particle passes' GPU times (ms) when passes are profiled.
    var time: Float = 0
    var passMs: [String: Double] = [:]
}
