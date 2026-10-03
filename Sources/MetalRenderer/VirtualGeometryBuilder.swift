import Foundation
import simd

/// GPU record of one virtual-geometry cluster (MSL `VGCluster`), shared by the cut kernel and the cache file.
///
/// The cut follows Nanite's rule. A cluster is drawn when its group's simplification (the coarser version that
/// replaces it, `parentError` over `parentSphere`) is too coarse on screen, and its own simplification error
/// (`selfError` over `selfSphere`, from the finer group it was made from, `childGroup`) is fine enough, or that finer
/// group isn't resident. Siblings share both tests and errors grow monotonically up the DAG, so the cut is
/// consistent: no cluster appears twice, no gap opens, and locked group borders keep it free of cracks.
struct VGCluster {
    var selfSphere = SIMD4<Float>()     // xyz = centre, w = radius (object space)
    var parentSphere = SIMD4<Float>()
    var lo = SIMD4<Float>()             // xyz = bounds min, w = selfError (0 at the finest level)
    var hi = SIMD4<Float>()             // xyz = bounds max, w = parentError (infinity for roots)
    var group: UInt32 = 0               // the group (page) it lives in
    var childGroup: UInt32 = .max       // the finer group it was simplified from (~0 at the finest level)
    var pageOffset: UInt32 = 0          // byte offset of its data in the group's page
    var triangles: UInt32 = 0
}

/// One mesh's LOD DAG: clusters (grouped, each group one streaming page) and the page data.
struct VirtualMesh {
    struct Group {
        var sphere = SIMD4<Float>()
        var error: Float = 0             // infinity for roots (always resident, never replaced)
        var clusterStart: UInt32 = 0     // its clusters are contiguous in `clusters`
        var clusterCount: UInt32 = 0
        var parentStart: UInt32 = 0      // groups holding the clusters this group simplifies into, in `parents`
        var parentCount: UInt32 = 0
        var pageSize: UInt32 = 0
        var level: UInt32 = 0
        var pageOffset: UInt64 = 0       // into `pageData`
        var isRoot: Bool { error == .infinity }
    }
    var groups: [Group] = []
    var clusters: [VGCluster] = []
    var parents: [UInt32] = []
    var bounds = AABB()
    var triangleCount = 0                // finest level
    var pageData: Data = Data()          // all pages, back to back (memory-mapped when read from a cache file)
}

/// Builds virtual meshes (our own clustering, simplification and DAG; see MeshClusterizer and MeshSimplifier) and
/// reads / writes their cache files.
enum VirtualGeometryBuilder {
    /// Page (streaming unit) size: every group's clusters must fit, and the GPU pool has slots of this size.
    static let pageBytes = 65536
    /// Meshes with at least this many triangles become virtual (custom ray tracer); smaller ones stay ordinary.
    static let minTriangles = 65536

    // MARK: Cluster pages

