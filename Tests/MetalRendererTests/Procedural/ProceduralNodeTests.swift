import XCTest
import simd
@testable import EngineCore
@testable import Modeling
@testable import Procedural

/// Every node kind: counts, shapes and the attributes they make or carry.
final class ProceduralNodeTests: XCTestCase {
    private let cooker = ProcCooker(environment: ProcEnvironment(file: { _ in nil }, stamp: { _ in 0 }))

    /// A chain: each (kind, params) wired into the next; the last one's geometry.
    private func chain(_ steps: [(ProcNodeKind, [String: ProcParam])], file: StaticString = #filePath, line: UInt = #line) -> ProcGeo {
        var g = ProcGraph()
        var last: String?
        for (kind, params) in steps {
            let id = g.add(kind, params: params)
            if let last { g.link(last, to: id) }
            last = id
        }
        g.setDisplay(last!)
        switch cooker.cook(g, last!) {
        case .success(let geo):
            XCTAssertNil(geo.validate(), file: file, line: line)
            return geo
        case .failure(let e):
            XCTFail("cook failed: \(e.message) at \(e.node)", file: file, line: line)
            return ProcGeo()
        }
    }

    private func cookError(_ steps: [(ProcNodeKind, [String: ProcParam])]) -> String? {
        var g = ProcGraph()
        var last: String?
        for (kind, params) in steps {
            let id = g.add(kind, params: params)
            if let last { g.link(last, to: id) }
            last = id
        }
        if case .failure(let e) = cooker.cook(g, last!) { return e.message }
        return nil
    }

    private func volume(_ g: ProcGeo) -> Float {
        var v: Float = 0
        for p in 0..<g.primCount where g.isPolygon(p) {
            let r = g.vertexRange(p)
            let o = g.P[Int(g.vertexPoint[r.lowerBound])]
            for k in (r.lowerBound + 1)..<(r.upperBound - 1) {
                v += simd_dot(o, simd_cross(g.P[Int(g.vertexPoint[k])], g.P[Int(g.vertexPoint[k + 1])])) / 6
            }
        }
        return v
    }

    func testGenerators() {
        let box = chain([(.box, ["divs": .vec3([2, 1, 1])])])
        XCTAssertEqual(box.primCount, 10)
        XCTAssertEqual(box.pointCount, 12)
        XCTAssertEqual(volume(box), 1, accuracy: 1e-5)   // closed, fronts out
        let grid = chain([(.grid, ["rows": .int(3), "cols": .int(4), "size": .vec2([3, 2])])])
        XCTAssertEqual(grid.pointCount, 12)
        XCTAssertEqual(grid.primCount, 6)
        XCTAssertEqual(grid.primNormal(0).y, 1, accuracy: 1e-5)
        XCTAssertEqual(grid.bounds.hi.x - grid.bounds.lo.x, 3, accuracy: 1e-5)
        let sphere = chain([(.sphere, ["rad": .vec3([2, 2, 2])])])
        XCTAssertGreaterThan(volume(sphere), 30)  // 4/3 π 8 ≈ 33.5, a bit less as polygons
        let tube = chain([(.tube, ["cols": .int(8)])])
        XCTAssertEqual(tube.primCount, 10)
        XCTAssertGreaterThan(volume(tube), 0)
        let cone = chain([(.tube, ["rad": .vec2([0, 1]), "cols": .int(8)])])
        XCTAssertEqual(cone.pointCount, 9)
        XCTAssertGreaterThan(volume(cone), 0)
        let circle = chain([(.circle, ["divs": .int(6)])])
        XCTAssertEqual(circle.primCount, 1)
        XCTAssertEqual(circle.primSize(0), 6)
        let arc = chain([(.circle, ["arc": .string("open"), "endangle": .float(180), "divs": .int(4)])])
        XCTAssertFalse(arc.primClosed[0])
        XCTAssertEqual(arc.pointCount, 5)
        let line = chain([(.line, ["points": .int(5), "dist": .float(2)])])
        XCTAssertEqual(line.P.last!.y, 2, accuracy: 1e-6)
        let add = chain([(.add, ["points": .points([[0, 0, 0], [1, 0, 0], [1, 1, 0]]), "connect": .string("closed")])])
        XCTAssertEqual(add.primCount, 1)
        XCTAssertTrue(add.primClosed[0])
        XCTAssertGreaterThan(volume(chain([(.torus, [:])])), 0)
    }

