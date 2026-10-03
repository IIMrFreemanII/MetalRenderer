import Foundation
import Metal
import QuartzCore
import simd

/// Per-instance data the custom traversal reads (MSL `RTInstance`): world -> object rows and the mesh's BLAS root.
struct RTInstance {
    var row0 = SIMD4<Float>()     // rows of inverse(transform): object point = (dot(row0, p1), dot(row1, p1), dot(row2, p1))
    var row1 = SIMD4<Float>()
    var row2 = SIMD4<Float>()
    var blasRoot: UInt32 = 0
    var mask: UInt32 = 0
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

/// Kernels that build the dynamic TLAS (Shaders.metal, "per-frame build of the dynamic top-level tree").
struct RTPipelines {
    let prep, keys, sortLocal, sortGlobal, hierarchy, fit: MTLComputePipelineState
    let vg: VGPipelines
}

/// Where the LBVH kernels read their leaf count and sort size: set by the CPU, or written by an earlier kernel.
enum LBVHCounts {
    case bytes(SIMD2<UInt32>)
    case buffer(MTLBuffer)
}

/// What the virtual-geometry cut needs to know about the view each frame.
struct VGView {
    var camPos: SIMD3<Float>
    var pixelScale: Float       // traced height / (2 tan(fovY / 2))
    var tau: Float              // allowed error in traced pixels
    var frame: UInt32
}

/// The custom ray tracer's scene: per-mesh BLASes and the static TLAS (built once on the CPU), and per frame slot the
/// dynamic TLAS over moving instances plus the `RTScene` argument buffer every ray-tracing kernel gets at buffer 1.
/// See BVH.swift for the node format.
///
/// The dynamic TLAS is rebuilt from scratch every frame on the GPU as an LBVH (Karras 2012): moving instances are
/// sorted along a Morton curve and the tree follows from the sorted keys, all in parallel. `METALRENDERER_RT_BUILD=cpu`
/// builds it on the CPU with binned SAH instead (a better tree, for comparing trace speed).
/// Totals of the custom tracer's traversal counters (Shaders.metal RT_COUNT): 0 rays, 1 top nodes, 2 bottom nodes,
/// 3 instance entries, 4 cluster entries, 5 triangle tests, 6 top nodes inside virtual instances.
struct TraversalStats {
    var counts = [UInt64](repeating: 0, count: 7)

    static func + (a: TraversalStats, b: TraversalStats) -> TraversalStats {
        TraversalStats(counts: zip(a.counts, b.counts).map { $0 + $1 })
    }
    var rays: Double { Double(counts[0]) }
    /// Counter `i` per ray.
    func perRay(_ i: Int) -> Double { Double(counts[i]) / max(rays, 1) }

