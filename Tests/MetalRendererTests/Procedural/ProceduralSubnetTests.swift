import XCTest
import simd
@testable import EngineCore
@testable import Modeling
@testable import Procedural

/// Networks in nodes (Sources/Procedural/Graph/ProcContents.swift): Subnetworks and Procedural Asset nodes cooked in
/// their own scope (inputs through Sub-Network Inputs, parameters read with `ch("../name")`, paths up and down), their
/// keys, saving, asset definitions, and Collapse into Subnetwork / Extract Contents.
final class ProceduralSubnetTests: XCTestCase {
    private func environment(frame: Float = 1, definitions: [String: ProcAsset] = [:]) -> ProcEnvironment {
        var e = ProcEnvironment(file: { _ in nil }, stamp: { _ in 0 }, definition: { definitions[$0] })
        e.frame = frame
        return e
    }

    private func cook(_ g: ProcGraph, at path: [String] = [], _ id: String, frame: Float = 1) throws -> ProcGeo {
        try ProcCooker(environment: environment(frame: frame)).cook(g, at: path, id).get()
    }

    private func size(_ g: ProcGeo) -> SIMD3<Float> { g.bounds.hi - g.bounds.lo }

    /// A box outside wired into a subnet whose Sub-Network Input feeds a Transform moving it up by `ty`.
    private func lifted(ty: Float = 2) -> (graph: ProcGraph, box: String, subnet: String, xform: String) {
        var g = ProcGraph()
        let box = g.add(.box)
        let s = g.add(.subnet)
        g.link(box, to: s)   // (no input yet: refused)
        var c = ProcGraph()
        let input = c.add(.subinput)
        let xf = c.add(.transform, params: ["t": .vec3([0, ty, 0])])
        c.link(input, to: xf)
        c.setDisplay(xf)
        g.nodes[g.index(of: s)!].contents = c
        XCTAssertTrue(g.link(box, to: s))
        g.setDisplay(s)
        return (g, box, s, xf)
    }

    func testSubnetCooksLikeItsContents() throws {
        let (g, box, s, xf) = lifted()
        var flat = ProcGraph()
        let b = flat.add(.box)
        let t = flat.add(.transform, params: ["t": .vec3([0, 2, 0])])
        flat.link(b, to: t)
        let a = try cook(g, s), want = try cook(flat, t)
        XCTAssertEqual(a.pointCount, want.pointCount)
        XCTAssertEqual(a.bounds.lo, want.bounds.lo)
        XCTAssertEqual(a.bounds.hi, want.bounds.hi)
        // Inside: the Transform at its path, its info by the subnet's id and its own.
        let c = ProcCooker(environment: environment())
        let inner = try c.cook(g, at: [s], xf).get()
        XCTAssertEqual(inner.bounds.lo, want.bounds.lo)
        XCTAssertNotNil(c.info["\(s)/\(xf)"])
        XCTAssertNotNil(c.info[box])
        XCTAssertNil(c.info[xf])
    }

    func testInputsFollowTheSubnetworkInputs() throws {
        var (g, _, s, _) = lifted()
        XCTAssertEqual(g.node(s)?.spec.inputs, ["Input 1"])
        // A second input, numbered 3 and labelled: three inputs, the second free.
        var c = g.node(s)!.contents!
        let third = c.add(.subinput, params: ["input": .int(3), "label": .string("Cutter")])
        g.nodes[g.index(of: s)!].contents = c
        XCTAssertEqual(g.node(s)?.spec.inputs, ["Input 1", "Input 2", "Cutter"])
        XCTAssertEqual(g.inputs(of: s).count, 3)
        // Nothing wired into an input: no geometry inside.
        XCTAssertEqual(try cook(g, at: [s], third).pointCount, 0)
        // An input of a number the subnet hasn't: not wired.
        let other = g.add(.box)
        XCTAssertFalse(g.link(other, to: s, 3))
        XCTAssertTrue(g.link(other, to: s, 2))
        XCTAssertEqual(try cook(g, at: [s], third).pointCount, 8)
    }

