import Metal
import simd

/// What the raster visibility buffer (`PrimaryVisibility.raster`, Shaders/Raster.metal) knows of a scene, made the
/// first time a frame of it is rasterized:
/// * a record per mesh index of the instances' records (the ordinary meshes, the virtual ones, the assemblies): its
///   bounds, how its triangles are read, and where its chunks' bounds start;
/// * each chunk's mesh, for the chunks' bounds, which the GPU works out once (`rasterBoundsKernel`, `boundsReady`);
/// * with Metal's blocks of instances, each instance's id (a hit names an instance by its block and its place there);
/// * each instance's visibility, as the last frame's second pass found it.
///
/// What isn't drawn is traced where its bounding box is in front (the raster draws the box): an assembly's parts, leaf
/// cards (alpha tested), ground cover that sways in the wind, virtual geometry without a BLAS over its cut (the cluster
/// tree, `METALRENDERER_VG_MODE=clusters`) and instances finer than the pixels; every primary ray traces when the draw
/// lists are full (RasterTraced). Virtual geometry is drawn from its BLAS's triangles, or as clusters (RasterClusters).
final class RasterScene {
    /// How a mesh's triangles are read (MSL RASTER_*), with `deforms` added for a crowd's pose slots.
    enum Kind: UInt32 { case skip = 0, arrays, block, virtual, clusters = 5 }   // (4: a box, drawn for what is skipped)
    static let deforms: UInt32 = 16
    static let chunk = 128   // triangles a chunk (RASTER_CHUNK)

    let meshes: MTLBuffer          // GPURasterMesh per mesh index
    let meshCount: Int
    let firstAssembly: Int         // the assemblies' first record (after the meshes and the virtual ones)
    let chunkMeshes: MTLBuffer     // per chunk with bounds: its mesh index
    let chunkCount: Int
    let chunkBounds: MTLBuffer     // per chunk: lo, hi (float4 each), from rasterBoundsKernel
    let ids: MTLBuffer?            // per instance: its id (Metal's tracer with blocks), else nil (the id is the place)
    let visible: MTLBuffer         // per instance: 1 = drawn last frame (MSL RASTER_VISIBLE; RASTER_IN_VIEW between the passes)
    /// The scene's own instances that move or deform, or whose virtual geometry's cut may change (places): what
    /// invalidates the virtual shadow maps' pages it covers (vsmInvalidateKernel). The blocks' never move.
    let moving: MTLBuffer
    let movingCount: Int
    let instanceCount: Int
    /// rasterBoundsKernel has filled `chunkBounds` (the renderer sets it once it has encoded that).
    var boundsReady = false
    /// What it was made for: the mesh table of the scene's buffers (a new set of buffers has a new one).
    private(set) weak var source: MTLBuffer?
    /// Virtual geometry is drawn as clusters (RasterClusters), not from the BLAS.
    let virtualClusters: Bool
    /// The raster clusters' per-frame state where there are none (rasterResetKernel clears it all the same).
    let noClusterState: MTLBuffer

    /// A mesh's record: `kind`, its bounds (a pose slot's hold every pose it takes), its first chunk.
    static func record(lo: SIMD3<Float>, hi: SIMD3<Float>, kind: Kind, deforms: Bool, firstChunk: Int) -> GPURasterMesh {
        let bits = kind.rawValue | (deforms ? RasterScene.deforms : 0)
        return GPURasterMesh(lo: SIMD4(lo, Float(bitPattern: UInt32(firstChunk))), hi: SIMD4(hi, Float(bitPattern: bits)))
    }

    /// How `mesh` is drawn: from its own buffer or the scene's arrays, or not at all (traced): leaf cards are cut out by
    /// an alpha mask the raster doesn't apply, and the custom tracer bends swaying ground cover where it meets it.
    static func kind(of mesh: GPUMesh, borrowed: Bool, customTracer: Bool) -> Kind {
        if mesh.cutout != 0 || (customTracer && mesh.sways != 0) || mesh.indexCount == 0 { return .skip }
        return borrowed ? .block : .arrays
    }

    /// Chunks of `triangles`.
    static func chunks(_ triangles: Int) -> Int { (triangles + chunk - 1) / chunk }

