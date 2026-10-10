import Foundation
import Metal
import QuartzCore
import simd

struct PaintBakeArgs {
    var size: UInt32 = 0
    var rays: UInt32 = 32
    var seed: UInt32 = 1
    var cellsX: UInt32 = 0
    var maxDistance: Float = 0.5
    var radius: Float = 0.02
    var curvatureScale: Float = 1
    var cellsY: UInt32 = 0
    var gridOrigin = SIMD4<Float>.zero
    var cellsZ: UInt32 = 0
    var thicknessScale: Float = 0.1
    var rowOffset: UInt32 = 0
    var pad1: UInt32 = 0
}

struct PaintGenerateArgs {
    var kind: UInt32 = 0
    var amount: Float = 0.5
    var contrast: Float = 0.5
    var scale: Float = 4
    var seed: UInt32 = 1
    var invert: UInt32 = 0
    var size: UInt32 = 0
    var hasGraph: UInt32 = 0
    var boundsLo = SIMD4<Float>.zero
    var boundsHi = SIMD4<Float>.zero
}

/// A PaintBake made off the render thread (it takes up to a second at 2K): the render thread adopts it once `done`.
final class PaintBakeJob {
    private let lock = NSLock()
    private var made: PaintBake??
    let started = CACurrentMediaTime()

    init(mesh: PaintMesh, map: MTLTexture, size: Int, device: MTLDevice, queue: MTLCommandQueue, bandRows: Int? = nil) {
        // A queue of its own: the frames' queue runs between its command buffers.
        let own = device.makeCommandQueue() ?? queue
        own.label = "painter bakes"
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let b = PaintBake(mesh: mesh, map: map, size: size, device: device, queue: own, bandRows: bandRows)
            lock.lock()
            made = .some(b)
            lock.unlock()
        }
    }

    /// The bake once made (`.some(nil)`: it failed), nil while it is being made.
    var done: PaintBake?? {
        lock.lock()
        defer { lock.unlock() }
        return made
    }
}

/// A painted object's mesh maps (MaterialShaders/PaintBake.metal), at its texture set's size: ambient occlusion and
/// thickness (rays against the object alone, on a structure of its own: Metal RT), curvature (each welded vertex's,
/// from how its neighbours' normals turn, and the creases near: edges whose faces meet at more than 25 degrees,
/// convex or concave, within a reach of 3.5% of the object's size). The generators' masks read them
/// (`generate`); they are made once a session, off the render thread (PaintBakeJob).
final class PaintBake {
    let occlusion: MTLTexture
    let thickness: MTLTexture
    let curvature: MTLTexture
    /// The point within the bounds and the normal (object space), as pictures.
    let position: MTLTexture
    let normal: MTLTexture
    /// The object's own arrays (bind pose), as the kernels read them.
    let indices: MTLBuffer, positions: MTLBuffer, normals: MTLBuffer
    let bounds: (SIMD3<Float>, SIMD3<Float>)

    static let rays: UInt32 = 32
    /// A crease's reach (and the scale of the vertices' curvature): this share of the object's size.
    static let reach: Float = 0.035

