import Foundation
import Metal

/// A .nnw file (Tools/neural/export.py): the net's shape and named tensors, float16 weights in one buffer.
/// "NNW1", a little-endian UInt32 header length, a JSON header, then the data (offsets in the header are into it).
final class NeuralWeights {
    struct Header: Decodable {
        struct Tensor: Decodable { let name: String; let shape: [Int]; let dtype: String; let offset: Int }
        let factor: Int
        let guides: Int
        let hidden: Int
        let widths: [Int]
        let tensors: [Tensor]
    }

    let header: Header
    let data: Data            // everything after the header
    let buffer: MTLBuffer     // `data` on the GPU
    private let tensors: [String: Header.Tensor]

    var factor: Int { header.factor }
    /// Per output pixel: 3 (log) colour channels and the hidden state.
    var stateChannels: Int { 3 + header.hidden }

    init(url: URL, device: MTLDevice) throws {
        let file = try Data(contentsOf: url)
        guard file.count > 8, file.prefix(4) == Data("NNW1".utf8) else { throw NeuralError.format(url.path) }
        let length = Int(file.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        header = try JSONDecoder().decode(Header.self, from: file.subdata(in: 8..<8 + length))
        data = file.subdata(in: 8 + length..<file.count)
        tensors = Dictionary(uniqueKeysWithValues: header.tensors.map { ($0.name, $0) })
        guard let buffer = data.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared) })
        else { throw NeuralError.format(url.path) }
        self.buffer = buffer
    }

    /// The weights the app uses: `METALRENDERER_NEURAL=<file>`, else Assets/Neural/denoiser.nnw; nil when there are none.
    static func load(device: MTLDevice) -> NeuralWeights? {
        let url = ProcessInfo.processInfo.environment["METALRENDERER_NEURAL"].map { URL(fileURLWithPath: $0) }
            ?? Scene.assetsDirectory.appendingPathComponent("Neural/denoiser.nnw")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try NeuralWeights(url: url, device: device) } catch {
            print("Neural upscaler: can't read \(url.path): \(error)")
            return nil
        }
    }

    /// Byte offset of tensor `name` in `buffer`.
    func offset(_ name: String) -> Int { tensors[name]!.offset }

    func shape(_ name: String) -> [Int] { tensors[name]?.shape ?? [] }

    /// A float32 tensor's values (the golden vectors' inputs and outputs, NeuralUpscalerTests).
    func floats(_ name: String) -> [Float]? {
        guard let t = tensors[name], t.dtype == "f32" else { return nil }
        let count = t.shape.reduce(1, *)
        return data.subdata(in: t.offset..<t.offset + count * 4).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

enum NeuralError: Error {
    case format(String)
    case memory
}

struct NeuralPipelines {
    let warp, prepare, conv, pool, finish: MTLComputePipelineState
}

/// What the net reads each frame: the composite's noisy light and its guides (render resolution, as MetalFX gets them).
struct NeuralInputs {
    let color, albedo, specular, normalDepth, roughness, motion: MTLTexture
    let jitter: SIMD2<Float>
    let exposure: Float
    let reset: Bool
}

/// NeuralParams in Shaders/Neural.metal.
struct GPUNeuralParams {
    var size = SIMD4<UInt32>()
    var channels = SIMD4<UInt32>()
    var frame = SIMD4<Float>()
    var shape = SIMD4<UInt32>()
}

/// Our own denoising upscaler, in place of MetalFX's (RenderSettings.upscaler): the net Tools/neural trains, run by
/// the kernels in Shaders/Neural.metal at a fixed factor (the weights'). It owns its tensors, sized for one render
/// resolution (padded to a multiple of 4 for the U-Net's two halvings), and last frame's output and state.
final class NeuralUpscaler {
    let weights: NeuralWeights
    let inputWidth, inputHeight: Int
    var factor: Int { weights.factor }
    var outputWidth: Int { inputWidth * factor }
    var outputHeight: Int { inputHeight * factor }
    /// Linear light before exposure at the output resolution, for tonemapKernel.
    let hdrOutput: MTLTexture

    private let width, height: Int   // padded
    private let state, warped, x, head: MTLBuffer
    private let full: [MTLBuffer], half: [MTLBuffer], quarter: [MTLBuffer]   // the U-Net's activations at each level
    static let relu: UInt32 = 1, upsample: UInt32 = 2, reset: UInt32 = 4   // NEURAL_* in Neural.metal

    init(device: MTLDevice, weights: NeuralWeights, inputWidth: Int, inputHeight: Int) throws {
        self.weights = weights
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        width = (inputWidth + 3) / 4 * 4
        height = (inputHeight + 3) / 4 * 4
        let f = weights.factor, n = width * height, w = weights.header.widths
        func buffer(_ channels: Int, _ pixels: Int) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: channels * pixels * 2, options: .storageModePrivate) else { throw NeuralError.memory }
            return b
        }
        state = try buffer(weights.stateChannels, n * f * f)
        warped = try buffer(weights.stateChannels, n * f * f)
        x = try buffer(16 + f * f * weights.stateChannels, n)
        head = try buffer(f * f * (1 + weights.stateChannels), n)
        full = try (0..<3).map { _ in try buffer(max(w[0], 16), n) }
        half = try (0..<3).map { _ in try buffer(w[1], n / 4) }
        quarter = try (0..<3).map { _ in try buffer(w[2], n / 16) }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: inputWidth * f, height: inputHeight * f,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let out = device.makeTexture(descriptor: d) else { throw NeuralError.memory }
        hdrOutput = out
    }

    /// The frame's dispatches, in pass `pass`.
    func stages(_ p: NeuralPipelines, _ inputs: NeuralInputs, pass: String = "neural") -> [ComputeStage] {
        [ComputeStage(pass: pass) { [self] enc in encode(p, inputs, into: enc) }]
    }

    private func encode(_ p: NeuralPipelines, _ inputs: NeuralInputs, into enc: ComputePass) {
        let f = factor, s = UInt32(weights.stateChannels), w = weights.header.widths.map { UInt32($0) }
        var params = GPUNeuralParams()
        params.size.z = UInt32(inputWidth)
        params.size.w = UInt32(inputHeight)
        params.frame = SIMD4(inputs.exposure, inputs.jitter.x, inputs.jitter.y, 0)
        params.shape = SIMD4(UInt32(f), s, UInt32(outputWidth), UInt32(outputHeight))
        func set(_ width: Int, _ height: Int, _ c0: UInt32 = 0, _ c1: UInt32 = 0, _ out: UInt32 = 0, _ flags: UInt32 = 0) {
            params.size.x = UInt32(width)
            params.size.y = UInt32(height)
            params.channels = SIMD4(c0, c1, out, flags)
            enc.setBytes(&params, length: MemoryLayout<GPUNeuralParams>.stride, index: 0)
        }
        func dispatch(_ width: Int, _ height: Int, _ depth: Int = 1) {
            enc.dispatchThreads(MTLSize(width: width, height: height, depth: depth),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        }
        func barrier() { enc.memoryBarrier(scope: .buffers) }
        // 3x3 convolution `layer` ("enc0.0") of `a` (+ `b`, concatenated) into `out`, at `level` (0 full, 1 half, 2 quarter).
        func conv(_ layer: String, _ a: MTLBuffer, _ ca: UInt32, _ b: MTLBuffer?, _ cb: UInt32, _ out: MTLBuffer, _ cout: UInt32,
                  level: Int, flags: UInt32 = NeuralUpscaler.relu) {
            let lw = width >> level, lh = height >> level
            enc.setComputePipelineState(p.conv)
            set(lw, lh, ca, cb, cout, flags)
            enc.setBuffer(a, offset: 0, index: 1)
            enc.setBuffer(b ?? a, offset: 0, index: 2)
            enc.setBuffer(weights.buffer, offset: weights.offset(layer + ".weight"), index: 3)
            enc.setBuffer(weights.buffer, offset: weights.offset(layer + ".bias"), index: 4)
            enc.setBuffer(out, offset: 0, index: 5)
            dispatch(lw, lh, Int(cout) / 4)
            barrier()
        }
        func pool(_ a: MTLBuffer, _ channels: UInt32, _ out: MTLBuffer, level: Int) {
            enc.setComputePipelineState(p.pool)
            set(width >> level, height >> level, 0, 0, channels)
            enc.setBuffer(a, offset: 0, index: 1)
            enc.setBuffer(out, offset: 0, index: 2)
            dispatch(width >> level, height >> level, Int(channels))
            barrier()
        }

        // Last frame's output and state, warped; the input tensor.
        enc.setComputePipelineState(p.warp)
        set(width * f, height * f, 0, 0, 0, inputs.reset ? NeuralUpscaler.reset : 0)
        enc.setBuffer(state, offset: 0, index: 1)
        enc.setBuffer(warped, offset: 0, index: 2)
        enc.setTexture(inputs.motion, index: 0)
        dispatch(width * f, height * f)
        barrier()
        enc.setComputePipelineState(p.prepare)
        set(width, height)
        enc.setBuffer(warped, offset: 0, index: 1)
        enc.setBuffer(x, offset: 0, index: 2)
        for (i, t) in [inputs.color, inputs.albedo, inputs.specular, inputs.normalDepth, inputs.roughness].enumerated() {
            enc.setTexture(t, index: i)
        }
        dispatch(width, height)
        barrier()

        // The U-Net (model.py's forward).
        let cin = UInt32(16 + f * f * Int(s))
        conv("enc0.0", x, cin, nil, 0, full[0], w[0], level: 0)
        conv("enc0.1", full[0], w[0], nil, 0, full[1], w[0], level: 0)                // e0
        pool(full[1], w[0], half[0], level: 1)
        conv("enc1.0", half[0], w[0], nil, 0, half[1], w[1], level: 1)
        conv("enc1.1", half[1], w[1], nil, 0, half[2], w[1], level: 1)                // e1
        pool(half[2], w[1], quarter[0], level: 2)
        conv("mid.0", quarter[0], w[1], nil, 0, quarter[1], w[2], level: 2)
        conv("mid.1", quarter[1], w[2], nil, 0, quarter[2], w[2], level: 2)           // m
        conv("dec1.0", quarter[2], w[2], half[2], w[1], half[0], w[1], level: 1, flags: NeuralUpscaler.relu | NeuralUpscaler.upsample)
        conv("dec1.1", half[0], w[1], nil, 0, half[1], w[1], level: 1)                // d1
        conv("dec0.0", half[1], w[1], full[1], w[0], full[0], w[0], level: 0, flags: NeuralUpscaler.relu | NeuralUpscaler.upsample)
        conv("dec0.1", full[0], w[0], nil, 0, full[2], w[0], level: 0)                // d0
        conv("head", full[2], w[0], nil, 0, head, UInt32(f * f) * (1 + s), level: 0, flags: 0)

        // Unfold, blend, write the state and the light.
        enc.setComputePipelineState(p.finish)
        set(width * f, height * f)
        enc.setBuffer(head, offset: 0, index: 1)
        enc.setBuffer(warped, offset: 0, index: 2)
        enc.setBuffer(state, offset: 0, index: 3)
        enc.setTexture(hdrOutput, index: 0)
        dispatch(width * f, height * f)
    }
}
