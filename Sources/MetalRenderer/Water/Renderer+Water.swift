import Characters
import Effects
import EngineCore
import Foundation
import Metal
import Physics
import Plants
import simd

/// A scene's water on the GPU (Shaders/Water.metal, WaterCommon.metal): its looks, its surfaces' own structure, the
/// water map around the camera (WaterMap: drawn on the CPU from the scene's WaterField, in the
/// background as the camera goes, uploaded into the back one of two copies and swapped in), the FFT ocean's
/// textures, and per frame slot the record the shading reads (GPUWaterScene, its address in SceneShading.water).
package final class WaterSystem {
    let device: MTLDevice
    private(set) var records: [MTLBuffer] = []
    private var looks: MTLBuffer
    /// The map's two copies (each a 2D array: [near, far]) and the one frames read.
    private var maps: [MTLTexture] = []
    private var infos: [MTLTexture] = []
    private var front = 0
    private var swappedFrame: UInt32 = 0
    /// The FFT ocean's cascades and the caustics (WaterWaves fills them once there are waves).
    var waves: MTLTexture
    var slopes: MTLTexture
    var caustics: MTLTexture
    var fftReady = false
    var causticsReady = false
    /// The FFT's starting spectrum (per cascade), its work arrays (two RGBA slices a cascade), the foam kept between
    /// frames; the wind the spectrum was made for.
    private var h0: MTLTexture?
    private var spectrum: MTLTexture?
    private var spectrumB: MTLTexture?
    private var foam: MTLTexture?
    private var spectrumWind: SIMD2<Float>?
    /// The near patch (Water.metal waterNearKernel): its grid's vertices as the waves moved them, where each is at
    /// rest, its triangles, its structure (refitted every frame), and where it is this frame (the scene's x, z).
    private var near: (vertices: MTLBuffer, rest: MTLBuffer, indices: MTLBuffer, structure: MTLAccelerationStructure,
                       descriptor: MTLPrimitiveAccelerationStructureDescriptor, scratch: MTLBuffer)?
    private(set) var nearCenter: SIMD2<Float>?
    /// `METALRENDERER_WATER_NEAR`: the near patch's cells a side (0: none), and half its side (m).
    static let nearCells = ProcessInfo.processInfo.environment["METALRENDERER_WATER_NEAR"].flatMap(Int.init) ?? 192
    static let nearRadius: Float = 120

    /// What the map was drawn for: the scene's water's key, and per level where it is (nil: not drawn).
    private(set) var key = ""
    private weak var field: WaterField?
    private var levels: [WaterMap.Level?] = [nil, nil]
    private var drawing = [false, false]
    private var drawn: [WaterMap.Level?] = [nil, nil]   // from the background, waiting to be uploaded
    private let lock = NSLock()
    private var generation = 0
    private static let queue = DispatchQueue(label: "MetalRenderer.waterMap", qos: .userInitiated)
    /// The scene the looks were written for (Scene.serial).
    private var sceneID: Int?
    /// The highest and lowest any water's surface reaches (the scene's y): its still surfaces', and the waves'.
    private var top: Float = 0
    private var bottom: Float = 0
    /// The still surfaces' structure and its buffers (built when a scene is adopted).
    private var surfaces: (structure: MTLAccelerationStructure, vertices: MTLBuffer, indices: MTLBuffer, looks: MTLBuffer)?
    private lazy var queue = device.makeCommandQueue()

    /// The wind over the water (m/s): `METALRENDERER_WATER_WIND`, else 7 (a moderate breeze: whitecaps here and there).
    static let windSpeed = ProcessInfo.processInfo.environment["METALRENDERER_WATER_WIND"].flatMap(Float.init) ?? 7
    /// `METALRENDERER_WATER_OFF=1`: scenes are made without their water (to measure what it costs).
    static let off = ProcessInfo.processInfo.environment["METALRENDERER_WATER_OFF"] == "1"
    /// `METALRENDERER_WATER_DEBUG`: 1 shows the map on the water (wet, depth, flow), 2 its normals.
    static let debug = ProcessInfo.processInfo.environment["METALRENDERER_WATER_DEBUG"].flatMap(UInt32.init) ?? 0

    package init?(device: MTLDevice) {
        self.device = device
        func array(_ format: MTLPixelFormat, _ size: Int, _ slices: Int, mips: Bool, _ label: String, shared: Bool) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: mips)
            d.textureType = .type2DArray
            d.arrayLength = slices
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = shared ? .shared : .private
            let t = device.makeTexture(descriptor: d)
            t?.label = label
            return t
        }
        let n = WaterMap.size
        for c in 0..<2 {
            guard let s = array(.rg32Float, n, 2, mips: false, "waterMapSurface\(c)", shared: true),
                  let i = array(.rgba8Unorm, n, 2, mips: false, "waterMapInfo\(c)", shared: true) else { return nil }
            maps.append(s)
            infos.append(i)
        }
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: WaterWaves.size, height: WaterWaves.size, mipmapped: true)
        cd.usage = [.shaderRead, .shaderWrite]
        cd.storageMode = .private
        guard let w = array(.rgba16Float, WaterWaves.size, WaterWaves.cascades, mips: true, "waterWaves", shared: false),
              let sl = array(.rgba16Float, WaterWaves.size, WaterWaves.cascades, mips: true, "waterSlopes", shared: false),
              let ca = device.makeTexture(descriptor: cd),
              let lk = device.makeBuffer(length: 64 * 256, options: .storageModeShared) else { return nil }
        ca.label = "waterCaustics"
        (waves, slopes, caustics, looks) = (w, sl, ca, lk)
        for slot in 0..<Renderer.maxFramesInFlight {
            guard let b = device.makeBuffer(length: MemoryLayout<GPUWaterScene>.stride, options: .storageModeShared) else { return nil }
            b.label = "waterScene\(slot)"
            records.append(b)
        }
    }

    /// The looks as they are now (a look edited in place: its water's surfaces stay).
    func setLooks(_ list: [WaterLook]) {
        let table = list.prefix(looks.length / 64).map(\.gpu)
        table.withUnsafeBytes { looks.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }

    func resources(slot: Int) -> [MTLResource] {
        var out: [MTLResource] = [records[slot], looks, maps[0], maps[1], infos[0], infos[1], waves, slopes, caustics]
        if let s = surfaces { out += [s.structure, s.vertices, s.indices, s.looks] }
        if let n = near { out += [n.vertices, n.rest, n.indices, n.structure] }
        return out
    }

    /// The near patch's grid and structure (once).
    private func makeNearPatch() {
        guard near == nil, WaterSystem.nearCells > 1, let queue else { return }
        let cells = WaterSystem.nearCells, n = cells + 1
        var vertices: [SIMD4<Float>] = [], indices: [UInt32] = []
        for j in 0..<n { for i in 0..<n { vertices.append(SIMD4(Float(i), -1000, Float(j), 255)) } }
        for j in 0..<cells {
            for i in 0..<cells {
                let a = UInt32(j * n + i), b = a + 1, c = a + UInt32(n), d = c + 1
                indices += [a, d, b, a, c, d]
            }
        }
        guard let vb = vertices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let ib = indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let rb = device.makeBuffer(length: n * n * 8, options: .storageModePrivate) else { return }
        vb.label = "waterNearVertices"
        rb.label = "waterNearRest"
        let g = MTLAccelerationStructureTriangleGeometryDescriptor()
        g.vertexBuffer = vb
        g.vertexStride = 16
        g.indexBuffer = ib
        g.indexType = .uint32
        g.triangleCount = cells * cells * 2
        g.opaque = true
        let d = MTLPrimitiveAccelerationStructureDescriptor()
        d.geometryDescriptors = [g]
        d.usage = .refit
        let sizes = device.accelerationStructureSizes(descriptor: d)
        guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, sizes.refitScratchBufferSize, 16), options: .storageModePrivate),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeAccelerationStructureCommandEncoder() else { return }
        structure.label = "waterNearPatch"
        enc.build(accelerationStructure: structure, descriptor: d, scratchBuffer: scratch, scratchBufferOffset: 0)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        near = (vb, rb, ib, structure, d, scratch)
    }

    /// Where the near patch goes for a camera at `camera` (the scene's x, z): there, snapped to half a metre.
    func placeNear(camera: SIMD2<Float>) {
        guard fftReady, WaterSystem.nearCells > 1 else { nearCenter = nil; return }
        nearCenter = (camera * 2).rounded(.toNearestOrEven) / 2
    }

    /// The scene's still surfaces as one structure of their own (and their vertices, indices and looks).
    private func buildSurfaces(_ w: SceneWater) {
        surfaces = nil
        let swell: Float = w.looks.contains { $0.waves >= 0.05 } ? 4 : 0.5
        top = (w.positions.map(\.y).max() ?? 0) + swell
        bottom = (w.positions.map(\.y).min() ?? 0) - swell
        guard !w.indices.isEmpty, let queue else { return }
        let vertices = w.positions.map { SIMD4($0, 0) }
        guard let vb = vertices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let ib = w.indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let lb = w.triangleLooks.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 4), options: .storageModeShared) })
        else { return }
        let g = MTLAccelerationStructureTriangleGeometryDescriptor()
        g.vertexBuffer = vb
        g.vertexStride = 16
        g.indexBuffer = ib
        g.indexType = .uint32
        g.triangleCount = w.indices.count / 3
        g.opaque = true
        let d = MTLPrimitiveAccelerationStructureDescriptor()
        d.geometryDescriptors = [g]
        let sizes = device.accelerationStructureSizes(descriptor: d)
        guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, 16), options: .storageModePrivate),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeAccelerationStructureCommandEncoder() else { return }
        structure.label = "waterSurfaces"
        enc.build(accelerationStructure: structure, descriptor: d, scratchBuffer: scratch, scratchBufferOffset: 0)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        surfaces = (structure, vb, ib, lb)
    }

    /// A new scene's water: its looks and materials written, its map kept if it is the same water (its key), else
    /// drawn again (at once: the first frame has it).
    func adopt(_ scene: Scene, camera: SIMD2<Double>) {
        guard let w = scene.water else { return }
        if sceneID != scene.serial {
            sceneID = scene.serial
            let table = w.looks.prefix(256).map(\.gpu)
            if table.count * 64 > looks.length, let b = device.makeBuffer(length: table.count * 64, options: .storageModeShared) { looks = b }
            table.withUnsafeBytes { looks.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            buildSurfaces(w)
        }
        // (The same key: the same water, another scene of it (the open world's next): its field takes over the map's
        // redraws as the camera goes, and the map that is drawn stays.)
        field = w.field
        guard w.key != key else { return }
        key = w.key
        lock.lock()
        generation += 1
        drawn = [nil, nil]
        drawing = [false, false]
        lock.unlock()
        levels = [nil, nil]
        guard let f = w.field else { return }
        let started = CFAbsoluteTimeGetCurrent()
        var fresh: [WaterMap.Level] = []
        for k in 0..<2 { fresh.append(WaterMap.draw(f, level: k, origin: WaterMap.origin(level: k, at: camera))) }
        upload(fresh[0], fresh[1], frame: 0, force: true)
        print(String(format: "Water: map drawn in %.0f ms (%d looks)", (CFAbsoluteTimeGetCurrent() - started) * 1000, w.looks.count))
        // METALRENDERER_WATER_PROBE="x,z0,z1": the field along a line (debugging).
        if let probe = ProcessInfo.processInfo.environment["METALRENDERER_WATER_PROBE"]?.split(separator: ",").compactMap({ Double($0) }), probe.count == 3 {
            for k in 0...24 {
                let z = probe[1] + (probe[2] - probe[1]) * Double(k) / 24, g = f.ground(probe[0], z), s = f.water(probe[0], z, ground: g)
                print(String(format: "Water probe z %.1f: ground %.2f level %@ flow %.2f look %d", z, g, s.map { String(format: "%.2f", $0.level) } ?? "-",
                             s.map { simd_length($0.flow) } ?? 0, s?.look ?? -1))
            }
        }
    }

    /// The map's levels the camera has gone far from, drawn again in the background; one that is ready, uploaded.
    func follow(camera: SIMD2<Double>, frame: UInt32) {
        guard let f = field else { return }
        lock.lock()
        let ready = drawn
        lock.unlock()
        if ready[0] != nil || ready[1] != nil {
            // (Into the copy no frame in flight reads: not twice within maxFramesInFlight frames.)
            if frame &- swappedFrame >= UInt32(Renderer.maxFramesInFlight) {
                lock.lock()
                drawn = [nil, nil]
                lock.unlock()
                upload(ready[0] ?? levels[0]!, ready[1] ?? levels[1]!, frame: frame, force: false)
            }
        }
        for k in 0..<2 {
            guard let l = levels[k], WaterMap.stale(level: k, origin: l.origin, at: camera) else { continue }
            lock.lock()
            let busy = drawing[k] || drawn[k] != nil
            if !busy { drawing[k] = true }
            let gen = generation
            lock.unlock()
            guard !busy else { continue }
            let origin = WaterMap.origin(level: k, at: camera)
            WaterSystem.queue.async { [weak self] in
                let level = WaterMap.draw(f, level: k, origin: origin)
                guard let self else { return }
                self.lock.lock()
                if self.generation == gen { self.drawn[k] = level; self.drawing[k] = false }
                self.lock.unlock()
            }
        }
    }

    private func upload(_ near: WaterMap.Level, _ far: WaterMap.Level, frame: UInt32, force: Bool) {
        let back = force ? front : 1 - front, n = WaterMap.size
        for (k, l) in [near, far].enumerated() {
            l.surface.withUnsafeBytes {
                maps[back].replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, slice: k, withBytes: $0.baseAddress!,
                                       bytesPerRow: n * 8, bytesPerImage: n * n * 8)
            }
            l.info.withUnsafeBytes {
                infos[back].replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, slice: k, withBytes: $0.baseAddress!,
                                    bytesPerRow: n * 4, bytesPerImage: n * n * 4)
            }
        }
        levels = [near, far]
        front = back
        swappedFrame = frame
    }

    /// This frame's record for `slot`: the time and wind, the map's levels in the scene's coordinates (`offset` the
    /// world's place of its origin), the looks, the textures.
    func write(slot: Int, time: Float, previousTime: Float, windDirection: Float, offset: SIMD2<Double>, lookCount: Int) {
        var r = GPUWaterScene()
        r.time = SIMD4(time, previousTime, time - previousTime, top)
        let a = windDirection * .pi / 180
        r.wind = SIMD4(cos(a), sin(a), WaterSystem.windSpeed, 0)
        if fftReady {
            r.cascades = SIMD4(WaterWaves.lengths[0], WaterWaves.lengths[1], WaterWaves.lengths[2], Float(WaterWaves.cascades))
            // (Where the scene's origin is in each tile, worked out in doubles: a far open world's offset keeps its waves.)
            func phase(_ k: Int) -> SIMD2<Float> {
                let L = Double(WaterWaves.lengths[k])
                return SIMD2(Float(offset.x - (offset.x / L).rounded(.down) * L), Float(offset.y - (offset.y / L).rounded(.down) * L))
            }
            let p0 = phase(0), p1 = phase(1), p2 = phase(2)
            r.phase0 = SIMD4(p0.x, p0.y, p1.x, p1.y)
            r.phase1 = SIMD4(p2.x, p2.y, 0, 0)
        }
        var flags: UInt32 = fftReady ? GPUWaterScene.fft : 0
        if causticsReady { flags |= GPUWaterScene.causticsOn }
        r.near.y = bottom
        if let near = levels[0], let far = levels[1] {
            flags |= GPUWaterScene.mapped
            r.map0 = SIMD4(Float(near.origin.x - offset.x), Float(near.origin.y - offset.y), Float(near.cell), Float(WaterMap.size))
            r.map1 = SIMD4(Float(far.origin.x - offset.x), Float(far.origin.y - offset.y), Float(far.cell), Float(WaterMap.size))
        }
        r.counts = SIMD4(UInt32(max(min(lookCount, 256), 1)), flags, 0, WaterSystem.debug)
        r.looks = looks.gpuAddress
        r.level = maps[front].gpuResourceID
        r.info = infos[front].gpuResourceID
        r.waves = waves.gpuResourceID
        r.slopes = slopes.gpuResourceID
        r.caustics = caustics.gpuResourceID
        if let c = nearCenter, let n = near {
            r.counts.y |= GPUWaterScene.nearPatch
            r.near = SIMD4(c.x, bottom, c.y, WaterSystem.nearRadius)
            r.nearPatch = n.structure.gpuResourceID
            r.nearVertices = n.vertices.gpuAddress
            r.nearIndices = n.indices.gpuAddress
            r.nearRest = n.rest.gpuAddress
        }
        if let s = surfaces {
            r.surfaces = s.structure.gpuResourceID
            r.surfaceVertices = s.vertices.gpuAddress
            r.surfaceIndices = s.indices.gpuAddress
            r.surfaceLooks = s.looks.gpuAddress
        }
        records[slot].contents().storeBytes(of: r, as: GPUWaterScene.self)
    }
}

