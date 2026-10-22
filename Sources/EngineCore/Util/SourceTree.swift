import Foundation

/// Where the package's files are at runtime: found from this source file's path, so a file that looks for the shaders
/// or the assets doesn't depend on how deep it sits in the folders.
package enum SourceTree {
    /// The folder with `Package.swift` (the current directory if the sources aren't where they were built).
    package static let packageRoot: URL = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            dir.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }()

    /// The engine's sources (the MetalRenderer module): `Shaders.metal`, `Shaders/` and the other entry files sit at
    /// the top of it.
    package static let target = packageRoot.appendingPathComponent("Sources/MetalRenderer")
}
