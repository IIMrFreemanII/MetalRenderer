import Foundation
import simd

/// A graph as code the shading runs (the shader-code mode: MatSurface.shaderMode) instead of baked textures: each node
/// a Metal function of the UV (MaterialShaders' functions, compiled into the main library with MAT_EVAL_ONLY), its
/// inputs calls of the nodes wired into it at the UV it reads them at (a transform's, a warp's, a normal's four
/// neighbours'), its parameters read from a buffer (SceneShading.procParams: a value's edit is a write, not a compile).
/// Resolution-free, and as sharp as the view is near. Only graphs whose nodes read their inputs at a few places
/// qualify (`reasons`): no blurs, distances, flood fills, occlusion, bitmaps; and within a budget of node evaluations
/// a shading point.
///
/// Every scene's programs are one splice (`splice`): their node functions and `proceduralMaterial(program, uv, P)`,
/// which Shaders/Procedural.metal stands in for until there is one (ShaderSource.procedural).
enum MatShaderCode {
    /// Node evaluations a shading point may cost (each node counted as often as it is called).
    static let budget = 160

    /// The kinds that can run as code.
    static let supported: Set<MatOpKind> = [.input, .output, .uniform, .uniformColor, .whiteNoise, .valueNoise, .perlinNoise, .fractalSum,
                                            .cells, .anisotropicNoise, .scratches, .grunge, .shape, .gradient, .checker, .bricks, .waves,
                                            .levels, .curve, .gradientMap, .hsl, .invert, .grayscale, .histogramScan, .posterize,
                                            .rgbaSplit, .rgbaMerge, .blend, .heightBlend, .transform, .mirror, .warp, .directionalWarp,
                                            .normal, .normalCombine, .curvature, .pixelProcessor, .code]

    /// Why `plan` can't run as code, by node (empty: it can).
    static func reasons(_ plan: MatPlan) -> [String: String] {
        var out: [String: String] = [:]
        let reached = reachedSteps(plan)
        for k in reached where !supported.contains(plan.steps[k].kind) {
            out[plan.steps[k].id] = "\(plan.steps[k].kind.spec.title) reads its input everywhere: it can only be baked"
        }
        if out.isEmpty {
            let cost = evaluations(plan)
            if cost > budget { out[""] = "\(cost) node evaluations a shading point (more than \(budget)): bake it" }
        }
        return out
    }

    /// The steps the outputs reach.
    static func reachedSteps(_ plan: MatPlan) -> Set<Int> {
        var seen = Set<Int>(), stack = Array(plan.channels.values)
        while let k = stack.popLast() {
            guard seen.insert(k).inserted else { continue }
            for s in plan.steps[k].inputs.compactMap({ $0 }) { stack.append(s.step) }
        }
        return seen
    }

    /// How many times a shading point evaluates a node: each output once, each node's inputs as many times as it
    /// reads them (a normal four, a warp five...).
    static func evaluations(_ plan: MatPlan) -> Int {
        var calls = [Int](repeating: 0, count: plan.steps.count)
        for k in plan.channels.values { calls[k] += 1 }
        for k in plan.steps.indices.reversed() where calls[k] > 0 {
            let step = plan.steps[k]
            for (i, src) in step.inputs.enumerated() {
                guard let src else { continue }
                calls[src.step] += calls[k] * taps(step.kind, input: i)
            }
        }
        return calls.reduce(0, +)
    }

    private static func taps(_ kind: MatOpKind, input: Int) -> Int {
        switch kind {
        case .normal: return 4
        case .curvature: return 5
        case .warp: return input == 1 ? 4 : 1
        default: return 1
        }
    }

    // MARK: - Code

    /// A program: its Metal (its nodes' functions, and the body of its case in proceduralMaterial), its parameters
    /// (each node's, packed, then its curves' and gradients' tables) at `base` in the buffer.
    struct Program {
        var functions: String
        var body: String
        var params: [SIMD4<Float>]
    }