    var description: String {
        String(format: "rays %.0fk: per ray %.1f top nodes (%.1f inside virtual instances), %.1f bottom nodes, %.2f instance entries, %.2f cluster entries, %.1f triangle tests",
               max(rays, 1) / 1000, perRay(1), perRay(6), perRay(2), perRay(3), perRay(4), perRay(5))
    }
}

final class CustomRayTracer {
    private let device: MTLDevice
    var pipelines: RTPipelines!   // set by the renderer once the custom-RT shaders are compiled
    static let cpuBuild = ProcessInfo.processInfo.environment["METALRENDERER_RT_BUILD"] == "cpu"
    let blasNodes: MTLBuffer
    let triangles: MTLBuffer
    private var tlasNodes: [MTLBuffer] = []       // per slot: static TLAS nodes, then the dynamic TLAS
    private var instances: [MTLBuffer] = []       // per slot: RTInstance per scene instance
    private var sceneArgs: [MTLBuffer] = []       // per slot: RTScene
    private let staticNodes: [BVHNode]
    private let staticRoot: UInt32
    private let dynamicIds: [Int]                 // scene instances that can move (animated objects, light spheres)
    private let blasRoots: [UInt32]
    private let meshBounds: [AABB]
    private let cpu: (blas: BVHBuilder.BLASResult, tris: [SIMD4<Float>])   // kept for the self-test
    // GPU build inputs and scratch (shared by the frame slots: Metal orders the passes that use them).
    private let meshInfo: MTLBuffer               // per mesh: (box min, BLAS root bits), (box max, 0)
    private let dynSlot: MTLBuffer                // per instance: index among the moving ones, or ~0
    private let leafBoxes: MTLBuffer              // per moving instance: (min, instance id bits), (max, mask bits)
    private let keys: MTLBuffer, values: MTLBuffer
    private let nodeParent: MTLBuffer, leafParent: MTLBuffer, counters: MTLBuffer
    private let instanceCount: Int
    private let paddedCount: Int                  // moving instances rounded up to a power of two (sort size)
    /// Virtual meshes, if the scene has any. Default: each virtual instance traced through an SAH BLAS over its
    /// current cut (VirtualBLAS). METALRENDERER_VG_MODE=clusters: a third top-level tree over this frame's cut of clusters,
    /// selected and streamed on the GPU (VirtualGeometry).
    let virtualGeometry: VirtualGeometry?
    let virtualBLAS: VirtualBLAS?
    static let clusterMode = ProcessInfo.processInfo.environment["METALRENDERER_VG_MODE"] == "clusters"
    private let dummy: MTLBuffer                  // stands in for the virtual-geometry buffers without any
    /// Traversal counters (compiled in with RT_STATS: METALRENDERER_RT_STATS=1, or the Debug window's toggle, which
    /// recompiles the shaders): rays, top-level nodes, bottom-level nodes, instance entries, cluster entries, triangle tests.
    let stats: MTLBuffer
    static var statsEnabled = ProcessInfo.processInfo.environment["METALRENDERER_RT_STATS"] == "1"

    /// Root ref of the dynamic TLAS: its first node when it has 2+ instances, the instance itself when it has one.
    private var dynamicRoot: UInt32 {
        dynamicIds.isEmpty ? BVHNode.none : dynamicIds.count == 1 ? BVHNode.leafBit | UInt32(dynamicIds[0]) : UInt32(staticNodes.count)
    }

    /// The first node of this frame's cluster tree (after the static and dynamic trees).
    private var virtualNodeBase: Int { staticNodes.count + max(dynamicIds.count - 1, 1) }

