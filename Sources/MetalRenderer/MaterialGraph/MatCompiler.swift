import Foundation
import Metal
import QuartzCore

/// The material graph's kernels: the library of the nodes' kernels (ShadersMaterial.metal, compiled once), and the
/// pixel processors' and Code nodes' generated ones (ShadersMaterialCode.metal with their code spliced in after it,
/// a small library each, the last few kept: an edit often comes back to code it had). Compiled with the device's
/// compiler: the engine runs them on a Metal 3 queue of its own.
final class MatCompiler {
    static let shared = MatCompiler()
    static let kept = 12

    /// The entry files: next to Shaders.metal (`METALRENDERER_SHADERS`'s folder, if set).
    static var folder: URL {
        ProcessInfo.processInfo.environment["METALRENDERER_SHADERS"].map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private let lock = NSLock()
    private var base: (device: ObjectIdentifier, library: MTLLibrary)?
    private var states: [String: MTLComputePipelineState] = [:]
    private var generated: [String: Result<MTLComputePipelineState, MatError>] = [:]
    private var recent: [String] = []
    /// The base library's compile time (ms).
    private(set) var baseMilliseconds: Double?

    /// The base library (compiling it the first time, on the caller's thread).
    func library(_ device: MTLDevice) throws -> MTLLibrary {
        lock.lock()
        if let b = base, b.device == ObjectIdentifier(device) { lock.unlock(); return b.library }
        lock.unlock()
        let start = CACurrentMediaTime()
        let text = try ShaderSource.load(MatCompiler.folder.appendingPathComponent("ShadersMaterial.metal"))
        let library = try Pipelines.compile(device: device, text: text, stats: false, compiler: nil)
        lock.lock()
        base = (ObjectIdentifier(device), library)
        states = [:]
        baseMilliseconds = (CACurrentMediaTime() - start) * 1000
        lock.unlock()
        print(String(format: "Material library: compiled in %.0f ms", (CACurrentMediaTime() - start) * 1000))
        return library
    }

    /// The pipeline of kernel `name` of the base library.
    func state(_ name: String, device: MTLDevice) throws -> MTLComputePipelineState {
        let library = try library(device)
        lock.lock()
        if let s = states[name] { lock.unlock(); return s }
        lock.unlock()
        guard let f = library.makeFunction(name: name) else { throw MatError("no kernel \(name)") }
        let s = try device.makeComputePipelineState(function: f)
        lock.lock()
        states[name] = s
        lock.unlock()
        return s
    }

    /// The pipeline of a generated kernel (`mat_generated`, in `source`), compiling it on the caller's thread the
    /// first time; a failure is kept (its compiler's message) until the code changes.
    func generated(_ source: String, device: MTLDevice) -> Result<MTLComputePipelineState, MatError> {
        lock.lock()
        if let r = generated[source] {
            recent.removeAll { $0 == source }
            recent.insert(source, at: 0)
            lock.unlock()
            return r
        }
        lock.unlock()
        let result: Result<MTLComputePipelineState, MatError>
        do {
            let text = try ShaderSource.load(MatCompiler.folder.appendingPathComponent("ShadersMaterialCode.metal"))
                + "\n#line 1 \"generated\"\n" + source
            let library = try Pipelines.compile(device: device, text: text, stats: false, compiler: nil)
            guard let f = library.makeFunction(name: "mat_generated") else { throw MatError("no mat_generated kernel") }
            result = .success(try device.makeComputePipelineState(function: f))
        } catch let e as MatError {
            result = .failure(e)
        } catch {
            result = .failure(MatError(MatCompiler.shorten("\(error)")))
        }
        lock.lock()
        generated[source] = result
        recent.insert(source, at: 0)
        while recent.count > MatCompiler.kept, let last = recent.popLast() { generated[last] = nil }
        lock.unlock()
        return result
    }

    /// A compiler's message without its noise: the errors' lines, about the generated code.
    static func shorten(_ message: String) -> String {
        let lines = message.split(separator: "\n").filter { $0.contains("error:") }
        let kept = lines.map { line -> String in
            guard let r = line.range(of: "generated:") else { return String(line) }
            return String(line[r.upperBound...])
        }
        return kept.isEmpty ? message : kept.prefix(4).joined(separator: "\n")
    }

    // MARK: - Generated kernels

    /// A pixel processor's kernel: its function's body (MatFunction.code) as `float4 f(uv)`.
    static func pixelProcessorSource(_ body: String) -> String {
        """
        inline float4 matGeneratedFunction(float2 uv, float2 size, float seed, constant MatArgs& args,
                                           texture2d<float> in0, texture2d<float> in1, texture2d<float> in2, texture2d<float> in3) {
        #define sampleInput(i, at) matInput4(in0, in1, in2, in3, args, (i), (at))
        \(body)
        #undef sampleInput
        }

        kernel void mat_generated(MAT_KERNEL_ARGS) {
            MAT_PIXEL
            out0.write(matGeneratedFunction(uv, float2(a.size), float(a.seed & 0xffffu), a, in0, in1, in2, in3), gid);
        }
        """
    }

    /// A Code node's kernel: its text as the body of `float4 f(uv)`, with its parameters a, b, c, d.
    static func codeSource(_ body: String) -> String {
        """
        inline float4 matGeneratedFunction(float2 uv, float2 size, float seed, constant MatArgs& args, constant float4* p,
                                           texture2d<float> in0, texture2d<float> in1, texture2d<float> in2, texture2d<float> in3) {
            float a = p[1].x, b = p[2].x, c = p[3].x, d = p[4].x;
        #define sampleInput(i, at) matInput4(in0, in1, in2, in3, args, (i), (at))
        #line 1 "code"
        \(body)
        #undef sampleInput
        }

        kernel void mat_generated(MAT_KERNEL_ARGS) {
            MAT_PIXEL
            out0.write(matGeneratedFunction(uv, float2(a.size), float(a.seed & 0xffffu), a, p, in0, in1, in2, in3), gid);
        }
        """
    }
}
