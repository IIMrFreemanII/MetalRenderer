import Foundation
import Metal

/// A .nnw file (Tools/neural/export.py): the net's shape and named tensors, float16 weights in one buffer.
/// "NNW1", a little-endian UInt32 header length, a JSON header, then the data (offsets in the header are into it).
final class NeuralWeights {
    struct Header: Decodable {
        struct Tensor: Decodable { let name: String; let shape: [Int]; let dtype: String; let offset: Int }
        /// model.py's `arch`; a file without one has the first net's.
        struct Arch: Decodable {
            var inputs = "v1"      // "v2": the light in parts and the history validity too (RenderTargets.split)
            var head = "direct"    // "kernel": filter weights over the noisy light and the history, not a colour
            var warp = "bilinear"  // or "bicubic"
            init() {}
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                inputs = try c.decodeIfPresent(String.self, forKey: .inputs) ?? inputs
                head = try c.decodeIfPresent(String.self, forKey: .head) ?? head
                warp = try c.decodeIfPresent(String.self, forKey: .warp) ?? warp
            }
            private enum CodingKeys: String, CodingKey { case inputs, head, warp }
        }
        let factor: Int
        let guides: Int
        let hidden: Int
        let widths: [Int]
        let arch: Arch
        let tensors: [Tensor]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            factor = try c.decode(Int.self, forKey: .factor)
            guides = try c.decode(Int.self, forKey: .guides)
            hidden = try c.decode(Int.self, forKey: .hidden)
            widths = try c.decode([Int].self, forKey: .widths)
            arch = try c.decodeIfPresent(Arch.self, forKey: .arch) ?? Arch()
            tensors = try c.decode([Tensor].self, forKey: .tensors)
        }
        private enum CodingKeys: String, CodingKey { case factor, guides, hidden, widths, arch, tensors }
    }

    let header: Header
    let data: Data            // everything after the header
    let buffer: MTLBuffer     // `data` on the GPU
    /// The convolutions' weights as neuralConvKernel reads them: per layer [tap][output, padded to 32][input, padded to
    /// 8] (PyTorch's are [output][input][ky][kx]), zeros in the padding.
    let packed: MTLBuffer
    private var packedOffsets: [String: Int] = [:]
    private let tensors: [String: Header.Tensor]
    static let tileOutputs = 32, tileInputs = 8   // NEURAL_TILE_COUT, and 8 input channels a step

    var factor: Int { header.factor }
    /// The kernel head (filter weights, the light in parts).
    var kernelHead: Bool { header.arch.head == "kernel" }
    /// It reads the light in parts too (the composite's FLAG_SPLIT_OUTPUT).
    var wantsSplit: Bool { header.arch.inputs == "v2" }
    /// Per output pixel: 3 (log) colour channels, or the kernel head's log diffuse, specular and extra light and the
    /// accumulated albedo and specular albedo; then the hidden state.
    var stateChannels: Int { (kernelHead ? 15 : 3) + header.hidden }
    /// Per output pixel, from the head: a blend weight and a colour, or 3 x 10 filter logits and the colours' blend
    /// weight; then the hidden state.
    var headChannels: Int { (kernelHead ? 31 : 4) + header.hidden }

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

        var packedData: [Float16] = []
        for t in header.tensors where t.dtype == "f16" && t.shape.count == 4 && t.shape[2] == 3 && t.shape[3] == 3 {
            let (cout, cin) = (t.shape[0], t.shape[1])
            let coutPad = (cout + Self.tileOutputs - 1) / Self.tileOutputs * Self.tileOutputs
            let cinPad = (cin + Self.tileInputs - 1) / Self.tileInputs * Self.tileInputs
            packedOffsets[t.name] = packedData.count * 2
            var layer = [Float16](repeating: 0, count: 9 * coutPad * cinPad)
            data.withUnsafeBytes { raw in
                let w = raw.baseAddress!.advanced(by: t.offset).assumingMemoryBound(to: Float16.self)
                for co in 0..<cout { for ci in 0..<cin { for k in 0..<9 {
                    layer[(k * coutPad + co) * cinPad + ci] = w[(co * cin + ci) * 9 + k]
                } } }
            }
            packedData += layer
        }
        guard let packed = packedData.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared) })
        else { throw NeuralError.format(url.path) }
        self.packed = packed
    }

    /// Byte offset of convolution `name`'s ("enc0.0.weight") repacked weights in `packed`.
    func packedOffset(_ name: String) -> Int { packedOffsets[name]! }

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
    let warp, prepare, conv, pool, finish, kernelFinish: MTLComputePipelineState
}

