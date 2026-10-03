import Metal

/// Live GPU time per pass for the settings panel ("GPU pass timings"): every timed encoder samples the GPU's timestamp
/// counter at its start and end (Apple GPUs sample only at encoder boundaries), so each named pass gets its own
/// encoder while profiling. Benchmarks time passes with separate command buffers instead (Benchmark.splitPasses).
///
/// Encoders without a dependency between them may run at the same time, which would make their times overlap (the
/// sum exceeded the frame's GPU time by half in the night market), so timed encoders run one after another: each waits
/// for a fence the previous one updates (`end`).
///
/// Untimed: MetalFX (it encodes itself), its copy into the drawable, and texture streaming; the panel shows them as
/// "other", the frame's GPU time minus the timed passes.
final class GPUProfiler {
    static let maxEncoders = 96   // per frame

    static func isSupported(on device: MTLDevice) -> Bool {
        device.supportsCounterSampling(.atStageBoundary) && timestampSet(device) != nil
    }

    private static func timestampSet(_ device: MTLDevice) -> MTLCounterSet? {
        device.counterSets?.first { $0.name == MTLCommonCounterSet.timestamp.rawValue }
    }

    private let device: MTLDevice
    private let samples: MTLCounterSampleBuffer
    private let framesInFlight: Int
    private let fence: MTLFence
    // Converts timestamp ticks to nanoseconds, measured against the CPU's timestamps (device.sampleTimestamps, which
    // are in nanoseconds; on Apple GPUs so are the counters, so this stays 1).
    private var calibration: (cpu: MTLTimestamp, gpu: MTLTimestamp)
    private var nsPerTick = 1.0

    init?(device: MTLDevice, framesInFlight: Int) {
        guard GPUProfiler.isSupported(on: device), let set = GPUProfiler.timestampSet(device) else { return nil }
        let desc = MTLCounterSampleBufferDescriptor()
        desc.counterSet = set
        desc.storageMode = .shared
        desc.sampleCount = framesInFlight * GPUProfiler.maxEncoders * 2
        guard let samples = try? device.makeCounterSampleBuffer(descriptor: desc), let fence = device.makeFence() else { return nil }
        self.fence = fence
        self.device = device
        self.samples = samples
        self.framesInFlight = framesInFlight
        let now = device.sampleTimestamps()
        calibration = (now.cpu, now.gpu)
    }

    /// One frame's timed encoders, in encoding order. Make them through `compute`, `blit` and `accelerationStructure`.
    final class Frame {
        fileprivate let profiler: GPUProfiler
        fileprivate let base: Int
        fileprivate(set) var names: [String] = []

        fileprivate init(profiler: GPUProfiler, slot: Int) {
            self.profiler = profiler
            base = slot * GPUProfiler.maxEncoders * 2
        }

        /// The sample indices for the next encoder, or nil when the frame is out of them (it is then untimed).
        private func next(_ name: String) -> (start: Int, end: Int)? {
            guard names.count < GPUProfiler.maxEncoders else { return nil }
            names.append(name)
            let i = base + 2 * (names.count - 1)
            return (i, i + 1)
        }

        func compute(_ cb: MTLCommandBuffer, _ name: String, concurrent: Bool = false) -> MTLComputeCommandEncoder? {
            let desc = MTLComputePassDescriptor()
            desc.dispatchType = concurrent ? .concurrent : .serial
            if let i = next(name), let a = desc.sampleBufferAttachments[0] {
                a.sampleBuffer = profiler.samples
                a.startOfEncoderSampleIndex = i.start
                a.endOfEncoderSampleIndex = i.end
            }
            let enc = cb.makeComputeCommandEncoder(descriptor: desc)
            enc?.waitForFence(profiler.fence)
            return enc
        }

        func blit(_ cb: MTLCommandBuffer, _ name: String) -> MTLBlitCommandEncoder? {
            let desc = MTLBlitPassDescriptor()
            if let i = next(name), let a = desc.sampleBufferAttachments[0] {
                a.sampleBuffer = profiler.samples
                a.startOfEncoderSampleIndex = i.start
                a.endOfEncoderSampleIndex = i.end
            }
            let enc = cb.makeBlitCommandEncoder(descriptor: desc)
            enc?.waitForFence(profiler.fence)
            return enc
        }

        func accelerationStructure(_ cb: MTLCommandBuffer, _ name: String) -> MTLAccelerationStructureCommandEncoder? {
            let desc = MTLAccelerationStructurePassDescriptor()
            if let i = next(name), let a = desc.sampleBufferAttachments[0] {
                a.sampleBuffer = profiler.samples
                a.startOfEncoderSampleIndex = i.start
                a.endOfEncoderSampleIndex = i.end
            }
            let enc = cb.makeAccelerationStructureCommandEncoder(descriptor: desc)
            enc.waitForFence(profiler.fence)
            return enc
        }

        /// Ends an encoder made by `compute`, `blit` or `accelerationStructure`, letting the next one start after it.
        func end(_ enc: MTLCommandEncoder) {
            switch enc {
            case let e as MTLComputeCommandEncoder: e.updateFence(profiler.fence)
            case let e as MTLBlitCommandEncoder: e.updateFence(profiler.fence)
            case let e as MTLAccelerationStructureCommandEncoder: e.updateFence(profiler.fence)
            default: break
            }
            enc.endEncoding()
        }

        /// Milliseconds per pass name (encoders of one name summed), in order of first use. Call once the frame's
        /// command buffer has completed.
        func resolve() -> [(name: String, ms: Double)] {
            guard !names.isEmpty,
                  let data = try? profiler.samples.resolveCounterRange(base..<(base + 2 * names.count)) else { return [] }
            let ticks = data.withUnsafeBytes { Array($0.bindMemory(to: MTLCounterResultTimestamp.self)) }
            let nsPerTick = profiler.recalibrate()
            var order: [String] = [], ms: [String: Double] = [:]
            for (i, name) in names.enumerated() where 2 * i + 1 < ticks.count {
                let start = ticks[2 * i].timestamp, end = ticks[2 * i + 1].timestamp
                guard start != MTLCounterErrorValue, end != MTLCounterErrorValue, end > start else { continue }
                if ms[name] == nil { order.append(name) }
                ms[name, default: 0] += Double(end - start) * nsPerTick / 1e6
            }
            return order.map { ($0, ms[$0]!) }
        }
    }

    func beginFrame(slot: Int) -> Frame { Frame(profiler: self, slot: slot % framesInFlight) }

    /// GPU ticks per CPU time, re-measured once at least half a second has passed since the last measurement.
    fileprivate func recalibrate() -> Double {
        let (cpu, gpu) = device.sampleTimestamps()
        let cpuNs = Double(cpu &- calibration.cpu)
        if cpuNs > 5e8, gpu > calibration.gpu {
            nsPerTick = cpuNs / Double(gpu - calibration.gpu)
            calibration = (cpu, gpu)
        }
        return nsPerTick
    }
}

extension Optional where Wrapped == GPUProfiler.Frame {
    /// Ends `enc`: through the frame's profile when there is one (see `GPUProfiler.Frame.end`).
    func end(_ enc: MTLCommandEncoder) {
        if let frame = self { frame.end(enc) } else { enc.endEncoding() }
    }
}
