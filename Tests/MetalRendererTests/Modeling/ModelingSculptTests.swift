import XCTest
import simd
@testable import EngineCore
@testable import Modeling

/// Sculpting: the tree's layout, raycasts, each brush's effect, masks, symmetry, undo, multires, remesh.
final class ModelingSculptTests: XCTestCase {
    private func sphere(_ level: Int = 4) -> SculptMesh {
        SculptMesh(Primitives.icoSphere(subdivisions: level, radius: 1), leafSize: 64)
    }

    private func radiusAt(_ m: SculptMesh, _ v: Int) -> Float {
        let p = m.position[v]
        return simd_length(SIMD3(p.x, p.y, p.z))
    }

    func testTreeOwnsEveryVertexOnce() {
        let m = sphere()
        XCTAssertGreaterThan(m.leaves.count, 4)
        var owned = [Int](repeating: 0, count: m.vertexCount)
        for l in m.leaves {
            let n = m.nodes[Int(l)]
            XCTAssertLessThanOrEqual(n.triCount, 64)
            for v in Int(n.vertStart)..<Int(n.vertStart + n.vertCount) { owned[v] += 1 }
            // Each owned vertex is a corner of one of the leaf's triangles.
            let tris = Set((Int(n.triStart)..<Int(n.triStart + n.triCount)).flatMap { t in (0..<3).map { Int(m.indices[3 * t + $0]) } })
            for v in Int(n.vertStart)..<Int(n.vertStart + n.vertCount) { XCTAssertTrue(tris.contains(v)) }
        }
        XCTAssertEqual(owned.filter { $0 != 1 }.count, 0)
        // The root box holds the sphere.
        XCTAssertEqual(m.bounds.hi.x, 1, accuracy: 1e-4)
    }

