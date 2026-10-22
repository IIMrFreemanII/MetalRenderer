import Foundation

/// The assets' folder: `METALRENDERER_ASSETS`, or `Assets/` next to `Package.swift`.
package enum Assets {
    package static let directory: URL = {
        if let dir = ProcessInfo.processInfo.environment["METALRENDERER_ASSETS"] { return URL(fileURLWithPath: dir) }
        return SourceTree.packageRoot.appendingPathComponent("Assets")
    }()
}
