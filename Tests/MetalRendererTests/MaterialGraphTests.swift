import XCTest
import simd
@testable import MetalRenderer

/// Material graphs without the GPU: their JSON, the plan the engine bakes (order, types, sizes, precision, packed
/// parameters, hashes), subgraphs inlined, and pixel processors' functions (Metal and the CPU's).
final class MaterialGraphTests: XCTestCase {
    private func simple() -> MaterialGraph {
        var b = MatBuilder("Simple", size: 9)
        let noise = b.node(.perlinNoise, ["scale": .int(4)])
        let tint = b.node(.uniformColor, ["color": .color([1, 0, 0, 1])])
        let mix = b.node(.blend, ["mode": .choice("multiply"), "opacity": .float(0.5)], ["fg": noise, "bg": tint])
        let half = b.node(.levels, [:], ["in": noise], id: "half")
        b.set { $0.nodes[$0.index("half")!].size = .relative(-1) }
        b.output(.baseColor, mix)
        b.output(.height, half)
        return b.graph
    }

    func testJSONRoundTrip() throws {
        var g = simple()
        g.inputs = [MatGraphInput("amount", "Amount", .float(0.3), span: 0...1)]
        g.nodes[0].exposed = ["disorder": "amount"]
        g.nodes[0].bits = .b32
        g.nodes.append(MatNode(.pixelProcessor, id: "pp"))
        g.surface.heightDepth = 0.07
        let back = try MaterialStore.decode(MaterialStore.encode(g))
        XCTAssertEqual(back, g)
        // Every built-in graph reads back as it was.
        for g in MaterialLibrary.all { XCTAssertEqual(try MaterialStore.decode(MaterialStore.encode(g)), g, g.name) }
    }

    func testPlanOrderTypesSizesAndBits() throws {
        let plan = try MatPlan(simple(), library: { _ in nil })
        XCTAssertEqual(plan.steps.count, 6)
        // Every step after its inputs.
        for (k, s) in plan.steps.enumerated() { for i in s.inputs.compactMap({ $0 }) { XCTAssertLessThan(i.step, k) } }
        let blend = plan.steps[plan.index["blend"]!]
        XCTAssertEqual(blend.outputs, [.color], "a grey over a colour is a colour")
        XCTAssertEqual(blend.bits, .b8, "auto: colour is 8-bit")
        XCTAssertEqual(blend.size, 9)
        XCTAssertEqual(blend.params[0].x, Float(MatBlendMode.allCases.firstIndex(of: .multiply)!))
        XCTAssertEqual(blend.params[1].x, 0.5)
        let half = plan.steps[plan.index["half"]!]
        XCTAssertEqual(half.outputs, [.grey])
        XCTAssertEqual(half.bits, .b16, "auto: grey is 16-bit")
        XCTAssertEqual(half.size, 8, "relative -1 of its input's 9")
        XCTAssertEqual(plan.steps[plan.index["height"]!].size, 8, "inherits its input's")
        XCTAssertEqual(Set(plan.channels.keys), [.baseColor, .height])
    }

    func testHashesFollowWhatChanged() throws {
        var g = simple()
        let a = try MatPlan(g, library: { _ in nil })
        g.nodes[g.index("half")!].params["gamma"] = .float(2)
        let b = try MatPlan(g, library: { _ in nil })
        func hash(_ p: MatPlan, _ id: String) -> UInt64 { p.steps[p.index[id]!].hash }
        XCTAssertEqual(hash(a, "perlinNoise"), hash(b, "perlinNoise"))
        XCTAssertEqual(hash(a, "blend"), hash(b, "blend"), "not downstream of the edit")
        XCTAssertNotEqual(hash(a, "half"), hash(b, "half"))
        XCTAssertNotEqual(hash(a, "height"), hash(b, "height"), "downstream of the edit")
        // Moving a node changes nothing baked.
        g.nodes[0].at += [40, 0]
        XCTAssertEqual(hash(b, "height"), hash(try MatPlan(g, library: { _ in nil }), "height"))
    }

