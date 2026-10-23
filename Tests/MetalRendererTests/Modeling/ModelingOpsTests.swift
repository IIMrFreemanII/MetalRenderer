import XCTest
import simd
@testable import EngineCore
@testable import Modeling

/// Edit mode's operations on the primitives: element counts as Blender gives them, valid arrays, closed surfaces
/// that stay closed and face out.
final class ModelingOpsTests: XCTestCase {
    private func assertSound(_ m: EditMesh, closed: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(m.validate(), m.validate() ?? "", file: file, line: line)
        if closed {
            XCTAssertTrue(m.isClosedManifold(), "closed", file: file, line: line)
            XCTAssertEqual(m.eulerCharacteristic, 2, "V − E + F", file: file, line: line)
            XCTAssertGreaterThan(volume(m), 0, "faces out", file: file, line: line)
        }
    }

    private func volume(_ m: EditMesh) -> Float {
        let (tri, _) = m.triangles()
        var v: Float = 0
        for t in 0..<(tri.count / 3) {
            v += simd_dot(m.positions[Int(m.cornerVerts[Int(tri[3 * t])])],
                          simd_cross(m.positions[Int(m.cornerVerts[Int(tri[3 * t + 1])])], m.positions[Int(m.cornerVerts[Int(tri[3 * t + 2])])])) / 6
        }
        return v
    }

    /// The cube with its top face (+y) selected.
    private func cubeTop() -> EditMesh {
        var m = Primitive.cube.mesh()
        let top = (0..<m.faceCount).first { m.faceNormal($0).y > 0.9 }!
        m.select(faces: [top])
        return m
    }

    func testDelete() {
        var m = cubeTop()
        m.delete(.faces)
        XCTAssertEqual(m.faceCount, 5)
        XCTAssertEqual(m.edgeCount, 12)
        XCTAssertEqual(m.vertexCount, 8)
        XCTAssertNil(m.validate())

        m = Primitive.cube.mesh()
        m.select(vertices: [0])
        m.delete(.vertices)
        XCTAssertEqual(m.vertexCount, 7)
        XCTAssertEqual(m.faceCount, 3)
        XCTAssertEqual(m.edgeCount, 9)
        XCTAssertNil(m.validate())

        m = cubeTop()
        m.delete(.onlyFaces)
        XCTAssertEqual(m.faceCount, 5)
        XCTAssertEqual(m.edgeCount, 12)

        m = Primitive.cube.mesh()
        m.select(edges: [0])
        m.delete(.edges)
        XCTAssertEqual(m.faceCount, 4)
        XCTAssertEqual(m.edgeCount, 11)
        XCTAssertNil(m.validate())
    }

    func testDissolve() {
        var m = Primitive.grid.mesh()   // 10 × 10
        let t = MeshTopology(m)
        let inner = (0..<m.edgeCount).first { t.faceCount(ofEdge: $0) == 2 }!
        m.select(edges: [inner])
        m.dissolve(.edge)
        XCTAssertEqual(m.faceCount, 99)
        XCTAssertNil(m.validate())
        // A vertex in the middle: its four faces become one.
        var g = Primitive.grid.mesh()
        let middle = (0..<g.vertexCount).min { simd_length(g.positions[$0]) < simd_length(g.positions[$1]) }!
        g.select(vertices: [middle])
        g.dissolve(.vertex)
        XCTAssertEqual(g.faceCount, 97)
        XCTAssertEqual(g.vertexCount, 120)
        XCTAssertNil(g.validate())
        // Faces: a 2 × 2 block becomes one.
        var h = Primitive.grid.mesh()
        let fs = (0..<h.faceCount).filter { simd_length(h.faceCenter($0)) < 0.2 }
        XCTAssertEqual(fs.count, 4)
        h.select(faces: fs)
        h.dissolve(.face)
        XCTAssertEqual(h.faceCount, 97)
        XCTAssertNil(h.validate())
    }

