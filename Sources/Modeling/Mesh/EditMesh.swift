import EngineCore
import Foundation
import simd

/// The modeller's mesh: polygons of any size over shared vertices, laid out as Blender's `Mesh` is (not its BMesh):
/// flat arrays, a face a range of corners (`faceStart[f]..<faceStart[f + 1]`), a corner a vertex, the edge to the next
/// corner, and a UV. Edges are what the faces' sides make, plus loose (wire) edges; each carries its flags (seam,
/// sharp, selected) and crease. An operation builds its result as a `Draft` and makes the mesh from it again: the
/// edges, the corners' edges and the flags of every edge that is still there come back by their two vertices, so no
/// operation keeps edge indices in step by hand.
///
/// A value type: an edit-mode undo step is a copy (the arrays are copied on write, so one costs only what the edit
/// changed). `generation` is new after every change, from one counter for the process, so two copies that went
/// different ways never share one (caches of what a mesh derives are filed under it).
package struct EditMesh {
    // Vertices.
    package var positions: [SIMD3<Float>] = []
    package var vertFlags: [UInt8] = []
    // Edges: v0 < v1.
    package var edges: [SIMD2<Int32>] = []
    package var edgeFlags: [UInt8] = []
    package var edgeCrease: [Float] = []
    // Faces and their corners.
    package var faceStart: [Int32] = [0]
    package var cornerVerts: [Int32] = []
    package var cornerEdges: [Int32] = []
    package var cornerUVs: [SIMD2<Float>] = []
    package var faceMaterial: [UInt16] = []
    package var faceSet: [Int32] = []
    package var faceFlags: [UInt8] = []

    package private(set) var generation: UInt64 = EditMesh.nextGeneration()

    package var vertexCount: Int { positions.count }
    package var edgeCount: Int { edges.count }
    package var faceCount: Int { faceStart.count - 1 }
    package var cornerCount: Int { cornerVerts.count }

    /// Flags, one bit each. Vertices, edges and faces: `select`, `hide`; edges: `seam`, `sharp`; faces: `smooth`.
    package enum Flag {
        package static let select: UInt8 = 1
        package static let hide: UInt8 = 2
        package static let seam: UInt8 = 4
        package static let sharp: UInt8 = 8
        package static let smooth: UInt8 = 4
    }

    package init() {}

    /// A mesh of these polygons (each a list of vertex indices, in order round its front, counter-clockwise seen from
    /// it), smooth shaded unless `smooth` is false; UVs per corner if given (else zeros).
    package init(positions: [SIMD3<Float>], faces: [[Int32]], uvs: [[SIMD2<Float>]]? = nil, smooth: Bool = false) {
        var draft = Draft()
        draft.positions = positions
        draft.vertFlags = [UInt8](repeating: 0, count: positions.count)
        for (f, face) in faces.enumerated() {
            draft.addFace(face, uvs: uvs?[f], flags: smooth ? Flag.smooth : 0)
        }
        self.init(draft)
    }

    // MARK: Faces

    @inline(__always) package func corners(_ f: Int) -> Range<Int> { Int(faceStart[f])..<Int(faceStart[f + 1]) }
    @inline(__always) package func faceSize(_ f: Int) -> Int { Int(faceStart[f + 1] - faceStart[f]) }
    package func faceVerts(_ f: Int) -> [Int32] { Array(cornerVerts[corners(f)]) }

    /// The corner after `c` round its face (the last's is the first).
    @inline(__always) package func nextCorner(_ c: Int, face f: Int) -> Int {
        c + 1 < Int(faceStart[f + 1]) ? c + 1 : Int(faceStart[f])
    }
    @inline(__always) package func prevCorner(_ c: Int, face f: Int) -> Int {
        c > Int(faceStart[f]) ? c - 1 : Int(faceStart[f + 1]) - 1
    }

    /// A face's normal (Newell's: right for any polygon that doesn't fold), not normalised to length 1 if it is
    /// degenerate (zero).
    package func faceNormal(_ f: Int) -> SIMD3<Float> {
        var n = SIMD3<Float>.zero
        let r = corners(f)
        var prev = positions[Int(cornerVerts[r.upperBound - 1])]
        for c in r {
            let p = positions[Int(cornerVerts[c])]
            n += SIMD3((prev.y - p.y) * (prev.z + p.z), (prev.z - p.z) * (prev.x + p.x), (prev.x - p.x) * (prev.y + p.y))
            prev = p
        }
        let l = simd_length(n)
        return l > 0 ? n / l : .zero
    }

    package func faceCenter(_ f: Int) -> SIMD3<Float> {
        var c = SIMD3<Float>.zero
        for k in corners(f) { c += positions[Int(cornerVerts[k])] }
        return c / Float(faceSize(f))
    }

    package func faceArea(_ f: Int) -> Float {
        var n = SIMD3<Float>.zero
        let r = corners(f)
        let o = positions[Int(cornerVerts[r.lowerBound])]
        for c in (r.lowerBound + 1)..<(r.upperBound - 1) {
            n += simd_cross(positions[Int(cornerVerts[c])] - o, positions[Int(cornerVerts[c + 1])] - o)
        }
        return simd_length(n) / 2
    }

    // MARK: Edges

    @inline(__always) package static func key(_ a: Int32, _ b: Int32) -> UInt64 {
        a < b ? UInt64(UInt32(a)) << 32 | UInt64(UInt32(b)) : UInt64(UInt32(b)) << 32 | UInt64(UInt32(a))
    }

    package func edgeKey(_ e: Int) -> UInt64 { EditMesh.key(edges[e].x, edges[e].y) }

    package func edgeLength(_ e: Int) -> Float {
        simd_distance(positions[Int(edges[e].x)], positions[Int(edges[e].y)])
    }

    // MARK: Bounds

    package var bounds: AABB {
        var b = AABB()
        for p in positions { b.grow(p) }
        return b
    }

    // MARK: Changes

    /// Called after changing the arrays in place (positions, flags): the mesh is new to caches.
    package mutating func touch() { generation = EditMesh.nextGeneration() }

    private static let counter = GenerationCounter()
    package static func nextGeneration() -> UInt64 { counter.next() }
}

