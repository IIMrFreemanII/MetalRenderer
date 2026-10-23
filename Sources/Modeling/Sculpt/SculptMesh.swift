import Foundation
import simd

/// A node of the sculpt tree (Blender's PBVH): its box; children, or (a leaf) its range of triangles and of the
/// vertices it owns. Every vertex is owned by exactly one leaf, so a brush that changes a leaf's vertices writes only
/// that leaf's range (in parallel with the other leaves) and the viewport copies only that range. A leaf's ranges have
/// room to grow (`triCapacity`, `vertCapacity`; dynamic topology adds triangles and vertices in place), and so have
/// its vertices' lists of triangles and neighbours (`vtRegion`, `vnRegion`).
package struct SculptNode {
    package var lo = SIMD3<Float>(repeating: .infinity)
    package var hi = SIMD3<Float>(repeating: -.infinity)
    package var left: Int32 = -1
    package var right: Int32 = -1
    package var parent: Int32 = -1
    package var triStart: Int32 = 0
    package var triCount: Int32 = 0
    package var triCapacity: Int32 = 0
    package var vertStart: Int32 = 0
    /// Slots in use, dead ones among them (vertices no triangle uses any more, for dynamic topology to take again).
    package var vertCount: Int32 = 0
    package var vertCapacity: Int32 = 0
    package var vtRegion: Int32 = 0
    package var vtCapacity: Int32 = 0
    package var vnRegion: Int32 = 0
    package var vnCapacity: Int32 = 0
    package var isLeaf: Bool { left < 0 }
}

