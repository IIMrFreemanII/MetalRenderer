import Foundation
import simd

/// The Boolean modifier: union, difference or intersection of a mesh with another object's.
///
/// Exact: a BSP tree per mesh (csg.js's algorithm): each mesh's polygons clipped by the other's tree, split by its
/// planes where they cross, in double precision; the pieces welded back into one mesh and the fragments of each
/// original face merged where they make one polygon again. Fine for meshes of up to tens of thousands of faces.
/// Voxel: both meshes as distance fields, combined, and the surface rebuilt (any size, and meshes with holes; the
/// result is a remesh at the voxel size).
package enum BooleanOps {
    package static let exactLimit = 40_000

    package static func apply(_ a: EditMesh, _ b: EditMesh, operation: Modifier.BooleanOperation, solver: Modifier.BooleanSolver,
                              voxel: Float) -> EditMesh {
        if solver == .voxel || a.cornerCount + b.cornerCount > exactLimit * 4 { return voxelBoolean(a, b, operation: operation, voxel: voxel) }
        return exact(a, b, operation: operation)
    }

    /// A first operand used against many second ones (Voronoi Fracture's cells): its BSP tree built once, each
    /// boolean working on a copy of it. The same results as `apply` with the mesh.
    package struct Operand {
        package let mesh: EditMesh
        private let tree: Node?

        package init(_ mesh: EditMesh) {
            self.mesh = mesh
            tree = mesh.cornerCount > exactLimit * 4 ? nil : Node(polygons(mesh, sourceOffset: false))
        }

        package func apply(_ b: EditMesh, operation: Modifier.BooleanOperation, solver: Modifier.BooleanSolver, voxel: Float) -> EditMesh {
            guard let tree, solver != .voxel, mesh.cornerCount + b.cornerCount <= exactLimit * 4 else {
                return BooleanOps.apply(mesh, b, operation: operation, solver: solver, voxel: voxel)
            }
            return exact(tree.copy(), mesh, b, operation: operation)
        }
    }

    // MARK: Exact (BSP)

    struct Vertex { var p: SIMD3<Double>; var uv: SIMD2<Double> }
    struct Plane {
        var n: SIMD3<Double>, w: Double
        init(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) {
            let cr = simd_cross(b - a, c - a)
            let l = simd_length(cr)
            n = l > 0 ? cr / l : SIMD3(0, 0, 1)
            w = simd_dot(n, a)
        }
        mutating func flip() { n = -n; w = -w }
    }
    struct Polygon {
        var verts: [Vertex]
        var plane: Plane
        var source: Int32      // face index; negative: −(face + 1) of the other mesh
        var flipped = false
        init?(_ verts: [Vertex], source: Int32) {
            guard verts.count >= 3 else { return nil }
            // A plane through the polygon (Newell's normal, robust for n-gons).
            var n = SIMD3<Double>.zero
            for i in 0..<verts.count {
                let p = verts[i].p, q = verts[(i + 1) % verts.count].p
                n += SIMD3((p.y - q.y) * (p.z + q.z), (p.z - q.z) * (p.x + q.x), (p.x - q.x) * (p.y + q.y))
            }
            let l = simd_length(n)
            guard l > 1e-18 else { return nil }
            plane = Plane(.zero, .zero, .zero)
            plane.n = n / l
            plane.w = simd_dot(plane.n, verts[0].p)
            self.verts = verts
            self.source = source
        }
        mutating func flip() { verts.reverse(); plane.flip(); flipped.toggle() }
    }

    static let epsilon = 1e-6

    /// Splits a polygon by a plane into the four lists (coplanar ones by which way they face).
    static func split(_ poly: Polygon, by plane: Plane, coplanarFront: inout [Polygon], coplanarBack: inout [Polygon],
                      front: inout [Polygon], back: inout [Polygon]) {
        let eps = epsilon * max(1, abs(plane.w))
        var kinds = [Int](repeating: 0, count: poly.verts.count)
        var all = 0
        for (i, v) in poly.verts.enumerated() {
            let t = simd_dot(plane.n, v.p) - plane.w
            let k = t < -eps ? 2 : (t > eps ? 1 : 0)
            kinds[i] = k
            all |= k
        }
        switch all {
        case 0:
            if simd_dot(plane.n, poly.plane.n) > 0 { coplanarFront.append(poly) } else { coplanarBack.append(poly) }
        case 1: front.append(poly)
        case 2: back.append(poly)
        default:
            var f: [Vertex] = [], b: [Vertex] = []
            let n = poly.verts.count
            for i in 0..<n {
                let j = (i + 1) % n
                let ti = kinds[i], tj = kinds[j]
                let vi = poly.verts[i], vj = poly.verts[j]
                if ti != 2 { f.append(vi) }
                if ti != 1 { b.append(vi) }
                if (ti | tj) == 3 {
                    let t = (plane.w - simd_dot(plane.n, vi.p)) / simd_dot(plane.n, vj.p - vi.p)
                    let v = Vertex(p: vi.p + (vj.p - vi.p) * t, uv: vi.uv + (vj.uv - vi.uv) * t)
                    f.append(v)
                    b.append(v)
                }
            }
            if var p = Polygon(f, source: poly.source) { p.plane = poly.plane; p.flipped = poly.flipped; front.append(p) }
            if var p = Polygon(b, source: poly.source) { p.plane = poly.plane; p.flipped = poly.flipped; back.append(p) }
        }
    }

    /// A BSP node; built, walked and clipped without recursion (a mesh's tree can be deep).
    final class Node {
        var plane: Plane?
        var front: Node?
        var back: Node?
        var polygons: [Polygon] = []

        init(_ polys: [Polygon] = []) { if !polys.isEmpty { build(polys) } }

        /// A copy of the tree, node for node (the operations change the trees they work on).
        func copy() -> Node {
            let root = Node()
            var stack: [(Node, Node)] = [(self, root)]
            while let (from, to) = stack.popLast() {
                to.plane = from.plane
                to.polygons = from.polygons
                if let f = from.front { to.front = Node(); stack.append((f, to.front!)) }
                if let b = from.back { to.back = Node(); stack.append((b, to.back!)) }
            }
            return root
        }

        var nodes: [Node] {
            var out: [Node] = [], stack: [Node] = [self]
            while let n = stack.popLast() {
                out.append(n)
                if let f = n.front { stack.append(f) }
                if let b = n.back { stack.append(b) }
            }
            return out
        }

        func invert() {
            for n in nodes {
                for i in n.polygons.indices { n.polygons[i].flip() }
                n.plane?.flip()
                swap(&n.front, &n.back)
            }
        }

        /// The polygons with the parts inside this tree's solid removed.
        func clip(_ polys: [Polygon]) -> [Polygon] {
            var out: [Polygon] = []
            var stack: [(Node, [Polygon])] = [(self, polys)]
            while let (n, ps) = stack.popLast() {
                guard let plane = n.plane else { out += ps; continue }
                var f: [Polygon] = [], b: [Polygon] = [], cf: [Polygon] = [], cb: [Polygon] = []
                for p in ps { split(p, by: plane, coplanarFront: &cf, coplanarBack: &cb, front: &f, back: &b) }
                f += cf
                b += cb
                if let front = n.front { stack.append((front, f)) } else { out += f }
                if let back = n.back { stack.append((back, b)) }
            }
            return out
        }

        func clip(to other: Node) {
            for n in nodes { n.polygons = other.clip(n.polygons) }
        }

        var allPolygons: [Polygon] { nodes.flatMap(\.polygons) }

        func build(_ polys: [Polygon]) {
            var stack: [(Node, [Polygon])] = [(self, polys)]
            while let (n, ps) = stack.popLast() {
                guard !ps.isEmpty else { continue }
                if n.plane == nil { n.plane = ps[0].plane }
                var f: [Polygon] = [], b: [Polygon] = []
                var cf: [Polygon] = [], cb: [Polygon] = []
                for p in ps { split(p, by: n.plane!, coplanarFront: &cf, coplanarBack: &cb, front: &f, back: &b) }
                n.polygons += cf + cb
                if !f.isEmpty { if n.front == nil { n.front = Node() }; stack.append((n.front!, f)) }
                if !b.isEmpty { if n.back == nil { n.back = Node() }; stack.append((n.back!, b)) }
            }
        }
    }

    static func polygons(_ m: EditMesh, sourceOffset: Bool) -> [Polygon] {
        (0..<m.faceCount).compactMap { f in
            let verts = m.corners(f).map { c -> Vertex in
                let p = m.positions[Int(m.cornerVerts[c])], uv = m.cornerUVs[c]
                return Vertex(p: SIMD3<Double>(p), uv: SIMD2<Double>(uv))
            }
            return Polygon(verts, source: sourceOffset ? -Int32(f + 1) : Int32(f))
        }
    }

    package static func exact(_ a: EditMesh, _ b: EditMesh, operation: Modifier.BooleanOperation) -> EditMesh {
        exact(Node(polygons(a, sourceOffset: false)), a, b, operation: operation)
    }

    /// The boolean of `a`, whose tree is `A` (changed by it), and `b`.
    static func exact(_ A: Node, _ a: EditMesh, _ b: EditMesh, operation: Modifier.BooleanOperation) -> EditMesh {
        let B = Node(polygons(b, sourceOffset: true))
        let result: [Polygon]
        switch operation {
        case .union:
            A.clip(to: B); B.clip(to: A); B.invert(); B.clip(to: A); B.invert()
            A.build(B.allPolygons)
            result = A.allPolygons
        case .difference:
            A.invert(); A.clip(to: B); B.clip(to: A); B.invert(); B.clip(to: A); B.invert()
            A.build(B.allPolygons); A.invert()
            result = A.allPolygons
        case .intersect:
            A.invert(); B.clip(to: A); B.invert(); A.clip(to: B); B.clip(to: A)
            A.build(B.allPolygons); A.invert()
            result = A.allPolygons
        }
        return assemble(result, a, b)
    }

    /// Polygons welded into a mesh (vertices within a millionth of the size are one), the fragments of each original
    /// face merged back where they make one polygon.
    static func assemble(_ polys: [Polygon], _ a: EditMesh, _ b: EditMesh) -> EditMesh {
        var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
        for p in polys { for v in p.verts { lo = simd_min(lo, v.p); hi = simd_max(hi, v.p) } }
        let step = max(simd_reduce_max(hi - lo), 1e-9) * 1e-6
        var index: [SIMD3<Int64>: Int32] = [:]
        var d = EditMesh.Draft()
        var source: [Int32] = []
        for poly in polys {
            var vs: [Int32] = [], uvs: [SIMD2<Float>] = []
            for v in poly.verts {
                let q = SIMD3<Int64>(((v.p - lo) / step).rounded(.toNearestOrEven))
                let i: Int32
                if let k = index[q] { i = k } else { i = d.addVertex(SIMD3<Float>(v.p)); index[q] = i }
                if vs.last == i { continue }
                vs.append(i)
                uvs.append(SIMD2<Float>(v.uv))
            }
            while vs.count > 1 && vs.first == vs.last { vs.removeLast(); uvs.removeLast() }
            guard Set(vs).count >= 3 else { continue }
            let fromA = poly.source >= 0
            let f = fromA ? Int(poly.source) : Int(-poly.source - 1)
            let m = fromA ? a : b
            let face = min(f, max(0, m.faceCount - 1))
            d.addFace(vs, uvs: uvs, material: fromA ? m.faceMaterial[face] : 0, set: m.faceSet.isEmpty ? 0 : m.faceSet[face],
                      flags: (m.faceFlags.isEmpty ? 0 : m.faceFlags[face]) & ~EditMesh.Flag.select)
            source.append(poly.source)
        }
        var mesh = EditMesh(d)
        guard mesh.faceCount == source.count else { mesh.removeUnusedVertices(); return mesh }
        // The fragments of one face: their shared edges dissolved.
        let t = MeshTopology(mesh)
        var any = false
        for e in 0..<mesh.edgeCount {
            let fs = t.faces(ofEdge: e)
            if fs.count == 2 && source[fs[0]] == source[fs[1]] { mesh.edgeFlags[e] |= EditMesh.Flag.select; any = true }
        }
        if any { mesh.dissolve(.edge) }
        mesh.removeUnusedVertices()
        mesh.selectAll(false)
        return mesh
    }

    // MARK: Voxel

    package static func voxelBoolean(_ a: EditMesh, _ b: EditMesh, operation: Modifier.BooleanOperation, voxel: Float) -> EditMesh {
        func tree(_ m: EditMesh) -> TriangleTree {
            let (tri, _) = m.triangles()
            return TriangleTree(positions: m.positions, indices: tri.map { UInt32(m.cornerVerts[Int($0)]) })
        }
        let ta = tree(a), tb = tree(b)
        let ba = a.bounds, bb = b.bounds
        var lo = ba.lo, hi = ba.hi
        switch operation {
        case .union: lo = simd_min(ba.lo, bb.lo); hi = simd_max(ba.hi, bb.hi)
        case .intersect: lo = simd_max(ba.lo, bb.lo); hi = simd_min(ba.hi, bb.hi)
        case .difference: break
        }
        guard lo.x <= hi.x && lo.y <= hi.y && lo.z <= hi.z else { return EditMesh() }
        return VoxelRemesh.surface(lo: lo, hi: hi, voxel: voxel) { p in
            let (da, ga) = ta.signedDistance(p), (db, gb) = tb.signedDistance(p)
            switch operation {
            case .union: return da < db ? (da, ga) : (db, gb)
            case .intersect: return da > db ? (da, ga) : (db, gb)
            case .difference: return da > -db ? (da, ga) : (-db, -gb)
            }
        }
    }
}
