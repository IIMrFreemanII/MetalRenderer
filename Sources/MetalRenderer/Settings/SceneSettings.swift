import CoreGraphics
import EngineCore
import Foundation
import simd

/// Which buildings the city is made of: every style by district, or one of them everywhere.
package enum CityStyle: Int, CaseIterable, Codable {
    case mixed              // towers in the centre, mid-rise blocks around them, old town and warehouses at the edge
    case oldtown            // narrow plastered houses with pitched roofs and shutters
    case residential        // brick apartment blocks with balconies around courtyards
    case warehouse          // low, wide brick halls with big windows and loading doors
    case office             // glass towers on podiums, with setbacks
    case modern             // concrete and panel mid-rise blocks with ribbon windows

    package var title: String {
        switch self {
        case .mixed: return "Mixed districts"
        case .oldtown: return "Old town"
        case .residential: return "Residential blocks"
        case .warehouse: return "Warehouses"
        case .office: return "Office towers"
        case .modern: return "Modern mid-rise"
        }
    }
}

/// The generated city (the City scenes): changing any of it builds the city again.
/// (Which city is `SceneSettings.seed`'s to say, as for the plants.)
package struct CitySettings: Equatable, Codable {
    /// Blocks along each side of the street grid (1 = a single block).
    package var blocks = 4
    package var style = CityStyle.mixed
    /// At night: the share of windows with a light on behind them.
    package var lit: Float = 0.35
    /// The share of windows with a room behind the glass instead of a blind (at night the lit ones have a lamp).
    package var rooms: Float = 0.15
    /// Generated brick, plaster, concrete, tile and paving textures (ProceduralTextures); off: flat colours.
    package var textures = true
    /// A window's shell (reveal, frame, sill, lintel, shutters) is made once and placed at every window like it
    /// (Building.Module), a building an assembly of them (Scene.Assembly.rigid); off: every building one mesh of its own.
    package var modules = false
    /// The building the camera comes near (within `interiorReach` metres) has its interior made, in the background:
    /// rooms, stairs, furniture, lights you can walk among (Scene+Interiors.swift). Off: every building a shell.
    var interiors = true
    var interiorReach: Float = 30
    /// A canal through the city in place of its middle avenue (with 4 blocks a side or more): quays, bridges where
    /// the streets cross it, water (CityPlan.canal).
    var canal = true

    static let blockRange = 1...10
    static let litRange: ClosedRange<Float> = 0...1
    static let roomRange: ClosedRange<Float> = 0...0.5

    /// (As the memberwise initializer, for the modules above this one.)
    package init(blocks: Int = 4, style: CityStyle = CityStyle.mixed, lit: Float = 0.35, rooms: Float = 0.15, textures: Bool = true, modules: Bool = false, interiors: Bool = true, interiorReach: Float = 30, canal: Bool = true) {
        self.blocks = blocks
        self.style = style
        self.lit = lit
        self.rooms = rooms
        self.textures = textures
        self.modules = modules
        self.interiors = interiors
        self.interiorReach = interiorReach
        self.canal = canal
    }
}

/// A glTF model the user opened or dropped into the scene.
package struct ExtraModel: Equatable, Codable {
    var path: String
    var position: SIMD3<Float>
    var yaw: Float
}

/// A scene's particle effects (Particles.swift; the particles scene's, the showcase's motes). Changing any of it
/// rebuilds the scene, which starts them again.
package struct ParticleSettings: Equatable, Codable {
    /// Every emitter's rate, bursts and pool times this: the effects thinner or denser (timing).
    package var budget: Float = 1
    /// The particles that cast shadows do (shadow rays look through them); off, none does.
    package var shadows = true
    /// Reflection rays see the particles in front of what they reflect (particleGather); off, mirrors miss them.
    package var reflections = true
    static let budgetRange: ClosedRange<Float> = 0.25...4

    /// `emitters` as these settings make them.
    func applied(to emitters: [ParticleEmitter]) -> [ParticleEmitter] {
        emitters.map { e in
            var e = e
            e.capacity = max(Int((Float(e.capacity) * budget).rounded()), 1)
            e.rate *= budget
            if let b = e.burst { e.burst = (b.time, max(Int((Float(b.count) * budget).rounded()), 1), b.period, b.repeats) }
            if !shadows { e.castsShadows = false }
            return e
        }
    }
}

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
    /// The scripted demo (a rocket, TNT, a burst, the walker into a hole: the benchmark's and the tests'); off: only
    /// what the player does.
    package var demo = false

    package static let floorRange = 4...6
    package static let seedRange = 1...999
    package static let sizeRange: ClosedRange<Float> = 12...36
    package static let pieceRange: ClosedRange<Float> = 0.25...2
    package static let toughnessRange: ClosedRange<Float> = 0.1...10
}