    func testTransformAndCopies() {
        let moved = chain([(.box, [:]), (.transform, ["t": .vec3([1, 2, 3]), "s": .vec3([2, 2, 2])])])
        XCTAssertEqual(moved.bounds.centroid, [1, 2, 3])
        XCTAssertEqual(volume(moved), 8, accuracy: 1e-4)
        // A mirroring scale keeps the fronts outside.
        let flipped = chain([(.box, [:]), (.transform, ["s": .vec3([-1, 1, 1])])])
        XCTAssertEqual(volume(flipped), 1, accuracy: 1e-5)
        // Only the group's points move.
        let half = chain([(.box, [:]), (.groupcreate, ["grouptype": .string("points"), "usebounds": .bool(true),
                                                        "boundmin": .vec3([0, -1, -1]), "boundmax": .vec3([1, 1, 1])]),
                          (.transform, ["group": .string("group1"), "t": .vec3([1, 0, 0])])])
        XCTAssertEqual(half.bounds.hi.x, 1.5, accuracy: 1e-6)
        XCTAssertEqual(half.bounds.lo.x, -0.5, accuracy: 1e-6)
        let copies = chain([(.box, [:]), (.copyxform, ["ncy": .int(3), "t": .vec3([2, 0, 0])])])
        XCTAssertEqual(copies.primCount, 18)
        XCTAssertEqual(copies.bounds.hi.x, 4.5, accuracy: 1e-5)
        XCTAssertEqual(copies.prims.ints("copynum")?.last, 2)
        let mirrored = chain([(.box, [:]), (.transform, ["t": .vec3([0.5, 0, 0])]), (.mirror, [:])])
        // Two boxes touching at x = 0: the seam's points shared.
        XCTAssertEqual(mirrored.primCount, 12)
        XCTAssertEqual(mirrored.pointCount, 12)
        XCTAssertEqual(volume(mirrored), 2, accuracy: 1e-4)
    }

    func testMergeAndSwitch() {
        var g = ProcGraph()
        let a = g.add(.box), b = g.add(.sphere), m = g.add(.merge), s = g.add(.switchnode, params: ["input": .int(1)])
        g.link(a, to: m, 0); g.link(b, to: m, 1)
        g.link(a, to: s, 0); g.link(b, to: s, 1)
        let merged = try! cooker.cook(g, m).get()
        XCTAssertEqual(merged.primCount, 6 + (try! cooker.cook(g, b).get()).primCount)
        let switched = try! cooker.cook(g, s).get()
        XCTAssertEqual(switched, try! cooker.cook(g, b).get())
    }

    func testPolyExtrude() {
        // One face of a box out by 1: 4 sides more, the box a unit longer.
        let one = chain([(.box, [:]), (.groupcreate, ["usenormal": .bool(true), "dir": .vec3([0, 1, 0])]),
                         (.polyextrude, ["group": .string("group1"), "dist": .float(1)])])
        XCTAssertEqual(one.primCount, 10)
        XCTAssertEqual(one.pointCount, 12)
        XCTAssertEqual(one.bounds.hi.y, 1.5, accuracy: 1e-5)
        XCTAssertEqual(volume(one), 2, accuracy: 1e-4)
        XCTAssertEqual(one.prims.group("extrudeFront")?.filter { $0 }.count, 1)
        XCTAssertEqual(one.prims.group("extrudeSide")?.filter { $0 }.count, 4)
        // A grid's quads, connected: one front, sides only round the outside; individually: walls round each.
        let connected = chain([(.grid, ["rows": .int(3), "cols": .int(3)]), (.polyextrude, ["dist": .float(0.5), "divs": .int(2)])])
        XCTAssertEqual(connected.primCount, 4 + 8 * 2)
        let individual = chain([(.grid, ["rows": .int(3), "cols": .int(3)]), (.polyextrude, ["dist": .float(0.5), "split": .string("individual"), "inset": .float(0.1)])])
        XCTAssertEqual(individual.primCount, 4 + 16)
        // Attributes ride along: a primitive attribute on the sides and fronts.
        let carried = chain([(.box, [:]), (.attribcreate, ["name": .string("tag"), "class": .string("primitive"), "type": .string("int"), "value": .vec4([7, 0, 0, 0])]),
                             (.polyextrude, ["dist": .float(0.2)])])
        XCTAssertTrue(carried.prims.ints("tag")!.allSatisfy { $0 == 7 })
    }

