// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MetalRenderer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MetalRenderer", targets: ["MetalRendererApp"])
    ],
    targets: [
        // The renderer, the scenes and the editors: everything but the entry point. A library, so that the app and
        // the tests share one build of it (an executable target is compiled twice, once more for `@testable import`).
        // Atomic operations for the CPU physics' worker pool (PhysicsThreads.swift).
        .target(name: "CPhysicsAtomics", path: "Sources/CPhysicsAtomics"),
        .target(
            name: "MetalRenderer",
            dependencies: ["CPhysicsAtomics"],
            path: "Sources/MetalRenderer",
            // Shaders are compiled at runtime (so you can hot-reload them with R),
            // so SwiftPM must not try to process them: the entry file and its pieces.
            exclude: ["Shaders.metal", "ShadersVFX.metal", "Shaders", "ShadersMaterial.metal", "ShadersMaterialCode.metal", "MaterialShaders"],
            swiftSettings: [
                // Release builds are testable too: `swift build -c release` and `swift test -c release` then build
                // the same thing, and switching between them rebuilds nothing.
                // No cross-module optimisation: the app's only code outside this module is `AppMain.run()`, and with
                // every internal function testable it would hand the tests' optimiser the whole module's bodies
                // (a release test build took 30 min instead of 35 s).
                .unsafeFlags(["-enable-testing", "-Xfrontend", "-disable-cmo"], .when(configuration: .release)),
                // An expression that takes the type checker over 300 ms (a function, 600 ms) shows up as a warning:
                // give it explicit types or split it before it slows every build down.
                .unsafeFlags(["-Xfrontend", "-warn-long-function-bodies=600",
                              "-Xfrontend", "-warn-long-expression-type-checking=300"], .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "MetalRendererApp",
            dependencies: ["MetalRenderer"],
            path: "Sources/MetalRendererApp"
        ),
        .testTarget(
            name: "MetalRendererTests",
            dependencies: ["MetalRenderer"],
            path: "Tests/MetalRendererTests"
        )
    ]
)
