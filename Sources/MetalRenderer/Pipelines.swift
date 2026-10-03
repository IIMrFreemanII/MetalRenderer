import Foundation
import Metal
import QuartzCore

/// The compute kernels in Shaders.metal: case `trace` is the function `traceKernel`.
enum Kernel: Int, CaseIterable {
    case trace, geometryDebug, lightMap
    case manyLights, manyLightsReuse, meshLights, regirBuild, restirTemporal, restirSpatial
    case restirGIInitial, restirGITemporal, restirGISpatial
    case rcProbe, rcTraceMerge, rcSH, rcClearAmbient, rcResolve
    case reflection
    case temporal, atrous, shadowTemporal, shadowFilter, accumulate
    case fogInject, fogIntegrate, fogReference
    case sky, skyMean, cloudShadow, cloudNoise, transmittanceLUT, multiScatterLUT
    case composite, accumulateColor, taau
    // Custom ray tracer only: the per-frame build of its dynamic tree and of the virtual geometry's cut.
    case rtPrep, rtKeys, rtSortLocal, rtSortGlobal, rtHierarchy, rtFit
    case vgReset, vgCut, vgFinish, vgPad, vgHierarchy, vgFit

    var function: String { "\(self)Kernel" }
    /// Exists only in the custom tracer's variant of the shaders (CUSTOM_RT).
    var customOnly: Bool { rawValue >= Kernel.rtPrep.rawValue }
}

/// Every compute pipeline, made from one compile of Shaders.metal for one ray tracer (the CUSTOM_RT macro) and
/// specialised for one set of light types (function constant 0, see Scene.lightTypeMask). A value, so a scene load or a
/// hot reload builds the next set in the background while frames keep using this one, and the renderer swaps the whole
/// set between two frames.
struct Pipelines {
    let kind: RayTracerKind
    let lightTypes: UInt32
    let library: MTLLibrary        // kept: another set of light types specialises it again without recompiling
    private let states: [MTLComputePipelineState?]

    subscript(_ kernel: Kernel) -> MTLComputePipelineState { states[kernel.rawValue]! }

    var rc: RCPipelines {
        RCPipelines(probe: self[.rcProbe], traceMerge: self[.rcTraceMerge], sh: self[.rcSH], clearAmbient: self[.rcClearAmbient],
                    resolve: self[.rcResolve])
    }
    /// The kernels that build the custom tracer's trees (nil for the Metal tracer).
    var rt: RTPipelines? {
        kind != .custom ? nil :
            RTPipelines(prep: self[.rtPrep], keys: self[.rtKeys], sortLocal: self[.rtSortLocal], sortGlobal: self[.rtSortGlobal],
                        hierarchy: self[.rtHierarchy], fit: self[.rtFit],
                        vg: VGPipelines(reset: self[.vgReset], cut: self[.vgCut], finish: self[.vgFinish], pad: self[.vgPad],
                                        hierarchy: self[.vgHierarchy], fit: self[.vgFit]))
    }

    /// Compiles `source` for `kind` unless `library` already is that, then makes every pipeline, in parallel. Safe to
    /// call from any thread; `stats` (the traversal counters, RT_STATS) is read by the caller for that reason.
    init(device: MTLDevice, source: URL, kind: RayTracerKind, lightTypes: UInt32, stats: Bool, reusing library: MTLLibrary? = nil) throws {
        let start = CACurrentMediaTime()
        let library = try library ?? Pipelines.compile(device: device, source: source, kind: kind, stats: stats)
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
                    let function = try library.makeFunction(name: kernels[i].function, constantValues: constants)
                    slots[kernels[i].rawValue] = try device.makeComputePipelineState(function: function)   // its own slot: no lock
                } catch {
                    lock.lock(); failure = failure ?? error; lock.unlock()
                }
            }
        }
        if let failure { throw failure }
        self.kind = kind
        self.lightTypes = lightTypes
        self.library = library
        self.states = states
        // Worth a line when something was really compiled (Metal keeps what it compiled before in its on-disk cache).
        let ms = (compiled - start) * 1000, pipelineMs = (CACurrentMediaTime() - compiled) * 1000
        if ms + pipelineMs > 100 {
            print(String(format: "Shaders: source compiled in %.0f ms, %d pipelines in %.0f ms", ms, kernels.count, pipelineMs))
        }
    }

    private static func compile(device: MTLDevice, source url: URL, kind: RayTracerKind, stats: Bool) throws -> MTLLibrary {
        let source = try String(contentsOf: url, encoding: .utf8)
        let options = MTLCompileOptions()
        // MSL 3.2 for device-scope fences and coherent buffers (rtFitKernel, custom ray tracer). Older systems keep
        // 3.0 and then need METALRENDERER_RT=metal.
        if #available(macOS 15.0, *) { options.languageVersion = .version3_2 } else { options.languageVersion = .version3_0 }
        options.preprocessorMacros = ["CUSTOM_RT": NSNumber(value: kind == .custom ? 1 : 0),
                                      "RT_STATS": NSNumber(value: stats ? 1 : 0)]
        // Fast math is the default (relaxed costs ~0.2 ms a frame in the stress scene and renders the same image);
        // `METALRENDERER_MATH=relaxed` keeps infinities and NaNs exact, to rule fast math out when something looks off.
        if #available(macOS 15.0, *), ProcessInfo.processInfo.environment["METALRENDERER_MATH"] == "relaxed" {
            options.mathMode = .relaxed
        }
        return try device.makeLibrary(source: source, options: options)
    }
}
