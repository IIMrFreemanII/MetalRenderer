import XCTest
import simd
@testable import EngineCore
@testable import Modeling

/// The modeller's mesh (EditMesh): primitives are valid closed surfaces facing out, drafts make edges again with
/// their flags, selection flushes as Blender's, normals and triangles.
final class ModelingMeshTests: XCTestCase {
    func testPrimitivesAreValid() {
        for p in Primitive.allCases {
            let m = p.mesh()
            XCTAssertNil(m.validate(), "\(p): \(m.validate() ?? "")")
            XCTAssertGreaterThan(m.vertexCount, 0, "\(p)")
        }
    }

    func testClosedPrimitivesAreSpheresOrTori() {
        let spheres: [Primitive] = [.cube, .uvSphere, .icoSphere, .cylinder, .cone, .head]
        for p in spheres {
            let m = p.mesh()
            XCTAssertTrue(m.isClosedManifold(), "\(p) is closed")
            XCTAssertEqual(m.eulerCharacteristic, 2, "\(p): V − E + F")
        }
        let torus = Primitive.torus.mesh()
        XCTAssertTrue(torus.isClosedManifold())
        XCTAssertEqual(torus.eulerCharacteristic, 0)
        XCTAssertEqual(Primitive.cube.mesh().faceCount, 6)
        XCTAssertEqual(Primitive.cube.mesh().edgeCount, 12)
        XCTAssertEqual(Primitive.uvSphere.mesh().faceCount, 32 * 16)
        XCTAssertEqual(Primitive.icoSphere.mesh().faceCount, 80)
        XCTAssertEqual(Primitive.grid.mesh().faceCount, 100)
        XCTAssertEqual(Primitive.circle.mesh().edgeCount, 32)
        XCTAssertEqual(Primitive.circle.mesh().faceCount, 0)
    }

    /// Every face of a closed primitive faces out: the signed volume is positive (the divergence theorem).
    func testPrimitivesFaceOutwards() {
        for p in [Primitive.cube, .uvSphere, .icoSphere, .cylinder, .cone, .torus, .head] {
            let m = p.mesh()
            let (tri, _) = m.triangles()
            var volume: Float = 0
            for t in 0..<(tri.count / 3) {
                let a = m.positions[Int(m.cornerVerts[Int(tri[3 * t])])]
                let b = m.positions[Int(m.cornerVerts[Int(tri[3 * t + 1])])]
                let c = m.positions[Int(m.cornerVerts[Int(tri[3 * t + 2])])]
                volume += simd_dot(a, simd_cross(b, c)) / 6
            }
            XCTAssertGreaterThan(volume, 0, "\(p) faces out")
        }
        // The cube's volume is its side cubed.
        let cube = Primitive.cube.mesh()
        let (tri, _) = cube.triangles()
        var v: Float = 0
        for t in 0..<(tri.count / 3) {
            let a = cube.positions[Int(cube.cornerVerts[Int(tri[3 * t])])], b = cube.positions[Int(cube.cornerVerts[Int(tri[3 * t + 1])])]
            let c = cube.positions[Int(cube.cornerVerts[Int(tri[3 * t + 2])])]
            v += simd_dot(a, simd_cross(b, c)) / 6
        }
        XCTAssertEqual(v, 8, accuracy: 1e-4)
    }

    func testDraftKeepsEdgeFlagsByVertices() {
        var m = Primitive.cube.mesh()
        m.edgeFlags[3] |= EditMesh.Flag.seam
        m.edgeCrease[5] = 0.7
        let k3 = m.edgeKey(3), k5 = m.edgeKey(5)
        // Shuffle the faces: the edges come back in key order with their flags.
        var d = m.draft()
        var faces: [[Int32]] = []
        for f in 0..<d.faceCount { faces.append(Array(d.faceVerts(f))) }
        d.faceStart = [0]; d.cornerVerts = []; d.cornerUVs = []; d.faceMaterial = []; d.faceSet = []; d.faceFlags = []
        for f in faces.reversed() { d.addFace(f) }
        let n = EditMesh(d)
        XCTAssertNil(n.validate())
        let e3 = (0..<n.edgeCount).first { n.edgeKey($0) == k3 }!, e5 = (0..<n.edgeCount).first { n.edgeKey($0) == k5 }!
        XCTAssertNotEqual(n.edgeFlags[e3] & EditMesh.Flag.seam, 0)
        XCTAssertEqual(n.edgeCrease[e5], 0.7)
        XCTAssertNotEqual(n.generation, m.generation)
    }

    func testDegenerateCornersAreDropped() {
        var d = EditMesh.Draft()
        for p in [SIMD3<Float>(0, 0, 0), [1, 0, 0], [1, 1, 0], [0, 1, 0]] { d.addVertex(p) }
        d.addFace([0, 1, 1, 2, 3])        // a repeat next to itself: a quad
        d.addFace([0, 1, 1])              // two corners: gone
        let m = EditMesh(d)
        XCTAssertNil(m.validate())
        XCTAssertEqual(m.faceCount, 1)
        XCTAssertEqual(m.faceSize(0), 4)
    }

    func testRemoveUnusedVertices() {
        var d = EditMesh.Draft()
        for p in [SIMD3<Float>(0, 0, 0), [5, 5, 5], [1, 0, 0], [1, 1, 0]] { d.addVertex(p) }
        d.addFace([0, 2, 3])
        var m = EditMesh(d)
        m.removeUnusedVertices()
        XCTAssertEqual(m.vertexCount, 3)
        XCTAssertNil(m.validate())
        XCTAssertEqual(m.positions[1], SIMD3(1, 0, 0))
    }