    func testModellerOperations() {
        let sub = chain([(.box, [:]), (.attribcreate, ["name": .string("w"), "value": .vec4([3, 0, 0, 0])]), (.subdivide, ["iterations": .int(2)])])
        XCTAssertEqual(sub.primCount, 96)
        XCTAssertTrue(sub.points.floats("w")!.allSatisfy { $0 == 3 })
        var g = ProcGraph()
        let a = g.add(.box), b = g.add(.sphere, params: ["rad": .vec3([0.7, 0.7, 0.7])]), bool = g.add(.boolean)
        g.link(a, to: bool, 0); g.link(b, to: bool, 1)
        let diff = try! cooker.cook(g, bool).get()
        XCTAssertNil(diff.validate())
        XCTAssertLessThan(volume(diff), 1)
        XCTAssertGreaterThan(volume(diff), 0)
        let bevel = chain([(.box, [:]), (.polybevel, ["dist": .float(0.1)])])
        XCTAssertGreaterThan(bevel.primCount, 6)
        let reduced = chain([(.sphere, ["rows": .int(30), "cols": .int(40)]), (.polyreduce, ["percentage": .float(25)])])
        XCTAssertLessThan(reduced.primCount, 30 * 40 * 2 / 3)
        let thick = chain([(.grid, ["rows": .int(2), "cols": .int(2)]), (.thicken, ["thickness": .float(0.1)])])
        XCTAssertEqual(thick.primCount, 6)
        let unwrapped = chain([(.box, [:]), (.uvunwrap, [:])])
        XCTAssertNotNil(unwrapped.vertices.vectors2("uv"))
        XCTAssertTrue(unwrapped.vertices.vectors2("uv")!.allSatisfy { all($0 .>= -1e-4) && all($0 .<= 1.0001) })
    }

    func testTopologyCleanups() {
        let tris = chain([(.box, [:]), (.divide, [:])])
        XCTAssertEqual(tris.primCount, 12)
        XCTAssertTrue((0..<12).allSatisfy { tris.primSize($0) == 3 })
        let faceted = chain([(.box, [:]), (.facet, [:])])
        XCTAssertEqual(faceted.pointCount, 24)
        let fused = chain([(.box, [:]), (.facet, [:]), (.fuse, [:])])
        XCTAssertEqual(fused.pointCount, 8)
        XCTAssertEqual(fused.primCount, 6)
        let collapsed = chain([(.box, [:]), (.fuse, ["dist": .float(5)])])
        XCTAssertEqual(collapsed.primCount, 0)
        XCTAssertEqual(chain([(.box, [:]), (.reverse, [:])]).primNormal(0), -chain([(.box, [:])]).primNormal(0))
        let smooth = chain([(.box, ["divs": .vec3([4, 4, 4])]), (.smooth, ["iterations": .int(20)])])
        XCTAssertLessThan(smooth.bounds.hi.x, 0.5)
    }

    func testNormals() {
        let v = chain([(.box, [:]), (.normal, [:])])
        XCTAssertEqual(v.vertices.vectors3("N")?.count, 24)
        // A box's corners are sharp at 60°: each vertex has its face's normal.
        XCTAssertEqual(v.vertices.vectors3("N")![0], v.primNormal(0))
        let p = chain([(.box, [:]), (.normal, ["type": .string("points")])])
        XCTAssertEqual(simd_length(p.points.vectors3("N")![0]), 1, accuracy: 1e-5)
        XCTAssertNil(p.vertices.vectors3("N"))
        let mesh = p.editMesh().mesh
        XCTAssertTrue(mesh.faceFlags.allSatisfy { $0 & EditMesh.Flag.smooth != 0 })
    }

