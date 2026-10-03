import Foundation
import Metal
import simd

/// Kernels of virtual geometry's per-frame cut (Shaders/VirtualGeometry.metal).
struct VGPipelines {
    let reset, cut, finish, pad, hierarchy, fit: MTLComputePipelineState
}

/// Power-of-two allocator for the streaming pool: blocks of 4 KB to 64 KB (a page), carved from 64 KB chunks.
struct BuddyAllocator {
    static let minBlock = 4096
    static let maxOrder = 4                          // 4 KB << 4 = 64 KB
    private var free: [Set<Int>] = Array(repeating: [], count: maxOrder + 1)
    private(set) var usedBytes = 0

    init(size: Int) {
        for offset in stride(from: 0, to: size - (BuddyAllocator.minBlock << BuddyAllocator.maxOrder) + 1,
                             by: BuddyAllocator.minBlock << BuddyAllocator.maxOrder) {
            free[BuddyAllocator.maxOrder].insert(offset)
        }
    }
    static func order(for bytes: Int) -> Int {
        var o = 0
        while (minBlock << o) < bytes { o += 1 }
        return o
    }
    mutating func allocate(_ bytes: Int) -> (offset: Int, order: Int)? {
        let order = BuddyAllocator.order(for: bytes)
        guard order <= BuddyAllocator.maxOrder, var o = (order...BuddyAllocator.maxOrder).first(where: { !free[$0].isEmpty }) else {
            return nil
        }
        let offset = free[o].removeFirst()
        while o > order {   // split, keeping the upper halves free
            o -= 1
            free[o].insert(offset + (BuddyAllocator.minBlock << o))
        }
        usedBytes += BuddyAllocator.minBlock << order
        return (offset, order)
    }
    mutating func release(_ offset: Int, order: Int) {
        usedBytes -= BuddyAllocator.minBlock << order
        var off = offset, o = order
        while o < BuddyAllocator.maxOrder, free[o].remove(off ^ (BuddyAllocator.minBlock << o)) != nil {
            off &= ~(BuddyAllocator.minBlock << o)
            o += 1
        }
        free[o].insert(off)
    }
}

/// Virtual geometry at run time (custom ray tracer): every frame the GPU picks a cut through each virtual mesh's
/// cluster DAG (vgCutKernel), builds a top-level tree over the picked clusters with the same LBVH kernels as the
/// moving instances, and asks for finer groups it would have liked. The CPU streams those groups' pages from the
/// memory-mapped cache files into a fixed-size pool and evicts the least recently used.
///
/// Residency rules that keep the cut whole: a group is loaded only after every group its clusters simplify into
/// (its parents), and evicted only when none of the groups it was made from (its children) are resident. Roots are
/// always resident, so every mesh can always be drawn, coarsely at worst.
final class VirtualGeometry {
    static let capacity = 65536          // most clusters selected per frame (the cluster tree's leaves)
    static let requestCapacity = 4096
    /// Streaming and LOD updates on the calling thread (deterministic): benchmarks, or METALRENDERER_VG_SYNC=1; =0 forces the
    /// background path even in benchmarks.
    static let sync: Bool = {
        let env = ProcessInfo.processInfo.environment["METALRENDERER_VG_SYNC"]
        return env == "1" || (Benchmark.isEnabled && env != "0")
    }()

    private let device: MTLDevice
    let poolBytes: Int
    let pool: MTLBuffer
    private let clusterBuffer: MTLBuffer
    private let instanceTable: MTLBuffer
    private let workCount: Int
    let instanceCount: Int
    private let leafBoxes, keys, values, nodeParent, leafParent, fitCounters, counts: MTLBuffer
    private let requestStamp, lastUsed: MTLBuffer
    private var groupPageBuffers: [MTLBuffer] = []    // per slot: the CPU's residency table for that frame
    private var counterBuffers: [MTLBuffer] = []      // per slot: selected, requests, overflow
    private var requestBuffers: [MTLBuffer] = []
    private(set) var selectedBuffers: [MTLBuffer] = []
    private(set) var rootsBuffers: [MTLBuffer] = []
    private(set) var nodeInstanceBuffers: [MTLBuffer] = []   // per slot: each cluster-tree node's instance (RT_ENTER)

