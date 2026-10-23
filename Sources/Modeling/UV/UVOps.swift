import EngineCore
import Foundation
import Materials
import simd

/// UV unwrapping (U): the faces cut into islands along their seams (Unwrap) or by the way they face (Smart UV
/// Project), each island flattened by the Material Painter's least-squares conformal map (UVUnwrap.flatten) and the
/// islands packed into the square by their outlines (UVPack). UVs are per corner: a seam is where a vertex's corners
/// on its two sides get different ones.
extension EditMesh {
    package enum UnwrapMethod { case seams, smart(angle: Float) }

    /// Unwraps the selected faces (all of them if `onlySelected` is false or none are selected).
    package mutating func unwrap(_ method: UnwrapMethod = .seams, onlySelected: Bool = true, margin: Int = 4) {
        var use = (0..<faceCount).map { !onlySelected || isSelected(face: $0) }
        if !use.contains(true) { use = [Bool](repeating: true, count: faceCount) }
        let t = MeshTopology(self)
        let fn = faceNormals()
        // Where islands part: seams, the mesh's boundary, faces not unwrapped; Smart: also sharp turns between faces.
        var cut = [Bool](repeating: false, count: edgeCount)
        for e in 0..<edgeCount {
            let fs = t.faces(ofEdge: e).filter { use[$0] }
            if fs.count != 2 { cut[e] = true; continue }
            if case .seams = method, edgeFlags[e] & Flag.seam != 0 { cut[e] = true }
        }
        var chart = [Int32](repeating: -1, count: faceCount)
        var charts: [[Int]] = []
        switch method {
        case .seams:
            for f in 0..<faceCount where use[f] && chart[f] < 0 {
                var stack = [f], faces: [Int] = []
                chart[f] = Int32(charts.count)
                while let g = stack.popLast() {
                    faces.append(g)
                    for c in corners(g) where !cut[Int(cornerEdges[c])] {
                        for h in t.faces(ofEdge: Int(cornerEdges[c])) where use[h] && chart[h] < 0 {
                            chart[h] = Int32(charts.count)
                            stack.append(h)
                        }
                    }
                }
                charts.append(faces)
            }
        case .smart(let angle):
            // Grown from the largest faces while they face within the angle of the island's first.
            let order = (0..<faceCount).filter { use[$0] }.sorted { faceArea($0) > faceArea($1) }
            let limit = cos(angle)
            for f in order where chart[f] < 0 {
                let k = Int32(charts.count)
                var stack = [f], faces: [Int] = []
                chart[f] = k
                var mean = fn[f] * faceArea(f)
                while let g = stack.popLast() {
                    faces.append(g)
                    for c in corners(g) where !cut[Int(cornerEdges[c])] {
                        for h in t.faces(ofEdge: Int(cornerEdges[c])) where use[h] && chart[h] < 0 {
                            let m = simd_normalize(mean)
                            guard simd_dot(fn[h], m) >= limit, simd_dot(fn[h], fn[g]) >= limit else { continue }
                            chart[h] = k
                            mean += fn[h] * faceArea(h)
                            stack.append(h)
                        }
                    }
                }
                charts.append(faces)
            }
            for e in 0..<edgeCount where !cut[e] {
                let fs = t.faces(ofEdge: e)
                if fs.count == 2 && chart[fs[0]] != chart[fs[1]] { cut[e] = true }
            }
        }
        guard !charts.isEmpty else { return }
        // Corners that are one UV vertex: the same vertex, joined round it across edges that aren't cut.
        var parent = Array(0..<cornerCount)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for e in 0..<edgeCount where !cut[e] {
            let cs = t.corners(ofEdge: e).map { Int($0) }
            guard cs.count == 2 else { continue }
            let f0 = Int(t.cornerFace[cs[0]]), f1 = Int(t.cornerFace[cs[1]])
            // c0 runs a → b in f0; c1 runs b → a in f1. Join a's corners and b's corners.
            let a0 = cs[0], b0 = nextCorner(cs[0], face: f0), b1 = cs[1], a1 = nextCorner(cs[1], face: f1)
            for (x, y) in [(a0, a1), (b0, b1)] where cornerVerts[x] == cornerVerts[y] {
                let rx = find(x), ry = find(y)
                if rx != ry { parent[rx] = ry }
            }
        }
        // Each island as a triangle mesh of its UV vertices, flattened.
        var flat: [[SIMD2<Float>]] = []
        var islandTriangles: [[(corner: Int, k: Int)]] = []   // per island: for each triangle corner, the mesh corner
        var tri: [Int32] = []
        for faces in charts {
            var local: [Int: Int32] = [:]
            var positions: [SIMD3<Float>] = []
            var indices: [UInt32] = []
            var cornersOf: [(corner: Int, k: Int)] = []
            for f in faces {
                tri.removeAll(keepingCapacity: true)
                triangulate(f, into: &tri)
                for c in tri {
                    let id = find(Int(c))
                    if local[id] == nil {
                        local[id] = Int32(positions.count)
                        positions.append(self.positions[Int(cornerVerts[Int(c)])])
                    }
                    indices.append(UInt32(local[id]!))
                    cornersOf.append((Int(c), cornersOf.count))
                }
            }
            let pm = PaintMesh(positions: positions, normals: [SIMD3<Float>](repeating: [0, 1, 0], count: positions.count), indices: indices)
            let n = pm.triangleCount
            var normal = [SIMD3<Float>](repeating: .zero, count: n), area = [Float](repeating: 0, count: n)
            for k in 0..<n {
                let (a, b, c) = pm.corners(k)
                let cr = simd_cross(pm.positions[b] - pm.positions[a], pm.positions[c] - pm.positions[a])
                area[k] = simd_length(cr) / 2
                if area[k] > 0 { normal[k] = simd_normalize(cr) }
            }
            var scratch = [Int32](repeating: -1, count: positions.count)
            let weld = (0..<Int32(positions.count)).map { $0 }
            var uv = UVUnwrap.flatten(Array(0..<n), pm, weld, normal: normal, area: area, scratch: &scratch)
            if uv == nil {
                // Folded both ways: its projection on its plane.
                var sum = SIMD3<Float>.zero
                for k in 0..<n { sum += normal[k] * area[k] }
                let nrm = simd_length(sum) > 0 ? simd_normalize(sum) : SIMD3<Float>(0, 1, 0)
                let u = simd_normalize(abs(nrm.x) < 0.9 ? simd_cross(nrm, [1, 0, 0]) : simd_cross(nrm, [0, 1, 0])), v = simd_cross(nrm, u)
                uv = indices.map { SIMD2(simd_dot(positions[Int($0)], u), simd_dot(positions[Int($0)], v)) }
            }
            flat.append(UVUnwrap.upright(uv!))
            islandTriangles.append(cornersOf)
        }
        // Packed into the square with a margin between islands.
        let resolution = 1024
        let packed = UVPack.pack(flat, resolution: resolution, padding: margin)
        for (i, uvs) in flat.enumerated() {
            let origin = packed.origins[i], turns = i < packed.turns.count ? packed.turns[i] : 0
            for (j, entry) in islandTriangles[i].enumerated() {
                let p = (origin + UVPack.turn(uvs[j], turns) * packed.scale) / Float(resolution)
                cornerUVs[entry.corner] = p
            }
        }
        touch()
    }

    /// The UVs as lines (each face's sides, in 0…1), for the UV editor's picture.
    package func uvLines(onlySelected: Bool) -> [(SIMD2<Float>, SIMD2<Float>, Bool)] {
        var out: [(SIMD2<Float>, SIMD2<Float>, Bool)] = []
        for f in 0..<faceCount where !onlySelected || isSelected(face: f) {
            let sel = isSelected(face: f)
            for c in corners(f) { out.append((cornerUVs[c], cornerUVs[nextCorner(c, face: f)], sel)) }
        }
        return out
    }
}
