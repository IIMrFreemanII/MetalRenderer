import Foundation
import Metal
import QuartzCore

/// The step's and the pose's kernels a particle system runs (ParticlesGPU): the main library's, or the VFX library's
/// for a system with programs (they call them, and read their buffers at 27 to 29).
struct ParticleKernels {
    let begin: MTLComputePipelineState
    let emit: MTLComputePipelineState
    let simulate: MTLComputePipelineState
    let pose: MTLComputePipelineState
    let programs: Bool

    init(_ p: Pipelines) {
        begin = p[.particleBegin]
        emit = p[.particleEmit]
        simulate = p[.particleSimulate]
        pose = p[.particlePose]
        programs = false
    }
    init(begin: MTLComputePipelineState, emit: MTLComputePipelineState, simulate: MTLComputePipelineState,
         pose: MTLComputePipelineState) {
        self.begin = begin
        self.emit = emit
        self.simulate = simulate
        self.pose = pose
        programs = true
    }
}

/// The VFX library (ShadersVFX.metal: the particle kernels with the effects' programs, VFXCodegen.source spliced in
/// after them), compiled in the background the first time a system's programs are asked for, and kept for the last
/// few (a graph's edits come back to sources it had). Until it is ready the system runs the fixed emitters' code
/// (`kernels` gives nil); benchmarks and tests wait for it.
final class VFXCompiler {
    static let shared = VFXCompiler()
    static let kept = 6

    struct Setup: Hashable {
        let entry: URL
        let lightTypes: UInt32
        let stats: Bool
        let metal4: Bool
    }
    private struct Key: Hashable {
        let setup: Setup
        let source: String
    }
    private enum Entry {
        case building
        case ready(ParticleKernels)
        case failed(String)
    }
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var recent: [Key] = []
    /// The last compile's time (ms: the library and its four pipelines) and the last failure (the editor shows them).
    private(set) var lastMilliseconds: Double?
    private(set) var lastFailure: String?
    private static let queue = DispatchQueue(label: "MetalRenderer.vfx", qos: .utility)

    /// The kernels for `generated` (VFXCodegen.source), or nil while they compile (`wait`: compile now) or if they
    /// don't (the failure: `failure(for:)`). Called every frame by a system with programs: a lookup under a lock.
    func kernels(for generated: String, setup: Setup, device: MTLDevice, compiler: AnyObject?, wait: Bool) -> ParticleKernels? {
        let key = Key(setup: setup, source: generated)
        lock.lock()
        switch entries[key] {
        case .ready(let k)?:
            touch(key)
            lock.unlock()
            return k
        case .building?, .failed?:
            lock.unlock()
            return nil
        case nil:
            entries[key] = .building
            lock.unlock()
        }
        let work = { [self] in
            let start = CACurrentMediaTime()
            let entry: Entry
            do {
                entry = .ready(try VFXCompiler.make(key, device: device, compiler: compiler))
            } catch {
                entry = .failed("\(error)")
                print("VFX: the effects' code didn't compile: \(error)")
            }
            lock.lock()
            entries[key] = entry
            touch(key)
            if case .ready = entry { lastMilliseconds = (CACurrentMediaTime() - start) * 1000; lastFailure = nil }
            if case .failed(let f) = entry { lastFailure = f }
            lock.unlock()
            if case .ready = entry { print(String(format: "VFX library: compiled in %.0f ms", (CACurrentMediaTime() - start) * 1000)) }
        }
        if wait {
            work()
            lock.lock(); defer { lock.unlock() }
            if case .ready(let k)? = entries[key] { return k }
            return nil
        }
        VFXCompiler.queue.async(execute: work)
        return nil
    }

    /// Why `generated` didn't compile, if it didn't.
    func failure(for generated: String, setup: Setup) -> String? {
        lock.lock(); defer { lock.unlock() }
        if case .failed(let f)? = entries[Key(setup: setup, source: generated)] { return f }
        return nil
    }

    /// The most recently used first; past `kept`, the oldest ready one goes.
    private func touch(_ key: Key) {
        recent.removeAll { $0 == key }
        recent.insert(key, at: 0)
        while recent.count > VFXCompiler.kept, let last = recent.last {
            recent.removeLast()
            entries[last] = nil
        }
    }

    private static func make(_ key: Key, device: MTLDevice, compiler: AnyObject?) throws -> ParticleKernels {
        let text = try ShaderSource.load(key.setup.entry) + "\n#line 1 \"generated\"\n" + key.source
        let library = try Pipelines.compile(device: device, text: text, stats: key.setup.stats, compiler: compiler)
        func state(_ k: Kernel) throws -> MTLComputePipelineState {
            let constants = MTLFunctionConstantValues()
            var types = key.setup.lightTypes
            constants.setConstantValue(&types, type: .uint, index: 0)
            return try Pipelines.makeState(device: device, library: library, compiler: compiler, kernel: k, constants: constants)
        }
        return ParticleKernels(begin: try state(.particleBegin), emit: try state(.particleEmit), simulate: try state(.particleSimulate),
                               pose: try state(.particlePose))
    }
}