    func testExtrudeRegion() {
        var m = cubeTop()
        let n = m.extrude()
        XCTAssertEqual(simd_distance(n, [0, 1, 0]), 0, accuracy: 1e-5)
        XCTAssertEqual(m.faceCount, 10)
        XCTAssertEqual(m.vertexCount, 12)
        XCTAssertEqual(m.selectedFaces.count, 1)
        XCTAssertEqual(m.selectedVertices.count, 4)
        // Moving the new face up keeps it a closed box.
        for v in m.selectedVertices { m.positions[v].y += 1 }
        assertSound(m)
        XCTAssertEqual(volume(m), 12, accuracy: 1e-3)
        // Two faces next to each other: one region, six sides.
        var r = Primitive.cube.mesh()
        let top = (0..<r.faceCount).first { r.faceNormal($0).y > 0.9 }!, side = (0..<r.faceCount).first { r.faceNormal($0).x > 0.9 }!
        r.select(faces: [top, side])
        r.extrude()
        XCTAssertEqual(r.faceCount, 6 + 6)
        for v in r.selectedVertices { r.positions[v] += [0.5, 0.5, 0] }
        assertSound(r)
        // Individual: each its own.
        var i = Primitive.cube.mesh()
        i.select(faces: [top, side])
        i.extrude(individual: true)
        XCTAssertEqual(i.faceCount, 6 + 8)
        XCTAssertNil(i.validate())
    }

    func testExtrudeEdgesAndVertices() {
        var m = Primitive.plane.mesh()
        m.select(edges: [0])
        m.extrude()
        XCTAssertEqual(m.faceCount, 2)
        XCTAssertEqual(m.vertexCount, 6)
        XCTAssertNil(m.validate())
        // The new face agrees with the old one across their edge.
        let t = MeshTopology(m)
        for e in 0..<m.edgeCount where t.faceCount(ofEdge: e) == 2 {
            let cs = t.corners(ofEdge: e)
            XCTAssertNotEqual(m.cornerVerts[Int(cs[cs.startIndex])], m.cornerVerts[Int(cs[cs.startIndex + 1])])
        }
        var v = Primitive.plane.mesh()
        v.select(vertices: [0])
        v.extrude()
        XCTAssertEqual(v.vertexCount, 5)
        XCTAssertEqual(v.edgeCount, 5)
        XCTAssertEqual(v.selectedVertices, [4])
    }

    func testInset() {
        var m = cubeTop()
        m.inset(thickness: 0.2)
        XCTAssertEqual(m.faceCount, 10)
        XCTAssertEqual(m.vertexCount, 12)
        assertSound(m)
        // The inner face is 1.6 wide (2 − 2 × 0.2) and still on top.
        let inner = m.selectedFaces
        XCTAssertEqual(inner.count, 1)
        XCTAssertEqual(m.faceArea(inner[0]), 1.6 * 1.6, accuracy: 1e-4)
        XCTAssertEqual(m.faceCenter(inner[0]).y, 1, accuracy: 1e-5)
        // With depth: lifted.
        var d = cubeTop()
        d.inset(thickness: 0.2, depth: 0.3)
        XCTAssertEqual(d.faceCenter(d.selectedFaces[0]).y, 1.3, accuracy: 1e-5)
        assertSound(d)
    }

    func testLoopsAndRings() {
        let s = Primitive.uvSphere.mesh()
        let t = MeshTopology(s)
        // An edge along the equator (both ends at y ≈ 0): its loop goes round, 32 edges.
        let eq = (0..<s.edgeCount).first { abs(s.positions[Int(s.edges[$0].x)].y) < 1e-4 && abs(s.positions[Int(s.edges[$0].y)].y) < 1e-4 }!
        XCTAssertEqual(s.edgeLoop(from: eq, topology: t).count, 32)
        let cube = Primitive.cube.mesh()
        let ring = cube.edgeRing(from: 0)
        XCTAssertEqual(ring.edges.count, 4)
        XCTAssertTrue(ring.closed)
        XCTAssertEqual(ring.faces.count, 4)
    }

