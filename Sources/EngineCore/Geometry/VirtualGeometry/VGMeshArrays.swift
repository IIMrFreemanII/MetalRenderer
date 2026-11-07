import simd

/// A mesh as plain arrays, to be made into virtual geometry (`VirtualGeometryBuilder.mesh(cacheKey:build:)`):
/// positions, normals and UVs per vertex, three indices a triangle.
package struct VGMeshArrays {
    package var positions: [SIMD3<Float>]
    package var normals: [SIMD3<Float>]
    package var uvs: [SIMD2<Float>]
    package var indices: [UInt32]

    package init(positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32]) {
        self.positions = positions
        self.normals = normals
        self.uvs = uvs
        self.indices = indices
    }

    package var triangleCount: Int { indices.count / 3 }
}
