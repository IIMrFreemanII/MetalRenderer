import XCTest
import simd
@testable import EngineCore
@testable import Procedural

/// Parameter expressions (Sources/Procedural/Expr): the language, channels, the frame, keys, per-element parameters,
/// text expansion, and how networks with expressions are saved.
final class ProceduralExpressionTests: XCTestCase {
    private func environment(frame: Float = 1) -> ProcEnvironment {
        var e = ProcEnvironment(file: { _ in nil }, stamp: { _ in 0 })
        e.frame = frame
        return e
    }

    /// A context on a Transform whose input is `input` (a box of size 2 by default).
    private func context(frame: Float = 1, name: String = "transform3", input: ProcGeo? = nil) throws -> ProcExprContext {
        var g = ProcGraph()
        let box = g.add(.box, params: ["size": .vec3([2, 2, 2])])
        let geo = try input ?? ProcCooker(environment: environment()).cook(g, box).get()
        let node = ProcNode(.transform, id: "t", name: name)
        return ProcExprContext(graph: g, node: node, frame: frame, state: ProcExprState(), input: { $0 == 0 ? geo : nil },
                               find: { _ in throw ProcExprError("no other nodes here") })
    }

    private func value(_ source: String, frame: Float = 1, file: StaticString = #filePath, line: UInt = #line) -> Float {
        do { return try context(frame: frame).evaluate(source) } catch {
            XCTFail("\(source): \(error)", file: file, line: line)
            return .nan
        }
    }

    private func set(_ g: inout ProcGraph, _ id: String, _ channel: String, _ source: String) {
        g.nodes[g.index(of: id)!].expressions[channel] = source
    }

    private func name(_ g: ProcGraph, _ id: String) -> String { g.node(id)!.name }

    func testParsingAndPrecedence() {
        XCTAssertEqual(value("1 + 2 * 3"), 7)
        XCTAssertEqual(value("(1 + 2) * 3"), 9)
        XCTAssertEqual(value("-2 * -3"), 6)
        XCTAssertEqual(value("10 % 4"), 2)
        XCTAssertEqual(value("2 < 3 && 4 >= 4"), 1)
        XCTAssertEqual(value("1 == 2 || !0"), 1)
        XCTAssertEqual(value("3 != 3"), 0)
        XCTAssertEqual(value("1.5e1 + .5"), 15.5)
        for (bad, column) in [("1 +", 3), ("(1 + 2", 0), ("2 $", 2), ("@", 0)] {
            XCTAssertThrowsError(try ProcExpr.parse(bad), bad) { e in XCTAssertEqual((e as? ProcExprError)?.column, column, bad) }
        }
        XCTAssertThrowsError(try context().evaluate("nofunction(1)"))
        XCTAssertThrowsError(try context().evaluate("sin(1, 2)"))
    }

    func testFunctionsAndVariables() {
        XCTAssertEqual(value("sin(90)"), 1, accuracy: 1e-6)          // degrees, as hscript's
        XCTAssertEqual(value("cos(180)"), -1, accuracy: 1e-6)
        XCTAssertEqual(value("atan2(1, 1)"), 45, accuracy: 1e-5)
        XCTAssertEqual(value("deg(rad(30))"), 30, accuracy: 1e-5)
        XCTAssertEqual(value("fit(5, 0, 10, 0, 1)"), 0.5)
        XCTAssertEqual(value("fit(20, 0, 10, 0, 1)"), 1)              // clamped
        XCTAssertEqual(value("fit01(0.25, 10, 20)"), 12.5)
        XCTAssertEqual(value("clamp(5, 0, 2)"), 2)
        XCTAssertEqual(value("lerp(2, 4, 0.5)"), 3)
        XCTAssertEqual(value("smooth(0, 1, 0.5)"), 0.5)
        XCTAssertEqual(value("if(1, 2, 3)") + value("if(0, 2, 3)"), 5)
        XCTAssertEqual(value("round(2.5) + int(-2.7) + floor(-0.5) + ceil(0.2)"), 3 - 2 - 1 + 1)
        XCTAssertEqual(value("frac(2.25) + abs(-1) + sign(-3) + sqrt(16) + pow(2, 3) + min(1, 2) + max(1, 2)"), 0.25 + 1 - 1 + 4 + 8 + 1 + 2)
        XCTAssertEqual(value("$PI"), .pi)
        XCTAssertEqual(value("$F", frame: 12), 12)
        XCTAssertEqual(value("$FF", frame: 12.5), 12.5)
        XCTAssertEqual(value("$T", frame: 25), 1)
        XCTAssertEqual(value("$FPS"), 24)
        // The node's first input: a box of size 2 about the origin.
        XCTAssertEqual(value("$NPT"), 8)
        XCTAssertEqual(value("$NPR"), 6)
        XCTAssertEqual(value("$XMIN + $SIZEX * 10 + $CEX"), -1 + 20 + 0)
        XCTAssertEqual(value("npoints(0) + nprims(0)"), 14)
        XCTAssertEqual(value("bbox(0, D_YMAX) + bbox(0, D_ZSIZE)"), 3)
        XCTAssertEqual(value("centroid(0, D_Z)"), 0)
        XCTAssertEqual(abs(value("point(0, \"P\", 0, 0)")), 1)
        XCTAssertEqual(value("opdigits(\".\")"), 3)
        let r = value("rand(1)")
        XCTAssertTrue(r >= 0 && r < 1)
        XCTAssertEqual(r, value("rand(1)"))
        XCTAssertNotEqual(r, value("rand(2)"))
        XCTAssertThrowsError(try context().evaluate("npoints(1)"))      // nothing on the second input
        XCTAssertThrowsError(try context().evaluate("$OS"))             // text, not a number
    }