    func testParametersAndPaths() throws {
        var (g, box, s, xf) = lifted(ty: 0)
        var c = g.node(s)!.contents!
        c.interface = [PromotedParam("lift", value: .float(1), span: 0...10, targets: [])]
        c.nodes[c.index(of: xf)!].expressions["ty"] = #"ch("../lift")"#
        // Reaches beside the subnet: the box's size.
        c.nodes[c.index(of: xf)!].expressions["tx"] = #"ch("../../box1/sizex") * 3"#
        g.nodes[g.index(of: s)!].contents = c
        XCTAssertEqual(g.node(s)?.spec.param("lift")?.ui, .number(0...10))
        XCTAssertEqual(try cook(g, s).bounds.lo.y, 0.5, accuracy: 1e-5)          // the default
        XCTAssertEqual(try cook(g, s).bounds.lo.x, 2.5, accuracy: 1e-5)
        g.nodes[g.index(of: s)!].params["lift"] = .float(4)
        XCTAssertEqual(try cook(g, s).bounds.lo.y, 3.5, accuracy: 1e-5)          // the subnet's value
        // Keyed and with an expression, like any parameter.
        g.nodes[g.index(of: s)!].curves["lift"] = ProcCurve([ProcKey(frame: 1, value: 0, interpolation: .linear), ProcKey(frame: 11, value: 10, interpolation: .linear)])
        XCTAssertEqual(try cook(g, s, frame: 6).bounds.lo.y, 4.5, accuracy: 1e-5)
        XCTAssertEqual(try cook(g, at: [s], xf, frame: 6).bounds.lo.y, 4.5, accuracy: 1e-5)
        g.nodes[g.index(of: s)!].curves = [:]
        g.nodes[g.index(of: s)!].expressions["lift"] = "$F * 2"
        XCTAssertEqual(try cook(g, s, frame: 3).bounds.lo.y, 5.5, accuracy: 1e-5)
        XCTAssertEqual(try cook(g, at: [s], xf, frame: 3).bounds.lo.y, 5.5, accuracy: 1e-5)
        // Outside, a node reads into the subnet.
        let reader = g.add(.box)
        g.nodes[g.index(of: reader)!].expressions["sizey"] = #"ch("../subnet1/transform1/tx")"#
        XCTAssertEqual(size(try cook(g, reader)).y, 3, accuracy: 1e-5)
        g.nodes[g.index(of: reader)!].expressions["sizez"] = #"npoints("../subnet1/subinput1")"#
        XCTAssertEqual(size(try cook(g, reader)).z, 8, accuracy: 1e-5)
        // A path that leads nowhere is an error that says so, and so is one above the top.
        g.nodes[g.index(of: reader)!].expressions["sizez"] = #"ch("../../box1/sizex")"#
        guard case .failure(let e) = ProcCooker(environment: environment()).cook(g, reader) else { return XCTFail("cooked") }
        XCTAssertTrue(e.message.contains("above the top"), e.message)
        g.nodes[g.index(of: reader)!].expressions["sizez"] = #"ch("../subnet1/nothing/tx")"#
        guard case .failure(let f) = ProcCooker(environment: environment()).cook(g, reader) else { return XCTFail("cooked") }
        XCTAssertTrue(f.message.contains("no node nothing"), f.message)
        _ = box
    }

