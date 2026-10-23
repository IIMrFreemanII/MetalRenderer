import Foundation
import simd

/// What edit mode selects: vertices, edges or faces (1, 2, 3), as Blender's select modes. Selection lives in the
/// mesh's flags, so it is undone with the mesh.
package enum SelectMode: Int, CaseIterable, Codable {
    case vertex = 1, edge, face
}

extension EditMesh {
    package func isSelected(vertex v: Int) -> Bool { vertFlags[v] & Flag.select != 0 }
    package func isSelected(edge e: Int) -> Bool { edgeFlags[e] & Flag.select != 0 }
    package func isSelected(face f: Int) -> Bool { faceFlags[f] & Flag.select != 0 }
    package func isHidden(vertex v: Int) -> Bool { vertFlags[v] & Flag.hide != 0 }
    package func isHidden(edge e: Int) -> Bool { edgeFlags[e] & Flag.hide != 0 }
    package func isHidden(face f: Int) -> Bool { faceFlags[f] & Flag.hide != 0 }

    package var selectedVertices: [Int] { (0..<vertexCount).filter { isSelected(vertex: $0) } }
    package var selectedEdges: [Int] { (0..<edgeCount).filter { isSelected(edge: $0) } }
    package var selectedFaces: [Int] { (0..<faceCount).filter { isSelected(face: $0) } }
    package var hasSelection: Bool { vertFlags.contains { $0 & Flag.select != 0 } }

    package mutating func setSelected(vertex v: Int, _ on: Bool) {
        if on { vertFlags[v] |= Flag.select } else { vertFlags[v] &= ~Flag.select }
    }
    package mutating func setSelected(edge e: Int, _ on: Bool) {
        if on { edgeFlags[e] |= Flag.select } else { edgeFlags[e] &= ~Flag.select }
    }
    package mutating func setSelected(face f: Int, _ on: Bool) {
        if on { faceFlags[f] |= Flag.select } else { faceFlags[f] &= ~Flag.select }
    }

    /// Everything selected, or nothing (hidden elements stay as they are).
    package mutating func selectAll(_ on: Bool) {
        for v in 0..<vertexCount where !isHidden(vertex: v) { setSelected(vertex: v, on) }
        for e in 0..<edgeCount where !isHidden(edge: e) { setSelected(edge: e, on) }
        for f in 0..<faceCount where !isHidden(face: f) { setSelected(face: f, on) }
        touch()
    }

    /// What was selected isn't, and what wasn't is (Ctrl-I), in the select mode's elements.
    package mutating func invertSelection(mode: SelectMode) {
        switch mode {
        case .vertex:
            for v in 0..<vertexCount where !isHidden(vertex: v) { setSelected(vertex: v, !isSelected(vertex: v)) }
        case .edge:
            for e in 0..<edgeCount where !isHidden(edge: e) { setSelected(edge: e, !isSelected(edge: e)) }
        case .face:
            for f in 0..<faceCount where !isHidden(face: f) { setSelected(face: f, !isSelected(face: f)) }
        }
        flushSelection(from: mode)
    }

    /// The other elements' selection made from the mode's (as Blender flushes it): from vertices, an edge is selected
    /// when both its ends are and a face when all its corners are; from edges, the vertices of selected edges and the
    /// faces all of whose edges are; from faces, their edges and vertices.
    package mutating func flushSelection(from mode: SelectMode) {
        deselectHidden()
        switch mode {
        case .vertex:
            for e in 0..<edgeCount { setSelected(edge: e, isSelected(vertex: Int(edges[e].x)) && isSelected(vertex: Int(edges[e].y))) }
            for f in 0..<faceCount { setSelected(face: f, corners(f).allSatisfy { isSelected(vertex: Int(cornerVerts[$0])) }) }
        case .edge:
            for v in 0..<vertexCount { setSelected(vertex: v, false) }
            for e in 0..<edgeCount where isSelected(edge: e) {
                setSelected(vertex: Int(edges[e].x), true)
                setSelected(vertex: Int(edges[e].y), true)
            }
            for f in 0..<faceCount { setSelected(face: f, corners(f).allSatisfy { isSelected(edge: Int(cornerEdges[$0])) }) }
        case .face:
            for v in 0..<vertexCount { setSelected(vertex: v, false) }
            for e in 0..<edgeCount { setSelected(edge: e, false) }
            for f in 0..<faceCount where isSelected(face: f) {
                for c in corners(f) {
                    setSelected(vertex: Int(cornerVerts[c]), true)
                    setSelected(edge: Int(cornerEdges[c]), true)
                }
            }
        }
        deselectHidden()
        touch()
    }

    /// Hidden elements are never selected.
    private mutating func deselectHidden() {
        for v in 0..<vertexCount where isHidden(vertex: v) { setSelected(vertex: v, false) }
        for e in 0..<edgeCount where isHidden(edge: e) { setSelected(edge: e, false) }
        for f in 0..<faceCount where isHidden(face: f) { setSelected(face: f, false) }
    }

