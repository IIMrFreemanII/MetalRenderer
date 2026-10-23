import Foundation
import simd

/// What a stroke changed, to undo it: each leaf's vertices (positions and masks) and triangles' face sets and hidden
/// flags as they were before the stroke first touched it. Swapping puts either state back, so one record undoes and
/// redoes. A stroke with dynamic topology keeps its leaves' whole room instead (`layout`).
package final class SculptUndoRecord {
    package var positions: [Int: [SIMD4<Float>]] = [:]
    package var faceSets: [Int: [Int32]] = [:]
    package var hidden: [Int: [Bool]] = [:]
    /// A whole mesh (remesh, multires level, a packing before dynamic topology): the arrays before.
    package var whole: SculptMesh.Snapshot?
    /// Dynamic topology's: the leaves it changed, as they were.
    package var layout: SculptLayoutUndo?
    package let topology: UInt64

    package init(topology: UInt64) { self.topology = topology }

    package var isEmpty: Bool { positions.isEmpty && faceSets.isEmpty && hidden.isEmpty && whole == nil && layout == nil }

    /// From here on the stroke may change the topology: its leaves are saved whole.
    package func beginLayout(_ m: SculptMesh) { layout = SculptLayoutUndo(m) }

    /// A leaf about to change (dynamic topology's edits).
    func touch(leaf l: Int, of m: SculptMesh) { layout?.touch(l, of: m) }

    /// Saves a leaf's state if this record hasn't yet.
    @inline(__always) package func save(leaf l: Int, of m: SculptMesh, faceSets withSets: Bool = false) {
        if whole != nil { return }
        if let layout { layout.touch(l, of: m); return }
        let node = m.nodes[Int(m.leaves[l])]
        if positions[l] == nil {
            let s = Int(node.vertStart), e = s + Int(node.vertCount)
            positions[l] = Array(m.position[s..<e])
        }
        if withSets && faceSets[l] == nil {
            let s = Int(node.triStart), e = s + Int(node.triCount)
            faceSets[l] = Array(m.faceSet[s..<e])
            hidden[l] = Array(m.hidden[s..<e])
        }
    }

    /// Puts the saved state back, keeping what was there for the way back. Returns the leaves it changed.
    @discardableResult
    package func swap(into m: SculptMesh) -> [Int] {
        if let w = whole {
            whole = m.snapshot()
            m.restore(w)
            return m.leaves.indices.map { $0 }
        }
        if let layout {
            layout.swap(into: m)
            return m.leaves.indices.map { $0 }
        }
        for (l, saved) in positions {
            let node = m.nodes[Int(m.leaves[l])]
            let s = Int(node.vertStart)
            let now = Array(m.position[s..<(s + saved.count)])
            m.position.replaceSubrange(s..<(s + saved.count), with: saved)
            positions[l] = now
        }
        for (l, saved) in faceSets {
            let node = m.nodes[Int(m.leaves[l])]
            let s = Int(node.triStart)
            let now = Array(m.faceSet[s..<(s + saved.count)])
            m.faceSet.replaceSubrange(s..<(s + saved.count), with: saved)
            faceSets[l] = now
        }
        for (l, saved) in hidden {
            let node = m.nodes[Int(m.leaves[l])]
            let s = Int(node.triStart)
            let now = Array(m.hidden[s..<(s + saved.count)])
            m.hidden.replaceSubrange(s..<(s + saved.count), with: saved)
            hidden[l] = now
        }
        let changed = Array(Set(positions.keys).union(faceSets.keys))
        m.updateNormals(leaves: changed)
        m.updateBoxes(leaves: changed)
        return changed
    }
}

extension SculptMesh {
    /// Every array, for an undo step that changes the topology.
    package struct Snapshot {
        var position: [SIMD4<Float>], normal: [SIMD4<Float>], source: [Int32], owner: [Int32], indices: [UInt32], triangleFace: [Int32]
        var faceSet: [Int32], hidden: [Bool], vtStart: [Int32], vtEnd: [Int32], vtList: [Int32], vnStart: [Int32], vnEnd: [Int32], vnList: [Int32]
        var nodes: [SculptNode], leaves: [Int32], leafOfNode: [Int32]
        var sourceFaces: Int, sourceCorners: Int, sourceVertices: Int, leafTriangles: Int
    }

    package func snapshot() -> Snapshot {
        Snapshot(position: position, normal: normal, source: source, owner: owner, indices: indices, triangleFace: triangleFace,
                 faceSet: faceSet, hidden: hidden, vtStart: vtStart, vtEnd: vtEnd, vtList: vtList, vnStart: vnStart, vnEnd: vnEnd,
                 vnList: vnList, nodes: nodes, leaves: leaves, leafOfNode: leafOfNode, sourceFaces: sourceFaces,
                 sourceCorners: sourceCorners, sourceVertices: sourceVertices, leafTriangles: leafTriangles)
    }