    func testLoopCut() {
        var m = Primitive.cube.mesh()
        m.loopCut(0)
        XCTAssertEqual(m.faceCount, 10)
        XCTAssertEqual(m.vertexCount, 12)
        XCTAssertEqual(m.selectedVertices.count, 4)
        assertSound(m)
        XCTAssertEqual(volume(m), 8, accuracy: 1e-4)
        var three = Primitive.cube.mesh()
        three.loopCut(0, cuts: 3)
        XCTAssertEqual(three.faceCount, 6 + 4 * 3)
        assertSound(three)
        // Slide: the cut moves toward one side, still flat on the cube.
        var slid = Primitive.cube.mesh()
        slid.loopCut(0, slide: 0.5)
        assertSound(slid)
        XCTAssertEqual(volume(slid), 8, accuracy: 1e-4)
        // Across a grid: a ring stopped by the boundary.
        var g = Primitives.grid(x: 3, y: 3, size: 3)
        g.loopCut(0)
        XCTAssertEqual(g.faceCount, 12)
        XCTAssertNil(g.validate())
    }

    func testBevel() {
        var one = Primitive.cube.mesh()
        one.select(edges: [0])
        one.bevelEdges(width: 0.2)
        XCTAssertEqual(one.faceCount, 7)
        XCTAssertEqual(one.vertexCount, 10)
        assertSound(one)
        XCTAssertLessThan(volume(one), 8)

        var all = Primitive.cube.mesh()
        all.selectAll(true)
        all.bevelEdges(width: 0.2)
        XCTAssertEqual(all.faceCount, 6 + 12 + 8)
        XCTAssertEqual(all.vertexCount, 24)
        assertSound(all)

        var round = Primitive.cube.mesh()
        round.selectAll(true)
        round.bevelEdges(width: 0.3, segments: 4)
        assertSound(round)
        XCTAssertEqual(round.faceCount, 6 + 12 * 4 + 8)

        var vertex = Primitive.cube.mesh()
        vertex.select(vertices: [0])
        vertex.bevelVertices(width: 0.3)
        XCTAssertEqual(vertex.faceCount, 7)
        XCTAssertEqual(vertex.vertexCount, 10)
        assertSound(vertex)
    }

    func testMerge() {
        var m = Primitive.cube.mesh()
        m.selectAll(true)
        m.merge(.center)
        XCTAssertEqual(m.vertexCount, 1)
        XCTAssertEqual(m.faceCount, 0)
        XCTAssertNil(m.validate())
        // Two ends of an edge: the cube keeps its six faces, two become triangles.
        var e = Primitive.cube.mesh()
        e.select(vertices: [Int(e.edges[0].x), Int(e.edges[0].y)])
        e.merge(.center)
        XCTAssertEqual(e.vertexCount, 7)
        XCTAssertEqual(e.faceCount, 6)
        XCTAssertNil(e.validate())
        XCTAssertTrue(e.isClosedManifold())
        // By distance: a cube with every face's own vertices welds back to eight.
        var split = EditMesh.Draft()
        let cube = Primitive.cube.mesh()
        for f in 0..<cube.faceCount {
            let vs = cube.faceVerts(f).map { split.addVertex(cube.positions[Int($0)], flags: EditMesh.Flag.select) }
            split.addFace(vs)
        }
        var w = EditMesh(split)
        w.flushSelection(from: .vertex)
        XCTAssertEqual(w.vertexCount, 24)
        XCTAssertEqual(w.merge(.byDistance, distance: 1e-4), 16)
        XCTAssertEqual(w.vertexCount, 8)
        assertSound(w)
    }

    func testFillAndConnect() {
        var m = Primitive.cube.mesh()
        m.select(faces: [0])
        m.delete(.onlyFaces)
        // The hole's four vertices: one face again, facing out.
        let hole = MeshTopology(m)
        let boundary = (0..<m.vertexCount).filter { v in hole.edges(ofVertex: v).contains { hole.isBoundary(Int($0)) } }
        m.select(vertices: boundary)
        m.fill()
        XCTAssertEqual(m.faceCount, 6)
        assertSound(m)
        // J across a face's diagonal: two triangles.
        var c = Primitive.cube.mesh()
        let f = c.faceVerts(0)
        c.select(vertices: [Int(f[0]), Int(f[2])])
        c.connectVertices()
        XCTAssertEqual(c.faceCount, 7)
        assertSound(c)
    }

