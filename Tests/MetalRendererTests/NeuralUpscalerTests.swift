import XCTest
import Metal
@testable import MetalRenderer

/// The neural upscaler's kernels (Shaders/Neural.metal) against the PyTorch model they implement (Tools/neural):
/// Neural/golden.nnw holds seeded weights, two frames of inputs and PyTorch's output for each (export.py --golden).
/// Two frames, so the second one checks the warp of the history and the state too.
final class NeuralUpscalerTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    private var shaders: URL {
        root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders.metal")
    }

    /// A shared texture of `format` holding `values` (height x width x channels, channel-last; missing channels 1).
    private func texture(_ device: MTLDevice, _ values: [Float], width: Int, height: Int, channels: Int,
                         format: MTLPixelFormat) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        let t = try XCTUnwrap(device.makeTexture(descriptor: d))
        let texel = Benchmark.layout(format).channels
        var halves = [Float16](repeating: 1, count: width * height * texel)
        for i in 0..<width * height { for c in 0..<channels { halves[i * texel + c] = Float16(values[i * channels + c]) } }
        t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: halves, bytesPerRow: width * texel * 2)
        return t
    }

    func testKernelsMatchThePyTorchModel() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let golden = try NeuralWeights(url: root.appendingPathComponent("Neural/golden.nnw"), device: device)
        let pipelines = try Pipelines(device: device, source: shaders, lightTypes: 0x3F, stats: false)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let shape = golden.shape("f0.color")
        let (h, w, f) = (shape[0], shape[1], golden.factor)
        let net = try NeuralUpscaler(device: device, weights: golden, inputWidth: w, inputHeight: h)
        let readback = try XCTUnwrap(device.makeBuffer(length: w * f * h * f * 8, options: .storageModeShared))

        for t in 0..<2 {
            func input(_ name: String, _ channels: Int, _ format: MTLPixelFormat) throws -> MTLTexture {
                try texture(device, XCTUnwrap(golden.floats("f\(t).\(name)")), width: w, height: h, channels: channels, format: format)
            }
            let jitter = try XCTUnwrap(golden.floats("f\(t).jitter")), exposure = try XCTUnwrap(golden.floats("f\(t).exposure"))
            let inputs = NeuralInputs(color: try input("color", 3, .rgba16Float), albedo: try input("albedo", 3, .rgba16Float),
                                      specular: try input("specular", 3, .rgba16Float), normalDepth: try input("normal", 4, .rgba16Float),
                                      roughness: try input("roughness", 1, .r16Float), motion: try input("motion", 2, .rg16Float),
                                      jitter: SIMD2(jitter[0], jitter[1]), exposure: exposure[0], reset: t == 0)
            let frame = try XCTUnwrap(Metal3Frame(queue: queue, profile: nil, split: false, overlap: false))
            frame.run(net.stages(pipelines.neural, inputs))
            frame.capture(net.hdrOutput, into: readback)
            frame.commit(presenting: nil, wait: true) { _ in }

            let expected = try XCTUnwrap(golden.floats("f\(t).output"))
            let got = readback.contents().bindMemory(to: Float16.self, capacity: w * f * h * f * 4)
            let floor = 0.1 * (expected.map(abs).max() ?? 1)   // relative error, absolute near black
            var worst: Float = 0
            for i in 0..<w * f * h * f {
                for c in 0..<3 {
                    let e = expected[i * 3 + c], g = Float(got[i * 4 + c])
                    worst = max(worst, abs(g - e) / max(abs(e), floor))
                }
            }
            XCTAssertLessThan(worst, 0.01, "frame \(t): worst relative error \(worst)")
        }
    }
}