    func testChannels() throws {
        var g = ProcGraph()
        let box = g.add(.box, params: ["size": .vec3([3, 1, 1])])
        let xf = g.add(.transform)
        g.link(box, to: xf)
        g.interface = [PromotedParam("offset", value: .float(5), targets: [])]
        set(&g, xf, "tx", "ch(\"../\(name(g, box))/sizex\")")
        set(&g, xf, "ty", "ch(\"tx\") * 2")
        set(&g, xf, "tz", "ch(\"../offset\")")
        let cooker = ProcCooker(environment: environment())
        let b = try cooker.cook(g, xf).get().bounds
        XCTAssertEqual((b.lo + b.hi) / 2, SIMD3(3, 6, 5))
        XCTAssertEqual(cooker.info[xf]?.channels["tx"], 3)
        // An instance's override is what ../offset reads.
        let over = try cooker.cook(g.applying(["offset": .float(7)]), xf).get().bounds
        XCTAssertEqual((over.lo.z + over.hi.z) / 2, 7)
        // A loop through ch() fails, naming it.
        set(&g, box, "sizex", "ch(\"../\(name(g, xf))/tx\")")
        guard case .failure(let e) = cooker.cook(g, xf) else { return XCTFail("a ch() loop cooked") }
        XCTAssertTrue(e.message.contains("reads itself"), e.message)
    }

    func testSwitchByFrameAndChannel() throws {
        var g = ProcGraph()
        let box = g.add(.box), sphere = g.add(.sphere)
        let sw = g.add(.switchnode)
        g.link(box, to: sw, 0); g.link(sphere, to: sw, 1)
        set(&g, sw, "input", "$F % 2")
        let boxGeo = try ProcCooker(environment: environment()).cook(g, box).get()
        XCTAssertNotEqual(try ProcCooker(environment: environment(frame: 1)).cook(g, sw).get().pointCount, boxGeo.pointCount)
        XCTAssertEqual(try ProcCooker(environment: environment(frame: 2)).cook(g, sw).get().pointCount, boxGeo.pointCount)
        g.interface = [PromotedParam("pick", value: .int(0), targets: [])]
        set(&g, sw, "input", "ch(\"../pick\")")
        XCTAssertEqual(try ProcCooker(environment: environment()).cook(g, sw).get().pointCount, boxGeo.pointCount)
        // The pick comes before any cook: geometry is out of its reach.
        set(&g, sw, "input", "npoints(0) > 0")
        guard case .failure(let e) = ProcCooker(environment: environment()).cook(g, sw) else { return XCTFail("cooked") }
        XCTAssertTrue(e.message.contains("can't read geometry"), e.message)
    }

    func testKeys() {
        var g = ProcGraph()
        let box = g.add(.box), other = g.add(.box)
        let xf = g.add(.transform), still = g.add(.transform)
        g.link(box, to: xf); g.link(other, to: still)
        set(&g, xf, "tx", "$F * 0.1")
        let one = ProcCooker(environment: environment(frame: 1)), two = ProcCooker(environment: environment(frame: 2))
        XCTAssertEqual(one.key(g, box), two.key(g, box))
        XCTAssertEqual(one.key(g, still), two.key(g, still))
        XCTAssertNotEqual(one.key(g, xf), two.key(g, xf))
        // A node reading another's channel: its key follows that channel's expression and value.
        set(&g, still, "ty", "ch(\"../\(name(g, box))/sizey\")")
        let before = one.key(g, still)
        g.nodes[g.index(of: box)!].params["size"] = .vec3([1, 4, 1])
        XCTAssertNotEqual(one.key(g, still), before)
        let after = one.key(g, still)
        set(&g, box, "sizey", "2 + 2")
        XCTAssertNotEqual(one.key(g, still), after)
    }

