import simd

/// What a click in the view found (Renderer.readPick): the instance, its material (its index in the scene), the
/// material's fingerprint as the scene made it (MaterialAssignments), the graph it already is (if it is procedural),
/// its colour there, and where.
package struct MaterialPick: Equatable {
    package var instance: Int
    package var material: Int
    package var fingerprint = ""
    package var graph: String?
    package var albedo: SIMD3<Float>
    package var position: SIMD3<Float>
}
