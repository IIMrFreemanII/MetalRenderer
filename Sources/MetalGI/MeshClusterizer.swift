import simd

/// Splits triangle lists into clusters (≤ `maxTriangles` triangles, ≤ `maxVertices` distinct vertices, so cluster-local
/// indices fit in 8 bits), and clusters into groups for the LOD DAG (VirtualGeometryBuilder).
///
/// Clusters grow greedily over triangles that share a position (so they cross UV seams), seeded in Morton order. A
/// candidate that adds the fewest new vertices wins, then the one nearest the cluster's centre, which keeps clusters
/// compact and their borders short: borders are locked during simplification, so short borders simplify better.
enum MeshClusterizer {
    /// Morton code of `p` inside `bounds`, 10 bits per axis.
    static func morton(_ p: SIMD3<Float>, _ bounds: AABB) -> UInt32 {
        func expand(_ v: UInt32) -> UInt32 {
            var x = v & 0x3FF
            x = (x | (x << 16)) & 0x0300_00FF
            x = (x | (x << 8)) & 0x0300_F00F
            x = (x | (x << 4)) & 0x030C_30C3
            x = (x | (x << 2)) & 0x0924_9249
            return x
        }
        let q = simd_clamp((p - bounds.lo) / simd_max(bounds.hi - bounds.lo, SIMD3(repeating: 1e-9)), .zero, SIMD3(repeating: 1)) * 1023
        return expand(UInt32(q.x)) << 2 | expand(UInt32(q.y)) << 1 | expand(UInt32(q.z))
    }

    /// Dense local numbering of the global ids that occur in a triangle list.
    private struct LocalIds {
        var local: [Int32] = []           // per occurrence
        var count = 0
        init(_ ids: [Int32], universe: Int) {
            local = [Int32](repeating: 0, count: ids.count)
            if ids.count > universe / 8 {   // big lists: an array beats a dictionary
                var map = [Int32](repeating: -1, count: universe)
                for (i, g) in ids.enumerated() {
                    if map[Int(g)] < 0 { map[Int(g)] = Int32(count); count += 1 }
                    local[i] = map[Int(g)]
                }
            } else {
                var map: [Int32: Int32] = [:]
                map.reserveCapacity(ids.count / 2)
                for (i, g) in ids.enumerated() {
                    if let l = map[g] { local[i] = l } else { map[g] = Int32(count); local[i] = Int32(count); count += 1 }
                }
            }
        }
    }

