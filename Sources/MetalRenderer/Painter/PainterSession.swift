import Foundation
import Metal
import simd

// Swift twins of MaterialShaders/Paint.metal's structs.
struct PaintObjectArgs {
    var transform = matrix_identity_float4x4
    var normalMatrix = matrix_identity_float4x4
    var firstIndex: UInt32 = 0
    var vertexOffset: UInt32 = 0
    var size: UInt32 = 0
    var triangles: UInt32 = 0
    var texelsPerMetre: Float = 0
    var heightDepth: Float = 0
    var normalStrength: Float = 1
    var layerCount: UInt32 = 0
    var aoTexture: UInt32 = .max
    var mirror: UInt32 = 0
    var instance: UInt32 = 0
    var level: Float = 0
}

struct PaintDab {
    var centre: SIMD2<Float>
    var radius: Float
    var hardness: Float
    var opacity: Float
    var flow: Float
    var angle: Float = 0
    var stamp: Int32 = -1
    var aspect: Float = 1
    var pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
}

struct PaintDabArgs {
    var viewProjection = matrix_identity_float4x4
    var camera = SIMD4<Float>.zero
    var screen = SIMD2<Float>.zero
    var dabs: UInt32 = 0
    var stencil: UInt32 = 0
    var stencilFrame = matrix_identity_float3x3
    var tolerance: Float = 0.01
    var fill: UInt32 = 0
    var pad0: Float = 0, pad1: Float = 0
}

struct PaintApplyArgs {
    var value = SIMD4<Float>.zero
    var erase: UInt32 = 0
    var colour: UInt32 = 0
    var stencil: UInt32 = 0
    var size: UInt32 = 0
}

struct PaintLayerRecord {
    var paint0 = SIMD4<UInt32>(repeating: .max)
    var paint1 = SIMD4<UInt32>(repeating: .max)
    var graph0 = SIMD4<UInt32>(repeating: .max)
    var graph1 = SIMD4<UInt32>(repeating: .max)
    var info = SIMD4<UInt32>.zero
    var colour = SIMD4<Float>.zero
    var values = SIMD4<Float>.zero
    var emissive = SIMD4<Float>.zero
    var projection = SIMD4<Float>.zero
}

struct PaintOriginalGPU {
    var albedo: SIMD4<Float>
    var emission: SIMD4<Float>
    var textures: SIMD4<UInt32>
}

/// What a stroke paints into: a paint layer's channels, or a layer's mask (its painted part).
enum PaintTarget: Equatable {
    case channels(Set<PaintChannel>)
    case mask
}

/// A painted object's texture set and layers on the GPU, while a scene has it (Renderer+Painter.swift): its texel map
/// (each texel's triangle and barycentrics: Paint.metal), its tiles' bounds (which tiles a dab may touch), the layers'
/// textures (a paint layer's channels and a mask's painted part, premultiplied by their coverage; a mask's generated
/// part), the graphs' bakes its fills project, and the texture set the composite writes, which the renderer's slots
/// hold. Strokes go into a stroke texture, then into the target's channels over what they were when it began; undo
/// keeps the tiles a stroke touched, before and after.
final class PainterSession {
    static let tile = 32

    let device: MTLDevice
    let object: PaintedObject
    let size: Int
    private(set) var document: PaintDocument
    private(set) var documentVersion = -1
    let corners: MTLBuffer
    let materialOf: MTLBuffer
    private(set) var texelMap: MTLTexture?
    /// Per tile: object-space min (xyz) and max, as the vertices were when it was measured (lo > hi: empty).
    private(set) var tileBounds: [SIMD4<Float>] = []
    var tilesAcross: Int { (size + PainterSession.tile - 1) / PainterSession.tile }

    // The texture set (mipmapped but `detail`).
    let base: MTLTexture, orm: MTLTexture, normal: MTLTexture, emissive: MTLTexture, height: MTLTexture, opacity: MTLTexture
    let detail: MTLTexture

    /// A layer's textures.
    final class LayerTextures {
        var channels: [PaintChannel: MTLTexture] = [:]
        var mask: MTLTexture?
        var generated: MTLTexture?
        var generatedFrom: PaintGenerator?
    }
    private(set) var layers: [UUID: LayerTextures] = [:]
    /// Layers to be filled from the object as it was (PaintLayer.source "original"), once their textures are there.
    private var originals: Set<UUID> = []
    /// The graphs fills project, by name: their bakes' textures once there.
    private var graphs: [String: MatOutputs] = [:]
    /// The mesh maps (PaintBake), once made; its occlusion is the ORM's R.
    var bake: PaintBake?
    var occlusion: MTLTexture?
    /// Tiles whose texels the composite must write again (all: every tile).
    private(set) var dirty: Set<Int> = []
    var allDirty: Bool { dirty.count >= tilesAcross * tilesAcross }
    /// The texture set was composited at least once (its slots may be given it).
    private(set) var composited = false

