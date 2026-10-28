import CoreGraphics
import EngineCore
import Foundation
import simd

/// The Fracture Editor's look at one object's pieces (DestructionSettings.preview).
package struct FracturePreview: Equatable, Codable {
    package var object: String
    /// The level shown (1: the object's pieces), and how far apart they are (a share of their distance from its middle).
    package var level = 1
    package var explode: Float = 0.4

    /// (As the memberwise initializer, for the modules above this one.)
    package init(object: String, level: Int = 1, explode: Float = 0.4) {
        self.object = object
        self.level = level
        self.explode = explode
    }
}

/// The destruction scene's (Scene+Destruction.swift). Changing any of it builds the scene again.
package struct DestructionSettings: Equatable, Codable {
    /// Scales every object's pieces (the first level's count, the next ones' by its square root).
    package var pieces: Float = 1
    /// Scale what breaks a piece into its children and frees it (toughness), and what a weld holds (strength).
    package var toughness: Float = 1
    package var strength: Float = 1
    /// Dust and debris where pieces part (the scene's particles), and small pieces fading away once still.
    package var dust = true
    package var fade = true
    /// Welds that give way go loose first (pieces hinge and hang on before they fall: Physics+LooseJoints.swift).
    /// The CPU's step only: on the GPU they break at once.
    package var looseJoints = true
    /// The scripted wrecking ball, weight and cannonballs (off: only what the tools do).
    package var demo = true
    /// The courtyard's objects only, or a whole building of pieces too (4,000 and more: offline).
    package var massive = false
    /// With `massive`: how many of its buildings stand side by side in the lot (3: over 10,000 bodies).
    package var buildings = 1
    package static let buildingRange = 1...3
    /// The statues: the meshes cut piece by piece (textures kept), or none.
    package var statues = true
    /// The Fracture Editor's edits, by object name, over the saved recipes (FractureStore) and the defaults (session
    /// state); and its preview: one object's pieces at a level, held apart (nothing moves, no demo).
    package var recipes: [String: FractureRecipe] = [:]
    package var preview: FracturePreview?

    package static let pieceRange: ClosedRange<Float> = 0.25...4
    package static let toughnessRange: ClosedRange<Float> = 0.1...10

    /// (As the memberwise initializer, for the modules above this one.)
    package init(pieces: Float = 1, toughness: Float = 1, strength: Float = 1, dust: Bool = true, fade: Bool = true, looseJoints: Bool = true, demo: Bool = true, massive: Bool = false, buildings: Int = 1, statues: Bool = true, recipes: [String: FractureRecipe] = [:], preview: FracturePreview? = nil) {
        self.pieces = pieces
        self.toughness = toughness
        self.strength = strength
        self.dust = dust
        self.fade = fade
        self.looseJoints = looseJoints
        self.demo = demo
        self.massive = massive
        self.buildings = buildings
        self.statues = statues
        self.recipes = recipes
        self.preview = preview
    }
}

/// The demolition scene's (Scene+Demolition.swift). Changing any of it builds the scene again.
package struct DemolitionSettings: Equatable, Codable {
    /// The office: its storeys, its seed (another plan, other rooms), its lot (m, x and z).
    package var floors = 5
    package var seed = 7
    package var width: Float = 24
    package var depth: Float = 16
    /// Scales every object's pieces (as DestructionSettings.pieces), what breaks them and what their welds hold.
    package var pieces: Float = 1
    package var toughness: Float = 1
    package var strength: Float = 1
    /// The rooms' furniture, fractured too; the windows' glass.
    package var furniture = true
    package var glass = true
    /// Dust and debris where pieces part, and small pieces fading away once still.
    package var dust = true
    package var fade = true
    /// Welds that give way go loose first (as DestructionSettings.looseJoints).
    package var looseJoints = true
    /// The scripted demo (a rocket, TNT, a burst, the walker into a hole: the benchmark's and the tests'); off: only
    /// what the player does.
    package var demo = false

    package static let floorRange = 4...6
    package static let seedRange = 1...999
    package static let sizeRange: ClosedRange<Float> = 12...36
    package static let pieceRange: ClosedRange<Float> = 0.25...2
    package static let toughnessRange: ClosedRange<Float> = 0.1...10

    /// (As the memberwise initializer, for the modules above this one.)
    package init(floors: Int = 5, seed: Int = 7, width: Float = 24, depth: Float = 16, pieces: Float = 1, toughness: Float = 1, strength: Float = 1, furniture: Bool = true, glass: Bool = true, dust: Bool = true, fade: Bool = true, looseJoints: Bool = true, demo: Bool = false) {
        self.floors = floors
        self.seed = seed
        self.width = width
        self.depth = depth
        self.pieces = pieces
        self.toughness = toughness
        self.strength = strength
        self.furniture = furniture
        self.glass = glass
        self.dust = dust
        self.fade = fade
        self.looseJoints = looseJoints
        self.demo = demo
    }
}

