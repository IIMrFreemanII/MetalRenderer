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

    // MARK: Slide, bridge, spin

    func testEdgeSlide() throws {
        // A loop cut round the cube: its loop slides toward either side, staying on the cube.
        var m = Primitive.cube.mesh()
        m.loopCut(0)
        var slide = try XCTUnwrap(EdgeSlide(m))
        XCTAssertEqual(slide.chains, 1)
        XCTAssertEqual(slide.items.count, 4)
        XCTAssertTrue(slide.items.allSatisfy { $0.sideA != nil && $0.sideB != nil && $0.sideA != $0.sideB })
        let axes = slide.alignSides { SIMD2($0.x, $0.y) }
        XCTAssertGreaterThan(simd_length(axes.a - axes.b), 0)
        let corners = Primitive.cube.mesh().positions
        for (factor, lands) in [(Float(0.5), false), (1, true), (-1, true)] {
            var s = m
            slide.apply(to: &s, factor: factor)
            assertSound(s)
            XCTAssertEqual(volume(s), 8, accuracy: 1e-4, "on the cube's faces")
            if lands {
                for i in slide.items {
                    XCTAssertTrue(corners.contains { simd_distance($0, s.positions[Int(i.vertex)]) < 1e-5 }, "at the ring's edge's end")
                }
            }
        }
        // A vertex alone: along the edge the screen direction points down.
        var g = Primitives.grid(x: 2, y: 2, size: 2)
        let centre = (0..<g.vertexCount).first { simd_length(g.positions[$0]) < 1e-5 }!
        g.select(vertices: [centre])
        let lone = try XCTUnwrap(EdgeSlide(g))
        XCTAssertEqual(lone.items.first?.ends.count, 4)
        let project: (SIMD3<Float>) -> SIMD2<Float>? = { SIMD2($0.x, -$0.z) }
        lone.apply(to: &g, factor: 0, toward: [0.5, 0], project: project)
        XCTAssertEqual(g.positions[centre].x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(g.positions[centre].z, 0, accuracy: 1e-5)
        // Three selected edges at a corner have no two sides.
        var corner = Primitive.cube.mesh()
        let v0 = Int32(0)
        corner.select(edges: (0..<corner.edgeCount).filter { corner.edges[$0].x == v0 || corner.edges[$0].y == v0 })
        XCTAssertNil(EdgeSlide(corner))
    }

    func testBridgeEdgeLoops() {
        // Two circles of 8: a tube of 8 quads, every edge between the loops shared by two of them.
        var a = Primitives.circle(vertices: 8, radius: 1, fill: false)
        var up = matrix_identity_float4x4
        up.columns.3 = [0, 2, 0, 1]
        a.join([a.transformed(by: up)])
        a.selectAll(true)
        XCTAssertNil(a.bridgeEdgeLoops())
        XCTAssertNil(a.validate())
        XCTAssertEqual(a.faceCount, 8)
        XCTAssertTrue((0..<a.faceCount).allSatisfy { a.faceSize($0) == 4 })
        XCTAssertEqual(a.selectedFaces.count, 8)
        // Facing away from the tube's axis.
        for f in 0..<a.faceCount {
            let c = a.faceCenter(f)
            XCTAssertGreaterThan(simd_dot(a.faceNormal(f), SIMD3(c.x, 0, c.z)), 0)
        }
        // 8 and 12: triangles, one per step along either loop.
        var b = Primitives.circle(vertices: 8, radius: 1, fill: false)
        b.join([Primitives.circle(vertices: 12, radius: 1.5, fill: false).transformed(by: up)])
        b.selectAll(true)
        XCTAssertNil(b.bridgeEdgeLoops())
        XCTAssertNil(b.validate())
        XCTAssertEqual(b.faceCount, 20)
        // Two cubes' facing faces: they go, and the cubes become one closed solid.
        var two = Primitive.cube.mesh()
        var right = matrix_identity_float4x4
        right.columns.3 = [4, 0, 0, 1]
        two.join([Primitive.cube.mesh().transformed(by: right)])
        let facing = (0..<two.faceCount).filter { f in
            let c = two.faceCenter(f), n = two.faceNormal(f)
            return (abs(c.x - 1) < 1e-4 && n.x > 0.9) || (abs(c.x - 3) < 1e-4 && n.x < -0.9)
        }
        XCTAssertEqual(facing.count, 2)
        two.select(faces: facing)
        XCTAssertNil(two.bridgeEdgeLoops())
        assertSound(two)
        XCTAssertEqual(two.faceCount, 14)
        XCTAssertEqual(volume(two), 8 + 8 + 2 * 2 * 2, accuracy: 1e-3)
        // One loop: nothing to bridge.
        var one = Primitives.circle(vertices: 8, radius: 1, fill: false)
        one.selectAll(true)
        XCTAssertNotNil(one.bridgeEdgeLoops())
        XCTAssertEqual(one.faceCount, 0)
    }

    func testSpin() {
        // A profile of two edges at x = 1, a full turn round y: a tube, its faces out.
        func profile(_ points: [SIMD3<Float>]) -> EditMesh {
            var d = EditMesh.Draft()
            for p in points { d.addVertex(p) }
            for i in 0..<(points.count - 1) { d.looseEdges.append(SIMD2(Int32(i), Int32(i + 1))) }
            var m = EditMesh(d)
            m.selectAll(true)
            return m
        }
        var tube = profile([[1, 0, 0], [1, 1, 0], [1, 2, 0]])
        tube.spin(steps: 8, angle: 2 * .pi, centre: .zero, axis: [0, 1, 0])
        XCTAssertNil(tube.validate())
        XCTAssertEqual(tube.vertexCount, 24)
        XCTAssertEqual(tube.faceCount, 16)
        for f in 0..<tube.faceCount {
            let c = tube.faceCenter(f)
            XCTAssertGreaterThan(simd_dot(tube.faceNormal(f), SIMD3(c.x, 0, c.z)), 0)
        }
        XCTAssertEqual(tube.selectedVertices.count, 3, "the last step's (the first, closed)")
        // A quarter turn in 4 steps: 5 rows of 3.
        var quarter = profile([[1, 0, 0], [1, 1, 0], [1, 2, 0]])
        quarter.spin(steps: 4, angle: .pi / 2, centre: .zero, axis: [0, 1, 0])
        XCTAssertEqual(quarter.vertexCount, 15)
        XCTAssertEqual(quarter.faceCount, 8)
        // A half circle from pole to pole: a closed sphere (the poles stay single vertices).
        let half = (0...6).map { k -> SIMD3<Float> in let a = Float(k) / 6 * .pi; return [sin(a), cos(a), 0] }
        var sphere = profile(half)
        sphere.spin(steps: 12, angle: 2 * .pi, centre: .zero, axis: [0, 1, 0])
        assertSound(sphere)
        XCTAssertEqual(sphere.vertexCount, 2 + 5 * 12)
        // A face on its own, either way round: a closed solid with a cap at each end; a full turn: a ring (no caps).
        for angle in [Float.pi / 2, -.pi / 2] {
            var quad = EditMesh(positions: [[1, 0, 0], [2, 0, 0], [2, 1, 0], [1, 1, 0]], faces: [[0, 1, 2, 3]])
            quad.selectAll(true)
            quad.spin(steps: 4, angle: angle, centre: .zero, axis: [0, 1, 0])
            assertSound(quad)
            XCTAssertEqual(quad.faceCount, 2 + 4 * 4)
        }
        var ring = EditMesh(positions: [[1, 0, 0], [2, 0, 0], [2, 1, 0], [1, 1, 0]], faces: [[0, 1, 2, 3]])
        ring.selectAll(true)
        ring.spin(steps: 16, angle: 2 * .pi, centre: .zero, axis: [0, 1, 0])
        XCTAssertNil(ring.validate())
        XCTAssertTrue(ring.isClosedManifold())
        XCTAssertEqual(ring.eulerCharacteristic, 0, "a torus")
        XCTAssertGreaterThan(volume(ring), 0)
        XCTAssertEqual(ring.faceCount, 64)
    }
}