    func testLoopsAreRefused() {
        var g = simple()
        g.links.append(MatLink("half", to: "perlinNoise", "in"))   // the noise has no input: not a link the plan reads
        g.links.append(MatLink("blend", to: "half", "in"))
        g.links.removeAll { $0.to == "half" && $0.from == "perlinNoise" }
        g.links.append(MatLink("half", to: "blend", "fg"))
        g.links.removeAll { $0.to == "blend" && $0.input == "fg" && $0.from == "perlinNoise" }
        XCTAssertThrowsError(try MatPlan(g, library: { _ in nil }))
        XCTAssertFalse(simple().canLink("half", "out", to: "perlinNoise", "in", library: { _ in nil }), "the noise has no input")
        XCTAssertFalse(simple().canLink("blend", "out", to: "perlinNoise", "x", library: { _ in nil }))
        XCTAssertTrue(simple().canLink("half", "out", to: "blend", "mask", library: { _ in nil }))
    }

    func testSubgraphsAreInlined() throws {
        // A subgraph: an input "src", darkened by its exposed "amount", out as "dark".
        var sub = MaterialGraph("Darken")
        sub.inputs = [MatGraphInput("amount", "Amount", .float(0.5), span: 0...1)]
        sub.nodes = [MatNode(.input, ["name": .text("src"), "type": .choice("grey")], id: "in"),
                     MatNode(.levels, id: "lv"),
                     MatNode(.output, ["name": .text("dark"), "usage": .choice("none")], id: "out")]
        sub.nodes[1].exposed = ["outHigh": "amount"]
        sub.links = [MatLink("in", to: "lv", "in"), MatLink("lv", to: "out", "in")]
        XCTAssertEqual(MatPlan.pins(of: sub).inputs.map(\.name), ["src"])
        XCTAssertEqual(MatPlan.pins(of: sub).outputs.map(\.name), ["dark"])

        var top = MaterialGraph("Top")
        top.nodes = [MatNode(.checker, id: "c"), MatNode(.subgraph, ["graph": .text("Darken"), "amount": .float(0.25)], id: "s"),
                     MatNode(.output, ["usage": .choice("roughness")], id: "o")]
        top.links = [MatLink("c", to: "s", "src"), MatLink("s", "dark", to: "o", "in")]
        let lib: (String) -> MaterialGraph? = { $0 == "Darken" ? sub : nil }
        let plan = try MatPlan(top, library: lib)
        let lv = plan.steps[plan.index["s/lv"]!]
        XCTAssertEqual(lv.params[4].x, 0.25, "the exposed parameter from the subgraph node")
        XCTAssertEqual(plan.steps[lv.inputs[0]!.step].id, "s/in", "the input node, a pass-through")
        XCTAssertEqual(plan.steps[plan.steps[lv.inputs[0]!.step].inputs[0]!.step].id, "c")
        XCTAssertEqual(plan.steps[plan.channels[.roughness]!].id, "o")
        XCTAssertNil(plan.channels[.baseColor])
        XCTAssertEqual(plan.steps[plan.index["s/out"]!].node.choice("usage"), "none", "a subgraph's outputs aren't the material's")

        // A graph inside itself is refused.
        var loop = sub
        loop.nodes.append(MatNode(.subgraph, ["graph": .text("Darken")], id: "again"))
        XCTAssertThrowsError(try MatPlan(top, library: { $0 == "Darken" ? loop : nil }))
        XCTAssertThrowsError(try MatPlan(top, library: { _ in nil }), "a missing graph")
    }

    func testCurvesAndGradientsAreTables() throws {
        var g = MaterialGraph("T")
        g.nodes = [MatNode(.gradient, id: "g"),
                   MatNode(.gradientMap, ["gradient": .gradient(VFXGradient([.init(0, [1, 0, 0, 1]), .init(1, [0, 0, 1, 1])]))], id: "m"),
                   MatNode(.curve, ["curve": .curve(VFXCurve([[0, 1], [1, 0]]))], id: "c")]
        g.links = [MatLink("g", to: "m", "in"), MatLink("g", to: "c", "in")]
        let plan = try MatPlan(g, library: { _ in nil })
        let m = plan.steps[plan.index["m"]!], c = plan.steps[plan.index["c"]!]
        XCTAssertEqual(m.luts.count, 1)
        XCTAssertEqual(m.luts[0].count, MatPlan.lutSize)
        XCTAssertEqual(m.luts[0][0], [1, 0, 0, 1])
        XCTAssertEqual(m.luts[0][MatPlan.lutSize - 1], [0, 0, 1, 1])
        XCTAssertEqual(c.luts[0][0].x, 1)
        XCTAssertEqual(c.luts[0][MatPlan.lutSize - 1].x, 0)
    }

