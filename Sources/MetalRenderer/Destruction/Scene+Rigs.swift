import Characters
import Effects
import EngineCore
import Foundation
import Materials
import Physics
import Plants
import simd

/// What the destruction and demolition scenes hold for their players (Sources/Game: DestructionPlayer,
/// DemolitionPlayer) and for the engine (the dust of their breaks, the Fracture Editor's list): their pools of shots,
/// rockets and charges, the walker's body and their fractured objects.
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

        /// (As the memberwise initializer, for the modules above this one.)
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
        package var nextRocket = 0
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
            package var body: Int
            package var local: SIMD3<Float>
            package var normal: SIMD3<Float>
            package var world: SIMD3<Float>
            package var worldNormal: SIMD3<Float>

            /// (As the memberwise initializer, for the modules above this one.)
            package init(body: Int, local: SIMD3<Float>, normal: SIMD3<Float>, world: SIMD3<Float>, worldNormal: SIMD3<Float>) {
                self.body = body
                self.local = local
                self.normal = normal
                self.world = world
                self.worldNormal = worldNormal
            }
        }
        package var placed: [Charge] = []
        /// Blocks by kind (DemolitionBlueprint.Kind) and the storeys' floors.
        package var counts: [Int] = []
        package var floors: [Float] = []

        package static let rocketPool = 8, chargePool = 16, fireballPool = 8
        package static let rocketRadius: Float = 0.12

        /// (As the memberwise initializer, for the modules above this one.)
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

    /// The direction and speed that send a ball from `from` to `target` at about `speed` (m/s), aimed up for its drop.
    package static func aim(from: SIMD3<Float>, at target: SIMD3<Float>, speed: Float, gravity: Float) -> (SIMD3<Float>, Float) {
        let d = target - from, t = length(d) / speed
        let v = d / t - SIMD3(0, gravity, 0) * t / 2
        return (normalize(v), length(v))
    }
}

/// The destruction scene's objects for the Fracture Editor.
package struct DestructionStatus: Equatable {
    package var objects: [FractureObjectInfo] = []
}

/// One of the destruction scene's fractured objects as the Fracture Editor shows it.
package struct FractureObjectInfo: Equatable {
    package var name: String
    package var recipe: FractureRecipe
    package var nodes: Int
    package var leaves: Int
    package var welds: Int
    package var levels: Int
}
