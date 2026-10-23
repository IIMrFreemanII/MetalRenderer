import Foundation
import simd

/// Dynamic topology (Blender's dyntopo): under the brush, edges longer than 4/3 of the detail size are split at
/// their middles and edges shorter than 2/5 of that collapsed, so the surface gets triangles as fine as the detail
/// wherever the brush goes. The work is local: the triangles under the brush are copied out, refined, and written back
/// into their leaves' room (a leaf without room moves to the end of the arrays, one grown past twice the leaf size
/// splits), and only the lists of the vertices round them are made again, so a dab costs what it touches whatever the
/// mesh's size.
package enum DynTopo {
    /// What a refinement changed, for the viewport: the leaves whose vertices to copy again and the triangle slots.
    package struct Change {
        package var leaves = Set<Int>()
        package var triangles: [Range<Int>] = []
    }

    /// The mesh refined round `centre` (object space) to edges of about `detail`, in place; nil if nothing changed.
    /// `record` (a stroke's, with its layout undo begun) gets every leaf before it changes.
    @discardableResult
    package static func refine(_ m: SculptMesh, centre: SIMD3<Float>, radius: Float, detail: Float, record: SculptUndoRecord? = nil,
                               maxSplits: Int = 20_000, maxCollapses: Int = 20_000) -> Change? {
        guard detail > 0, radius > 0 else { return nil }
        let reach = radius * 1.1, reach2 = reach * reach

        // The triangles under the brush (a corner inside the reach, not hidden), over vertices numbered here: those
        // first the mesh's, then the new ones.
        var vpos: [SIMD4<Float>] = [], vglobal: [UInt32] = [], vleaf: [Int32] = [], boundary: [Bool] = []
        var originalCount = 0
        var lt: [SIMD3<UInt32>] = [], gid: [Int32] = [], lleaf: [Int32] = [], lset: [Int32] = []
        var alive: [Bool] = [], rewritten: [Bool] = []
        // The mesh's scratch numbering: each vertex's here and each triangle's (−1: not here), put back at the end.
        if m.scratchVertex.count < m.vertexCount { m.scratchVertex.append(contentsOf: repeatElement(-1, count: m.vertexCount - m.scratchVertex.count)) }
        if m.scratchTriangle.count < m.triangleSlots { m.scratchTriangle.append(contentsOf: repeatElement(-1, count: m.triangleSlots - m.scratchTriangle.count)) }
        var localOf = m.scratchVertex, regionOf = m.scratchTriangle
        m.scratchVertex = []; m.scratchTriangle = []
        var handedBack = false
        func handBack() {
            guard !handedBack else { return }
            handedBack = true
            for g in vglobal.prefix(originalCount) { localOf[Int(g)] = -1 }
            for t in gid where t >= 0 { regionOf[Int(t)] = -1 }
            m.scratchVertex = localOf; m.scratchTriangle = regionOf
            localOf = []; regionOf = []
        }
        defer { handBack() }
        do {
            let position = m.position, indices = m.indices, owner = m.owner, hidden = m.hidden, faceSet = m.faceSet
            func vertex(_ g: UInt32) -> UInt32 {
                let known = localOf[Int(g)]
                if known >= 0 { return UInt32(known) }
                let l = UInt32(vpos.count)
                localOf[Int(g)] = Int32(l)
                vpos.append(position[Int(g)])
                vglobal.append(g)
                vleaf.append(owner[Int(g)])
                boundary.append(false)
                return l
            }
            func near(_ g: UInt32) -> Bool {
                let p = position[Int(g)]
                return simd_length_squared(SIMD3(p.x, p.y, p.z) - centre) < reach2
            }
            for l in m.leaves(inSphere: centre, radius: reach) {
                let n = m.nodes[Int(m.leaves[l])]
                for t in Int(n.triStart)..<Int(n.triStart + n.triCount) where !hidden[t] {
                    let a = indices[3 * t], b = indices[3 * t + 1], c = indices[3 * t + 2]
                    guard near(a) || near(b) || near(c) else { continue }
                    regionOf[t] = Int32(lt.count)
                    lt.append(SIMD3(vertex(a), vertex(b), vertex(c)))
                    gid.append(Int32(t)); lleaf.append(Int32(l)); lset.append(faceSet[t])
                    alive.append(true); rewritten.append(false)
                }
            }
            originalCount = vpos.count
        }
        guard !lt.isEmpty else { return nil }
        let originals = vpos.count
        // Vertices with triangles not here (beyond the reach, or hidden): they aren't collapsed, and their edges are
        // split only when every triangle of the edge is here. (The arrays read here are let go before the writes, or
        // the first write would copy them whole.)
        do {
            let vtStart = m.vtStart, vtEnd = m.vtEnd, vtList = m.vtList
            for v in 0..<originals {
                let g = Int(vglobal[v])
                for k in Int(vtStart[g])..<Int(vtEnd[g]) where regionOf[Int(vtList[k])] < 0 {
                    boundary[v] = true
                    break
                }
            }
        }
        func outside(_ a: UInt32, _ b: UInt32) -> Bool {
            let ga = Int(vglobal[Int(a)]), gb = vglobal[Int(b)]
            for k in Int(m.vtStart[ga])..<Int(m.vtEnd[ga]) where regionOf[Int(m.vtList[k])] < 0 {
                let t = Int(m.vtList[k])
                if m.indices[3 * t] == gb || m.indices[3 * t + 1] == gb || m.indices[3 * t + 2] == gb { return true }
            }
            return false
        }

        // Edges and their (one or two) triangles; edges of more are left alone.
        var edges: [UInt64: SIMD2<Int32>] = [:]
        edges.reserveCapacity(lt.count * 2)
        var bad = Set<UInt64>()
        @inline(__always) func key(_ a: UInt32, _ b: UInt32) -> UInt64 { a < b ? UInt64(a) << 32 | UInt64(b) : UInt64(b) << 32 | UInt64(a) }
        func addEdge(_ k: UInt64, _ t: Int32) {
            if var e = edges[k] {
                if e.x < 0 { e.x = t } else if e.y < 0 { e.y = t } else { bad.insert(k) }
                edges[k] = e
            } else {
                edges[k] = SIMD2(t, -1)
            }
        }
        func removeEdge(_ k: UInt64, _ t: Int32) {
            guard var e = edges[k] else { return }
            if e.x == t { e.x = -1 } else if e.y == t { e.y = -1 }
            edges[k] = e.x < 0 && e.y < 0 ? nil : e
        }
        func addEdges(_ t: Int) {
            let v = lt[t]
            addEdge(key(v.x, v.y), Int32(t)); addEdge(key(v.y, v.z), Int32(t)); addEdge(key(v.z, v.x), Int32(t))
        }
        func removeEdges(_ t: Int) {
            let v = lt[t]
            removeEdge(key(v.x, v.y), Int32(t)); removeEdge(key(v.y, v.z), Int32(t)); removeEdge(key(v.z, v.x), Int32(t))
        }
        for t in lt.indices { addEdges(t) }
        @inline(__always) func pos(_ v: UInt32) -> SIMD3<Float> { let p = vpos[Int(v)]; return SIMD3(p.x, p.y, p.z) }
        func inside(_ v: UInt32) -> Bool { simd_length_squared(pos(v) - centre) < reach2 }
        func length2(_ k: UInt64) -> Float { simd_length_squared(pos(UInt32(k >> 32)) - pos(UInt32(k & 0xFFFF_FFFF))) }
        // Collapsing below 2/5 of the split length (Blender's ratio): an edge just split is well above it, so the two
        // don't undo each other's work dab after dab.
        let long = detail * 4 / 3, short = long * 2 / 5
        let long2 = long * long, short2 = short * short

        // Splits, longest first, a few passes.
        var splits = 0
        for _ in 0..<4 {
            var candidates: [(length: Float, key: UInt64)] = []
            for k in edges.keys {
                let l = length2(k)
                if l > long2 && !bad.contains(k) && (inside(UInt32(k >> 32)) || inside(UInt32(k & 0xFFFF_FFFF))) { candidates.append((l, k)) }
            }
            if candidates.isEmpty { break }
            candidates.sort { $0.length > $1.length }
            for (_, k) in candidates {
                guard splits < maxSplits, let e = edges[k], !bad.contains(k), length2(k) > long2 else { continue }
                let a = UInt32(k >> 32), b = UInt32(k & 0xFFFF_FFFF)
                if Int(a) < originals && Int(b) < originals && boundary[Int(a)] && boundary[Int(b)] && outside(a, b) { continue }
                let first = e.x >= 0 ? e.x : e.y
                let mid = UInt32(vpos.count)
                vpos.append((vpos[Int(a)] + vpos[Int(b)]) / 2)
                vglobal.append(.max)
                vleaf.append(lleaf[Int(first)])
                boundary.append(false)
                for t32 in [e.x, e.y] where t32 >= 0 {
                    let t = Int(t32)
                    removeEdges(t)
                    let v = lt[t]
                    // The triangle's corners from a's side: (x, y, z) with the edge x → y, either way round.
                    let order: SIMD3<UInt32>
                    if (v.x == a && v.y == b) || (v.x == b && v.y == a) { order = v }
                    else if (v.y == a && v.z == b) || (v.y == b && v.z == a) { order = SIMD3(v.y, v.z, v.x) }
                    else { order = SIMD3(v.z, v.x, v.y) }
                    let t2 = lt.count
                    lt[t] = SIMD3(order.x, mid, order.z)
                    rewritten[t] = true
                    lt.append(SIMD3(mid, order.y, order.z))
                    gid.append(-1); lleaf.append(lleaf[t]); lset.append(lset[t]); alive.append(true); rewritten.append(true)
                    addEdges(t)
                    addEdges(t2)
                }
                splits += 1
            }
        }

        // Collapses, shortest first: b into a at their middle, if it doesn't fold the triangles round them.
        var vertTris = [[Int32]](repeating: [], count: vpos.count)
        for t in lt.indices where alive[t] {
            let v = lt[t]
            vertTris[Int(v.x)].append(Int32(t)); vertTris[Int(v.y)].append(Int32(t)); vertTris[Int(v.z)].append(Int32(t))
        }
        var dead = [Bool](repeating: false, count: vpos.count)
        var moved = [Bool](repeating: false, count: vpos.count)
        var collapses = 0
        var shorts: [(length: Float, key: UInt64)] = []
        for k in edges.keys {
            let l = length2(k)
            if l < short2 && !bad.contains(k) && inside(UInt32(k >> 32)) && inside(UInt32(k & 0xFFFF_FFFF)) { shorts.append((l, k)) }
        }
        shorts.sort { $0.length < $1.length }
        var na: [UInt32] = [], nb: [UInt32] = []
        for (_, k) in shorts {
            guard collapses < maxCollapses else { break }
            let a = UInt32(k >> 32), b = UInt32(k & 0xFFFF_FFFF)
            guard !dead[Int(a)], !dead[Int(b)], !boundary[Int(a)], !boundary[Int(b)], let e = edges[k], e.x >= 0, e.y >= 0, !bad.contains(k),
                  length2(k) < short2 else { continue }
            // Link condition: the vertices both are joined to are exactly the two across the edge.
            func neighbours(_ v: UInt32, into out: inout [UInt32]) {
                out.removeAll(keepingCapacity: true)
                for t in vertTris[Int(v)] where alive[Int(t)] {
                    let x = lt[Int(t)]
                    if x.x != v && !out.contains(x.x) { out.append(x.x) }
                    if x.y != v && !out.contains(x.y) { out.append(x.y) }
                    if x.z != v && !out.contains(x.z) { out.append(x.z) }
                }
            }
            neighbours(a, into: &na)
            neighbours(b, into: &nb)
            var common = 0
            for x in na where nb.contains(x) { common += 1 }
            guard common == 2 else { continue }
            let mid = (vpos[Int(a)] + vpos[Int(b)]) / 2
            // No triangle round them may turn over.
            var flips = false
            for list in [vertTris[Int(a)], vertTris[Int(b)]] {
                for t in list where alive[Int(t)] && t != e.x && t != e.y {
                    let v = lt[Int(t)]
                    func p(_ x: UInt32) -> SIMD3<Float> { x == a || x == b ? SIMD3(mid.x, mid.y, mid.z) : pos(x) }
                    let before = simd_cross(pos(v.y) - pos(v.x), pos(v.z) - pos(v.x)), after = simd_cross(p(v.y) - p(v.x), p(v.z) - p(v.x))
                    if simd_dot(before, after) <= 0.1 * simd_length_squared(before) { flips = true; break }
                }
                if flips { break }
            }
            if flips { continue }
            vpos[Int(a)] = mid
            vpos[Int(b)] = mid
            moved[Int(a)] = true
            for t in [e.x, e.y] { removeEdges(Int(t)); alive[Int(t)] = false }
            for t32 in vertTris[Int(b)] where alive[Int(t32)] {
                let t = Int(t32)
                removeEdges(t)
                var v = lt[t]
                if v.x == b { v.x = a }
                if v.y == b { v.y = a }
                if v.z == b { v.z = a }
                lt[t] = v
                rewritten[t] = true
                addEdges(t)
                vertTris[Int(a)].append(t32)
            }
            dead[Int(b)] = true
            collapses += 1
        }
        guard splits + collapses > 0 else { return nil }
        handBack()
        return write(m, record: record, originals: originals, vpos: vpos, vglobal: vglobal, vleaf: vleaf, dead: dead, moved: moved,
                     lt: lt, gid: gid, lleaf: lleaf, lset: lset, alive: alive, rewritten: rewritten)
    }

    /// The refined triangles back into their leaves.
    private static func write(_ m: SculptMesh, record: SculptUndoRecord?, originals: Int, vpos: [SIMD4<Float>], vglobal: [UInt32],
                              vleaf: [Int32], dead: [Bool], moved: [Bool], lt: [SIMD3<UInt32>], gid: [Int32], lleaf: [Int32],
                              lset: [Int32], alive: [Bool], rewritten: [Bool]) -> Change {
        var vglobal = vglobal, gid = gid, alive = alive
        // A triangle the collapses made degenerate goes (the link condition keeps that from happening).
        for t in lt.indices where alive[t] {
            let v = lt[t]
            if v.x == v.y || v.y == v.z || v.z == v.x { alive[t] = false }
        }
        var used = [Bool](repeating: false, count: vpos.count)
        for t in lt.indices where alive[t] { used[Int(lt[t].x)] = true; used[Int(lt[t].y)] = true; used[Int(lt[t].z)] = true }
        // What each leaf loses and gains.
        var removed: [Int: Int] = [:], added: [Int: Int] = [:], newVerts: [Int: Int] = [:]
        var leavesChanged = Set<Int>()
        for t in lt.indices {
            let l = Int(lleaf[t])
            if gid[t] >= 0 {
                if !alive[t] { removed[l, default: 0] += 1; leavesChanged.insert(l) } else if rewritten[t] { leavesChanged.insert(l) }
            } else if alive[t] {
                added[l, default: 0] += 1
                leavesChanged.insert(l)
            }
        }
        for v in originals..<vpos.count where used[v] && !dead[v] { newVerts[Int(vleaf[v]), default: 0] += 1; leavesChanged.insert(Int(vleaf[v])) }
        // Leaves without the room for it move to the end first.
        var moves: [(leaf: Int, triangles: Int, vertices: Int)] = []
        for l in leavesChanged {
            let n = m.nodes[Int(m.leaves[l])]
            let tris = Int(n.triCount) - removed[l, default: 0] + added[l, default: 0]
            let verts = newVerts[l, default: 0]
            var room = Int(n.vertCapacity - n.vertCount)
            if verts > room { room += m.freeVertexSlots(leaf: l).count }
            if tris > Int(n.triCapacity) || verts > room {
                let vc = Int(n.vertCount) + verts
                moves.append((l, tris + tris / 2 + 16, vc + vc / 2 + 16))
            }
        }
        var changed = leavesChanged
        var cleared: [Range<Int>] = []
        if !moves.isEmpty {
            let r = m.moveLeaves(moves, record: record, changed: &changed, cleared: &cleared)
            for v in 0..<originals { if let to = r.vertices[vglobal[v]] { vglobal[v] = to } }
            for t in lt.indices where gid[t] >= 0 { gid[t] = Int32(r.triangle(Int(gid[t]))) }
        }
        // New vertices into their leaves' room: dead slots first.
        var free: [Int: [Int32]] = [:]
        for v in originals..<vpos.count where used[v] && !dead[v] {
            let l = Int(vleaf[v]), n = Int(m.leaves[l])
            record?.touch(leaf: l, of: m)
            if free[l] == nil { free[l] = m.freeVertexSlots(leaf: l) }
            let slot: Int
            if let f = free[l]!.popLast() {
                slot = Int(f)
            } else {
                slot = Int(m.nodes[n].vertStart + m.nodes[n].vertCount)
                m.nodes[n].vertCount += 1
            }
            m.position[slot] = vpos[v]
            m.normal[slot] = SIMD4(0, 1, 0, 0)
            m.source[slot] = -1
            m.owner[slot] = Int32(l)
            m.vtStart[slot] = 0; m.vtEnd[slot] = 0; m.vnStart[slot] = 0; m.vnEnd[slot] = 0
            vglobal[v] = UInt32(slot)
        }
        // Moved and merged vertices.
        var movedVerts: [UInt32] = []
        for v in 0..<originals where moved[v] || dead[v] {
            let g = Int(vglobal[v])
            let o = Int(m.owner[g])
            if o >= 0 { record?.touch(leaf: o, of: m) }
            m.position[g] = vpos[v]
            if dead[v] { m.source[g] = -1 }
            movedVerts.append(UInt32(g))
        }
        // The leaves' triangles: rewritten ones where they are, new ones into the removed ones' slots (then after the
        // last), the last moved into what slots are left over; the others stay in their slots.
        var gone = Set<Int32>()
        var rewrite: [Int32: Int] = [:]
        var fresh: [Int: [Int]] = [:]
        for t in lt.indices {
            if gid[t] >= 0 {
                if !alive[t] { gone.insert(gid[t]) } else if rewritten[t] { rewrite[gid[t]] = t }
            } else if alive[t] {
                fresh[Int(lleaf[t]), default: []].append(t)
            }
        }
        func put(_ t: Int, at slot: Int) {
            let v = lt[t]
            m.indices[3 * slot] = vglobal[Int(v.x)]
            m.indices[3 * slot + 1] = vglobal[Int(v.y)]
            m.indices[3 * slot + 2] = vglobal[Int(v.z)]
            m.triangleFace[slot] = -1
            m.faceSet[slot] = lset[t]
            m.hidden[slot] = false
        }
        var written = Set<Int>()
        var oldCorners: [UInt32] = []
        var slotMap: [Int32: Int32] = [:]
        for l in leavesChanged {
            record?.touch(leaf: l, of: m)
            let n = Int(m.leaves[l])
            let s = Int(m.nodes[n].triStart)
            var count = Int(m.nodes[n].triCount)
            var holes: [Int] = []
            for t in s..<(s + count) {
                let slot = Int32(t)
                if gone.contains(slot) {
                    oldCorners += m.indices[(3 * t)..<(3 * t + 3)]
                    m.clearTriangle(t)
                    holes.append(t)
                } else if let local = rewrite[slot] {
                    oldCorners += m.indices[(3 * t)..<(3 * t + 3)]
                    put(local, at: t)
                    written.insert(t)
                }
            }
            holes.reverse()
            for t in fresh[l] ?? [] {
                let slot: Int
                if let h = holes.popLast() { slot = h } else { slot = s + count; count += 1 }
                put(t, at: slot)
                written.insert(slot)
            }
            // Slots left over: the last triangles moved into them (lowest first).
            holes.reverse()
            var h = 0, top = holes.count
            while h < top {
                let last = s + count - 1
                if holes[top - 1] == last {
                    top -= 1
                } else {
                    m.copyTriangle(last, to: holes[h])
                    m.clearTriangle(last)
                    if written.remove(last) != nil { written.insert(holes[h]) } else { slotMap[Int32(last)] = Int32(holes[h]) }
                    h += 1
                }
                count -= 1
            }
            m.nodes[n].triCount = Int32(count)
        }
        var change = Change()
        change.leaves = m.updateAdjacency(written: Array(written), oldCorners: oldCorners, slotMap: slotMap, moved: movedVerts,
                                          boxes: changed, record: record)
        change.leaves.formUnion(changed)
        // Leaves grown past twice the leaf size split in two.
        var split = Set<Int>()
        for l in changed where Int(m.nodes[Int(m.leaves[l])].triCount) > 2 * m.leafTriangles {
            m.splitLeaf(l, record: record, changed: &split, cleared: &cleared)
        }
        if !split.isEmpty {
            m.updateBoxes(leaves: split)
            change.leaves.formUnion(split)
        }
        for l in changed.union(split) {
            let n = m.nodes[Int(m.leaves[l])]
            change.triangles.append(Int(n.triStart)..<Int(n.triStart + n.triCapacity))
        }
        change.triangles += cleared
        return change
    }
}
