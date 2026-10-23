import Foundation
import simd

/// What a mesh's arrays don't say directly, as CSR tables (`start[i]..<start[i + 1]` of `items`): each vertex's
/// faces (as corners: the corner says the face and where in it) and edges, each edge's faces (as corners whose side it
/// is). Made in one pass each, for a mesh as it is; an operation that changes the mesh makes them again.
package struct MeshTopology {
    package var vertCornerStart: [Int32]
    package var vertCorners: [Int32]
    package var vertEdgeStart: [Int32]
    package var vertEdges: [Int32]
    package var edgeCornerStart: [Int32]
    package var edgeCorners: [Int32]
    /// The face each corner is in.
    package var cornerFace: [Int32]
    package let generation: UInt64

    package init(_ m: EditMesh) {
        generation = m.generation
        let nv = m.vertexCount, ne = m.edgeCount, nc = m.cornerCount
        cornerFace = [Int32](repeating: 0, count: nc)
        for f in 0..<m.faceCount { for c in m.corners(f) { cornerFace[c] = Int32(f) } }
        func csr(_ count: Int, _ n: Int, _ keyOf: (Int) -> Int) -> (start: [Int32], items: [Int32]) {
            var start = [Int32](repeating: 0, count: count + 1)
            for i in 0..<n { start[keyOf(i) + 1] += 1 }
            for i in 0..<count { start[i + 1] += start[i] }
            var fill = start
            var items = [Int32](repeating: 0, count: n)
            for i in 0..<n {
                let k = keyOf(i)
                items[Int(fill[k])] = Int32(i)
                fill[k] += 1
            }
            return (start, items)
        }
        (vertCornerStart, vertCorners) = csr(nv, nc) { Int(m.cornerVerts[$0]) }
        (edgeCornerStart, edgeCorners) = csr(ne, nc) { Int(m.cornerEdges[$0]) }
        // Each edge twice, once per end.
        var start = [Int32](repeating: 0, count: nv + 1)
        for e in m.edges { start[Int(e.x) + 1] += 1; start[Int(e.y) + 1] += 1 }
        for i in 0..<nv { start[i + 1] += start[i] }
        var fill = start
        var items = [Int32](repeating: 0, count: 2 * ne)
        for (i, e) in m.edges.enumerated() {
            items[Int(fill[Int(e.x)])] = Int32(i); fill[Int(e.x)] += 1
            items[Int(fill[Int(e.y)])] = Int32(i); fill[Int(e.y)] += 1
        }
        vertEdgeStart = start
        vertEdges = items
    }

    @inline(__always) package func corners(ofVertex v: Int) -> ArraySlice<Int32> {
        vertCorners[Int(vertCornerStart[v])..<Int(vertCornerStart[v + 1])]
    }
    @inline(__always) package func edges(ofVertex v: Int) -> ArraySlice<Int32> {
        vertEdges[Int(vertEdgeStart[v])..<Int(vertEdgeStart[v + 1])]
    }
    @inline(__always) package func corners(ofEdge e: Int) -> ArraySlice<Int32> {
        edgeCorners[Int(edgeCornerStart[e])..<Int(edgeCornerStart[e + 1])]
    }
    package func faces(ofEdge e: Int) -> [Int] { corners(ofEdge: e).map { Int(cornerFace[Int($0)]) } }
    package func faces(ofVertex v: Int) -> [Int] { corners(ofVertex: v).map { Int(cornerFace[Int($0)]) } }
    @inline(__always) package func faceCount(ofEdge e: Int) -> Int { Int(edgeCornerStart[e + 1] - edgeCornerStart[e]) }

    /// An edge with one face: the mesh's boundary.
    package func isBoundary(_ e: Int) -> Bool { faceCount(ofEdge: e) == 1 }

    /// The edge between two vertices, if there is one.
    package func edge(_ m: EditMesh, _ a: Int32, _ b: Int32) -> Int? {
        for e in edges(ofVertex: Int(a)) where m.edges[Int(e)].x == b || m.edges[Int(e)].y == b { return Int(e) }
        return nil
    }

    /// The edge's other end.
    @inline(__always) package static func other(_ m: EditMesh, edge e: Int, from v: Int32) -> Int32 {
        m.edges[e].x == v ? m.edges[e].y : m.edges[e].x
    }
}

// MARK: - Checks

extension EditMesh {
    /// What is wrong with the mesh's arrays, if anything (nil: nothing): what the tests and a debug build check after
    /// each operation.
    package func validate() -> String? {
        if faceStart.first != 0 || faceStart.last != Int32(cornerVerts.count) { return "face ranges don't cover the corners" }
        for f in 0..<faceCount where faceSize(f) < 3 { return "face \(f) has \(faceSize(f)) corners" }
        if cornerUVs.count != cornerVerts.count || cornerEdges.count != cornerVerts.count { return "corner arrays differ in length" }
        if faceMaterial.count != faceCount || faceSet.count != faceCount || faceFlags.count != faceCount { return "face arrays differ in length" }
        if vertFlags.count != positions.count { return "vertex flags differ in length" }
        if edgeFlags.count != edges.count || edgeCrease.count != edges.count { return "edge arrays differ in length" }
        for v in cornerVerts where v < 0 || Int(v) >= positions.count { return "a corner's vertex \(v) is out of range" }
        var keys = Set<UInt64>()
        for (i, e) in edges.enumerated() {
            if e.x >= e.y || e.x < 0 || Int(e.y) >= positions.count { return "edge \(i) is \(e)" }
            if !keys.insert(edgeKey(i)).inserted { return "edge \(i) repeats another" }
        }
        for f in 0..<faceCount {
            for c in corners(f) {
                let e = cornerEdges[c]
                guard e >= 0 && Int(e) < edges.count else { return "corner \(c) has no edge" }
                let n = nextCorner(c, face: f)
                if edgeKey(Int(e)) != EditMesh.key(cornerVerts[c], cornerVerts[n]) { return "corner \(c)'s edge is not its side" }
            }
            var seen = Set<Int32>()
            for c in corners(f) where !seen.insert(cornerVerts[c]).inserted { return "face \(f) repeats vertex \(cornerVerts[c])" }
        }
        for p in positions where !(p.x.isFinite && p.y.isFinite && p.z.isFinite) { return "a position is not finite" }
        return nil
    }

    /// V − E + F.
    package var eulerCharacteristic: Int { vertexCount - edgeCount + faceCount }

    /// Every edge has exactly two faces, and they go along it opposite ways.
    package func isClosedManifold() -> Bool {
        let t = MeshTopology(self)
        for e in 0..<edgeCount {
            let cs = t.corners(ofEdge: e)
            guard cs.count == 2 else { return false }
            let a = Int(cs[cs.startIndex]), b = Int(cs[cs.startIndex + 1])
            if cornerVerts[a] == cornerVerts[b] { return false }   // same direction: the faces disagree on front
        }
        return true
    }
}
