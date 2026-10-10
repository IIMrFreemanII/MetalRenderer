// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MetalRenderer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MetalRenderer",
            path: "Sources/MetalRenderer",
            // Shaders are compiled at runtime (so you can hot-reload them with R),
            // so SwiftPM must not try to process them: the entry file and its pieces.
            exclude: ["Shaders.metal", "ShadersVFX.metal", "Shaders", "ShadersMaterial.metal", "ShadersMaterialCode.metal", "MaterialShaders"]
        ),
        .testTarget(
            name: "MetalRendererTests",
            dependencies: ["MetalRenderer"],
            path: "Tests/MetalRendererTests"
        )
    ]
)
