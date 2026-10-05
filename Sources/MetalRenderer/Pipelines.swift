import Foundation
import Metal
import QuartzCore

/// The compute kernels in Shaders/*.metal: case `trace` is the function `traceKernel`.
enum Kernel: Int, CaseIterable {
    case trace, glass, geometryDebug, lightMap
    case manyLights, manyLightsReuse, meshLights, regirBuild, restirTemporal, restirSpatial, megaLightsCull, megaLightsSample
    case restirGIInitial, restirGITemporal, restirGISpatial
    case rcProbe, rcTraceMerge, rcSH, rcClearAmbient, rcResolve
    case reflection
    case temporal, atrous, shadowTemporal, shadowFilter, accumulate
    case fogInject, fogIntegrate, fogReference
    case sky, skyMean, cloudShadow, cloudNoise, transmittanceLUT, multiScatterLUT
    case composite, accumulateColor, tonemap
    case focus, dof, bloomDown, bloomUp, finish   // the lens and the finish (Post.metal)
    case crowdPose, crowdSkin   // the crowd's pose slots: skinning matrices, then vertices (CrowdSkinner)
    // Custom ray tracer only: the per-frame build of its dynamic tree and of the virtual geometry's cut.
    case rtPrep, rtKeys, rtSortLocal, rtSortGlobal, rtHierarchy, rtFit
    case vgReset, vgCut, vgFinish, vgPad, vgHierarchy, vgFit
    case crowdRefit             // ...and their bottom-level trees

    var function: String { "\(self)Kernel" }
    /// Exists only in the custom tracer's variant of the shaders (CUSTOM_RT).
    var customOnly: Bool { rawValue >= Kernel.rtPrep.rawValue }

    /// The bits of Uniforms.flags that this kernel's variants have compiled in (KernelVariants): the ones it reads
    /// that stay the same from frame to frame. A bit that is missing here is only read at run time, as before; a bit
    /// the kernel doesn't read would only make variants that are the same code.
    var fixedFlags: UInt32 {
        typealias F = UniformFlags
        switch self {
        // F.wind: every kernel that casts many rays. Their traversal holds the wind's turns only while it blows.
        case .trace: return F.specular | F.upscale | F.blueNoise | F.skyMap | F.lightMaps | F.noClamp | F.restir | F.allLights | F.wind
        case .manyLights, .manyLightsReuse: return F.blueNoise | F.wind
        case .restirSpatial, .megaLightsSample: return F.specular
        case .restirGIInitial: return F.blueNoise | F.noClamp | F.skyMap | F.allLights | F.wind
        case .reflection: return F.blueNoise | F.noClamp | F.reference | F.restir | F.shadowDenoiser | F.skyMap | F.wind
        case .rcProbe, .rcTraceMerge, .lightMap: return F.wind
        case .fogInject: return F.blueNoise | F.skyMap
        default: return 0
        }
    }
    /// The same for the kernel's own flags: the word its `bind` passes (Uniforms.tracePassFlags, GPURestirParams'
    /// and GPURestirGIParams' flags, GPUFogParams.reflectionPassFlags). The "last frame is valid" bits change on the
    /// first frame after a reset, so they stay run-time tests: a variant for that one frame would be compiled for nothing.
    var fixedPassFlags: UInt32 {
        switch self {
        case .trace: return Uniforms.traceBounces | Uniforms.traceManyLights
        case .restirTemporal: return GPURestirParams.visibilityReuse
        case .megaLightsSample: return GPUMegaLightsParams.partition
        case .restirSpatial: return GPURestirParams.shade | GPURestirParams.split
        case .restirGIInitial:
            return GPURestirGIParams.lightMaps | GPURestirGIParams.feedbackSet | GPURestirGIParams.fallback
                | GPURestirGIParams.quarter | GPURestirGIParams.oneBounce
        case .reflection: return GPUFogParams.reflectionsFogged
        default: return 0
        }
    }
}

/// Variants of the big kernels with a configuration's flags compiled in (function constants 1 to 4, see flagOn and
/// passOn in Shaders/Types.metal): a path tracer without the light-map lookup, a ReSTIR pass that only merges, reflections
/// that never follow a second bounce. What a variant doesn't do holds no registers, which is what these kernels are
/// short of (what pays is a variant without one of the kernel's ray casts). One is made the first time a frame asks
/// for it, in the background: until it is ready the frame runs the kernel's general pipeline, which reads the same
/// flags from its uniforms and renders the same image (to fast math's rounding; bit for bit with
/// `METALRENDERER_MATH=safe`). Benchmarks wait for it instead, so every measured frame runs the same code.
/// `METALRENDERER_VARIANTS=0` turns them off.
final class KernelVariants {
    static let enabled = ProcessInfo.processInfo.environment["METALRENDERER_VARIANTS"] != "0"
    /// `METALRENDERER_VARIANTS=log` prints each variant as it is made: the kernel, its compiled-in bits and their masks.
    private static let logged = ProcessInfo.processInfo.environment["METALRENDERER_VARIANTS"] == "log"
    private struct Key: Hashable { let kernel: Kernel; let flags: UInt32; let pass: UInt32 }

