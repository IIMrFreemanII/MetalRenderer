import Foundation
import simd

/// What the operations share: regions of faces and their boundaries, the faces round a vertex in order.
extension EditMesh {
    /// The selected faces as a mask.
    package var selectedFaceMask: [Bool] { (0..<faceCount).map { isSelected(face: $0) } }

    /// Faces of `mask` in groups joined by edges (union-find over shared edges).
    package func regions(_ mask: [Bool], topology t: MeshTopology? = nil) -> [[Int]] {
        let t = t ?? MeshTopology(self)
        var parent = Array(0..<faceCount)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for e in 0..<edgeCount {
            let fs = t.faces(ofEdge: e).filter { mask[$0] }
            for k in 1..<max(1, fs.count) {
                let a = find(fs[0]), b = find(fs[k])
                if a != b { parent[a] = b }
            }
        }
        var groups: [Int: [Int]] = [:]
        for f in 0..<faceCount where mask[f] { groups[find(f), default: []].append(f) }
        return groups.values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    /// The boundary of a set of faces as closed loops of directed corners, each running the way its face does (so
    /// the region is on the left, seen from the front): a corner's side is on the boundary when no other face of the
    /// set has that edge. Open chains (a non-manifold boundary) come back as they are.
    package func boundaryLoops(of faces: [Int], topology t: MeshTopology? = nil) -> [[Int]] {
        let t = t ?? MeshTopology(self)
        var inSet = [Bool](repeating: false, count: faceCount)
        for f in faces { inSet[f] = true }
        var from: [Int32: [Int]] = [:]   // start vertex → boundary corners
        for f in faces {
            for c in corners(f) {
                let e = Int(cornerEdges[c])
                let shared = t.faces(ofEdge: e).filter { inSet[$0] }.count
                if shared == 1 { from[cornerVerts[c], default: []].append(c) }
            }
        }
        var used = Set<Int>()
        var loops: [[Int]] = []
        for f in faces {
            for c0 in corners(f) where from[cornerVerts[c0]]?.contains(c0) == true && !used.contains(c0) {
                var loop: [Int] = []
                var c = c0
                while !used.contains(c) {
                    used.insert(c)
                    loop.append(c)
                    let next = cornerVerts[nextCorner(c, face: Int(t.cornerFace[c]))]
                    guard let candidates = from[next], let n = candidates.first(where: { !used.contains($0) }) ?? candidates.first(where: { $0 == c0 }) else { break }
                    c = n
                }
                loops.append(loop)
            }
        }
        return loops
    }

    /// The faces round a vertex in order, as their corners at it: each corner's outgoing edge is the next one's
    /// incoming edge (faces wound the same way turn round the vertex one way). Whether the fan closes; an open one
    /// starts at the boundary. Non-manifold vertices give the first fan found.
    package func fan(_ v: Int, topology t: MeshTopology) -> (corners: [Int], closed: Bool) {
        let cs = t.corners(ofVertex: v).map { Int($0) }
        guard !cs.isEmpty else { return ([], false) }
        func inEdge(_ c: Int) -> Int32 { cornerEdges[prevCorner(c, face: Int(t.cornerFace[c]))] }
        func outEdge(_ c: Int) -> Int32 { cornerEdges[c] }
        func next(_ c: Int) -> Int? { cs.first { $0 != c && inEdge($0) == outEdge(c) } }
        func prev(_ c: Int) -> Int? { cs.first { $0 != c && outEdge($0) == inEdge(c) } }
        var start = cs[0]
        var steps = 0
        while let p = prev(start), p != cs[0], steps < cs.count { start = p; steps += 1 }
        var out = [start]
        var c = start
        while let n = next(c) {
            if n == start { return (out, true) }
            if out.contains(n) || out.count > cs.count { break }
            out.append(n)
            c = n
        }
        return (out, false)
    }

    /// The mean of a set of vertices.
    package func centre(_ verts: some Sequence<Int>) -> SIMD3<Float> {
        var s = SIMD3<Float>.zero, n = 0
        for v in verts { s += positions[v]; n += 1 }
        return n > 0 ? s / Float(n) : .zero
    }

    /// The flags of every edge, by its vertices (to carry over to a draft's new edges by key).
    package func edgeFlagsByKey() -> [UInt64: (flags: UInt8, crease: Float)] {
        var out: [UInt64: (flags: UInt8, crease: Float)] = [:]
        for e in 0..<edgeCount where edgeFlags[e] != 0 || edgeCrease[e] != 0 { out[edgeKey(e)] = (edgeFlags[e], edgeCrease[e]) }
        return out
    }

    /// Selects exactly these vertices (and what they make whole), or these faces.
    package mutating func select(vertices: some Sequence<Int>) {
        for v in 0..<vertexCount { vertFlags[v] &= ~Flag.select }
        for v in vertices where v < vertexCount { vertFlags[v] |= Flag.select }
        flushSelection(from: .vertex)
    }

    package mutating func select(faces: some Sequence<Int>) {
        for f in 0..<faceCount { faceFlags[f] &= ~Flag.select }
        for f in faces where f < faceCount { faceFlags[f] |= Flag.select }
        flushSelection(from: .face)
    }

    package mutating func select(edges: some Sequence<Int>) {
        for e in 0..<edgeCount { edgeFlags[e] &= ~Flag.select }
        for e in edges where e < edgeCount { edgeFlags[e] |= Flag.select }
        flushSelection(from: .edge)
    }
}

extension EditMesh.Draft {
    /// A face's corners as (vertex, UV) pairs.
    package func face(_ f: Int) -> [(v: Int32, uv: SIMD2<Float>)] {
        (Int(faceStart[f])..<Int(faceStart[f + 1])).map { (cornerVerts[$0], cornerUVs[$0]) }
    }

    /// The draft without faces (to build them again).
    package mutating func clearFaces() {
        faceStart = [0]
        cornerVerts = []
        cornerUVs = []
        faceMaterial = []
        faceSet = []
        faceFlags = []
    }

    package mutating func addFace(_ corners: [(v: Int32, uv: SIMD2<Float>)], material: UInt16, set: Int32, flags: UInt8) {
        addFace(corners.map(\.v), uvs: corners.map(\.uv), material: material, set: set, flags: flags)
    }
}
