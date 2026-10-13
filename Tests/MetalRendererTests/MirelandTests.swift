import XCTest
import simd
@testable import MetalRenderer

/// The Mireland swamp (Scene+Mireland.swift): every Mireland material in it, procedural; its cut-outs on meshes with
/// UVs (the alpha test reads them), their shadows traced; displacement only where the scene allows it, within budget.
final class MirelandTests: XCTestCase {
    func testTheSwampIsMadeOfTheMirelandMaterials() {
        let scene = Scene(SceneSettings(kind: .mireland))
        XCTAssertEqual(Set(scene.procedural.map(\.graph)), Set(MaterialLibrary.mireland.map(\.name)))
        XCTAssertTrue(scene.hasOpacity)
        XCTAssertFalse(scene.isStill)
        var cutOut = 0
        for (i, inst) in scene.instances.enumerated() where scene.cutsHoles(i) {
            cutOut += 1
            XCTAssertNotEqual(inst.mask & Scene.maskShadowTraced, 0, "a cut-out's shadow is traced")
            let mesh = scene.meshes[inst.mesh]
            let range = Int(mesh.firstIndex)..<Int(mesh.firstIndex + mesh.indexCount)
            XCTAssertGreaterThan(Scene.uvArea(scene.uvs, Array(scene.indices[range])), 0, "a cut-out without UVs")
        }
        XCTAssertGreaterThan(cutOut, 100, "the grass, the plants and the decals")
        // Only the near gnarly trunks are displaced; the ground, the patches and the far trees keep their parallax.
        XCTAssertFalse(scene.displaced.isEmpty)
        let gnarly = scene.procedural.filter { $0.graph == "Swamp Gnarly Bark" }.map(\.material)
        XCTAssertTrue(scene.displaced.allSatisfy { gnarly.contains($0.material) && !scene.undisplacedMaterials.contains($0.material) })
        XCTAssertLessThanOrEqual(scene.displaced.reduce(0) { $0 + $1.triangles }, Scene.displacedTrianglesPerScene)
        XCTAssertEqual(MaterialAssignments.scope(SceneSettings(kind: .mireland)), "mireland,seed=1")
    }
}
