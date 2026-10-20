import CoreGraphics
import Foundation
import simd

/// Which scene is loaded.
enum SceneKind: Int, CaseIterable, Codable {
    case cornell            // small Cornell-style room: 5 objects (2 moving), 3 moving lights
    case stress             // stress test: a warehouse, factory, garage and office with `objects` props and `lights` lights
    case gallery            // the glTF models in Assets/ on plinths, 8 moving lights
    case spots              // a stage under six sweeping spot lights
    case sun                // a courtyard and a covered room under the sun, with a day cycle
    case area               // a studio with softboxes and light panels (rect area lights) over glossy objects
    case tubes              // a garage with fluorescent and neon tube lights
    case emissive           // a dark room lit only by emissive meshes (neon shapes, a screen, a spinning ring)
    case mixed              // a room at dusk with every light type
    case fog                // a misty hall: sun shafts through tall windows, a searchlight, ground mist
    case valley             // an open valley under the sky: a day cycle, drifting clouds and their shadows
    case market             // a night market: thousands of festoon bulbs (`lights`), lanterns, lit windows, neon signs
    case forest             // generated trees, bushes, ferns and grass (`trees`, `seed`) on rolling ground, a day cycle
    case crowd              // a square under the sun with `characters` animated characters on `poses` pose slots
    case city               // a generated city (`CitySettings`) under the sun: blocks of procedural buildings, a day cycle
    case cityNight          // the same city at night: lit windows and rooms, street lamps, the moon
    case world              // the open world (World.swift): hills, forest and cities without end, made around the camera;
                            // its day goes through dusk into a night of lit windows, street lamps and the moon
    case showcase           // one model of Assets/ (`SceneSettings.showcase`) staged on a set of its own (ShowcaseLook):
                            // volumetric beams, mist, accent lights, particles, with bloom and depth of field
    case shapes             // SDF shapes (SDFShapes.swift): primitives, cuts and blends, a baked mesh, glowing shapes as lights
    case physics            // rigid SDF shapes (Physics.swift) poured into an arena: a ramp, a pile, a tower knocked over
    case ragdolls           // `ragdolls` ragdolls (jointed bodies, Physics.swift) dropped down a staircase
    case hair               // hair and fur (PhysicsHair.swift): furry bodies rolling down a ramp, a long-haired head
                            // swinging, in a breeze; strands drawn as curves (Metal's ray tracer)
    case softBodies         // `softBodies` soft bodies (PhysicsSoft.swift): jellies dropped onto steps, pegs and a bowl
    case muscles            // flesh, muscles and skin (PhysicsFlesh.swift) on a character walking and running round a
                            // circle among balls, and on ragdolls tumbling down steps
    case fluids             // liquids (PhysicsFluid.swift): water, blood and honey poured side by side down steps into a
                            // tray, boxes floating and sinking in them, a paddle in each to stir it
    case particles          // GPU particle effects (Particles.swift), ray traced: fire and smoke, sparks that bounce and
                            // smoke, magic motes in curl noise, rain that splashes
    case plants             // the plant workshop (Scene+Plants.swift): one species' plants on a lawn under the sun, as the
                            // plant editor shapes them (`SceneSettings.plants`)
    case buildings          // the building workshop (Scene+Buildings.swift): one building, inside and out, on its lot, as
                            // the building editor shapes it (`SceneSettings.buildings`)
    case characters         // the character workshop (Scene+Characters.swift): generated people (CharacterDNA) in a studio,
                            // as the character editor shapes them (`SceneSettings.characterWorkshop`)
    case vfxStage           // the VFX stage (Scene+Stage.swift): effects (`SceneSettings.stage`) lined up in a studio, as
                            // the VFX editor shapes them
    case materials          // the material workshop (Scene+Materials.swift): a Material Designer graph's material on a
                            // sphere, a cube, a cylinder and a tile (`SceneSettings.materialWorkshop`), baked as it is edited
    case mireland           // a misty swamp (Scene+Mireland.swift) made of the Mireland materials, every one procedural
    case painter            // the painter workshop (Scene+Painter.swift): one object on a plinth, painted with the Material
                            // Painter (`SceneSettings.painterWorkshop`)
    case terrain            // the terrain workshop (Scene+TerrainWorkshop.swift): a terrain of its own, 0.5 to 4 km, made with
                            // the Terrain Editor (`SceneSettings.terrainWorkshop`)
    case destruction        // destruction (Scene+Destruction.swift, Physics+Fracture.swift): a courtyard of fractured walls,
                            // pillars, a tower, glass panes, beams and statues broken by a wrecking ball, a weight and
                            // shots (`SceneSettings.destruction`)
    case demolition         // demolition (Scene+Demolition.swift): a generated office, every wall, slab, column, stair and
                            // desk of it fractured, to fly round or walk through and wreck with a machine gun, rockets
                            // and TNT (`SceneSettings.demolition`); drawn in the solid look

