import Characters
import Effects
import EngineCore
import Materials
import Physics
import Plants
import simd

extension Scene {
    // MARK: - Mesh generators (MeshShapes, in the core)

    package static func quadMesh() -> MeshGeometry { MeshShapes.quadMesh() }
    package static func cubeMesh() -> MeshGeometry { MeshShapes.cubeMesh() }
    package static func capsuleMesh(halfLength: Float, radius: Float, segments: Int = 24, rings: Int = 6) -> MeshGeometry { MeshShapes.capsuleMesh(halfLength: halfLength, radius: radius, segments: segments, rings: rings) }
    package static func icosphere(subdivisions: Int) -> MeshGeometry { MeshShapes.icosphere(subdivisions: subdivisions) }
}
