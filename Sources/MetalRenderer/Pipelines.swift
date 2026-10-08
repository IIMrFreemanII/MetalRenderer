import Foundation
import Metal
import QuartzCore

/// The compute kernels in Shaders/*.metal: case `trace` is the function `traceKernel`.
enum Kernel: Int, CaseIterable {
    case trace, glass, liquid, liquidApply, geometryDebug, lightMap
    case manyLights, manyLightsReuse, meshLights, regirBuild, restirTemporal, restirSpatial, megaLightsCull, megaLightsSample
    case restirGIInitial, restirGITemporal, restirGISpatial
    case rcProbe, rcTraceMerge, rcSH, rcClearAmbient, rcResolve
    case lumenProbe, lumenTrace, lumenFilter, lumenSH, lumenResolve, lumenHZB, lumenCardCapture, lumenCardLight,
         lumenCardRadiosity, lumenCardCombine, lumenCull,
         lumenGlobalBin, lumenGlobalCompose
    case reflection
    case pathTrace              // the reference path tracer (Shaders/PathTrace.metal)
    case temporal, atrous, shadowTemporal, shadowFilter, accumulate
    case fogInject, fogIntegrate, fogReference
    case sky, skyMean, cloudShadow, cloudNoise, transmittanceLUT, multiScatterLUT
    case composite, accumulateColor, tonemap
    case focus, dof, bloomDown, bloomUp, finish   // the lens and the finish (Post.metal)
    case neuralWarp, neuralPrepare, neuralConv, neuralPool, neuralFinish   // our own denoising upscaler (NeuralUpscaler)
    case crowdPose, crowdSkin   // the crowd's pose slots: skinning matrices, then vertices (CrowdSkinner)
    // Rigid bodies (PhysicsGPU): a step's stages, then the frame's poses.
    case physicsReset, physicsClear, physicsInsert, physicsPairs, physicsLink, physicsNarrow
    case physicsParticleInsert, physicsParticleNeighbours
    case physicsSubsteps, physicsPose, physicsParticlePose, physicsClothMesh, physicsSoftMesh, physicsSoftNormals
    case physicsHair, physicsHairTick, physicsHairReset, physicsHairCurves   // hair (PhysicsHair.swift)
    // Liquids (PhysicsFluidGPU): a group's start and pour, the scan, PBF's sort and solve, MPM's grid, the bodies' impulses.
    case fluidReset, fluidBegin, fluidPour, fluidApply, fluidScanBlocks, fluidScanTop, fluidScanAdd
    case fluidPredict, fluidCellsClear, fluidCellCount, fluidScatter, fluidCellSort, fluidReorder
    case fluidPbfNeighbours, fluidPbfLambda, fluidPbfDelta, fluidPbfVelocity, fluidPbfVorticity, fluidPbfViscosity
    case fluidMpmClear, fluidMpmKeys, fluidMpmP2G, fluidMpmGrid, fluidMpmG2P
    case fluidSurfaceClear, fluidSurfaceSplat, fluidSurfaceBlur, fluidSurfaceCount, fluidSurfaceVertex, fluidSurfaceQuad, fluidSurfaceTail
    case plantWind              // the plants' variants in the wind (PlantTracing)
    // The raster visibility buffer (Shaders/Raster.metal): culling, the chunks' bounds, the depth pyramid, its view.
    case rasterReset, rasterCull, rasterChunks, rasterBounds, hzbInit, hzbReduce, rasterDebug
    // Virtual shadow maps (Shaders/VSM.metal): the pages' upkeep, then the culling of what draws them.
    case vsmReset, vsmViewReset, vsmFree, vsmInvalidate, vsmAlloc, vsmSettle, vsmCull, vsmChunks, vsmDebug
    // Virtual geometry: the per-frame cut, and its clusters' boxes (METALRENDERER_VG_MODE=clusters).
    case vgReset, vgCut, vgBoxes
    case rasterVGCut, rasterVGRetest, rasterVGMeshArgs   // the raster clusters (Shaders/RasterClusters.metal)
    case vsmVGCut               // ...in the shadow maps

