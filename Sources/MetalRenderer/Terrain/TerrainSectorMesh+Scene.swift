import EngineCore
import Landscape

extension TerrainSectorMesh {
    /// As a scene borrows it (Scene.addMesh(borrowing:)).
    var borrowed: Scene.BorrowedMesh {
        Scene.BorrowedMesh(positions: .made(positions), normals: .made(normals), uvs: .made(uvs), indices: .made(indices),
                           materials: materials.map { .made($0) }, weights: .made(weights))
    }
}
