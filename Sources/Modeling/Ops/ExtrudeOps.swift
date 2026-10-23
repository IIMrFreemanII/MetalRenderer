import Foundation
import simd

/// E, Alt-E and I: extruding the selection (a region of faces, edges, or vertices) and insetting faces. Each makes the
/// new geometry from the mesh as it is; the editor then moves it (extrude: along the region's normal) or sizes it
/// (inset: with the mouse), making it again from the mesh before the operation for each new value.
extension EditMesh {
    /// Extrude (E): the selected faces as regions, each lifted off with side faces round its boundary; without
    /// faces, the selected edges with a face each; without those, the selected vertices with an edge each. The new
    /// geometry is selected. Returns the direction to move it along (the regions' mean normal; zero for edges and
    /// vertices: they move freely).
    @discardableResult
    package mutating func extrude(individual: Bool = false) -> SIMD3<Float> {
        let sel = selectedFaceMask
        if sel.contains(true) { return extrudeFaces(individual ? (0..<faceCount).filter { sel[$0] }.map { [$0] } : regions(sel)) }
        if (0..<edgeCount).contains(where: { isSelected(edge: $0) }) { extrudeEdges(); return .zero }
        if hasSelection { extrudeVertices() }
        return .zero
    }

    private mutating func extrudeFaces(_ groups: [[Int]]) -> SIMD3<Float> {
        let t = MeshTopology(self)
        var d = draft()
        d.clearFaces()
        for v in 0..<vertexCount { d.vertFlags[v] &= ~Flag.select }
        var inGroup = [Int](repeating: -1, count: faceCount)
        for (g, faces) in groups.enumerated() { for f in faces { inGroup[f] = g } }
        var normal = SIMD3<Float>.zero
        var moved: [[Int32]] = []   // per group: vertex → its copy
        var sides: [(f: Int, corners: [(v: Int32, uv: SIMD2<Float>)])] = []
        var keepFlipped: [Int] = []
        for faces in groups {
            var dup = [Int32: Int32]()
            for f in faces {
                normal += faceNormal(f) * faceArea(f)
                for c in corners(f) where dup[cornerVerts[c]] == nil {
                    dup[cornerVerts[c]] = d.addVertex(positions[Int(cornerVerts[c])], flags: Flag.select)
                }
            }
            let loops = boundaryLoops(of: faces, topology: t)
            if loops.isEmpty { keepFlipped += faces }   // a closed region: the original stays, turned inside out
            for loop in loops {
                for c in loop {
                    let f = Int(t.cornerFace[c]), n = nextCorner(c, face: f)
                    let a = cornerVerts[c], b = cornerVerts[n]
                    sides.append((f, [(a, cornerUVs[c]), (b, cornerUVs[n]), (dup[b]!, cornerUVs[n]), (dup[a]!, cornerUVs[c])]))
                }
            }
            var map = [Int32](repeating: -1, count: vertexCount)
            for (k, v) in dup { map[Int(k)] = v }
            moved.append(map)
        }
        for f in 0..<faceCount {
            let g = inGroup[f]
            let flags = faceFlags[f] & ~Flag.select
            if g < 0 {
                d.addFace(faceVerts(f), uvs: Array(cornerUVs[corners(f)]), material: faceMaterial[f], set: faceSet[f], flags: flags)
            } else {
                let map = moved[g]
                d.addFace(corners(f).map { map[Int(cornerVerts[$0])] }, uvs: Array(cornerUVs[corners(f)]), material: faceMaterial[f],
                          set: faceSet[f], flags: flags | Flag.select)
            }
        }
        for f in keepFlipped {
            d.addFace(faceVerts(f).reversed(), uvs: cornerUVs[corners(f)].reversed(), material: faceMaterial[f], set: faceSet[f],
                      flags: faceFlags[f] & ~Flag.select)
        }
        for s in sides { d.addFace(s.corners, material: faceMaterial[s.f], set: faceSet[s.f], flags: faceFlags[s.f] & ~Flag.select) }
        var mesh = EditMesh(d)
        mesh.flushSelection(from: .face)
        mesh.removeUnusedVertices(used: looseVertexMask(of: self, count: mesh.vertexCount))
        self = mesh
        let l = simd_length(normal)
        return l > 0 ? normal / l : .zero
    }

    /// Each selected edge with a face to its copy (the face turned to agree with the edge's face, if it has one).
    private mutating func extrudeEdges() {
        let t = MeshTopology(self)
        var d = draft()
        for v in 0..<vertexCount { d.vertFlags[v] &= ~Flag.select }
        for f in 0..<d.faceCount { d.faceFlags[f] &= ~Flag.select }
        var dup = [Int32: Int32]()
        func copy(_ v: Int32) -> Int32 {
            if let c = dup[v] { return c }
            let c = d.addVertex(positions[Int(v)], flags: Flag.select)
            dup[v] = c
            return c
        }
        for e in 0..<edgeCount where isSelected(edge: e) {
            var a = edges[e].x, b = edges[e].y
            // A face has a → b: the new one goes b → a along it.
            if let c = t.corners(ofEdge: e).first {
                let f = Int(t.cornerFace[Int(c)])
                a = cornerVerts[Int(c)]
                b = cornerVerts[nextCorner(Int(c), face: f)]
                d.addFace([b, a, copy(a), copy(b)], material: faceMaterial[f], set: faceSet[f])
            } else {
                d.addFace([a, b, copy(b), copy(a)])
            }
        }
        // Lone selected vertices: an edge each.
        for v in 0..<vertexCount where isSelected(vertex: v) && dup[Int32(v)] == nil {
            if t.edges(ofVertex: v).contains(where: { isSelected(edge: Int($0)) }) { continue }
            d.looseEdges.append(SIMD2(Int32(v), copy(Int32(v))))
        }
        var mesh = EditMesh(d)
        mesh.flushSelection(from: .vertex)
        self = mesh
    }

