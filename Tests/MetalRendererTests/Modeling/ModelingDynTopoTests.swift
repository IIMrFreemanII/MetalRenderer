import Metal
import XCTest
import simd
@testable import EngineCore
@testable import Modeling

/// Dynamic topology, done in place: the layout and the lists stay right through many refinements (leaves moving and
/// splitting), the surface stays closed (next to hidden triangles too), a stroke undoes and redoes exactly, packing
/// keeps the shape, and the viewport's buffers follow.
final class ModelingDynTopoTests: XCTestCase {
    private func sphere(_ level: Int) -> SculptMesh {
        SculptMesh(Primitives.icoSphere(subdivisions: level, radius: 1), leafSize: 64)
    }

    private func closed(_ m: SculptMesh, file: StaticString = #filePath, line: UInt = #line) {
        let mesh = m.editMesh()
        XCTAssertNil(mesh.validate(), file: file, line: line)
        XCTAssertTrue(mesh.isClosedManifold(), file: file, line: line)
    }

    /// Every array, to compare states exactly (normals are made again, so not them).
    private struct State: Equatable {
        var position: [SIMD4<Float>], source: [Int32], owner: [Int32], indices: [UInt32], face: [Int32], sets: [Int32], hidden: [Bool]
        var lists: [[Int32]], nodes: [[Int32]], leaves: [Int32]

        init(_ m: SculptMesh) {
            position = m.position; source = m.source; owner = m.owner; indices = m.indices
            face = m.triangleFace; sets = m.faceSet; hidden = m.hidden
            lists = [m.vtStart, m.vtEnd, m.vtList, m.vnStart, m.vnEnd, m.vnList]
            nodes = m.nodes.map { [$0.left, $0.right, $0.parent, $0.triStart, $0.triCount, $0.triCapacity, $0.vertStart, $0.vertCount,
                                   $0.vertCapacity, $0.vtRegion, $0.vtCapacity, $0.vnRegion, $0.vnCapacity] }
            leaves = m.leaves
        }
    }

    /// The live triangles as their corners' positions, in an order of their own (the same shape whatever the numbering).
    private func shape(_ m: SculptMesh) -> [[Float]] {
        var out: [[Float]] = []
        for l in m.leaves {
            let n = m.nodes[Int(l)]
            for t in Int(n.triStart)..<Int(n.triStart + n.triCount) {
                var c = (0..<3).map { m.position[Int(m.indices[3 * t + $0])] }
                let first = (0..<3).min { lexicographic(c[$0], c[$1]) }!
                c = (0..<3).map { c[(first + $0) % 3] }
                out.append(c.flatMap { [$0.x, $0.y, $0.z] })
            }
        }
        return out.sorted { $0.lexicographicallyPrecedes($1) }
    }