extension WaterSystem {
    /// The FFT ocean's waves for this frame (Shaders/Water.metal): the spectrum turned to `time`, the inverse FFT, the
    /// textures made, their mips. The starting spectrum is made again when the wind changes.
    func encodeWaves(_ passes: FrameEncoder, pipelines: Pipelines, time: Float, dt: Float, windDirection: Float) {
        let n = WaterWaves.size, cascades = WaterWaves.cascades
        func array(_ format: MTLPixelFormat, _ slices: Int, _ label: String) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: n, height: n, mipmapped: false)
            d.textureType = .type2DArray
            d.arrayLength = slices
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            let t = device.makeTexture(descriptor: d)
            t?.label = label
            return t
        }
        if spectrum == nil {
            spectrum = array(.rgba32Float, cascades * 2, "waterSpectrum")
            spectrumB = array(.rgba32Float, cascades * 2, "waterSpectrumB")
            foam = array(.r16Float, cascades, "waterFoam")
        }
        let a = windDirection * .pi / 180, wind = SIMD2(WaterSystem.windSpeed, a)
        if spectrumWind != wind {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: n, height: n, mipmapped: false)
            d.textureType = .type2DArray
            d.arrayLength = cascades
            d.usage = .shaderRead
            d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d) else { return }
            t.label = "waterH0"
            for c in 0..<cascades {
                let amps = WaterSpectrum.amplitudes(cascade: c, wind: Double(wind.x), direction: Double(a))
                amps.withUnsafeBytes {
                    t.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, slice: c, withBytes: $0.baseAddress!,
                              bytesPerRow: n * 16, bytesPerImage: n * n * 16)
                }
            }
            h0 = t
            spectrumWind = wind
        }
        guard let h0, let spectrum, let spectrumB, let foam, let enc = passes.compute("water waves", serial: true) else { return }
        let l = WaterWaves.lengths
        var p = WaterFFTParams(lengths: SIMD4(l[0], l[1], l[2], 0), time: time, dt: min(max(dt, 0), 0.1), vertical: 0, pad: 0)
        enc.setComputePipelineState(pipelines[.waterSpectrum])
        enc.setBytes(&p, length: MemoryLayout<WaterFFTParams>.stride, index: 0)
        enc.setTextures([h0, spectrum], range: 0..<2)
        enc.dispatchThreads(MTLSize(width: n, height: n, depth: cascades), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.setComputePipelineState(pipelines[.waterFFT])
        for (vertical, from, to) in [(UInt32(0), spectrum, spectrumB), (UInt32(1), spectrumB, spectrum)] {
            p.vertical = vertical
            enc.setBytes(&p, length: MemoryLayout<WaterFFTParams>.stride, index: 0)
            enc.setTextures([from, to], range: 0..<2)
            enc.dispatchThreadgroups(MTLSize(width: n, height: cascades * 2, depth: 1), threadsPerThreadgroup: MTLSize(width: n / 2, height: 1, depth: 1))
        }
        enc.setComputePipelineState(pipelines[.waterAssemble])
        enc.setBytes(&p, length: MemoryLayout<WaterFFTParams>.stride, index: 0)
        enc.setTextures([spectrum, waves, slopes, foam], range: 0..<4)
        enc.dispatchThreads(MTLSize(width: n, height: n, depth: cascades), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        passes.generateMipmaps([waves, slopes], pass: "water waves")
        fftReady = true
    }

    /// The sun's caustics from this frame's waves (cascade 2's), and their mips (the deeper, the blurrier).
    func encodeCaustics(_ passes: FrameEncoder, pipelines: Pipelines, sun: SIMD3<Float>?) {
        guard fftReady, let sun, sun.y > 0.05, let enc = passes.compute("water waves", serial: true) else { causticsReady = false; return }
        var p = WaterCausticParams(sun: SIMD4(sun, 1.333), length: WaterWaves.lengths[2], pad0: 0, pad1: 0, pad2: 0)
        enc.setComputePipelineState(pipelines[.waterCaustics])
        enc.setBytes(&p, length: MemoryLayout<WaterCausticParams>.stride, index: 0)
        enc.setTextures([slopes, caustics], range: 0..<2)
        enc.dispatchThreads(MTLSize(width: WaterWaves.size, height: WaterWaves.size, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        passes.generateMipmaps([caustics], pass: "water waves")
        causticsReady = true
    }

    /// The near patch's vertices for this frame (where the camera is: `nearCenter`), from this frame's waves, and its
    /// structure refitted around them.
    func encodeNear(_ passes: FrameEncoder, pipelines: Pipelines, slot: Int) {
        makeNearPatch()
        guard let c = nearCenter, let n = near, let enc = passes.compute("water near", serial: true) else { return }
        var p = WaterNearParams(center: c, radius: WaterSystem.nearRadius, cells: UInt32(WaterSystem.nearCells))
        enc.setComputePipelineState(pipelines[.waterNear])
        enc.setBytes(&p, length: MemoryLayout<WaterNearParams>.stride, index: 0)
        enc.setBuffer(records[slot], offset: 0, index: 1)
        enc.setBuffer(n.vertices, offset: 0, index: 2)
        enc.setBuffer(n.rest, offset: 0, index: 3)
        enc.useResources(resources(slot: slot), usage: .read)
        enc.useResources([n.vertices, n.rest], usage: [.read, .write])
        let side = WaterSystem.nearCells + 1
        enc.dispatchThreads(MTLSize(width: side, height: side, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        passes.updatePrimitives(PrimitiveRefit(structures: [n.structure], descriptors: [n.descriptor], scratch: n.scratch, scratchOffsets: [0]),
                                pass: "water near")
    }
}

/// waterCausticsKernel's parameters (MSL WaterCausticParams).
struct WaterCausticParams {
    var sun: SIMD4<Float>
    var length: Float
    var pad0: Float, pad1: Float, pad2: Float
}

/// waterNearKernel's parameters (MSL WaterNearParams).
struct WaterNearParams {
    var center: SIMD2<Float>
    var radius: Float
    var cells: UInt32
}

/// waterSpectrumKernel's, waterFFTKernel's and waterAssembleKernel's parameters (MSL WaterFFTParams).
struct WaterFFTParams {
    var lengths: SIMD4<Float>
    var time: Float
    var dt: Float
    var vertical: UInt32
    var pad: UInt32
}

extension Renderer {
    /// The FFT ocean's waves, when the scene has water with waves, and the near patch they move.
    package func encodeWaterWaves(slot: Int, passes: FrameEncoder) {
        guard scene.hasWater, let w = scene.water, w.looks.contains(where: { $0.waves >= 0.05 }), let water else { return }
        water.encodeWaves(passes, pipelines: pipelines, time: animTime, dt: animTime - previousAnimTime, windDirection: settings.foliage.windDirection)
        // (The sun as this frame's lights have it: the sky set its direction.)
        let sun = scene.firstSun.flatMap { i -> SIMD3<Float>? in
            guard slot < lightBuffers.count, (i + 1) * MemoryLayout<GPULight>.stride <= lightBuffers[slot].length else { return nil }
            let l = lightBuffers[slot].contents().bindMemory(to: GPULight.self, capacity: i + 1)[i]
            return simd_normalize(SIMD3(l.axis.x, l.axis.y, l.axis.z))
        }
        water.encodeCaustics(passes, pipelines: pipelines, sun: sun)
        water.encodeNear(passes, pipelines: pipelines, slot: slot)
    }

    /// This frame's water: the system made or brought up to the scene, the map following the camera, the slot's record
    /// written and its address put in the shading arguments. False: no water this frame.
    package func prepareWater(slot: Int) -> Bool {
        guard let w = scene.water, scene.hasWater else {
            if slot < shadingArgs.count { shadingArgs[slot].contents().storeBytes(of: UInt64(0), toByteOffset: Renderer.shadingWaterOffset, as: UInt64.self) }
            return false
        }
        if water == nil { water = WaterSystem(device: device) }
        guard let system = water, slot < shadingArgs.count else { return false }
        let eye = SIMD2(Double(camera.position.x) + w.offset.x, Double(camera.position.z) + w.offset.y)
        system.adopt(scene, camera: eye)
        system.follow(camera: eye, frame: frameIndex)
        system.placeNear(camera: SIMD2(camera.position.x, camera.position.z))
        system.write(slot: slot, time: animTime, previousTime: previousAnimTime, windDirection: settings.foliage.windDirection, offset: w.offset,
                     lookCount: w.looks.count)
        shadingArgs[slot].contents().storeBytes(of: system.records[slot].gpuAddress, toByteOffset: Renderer.shadingWaterOffset, as: UInt64.self)
        return true
    }
}

/// The FFT ocean's sizes (Shaders/Water.metal's waterSpectrum / waterFFT / waterAssemble kernels): three cascades of
/// 256 x 256 over tiles of these sides, the longest swell to the smallest chop.
enum WaterWaves {
    static let size = 256
    static let cascades = 3
    static let lengths: [Float] = [233, 41.3, 7.9]
}