    func testKeys() throws {
        var (g, _, s, xf) = lifted()
        let cooker = ProcCooker(environment: environment())
        let k = cooker.key(g, s)
        // A second subnet made the same: the same key (nothing of ids or names in it).
        var twin = g
        let s2 = twin.add(.subnet)
        twin.nodes[twin.index(of: s2)!].contents = g.node(s)!.contents
        twin.link(twin.nodes[0].id, to: s2)
        XCTAssertEqual(cooker.key(twin, s2), k)
        // An edit inside: another key.
        var edited = g
        edited.nodes[edited.index(of: s)!].contents!.setParam(xf, "t", .vec3([0, 3, 0]))
        XCTAssertNotEqual(cooker.key(edited, s), k)
        // Something outside it reads: another key.
        g.nodes[g.index(of: s)!].contents!.nodes[1].expressions["tx"] = #"ch("../../box1/sizex")"#
        let reads = cooker.key(g, s)
        g.setParam(g.nodes[0].id, "size", .vec3([4, 1, 1]))
        XCTAssertNotEqual(cooker.key(g, s), reads)
        // The input's key: another box, another key.
        XCTAssertNotEqual(reads, k)
    }

    func testForEachInsideASubnet() throws {
        var g = ProcGraph()
        let boxes = g.add(.box)
        let s = g.add(.subnet)
        var c = ProcGraph()
        let input = c.add(.subinput)
        let begin = c.add(.foreachbegin)
        let xf = c.add(.transform, params: ["t": .vec3([0, 1, 0])])
        let end = c.add(.foreachend, params: ["iterationmethod": .string("count"), "iterations": .int(3), "gather": .string("feedback")])
        c.link(input, to: begin)
        c.link(begin, to: xf)
        c.link(xf, to: end)
        c.setDisplay(end)
        g.nodes[g.index(of: s)!].contents = c
        g.link(boxes, to: s)
        XCTAssertEqual(try cook(g, s).bounds.lo.y, 2.5, accuracy: 1e-5)
    }