    private struct Group {
        var mesh: Int
        var local: Int
        var pageOffset: Int                  // in the mesh's pageData
        var pageSize: Int
        var isRoot: Bool
        var parents: [Int]                   // global group ids
        var poolOffset = -1                  // bytes; -1 = not resident
        var order = 0
        var residentChildren = 0
        var inFlight = false
    }
    private var groups: [Group] = []
    private var groupPage: [UInt32]          // CPU master residency table (pool offset / 16, or ~0)
    /// Counts the table's changes: a frame slot's copy is rewritten only when it is behind (`slotPageGeneration`).
    private var pageGeneration = 0
    private var slotPageGeneration: [Int] = []
    private var residentGroups = 0           // entries of groupPage that are not ~0

    /// The one place the residency table is written.
    private func setPage(_ g: Int, _ page: UInt32) {
        guard groupPage[g] != page else { return }
        residentGroups += (page != .max ? 1 : 0) - (groupPage[g] != .max ? 1 : 0)
        groupPage[g] = page
        pageGeneration += 1
    }
    private let meshes: [VirtualMesh]
    private var allocator: BuddyAllocator

    // Streaming state (the lock guards what the GPU completion handler and the copy queue hand over).
    private let lock = NSLock()
    private var pendingRequests: [Int: Float] = [:]    // group -> priority (projected error)
    private var loaded: [Int] = []                     // groups whose pages finished copying, in load order
    private var deferredFrees: [(offset: Int, order: Int, frame: UInt32)] = []
    private let copyQueue = DispatchQueue(label: "metalrenderer.vg.copy", qos: .userInitiated)
    private var completedFrame: UInt32 = 0
    private(set) var stats = (selected: 0, overflow: false, residentGroups: 0, pending: 0, loadedThisFrame: 0)
    var bytesPerFrame = 32 << 20