/// The physics scene's (Physics.swift). Changing any of it rebuilds the scene, which starts the simulation again.
package struct PhysicsSettings: Equatable, Codable {
    /// Where the steps run: the GPU (Shaders/Physics.metal), the CPU (PhysicsCPU.swift), or whichever suits the
    /// scene (`runsOnGPU`).
    package enum Backend: Int, CaseIterable, Codable {
        case auto, gpu, cpu
        var title: String { ["Automatic", "GPU", "CPU"][rawValue] }
    }
    package var backend = Backend.auto
    /// The CPU's steps on a thread of their own, behind the frame (PhysicsStepper): the frame doesn't wait for them.
    var asynchronous = true
    /// The CPU's steps on every core (PhysicsPool), or on one: the same numbers either way.
    var everyCore = true
    /// Substeps a step (1/60 s): more hold stacks stiffer, for more work (8 lets a tower of 8 crossed layers sink
    /// through the floor; 12 holds it to 3 mm).
    var substeps = 16
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

    static let substepRange = 1...32
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
    static let gpuFrom = 64

    /// Whether a world of `bodies` bodies and particles is stepped on the GPU. Automatic: the CPU below `gpuFrom`
    /// (where a dispatch costs more than the work), and with fractured objects at any size: the GPU's substeps solve
    /// the contacts a colour after another, each colour waiting for the last (about a thousand a step), and its steps
    /// are the frame's while the CPU's run beside it. On the M1 Max (Benchmark+Destruction.swift's destructioncpu) the
    /// CPU's step took 2.0 ms against the GPU's 4.7 in the courtyard, 13 against 16 for a building settling, and 31
    /// against 30 for three; with the GPU's in the window, a settling building drew at 16 to 23 fps, with the CPU's
    /// at 120.
    func runsOnGPU(bodies: Int, fractures: Bool = false) -> Bool {
        backend == .gpu || (backend == .auto && bodies >= PhysicsSettings.gpuFrom && !fractures)
    }
}

