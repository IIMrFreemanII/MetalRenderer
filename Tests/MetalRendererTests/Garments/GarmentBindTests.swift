import XCTest
import simd
@testable import Characters
@testable import Editors
@testable import EngineCore
@testable import Garments
@testable import Physics

/// Garments bound to bodies and worn (GarmentBinding, DressedCharacter), the drape carried across edits
/// (GarmentBuild.carry), the exports' formats, and the designer's model (its edits and undo).
final class GarmentBindTests: XCTestCase {
    /// A flat sheet over a box of a body: each sheet point a few millimetres out from its nearest face, wherever the
    /// body moves.
    func testABindingFollowsTheBody() {
        var body = SkinnedCharacter(name: "box", positions: [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]], normals: Array(repeating: [0, 0, 1], count: 4),
                                    uvs: Array(repeating: .zero, count: 4), indices: [0, 1, 2, 0, 2, 3], skin: Array(repeating: GPUSkinVertex(), count: 4),
                                    joints: [], jointNames: [], color: .one, boundsMin: .zero, boundsMax: .one, clips: [])
        var g = Garment(name: "Sheet")
        g.particleDistance = 0.1
        g.panels = [Panel(id: 0, name: "S", points: [PathPoint([0.2, 0.2]), PathPoint([0.8, 0.2]), PathPoint([0.8, 0.8]), PathPoint([0.2, 0.8])])]
        let build = GarmentBuild.make(g)
        let drape = build.rest2D.map { SIMD3($0.x, $0.y, 0.01) }
        let binding = GarmentBinding(build: build, positions: drape, body: body)
        for (a, b) in zip(binding.positions(on: body), drape) { XCTAssertEqual(simd_distance(a, b), 0, accuracy: 1e-4) }
        // The body moved up a metre: the sheet with it.
        body.positions = body.positions.map { $0 + [0, 1, 0] }
        for (a, b) in zip(binding.positions(on: body), drape) { XCTAssertEqual(simd_distance(a, b + [0, 1, 0]), 0, accuracy: 1e-4) }
        // Dressed: the body's two triangles, hidden under the sheet's points or not, and the sheet's after them.
        let dressed = DressedCharacter.dress(body, in: [binding], materialBase: 3)
        XCTAssertEqual(dressed.positions.count, 4 + build.particleCount)
        XCTAssertEqual(dressed.skin.count, dressed.positions.count)
        XCTAssertEqual(dressed.materials.count, dressed.indices.count / 3)
        XCTAssertTrue(dressed.materials.suffix(build.triangles.count / 3).allSatisfy { $0 == 3 })
    }

    /// A panel made a little longer keeps its drape where it was, and the new part follows on.
    func testTheDrapeIsCarriedAcrossAnEdit() {
        var g = Garment(name: "Carry")
        g.particleDistance = 0.04
        g.panels = [Panel(id: 0, name: "A", points: [PathPoint([0, 0]), PathPoint([0.4, 0]), PathPoint([0.4, 0.4]), PathPoint([0, 0.4])])]
        let old = GarmentBuild.make(g)
        // The old drape: the sheet lifted and turned up.
        let positions = old.rest2D.map { SIMD3($0.x, 1, -$0.y) }
        g.panels[0].points[2].p.y = 0.44
        g.panels[0].points[3].p.y = 0.44
        let new = GarmentBuild.make(g)
        let carried = new.carry(from: old, positions: positions)
        XCTAssertEqual(carried.count, new.particleCount)
        XCTAssertTrue(carried.allSatisfy { $0.x.isFinite })
        // (The panel's middle moved by 2 cm on the sheet: the carry is about the middles.)
        for (i, q) in carried.enumerated() where new.rest2D[i].y < 0.3 {
            XCTAssertEqual(q.y, 1, accuracy: 1e-4)
            XCTAssertEqual(q.x, new.rest2D[i].x, accuracy: 0.03)
        }
    }

    func testTheExportsAreTheirFormats() throws {
        var g = Garment(name: "Square")
        g.particleDistance = 0.05
        g.panels = [Panel(id: 0, name: "A", points: [PathPoint([0, 0]), PathPoint([0.3, 0]), PathPoint([0.3, 0.3]), PathPoint([0, 0.3])])]
        let b = GarmentBuild.make(g)
        let p = b.rest2D.map { SIMD3($0.x, $0.y, 0) }
        let mesh = GarmentExport.Mesh(build: b, positions: p, garment: g)
        let obj = GarmentExport.obj(mesh)
        XCTAssertEqual(obj.components(separatedBy: "\nv ").count - 1, b.particleCount)
        XCTAssertEqual(obj.components(separatedBy: "\nf ").count - 1, b.triangles.count / 3)
        let glb = try GarmentExport.glb(mesh)
        XCTAssertEqual(glb.prefix(4), Data("glTF".utf8))
        XCTAssertEqual(glb.count % 4, 0)
        let pc2 = GarmentExport.pc2([p, p])
        XCTAssertEqual(pc2.prefix(11), Data("POINTCACHE2".utf8))
        XCTAssertEqual(pc2.count, 32 + 2 * p.count * 12)
        let cache = GarmentExport.gcache([p, p.map { $0 + [0, 1, 0] }], triangles: b.triangles)
        let back = try XCTUnwrap(GarmentExport.readGCache(cache))
        XCTAssertEqual(back.frames.count, 2)
        XCTAssertEqual(back.triangles, b.triangles)
        XCTAssertEqual(back.frames[1][3].y, p[3].y + 1, accuracy: 1e-6)
    }

    /// The designer's edits are undone one at a time; a dart cuts the outline and sews its legs.
    func testTheDesignersEditsUndo() {
        let m = GarmentModel()
        let panels = m.garment.panels.count, seams = m.garment.seams.count
        let front = m.garment.panels.first { $0.name == "Front" }!
        let points = front.points.count
        m.addDart(panel: front.id, edge: 0, at: 0.5)
        XCTAssertEqual(m.garment.panel(id: front.id)!.points.count, points + 3)
        XCTAssertEqual(m.garment.seams.count, seams + 1)
        m.addPanel("Patch", [PathPoint([3, 0]), PathPoint([3.2, 0]), PathPoint([3.2, 0.2])])
        XCTAssertEqual(m.garment.panels.count, panels + 1)
        m.undo.undo()
        XCTAssertEqual(m.garment.panels.count, panels)
        m.undo.undo()
        XCTAssertEqual(m.garment.panel(id: front.id)!.points.count, points)
        XCTAssertEqual(m.garment.seams.count, seams)
        // A linked mirror follows its original's shape.
        m.selection = [front.id]
        m.duplicateSelection(mirrored: true)
        let mirror = m.garment.panels.last!
        XCTAssertEqual(mirror.mirrorOf, front.id)
        m.edit("Move a point") { g in g.panels[g.panelIndex(id: front.id)!].points[0].p.y -= 0.05 }
        let a = m.garment.panel(id: front.id)!, b = m.garment.panel(id: mirror.id)!
        XCTAssertEqual(a.bounds.hi.y - a.bounds.lo.y, b.bounds.hi.y - b.bounds.lo.y, accuracy: 1e-4)
    }
}
