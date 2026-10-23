import Foundation
import simd

/// Dynamic topology (Blender's dyntopo): under the brush, edges longer than 4/3 of the detail size are split at
/// their middles and edges shorter than 4/5 of it collapsed, so the surface gets triangles as fine as the detail
/// wherever the brush goes. The mesh is then laid out again (a new tree): fine for the meshes dyntopo is used on (up to
/// a few hundred thousand triangles), done once per mouse event rather than per dab.
package enum DynTopo {
    /// The mesh refined round `centre` (object space) to edges of about `detail`; nil if nothing changed.
    package static func refine(_ m: SculptMesh, centre: SIMD3<Float>, radius: Float, detail: Float, maxSplits: Int = 20_000) -> SculptMesh? {
        guard detail > 0, radius > 0 else { return nil }
        var pos = m.position
        var tris: [SIMD3<UInt32>] = (0..<m.triangleCount).map { SIMD3(m.indices[3 * $0], m.indices[3 * $0 + 1], m.indices[3 * $0 + 2]) }
        var sets = m.faceSet, hidden = m.hidden
        var alive = [Bool](repeating: true, count: tris.count)
        let reach = radius * 1.1, reach2 = reach * reach
        func inside(_ v: UInt32) -> Bool {
            let p = pos[Int(v)]
            return simd_length_squared(SIMD3(p.x, p.y, p.z) - centre) < reach2
        }
        // The triangles under the brush and their edges.
        var region: [Int] = []
        for l in m.leaves(inSphere: centre, radius: reach) {
            let n = m.nodes[Int(m.leaves[l])]
            for t in Int(n.triStart)..<Int(n.triStart + n.triCount) where !hidden[t] {
                if inside(tris[t].x) || inside(tris[t].y) || inside(tris[t].z) { region.append(t) }
            }
        }
        guard !region.isEmpty else { return nil }
        var edgeTris: [UInt64: [Int]] = [:]
        @inline(__always) func key(_ a: UInt32, _ b: UInt32) -> UInt64 { a < b ? UInt64(a) << 32 | UInt64(b) : UInt64(b) << 32 | UInt64(a) }
        func addEdges(_ t: Int) {
            let v = tris[t]
            for (a, b) in [(v.x, v.y), (v.y, v.z), (v.z, v.x)] { edgeTris[key(a, b), default: []].append(t) }
        }
        func removeEdges(_ t: Int) {
            let v = tris[t]
            for (a, b) in [(v.x, v.y), (v.y, v.z), (v.z, v.x)] { edgeTris[key(a, b)]?.removeAll { $0 == t } }
        }
        for t in region { addEdges(t) }
        func length2(_ k: UInt64) -> Float {
            let a = pos[Int(k >> 32)], b = pos[Int(k & 0xFFFF_FFFF)]
            return simd_length_squared(SIMD3(a.x - b.x, a.y - b.y, a.z - b.z))
        }
        let long2 = (detail * 4 / 3) * (detail * 4 / 3), short2 = (detail * 4 / 5) * (detail * 4 / 5)
        var changed = false
        // Splits, longest first, a few passes.
        var splits = 0
        for _ in 0..<4 {
            let candidates = edgeTris.keys.filter { length2($0) > long2 && (inside(UInt32($0 >> 32)) || inside(UInt32($0 & 0xFFFF_FFFF))) }
                .sorted { length2($0) > length2($1) }
            if candidates.isEmpty { break }
            for k in candidates {
                guard splits < maxSplits, let ts = edgeTris[k], !ts.isEmpty, ts.count <= 2, length2(k) > long2 else { continue }
                let a = UInt32(k >> 32), b = UInt32(k & 0xFFFF_FFFF)
                let pa = pos[Int(a)], pb = pos[Int(b)]
                let mid = UInt32(pos.count)
                pos.append((pa + pb) / 2)
                for t in ts {
                    removeEdges(t)
                    let v = tris[t]
                    // The triangle's corners from a's side: (x, y, z) with the edge x → y, either way round.
                    let order: SIMD3<UInt32>
                    if (v.x == a && v.y == b) || (v.x == b && v.y == a) { order = v }
                    else if (v.y == a && v.z == b) || (v.y == b && v.z == a) { order = SIMD3(v.y, v.z, v.x) }
                    else { order = SIMD3(v.z, v.x, v.y) }
                    let t2 = tris.count
                    tris[t] = SIMD3(order.x, mid, order.z)
                    tris.append(SIMD3(mid, order.y, order.z))
                    sets.append(sets[t]); hidden.append(hidden[t]); alive.append(true)
                    addEdges(t)
                    addEdges(t2)
                }
                splits += 1
                changed = true
            }
        }
        // Collapses, shortest first: b into a at their middle, if it doesn't fold the triangles round it.
        var vertTris: [UInt32: [Int]] = [:]
        for (_, ts) in edgeTris { for t in ts where alive[t] { let v = tris[t]; for x in [v.x, v.y, v.z] where !(vertTris[x]?.contains(t) ?? false) { vertTris[x, default: []].append(t) } } }
        let shorts = edgeTris.keys.filter { length2($0) < short2 && inside(UInt32($0 >> 32)) && inside(UInt32($0 & 0xFFFF_FFFF)) }.sorted { length2($0) < length2($1) }
        var removed = Set<UInt32>()
        for k in shorts {
            let a = UInt32(k >> 32), b = UInt32(k & 0xFFFF_FFFF)
            guard !removed.contains(a), !removed.contains(b), let ts = edgeTris[k], ts.count == 2, length2(k) < short2 else { continue }
            let ta = vertTris[a] ?? [], tb = vertTris[b] ?? []
            // Link condition: the vertices both are joined to are exactly the two across the edge.
            func neighbours(_ v: UInt32, _ list: [Int]) -> Set<UInt32> {
                var s = Set<UInt32>()
                for t in list where alive[t] { let x = tris[t]; for y in [x.x, x.y, x.z] where y != v { s.insert(y) } }
                return s
            }
            let common = neighbours(a, ta).intersection(neighbours(b, tb))
            guard common.count == 2 else { continue }
            let mid = (pos[Int(a)] + pos[Int(b)]) / 2
            // No triangle round them may turn over.
            var flips = false
            for t in Set(ta + tb) where alive[t] && !ts.contains(t) {
                let v = tris[t]
                func p(_ x: UInt32) -> SIMD3<Float> { let q = (x == a || x == b) ? mid : pos[Int(x)]; return SIMD3(q.x, q.y, q.z) }
                func o(_ x: UInt32) -> SIMD3<Float> { let q = pos[Int(x)]; return SIMD3(q.x, q.y, q.z) }
                let before = simd_cross(o(v.y) - o(v.x), o(v.z) - o(v.x)), after = simd_cross(p(v.y) - p(v.x), p(v.z) - p(v.x))
                if simd_dot(before, after) <= 0.1 * simd_length_squared(before) { flips = true; break }
            }
            if flips { continue }
            pos[Int(a)] = mid
            for t in ts { removeEdges(t); alive[t] = false }
            for t in tb where alive[t] {
                removeEdges(t)
                var v = tris[t]
                if v.x == b { v.x = a }
                if v.y == b { v.y = a }
                if v.z == b { v.z = a }
                tris[t] = v
                addEdges(t)
                if !(vertTris[a]?.contains(t) ?? false) { vertTris[a, default: []].append(t) }
            }
            removed.insert(b)
            changed = true
        }
        guard changed else { return nil }
        // The triangles that are left, and the vertices they use.
        var keep: [Int] = []
        keep.reserveCapacity(tris.count)
        for t in 0..<tris.count where alive[t] {
            let v = tris[t]
            if v.x != v.y && v.y != v.z && v.z != v.x { keep.append(t) }
        }
        var newIndex = [Int32](repeating: -1, count: pos.count)
        var positions: [SIMD3<Float>] = [], masks: [Float] = []
        var indices: [UInt32] = []
        indices.reserveCapacity(keep.count * 3)
        for t in keep {
            for x in [tris[t].x, tris[t].y, tris[t].z] {
                if newIndex[Int(x)] < 0 {
                    newIndex[Int(x)] = Int32(positions.count)
                    let p = pos[Int(x)]
                    positions.append(SIMD3(p.x, p.y, p.z))
                    masks.append(p.w)
                }
                indices.append(UInt32(newIndex[Int(x)]))
            }
        }
        let out = SculptMesh(positions: positions, masks: masks, indices: indices,
                             triangleFace: [Int32](repeating: -1, count: keep.count), faceSet: keep.map { sets[$0] },
                             hidden: keep.map { hidden[$0] }, source: [Int32](repeating: -1, count: positions.count))
        return out
    }
}