    var function: String { "\(self)Kernel" }

    /// The bits of Uniforms.flags that this kernel's variants have compiled in (KernelVariants): the ones it reads
    /// that stay the same from frame to frame. A bit that is missing here is only read at run time, as before; a bit
    /// the kernel doesn't read would only make variants that are the same code.
    var fixedFlags: UInt32 {
        typealias F = UniformFlags
        switch self {
        // F.wind: every kernel that casts many rays. Their traversal holds the wind's turns only while it blows.
        case .trace: return F.specular | F.upscale | F.blueNoise | F.skyMap | F.lightMaps | F.noClamp | F.restir | F.allLights | F.wind
            | F.visBuffer | F.vsm
        case .manyLights, .manyLightsReuse: return F.blueNoise | F.wind | F.vsm
        case .restirSpatial, .megaLightsSample: return F.specular | F.vsm
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
    private var building = 0             // asked for and not ready yet (in the background)
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
    /// How many are being made in the background.
    var pending: Int { lock.lock(); defer { lock.unlock() }; return building }

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
        lock.lock(); building += 1; lock.unlock()
        KernelVariants.queue.async {
            _ = self.make(key)
            self.lock.lock(); self.building -= 1; self.lock.unlock()
        }
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

/// Every compute pipeline, made from one compile of the shaders (with or without the RT_STATS counters) and
/// specialised for one set of light types (function constant 0, see Scene.lightTypeMask). A value, so a scene load or a
/// hot reload builds the next set in the background while frames keep using this one, and the renderer swaps the whole
/// set between two frames.
/// The pipeline sets made lately, by what they were made for: a scene switch back to light types seen before takes
/// their set instead of specialising all the kernels again (1.5–3 s on an M1 Max). Any thread. (Generic for the tests.)
final class PipelineCache<Value> {
    struct Key: Hashable {
        var api: RenderAPI
        var stats: Bool
        var lightTypes: UInt32
        var generation: Int        // the shaders' (Renderer.shaderGeneration): a reload makes every older set stale
    }
    /// How many sets are kept (each is the kernels' pipelines and the variants made for them since).
    let capacity: Int
    private let lock = NSLock()
    private var sets: [(key: Key, pipelines: Value)] = []   // the most recently used last

    init(capacity: Int = 6) { self.capacity = capacity }

    var count: Int { lock.lock(); defer { lock.unlock() }; return sets.count }

    func get(_ key: Key) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let i = sets.firstIndex(where: { $0.key == key }) else { return nil }
        let set = sets.remove(at: i)
        sets.append(set)
        return set.pipelines
    }

    /// Keeps `pipelines` for `key`; sets of older shaders go, then the least recently used beyond `capacity`. A set of
    /// older shaders than those kept (a scene load that started before a reload) isn't kept.
    func put(_ key: Key, _ pipelines: Value) {
        lock.lock(); defer { lock.unlock() }
        if let newest = sets.map(\.key.generation).max(), key.generation < newest { return }
        sets.removeAll { $0.key == key || $0.key.generation < key.generation }
        sets.append((key, pipelines))
        if sets.count > capacity { sets.removeFirst(sets.count - capacity) }
    }
}

struct Pipelines {
    let stats: Bool                // compiled with the ray queries' counters (RT_STATS)
    let api: RenderAPI             // Metal 4: compiled and specialised by its compiler (MTL4Compiler)
    let lightTypes: UInt32
    let library: MTLLibrary        // kept: another set of light types specialises it again without recompiling
    private let states: [MTLComputePipelineState?]
    let variants: KernelVariants

    /// The raster visibility buffer's draw (rasterVertex, rasterFragment): instance and triangle ids into an rg32Uint
    /// target, over a depth32Float one.
    let visibility: MTLRenderPipelineState
    /// The raster clusters' draw by mesh shaders (rasterClusterMesh, rasterFragment).
    let clusterMesh: MTLRenderPipelineState
    static let visibilityFormat = MTLPixelFormat.rg32Uint
    static let depthFormat = MTLPixelFormat.depth32Float
    /// The virtual shadow maps' draws (vsmVertex; vsmClearVertex, the pages' clear): depth only, each triangle into its
    /// page's slice of the pool (VSMTargets.pool).
    let vsm: MTLRenderPipelineState
    let vsmClear: MTLRenderPipelineState

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
    var neural: NeuralPipelines {
        NeuralPipelines(warp: self[.neuralWarp], prepare: self[.neuralPrepare], conv: self[.neuralConv], pool: self[.neuralPool],
                        finish: self[.neuralFinish])
    }
    var lumen: LumenPipelines {
        LumenPipelines(probe: self[.lumenProbe], trace: self[.lumenTrace], filter: self[.lumenFilter], sh: self[.lumenSH],
                       clearAmbient: self[.rcClearAmbient], resolve: self[.lumenResolve],
                       hzb: self[.lumenHZB], hzbReduce: self[.hzbReduce], cardCapture: self[.lumenCardCapture],
                       cardLight: self[.lumenCardLight], cardRadiosity: self[.lumenCardRadiosity],
                       cardCombine: self[.lumenCardCombine], cull: self[.lumenCull], globalBin: self[.lumenGlobalBin],
                       globalCompose: self[.lumenGlobalCompose])
    }
    var vg: VGPipelines { VGPipelines(reset: self[.vgReset], cut: self[.vgCut], boxes: self[.vgBoxes]) }

    /// Compiles `source` unless `library` already is that, then makes every pipeline, in parallel. Safe to call from
    /// any thread; `stats` (the ray queries' counters, RT_STATS) is read by the caller for that reason.
    /// `compiler`: Metal 4's (an `MTL4Compiler`), for `api` `.metal4`. `load`: the load to report the pipelines to.
    init(device: MTLDevice, source: URL, api: RenderAPI = .metal3, compiler: AnyObject? = nil,
         lightTypes: UInt32, stats: Bool, reusing library: MTLLibrary? = nil, load: LoadJob? = nil) throws {
        let start = CACurrentMediaTime()
        let kernels = Kernel.allCases
        let step = load?.step("Shaders", total: kernels.count + 4, detail: library == nil ? "compiling the source" : "")
        let library = try library ?? Pipelines.compile(device: device, source: source, stats: stats, compiler: compiler)
        let compiled = CACurrentMediaTime()
        step?.set(detail: "pipelines")
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
                    step?.advance()
                } catch {
                    lock.lock(); failure = failure ?? error; lock.unlock()
                }
            }
        }
        if let failure { throw failure }
        visibility = try Pipelines.makeRenderState(device: device, library: library, compiler: compiler, lightTypes: lightTypes,
                                                   vertex: "rasterVertex", fragment: "rasterFragment", color: Pipelines.visibilityFormat)
        clusterMesh = try Pipelines.makeMeshState(device: device, library: library, compiler: compiler, lightTypes: lightTypes,
                                                  mesh: "rasterClusterMesh", fragment: "rasterFragment", color: Pipelines.visibilityFormat)
        vsm = try Pipelines.makeRenderState(device: device, library: library, compiler: compiler, lightTypes: lightTypes,
                                            vertex: "vsmVertex", fragment: "vsmFragment", color: nil)
        vsmClear = try Pipelines.makeRenderState(device: device, library: library, compiler: compiler, lightTypes: lightTypes,
                                                 vertex: "vsmClearVertex", fragment: "vsmFragment", color: nil)
        step?.finish()
        self.stats = stats
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