    /// Serializes one cluster: header, BVH nodes, vertices (position + octahedral normal), UVs (half2), triangles
    /// (three 8-bit local indices, in BVH leaf order). Layout matches the shaders' `vgCluster*` accessors:
    ///   u32 nodeCount, vertexCount, triangleCount, 0, nodeOffset, positionOffset, uvOffset, triangleOffset (bytes).
    static func clusterBlob(triangles: [UInt32], positions: UnsafeBufferPointer<SIMD3<Float>>,
                            normals: UnsafeBufferPointer<SIMD3<Float>>, uvs: UnsafeBufferPointer<SIMD2<Float>>) -> (blob: [UInt8], bounds: AABB) {
        var local: [UInt32: UInt8] = [:]
        var verts: [UInt32] = []
        var tris: [SIMD3<UInt8>] = []
        var boxes: [AABB] = []
        var bounds = AABB()
        for t in stride(from: 0, to: triangles.count, by: 3) {
            var c = SIMD3<UInt8>()
            var box = AABB()
            for k in 0..<3 {
                let g = triangles[t + k]
                if let l = local[g] { c[k] = l } else {
                    let l = UInt8(verts.count)
                    local[g] = l; verts.append(g); c[k] = l
                }
                box.grow(positions[Int(g)])
            }
            tris.append(c)
            boxes.append(box)
            bounds.grow(box)
        }
        let (nodes, order) = BVHBuilder.buildCluster(boxes: boxes)
        let nodeOffset = 32
        let posOffset = nodeOffset + nodes.count * 64
        let uvOffset = posOffset + verts.count * 16
        let triOffset = uvOffset + verts.count * 4
        let size = (triOffset + tris.count * 4 + 15) & ~15
        var blob = [UInt8](repeating: 0, count: size)
        blob.withUnsafeMutableBytes { raw in
            let header: [UInt32] = [UInt32(nodes.count), UInt32(verts.count), UInt32(tris.count), 0,
                                    UInt32(nodeOffset), UInt32(posOffset), UInt32(uvOffset), UInt32(triOffset)]
            for (i, h) in header.enumerated() { raw.storeBytes(of: h, toByteOffset: 4 * i, as: UInt32.self) }
            for (i, n) in nodes.enumerated() { raw.storeBytes(of: n, toByteOffset: nodeOffset + 64 * i, as: BVHNode.self) }
            for (i, g) in verts.enumerated() {
                let p = positions[Int(g)]
                raw.storeBytes(of: SIMD4<Float>(p, Float(bitPattern: octEncode(normals[Int(g)]))), toByteOffset: posOffset + 16 * i,
                               as: SIMD4<Float>.self)
                let uv = uvs[Int(g)]
                let h = UInt32(Float16(uv.x).bitPattern) | UInt32(Float16(uv.y).bitPattern) << 16
                raw.storeBytes(of: h, toByteOffset: uvOffset + 4 * i, as: UInt32.self)
            }
            for (i, t) in order.enumerated() {
                let c = tris[t]
                raw.storeBytes(of: UInt32(c.x) | UInt32(c.y) << 8 | UInt32(c.z) << 16, toByteOffset: triOffset + 4 * i, as: UInt32.self)
            }
        }
        return (blob, bounds)
    }

    /// Octahedral normal encoding, two snorm16 values.
    static func octEncode(_ n: SIMD3<Float>) -> UInt32 {
        var v = n / max(abs(n.x) + abs(n.y) + abs(n.z), 1e-20)
        if v.z < 0 {
            let x = (1 - abs(v.y)) * (v.x >= 0 ? 1 : -1), y = (1 - abs(v.x)) * (v.y >= 0 ? 1 : -1)
            v.x = x; v.y = y
        }
        let x = Int16(max(-1, min(1, v.x)) * 32767), y = Int16(max(-1, min(1, v.y)) * 32767)
        return UInt32(UInt16(bitPattern: x)) | UInt32(UInt16(bitPattern: y)) << 16
    }

    static func sphere(of b: AABB, points: [SIMD3<Float>]) -> SIMD4<Float> {
        let c = b.centroid
        let r = points.reduce(Float(0)) { max($0, distance($1, c)) }
        return SIMD4(c, r)
    }

    /// Smallest sphere around both (or the larger one if it contains the other).
    static func union(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
        let ca = SIMD3(a.x, a.y, a.z), cb = SIMD3(b.x, b.y, b.z)
        let d = distance(ca, cb)
        if d + b.w <= a.w { return a }
        if d + a.w <= b.w { return b }
        let r = (d + a.w + b.w) / 2
        let c = ca + (cb - ca) * ((r - a.w) / max(d, 1e-20))
        return SIMD4(c, r)
    }

    // MARK: DAG

    private struct Cluster {
        var triangles: [UInt32]          // global vertex ids
        var blob: [UInt8]
        var bounds: AABB
        var sphere: SIMD4<Float>         // of its own geometry
        var selfError: Float
        var selfSphere: SIMD4<Float>
        var childGroup: Int32
        var group: Int32 = -1
    }

