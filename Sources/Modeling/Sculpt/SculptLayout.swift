import Foundation
import simd

/// Dynamic topology's changes to the sculpt mesh's layout, made in place so a dab costs what it touches: a leaf that
/// outgrows its room moves to the end of the arrays, one that holds too many triangles splits in two, and the lists of
/// the vertices round what changed are made again. What that leaves behind is packed away by `compact()`, at the start
/// of a stroke.
extension SculptMesh {
    /// Which leaf holds a triangle slot: a binary search over the leaves' ranges.
    struct TriangleLeaves {
        private var starts: [Int32] = [], ends: [Int32] = [], leaf: [Int32] = []

        init(_ m: SculptMesh) {
            var order: [(start: Int32, end: Int32, leaf: Int32)] = []
            order.reserveCapacity(m.leaves.count)
            for (l, n) in m.leaves.enumerated() {
                let node = m.nodes[Int(n)]
                if node.triCount > 0 { order.append((node.triStart, node.triStart + node.triCount, Int32(l))) }
            }
            order.sort { $0.start < $1.start }
            starts = order.map(\.start)
            ends = order.map(\.end)
            leaf = order.map(\.leaf)
        }

        func leaf(of t: Int32) -> Int? {
            var lo = 0, hi = starts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if starts[mid] <= t { lo = mid + 1 } else { hi = mid }
            }
            let i = lo - 1
            guard i >= 0, t < ends[i] else { return nil }
            return Int(leaf[i])
        }
    }

    /// Where leaves went (`moveLeaves`, `splitLeaf`): their vertices' new numbers and their triangles'.
    struct LeafMoves {
        var vertices: [UInt32: UInt32] = [:]
        var triangles: [(from: Int, count: Int, to: Int)] = []
        var splitTriangles: [Int: Int] = [:]

        func triangle(_ t: Int) -> Int {
            if let s = splitTriangles[t] { return s }
            for m in triangles where t >= m.from && t < m.from + m.count { return m.to + t - m.from }
            return t
        }
    }

    // MARK: Slots

    /// `count` unused triangle slots at the end; where they start.
    func appendTriangleSlots(_ count: Int) -> Int {
        let s = triangleSlots
        indices.append(contentsOf: repeatElement(0, count: 3 * count))
        triangleFace.append(contentsOf: repeatElement(-1, count: count))
        faceSet.append(contentsOf: repeatElement(0, count: count))
        hidden.append(contentsOf: repeatElement(false, count: count))
        return s
    }

    /// `count` unused vertex slots of a leaf's at the end; where they start.
    func appendVertexSlots(_ count: Int, owner l: Int32) -> Int {
        let s = vertexCount
        position.append(contentsOf: repeatElement(.zero, count: count))
        normal.append(contentsOf: repeatElement(SIMD4(0, 1, 0, 0), count: count))
        source.append(contentsOf: repeatElement(-1, count: count))
        owner.append(contentsOf: repeatElement(l, count: count))
        for list in [\SculptMesh.vtStart, \.vtEnd, \.vnStart, \.vnEnd] { self[keyPath: list].append(contentsOf: repeatElement(0, count: count)) }
        return s
    }

    func copyTriangle(_ from: Int, to: Int) {
        indices[3 * to] = indices[3 * from]
        indices[3 * to + 1] = indices[3 * from + 1]
        indices[3 * to + 2] = indices[3 * from + 2]
        triangleFace[to] = triangleFace[from]
        faceSet[to] = faceSet[from]
        hidden[to] = hidden[from]
    }

    /// A slot no leaf uses: drawn as nothing, mapped to no face.
    func clearTriangle(_ t: Int) {
        indices[3 * t] = 0
        indices[3 * t + 1] = 0
        indices[3 * t + 2] = 0
        triangleFace[t] = -1
        faceSet[t] = 0
        hidden[t] = false
    }

    func copyVertex(_ from: Int, to: Int) {
        position[to] = position[from]
        normal[to] = normal[from]
        source[to] = source[from]
        vtStart[to] = vtStart[from]
        vtEnd[to] = vtEnd[from]
        vnStart[to] = vnStart[from]
        vnEnd[to] = vnEnd[from]
    }

    func clearVertex(_ v: Int) {
        source[v] = -1
        owner[v] = -1
        vtStart[v] = 0
        vtEnd[v] = 0
        vnStart[v] = 0
        vnEnd[v] = 0
    }

    /// The arrays cut back to these lengths (an undo of what was added at their ends).
    func truncate(triangles: Int, vertices: Int, vt: Int, vn: Int) {
        indices.removeSubrange((3 * triangles)...)
        triangleFace.removeSubrange(triangles...)
        faceSet.removeSubrange(triangles...)
        hidden.removeSubrange(triangles...)
        position.removeSubrange(vertices...)
        normal.removeSubrange(vertices...)
        source.removeSubrange(vertices...)
        owner.removeSubrange(vertices...)
        vtStart.removeSubrange(vertices...)
        vtEnd.removeSubrange(vertices...)
        vnStart.removeSubrange(vertices...)
        vnEnd.removeSubrange(vertices...)
        vtList.removeSubrange(vt...)
        vnList.removeSubrange(vn...)
    }

    /// Dead vertex slots of a leaf's (no triangle uses them), for new vertices.
    func freeVertexSlots(leaf l: Int) -> [Int32] {
        let n = nodes[Int(leaves[l])]
        var out: [Int32] = []
        for v in Int(n.vertStart)..<Int(n.vertStart + n.vertCount) where vtStart[v] == vtEnd[v] { out.append(Int32(v)) }
        return out
    }

    // MARK: Moving and splitting leaves

    /// Moves leaves to room at the end of the arrays (`triangles` and `vertices` slots each), their vertices
    /// renumbered in every triangle that uses them and the lists patched to match (they must be up to date: they find
    /// those triangles). `changed` gets the leaves whose triangles changed, `cleared` the slots left behind.
    func moveLeaves(_ moves: [(leaf: Int, triangles: Int, vertices: Int)], record: SculptUndoRecord?,
                    changed: inout Set<Int>, cleared: inout [Range<Int>]) -> LeafMoves {
        var result = LeafMoves()
        var moved: [Int] = []
        for mv in moves {
            record?.touch(leaf: mv.leaf, of: self)
            let n = Int(leaves[mv.leaf])
            let node = nodes[n]
            let ts = Int(node.triStart), tc = Int(node.triCount), vs = Int(node.vertStart), vc = Int(node.vertCount)
            let tcap = max(mv.triangles, tc), vcap = max(mv.vertices, vc)
            let newT = appendTriangleSlots(tcap)
            for k in 0..<tc {
                copyTriangle(ts + k, to: newT + k)
                clearTriangle(ts + k)
            }
            let newV = appendVertexSlots(vcap, owner: Int32(mv.leaf))
            for k in 0..<vc {
                copyVertex(vs + k, to: newV + k)
                clearVertex(vs + k)
                result.vertices[UInt32(vs + k)] = UInt32(newV + k)
                moved.append(newV + k)
            }
            nodes[n].triStart = Int32(newT)
            nodes[n].triCapacity = Int32(tcap)
            nodes[n].vertStart = Int32(newV)
            nodes[n].vertCapacity = Int32(vcap)
            result.triangles.append((ts, tc, newT))
            cleared.append(ts..<(ts + tc))
            changed.insert(mv.leaf)
        }
        renumber(moved, result, record: record, changed: &changed)
        return result
    }

    /// Splits a leaf that holds too many triangles in two (at the median of its triangles' centres on their longest
    /// axis), each half in room at the end of the arrays; the leaf's index goes to the first half, the second is a new
    /// leaf. Vertices no triangle uses are dropped. The lists must be up to date; they're patched to match.
    func splitLeaf(_ l: Int, record: SculptUndoRecord?, changed: inout Set<Int>, cleared: inout [Range<Int>]) {
        record?.touch(leaf: l, of: self)
        let n = Int(leaves[l])
        let node = nodes[n]
        let ts = Int(node.triStart), tc = Int(node.triCount), vs = Int(node.vertStart), vc = Int(node.vertCount)
        guard tc >= 2 else { return }
        func centre(_ t: Int) -> SIMD3<Float> {
            let a = position[Int(indices[3 * t])], b = position[Int(indices[3 * t + 1])], c = position[Int(indices[3 * t + 2])]
            return SIMD3(a.x + b.x + c.x, a.y + b.y + c.y, a.z + b.z + c.z) / 3
        }
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for t in ts..<(ts + tc) { let c = centre(t); lo = simd_min(lo, c); hi = simd_max(hi, c) }
        let ext = hi - lo
        let axis = ext.x >= ext.y && ext.x >= ext.z ? 0 : (ext.y >= ext.z ? 1 : 2)
        let order = (ts..<(ts + tc)).map { (key: centre($0)[axis], t: $0) }.sorted { $0.key < $1.key }.map(\.t)
        let halves = [Array(order[..<(tc / 2)]), Array(order[(tc / 2)...])]
        // Each vertex to the half whose triangles use it first; one only other leaves' triangles use, to the first.
        var side = [Int8](repeating: -1, count: vc)
        for (s, list) in halves.enumerated() {
            for t in list {
                for j in 0..<3 {
                    let v = Int(indices[3 * t + j]) - vs
                    if v >= 0 && v < vc && side[v] < 0 { side[v] = Int8(s) }
                }
            }
        }
        for k in 0..<vc where side[k] < 0 && vtEnd[vs + k] > vtStart[vs + k] { side[k] = 0 }
        // The leaf becomes a node with two leaves under it.
        let children = [nodes.count, nodes.count + 1]
        var child = SculptNode()
        child.parent = Int32(n)
        nodes.append(child)
        nodes.append(child)
        nodes[n].left = Int32(children[0])
        nodes[n].right = Int32(children[1])
        nodes[n].triCount = 0
        nodes[n].vertCount = 0
        let second = leaves.count
        leaves[l] = Int32(children[0])
        leaves.append(Int32(children[1]))
        leafOfNode[n] = -1
        leafOfNode.append(Int32(l))
        leafOfNode.append(Int32(second))
        var result = LeafMoves()
        var moved: [Int] = []
        for (s, leaf) in [l, second].enumerated() {
            let list = halves[s]
            let tcap = list.count + list.count / 2 + 16
            let newT = appendTriangleSlots(tcap)
            for (k, t) in list.enumerated() {
                copyTriangle(t, to: newT + k)
                result.splitTriangles[t] = newT + k
            }
            let verts = (0..<vc).filter { side[$0] == Int8(s) }
            let vcap = verts.count + verts.count / 2 + 16
            let newV = appendVertexSlots(vcap, owner: Int32(leaf))
            for (k, v) in verts.enumerated() {
                copyVertex(vs + v, to: newV + k)
                result.vertices[UInt32(vs + v)] = UInt32(newV + k)
                moved.append(newV + k)
            }
            let c = children[s]
            nodes[c].triStart = Int32(newT)
            nodes[c].triCount = Int32(list.count)
            nodes[c].triCapacity = Int32(tcap)
            nodes[c].vertStart = Int32(newV)
            nodes[c].vertCount = Int32(verts.count)
            nodes[c].vertCapacity = Int32(vcap)
            changed.insert(leaf)
        }
        for t in ts..<(ts + tc) { clearTriangle(t) }
        for v in vs..<(vs + vc) { clearVertex(v) }
        cleared.append(ts..<(ts + tc))
        renumber(moved, result, record: record, changed: &changed)
    }

    /// The moved vertices' new numbers into every triangle that uses them (found through their lists, which still name
    /// the triangles as they were numbered before the move), then the lists patched in place: the moved triangles' new
    /// slots in their corners' lists, the moved vertices' new numbers in their neighbours' (and their own).
    private func renumber(_ moved: [Int], _ moves: LeafMoves, record: SculptUndoRecord?, changed: inout Set<Int>) {
        let where_ = TriangleLeaves(self)
        for v in moved {
            for k in Int(vtStart[v])..<Int(vtEnd[v]) {
                let t = moves.triangle(Int(vtList[k]))
                if let l = where_.leaf(of: Int32(t)), changed.insert(l).inserted { record?.touch(leaf: l, of: self) }
                for j in 0..<3 {
                    if let to = moves.vertices[indices[3 * t + j]] { indices[3 * t + j] = to }
                }
            }
        }
        // Their corners' lists of triangles (the lists of other leaves' vertices among them).
        func retarget(_ from: Int, _ to: Int) {
            for j in 0..<3 {
                let v = Int(indices[3 * to + j])
                if owner[v] >= 0 { record?.touch(leaf: Int(owner[v]), of: self) }
                for k in Int(vtStart[v])..<Int(vtEnd[v]) where vtList[k] == Int32(from) { vtList[k] = Int32(to); break }
            }
        }
        for m in moves.triangles { for k in 0..<m.count { retarget(m.from + k, m.to + k) } }
        for (from, to) in moves.splitTriangles { retarget(from, to) }
        // Neighbours' lists.
        for (old, new) in moves.vertices {
            let v = Int(new)
            for k in Int(vnStart[v])..<Int(vnEnd[v]) {
                var u = vnList[k]
                if let to = moves.vertices[UInt32(u)] { u = Int32(to); vnList[k] = u }
                let o = owner[Int(u)]
                if o >= 0 { record?.touch(leaf: Int(o), of: self) }
                for i in Int(vnStart[Int(u)])..<Int(vnEnd[Int(u)]) where vnList[i] == Int32(old) { vnList[i] = Int32(new); break }
            }
        }
    }

    // MARK: Lists

    /// The lists after triangles changed: `written` slots got new corners, `oldCorners` lost a triangle (removed, or
    /// rewritten), `slotMap` moved triangles to other slots unchanged. Only those vertices' lists are made again (from
    /// their old lists, renumbered, and the written slots), their leaves' regions packed; then the normals round them
    /// and the boxes of `boxes` and of the leaves of `moved` vertices. Returns the leaves whose vertices changed.
    func updateAdjacency(written: [Int], oldCorners: [UInt32], slotMap: [Int32: Int32], moved: [UInt32], boxes: Set<Int>,
                         record: SculptUndoRecord?) -> Set<Int> {
        if scratchVertex.count < vertexCount { scratchVertex.append(contentsOf: repeatElement(-1, count: vertexCount - scratchVertex.count)) }
        var mark = scratchVertex
        scratchVertex = []
        // The vertices, numbered here; the written slots each gained.
        var affected: [UInt32] = []
        func add(_ v: UInt32) {
            if mark[Int(v)] < 0 { mark[Int(v)] = Int32(affected.count); affected.append(v) }
        }
        for v in oldCorners { add(v) }
        for t in written { for j in 0..<3 { add(indices[3 * t + j]) } }
        for (_, to) in slotMap { for j in 0..<3 { add(indices[3 * Int(to) + j]) } }
        var gainStart = [Int32](repeating: 0, count: affected.count + 1)
        for t in written { for j in 0..<3 { gainStart[Int(mark[Int(indices[3 * t + j])]) + 1] += 1 } }
        for i in 0..<affected.count { gainStart[i + 1] += gainStart[i] }
        var gains = [Int32](repeating: 0, count: Int(gainStart[affected.count]))
        var fill = gainStart
        for t in written {
            for j in 0..<3 {
                let i = Int(mark[Int(indices[3 * t + j])])
                gains[Int(fill[i])] = Int32(t)
                fill[i] += 1
            }
        }
        // Their lists, and every leaf of theirs packed again (read here; written below).
        var regions: [Int] = []
        var regionSeen = Set<Int>()
        for v in affected where owner[Int(v)] >= 0 && regionSeen.insert(Int(owner[Int(v)])).inserted { regions.append(Int(owner[Int(v)])) }
        var packedVT: [[Int32]] = [], packedVN: [[Int32]] = [], countsVT: [[Int32]] = [], countsVN: [[Int32]] = []
        do {
            let indices = self.indices, vtStart = self.vtStart, vtEnd = self.vtEnd, vtList = self.vtList
            let vnStart = self.vnStart, vnEnd = self.vnEnd, vnList = self.vnList
            var vtFlat: [Int32] = [], vnFlat: [Int32] = []
            var vtOff = [Int32](repeating: 0, count: affected.count + 1), vnOff = vtOff
            vtFlat.reserveCapacity(affected.count * 7)
            vnFlat.reserveCapacity(affected.count * 7)
            @inline(__always) func has(_ t: Int, _ v: UInt32) -> Bool {
                let a = indices[3 * t], b = indices[3 * t + 1], c = indices[3 * t + 2]
                return a != b && (a == v || b == v || c == v)
            }
            for (i, v) in affected.enumerated() {
                let start = vtFlat.count
                func put(_ t: Int32) {
                    var k = start
                    while k < vtFlat.count { if vtFlat[k] == t { return }; k += 1 }
                    vtFlat.append(t)
                }
                for k in Int(vtStart[Int(v)])..<Int(vtEnd[Int(v)]) {
                    var t = vtList[k]
                    if !slotMap.isEmpty, let to = slotMap[t] { t = to }
                    if has(Int(t), v) { put(t) }
                }
                for k in Int(gainStart[i])..<Int(gainStart[i + 1]) { put(gains[k]) }
                vtOff[i + 1] = Int32(vtFlat.count)
                let nstart = vnFlat.count
                for k in start..<vtFlat.count {
                    let t = Int(vtFlat[k])
                    for j in 0..<3 {
                        let o = Int32(indices[3 * t + j])
                        if o == Int32(v) { continue }
                        var q = nstart, seen = false
                        while q < vnFlat.count { if vnFlat[q] == o { seen = true; break }; q += 1 }
                        if !seen { vnFlat.append(o) }
                    }
                }
                vnOff[i + 1] = Int32(vnFlat.count)
            }
            for l in regions {
                let n = Int(leaves[l])
                let vs = Int(nodes[n].vertStart), ve = vs + Int(nodes[n].vertCount)
                var pt: [Int32] = [], pn: [Int32] = [], ct: [Int32] = [], cn: [Int32] = []
                pt.reserveCapacity(Int(nodes[n].vtCapacity)); pn.reserveCapacity(Int(nodes[n].vnCapacity))
                ct.reserveCapacity(ve - vs); cn.reserveCapacity(ve - vs)
                for v in vs..<ve {
                    let i = Int(mark[v])
                    if i >= 0 {
                        pt += vtFlat[Int(vtOff[i])..<Int(vtOff[i + 1])]
                        pn += vnFlat[Int(vnOff[i])..<Int(vnOff[i + 1])]
                        ct.append(vtOff[i + 1] - vtOff[i]); cn.append(vnOff[i + 1] - vnOff[i])
                    } else {
                        pt += vtList[Int(vtStart[v])..<Int(vtEnd[v])]
                        pn += vnList[Int(vnStart[v])..<Int(vnEnd[v])]
                        ct.append(vtEnd[v] - vtStart[v]); cn.append(vnEnd[v] - vnStart[v])
                    }
                }
                packedVT.append(pt); packedVN.append(pn); countsVT.append(ct); countsVN.append(cn)
            }
        }
        for v in affected { mark[Int(v)] = -1 }
        scratchVertex = mark
        for (r, l) in regions.enumerated() {
            record?.touch(leaf: l, of: self)
            let n = Int(leaves[l])
            let vs = Int(nodes[n].vertStart)
            var at: Int32
            if packedVT[r].count <= Int(nodes[n].vtCapacity) {
                at = nodes[n].vtRegion
            } else {
                at = Int32(vtList.count)
                let capacity = packedVT[r].count + packedVT[r].count / 4 + 16
                vtList.append(contentsOf: repeatElement(0, count: capacity))
                nodes[n].vtRegion = at
                nodes[n].vtCapacity = Int32(capacity)
            }
            vtList.replaceSubrange(Int(at)..<(Int(at) + packedVT[r].count), with: packedVT[r])
            for (k, c) in countsVT[r].enumerated() { vtStart[vs + k] = at; at += c; vtEnd[vs + k] = at }
            if packedVN[r].count <= Int(nodes[n].vnCapacity) {
                at = nodes[n].vnRegion
            } else {
                at = Int32(vnList.count)
                let capacity = packedVN[r].count + packedVN[r].count / 4 + 16
                vnList.append(contentsOf: repeatElement(0, count: capacity))
                nodes[n].vnRegion = at
                nodes[n].vnCapacity = Int32(capacity)
            }
            vnList.replaceSubrange(Int(at)..<(Int(at) + packedVN[r].count), with: packedVN[r])
            for (k, c) in countsVN[r].enumerated() { vnStart[vs + k] = at; at += c; vnEnd[vs + k] = at }
        }
        // Normals: the affected vertices' and the moved ones' neighbours'.
        var normals = regionSeen
        for v in moved {
            for k in Int(vnStart[Int(v)])..<Int(vnEnd[Int(v)]) where owner[Int(vnList[k])] >= 0 { normals.insert(Int(owner[Int(vnList[k])])) }
        }
        // Boxes: the changed leaves', and those of every leaf with a triangle on a moved vertex.
        var boxed = boxes
        if !moved.isEmpty {
            let where_ = TriangleLeaves(self)
            for v in moved {
                if owner[Int(v)] >= 0 { boxed.insert(Int(owner[Int(v)])) }
                for k in Int(vtStart[Int(v)])..<Int(vtEnd[Int(v)]) { if let l = where_.leaf(of: vtList[k]) { boxed.insert(l) } }
            }
        }
        updateBoxes(leaves: boxed)
        updateNormals(leaves: Array(normals))
        return normals
    }

    // MARK: Packing

    /// Whether what dynamic topology left behind (slots of moved leaves, lists outgrown) is worth packing away.
    package var needsCompaction: Bool {
        var tris = 0, verts = 0, vt = 0, vn = 0
        for l in leaves {
            let n = nodes[Int(l)]
            tris += Int(n.triCapacity); verts += Int(n.vertCapacity); vt += Int(n.vtCapacity); vn += Int(n.vnCapacity)
        }
        return triangleSlots > tris * 3 / 2 + 65_536 || vertexCount > verts * 3 / 2 + 32_768
            || vtList.count > vt * 3 / 2 + 200_000 || vnList.count > vn * 3 / 2 + 200_000
    }

    /// Every leaf's triangles, vertices and lists packed together again in leaf order, each with a quarter more room
    /// than it uses; slots no leaf uses and dead vertices dropped. The shape is unchanged; the numbering isn't.
    package func compact() {
        var vmap = [Int32](repeating: -1, count: vertexCount)
        var tmap = [Int32](repeating: -1, count: triangleSlots)
        var face: [Int32] = [], sets: [Int32] = [], hid: [Bool] = []
        var pos: [SIMD4<Float>] = [], nrm: [SIMD4<Float>] = [], src: [Int32] = [], own: [Int32] = []
        var old: [(tri: Int, triCount: Int, verts: [Int])] = []
        let live = triangleCount
        face.reserveCapacity(live + live / 4); sets.reserveCapacity(live + live / 4); hid.reserveCapacity(live + live / 4)
        for (l, ni) in leaves.enumerated() {
            let n = Int(ni)
            let ts = Int(nodes[n].triStart), tc = Int(nodes[n].triCount)
            let vs = Int(nodes[n].vertStart), vc = Int(nodes[n].vertCount)
            let newT = face.count
            for k in 0..<tc {
                tmap[ts + k] = Int32(newT + k)
                face.append(triangleFace[ts + k]); sets.append(faceSet[ts + k]); hid.append(hidden[ts + k])
            }
            let tcap = tc + tc / 4 + 16
            face.append(contentsOf: repeatElement(-1, count: tcap - tc))
            sets.append(contentsOf: repeatElement(0, count: tcap - tc))
            hid.append(contentsOf: repeatElement(false, count: tcap - tc))
            let newV = pos.count
            var verts: [Int] = []
            for v in vs..<(vs + vc) where vtEnd[v] > vtStart[v] {
                vmap[v] = Int32(pos.count)
                verts.append(v)
                pos.append(position[v]); nrm.append(normal[v]); src.append(source[v]); own.append(Int32(l))
            }
            let vcap = verts.count + verts.count / 4 + 16
            pos.append(contentsOf: repeatElement(.zero, count: vcap - verts.count))
            nrm.append(contentsOf: repeatElement(SIMD4(0, 1, 0, 0), count: vcap - verts.count))
            src.append(contentsOf: repeatElement(-1, count: vcap - verts.count))
            own.append(contentsOf: repeatElement(Int32(l), count: vcap - verts.count))
            nodes[n].triStart = Int32(newT); nodes[n].triCapacity = Int32(tcap)
            nodes[n].vertStart = Int32(newV); nodes[n].vertCount = Int32(verts.count); nodes[n].vertCapacity = Int32(vcap)
            old.append((ts, tc, verts))
        }
        var idx = [UInt32](repeating: 0, count: 3 * face.count)
        var vs = [Int32](repeating: 0, count: pos.count), ve = vs, ns = vs, ne = vs
        var vt: [Int32] = [], vn: [Int32] = []
        vt.reserveCapacity(vtList.count); vn.reserveCapacity(vnList.count)
        for (l, ni) in leaves.enumerated() {
            let n = Int(ni)
            let o = old[l]
            let newT = Int(nodes[n].triStart)
            for k in 0..<(3 * o.triCount) { idx[3 * newT + k] = UInt32(vmap[Int(indices[3 * o.tri + k])]) }
            let vtAt = vt.count, vnAt = vn.count
            for (k, v) in o.verts.enumerated() {
                let to = Int(nodes[n].vertStart) + k
                vs[to] = Int32(vt.count)
                for i in Int(vtStart[v])..<Int(vtEnd[v]) { vt.append(tmap[Int(vtList[i])]) }
                ve[to] = Int32(vt.count)
                ns[to] = Int32(vn.count)
                for i in Int(vnStart[v])..<Int(vnEnd[v]) { vn.append(vmap[Int(vnList[i])]) }
                ne[to] = Int32(vn.count)
            }
            let vtUsed = vt.count - vtAt, vnUsed = vn.count - vnAt
            vt.append(contentsOf: repeatElement(0, count: vtUsed / 4 + 16))
            vn.append(contentsOf: repeatElement(0, count: vnUsed / 4 + 16))
            nodes[n].vtRegion = Int32(vtAt); nodes[n].vtCapacity = Int32(vt.count - vtAt)
            nodes[n].vnRegion = Int32(vnAt); nodes[n].vnCapacity = Int32(vn.count - vnAt)
        }
        indices = idx; triangleFace = face; faceSet = sets; hidden = hid
        position = pos; normal = nrm; source = src; owner = own
        vtStart = vs; vtEnd = ve; vtList = vt; vnStart = ns; vnEnd = ne; vnList = vn
        scratchVertex = []; scratchTriangle = []
        bumpTopology()
    }

    // MARK: Checking

    /// What is wrong with the layout (nil: nothing): leaves' ranges inside their room and apart, every corner a vertex
    /// its leaf owns, every vertex's lists as the triangles make them, boxes round their triangles (after a dab
    /// they needn't be: it updates only the boxes of the leaves whose vertices it moved). For tests.
    package func check(boxes: Bool = true) -> String? {
        var triOwner = [Int32](repeating: -1, count: triangleSlots)
        var vertOwner = [Int32](repeating: -1, count: vertexCount)
        for (l, ni) in leaves.enumerated() {
            let n = nodes[Int(ni)]
            guard n.isLeaf, leafOfNode[Int(ni)] == Int32(l) else { return "leaf \(l): node \(ni) isn't it" }
            guard n.triCount <= n.triCapacity, n.vertCount <= n.vertCapacity,
                  Int(n.triStart + n.triCapacity) <= triangleSlots, Int(n.vertStart + n.vertCapacity) <= vertexCount
            else { return "leaf \(l): range outside its room or the arrays" }
            for t in Int(n.triStart)..<Int(n.triStart + n.triCapacity) {
                guard triOwner[t] < 0 else { return "triangle slot \(t) in leaves \(triOwner[t]) and \(l)" }
                triOwner[t] = Int32(l)
            }
            for v in Int(n.vertStart)..<Int(n.vertStart + n.vertCapacity) {
                guard vertOwner[v] < 0 else { return "vertex slot \(v) in leaves \(vertOwner[v]) and \(l)" }
                vertOwner[v] = Int32(l)
                guard owner[v] == Int32(l) || v >= Int(n.vertStart + n.vertCount) else { return "vertex \(v): owner \(owner[v]), not \(l)" }
            }
        }
        var tris = [[Int32]](repeating: [], count: vertexCount)
        for (l, ni) in leaves.enumerated() {
            let n = nodes[Int(ni)]
            for t in Int(n.triStart)..<Int(n.triStart + n.triCount) {
                let c = [Int(indices[3 * t]), Int(indices[3 * t + 1]), Int(indices[3 * t + 2])]
                guard c[0] != c[1], c[1] != c[2], c[2] != c[0] else { return "triangle \(t) in leaf \(l) degenerate" }
                for v in c {
                    let o = Int(owner[v])
                    guard o >= 0, v < Int(nodes[Int(leaves[o])].vertStart + nodes[Int(leaves[o])].vertCount) else { return "triangle \(t): corner \(v) owned by no leaf" }
                    tris[v].append(Int32(t))
                    let p = SIMD3(position[v].x, position[v].y, position[v].z)
                    guard boxes else { continue }
                    guard all(p .>= n.lo - 1e-5), all(p .<= n.hi + 1e-5) else { return "triangle \(t) outside leaf \(l)'s box" }
                }
            }
        }
        for v in 0..<vertexCount where owner[v] >= 0 {
            let listed = Array(vtList[Int(vtStart[v])..<Int(vtEnd[v])]).sorted()
            guard listed == tris[v].sorted() else { return "vertex \(v): triangles \(listed), not \(tris[v].sorted())" }
            var near = Set<Int32>()
            for t in tris[v] { for j in 0..<3 where indices[3 * Int(t) + j] != UInt32(v) { near.insert(Int32(indices[3 * Int(t) + j])) } }
            let neighbours = Array(vnList[Int(vnStart[v])..<Int(vnEnd[v])])
            guard Set(neighbours) == near, neighbours.count == near.count else { return "vertex \(v): neighbours wrong" }
        }
        return nil
    }
}