    /// A render pipeline over a `depthFormat` target and a `color` one (or none), specialised for the light types
    /// (whose feature bits the vertices read: TILED). Triangles as the input topology, which layered drawing wants.
    private static func makeRenderState(device: MTLDevice, library: MTLLibrary, compiler: AnyObject?, lightTypes: UInt32,
                                        vertex: String, fragment: String, color: MTLPixelFormat?) throws -> MTLRenderPipelineState {
        let constants = MTLFunctionConstantValues()
        var types = lightTypes
        constants.setConstantValue(&types, type: .uint, index: 0)
        if #available(macOS 26.0, *), let compiler = compiler as? MTL4Compiler {
            func function(_ name: String) -> MTL4SpecializedFunctionDescriptor {
                let f = MTL4LibraryFunctionDescriptor()
                f.library = library
                f.name = name
                let specialized = MTL4SpecializedFunctionDescriptor()
                specialized.functionDescriptor = f
                specialized.constantValues = constants
                return specialized
            }
            let d = MTL4RenderPipelineDescriptor()
            d.vertexFunctionDescriptor = function(vertex)
            d.fragmentFunctionDescriptor = function(fragment)
            if let color { d.colorAttachments[0].pixelFormat = color }
            d.inputPrimitiveTopology = .triangle
            return try compiler.makeRenderPipelineState(descriptor: d)
        }
        let d = MTLRenderPipelineDescriptor()
        d.label = vertex
        d.vertexFunction = try library.makeFunction(name: vertex, constantValues: constants)
        d.fragmentFunction = try library.makeFunction(name: fragment, constantValues: constants)
        if let color { d.colorAttachments[0].pixelFormat = color }
        d.depthAttachmentPixelFormat = depthFormat
        d.inputPrimitiveTopology = .triangle
        return try device.makeRenderPipelineState(descriptor: d)
    }

    /// A mesh-shader pipeline (no object stage): `mesh`'s threadgroups make the triangles `fragment` shades.
    private static func makeMeshState(device: MTLDevice, library: MTLLibrary, compiler: AnyObject?, lightTypes: UInt32,
                                      mesh: String, fragment: String, color: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let constants = MTLFunctionConstantValues()
        var types = lightTypes
        constants.setConstantValue(&types, type: .uint, index: 0)
        if #available(macOS 26.0, *), let compiler = compiler as? MTL4Compiler {
            func function(_ name: String) -> MTL4SpecializedFunctionDescriptor {
                let f = MTL4LibraryFunctionDescriptor()
                f.library = library
                f.name = name
                let specialized = MTL4SpecializedFunctionDescriptor()
                specialized.functionDescriptor = f
                specialized.constantValues = constants
                return specialized
            }
            let d = MTL4MeshRenderPipelineDescriptor()
            d.meshFunctionDescriptor = function(mesh)
            d.fragmentFunctionDescriptor = function(fragment)
            d.colorAttachments[0].pixelFormat = color
            return try compiler.makeRenderPipelineState(descriptor: d)
        }
        let d = MTLMeshRenderPipelineDescriptor()
        d.label = mesh
        d.meshFunction = try library.makeFunction(name: mesh, constantValues: constants)
        d.fragmentFunction = try library.makeFunction(name: fragment, constantValues: constants)
        d.colorAttachments[0].pixelFormat = color
        d.depthAttachmentPixelFormat = depthFormat
        return try device.makeRenderPipelineState(descriptor: d, options: []).0
    }

    static func compile(device: MTLDevice, source url: URL, stats: Bool, compiler: AnyObject?) throws -> MTLLibrary {
        let source = try ShaderSource.load(url)   // Shaders.metal with the pieces in Shaders/ spliced in
        let options = MTLCompileOptions()
        if #available(macOS 15.0, *) { options.languageVersion = .version3_2 } else { options.languageVersion = .version3_0 }
        options.preprocessorMacros = ["RT_STATS": NSNumber(value: stats ? 1 : 0)]
        // Fast math is the default (relaxed cost ~0.2 ms a frame in the old stress hall and rendered the same image);
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