    /// `instances`: a copy of `scene.instances` taken on the main thread when this runs in the background for a scene
    /// that is still being drawn (`Scene.update` rewrites the transforms there every frame).
    init(device: MTLDevice, scene: Scene, instances sceneInstances: [Scene.Instance]? = nil, slots: Int, poolMB: Int = 768) throws {
        self.device = device
        let sceneInstances = sceneInstances ?? scene.instances
        let start = CACurrentMediaTime()
        let blas = BVHBuilder.buildBLAS(positions: scene.positions, indices: scene.indices, meshes: scene.meshes)
        blasRoots = blas.roots
        meshBounds = blas.bounds
        cpu = (blas, blas.triangles)

        // Static instances in two groups: the geometry, and the proxies of lights that stay in place (thousands of bulbs
        // in the market).
        struct Group { var boxes: [AABB] = [], ids: [Int] = [], masks: [UInt32] = [] }
        var geometry = Group(), proxies = Group(), dyn: [Int] = []
        var virtualInstances: [(instance: Int, mesh: Int)] = []
        func bounds(_ inst: Scene.Instance) -> AABB { inst.mesh >= 0 ? blas.bounds[inst.mesh] : scene.virtualMeshes[inst.virtualMesh].bounds }
        for (i, inst) in sceneInstances.enumerated() {
            if inst.virtualMesh >= 0 { virtualInstances.append((i, inst.virtualMesh)) }
            if inst.virtualMesh >= 0 && CustomRayTracer.clusterMode {
                continue   // in the cluster tree, not the instance trees
            } else if inst.isStatic {
                let box = bounds(inst).transformed(inst.transform)
                if inst.mask == Scene.maskGeometry {
                    geometry.boxes.append(box); geometry.ids.append(i); geometry.masks.append(inst.mask)
                } else {
                    proxies.boxes.append(box); proxies.ids.append(i); proxies.masks.append(inst.mask)
                }
            } else {
                dyn.append(i)
            }
        }
        // One tree per group, joined by a root node. Shadow and GI rays (MASK_GEOMETRY) skip the proxies' tree at the
        // root by its mask and walk a tree of geometry only: one tree over both costs them ~0.5 ms a frame in the market,
        // since the SAH then splits the geometry around the bulbs.
        var nodes: [BVHNode] = []
        let root: UInt32, staticDepth: Int
        if geometry.ids.isEmpty || proxies.ids.isEmpty {
            let group = geometry.ids.isEmpty ? proxies : geometry
            (root, staticDepth) = BVHBuilder.buildTLAS(boxes: group.boxes, ids: group.ids, masks: group.masks, nodeBase: 0, into: &nodes)
        } else {
            nodes.append(BVHNode())   // the joining root, filled in below
            var depth = 0
            for (k, group) in [geometry, proxies].enumerated() {
                let tree = BVHBuilder.buildTLAS(boxes: group.boxes, ids: group.ids, masks: group.masks, nodeBase: 0, into: &nodes)
                var box = AABB()
                for b in group.boxes { box.grow(b) }
                nodes[0].setChild(k, lo: box.lo, hi: box.hi, ref: tree.root, mask: group.masks.reduce(0, |))
                depth = max(depth, tree.depth)
            }
            root = 0
            staticDepth = depth + 1
        }
        let staticCount = geometry.ids.count + proxies.ids.count
        staticNodes = nodes
        staticRoot = root
        dynamicIds = dyn

        func buffer<T>(_ array: [T], _ label: String) throws -> MTLBuffer {
            let length = max(MemoryLayout<T>.stride * array.count, 16)
            let b = array.isEmpty ? device.makeBuffer(length: length, options: .storageModeShared)
                                  : array.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            guard let b else { throw RendererError.resourceCreation("buffer \(label)") }
            b.label = label
            return b
        }
        blasNodes = try buffer(blas.nodes, "blasNodes")
        triangles = try buffer(blas.triangles, "bvhTriangles")
        virtualGeometry = virtualInstances.isEmpty || !CustomRayTracer.clusterMode ? nil
            : try VirtualGeometry(device: device, meshes: scene.virtualMeshes, instances: virtualInstances, poolMB: poolMB, slots: slots)
        virtualBLAS = virtualInstances.isEmpty || CustomRayTracer.clusterMode ? nil
            : try VirtualBLAS(device: device, meshes: scene.virtualMeshes, instances: virtualInstances, slots: slots)
        dummy = try buffer([UInt32](repeating: BVHNode.none, count: 4), "rtDummy")
        stats = try buffer([UInt32](repeating: 0, count: 8), "rtStats")
        let tlasCapacity = staticNodes.count + max(dynamicIds.count - 1, 1) + (virtualGeometry == nil ? 0 : VirtualGeometry.capacity)
        for slot in 0..<slots {
            let t = try buffer([BVHNode](repeating: BVHNode(), count: tlasCapacity), "tlasNodes\(slot)")
            staticNodes.withUnsafeBytes { if $0.count > 0 { t.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
            tlasNodes.append(t)
            instances.append(try buffer([RTInstance](repeating: RTInstance(), count: max(sceneInstances.count, 1)), "rtInstances\(slot)"))
            sceneArgs.append(try buffer([UInt8](repeating: 0, count: 112), "rtScene\(slot)"))
        }

        instanceCount = sceneInstances.count
        paddedCount = max(2, 1 << Int(ceil(log2(Double(max(dyn.count, 2))))))
        var info: [SIMD4<Float>] = []
        for (m, b) in blas.bounds.enumerated() {
            info += [SIMD4(b.lo, Float(bitPattern: blas.roots[m])), SIMD4(b.hi, 0)]
        }
        for vm in scene.virtualMeshes {   // after the ordinary meshes (GPUInstanceData.meshIndex of virtual instances)
            info += [SIMD4(vm.bounds.lo, 0), SIMD4(vm.bounds.hi, 0)]
        }
        var slotOf = [UInt32](repeating: BVHNode.none, count: max(sceneInstances.count, 1))
        for (k, i) in dyn.enumerated() { slotOf[i] = UInt32(k) }
        meshInfo = try buffer(info, "rtMeshInfo")
        dynSlot = try buffer(slotOf, "rtDynSlot")
        leafBoxes = try buffer([SIMD4<Float>](repeating: .zero, count: 2 * max(dyn.count, 1)), "rtLeafBoxes")
        keys = try buffer([UInt32](repeating: 0, count: paddedCount), "rtKeys")
        values = try buffer([UInt32](repeating: 0, count: paddedCount), "rtValues")
        nodeParent = try buffer([UInt32](repeating: 0, count: max(dyn.count, 1)), "rtNodeParent")
        leafParent = try buffer([UInt32](repeating: 0, count: max(dyn.count, 1)), "rtLeafParent")
        counters = try buffer([UInt32](repeating: 0, count: max(dyn.count, 1)), "rtCounters")
        for slot in 0..<slots { writeArgs(slot: slot) }
        print(String(format: "Custom BVH: %d BLAS nodes, %d triangles, static TLAS %d instances (%d nodes, depth %d), %d dynamic, built in %.1f ms",
                     blas.nodes.count, blas.triangles.count / 3, staticCount, staticNodes.count, staticDepth, dynamicIds.count,
                     (CACurrentMediaTime() - start) * 1000))
        if ProcessInfo.processInfo.environment["METALRENDERER_RT_CHECK"] == "1" { selfTest(scene: scene) }
    }

    /// RTScene (96 bytes, asserted in Shaders.metal): 10 GPU addresses, then the static and dynamic root refs and the
    /// cluster tree's first node.
    private func writeArgs(slot: Int) {
        let p = sceneArgs[slot].contents()
        let vg = virtualGeometry
        p.storeBytes(of: tlasNodes[slot].gpuAddress, toByteOffset: 0, as: UInt64.self)
        p.storeBytes(of: blasNodes.gpuAddress, toByteOffset: 8, as: UInt64.self)
        p.storeBytes(of: triangles.gpuAddress, toByteOffset: 16, as: UInt64.self)
        p.storeBytes(of: instances[slot].gpuAddress, toByteOffset: 24, as: UInt64.self)
        p.storeBytes(of: (vg?.selectedBuffers[slot] ?? dummy).gpuAddress, toByteOffset: 32, as: UInt64.self)
        p.storeBytes(of: (vg?.pool ?? dummy).gpuAddress, toByteOffset: 40, as: UInt64.self)
        p.storeBytes(of: (vg?.rootsBuffers[slot] ?? dummy).gpuAddress, toByteOffset: 48, as: UInt64.self)
        p.storeBytes(of: (vg?.nodeInstanceBuffers[slot] ?? dummy).gpuAddress, toByteOffset: 56, as: UInt64.self)
        p.storeBytes(of: stats.gpuAddress, toByteOffset: 64, as: UInt64.self)
        p.storeBytes(of: (virtualBLAS?.table(slot: slot) ?? dummy).gpuAddress, toByteOffset: 72, as: UInt64.self)
        p.storeBytes(of: staticRoot, toByteOffset: 80, as: UInt32.self)
        p.storeBytes(of: dynamicRoot, toByteOffset: 84, as: UInt32.self)
        p.storeBytes(of: UInt32(virtualNodeBase), toByteOffset: 88, as: UInt32.self)
    }

    static func rtInstance(_ inst: Scene.Instance, blasRoot: UInt32) -> RTInstance {
        let inv = inst.transform.inverse
        return RTInstance(row0: SIMD4(inv[0][0], inv[1][0], inv[2][0], inv[3][0]),
                          row1: SIMD4(inv[0][1], inv[1][1], inv[2][1], inv[3][1]),
                          row2: SIMD4(inv[0][2], inv[1][2], inv[2][2], inv[3][2]),
                          blasRoot: blasRoot, mask: inst.mask)
    }

    /// CPU build (`METALRENDERER_RT_BUILD=cpu` only): this frame's instance data and dynamic TLAS.
    func update(slot: Int, scene: Scene) {
        guard CustomRayTracer.cpuBuild else { return }
        let inst = instances[slot].contents().bindMemory(to: RTInstance.self, capacity: scene.instances.count)
        for (i, s) in scene.instances.enumerated() { inst[i] = CustomRayTracer.rtInstance(s, blasRoot: s.mesh >= 0 ? blasRoots[s.mesh] : 0) }
        guard dynamicIds.count >= 2 else { return }
        let boxes = dynamicIds.map { i -> AABB in
            let inst = scene.instances[i]
            return (inst.mesh >= 0 ? meshBounds[inst.mesh] : scene.virtualMeshes[inst.virtualMesh].bounds).transformed(inst.transform)
        }
        var nodes: [BVHNode] = []
        _ = BVHBuilder.buildTLAS(boxes: boxes, ids: dynamicIds, masks: dynamicIds.map { scene.instances[$0].mask },
                                 nodeBase: staticNodes.count, into: &nodes)
        nodes.withUnsafeBytes {
            tlasNodes[slot].contents().advanced(by: staticNodes.count * MemoryLayout<BVHNode>.stride)
                .copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
    }

    /// GPU build: every instance's RTInstance, the dynamic TLAS from this frame's instance data, and the
    /// virtual-geometry cut and its cluster tree.
    func encodeBuild(_ enc: ComputePass, slot: Int, instanceData: MTLBuffer, view: VGView) {
        guard instanceCount > 0, let pipelines else { return }
        if !CustomRayTracer.cpuBuild {
            var count = UInt32(instanceCount)
            enc.setBytes(&count, length: 4, index: 0)
            enc.setBuffer(instanceData, offset: 0, index: 1)
            enc.setBuffer(meshInfo, offset: 0, index: 2)
            enc.setBuffer(dynSlot, offset: 0, index: 3)
            enc.setBuffer(instances[slot], offset: 0, index: 4)
            enc.setBuffer(leafBoxes, offset: 0, index: 5)
            enc.setComputePipelineState(pipelines.prep)
            enc.dispatchThreads(MTLSize(width: instanceCount, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            let n = dynamicIds.count
            if n >= 2 {
                CustomRayTracer.encodeLBVH(enc, rt: pipelines, counts: .bytes(SIMD2(UInt32(n), UInt32(paddedCount))), capacity: n,
                                           leafBoxes: leafBoxes, keys: keys, values: values, nodes: tlasNodes[slot],
                                           nodeBase: staticNodes.count, nodeParent: nodeParent, leafParent: leafParent, counters: counters)
            }
        }
        virtualGeometry?.encode(enc, slot: slot, rt: pipelines, vg: pipelines.vg, instanceData: instanceData, tlasNodes: tlasNodes[slot],
                                nodeBase: virtualNodeBase, camPos: view.camPos, pixelScale: view.pixelScale, tau: view.tau, frame: view.frame)
    }

    /// An LBVH over `leafBoxes` (Morton keys, bitonic sort, Karras hierarchy, bottom-up boxes) into `nodes` from
    /// `nodeBase` on. Dispatches cover `capacity` leaves; the kernels skip what lies beyond the actual count.
    static func encodeLBVH(_ enc: ComputePass, rt: RTPipelines, counts: LBVHCounts, capacity: Int,
                           leafBoxes: MTLBuffer, keys: MTLBuffer, values: MTLBuffer, nodes: MTLBuffer, nodeBase: Int,
                           nodeParent: MTLBuffer, leafParent: MTLBuffer, counters: MTLBuffer) {
        func dispatch(_ pso: MTLComputePipelineState, _ threads: Int, group: Int = 64) {
            enc.setComputePipelineState(pso)
            enc.dispatchThreads(MTLSize(width: max(threads, 1), height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(group, pso.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        }
        func bindCounts(_ index: Int) {
            switch counts {
            case .bytes(var c): enc.setBytes(&c, length: 8, index: index)
            case .buffer(let b): enc.setBuffer(b, offset: 0, index: index)
            }
        }
        let padded = max(2, 1 << Int(ceil(log2(Double(max(capacity, 2))))))   // sort size the dispatches cover

        bindCounts(0)
        enc.setBuffer(leafBoxes, offset: 0, index: 1)
        enc.setBuffer(keys, offset: 0, index: 2)
        enc.setBuffer(values, offset: 0, index: 3)
        dispatch(rt.keys, 1024, group: 1024)
        encodeSort(enc, rt: rt, counts: counts, capacity: capacity, keys: keys, values: values)

        var params = SIMD2<UInt32>(0, UInt32(nodeBase))
        enc.setBytes(&params, length: 8, index: 0)
        enc.setBuffer(keys, offset: 0, index: 1)
        enc.setBuffer(values, offset: 0, index: 2)
        enc.setBuffer(leafBoxes, offset: 0, index: 3)
        enc.setBuffer(nodes, offset: nodeBase * MemoryLayout<BVHNode>.stride, index: 4)
        enc.setBuffer(nodeParent, offset: 0, index: 5)
        enc.setBuffer(leafParent, offset: 0, index: 6)
        enc.setBuffer(counters, offset: 0, index: 7)
        bindCounts(8)
        dispatch(rt.hierarchy, capacity - 1)
        dispatch(rt.fit, capacity)
    }

    /// Bitonic sort of (key, value) pairs: whole 2048-key blocks in threadgroup memory, then the cross-block stages.
    /// Dispatches cover `capacity`; the kernels skip what lies beyond the padded count in `counts`.
    static func encodeSort(_ enc: ComputePass, rt: RTPipelines, counts: LBVHCounts, capacity: Int,
                           keys: MTLBuffer, values: MTLBuffer) {
        func dispatch(_ pso: MTLComputePipelineState, _ threads: Int) {
            enc.setComputePipelineState(pso)
            enc.dispatchThreads(MTLSize(width: max(threads, 1), height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(64, pso.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        }
        let padded = max(2, 1 << Int(ceil(log2(Double(max(capacity, 2))))))
        enc.setBuffer(keys, offset: 0, index: 1)
        enc.setBuffer(values, offset: 0, index: 2)
        switch counts {
        case .bytes(var c): enc.setBytes(&c, length: 8, index: 3)
        case .buffer(let b): enc.setBuffer(b, offset: 0, index: 3)
        }
        let block = 2048, blocks = max(padded / block, 1)
        func local(_ k: Int) {
            var p = SIMD2<UInt32>(0, UInt32(k))
            enc.setBytes(&p, length: 8, index: 0)
            enc.setComputePipelineState(rt.sortLocal)
            enc.dispatchThreadgroups(MTLSize(width: blocks, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 1024, height: 1, depth: 1))
        }
        local(0)
        var k = 2 * block
        while k <= padded {
            var j = k / 2
            while j >= block {
                var p = SIMD2<UInt32>(UInt32(k), UInt32(j))
                enc.setBytes(&p, length: 8, index: 0)
                dispatch(rt.sortGlobal, padded / 2)
                j /= 2
            }
            local(k)
            k *= 2
        }
    }

    /// The raw traversal counters (they only grow, wrapping at 2^32). While frames are in flight, read these and take
    /// differences: a reset from the CPU doesn't stick then (the GPU's atomics write their cached values back over it).
    func readCounters() -> [UInt32] {
        let c = stats.contents().bindMemory(to: UInt32.self, capacity: 8)
        return (0..<7).map { c[$0] }
    }

    /// Traversal counter totals since the last call (then resets them). Only with the GPU idle (benchmarks wait for
    /// each frame), see `readCounters`.
    func takeStats() -> TraversalStats {
        let c = stats.contents().bindMemory(to: UInt32.self, capacity: 8)
        let out = TraversalStats(counts: (0..<7).map { UInt64(c[$0]) })
        memset(stats.contents(), 0, 32)
        return out
    }

    func bind(_ enc: ComputePass, slot: Int) {
        enc.setBuffer(sceneArgs[slot], offset: 0, index: 1)
        enc.useResources([tlasNodes[slot], blasNodes, triangles, instances[slot]] + (virtualGeometry?.resources(slot: slot) ?? [dummy])
                         + (virtualBLAS?.resources(slot: slot) ?? []), usage: .read)
        enc.useResource(stats, usage: [.read, .write])
    }

    // MARK: - Self-test (METALRENDERER_RT_CHECK=1)

    /// CPU traversal of one BLAS (the same algorithm as the shader): closest hit t along an object-space ray.
    private func intersectBLAS(root: UInt32, o: SIMD3<Float>, d: SIMD3<Float>, tmax: Float) -> Float {
        var best = tmax
        var stack = [root]
        var dd = d
        dd.replace(with: SIMD3(repeating: 1e-12), where: abs(d) .< 1e-12)
        let inv = SIMD3<Float>(1, 1, 1) / dd
        func slab(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> Bool {
            let t0 = (lo - o) * inv, t1 = (hi - o) * inv
            let tn = simd_min(t0, t1).max(), tf = simd_max(t0, t1).min()
            return max(tn, 0) <= min(tf, best)
        }
        while let ref = stack.popLast() {
            if ref == BVHNode.none { continue }
            if ref & BVHNode.leafBit != 0 {
                let first = Int(ref & 0x0FFF_FFFF), count = Int((ref >> 28) & 7) + 1
                for t in first..<(first + count) {
                    let v0 = cpu.tris[3 * t], e1 = cpu.tris[3 * t + 1], e2 = cpu.tris[3 * t + 2]
                    if let h = CustomRayTracer.triangle(o, d, SIMD3(v0.x, v0.y, v0.z), SIMD3(e1.x, e1.y, e1.z), SIMD3(e2.x, e2.y, e2.z)),
                       h < best { best = h }
                }
                continue
            }
            let n = cpu.blas.nodes[Int(ref)]
            for k in 0..<2 where slab(n.lo(k), n.hi(k)) { stack.append(n.ref(k)) }
        }
        return best
    }

    static func triangle(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ v0: SIMD3<Float>, _ e1: SIMD3<Float>, _ e2: SIMD3<Float>) -> Float? {
        let pv = cross(d, e2), det = dot(e1, pv)
        if det == 0 { return nil }
        let inv = 1 / det, tv = o - v0
        let u = dot(tv, pv) * inv
        if u < 0 || u > 1 { return nil }
        let qv = cross(tv, e1), v = dot(d, qv) * inv
        if v < 0 || u + v > 1 { return nil }
        let t = dot(e2, qv) * inv
        return t > 0 ? t : nil
    }

    /// Random rays against every mesh's BLAS, compared with testing every triangle. Prints the result.
    private func selfTest(scene: Scene) {
        var rng = SystemRandomNumberGenerator()
        var mismatches = 0, rays = 0, hits = 0
        for (m, mesh) in scene.meshes.enumerated() {
            let b = meshBounds[m]
            let size = simd_max(b.hi - b.lo, SIMD3(repeating: 1e-3))
            let triCount = Int(mesh.indexCount) / 3
            for _ in 0..<2000 {
                let o = b.lo - size + SIMD3(Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng),
                                            Float.random(in: 0...1, using: &rng)) * size * 3
                let target = b.lo + SIMD3(Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng),
                                          Float.random(in: 0...1, using: &rng)) * size
                let d = target - o
                var brute = Float.infinity
                for t in 0..<triCount {
                    let base = Int(mesh.firstIndex) + 3 * t
                    let p0 = scene.positions[Int(scene.indices[base])], p1 = scene.positions[Int(scene.indices[base + 1])],
                        p2 = scene.positions[Int(scene.indices[base + 2])]
                    if let h = CustomRayTracer.triangle(o, d, p0, p1 - p0, p2 - p0), h < brute { brute = h }
                }
                let bvh = intersectBLAS(root: blasRoots[m], o: o, d: d, tmax: .infinity)
                rays += 1
                if brute.isFinite { hits += 1 }
                if !(brute == bvh || abs(brute - bvh) <= 1e-5 * max(1, brute)) { mismatches += 1 }
            }
        }
        print("Custom BVH self-test: \(rays) rays over \(scene.meshes.count) meshes, \(hits) hits, \(mismatches) mismatches")
    }
}