    private func lexicographic(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool { [a.x, a.y, a.z].lexicographicallyPrecedes([b.x, b.y, b.z]) }

    func testRefinesInPlace() throws {
        // Fine detail under the brush: more triangles there, still a closed surface, the layout and lists right.
        let m = sphere(2)
        let before = m.triangleCount
        let change = try XCTUnwrap(DynTopo.refine(m, centre: [0, 1, 0], radius: 0.6, detail: 0.08))
        XCTAssertNil(m.check())
        XCTAssertGreaterThan(m.triangleCount, before * 2)
        XCTAssertFalse(change.leaves.isEmpty)
        XCTAssertFalse(change.triangles.isEmpty)
        closed(m)
        // The far side untouched.
        let bottom = (0..<m.vertexCount).filter { m.owner[$0] >= 0 }.min { m.position[$0].y < m.position[$1].y }!
        XCTAssertEqual(m.position[bottom].y, -1, accuracy: 1e-5)
        // Coarse detail: edges collapsed, fewer triangles, still closed.
        let dense = sphere(4)
        let many = dense.triangleCount
        XCTAssertNotNil(DynTopo.refine(dense, centre: [0, 1, 0], radius: 0.6, detail: 0.3))
        XCTAssertNil(dense.check())
        XCTAssertLessThan(dense.triangleCount, many)
        closed(dense)
    }

    func testStrokeMovesAndSplitsLeaves() {
        // A long stroke of dabs, each followed by refinement: leaves outgrow their room and split, and after every
        // step the lists are what the triangles make.
        let m = sphere(3)
        let leaves = m.leaves.count, triangles = m.triangleCount
        var brush = SculptBrush(kind: .draw)
        brush.symmetry = [true, false, false]
        let stroke = SculptStroke(mesh: m, brush: brush)
        stroke.record.beginLayout(m)
        for i in 0..<40 {
            let a = Float(i) / 39 * 2.4 - 1.2
            let q = simd_normalize(SIMD3<Float>(sin(a) * 0.8, 1, cos(a) * 0.3))
            stroke.move(to: q, radius: 0.3, strength: 0.4)
            for mirror in stroke.mirrors { DynTopo.refine(m, centre: q * mirror, radius: 0.3, detail: 0.04, record: stroke.record) }
            if let problem = m.check(boxes: false) { XCTFail("step \(i): \(problem)"); return }
        }
        XCTAssertGreaterThan(m.leaves.count, leaves)
        XCTAssertGreaterThan(m.triangleCount, triangles * 3)
        closed(m)
    }

    func testNextToHiddenTriangles() {
        // Hidden triangles aren't refined, and the edges they share aren't split: no cracks next to them.
        let m = sphere(3)
        for l in m.leaves {
            let n = m.nodes[Int(l)]
            for t in Int(n.triStart)..<Int(n.triStart + n.triCount) {
                let c = (0..<3).map { m.position[Int(m.indices[3 * t + $0])].x }.reduce(0, +) / 3
                m.hidden[t] = c > 0.1
            }
        }
        let hidden = m.hidden.filter { $0 }.count
        for i in 0..<6 { DynTopo.refine(m, centre: simd_normalize(SIMD3(Float(i) * 0.05, 1, 0)), radius: 0.6, detail: 0.05) }
        XCTAssertNil(m.check())
        closed(m)
        XCTAssertEqual(m.hidden.filter { $0 }.count, hidden)
    }

    func testStrokeUndoesAndRedoes() {
        let m = sphere(3)
        let before = State(m)
        let stroke = SculptStroke(mesh: m, brush: SculptBrush(kind: .clayStrips))
        stroke.record.beginLayout(m)
        for i in 0..<25 {
            let q = simd_normalize(SIMD3<Float>(Float(i) * 0.06 - 0.7, 1, 0.2))
            stroke.move(to: q, radius: 0.3, strength: 0.5)
            for mirror in stroke.mirrors { DynTopo.refine(m, centre: q * mirror, radius: 0.3, detail: 0.035, record: stroke.record) }
        }
        let after = State(m)
        XCTAssertNotEqual(before, after)
        stroke.record.swap(into: m)
        XCTAssertEqual(State(m), before)
        XCTAssertNil(m.check())
        stroke.record.swap(into: m)
        XCTAssertEqual(State(m), after)
        XCTAssertNil(m.check(boxes: false))
        // A plain stroke after it still undoes by its leaves.
        let plain = SculptStroke(mesh: m, brush: SculptBrush(kind: .draw))
        plain.dab(at: [0, 1, 0], radius: 0.3, strength: 1)
        plain.record.swap(into: m)
        XCTAssertEqual(State(m).position, after.position)
    }

    func testCompactionKeepsTheShape() {
        let m = sphere(3)
        for i in 0..<30 { DynTopo.refine(m, centre: simd_normalize(SIMD3(Float(i) * 0.05 - 0.75, 1, 0)), radius: 0.3, detail: 0.03) }
        let shape = shape(m)
        let slots = m.triangleSlots
        m.compact()
        XCTAssertNil(m.check())
        XCTAssertEqual(self.shape(m), shape)
        XCTAssertLessThan(m.triangleSlots, slots)
        // It refines on from there.
        XCTAssertNotNil(DynTopo.refine(m, centre: [0, -1, 0], radius: 0.4, detail: 0.05))
        XCTAssertNil(m.check())
        closed(m)
    }

    func testViewportBuffersFollow() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let m = sphere(3)
        let drawing = SculptDrawing(device: device)
        _ = drawing.prepare(m)
        _ = drawing.prepare(m)
        let stroke = SculptStroke(mesh: m, brush: SculptBrush(kind: .draw))
        stroke.record.beginLayout(m)
        for i in 0..<20 {
            let q = simd_normalize(SIMD3<Float>(Float(i) * 0.07 - 0.7, 1, 0))
            stroke.move(to: q, radius: 0.3, strength: 0.5)
            drawing.markDirty(stroke.dirty)
            stroke.dirty.removeAll()
            for mirror in stroke.mirrors {
                if let change = DynTopo.refine(m, centre: q * mirror, radius: 0.3, detail: 0.04, record: stroke.record) {
                    drawing.markDirty(change.leaves)
                    drawing.markTriangles(change.triangles)
                }
            }
            // Both buffers in turn hold the mesh.
            for _ in 0..<2 {
                let drawn = drawing.prepare(m)
                XCTAssertEqual(drawn.indexCount, m.indices.count)
                let ix = try XCTUnwrap(drawn.indices).contents().bindMemory(to: UInt32.self, capacity: m.indices.count)
                let vx = try XCTUnwrap(drawn.vertices).contents().bindMemory(to: ViewVertex.self, capacity: m.vertexCount)
                for k in 0..<m.indices.count where ix[k] != m.indices[k] { XCTFail("step \(i): index \(k)"); return }
                for l in m.leaves {
                    let n = m.nodes[Int(l)]
                    for k in (3 * Int(n.triStart))..<(3 * Int(n.triStart + n.triCount)) {
                        let v = Int(m.indices[k]), p = m.position[v]
                        if vx[v].x != p.x || vx[v].y != p.y || vx[v].z != p.z { XCTFail("step \(i): vertex \(v)"); return }
                    }
                }
            }
        }
    }
}
