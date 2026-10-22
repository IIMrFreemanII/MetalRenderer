/// How a mesh in a buffer of its own (the engine's MeshBlock) lays out its bytes: positions, normals, UVs, indices, a
/// material per triangle, then (a terrain's sector) its vertices' layer weights. What writes one (TerrainSectorMesh)
/// and what reads one go by these.
package enum MeshBlockLayout {
    package static func indexOffset(vertices: Int) -> Int { vertices * (2 * MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<SIMD2<Float>>.stride) }
    /// A terrain's sector's layer weights (16 bytes a vertex): after the materials, on a 16-byte boundary.
    package static func weightsOffset(vertices: Int, indices: Int) -> Int { (indexOffset(vertices: vertices) + indices * 4 + indices / 3 + 15) & ~15 }
    /// The bytes a mesh takes, with weights or without.
    package static func length(vertices: Int, indices: Int, weights: Bool) -> Int {
        weights ? weightsOffset(vertices: vertices, indices: indices) + vertices * 16 : indexOffset(vertices: vertices) + indices * 4 + indices / 3
    }
}
