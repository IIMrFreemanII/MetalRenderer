import XCTest
import simd
@testable import EngineCore
@testable import Procedural

/// Keyframed channels (Sources/Procedural/Graph/ProcCurve.swift): the curves' interpolations, slopes and
/// extrapolations, how a keyed channel cooks and keys its node's cook, `chf()` at another frame, and how keys are saved.
final class ProceduralKeyframeTests: XCTestCase {
    private func environment(frame: Float = 1) -> ProcEnvironment {
        var e = ProcEnvironment(file: { _ in nil }, stamp: { _ in 0 })
        e.frame = frame
        return e
    }

    private func cook(_ g: ProcGraph, _ id: String, frame: Float) throws -> ProcGeo {
        try ProcCooker(environment: environment(frame: frame)).cook(g, id).get()
    }

    private func width(_ g: ProcGeo) -> Float { g.bounds.hi.x - g.bounds.lo.x }

    private func line(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ m: ProcInterpolation = .linear) -> ProcCurve {
        ProcCurve([ProcKey(frame: a.x, value: a.y, interpolation: m), ProcKey(frame: b.x, value: b.y, interpolation: m)])
    }

    func testInterpolations() {
        XCTAssertEqual(line([1, 0], [11, 10]).value(at: 6), 5)
        XCTAssertEqual(line([1, 0], [11, 10], .constant).value(at: 6), 0)
        XCTAssertEqual(line([1, 0], [11, 10], .constant).value(at: 11), 10)
        XCTAssertEqual(line([1, 0], [11, 10], .ease).value(at: 6), 5, accuracy: 1e-5)
        XCTAssertEqual(line([1, 0], [11, 10], .easeIn).value(at: 6), 2.5, accuracy: 1e-5)
        XCTAssertEqual(line([1, 0], [11, 10], .easeOut).value(at: 6), 7.5, accuracy: 1e-5)
        // A spline held at both ends: flat there (3s² - 2s³).
        let s = line([0, 0], [8, 10], .spline)
        XCTAssertEqual(s.value(at: 4), 5, accuracy: 1e-5)
        XCTAssertEqual(s.value(at: 2), 1.5625, accuracy: 1e-5)
        // One key: its value everywhere; none: 0.
        XCTAssertEqual(ProcCurve([ProcKey(frame: 3, value: 2)]).value(at: 100), 2)
        XCTAssertEqual(ProcCurve().value(at: 1), 0)
        // A key on a frame that has one replaces it; keys stay sorted.
        var c = line([1, 0], [11, 10])
        c.set(11, 4)
        c.set(5, 2)
        XCTAssertEqual(c.keys.map(\.frame), [1, 5, 11])
        XCTAssertEqual(c.keys.map(\.value), [0, 2, 4])
        XCTAssertEqual(c.keys[1].interpolation, .linear)         // the interpolation of the key before it
        c.remove(at: 5)
        XCTAssertEqual(c.keys.map(\.frame), [1, 11])
    }

    func testAutomaticSlopesDontOvershoot() {
        // A peak: flat on it, the curve never above it.
        let peak = ProcCurve([ProcKey(frame: 0, value: 0), ProcKey(frame: 10, value: 5), ProcKey(frame: 20, value: 0)])
        XCTAssertEqual(peak.slopes(1), .zero)
        XCTAssertLessThanOrEqual((0...200).map { peak.value(at: Float($0) / 10) }.max()!, 5 + 1e-5)
        // Rising unevenly: monotone, within its keys.
        let rise = ProcCurve([ProcKey(frame: 0, value: 0), ProcKey(frame: 10, value: 1), ProcKey(frame: 11, value: 10)])
        let samples = (0...110).map { rise.value(at: Float($0) / 10) }
        XCTAssertEqual(samples, samples.sorted())
        XCTAssertGreaterThanOrEqual(samples.min()!, 0)
        XCTAssertLessThanOrEqual(samples.max()!, 10 + 1e-5)
        // Slopes of its own.
        let own = ProcCurve([ProcKey(frame: 0, value: 0, slopes: [1, 1]), ProcKey(frame: 10, value: 0, slopes: [-1, -1])])
        XCTAssertEqual(own.value(at: 5), 2.5, accuracy: 1e-5)
    }

    func testExtrapolation() {
        var c = line([0, 0], [10, 10])
        XCTAssertEqual(c.value(at: 15), 10)
        XCTAssertEqual(c.value(at: -5), 0)
        c.after = .linear
        c.before = .linear
        XCTAssertEqual(c.value(at: 15), 15, accuracy: 1e-5)
        XCTAssertEqual(c.value(at: -5), -5, accuracy: 1e-5)
        c.after = .cycle
        c.before = .cycle
        XCTAssertEqual(c.value(at: 15), 5, accuracy: 1e-5)
        XCTAssertEqual(c.value(at: 27), 7, accuracy: 1e-5)
        XCTAssertEqual(c.value(at: -5), 5, accuracy: 1e-5)
        c.after = .cycleOffset
        c.before = .cycleOffset
        XCTAssertEqual(c.value(at: 15), 15, accuracy: 1e-5)
        XCTAssertEqual(c.value(at: 27), 27, accuracy: 1e-5)
        XCTAssertEqual(c.value(at: -5), -5, accuracy: 1e-5)
    }