/// One process-wide counter: every mesh change takes the next number.
private final class GenerationCounter: @unchecked Sendable {
    private var value: UInt64 = 0
    private let lock = NSLock()
    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

// MARK: - Drafts

extension EditMesh {
    /// A mesh being made: vertices, faces, loose edges, and the flags and creases of edges by their two vertices.
    /// `EditMesh(draft)` makes the edges from the faces and the loose ones, and gives each the flags filed under it.
    package struct Draft {
        package var positions: [SIMD3<Float>] = []
        package var vertFlags: [UInt8] = []
        package var faceStart: [Int32] = [0]
        package var cornerVerts: [Int32] = []
        package var cornerUVs: [SIMD2<Float>] = []
        package var faceMaterial: [UInt16] = []
        package var faceSet: [Int32] = []
        package var faceFlags: [UInt8] = []
        /// Edges no face has (wire edges): kept as edges.
        package var looseEdges: [SIMD2<Int32>] = []
        /// Flags and crease of edges by `EditMesh.key`: an edge gets those filed under its vertices.
        package var edgeAttributes: [UInt64: (flags: UInt8, crease: Float)] = [:]

        package init() {}

        package var faceCount: Int { faceStart.count - 1 }

        @discardableResult
        package mutating func addVertex(_ p: SIMD3<Float>, flags: UInt8 = 0) -> Int32 {
            positions.append(p)
            vertFlags.append(flags)
            return Int32(positions.count - 1)
        }

        package mutating func addFace(_ verts: [Int32], uvs: [SIMD2<Float>]? = nil, material: UInt16 = 0, set: Int32 = 0, flags: UInt8 = 0) {
            precondition(verts.count >= 3, "a face has three corners or more")
            cornerVerts += verts
            if let uvs { cornerUVs += uvs } else { cornerUVs += [SIMD2<Float>](repeating: .zero, count: verts.count) }
            faceStart.append(Int32(cornerVerts.count))
            faceMaterial.append(material)
            faceSet.append(set)
            faceFlags.append(flags)
        }

        package func faceVerts(_ f: Int) -> ArraySlice<Int32> { cornerVerts[Int(faceStart[f])..<Int(faceStart[f + 1])] }
    }

    /// The mesh as a draft: everything it has, its edges' flags filed by their vertices, its loose edges.
    package func draft() -> Draft {
        var d = Draft()
        d.positions = positions
        d.vertFlags = vertFlags
        d.faceStart = faceStart
        d.cornerVerts = cornerVerts
        d.cornerUVs = cornerUVs
        d.faceMaterial = faceMaterial
        d.faceSet = faceSet
        d.faceFlags = faceFlags
        d.edgeAttributes.reserveCapacity(edges.count)
        var used = [Bool](repeating: false, count: edges.count)
        for e in cornerEdges { used[Int(e)] = true }
        for e in 0..<edges.count {
            if edgeFlags[e] != 0 || edgeCrease[e] != 0 { d.edgeAttributes[edgeKey(e)] = (edgeFlags[e], edgeCrease[e]) }
            if !used[e] { d.looseEdges.append(edges[e]) }
        }
        return d
    }