/// The car scene's (Scene+CarGround.swift, Physics+Cars.swift). Changing any of it builds the scene again.
package struct CarSettings: Equatable, Codable {
    /// What the scene does by itself: nothing (the player drives), the player's car into the wall at `demoSpeed`, every
    /// car round its own lap on autopilot (the benchmark's); the player's car and the next head on, each at
    /// `demoSpeed`; the player's car through the brick wall, or into the crates, at `demoSpeed`.
    package enum Demo: Int, CaseIterable, Codable {
        case none, wall, laps, headOn, breakables, props
        package var title: String { ["None", "Into the wall", "Laps", "Head on", "Through the brick wall", "Into the crates"][rawValue] }
        /// Whether its cars start at `demoSpeed`.
        package var crashes: Bool { self != .none && self != .laps }
    }
    /// The player's car, and how many cars there are (the player's, and the other styles parked in turn).
    package var style = CarStyle.civic
    package var cars = 4
    package var demo = Demo.none
    /// The wall demo's speed (km/h).
    package var demoSpeed: Float = 50
    /// Traction control and ABS (CarTune.assists).
    package var assists = true

    package static let carRange = 1...8
    package static let speedRange: ClosedRange<Float> = 20...150

    /// (As the memberwise initializer, for the modules above this one.)
    package init(style: CarStyle = CarStyle.civic, cars: Int = 4, demo: Demo = Demo.none, demoSpeed: Float = 50, assists: Bool = true) {
        self.style = style
        self.cars = cars
        self.demo = demo
        self.demoSpeed = demoSpeed
        self.assists = assists
    }
}