    private let device: MTLDevice
    private let library: MTLLibrary
    private let compiler: AnyObject?   // Metal 4's (an `MTL4Compiler`): the variants are made the way the set was
    private let lightTypes: UInt32
    private let lock = NSLock()
    private var states: [Key: MTLComputePipelineState] = [:]
    private var started: Set<Key> = []   // being built, or failed: not asked for again
    // Below the frame loop's priority: several variants compile at once after a settings change, and the frame has a
    // pipeline to run in the meantime.
    private static let queue = DispatchQueue(label: "MetalRenderer.variants", qos: .utility, attributes: .concurrent)

    init(device: MTLDevice, library: MTLLibrary, compiler: AnyObject?, lightTypes: UInt32) {
        self.device = device
        self.library = library
        self.compiler = compiler
        self.lightTypes = lightTypes
    }

    /// How many variants are ready.
    var count: Int { lock.lock(); defer { lock.unlock() }; return states.count }

    /// The variant of `kernel` for these flags, or nil while it is being made (`wait`: make it now). Called every frame
    /// for every dispatch of a kernel that has variants: a dictionary lookup under a lock that is never held for long.
    func state(_ kernel: Kernel, flags: UInt32, pass: UInt32, wait: Bool) -> MTLComputePipelineState? {
        let key = Key(kernel: kernel, flags: flags & kernel.fixedFlags, pass: pass & kernel.fixedPassFlags)
        lock.lock()
        if let state = states[key] { lock.unlock(); return state }
        let start = started.insert(key).inserted
        lock.unlock()
        guard start else { return nil }
        if wait { return make(key) }
        KernelVariants.queue.async { _ = self.make(key) }
        return nil
    }

    private func make(_ key: Key) -> MTLComputePipelineState? {
        do {
            let constants = MTLFunctionConstantValues()
            var values = [lightTypes, key.flags, key.kernel.fixedFlags, key.pass, key.kernel.fixedPassFlags]
            constants.setConstantValues(&values, type: .uint, range: 0..<values.count)
            let state = try Pipelines.makeState(device: device, library: library, compiler: compiler, kernel: key.kernel,
                                                constants: constants)
            lock.lock(); states[key] = state; lock.unlock()
            if KernelVariants.logged {
                print(String(format: "Shaders: variant of %@, flags %x of %x, own %x of %x", key.kernel.function, key.flags,
                             key.kernel.fixedFlags, key.pass, key.kernel.fixedPassFlags))
            }
            return state
        } catch {
            print("Shaders: no variant of \(key.kernel.function) for flags \(key.flags), \(key.pass): \(error)")
            return nil
        }
    }
}

/// Every compute pipeline, made from one compile of the shaders for one ray tracer (the CUSTOM_RT macro) and
/// specialised for one set of light types (function constant 0, see Scene.lightTypeMask). A value, so a scene load or a
/// hot reload builds the next set in the background while frames keep using this one, and the renderer swaps the whole
/// set between two frames.
struct Pipelines {
    let kind: RayTracerKind
    let api: RenderAPI             // Metal 4: compiled and specialised by its compiler (MTL4Compiler)
    let lightTypes: UInt32
    let library: MTLLibrary        // kept: another set of light types specialises it again without recompiling
    private let states: [MTLComputePipelineState?]
    let variants: KernelVariants

    subscript(_ kernel: Kernel) -> MTLComputePipelineState { states[kernel.rawValue]! }

    /// The pipeline for a dispatch of `kernel` whose uniforms carry `flags` and whose own flags are `pass`: the
    /// variant with them compiled in once it is ready (`wait`: now), else the general one.
    func state(_ kernel: Kernel, flags: UInt32, pass: UInt32 = 0, wait: Bool = false) -> MTLComputePipelineState {
        guard KernelVariants.enabled, kernel.fixedFlags | kernel.fixedPassFlags != 0 else { return self[kernel] }
        return variants.state(kernel, flags: flags, pass: pass, wait: wait) ?? self[kernel]
    }

    var rc: RCPipelines {
        RCPipelines(probe: self[.rcProbe], traceMerge: self[.rcTraceMerge], sh: self[.rcSH], clearAmbient: self[.rcClearAmbient],
                    resolve: self[.rcResolve])
    }
    /// The kernels that build the custom tracer's trees (nil for the Metal tracer).
    var rt: RTPipelines? {
        kind != .custom ? nil :
            RTPipelines(prep: self[.rtPrep], keys: self[.rtKeys], sortLocal: self[.rtSortLocal], sortGlobal: self[.rtSortGlobal],
                        hierarchy: self[.rtHierarchy], fit: self[.rtFit], crowdRefit: self[.crowdRefit],
                        vg: VGPipelines(reset: self[.vgReset], cut: self[.vgCut], finish: self[.vgFinish], pad: self[.vgPad],
                                        hierarchy: self[.vgHierarchy], fit: self[.vgFit]))
    }

