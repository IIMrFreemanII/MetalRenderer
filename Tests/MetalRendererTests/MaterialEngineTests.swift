import XCTest
import Metal
import ImageIO
import simd
@testable import MetalRenderer

/// The material graph's GPU engine (MatEngine, the kernels in MaterialShaders/): nodes' values against the CPU's
/// formulas, the cache (only what an edit reaches is baked again), and the multi-pass nodes against brute force.
final class MaterialEngineTests: XCTestCase {
    private static var shared: MatEngine?
    private var engine: MatEngine!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        if MaterialEngineTests.shared == nil { MaterialEngineTests.shared = MatEngine(device: device) }
        engine = MaterialEngineTests.shared
    }

    /// Bakes `g` and reads node `id`'s output `output`.
    private func bake(_ g: MaterialGraph, _ id: String, output: Int = 0) throws -> (pixels: [SIMD4<Float>], side: Int, result: MatResult) {
        let plan = try MatPlan(g, library: { _ in nil })
        let r = engine.evaluateNow(plan)
        XCTAssertTrue(r.errors.isEmpty, "\(r.errors)")
        let step = plan.steps[plan.index[id]!]
        let t = try XCTUnwrap(engine.texture(step.hash, output: output))
        return (engine.read(t), step.pixels, r)
    }

    private func graph(_ size: Int = 6, _ nodes: [MatNode], _ links: [MatLink] = []) -> MaterialGraph {
        var g = MaterialGraph("Test", size: size, nodes: nodes, links: links)
        g.bits = .b32
        return g
    }

    func testUniformAndBlendModes() throws {
        let fg = SIMD4<Float>(0.3, 0.6, 0.9, 1), bg = SIMD4<Float>(0.7, 0.2, 0.5, 1)
        func cpu(_ m: MatBlendMode, _ f: Float, _ b: Float) -> Float {
            switch m {
            case .copy: return f
            case .add: return f + b
            case .subtract: return b - f
            case .multiply: return f * b
            case .screen: return 1 - (1 - f) * (1 - b)
            case .overlay: return b < 0.5 ? 2 * f * b : 1 - 2 * (1 - f) * (1 - b)
            case .softLight: return (1 - 2 * f) * b * b + 2 * f * b
            case .hardLight: return f < 0.5 ? 2 * f * b : 1 - 2 * (1 - f) * (1 - b)
            case .darken: return min(f, b)
            case .lighten: return max(f, b)
            case .difference: return abs(f - b)
            case .divide: return b / max(f, 1e-4)
            case .colorDodge: return b / max(1 - f, 1e-4)
            case .colorBurn: return 1 - (1 - b) / max(f, 1e-4)
            case .linearLight: return b + 2 * f - 1
            case .exclusion: return f + b - 2 * f * b
            }
        }
        for mode in MatBlendMode.allCases {
            let g = graph(4, [MatNode(.uniformColor, ["color": .color(fg)], id: "f"), MatNode(.uniformColor, ["color": .color(bg)], id: "b"),
                              MatNode(.blend, ["mode": .choice(mode.rawValue), "opacity": .float(0.75)], id: "x")],
                          [MatLink("f", to: "x", "fg"), MatLink("b", to: "x", "bg")])
            let v = try bake(g, "x").pixels[5]
            for c in 0..<3 {
                let want = bg[c] + (cpu(mode, fg[c], bg[c]) - bg[c]) * 0.75
                XCTAssertEqual(v[c], want, accuracy: 1e-4, "\(mode) channel \(c)")
            }
        }
    }

    func testNormalOfARamp() throws {
        // A ramp along U, one tile: its slope is 1 per UV; the normal leans against it: x = -k / sqrt(k² + 1).
        let g = graph(7, [MatNode(.gradient, id: "ramp"), MatNode(.normal, ["intensity": .float(50)], id: "n")], [MatLink("ramp", to: "n", "in")])
        let (px, side, _) = try bake(g, "n")
        let k: Float = 50 * 0.01
        let v = px[(side / 2) * side + side / 2] * 2 - 1
        XCTAssertEqual(v.x, -k / sqrt(k * k + 1), accuracy: 0.01)
        XCTAssertEqual(v.y, 0, accuracy: 0.01)
        XCTAssertEqual(v.z, 1 / sqrt(k * k + 1), accuracy: 0.01)
    }

    func testBlurKeepsTheMeanAndNoisesTile() throws {
        let g = graph(7, [MatNode(.checker, ["tiles": .int(8)], id: "c"), MatNode(.blur, ["radius": .float(16)], id: "b"),
                          MatNode(.perlinNoise, ["scale": .int(5)], id: "p")],
                      [MatLink("c", to: "b", "in")])
        let (blur, side, _) = try bake(g, "b")
        let mean = blur.reduce(0) { $0 + $1.x } / Float(blur.count)
        XCTAssertEqual(mean, 0.5, accuracy: 0.01)
        XCTAssertLessThan(blur.map(\.x).max()!, 0.95, "it blurred")
        // The noise wraps: its last column meets its first as smoothly as its columns meet each other.
        let (noise, _, _) = try bake(g, "p")
        var seam: Float = 0, inner: Float = 0
        for y in 0..<side {
            seam = max(seam, abs(noise[y * side + side - 1].x - noise[y * side].x))
            inner = max(inner, abs(noise[y * side + 1].x - noise[y * side].x))
        }
        XCTAssertLessThan(seam, inner * 2 + 0.01)
    }

    func testOnlyWhatAnEditReachesIsBaked() throws {
        var g = graph(6, [MatNode(.perlinNoise, id: "a"), MatNode(.cells, id: "b"), MatNode(.blend, id: "x"), MatNode(.levels, id: "l"),
                          MatNode(.output, ["usage": .choice("height")], id: "o")],
                      [MatLink("a", to: "x", "fg"), MatLink("b", to: "x", "bg"), MatLink("x", to: "l", "in"), MatLink("l", to: "o", "in")])
        let first = engine.evaluateNow(try MatPlan(g, library: { _ in nil }))
        XCTAssertNotNil(first.outputs.height)
        XCTAssertEqual(engine.evaluateNow(try MatPlan(g, library: { _ in nil })).baked, 0, "nothing changed")
        g.nodes[g.index("l")!].params["gamma"] = .float(2)
        let second = engine.evaluateNow(try MatPlan(g, library: { _ in nil }))
        XCTAssertEqual(second.baked, 2, "the levels and the output")
        XCTAssertFalse(second.outputs.height === first.outputs.height, "a new height texture")
        g.nodes[g.index("l")!].params["gamma"] = nil
        let undone = engine.evaluateNow(try MatPlan(g, library: { _ in nil }))
        XCTAssertEqual(undone.baked, 0, "undo finds the images it had")
        XCTAssertTrue(undone.outputs.height === first.outputs.height, "and the texture")
    }

    func testDistanceMatchesBruteForce() throws {
        // A disc's distance field, against the shortest wrapped distance to its pixels.
        let g = graph(6, [MatNode(.shape, ["kind": .choice("disc"), "size": .float(0.3), "softness": .float(0)], id: "m"),
                          MatNode(.distance, ["distance": .float(0.5)], id: "d")], [MatLink("m", to: "d", "in")])
        let (mask, side, _) = try bake(g, "m")
        let (field, _, _) = try bake(g, "d")
        let on = (0..<mask.count).filter { mask[$0].x > 0.5 }
        var worst: Float = 0
        for y in stride(from: 0, to: side, by: 3) {
            for x in stride(from: 0, to: side, by: 3) {
                var best = Float.greatestFiniteMagnitude
                for k in on {
                    var dx = Float(k % side - x), dy = Float(k / side - y)
                    dx -= Float(side) * (dx / Float(side)).rounded()
                    dy -= Float(side) * (dy / Float(side)).rounded()
                    best = min(best, (dx * dx + dy * dy).squareRoot())
                }
                let want = max(0, 1 - best / Float(side) / 0.5)
                worst = max(worst, abs(field[y * side + x].x - want))
            }
        }
        XCTAssertLessThan(worst, 0.035)   // a pixel off (1 / 32) at most
    }

    func testFloodFillFindsEachShape() throws {
        // A grid of 3 × 3 discs: nine shapes, nine greys.
        let g = graph(7, [MatNode(.shape, ["kind": .choice("disc"), "size": .float(0.6), "softness": .float(0), "tiling": .int(3)], id: "m"),
                          MatNode(.floodFill, id: "f")], [MatLink("m", to: "f", "in")])
        let (px, side, _) = try bake(g, "f")
        let (mask, _, _) = try bake(g, "m")
        var greys = Set<Int>()
        for k in 0..<px.count where mask[k].x > 0.5 { greys.insert(Int(px[k].x * 1e5)) }
        XCTAssertEqual(greys.count, 9)
        // Its size output: each disc about 0.6 / 3 across.
        let (size, _, _) = try bake(g, "f", output: 3)
        let centre = (side / 6) * side + side / 6
        XCTAssertEqual(size[centre].x, 0.2, accuracy: 0.03)
    }

    func testPixelProcessorMatchesItsFunction() throws {
        var pp = MatNode(.pixelProcessor, id: "pp")
        pp.function = MatFunction(nodes: [MatFnNode(.position, id: "p"), MatFnNode(.sample, id: "s"), MatFnNode(.random, id: "r"),
                                          MatFnNode(.multiply, id: "m"), MatFnNode(.result, id: "out")],
                                  links: [MatLink("p", to: "s", "uv"), MatLink("p", to: "r", "at"), MatLink("s", to: "m", "a"),
                                          MatLink("r", to: "m", "b"), MatLink("m", to: "out", "value")])
        let g = graph(5, [MatNode(.gradient, id: "ramp"), pp], [MatLink("ramp", to: "pp", "in0")])
        let (px, side, result) = try bake(g, "pp")
        XCTAssertTrue(result.errors.isEmpty)
        let code = try pp.function!.code()
        let plan = try MatPlan(g, library: { _ in nil })
        var env = MatFnEnv()
        env.size = SIMD2(repeating: Float(side))
        env.seed = Float(plan.steps[plan.index["pp"]!].seed & 0xffff)
        env.sample = { _, uv in let t = uv.x - floor(uv.x); return SIMD4(t, t, t, 1) }
        for k in [0, 17, 300, side * side - 1] {
            env.uv = (SIMD2(Float(k % side), Float(k / side)) + 0.5) / Float(side)
            XCTAssertEqual(px[k].x, code.eval(env).x, accuracy: 0.02, "pixel \(k)")
        }
    }

    func testACodeNodesErrorIsReported() throws {
        let g = graph(4, [MatNode(.code, ["code": .text("return nonsense;")], id: "c")])
        let r = engine.evaluateNow(try MatPlan(g, library: { _ in nil }))
        XCTAssertNotNil(r.errors["c"])
        XCTAssertTrue(r.errors["c"]!.contains("nonsense"), r.errors["c"]!)
    }

    func testTheStarterBakes() throws {
        for g in MaterialLibrary.all {
            let r = engine.evaluateNow(try MatPlan(g, library: { _ in nil }))
            XCTAssertTrue(r.errors.isEmpty, "\(g.name): \(r.errors)")
            XCTAssertNotNil(r.outputs.baseColor, g.name)
            XCTAssertNotNil(r.outputs.normal, g.name)
            XCTAssertEqual(r.outputs.baseColor?.mipmapLevelCount, g.size + 1)
            XCTAssertFalse(r.thumbnails.isEmpty)
        }
    }

    /// Every format writes and reads back at the graph's size. With MAT_PNG=<folder>, the starters' outputs are
    /// written there to look at.
    func testExport() throws {
        let g = MaterialLibrary.all[0]
        let r = engine.evaluateNow(try MatPlan(g, library: { _ in nil }))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mat-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for f in MatExport.Format.allCases {
            let files = try MatExport.write(r, engine: engine, to: folder.appendingPathComponent(f.suffix + f.rawValue.filter(\.isNumber)), format: f)
            XCTAssertEqual(files.count, r.plan.channels.count + 1, f.rawValue)
            for url in files {
                let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), url.lastPathComponent)
                let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
                XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 1 << g.size, url.lastPathComponent)
            }
        }
        if let out = ProcessInfo.processInfo.environment["MAT_PNG"] {
            for g in MaterialLibrary.all {
                let r = engine.evaluateNow(try MatPlan(g, library: { _ in nil }))
                try MatExport.write(r, engine: engine, to: URL(fileURLWithPath: out), format: .png8)
            }
        }
    }
}