/// What the net reads each frame: the composite's noisy light and its guides (render resolution, as MetalFX gets them),
/// and for v2 nets the light in parts (RenderTargets.split: diffuse, specular, extra with the history validity).
struct NeuralInputs {
    let color, albedo, specular, normalDepth, roughness, motion: MTLTexture
    var split: (diffuse: MTLTexture, specular: MTLTexture, extra: MTLTexture)? = nil
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
/// resolution (padded to a multiple of 2^(levels - 1) for the U-Net's halvings), and last frame's output and state.
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
    private let levels: [[MTLBuffer]]   // the U-Net's activations at each level (full, half, ... resolution), 3 each
    static let relu: UInt32 = 1, upsample: UInt32 = 2, reset: UInt32 = 4, bicubic: UInt32 = 8   // NEURAL_* in Neural.metal

    init(device: MTLDevice, weights: NeuralWeights, inputWidth: Int, inputHeight: Int) throws {
        self.weights = weights
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        let w = weights.header.widths, step = 1 << (w.count - 1)
        width = (inputWidth + step - 1) / step * step
        height = (inputHeight + step - 1) / step * step
        let f = weights.factor, n = width * height
        func buffer(_ channels: Int, _ pixels: Int) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: channels * pixels * 2, options: .storageModePrivate) else { throw NeuralError.memory }
            return b
        }
        state = try buffer(weights.stateChannels, n * f * f)
        warped = try buffer(weights.stateChannels, n * f * f)
        x = try buffer(weights.header.guides + 2 + f * f * weights.stateChannels, n)
        head = try buffer(f * f * weights.headChannels, n)
        levels = try w.indices.map { l in try (0..<3).map { _ in try buffer(w[l], n >> (2 * l)) } }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: inputWidth * f, height: inputHeight * f,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let out = device.makeTexture(descriptor: d) else { throw NeuralError.memory }
        hdrOutput = out
    }

    /// The frame's dispatches, in three passes (timed apart): `pass` + " in" (the history warped, the input tensor),
    /// `pass` (the U-Net), `pass` + " out" (the head applied: the state and the light).
    func stages(_ p: NeuralPipelines, _ inputs: NeuralInputs, pass: String = "neural") -> [ComputeStage] {
        [(Part.inputs, pass + " in"), (.net, pass), (.output, pass + " out")].map { part, name in
            ComputeStage(pass: name) { [self] enc in encode(p, inputs, part, into: enc) }
        }
    }

    private enum Part { case inputs, net, output }

    private func encode(_ p: NeuralPipelines, _ inputs: NeuralInputs, _ part: Part, into enc: ComputePass) {
        let f = factor, s = UInt32(weights.stateChannels), w = weights.header.widths.map { UInt32($0) }
        let g = UInt32(weights.header.guides)
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
        // 3x3 convolution `layer` ("enc0.0") of `a` (+ `b`, concatenated) into `out`, at `level` (0 full, 1 half, ...).
        func conv(_ layer: String, _ a: MTLBuffer, _ ca: UInt32, _ b: MTLBuffer?, _ cb: UInt32, _ out: MTLBuffer, _ cout: UInt32,
                  level: Int, flags: UInt32 = NeuralUpscaler.relu) {
            let lw = width >> level, lh = height >> level
            enc.setComputePipelineState(p.conv)
            set(lw, lh, ca, cb, cout, flags)
            enc.setBuffer(a, offset: 0, index: 1)
            enc.setBuffer(b ?? a, offset: 0, index: 2)
            enc.setBuffer(weights.packed, offset: weights.packedOffset(layer + ".weight"), index: 3)
            enc.setBuffer(weights.buffer, offset: weights.offset(layer + ".bias"), index: 4)
            enc.setBuffer(out, offset: 0, index: 5)
            // A threadgroup: 8 rows x 8 pixels x 32 output channels (NEURAL_TILE_*), a simdgroup two rows.
            enc.dispatchThreadgroups(MTLSize(width: (lw + 7) / 8, height: (lh + 15) / 16,
                                             depth: (Int(cout) + NeuralWeights.tileOutputs - 1) / NeuralWeights.tileOutputs),
                                     threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
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

        let split = inputs.split.map { [$0.diffuse, $0.specular, $0.extra] } ?? Array(repeating: inputs.color, count: 3)
        switch part {
        case .inputs:
        // Last frame's output and state, warped; the input tensor.
        enc.setComputePipelineState(p.warp)
        set(width * f, height * f, 0, 0, 0, (inputs.reset ? NeuralUpscaler.reset : 0)
            | (weights.header.arch.warp == "bicubic" ? NeuralUpscaler.bicubic : 0))
        enc.setBuffer(state, offset: 0, index: 1)
        enc.setBuffer(warped, offset: 0, index: 2)
        enc.setTexture(inputs.motion, index: 0)
        dispatch(width * f, height * f)
        barrier()
        enc.setComputePipelineState(p.prepare)
        set(width, height, g)
        enc.setBuffer(warped, offset: 0, index: 1)
        enc.setBuffer(x, offset: 0, index: 2)
        for (i, t) in ([inputs.color, inputs.albedo, inputs.specular, inputs.normalDepth, inputs.roughness] + split).enumerated() {
            enc.setTexture(t, index: i)
        }
        dispatch(width, height)
        barrier()

        case .net:

        // The U-Net (model.py's forward): at each level two convolutions into its buffers 1 and 2 (2 is the skip
        // connection), pooled into the next level's buffer 0; the last level is "mid"; then back up, each "dec" level
        // reading the level below upsampled and the skip.
        let top = w.count - 1
        var cur = x, curChannels = g + 2 + UInt32(f * f) * s
        for l in 0...top {
            let b = levels[l], name = l == top ? "mid" : "enc\(l)"
            if l > 0 {
                pool(cur, curChannels, b[0], level: l)
                cur = b[0]
            }
            conv(name + ".0", cur, curChannels, nil, 0, b[1], w[l], level: l)
            conv(name + ".1", b[1], w[l], nil, 0, b[2], w[l], level: l)
            (cur, curChannels) = (b[2], w[l])
        }
        for l in stride(from: top - 1, through: 0, by: -1) {
            let b = levels[l]
            conv("dec\(l).0", cur, curChannels, b[2], w[l], b[0], w[l], level: l, flags: NeuralUpscaler.relu | NeuralUpscaler.upsample)
            conv("dec\(l).1", b[0], w[l], nil, 0, b[1], w[l], level: l)
            (cur, curChannels) = (b[1], w[l])
        }
        conv("head", cur, curChannels, nil, 0, head, UInt32(f * weights.headChannels * f), level: 0, flags: 0)

        case .output:

        // Unfold and apply the head, write the state and the light.
        enc.setComputePipelineState(weights.kernelHead ? p.kernelFinish : p.finish)
        set(width * f, height * f)
        enc.setBuffer(head, offset: 0, index: 1)
        enc.setBuffer(warped, offset: 0, index: 2)
        enc.setBuffer(state, offset: 0, index: 3)
        enc.setTexture(hdrOutput, index: 0)
        if weights.kernelHead {
            for (i, t) in ([inputs.albedo, inputs.specular] + split).enumerated() { enc.setTexture(t, index: i + 1) }
        }
        dispatch(width * f, height * f)
        }
    }
}