    // The stroke under way.
    struct Stroke {
        var layer: UUID
        var target: PaintTarget
        var values: PaintValues
        var erase: Bool
        var stencil: Bool
        var touched: Set<Int> = []
    }
    private(set) var stroke: Stroke?
    private var strokeTexture: MTLTexture?
    private var strokeColour: MTLTexture?
    private var strokeBase: [Int: MTLTexture] = [:]        // per target texture (its index in `targets`)
    /// Dabs waiting for the next frame, and its view.
    var pendingDabs: [PaintDab] = []
    var pendingFill: [UInt8]? = nil
    var mirror: UInt32 = 0
    /// The stroke has ended: its undo is to be kept once its last dabs are in.
    private var ending = false

    /// What a stroke did, to undo or redo it: the tiles it touched in each texture it painted, as they were before
    /// and after (packed, a tile after the other).
    final class UndoRecord {
        let layer: UUID
        let target: PaintTarget
        let tiles: [Int]
        var before: [MTLTexture] = []
        var after: [MTLTexture] = []
        var bytes = 0
        init(layer: UUID, target: PaintTarget, tiles: [Int]) { self.layer = layer; self.target = target; self.tiles = tiles }
    }
    private(set) var undoRecords: [UndoRecord] = []
    static let undoBudget = 512 << 20
    /// Undo or redo asked for, done in the next frame (the record, and true for undo).
    var pendingUndo: [(UndoRecord, Bool)] = []
    /// Called when a stroke's undo record is kept (the painter's model registers it with its undo manager).
    var onStrokeRecorded: ((UndoRecord) -> Void)?