    var title: String {
        switch self {
        case .cornell: return "Cornell room"
        case .stress: return "Stress test"
        case .gallery: return "Gallery (Assets)"
        case .spots: return "Spot lights"
        case .sun: return "Sun and sky"
        case .area: return "Area lights"
        case .tubes: return "Tube lights"
        case .emissive: return "Emissive meshes"
        case .mixed: return "Mixed lights"
        case .fog: return "Misty hall"
        case .valley: return "Open valley"
        case .market: return "Night market"
        case .forest: return "Forest"
        case .crowd: return "Crowd"
        case .city: return "City"
        case .cityNight: return "City at night"
        case .world: return "Open world"
        case .showcase: return "Showcase (one model)"
        case .shapes: return "SDF shapes"
        case .physics: return "Physics"
        case .ragdolls: return "Ragdolls"
        case .hair: return "Hair and fur"
        case .softBodies: return "Soft bodies"
        case .muscles: return "Muscles and skin"
        case .fluids: return "Fluids"
        case .particles: return "Particles"
        case .plants: return "Plant workshop"
        case .buildings: return "Building workshop"
        case .characters: return "Character workshop"
        case .vfxStage: return "VFX stage"
        case .materials: return "Material workshop"
        case .mireland: return "Mireland swamp"
        case .painter: return "Painter workshop"
        case .terrain: return "Terrain workshop"
        case .destruction: return "Destruction"
        case .demolition: return "Demolition"
        }
    }

    /// The scenes the physics steps (Physics.swift): they share its settings and look (RenderSettings.usePhysicsLook).
    var simulates: Bool {
        self == .physics || self == .ragdolls || self == .hair || self == .softBodies || self == .muscles || self == .fluids
            || self == .destruction || self == .demolition
    }
    /// ...and those of them drawn with its plain look: destruction has its full look (its glass needs reflections).
    var usesPhysicsLook: Bool { simulates && self != .destruction && self != .demolition }
    /// Scenes built with `SceneSettings.lights` lights (the panel's Lights slider).
    var hasLightCount: Bool { self == .stress || self == .market }
    /// Length of the sun's day cycle in seconds (Scene+Lights: the sun scene's `day`, the valley's two `half`s; the
    /// open world's whole day, with its night), or nil.
    var dayCycle: Float? {
        self == .sun ? 60 : self == .valley || self == .forest || self == .city || self == .terrain ? 180 : self == .world ? Heavens.day : nil
    }
    /// The generated city, by day or by night (Scene+City.swift): the scenes `SceneSettings.city` describes.
    var isCity: Bool { self == .city || self == .cityNight }
    /// The scene's default camera depends on how it was built (its size), so it is asked of the scene itself.
    /// The open world (Scene+World.swift).
    var isWorld: Bool { self == .world }
    /// Scenes with a share of their windows lit at night (`CitySettings.lit`).
    var hasLitWindows: Bool { self == .cityNight || self == .world }
    var cameraFromScene: Bool { self == .crowd || isCity || isWorld || self == .showcase || isWorkshop || self == .mireland || self == .terrain }   // these frame what they hold
    /// The editors' scenes: one thing (a plant, a building) made again at every edit, an orbit camera round it.
    var isWorkshop: Bool { self == .plants || self == .buildings || self == .characters }
    /// Scenes with generated plants (Foliage): `SceneSettings.seed` picks them.
    var hasPlants: Bool { self == .forest || self == .valley || isWorld || self == .plants }
    /// Scenes whose amount of plants is `SceneSettings.trees` and `undergrowth`.
    var hasForest: Bool { self == .forest || isWorld }
    /// Scenes the realistic look changes (SceneSettings.realism): the ones on a terrain, outdoors.
    var hasRealisticLook: Bool { hasPlants || self == .terrain || self == .sun || self == .crowd || self == .buildings }
}

