import Foundation
import Metal
import simd

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

/// Virtual geometry's streaming: the cluster groups' pages, copied from the memory-mapped cache files into a
/// fixed-size pool as a GPU cut asks for them, and evicted least recently used. A cut (VirtualGeometry's for the
/// cluster tree, the raster's for the visibility buffer) reads the residency table `bindPages(slot:)`, marks the
/// groups it draws in `lastUsed`, and writes requests that `addRequests` hands over.
///
/// Residency rules that keep the cut whole: a group is loaded only after every group its clusters simplify into
/// (its parents), and evicted only when none of the groups it was made from (its children) are resident. Roots are
/// always resident, so every mesh can always be drawn, coarsely at worst.
final class VGStreamer {
    /// Streaming on the calling thread (deterministic): benchmarks, or METALRENDERER_VG_SYNC=1; =0 forces the
    /// background path even in benchmarks.
    static let sync: Bool = {
        let env = ProcessInfo.processInfo.environment["METALRENDERER_VG_SYNC"]
        return env == "1" || (Benchmark.isEnabled && env != "0")
    }()

    let poolBytes: Int
    let pool: MTLBuffer
    /// Every mesh's VGCluster records back to back, with global group numbers.
    let clusterBuffer: MTLBuffer
    let requestStamp, lastUsed: MTLBuffer
    private var groupPageBuffers: [MTLBuffer] = []    // per slot: the CPU's residency table for that frame
    /// Per mesh: its first global cluster and group.
    let meshClusterBase: [Int]
    let meshGroupBase: [Int]
    let clusterCount: Int
    let meshes: [VirtualMesh]

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
    private var allocator: BuddyAllocator

    // Streaming state (the lock guards what the GPU completion handler and the copy queue hand over).
    private let lock = NSLock()
    private var pendingRequests: [Int: Float] = [:]    // group -> priority (projected error)
    private var loaded: [Int] = []                     // groups whose pages finished copying, in load order
    private var deferredFrees: [(offset: Int, order: Int, frame: UInt32)] = []
    private let copyQueue = DispatchQueue(label: "metalrenderer.vg.copy", qos: .userInitiated)
    private var completedFrame: UInt32 = 0
    private var published = Set<Int>()                 // meshes that got groups since `takePublished`
    private(set) var stats = (residentGroups: 0, pending: 0, loadedThisFrame: 0)
    private(set) var rootBytes = 0
    var bytesPerFrame = 32 << 20

    init(device: MTLDevice, meshes: [VirtualMesh], poolMB: Int, slots: Int, label: String = "vg") throws {
        self.meshes = meshes
        func buffer(_ length: Int, _ name: String) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw RendererError.resourceCreation("buffer \(label)\(name)")
            }
            b.label = label + name
            return b
        }

        // Global group and cluster numbering: meshes back to back.
        var clusterRecords: [VGCluster] = []
        var clusterBase: [Int] = [], groupBase: [Int] = []
        for (m, mesh) in meshes.enumerated() {
            let base = groups.count
            groupBase.append(base)
            clusterBase.append(clusterRecords.count)
            for (g, rec) in mesh.groups.enumerated() {
                let parents = (0..<Int(rec.parentCount)).map { base + Int(mesh.parents[Int(rec.parentStart) + $0]) }
                groups.append(Group(mesh: m, local: g, pageOffset: Int(rec.pageOffset), pageSize: Int(rec.pageSize),
                                    isRoot: rec.isRoot, parents: parents))
            }
            for var c in mesh.clusters {
                c.group += UInt32(base)
                if c.childGroup != .max { c.childGroup += UInt32(base) }
                clusterRecords.append(c)
            }
        }
        meshClusterBase = clusterBase
        meshGroupBase = groupBase
        clusterCount = clusterRecords.count
        groupPage = [UInt32](repeating: .max, count: groups.count)

        poolBytes = max(poolMB, 64) << 20
        pool = try buffer(poolBytes, "Pool")
        allocator = BuddyAllocator(size: poolBytes)
        let clusterData = try buffer(clusterRecords.count * MemoryLayout<VGCluster>.stride, "Clusters")
        clusterRecords.withUnsafeBytes { clusterData.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        clusterBuffer = clusterData
        requestStamp = try buffer(groups.count * 4, "RequestStamp")
        memset(requestStamp.contents(), 0xFF, groups.count * 4)
        lastUsed = try buffer(groups.count * 4, "LastUsed")
        memset(lastUsed.contents(), 0, groups.count * 4)
        for slot in 0..<slots {
            groupPageBuffers.append(try buffer(groups.count * 4, "GroupPage\(slot)"))
        }

        // Roots are resident from the start (copied right away).
        for g in groups.indices where groups[g].isRoot {
            guard allocate(g) else { throw RendererError.resourceCreation("virtual geometry pool too small for the root pages") }
            copyPage(g)
            setPage(g, UInt32(groups[g].poolOffset / 16))
            rootBytes += groups[g].pageSize
        }
        stats.residentGroups = residentGroups
    }

    var residentMB: Double { Double(allocator.usedBytes) / 1_048_576 }
    var groupCount: Int { groups.count }
    /// Nothing requested, loading or waiting to be published: the cut has what it asked for.
    var isSettled: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingRequests.isEmpty && loaded.isEmpty && stats.pending == 0 && !groups.contains { $0.inFlight }
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

    /// Waits for the pages being copied in the background (tests).
    func waitForCopies() { copyQueue.sync {} }

    // MARK: Per frame

    /// The residency table for the frame in `slot`, copied from the master table only when that changed.
    func bindPages(slot: Int) -> MTLBuffer {
        if slotPageGeneration.count <= slot { slotPageGeneration += [Int](repeating: -1, count: slot + 1 - slotPageGeneration.count) }
        if slotPageGeneration[slot] != pageGeneration {   // residency changed since this slot's copy was written
            groupPage.withUnsafeBytes { groupPageBuffers[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            slotPageGeneration[slot] = pageGeneration
        }
        return groupPageBuffers[slot]
    }

    /// The meshes that got groups since the last call (what a cut drawn before them would now draw finer).
    func takePublished() -> Set<Int> {
        defer { published.removeAll() }
        return published
    }

    /// The residency table `bindPages(slot:)` last wrote for `slot`.
    func pageTable(slot: Int) -> MTLBuffer { groupPageBuffers[slot] }

    /// The frame `frame` has finished on the GPU: its cut's requests, (global group, priority bits) pairs (any thread).
    func addRequests(_ r: UnsafePointer<SIMD2<UInt32>>, count n: Int, frame: UInt32) {
        lock.lock()
        for i in 0..<n {
            let g = Int(r[i].x)
            guard g < groups.count else { continue }
            pendingRequests[g] = max(pendingRequests[g] ?? 0, Float(bitPattern: r[i].y))
        }
        completedFrame = max(completedFrame, frame)
        lock.unlock()
    }

    /// Render thread, before encoding `frame`: publish finished loads, free evicted pages the GPU no longer reads, and
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
            published.insert(groups[g].mesh)
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
            if VGStreamer.sync {
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
}
