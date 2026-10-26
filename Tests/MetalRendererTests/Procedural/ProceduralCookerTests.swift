import XCTest
import simd
@testable import EngineCore
@testable import Procedural

/// The network and its cooker: wiring rules, the cache (what an edit recooks), bypass, errors, promoted parameters,
/// the JSON.
final class ProceduralCookerTests: XCTestCase {
    private func cooker() -> ProcCooker { ProcCooker(environment: ProcEnvironment(file: { _ in nil }, stamp: { _ in 0 })) }

    /// box → transform → polyextrude.
    private func network() -> (ProcGraph, box: String, xform: String, extrude: String) {
        var g = ProcGraph()
        let box = g.add(.box)
        let xform = g.add(.transform)
        let extrude = g.add(.polyextrude)
        g.link(box, to: xform)
        g.link(xform, to: extrude)
        g.setDisplay(extrude)
        return (g, box, xform, extrude)
    }

    func testNamesWiresAndCycles() {
        var (g, box, xform, extrude) = network()
        XCTAssertEqual(g.nodes.map(\.name), ["box1", "transform1", "polyextrude1"])
        XCTAssertEqual(g.displayNode, extrude)
        XCTAssertFalse(g.link(extrude, to: box))        // boxes have no input
        XCTAssertFalse(g.link(extrude, to: xform))      // a cycle
        XCTAssertEqual(g.inputs(of: extrude), [xform])
        // Deleting the middle node wires around it.
        g.remove([xform])
        XCTAssertEqual(g.inputs(of: extrude), [box])
        // A merge's wires stay in order, inserted where asked.
        let m = g.add(.merge), s = g.add(.sphere), t = g.add(.torus)
        g.link(box, to: m, 0); g.link(s, to: m, 1); g.link(t, to: m, 1)
        XCTAssertEqual(g.inputs(of: m), [box, t, s])
        g.unlink(to: m, 0)
        XCTAssertEqual(g.inputs(of: m), [t, s])
        XCTAssertTrue(g.rename(m, to: "everything"))
        XCTAssertFalse(g.rename(s, to: "everything"))
    }

    func testEditsRecookOnlyBelow() throws {
        let c = cooker()
        var (g, box, xform, extrude) = network()
        _ = try c.cook(g, extrude).get()
        XCTAssertEqual(c.info[box]?.cached, false)
        // Same network again: everything from the cache.
        _ = try c.cook(g, extrude).get()
        XCTAssertEqual(c.info[extrude]?.cached, true)
        // An edit to the transform: the box stays cached, the two below recook.
        g.setParam(xform, "t", .vec3([0, 1, 0]))
        let moved = try c.cook(g, extrude).get()
        XCTAssertEqual(moved.bounds.centroid.y, 1, accuracy: 1e-5)
        XCTAssertEqual(c.info[extrude]?.cached, false)
        XCTAssertEqual(c.info[xform]?.cached, false)
        // Undo (the old value): cached again.
        g.setParam(xform, "t", .vec3(.zero))
        _ = try c.cook(g, extrude).get()
        XCTAssertEqual(c.info[extrude]?.cached, true)
        // Moving or renaming a node doesn't change its key.
        let k = c.key(g, extrude)
        g.nodes[2].at = [100, 100]
        g.rename(extrude, to: "pushed")
        XCTAssertEqual(c.key(g, extrude), k)
    }

    func testBypassAndSwitchKeys() throws {
        let c = cooker()
        var (g, _, xform, extrude) = network()
        g.setParam(xform, "t", .vec3([5, 0, 0]))
        g.nodes[g.index(of: xform)!].bypass = true
        XCTAssertEqual(try c.cook(g, extrude).get().bounds.centroid.x, 0, accuracy: 1e-5)
        // A Switch's key is its chosen input's: changing the other input doesn't recook it.
        var s = ProcGraph()
        let a = s.add(.box), b = s.add(.sphere), sw = s.add(.switchnode)
        s.link(a, to: sw, 0); s.link(b, to: sw, 1)
        let k = c.key(s, sw)
        s.setParam(b, "rows", .int(30))
        XCTAssertEqual(c.key(s, sw), k)
        s.setParam(sw, "input", .int(1))
        XCTAssertNotEqual(c.key(s, sw), k)
    }

    func testErrorsAreTheNodes() {
        let c = cooker()
        var g = ProcGraph()
        let box = g.add(.box)
        let bad = g.add(.attribrename, params: ["from": .string("missing"), "to": .string("x")])
        let below = g.add(.null)
        g.link(box, to: bad); g.link(bad, to: below)
        guard case .failure(let e) = c.cook(g, below) else { return XCTFail("should fail") }
        XCTAssertEqual(e.node, bad)
        XCTAssertNotNil(c.info[bad]?.error)
        XCTAssertEqual(c.info[below]?.error, "Input 1 has an error")
    }

    func testPromotedParametersAndJSON() throws {
        var (g, box, _, extrude) = network()
        g.interface = [PromotedParam("height", value: .float(0.2), span: 0...2, targets: [.init(node: "polyextrude1", param: "dist")])]
        let tall = g.applying(["height": .float(1.5)])
        XCTAssertEqual(tall.node(extrude)?.param("dist"), .float(1.5))
        XCTAssertEqual(g.applying([:]).node(extrude)?.param("dist"), .float(0.2))
        g.setParam(box, "size", .vec3([2, 1, 1]))
        g.nodes[0].template = true
        let data = try JSONEncoder().encode(g)
        let back = try JSONDecoder().decode(ProcGraph.self, from: data)
        XCTAssertEqual(back, g)
        // Unset parameters aren't written.
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"size\":{\"vec3\""))
        XCTAssertFalse(json.contains("divs"))
    }

    func testEverySpecIsWellFormed() {
        for kind in ProcNodeKind.allCases {
            let s = kind.spec
            XCTAssertFalse(s.title.isEmpty, kind.rawValue)
            XCTAssertEqual(Set(s.params.map(\.name)).count, s.params.count, "\(kind.rawValue) repeats a parameter")
            for p in s.params {
                if case .menu(let items) = p.ui { XCTAssertTrue(items.contains(p.value.string), "\(kind.rawValue).\(p.name)") }
                if let w = p.shown { XCTAssertNotNil(s.param(w.param), "\(kind.rawValue).\(p.name) shown by a missing parameter") }
            }
        }
    }
}
