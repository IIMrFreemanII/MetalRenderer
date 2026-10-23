import Foundation
import simd

/// The modifiers' operations on a mesh (ModifierStack.apply runs them). Axes are Blender's (X, Y, Z with Z up):
/// Blender's Y is the engine's −Z, its Z the engine's Y.
package enum ModifierOps {
    /// Blender's axis `i` as an engine axis index.
    @inline(__always) static func engineAxis(_ i: Int) -> Int { [0, 2, 1][i] }

    /// Mirror: a mirrored copy across each axis's plane through the object's origin, joined; vertices on the plane
    /// welded to their copies.
    package static func mirror(_ m: EditMesh, axes: [Bool], merge: Bool, distance: Float) -> EditMesh {
        var mesh = m
        for i in 0..<3 where i < axes.count && axes[i] {
            let a = engineAxis(i)
            var s = SIMD4<Float>(1, 1, 1, 1)
            s[a] = -1
            let copy = mesh.transformed(by: float4x4(diagonal: s))
            let n = mesh.vertexCount
            var joined = mesh
            joined.join([copy])
            if merge {
                // Each vertex on the plane and its copy: one.
                var target = Array(0..<Int32(joined.vertexCount))
                for v in 0..<n where abs(mesh.positions[v][a]) <= distance { target[n + v] = Int32(v); joined.positions[v][a] = 0 }
                var d = joined.draft()
                for c in 0..<d.cornerVerts.count { d.cornerVerts[c] = target[Int(d.cornerVerts[c])] }
                d.looseEdges = d.looseEdges.map { SIMD2(target[Int($0.x)], target[Int($0.y)]) }
                var w = EditMesh(d)
                w.removeDuplicateFaces()
                w.removeUnusedVertices(used: looseVertexMask(of: joined, count: w.vertexCount))
                joined = w
            }
            mesh = joined
        }
        mesh.selectAll(false)
        return mesh
    }

    /// Array: `count` copies, each offset by the relative offset (times the mesh's size) and the constant one;
    /// touching vertices of neighbouring copies welded if `merge`.
    package static func array(_ m: EditMesh, count: Int, relative: SIMD3<Float>?, constant: SIMD3<Float>?, merge: Bool, distance: Float) -> EditMesh {
        guard count > 1 else { return m }
        let b = m.bounds
        let size = b.lo.x <= b.hi.x ? b.hi - b.lo : .zero
        var step = SIMD3<Float>.zero
        if let r = relative { step += BlenderAxes.fromBlender(r) * size }
        if let c = constant { step += BlenderAxes.fromBlender(c) }
        var copies: [EditMesh] = []
        for k in 1..<count {
            var t = matrix_identity_float4x4
            t.columns.3 = SIMD4(step * Float(k), 1)
            copies.append(m.transformed(by: t))
        }
        var out = m
        out.join(copies)
        if merge {
            out.selectAll(true)
            out.merge(.byDistance, distance: max(distance, 1e-6))
        }
        out.selectAll(false)
        return out
    }

    /// Solidify: the surface given `thickness` — an offset copy turned inside out, and rims along the open edges.
    /// `offset` −1 keeps the surface outside (the shell goes in), +1 inside, 0 centred.
    package static func solidify(_ m: EditMesh, thickness: Float, offset: Float, even: Bool, rim: Bool) -> EditMesh {
        guard m.faceCount > 0 else { return m }
        let fn = m.faceNormals()
        let vn = m.vertexNormals(faceNormals: fn)
        let t = MeshTopology(m)
        let outer = thickness * (offset + 1) / 2, inner = -thickness * (1 - offset) / 2
        var scale = [Float](repeating: 1, count: m.vertexCount)
        if even {
            // Thicker where the faces round a vertex meet at an angle (so the walls are even).
            for v in 0..<m.vertexCount {
                var c: Float = 1
                for f in t.faces(ofVertex: v) { c = min(c, max(0.25, simd_dot(vn[v], fn[f]))) }
                scale[v] = 1 / c
            }
        }
        var d = m.draft()
        let n = Int32(m.vertexCount)
        for v in 0..<m.vertexCount {
            d.positions[v] = m.positions[v] + vn[v] * outer * scale[v]
            d.addVertex(m.positions[v] + vn[v] * inner * scale[v])
        }
        for f in 0..<m.faceCount {
            d.addFace(m.faceVerts(f).reversed().map { $0 + n }, uvs: m.cornerUVs[m.corners(f)].reversed(), material: m.faceMaterial[f],
                      set: m.faceSet[f], flags: m.faceFlags[f])
        }
        if rim {
            for e in 0..<m.edgeCount where t.faceCount(ofEdge: e) == 1 {
                let c = Int(t.corners(ofEdge: e).first!)
                let f = Int(t.cornerFace[c])
                let a = m.cornerVerts[c], b = m.cornerVerts[m.nextCorner(c, face: f)]
                // The outer face runs a → b: the rim goes b → a, down to the inner copy.
                d.addFace([b, a, a + n, b + n], material: m.faceMaterial[f], set: m.faceSet[f], flags: m.faceFlags[f])
            }
        }
        var out = EditMesh(d)
        out.selectAll(false)
        return out
    }

    /// Bevel by angle: every edge sharper than the limit.
    package static func bevel(_ m: EditMesh, width: Float, segments: Int, angle: Float) -> EditMesh {
        var out = m
        out.bevelEdges(width: width, segments: segments, onlySelected: false, angleLimit: angle)
        out.selectAll(false)
        return out
    }
}

extension ModifierStack {
    /// One modifier on a mesh (the stack's step).
    package static func run(_ m: Modifier, on mesh: EditMesh, purpose: Purpose, object: ModelObject, operand: (UUID) -> ModelObject?) -> EditMesh {
        switch m.kind {
        case .mirror:
            return ModifierOps.mirror(mesh, axes: m.axes, merge: m.merge, distance: m.mergeDistance)
        case .array:
            return ModifierOps.array(mesh, count: m.count, relative: m.useRelative ? m.relativeOffset : nil,
                                     constant: m.useConstant ? m.constantOffset : nil, merge: m.mergeEnds, distance: m.mergeDistance)
        case .solidify:
            return ModifierOps.solidify(mesh, thickness: m.thickness, offset: m.offset, even: m.evenThickness, rim: m.fillRim)
        case .subdivision:
            let levels = purpose == .render ? m.renderLevels : m.levels
            var out = mesh
            if !m.useCreases { for e in 0..<out.edgeCount { out.edgeCrease[e] = 0 } }
            out = CatmullClark.subdivide(out, levels: levels)
            out.selectAll(false)
            return out
        case .bevel:
            return ModifierOps.bevel(mesh, width: m.width, segments: m.segments, angle: m.angleLimit)
        case .boolean:
            guard let id = m.operand, let other = operand(id), other.id != object.id else { return mesh }
            // The other object's mesh (its own modifiers too) in this object's space.
            let otherMesh = ModifierStack.evaluate(other, for: purpose, operand: { _ in nil })
            let into = object.transform.matrix.inverse * other.transform.matrix
            return BooleanOps.apply(mesh, otherMesh.transformed(by: into), operation: m.operation, solver: m.solver, voxel: m.voxelSize)
        case .triangulate:
            var out = mesh
            out.triangulate(onlySelected: false)
            out.selectAll(false)
            return out
        case .weld:
            var out = mesh
            out.selectAll(true)
            out.merge(.byDistance, distance: max(m.mergeDistance, 1e-6))
            out.selectAll(false)
            return out
        }
    }
}