    /// Each selected vertex with an edge to its copy.
    private mutating func extrudeVertices() {
        var d = draft()
        for v in 0..<vertexCount where isSelected(vertex: v) {
            d.vertFlags[v] &= ~Flag.select
            let c = d.addVertex(positions[v], flags: Flag.select)
            d.looseEdges.append(SIMD2(Int32(v), c))
        }
        var mesh = EditMesh(d)
        mesh.flushSelection(from: .vertex)
        self = mesh
    }

    /// Inset (I): the selected faces shrunk into their own outline by `thickness`, a ring of faces round them, and
    /// lifted by `depth`; each face alone if `individual`. Even thickness: corners move further where the outline turns.
    package mutating func inset(thickness: Float, depth: Float = 0, individual: Bool = false) {
        let sel = selectedFaceMask
        guard sel.contains(true) else { return }
        let groups = individual ? (0..<faceCount).filter { sel[$0] }.map { [$0] } : regions(sel)
        let t = MeshTopology(self)
        let fn = faceNormals()
        var d = draft()
        d.clearFaces()
        var inGroup = [Int](repeating: -1, count: faceCount)
        for (g, faces) in groups.enumerated() { for f in faces { inGroup[f] = g } }
        var maps: [[Int32: Int32]] = []
        var rings: [(f: Int, corners: [(v: Int32, uv: SIMD2<Float>)])] = []
        for faces in groups {
            var normal = SIMD3<Float>.zero
            for f in faces { normal += fn[f] * faceArea(f) }
            normal = simd_length(normal) > 0 ? simd_normalize(normal) : .zero
            var map = [Int32: Int32]()
            // Interior vertices move with the depth.
            for f in faces { for c in corners(f) where map[cornerVerts[c]] == nil { map[cornerVerts[c]] = cornerVerts[c] } }
            let loops = boundaryLoops(of: faces, topology: t)
            var boundary = Set<Int32>()
            for loop in loops {
                let n = loop.count
                for i in 0..<n {
                    let c = loop[i], cp = loop[(i + n - 1) % n]
                    let fc = Int(t.cornerFace[c]), fp = Int(t.cornerFace[cp])
                    let v = cornerVerts[c]
                    let p = positions[Int(v)]
                    let next = positions[Int(cornerVerts[nextCorner(c, face: fc)])]
                    let prev = positions[Int(cornerVerts[cp])]
                    let dn = simd_normalize(next - p), dp = simd_normalize(p - prev)
                    let nn = simd_normalize(simd_cross(fn[fc], dn)), np = simd_normalize(simd_cross(fn[fp], dp))
                    var m = nn + np
                    m = simd_length(m) > 1e-6 ? simd_normalize(m) : nn
                    let scale = 1 / max(simd_dot(m, nn), 0.25)
                    let q = p + m * thickness * scale + normal * depth
                    if !boundary.contains(v) {
                        map[v] = d.addVertex(q, flags: Flag.select)
                        boundary.insert(v)
                    }
                }
                for c in loop {
                    let f = Int(t.cornerFace[c]), nx = nextCorner(c, face: f)
                    let a = cornerVerts[c], b = cornerVerts[nx]
                    rings.append((f, [(a, cornerUVs[c]), (b, cornerUVs[nx]), (map[b]!, cornerUVs[nx]), (map[a]!, cornerUVs[c])]))
                }
            }
            // Interior vertices: lifted.
            if depth != 0 {
                for (v, m) in map where m == v && !boundary.contains(v) { d.positions[Int(v)] = positions[Int(v)] + normal * depth }
            }
            maps.append(map)
        }
        for v in 0..<vertexCount { d.vertFlags[v] &= ~Flag.select }
        for f in 0..<faceCount {
            let g = inGroup[f]
            if g < 0 {
                d.addFace(faceVerts(f), uvs: Array(cornerUVs[corners(f)]), material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f] & ~Flag.select)
            } else {
                d.addFace(corners(f).map { maps[g][cornerVerts[$0]]! }, uvs: Array(cornerUVs[corners(f)]), material: faceMaterial[f],
                          set: faceSet[f], flags: faceFlags[f] | Flag.select)
            }
        }
        for r in rings { d.addFace(r.corners, material: faceMaterial[r.f], set: faceSet[r.f], flags: faceFlags[r.f] & ~Flag.select) }
        var mesh = EditMesh(d)
        mesh.flushSelection(from: .face)
        self = mesh
    }
}

/// Vertices of `old` that had no edge (loose vertices stay through a clean-up), as a mask over `count` vertices.
func looseVertexMask(of old: EditMesh, count: Int) -> [Bool] {
    var used = [Bool](repeating: true, count: old.vertexCount)
    for e in old.edges { used[Int(e.x)] = false; used[Int(e.y)] = false }
    for v in old.cornerVerts { used[Int(v)] = false }
    return (0..<count).map { $0 < used.count ? used[$0] : false }
}
