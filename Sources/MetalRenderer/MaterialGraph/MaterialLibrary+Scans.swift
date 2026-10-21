import EngineCore
import Foundation
import Physics
import Plants

/// Photo-scanned materials: Bitmap nodes over the maps in Assets/Textures/<set>/ (Git LFS), the graph the Designer's
/// "Import Scanned Material…" makes (ScanMaterial.graph).
extension MaterialLibrary {
    package static let scans: [MaterialGraph] = [rockWall17()]

    /// Poly Haven's Rock Wall 17 (Dimitrios Savva, CC0): a dry-stone wall, 1.8 m a repeat, at 4K. Its normal and
    /// roughness were the download's DWAA EXRs, kept as 16-bit PNGs.
    package static func rockWall17() -> MaterialGraph {
        let dir = "Textures/rock-wall-17/"
        return ScanMaterial.graph(name: "Rock Wall 17",
                                  paths: [.albedo: dir + "albedo.jpg", .normal: dir + "normal.png", .roughness: dir + "roughness.png",
                                          .height: dir + "height.png"],
                                  metres: 1.8, size: 12)
    }
}