/// The mesh sculpt mode works on: triangles over smooth vertices, laid out by the tree (each leaf's triangles and
/// owned vertices contiguous), as flat arrays the brushes walk in parallel. Position's w is the mask (0 free, 1
/// masked). Made from the object's mesh (or its multires level); `source` maps each vertex back to the mesh's, and
/// `triangleFace` each triangle to the face it came from, so the shape goes back without touching the mesh's UVs and
/// faces while the topology is unchanged (dynamic topology and remeshing change it: then the mesh is made again).
///
/// Dynamic topology leaves slots no leaf uses (a leaf that outgrew its room moved to the end of the arrays): their
/// triangles are degenerate (drawn as nothing, `triangleFace` −1), their vertices have no source and no owner.
/// `compact()` packs them away.
package final class SculptMesh {
    package var position: [SIMD4<Float>]
    package var normal: [SIMD4<Float>]
    package var source: [Int32]
    /// The leaf each vertex slot belongs to (−1: none).
    package var owner: [Int32]
    package var indices: [UInt32]
    package var triangleFace: [Int32]
    package var faceSet: [Int32]
    /// Hidden triangles (their face set hidden, H): not drawn, not sculpted.
    package var hidden: [Bool]
    // Each vertex's triangles and neighbours: `vtList[vtStart[v]..<vtEnd[v]]`, in its leaf's region of the list.
    package var vtStart: [Int32] = []
    package var vtEnd: [Int32] = []
    package var vtList: [Int32] = []
    package var vnStart: [Int32] = []
    package var vnEnd: [Int32] = []
    package var vnList: [Int32] = []
    package var nodes: [SculptNode] = []
    package var leaves: [Int32] = []
    /// Each node's index in `leaves` (−1: not a leaf).
    package var leafOfNode: [Int32] = []
    /// Changes when the arrays are made again (remesh, undo of dynamic topology, compaction): the viewport's buffers
    /// are made again.
    package private(set) var topologyGeneration: UInt64 = EditMesh.nextGeneration()
    /// The source mesh's topology it was made from (its face and corner counts): whether shapes can go back.
    package var sourceFaces = 0
    package var sourceCorners = 0
    package var sourceVertices = 0
    /// The tree's leaf size: dynamic topology splits a leaf that grows past twice it.
    package var leafTriangles = SculptMesh.leafSize
    /// Dynamic topology's numbering of the vertices and triangles under the brush (all −1 between its calls).
    var scratchVertex: [Int32] = []
    var scratchTriangle: [Int32] = []

    /// Vertex slots (some unused after dynamic topology).
    package var vertexCount: Int { position.count }
    /// Triangle slots (some unused after dynamic topology).
    package var triangleSlots: Int { indices.count / 3 }
    /// The triangles the leaves hold.
    package var triangleCount: Int { leaves.reduce(0) { $0 + Int(nodes[Int($1)].triCount) } }
    package static let leafSize = 1024

    /// The mesh of an object (its faces triangulated, its vertices smooth).
    package convenience init(_ m: EditMesh, leafSize: Int = SculptMesh.leafSize) {
        let (tri, face) = m.triangles()
        var idx = [UInt32](repeating: 0, count: tri.count)
        for i in 0..<tri.count { idx[i] = UInt32(m.cornerVerts[Int(tri[i])]) }
        var fs = [Int32](repeating: 0, count: face.count)
        var hid = [Bool](repeating: false, count: face.count)
        for t in 0..<face.count {
            fs[t] = m.faceSet[Int(face[t])]
            hid[t] = m.isHidden(face: Int(face[t]))
        }
        self.init(positions: m.positions, indices: idx, triangleFace: face, faceSet: fs, hidden: hid,
                  source: (0..<Int32(m.vertexCount)).map { $0 }, leafSize: leafSize)
        sourceFaces = m.faceCount
        sourceCorners = m.cornerCount
        sourceVertices = m.vertexCount
    }

    /// Triangles over positions, laid out by a tree built for them.
    package init(positions: [SIMD3<Float>], masks: [Float]? = nil, indices: [UInt32], triangleFace: [Int32], faceSet: [Int32], hidden: [Bool],
                 source: [Int32], leafSize: Int = SculptMesh.leafSize) {
        let nt = indices.count / 3
        // The tree over the triangles' centroids.
        var centroid = [SIMD3<Float>](repeating: .zero, count: nt)
        for t in 0..<nt {
            centroid[t] = (positions[Int(indices[3 * t])] + positions[Int(indices[3 * t + 1])] + positions[Int(indices[3 * t + 2])]) / 3
        }
        let (built, order) = SculptMesh.buildTree(centroid, leafSize: leafSize)
        // Triangles in the tree's order; vertices numbered as the leaves first use them.
        var newIndex = [Int32](repeating: -1, count: positions.count)
        var pos: [SIMD4<Float>] = []
        pos.reserveCapacity(positions.count)
        var src: [Int32] = []
        src.reserveCapacity(positions.count)
        var own: [Int32] = []
        own.reserveCapacity(positions.count)
        var idx = [UInt32](repeating: 0, count: indices.count)
        var tf = [Int32](repeating: 0, count: nt), fs = [Int32](repeating: 0, count: nt)
        var hid = [Bool](repeating: false, count: nt)
        var nodes = built
        var leaves: [Int32] = []
        for (n, node) in built.enumerated() where node.isLeaf {
            let leaf = Int32(leaves.count)
            leaves.append(Int32(n))
            let vStart = pos.count
            for k in Int(node.triStart)..<Int(node.triStart + node.triCount) {
                let t = Int(order[k])
                for j in 0..<3 {
                    let v = Int(indices[3 * t + j])
                    if newIndex[v] < 0 {
                        newIndex[v] = Int32(pos.count)
                        pos.append(SIMD4(positions[v], masks?[v] ?? 0))
                        src.append(v < source.count ? source[v] : -1)
                        own.append(leaf)
                    }
                    idx[3 * k + j] = UInt32(newIndex[v])
                }
                tf[k] = triangleFace[t]
                fs[k] = faceSet[t]
                hid[k] = hidden[t]
            }
            nodes[n].triCapacity = node.triCount
            nodes[n].vertStart = Int32(vStart)
            nodes[n].vertCount = Int32(pos.count - vStart)
            nodes[n].vertCapacity = nodes[n].vertCount
        }
        // Vertices no triangle uses: kept at the end (owned by no leaf).
        for v in 0..<positions.count where newIndex[v] < 0 {
            newIndex[v] = Int32(pos.count)
            pos.append(SIMD4(positions[v], masks?[v] ?? 0))
            src.append(v < source.count ? source[v] : -1)
            own.append(-1)
        }
        position = pos
        normal = [SIMD4<Float>](repeating: SIMD4(0, 1, 0, 0), count: pos.count)
        self.source = src
        owner = own
        self.indices = idx
        self.triangleFace = tf
        self.faceSet = fs
        self.hidden = hid
        self.nodes = nodes
        self.leaves = leaves
        var leafOf = [Int32](repeating: -1, count: nodes.count)
        for (i, n) in leaves.enumerated() { leafOf[Int(n)] = Int32(i) }
        leafOfNode = leafOf
        leafTriangles = leafSize
        buildAdjacency()
        updateNormals(leaves: leaves.indices.map { $0 })
        updateBoxes(leaves: leaves.indices.map { $0 })
    }

    // MARK: The tree

    /// A tree over centroids: split at the median of the longest axis until a node has `leafSize` or fewer.
    /// Returns the nodes (leaves with their range of `order`) and the order.
    static func buildTree(_ c: [SIMD3<Float>], leafSize: Int) -> (nodes: [SculptNode], order: [Int32]) {
        var order = (0..<Int32(c.count)).map { $0 }
        var nodes: [SculptNode] = []
        nodes.reserveCapacity(2 * (c.count / max(leafSize, 1) + 1))
        guard !c.isEmpty else {
            var leaf = SculptNode()
            leaf.triStart = 0; leaf.triCount = 0
            return ([leaf], order)
        }
        c.withUnsafeBufferPointer { cp in
            order.withUnsafeMutableBufferPointer { op in
                func build(_ start: Int, _ end: Int, parent: Int32) -> Int32 {
                    let me = Int32(nodes.count)
                    var node = SculptNode()
                    node.parent = parent
                    nodes.append(node)
                    if end - start <= leafSize {
                        nodes[Int(me)].triStart = Int32(start)
                        nodes[Int(me)].triCount = Int32(end - start)
                        return me
                    }
                    var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
                    for i in start..<end { let p = cp[Int(op[i])]; lo = simd_min(lo, p); hi = simd_max(hi, p) }
                    let ext = hi - lo
                    let axis = ext.x >= ext.y && ext.x >= ext.z ? 0 : (ext.y >= ext.z ? 1 : 2)
                    let mid = (start + end) / 2
                    SculptMesh.select(op, cp, start, end, mid, axis)
                    let l = build(start, mid, parent: me)
                    let r = build(mid, end, parent: me)
                    nodes[Int(me)].left = l
                    nodes[Int(me)].right = r
                    return me
                }
                _ = build(0, c.count, parent: -1)
            }
        }
        return (nodes, order)
    }

    /// Quickselect: `order[start..<end]` partitioned so the `k`-th by the axis's coordinate is in its place.
    private static func select(_ o: UnsafeMutableBufferPointer<Int32>, _ c: UnsafeBufferPointer<SIMD3<Float>>, _ start: Int, _ end: Int, _ k: Int, _ axis: Int) {
        var lo = start, hi = end - 1
        while lo < hi {
            let pivot = c[Int(o[(lo + hi) / 2])][axis]
            var i = lo, j = hi
            while i <= j {
                while c[Int(o[i])][axis] < pivot { i += 1 }
                while c[Int(o[j])][axis] > pivot { j -= 1 }
                if i <= j { o.swapAt(i, j); i += 1; j -= 1 }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { return }
        }
    }

    /// Leaves' boxes from their triangles and the vertices they own (leaf indices into `leaves`), then their
    /// ancestors'.
    package func updateBoxes(leaves which: some Sequence<Int>) {
        var touched = Set<Int32>()
        position.withUnsafeBufferPointer { p in
            indices.withUnsafeBufferPointer { ix in
                for l in which {
                    let n = Int(leaves[l])
                    var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
                    let start = Int(nodes[n].triStart) * 3, end = start + Int(nodes[n].triCount) * 3
                    for i in start..<end {
                        let q = p[Int(ix[i])]
                        let v = SIMD3(q.x, q.y, q.z)
                        lo = simd_min(lo, v)
                        hi = simd_max(hi, v)
                    }
                    let vs = Int(nodes[n].vertStart)
                    for v in vs..<(vs + Int(nodes[n].vertCount)) {
                        let q = p[v]
                        lo = simd_min(lo, SIMD3(q.x, q.y, q.z))
                        hi = simd_max(hi, SIMD3(q.x, q.y, q.z))
                    }
                    nodes[n].lo = lo
                    nodes[n].hi = hi
                    var parent = nodes[n].parent
                    while parent >= 0 && touched.insert(parent).inserted { parent = nodes[Int(parent)].parent }
                }
            }
        }
        // Parents after children: they come before them in the array.
        for n in touched.sorted(by: >) {
            let l = Int(nodes[Int(n)].left), r = Int(nodes[Int(n)].right)
            nodes[Int(n)].lo = simd_min(nodes[l].lo, nodes[r].lo)
            nodes[Int(n)].hi = simd_max(nodes[l].hi, nodes[r].hi)
        }
    }

    /// The leaves (indices into `leaves`) whose boxes meet a sphere.
    package func leaves(inSphere c: SIMD3<Float>, radius r: Float) -> [Int] {
        var out: [Int] = []
        guard !nodes.isEmpty else { return out }
        var stack: [Int32] = [0]
        let r2 = r * r
        while let n = stack.popLast() {
            let node = nodes[Int(n)]
            let q = simd_clamp(c, node.lo, node.hi)
            if !(simd_length_squared(q - c) <= r2) { continue }
            if node.isLeaf { if leafOfNode[Int(n)] >= 0 { out.append(Int(leafOfNode[Int(n)])) } } else { stack.append(node.left); stack.append(node.right) }
        }
        return out
    }

    /// The nearest triangle a ray hits (object space): its distance along `dir` and the triangle.
    package func raycast(origin o: SIMD3<Float>, direction d: SIMD3<Float>, skipHidden: Bool = true) -> (t: Float, triangle: Int)? {
        guard !nodes.isEmpty else { return nil }
        var safe = d
        for i in 0..<3 where abs(safe[i]) < 1e-20 { safe[i] = 1e-20 }
        let inv = SIMD3<Float>(1, 1, 1) / safe
        var best: (t: Float, triangle: Int)?
        var stack: [Int32] = [0]
        while let n = stack.popLast() {
            let node = nodes[Int(n)]
            let t0 = (node.lo - o) * inv, t1 = (node.hi - o) * inv
            let tmin = simd_reduce_max(simd_min(t0, t1)), tmax = simd_reduce_min(simd_max(t0, t1))
            if tmax < max(tmin, 0) || tmin > (best?.t ?? .infinity) { continue }
            if node.isLeaf {
                for k in Int(node.triStart)..<Int(node.triStart + node.triCount) {
                    if skipHidden && hidden[k] { continue }
                    let a = position[Int(indices[3 * k])], b = position[Int(indices[3 * k + 1])], c = position[Int(indices[3 * k + 2])]
                    if let t = SculptMesh.rayTriangle(o, d, SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z), SIMD3(c.x, c.y, c.z)),
                       t < (best?.t ?? .infinity) {
                        best = (t, k)
                    }
                }
            } else {
                stack.append(node.left)
                stack.append(node.right)
            }
        }
        return best
    }

    @inline(__always) static func rayTriangle(_ o: SIMD3<Float>, _ dir: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float? {
        let e1 = b - a, e2 = c - a
        let p = simd_cross(dir, e2)
        let det = simd_dot(e1, p)
        guard abs(det) > 1e-14 else { return nil }
        let inv = 1 / det
        let s = o - a
        let u = simd_dot(s, p) * inv
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(dir, q) * inv
        guard v >= 0, u + v <= 1 else { return nil }
        let t = simd_dot(e2, q) * inv
        return t > 0 ? t : nil
    }

    // MARK: Adjacency and normals

    /// Each vertex's triangles and neighbours, every leaf's in a region of its own (in vertex order, without room to
    /// spare: dynamic topology moves a region that outgrows itself to the end).
    package func buildAdjacency() {
        let nv = vertexCount
        var count = [Int32](repeating: 0, count: nv)
        for l in leaves {
            let n = nodes[Int(l)]
            for i in (3 * Int(n.triStart))..<(3 * Int(n.triStart + n.triCount)) { count[Int(indices[i])] += 1 }
        }
        var start = [Int32](repeating: 0, count: nv)
        var total: Int32 = 0
        for v in 0..<nv { start[v] = total; total += count[v] }
        var end = start
        var list = [Int32](repeating: 0, count: Int(total))
        for l in leaves {
            let n = nodes[Int(l)]
            for t in Int(n.triStart)..<Int(n.triStart + n.triCount) {
                for j in 0..<3 {
                    let v = Int(indices[3 * t + j])
                    list[Int(end[v])] = Int32(t)
                    end[v] += 1
                }
            }
        }
        vtStart = start
        vtEnd = end
        vtList = list
        // Neighbours: the other corners of each vertex's triangles, without repeats.
        var nStart = [Int32](repeating: 0, count: nv), nEnd = [Int32](repeating: 0, count: nv)
        var nList: [Int32] = []
        nList.reserveCapacity(Int(total) * 2)
        var seen: [Int32] = []
        for v in 0..<nv {
            seen.removeAll(keepingCapacity: true)
            for k in Int(start[v])..<Int(end[v]) {
                let t = Int(list[k])
                for j in 0..<3 {
                    let o = Int32(indices[3 * t + j])
                    if o != Int32(v) && !seen.contains(o) { seen.append(o) }
                }
            }
            nStart[v] = Int32(nList.count)
            nList += seen
            nEnd[v] = Int32(nList.count)
        }
        vnStart = nStart
        vnEnd = nEnd
        vnList = nList
        for l in leaves {
            let n = Int(l), vs = Int(nodes[n].vertStart), ve = vs + Int(nodes[n].vertCount)
            guard ve > vs else { continue }
            nodes[n].vtRegion = start[vs]
            nodes[n].vtCapacity = end[ve - 1] - start[vs]
            nodes[n].vnRegion = nStart[vs]
            nodes[n].vnCapacity = nEnd[ve - 1] - nStart[vs]
        }
    }

    /// The normals of the leaves' vertices (area-weighted, from their triangles wherever those are), in parallel.
    package func updateNormals(leaves which: some Collection<Int>) {
        guard !which.isEmpty else { return }
        let ranges = which.map { (Int(nodes[Int(leaves[$0])].vertStart), Int(nodes[Int(leaves[$0])].vertCount)) }
        position.withUnsafeBufferPointer { p in
            normal.withUnsafeMutableBufferPointer { n in
                indices.withUnsafeBufferPointer { ix in
                    vtStart.withUnsafeBufferPointer { vs in
                        vtEnd.withUnsafeBufferPointer { ve in
                            vtList.withUnsafeBufferPointer { vl in
                                let pp = p.baseAddress!, np = n.baseAddress!, ip = ix.baseAddress!
                                let sp = vs.baseAddress!, ep = ve.baseAddress!, lp = vl.baseAddress!
                                DispatchQueue.concurrentPerform(iterations: ranges.count) { k in
                                    let (start, count) = ranges[k]
                                    sculptVertexNormals(pp, np, ip, sp, ep, lp, start, start + count)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Every vertex's normal (after a change everywhere).
    package func updateAllNormals() {
        updateNormals(leaves: leaves.indices.map { $0 })
        // Vertices outside the leaves (unused): up.
    }

    // MARK: Back to the mesh

    /// Whether the shape can go back into `mesh` vertex for vertex (the topology it was made from is the mesh's).
    package func matches(_ mesh: EditMesh) -> Bool {
        mesh.faceCount == sourceFaces && mesh.cornerCount == sourceCorners && mesh.vertexCount == sourceVertices && !source.contains(-1)
    }

    /// The shape (and face sets) written into the mesh it was made from.
    package func write(into mesh: inout EditMesh) {
        for v in 0..<vertexCount where source[v] >= 0 && Int(source[v]) < mesh.vertexCount {
            let p = position[v]
            mesh.positions[Int(source[v])] = SIMD3(p.x, p.y, p.z)
        }
        for t in 0..<triangleSlots where triangleFace[t] >= 0 && Int(triangleFace[t]) < mesh.faceCount {
            mesh.faceSet[Int(triangleFace[t])] = faceSet[t]
            if hidden[t] { mesh.faceFlags[Int(triangleFace[t])] |= EditMesh.Flag.hide } else { mesh.faceFlags[Int(triangleFace[t])] &= ~EditMesh.Flag.hide }
        }
        mesh.touch()
    }

    /// The masks by the mesh's vertices (what the object keeps between visits to sculpt mode).
    package func masks(count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for v in 0..<vertexCount where source[v] >= 0 && Int(source[v]) < count { out[Int(source[v])] = position[v].w }
        return out
    }

    package func setMasks(_ masks: [Float]) {
        for v in 0..<vertexCount where source[v] >= 0 && Int(source[v]) < masks.count { position[v].w = masks[Int(source[v])] }
    }

    /// The leaves' triangles' corners (without the slots no leaf uses).
    package func liveIndices() -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(triangleCount * 3)
        for l in leaves {
            let n = nodes[Int(l)]
            out += indices[(3 * Int(n.triStart))..<(3 * Int(n.triStart + n.triCount))]
        }
        return out
    }

    /// The triangles as a mesh of their own (after the topology changed): smooth faces with their face sets.
    package func editMesh() -> EditMesh {
        var d = EditMesh.Draft()
        d.positions = position.map { SIMD3($0.x, $0.y, $0.z) }
        d.vertFlags = [UInt8](repeating: 0, count: vertexCount)
        for l in leaves {
            let n = nodes[Int(l)]
            for t in Int(n.triStart)..<Int(n.triStart + n.triCount) {
                d.addFace([Int32(indices[3 * t]), Int32(indices[3 * t + 1]), Int32(indices[3 * t + 2])], set: faceSet[t],
                          flags: EditMesh.Flag.smooth | (hidden[t] ? EditMesh.Flag.hide : 0))
            }
        }
        var m = EditMesh(d)
        m.removeUnusedVertices()
        return m
    }

    package func bumpTopology() { topologyGeneration = EditMesh.nextGeneration() }

    /// The bounds of the whole mesh.
    package var bounds: (lo: SIMD3<Float>, hi: SIMD3<Float>) { nodes.isEmpty ? (.zero, .zero) : (nodes[0].lo, nodes[0].hi) }
}

/// The normals of vertices `start..<end`: the sum of their triangles' area normals, made unit length.
@inline(never)
func sculptVertexNormals(_ p: UnsafePointer<SIMD4<Float>>, _ n: UnsafeMutablePointer<SIMD4<Float>>, _ ix: UnsafePointer<UInt32>,
                         _ vtStart: UnsafePointer<Int32>, _ vtEnd: UnsafePointer<Int32>, _ vtList: UnsafePointer<Int32>,
                         _ start: Int, _ end: Int) {
    var v = start
    while v < end {
        var sum = SIMD3<Float>.zero
        var k = Int(vtStart[v])
        let e = Int(vtEnd[v])
        while k < e {
            let t = Int(vtList[k]) &* 3
            let a = p[Int(ix[t])], b = p[Int(ix[t &+ 1])], c = p[Int(ix[t &+ 2])]
            let ab = SIMD3(b.x - a.x, b.y - a.y, b.z - a.z), ac = SIMD3(c.x - a.x, c.y - a.y, c.z - a.z)
            sum += simd_cross(ab, ac)
            k &+= 1
        }
        let l = simd_length(sum)
        n[v] = l > 1e-30 ? SIMD4(sum / l, 0) : SIMD4(0, 1, 0, 0)
        v &+= 1
    }
}