    func testKeyedChannelsCookAndKey() throws {
        var g = ProcGraph()
        let box = g.add(.box)
        g.nodes[g.index(of: box)!].curves["sizex"] = line([1, 1], [11, 11])
        XCTAssertEqual(width(try cook(g, box, frame: 6)), 6, accuracy: 1e-5)
        XCTAssertEqual(width(try cook(g, box, frame: 30)), 11, accuracy: 1e-5)
        // The key holds the channel's value on the frame, not the frame: frames where it holds share a cook.
        let cooker = ProcCooker(environment: environment(frame: 12))
        let k12 = cooker.key(g, box)
        cooker.environment.frame = 20
        XCTAssertEqual(cooker.key(g, box), k12)
        cooker.environment.frame = 6
        XCTAssertNotEqual(cooker.key(g, box), k12)
        // A key moved: another key.
        var moved = g
        moved.nodes[0].curves["sizex"]!.set(11, 12)
        cooker.environment.frame = 12
        XCTAssertNotEqual(cooker.key(moved, box), k12)
        // The cook's report shows the channel's value.
        let c = ProcCooker(environment: environment(frame: 3))
        _ = try c.cook(g, box).get()
        XCTAssertEqual(c.info[box]?.channels["sizex"], 3)
    }

    func testChannelsReadKeys() throws {
        var g = ProcGraph()
        let box = g.add(.box)
        let xf = g.add(.transform)
        g.link(box, to: xf)
        g.nodes[g.index(of: box)!].curves["sizex"] = line([1, 1], [11, 11])
        g.nodes[g.index(of: xf)!].expressions["tx"] = #"ch("../box1/sizex")"#
        g.nodes[g.index(of: xf)!].expressions["ty"] = #"chf("../box1/sizex", $F + 2)"#
        let c = ProcCooker(environment: environment(frame: 4))
        _ = try c.cook(g, xf).get()
        XCTAssertEqual(c.info[xf]?.channels["tx"], 4)
        XCTAssertEqual(c.info[xf]?.channels["ty"], 6)
        // ty reads box1's keys on another frame: its key holds all of them, so moving one far away recooks it.
        let k = c.key(g, xf)
        g.nodes[g.index(of: box)!].curves["sizex"]!.set(40, 2)
        XCTAssertNotEqual(c.key(g, xf), k)
        // chf() of an expression: an error that says so.
        g.nodes[g.index(of: box)!].curves["sizex"] = nil
        g.nodes[g.index(of: box)!].expressions["sizex"] = "$F"
        guard case .failure(let e) = ProcCooker(environment: environment()).cook(g, xf) else { return XCTFail("chf() of an expression cooked") }
        XCTAssertTrue(e.message.contains("has an expression"), e.message)
    }

    func testSwitchByKeys() throws {
        var g = ProcGraph()
        let a = g.add(.box, params: ["size": .vec3([1, 1, 1])])
        let b = g.add(.box, params: ["size": .vec3([5, 1, 1])])
        let sw = g.add(.switchnode)
        g.link(a, to: sw, 0)
        g.link(b, to: sw, 1)
        g.nodes[g.index(of: sw)!].curves["input"] = line([1, 0], [10, 1], .constant)
        XCTAssertEqual(width(try cook(g, sw, frame: 5)), 1, accuracy: 1e-5)
        XCTAssertEqual(width(try cook(g, sw, frame: 10)), 5, accuracy: 1e-5)
    }

    func testExpressionsKeysAndPromotion() {
        var g = ProcGraph()
        let box = g.add(.box)
        g.nodes[0].curves["sizex"] = line([1, 1], [5, 5])
        XCTAssertTrue(g.nodes[0].isDriven("sizex"))
        XCTAssertFalse(g.nodes[0].isDriven("sizey"))
        // A promoted parameter wins over its target's keys.
        g.interface = [PromotedParam("width", value: .vec3([2, 1, 1]), targets: [.init(node: "box1", param: "size")])]
        XCTAssertEqual(g.applying([:]).node(box)?.curves, [:])
    }

    func testSavedKeys() throws {
        var g = ProcGraph()
        _ = g.add(.box)
        let plain = String(decoding: try JSONEncoder().encode(g), as: UTF8.self)
        XCTAssertFalse(plain.contains("curves"))
        XCTAssertFalse(plain.contains("frames"))
        var c = line([1, 0], [24, 2], .ease)
        c.after = .cycle
        c.update(1) { $0.slopes = [0.5, 0.25] }
        g.nodes[0].curves["tx"] = c
        g.frames = 1...48
        let back = try JSONDecoder().decode(ProcGraph.self, from: JSONEncoder().encode(g))
        XCTAssertEqual(back, g)
        // A network saved before keys: none, and the default range.
        let old = try JSONDecoder().decode(ProcGraph.self, from: Data(#"{"nodes": [{"id": "n1", "kind": "box", "at": [0, 0]}], "links": [], "interface": []}"#.utf8))
        XCTAssertEqual(old.nodes[0].curves, [:])
        XCTAssertEqual(old.frames, ProcGraph.defaultFrames)
    }
}