/// A stroke's undo when dynamic topology changes it: the tree as it was, every slot of the leaves the stroke changed
/// as it was before the first change (their room's triangles, vertices and lists), and how long the arrays were (what
/// was added at their ends goes). Swapping puts either state back.
package final class SculptLayoutUndo {
    private struct Triangles {
        var start: Int
        var indices: [UInt32], face: [Int32], set: [Int32], hidden: [Bool]

        init(_ m: SculptMesh, _ r: Range<Int>) {
            start = r.lowerBound
            indices = Array(m.indices[(3 * r.lowerBound)..<(3 * r.upperBound)])
            face = Array(m.triangleFace[r]); set = Array(m.faceSet[r]); hidden = Array(m.hidden[r])
        }

        func write(into m: SculptMesh) {
            m.indices.replaceSubrange((3 * start)..<(3 * start + indices.count), with: indices)
            let r = start..<(start + face.count)
            m.triangleFace.replaceSubrange(r, with: face); m.faceSet.replaceSubrange(r, with: set); m.hidden.replaceSubrange(r, with: hidden)
        }
    }

    private struct Vertices {
        var start: Int
        var position: [SIMD4<Float>], source: [Int32], owner: [Int32], lists: [[Int32]]
        static let lists: [ReferenceWritableKeyPath<SculptMesh, [Int32]>] = [\.vtStart, \.vtEnd, \.vnStart, \.vnEnd]

        init(_ m: SculptMesh, _ r: Range<Int>) {
            start = r.lowerBound
            position = Array(m.position[r]); source = Array(m.source[r]); owner = Array(m.owner[r])
            lists = Vertices.lists.map { Array(m[keyPath: $0][r]) }
        }

        func write(into m: SculptMesh) {
            let r = start..<(start + position.count)
            m.position.replaceSubrange(r, with: position); m.source.replaceSubrange(r, with: source); m.owner.replaceSubrange(r, with: owner)
            if m.normal.count < r.upperBound { m.normal.append(contentsOf: repeatElement(SIMD4(0, 1, 0, 0), count: r.upperBound - m.normal.count)) }
            for (k, list) in Vertices.lists.enumerated() { m[keyPath: list].replaceSubrange(r, with: lists[k]) }
        }
    }

    private struct List {
        var start: Int
        var values: [Int32]
        init(_ a: [Int32], _ r: Range<Int>) { start = r.lowerBound; values = Array(a[r]) }
        func write(into a: inout [Int32]) { a.replaceSubrange(start..<(start + values.count), with: values) }
    }

    private let counts: (triangles: Int, vertices: Int, vt: Int, vn: Int)
    private var nodes: [SculptNode], leaves: [Int32], leafOfNode: [Int32]
    private var saved = Set<Int>()
    private var triangles: [Triangles] = [], vertices: [Vertices] = [], vt: [List] = [], vn: [List] = []
    /// What the arrays held past `counts` in the other state (nothing in the state before the stroke).
    private var tail: (Triangles, Vertices, List, List)?

    package init(_ m: SculptMesh) {
        counts = (m.triangleSlots, m.vertexCount, m.vtList.count, m.vnList.count)
        nodes = m.nodes
        leaves = m.leaves
        leafOfNode = m.leafOfNode
    }

    /// Saves a leaf's room before the stroke first changes it (what lies past the old ends needs no saving).
    func touch(_ l: Int, of m: SculptMesh) {
        guard saved.insert(l).inserted else { return }
        let n = m.nodes[Int(m.leaves[l])]
        func clip(_ start: Int32, _ capacity: Int32, _ count: Int) -> Range<Int>? {
            let s = Int(start), e = min(s + Int(capacity), count)
            return e > s ? s..<e : nil
        }
        if let r = clip(n.triStart, n.triCapacity, counts.triangles) { triangles.append(Triangles(m, r)) }
        if let r = clip(n.vertStart, n.vertCapacity, counts.vertices) { vertices.append(Vertices(m, r)) }
        if let r = clip(n.vtRegion, n.vtCapacity, counts.vt) { vt.append(List(m.vtList, r)) }
        if let r = clip(n.vnRegion, n.vnCapacity, counts.vn) { vn.append(List(m.vnList, r)) }
    }

    /// The other state into the mesh, this one kept.
    func swap(into m: SculptMesh) {
        Swift.swap(&nodes, &m.nodes)
        Swift.swap(&leaves, &m.leaves)
        Swift.swap(&leafOfNode, &m.leafOfNode)
        for i in triangles.indices {
            let now = Triangles(m, triangles[i].start..<(triangles[i].start + triangles[i].face.count))
            triangles[i].write(into: m)
            triangles[i] = now
        }
        for i in vertices.indices {
            let now = Vertices(m, vertices[i].start..<(vertices[i].start + vertices[i].position.count))
            vertices[i].write(into: m)
            vertices[i] = now
        }
        for i in vt.indices {
            let now = List(m.vtList, vt[i].start..<(vt[i].start + vt[i].values.count))
            vt[i].write(into: &m.vtList)
            vt[i] = now
        }
        for i in vn.indices {
            let now = List(m.vnList, vn[i].start..<(vn[i].start + vn[i].values.count))
            vn[i].write(into: &m.vnList)
            vn[i] = now
        }
        let now = (Triangles(m, counts.triangles..<m.triangleSlots), Vertices(m, counts.vertices..<m.vertexCount),
                   List(m.vtList, counts.vt..<m.vtList.count), List(m.vnList, counts.vn..<m.vnList.count))
        m.truncate(triangles: counts.triangles, vertices: counts.vertices, vt: counts.vt, vn: counts.vn)
        if let t = tail {
            _ = m.appendTriangleSlots(t.0.face.count)
            t.0.write(into: m)
            _ = m.appendVertexSlots(t.1.position.count, owner: -1)
            t.1.write(into: m)
            m.vtList += t.2.values
            m.vnList += t.3.values
        }
        tail = now
        m.updateAllNormals()
        m.bumpTopology()
    }
}
