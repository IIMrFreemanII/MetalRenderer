import Foundation
import Metal
import QuartzCore

/// The compute kernels in Shaders/*.metal: case `trace` is the function `traceKernel`.
package enum Kernel: Int, CaseIterable {
    case trace, glass, liquid, liquidApply, geometryDebug, lightMap
    case solid                  // solid shading: the whole frame (RenderSettings.solid, Output.metal), the classic look
    case solidTrace, solidResolve   // ...the look that tells things apart (RenderSettings.solidLook): its rays, then its picture
    case water, waterApply   // water's surface over the trace (Shaders/Water.metal)
    case waterSpectrum, waterFFT, waterAssemble   // the FFT ocean's waves, every frame
    case waterNear              // the near patch's vertices, moved by the waves
    case waterCaustics          // the sun's caustics under the waves
    case manyLights, manyLightsReuse, meshLights, regirBuild, restirTemporal, restirSpatial
    case restirGIInitial, restirGITemporal, restirGISpatial
    case rcProbe, rcTraceMerge, rcFilter, rcSH, rcClearAmbient, rcResolve
    case reflection
    case pathTrace              // the reference path tracer (Shaders/PathTrace.metal)
    case temporal, atrous, shadowTemporal, shadowFilter, accumulate
    case fogInject, fogIntegrate, fogReference
    case sky, skyMean, cloudShadow, cloudNoise, transmittanceLUT, multiScatterLUT
    case mipDown2D, mipDown2DArray   // mip chains under Metal 4 (Shaders/Mips.metal)
    case composite, accumulateColor, tonemap
    case taaResolve             // temporal AA without upscaling (Post.metal)
    case focus, dof, bloomDown, bloomUp, finish   // the lens and the finish (Post.metal)
    case crowdPose, crowdSkin, crowdHair   // the crowd's pose slots: skinning matrices, vertices, hair (CrowdSkinner)
    // Rigid bodies (PhysicsGPU): a step's stages, then the frame's poses.
    case physicsReset, physicsClear, physicsInsert, physicsPairs, physicsLink, physicsNarrow
    case physicsParticleInsert, physicsParticleNeighbours
    case physicsSubsteps, physicsPose, physicsParticlePose, physicsClothMesh, physicsSoftMesh, physicsSoftNormals
    case physicsHair, physicsHairTick, physicsHairReset, physicsHairCurves   // hair (PhysicsHair.swift)
    case physicsFractureReset, physicsFractureCommand, physicsFractureVerdict, physicsFractureApply, physicsFracturePose, physicsFractureEvents, physicsFracturePairs, physicsFractureLink, physicsFractureNarrow, physicsFractureClear, physicsFractureInsert,
         physicsColourReset, physicsColourStart, physicsColourArgs, physicsColourWin, physicsColourTake, physicsColourCount,
         physicsColourStarts, physicsColourScatter, physicsColourExtra,
         physicsWideStart, physicsWideIntegrate, physicsWideVelocities, physicsWideArgs, physicsWidePush, physicsWideKick, physicsWideJoints, physicsWideTail   // destruction (Physics+Fracture.swift)
    // Liquids (PhysicsFluidGPU): a group's start and pour, the scan, PBF's sort and solve, MPM's grid, the bodies' impulses.
    case fluidReset, fluidBegin, fluidPour, fluidApply, fluidScanBlocks, fluidScanTop, fluidScanAdd
    case fluidPredict, fluidCellsClear, fluidCellCount, fluidScatter, fluidCellSort, fluidReorder
    case fluidPbfNeighbours, fluidPbfLambda, fluidPbfDelta, fluidPbfVelocity, fluidPbfVorticity, fluidPbfViscosity
    case fluidMpmClear, fluidMpmKeys, fluidMpmP2G, fluidMpmGrid, fluidMpmG2P
    case fluidSurfaceClear, fluidSurfaceSplat, fluidSurfaceBlur, fluidSurfaceCount, fluidSurfaceVertex, fluidSurfaceQuad, fluidSurfaceTail
    case plantWind              // the plants' variants in the wind (PlantTracing)
    // Particle effects (ParticlesGPU, Shaders/ParticleSim.metal): a step's begin, emit and simulate, then the frame's
    // records and boxes for the rays.
    case particleReset, particleBegin, particleEmit, particleSimulate, particlePose, particlePoseTail, particleMeshPose, particleOverlay, particleTrailPose
    case particleInject         // destruction's dust: the physics' breaks as a proxy emitter's events
    case particleLight, particleLayer   // their light, once a particle; the camera's layer of them (FramePlan.particles)
    case particleDistortDiscs, particleDistort   // the heat haze's discs, its bend of the frame's light (ParticleEmitter.distortion)
    // Virtual geometry: the per-frame cut, and its clusters' boxes (METALRENDERER_VG_MODE=clusters).
    case vgReset, vgCut, vgBoxes
    case gizmoLines             // the VFX editor's gizmos (Shaders/Gizmo.metal)
    case pick                   // the Material Designer's click-to-pick (Shaders/Pick.metal)

    package var function: String { "\(self)Kernel" }

    /// The bits of Uniforms.flags that this kernel's variants have compiled in (KernelVariants): the ones it reads
    /// that stay the same from frame to frame. A bit that is missing here is only read at run time, as before; a bit
    /// the kernel doesn't read would only make variants that are the same code.
    package var fixedFlags: UInt32 {
        typealias F = UniformFlags
        switch self {
        // F.wind: every kernel that casts many rays. Their traversal holds the wind's turns only while it blows.
        case .trace: return F.specular | F.upscale | F.blueNoise | F.skyMap | F.lightMaps | F.noClamp | F.restir | F.allLights | F.wind
        case .manyLights, .manyLightsReuse: return F.blueNoise | F.wind
        case .restirSpatial: return F.specular
        case .restirGIInitial: return F.blueNoise | F.noClamp | F.skyMap | F.allLights | F.wind
        case .reflection: return F.blueNoise | F.noClamp | F.reference | F.restir | F.shadowDenoiser | F.skyMap | F.wind
        case .rcProbe, .rcTraceMerge, .lightMap, .solid, .solidTrace: return F.wind
        case .fogInject: return F.blueNoise | F.skyMap
        default: return 0
        }
    }
    /// The same for the kernel's own flags: the word its `bind` passes (Uniforms.tracePassFlags, GPURestirParams'
    /// and GPURestirGIParams' flags, GPUFogParams.reflectionPassFlags). The "last frame is valid" bits change on the
    /// first frame after a reset, so they stay run-time tests: a variant for that one frame would be compiled for nothing.
    package var fixedPassFlags: UInt32 {
        switch self {
        case .trace: return Uniforms.traceBounces | Uniforms.traceManyLights
        case .restirTemporal: return GPURestirParams.visibilityReuse
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
package final class KernelVariants {
    static let enabled = ProcessInfo.processInfo.environment["METALRENDERER_VARIANTS"] != "0"
    /// `METALRENDERER_VARIANTS=log` prints each variant as it is made: the kernel, its compiled-in bits and their masks.
    private static let logged = ProcessInfo.processInfo.environment["METALRENDERER_VARIANTS"] == "log"
    private struct Key: Hashable { let kernel: Kernel; let flags: UInt32; let pass: UInt32 }

    private let device: MTLDevice
    private let library: MTLLibrary
    private let compiler: MTL4Compiler?   // Metal 4's: the variants are made the way the set was
    private let lightTypes: UInt32
    private let lock = NSLock()
    private var states: [Key: MTLComputePipelineState] = [:]
    private var started: Set<Key> = []   // being built, or failed: not asked for again
    private var building = 0             // asked for and not ready yet (in the background)
    // Below the frame loop's priority: several variants compile at once after a settings change, and the frame has a
    // pipeline to run in the meantime.
    private static let queue = DispatchQueue(label: "MetalRenderer.variants", qos: .utility, attributes: .concurrent)

    package init(device: MTLDevice, library: MTLLibrary, compiler: MTL4Compiler?, lightTypes: UInt32) {
        self.device = device
        self.library = library
        self.compiler = compiler
        self.lightTypes = lightTypes
    }

    /// How many variants are ready.
    var count: Int { lock.lock(); defer { lock.unlock() }; return states.count }
    /// How many are being made in the background.
    package var pending: Int { lock.lock(); defer { lock.unlock() }; return building }

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
package final class PipelineCache<Value> {
    package struct Key: Hashable {
        package var stats: Bool
        package var lightTypes: UInt32
        package var generation: Int        // the shaders' (Renderer.shaderGeneration): a reload makes every older set stale
        package var procedural = ""        // the procedural materials' code spliced in (MatShaderCode.splice)

        /// (As the memberwise initializer, for the modules above this one.)
        package init(stats: Bool, lightTypes: UInt32, generation: Int, procedural: String = "") {
            self.stats = stats
            self.lightTypes = lightTypes
            self.generation = generation
            self.procedural = procedural
        }
    }
    /// How many sets are kept (each is the kernels' pipelines and the variants made for them since).
    package let capacity: Int
    private let lock = NSLock()
    private var sets: [(key: Key, pipelines: Value)] = []   // the most recently used last

    package init(capacity: Int = 6) { self.capacity = capacity }

    package var count: Int { lock.lock(); defer { lock.unlock() }; return sets.count }

    package func get(_ key: Key) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let i = sets.firstIndex(where: { $0.key == key }) else { return nil }
        let set = sets.remove(at: i)
        sets.append(set)
        return set.pipelines
    }

    /// Keeps `pipelines` for `key`; sets of older shaders go, then the least recently used beyond `capacity`. A set of
    /// older shaders than those kept (a scene load that started before a reload) isn't kept.
    package func put(_ key: Key, _ pipelines: Value) {
        lock.lock(); defer { lock.unlock() }
        if let newest = sets.map(\.key.generation).max(), key.generation < newest { return }
        sets.removeAll { $0.key == key || $0.key.generation < key.generation }
        sets.append((key, pipelines))
        if sets.count > capacity { sets.removeFirst(sets.count - capacity) }
    }
}

package struct Pipelines {
    package let stats: Bool                // compiled with the ray queries' counters (RT_STATS)
    package let lightTypes: UInt32
    package let library: MTLLibrary        // kept: another set of light types specialises it again without recompiling
    package let procedural: String         // the procedural materials' code spliced into it (MatShaderCode.splice; "" none)
    private let states: [MTLComputePipelineState?]
    package let variants: KernelVariants

    package subscript(_ kernel: Kernel) -> MTLComputePipelineState { states[kernel.rawValue]! }

    /// The pipeline for a dispatch of `kernel` whose uniforms carry `flags` and whose own flags are `pass`: the
    /// variant with them compiled in once it is ready (`wait`: now), else the general one.
    package func state(_ kernel: Kernel, flags: UInt32, pass: UInt32 = 0, wait: Bool = false) -> MTLComputePipelineState {
        guard KernelVariants.enabled, kernel.fixedFlags | kernel.fixedPassFlags != 0 else { return self[kernel] }
        return variants.state(kernel, flags: flags, pass: pass, wait: wait) ?? self[kernel]
    }

    /// Compiles `source` unless `library` already is that, then makes every pipeline, in parallel. Safe to call from
    /// any thread; `stats` (the ray queries' counters, RT_STATS) is read by the caller for that reason.
    /// `compiler`: Metal 4's, which the frames' pipelines are made by (nil: the device's, for work outside the frames and
    /// the tests). `load`: the load to report the pipelines to.
    package init(device: MTLDevice, source: URL, compiler: MTL4Compiler? = nil,
         lightTypes: UInt32, stats: Bool, procedural: String = "", reusing library: MTLLibrary? = nil, load: LoadJob? = nil) throws {
        let start = CACurrentMediaTime()
        let kernels = Kernel.allCases
        let step = load?.step("Shaders", total: kernels.count + 4, detail: library == nil ? "compiling the source" : "")
        let library = try library ?? Pipelines.compile(device: device, source: source, stats: stats, compiler: compiler, procedural: procedural)
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
        step?.finish()
        self.stats = stats
        self.lightTypes = lightTypes
        self.library = library
        self.procedural = procedural
        self.states = states
        self.variants = KernelVariants(device: device, library: library, compiler: compiler, lightTypes: lightTypes)
        // Worth a line when something was really compiled (Metal keeps what it compiled before in its on-disk cache).
        let ms = (compiled - start) * 1000, pipelineMs = (CACurrentMediaTime() - compiled) * 1000
        if ms + pipelineMs > 100 {
            print(String(format: "Shaders: source compiled in %.0f ms, %d pipelines in %.0f ms", ms, kernels.count, pipelineMs))
        }
    }

    /// `kernel`'s pipeline with `constants`: from Metal 4's compiler when there is one, else from the device.
    package static func makeState(device: MTLDevice, library: MTLLibrary, compiler: MTL4Compiler?, kernel: Kernel,
                          constants: MTLFunctionConstantValues) throws -> MTLComputePipelineState {
        if let compiler {
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

    package static func compile(device: MTLDevice, source url: URL, stats: Bool, compiler: MTL4Compiler?, procedural: String = "") throws -> MTLLibrary {
        var text = try ShaderSource.load(url)
        if !procedural.isEmpty { text = text.replacingOccurrences(of: ShaderSource.proceduralMarker, with: procedural) }
        return try compile(device: device, text: text, stats: stats, compiler: compiler)   // Shaders.metal with the pieces in Shaders/ spliced in
    }

    /// `source` compiled as Shaders.metal is (the VFX library's: VFXCompiler).
    package static func compile(device: MTLDevice, text source: String, stats: Bool, compiler: MTL4Compiler?) throws -> MTLLibrary {
        let options = MTLCompileOptions()
        options.languageVersion = .version3_2
        options.preprocessorMacros = ["RT_STATS": NSNumber(value: stats ? 1 : 0)]
        // Fast math is the default (relaxed cost ~0.2 ms a frame in the old stress hall and rendered the same image);
        // `METALRENDERER_MATH=relaxed` keeps infinities and NaNs exact, to rule fast math out when something looks off.
        // `safe` also keeps the order of every operation: a kernel's variants then compute bit for bit what its
        // general pipeline computes, which is how to check a variant's flags against the uniforms' (pngdiff.py).
        if let mode = ProcessInfo.processInfo.environment["METALRENDERER_MATH"] {
            if mode == "relaxed" { options.mathMode = .relaxed }
            if mode == "safe" { options.mathMode = .safe }
        }
        if let compiler {
            let descriptor = MTL4LibraryDescriptor()
            descriptor.source = source
            descriptor.options = options
            return try compiler.makeLibrary(descriptor: descriptor)
        }
        return try device.makeLibrary(source: source, options: options)
    }
}