    func testSubdivide() {
        var m = cubeTop()
        m.subdivide()
        XCTAssertEqual(m.faceCount, 9)
        assertSound(m)
        var all = Primitive.cube.mesh()
        all.selectAll(true)
        all.subdivide()
        XCTAssertEqual(all.faceCount, 24)
        XCTAssertEqual(all.vertexCount, 26)
        assertSound(all)
    }

    func testNormals() {
        var m = Primitive.uvSphere.mesh()
        m.select(faces: [3, 70, 200, 301])
        m.flipNormals()
        XCTAssertFalse(m.isClosedManifold())
        m.selectAll(true)
        m.recalculateNormals()
        assertSound(m)
        // All inside out: back out.
        m.flipNormals(onlySelected: false)
        XCTAssertLessThan(volume(m), 0)
        m.selectAll(true)
        m.recalculateNormals()
        assertSound(m)
    }

    func testTriangulateAndBack() {
        var m = Primitive.cube.mesh()
        m.selectAll(true)
        m.triangulate()
        XCTAssertEqual(m.faceCount, 12)
        assertSound(m)
        m.selectAll(true)
        m.trianglesToQuads()
        XCTAssertEqual(m.faceCount, 6)
        assertSound(m)
    }

    func testDuplicateSeparateJoin() {
        var m = Primitive.cube.mesh()
        m.selectAll(true)
        m.duplicateSelection()
        XCTAssertEqual(m.faceCount, 12)
        XCTAssertEqual(m.vertexCount, 16)
        XCTAssertEqual(m.selectedFaces.count, 6)
        XCTAssertNil(m.validate())
        var s = cubeTop()
        let part = s.separateSelection()
        XCTAssertEqual(part?.faceCount, 1)
        XCTAssertEqual(part?.vertexCount, 4)
        XCTAssertEqual(s.faceCount, 5)
        XCTAssertEqual(s.vertexCount, 8)
        var j = Primitive.cube.mesh()
        var shift = matrix_identity_float4x4
        shift.columns.3 = [3, 0, 0, 1]
        j.join([Primitive.cube.mesh().transformed(by: shift)])
        XCTAssertEqual(j.faceCount, 12)
        XCTAssertEqual(j.vertexCount, 16)
        XCTAssertNil(j.validate())
        // A mirrored copy keeps facing out.
        let mirrored = Primitive.cube.mesh().transformed(by: float4x4(diagonal: [-1, 1, 1, 1]))
        assertSound(mirrored)
    }

    func testMarksAndShading() {
        var m = Primitive.cube.mesh()
        m.select(edges: [0, 1])
        m.markEdges(EditMesh.Flag.seam, true)
        m.setCrease(0.5)
        XCTAssertEqual(m.edgeFlags.filter { $0 & EditMesh.Flag.seam != 0 }.count, 2)
        XCTAssertEqual(m.edgeCrease.filter { $0 == 0.5 }.count, 2)
        // Flags survive an operation that remakes the mesh.
        m.select(faces: [5])
        m.inset(thickness: 0.1)
        XCTAssertEqual(m.edgeFlags.filter { $0 & EditMesh.Flag.seam != 0 }.count, 2)
        var s = Primitive.uvSphere.mesh()
        s.autoSmooth(angle: 30 * .pi / 180)
        XCTAssertEqual(s.edgeFlags.filter { $0 & EditMesh.Flag.sharp != 0 }.count, 0)
        var c = Primitive.cube.mesh()
        c.autoSmooth(angle: 30 * .pi / 180)
        XCTAssertEqual(c.edgeFlags.filter { $0 & EditMesh.Flag.sharp != 0 }.count, 12)
    }
}
