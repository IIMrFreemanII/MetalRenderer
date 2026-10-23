import XCTest
import simd
@testable import EngineCore
@testable import Modeling

/// The modeller's files: OBJ both ways, glTF in and out, model assets.
final class ModelingIOTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModelingIOTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func testOBJRoundTrip() throws {
        var cube = Primitive.cube.mesh()
        cube.faceMaterial[2] = 1
        let slots = [MaterialSlot(name: "Red", baseColor: [1, 0, 0, 1], roughness: 0.3), MaterialSlot(name: "Blue", baseColor: [0, 0, 1, 1])]
        let url = folder.appendingPathComponent("cube.obj")
        try OBJFile.write([("Cube", cube, matrix_identity_float4x4, slots)], to: url)
        let back = try OBJFile.read(url)
        XCTAssertEqual(back.count, 1)
        let m = back[0].mesh
        XCTAssertNil(m.validate())
        XCTAssertEqual(m.faceCount, 6)
        XCTAssertEqual(m.vertexCount, 8)
        XCTAssertTrue(m.isClosedManifold())
        XCTAssertEqual(back[0].name, "Cube")
        XCTAssertEqual(back[0].materials.map(\.name), ["Red", "Blue"])
        XCTAssertEqual(back[0].materials[0].baseColor.x, 1)
        XCTAssertEqual(back[0].materials[0].roughness, 0.3, accuracy: 1e-5)
        XCTAssertEqual(m.faceMaterial[2], 1)
        XCTAssertEqual(m.cornerUVs, cube.cornerUVs)
        for v in 0..<8 { XCTAssertEqual(m.positions[v], cube.positions[v]) }
    }

    func testOBJObjectsNegativeIndicesAndLines() {
        let text = """
        o A
        v 0 0 0
        v 1 0 0
        v 1 1 0
        f -3 -2 -1
        o B
        v 0 0 1
        v 1 0 1
        v 1 1 1
        v 0 1 1
        f 4/1 5/1 6/1 7/1
        l 4 6
        """
        let objects = OBJFile.parse(text)
        XCTAssertEqual(objects.map(\.name), ["A", "B"])
        XCTAssertEqual(objects[0].mesh.faceCount, 1)
        XCTAssertEqual(objects[1].mesh.vertexCount, 4)
        XCTAssertEqual(objects[1].mesh.faceSize(0), 4)
        XCTAssertEqual(objects[1].mesh.edgeCount, 5)    // four sides and the diagonal line
    }

    func testGLBRoundTripKeepsHardEdges() throws {
        let cube = Primitive.cube.mesh()
        let tm = TriangleMesh(cube)
        XCTAssertEqual(tm.positions.count, 24)   // flat: four vertices per side
        let url = folder.appendingPathComponent("cube.glb")
        try GLTFModels.write([("Cube", tm, [MaterialSlot(name: "M", baseColor: [0.2, 0.4, 0.6, 1], metallic: 1, roughness: 0.2)])], to: url)
        let objects = try GLTFModels.read(url)
        XCTAssertEqual(objects.count, 1)
        let m = objects[0].mesh
        XCTAssertNil(m.validate())
        XCTAssertEqual(m.vertexCount, 8, "welded back to the cube's corners")
        XCTAssertEqual(m.faceCount, 12)
        XCTAssertTrue(m.isClosedManifold())
        // Its hard edges came back sharp (the diagonals of its sides aren't).
        XCTAssertEqual(m.edgeFlags.filter { $0 & EditMesh.Flag.sharp != 0 }.count, 12)
        XCTAssertEqual(objects[0].materials[0].metallic, 1)
        XCTAssertEqual(objects[0].materials[0].baseColor.y, 0.4, accuracy: 1e-6)
        // Same shading: flat corners.
        let n = m.cornerNormals()
        for f in 0..<m.faceCount { for c in m.corners(f) { XCTAssertEqual(simd_dot(n[c], m.faceNormal(f)), 1, accuracy: 1e-4) } }
    }

    func testModelAssetRoundTrip() throws {
        var doc = ModelingDocument.startup()
        var sphere = ModelObject(name: "Sphere", mesh: Primitive.uvSphere.mesh())
        sphere.transform = ObjectTransform(location: [2, 0, 0], rotation: [0, 0.5, 0], scale: [1, 2, 1])
        sphere.modifiers = [Modifier(.subdivision), Modifier(.mirror)]
        sphere.mesh.edgeFlags[7] |= EditMesh.Flag.seam
        sphere.mesh.edgeCrease[9] = 0.5
        var mr = MultiresData()
        mr.sculptLevel = 1; mr.displacements = [[[1, 2, 3], [4, 5, 6]], [[7, 8, 9]]]
        sphere.multires = mr
        doc.add(sphere)
        let tm = TriangleMesh(doc.objects[0].mesh)
        let rendered = ModelAsset.Rendered(positions: tm.positions, normals: tm.normals, uvs: tm.uvs, indices: tm.indices,
                                           triangleMaterial: tm.triangleMaterial, materials: doc.objects[0].materials)
        let url = folder.appendingPathComponent("test.\(ModelAsset.suffix)")
        try ModelAsset.write(doc, rendered: rendered, to: url)

        let back = try XCTUnwrap(ModelAsset.readDocument(url))
        XCTAssertEqual(back.objects.count, 2)
        XCTAssertEqual(back.objects.map(\.name), ["Cube", "Sphere"])
        XCTAssertEqual(back.active, 1)
        XCTAssertEqual(back.asset, "test")
        let s = back.objects[1]
        XCTAssertNil(s.mesh.validate())
        XCTAssertEqual(s.mesh.positions, doc.objects[1].mesh.positions)
        XCTAssertEqual(s.mesh.cornerVerts, doc.objects[1].mesh.cornerVerts)
        XCTAssertEqual(s.mesh.edges, doc.objects[1].mesh.edges)
        XCTAssertEqual(s.mesh.edgeFlags, doc.objects[1].mesh.edgeFlags)
        XCTAssertEqual(s.mesh.edgeCrease, doc.objects[1].mesh.edgeCrease)
        XCTAssertEqual(s.mesh.faceFlags, doc.objects[1].mesh.faceFlags)
        XCTAssertEqual(s.transform, sphere.transform)
        XCTAssertEqual(s.modifiers.map(\.kind), [.subdivision, .mirror])
        XCTAssertEqual(s.id, sphere.id)
        XCTAssertEqual(s.multires, mr)

        let r = try XCTUnwrap(ModelAsset.readRendered(url))
        XCTAssertEqual(r.triangleCount, tm.triangleCount)
        XCTAssertEqual(r.positions, tm.positions)
        XCTAssertEqual(r.materials.map(\.name), ["Material"])
        // Another file under the name isn't an asset.
        try Data("nope".utf8).write(to: url)
        XCTAssertNil(ModelAsset.readDocument(url))
    }

    func testStoreSlugAndList() throws {
        XCTAssertEqual(ModelStore.slug("My Chair #2"), "My-Chair--2")
        let url = try XCTUnwrap(ModelStore.url("a", in: folder))
        let doc = ModelingDocument.startup()
        try ModelAsset.write(doc, rendered: ModelAsset.Rendered(positions: [], normals: [], uvs: [], indices: [], triangleMaterial: [], materials: []), to: url)
        XCTAssertEqual(ModelStore.list(in: folder).map(\.slug), ["a"])
    }
}