/// Scene choice and the stress test's size. Changing it rebuilds the scene (geometry, acceleration structures).
package struct SceneSettings: Equatable, Codable {
    package var kind = SceneKind.cornell
    package var objects = 400
    package var lights = 32
    /// The crowd scene: how many characters, and how many poses the GPU animates for them each frame (Crowd).
    package var characters = 2048
    package var poses = 64
    /// ...and at which level of detail they are skinned and traced: 0 = the full mesh, each level half the one before.
    package var detail = 3
    /// ...and who they are: the character library's (the Y and X Bots) or the character catalog's people, made from
    /// their DNA (CharacterBuilder).
    package var crowdBodies = CrowdBodies.library
    package var city = CitySettings()
    /// The showcase: which model of `Scene.galleryFiles()`, as a part of its file name (any case); "" = the first.
    package var showcase = ""
    package var extraModels: [ExtraModel] = []   // added with File > Open or drag and drop (cleared when the scene changes)
    /// Emissive surfaces are lights: sampled for direct light with shadow rays (and seen by GI through light maps).
    /// Off: they only light what GI rays happen to hit, as before.
    package var emissiveLights: Bool = ProcessInfo.processInfo.environment["METALRENDERER_EMISSIVE_LIGHTS"] != "0"
    /// Benchmarks only (METALRENDERER_BENCH=lightcheck): one light, or its emissive-mesh twin, over a floor instead of `kind`.
    package var lightCheck: String? = nil

    /// The forest: how many trees, and bushes, ferns and grass as a percentage of the usual; the seed of the plants
    /// (and of the forest's ground and where everything stands).
    package var trees = 2500
    package var undergrowth = 100
    package var seed = 1
    /// The open world: the tile the scene is made around (nil: the one the world starts in). The renderer's to set, as
    /// the camera moves; not a preference.
    package var worldTile: SIMD2<Int>? = nil
    /// ...and the tile whose corner is the scene's origin (nil: the first city's). It follows the camera from afar, so
    /// that the scene's coordinates stay small however far the camera has gone.
    package var worldAnchor: SIMD2<Int>? = nil
    /// ...and whether its cities' lights are the scene's lights: the renderer's to set too, with the time of day
    /// (`World.lightsReady`). By day nothing samples them, and they are off.
    package var worldLit = false
    /// Plants baked into meshes of their own instead of assemblies: no wind or leaf fall, and eight times the
    /// triangles (METALRENDERER_BENCH=forestcheck compares the two).
    package var bakedPlants = false
    /// The trees' and bushes' leaves as cards: a few rectangles a bough, each showing a twig with its leaves, cut out
    /// by an alpha mask the ray queries test. Off: every leaf is a mesh of its own.
    package var leafCards = false
    /// The outdoor scenes' realistic look (Realism): scanned materials, height-blended ground, realistic lighting.
    package var realism = Realism.on
    /// Far baked plants as their voxel grids (VoxelLOD) instead of their triangles. Off: it is slower wherever it was
    /// measured. In software (M1 Max) the ray queries a voxel box needs
    /// cost every ray about 30%; in hardware (M4 Max) each box a ray meets hands it back to the shader, and the
    /// forest takes 1.3 to 2.1 times as long, the open world 3 times.
    package var voxelBoxes = false
    /// The physics scene: its bodies and how they are simulated.
    package var physics = PhysicsSettings()
    /// The destruction scene: its objects and how they break.
    package var destruction = DestructionSettings()
    /// The demolition scene: its building and how it breaks.
    package var demolition = DemolitionSettings()
    package var particles = ParticleSettings()
    /// The plant workshop: what it shows.
    package var plants = PlantSceneSettings()
    /// The species the plants are grown from: a key of PlantCatalog's registry, which the plant editor sets as it
    /// edits; "" the saved species (Assets/Plants), "builtin" the built-in ones. Session state, not a preference.
    package var plantCatalog = ""
    /// The effects that replace the scenes' own of the same name (VFXCatalog): "" the saved ones (Assets/Effects),
    /// "builtin" none, otherwise a key of the registry the VFX editor fills as it edits. Session state.
    package var effects = ""
    /// The VFX stage: the effects it shows.
    package var stage = VFXStageSettings()
    /// The material workshop: the graph it shows, on what.
    package var materialWorkshop = MaterialWorkshopSettings()
    /// The material graphs procedural materials are baked from (MaterialCatalog): "" the saved ones (Assets/Materials),
    /// "builtin" the built-in ones, otherwise a key of the registry the Material Designer fills as it edits. An edit
    /// that keeps every graph's channels bakes in place (Renderer.editMaterials). Session state.
    package var materials = ""
    /// Which scene materials graphs replace (MaterialAssignments: click-to-pick's): "" the saved ones
    /// (Assets/Materials/assignments.json), otherwise a key of the registry the Material Designer fills. A change makes
    /// the scene again. Session state.
    package var materialAssignments = ""
    /// The painter workshop: what it shows, painted with which document.
    package var painterWorkshop = PainterWorkshopSettings()
    /// The terrain workshop: how big its terrain is, what it starts from, its document.
    package var terrainWorkshop = TerrainWorkshopSettings()
    /// Changed by the Terrain Editor when an edit of a terrain's document needs the scene made again (a layer's Material
    /// Designer graph, its water): any new value does. Session state.
    package var terrainKey = ""
    /// Which scene objects the Material Painter paints (PaintAssignments): "" the saved ones
    /// (Assets/Painter/assignments.json), otherwise a key of the registry the painter fills. A change makes the scene
    /// again. Session state.
    package var paintAssignments = ""
    /// What the Project Graph hid and duplicated (SceneOverrides): "" the saved ones (Assets/Scenes/Overrides), otherwise
    /// a key of the registry the graph fills. A change makes the scene again. Session state.
    package var sceneOverrides = ""
    /// The building workshop: what it shows.
    package var buildings = BuildingSceneSettings()
    /// The building styles and single buildings scenes are built with: a key of BuildingCatalog's registry, which the
    /// building editor sets as it edits; "" the saved ones (Assets/Buildings), "builtin" the built-in ones. Session state.
    package var buildingCatalog = ""
    /// The character workshop: who it shows, and how.
    package var characterWorkshop = CharacterSceneSettings()
    /// The characters scenes are made with: a key of CharacterCatalog's registry, which the character editor sets as it
    /// edits; "" the saved ones (Assets/CharacterDefs), "builtin" the built-in ones. Session state.
    package var characterCatalog = ""
    /// The city's building whose interior the scene has (LotRef.key; nil: none): the renderer's to set, as the camera
    /// comes near a building and leaves it (Scene+Interiors.swift). Session state.
    package var interior: String? = nil

    package static let objectRange = 0...2000
    package static let treeRange = 0...20000
    package static let undergrowthRange = 0...200
    package static let seedRange = 0...999
    package static let lightRange = 1...16384
    package static let characterRange = 1...131_072
    package static let poseRange = 1...512
    package static let detailRange = 0...CharacterLibrary.coarserLevels

    /// A scene with a light count of its own (the night market's 4096 bulbs) starts with it, unless the count was
    /// changed from the default.
    package mutating func startLights() {
        if let n = kind.definition.lights, lights == SceneSettings().lights { lights = n }
    }

    /// The settings whose values differ from `other`'s, by name ("effects", "city.style"): why a scene is made again.
    package func changes(from other: SceneSettings) -> [String] {
        func object(_ s: SceneSettings) -> [String: Any] {
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            guard let data = try? encoder.encode(s) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        func walk(_ a: [String: Any], _ b: [String: Any], _ path: String) -> [String] {
            Set(a.keys).union(b.keys).sorted().flatMap { k -> [String] in
                let name = path.isEmpty ? k : "\(path).\(k)"
                if let x = a[k] as? [String: Any], let y = b[k] as? [String: Any] { return walk(x, y, name) }
                return (a[k] as? NSObject) == (b[k] as? NSObject) ? [] : [name]
            }
        }
        return walk(object(self), object(other), "")
    }

    /// The plant workshop both, showing the same species the same way (only the species' definitions and which of its
    /// plants differ): what an edit changes.
    package func isSameWorkshop(as other: SceneSettings) -> Bool {
        if kind == .characters && other.kind == .characters {
            let a = characterWorkshop, b = other.characterWorkshop
            return a.layout == b.layout && a.pose == b.pose && a.clip == b.clip && a.view == b.view
        }
        if kind == .buildings && other.kind == .buildings {
            return buildings.layout == other.buildings.layout && buildings.style == other.buildings.style
                && buildings.pinned == other.buildings.pinned
        }
        return kind == .plants && other.kind == .plants && plants.layout == other.plants.layout && plants.view == other.plants.view
            && plants.species == other.plants.species && leafCards == other.leafCards && bakedPlants == other.bakedPlants
            && realism == other.realism
    }

    /// The same city, with another building's interior in it (or none): the same streets and buildings, where they
    /// were (Renderer: what the frames have gathered holds).
    package func isSameCity(as other: SceneSettings) -> Bool {
        var a = self, b = other
        (a.interior, b.interior) = (nil, nil)
        return (kind.isCity || kind.isWorld) && a == b && interior != other.interior
    }

    /// The same open world, whatever tile the scene is made around, wherever its origin is and whatever the time of day.
    package func isSameWorld(as other: SceneSettings) -> Bool {
        var a = self, b = other
        (a.worldTile, b.worldTile, a.worldAnchor, b.worldAnchor) = (nil, nil, nil, nil)
        (a.worldLit, b.worldLit) = (false, false)
        (a.interior, b.interior) = (nil, nil)
        return kind.isWorld && a == b
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(kind: SceneKind = SceneKind.cornell, objects: Int = 400, lights: Int = 32, characters: Int = 2048, poses: Int = 64, detail: Int = 3, crowdBodies: CrowdBodies = CrowdBodies.library, city: CitySettings = CitySettings(), showcase: String = "", extraModels: [ExtraModel] = [], emissiveLights: Bool = ProcessInfo.processInfo.environment["METALRENDERER_EMISSIVE_LIGHTS"] != "0", lightCheck: String? = nil, trees: Int = 2500, undergrowth: Int = 100, seed: Int = 1, worldTile: SIMD2<Int>? = nil, worldAnchor: SIMD2<Int>? = nil, worldLit: Bool = false, bakedPlants: Bool = false, leafCards: Bool = false, realism: Realism = Realism.on, voxelBoxes: Bool = false, physics: PhysicsSettings = PhysicsSettings(), destruction: DestructionSettings = DestructionSettings(), demolition: DemolitionSettings = DemolitionSettings(), particles: ParticleSettings = ParticleSettings(), plants: PlantSceneSettings = PlantSceneSettings(), plantCatalog: String = "", effects: String = "", stage: VFXStageSettings = VFXStageSettings(), materialWorkshop: MaterialWorkshopSettings = MaterialWorkshopSettings(), materials: String = "", materialAssignments: String = "", painterWorkshop: PainterWorkshopSettings = PainterWorkshopSettings(), terrainWorkshop: TerrainWorkshopSettings = TerrainWorkshopSettings(), terrainKey: String = "", paintAssignments: String = "", sceneOverrides: String = "", buildings: BuildingSceneSettings = BuildingSceneSettings(), buildingCatalog: String = "", characterWorkshop: CharacterSceneSettings = CharacterSceneSettings(), characterCatalog: String = "", interior: String? = nil) {
        self.kind = kind
        self.objects = objects
        self.lights = lights
        self.characters = characters
        self.poses = poses
        self.detail = detail
        self.crowdBodies = crowdBodies
        self.city = city
        self.showcase = showcase
        self.extraModels = extraModels
        self.emissiveLights = emissiveLights
        self.lightCheck = lightCheck
        self.trees = trees
        self.undergrowth = undergrowth
        self.seed = seed
        self.worldTile = worldTile
        self.worldAnchor = worldAnchor
        self.worldLit = worldLit
        self.bakedPlants = bakedPlants
        self.leafCards = leafCards
        self.realism = realism
        self.voxelBoxes = voxelBoxes
        self.physics = physics
        self.destruction = destruction
        self.demolition = demolition
        self.particles = particles
        self.plants = plants
        self.plantCatalog = plantCatalog
        self.effects = effects
        self.stage = stage
        self.materialWorkshop = materialWorkshop
        self.materials = materials
        self.materialAssignments = materialAssignments
        self.painterWorkshop = painterWorkshop
        self.terrainWorkshop = terrainWorkshop
        self.terrainKey = terrainKey
        self.paintAssignments = paintAssignments
        self.sceneOverrides = sceneOverrides
        self.buildings = buildings
        self.buildingCatalog = buildingCatalog
        self.characterWorkshop = characterWorkshop
        self.characterCatalog = characterCatalog
        self.interior = interior
    }
}

/// The VFX stage (Scene+Stage.swift): the effects it lines up, by name (VFXLibrary's, or the catalog's: Scene.effect).
package struct VFXStageSettings: Equatable, Codable {
    package var effects = ["fireworks"]
    package var backdrop = VFXBackdrop.dark
}

/// The material workshop (Scene+Materials.swift): the graph whose material it shows (by name: MaterialCatalog's),
/// on which shapes, against what.
package struct MaterialWorkshopSettings: Equatable, Codable {
    package var graph = "Red Bricks"
    package var layout = Layout.lineup
    package var backdrop = Backdrop.studio

    package enum Layout: String, Codable, CaseIterable {
        /// (`card`: a standing card and a tile on the ground, for a cut-out material: a plant, a decal.)
        case lineup, sphere, cube, cylinder, plane, card
        package var title: String { self == .lineup ? "Line-up" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }
    package enum Backdrop: String, Codable, CaseIterable {
        case studio, outdoor, dark
        package var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }
}

/// The painter workshop (Scene+Painter.swift): the object it paints (a shape, the base character, a glTF model's
/// largest part), with which document (PaintDocuments, by name), against what.
package struct PainterWorkshopSettings: Equatable, Codable {
    package var subject = Subject.sphere
    /// `.model`: the glTF file (a path, or a name under Assets).
    package var model = ""
    package var document = "Workshop"
    package var backdrop = MaterialWorkshopSettings.Backdrop.studio

    package enum Subject: String, Codable, CaseIterable {
        case sphere, cube, cylinder, plane, character, model
        package var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }
}

/// What the VFX stage's effects are shown against.
package enum VFXBackdrop: String, Codable, CaseIterable {
    /// A dark room, a key light and a cool one over it; a grey cyclorama (a floor curving up into a wall), softly lit;
    /// nothing at all, black; a plain under the sun and a blue sky; the plain at night, under the moon.
    case dark, grey, black, outdoor, night
    package var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// The building workshop (Scene+Buildings.swift): which building it shows, and how.
package struct BuildingSceneSettings: Equatable, Codable {
    /// The style's id (BuildingCatalog), the lot (its width across the front, its depth), what its sides look onto,
    /// its floors and seed.
    package var style = "residential"
    package var lot = SIMD2<Float>(20, 14)
    package var sides = Sides.row
    package var floors = 5
    package var seed = 1
    package var layout = Layout.single
    package var view = View.full
    /// The cutaway's and the dollhouse's top storey (0: the ground floor).
    package var cut = 1
    package var night = false
    /// A single building of a city to show instead (the editor's Pin), nil: the workshop's own.
    package var pinned: LotRef? = nil
    /// Registry keys (BuildingCatalog.register), session state: the editor's variations of the style to show beside it
    /// (layout `mutate`), and the definitions to show in its place (comparing with the saved ones). "" = none.
    package var mutants = ""
    package var compare = ""

    package enum Sides: Int, CaseIterable, Codable {
        case row            // between neighbours, a yard behind
        case backToBack     // between neighbours, a neighbour behind too
        case corner         // a street in front and on its right
        case free           // streets and open ground all round
        package var edges: [CityPlan.Edge] {
            switch self {
            case .row: return [.street, .party, .open, .party]
            case .backToBack: return [.street, .party, .party, .party]
            case .corner: return [.street, .street, .party, .party]
            case .free: return [.street, .open, .open, .street]
            }
        }
        package var title: String { ["In a row", "Back to back", "On a corner", "Free-standing"][rawValue] }
    }
    package enum Layout: Int, CaseIterable, Codable {
        case single         // the building on its lot
        case street         // between two neighbours of its style
        case mutate         // it and the editor's variations of it, along a street
        package var title: String { ["One building", "In its street", "Variations"][rawValue] }
    }
    package enum View: Int, CaseIterable, Codable {
        case full
        case cutaway        // no roof and nothing above storey `cut`
        case dollhouse      // ...and no front wall up to it either
        package var title: String { ["Whole", "Cutaway", "Dollhouse"][rawValue] }
    }

    package static let floorRange = 1...40
    package static let widthRange: ClosedRange<Float> = 6...48
    package static let depthRange: ClosedRange<Float> = 8...48

    /// (As the memberwise initializer, for the modules above this one.)
    package init(style: String = "residential", lot: SIMD2<Float> = SIMD2<Float>(20, 14), sides: Sides = Sides.row, floors: Int = 5, seed: Int = 1, layout: Layout = Layout.single, view: View = View.full, cut: Int = 1, night: Bool = false, pinned: LotRef? = nil, mutants: String = "", compare: String = "") {
        self.style = style
        self.lot = lot
        self.sides = sides
        self.floors = floors
        self.seed = seed
        self.layout = layout
        self.view = view
        self.cut = cut
        self.night = night
        self.pinned = pinned
        self.mutants = mutants
        self.compare = compare
    }
}

/// Who the crowd scene's characters are.
package enum CrowdBodies: Int, CaseIterable, Codable {
    case library        // Assets/Characters: the Mixamo mannequins
    case generated      // the character catalog's people (CharacterCatalog, CharacterBuilder)
    package var title: String { ["Mannequins", "Generated people"][rawValue] }
}

/// The character workshop (Scene+Characters.swift): who it shows, in what pose, and how.
package struct CharacterSceneSettings: Equatable, Codable {
    /// The character's id (CharacterCatalog).
    package var character = "man"
    package var layout = Layout.single
    package var pose = Pose.aPose
    /// Pose `clip`: the clip's name (any clip of the character library).
    package var clip = ""
    package var view = View.body
    /// What the faces do (blinks always), and whether their eyes follow the camera.
    package var expression = FaceExpression.neutral
    package var lookAt = true
    /// How hair is drawn (CharacterHair): strands, the caps crowds have, or none.
    package var hair = HairMode.strands
    /// Registry keys (CharacterCatalog.register), session state: the editor's variations of the character to show
    /// beside it (layout `mutate`), and the definitions to show in its place (comparing with the saved ones). "" = none.
    package var mutants = ""
    package var compare = ""

    package enum Layout: Int, CaseIterable, Codable {
        case single         // the character
        case lineup         // every character of the catalog, side by side
        case mutate         // the character and the editor's variations of it, in a row
        package var title: String { ["One character", "Everyone", "Variations"][rawValue] }
    }
    package enum Pose: Int, CaseIterable, Codable {
        case tPose, aPose, idle, walk, clip
        package var title: String { ["T pose", "A pose", "Idle", "Walking", "Clip"][rawValue] }
        /// The clip it plays (CharacterKit's names), for every pose but `clip`.
        package var clipName: String? { [Optional("T-Pose"), "A-Pose", "Idle", "Walking", nil][rawValue] }
    }
    package enum View: Int, CaseIterable, Codable {
        case body           // the whole character
        case face           // its head, close
        package var title: String { ["Body", "Face"][rawValue] }
    }
    package enum HairMode: Int, CaseIterable, Codable {
        case strands, caps, none
        package var title: String { ["Strands", "Caps", "None"][rawValue] }
    }
}

/// The plant workshop (Scene+Plants.swift): which plants it shows, and how.
package struct PlantSceneSettings: Equatable, Codable {
    /// The species' id (PlantCatalog), and the age and seeded variant of the one plant shown.
    package var species = "oak"
    package var age = Foliage.Age.mature
    package var variant = 0
    /// What the variants are grown from: the library's seed (SceneSettings.seed), so the workshop's oak 2 at seed 1 is
    /// the forest's.
    package var seed = 1
    package var layout = Layout.single
    package var view = View.plant
    /// Registry keys (PlantCatalog.register), session state: the editor's variations of the species to show beside it
    /// (layout `mutate`), and the definition to show in its place (comparing with the saved one). "" = none.
    package var mutants = ""
    package var compare = ""

    package enum Layout: Int, CaseIterable, Codable {
        case single         // the one plant
        case lineup         // every age (rows) and variant (columns)
        case mutate         // the plant and the editor's variations of it, in a row

        package var title: String { ["One plant", "Ages and variants", "Variations"][rawValue] }
    }
    package enum View: Int, CaseIterable, Codable {
        case plant
        case skeleton       // the stems as thin lines, a colour to a level; no leaves

        package var title: String { ["Plant", "Skeleton"][rawValue] }
    }

    package static let variantRange = 0...7
}

extension SceneKind {
    /// The camera turns about what the scene shows (the plant workshop's plants, the VFX stage's effects; F frames them).
    package var orbits: Bool { isWorkshop || self == .vfxStage || self == .materials || self == .painter }
}
