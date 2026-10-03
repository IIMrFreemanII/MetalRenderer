import XCTest
import Metal
@testable import MetalRenderer

/// Kernel variants (Pipelines.swift): a kernel with a configuration's flags compiled in. The flag words are made
/// twice, in Swift for the variant's constants and in the shaders for the general pipeline, and must agree.
final class KernelVariantsTests: XCTestCase {
    private let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders.metal")

    /// `constant uint NAME = value` (also in a comma-separated list) in the shader source.
    private func shaderConstants() throws -> [String: UInt32] {
        let source = try ShaderSource.load(shaders, lineMarkers: false)
        var out: [String: UInt32] = [:]
        let regex = try NSRegularExpression(pattern: #"\b([A-Z][A-Z0-9_]+) *= *(\d+)u?\s*[,;]"#)
        for line in source.split(separator: "\n") where line.hasPrefix("constant uint ") || line.hasPrefix("              ") {
            let text = String(line)
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                out[String(text[Range(m.range(at: 1), in: text)!])] = UInt32(text[Range(m.range(at: 2), in: text)!])
            }
        }
        return out
    }

    func testFlagValuesMatchTheShader() throws {
        let msl = try shaderConstants()
        let pairs: [(String, UInt32)] = [
            ("FLAG_HISTORY_VALID", UniformFlags.historyValid), ("FLAG_DENOISE", UniformFlags.denoise),
            ("FLAG_UPSCALE", UniformFlags.upscale), ("FLAG_BLUE_NOISE", UniformFlags.blueNoise),
            ("FLAG_SEPARATE", UniformFlags.separateSignals), ("FLAG_NO_CLAMP", UniformFlags.noClamp),
            ("FLAG_LIGHT_MAPS", UniformFlags.lightMaps), ("FLAG_SHADOW_DENOISER", UniformFlags.shadowDenoiser),
            ("FLAG_ALL_LIGHTS", UniformFlags.allLights), ("FLAG_SPECULAR", UniformFlags.specular),
            ("FLAG_REFERENCE", UniformFlags.reference), ("FLAG_MESH_LIGHTS", UniformFlags.meshLights),
            ("FLAG_FOG", UniformFlags.fog), ("FLAG_FOG_REFERENCE", UniformFlags.fogReference),
            ("FLAG_SKY_MAP", UniformFlags.skyMap), ("FLAG_RESTIR", UniformFlags.restir),
            ("RESTIR_TEMPORAL_VALID", GPURestirParams.temporalValid), ("RESTIR_VISIBILITY", GPURestirParams.visibilityReuse),
            ("RESTIR_SHADE", GPURestirParams.shade), ("RESTIR_SPLIT", GPURestirParams.split),
            ("RGI_TEMPORAL_VALID", GPURestirGIParams.temporalValid), ("RGI_SHADE", GPURestirGIParams.shade),
            ("RGI_LIGHT_MAPS", GPURestirGIParams.lightMaps), ("RGI_FEEDBACK", GPURestirGIParams.feedback),
            ("RGI_UNBIASED", GPURestirGIParams.unbiased), ("RGI_KEEP_FEEDBACK", GPURestirGIParams.keepFeedback),
            ("RGI_FALLBACK", GPURestirGIParams.fallback), ("RGI_FEEDBACK_SET", GPURestirGIParams.feedbackSet),
            ("RGI_QUARTER", GPURestirGIParams.quarter),
            ("RGI_ONE_BOUNCE", GPURestirGIParams.oneBounce),
            ("TRACE_BOUNCES", Uniforms.traceBounces), ("TRACE_MANY_LIGHTS", Uniforms.traceManyLights),
            ("REFLECT_FOG", GPUFogParams.reflectionsFogged),
            ("FOG_HISTORY_VALID", GPUFogParams.historyValid), ("FOG_REFLECTIONS", GPUFogParams.reflections),
            ("FOG_ENABLED", GPUFogParams.enabled),
        ]
        for (name, value) in pairs { XCTAssertEqual(msl[name], value, name) }
        XCTAssertEqual(msl["SHADOW_GROUPS"], 4, "Uniforms.tracePassFlags compares with 4")
    }

    func testOwnFlagWords() {
        var u = Uniforms()
        XCTAssertEqual(u.tracePassFlags, 0)
        u.bounces = 3
        XCTAssertEqual(u.tracePassFlags, Uniforms.traceBounces)
        u.lightGroupEnd.w = 4
        XCTAssertEqual(u.tracePassFlags, Uniforms.traceBounces)
        u.lightGroupEnd.w = 5
        XCTAssertEqual(u.tracePassFlags, Uniforms.traceBounces | Uniforms.traceManyLights)

        var g = GPURestirGIParams()
        g.config.x = GPURestirGIParams.feedback
        g.extra = SIMD4(0, 2, 0, 0)
        XCTAssertEqual(g.initialPassFlags, GPURestirGIParams.feedback)
        g.extra = SIMD4(1, 1, 0, 0)
        XCTAssertEqual(g.initialPassFlags, GPURestirGIParams.feedback | GPURestirGIParams.quarter | GPURestirGIParams.oneBounce)

        var f = GPUFogParams()
        XCTAssertEqual(f.reflectionPassFlags, 0)
        f.counts.w = GPUFogParams.enabled | GPUFogParams.historyValid
        XCTAssertEqual(f.reflectionPassFlags, 0)
        f.counts.w = GPUFogParams.enabled | GPUFogParams.reflections
        XCTAssertEqual(f.reflectionPassFlags, GPUFogParams.reflectionsFogged)
    }

    /// A bit that flips on the first frame after a reset would have a variant compiled for that one frame.
    func testNoVariantForBitsThatChangeEveryReset() {
        for kernel in Kernel.allCases {
            XCTAssertEqual(kernel.fixedFlags & UniformFlags.historyValid, 0, "\(kernel)")
        }
        XCTAssertEqual(Kernel.restirTemporal.fixedPassFlags & GPURestirParams.temporalValid, 0)
        XCTAssertEqual(Kernel.restirSpatial.fixedPassFlags & GPURestirParams.temporalValid, 0)
        XCTAssertEqual(Kernel.restirGIInitial.fixedPassFlags & (GPURestirGIParams.temporalValid | GPURestirGIParams.feedback), 0)
    }

    /// Every kernel with variants compiles with its flags all off and all on, and flags outside its masks don't make
    /// another variant.
    func testVariantsCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        guard KernelVariants.enabled else { throw XCTSkip("METALRENDERER_VARIANTS=0") }
        let pipelines = try Pipelines(device: device, source: shaders, kind: .custom, lightTypes: 0x3F, stats: false)
        var expected = 0
        for kernel in Kernel.allCases where kernel.fixedFlags | kernel.fixedPassFlags != 0 {
            let off = pipelines.state(kernel, flags: 0, pass: 0, wait: true)
            let on = pipelines.state(kernel, flags: ~0, pass: ~0, wait: true)
            XCTAssertFalse(off === pipelines[kernel], "\(kernel): no variant")
            XCTAssertFalse(on === off, "\(kernel)")
            let again = pipelines.state(kernel, flags: ~kernel.fixedFlags, pass: ~kernel.fixedPassFlags, wait: true)
            XCTAssertTrue(again === off, "\(kernel): bits outside its masks made another variant")
            expected += 2
        }
        XCTAssertEqual(pipelines.variants.count, expected)
        XCTAssertTrue(pipelines.state(.composite, flags: ~0, wait: true) === pipelines[.composite], "composite has no variants")
    }
}