    func testFunctionCodeMatchesItsClosure() throws {
        // r = sample(in0, uv * 2) * 0.5 + random(uv) ; a vec2 mixed into a vec4.
        var f = MatFunction()
        f.nodes = [MatFnNode(.position, id: "p"), MatFnNode(.vector2, ["value": .vec2([2, 2])], id: "two"),
                   MatFnNode(.multiply, id: "uv2"), MatFnNode(.sample, id: "s"), MatFnNode(.multiply, ["b": .float(0.5)], id: "half"),
                   MatFnNode(.random, id: "r"), MatFnNode(.add, id: "sum"), MatFnNode(.result, id: "out")]
        f.links = [MatLink("p", to: "uv2", "a"), MatLink("two", to: "uv2", "b"), MatLink("uv2", to: "s", "uv"),
                   MatLink("s", to: "half", "a"), MatLink("p", to: "r", "at"), MatLink("half", to: "sum", "a"), MatLink("r", to: "sum", "b"),
                   MatLink("sum", to: "out", "value")]
        let code = try f.code()
        XCTAssertTrue(code.metal.contains("sampleInput(0, v_uv2)"), code.metal)
        XCTAssertTrue(code.metal.contains("matRandom(v_p"), code.metal)
        var env = MatFnEnv()
        env.uv = [0.25, 0.75]
        env.sample = { i, uv in SIMD4(uv.x, uv.y, Float(i), 1) }
        let v = code.eval(env)
        let r = MatFunction.random([0.25, 0.75], 0)
        XCTAssertEqual(v.x, 0.25 + r, accuracy: 1e-6)
        XCTAssertEqual(v.y, 0.75 + r, accuracy: 1e-6)
        XCTAssertEqual(v.w, 0.5 + r, accuracy: 1e-6)

        XCTAssertThrowsError(try MatFunction().code(), "no Result")
        var loop = MatFunction.passThrough
        loop.links.append(MatLink("sample", to: "position", "x"))
        XCTAssertNoThrow(try loop.code(), "a wire into no pin is ignored")
    }

    /// Which graphs run as code: not one with occlusion (it reads everywhere), the marble yes, within the budget;
    /// its splice compiles (with Procedural.metal, the stand-in it replaces).
    func testShaderCode() throws {
        let bricks = try MatPlan(MaterialLibrary.redBricks(), library: { _ in nil })
        XCTAssertFalse(MatShaderCode.reasons(bricks).isEmpty)
        let marble = try MatPlan(MaterialLibrary.marble(), library: { _ in nil })
        XCTAssertTrue(MatShaderCode.reasons(marble).isEmpty, "\(MatShaderCode.reasons(marble))")
        XCTAssertLessThanOrEqual(MatShaderCode.evaluations(marble), MatShaderCode.budget)
        let p = try MatShaderCode.program(marble, number: 0, base: 0)
        XCTAssertEqual(p.params.count, marble.steps.reduce(0) { $0 + max($1.params.count, 1) + $1.luts.count * MatPlan.lutSize })
        let splice = try MatShaderCode.splice([(0, p)])
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let stub = try String(contentsOf: MatCompiler.folder.appendingPathComponent("Shaders/Procedural.metal"), encoding: .utf8)
        let text = "#include <metal_stdlib>\nusing namespace metal;\n" + stub.replacingOccurrences(of: ShaderSource.proceduralMarker, with: splice)
            + "\nkernel void probe(device float4* out [[buffer(0)]], device const float4* P [[buffer(1)]]) { out[0] = proceduralMaterial(0u, float2(0.3), P).base; }\n"
        XCTAssertNoThrow(try device.makeLibrary(source: text, options: nil))
    }
}