    func testSaved() throws {
        var (g, _, s, _) = lifted()
        g.nodes[g.index(of: s)!].contents!.interface = [PromotedParam("lift", value: .float(1), targets: [])]
        let back = try JSONDecoder().decode(ProcGraph.self, from: JSONEncoder().encode(g))
        XCTAssertEqual(back, g)
        var plain = ProcGraph()
        plain.add(.box)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("contents"))
        // A subnet saved without contents has an empty network.
        let old = try JSONDecoder().decode(ProcGraph.self, from: Data(#"{"nodes": [{"id": "n1", "kind": "subnet", "at": [0, 0]}]}"#.utf8))
        XCTAssertEqual(old.nodes[0].contents, ProcGraph())
    }

    // MARK: Asset nodes

    /// A library asset: a box whose height is its parameter `height`.
    private func tower(height: Float = 3) -> ProcAsset {
        var g = ProcGraph()
        let b = g.add(.box)
        g.nodes[g.index(of: b)!].expressions["sizey"] = #"ch("../height")"#
        g.interface = [PromotedParam("height", value: .float(height), span: 0...20, targets: [])]
        return ProcAsset(name: "Tower", graph: g, materials: [MaterialSlot(name: "brick")])
    }

    func testAssetNodes() throws {
        var g = ProcGraph()
        let a = g.add(.asset, params: ["asset": .string("tower")])
        XCTAssertNil(g.node(a)?.contents)
        var library = ["tower": tower()]
        var synced = g.syncingDefinitions { library[$0] }
        XCTAssertEqual(synced.node(a)?.spec.param("height")?.value, .float(3))
        XCTAssertEqual(size(try ProcCooker(environment: environment()).cook(synced, a).get()).y, 3, accuracy: 1e-5)
        synced.nodes[0].params["height"] = .float(7)
        XCTAssertEqual(size(try ProcCooker(environment: environment()).cook(synced, a).get()).y, 7, accuracy: 1e-5)
        // The definition changes: so do the contents and the key.
        let cooker = ProcCooker(environment: environment())
        let k = cooker.key(synced, a)
        var taller = tower()
        taller.graph.nodes[0].params["divs"] = .vec3([2, 2, 2])
        library["tower"] = taller
        synced = synced.syncingDefinitions { library[$0] }
        XCTAssertNotEqual(cooker.key(synced, a), k)
        XCTAssertTrue(synced.isLocked([a]))
        // Allowed editing: its contents its own, the library's no longer put in.
        synced.nodes[0].editable = true
        synced.nodes[0].contents!.nodes[0].params["divs"] = .vec3([3, 3, 3])
        XCTAssertEqual(synced.syncingDefinitions { library[$0] }.nodes[0].contents?.nodes[0].params["divs"], .vec3([3, 3, 3]))
        XCTAssertFalse(synced.isLocked([a]))
        synced.nodes[0].editable = false
        XCTAssertEqual(synced.syncingDefinitions { library[$0] }.nodes[0].contents?.nodes[0].params["divs"], .vec3([2, 2, 2]))
        // A library without it: the contents it was saved with.
        XCTAssertEqual(synced.syncingDefinitions { _ in nil }.nodes[0].contents, synced.nodes[0].contents)
    }

    func testAnAssetThatContainsItself() throws {
        var looped = tower()
        let inner = looped.graph.add(.asset, params: ["asset": .string("tower")])
        looped.graph.nodes[looped.graph.index(of: inner)!].contents = tower().graph
        looped.graph.link(inner, to: looped.graph.add(.merge))
        var g = ProcGraph()
        let a = g.add(.asset, params: ["asset": .string("tower")])
        g = g.syncingDefinitions { $0 == "tower" ? looped : nil }
        g.nodes[0].contents!.setDisplay(inner)
        guard case .failure(let e) = ProcCooker(environment: environment()).cook(g, a) else { return XCTFail("cooked") }
        XCTAssertTrue(e.message.contains("contains itself"), e.message)
    }

    func testPlacedAssetWithAssetNodes() throws {
        var outer = ProcGraph()
        let a = outer.add(.asset, params: ["asset": .string("tower"), "height": .float(5)])
        let s = outer.add(.subnet)
        var c = ProcGraph()
        let input = c.add(.subinput)
        let xf = c.add(.transform, params: ["t": .vec3([10, 0, 0])])
        c.link(input, to: xf)
        c.setDisplay(xf)
        outer.nodes[outer.index(of: s)!].contents = c
        outer.link(a, to: s)
        outer.setDisplay(s)
        let asset = ProcAsset(name: "Street", graph: outer)
        let env = environment(definitions: ["tower": tower()])
        let cooked = try asset.cook([:], environment: env).get()
        let ys = cooked.rendered.positions.map(\.y), xs = cooked.rendered.positions.map(\.x)
        XCTAssertEqual(ys.max()! - ys.min()!, 5, accuracy: 1e-5)
        XCTAssertEqual(xs.min()!, 9.5, accuracy: 1e-5)
        // The nested asset's material slots join the asset's.
        XCTAssertEqual(asset.slots(env).map(\.name), ["brick"])
        // The cache's name follows the nested definition.
        var changed = tower()
        changed.graph.nodes[0].params["divs"] = .vec3([2, 2, 2])
        XCTAssertNotEqual(asset.cacheName([:], environment: env),
                          asset.cacheName([:], environment: environment(definitions: ["tower": changed])))
    }

    // MARK: Collapse and extract

    /// box1 → transform1 (tx reads box1's size) → null1 (ty reads transform1's tx); merge1 reads box1 too.
    private func chain() -> ProcGraph {
        var g = ProcGraph()
        let box = g.add(.box, at: [0, 0])
        let xf = g.add(.transform, at: [0, 64])
        let null = g.add(.null, at: [0, 128])
        g.link(box, to: xf)
        g.link(xf, to: null)
        g.nodes[g.index(of: xf)!].expressions["tx"] = #"ch("../box1/sizex") * 2"#
        g.nodes[g.index(of: null)!].comment = "out"
        let reader = g.add(.box, at: [200, 0])
        g.nodes[g.index(of: reader)!].expressions["sizey"] = #"ch("../transform1/tx") + 1"#
        g.interface = [PromotedParam("shift", value: .vec3([0, 1, 0]), targets: [.init(node: "transform1", param: "t")])]
        g.setDisplay(null)
        return g
    }

    func testCollapseAndExtract() throws {
        var g = chain()
        let before = try cook(g, g.named("null1")!.id)
        let reader = g.named("box2")!.id
        let readerBefore = try cook(g, reader)
        let s = try g.collapse([g.named("transform1")!.id])
        let sub = g.node(s)!
        XCTAssertEqual(sub.name, "subnet1")
        XCTAssertEqual(g.inputs(of: s), [g.named("box1")!.id])
        XCTAssertEqual(g.inputs(of: g.named("null1")!.id), [s])
        XCTAssertEqual(sub.contents?.named("transform1")?.expressions["tx"], #"ch("../../box1/sizex") * 2"#)
        XCTAssertEqual(g.named("box2")?.expressions["sizey"], #"ch("../subnet1/transform1/tx") + 1"#)
        XCTAssertEqual(g.interface[0].targets[0].node, "subnet1/transform1")
        XCTAssertEqual(sub.contents?.nodes.filter { $0.kind == .subinput }.count, 1)
        let after = try cook(g, g.named("null1")!.id)
        XCTAssertEqual(after.bounds.lo, before.bounds.lo)
        XCTAssertEqual(try cook(g, reader).bounds.hi, readerBefore.bounds.hi)
        // Two nodes feeding the outside: refused.
        var two = chain()
        two.link(two.named("box1")!.id, to: two.add(.merge))
        XCTAssertThrowsError(try two.collapse([two.named("box1")!.id, two.named("transform1")!.id]))
        // Extracted again: the network it was, up to ids and places.
        let ids = try g.extract(s)
        XCTAssertEqual(ids.count, 1)
        XCTAssertNil(g.named("subnet1"))
        let back = g.named("transform1")!
        XCTAssertEqual(back.expressions["tx"], #"ch("../box1/sizex") * 2"#)
        XCTAssertEqual(g.named("box2")?.expressions["sizey"], #"ch("../transform1/tx") + 1"#)
        XCTAssertEqual(g.interface[0].targets[0].node, "transform1")
        XCTAssertEqual(g.inputs(of: back.id), [g.named("box1")!.id])
        XCTAssertEqual(g.inputs(of: g.named("null1")!.id), [back.id])
        XCTAssertEqual(try cook(g, g.named("null1")!.id).bounds.lo, before.bounds.lo)
    }

    func testExtractKeepsTheSubnetParameters() throws {
        var (g, _, s, xf) = lifted(ty: 0)
        g.nodes[g.index(of: s)!].contents!.interface = [PromotedParam("lift", value: .float(1), targets: [])]
        let k = g.node(s)!.contents!.index(of: xf)!
        g.nodes[g.index(of: s)!].contents!.nodes[k].expressions["ty"] = #"ch("../lift")"#
        g.nodes[g.index(of: s)!].params["lift"] = .float(6)
        g.interface = [PromotedParam("lift", value: .float(0), targets: [])]
        let before = try cook(g, s)
        try g.extract(s)
        XCTAssertEqual(g.interface.map(\.name), ["lift", "lift2"])
        XCTAssertEqual(g.interface[1].value, .float(6))
        let moved = g.named("transform1")!
        XCTAssertEqual(moved.expressions["ty"], #"ch("../lift2")"#)
        XCTAssertEqual(try cook(g, moved.id).bounds.lo, before.bounds.lo)
    }

    func testRewritingStrings() {
        XCTAssertEqual(ProcExpr.rewritingStrings(#"ch("a") + ch('b') + "c\"d""#) { $0 == "a" ? "x/y" : $0 == "c\"d" ? "e" : nil },
                       #"ch("x/y") + ch('b') + "e""#)
        let n = ProcNode(.box, id: "n1", params: ["name": .string(#"piece`chs("../box1/name")`"#)])
        let r = n.rewritingPaths { place, channel in place == ["..", "box1"] ? (["..", "..", "box1"], channel) : nil }
        XCTAssertEqual(r.params["name"], .string(#"piece`chs("../../box1/name")`"#))
    }
}