    func testRaycastAndSphereQuery() {
        let m = sphere()
        let hit = m.raycast(origin: [0, 0, 5], direction: [0, 0, -1])
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit!.t, 4, accuracy: 0.02)
        XCTAssertNil(m.raycast(origin: [0, 3, 5], direction: [0, 0, -1]))
        let near = m.leaves(inSphere: [0, 0, 1], radius: 0.2)
        XCTAssertFalse(near.isEmpty)
        XCTAssertLessThan(near.count, m.leaves.count)
    }

    func testDrawInflateSmoothFlatten() {
        // Draw at the top pushes the top out along the surface normal.
        let m = sphere()
        let top = (0..<m.vertexCount).max { m.position[$0].y < m.position[$1].y }!
        var brush = SculptBrush(kind: .draw)
        brush.symmetry = [false, false, false]
        let s = SculptStroke(mesh: m, brush: brush)
        s.dab(at: [0, 1, 0], radius: 0.4, strength: 1)
        XCTAssertGreaterThan(m.position[top].y, 1.01)
        XCTAssertFalse(s.dirty.isEmpty)
        // A vertex far from it didn't move.
        let bottom = (0..<m.vertexCount).min { m.position[$0].y < m.position[$1].y }!
        XCTAssertEqual(radiusAt(m, bottom), 1, accuracy: 1e-5)
        // Subtract: in.
        var sub = brush
        sub.subtract = true
        let m2 = sphere()
        SculptStroke(mesh: m2, brush: sub).dab(at: [0, 1, 0], radius: 0.4, strength: -1)
        XCTAssertLessThan(m2.position[top].y, 0.99)
        // Smooth flattens a bump back toward its neighbours.
        let before = m.position[top].y
        let smooth = SculptStroke(mesh: m, brush: SculptBrush(kind: .smooth))
        for _ in 0..<5 { smooth.dab(at: [0, 1.05, 0], radius: 0.4, strength: 1, smooth: true) }
        XCTAssertLessThan(m.position[top].y, before)
        // Flatten: the cap toward a plane, so the top comes down.
        let f = sphere()
        let flat = SculptStroke(mesh: f, brush: SculptBrush(kind: .flatten))
        for _ in 0..<10 { flat.dab(at: [0, 1, 0], radius: 0.5, strength: 1) }
        XCTAssertLessThan(f.position[top].y, 0.99)
        // Inflate: everything near moves out.
        let i = sphere()
        SculptStroke(mesh: i, brush: SculptBrush(kind: .inflate)).dab(at: [0, 1, 0], radius: 0.5, strength: 1)
        XCTAssertGreaterThan(radiusAt(i, top), 1.005)
    }

    func testMaskHoldsVerticesAndSymmetryMirrors() {
        let m = sphere()
        let top = (0..<m.vertexCount).max { m.position[$0].y < m.position[$1].y }!
        let mask = SculptStroke(mesh: m, brush: SculptBrush(kind: .mask))
        mask.dab(at: [0, 1, 0], radius: 0.3, strength: 1)
        XCTAssertEqual(m.position[top].w, 1, accuracy: 1e-5)
        let y = m.position[top].y
        SculptStroke(mesh: m, brush: SculptBrush(kind: .draw)).dab(at: [0, 1, 0], radius: 0.4, strength: 1)
        XCTAssertEqual(m.position[top].y, y, accuracy: 1e-6, "masked: it doesn't move")
        // X symmetry: a dab at +x moves the vertex at −x the same.
        let s = sphere()
        let right = (0..<s.vertexCount).max { s.position[$0].x < s.position[$1].x }!
        let left = (0..<s.vertexCount).min { s.position[$0].x < s.position[$1].x }!
        SculptStroke(mesh: s, brush: SculptBrush(kind: .draw)).dab(at: [1, 0, 0], radius: 0.4, strength: 1)
        XCTAssertEqual(s.position[right].x, -s.position[left].x, accuracy: 1e-4)
        XCTAssertGreaterThan(s.position[right].x, 1.01)
    }

    func testUndoSwapsLeavesBack() {
        let m = sphere()
        let original = m.position
        let s = SculptStroke(mesh: m, brush: SculptBrush(kind: .draw))
        s.move(to: [0, 1, 0], radius: 0.3, strength: 1)
        s.move(to: [0.5, 0.8, 0.2], radius: 0.3, strength: 1)
        XCTAssertNotEqual(m.position, original)
        let changed = m.position
        s.record.swap(into: m)
        XCTAssertEqual(m.position, original)
        s.record.swap(into: m)
        XCTAssertEqual(m.position, changed)
    }

    func testGrabFollowsTheMouse() {
        let m = sphere()
        let top = (0..<m.vertexCount).max { m.position[$0].y < m.position[$1].y }!
        var brush = SculptBrush(kind: .grab)
        brush.symmetry = [false, false, false]
        let s = SculptStroke(mesh: m, brush: brush)
        let start = m.position[top]
        s.move(to: SIMD3(start.x, start.y, start.z), radius: 0.3, strength: 1)
        s.move(to: SIMD3(start.x, start.y + 0.5, start.z), radius: 0.3, strength: 1)
        XCTAssertEqual(m.position[top].y, start.y + 0.5, accuracy: 0.02)
    }

    func testBackIntoTheMesh() {
        let ico = Primitives.icoSphere(subdivisions: 3, radius: 1)
        let m = SculptMesh(ico, leafSize: 64)
        XCTAssertTrue(m.matches(ico))
        SculptStroke(mesh: m, brush: SculptBrush(kind: .draw)).dab(at: [0, 1, 0], radius: 0.5, strength: 1)
        var out = ico
        m.write(into: &out)
        XCTAssertNil(out.validate())
        XCTAssertEqual(out.faceCount, ico.faceCount)
        let top = (0..<out.vertexCount).max { out.positions[$0].y < out.positions[$1].y }!
        XCTAssertGreaterThan(out.positions[top].y, 1.01)
        // The triangles as a mesh of their own (after a topology change).
        let rebuilt = m.editMesh()
        XCTAssertNil(rebuilt.validate())
        XCTAssertTrue(rebuilt.isClosedManifold())
    }

    func testMultiresLevels() {
        let cube = Primitive.cube.mesh()
        var r = MultiresData()
        Multires.addLevel(cube, &r)
        Multires.addLevel(cube, &r)
        XCTAssertEqual(r.levels, 2)
        let l2 = Multires.levelMesh(cube, r, level: 2)
        XCTAssertEqual(l2.faceCount, 96)
        // Sculpt level 2, store, read back: the bump is there; level 1 is unchanged.
        let s = Multires.sculptMesh(cube, r)!
        XCTAssertEqual(s.vertexCount, l2.vertexCount)
        let top = (0..<s.vertexCount).max { s.position[$0].y < s.position[$1].y }!
        let y0 = s.position[top].y
        SculptStroke(mesh: s, brush: SculptBrush(kind: .draw)).dab(at: SIMD3(s.position[top].x, s.position[top].y, s.position[top].z), radius: 0.5, strength: 1)
        Multires.store(s, level: 2, base: cube, into: &r)
        let after = Multires.levelMesh(cube, r, level: 2)
        XCTAssertGreaterThan(after.positions.map(\.y).max()!, y0 + 0.01)
        XCTAssertEqual(Multires.levelMesh(cube, r, level: 1).positions, CatmullClark.subdivide(cube).positions, "level 1 has no displacement")
        // Moving the base carries the detail along.
        var moved = cube
        for v in 0..<moved.vertexCount { moved.positions[v].y += 1 }
        moved.touch()
        let carried = Multires.levelMesh(moved, r, level: 2)
        XCTAssertEqual(carried.positions.map(\.y).max()!, after.positions.map(\.y).max()! + 1, accuracy: 1e-3)
    }

    func testVoxelRemesh() {
        let ico = Primitives.icoSphere(subdivisions: 3, radius: 1)
        let (tri, _) = ico.triangles()
        let remeshed = VoxelRemesh.remesh(positions: ico.positions, indices: tri.map { UInt32(ico.cornerVerts[Int($0)]) }, voxel: 0.1)
        XCTAssertNil(remeshed.validate())
        XCTAssertTrue(remeshed.isClosedManifold())
        XCTAssertGreaterThan(remeshed.faceCount, 500)
        // Quads, on the sphere.
        XCTAssertGreaterThan((0..<remeshed.faceCount).filter { remeshed.faceSize($0) == 4 }.count, remeshed.faceCount * 9 / 10)
        for p in remeshed.positions { XCTAssertEqual(simd_length(p), 1, accuracy: 0.05) }
    }

    func testDynamicTopology() throws {
        // Fine detail under the brush: more triangles there, still a closed surface.
        let m = SculptMesh(Primitives.icoSphere(subdivisions: 2, radius: 1), leafSize: 64)
        let refined = try XCTUnwrap(DynTopo.refine(m, centre: [0, 1, 0], radius: 0.6, detail: 0.08))
        XCTAssertGreaterThan(refined.triangleCount, m.triangleCount * 2)
        let mesh = refined.editMesh()
        XCTAssertNil(mesh.validate())
        XCTAssertTrue(mesh.isClosedManifold())
        // The far side untouched: its triangles as long as before.
        let bottom = (0..<refined.vertexCount).min { refined.position[$0].y < refined.position[$1].y }!
        XCTAssertEqual(refined.position[bottom].y, -1, accuracy: 1e-5)
        // Coarse detail: edges collapsed, fewer triangles, still closed.
        let dense = SculptMesh(Primitives.icoSphere(subdivisions: 4, radius: 1), leafSize: 64)
        let coarse = try XCTUnwrap(DynTopo.refine(dense, centre: [0, 1, 0], radius: 0.6, detail: 0.3))
        XCTAssertLessThan(coarse.triangleCount, dense.triangleCount)
        XCTAssertTrue(coarse.editMesh().isClosedManifold())
    }
}