/// Which buildings the city is made of: every style by district, or one of them everywhere.
enum CityStyle: Int, CaseIterable, Codable {
    case mixed              // towers in the centre, mid-rise blocks around them, old town and warehouses at the edge
    case oldtown            // narrow plastered houses with pitched roofs and shutters
    case residential        // brick apartment blocks with balconies around courtyards
    case warehouse          // low, wide brick halls with big windows and loading doors
    case office             // glass towers on podiums, with setbacks
    case modern             // concrete and panel mid-rise blocks with ribbon windows

    var title: String {
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
struct CitySettings: Equatable, Codable {
    /// Blocks along each side of the street grid (1 = a single block).
    var blocks = 4
    var style = CityStyle.mixed
    /// At night: the share of windows with a light on behind them.
    var lit: Float = 0.35
    /// The share of windows with a room behind the glass instead of a blind (at night the lit ones have a lamp).
    var rooms: Float = 0.15
    /// Generated brick, plaster, concrete, tile and paving textures (ProceduralTextures); off: flat colours.
    var textures = true
    /// A window's shell (reveal, frame, sill, lintel, shutters) is made once and placed at every window like it
    /// (Building.Module), a building an assembly of them (Scene.Assembly.rigid); off: every building one mesh of its own.
    var modules = false
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
}

/// A glTF model the user opened or dropped into the scene.
struct ExtraModel: Equatable, Codable {
    var path: String
    var position: SIMD3<Float>
    var yaw: Float
}

/// A scene's particle effects (Particles.swift; the particles scene's, the showcase's motes). Changing any of it
/// rebuilds the scene, which starts them again.
struct ParticleSettings: Equatable, Codable {
    /// Every emitter's rate, bursts and pool times this: the effects thinner or denser (timing).
    var budget: Float = 1
    /// The particles that cast shadows do (shadow rays look through them); off, none does.
    var shadows = true
    /// Reflection rays see the particles in front of what they reflect (particleGather); off, mirrors miss them.
    var reflections = true
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
struct FracturePreview: Equatable, Codable {
    var object: String
    /// The level shown (1: the object's pieces), and how far apart they are (a share of their distance from its middle).
    var level = 1
    var explode: Float = 0.4
}

/// The destruction scene's (Scene+Destruction.swift). Changing any of it builds the scene again.
struct DestructionSettings: Equatable, Codable {
    /// Scales every object's pieces (the first level's count, the next ones' by its square root).
    var pieces: Float = 1
    /// Scale what breaks a piece into its children and frees it (toughness), and what a weld holds (strength).
    var toughness: Float = 1
    var strength: Float = 1
    /// Dust and debris where pieces part (the scene's particles), and small pieces fading away once still.
    var dust = true
    var fade = true
    /// The scripted wrecking ball, weight and cannonballs (off: only what the tools do).
    var demo = true
    /// The courtyard's objects only, or a whole building of pieces too (4,000 and more: offline).
    var massive = false
    /// With `massive`: how many of its buildings stand side by side in the lot (3: over 10,000 bodies).
    var buildings = 1
    static let buildingRange = 1...3
    /// The statues: the meshes cut piece by piece (textures kept), or none.
    var statues = true
    /// The Fracture Editor's edits, by object name, over the saved recipes (FractureStore) and the defaults (session
    /// state); and its preview: one object's pieces at a level, held apart (nothing moves, no demo).
    var recipes: [String: FractureRecipe] = [:]
    var preview: FracturePreview?

    static let pieceRange: ClosedRange<Float> = 0.25...4
    static let toughnessRange: ClosedRange<Float> = 0.1...10
}

/// The demolition scene's (Scene+Demolition.swift). Changing any of it builds the scene again.
struct DemolitionSettings: Equatable, Codable {
    /// The office: its storeys, its seed (another plan, other rooms), its lot (m, x and z).
    var floors = 5
    var seed = 7
    var width: Float = 24
    var depth: Float = 16
    /// Scales every object's pieces (as DestructionSettings.pieces), what breaks them and what their welds hold.
    var pieces: Float = 1
    var toughness: Float = 1
    var strength: Float = 1
    /// The rooms' furniture, fractured too; the windows' glass.
    var furniture = true
    var glass = true
    /// Dust and debris where pieces part, and small pieces fading away once still.
    var dust = true
    var fade = true
    /// The scripted demo (a rocket, TNT, a burst, the walker into a hole: the benchmark's and the tests'); off: only
    /// what the player does.
    var demo = false

    static let floorRange = 4...6
    static let seedRange = 1...999
    static let sizeRange: ClosedRange<Float> = 12...36
    static let pieceRange: ClosedRange<Float> = 0.25...2
    static let toughnessRange: ClosedRange<Float> = 0.1...10
}

/// The physics scene's (Physics.swift). Changing any of it rebuilds the scene, which starts the simulation again.
struct PhysicsSettings: Equatable, Codable {
    /// Where the steps run: the GPU (Shaders/Physics.metal), the CPU (PhysicsCPU.swift), or whichever suits the
    /// scene (`runsOnGPU`).
    enum Backend: Int, CaseIterable, Codable {
        case auto, gpu, cpu
        var title: String { ["Automatic", "GPU", "CPU"][rawValue] }
    }
    var backend = Backend.auto
    /// The CPU's steps on a thread of their own, behind the frame (PhysicsStepper): the frame doesn't wait for them.
    var asynchronous = true
    /// The CPU's steps on every core (PhysicsPool), or on one: the same numbers either way.
    var everyCore = true
    /// Substeps a step (1/60 s): more hold stacks stiffer, for more work (8 lets a tower of 8 crossed layers sink
    /// through the floor; 12 holds it to 3 mm).
    var substeps = 16
    /// Rigid bodies poured in, and particles poured into a bin.
    var bodies = 96
    var particles = 2048
    /// The cloth's vertices along a side (0: no cloth).
    var cloth = 36
    /// Ragdolls dropped down the ragdoll scene's stairs (11 bodies each).
    var ragdolls = 24
    /// The hair scene: strands drawn around each simulated one (guide), and furry bodies dropped down its ramp.
    var hair = 12
    var furBodies = 6
    /// The soft body scene: soft bodies dropped in, and their lattices' cubes along each one's longest side.
    var softBodies = 16
    var softCells = 6
    /// The muscles scene (Scene+Muscles.swift): the character, the ragdolls with flesh, the flesh's lattice spacing
    /// (cm), its skin, and how much its muscles contract.
    var muscleCharacter = true
    var muscleRagdolls = 3
    var fleshCell: Float = 3.5
    /// The skin: the drawn surface in the flesh's outer tets (stiffer: its tension), or on a shell of its own that
    /// slides over the flesh (PhysicsSkin.swift; the character's).
    enum Skin: Int, CaseIterable, Codable {
        case embedded, sliding
        var title: String { ["Embedded", "Sliding"][rawValue] }
    }
    var skin = Skin.embedded
    var muscleGain: Float = 1
    /// What the character is drawn as: its skin, or its muscles (an écorché: MuscleAtlas.swift) on the same flesh.
    enum Body: Int, CaseIterable, Codable {
        case skin, muscles
        var title: String { ["Skin", "Muscles"][rawValue] }
    }
    var body = Body.skin
    /// The fluids scene (Scene+Fluids.swift): which liquids it pours, the solver each is stepped by (PhysicsFluid.swift),
    /// or one for all of them, and how many particles each pours at most. Honey by MPM (its viscosity is what MPM is
    /// for), water and blood by PBF: MPM's push on a body is weak in a thin liquid (a light box bobbed and sank in MPM
    /// water and blood; PBF's boundary density holds it up).
    enum Liquids: Int, CaseIterable, Codable {
        case all, water, blood, honey
        var title: String { ["All three", "Water", "Blood", "Honey"][rawValue] }
    }
    var liquids = Liquids.all
    enum Solver: Int, CaseIterable, Codable {
        case pbf, mpm
        var title: String { ["Position based (PBF)", "Material point (MLS-MPM)"][rawValue] }
    }
    enum Solvers: Int, CaseIterable, Codable {
        case auto, pbf, mpm
        var title: String { ["Each liquid's own", "PBF for all", "MPM for all"][rawValue] }
    }
    var solver = Solvers.auto
    var waterSolver = Solver.pbf
    var bloodSolver = Solver.pbf
    var honeySolver = Solver.mpm
    var fluidParticles = 32768

    static let substepRange = 1...32
    static let bodyRange = 0...4096
    static let particleRange = 0...16384
    static let clothRange = 0...96
    static let ragdollRange = 1...256
    static let hairRange = 1...32
    static let furBodyRange = 0...32
    static let softBodyRange = 1...128
    static let softCellRange = 3...12
    static let muscleRagdollRange = 0...12
    static let fleshCellRange: ClosedRange<Float> = 2...6
    static let muscleGainRange: ClosedRange<Float> = 0...2
    static let fluidRange = 1024...262144
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
struct SceneSettings: Equatable, Codable {
    var kind = SceneKind.cornell
    var objects = 400
    var lights = 32
    /// The crowd scene: how many characters, and how many poses the GPU animates for them each frame (Crowd).
    var characters = 2048
    var poses = 64
    /// ...and at which level of detail they are skinned and traced: 0 = the full mesh, each level half the one before.
    var detail = 3
    /// ...and who they are: the character library's (the Y and X Bots) or the character catalog's people, made from
    /// their DNA (CharacterBuilder).
    var crowdBodies = CrowdBodies.library
    var city = CitySettings()
    /// The showcase: which model of `Scene.galleryFiles()`, as a part of its file name (any case); "" = the first.
    var showcase = ""
    var extraModels: [ExtraModel] = []   // added with File > Open or drag and drop (cleared when the scene changes)
    /// Emissive surfaces are lights: sampled for direct light with shadow rays (and seen by GI through light maps).
    /// Off: they only light what GI rays happen to hit, as before.
    var emissiveLights = ProcessInfo.processInfo.environment["METALRENDERER_EMISSIVE_LIGHTS"] != "0"
    /// Benchmarks only (METALRENDERER_BENCH=lightcheck): one light, or its emissive-mesh twin, over a floor instead of `kind`.
    var lightCheck: String? = nil

    /// The forest: how many trees, and bushes, ferns and grass as a percentage of the usual; the seed of the plants
    /// (and of the forest's ground and where everything stands).
    var trees = 2500
    var undergrowth = 100
    var seed = 1
    /// The open world: the tile the scene is made around (nil: the one the world starts in). The renderer's to set, as
    /// the camera moves; not a preference.
    var worldTile: SIMD2<Int>? = nil
    /// ...and the tile whose corner is the scene's origin (nil: the first city's). It follows the camera from afar, so
    /// that the scene's coordinates stay small however far the camera has gone.
    var worldAnchor: SIMD2<Int>? = nil
    /// ...and whether its cities' lights are the scene's lights: the renderer's to set too, with the time of day
    /// (`World.lightsReady`). By day nothing samples them, and they are off.
    var worldLit = false
    /// Plants baked into meshes of their own instead of assemblies: no wind or leaf fall, and eight times the
    /// triangles (METALRENDERER_BENCH=forestcheck compares the two).
    var bakedPlants = false
    /// The trees' and bushes' leaves as cards: a few rectangles a bough, each showing a twig with its leaves, cut out
    /// by an alpha mask the ray queries test. Off: every leaf is a mesh of its own.
    var leafCards = false
    /// The outdoor scenes' realistic look (Realism): scanned materials, height-blended ground, realistic lighting.
    var realism = Realism.on
    /// Far baked plants as their voxel grids (VoxelLOD) instead of their triangles. Off: it is slower wherever it was
    /// measured. In software (M1 Max) the ray queries a voxel box needs
    /// cost every ray about 30%; in hardware (M4 Max) each box a ray meets hands it back to the shader, and the
    /// forest takes 1.3 to 2.1 times as long, the open world 3 times.
    var voxelBoxes = false
    /// The physics scene: its bodies and how they are simulated.
    var physics = PhysicsSettings()
    /// The destruction scene: its objects and how they break.
    var destruction = DestructionSettings()
    /// The demolition scene: its building and how it breaks.
    var demolition = DemolitionSettings()
    var particles = ParticleSettings()
    /// The plant workshop: what it shows.
    var plants = PlantSceneSettings()
    /// The species the plants are grown from: a key of PlantCatalog's registry, which the plant editor sets as it
    /// edits; "" the saved species (Assets/Plants), "builtin" the built-in ones. Session state, not a preference.
    var plantCatalog = ""
    /// The effects that replace the scenes' own of the same name (VFXCatalog): "" the saved ones (Assets/Effects),
    /// "builtin" none, otherwise a key of the registry the VFX editor fills as it edits. Session state.
    var effects = ""
    /// The VFX stage: the effects it shows.
    var stage = VFXStageSettings()
    /// The material workshop: the graph it shows, on what.
    var materialWorkshop = MaterialWorkshopSettings()
    /// The material graphs procedural materials are baked from (MaterialCatalog): "" the saved ones (Assets/Materials),
    /// "builtin" the built-in ones, otherwise a key of the registry the Material Designer fills as it edits. An edit
    /// that keeps every graph's channels bakes in place (Renderer.editMaterials). Session state.
    var materials = ""
    /// Which scene materials graphs replace (MaterialAssignments: click-to-pick's): "" the saved ones
    /// (Assets/Materials/assignments.json), otherwise a key of the registry the Material Designer fills. A change makes
    /// the scene again. Session state.
    var materialAssignments = ""
    /// The painter workshop: what it shows, painted with which document.
    var painterWorkshop = PainterWorkshopSettings()
    /// The terrain workshop: how big its terrain is, what it starts from, its document.
    var terrainWorkshop = TerrainWorkshopSettings()
    /// Changed by the Terrain Editor when an edit of a terrain's document needs the scene made again (a layer's Material
    /// Designer graph, its water): any new value does. Session state.
    var terrainKey = ""
    /// Which scene objects the Material Painter paints (PaintAssignments): "" the saved ones
    /// (Assets/Painter/assignments.json), otherwise a key of the registry the painter fills. A change makes the scene
    /// again. Session state.
    var paintAssignments = ""
    /// What the Project Graph hid and duplicated (SceneOverrides): "" the saved ones (Assets/Scenes/Overrides), otherwise
    /// a key of the registry the graph fills. A change makes the scene again. Session state.
    var sceneOverrides = ""
    /// The building workshop: what it shows.
    var buildings = BuildingSceneSettings()
    /// The building styles and single buildings scenes are built with: a key of BuildingCatalog's registry, which the
    /// building editor sets as it edits; "" the saved ones (Assets/Buildings), "builtin" the built-in ones. Session state.
    var buildingCatalog = ""
    /// The character workshop: who it shows, and how.
    var characterWorkshop = CharacterSceneSettings()
    /// The characters scenes are made with: a key of CharacterCatalog's registry, which the character editor sets as it
    /// edits; "" the saved ones (Assets/CharacterDefs), "builtin" the built-in ones. Session state.
    var characterCatalog = ""
    /// The city's building whose interior the scene has (LotRef.key; nil: none): the renderer's to set, as the camera
    /// comes near a building and leaves it (Scene+Interiors.swift). Session state.
    var interior: String? = nil

    static let objectRange = 0...2000
    static let treeRange = 0...20000
    static let undergrowthRange = 0...200
    static let seedRange = 0...999
    static let lightRange = 1...16384
    static let characterRange = 1...131_072
    static let poseRange = 1...512
    static let detailRange = 0...CharacterLibrary.coarserLevels
    static let marketLights = 4096       // the night market's default bulb count

    /// The settings whose values differ from `other`'s, by name ("effects", "city.style"): why a scene is made again.
    func changes(from other: SceneSettings) -> [String] {
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
    func isSameWorkshop(as other: SceneSettings) -> Bool {
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
    func isSameCity(as other: SceneSettings) -> Bool {
        var a = self, b = other
        (a.interior, b.interior) = (nil, nil)
        return (kind.isCity || kind.isWorld) && a == b && interior != other.interior
    }

    /// The same open world, whatever tile the scene is made around, wherever its origin is and whatever the time of day.
    func isSameWorld(as other: SceneSettings) -> Bool {
        var a = self, b = other
        (a.worldTile, b.worldTile, a.worldAnchor, b.worldAnchor) = (nil, nil, nil, nil)
        (a.worldLit, b.worldLit) = (false, false)
        (a.interior, b.interior) = (nil, nil)
        return kind.isWorld && a == b
    }
}

/// The VFX stage (Scene+Stage.swift): the effects it lines up, by name (VFXLibrary's, or the catalog's: Scene.effect).
struct VFXStageSettings: Equatable, Codable {
    var effects = ["fireworks"]
    var backdrop = VFXBackdrop.dark
}

/// The material workshop (Scene+Materials.swift): the graph whose material it shows (by name: MaterialCatalog's),
/// on which shapes, against what.
struct MaterialWorkshopSettings: Equatable, Codable {
    var graph = "Red Bricks"
    var layout = Layout.lineup
    var backdrop = Backdrop.studio

    enum Layout: String, Codable, CaseIterable {
        /// (`card`: a standing card and a tile on the ground, for a cut-out material: a plant, a decal.)
        case lineup, sphere, cube, cylinder, plane, card
        var title: String { self == .lineup ? "Line-up" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }
    enum Backdrop: String, Codable, CaseIterable {
        case studio, outdoor, dark
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }
}

/// The painter workshop (Scene+Painter.swift): the object it paints (a shape, the base character, a glTF model's
/// largest part), with which document (PaintDocuments, by name), against what.
struct PainterWorkshopSettings: Equatable, Codable {
    var subject = Subject.sphere
    /// `.model`: the glTF file (a path, or a name under Assets).
    var model = ""
    var document = "Workshop"
    var backdrop = MaterialWorkshopSettings.Backdrop.studio

    enum Subject: String, Codable, CaseIterable {
        case sphere, cube, cylinder, plane, character, model
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }
}

/// What the VFX stage's effects are shown against.
enum VFXBackdrop: String, Codable, CaseIterable {
    /// A dark room, a key light and a cool one over it; a grey cyclorama (a floor curving up into a wall), softly lit;
    /// nothing at all, black; a plain under the sun and a blue sky; the plain at night, under the moon.
    case dark, grey, black, outdoor, night
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// The building workshop (Scene+Buildings.swift): which building it shows, and how.
struct BuildingSceneSettings: Equatable, Codable {
    /// The style's id (BuildingCatalog), the lot (its width across the front, its depth), what its sides look onto,
    /// its floors and seed.
    var style = "residential"
    var lot = SIMD2<Float>(20, 14)
    var sides = Sides.row
    var floors = 5
    var seed = 1
    var layout = Layout.single
    var view = View.full
    /// The cutaway's and the dollhouse's top storey (0: the ground floor).
    var cut = 1
    var night = false
    /// A single building of a city to show instead (the editor's Pin), nil: the workshop's own.
    var pinned: LotRef? = nil
    /// Registry keys (BuildingCatalog.register), session state: the editor's variations of the style to show beside it
    /// (layout `mutate`), and the definitions to show in its place (comparing with the saved ones). "" = none.
    var mutants = ""
    var compare = ""

    enum Sides: Int, CaseIterable, Codable {
        case row            // between neighbours, a yard behind
        case backToBack     // between neighbours, a neighbour behind too
        case corner         // a street in front and on its right
        case free           // streets and open ground all round
        var edges: [CityPlan.Edge] {
            switch self {
            case .row: return [.street, .party, .open, .party]
            case .backToBack: return [.street, .party, .party, .party]
            case .corner: return [.street, .street, .party, .party]
            case .free: return [.street, .open, .open, .street]
            }
        }
        var title: String { ["In a row", "Back to back", "On a corner", "Free-standing"][rawValue] }
    }
    enum Layout: Int, CaseIterable, Codable {
        case single         // the building on its lot
        case street         // between two neighbours of its style
        case mutate         // it and the editor's variations of it, along a street
        var title: String { ["One building", "In its street", "Variations"][rawValue] }
    }
    enum View: Int, CaseIterable, Codable {
        case full
        case cutaway        // no roof and nothing above storey `cut`
        case dollhouse      // ...and no front wall up to it either
        var title: String { ["Whole", "Cutaway", "Dollhouse"][rawValue] }
    }

    static let floorRange = 1...40
    static let widthRange: ClosedRange<Float> = 6...48
    static let depthRange: ClosedRange<Float> = 8...48
}

/// Who the crowd scene's characters are.
enum CrowdBodies: Int, CaseIterable, Codable {
    case library        // Assets/Characters: the Mixamo mannequins
    case generated      // the character catalog's people (CharacterCatalog, CharacterBuilder)
    var title: String { ["Mannequins", "Generated people"][rawValue] }
}

/// The character workshop (Scene+Characters.swift): who it shows, in what pose, and how.
struct CharacterSceneSettings: Equatable, Codable {
    /// The character's id (CharacterCatalog).
    var character = "man"
    var layout = Layout.single
    var pose = Pose.aPose
    /// Pose `clip`: the clip's name (any clip of the character library).
    var clip = ""
    var view = View.body
    /// What the faces do (blinks always), and whether their eyes follow the camera.
    var expression = FaceExpression.neutral
    var lookAt = true
    /// How hair is drawn (CharacterHair): strands, the caps crowds have, or none.
    var hair = HairMode.strands
    /// Registry keys (CharacterCatalog.register), session state: the editor's variations of the character to show
    /// beside it (layout `mutate`), and the definitions to show in its place (comparing with the saved ones). "" = none.
    var mutants = ""
    var compare = ""

    enum Layout: Int, CaseIterable, Codable {
        case single         // the character
        case lineup         // every character of the catalog, side by side
        case mutate         // the character and the editor's variations of it, in a row
        var title: String { ["One character", "Everyone", "Variations"][rawValue] }
    }
    enum Pose: Int, CaseIterable, Codable {
        case tPose, aPose, idle, walk, clip
        var title: String { ["T pose", "A pose", "Idle", "Walking", "Clip"][rawValue] }
        /// The clip it plays (CharacterKit's names), for every pose but `clip`.
        var clipName: String? { [Optional("T-Pose"), "A-Pose", "Idle", "Walking", nil][rawValue] }
    }
    enum View: Int, CaseIterable, Codable {
        case body           // the whole character
        case face           // its head, close
        var title: String { ["Body", "Face"][rawValue] }
    }
    enum HairMode: Int, CaseIterable, Codable {
        case strands, caps, none
        var title: String { ["Strands", "Caps", "None"][rawValue] }
    }
}

/// The plant workshop (Scene+Plants.swift): which plants it shows, and how.
struct PlantSceneSettings: Equatable, Codable {
    /// The species' id (PlantCatalog), and the age and seeded variant of the one plant shown.
    var species = "oak"
    var age = Foliage.Age.mature
    var variant = 0
    /// What the variants are grown from: the library's seed (SceneSettings.seed), so the workshop's oak 2 at seed 1 is
    /// the forest's.
    var seed = 1
    var layout = Layout.single
    var view = View.plant
    /// Registry keys (PlantCatalog.register), session state: the editor's variations of the species to show beside it
    /// (layout `mutate`), and the definition to show in its place (comparing with the saved one). "" = none.
    var mutants = ""
    var compare = ""

    enum Layout: Int, CaseIterable, Codable {
        case single         // the one plant
        case lineup         // every age (rows) and variant (columns)
        case mutate         // the plant and the editor's variations of it, in a row

        var title: String { ["One plant", "Ages and variants", "Variations"][rawValue] }
    }
    enum View: Int, CaseIterable, Codable {
        case plant
        case skeleton       // the stems as thin lines, a colour to a level; no leaves

        var title: String { ["Plant", "Skeleton"][rawValue] }
    }

    static let variantRange = 0...7
}

extension SceneKind {
    /// The camera turns about what the scene shows (the plant workshop's plants, the VFX stage's effects; F frames them).
    var orbits: Bool { isWorkshop || self == .vfxStage || self == .materials || self == .painter }
}