    /// `bandRows`: rows of occlusion and curvature per command buffer (nil: about 128K texels' worth).
    init?(mesh: PaintMesh, map: MTLTexture, size: Int, device: MTLDevice, queue: MTLCommandQueue, bandRows: Int? = nil) {
        func make(_ format: MTLPixelFormat, _ label: String) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            let t = device.makeTexture(descriptor: d)
            t?.label = "paint bake \(label)"
            return t
        }
        guard let o = make(.r8Unorm, "occlusion"), let t = make(.r8Unorm, "thickness"), let c = make(.r8Unorm, "curvature"),
              let pm = make(.rgba8Unorm, "position"), let nm = make(.rgba8Unorm, "normal"),
              let ib = device.makeBuffer(bytes: mesh.indices, length: max(mesh.indices.count * 4, 16), options: .storageModeShared),
              let pb = device.makeBuffer(bytes: mesh.positions, length: max(mesh.positions.count * 16, 16), options: .storageModeShared),
              let nb = device.makeBuffer(bytes: mesh.normals, length: max(mesh.normals.count * 16, 16), options: .storageModeShared)
        else { return nil }
        (occlusion, thickness, curvature, position, normal, indices, positions, normals) = (o, t, c, pm, nm, ib, pb, nb)
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for p in mesh.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        bounds = (lo, hi)
        let extent = max(simd_reduce_max(hi - lo), 1e-3)
        guard let structure = PaintBake.structure(mesh: mesh, indices: ib, positions: pb, device: device, queue: queue) else { return nil }
        let (vertexCurvature, segments, cells, items, grid) = PaintBake.curvatureInputs(mesh, radius: PaintBake.reach * extent)
        guard let vc = device.makeBuffer(bytes: vertexCurvature, length: max(vertexCurvature.count * 4, 16), options: .storageModeShared),
              let sb = segments.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress ?? UnsafeRawPointer(bitPattern: 16)!, length: max($0.count, 16), options: .storageModeShared) }),
              let cb = cells.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress ?? UnsafeRawPointer(bitPattern: 16)!, length: max($0.count, 16), options: .storageModeShared) }),
              let itb = items.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress ?? UnsafeRawPointer(bitPattern: 16)!, length: max($0.count, 16), options: .storageModeShared) }),
              let occ = try? MatCompiler.shared.state("paintBakeOcclusion", device: device),
              let curv = try? MatCompiler.shared.state("paintBakeCurvature", device: device),
              let maps = try? MatCompiler.shared.state("paintBakeMaps", device: device) else { return nil }
        var a = PaintObjectArgs()
        a.size = UInt32(size)
        a.triangles = UInt32(mesh.triangleCount)
        var b = PaintBakeArgs()
        b.size = UInt32(size)
        b.rays = PaintBake.rays
        b.maxDistance = 0.35 * extent
        b.radius = PaintBake.reach * extent
        b.thicknessScale = 0.25 * extent
        b.curvatureScale = PaintBake.reach * extent * 3
        b.gridOrigin = SIMD4(grid.origin, grid.cell)
        (b.cellsX, b.cellsY, b.cellsZ) = (UInt32(grid.dims.x), UInt32(grid.dims.y), UInt32(grid.dims.z))
        let threads = MTLSize(width: size, height: size, depth: 1), group = MTLSize(width: 16, height: 16, depth: 1)
        // Occlusion and curvature in bands of rows, a command buffer each, so that the frames (another queue) get the
        // GPU between them.
        let rows = max(bandRows ?? (1 << 17) / size, 16)
        for start in stride(from: 0, to: size, by: rows) {
            guard let command = queue.makeCommandBuffer(), let enc = command.makeComputeCommandEncoder() else { return nil }
            let band = MTLSize(width: size, height: min(rows, size - start), depth: 1)
            b.rowOffset = UInt32(start)
            enc.setComputePipelineState(occ)
            enc.setTextures([map, o, t], range: 0..<3)
            enc.setBytes(&a, length: MemoryLayout<PaintObjectArgs>.stride, index: 0)
            enc.setBytes(&b, length: MemoryLayout<PaintBakeArgs>.stride, index: 1)
            enc.setBuffers([ib, pb, nb], offsets: [0, 0, 0], range: 2..<5)
            enc.setAccelerationStructure(structure, bufferIndex: 5)
            enc.useResource(structure, usage: .read)
            enc.dispatchThreads(band, threadsPerThreadgroup: group)
            enc.setComputePipelineState(curv)
            enc.setTextures([map, c], range: 0..<2)
            enc.setBytes(&a, length: MemoryLayout<PaintObjectArgs>.stride, index: 0)
            enc.setBytes(&b, length: MemoryLayout<PaintBakeArgs>.stride, index: 1)
            enc.setBuffers([ib, pb, nb, vc, sb, cb, itb], offsets: [0, 0, 0, 0, 0, 0, 0], range: 2..<9)
            enc.dispatchThreads(band, threadsPerThreadgroup: group)
            enc.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            if let e = command.error { print("Painter: the bakes failed: \(e)"); return nil }
        }
        guard let command = queue.makeCommandBuffer(), let enc = command.makeComputeCommandEncoder() else { return nil }
        var g = PaintGenerateArgs()
        g.size = UInt32(size)
        g.boundsLo = SIMD4(lo, 0)
        g.boundsHi = SIMD4(hi, 0)
        enc.setComputePipelineState(maps)
        enc.setTextures([map, pm, nm], range: 0..<3)
        enc.setBytes(&a, length: MemoryLayout<PaintObjectArgs>.stride, index: 0)
        enc.setBytes(&g, length: MemoryLayout<PaintGenerateArgs>.stride, index: 1)
        enc.setBuffers([ib, pb, nb], offsets: [0, 0, 0], range: 2..<5)
        enc.dispatchThreads(threads, threadsPerThreadgroup: group)
        enc.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let e = command.error { print("Painter: the bakes failed: \(e)"); return nil }
    }

    /// The object's own structure (its triangles in its own space).
    private static func structure(mesh: PaintMesh, indices: MTLBuffer, positions: MTLBuffer, device: MTLDevice, queue: MTLCommandQueue)
        -> MTLAccelerationStructure? {
        let g = MTLAccelerationStructureTriangleGeometryDescriptor()
        g.vertexBuffer = positions
        g.vertexStride = 16
        g.vertexFormat = .float3
        g.indexBuffer = indices
        g.indexType = .uint32
        g.triangleCount = mesh.triangleCount
        g.opaque = true
        let d = MTLPrimitiveAccelerationStructureDescriptor()
        d.geometryDescriptors = [g]
        let sizes = device.accelerationStructureSizes(descriptor: d)
        guard let s = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, 16), options: .storageModePrivate),
              let cb = queue.makeCommandBuffer(), let enc = cb.makeAccelerationStructureCommandEncoder() else { return nil }
        enc.build(accelerationStructure: s, descriptor: d, scratchBuffer: scratch, scratchBufferOffset: 0)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return s
    }

    /// Each vertex's curvature (mean of its welded neighbours' normal turn over their distance, >0 convex), the
    /// creases (segment ends: xyz, w = +1 convex / -1 concave; then the other end, w = sharpness), and a grid of
    /// cells of the reach over them (per cell its items' start and count; the items).
    static func curvatureInputs(_ mesh: PaintMesh, radius: Float)
        -> ([Float], [SIMD4<Float>], [SIMD2<UInt32>], [UInt32], (origin: SIMD3<Float>, cell: Float, dims: SIMD3<Int>)) {
        let (weld, count) = mesh.welded()
        // Welded normals: angle-weighted face normals (a hard edge's two sides are one vertex here).
        var nsum = [SIMD3<Float>](repeating: .zero, count: count), pos = [SIMD3<Float>](repeating: .zero, count: count)
        var faceNormal = [SIMD3<Float>](repeating: .zero, count: mesh.triangleCount)
        for t in 0..<mesh.triangleCount {
            let (i0, i1, i2) = mesh.corners(t)
            let p = [mesh.positions[i0], mesh.positions[i1], mesh.positions[i2]], w = [weld[i0], weld[i1], weld[i2]]
            let c = simd_cross(p[1] - p[0], p[2] - p[0])
            guard simd_length(c) > 0 else { continue }
            let n = simd_normalize(c)
            faceNormal[t] = n
            for k in 0..<3 {
                let e1 = p[(k + 1) % 3] - p[k], e2 = p[(k + 2) % 3] - p[k]
                let cosine = simd_dot(e1, e2) / max(simd_length(e1) * simd_length(e2), 1e-30)
                nsum[Int(w[k])] += n * acos(min(max(cosine, -1), 1))
                pos[Int(w[k])] = p[k]
            }
        }
        let wn = nsum.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3<Float>(0, 1, 0) }
        // Edges: per welded edge, its triangles.
        var edges: [UInt64: [Int32]] = [:]
        for t in 0..<mesh.triangleCount {
            let (i0, i1, i2) = mesh.corners(t)
            let w = [weld[i0], weld[i1], weld[i2]]
            for k in 0..<3 {
                let a = UInt64(UInt32(w[k])), b = UInt64(UInt32(w[(k + 1) % 3]))
                guard a != b else { continue }
                edges[min(a, b) << 32 | max(a, b), default: []].append(Int32(t))
            }
        }
        var ksum = [Float](repeating: 0, count: count), kn = [Float](repeating: 0, count: count)
        var segments: [SIMD4<Float>] = []
        let creaseCos = cos(Float(25) * .pi / 180)
        for (key, tris) in edges {
            let a = Int(key >> 32), b = Int(key & 0xFFFF_FFFF)
            let d = pos[b] - pos[a], l2 = simd_length_squared(d)
            if l2 > 0 {
                let k = simd_dot(wn[b] - wn[a], d) / l2
                ksum[a] += k; kn[a] += 1
                ksum[b] += k; kn[b] += 1
            }
            guard tris.count == 2 else { continue }
            let n0 = faceNormal[Int(tris[0])], n1 = faceNormal[Int(tris[1])]
            let c = simd_dot(n0, n1)
            guard c < creaseCos, n0 != .zero, n1 != .zero else { continue }
            // Convex if the other face's far corner is below this face's plane.
            let (j0, j1, j2) = mesh.corners(Int(tris[1]))
            let centre = (mesh.positions[j0] + mesh.positions[j1] + mesh.positions[j2]) / 3
            let convex = simd_dot(centre - pos[a], n0) < 0
            let sharp = min(max((creaseCos - c) / (creaseCos + 0.5), 0.2), 1)
            segments.append(SIMD4(pos[a], convex ? 1 : -1))
            segments.append(SIMD4(pos[b], sharp))
        }
        let vertexK = (0..<count).map { kn[$0] > 0 ? ksum[$0] / kn[$0] : 0 }
        // Per mesh vertex (the kernels index by the mesh's own vertices).
        let perVertex = (0..<mesh.positions.count).map { vertexK[Int(weld[$0])] }
        // The grid: cells of the reach, over the mesh's bounds.
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for p in mesh.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let cell = max(radius, simd_reduce_max(hi - lo) / 128)
        let dims = simd_max(SIMD3<Int>(((hi - lo) / cell).rounded(.up)) &+ 1, SIMD3(repeating: 1))
        var lists = [[UInt32]](repeating: [], count: dims.x * dims.y * dims.z)
        for s in 0..<segments.count / 2 {
            let a = SIMD3(segments[2 * s].x, segments[2 * s].y, segments[2 * s].z), b = SIMD3(segments[2 * s + 1].x, segments[2 * s + 1].y, segments[2 * s + 1].z)
            let l = simd_max(SIMD3<Int>(((simd_min(a, b) - lo) / cell).rounded(.down)), .zero)
            let h = simd_min(SIMD3<Int>(((simd_max(a, b) - lo) / cell).rounded(.down)), dims &- 1)
            guard l.x <= h.x, l.y <= h.y, l.z <= h.z else { continue }
            for z in l.z...h.z { for y in l.y...h.y { for x in l.x...h.x { lists[(z * dims.y + y) * dims.x + x].append(UInt32(s)) } } }
        }
        var cells: [SIMD2<UInt32>] = [], items: [UInt32] = []
        for list in lists {
            cells.append(SIMD2(UInt32(items.count), UInt32(list.count)))
            items += list
        }
        if segments.isEmpty { return (perVertex, [SIMD4<Float>(repeating: 0)], [SIMD2<UInt32>(0, 0)], [0], (lo, 0, SIMD3(1, 1, 1))) }
        return (perVertex, segments, cells, items, (lo, cell, dims))
    }

    /// A generator's mask into `out` (R8, the set's size), now (waits for the GPU). `graph`: a graph mask's bake.
    func generate(_ g: PaintGenerator, into out: MTLTexture, map: MTLTexture, graph: MTLTexture?, queue: MTLCommandQueue, device: MTLDevice) {
        guard let state = try? MatCompiler.shared.state("paintGenerate", device: device),
              let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
        var a = PaintObjectArgs()
        a.size = UInt32(out.width)
        var args = PaintGenerateArgs()
        args.kind = UInt32(PaintGenerator.Kind.allCases.firstIndex(of: g.kind) ?? 0)
        args.amount = g.amount
        args.contrast = g.contrast
        args.scale = g.scale
        args.seed = UInt32(truncatingIfNeeded: g.seed)
        args.invert = g.invert ? 1 : 0
        args.size = UInt32(out.width)
        args.hasGraph = graph != nil ? 1 : 0
        args.boundsLo = SIMD4(bounds.0, 0)
        args.boundsHi = SIMD4(bounds.1, 0)
        enc.setComputePipelineState(state)
        enc.setTextures([map, curvature, occlusion, thickness, out, graph ?? curvature], range: 0..<6)
        enc.setBytes(&a, length: MemoryLayout<PaintObjectArgs>.stride, index: 0)
        enc.setBytes(&args, length: MemoryLayout<PaintGenerateArgs>.stride, index: 1)
        enc.setBuffers([indices, positions, normals], offsets: [0, 0, 0], range: 2..<5)
        enc.dispatchThreads(MTLSize(width: out.width, height: out.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }
}
