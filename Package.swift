// swift-tools-version:5.9
import PackageDescription

/// Every module's flags.
let engineSettings: [SwiftSetting] = [
    // Release builds are testable too: `swift build -c release` and `swift test -c release` then build
    // the same thing, and switching between them rebuilds nothing.
    .unsafeFlags(["-enable-testing"], .when(configuration: .release)),
    // No function body crosses a module unless it is `@inlinable`: a body the build carried into the modules above
    // would stay there after an edit, since only a module's interface rebuilds its dependents. So no cross-module
    // optimisation: `-disable-cmo`, and in a testable module the CMO pass too (it still hands the small functions'
    // bodies to the modules above; it would also hand the tests' optimiser the whole module's: a release test build
    // took 30 min instead of 35 s). A helper a loop of the frame's needs from below is an `@inlinable package`
    // function on plain types (Tools/perf/hotcalls.py finds the ones that aren't; Tools/modules/inlinable.py rebuilds
    // the modules above one whose body changed).
    .unsafeFlags(["-Xfrontend", "-disable-cmo", "-Xllvm", "-sil-disable-pass=cmo"]),
    // An expression that takes the type checker over 300 ms (a function, 600 ms) shows up as a warning:
    // give it explicit types or split it before it slows every build down.
    .unsafeFlags(["-Xfrontend", "-warn-long-function-bodies=600",
                  "-Xfrontend", "-warn-long-expression-type-checking=300"], .when(configuration: .debug))
]

let package = Package(
    name: "MetalRenderer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MetalRenderer", targets: ["MetalRendererApp"])
    ],
    targets: [
        // Atomic operations for the CPU physics' worker pool (Physics/PhysicsThreads.swift).
        .target(name: "CPhysicsAtomics", path: "Sources/CPhysicsAtomics"),
        // The core: math, geometry and file formats, textures, the GPU structs and pipelines every module shares; it
        // knows no scene or renderer. The modules are libraries, so that the app and the tests share one build of
        // each (an executable target is compiled twice, once more for `@testable import`), and an edit rebuilds its
        // module and, when the edit changes the module's interface, the modules above it (README, "Source layout").
        .target(
            name: "EngineCore",
            path: "Sources/EngineCore",
            swiftSettings: engineSettings
        ),
        // The plants: species, their generator (meshes, voxels, textures), the catalog and its store. The scene's
        // plant tracing (descriptors, voxel levels) is the engine's.
        .target(
            name: "Plants",
            dependencies: ["EngineCore"],
            path: "Sources/Plants",
            swiftSettings: engineSettings
        ),
        // The physics: rigid bodies and their CPU and GPU steps, joints, particles, cloth, soft bodies, muscles, hair,
        // liquids, and the destruction's fracture and demolition inside the step (their loops call each other's).
        // The scene's side of it (Scene+PhysicsWorld, the rigs) is the engine's.
        .target(
            name: "Physics",
            dependencies: ["EngineCore", "CPhysicsAtomics"],
            path: "Sources/Physics",
            swiftSettings: engineSettings
        ),
        // The characters: bodies and their DNA, faces, skin, hair, muscles and skeletons, animation (FBX, Mixamo),
        // the crowd and its skinning, the physics' rig of a character. Putting them in a scene is the engine's.
        .target(
            name: "Characters",
            dependencies: ["EngineCore", "Plants", "Physics"],
            path: "Sources/Characters",
            swiftSettings: engineSettings
        ),
        // The effects: GPU particles (emitters, fields, colliders, their textures) and effects as graphs (the VFX
        // graph, its lowering, interpreter and generated Metal, the library and store). Running them in a scene is the
        // engine's. On the physics: its break events emit particles.
        .target(
            name: "Effects",
            dependencies: ["EngineCore", "Physics"],
            path: "Sources/Effects",
            swiftSettings: engineSettings
        ),
        // The materials: the Material Designer's graphs, their compiler and engine (bakes, generated Metal), the
        // library and store, scanned materials; the Material Painter's documents, brushes, bakes and unwrapping. Their
        // part of a scene and a frame (assignments, displacement, the painter's session) is the engine's. On the
        // effects: the graphs share their curves and gradients.
        .target(
            name: "Materials",
            dependencies: ["EngineCore", "Effects"],
            path: "Sources/Materials",
            swiftSettings: engineSettings
        ),
        // The engine: the scene, the renderer and its systems, the editors' workshop scenes, the benchmarks; all but
        // the core, the editors, the game and the entry point.
        .target(
            name: "MetalRenderer",
            dependencies: ["EngineCore", "Plants", "Physics", "Characters", "Effects", "Materials"],
            path: "Sources/MetalRenderer",
            // Shaders are compiled at runtime (so you can hot-reload them with R),
            // so SwiftPM must not try to process them: the entry file and its pieces.
            exclude: ["Shaders.metal", "ShadersVFX.metal", "Shaders", "ShadersMaterial.metal", "ShadersMaterialCode.metal", "MaterialShaders"],
            swiftSettings: engineSettings
        ),
        // The editors and the app around the renderer: the window, its panels and menus, every editor's UI. The
        // engine never calls them: they read its reports (RendererController) and send it work.
        .target(
            name: "Editors",
            dependencies: ["EngineCore", "Plants", "Physics", "Characters", "Effects", "Materials", "MetalRenderer"],
            path: "Sources/Editors",
            swiftSettings: engineSettings
        ),
        // The game: the demo scenes (their builders, looks and settings rows) and the benchmark modes that show them,
        // on the engine's `package` API. A change here recompiles this target alone (README, "Source layout").
        .target(
            name: "Game",
            dependencies: ["EngineCore", "Plants", "Physics", "Characters", "Effects", "Materials", "MetalRenderer"],
            path: "Sources/Game",
            swiftSettings: engineSettings
        ),
        .executableTarget(
            name: "MetalRendererApp",
            dependencies: ["Editors", "Game"],
            path: "Sources/MetalRendererApp"
        ),
        .testTarget(
            name: "MetalRendererTests",
            dependencies: ["EngineCore", "Plants", "Physics", "Characters", "Effects", "Materials", "MetalRenderer", "Editors", "Game"],
            path: "Tests/MetalRendererTests"
        )
    ]
)