    /// Builds the LOD DAG of one mesh. `log` gets progress lines.
    static func build(positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32],
                      name: String, log: (String) -> Void = { print($0) }) -> VirtualMesh {
        let start = CFAbsoluteTimeGetCurrent()
        // Welded position ids (topology ignores normal and UV splits).
        var posIds = [Int32](repeating: 0, count: positions.count)
        var seen: [SIMD3<UInt32>: Int32] = [:]
        seen.reserveCapacity(positions.count)
        for (i, p) in positions.enumerated() {
            let key = SIMD3(p.x.bitPattern, p.y.bitPattern, p.z.bitPattern)
            if let id = seen[key] { posIds[i] = id } else { let id = Int32(seen.count); seen[key] = id; posIds[i] = id }
        }

        var clusters: [Cluster] = []
        var groups: [(members: [Int], error: Float, sphere: SIMD4<Float>, level: Int)] = []

        positions.withUnsafeBufferPointer { P in
        normals.withUnsafeBufferPointer { N in
        uvs.withUnsafeBufferPointer { UV in
        posIds.withUnsafeBufferPointer { PID in
            func makeClusters(_ tris: [UInt32], selfError: Float, selfSphere: SIMD4<Float>?, childGroup: Int32) -> [Cluster] {
                let parts = childGroup < 0 ? MeshClusterizer.clusterize(triangles: tris, positions: P, posId: PID)
                                           : MeshClusterizer.clusterizeBalanced(triangles: tris, positions: P, posId: PID)
                return parts.map { members in
                    var t: [UInt32] = []
                    t.reserveCapacity(members.count * 3)
                    for m in members { t += [tris[3 * Int(m)], tris[3 * Int(m) + 1], tris[3 * Int(m) + 2]] }
                    let (blob, bounds) = clusterBlob(triangles: t, positions: P, normals: N, uvs: UV)
                    let s = sphere(of: bounds, points: t.map { P[Int($0)] })
                    return Cluster(triangles: t, blob: blob, bounds: bounds, sphere: s, selfError: selfError,
                                   selfSphere: selfSphere ?? s, childGroup: childGroup)
                }
            }

            clusters = makeClusters(indices, selfError: 0, selfSphere: nil, childGroup: -1)
            var current = Array(clusters.indices)
            var level = 0
            var previousTris = Int.max
            var owner = [Int32](repeating: -1, count: seen.count)        // per position: the group using it
            var shared = [Bool](repeating: false, count: seen.count)     // used by two groups: locked
            while !current.isEmpty {
                let totalTris = current.reduce(0) { $0 + clusters[$1].triangles.count / 3 }
                // Stop when the level barely shrank (what's left can't simplify): everything becomes a root.
                let isLast = current.count <= 2 || totalTris <= 256 || level >= 24 || (level > 0 && totalTris * 100 > previousTris * 95)
                previousTris = totalTris
                let parts = MeshClusterizer.group(clusterTriangles: current.map { clusters[$0].triangles }, positions: P, posId: PID,
                                                  bytes: current.map { clusters[$0].blob.count }, maxBytes: pageBytes)
                let groupBase = groups.count
                // Positions shared by two groups are their common border: locked, so both stay crack-free.
                for i in owner.indices { owner[i] = -1; shared[i] = false }
                for (g, part) in parts.enumerated() {
                    for c in part {
                        for v in clusters[current[c]].triangles {
                            let p = Int(PID[Int(v)])
                            if owner[p] < 0 { owner[p] = Int32(g) } else if owner[p] != Int32(g) { shared[p] = true }
                        }
                    }
                }
                let lockedPositions = shared
                // Simplify every group in parallel, then cluster its result.
                var results = [(tris: [UInt32], error: Float, outputs: [Cluster])?](repeating: nil, count: parts.count)
                results.withUnsafeMutableBufferPointer { slots in
                    DispatchQueue.concurrentPerform(iterations: isLast ? 0 : parts.count) { g in
                        let members = parts[g].map { current[$0] }
                        var tris: [UInt32] = []
                        for m in members { tris += clusters[m].triangles }
                        var (simplified, err) = MeshSimplifier.simplify(triangles: tris, positions: P, posId: PID, uvs: UV,
                                                                         targetTriangles: tris.count / 6,
                                                                         locked: { lockedPositions[Int($0)] })
                        if simplified.count > tris.count * 3 / 4 {
                            // Stuck on UV seams: finish with the relaxed pass (textures may stretch slightly at this LOD).
                            let (relaxed, rerr) = MeshSimplifier.simplify(triangles: simplified, positions: P, posId: PID, uvs: UV,
                                                                          targetTriangles: tris.count / 6, relaxed: true,
                                                                          locked: { lockedPositions[Int($0)] })
                            simplified = relaxed
                            err = max(err, rerr)
                        }
                        if simplified.isEmpty || simplified.count > tris.count * 85 / 100 {
                            // Stuck (all border, say): pass the group up unchanged, so it meets new neighbours next level.
                            simplified = tris
                            err = 0
                        }
                        let error = max(err, members.map { clusters[$0].selfError }.max() ?? 0)
                        var s = members.map { clusters[$0].selfSphere }.reduce(clusters[members[0]].sphere, union)
                        for m in members { s = union(s, clusters[m].sphere) }
                        let outputs = makeClusters(simplified, selfError: error, selfSphere: s, childGroup: Int32(groupBase + g))
                        slots[g] = (simplified, error, outputs)   // its own slot: no lock
                    }
                }
                var next: [Int] = []
                for (g, part) in parts.enumerated() {
                    let members = part.map { current[$0] }
                    for m in members { clusters[m].group = Int32(groupBase + g) }
                    if let r = results[g] {
                        let s = r.outputs.first!.selfSphere
                        groups.append((members, r.error, s, level))
                        for o in r.outputs { next.append(clusters.count); clusters.append(o) }
                    } else {
                        var s = clusters[members[0]].sphere
                        for m in members { s = union(union(s, clusters[m].sphere), clusters[m].selfSphere) }
                        groups.append((members, .infinity, s, level))   // root: never replaced by anything coarser
                    }
                }
                log(String(format: "  %@ level %d: %d clusters, %d triangles -> %d groups (%d roots), %.1f s", name, level,
                           current.count, totalTris, parts.count, results.filter { $0 == nil }.count,
                           CFAbsoluteTimeGetCurrent() - start))
                current = next
                level += 1
            }
        }}}}

        // Output: clusters ordered by group, pages concatenated.
        var mesh = VirtualMesh()
        mesh.triangleCount = indices.count / 3
        var parentSets = [Set<Int>](repeating: [], count: groups.count)
        for c in clusters where c.childGroup >= 0 { parentSets[Int(c.childGroup)].insert(Int(c.group)) }
        var pageData = Data()
        for (g, group) in groups.enumerated() {
            var rec = VirtualMesh.Group()
            rec.sphere = group.sphere
            rec.error = group.error
            rec.level = UInt32(group.level)
            rec.clusterStart = UInt32(mesh.clusters.count)
            rec.clusterCount = UInt32(group.members.count)
            rec.parentStart = UInt32(mesh.parents.count)
            let ps = parentSets[g].sorted()
            rec.parentCount = UInt32(ps.count)
            mesh.parents += ps.map(UInt32.init)
            rec.pageOffset = UInt64(pageData.count)
            var offset = 0
            for m in group.members {
                let c = clusters[m]
                var r = VGCluster()
                r.selfSphere = c.selfSphere
                r.parentSphere = group.sphere
                r.lo = SIMD4(c.bounds.lo, c.selfError)
                r.hi = SIMD4(c.bounds.hi, group.error)
                r.group = UInt32(g)
                r.childGroup = c.childGroup >= 0 ? UInt32(c.childGroup) : .max
                r.pageOffset = UInt32(offset)
                r.triangles = UInt32(c.triangles.count / 3)
                mesh.clusters.append(r)
                pageData.append(contentsOf: c.blob)
                offset += c.blob.count
                mesh.bounds.grow(c.bounds)
            }
            precondition(offset <= pageBytes, "page over budget")
            rec.pageSize = UInt32(offset)
            mesh.groups.append(rec)
        }
        mesh.pageData = pageData
        let roots = mesh.groups.filter(\.isRoot)
        log(String(format: "  %@: %d triangles -> %d clusters in %d groups (%d levels), %.0f MB of pages; roots: %d groups, %d triangles, %.1f MB; %.1f s",
                   name, mesh.triangleCount, mesh.clusters.count, mesh.groups.count, (groups.map(\.level).max() ?? 0) + 1,
                   Double(pageData.count) / 1_048_576, roots.count,
                   roots.reduce(0) { r, g in r + mesh.clusters[Int(g.clusterStart)..<Int(g.clusterStart + g.clusterCount)].reduce(0) { $0 + Int($1.triangles) } },
                   Double(roots.reduce(0) { $0 + Int($1.pageSize) }) / 1_048_576, CFAbsoluteTimeGetCurrent() - start))
        return mesh
    }

    /// DAG invariants the cut relies on (METALRENDERER_VG_CHECK=1). Returns a list of problems (empty = fine).
    static func check(_ mesh: VirtualMesh) -> [String] {
        var problems: [String] = []
        func contains(_ outer: SIMD4<Float>, _ inner: SIMD4<Float>) -> Bool {
            distance(SIMD3(outer.x, outer.y, outer.z), SIMD3(inner.x, inner.y, inner.z)) + inner.w <= outer.w * 1.0001 + 1e-6
        }
        for (i, c) in mesh.clusters.enumerated() {
            if c.hi.w < c.lo.w { problems.append("cluster \(i): parent error \(c.hi.w) < own error \(c.lo.w)") }
            if !contains(c.parentSphere, c.selfSphere) { problems.append("cluster \(i): parent sphere doesn't contain its own") }
            if c.childGroup != .max {
                let child = mesh.groups[Int(c.childGroup)]
                if child.error != c.lo.w { problems.append("cluster \(i): own error differs from its child group's") }
                if child.isRoot { problems.append("cluster \(i): made from a root group") }
            }
        }
        for (g, group) in mesh.groups.enumerated() where !group.isRoot && group.parentCount == 0 {
            problems.append("group \(g): not a root but nothing replaces it")
        }
        if !mesh.groups.contains(where: \.isRoot) { problems.append("no root group") }
        return Array(problems.prefix(20))
    }

    // MARK: Cache files

    /// The virtual meshes for `model`'s meshes `indices`: read from the cache file, or built (and cached) if the
    /// file is missing or stale.
    static func meshes(for url: URL, model: GLTFModel, indices: [Int]) -> [Int: VirtualMesh] {
        let cache = cacheURL(for: url)
        if let cached = try? read(cache), indices.allSatisfy({ cached[$0] != nil }) { return cached }
        print("Virtual geometry: building \(model.name) (first load; cached in \(cache.path))")
        let built = indices.map { i -> (index: Int, mesh: VirtualMesh) in
            let m = model.meshes[i]
            return (i, build(positions: m.positions, normals: m.normals, uvs: m.uvs, indices: m.indices, name: "\(model.name)#\(i)"))
        }
        do {
            try write(built, to: cache)
            return try read(cache)   // memory-mapped pages instead of the in-memory copies
        } catch {
            print("Virtual geometry: could not write \(cache.path): \(error)")
            return Dictionary(uniqueKeysWithValues: built.map { ($0.index, $0.mesh) })
        }
    }

    private static let magic: UInt32 = 0x3156_474D   // "MGV1"
    static let version: UInt32 = 4

    /// Cache file for `model` (by name, size and modification time): next to it in `.metalrenderer-cache/`, or in
    /// ~/Library/Caches/MetalRenderer if that isn't writable.
    static func cacheURL(for model: URL) -> URL {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: model.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = Int((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let name = "\(model.deletingPathExtension().lastPathComponent)-\(size)-\(mtime)-v\(version).mgv"
        let local = model.deletingLastPathComponent().appendingPathComponent(".metalrenderer-cache")
        if (try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)) != nil,
           FileManager.default.isWritableFile(atPath: local.path) {
            return local.appendingPathComponent(name)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MetalRenderer")
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        return caches.appendingPathComponent(name)
    }

    /// Writes `meshes` (keyed by glTF mesh index) to one file: header, then per mesh its records, then all pages.
    static func write(_ meshes: [(index: Int, mesh: VirtualMesh)], to url: URL) throws {
        var head = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { head.append(contentsOf: $0) } }
        func putArray<T>(_ a: [T]) { a.withUnsafeBytes { head.append(contentsOf: $0) } }
        put(magic); put(version); put(UInt32(meshes.count)); put(UInt32(0))
        // Page data goes after all headers; offsets are patched in once the header size is known.
        var headerSize = 16
        for (_, m) in meshes {
            headerSize += 48 + m.groups.count * MemoryLayout<VirtualMesh.Group>.stride
                + m.clusters.count * MemoryLayout<VGCluster>.stride + m.parents.count * 4
        }
        headerSize = (headerSize + 4095) & ~4095
        var pageBase = UInt64(headerSize)
        for (index, m) in meshes {
            put(UInt32(index)); put(UInt32(m.groups.count)); put(UInt32(m.clusters.count)); put(UInt32(m.parents.count))
            put(UInt32(m.triangleCount)); put(UInt32(0)); put(UInt64(m.pageData.count))
            put(m.bounds.lo.x); put(m.bounds.lo.y); put(m.bounds.lo.z); put(m.bounds.hi.x); put(m.bounds.hi.y); put(m.bounds.hi.z)
            putArray(m.groups.map { var g = $0; g.pageOffset += pageBase; return g })
            putArray(m.clusters)
            putArray(m.parents)
            pageBase += UInt64(m.pageData.count)
        }
        head.append(Data(count: headerSize - head.count))
        let tmp = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        try handle.write(contentsOf: head)
        for (_, m) in meshes { try handle.write(contentsOf: m.pageData) }
        try handle.close()
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    /// Reads a cache file (memory-mapped: pages are only paged in when streamed). Group page offsets point into
    /// each mesh's `pageData`.
    static func read(_ url: URL) throws -> [Int: VirtualMesh] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var offset = 0
        func get<T>(_: T.Type) throws -> T {
            guard offset + MemoryLayout<T>.size <= data.count else { throw GLTFError.invalid("truncated cache file") }
            defer { offset += MemoryLayout<T>.size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }
        func getArray<T>(_: T.Type, _ n: Int) throws -> [T] {
            let bytes = n * MemoryLayout<T>.stride
            guard offset + bytes <= data.count else { throw GLTFError.invalid("truncated cache file") }
            defer { offset += bytes }
            return data.withUnsafeBytes { raw in
                (0..<n).map { raw.loadUnaligned(fromByteOffset: offset + $0 * MemoryLayout<T>.stride, as: T.self) }
            }
        }
        guard try get(UInt32.self) == magic, try get(UInt32.self) == version else { throw GLTFError.invalid("not a cache file") }
        let count = Int(try get(UInt32.self))
        _ = try get(UInt32.self)
        var meshes: [Int: VirtualMesh] = [:]
        for _ in 0..<count {
            let index = Int(try get(UInt32.self))
            let groupCount = Int(try get(UInt32.self)), clusterCount = Int(try get(UInt32.self)), parentCount = Int(try get(UInt32.self))
            var m = VirtualMesh()
            m.triangleCount = Int(try get(UInt32.self))
            _ = try get(UInt32.self)
            let pageBytes = Int(try get(UInt64.self))
            let lo = SIMD3(try get(Float.self), try get(Float.self), try get(Float.self))
            let hi = SIMD3(try get(Float.self), try get(Float.self), try get(Float.self))
            m.bounds = AABB(lo: lo, hi: hi)
            m.groups = try getArray(VirtualMesh.Group.self, groupCount)
            m.clusters = try getArray(VGCluster.self, clusterCount)
            m.parents = try getArray(UInt32.self, parentCount)
            guard let first = m.groups.first?.pageOffset, Int(first) + pageBytes <= data.count else {
                throw GLTFError.invalid("cache file pages out of range")
            }
            m.pageData = data[Int(first)..<(Int(first) + pageBytes)]   // a slice of the mapping: nothing is read yet
            for g in m.groups.indices { m.groups[g].pageOffset -= first }
            meshes[index] = m
        }
        return meshes
    }
}
