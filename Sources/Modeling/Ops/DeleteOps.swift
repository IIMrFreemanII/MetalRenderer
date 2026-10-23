import Foundation
import simd

/// X / Delete in edit mode: what goes, as Blender's Delete menu; and Dissolve, which merges what is round the selection.
package enum DeleteKind: String, CaseIterable {
    case vertices, edges, faces, onlyEdgesAndFaces, onlyFaces
    package var title: String {
        switch self {
        case .vertices: "Vertices"
        case .edges: "Edges"
        case .faces: "Faces"
        case .onlyEdgesAndFaces: "Only Edges & Faces"
        case .onlyFaces: "Only Faces"
        }
    }
}

extension EditMesh {
    /// Deletes the selection's elements of `kind` and what depends on them.
    package mutating func delete(_ kind: DeleteKind) {
        let t = MeshTopology(self)
        var d = draft()
        let wasLoose = (0..<vertexCount).map { t.edges(ofVertex: $0).isEmpty }
        var keepFace = [Bool](repeating: true, count: faceCount)
        var keepEdge = [Bool](repeating: true, count: edgeCount)
        var keepVertex = [Bool](repeating: true, count: vertexCount)
        switch kind {
        case .vertices:
            for v in 0..<vertexCount where isSelected(vertex: v) { keepVertex[v] = false }
            for e in 0..<edgeCount where !keepVertex[Int(edges[e].x)] || !keepVertex[Int(edges[e].y)] { keepEdge[e] = false }
            for f in 0..<faceCount where corners(f).contains(where: { !keepVertex[Int(cornerVerts[$0])] }) { keepFace[f] = false }
        case .edges, .onlyEdgesAndFaces:
            for e in 0..<edgeCount where isSelected(edge: e) { keepEdge[e] = false }
            for f in 0..<faceCount where corners(f).contains(where: { !keepEdge[Int(cornerEdges[$0])] }) { keepFace[f] = false }
        case .faces, .onlyFaces:
            for f in 0..<faceCount where isSelected(face: f) { keepFace[f] = false }
            if kind == .faces {
                // Edges and vertices only the deleted faces had go with them.
                for e in 0..<edgeCount {
                    let fs = t.faces(ofEdge: e)
                    if !fs.isEmpty && fs.allSatisfy({ !keepFace[$0] }) { keepEdge[e] = false }
                }
            }
        }
        // Faces kept; edges of removed faces that stay become loose.
        d.clearFaces()
        for f in 0..<faceCount where keepFace[f] {
            d.addFace(faceVerts(f), uvs: Array(cornerUVs[corners(f)]), material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f])
        }
        d.looseEdges = (0..<edgeCount).filter { e in keepEdge[e] && t.faces(ofEdge: e).allSatisfy { !keepFace[$0] } }.map { edges[$0] }
        var mesh = EditMesh(d)
        // Vertices: the deleted ones, and ones left with nothing that weren't loose before (onlyEdgesAndFaces keeps them).
        var used = [Bool](repeating: false, count: vertexCount)
        for v in 0..<vertexCount {
            used[v] = keepVertex[v] && (wasLoose[v] || kind == .onlyEdgesAndFaces || kind == .onlyFaces)
        }
        mesh.removeUnusedVertices(used: used)
        mesh.selectAll(false)
        self = mesh
    }

    /// Dissolve (Ctrl-X and the Delete menu's dissolves): the faces round the selection merged into one, the
    /// selected vertices, edges or faces taken out from between them.
    package mutating func dissolve(_ mode: SelectMode) {
        let t = MeshTopology(self)
        // Faces that become one, by union-find over the edges being taken out.
        var parent = Array(0..<faceCount)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        var removedEdge = [Bool](repeating: false, count: edgeCount)
        switch mode {
        case .vertex:
            for v in 0..<vertexCount where isSelected(vertex: v) { for e in t.edges(ofVertex: v) { removedEdge[Int(e)] = true } }
        case .edge:
            for e in 0..<edgeCount where isSelected(edge: e) { removedEdge[e] = true }
        case .face:
            for e in 0..<edgeCount where t.faces(ofEdge: e).count == 2 && t.faces(ofEdge: e).allSatisfy({ isSelected(face: $0) }) {
                removedEdge[e] = true
            }
        }
        // Only edges between two faces can be dissolved (a boundary edge stays).
        for e in 0..<edgeCount where removedEdge[e] {
            let fs = t.faces(ofEdge: e)
            if fs.count == 2 {
                let a = find(fs[0]), b = find(fs[1])
                if a != b { parent[a] = b }
            } else { removedEdge[e] = false }
        }
        var groups: [Int: [Int]] = [:]
        for f in 0..<faceCount { groups[find(f), default: []].append(f) }
        var d = draft()
        d.clearFaces()
        var outFaces: [(Int, [(v: Int32, uv: SIMD2<Float>)])] = []
        for (_, faces) in groups {
            if faces.count == 1 {
                let f = faces[0]
                outFaces.append((f, corners(f).map { (cornerVerts[$0], cornerUVs[$0]) }))
                continue
            }
            let loops = boundaryLoops(of: faces, topology: t)
            if loops.count == 1 {
                var loop = loops[0].map { (v: cornerVerts[$0], uv: cornerUVs[$0]) }
                // Vertex dissolve: the selected vertices that are now in the middle of a side go too.
                if mode == .vertex {
                    let kept = loop.filter { !isSelected(vertex: Int($0.v)) }
                    if kept.count >= 3 { loop = kept }
                }
                if loop.count >= 3 { outFaces.append((faces.min()!, loop)); continue }
            }
            // A ring (a hole) can't be one face: leave the faces as they were.
            for f in faces { outFaces.append((f, corners(f).map { (cornerVerts[$0], cornerUVs[$0]) })) }
        }
        outFaces.sort { $0.0 < $1.0 }
        for (f, loop) in outFaces { d.addFace(loop, material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f] & ~Flag.select) }
        var mesh = EditMesh(d)
        // Vertices dissolved away (inside a merged face), and two-edge vertices of a dissolved edge chain.
        mesh.removeUnusedVertices(used: (0..<vertexCount).map { !isSelected(vertex: $0) && t.edges(ofVertex: $0).isEmpty })
        mesh.selectAll(false)
        self = mesh
    }
}
