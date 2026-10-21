import CoreGraphics
import Foundation
import simd

/// How frames reach the GPU. Changing it recompiles the shaders and rebuilds the scene's structures.
package enum RenderAPI: Int, CaseIterable, Codable {
    case metal3             // MTLCommandQueue, one compute encoder per frame
    case metal4             // Metal 4: MTL4CommandQueue, argument tables, residency sets (macOS 26; Capabilities.metal4)

    package var title: String { self == .metal3 ? "Metal 3" : "Metal 4" }

    /// `METALRENDERER_API=metal4|metal3` picks the starting API (benchmarks: for every setting).
    package static let initial: RenderAPI = ProcessInfo.processInfo.environment["METALRENDERER_API"] == "metal4" ? .metal4 : .metal3
}