    /// The mesh a draft describes. Faces with a repeated vertex next to itself lose the repeat (a face left with fewer
    /// than three corners goes); loose edges that a face has, or that join a vertex to itself, go.
    package init(_ d: Draft) {
        positions = d.positions
        vertFlags = d.vertFlags.count == d.positions.count ? d.vertFlags : [UInt8](repeating: 0, count: d.positions.count)
        // Faces, without corners that repeat the one before.
        faceStart = [0]
        faceStart.reserveCapacity(d.faceCount + 1)
        cornerVerts.reserveCapacity(d.cornerVerts.count)
        cornerUVs.reserveCapacity(d.cornerVerts.count)
        var loop: [(v: Int32, uv: SIMD2<Float>)] = []
        for f in 0..<d.faceCount {
            let r = Int(d.faceStart[f])..<Int(d.faceStart[f + 1])
            loop.removeAll(keepingCapacity: true)
            for c in r {
                let v = d.cornerVerts[c]
                if let last = loop.last, last.v == v { continue }
                loop.append((v, c < d.cornerUVs.count ? d.cornerUVs[c] : .zero))
            }
            while loop.count > 1 && loop[loop.count - 1].v == loop[0].v { loop.removeLast() }
            // A vertex the face passes twice (a merge made a bow tie): the face is two, split there.
            for part in EditMesh.splitAtRepeats(loop) where part.count >= 3 {
                for (v, uv) in part { cornerVerts.append(v); cornerUVs.append(uv) }
                faceStart.append(Int32(cornerVerts.count))
                faceMaterial.append(f < d.faceMaterial.count ? d.faceMaterial[f] : 0)
                faceSet.append(f < d.faceSet.count ? d.faceSet[f] : 0)
                faceFlags.append(f < d.faceFlags.count ? d.faceFlags[f] : 0)
            }
        }
        // Edges: every corner's side, and the loose ones, sorted by key; equal keys are one edge.
        let corners = cornerVerts.count
        var keyed: [(key: UInt64, corner: Int32)] = []
        keyed.reserveCapacity(corners + d.looseEdges.count)
        for f in 0..<(faceStart.count - 1) {
            let r = Int(faceStart[f])..<Int(faceStart[f + 1])
            for c in r {
                let n = c + 1 < r.upperBound ? c + 1 : r.lowerBound
                keyed.append((EditMesh.key(cornerVerts[c], cornerVerts[n]), Int32(c)))
            }
        }
        for e in d.looseEdges where e.x != e.y { keyed.append((EditMesh.key(e.x, e.y), -1)) }
        keyed.sort { $0.key < $1.key }
        cornerEdges = [Int32](repeating: -1, count: corners)
        var i = 0
        while i < keyed.count {
            let k = keyed[i].key
            let e = Int32(edges.count)
            edges.append(SIMD2(Int32(truncatingIfNeeded: k >> 32), Int32(truncatingIfNeeded: k & 0xFFFF_FFFF)))
            let a = d.edgeAttributes[k]
            edgeFlags.append(a?.flags ?? 0)
            edgeCrease.append(a?.crease ?? 0)
            while i < keyed.count && keyed[i].key == k {
                if keyed[i].corner >= 0 { cornerEdges[Int(keyed[i].corner)] = e }
                i += 1
            }
        }
    }

    /// A closed loop of corners cut into loops that pass no vertex twice.
    static func splitAtRepeats(_ loop: [(v: Int32, uv: SIMD2<Float>)]) -> [[(v: Int32, uv: SIMD2<Float>)]] {
        var seen: [Int32: Int] = [:]
        for (i, c) in loop.enumerated() {
            if let j = seen[c.v] {
                // loop[j..<i] closes on itself; the rest without it.
                let inner = Array(loop[j..<i])
                let outer = Array(loop[..<j] + loop[i...])
                return splitAtRepeats(inner) + splitAtRepeats(outer)
            }
            seen[c.v] = i
        }
        return [loop]
    }

    /// Vertices no face or edge uses (and, if `keepLoose`, that aren't loose vertices of their own: those stay) go,
    /// and the rest are numbered again in order.
    package mutating func removeUnusedVertices(keepLoose: Bool = false, used extra: [Bool]? = nil) {
        var used = extra ?? [Bool](repeating: keepLoose, count: positions.count)
        for v in cornerVerts { used[Int(v)] = true }
        for e in edges { used[Int(e.x)] = true; used[Int(e.y)] = true }
        guard used.contains(false) else { return }
        var map = [Int32](repeating: -1, count: positions.count)
        var p: [SIMD3<Float>] = [], fl: [UInt8] = []
        p.reserveCapacity(positions.count)
        for v in 0..<positions.count where used[v] {
            map[v] = Int32(p.count)
            p.append(positions[v])
            fl.append(vertFlags[v])
        }
        positions = p
        vertFlags = fl
        for c in 0..<cornerVerts.count { cornerVerts[c] = map[Int(cornerVerts[c])] }
        for e in 0..<edges.count {
            let a = map[Int(edges[e].x)], b = map[Int(edges[e].y)]
            edges[e] = SIMD2(min(a, b), max(a, b))
        }
        touch()
    }
}
