import Foundation
import simd

/// What the destruction and demolition scenes' tools hold of their scenes (Renderer+Destruction.swift,
/// Renderer+Demolition.swift): their pools of shots, rockets and charges, the walker's body and their fractured
/// objects. The scenes are the game's (Sources/Game); their tools are still the engine's.
extension Scene {
    /// The scene's scripted times (s) and the pool of balls the Shoot tool fires (Renderer.fireShot).
    package struct DestructionRig {
        package var shots: [Int] = []
        package var nextShot = 0
        /// The fractured objects, as they were made.
        package var objects: [Fractured] = []
        /// Per FractureMaterial, the particle emitter its breaks are events of (ParticleSystem.none: no dust).
        package var dustProxies: [UInt32] = []
        /// Each object's recipe before the Pieces setting's scale (the Fracture Editor's).
        package var recipes: [String: FractureRecipe] = [:]

        /// What the Fracture Editor lists (DestructionStatus.objects).
        var info: [FractureObjectInfo] {
            objects.map { f in
                FractureObjectInfo(name: f.name, recipe: recipes[f.name] ?? f.tree.recipe, nodes: f.tree.nodes.count,
                                   leaves: f.tree.leaves, welds: f.tree.welds.count, levels: f.tree.levels)
            }
        }
        package static let poolSize = 12
        /// The demo's cannonballs, ahead of the pool.
        package static let scripted = 4
        package static let shotSpeed: Float = 16

        /// (As the memberwise initializer, for the game: Sources/Game.)
        package init(shots: [Int] = [], nextShot: Int = 0, objects: [Fractured] = [], dustProxies: [UInt32] = [], recipes: [String: FractureRecipe] = [:]) {
            self.shots = shots
            self.nextShot = nextShot
            self.objects = objects
            self.dustProxies = dustProxies
            self.recipes = recipes
        }
    }

    /// What the demolition scene's tools use: the rockets' pool, the walker's body, the charges' and fireballs'
    /// instances, and what was built.
    package struct DemolitionRig {
        package var rockets: [Int] = []
        var nextRocket = 0
        package var walker = -1
        /// Where the walker starts (outside the front door) and the building's middle.
        package var spawn = SIMD3<Float>()
        package var centre = SIMD3<Float>()
        /// Instances for TNT charges and fireballs (pooled; hidden while unused).
        package var charges: [Int] = []
        package var fireballs: [Int] = []
        package var objects: [Fractured] = []
        package var dustProxies: [UInt32] = []
        /// TNT stuck on pieces (Renderer+Demolition.swift): each on its body (that body's space), and where it was.
        package struct Charge {
            var body: Int
            var local: SIMD3<Float>
            var normal: SIMD3<Float>
            var world: SIMD3<Float>
            var worldNormal: SIMD3<Float>
        }
        var placed: [Charge] = []
        /// Blocks by kind (DemolitionBlueprint.Kind) and the storeys' floors.
        package var counts: [Int] = []
        package var floors: [Float] = []

        package static let rocketPool = 8, chargePool = 16, fireballPool = 8
        package static let rocketRadius: Float = 0.12

        /// (As the memberwise initializer, for the game: Sources/Game.)
        package init(rockets: [Int] = [], nextRocket: Int = 0, walker: Int = -1, spawn: SIMD3<Float> = SIMD3<Float>(), centre: SIMD3<Float> = SIMD3<Float>(), charges: [Int] = [], fireballs: [Int] = [], objects: [Fractured] = [], dustProxies: [UInt32] = [], placed: [Charge] = [], counts: [Int] = [], floors: [Float] = []) {
            self.rockets = rockets
            self.nextRocket = nextRocket
            self.walker = walker
            self.spawn = spawn
            self.centre = centre
            self.charges = charges
            self.fireballs = fireballs
            self.objects = objects
            self.dustProxies = dustProxies
            self.placed = placed
            self.counts = counts
            self.floors = floors
        }
    }

    /// The TNT charges where their bodies are now (`drawn`: the poses drawn this frame), and the fireballs of the rockets
    /// that went off lately: each grows to most of its blast's radius in 0.15 s, then shrinks away by 0.45 s.
    func placeDemolition(_ drawn: [GPUPhysicsBody], _ state: DemolitionState, step: Int) {
        guard var rig = demolitionRig, let physics else { return }
        let hidden = translate([0, -60, 0]) * scale(PhysicsWorld.hiddenScale)
        let nodes = physics.fractureNodes
        for k in rig.placed.indices {
            var c = rig.placed[k]
            // Its body broke: onto the piece of it nearest where it was.
            while drawn.indices.contains(c.body), drawn[c.body].info.y & PhysicsWorld.disabledBit != 0, c.body < nodes.count, nodes[c.body].info.z > 0 {
                let first = Int(nodes[c.body].info.y), count = Int(nodes[c.body].info.z)
                var best = first, nearest = Float.infinity
                for j in first..<first + count {
                    let d = length_squared(PhysicsMath.xyz(drawn[j].position) - c.world)
                    if d < nearest { (best, nearest) = (j, d) }
                }
                let b = drawn[best]
                c.body = best
                c.local = PhysicsMath.qrot(PhysicsMath.qconj(b.rotation), c.world - PhysicsMath.xyz(b.position))
                c.normal = PhysicsMath.qrot(PhysicsMath.qconj(b.rotation), c.worldNormal)
            }
            if drawn.indices.contains(c.body), drawn[c.body].info.y & PhysicsWorld.disabledBit == 0 {
                let b = drawn[c.body]
                c.world = PhysicsMath.xyz(b.position) + PhysicsMath.qrot(b.rotation, c.local)
                c.worldNormal = PhysicsMath.qrot(b.rotation, c.normal)
            }
            rig.placed[k] = c
        }
        for (k, instance) in rig.charges.enumerated() {
            guard k < rig.placed.count else { setTransform(instance, hidden); continue }
            let c = rig.placed[k], n = c.worldNormal
            // Lying on the surface: its thin side along the normal.
            let up = abs(n.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
            let x = normalize(cross(up, n)), y = cross(n, x)
            let turn = float4x4(columns: (SIMD4(x, 0), SIMD4(y, 0), SIMD4(n, 0), SIMD4(0, 0, 0, 1)))
            setTransform(instance, translate(c.world + n * 0.06) * turn * scale([0.22, 0.14, 0.12]))
        }
        var shown = 0
        for (d, s) in zip(state.detonations, state.detonationSteps).reversed() where shown < rig.fireballs.count {
            let age = Float(step - s) * PhysicsWorld.stepLength
            guard age >= 0, age < 0.45 else { continue }
            let most = d.w * 0.6
            let r = age < 0.15 ? most * (1 - pow(1 - age / 0.15, 3)) : most * (1 - (age - 0.15) / 0.3)
            setTransform(rig.fireballs[shown], translate(PhysicsMath.xyz(d)) * scale(SIMD3(repeating: max(r, PhysicsWorld.hiddenScale))))
            shown += 1
        }
        for k in shown..<rig.fireballs.count { setTransform(rig.fireballs[k], hidden) }
        demolitionRig = rig
    }

    /// The direction and speed that send a ball from `from` to `target` at about `speed` (m/s), aimed up for its drop.
    package static func aim(from: SIMD3<Float>, at target: SIMD3<Float>, speed: Float, gravity: Float) -> (SIMD3<Float>, Float) {
        let d = target - from, t = length(d) / speed
        let v = d / t - SIMD3(0, gravity, 0) * t / 2
        return (normalize(v), length(v))
    }
}