    init(device: MTLDevice, scene: Scene, buffers: SceneBuffers, customTracer: Bool, virtualBLAS: Bool, clusters: Bool = false) throws {
        func shared<T>(_ array: [T], _ label: String) throws -> MTLBuffer {
            let made = array.withUnsafeBytes { raw in
                raw.count > 0 ? device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
                              : device.makeBuffer(length: 16, options: .storageModeShared)
            }
            guard let made else { throw RendererError.resourceCreation("buffer \(label)") }
            made.label = label
            return made
        }
        source = buffers.meshes
        virtualClusters = virtualBLAS && clusters
        noClusterState = try shared([UInt32](repeating: 0, count: 4), "raster no clusters")
        // The ordinary meshes, then the virtual ones (meshIndex = meshes.count + v).
        var records: [GPURasterMesh] = [], chunkMeshes: [UInt32] = []
        for (m, mesh) in scene.meshes.enumerated() {
            let borrowed = mesh.block != 0 || (m < buffers.blocks.count && buffers.blocks[m] != nil)
            let kind = RasterScene.kind(of: mesh, borrowed: borrowed, customTracer: customTracer)
            let deforms = mesh.prevOffset != 0 || mesh.vertexOffset != 0
            let b = scene.localBounds(mesh: m)
            let first = chunkMeshes.count
            if kind != .skip && !deforms {
                chunkMeshes += [UInt32](repeating: UInt32(m), count: RasterScene.chunks(Int(mesh.indexCount) / 3))
            }
            records.append(RasterScene.record(lo: b.lo, hi: b.hi, kind: kind, deforms: deforms, firstChunk: first))
        }
        for v in scene.virtualMeshes {
            records.append(RasterScene.record(lo: v.bounds.lo, hi: v.bounds.hi, kind: !virtualBLAS ? .skip : clusters ? .clusters : .virtual,
                                              deforms: false, firstChunk: 0))
        }
        firstAssembly = records.count
        for a in scene.assemblies {   // (traced: their boxes are drawn, to say where)
            records.append(RasterScene.record(lo: a.bounds.lo, hi: a.bounds.hi, kind: .skip, deforms: false, firstChunk: 0))
        }
        for b in scene.sdfBounds {    // SDF shapes, alike
            records.append(RasterScene.record(lo: b.lo, hi: b.hi, kind: .skip, deforms: false, firstChunk: 0))
        }
        meshCount = records.count
        chunkCount = chunkMeshes.count
        meshes = try shared(records, "raster meshes")
        self.chunkMeshes = try shared(chunkMeshes, "raster chunk meshes")
        guard let bounds = device.makeBuffer(length: max(chunkCount, 1) * 32, options: .storageModePrivate) else {
            throw RendererError.resourceCreation("buffer raster chunk bounds")
        }
        bounds.label = "raster chunk bounds"
        chunkBounds = bounds

        // Ids: the scene's own instances are block 0, then each block's in their order (SceneBuffers).
        instanceCount = buffers.instanceCount
        if buffers.instanceTable != nil {
            var list = (0..<UInt32(scene.instances.count)).map { $0 }
            for block in buffers.instanceBlocks { list += (0..<block.count).map { block.id($0) } }
            ids = try shared(list, "raster ids")
        } else {
            ids = nil
        }
        let movers = scene.instances.indices.filter {
            let inst = scene.instances[$0]
            return inst.moves || inst.deforms || inst.virtualMesh >= 0
        }.map { UInt32($0) }
        movingCount = movers.count
        moving = try shared(movers, "raster moving instances")
        guard let visible = device.makeBuffer(length: max(instanceCount, 1) * 4, options: .storageModeShared) else {
            throw RendererError.resourceCreation("buffer raster visibility")
        }
        memset(visible.contents(), 0, visible.length)   // nothing drawn yet: the first frame's pass 2 draws it all
        visible.label = "raster visibility"
        self.visible = visible
    }

    /// Bytes on the GPU (the Debug window's memory line).
    var megabytes: Double {
        Double(meshes.length + chunkMeshes.length + chunkBounds.length + (ids?.length ?? 0) + visible.length + moving.length) / 1_048_576
    }
}

/// The raster visibility buffer's per-size state: its targets, the depth pyramid, the passes' draw lists and their
/// counters.
final class RasterTargets {
    let width: Int, height: Int
    let visibility: MTLTexture     // rg32Uint: instance id, triangle (RASTER_NO_ID = nothing)
    let depth: MTLTexture          // depth32Float, reversed Z
    let hzb: MTLTexture            // r32Float, mipmapped: level 0 is half the size rounded up to powers of two
    /// The pyramid of a frame's final depth, which the next frame's raster clusters test against (`prevFrame`).
    let hzbPrev: MTLTexture
    var prevFrame: UInt32 = .max   // the frame `hzbPrev` is of
    let maxDraws: Int, maxGroups: Int
    let draws: MTLBuffer           // per pass: maxDraws chunks (uint4)
    let groups: MTLBuffer          // per pass: maxGroups groups (uint4)
    let records: MTLBuffer         // per pass: maxGroups RasterInstance, at each drawn instance's first group
    let counters: MTLBuffer        // per pass: RasterCounters (32 bytes)
    static let countersStride = 32
    static let recordSize = 64     // RasterInstance

    init(device: MTLDevice, width: Int, height: Int, chunks: Int, instances: Int) throws {
        (self.width, self.height) = (width, height)
        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, mips: Bool, _ usage: MTLTextureUsage, _ label: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: mips)
            d.usage = usage
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        visibility = try texture(Pipelines.visibilityFormat, width, height, mips: false, [.renderTarget, .shaderRead], "visibility buffer")
        depth = try texture(Pipelines.depthFormat, width, height, mips: false, [.renderTarget, .shaderRead], "raster depth")
        func half(_ n: Int) -> Int { max(1, (1 << Int(ceil(log2(Double(max(n, 2)))))) / 2) }
        hzb = try texture(.r32Float, half(width), half(height), mips: true, [.shaderRead, .shaderWrite], "hzb")
        hzbPrev = try texture(.r32Float, half(width), half(height), mips: true, [.shaderRead, .shaderWrite], "hzb previous")
        // Every chunk of the scene, or for the cut's triangles about four a pixel; the groups follow.
        maxDraws = min(max(chunks + width * height * 4 / RasterScene.chunk, 65536), 1 << 22)
        maxGroups = instances + maxDraws / 64 + 1
        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: length, options: .storageModePrivate) else { throw RendererError.resourceCreation("buffer \(label)") }
            b.label = label
            return b
        }
        draws = try buffer(2 * maxDraws * 16, "raster draws")
        groups = try buffer(2 * maxGroups * 16, "raster groups")
        records = try buffer(2 * maxGroups * RasterTargets.recordSize, "raster instances")
        counters = try buffer(2 * RasterTargets.countersStride + 16, "raster counters")   // + RasterTraced
    }
}