    func testSelectionFlush() {
        var m = Primitive.cube.mesh()
        // Select the +x face's four vertices: in vertex mode its edges and the face are selected.
        for c in m.corners(0) { m.setSelected(vertex: Int(m.cornerVerts[c]), true) }
        m.flushSelection(from: .vertex)
        XCTAssertEqual(m.selectedFaces, [0])
        XCTAssertEqual(m.selectedEdges.count, 4)
        // To face mode and back: the same.
        m.convertSelection(from: .vertex, to: .face)
        XCTAssertEqual(m.selectedFaces, [0])
        XCTAssertEqual(m.selectedVertices.count, 4)
        // Grow by faces: every vertex (a cube's faces all touch the +x face's vertices).
        m.growSelection(true, mode: .vertex)
        XCTAssertEqual(m.selectedVertices.count, 8)
        m.invertSelection(mode: .vertex)
        XCTAssertFalse(m.hasSelection)
    }

    func testHideAndReveal() {
        var m = Primitive.cube.mesh()
        m.setSelected(face: 2, true)
        m.flushSelection(from: .face)
        m.hide(selected: true, mode: .face)
        XCTAssertTrue(m.isHidden(face: 2))
        XCTAssertFalse(m.hasSelection)
        // A face's edges stay shown while another face shows them.
        XCTAssertEqual((0..<m.edgeCount).filter { m.isHidden(edge: $0) }.count, 0)
        m.reveal()
        XCTAssertFalse(m.isHidden(face: 2))
        XCTAssertTrue(m.isSelected(face: 2))
    }

    func testTrianglesAndNormals() {
        let m = Primitive.cube.mesh()
        let (tri, face) = m.triangles()
        XCTAssertEqual(tri.count, 36)
        XCTAssertEqual(face.count, 12)
        // A flat cube: each corner has its face's normal.
        let cn = m.cornerNormals()
        for f in 0..<m.faceCount { for c in m.corners(f) { XCTAssertEqual(simd_distance(cn[c], m.faceNormal(f)), 0, accuracy: 1e-6) } }
        // Smooth, no sharp edges: the corners of a vertex share one normal, along the diagonal.
        var s = m
        for f in 0..<s.faceCount { s.faceFlags[f] |= EditMesh.Flag.smooth }
        let sn = s.cornerNormals()
        XCTAssertEqual(simd_distance(sn[0], simd_normalize(s.positions[Int(s.cornerVerts[0])])), 0, accuracy: 1e-5)
        // Smooth with every edge sharp: back to flat.
        for e in 0..<s.edgeCount { s.edgeFlags[e] |= EditMesh.Flag.sharp }
        let hn = s.cornerNormals()
        for f in 0..<s.faceCount { for c in s.corners(f) { XCTAssertEqual(simd_distance(hn[c], s.faceNormal(f)), 0, accuracy: 1e-5) } }
    }

    /// A concave n-gon (an L) triangulates without a triangle outside it.
    func testConcaveFaceTriangulation() {
        let p: [SIMD3<Float>] = [[0, 0, 0], [2, 0, 0], [2, 0, -1], [1, 0, -1], [1, 0, -2], [0, 0, -2]]
        let m = EditMesh(positions: p, faces: [[0, 1, 2, 3, 4, 5]])
        var tri: [Int32] = []
        m.triangulate(0, into: &tri)
        XCTAssertEqual(tri.count, 12)
        var area: Float = 0
        for t in 0..<4 {
            let a = p[Int(tri[3 * t])], b = p[Int(tri[3 * t + 1])], c = p[Int(tri[3 * t + 2])]
            let n = simd_cross(b - a, c - a)
            XCTAssertGreaterThan(n.y, 0, "triangle \(t) faces the polygon's way")
            area += simd_length(n) / 2
        }
        XCTAssertEqual(area, 3, accuracy: 1e-5)
    }

    func testTriangleMeshWeldsCorners() {
        var m = Primitive.uvSphere.mesh()
        // One UV per vertex on a smooth sphere except the seam and the poles: far fewer vertices than corners.
        let t = TriangleMesh(m)
        XCTAssertLessThan(t.positions.count, m.cornerCount / 2)
        XCTAssertEqual(t.triangleCount, 32 * 14 * 2 + 64)
        m.faceFlags[0] |= EditMesh.Flag.hide
        XCTAssertEqual(TriangleMesh(m, skipHidden: true).triangleCount, t.triangleCount - 1)
    }

    func testUniqueNames() {
        var doc = ModelingDocument.startup()
        doc.add(ModelObject(name: "Cube", mesh: Primitive.cube.mesh()))
        doc.add(ModelObject(name: "Cube", mesh: Primitive.cube.mesh()))
        XCTAssertEqual(doc.objects.map(\.name), ["Cube", "Cube.001", "Cube.002"])
        XCTAssertEqual(doc.active, 2)
    }

    func testEulerRoundTrip() {
        for r in [SIMD3<Float>(0.3, -0.7, 1.1), [0, 0, 0], [-2, 0.2, 0.5]] {
            let t = ObjectTransform(rotation: r)
            let back = ObjectTransform.euler(t.rotationMatrix)
            let u = ObjectTransform(rotation: back)
            for i in 0..<3 {
                XCTAssertEqual(simd_distance(t.rotationMatrix[i], u.rotationMatrix[i]), 0, accuracy: 1e-5)
            }
        }
    }
}