    /// Clusters of `triangles` (global attribute vertex ids, 3 per triangle). Returns triangle index lists.
    /// `unlimitedReach`: fill clusters with the nearest leftover triangles however far (a simplified group is
    /// spatially local already, and its fragments should share clusters).
    static func clusterize(triangles: [UInt32], positions: UnsafeBufferPointer<SIMD3<Float>>, posId: UnsafeBufferPointer<Int32>,
                           maxTriangles: Int = 128, maxVertices: Int = 255, unlimitedReach: Bool = false) -> [[Int32]] {
        let triCount = triangles.count / 3
        guard triCount > 0 else { return [] }
        let posLocal = LocalIds(triangles.map { posId[Int($0)] }, universe: posId.count)
        // Position -> triangles (CSR).
        var start = [Int32](repeating: 0, count: posLocal.count + 1)
        for p in posLocal.local { start[Int(p) + 1] += 1 }
        for i in 0..<posLocal.count { start[i + 1] += start[i] }
        var fill = start
        var adj = [Int32](repeating: 0, count: triangles.count)
        for (i, p) in posLocal.local.enumerated() { adj[Int(fill[Int(p)])] = Int32(i / 3); fill[Int(p)] += 1 }

        var centroids = [SIMD3<Float>](repeating: .zero, count: triCount)
        var bounds = AABB()
        for t in 0..<triCount {
            let c = (positions[Int(triangles[3 * t])] + positions[Int(triangles[3 * t + 1])] + positions[Int(triangles[3 * t + 2])]) / 3
            centroids[t] = c
            bounds.grow(c)
        }
        let keys = centroids.map { morton($0, bounds) }
        let seeds = (0..<triCount).sorted { keys[$0] < keys[$1] }

        var assigned = [Bool](repeating: false, count: triCount)
        var inFrontier = [Int32](repeating: -1, count: triCount)   // cluster id that queued the triangle
        var clusters: [[Int32]] = []
        var seedPos = 0
        for (sp, seed) in seeds.enumerated() where !assigned[seed] {
            seedPos = sp
            let id = Int32(clusters.count)
            var members: [Int32] = []
            var verts = Set<UInt32>()
            var frontier: [Int32] = []
            var center = SIMD3<Float>.zero
            var radius: Float = 0
            func add(_ t: Int) {
                assigned[t] = true
                members.append(Int32(t))
                for k in 0..<3 { verts.insert(triangles[3 * t + k]) }
                center += (centroids[t] - center) / Float(members.count)
                radius = max(radius, distance(centroids[t], center))
                for k in 0..<3 {
                    let p = Int(posLocal.local[3 * t + k])
                    for i in Int(start[p])..<Int(start[p + 1]) {
                        let n = Int(adj[i])
                        if !assigned[n] && inFrontier[n] != id { inFrontier[n] = id; frontier.append(Int32(n)) }
                    }
                }
            }
            add(seed)
            while members.count < maxTriangles {
                var best = -1, bestNew = 4, bestDist = Float.infinity
                var i = 0
                while i < frontier.count {
                    let t = Int(frontier[i])
                    if assigned[t] { frontier.swapAt(i, frontier.count - 1); frontier.removeLast(); continue }
                    var new = 0
                    for k in 0..<3 where !verts.contains(triangles[3 * t + k]) { new += 1 }
                    if verts.count + new <= maxVertices {
                        let d = distance_squared(centroids[t], center)
                        if new < bestNew || (new == bestNew && d < bestDist) { best = t; bestNew = new; bestDist = d }
                    }
                    i += 1
                }
                if best < 0 {
                    // Nothing connected left: the nearest unassigned triangle among the next ones in Morton order, if
                    // it's close (disconnected fragments, slivers), so the cluster still fills up.
                    var bestD = Float.infinity
                    for q in seeds[(seedPos + 1)..<min(seedPos + 257, triCount)] where !assigned[q] {
                        var new = 0
                        for k in 0..<3 where !verts.contains(triangles[3 * q + k]) { new += 1 }
                        guard verts.count + new <= maxVertices else { continue }
                        let d = distance_squared(centroids[q], center)
                        if d < bestD { bestD = d; best = q }
                    }
                    let reach = 2 * radius + 0.02 * (bounds.hi - bounds.lo).max()
                    if best < 0 || (!unlimitedReach && bestD > reach * reach) { break }
                }
                add(best)
            }
            clusters.append(members)
        }

        // Fold slivers (< 16 triangles: leftovers between full clusters) into a neighbouring cluster with room.
        var owner = [Int32](repeating: 0, count: triCount)
        for (c, members) in clusters.enumerated() { for t in members { owner[Int(t)] = Int32(c) } }
        var vertexCount = clusters.map { members in Set(members.flatMap { t in (0..<3).map { triangles[3 * Int(t) + $0] } }).count }
        for c in clusters.indices where !clusters[c].isEmpty && clusters[c].count < 16 {
            var best = -1, bestShared = 0
            var shared: [Int: Int] = [:]
            for t in clusters[c] {
                for k in 0..<3 {
                    let p = Int(posLocal.local[3 * Int(t) + k])
                    for i in Int(start[p])..<Int(start[p + 1]) {
                        let o = Int(owner[Int(adj[i])])
                        if o != c { shared[o, default: 0] += 1 }
                    }
                }
            }
            for (o, n) in shared where n > bestShared && clusters[o].count + clusters[c].count <= maxTriangles
                && vertexCount[o] + vertexCount[c] <= maxVertices {
                best = o; bestShared = n
            }
            guard best >= 0 else { continue }
            for t in clusters[c] { owner[Int(t)] = Int32(best) }
            clusters[best] += clusters[c]
            vertexCount[best] = Set(clusters[best].flatMap { t in (0..<3).map { triangles[3 * Int(t) + $0] } }).count
            clusters[c] = []
        }
        return clusters.filter { !$0.isEmpty }
    }

    /// Clusters of a small triangle list (a simplified group) with balanced sizes: 400 triangles become 4 x 100
    /// rather than 128 + 128 + 128 + 16.
    static func clusterizeBalanced(triangles: [UInt32], positions: UnsafeBufferPointer<SIMD3<Float>>,
                                   posId: UnsafeBufferPointer<Int32>) -> [[Int32]] {
        let n = triangles.count / 3
        let parts = max(1, (n + 127) / 128)
        let size = min(128, (n + parts - 1) / parts + 8)
        return clusterize(triangles: triangles, positions: positions, posId: posId, maxTriangles: size, unlimitedReach: true)
    }

