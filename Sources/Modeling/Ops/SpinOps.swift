import Foundation
import simd

/// Spin: the selection extruded `steps` times round an axis through a centre, `angle` in all (a lathe). Selected
/// faces are swept as regions (their boundary makes the walls, the faces end up at the last step, and a region on its
/// own leaves a cap where it started); selected edges sweep into walls; lone selected vertices into edges. A full turn
/// closes on itself: the last step is the first (and a region's two caps go). What the last step has is selected.
extension EditMesh {
    package mutating func spin(steps: Int, angle: Float, centre: SIMD3<Float>, axis: SIMD3<Float>) {
        guard steps >= 1, abs(angle) > 1e-6, simd_length(axis) > 1e-9, hasSelection else { return }
        let axis = simd_normalize(axis)
        let full = abs(abs(angle) - 2 * .pi) < 1e-4
        let t = MeshTopology(self)
        let faceSel = selectedFaceMask.enumerated().map { $1 && !isHidden(face: $0) }
        let regions = regions(faceSel, topology: t)
        // The vertices that sweep: the selected ones (and the regions').
        let moving = (0..<vertexCount).filter { isSelected(vertex: $0) && !isHidden(vertex: $0) }
        guard !moving.isEmpty else { return }
        var d = draft()
        d.clearFaces()
        for v in 0..<vertexCount { d.vertFlags[v] &= ~Flag.select }
        // copy[k][v]: vertex v at step k (0: itself; a full turn's last step is step 0).
        var copy = [[Int32]](repeating: [], count: steps + 1)
        copy[0] = (0..<Int32(vertexCount)).map { $0 }
        for k in 1...steps {
            if full && k == steps { copy[k] = copy[0]; continue }
            let q = simd_quatf(angle: angle * Float(k) / Float(steps), axis: axis)
            var map = copy[0]
            // (A vertex on the axis stays one vertex: the faces round it close to a point.)
            for v in moving {
                let r = positions[v] - centre
                if simd_length(r - axis * simd_dot(r, axis)) > 1e-6 { map[v] = d.addVertex(q.act(r) + centre) }
            }
            copy[k] = map
        }
        let last = copy[steps]
        // Walls: each selected edge on a region's boundary, or not in a region at all, once a step.
        var inRegion = [Bool](repeating: false, count: faceCount)
        for r in regions { for f in r { inRegion[f] = true } }
        var walls: [(a: Int32, b: Int32, face: Int?)] = []   // a → b as the face beside it runs (nil: none)
        var wallEdges = Set<Int>()
        for r in regions {
            for loop in boundaryLoops(of: r, topology: t) {
                for c in loop {
                    let f = Int(t.cornerFace[c])
                    walls.append((cornerVerts[c], cornerVerts[nextCorner(c, face: f)], f))
                    wallEdges.insert(Int(cornerEdges[c]))
                }
            }
        }
        for e in 0..<edgeCount where isSelected(edge: e) && !isHidden(edge: e) && !wallEdges.contains(e) {
            if t.faces(ofEdge: e).contains(where: { inRegion[$0] }) { continue }   // inside a region
            let a = edges[e].x, b = edges[e].y
            // Against the face beside it, if it has one: a face running a → b means the wall runs b → a at the start.
            if let c = t.corners(ofEdge: e).first {
                let f = Int(t.cornerFace[Int(c)])
                walls.append((cornerVerts[Int(c)], cornerVerts[nextCorner(Int(c), face: f)], f))
            } else {
                walls.append((a, b, nil))
            }
            wallEdges.insert(e)
        }
        // Inside out when the sweep goes against the regions' normal (a region's faces end up facing back); loose
        // walls face away from the axis.
        var flipRegions = false
        if !regions.isEmpty {
            var n = SIMD3<Float>.zero, c = SIMD3<Float>.zero, w: Float = 0
            for r in regions { for f in r { n += faceNormal(f) * faceArea(f); c += faceCenter(f) * faceArea(f); w += faceArea(f) } }
            let sweep = simd_cross(axis, c / max(w, 1e-12) - centre) * (angle > 0 ? 1 : -1)
            flipRegions = simd_dot(n, sweep) < 0
        }
        func wallFace(_ w: (a: Int32, b: Int32, face: Int?), _ k: Int) -> [Int32] {
            let a0 = copy[k - 1][Int(w.a)], b0 = copy[k - 1][Int(w.b)], a1 = copy[k][Int(w.a)], b1 = copy[k][Int(w.b)]
            return [a0, b0, b1, a1]
        }
        var looseFlip: Bool?
        for w in walls {
            let material = w.face.map { faceMaterial[$0] } ?? 0, set = w.face.map { faceSet[$0] } ?? 0
            let flags = (w.face.map { faceFlags[$0] } ?? 0) & ~(Flag.select | Flag.hide)
            // A region's boundary: as extrude's walls (the region moves on); an edge beside an unselected face: the
            // other way (the face stays); a loose edge: facing away from the axis.
            var flip: Bool
            if let f = w.face, inRegion[f] { flip = flipRegions } else if w.face != nil { flip = true } else {
                if looseFlip == nil {
                    let quad = wallFace(w, 1).map { d.positions[Int($0)] }
                    // (Newell's normal: right for a wall that closes to a point on the axis too.)
                    let n = (0..<4).reduce(SIMD3<Float>.zero) { $0 + simd_cross(quad[$1], quad[($1 + 1) % 4]) }
                    let mid = quad.reduce(.zero, +) / 4
                    let out = mid - centre - axis * simd_dot(mid - centre, axis)
                    looseFlip = simd_dot(n, out) < 0
                }
                flip = looseFlip!
            }
            for k in 1...steps {
                let q = wallFace(w, k)
                d.addFace(flip ? q.reversed() : q, material: material, set: set, flags: flags)
            }
        }
        // Lone vertices (no selected edge): an edge a step.
        var onEdge = [Bool](repeating: false, count: vertexCount)
        for e in wallEdges { onEdge[Int(edges[e].x)] = true; onEdge[Int(edges[e].y)] = true }
        for r in regions { for f in r { for c in corners(f) { onEdge[Int(cornerVerts[c])] = true } } }
        for v in moving where !onEdge[v] {
            for k in 1...steps { d.looseEdges.append(SIMD2(copy[k - 1][v], copy[k][v])) }
        }
        // The faces: those outside the regions as they were; a region's at the last step (none after a full turn),
        // and a cap where it started when nothing else holds its boundary.
        for f in 0..<faceCount where !inRegion[f] {
            d.addFace(faceVerts(f), uvs: Array(cornerUVs[corners(f)]), material: faceMaterial[f], set: faceSet[f], flags: faceFlags[f] & ~Flag.select)
        }
        for r in regions {
            let alone = boundaryLoops(of: r, topology: t).allSatisfy { loop in loop.allSatisfy { t.faceCount(ofEdge: Int(cornerEdges[$0])) == 1 } }
            for f in r {
                let uvs = Array(cornerUVs[corners(f)])
                let moved = corners(f).map { last[Int(cornerVerts[$0])] }
                if full && alone { continue }
                d.addFace(flipRegions ? moved.reversed() : moved, uvs: flipRegions ? uvs.reversed() : uvs, material: faceMaterial[f],
                          set: faceSet[f], flags: (faceFlags[f] & ~Flag.select) | Flag.select)
                if alone {
                    let start = faceVerts(f)
                    d.addFace(flipRegions ? start : start.reversed(), uvs: flipRegions ? uvs : uvs.reversed(), material: faceMaterial[f],
                              set: faceSet[f], flags: faceFlags[f] & ~Flag.select)
                }
            }
        }
        for v in moving { d.vertFlags[Int(last[v])] |= Flag.select }
        var mesh = EditMesh(d)
        mesh.flushSelection(from: regions.isEmpty ? .vertex : .face)
        self = mesh
    }
}
