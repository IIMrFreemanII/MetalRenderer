import CoreGraphics
import Foundation
import Metal
import MetalKit
import QuartzCore
import simd

/// One node's dispatch (MSL: MatArgs in MaterialShaders/MatCommon.metal, the same layout).
struct MatArgs {
    var size: SIMD2<UInt32>
    var wired: UInt32 = 0
    var greyIn: UInt32 = 0
    var lumIn: UInt32 = 0
    var greyOut: UInt32 = 0
    var seed: UInt32 = 0
    var pass: UInt32 = 0
    var data = SIMD4<Float>.zero
}

/// The renderer's textures of a baked graph (MaterialBake: the material's slots): base colour and emissive as sRGB
/// values (`baseColor`, `emissive`: their sRGB views), occlusion-roughness-metallic packed (glTF's R, G, B), the
/// normal (OpenGL), the height (16-bit float) and the opacity; nil: the graph has no output for it. Mipmapped.
/// `keys` are what each was made from: a texture whose key didn't change is the same texture.
final class MatOutputs {
    var baseColor: MTLTexture?
    var orm: MTLTexture?
    var normal: MTLTexture?
    var emissive: MTLTexture?
    var height: MTLTexture?
    var opacity: MTLTexture?
    var keys: [String: UInt64] = [:]
    var surface = MatSurface()

    var all: [MTLTexture] { [baseColor, orm, normal, emissive, height, opacity].compactMap { $0 } }
}

/// What an evaluation gives back: the renderer's textures, the thumbnails it made (by the step's hash), what each
/// node's error was (a compile's, a file's), and how long the GPU took.
struct MatResult {
    var outputs: MatOutputs
    var thumbnails: [UInt64: CGImage] = [:]
    var errors: [String: String] = [:]
    var gpuMilliseconds: Double = 0
    /// Nodes baked (the rest were cached).
    var baked = 0
    var plan: MatPlan
}