    /// The selection when the mode changes: going to a coarser mode keeps what is wholly selected; to a finer one,
    /// the selected elements' parts.
    package mutating func convertSelection(from old: SelectMode, to new: SelectMode) {
        guard old != new else { return }
        flushSelection(from: old)
        flushSelection(from: new)
    }

    /// The selected vertices' centre (the median, as Blender's pivot), nil without a selection.
    package func selectionCentre() -> SIMD3<Float>? {
        var sum = SIMD3<Float>.zero, n = 0
        for v in 0..<vertexCount where isSelected(vertex: v) { sum += positions[v]; n += 1 }
        return n > 0 ? sum / Float(n) : nil
    }

    // MARK: Hide

    /// Hide the selection (H) or what isn't selected (Shift-H).
    package mutating func hide(selected: Bool, mode: SelectMode) {
        switch mode {
        case .face:
            for f in 0..<faceCount where isSelected(face: f) == selected && !isHidden(face: f) { faceFlags[f] |= Flag.hide }
        case .edge:
            for e in 0..<edgeCount where isSelected(edge: e) == selected { edgeFlags[e] |= Flag.hide }
            for f in 0..<faceCount where corners(f).contains(where: { isHidden(edge: Int(cornerEdges[$0])) }) { faceFlags[f] |= Flag.hide }
        case .vertex:
            for v in 0..<vertexCount where isSelected(vertex: v) == selected { vertFlags[v] |= Flag.hide }
            for f in 0..<faceCount where corners(f).contains(where: { isHidden(vertex: Int(cornerVerts[$0])) }) { faceFlags[f] |= Flag.hide }
        }
        // Edges and vertices whose faces are all hidden are hidden; ones of hidden edges too.
        let t = MeshTopology(self)
        for e in 0..<edgeCount {
            let fs = t.faces(ofEdge: e)
            if !fs.isEmpty && fs.allSatisfy({ isHidden(face: $0) }) { edgeFlags[e] |= Flag.hide }
            if isHidden(vertex: Int(edges[e].x)) || isHidden(vertex: Int(edges[e].y)) { edgeFlags[e] |= Flag.hide }
        }
        for v in 0..<vertexCount {
            let es = t.edges(ofVertex: v)
            if !es.isEmpty && es.allSatisfy({ isHidden(edge: Int($0)) }) { vertFlags[v] |= Flag.hide }
        }
        flushSelection(from: mode)
    }

    /// Show what is hidden, selected (Alt-H).
    package mutating func reveal() {
        for v in 0..<vertexCount where isHidden(vertex: v) { vertFlags[v] = (vertFlags[v] & ~Flag.hide) | Flag.select }
        for e in 0..<edgeCount where isHidden(edge: e) { edgeFlags[e] = (edgeFlags[e] & ~Flag.hide) | Flag.select }
        for f in 0..<faceCount where isHidden(face: f) { faceFlags[f] = (faceFlags[f] & ~Flag.hide) | Flag.select }
        touch()
    }

    // MARK: Linked, more and less

    /// Everything joined to the selection (Ctrl-L), or to one element (L under the cursor), across edges that aren't
    /// seams if `delimitSeams`.
    package mutating func selectLinked(fromVertices start: [Int]? = nil, delimitSeams: Bool = false, mode: SelectMode) {
        let t = MeshTopology(self)
        var seen = [Bool](repeating: false, count: vertexCount)
        var stack = start ?? selectedVertices
        for v in stack { seen[v] = true }
        while let v = stack.popLast() {
            for e in t.edges(ofVertex: v) where !isHidden(edge: Int(e)) {
                if delimitSeams && edgeFlags[Int(e)] & Flag.seam != 0 { continue }
                let o = Int(MeshTopology.other(self, edge: Int(e), from: Int32(v)))
                if !seen[o] { seen[o] = true; stack.append(o) }
            }
        }
        for v in 0..<vertexCount where seen[v] { setSelected(vertex: v, true) }
        flushSelection(from: .vertex)
    }

    /// Grow the selection by one ring of neighbours (Ctrl-+), or shrink it (Ctrl--).
    package mutating func growSelection(_ grow: Bool, mode: SelectMode) {
        let t = MeshTopology(self)
        let was = (0..<vertexCount).map { isSelected(vertex: $0) }
        for v in 0..<vertexCount where !isHidden(vertex: v) {
            if grow {
                if was[v] { continue }
                // A neighbour across a face (Blender grows by faces).
                for c in t.corners(ofVertex: v) {
                    let f = Int(t.cornerFace[Int(c)])
                    if corners(f).contains(where: { was[Int(cornerVerts[$0])] }) { setSelected(vertex: v, true); break }
                }
            } else if was[v] {
                for c in t.corners(ofVertex: v) {
                    let f = Int(t.cornerFace[Int(c)])
                    if corners(f).contains(where: { !was[Int(cornerVerts[$0])] }) { setSelected(vertex: v, false); break }
                }
            }
        }
        flushSelection(from: .vertex)
        if mode == .face {
            // Keep faces only (flushSelection from vertices may have picked faces whose vertices all happen to be in).
            flushSelection(from: .face)
        }
    }
}