    package func restore(_ s: Snapshot) {
        position = s.position; normal = s.normal; source = s.source; owner = s.owner; indices = s.indices; triangleFace = s.triangleFace
        faceSet = s.faceSet; hidden = s.hidden; vtStart = s.vtStart; vtEnd = s.vtEnd; vtList = s.vtList
        vnStart = s.vnStart; vnEnd = s.vnEnd; vnList = s.vnList
        nodes = s.nodes; leaves = s.leaves; leafOfNode = s.leafOfNode
        sourceFaces = s.sourceFaces; sourceCorners = s.sourceCorners; sourceVertices = s.sourceVertices; leafTriangles = s.leafTriangles
        scratchVertex = []; scratchTriangle = []
        bumpTopology()
    }

    /// Takes another mesh's arrays (a remesh, a new multires level), as one undoable change.
    package func replace(with other: SculptMesh) {
        restore(other.snapshot())
    }
}

/// A stroke of a brush: dabs along the mouse's path, `spacing` of the radius apart, each mirrored by the brush's
/// symmetry; the leaves it touched (for the viewport and the undo record).
package final class SculptStroke {
    package let mesh: SculptMesh
    package let brush: SculptBrush
    package let record: SculptUndoRecord
    /// Leaves changed since the viewport last took them.
    package var dirty = Set<Int>()
    private let falloff: [Float]
    private let smoothFalloff: [Float]
    private var scratch: [SIMD4<Float>] = []
    private var lastDab: SIMD3<Float>?
    private var travelled: Float = 0
    // Grab: the vertices under the brush when the stroke began, per mirror.
    private var grabbed: [(verts: [Int32], weights: [Float], start: [SIMD4<Float>], mirror: SIMD3<Float>)] = []
    private var grabOrigin: SIMD3<Float>?
    private let faceSetValue: Int32

    package init(mesh: SculptMesh, brush: SculptBrush) {
        self.mesh = mesh
        self.brush = brush
        record = SculptUndoRecord(topology: mesh.topologyGeneration)
        falloff = sculptFalloffTable(brush.falloff)
        smoothFalloff = sculptFalloffTable(.smooth)
        faceSetValue = brush.faceSet != 0 ? brush.faceSet : (mesh.faceSet.max() ?? 0) + 1
    }

    /// The mirrors the brush applies (+1 / −1 per axis), the plain one first.
    package var mirrors: [SIMD3<Float>] {
        var out: [SIMD3<Float>] = [SIMD3(1, 1, 1)]
        for axis in 0..<3 where brush.symmetry[axis] {
            out += out.map { var m = $0; m[axis] = -1; return m }
        }
        return out
    }

    /// The stroke moved to `point` (object space, on the surface): dabs every `spacing` along the way. `radius` in
    /// object space; `strength` already signed and scaled by pressure; `smooth` makes this stroke the smooth brush
    /// (Shift).
    package func move(to point: SIMD3<Float>, radius: Float, strength: Float, smooth: Bool = false) {
        if brush.kind == .grab && !smooth { grab(to: point, radius: radius); return }
        guard let last = lastDab else {
            lastDab = point
            dab(at: point, radius: radius, strength: strength, smooth: smooth)
            return
        }
        let step = max(radius * brush.spacing, 1e-6)
        var from = last
        var d = simd_distance(from, point)
        while d >= step {
            from = from + (point - from) * (step / d)
            dab(at: from, radius: radius, strength: strength, smooth: smooth)
            d = simd_distance(from, point)
        }
        lastDab = from
    }

    /// One dab and its mirrors.
    package func dab(at c: SIMD3<Float>, radius r: Float, strength s: Float, smooth: Bool = false) {
        for m in mirrors { dabOnce(at: c * m, radius: r, strength: s, smooth: smooth, mirror: m) }
        if brush.autosmooth > 0 && !smooth && brush.kind != .mask && brush.kind != .drawFaceSets {
            for m in mirrors { dabOnce(at: c * m, radius: r, strength: brush.autosmooth, smooth: true, mirror: m) }
        }
    }

    private func dabOnce(at c: SIMD3<Float>, radius r: Float, strength s: Float, smooth: Bool, mirror: SIMD3<Float>) {
        let m = mesh
        let touched = m.leaves(inSphere: c, radius: r)
        guard !touched.isEmpty else { return }
        let kind = smooth ? SculptBrushKind.smooth : brush.kind
        for l in touched { record.save(leaf: l, of: m, faceSets: kind == .drawFaceSets) }
        if kind == .drawFaceSets {
            paintFaceSets(touched, c, r)
            for l in touched { dirty.insert(l) }
            return
        }
        let ranges = touched.map { (Int(m.nodes[Int(m.leaves[$0])].vertStart), Int(m.nodes[Int(m.leaves[$0])].vertCount)) }
        // The area under the brush: its normal and centre.
        var nsum = SIMD3<Float>.zero, csum = SIMD3<Float>.zero, wsum: Float = 0
        m.position.withUnsafeBufferPointer { p in
            m.normal.withUnsafeBufferPointer { n in
                for (start, count) in ranges {
                    let a = sculptAreaSums(p.baseAddress!, n.baseAddress!, start, start + count, c, r)
                    nsum += a.normal; csum += a.centre; wsum += a.weight
                }
            }
        }
        guard wsum > 0 else { return }
        let areaNormal = simd_length(nsum) > 1e-20 ? simd_normalize(nsum) : SIMD3<Float>(0, 1, 0)
        let dab = SculptDab(center: c, radius: r, normal: areaNormal, planeCenter: csum / wsum, strength: s, kind: kind.code)
        let table = kind == .smooth ? smoothFalloff : falloff
        if kind == .smooth {
            if scratch.count != m.vertexCount { scratch = [SIMD4<Float>](repeating: .zero, count: m.vertexCount) }
            m.position.withUnsafeMutableBufferPointer { p in
                scratch.withUnsafeMutableBufferPointer { t in
                    m.vnStart.withUnsafeBufferPointer { vs in
                        m.vnEnd.withUnsafeBufferPointer { ve in
                            m.vnList.withUnsafeBufferPointer { vl in
                                table.withUnsafeBufferPointer { f in
                                    let pp = p.baseAddress!, tp = t.baseAddress!, sp = vs.baseAddress!, ep = ve.baseAddress!
                                    let lp = vl.baseAddress!, fp = f.baseAddress!
                                    DispatchQueue.concurrentPerform(iterations: ranges.count) { k in
                                        let (start, count) = ranges[k]
                                        sculptSmoothTargets(UnsafePointer(pp), tp, sp, ep, lp, start, start + count, dab, fp)
                                    }
                                    DispatchQueue.concurrentPerform(iterations: ranges.count) { k in
                                        let (start, count) = ranges[k]
                                        sculptCopyRange(UnsafePointer(tp), pp, start, start + count)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            m.position.withUnsafeMutableBufferPointer { p in
                m.normal.withUnsafeBufferPointer { n in
                    table.withUnsafeBufferPointer { f in
                        let pp = p.baseAddress!, np = n.baseAddress!, fp = f.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: ranges.count) { k in
                            let (start, count) = ranges[k]
                            sculptDabKernel(pp, np, start, start + count, dab, fp)
                        }
                    }
                }
            }
        }
        // Normals and boxes round the dab (neighbours' normals change with it).
        let around = kind == .mask ? touched : m.leaves(inSphere: c, radius: r * 1.25)
        if kind != .mask {
            m.updateNormals(leaves: around)
            m.updateBoxes(leaves: touched)
        }
        for l in around { dirty.insert(l) }
        _ = mirror
    }

    private func paintFaceSets(_ touched: [Int], _ c: SIMD3<Float>, _ r: Float) {
        let m = mesh
        let r2 = r * r
        for l in touched {
            let node = m.nodes[Int(m.leaves[l])]
            for t in Int(node.triStart)..<Int(node.triStart + node.triCount) where !m.hidden[t] {
                let a = m.position[Int(m.indices[3 * t])], b = m.position[Int(m.indices[3 * t + 1])], cc = m.position[Int(m.indices[3 * t + 2])]
                let centre = SIMD3((a.x + b.x + cc.x) / 3, (a.y + b.y + cc.y) / 3, (a.z + b.z + cc.z) / 3)
                if simd_length_squared(centre - c) < r2 { m.faceSet[t] = brush.subtract ? 0 : faceSetValue }
            }
        }
    }

    // MARK: Grab

    /// Grab: the vertices under the brush where the stroke began follow the mouse (each mirror its mirrored way).
    private func grab(to point: SIMD3<Float>, radius r: Float) {
        let m = mesh
        guard let origin = grabOrigin else {
            grabOrigin = point
            for mirror in mirrors {
                let c = point * mirror
                var verts: [Int32] = [], weights: [Float] = [], start: [SIMD4<Float>] = []
                for l in m.leaves(inSphere: c, radius: r) {
                    record.save(leaf: l, of: m)
                    let node = m.nodes[Int(m.leaves[l])]
                    for v in Int(node.vertStart)..<Int(node.vertStart + node.vertCount) {
                        let q = m.position[v]
                        let d = simd_distance(SIMD3(q.x, q.y, q.z), c)
                        guard d < r else { continue }
                        let w = falloff[min(255, Int(d / r * 255))] * (1 - q.w) * brush.strength
                        guard w > 0 else { continue }
                        verts.append(Int32(v)); weights.append(w); start.append(q)
                    }
                }
                grabbed.append((verts, weights, start, mirror))
            }
            return
        }
        let delta = point - origin
        var touchedLeaves = Set<Int>()
        for g in grabbed {
            let d = delta * g.mirror
            for i in 0..<g.verts.count {
                let s = g.start[i]
                m.position[Int(g.verts[i])] = SIMD4(SIMD3(s.x, s.y, s.z) + d * g.weights[i], s.w)
            }
            for l in m.leaves(inSphere: (origin + delta) * g.mirror, radius: r * 1.5) { touchedLeaves.insert(l) }
            for l in m.leaves(inSphere: origin * g.mirror, radius: r * 1.5) { touchedLeaves.insert(l) }
        }
        let list = Array(touchedLeaves)
        m.updateNormals(leaves: list)
        m.updateBoxes(leaves: list)
        for l in list { dirty.insert(l) }
    }

    /// Where the grab began (it moves the vertices in the view's plane through it).
    package var grabStart: SIMD3<Float>? { grabOrigin }
}

// MARK: - Mask and face set operations

extension SculptMesh {
    /// Clear (0), fill (1) or invert the mask everywhere.
    package func setMask(_ op: (Float) -> Float, record: SculptUndoRecord) {
        for l in leaves.indices { record.save(leaf: l, of: self) }
        for v in 0..<vertexCount { position[v].w = max(0, min(1, op(position[v].w))) }
    }

    /// Grow or shrink the mask by one ring of neighbours.
    package func growMask(_ grow: Bool, record: SculptUndoRecord) {
        for l in leaves.indices { record.save(leaf: l, of: self) }
        let old = position.map(\.w)
        for v in 0..<vertexCount {
            var m = old[v]
            for k in Int(vnStart[v])..<Int(vnEnd[v]) {
                let o = old[Int(vnList[k])]
                m = grow ? max(m, o) : min(m, o)
            }
            position[v].w = m
        }
    }

    /// Hide every face set but the one under `triangle` (H), or show all (Alt-H). Returns whether anything changed.
    @discardableResult
    package func isolateFaceSet(of triangle: Int?, record: SculptUndoRecord) -> Bool {
        for l in leaves.indices { record.save(leaf: l, of: self, faceSets: true) }
        if let t = triangle {
            let set = faceSet[t]
            for i in 0..<triangleSlots { hidden[i] = faceSet[i] != set }
        } else {
            for i in 0..<triangleSlots { hidden[i] = false }
        }
        return true
    }

    /// A face set per loose part (Face Sets › Initialize by Loose Parts), or from the mask (masked: a new set).
    package func faceSetsFromMask(record: SculptUndoRecord) {
        for l in leaves.indices { record.save(leaf: l, of: self, faceSets: true) }
        let new = (faceSet.max() ?? 0) + 1
        for t in 0..<triangleSlots {
            let w = (position[Int(indices[3 * t])].w + position[Int(indices[3 * t + 1])].w + position[Int(indices[3 * t + 2])].w) / 3
            if w > 0.5 { faceSet[t] = new }
        }
    }

    package func faceSetsByLooseParts(record: SculptUndoRecord) {
        for l in leaves.indices { record.save(leaf: l, of: self, faceSets: true) }
        var part = [Int32](repeating: -1, count: vertexCount)
        var next: Int32 = 1
        for v in 0..<vertexCount where part[v] < 0 {
            var stack = [v]
            part[v] = next
            while let x = stack.popLast() {
                for k in Int(vnStart[x])..<Int(vnEnd[x]) {
                    let o = Int(vnList[k])
                    if part[o] < 0 { part[o] = next; stack.append(o) }
                }
            }
            next += 1
        }
        for t in 0..<triangleSlots { faceSet[t] = part[Int(indices[3 * t])] }
    }
}

/// A face set's colour in the viewport (RGBA8, as ViewVertex takes it): a pastel from its id, none for 0.
package func faceSetColor(_ id: Int32) -> UInt32 {
    guard id > 0 else { return 0 }
    var h = UInt32(bitPattern: id) &* 2654435761
    h ^= h >> 13
    h &*= 0x5bd1e995
    let r = 120 + (h & 127), g = 120 + ((h >> 8) & 127), b = 120 + ((h >> 16) & 127)
    return r | g << 8 | b << 16 | 0xFF00_0000
}