    /// Groups clusters for simplification: greedy, seeded in Morton order of cluster centres, adding the unassigned
    /// neighbour that shares the most border edges (then the nearest) until `maxClusters` clusters or `maxBytes`
    /// (the page budget, from `bytes`) is reached.
    static func group(clusterTriangles: [[UInt32]], positions: UnsafeBufferPointer<SIMD3<Float>>, posId: UnsafeBufferPointer<Int32>,
                      bytes: [Int], maxClusters: Int = 8, maxBytes: Int) -> [[Int]] {
        let n = clusterTriangles.count
        // Shared border edges between clusters: sort (edge, cluster) pairs, then pair up runs.
        var halfEdges: [(UInt64, Int32)] = []
        halfEdges.reserveCapacity(clusterTriangles.reduce(0) { $0 + $1.count })
        for (c, tris) in clusterTriangles.enumerated() {
            for t in stride(from: 0, to: tris.count, by: 3) {
                for k in 0..<3 {
                    let a = UInt32(posId[Int(tris[t + k])]), b = UInt32(posId[Int(tris[t + (k + 1) % 3])])
                    halfEdges.append((UInt64(min(a, b)) << 32 | UInt64(max(a, b)), Int32(c)))
                }
            }
        }
        halfEdges.sort { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
        var adjacency = [[Int: Int]](repeating: [:], count: n)
        var i = 0
        while i < halfEdges.count {
            var j = i + 1
            while j < halfEdges.count && halfEdges[j].0 == halfEdges[i].0 { j += 1 }
            if j - i >= 2 {
                for a in i..<j {
                    for b in (a + 1)..<j where halfEdges[a].1 != halfEdges[b].1 {
                        let x = Int(halfEdges[a].1), y = Int(halfEdges[b].1)
                        adjacency[x][y, default: 0] += 1
                        adjacency[y][x, default: 0] += 1
                    }
                }
            }
            i = j
        }

        var centers = [SIMD3<Float>](repeating: .zero, count: n)
        var bounds = AABB()
        for (c, tris) in clusterTriangles.enumerated() {
            var s = SIMD3<Float>.zero
            for v in tris { s += positions[Int(v)] }
            centers[c] = s / Float(max(tris.count, 1))
            bounds.grow(centers[c])
        }
        let keys = centers.map { morton($0, bounds) }
        let seeds = (0..<n).sorted { keys[$0] < keys[$1] }
        var assigned = [Bool](repeating: false, count: n)
        var groups: [[Int]] = []
        for (seedPos, seed) in seeds.enumerated() where !assigned[seed] {
            var members = [seed]
            var total = bytes[seed]
            assigned[seed] = true
            var center = centers[seed]
            while members.count < maxClusters {
                var best = -1, bestShared = 0, bestDist = Float.infinity
                for m in members {
                    for (nb, shared) in adjacency[m] where !assigned[nb] && total + bytes[nb] <= maxBytes {
                        let d = distance_squared(centers[nb], center)
                        if shared > bestShared || (shared == bestShared && d < bestDist) { best = nb; bestShared = shared; bestDist = d }
                    }
                }
                if best < 0 {
                    // No unassigned neighbour (islands, or neighbours taken): the nearest of the next few clusters
                    // in Morton order, so small disconnected parts still simplify together.
                    for q in seeds[(seedPos + 1)..<min(seedPos + 17, n)] where !assigned[q] && total + bytes[q] <= maxBytes {
                        let d = distance_squared(centers[q], center)
                        if d < bestDist { best = q; bestDist = d }
                    }
                    if best < 0 { break }
                }
                assigned[best] = true
                members.append(best)
                total += bytes[best]
                center += (centers[best] - center) / Float(members.count)
            }
            groups.append(members)
        }

        // Merge small groups (islands, leftovers) into the nearest group with room: a group is one page and one
        // simplification, and both work better with more triangles.
        func groupBytes(_ g: [Int]) -> Int { g.reduce(0) { $0 + bytes[$1] } }
        func groupCenter(_ g: [Int]) -> SIMD3<Float> { g.reduce(SIMD3<Float>.zero) { $0 + centers[$1] } / Float(g.count) }
        var gc = groups.map(groupCenter)
        for g in groups.indices where !groups[g].isEmpty && groups[g].count <= maxClusters / 2 {
            var best = -1, bestDist = Float.infinity
            let size = groupBytes(groups[g])
            for h in groups.indices where h != g && !groups[h].isEmpty && groups[h].count + groups[g].count <= maxClusters
                && groupBytes(groups[h]) + size <= maxBytes {
                let d = distance_squared(gc[g], gc[h])
                if d < bestDist { best = h; bestDist = d }
            }
            guard best >= 0 else { continue }
            groups[best] += groups[g]
            gc[best] = groupCenter(groups[best])
            groups[g] = []
        }
        return groups.filter { !$0.isEmpty }
    }
}