/// The physics scene's (Physics.swift). Changing any of it rebuilds the scene, which starts the simulation again.
package struct PhysicsSettings: Equatable, Codable {
    /// Where the steps run: the GPU (Shaders/Physics.metal), the CPU (PhysicsCPU.swift), or whichever suits the
    /// scene (`runsOnGPU`).
    package enum Backend: Int, CaseIterable, Codable {
        case auto, gpu, cpu
        package var title: String { ["Automatic", "GPU", "CPU"][rawValue] }
    }
    package var backend = Backend.auto
    /// The CPU's steps on a thread of their own, behind the frame (PhysicsStepper): the frame doesn't wait for them.
    package var asynchronous = true
    /// The CPU's steps on every core (PhysicsPool), or on one: the same numbers either way.
    package var everyCore = true
    /// Substeps a step (1/60 s): more hold stacks stiffer, for more work (8 lets a tower of 8 crossed layers sink
    /// through the floor; 12 holds it to 3 mm).
    package var substeps = 16
    /// Rigid bodies poured in, and particles poured into a bin.
    package var bodies = 96
    package var particles = 2048
    /// The cloth's vertices along a side (0: no cloth).
    package var cloth = 36
    /// Ragdolls dropped down the ragdoll scene's stairs (11 bodies each).
    package var ragdolls = 24
    /// The hair scene: strands drawn around each simulated one (guide), and furry bodies dropped down its ramp.
    package var hair = 12
    package var furBodies = 6
    /// The soft body scene: soft bodies dropped in, and their lattices' cubes along each one's longest side.
    package var softBodies = 16
    package var softCells = 6
    /// The muscles scene (Scene+Muscles.swift): the character, the ragdolls with flesh, the flesh's lattice spacing
    /// (cm), its skin, and how much its muscles contract.
    package var muscleCharacter = true
    package var muscleRagdolls = 3
    package var fleshCell: Float = 3.5
    /// The skin: the drawn surface in the flesh's outer tets (stiffer: its tension), or on a shell of its own that
    /// slides over the flesh (PhysicsSkin.swift; the character's).
    package enum Skin: Int, CaseIterable, Codable {
        case embedded, sliding
        package var title: String { ["Embedded", "Sliding"][rawValue] }
    }
    package var skin = Skin.embedded
    package var muscleGain: Float = 1
    /// What the character is drawn as: its skin, or its muscles (an écorché: MuscleAtlas.swift) on the same flesh.
    package enum Body: Int, CaseIterable, Codable {
        case skin, muscles
        package var title: String { ["Skin", "Muscles"][rawValue] }
    }
    package var body = Body.skin
    /// The fluids scene (Scene+Fluids.swift): which liquids it pours, the solver each is stepped by (PhysicsFluid.swift),
    /// or one for all of them, and how many particles each pours at most. Honey by MPM (its viscosity is what MPM is
    /// for), water and blood by PBF: MPM's push on a body is weak in a thin liquid (a light box bobbed and sank in MPM
    /// water and blood; PBF's boundary density holds it up).
    package enum Liquids: Int, CaseIterable, Codable {
        case all, water, blood, honey
        package var title: String { ["All three", "Water", "Blood", "Honey"][rawValue] }
    }
    package var liquids = Liquids.all
    package enum Solver: Int, CaseIterable, Codable {
        case pbf, mpm
        package var title: String { ["Position based (PBF)", "Material point (MLS-MPM)"][rawValue] }
    }
    package enum Solvers: Int, CaseIterable, Codable {
        case auto, pbf, mpm
        package var title: String { ["Each liquid's own", "PBF for all", "MPM for all"][rawValue] }
    }
    package var solver = Solvers.auto
    package var waterSolver = Solver.pbf
    package var bloodSolver = Solver.pbf
    package var honeySolver = Solver.mpm
    package var fluidParticles = 32768

    package static let substepRange = 1...32
    package static let bodyRange = 0...4096
    package static let particleRange = 0...16384
    package static let clothRange = 0...96
    package static let ragdollRange = 1...256
    package static let hairRange = 1...32
    package static let furBodyRange = 0...32
    package static let softBodyRange = 1...128
    package static let softCellRange = 3...12
    package static let muscleRagdollRange = 0...12
    package static let fleshCellRange: ClosedRange<Float> = 2...6
    package static let muscleGainRange: ClosedRange<Float> = 0...2
    package static let fluidRange = 1024...262144
    package static let gpuFrom = 64

    /// Whether a world of `bodies` bodies and particles is stepped on the GPU. Automatic: the CPU below `gpuFrom`
    /// (where a dispatch costs more than the work), and with fractured objects at any size: the GPU's substeps solve
    /// the contacts a colour after another, each colour waiting for the last (about a thousand a step), and its steps
    /// are the frame's while the CPU's run beside it. On the M1 Max (Benchmark+Destruction.swift's destructioncpu) the
    /// CPU's step took 2.0 ms against the GPU's 4.7 in the courtyard, 13 against 16 for a building settling, and 31
    /// against 30 for three; with the GPU's in the window, a settling building drew at 16 to 23 fps, with the CPU's
    /// at 120.
    package func runsOnGPU(bodies: Int, fractures: Bool = false) -> Bool {
        backend == .gpu || (backend == .auto && bodies >= PhysicsSettings.gpuFrom && !fractures)
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(backend: Backend = Backend.auto, asynchronous: Bool = true, everyCore: Bool = true, substeps: Int = 16, bodies: Int = 96, particles: Int = 2048, cloth: Int = 36, ragdolls: Int = 24, hair: Int = 12, furBodies: Int = 6, softBodies: Int = 16, softCells: Int = 6, muscleCharacter: Bool = true, muscleRagdolls: Int = 3, fleshCell: Float = 3.5, skin: Skin = Skin.embedded, muscleGain: Float = 1, body: Body = Body.skin, liquids: Liquids = Liquids.all, solver: Solvers = Solvers.auto, waterSolver: Solver = Solver.pbf, bloodSolver: Solver = Solver.pbf, honeySolver: Solver = Solver.mpm, fluidParticles: Int = 32768) {
        self.backend = backend
        self.asynchronous = asynchronous
        self.everyCore = everyCore
        self.substeps = substeps
        self.bodies = bodies
        self.particles = particles
        self.cloth = cloth
        self.ragdolls = ragdolls
        self.hair = hair
        self.furBodies = furBodies
        self.softBodies = softBodies
        self.softCells = softCells
        self.muscleCharacter = muscleCharacter
        self.muscleRagdolls = muscleRagdolls
        self.fleshCell = fleshCell
        self.skin = skin
        self.muscleGain = muscleGain
        self.body = body
        self.liquids = liquids
        self.solver = solver
        self.waterSolver = waterSolver
        self.bloodSolver = bloodSolver
        self.honeySolver = honeySolver
        self.fluidParticles = fluidParticles
    }
}