    /// Compiles `source` for `kind` unless `library` already is that, then makes every pipeline, in parallel. Safe to
    /// call from any thread; `stats` (the traversal counters, RT_STATS) is read by the caller for that reason.
    /// `compiler`: Metal 4's (an `MTL4Compiler`), for `api` `.metal4`.
    init(device: MTLDevice, source: URL, kind: RayTracerKind, api: RenderAPI = .metal3, compiler: AnyObject? = nil,
         lightTypes: UInt32, stats: Bool, reusing library: MTLLibrary? = nil) throws {
        let start = CACurrentMediaTime()
        let library = try library ?? Pipelines.compile(device: device, source: source, kind: kind, stats: stats, compiler: compiler)
        let compiled = CACurrentMediaTime()
        let kernels = Kernel.allCases.filter { kind == .custom || !$0.customOnly }
        var states = [MTLComputePipelineState?](repeating: nil, count: Kernel.allCases.count)
        var failure: Error?
        let lock = NSLock()
        states.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: kernels.count) { i in
                do {
                    let constants = MTLFunctionConstantValues()
                    var types = lightTypes
                    constants.setConstantValue(&types, type: .uint, index: 0)
                    slots[kernels[i].rawValue] = try Pipelines.makeState(device: device, library: library, compiler: compiler,
                                                                         kernel: kernels[i], constants: constants)   // its own slot: no lock
                } catch {
                    lock.lock(); failure = failure ?? error; lock.unlock()
                }
            }
        }
        if let failure { throw failure }
        self.kind = kind
        self.api = api
        self.lightTypes = lightTypes
        self.library = library
        self.states = states
        self.variants = KernelVariants(device: device, library: library, compiler: compiler, lightTypes: lightTypes)
        // Worth a line when something was really compiled (Metal keeps what it compiled before in its on-disk cache).
        let ms = (compiled - start) * 1000, pipelineMs = (CACurrentMediaTime() - compiled) * 1000
        if ms + pipelineMs > 100 {
            print(String(format: "Shaders: source compiled in %.0f ms, %d pipelines in %.0f ms", ms, kernels.count, pipelineMs))
        }
    }

    /// `kernel`'s pipeline with `constants`: from Metal 4's compiler when there is one, else from the device.
    static func makeState(device: MTLDevice, library: MTLLibrary, compiler: AnyObject?, kernel: Kernel,
                          constants: MTLFunctionConstantValues) throws -> MTLComputePipelineState {
        if #available(macOS 26.0, *), let compiler = compiler as? MTL4Compiler {
            let function = MTL4LibraryFunctionDescriptor()
            function.library = library
            function.name = kernel.function
            let specialized = MTL4SpecializedFunctionDescriptor()
            specialized.functionDescriptor = function
            specialized.constantValues = constants
            let descriptor = MTL4ComputePipelineDescriptor()
            descriptor.computeFunctionDescriptor = specialized
            return try compiler.makeComputePipelineState(descriptor: descriptor)
        }
        let function = try library.makeFunction(name: kernel.function, constantValues: constants)
        return try device.makeComputePipelineState(function: function)
    }

    private static func compile(device: MTLDevice, source url: URL, kind: RayTracerKind, stats: Bool,
                                compiler: AnyObject?) throws -> MTLLibrary {
        let source = try ShaderSource.load(url)   // Shaders.metal with the pieces in Shaders/ spliced in
        let options = MTLCompileOptions()
        // MSL 3.2 for device-scope fences and coherent buffers (rtFitKernel, custom ray tracer). Older systems keep
        // 3.0 and then need METALRENDERER_RT=metal.
        if #available(macOS 15.0, *) { options.languageVersion = .version3_2 } else { options.languageVersion = .version3_0 }
        options.preprocessorMacros = ["CUSTOM_RT": NSNumber(value: kind == .custom ? 1 : 0),
                                      "RT_STATS": NSNumber(value: stats ? 1 : 0)]
        // Fast math is the default (relaxed costs ~0.2 ms a frame in the stress scene and renders the same image);
        // `METALRENDERER_MATH=relaxed` keeps infinities and NaNs exact, to rule fast math out when something looks off.
        // `safe` also keeps the order of every operation: a kernel's variants then compute bit for bit what its
        // general pipeline computes, which is how to check a variant's flags against the uniforms' (pngdiff.py).
        if #available(macOS 15.0, *), let mode = ProcessInfo.processInfo.environment["METALRENDERER_MATH"] {
            if mode == "relaxed" { options.mathMode = .relaxed }
            if mode == "safe" { options.mathMode = .safe }
        }
        if #available(macOS 26.0, *), let compiler = compiler as? MTL4Compiler {
            let descriptor = MTL4LibraryDescriptor()
            descriptor.source = source
            descriptor.options = options
            return try compiler.makeLibrary(descriptor: descriptor)
        }
        return try device.makeLibrary(source: source, options: options)
    }
}
