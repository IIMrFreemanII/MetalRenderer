// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MetalGI",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MetalGI",
            path: "Sources/MetalGI",
            // Shaders are compiled at runtime (so you can hot-reload them with R),
            // so SwiftPM must not try to process this file.
            exclude: ["Shaders.metal"]
        )
    ]
)