    func testAttributeCreatePerElement() throws {
        var g = ProcGraph()
        let grid = g.add(.grid, params: ["rows": .int(7), "cols": .int(9)])
        let a = g.add(.attribcreate, params: ["name": .string("v"), "type": .string("vector3")])
        g.link(grid, to: a)
        set(&g, a, "valuex", "@P.x * 2 + $PT")
        set(&g, a, "valuey", "sin($PT * 10)")
        set(&g, a, "valuez", "ch(\"valuew\") + 1")    // (not per element: valuew as set, 0)
        let cooker = ProcCooker(environment: environment())
        let out = try cooker.cook(g, a).get()
        let v = try XCTUnwrap(out.points.vectors3("v"))
        for i in 0..<out.pointCount {
            XCTAssertEqual(v[i].x, out.P[i].x * 2 + Float(i))      // the same float operations: the same bits
            XCTAssertEqual(v[i].y, sin(Float(i) * 10 * (.pi / 180)))
            XCTAssertEqual(v[i].z, 1)
        }
        XCTAssertNil(try XCTUnwrap(cooker.info[a]?.channels["valuex"]))   // (per element)
        // On primitives: $PR, and @P is each one's centre.
        g.nodes[g.index(of: a)!].params["class"] = .string("primitive")
        set(&g, a, "valuex", "$PR")
        set(&g, a, "valuey", "@P.z")
        let prims = try cooker.cook(g, a).get()
        let pv = try XCTUnwrap(prims.prims.vectors3("v"))
        for p in 0..<prims.primCount {
            XCTAssertEqual(pv[p].x, Float(p))
            XCTAssertEqual(pv[p].y, prims.primCenter(p).z)
        }
    }

    func testGroupAndSortByExpression() throws {
        var g = ProcGraph()
        let grid = g.add(.grid, params: ["rows": .int(5), "cols": .int(5)])
        let grp = g.add(.groupcreate, params: ["groupname": .string("right"), "grouptype": .string("points"), "useexpr": .bool(true)])
        let sort = g.add(.sort, params: ["key": .string("expression")])
        g.link(grid, to: grp); g.link(grp, to: sort)
        set(&g, grp, "expression", "@P.x > 0")
        set(&g, sort, "expression", "-@P.x")
        let cooker = ProcCooker(environment: environment())
        let grouped = try cooker.cook(g, grp).get()
        XCTAssertEqual(grouped.points.group("right"), grouped.P.map { $0.x > 0 })
        let sorted = try cooker.cook(g, sort).get()
        XCTAssertEqual(sorted.P.map(\.x), sorted.P.map(\.x).sorted(by: >))
    }

    func testTextExpansion() throws {
        var g = ProcGraph()
        let grid = g.add(.grid)
        let a = g.add(.attribcreate, params: ["name": .string("piece`$F`")])
        let b = g.add(.attribcreate, params: ["name": .string("`chs(\"../\(name(g, a))/name\")`_$OS")])
        g.link(grid, to: a); g.link(a, to: b)
        let out = try ProcCooker(environment: environment(frame: 3)).cook(g, b).get()
        XCTAssertNotNil(out.points["piece3"])
        XCTAssertNotNil(out.points["piece3_\(name(g, b))"])
        // The frame is in the key of a node whose text reads it.
        XCTAssertNotEqual(ProcCooker(environment: environment(frame: 3)).key(g, a), ProcCooker(environment: environment(frame: 4)).key(g, a))
    }

    func testElementVariablesOnlyWherePerElement() {
        var g = ProcGraph()
        let box = g.add(.box)
        let xf = g.add(.transform)
        g.link(box, to: xf)
        set(&g, xf, "tx", "$PT")
        guard case .failure(let e) = ProcCooker(environment: environment()).cook(g, xf) else { return XCTFail("cooked") }
        XCTAssertTrue(e.message.contains("Attribute Create's Value"), e.message)
        XCTAssertTrue(e.message.hasPrefix("Translate"), e.message)
    }

    func testPlacedAssetsFrame() throws {
        var g = ProcGraph()
        let box = g.add(.box)
        set(&g, box, "sizex", "$F")
        let asset = ProcAsset(name: "Bar", graph: g)
        func width(_ frame: Float) throws -> Float {
            let p = try asset.cook([:], environment: environment(frame: frame)).get().rendered.positions.map(\.x)
            return (p.max() ?? 0) - (p.min() ?? 0)
        }
        XCTAssertEqual(try width(1), 1, accuracy: 1e-5)
        XCTAssertEqual(try width(3), 3, accuracy: 1e-5)
        XCTAssertNotEqual(asset.cacheName([:], environment: environment(frame: 1)), asset.cacheName([:], environment: environment(frame: 3)))
        XCTAssertEqual(ProcAssetReference("bar?frame=3").frame, 3)
        XCTAssertEqual(ProcAssetReference("bar").frame, 1)
    }

    func testSavedNetworks() throws {
        var g = ProcGraph()
        let box = g.add(.box)
        set(&g, box, "sizex", "$F")
        let back = try JSONDecoder().decode(ProcGraph.self, from: try JSONEncoder().encode(g))
        XCTAssertEqual(back, g)
        // A node without expressions writes none, and a file from before them reads with none.
        let plain = String(data: try JSONEncoder().encode(ProcNode(.box, id: "b")), encoding: .utf8)!
        XCTAssertFalse(plain.contains("expressions"))
        let old = try JSONDecoder().decode(ProcNode.self, from: Data(#"{"id":"b","kind":"box","at":[0,0]}"#.utf8))
        XCTAssertEqual(old.expressions, [:])
        // A promoted value wins over the target's expressions.
        g.interface = [PromotedParam("size", value: .vec3([2, 2, 2]), targets: [.init(node: name(g, box), param: "size")])]
        XCTAssertEqual(g.applying([:]).node(box)?.expressions, [:])
    }
}