    func testAttributes() {
        let created = chain([(.box, [:]), (.attribcreate, ["name": .string("Cd"), "type": .string("vector3"), "value": .vec4([1, 0, 0, 0])])])
        XCTAssertEqual(created.points.vectors3("Cd")?.first, [1, 0, 0])
        let named = chain([(.box, [:]), (.attribcreate, ["name": .string("kind"), "class": .string("primitive"), "type": .string("string"), "string": .string("wall")])])
        XCTAssertEqual(named.prims["kind"]?.string(5), "wall")
        let deleted = chain([(.box, [:]), (.attribcreate, ["name": .string("tmp1")]), (.attribdelete, ["ptdel": .string("tmp*")])])
        XCTAssertNil(deleted.points["tmp1"])
        let renamed = chain([(.box, [:]), (.attribcreate, ["name": .string("a")]), (.attribrename, ["from": .string("a"), "to": .string("b")])])
        XCTAssertNotNil(renamed.points["b"])
        let r1 = chain([(.box, [:]), (.attribrandomize, ["seed": .int(4)])])
        let r2 = chain([(.box, [:]), (.attribrandomize, ["seed": .int(4)])])
        XCTAssertEqual(r1.points.vectors3("Cd"), r2.points.vectors3("Cd"))
        XCTAssertTrue(r1.points.vectors3("Cd")!.allSatisfy { all($0 .>= 0) && all($0 .<= 1) })
        let bumpy = chain([(.sphere, ["rows": .int(20), "cols": .int(30)]), (.attribnoise, ["op": .string("alongnormal"), "amp": .float(0.3), "freq": .float(2)])])
        let radii = bumpy.P.map { simd_length($0) }
        XCTAssertGreaterThan(radii.max()! - radii.min()!, 0.05)
        let promoted = chain([(.box, [:]), (.attribcreate, ["name": .string("w"), "value": .vec4([2, 0, 0, 0])]),
                              (.attribpromote, ["name": .string("w"), "from": .string("point"), "to": .string("detail"), "method": .string("sum")])])
        XCTAssertEqual(promoted.detail.floats("w"), [16])
        XCTAssertNil(promoted.points["w"])
        let measured = chain([(.box, [:]), (.measure, [:])])
        XCTAssertEqual(measured.prims.floats("area")?.first ?? 0, 1, accuracy: 1e-5)
        let colored = chain([(.box, [:]), (.color, ["mode": .string("ramp"), "rampattr": .string("P")])])
        XCTAssertEqual(colored.points.vectors3("Cd")?.count, 8)
    }

    func testConnectivityAndSort() {
        let pieces = chain([(.box, [:]), (.copyxform, ["ncy": .int(3), "t": .vec3([2, 0, 0])]), (.connectivity, [:])])
        XCTAssertEqual(Set(pieces.points.ints("class")!), [0, 1, 2])
        let prims = chain([(.box, [:]), (.copyxform, ["ncy": .int(2), "t": .vec3([2, 0, 0])]), (.connectivity, ["class": .string("primitive")])])
        XCTAssertEqual(prims.prims.ints("class"), [0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1])
        let sorted = chain([(.line, ["points": .int(5)]), (.sort, ["key": .string("y"), "reverse": .bool(true)])])
        XCTAssertEqual(sorted.P.first!.y, 1, accuracy: 1e-6)
        XCTAssertEqual(Array(sorted.primPoints(0)), [4, 3, 2, 1, 0])
    }

    func testGroupsAndBlast() {
        let top = chain([(.box, [:]), (.groupcreate, ["usenormal": .bool(true), "dir": .vec3([0, 1, 0])]), (.blast, ["group": .string("group1")])])
        XCTAssertEqual(top.primCount, 5)
        XCTAssertEqual(top.pointCount, 8)
        let kept = chain([(.box, [:]), (.groupcreate, ["usenormal": .bool(true), "dir": .vec3([0, 1, 0])]),
                          (.blast, ["group": .string("group1"), "negate": .bool(true), "removegrp": .bool(true)])])
        XCTAssertEqual(kept.primCount, 1)
        XCTAssertEqual(kept.pointCount, 4)
        XCTAssertNil(kept.prims.group("group1"))
        let points = chain([(.box, [:]), (.blast, ["group": .string("0"), "grouptype": .string("points")])])
        XCTAssertEqual(points.pointCount, 7)
        XCTAssertEqual(points.primCount, 3)
        let random = chain([(.grid, ["rows": .int(21), "cols": .int(21)]), (.groupcreate, ["userandom": .bool(true), "percent": .float(25)])])
        let share = Float(random.prims.group("group1")!.filter { $0 }.count) / 400
        XCTAssertEqual(share, 0.25, accuracy: 0.07)
    }

    func testErrors() {
        XCTAssertEqual(cookError([(.transform, [:])]), "Input 1 (Geometry) isn't connected")
        XCTAssertEqual(cookError([(.box, [:]), (.attribrename, ["from": .string("nope"), "to": .string("x")])]), "No point attribute \"nope\"")
        XCTAssertNotNil(cookError([(.box, [:]), (.blast, ["group": .string("@nope>1")])]))
        XCTAssertNotNil(cookError([(.file, ["file": .string("mesh:missing")])]))
    }
}