    /// Program `number` of `plan`, its parameters at float4 `base` of the buffer.
    static func program(_ plan: MatPlan, number: Int, base: Int) throws -> Program {
        let reached = reachedSteps(plan)
        if let bad = reasons(plan).first { throw MatError(bad.key.isEmpty ? bad.value : "\(bad.key): \(bad.value)") }
        var params: [SIMD4<Float>] = []
        var offset: [Int: Int] = [:], lut: [Int: Int] = [:]
        for k in plan.steps.indices where reached.contains(k) {
            offset[k] = base + params.count
            params += plan.steps[k].params.isEmpty ? [.zero] : plan.steps[k].params
        }
        for k in plan.steps.indices where reached.contains(k) && !plan.steps[k].luts.isEmpty {
            lut[k] = base + params.count
            for t in plan.steps[k].luts { params += t }
        }
        func name(_ k: Int, _ o: Int) -> String { "mp\(number)_\(k)_\(o)" }
        var lines: [String] = []
        for k in plan.steps.indices where reached.contains(k) {
            let step = plan.steps[k]
            let p = "(P + \(offset[k]!))"
            let pins = step.kind.spec.inputs
            /// Input i at `at` as the node reads it (grey as grey, a colour into a grey pin as its luminance), or `otherwise`.
            func input(_ i: Int, _ at: String, _ otherwise: String = "float4(0, 0, 0, 1)") -> String {
                guard i < step.inputs.count, let src = step.inputs[i] else { return otherwise }
                let mode = src.type == .grey ? 1 : (pins.indices.contains(i) && pins[i].type == .grey ? 2 : 0)
                return "matAsInput(\(name(src.step, src.output))(\(at), P), \(mode))"
            }
            func texel(_ i: Int) -> String {
                let n = i < step.inputs.count ? step.inputs[i].map { plan.steps[$0.step].pixels } ?? step.pixels : step.pixels
                return "float2(\(MatFunction.literal(1 / Float(n))))"
            }
            let seed = "\(step.seed)u"
            for o in step.outputs.indices {
                var body: String
                switch step.kind {
                case .input, .uniform, .uniformColor: body = "return \(p)[0];"
                case .output: body = "return \(input(0, "uv"));"
                case .whiteNoise: body = "return float4(matWhiteNoiseAt(uv, float2(\(step.pixels)), \(p), \(seed)));"
                case .valueNoise: body = "return float4(matValueNoiseAt(uv, \(p), \(seed)));"
                case .perlinNoise: body = "return float4(matPerlinAt(uv, \(p), \(seed)));"
                case .fractalSum: body = "return float4(matFractalAt(uv, \(p), \(seed)));"
                case .cells: body = "return float4(matCellsValue(uv, \(p), \(seed)));"
                case .anisotropicNoise: body = "return float4(matAnisotropicAt(uv, \(p), \(seed)));"
                case .scratches: body = "return float4(matScratchesAt(uv, \(p), \(seed)));"
                case .grunge: body = "return float4(matGrungeAt(uv, \(p), \(seed)));"
                case .shape: body = "return float4(matShapeAt(uv, \(p)));"
                case .gradient: body = "return float4(matGradientAt(uv, \(p)));"
                case .checker: body = "return float4(matCheckerAt(uv, \(p)));"
                case .waves: body = "return float4(matWavesAt(uv, \(p)));"
                case .bricks: body = "return float4(matBricksAt(uv, \(p), \(seed)).\(o == 0 ? "x" : "y"));"
                case .levels: body = "return matLevels(\(input(0, "uv")), \(p));"
                case .curve: body = "return matCurve(\(input(0, "uv")), \(p), P + \(lut[k] ?? 0));"
                case .gradientMap: body = "return matGradientMap(\(input(0, "uv")), \(p), P + \(lut[k] ?? 0));"
                case .hsl: body = "return matHSL(\(input(0, "uv")), \(p));"
                case .invert: body = "float4 v = \(input(0, "uv")); return float4(1.0 - v.rgb, v.a);"
                case .grayscale: body = "return matGrayscale(\(input(0, "uv")), \(p));"
                case .histogramScan: body = "return matHistogramScan(\(input(0, "uv")), \(p));"
                case .posterize: body = "return matPosterize(\(input(0, "uv")), \(p));"
                case .rgbaSplit: body = "return float4(\(input(0, "uv"))[\(o)]);"
                case .rgbaMerge:
                    body = "float4 f = \(p)[0]; return float4(\(input(0, "uv", "f.rrrr")).r, \(input(1, "uv", "f.gggg")).r, "
                        + "\(input(2, "uv", "f.bbbb")).r, \(input(3, "uv", "f.aaaa")).r);"
                case .blend: body = "return matBlend(\(input(0, "uv")), \(input(1, "uv")), \(input(2, "uv", "float4(1)")).r, \(p));"
                case .heightBlend:
                    body = "float2 v = matHeightBlend(\(input(0, "uv", "float4(0)")).r, \(input(1, "uv", "float4(0)")).r, "
                        + "\(input(2, "uv", "float4(1)")).r, \(p)); return float4(v.\(o == 0 ? "x" : "y"));"
                case .normalCombine:
                    body = "return matNormalCombine(\(input(0, "uv", "float4(0.5, 0.5, 1, 1)")), \(input(1, "uv", "float4(0.5, 0.5, 1, 1)")), \(p));"
                case .transform: body = "return \(input(0, "matTransformUV(uv, \(p))"));"
                case .mirror: body = "return \(input(0, "matMirrorUV(uv, \(p))"));"
                case .directionalWarp: body = "return \(input(0, "matDirectionalWarpUV(uv, \(input(1, "uv", "float4(1)")).r, \(p))"));"
                case .warp:
                    let t = texel(1)
                    body = "float2 t = \(t); float dx = \(input(1, "uv + float2(t.x, 0)", "float4(0)")).r - \(input(1, "uv - float2(t.x, 0)", "float4(0)")).r; "
                        + "float dy = \(input(1, "uv + float2(0, t.y)", "float4(0)")).r - \(input(1, "uv - float2(0, t.y)", "float4(0)")).r; "
                        + "return \(input(0, "matWarpUV(uv, float2(dx, dy) / (2.0 * t), \(p))"));"
                case .normal:
                    body = "float2 t = \(texel(0)); float l = \(input(0, "uv - float2(t.x, 0)")).r, r = \(input(0, "uv + float2(t.x, 0)")).r; "
                        + "float up = \(input(0, "uv - float2(0, t.y)")).r, down = \(input(0, "uv + float2(0, t.y)")).r; "
                        + "return matNormalFromSlope(float2(r - l, up - down) / (2.0 * t), \(p));"
                case .curvature:
                    body = "float2 t = \(texel(0)); float c = \(input(0, "uv")).r; "
                        + "float lap = (\(input(0, "uv - float2(t.x, 0)")).r + \(input(0, "uv + float2(t.x, 0)")).r - 2.0 * c) / (t.x * t.x) "
                        + "+ (\(input(0, "uv - float2(0, t.y)")).r + \(input(0, "uv + float2(0, t.y)")).r - 2.0 * c) / (t.y * t.y); "
                        + "return float4(matCurvatureFrom(lap, \(p)));"
                case .pixelProcessor, .code:
                    // Its inputs as a function of the place they are read at; then its code.
                    let dispatcher = "\(name(k, 0))_in"
                    lines.append("inline float4 \(dispatcher)(int i, float2 at, device const float4* P) {")
                    lines.append("    switch (i) {")
                    for i in 0..<4 { lines.append("        case \(i): return \(input(i, "at"));") }
                    lines.append("        default: return float4(0, 0, 0, 1);")
                    lines.append("    }")
                    lines.append("}")
                    let code: String
                    if step.kind == .code {
                        code = "float a = \(p)[1].x, b = \(p)[2].x, c = \(p)[3].x, d = \(p)[4].x;\n" + step.node.text("code")
                    } else {
                        code = try (step.node.function ?? .passThrough).code().metal
                    }
                    body = "float2 size = float2(\(step.pixels)); float seed = float(\(step.seed & 0xffff));\n"
                        + "#define sampleInput(i, at) \(dispatcher)((i), (at), P)\n\(code)\n#undef sampleInput"
                default:
                    throw MatError("\(step.id): \(step.kind.spec.title) can't run as code")
                }
                lines.append("inline float4 \(name(k, o))(float2 uv, device const float4* P) {")
                lines.append("    \(body)")
                lines.append("}")
            }
        }
        // The case: the channels as the renderer's textures would hold them (MatEngine.pack).
        var body: [String] = []
        func channel(_ c: MatChannel) -> String? { plan.channels[c].map { "matAsInput(\(name($0, 0))(uv, P), \(plan.steps[$0].outputs[0] == .grey ? 1 : 0))" } }
        if let v = channel(.baseColor) { body.append("s.base = \(v); s.has |= 1u;") }
        let ao = channel(.ambientOcclusion), rough = channel(.roughness), metal = channel(.metallic)
        if ao != nil || rough != nil || metal != nil {
            body.append("s.orm = float4(\(ao.map { "\($0).r" } ?? "1.0"), \(rough.map { "\($0).r" } ?? "0.5"), \(metal.map { "\($0).r" } ?? "0.0"), 1); s.has |= 2u;")
        }
        if let v = channel(.normal) {
            body.append("s.normal = \(v);\(plan.surface.normalDirectX ? " s.normal.g = 1.0 - s.normal.g;" : "") s.has |= 4u;")
        }
        if let v = channel(.emissive) { body.append("s.emissive = \(v); s.has |= 8u;") }
        return Program(functions: lines.joined(separator: "\n"), body: body.joined(separator: " "), params: params)
    }

