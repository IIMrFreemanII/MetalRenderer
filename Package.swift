// swift-tools-version:5.9
import PackageDescription

/// The engine's and the game's flags.
let engineSettings: [SwiftSetting] = [
    // Release builds are testable too: `swift build -c release` and `swift test -c release` then build
    // the same thing, and switching between them rebuilds nothing.
    // No cross-module optimisation: with every internal function testable it would hand the tests' optimiser the
    // whole module's bodies (a release test build took 30 min instead of 35 s). The game's calls into the engine
    // are calls then, not inlined: they build scenes and set them up, none of them in a loop of the frame's.
    .unsafeFlags(["-enable-testing", "-Xfrontend", "-disable-cmo"], .when(configuration: .release)),
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
        // Atomic operations for the CPU physics' worker pool (PhysicsThreads.swift).
        .target(name: "CPhysicsAtomics", path: "Sources/CPhysicsAtomics"),
        // The engine: the renderer, its systems, the editors and their workshops; all but the game and the entry
        // point. A library, so that the app and the tests share one build of it (an executable target is compiled
        // twice, once more for `@testable import`).
        .target(
            name: "MetalRenderer",
            dependencies: ["CPhysicsAtomics"],
            path: "Sources/MetalRenderer",
            // Shaders are compiled at runtime (so you can hot-reload them with R),
            // so SwiftPM must not try to process them: the entry file and its pieces.
            exclude: ["Shaders.metal", "ShadersVFX.metal", "Shaders", "ShadersMaterial.metal", "ShadersMaterialCode.metal", "MaterialShaders"],
            swiftSettings: engineSettings
        ),
        // The game: the demo scenes (their builders, looks and settings rows) and the benchmark modes that show them,
        // on the engine's `package` API. A change here recompiles this target alone (README, "Source layout").
        .target(
            name: "Game",
            dependencies: ["MetalRenderer"],
            path: "Sources/Game",
            swiftSettings: engineSettings
        ),
        .executableTarget(
            name: "MetalRendererApp",
            dependencies: ["MetalRenderer", "Game"],
            path: "Sources/MetalRendererApp"
        ),
        .testTarget(
            name: "MetalRendererTests",
            dependencies: ["MetalRenderer", "Game"],
            path: "Tests/MetalRendererTests"
        )
    ]
)