    /// `instances`: (scene instance index, virtual mesh index) for every virtual instance.
    init(device: MTLDevice, meshes: [VirtualMesh], instances: [(instance: Int, mesh: Int)], poolMB: Int, slots: Int) throws {
        self.device = device
        self.meshes = meshes
        func buffer(_ length: Int, _ label: String, shared: Bool = false) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: max(length, 16), options: shared ? .storageModeShared : .storageModePrivate) else {
                throw RendererError.resourceCreation("buffer \(label)")
            }
            b.label = label
            return b
        }

        // Global group and cluster numbering: meshes back to back.
        var clusterRecords: [VGCluster] = []
        var meshClusterBase: [Int] = []
        for (m, mesh) in meshes.enumerated() {
            let groupBase = groups.count
            meshClusterBase.append(clusterRecords.count)
            for (g, rec) in mesh.groups.enumerated() {
                let parents = (0..<Int(rec.parentCount)).map { groupBase + Int(mesh.parents[Int(rec.parentStart) + $0]) }
                groups.append(Group(mesh: m, local: g, pageOffset: Int(rec.pageOffset), pageSize: Int(rec.pageSize),
                                    isRoot: rec.isRoot, parents: parents))
            }
            for var c in mesh.clusters {
                c.group += UInt32(groupBase)
                if c.childGroup != .max { c.childGroup += UInt32(groupBase) }
                clusterRecords.append(c)
            }
        }
        groupPage = [UInt32](repeating: .max, count: groups.count)
        // Per virtual instance: scene instance, cluster range, first work item, mesh bounds (MSL VGInstance).
        var table: [SIMD4<UInt32>] = []
        var work = 0
        precondition(instances.count <= 256, "the cluster tree's keys have 8 bits for the virtual instance")
        for (instance, mesh) in instances {
            let count = meshes[mesh].clusters.count
            let b = meshes[mesh].bounds
            table.append(SIMD4(UInt32(instance), UInt32(meshClusterBase[mesh]), UInt32(count), UInt32(work)))
            table.append(SIMD4(b.lo.x.bitPattern, b.lo.y.bitPattern, b.lo.z.bitPattern, 0))
            table.append(SIMD4(b.hi.x.bitPattern, b.hi.y.bitPattern, b.hi.z.bitPattern, 0))
            work += count
        }
        workCount = work
        instanceCount = instances.count

        poolBytes = max(poolMB, 64) << 20
        pool = try buffer(poolBytes, "vgPool", shared: true)
        allocator = BuddyAllocator(size: poolBytes)
        let clusterData = try buffer(clusterRecords.count * MemoryLayout<VGCluster>.stride, "vgClusters", shared: true)
        clusterRecords.withUnsafeBytes { clusterData.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        clusterBuffer = clusterData
        let tableData = try buffer(table.count * 16, "vgInstances", shared: true)   // 48 bytes per instance
        table.withUnsafeBytes { if $0.count > 0 { tableData.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        instanceTable = tableData

        let cap = VirtualGeometry.capacity
        leafBoxes = try buffer(cap * 32, "vgLeafBoxes")
        keys = try buffer(cap * 4, "vgKeys")
        values = try buffer(cap * 4, "vgValues")
        nodeParent = try buffer(cap * 4, "vgNodeParent")
        leafParent = try buffer(cap * 4, "vgLeafParent")
        fitCounters = try buffer(cap * 4, "vgFitCounters")
        counts = try buffer(16, "vgCounts")
        requestStamp = try buffer(groups.count * 4, "vgRequestStamp", shared: true)
        memset(requestStamp.contents(), 0xFF, groups.count * 4)
        lastUsed = try buffer(groups.count * 4, "vgLastUsed", shared: true)
        memset(lastUsed.contents(), 0, groups.count * 4)
        for slot in 0..<slots {
            groupPageBuffers.append(try buffer(groups.count * 4, "vgGroupPage\(slot)", shared: true))
            counterBuffers.append(try buffer(16, "vgCounters\(slot)", shared: true))
            requestBuffers.append(try buffer(VirtualGeometry.requestCapacity * 8, "vgRequests\(slot)", shared: true))
            selectedBuffers.append(try buffer(cap * 8, "vgSelected\(slot)"))
            let roots = try buffer(16, "vgRoots\(slot)", shared: true)
            roots.contents().storeBytes(of: BVHNode.none, as: UInt32.self)
            rootsBuffers.append(roots)
            nodeInstanceBuffers.append(try buffer(cap * 4, "vgNodeInstance\(slot)"))
        }

        // Roots are resident from the start (copied right away).
        var rootBytes = 0
        for g in groups.indices where groups[g].isRoot {
            guard allocate(g) else { throw RendererError.resourceCreation("virtual geometry pool too small for the root pages") }
            copyPage(g)
            setPage(g, UInt32(groups[g].poolOffset / 16))
            rootBytes += groups[g].pageSize
        }
        stats.residentGroups = groups.filter { $0.poolOffset >= 0 }.count
        print(String(format: "Virtual geometry: %d meshes, %d instances, %d clusters in %d groups, pool %d MB (roots %.1f MB)",
                     meshes.count, instanceCount, clusterRecords.count, groups.count, poolBytes >> 20, Double(rootBytes) / 1_048_576))
    }

    var residentMB: Double { Double(allocator.usedBytes) / 1_048_576 }
    var meshCount: Int { meshes.count }
    var groupCount: Int { groups.count }
    var clusterCount: Int { meshes.reduce(0) { $0 + $1.clusters.count } }
    var summary: String {
        String(format: "VG: %d clusters drawn%@, %d groups resident (%.0f MB of %d), %d requests waiting", stats.selected,
               stats.overflow ? " (capacity reached)" : "", stats.residentGroups, residentMB, poolBytes >> 20, stats.pending)
    }

    private func allocate(_ g: Int) -> Bool {
        guard let a = allocator.allocate(groups[g].pageSize) else { return false }
        groups[g].poolOffset = a.offset
        groups[g].order = a.order
        return true
    }

    private func copyPage(_ g: Int) {
        let grp = groups[g]
        meshes[grp.mesh].pageData.withUnsafeBytes { raw in
            pool.contents().advanced(by: grp.poolOffset).copyMemory(from: raw.baseAddress!.advanced(by: grp.pageOffset),
                                                                    byteCount: grp.pageSize)
        }
        // Each cluster's header word 3 (unused in the cache) gets group | level << 24, for the geometry debug views.
        let rec = meshes[grp.mesh].groups[grp.local]
        let groupLevel = UInt32(grp.local) & 0xFFFFFF | min(rec.level, 255) << 24
        for c in meshes[grp.mesh].clusters[Int(rec.clusterStart)..<Int(rec.clusterStart + rec.clusterCount)] {
            pool.contents().storeBytes(of: groupLevel, toByteOffset: grp.poolOffset + Int(c.pageOffset) + 12, as: UInt32.self)
        }
    }

    // MARK: Per frame

    /// VGParams in Shaders/VirtualGeometry.metal (48 bytes).
    struct Params {
        var camPos: SIMD4<Float>
        var tau: Float
        var workCount, instanceCount, capacity, frame, requestCapacity, nodeBase, pad: UInt32
    }

    /// Encodes the cut and the cluster tree build. `nodeBase`: the tree's first node in `tlasNodes`.
    func encode(_ enc: MTLComputeCommandEncoder, slot: Int, rt: RTPipelines, vg: VGPipelines, instanceData: MTLBuffer,
                tlasNodes: MTLBuffer, nodeBase: Int, camPos: SIMD3<Float>, pixelScale: Float, tau: Float, frame: UInt32) {
        if slotPageGeneration.count <= slot { slotPageGeneration += [Int](repeating: -1, count: slot + 1 - slotPageGeneration.count) }
        if slotPageGeneration[slot] != pageGeneration {   // residency changed since this slot's copy was written
            groupPage.withUnsafeBytes { groupPageBuffers[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            slotPageGeneration[slot] = pageGeneration
        }
        func dispatch(_ pso: MTLComputePipelineState, _ threads: Int, group: Int = 64) {
            enc.setComputePipelineState(pso)
            enc.dispatchThreads(MTLSize(width: max(threads, 1), height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(group, pso.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        }
        var p = Params(camPos: SIMD4(camPos, pixelScale), tau: tau, workCount: UInt32(workCount), instanceCount: UInt32(instanceCount),
                       capacity: UInt32(VirtualGeometry.capacity), frame: frame, requestCapacity: UInt32(VirtualGeometry.requestCapacity),
                       nodeBase: UInt32(nodeBase), pad: 0)
        enc.setBuffer(counterBuffers[slot], offset: 0, index: 0)
        dispatch(vg.reset, 1)
        enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        enc.setBuffer(instanceTable, offset: 0, index: 1)
        enc.setBuffer(clusterBuffer, offset: 0, index: 2)
        enc.setBuffer(groupPageBuffers[slot], offset: 0, index: 3)
        enc.setBuffer(instanceData, offset: 0, index: 4)
        enc.setBuffer(counterBuffers[slot], offset: 0, index: 5)
        enc.setBuffer(selectedBuffers[slot], offset: 0, index: 6)
        enc.setBuffer(leafBoxes, offset: 0, index: 7)
        enc.setBuffer(requestBuffers[slot], offset: 0, index: 8)
        enc.setBuffer(requestStamp, offset: 0, index: 9)
        enc.setBuffer(lastUsed, offset: 0, index: 10)
        enc.setBuffer(keys, offset: 0, index: 13)
        enc.setBuffer(values, offset: 0, index: 14)
        dispatch(vg.cut, workCount)
        enc.setBuffer(counts, offset: 0, index: 11)
        enc.setBuffer(rootsBuffers[slot], offset: 0, index: 12)
        dispatch(vg.finish, 1)
        dispatch(vg.pad, VirtualGeometry.capacity)

        // The cluster tree: keys come from the cut (instance first, then Morton), so it splits by instance and each
        // instance's part stays in its object space (vgHierarchyKernel / vgFitKernel).
        CustomRayTracer.encodeSort(enc, rt: rt, counts: .buffer(counts), capacity: VirtualGeometry.capacity, keys: keys, values: values)
        var params = SIMD2<UInt32>(0, UInt32(nodeBase))
        enc.setBytes(&params, length: 8, index: 0)
        enc.setBuffer(keys, offset: 0, index: 1)
        enc.setBuffer(values, offset: 0, index: 2)
        enc.setBuffer(leafBoxes, offset: 0, index: 3)
        enc.setBuffer(tlasNodes, offset: nodeBase * MemoryLayout<BVHNode>.stride, index: 4)
        enc.setBuffer(nodeParent, offset: 0, index: 5)
        enc.setBuffer(leafParent, offset: 0, index: 6)
        enc.setBuffer(fitCounters, offset: 0, index: 7)
        enc.setBuffer(counts, offset: 0, index: 8)
        enc.setBuffer(selectedBuffers[slot], offset: 0, index: 9)
        enc.setBuffer(nodeInstanceBuffers[slot], offset: 0, index: 10)
        enc.setBuffer(rootsBuffers[slot], offset: 0, index: 12)
        enc.setBuffer(instanceData, offset: 0, index: 15)
        dispatch(vg.hierarchy, VirtualGeometry.capacity - 1)
        dispatch(vg.fit, VirtualGeometry.capacity)
    }

    /// The frame that used `slot` has finished on the GPU: collect its requests (any thread).
    func collect(slot: Int, frame: UInt32) {
        let c = counterBuffers[slot].contents().bindMemory(to: UInt32.self, capacity: 3)
        let n = min(Int(c[1]), VirtualGeometry.requestCapacity)
        let r = requestBuffers[slot].contents().bindMemory(to: SIMD2<UInt32>.self, capacity: VirtualGeometry.requestCapacity)
        lock.lock()
        for i in 0..<n {
            let g = Int(r[i].x)
            guard g < groups.count else { continue }
            pendingRequests[g] = max(pendingRequests[g] ?? 0, Float(bitPattern: r[i].y))
        }
        completedFrame = max(completedFrame, frame)
        stats.selected = Int(c[0])
        stats.overflow = c[2] != 0
        lock.unlock()
    }

    /// Main thread, before encoding `frame`: publish finished loads, free evicted pages the GPU no longer reads, and
    /// start loading the most wanted requests (their missing parents first) within the per-frame byte budget.
    func update(frame: UInt32, framesInFlight: Int) {
        lock.lock()
        let done = loaded
        loaded.removeAll()
        var requests = pendingRequests
        pendingRequests.removeAll()
        let completed = completedFrame
        lock.unlock()

        for g in done {
            groups[g].inFlight = false
            setPage(g, UInt32(groups[g].poolOffset / 16))
        }
        deferredFrees.removeAll { f in
            guard f.frame &+ UInt32(framesInFlight) <= completed else { return false }
            allocator.release(f.offset, order: f.order)
            return true
        }

        guard !requests.isEmpty else {   // the usual frame once the view has settled: nothing to load
            stats.pending = 0
            stats.loadedThisFrame = 0
            stats.residentGroups = residentGroups
            return
        }
        var budget = bytesPerFrame
        var started: [Int] = []
        let order = requests.sorted { $0.value > $1.value }
        loading: for (g, _) in order {
            // Missing ancestors first (they must be resident before g), coarsest first.
            var chain: [Int] = []
            var stack = [g]
            var seen = Set<Int>()
            while let x = stack.popLast() {
                guard seen.insert(x).inserted, groups[x].poolOffset < 0 else { continue }
                chain.append(x)
                stack += groups[x].parents
            }
            for x in chain.reversed() {
                if groups[x].poolOffset >= 0 { continue }
                if budget < groups[x].pageSize { break loading }
                if !allocate(x) {
                    evict(frame: frame, needed: groups[x].pageSize)
                    if !allocate(x) { break loading }
                }
                groups[x].inFlight = true
                for p in groups[x].parents { groups[p].residentChildren += 1 }   // from now on, parents stay
                budget -= groups[x].pageSize
                started.append(x)
            }
            requests[g] = nil
        }
        if !started.isEmpty {
            if VirtualGeometry.sync {
                for g in started { copyPage(g) }
                lock.lock(); loaded += started; lock.unlock()
                update(frame: frame, framesInFlight: framesInFlight)   // publish them for this frame
                return
            }
            copyQueue.async { [self] in
                for g in started { copyPage(g) }
                lock.lock(); loaded += started; lock.unlock()
            }
        }
        // Requests that didn't fit wait for the next frame (the GPU asks again while they're still wanted).
        stats.pending = requests.count
        stats.loadedThisFrame = started.count
        stats.residentGroups = residentGroups
    }

    /// Frees resident leaf groups (no resident children) that weren't drawn in the last frames, oldest first,
    /// until `needed` bytes could be found. Their pages are only reused once the GPU is done with them.
    private func evict(frame: UInt32, needed: Int) {
        let used = lastUsed.contents().bindMemory(to: UInt32.self, capacity: groups.count)
        var candidates = groups.indices.filter { g in
            let grp = groups[g]
            return !grp.isRoot && grp.poolOffset >= 0 && !grp.inFlight && grp.residentChildren == 0 && groupPage[g] != .max
                && used[g] &+ 2 < frame
        }
        candidates.sort { used[$0] < used[$1] }
        var freed = 0
        for g in candidates {
            setPage(g, .max)
            for p in groups[g].parents { groups[p].residentChildren -= 1 }
            deferredFrees.append((groups[g].poolOffset, groups[g].order, frame))
            freed += BuddyAllocator.minBlock << groups[g].order
            groups[g].poolOffset = -1
            if freed >= needed * 4 { break }
        }
    }

    func resources(slot: Int) -> [MTLResource] { [pool, selectedBuffers[slot], rootsBuffers[slot], nodeInstanceBuffers[slot]] }
}