/// Bakes a graph's plan (MatPlan) on the GPU, on a queue of its own: a node at a time, in the plan's order, each a
/// kernel of the material library (several passes for a blur, a distance, a flood fill) into images of its size and
/// precision. A node's images are kept by its hash, so an edit bakes only the nodes downstream of it, and undo finds
/// the images it had; what isn't in the plan goes once the cache is over its budget. Then the renderer's textures
/// from the output nodes (MatOutputs), and thumbnails of the nodes baked.
///
/// Evaluations run one at a time, in the background: one asked for while another runs waits, and only the latest
/// waits (a slider's drag asks 30 times a second; what it shows is its last).
final class MatEngine {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let work = DispatchQueue(label: "MetalRenderer.materials", qos: .userInitiated)
    private let lock = NSLock()
    /// A node's images by its hash, and when each was last used (an evaluation's number).
    private var images: [UInt64: (textures: [MTLTexture], bytes: Int, used: Int)] = [:]
    private var packed: [UInt64: MTLTexture] = [:]
    private var bitmaps: [String: MTLTexture] = [:]
    private var evaluations = 0
    private var busy = false
    private var pending: (MatPlan, Set<UInt64>, (MatResult) -> Void)?
    private lazy var dummy: MTLTexture = {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]   // bound for unused outputs too
        let t = device.makeTexture(descriptor: d)!
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 0, count: 4), bytesPerRow: 4)
        return t
    }()
    /// The cache's budget: images past it that the plan doesn't use are let go, the least recently used first.
    var budget: Int

    static let thumbnailSide = 96

    init(device: MTLDevice) {
        self.device = device
        queue = device.makeCommandQueue()!
        queue.label = "Material graph"
        budget = max(Int(device.recommendedMaxWorkingSetSize / 8), 512 << 20)
    }

    /// Bakes `plan` (after the evaluation running now, if one is; replacing one waiting), then calls `done` on the
    /// main thread. Thumbnails are made for the nodes baked and for those whose hashes aren't in `known`.
    func evaluate(_ plan: MatPlan, known: Set<UInt64> = [], done: @escaping (MatResult) -> Void) {
        lock.lock()
        if busy {
            pending = (plan, known, done)
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()
        work.async { [self] in
            let result = run(plan, known: known)
            DispatchQueue.main.async {
                done(result)
                self.lock.lock()
                let next = self.pending
                self.pending = nil
                self.busy = false
                self.lock.unlock()
                if let (p, k, d) = next { self.evaluate(p, known: k, done: d) }
            }
        }
    }

    /// Bakes `plan` now, on the caller's thread (benchmarks, tests).
    func evaluateNow(_ plan: MatPlan, known: Set<UInt64> = []) -> MatResult {
        work.sync { run(plan, known: known) }
    }

    /// Node `hash`'s output `output`, if it is baked (the editor's 2D view).
    func texture(_ hash: UInt64, output: Int = 0) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        guard let i = images[hash], i.textures.indices.contains(output) else { return nil }
        return i.textures[output]
    }

    /// Images kept and their bytes.
    var cacheStats: (count: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (images.count, images.values.reduce(0) { $0 + $1.bytes })
    }

    // MARK: - An evaluation

    private func run(_ plan: MatPlan, known: Set<UInt64>) -> MatResult {
        evaluations += 1
        let outputs = MatOutputs()
        outputs.surface = plan.surface
        var result = MatResult(outputs: outputs, plan: plan)
        guard let cb = queue.makeCommandBuffer() else { return result }
        cb.label = "Material graph"
        var thumbs: [(hash: UInt64, slot: Int)] = []
        let side = MatEngine.thumbnailSide
        let atlas = device.makeBuffer(length: max(plan.steps.count, 1) * side * side * 4, options: .storageModeShared)
        do {
            _ = try MatCompiler.shared.library(device)
        } catch {
            result.errors[""] = "The material library didn't compile: \(error)"
            print(result.errors[""]!)
            return result
        }
        var made: [Int: [MTLTexture]] = [:]
        for (k, step) in plan.steps.enumerated() {
            lock.lock()
            let cached = images[step.hash]
            if cached != nil { images[step.hash]!.used = evaluations }
            lock.unlock()
            if let cached {
                made[k] = cached.textures
            } else {
                let textures = step.outputs.map { makeImage(step, $0) }
                made[k] = textures
                do {
                    try encode(step, k, plan: plan, made: made, outputs: textures, cb: cb)
                } catch {
                    result.errors[step.id] = "\(error)"
                }
                result.baked += 1
                lock.lock()
                images[step.hash] = (textures, textures.reduce(0) { $0 + MatEngine.bytes($1) }, evaluations)
                lock.unlock()
            }
            if (cached == nil || !known.contains(step.hash)), let first = made[k]?.first, atlas != nil {
                thumbs.append((step.hash, thumbs.count))
                encodeThumbnail(first, grey: step.outputs.first == .grey, slot: thumbs.count - 1, atlas: atlas!, cb: cb)
            }
        }
        pack(plan, made: made, into: outputs, cb: cb)
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { result.errors["", default: ""] += "\(e)" }
        result.gpuMilliseconds = (cb.gpuEndTime - cb.gpuStartTime) * 1000
        if let atlas { for t in thumbs { result.thumbnails[t.hash] = MatEngine.image(atlas, slot: t.slot, side: side) } }
        evict(keeping: Set(plan.steps.map(\.hash)))
        return result
    }

    private static func format(_ type: MatType, _ bits: MatBits) -> MTLPixelFormat {
        switch (type, bits) {
        case (.grey, .b8): return .r8Unorm
        case (.grey, .b32): return .r32Float
        case (.grey, _): return .r16Float
        case (.color, .b16): return .rgba16Float
        case (.color, .b32): return .rgba32Float
        case (.color, _): return .rgba8Unorm
        }
    }

    private static func bytes(_ t: MTLTexture) -> Int {
        let px: Int
        switch t.pixelFormat {
        case .r8Unorm: px = 1
        case .r16Float: px = 2
        case .r32Float, .rgba8Unorm: px = 4
        case .rgba16Float, .rg32Float: px = 8
        default: px = 16
        }
        return t.width * t.height * px
    }

    private func makeImage(_ step: MatPlan.Step, _ type: MatType, format: MTLPixelFormat? = nil) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format ?? MatEngine.format(type, step.bits), width: step.pixels,
                                                         height: step.pixels, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)!
        t.label = step.id
        return t
    }

    /// Let go of images no plan step uses, the least recently used first, while over the budget.
    private func evict(keeping: Set<UInt64>) {
        lock.lock(); defer { lock.unlock() }
        var total = images.values.reduce(0) { $0 + $1.bytes }
        guard total > budget else { return }
        for (h, i) in images.sorted(by: { $0.value.used < $1.value.used }) where !keeping.contains(h) {
            images[h] = nil
            total -= i.bytes
            if total <= budget { break }
        }
    }

    // MARK: - Encoding a node

    private func args(_ step: MatPlan.Step, _ plan: MatPlan) -> MatArgs {
        var a = MatArgs(size: SIMD2(UInt32(step.pixels), UInt32(step.pixels)))
        let pins = step.kind.spec.inputs
        for (i, src) in step.inputs.enumerated() {
            guard let src else { continue }
            a.wired |= 1 << i
            if src.type == .grey { a.greyIn |= 1 << i } else if pins.indices.contains(i), pins[i].type == .grey { a.lumIn |= 1 << i }
        }
        for (k, t) in step.outputs.enumerated() where t == .grey { a.greyOut |= 1 << k }
        a.seed = step.seed
        return a
    }

    private func encode(_ step: MatPlan.Step, _ k: Int, plan: MatPlan, made: [Int: [MTLTexture]], outputs: [MTLTexture],
                        cb: MTLCommandBuffer) throws {
        let inputs: [MTLTexture?] = step.inputs.map { src in src.flatMap { made[$0.step]?[$0.output] } }
        let a = args(step, plan)
        let luts = step.luts.isEmpty ? nil : device.makeBuffer(bytes: step.luts.flatMap { $0 }, length: step.luts.count * MatPlan.lutSize * 16)
        func dispatch(_ kernel: String, _ ins: [MTLTexture?], _ outs: [MTLTexture], _ a: MatArgs, buffers: [Int: MTLBuffer] = [:],
                      size: Int? = nil) throws {
            let state = try MatCompiler.shared.state(kernel, device: device)
            try dispatchState(state, ins, outs, a, buffers: buffers, size: size)
        }
        func dispatchState(_ state: MTLComputePipelineState, _ ins: [MTLTexture?], _ outs: [MTLTexture], _ a: MatArgs,
                           buffers: [Int: MTLBuffer] = [:], size: Int? = nil) throws {
            guard let enc = cb.makeComputeCommandEncoder() else { return }
            enc.label = "\(step.id) \(state.label ?? "")"
            enc.setComputePipelineState(state)
            for i in 0..<4 { enc.setTexture(i < ins.count ? (ins[i] ?? dummy) : dummy, index: i) }
            for i in 0..<4 { enc.setTexture(i < outs.count ? outs[i] : dummy, index: 8 + i) }
            var a = a
            enc.setBytes(&a, length: MemoryLayout<MatArgs>.stride, index: 0)
            let params = step.params.isEmpty ? [SIMD4<Float>.zero] : step.params
            enc.setBytes(params, length: params.count * 16, index: 1)
            if let luts { enc.setBuffer(luts, offset: 0, index: 2) } else { enc.setBytes([SIMD4<Float>.zero], length: 16, index: 2) }
            for (i, b) in buffers { enc.setBuffer(b, offset: 0, index: i) }
            let n = size ?? step.pixels
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            enc.dispatchThreads(MTLSize(width: n, height: n, depth: 1), threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        switch step.kind {
        case .input, .uniform, .uniformColor:
            try dispatch("mat_uniform", [], outputs, a)
        case .output:
            try dispatch("mat_copy", inputs, outputs, a)
        case .bitmap:
            let image = try bitmap(step.node.text("path"))
            var b = a
            b.wired = image != nil ? 1 : 0
            try dispatch("mat_copy", [image], outputs, b)
        case .meshMap:
            // The painter's bake of the object its context names (PaintMeshMaps), or its neutral picture.
            let image = PaintMeshMaps.texture(context: step.node.text("context"), map: step.node.text("map"), device: device)
            var b = a
            b.wired = image != nil ? 1 : 0
            try dispatch("mat_copy", [image], outputs, b)
        case .blur:
            let temp = makeImage(step, step.outputs[0])
            try dispatch("mat_blur", inputs, [temp], a)
            var b = a
            b.pass = 1
            b.wired = 1
            b.greyIn = step.outputs[0] == .grey ? 1 : 0
            b.lumIn = 0
            try dispatch("mat_blur", [temp], outputs, b)
        case .distance, .bevel:
            let threshold = step.kind == .distance ? step.params[1].x : step.params[2].x
            var seedA = makeImage(step, .color, format: .rg32Float), seedB = makeImage(step, .color, format: .rg32Float)
            var s = a
            s.data = SIMD4(threshold, step.kind == .bevel ? 1 : 0, 0, 0)
            try dispatch("mat_jfaSeed", inputs, [seedA], s)
            var jump = step.pixels / 2
            while jump >= 1 {
                var j = a
                j.wired = 1; j.greyIn = 0; j.lumIn = 0
                j.data = SIMD4(Float(jump), 0, 0, 0)
                try dispatch("mat_jfaStep", [seedA], [seedB], j)
                swap(&seedA, &seedB)
                jump /= 2
            }
            var o = a
            o.wired = a.wired << 1 | 1
            o.greyIn = a.greyIn << 1
            o.lumIn = a.lumIn << 1
            try dispatch(step.kind == .distance ? "mat_distanceOut" : "mat_bevelOut", [seedA] + inputs, outputs, o)
        case .floodFill:
            let n = step.pixels * step.pixels
            guard let labels = device.makeBuffer(length: n * 4, options: .storageModePrivate),
                  let bounds = device.makeBuffer(length: n * 16, options: .storageModePrivate) else { throw MatError("out of memory") }
            let b: [Int: MTLBuffer] = [4: labels, 5: bounds]
            try dispatch("mat_ffInit", inputs, [], a, buffers: b)
            let rounds = 3 * Int(log2(Double(step.pixels))) + 4
            for _ in 0..<rounds {
                try dispatch("mat_ffPropagate", [], [], a, buffers: b)
                try dispatch("mat_ffJump", [], [], a, buffers: b)
                try dispatch("mat_ffJump", [], [], a, buffers: b)
            }
            try dispatch("mat_ffBoundsClear", [], [], a, buffers: b)
            try dispatch("mat_ffBounds", [], [], a, buffers: b)
            try dispatch("mat_ffOut", [], outputs, a, buffers: b)
        case .autoLevels:
            guard let range = device.makeBuffer(length: 8, options: .storageModePrivate) else { throw MatError("out of memory") }
            try dispatch("mat_minMaxClear", [], [], a, buffers: [4: range], size: 1)
            try dispatch("mat_minMax", inputs, [], a, buffers: [4: range])
            try dispatch("mat_autoLevels", inputs, outputs, a, buffers: [4: range])
        case .pixelProcessor, .code:
            let source: String
            if step.kind == .code {
                source = MatCompiler.codeSource(step.node.text("code"))
            } else {
                guard let f = step.node.function else { throw MatError("no function") }
                source = MatCompiler.pixelProcessorSource(try f.code().metal)
            }
            switch MatCompiler.shared.generated(source, device: device) {
            case .success(let state): try dispatchState(state, inputs, outputs, a)
            case .failure(let e):
                try dispatch("mat_uniform", [], outputs, a)   // black (its parameter 0 is its mode: 0)
                throw e
            }
        case .subgraph:
            throw MatError("a subgraph node in a plan")
        default:
            try dispatch(step.kind.kernel, inputs, outputs, a)
        }
    }

    private func bitmap(_ path: String) throws -> MTLTexture? {
        guard !path.isEmpty else { return nil }
        lock.lock()
        if let t = bitmaps[path] { lock.unlock(); return t }
        lock.unlock()
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : Scene.assetsDirectory.appendingPathComponent(path)
        let t = try MTKTextureLoader(device: device).newTexture(URL: url, options: [.SRGB: false, .textureStorageMode: MTLStorageMode.private.rawValue])
        lock.lock()
        bitmaps[path] = t
        lock.unlock()
        return t
    }

    // MARK: - Reading back

    /// `texture`'s pixels (level `level`) as floats, RGBA (a grey's in R, G and B; alpha 1): the export's, the tests'.
    func read(_ texture: MTLTexture, level: Int = 0) -> [SIMD4<Float>] {
        let w = max(texture.width >> level, 1), h = max(texture.height >> level, 1)
        let (channels, size): (Int, Int)
        switch texture.pixelFormat {
        case .r8Unorm: (channels, size) = (1, 1)
        case .r16Float: (channels, size) = (1, 2)
        case .r32Float: (channels, size) = (1, 4)
        case .rg32Float: (channels, size) = (2, 4)
        case .rgba8Unorm, .rgba8Unorm_srgb: (channels, size) = (4, 1)
        case .rgba16Float: (channels, size) = (4, 2)
        default: (channels, size) = (4, 4)
        }
        let row = w * channels * size
        guard let buffer = device.makeBuffer(length: row * h, options: .storageModeShared), let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return [] }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: row * h)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let raw = buffer.contents()
        func value(_ i: Int) -> Float {
            switch size {
            case 1: return Float(raw.load(fromByteOffset: i, as: UInt8.self)) / 255
            case 2: return Float(raw.load(fromByteOffset: i * 2, as: Float16.self))
            default: return raw.load(fromByteOffset: i * 4, as: Float.self)
            }
        }
        return (0..<(w * h)).map { k in
            switch channels {
            case 1: let v = value(k); return SIMD4(v, v, v, 1)
            case 2: return SIMD4(value(k * 2), value(k * 2 + 1), 0, 1)
            default: return SIMD4(value(k * 4), value(k * 4 + 1), value(k * 4 + 2), value(k * 4 + 3))
            }
        }
    }

    // MARK: - Thumbnails

    private func encodeThumbnail(_ t: MTLTexture, grey: Bool, slot: Int, atlas: MTLBuffer, cb: MTLCommandBuffer) {
        guard let state = try? MatCompiler.shared.state("mat_thumbnail", device: device), let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(state)
        enc.setTexture(t, index: 0)
        let side = MatEngine.thumbnailSide
        var a = MatArgs(size: SIMD2(UInt32(side), UInt32(side)))
        a.greyIn = grey ? 1 : 0
        a.data = SIMD4(Float(slot), Float(side), 0, 0)
        enc.setBytes(&a, length: MemoryLayout<MatArgs>.stride, index: 0)
        enc.setBuffer(atlas, offset: 0, index: 3)
        enc.dispatchThreads(MTLSize(width: side, height: side, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
    }

    private static func image(_ atlas: MTLBuffer, slot: Int, side: Int) -> CGImage? {
        let bytes = side * side * 4
        let data = Data(bytes: atlas.contents() + slot * bytes, count: bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - The renderer's textures

    /// The output nodes' images as the renderer's textures, at the graph's size, mipmapped. A texture made from
    /// the same images as before is the same texture (the renderer keeps its slot).
    private func pack(_ plan: MatPlan, made: [Int: [MTLTexture]], into out: MatOutputs, cb: MTLCommandBuffer) {
        let n = 1 << plan.size
        func source(_ c: MatChannel) -> (MTLTexture, UInt64, MatType)? {
            guard let k = plan.channels[c], let t = made[k]?.first else { return nil }
            return (t, plan.steps[k].hash, plan.steps[k].outputs[0])
        }
        func make(_ name: String, _ format: MTLPixelFormat, _ key: UInt64, kernel: String, inputs: [(MTLTexture, MatType)?],
                  params: [SIMD4<Float>], data: SIMD4<Float> = .zero) -> MTLTexture? {
            out.keys[name] = key
            lock.lock()
            if let t = packed[key] { lock.unlock(); return t }
            lock.unlock()
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: n, height: n, mipmapped: true)
            d.usage = format == .rgba8Unorm ? [.shaderRead, .shaderWrite, .pixelFormatView] : [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d), let state = try? MatCompiler.shared.state(kernel, device: device),
                  let enc = cb.makeComputeCommandEncoder() else { return nil }
            t.label = "\(plan.steps.first?.id ?? "graph") \(name)"
            enc.setComputePipelineState(state)
            var a = MatArgs(size: SIMD2(UInt32(n), UInt32(n)))
            for (i, input) in inputs.enumerated() {
                enc.setTexture(input?.0 ?? dummy, index: i)
                if let input { a.wired |= 1 << i; if input.1 == .grey { a.greyIn |= 1 << i } }
            }
            for i in inputs.count..<4 { enc.setTexture(dummy, index: i) }
            enc.setTexture(t, index: 8)
            for i in 9..<12 { enc.setTexture(dummy, index: i) }
            a.data = data
            enc.setBytes(&a, length: MemoryLayout<MatArgs>.stride, index: 0)
            enc.setBytes(params, length: params.count * 16, index: 1)
            enc.setBytes([SIMD4<Float>.zero], length: 16, index: 2)
            enc.dispatchThreads(MTLSize(width: n, height: n, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.endEncoding()
            if let blit = cb.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: t)
                blit.endEncoding()
            }
            lock.lock()
            packed[key] = t
            lock.unlock()
            return t
        }
        func key(_ parts: UInt64...) -> UInt64 {
            var h = Hasher64()
            h.add(UInt64(n))
            for p in parts { h.add(p) }
            return h.value
        }
        func single(_ c: MatChannel, _ format: MTLPixelFormat, flip: Bool = false) -> MTLTexture? {
            guard let s = source(c) else { return nil }
            return make(c.rawValue, format, key(s.1, UInt64(format.rawValue), flip ? 1 : 0, 7), kernel: "mat_packColor",
                        inputs: [(s.0, s.2)], params: [c.fallback], data: SIMD4(flip ? 1 : 0, 0, 0, 0))
        }
        out.baseColor = single(.baseColor, .rgba8Unorm)
        out.emissive = single(.emissive, .rgba8Unorm)
        out.normal = single(.normal, .rgba8Unorm, flip: plan.surface.normalDirectX)
        out.height = single(.height, .r16Float)
        out.opacity = single(.opacity, .r8Unorm)
        let ao = source(.ambientOcclusion), rough = source(.roughness), metal = source(.metallic)
        if ao != nil || rough != nil || metal != nil {
            out.orm = make("orm", .rgba8Unorm, key(ao?.1 ?? 1, rough?.1 ?? 2, metal?.1 ?? 3, 11), kernel: "mat_packORM",
                           inputs: [ao.map { ($0.0, $0.2) }, rough.map { ($0.0, $0.2) }, metal.map { ($0.0, $0.2) }],
                           params: [MatChannel.ambientOcclusion.fallback, MatChannel.roughness.fallback, MatChannel.metallic.fallback])
        }
        // Packed textures no output uses any more go.
        let live = Set(out.keys.values)
        lock.lock()
        packed = packed.filter { live.contains($0.key) || packedRecent.contains($0.key) }
        packedRecent = live
        lock.unlock()
    }
    /// The last evaluation's packed keys: kept one evaluation more (undo's first step finds them).
    private var packedRecent: Set<UInt64> = []
}