    /// The splice of `programs` (by number): MaterialShaders' functions, the programs' nodes, the dispatcher.
    static func splice(_ programs: [(number: Int, program: Program)]) throws -> String {
        guard !programs.isEmpty else { return "" }
        var text = "#define MAT_EVAL_ONLY 1\n#define MAT_PROCEDURAL 1\n"
        for piece in ["MatCommon", "MatNoise", "MatPatterns", "MatAdjust", "MatFilters", "MatHeight"] {
            let url = MatCompiler.folder.appendingPathComponent("MaterialShaders/\(piece).metal")
            text += "#line 1 \"MaterialShaders/\(piece).metal\"\n" + (try String(contentsOf: url, encoding: .utf8)) + "\n"
        }
        text += """
        #line 1 "procedural"
        // A node's value as its consumer reads it: as it is (0), a grey's R as R, G, B (1), a colour's luminance (2).
        inline float4 matAsInput(float4 v, int mode) {
            if (mode == 1) return float4(v.rrr, 1);
            if (mode == 2) { float l = dot(v.rgb, MAT_LUMA); return float4(l, l, l, 1); }
            return v;
        }

        """
        for p in programs { text += p.program.functions + "\n" }
        text += "inline ProcSample proceduralMaterial(uint program, float2 uv, device const float4* P) {\n"
        text += "    ProcSample s = { float4(0.5), float4(1, 0.5, 0, 1), float4(0.5, 0.5, 1, 1), float4(0), 0u };\n"
        text += "    switch (program) {\n"
        for p in programs { text += "        case \(p.number)u: { \(p.program.body) break; }\n" }
        text += "        default: break;\n    }\n    return s;\n}\n"
        return text
    }
}