    init?(device: MTLDevice, object: PaintedObject, document: PaintDocument) {
        self.device = device
        self.object = object
        self.size = object.resolution
        self.document = document
        guard let corners = device.makeBuffer(bytes: object.atlas.corners, length: max(object.atlas.corners.count * 8, 16), options: .storageModeShared)
        else { return nil }
        self.corners = corners
        func make(_ format: MTLPixelFormat, mips: Bool, view: Bool = false, _ label: String) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: object.resolution, height: object.resolution, mipmapped: mips)
            d.usage = view ? [.shaderRead, .shaderWrite, .pixelFormatView] : [.shaderRead, .shaderWrite]
            d.storageMode = .private
            let t = device.makeTexture(descriptor: d)
            t?.label = "painted \(label)"
            return t
        }
        guard let b = make(.rgba8Unorm, mips: true, view: true, "base colour"), let o = make(.rgba8Unorm, mips: true, "orm"),
              let n = make(.rgba8Unorm, mips: true, "normal"), let e = make(.rgba8Unorm, mips: true, view: true, "emissive"),
              let h = make(.r16Float, mips: true, "height"), let op = make(.r8Unorm, mips: true, "opacity"),
              let d = make(.rgba8Unorm, mips: false, "detail normal") else { return nil }
        (base, orm, normal, emissive, height, opacity, detail) = (b, o, n, e, h, op, d)
        materialOf = device.makeBuffer(length: max(object.atlas.corners.count / 3, 16), options: .storageModeShared)!
        dirty = Set(0..<(tilesAcross * tilesAcross))
    }

    // MARK: - The texel map

    /// The texel map (drawn, then dilated `padding` times into the gutters) and the tiles' bounds, now (waits for the
    /// GPU). `indices`, `positions`, `normals`: the scene's buffers; `offsets`: each triangle's material offset.
    func prepare(queue: MTLCommandQueue, args: PaintObjectArgs, indices: MTLBuffer, positions: MTLBuffer, normals: MTLBuffer,
                 offsets: [UInt8]) throws {
        offsets.withUnsafeBytes { materialOf.contents().copyMemory(from: $0.baseAddress!, byteCount: min($0.count, materialOf.length)) }
        let compiler = MatCompiler.shared
        let library = try compiler.library(device)
        let rp = MTLRenderPipelineDescriptor()
        rp.vertexFunction = library.makeFunction(name: "paintTexelVertex")
        rp.fragmentFunction = library.makeFunction(name: "paintTexelFragment")
        rp.colorAttachments[0].pixelFormat = .rg32Uint
        let raster = try device.makeRenderPipelineState(descriptor: rp)
        let dilate = try compiler.state("paintDilate", device: device)
        let bounds = try compiler.state("paintTileBounds", device: device)
        func mapTexture() -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Uint, width: size, height: size, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard var a = mapTexture(), var b = mapTexture(), let cb = queue.makeCommandBuffer() else { throw MatError("no texel map") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = a
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        guard let r = cb.makeRenderCommandEncoder(descriptor: pass) else { throw MatError("no texel map pass") }
        r.setRenderPipelineState(raster)
        r.setCullMode(.none)
        r.setVertexBuffer(corners, offset: 0, index: 0)
        r.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: object.atlas.corners.count)
        r.endEncoding()
        guard let c = cb.makeComputeCommandEncoder() else { throw MatError("no texel map pass") }
        c.setComputePipelineState(dilate)
        c.setBuffer(corners, offset: 0, index: 0)
        let grid = MTLSize(width: size, height: size, depth: 1), group = MTLSize(width: 16, height: 16, depth: 1)
        for _ in 0..<UVUnwrap.padding(size) {
            c.setTexture(a, index: 0)
            c.setTexture(b, index: 1)
            c.dispatchThreads(grid, threadsPerThreadgroup: group)
            swap(&a, &b)
        }
        c.endEncoding()
        texelMap = a
        cb.commit()
        cb.waitUntilCompleted()
        try measureTiles(queue: queue, args: args, indices: indices, positions: positions, normals: normals, pipeline: bounds)
    }

    /// The tiles' bounds, with the vertices as they are now (a deforming object's: when painting starts on it).
    func measureTiles(queue: MTLCommandQueue, args: PaintObjectArgs, indices: MTLBuffer, positions: MTLBuffer, normals: MTLBuffer,
                      pipeline: MTLComputePipelineState? = nil) throws {
        guard let map = texelMap else { return }
        let state = try pipeline ?? MatCompiler.shared.state("paintTileBounds", device: device)
        let count = tilesAcross * tilesAcross
        guard let out = device.makeBuffer(length: count * 32, options: .storageModeShared), let cb = queue.makeCommandBuffer(),
              let c = cb.makeComputeCommandEncoder() else { throw MatError("no tile bounds") }
        var a = args
        a.size = UInt32(size)
        c.setComputePipelineState(state)
        c.setTexture(map, index: 0)
        c.setBytes(&a, length: MemoryLayout<PaintObjectArgs>.stride, index: 0)
        c.setBuffer(indices, offset: 0, index: 1)
        c.setBuffer(positions, offset: 0, index: 2)
        c.setBuffer(normals, offset: 0, index: 3)
        c.setBuffer(out, offset: 0, index: 4)
        c.dispatchThreadgroups(MTLSize(width: tilesAcross, height: tilesAcross, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        c.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        tileBounds = Array(UnsafeBufferPointer(start: out.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * count), count: 2 * count))
    }

    // MARK: - The document

    /// The document as it is now: textures for its layers (made or let go of), the graphs its fills name, and every
    /// tile to composite again. A layer whose source is "original" is filled from the object as it was.
    func sync(_ d: PaintDocument, version: Int) {
        guard version != documentVersion else { return }
        document = d
        documentVersion = version
        var live = Set<UUID>()
        for layer in d.layers {
            live.insert(layer.id)
            let t = layers[layer.id] ?? LayerTextures()
            if layers[layer.id] == nil, layer.source == "original" { originals.insert(layer.id) }
            layers[layer.id] = t
            if layer.kind == .paint {
                for c in layer.channels where t.channels[c] == nil { t.channels[c] = makePaint(c.isColor ? .rgba16Float : .rg16Float, "\(layer.name) \(c)") }
            }
            if let mask = layer.mask, mask.painted, t.mask == nil { t.mask = makePaint(.rg16Float, "\(layer.name) mask") }
            if layer.mask?.generator == nil { t.generated = nil; t.generatedFrom = nil }
        }
        for id in layers.keys where !live.contains(id) { layers[id] = nil }
        invalidate()
    }

    /// Every tile to composite again.
    func invalidate() { dirty = Set(0..<(tilesAcross * tilesAcross)) }

    /// A paint texture, cleared (no coverage).
    func makePaint(_ format: MTLPixelFormat, _ label: String) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.label = "paint \(label)"
        cleared.append(t)
        return t
    }
    /// Textures made since the last frame, to be cleared by it (private textures start undefined).
    var cleared: [MTLTexture] = []
    /// Layer textures given pixels (a document opened, a generator's mask made): written by the next frame.
    var uploads: [(MTLTexture, [UInt8], Int)] = []

    /// A graph a fill projects: its textures, if baked (asking for the bake, or baking it now in a benchmark).
    func graph(_ name: String, catalog: MaterialCatalog, now: Bool) -> MatOutputs? {
        guard let g = catalog.graph(name) else { return nil }
        let bake = MaterialBake.shared(device)
        let key = MaterialBake.key(g, catalog: catalog)
        if let o = bake.baked(key) ?? (now ? bake.bakeNow(g, key: key, catalog: catalog) : nil) {
            if graphs[name] !== o { graphs[name] = o; invalidate() }
            return o
        }
        bake.request(g, key: key, catalog: catalog) {}
        return nil
    }

    // MARK: - The composite

    /// The table the composite reads its textures through (MTLResourceIDs), and what it lists (to declare them).
    private func table(_ textures: [MTLTexture]) -> MTLBuffer? {
        let ids = textures.map(\.gpuResourceID)
        return ids.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared) }
    }

    /// The layers' records and the textures they name.
    func records(catalog: MaterialCatalog, now: Bool) -> ([PaintLayerRecord], [MTLTexture]) {
        var textures: [MTLTexture] = []
        func index(_ t: MTLTexture?) -> UInt32 {
            guard let t else { return .max }
            if let i = textures.firstIndex(where: { $0 === t }) { return UInt32(i) }
            textures.append(t)
            return UInt32(textures.count - 1)
        }
        var out: [PaintLayerRecord] = []
        for layer in document.layers where layer.visible {
            let t = layers[layer.id]
            var r = PaintLayerRecord()
            r.info = SIMD4(layer.kind == .paint ? 1 : 0, layer.channels.reduce(0) { $0 | $1.bit }, UInt32(layer.blend.rawValue),
                           UInt32(layer.heightBlend.rawValue))
            r.colour = SIMD4(layer.values.color, layer.opacity)
            r.values = SIMD4(layer.values.roughness, layer.values.metallic, layer.values.height, layer.values.opacity)
            r.emissive = SIMD4(layer.values.emissive, layer.mask?.base ?? 1)
            if layer.kind == .paint {
                r.paint0 = SIMD4(index(t?.channels[.color]), index(t?.channels[.roughness]), index(t?.channels[.metallic]), index(t?.channels[.height]))
                r.paint1.x = index(t?.channels[.emissive])
                r.paint1.y = index(t?.channels[.opacity])
            } else if let name = layer.graph, let o = graph(name, catalog: catalog, now: now) {
                r.graph0 = SIMD4(index(o.baseColor), index(o.orm), index(o.normal), index(o.emissive))
                r.graph1 = SIMD4(index(o.height), index(o.opacity), .max, .max)
                let graphSize = Float(o.baseColor?.width ?? o.orm?.width ?? o.height?.width ?? 1024)
                let uv = layer.projection == .uv
                // Tiles across the set (UV) or per metre (triplanar); the level whose texels are the set's.
                let tiles = uv ? max(layer.tiling * Float(size) / max(object.atlas.texelsPerMetre, 1e-3), 1e-3) : layer.tiling
                let texelsPerMetre = uv ? graphSize * tiles / Float(size) * object.atlas.texelsPerMetre : graphSize * tiles
                let level = max(log2(max(texelsPerMetre / max(object.atlas.texelsPerMetre, 1e-3), 1e-6)), 0)
                r.projection = SIMD4(uv ? 1 : 0, uv ? tiles : layer.tiling, 1, level)
            } else if layer.graph != nil {
                continue   // its bake isn't there yet: left out until it is
            }
            if layer.mask?.painted == true { r.paint1.z = index(t?.mask) }
            if layer.mask?.generator != nil { r.paint1.w = index(t?.generated) }
            out.append(r)
        }
        return (out, textures)
    }

    func objectArgs(transform: float4x4, scene: Scene) -> PaintObjectArgs {
        let m = scene.meshes[object.mesh]
        var a = PaintObjectArgs()
        a.transform = transform
        a.normalMatrix = transform.inverse.transpose
        a.firstIndex = m.firstIndex
        a.vertexOffset = m.vertexOffset
        a.size = UInt32(size)
        a.triangles = m.indexCount / 3
        a.texelsPerMetre = object.atlas.texelsPerMetre > 0 ? object.atlas.texelsPerMetre : Float(size)
        a.heightDepth = document.heightDepth
        a.normalStrength = document.normalStrength
        a.instance = UInt32(object.instance)
        return a
    }

    /// The tiles as a buffer of their indices.
    private func tileBuffer(_ tiles: [Int]) -> MTLBuffer? {
        let list = tiles.map { UInt32($0) }
        return list.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared) }
    }

    /// Writes this frame's work into `passes`: new textures cleared, uploads, layers filled from the object as it
    /// was, the dabs and fills into the stroke and the stroke into its target, an undo or redo, then the dirty tiles
    /// composited and the texture set's levels made. `scene` and its buffers: the vertices the texels are on.
    func encode(_ passes: FrameEncoder, scene: Scene, transform: float4x4, sceneTextures: [MTLTexture], indices: MTLBuffer,
                positions: MTLBuffer, normals: MTLBuffer, uvs: MTLBuffer, view: PaintDabArgs?, surfacePos: MTLTexture?,
                stamps: MTLTexture?, stencil: MTLTexture?, catalog: MaterialCatalog, now: Bool) {
        guard let map = texelMap else { return }
        var args = objectArgs(transform: transform, scene: scene)
        args.mirror = mirror
        let group = MTLSize(width: 8, height: 8, depth: 1)
        let compiler = MatCompiler.shared
        if !cleared.isEmpty, let clear = try? compiler.state("paintClear", device: device), let enc = passes.compute("paint clear", serial: true) {
            enc.setComputePipelineState(clear)
            for t in cleared {
                enc.setTexture(t, index: 0)
                enc.dispatchThreads(MTLSize(width: t.width, height: t.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            }
            passes.endCompute()
            cleared = []
        }
        if !uploads.isEmpty { upload(passes) }
        if !originals.isEmpty { bakeOriginals(passes, args: args, scene: scene, sceneTextures: sceneTextures, indices: indices, uvs: uvs) }
        if !pendingUndo.isEmpty { applyUndo(passes) }
        if stroke != nil, let view, let surfacePos { encodeStroke(passes, args: args, view: view, surfacePos: surfacePos, stamps: stamps,
                                                                  stencil: stencil, indices: indices, positions: positions, normals: normals) }
        guard !dirty.isEmpty, let composite = try? compiler.state("paintComposite", device: device),
              let normalState = try? compiler.state("paintNormal", device: device) else { return }
        let (records, textures) = records(catalog: catalog, now: now)
        var withAO = textures
        if let occlusion { args.aoTexture = UInt32(withAO.count); withAO.append(occlusion) }
        args.layerCount = UInt32(records.count)
        let tiles = Array(dirty).sorted()
        guard let tileList = tileBuffer(tiles), let table = table(withAO.isEmpty ? [base] : withAO),
              let recordBuffer = records.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress ?? UnsafeRawPointer(bitPattern: 16)!,
                                                                             length: max($0.count, 16), options: .storageModeShared) }),
              let enc = passes.compute("paint composite", serial: true) else { return }
        enc.setComputePipelineState(composite)
        enc.setTextures([map, base, orm, emissive, height, opacity, detail], range: 0..<7)
        enc.setBytes(&args, length: MemoryLayout<PaintObjectArgs>.stride, index: 0)
        enc.setBuffer(recordBuffer, offset: 0, index: 1)
        enc.setBuffer(table, offset: 0, index: 2)
        enc.setBuffer(indices, offset: 0, index: 3)
        enc.setBuffer(positions, offset: 0, index: 4)
        enc.setBuffer(normals, offset: 0, index: 5)
        enc.setBuffer(corners, offset: 0, index: 6)
        enc.setBuffer(tileList, offset: 0, index: 7)
        enc.useResources(withAO, usage: .read)
        enc.useResources([map, recordBuffer, table, indices, positions, normals, corners, tileList], usage: .read)
        enc.useResources([base, orm, emissive, height, opacity, detail], usage: .write)
        enc.dispatchThreadgroups(MTLSize(width: tiles.count, height: 1, depth: 1), threadsPerThreadgroup: group)
        enc.memoryBarrier(scope: .textures)
        enc.setComputePipelineState(normalState)
        enc.setTextures([height, detail, normal], range: 0..<3)
        enc.setBytes(&args, length: MemoryLayout<PaintObjectArgs>.stride, index: 0)
        enc.setBuffer(tileList, offset: 0, index: 1)
        enc.dispatchThreadgroups(MTLSize(width: tiles.count, height: 1, depth: 1), threadsPerThreadgroup: group)
        passes.endCompute()
        passes.generateMipmaps([base, orm, normal, emissive, height, opacity], pass: "paint levels")
        dirty = []
        composited = true
    }

    // MARK: - Strokes

    /// A stroke begins on `layer`'s `target` (its textures made if they aren't).
    func beginStroke(layer: UUID, target: PaintTarget, values: PaintValues, erase: Bool, stencil: Bool) {
        if stroke != nil { endStroke() }
        guard let t = layers[layer] else { return }
        if case .channels(let cs) = target {
            for c in cs where t.channels[c] == nil { t.channels[c] = makePaint(c.isColor ? .rgba16Float : .rg16Float, "\(c)") }
        } else if t.mask == nil {
            t.mask = makePaint(.rg16Float, "mask")
        }
        if strokeTexture == nil { strokeTexture = makePaint(.r16Float, "stroke") }
        if strokeColour == nil { strokeColour = makePaint(.rgba16Float, "stroke colour") }
        stroke = Stroke(layer: layer, target: target, values: values, erase: erase, stencil: stencil)
        strokeBase = [:]
        strokeCleared = false
        ending = false
    }
    private var strokeCleared = false

    /// The stroke has ended (its last dabs are drawn with the next frame, then its undo is kept).
    func endStroke() {
        guard stroke != nil else { return }
        ending = true
    }

    /// The textures a stroke paints into, in order.
    private func targets(_ s: Stroke) -> [(texture: MTLTexture, channel: PaintChannel?)] {
        guard let t = layers[s.layer] else { return [] }
        switch s.target {
        case .mask: return t.mask.map { [($0, nil)] } ?? []
        case .channels(let cs):
            return PaintChannel.allCases.filter { cs.contains($0) }.compactMap { c in t.channels[c].map { ($0, c) } }
        }
    }

    /// The tiles a dab at `centre`, `radius` pixels, may touch (their bounds projected onto the screen; mirrored too).
    func tiles(touching dabs: [PaintDab], view: PaintDabArgs, transform: float4x4) -> [Int] {
        var out: [Int] = []
        let count = tilesAcross * tilesAcross
        let m = view.viewProjection * transform
        func rect(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> (SIMD2<Float>, SIMD2<Float>)? {
            var a = SIMD2<Float>(repeating: .infinity), b = -a
            for k in 0..<8 {
                let p = SIMD3<Float>(k & 1 == 0 ? lo.x : hi.x, k & 2 == 0 ? lo.y : hi.y, k & 4 == 0 ? lo.z : hi.z)
                let c = m * SIMD4(p, 1)
                if c.w <= 1e-4 { return (SIMD2(repeating: -.infinity), SIMD2(repeating: .infinity)) }   // behind: anywhere
                let ndc = SIMD2(c.x, c.y) / c.w
                let s = SIMD2((ndc.x * 0.5 + 0.5) * view.screen.x, (0.5 - ndc.y * 0.5) * view.screen.y)
                a = simd_min(a, s); b = simd_max(b, s)
            }
            return (a, b)
        }
        for t in 0..<count {
            let lo = tileBounds[2 * t], hi = tileBounds[2 * t + 1]
            guard lo.x <= hi.x else { continue }
            let l3 = SIMD3(lo.x, lo.y, lo.z), h3 = SIMD3(hi.x, hi.y, hi.z)
            var boxes = [(l3, h3)]
            if mirror != 0 {
                let ax = Int(mirror - 1)
                var l = l3, h = h3
                (l[ax], h[ax]) = (-h3[ax], -l3[ax])
                boxes.append((l, h))
            }
            var hit = false
            for (l, h) in boxes {
                guard let (a, b) = rect(l, h) else { continue }
                for d in dabs where d.centre.x + d.radius >= a.x && d.centre.x - d.radius <= b.x && d.centre.y + d.radius >= a.y && d.centre.y - d.radius <= b.y {
                    hit = true
                    break
                }
                if hit { break }
            }
            if hit { out.append(t) }
        }
        return out
    }

    private func encodeStroke(_ passes: FrameEncoder, args: PaintObjectArgs, view: PaintDabArgs, surfacePos: MTLTexture, stamps: MTLTexture?,
                              stencil: MTLTexture?, indices: MTLBuffer, positions: MTLBuffer, normals: MTLBuffer) {
        guard var s = stroke, let map = texelMap, let strokeTexture, let strokeColour else { return }
        let compiler = MatCompiler.shared
        guard let dab = try? compiler.state("paintDab", device: device), let apply = try? compiler.state("paintApply", device: device),
              let copy = try? compiler.state("paintTileCopy", device: device), let clear = try? compiler.state("paintClear", device: device)
        else { return }
        let fill = pendingFill
        let dabs = pendingDabs
        pendingDabs = []
        pendingFill = nil
        var tiles: [Int]
        if fill != nil {
            tiles = (0..<(tilesAcross * tilesAcross)).filter { tileBounds[2 * $0].x <= tileBounds[2 * $0 + 1].x }
        } else if !dabs.isEmpty {
            tiles = self.tiles(touching: dabs, view: view, transform: args.transform)
        } else {
            tiles = []
        }
        let group = MTLSize(width: 8, height: 8, depth: 1)
        let outputs = targets(s)
        if !tiles.isEmpty, let enc = passes.compute("paint stroke", serial: true) {
            if !strokeCleared {
                enc.setComputePipelineState(clear)
                for t in [strokeTexture, strokeColour] {
                    enc.setTexture(t, index: 0)
                    enc.dispatchThreads(MTLSize(width: size, height: size, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                }
                enc.memoryBarrier(scope: .textures)
                strokeCleared = true
            }
            // The tiles touched first now: what their targets hold kept as the stroke's base.
            let fresh = tiles.filter { !s.touched.contains($0) }
            if !fresh.isEmpty, let list = tileBuffer(fresh) {
                enc.setComputePipelineState(copy)
                for (i, o) in outputs.enumerated() {
                    if strokeBase[i] == nil { strokeBase[i] = makeLike(o.texture, "stroke base") }
                    guard let b = strokeBase[i] else { continue }
                    var c = SIMD4<UInt32>(UInt32(size), UInt32(tilesAcross), UInt32(size), UInt32(tilesAcross))
                    enc.setTexture(o.texture, index: 0)
                    enc.setTexture(b, index: 1)
                    enc.setBytes(&c, length: 16, index: 0)
                    enc.setBuffer(list, offset: 0, index: 1)
                    enc.setBuffer(list, offset: 0, index: 2)
                    enc.dispatchThreadgroups(MTLSize(width: fresh.count, height: 1, depth: 1), threadsPerThreadgroup: group)
                }
                enc.memoryBarrier(scope: .textures)
                s.touched.formUnion(fresh)
            }
            guard let list = tileBuffer(tiles) else { passes.endCompute(); return }
            var a = args
            var v = view
            v.dabs = UInt32(fill != nil ? 1 : dabs.count)
            v.fill = fill != nil ? 1 : 0
            v.stencil = s.stencil && stencil != nil ? 1 : 0
            let dabList = fill != nil ? [PaintDab(centre: .zero, radius: 1, hardness: 1, opacity: 1, flow: 1)] : dabs
            let selection = fill ?? [0]
            enc.setComputePipelineState(dab)
            enc.setTextures([map, strokeTexture, surfacePos, stamps, stencil ?? strokeColour, strokeColour], range: 0..<6)
            enc.setBytes(&a, length: MemoryLayout<PaintObjectArgs>.stride, index: 0)
            enc.setBytes(&v, length: MemoryLayout<PaintDabArgs>.stride, index: 1)
            dabList.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 2) }
            enc.setBuffer(indices, offset: 0, index: 3)
            enc.setBuffer(positions, offset: 0, index: 4)
            enc.setBuffer(normals, offset: 0, index: 5)
            enc.setBuffer(list, offset: 0, index: 6)
            let selected = selection.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared) }
            enc.setBuffer(selected, offset: 0, index: 7)
            enc.useResources([indices, positions, normals], usage: .read)
            enc.dispatchThreadgroups(MTLSize(width: tiles.count, height: 1, depth: 1), threadsPerThreadgroup: group)
            enc.memoryBarrier(scope: .textures)
            // The stroke into each target, over its base.
            enc.setComputePipelineState(apply)
            for (i, o) in outputs.enumerated() {
                guard let b = strokeBase[i] else { continue }
                var p = PaintApplyArgs()
                p.size = UInt32(size)
                p.erase = s.erase ? 1 : 0
                switch o.channel {
                case .color?: p.value = SIMD4(s.values.color, 1); p.colour = 1; p.stencil = v.stencil
                case .emissive?: p.value = SIMD4(s.values.emissive, 1); p.colour = 1
                case .roughness?: p.value.x = s.values.roughness
                case .metallic?: p.value.x = s.values.metallic
                case .height?: p.value.x = s.values.height
                case .opacity?: p.value.x = s.values.opacity
                case nil:   // a mask: white, or black for the eraser
                    p.value.x = s.erase ? 0 : 1
                    p.erase = 0
                }
                enc.setTextures([strokeTexture, b, o.texture, strokeColour], range: 0..<4)
                enc.setBytes(&p, length: MemoryLayout<PaintApplyArgs>.stride, index: 0)
                enc.setBuffer(list, offset: 0, index: 1)
                enc.dispatchThreadgroups(MTLSize(width: tiles.count, height: 1, depth: 1), threadsPerThreadgroup: group)
            }
            passes.endCompute()
            dirty.formUnion(tiles)
        }
        stroke = s
        if ending || fill != nil { finishStroke(passes) }
    }

    /// A texture like `t` (format and size), private.
    private func makeLike(_ t: MTLTexture, _ label: String) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: t.pixelFormat, width: t.width, height: t.height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        let made = device.makeTexture(descriptor: d)
        made?.label = label
        return made
    }

    /// The stroke done: its touched tiles, before (its base) and after (its targets), packed into its undo record.
    private func finishStroke(_ passes: FrameEncoder) {
        guard let s = stroke else { return }
        stroke = nil
        ending = false
        let tiles = Array(s.touched).sorted()
        guard !tiles.isEmpty, let copy = try? MatCompiler.shared.state("paintTileCopy", device: device) else { return }
        let record = UndoRecord(layer: s.layer, target: s.target, tiles: tiles)
        let outputs = targets(s)
        let across = 64, rows = (tiles.count + across - 1) / across
        guard let src = tileBuffer(tiles), let dst = tileBuffer(Array(0..<tiles.count)),
              let enc = passes.compute("paint undo", serial: true) else { return }
        enc.setComputePipelineState(copy)
        for (i, o) in outputs.enumerated() {
            guard let b = strokeBase[i] else { continue }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: o.texture.pixelFormat, width: across * PainterSession.tile,
                                                             height: rows * PainterSession.tile, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let before = device.makeTexture(descriptor: d), let after = device.makeTexture(descriptor: d) else { continue }
            var c = SIMD4<UInt32>(UInt32(size), UInt32(tilesAcross), UInt32(across * PainterSession.tile), UInt32(across))
            for (from, to) in [(b, before), (o.texture, after)] {
                enc.setTexture(from, index: 0)
                enc.setTexture(to, index: 1)
                enc.setBytes(&c, length: 16, index: 0)
                enc.setBuffer(src, offset: 0, index: 1)
                enc.setBuffer(dst, offset: 0, index: 2)
                enc.dispatchThreadgroups(MTLSize(width: tiles.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            }
            record.before.append(before)
            record.after.append(after)
            record.bytes += 2 * before.allocatedSize
        }
        passes.endCompute()
        undoRecords.append(record)
        var total = undoRecords.reduce(0) { $0 + $1.bytes }
        while total > PainterSession.undoBudget, undoRecords.count > 1 {
            total -= undoRecords.removeFirst().bytes
        }
        onStrokeRecorded?(record)
    }

    /// Undo (or redo) `record` with the next frame: its tiles back as they were before (after) it.
    func undo(_ record: UndoRecord, undo: Bool) { pendingUndo.append((record, undo)) }

    private func applyUndo(_ passes: FrameEncoder) {
        guard let copy = try? MatCompiler.shared.state("paintTileCopy", device: device), let enc = passes.compute("paint undo", serial: true) else { return }
        enc.setComputePipelineState(copy)
        for (record, isUndo) in pendingUndo {
            guard undoRecords.contains(where: { $0 === record }),
                  let src = tileBuffer(Array(0..<record.tiles.count)), let dst = tileBuffer(record.tiles) else { continue }
            let s = Stroke(layer: record.layer, target: record.target, values: PaintValues(), erase: false, stencil: false)
            for (i, o) in targets(s).enumerated() where i < record.before.count {
                let from = isUndo ? record.before[i] : record.after[i]
                var c = SIMD4<UInt32>(UInt32(from.width), UInt32(from.width / PainterSession.tile), UInt32(size), UInt32(tilesAcross))
                enc.setTexture(from, index: 0)
                enc.setTexture(o.texture, index: 1)
                enc.setBytes(&c, length: 16, index: 0)
                enc.setBuffer(src, offset: 0, index: 1)
                enc.setBuffer(dst, offset: 0, index: 2)
                enc.dispatchThreadgroups(MTLSize(width: record.tiles.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            }
            dirty.formUnion(record.tiles)
        }
        passes.endCompute()
        pendingUndo = []
    }

    // MARK: - Pixels in and out

    /// Saved pixels (half floats, as `format` holds them) for a layer's channel, or its painted mask (nil), written by
    /// the next frame.
    func upload(layer: PaintLayer, channel: PaintChannel?, bytes: [UInt8], bytesPerRow: Int, format: MTLPixelFormat) {
        let t = layers[layer.id] ?? LayerTextures()
        layers[layer.id] = t
        let target: MTLTexture?
        if let c = channel {
            if t.channels[c] == nil { t.channels[c] = makePaint(format, "\(layer.name) \(c)") }
            target = t.channels[c]
        } else {
            if t.mask == nil { t.mask = makePaint(.rg16Float, "\(layer.name) mask") }
            target = t.mask
        }
        guard let target else { return }
        cleared.removeAll { $0 === target }
        uploads.append((target, bytes, bytesPerRow))
    }

    private func upload(_ passes: FrameEncoder) {
        // Shared staging textures, copied into the private ones by a kernel (the frame has no blit pass).
        guard let copy = try? MatCompiler.shared.state("paintCopy", device: device), let enc = passes.compute("paint upload", serial: true) else { return }
        enc.setComputePipelineState(copy)
        for (t, bytes, bytesPerRow) in uploads {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: t.pixelFormat, width: t.width, height: t.height, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .shared
            guard let staging = device.makeTexture(descriptor: d) else { continue }
            bytes.withUnsafeBytes { staging.replace(region: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: bytesPerRow) }
            enc.setTexture(staging, index: 0)
            enc.setTexture(t, index: 1)
            enc.dispatchThreads(MTLSize(width: t.width, height: t.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        passes.endCompute()
        uploads = []
        invalidate()
    }

    /// The layers whose source is the object as it was: its materials' textures and values, at its own UVs.
    private func bakeOriginals(_ passes: FrameEncoder, args: PaintObjectArgs, scene: Scene, sceneTextures: [MTLTexture], indices: MTLBuffer, uvs: MTLBuffer) {
        guard let state = try? MatCompiler.shared.state("paintBakeOriginal", device: device), let map = texelMap else { return }
        var used: [MTLTexture] = []
        func index(_ i: UInt32) -> UInt32 {
            guard i != .max, Int(i) < sceneTextures.count else { return .max }
            let t = sceneTextures[Int(i)]
            if let k = used.firstIndex(where: { $0 === t }) { return UInt32(k) }
            used.append(t)
            return UInt32(used.count - 1)
        }
        let originals = object.originals.map { m in
            PaintOriginalGPU(albedo: m.albedo, emission: m.emission, textures: SIMD4(index(m.textures.x), index(m.textures.y), index(m.textures.z), index(m.textures.w)))
        }
        guard let table = table(used.isEmpty ? [base] : used),
              let records = originals.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared) })
        else { return }
        var a = args
        // The level whose texels are about the set's (a texture of 2K over 0...1 at the set's size: 0).
        let widest = used.map(\.width).max() ?? size
        a.level = max(log2(Float(widest) / Float(size)), 0)
        for id in self.originals {
            guard let t = layers[id], let c = t.channels[.color], let r = t.channels[.roughness], let m = t.channels[.metallic] else { continue }
            let e = t.channels[.emissive] ?? makeLike(c, "scratch emissive")
            guard let e, let enc = passes.compute("paint original", serial: true) else { continue }
            enc.setComputePipelineState(state)
            enc.setTextures([map, c, r, m, e], range: 0..<5)
            enc.setBytes(&a, length: MemoryLayout<PaintObjectArgs>.stride, index: 0)
            enc.setBuffer(records, offset: 0, index: 1)
            enc.setBuffer(table, offset: 0, index: 2)
            enc.setBuffer(indices, offset: 0, index: 3)
            enc.setBuffer(uvs, offset: 0, index: 4)
            enc.setBuffer(materialOf, offset: 0, index: 5)
            enc.useResources(used, usage: .read)
            enc.useResources([indices, uvs], usage: .read)
            enc.dispatchThreads(MTLSize(width: size, height: size, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            passes.endCompute()
        }
        self.originals = []
        invalidate()
    }
}
