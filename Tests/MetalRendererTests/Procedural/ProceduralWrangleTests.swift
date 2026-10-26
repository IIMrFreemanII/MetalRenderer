import XCTest
import simd
@testable import EngineCore
@testable import Procedural

/// Attribute Wrangle (Swift compiled at run time) and For-Each loops.
final class ProceduralWrangleTests: XCTestCase {
    private let cooker = ProcCooker(environment: ProcEnvironment(file: { _ in nil }, stamp: { _ in 0 }))

    private func chain(_ steps: [(ProcNodeKind, [String: ProcParam])]) -> Result<ProcGeo, ProcCookError> {
        var g = ProcGraph()
        var last: String?
        for (kind, params) in steps {
            let id = g.add(kind, params: params)
            if let last { g.link(last, to: id) }
            last = id
        }
        return cooker.cook(g, last!)
    }

    private func needCompiler() throws {
        if let p = WrangleCompiler.shared.problem() { throw XCTSkip(p) }
    }

    func testBindingsAreRewritten() {
        let (code, bindings) = WrangleSource.rewrite("@P.y += f@mass * @ptnum; v@up = {0,1,0}; s@name = \"a@b\" // @ignored", existing: { _ in nil })
        XCTAssertEqual(bindings.map(\.name), ["P", "mass", "up", "name"])
        XCTAssertEqual(bindings.map(\.type), [.vector3, .float, .vector3, .string])
        XCTAssertTrue(code.contains("_a_P.y += _a_mass * ptnum"))
        XCTAssertTrue(code.contains("\"a@b\""))
        XCTAssertTrue(code.contains("// @ignored"))
        // Types from the input when there is no prefix.
        XCTAssertEqual(WrangleSource.rewrite("@w = 1", existing: { $0 == "w" ? .int : nil }).bindings.first?.type, .int)
    }

    func testWrangleRunsSwift() throws {
        try needCompiler()
        let start = Date()
        let waved = try chain([(.grid, ["rows": .int(20), "cols": .int(20)]),
                               (.attribwrangle, ["snippet": .string("@P.y = sin(@P.x) * 2\nf@mass = Float(@ptnum)\nv@Cd = SIMD3(1, 0, 0)")])]).get()
        print("wrangle compiled and ran in \(Date().timeIntervalSince(start)) s")
        XCTAssertNil(waved.validate())
        XCTAssertEqual(waved.P[7].y, sin(waved.P[7].x) * 2, accuracy: 1e-5)
        XCTAssertEqual(waved.points.floats("mass")?[33], 33)
        XCTAssertEqual(waved.points.vectors3("Cd")?.last, [1, 0, 0])
        // The same snippet again: no compile.
        _ = try chain([(.grid, ["rows": .int(5), "cols": .int(5)]),
                       (.attribwrangle, ["snippet": .string("@P.y = sin(@P.x) * 2\nf@mass = Float(@ptnum)\nv@Cd = SIMD3(1, 0, 0)")])]).get()
        XCTAssertEqual(WrangleCompiler.shared.lastCompileSeconds, 0)
        // Primitives, a group, reading another input, adding and removing.
        var g = ProcGraph()
        let box = g.add(.box), sphere = g.add(.sphere)
        let w = g.add(.attribwrangle, params: ["class": .string("primitives"), "snippet": .string(
            "i@near = nearpoint(1, @P)\nif @primnum == 0 { removeprim(@primnum) }\nlet p = addpoint(SIMD3(0, 5, 0))\n_ = p")])
        g.link(box, to: w, 0); g.link(sphere, to: w, 1)
        let out = try cooker.cook(g, w).get()
        XCTAssertEqual(out.primCount, 5)
        XCTAssertEqual(out.pointCount, 8 + 6)   // a point added per primitive (the six ran before the removal)
        XCTAssertNotNil(out.prims.ints("near"))
        // A snippet's errors name its lines.
        guard case .failure(let e) = chain([(.box, [:]), (.attribwrangle, ["snippet": .string("@P.y += 1\nthis is not swift")])]) else {
            return XCTFail("bad Swift compiled")
        }
        XCTAssertTrue(e.message.contains("line 2"), e.message)
    }

    func testForEachPieces() throws {
        // Three boxes, each moved up by its piece number through a loop.
        var g = ProcGraph()
        let box = g.add(.box)
        let copies = g.add(.copyxform, params: ["ncy": .int(3), "t": .vec3([2, 0, 0])])
        let named = g.add(.connectivity, params: ["class": .string("primitive"), "name": .string("name")])
        let begin = g.add(.foreachbegin)
        let lift = g.add(.transform, params: ["t": .vec3([0, 1, 0])])
        let end = g.add(.foreachend)
        g.link(box, to: copies); g.link(copies, to: named); g.link(named, to: begin); g.link(begin, to: lift); g.link(lift, to: end)
        let out = try cooker.cook(g, end).get()
        XCTAssertEqual(out.primCount, 18)
        XCTAssertEqual(out.bounds.lo.y, 0.5, accuracy: 1e-5)
        // Feedback: the body applied three times over.
        g.setParam(end, "gather", .string("feedback"))
        g.setParam(end, "iterationmethod", .string("count"))
        g.setParam(end, "iterations", .int(3))
        let fed = try cooker.cook(g, end).get()
        XCTAssertEqual(fed.bounds.lo.y, 2.5, accuracy: 1e-5)
        XCTAssertEqual(fed.primCount, 18)
        // A point each: the body sees one point (a copy of a sphere on it, merged).
        var h = ProcGraph()
        let line = h.add(.line, params: ["points": .int(4)])
        let b2 = h.add(.foreachbegin)
        let ball = h.add(.sphere, params: ["rad": .vec3([0.1, 0.1, 0.1])])
        let cp = h.add(.copytopoints)
        let e2 = h.add(.foreachend, params: ["iterationmethod": .string("points")])
        h.link(line, to: b2); h.link(ball, to: cp, 0); h.link(b2, to: cp, 1); h.link(cp, to: e2)
        let balls = try cooker.cook(h, e2).get()
        XCTAssertEqual(balls.primCount, 4 * (try cooker.cook(h, ball).get()).primCount)
    }
}
