import EngineCore
import Foundation
import Modeling
import simd

/// Geometry to and from the modeller's `EditMesh`: what the viewport draws, what saving bakes, and what the nodes
/// that run the modeller's operations (bevel, boolean, subdivision) hand it.
///
/// A polygon is a face, its vertices' `uv` the corners' UVs, the primitive string `material` the face's material
/// (an index into the names returned); a polyline is loose edges. Back, a face is a polygon, a loose edge a polyline
/// of two points, a face's material its `material` name.
extension ProcGeo {
    /// The mesh's faces as polygons and its loose edges as polylines; `materials` names its material indices. With
    /// `normals`, smooth faces' vertex normals become the point attribute N.
    package init(_ m: EditMesh, materials: [String] = [], normals: Bool = false) {
        self.init()
        P = m.positions
        vertexPoint = m.cornerVerts
        primStart = m.faceStart
        primClosed = [Bool](repeating: true, count: m.faceCount)
        var used = [Bool](repeating: false, count: m.edgeCount)
        for e in m.cornerEdges where e >= 0 { used[Int(e)] = true }
        for e in 0..<m.edgeCount where !used[e] {
            vertexPoint += [m.edges[e].x, m.edges[e].y]
            primStart.append(Int32(vertexPoint.count))
            primClosed.append(false)
        }
        syncCounts()
        if m.cornerUVs.contains(where: { $0 != .zero }) {
            vertices.set("uv", .vector2(m.cornerUVs + [SIMD2<Float>](repeating: .zero, count: vertexCount - m.cornerCount)))
        }
        if m.faceMaterial.contains(where: { $0 != 0 }) || !materials.isEmpty {
            let names = materials.isEmpty ? ["Material"] : materials
            var rows = [Int32](repeating: 0, count: primCount)
            for f in 0..<m.faceCount { rows[f] = Int32(min(Int(m.faceMaterial[f]), names.count - 1)) + 1 }
            prims.set("material", .string(rows, table: [""] + names))
        }
        if normals, m.faceFlags.contains(where: { $0 & EditMesh.Flag.smooth != 0 }) {
            // Smooth faces: a point normal (sharp edges aren't kept: a Normal node's cusp angle makes them again).
            points.set("N", .vector3(m.vertexNormals()))
        }
    }

    /// The geometry as a mesh: polygons as faces, polylines as loose edges, points no primitive uses as loose
    /// vertices. With a normal (`N` on points or vertices), faces are smooth and vertex normals that differ across an
    /// edge make it sharp; without one, as Houdini's viewport shows it, faces are smooth and edges whose faces meet
    /// at more than `cusp` degrees are sharp. `selectPoints` / `selectPrims` set the selection flags (an operation's
    /// input). The face of each polygon is in order: face `f` is the `f`-th polygon, unless a polygon was degenerate.
    package func editMesh(selectPoints: [Bool]? = nil, selectPrims: [Bool]? = nil, cusp: Float = 60) -> (mesh: EditMesh, materials: [String]) {
        var d = EditMesh.Draft()
        d.positions = P
        d.vertFlags = selectPoints.map { $0.map { $0 ? EditMesh.Flag.select : 0 } } ?? [UInt8](repeating: 0, count: pointCount)
        let uv = vertices.vectors2("uv")
        let vertexN = vertices.vectors3("N")
        let hasN = vertexN != nil || points.vectors3("N") != nil
        let smooth = hasN || cusp < 180
        let cosCusp = cos(cusp * .pi / 180)
        // Materials: the distinct names in first-seen order.
        var materials: [String] = []
        var materialOf: [Int32] = []
        if case .string(let rows, let table)? = prims["material"] {
            var slot = [Int32](repeating: -1, count: table.count)
            materialOf = rows.map { r in
                if slot[Int(r)] < 0 { slot[Int(r)] = Int32(materials.count); materials.append(table[Int(r)].isEmpty ? "Material" : table[Int(r)]) }
                return slot[Int(r)]
            }
        }
        var edgeNormal: [UInt64: SIMD3<Float>] = [:]
        for p in 0..<primCount {
            let r = vertexRange(p)
            if isPolygon(p) {
                let verts = Array(vertexPoint[r])
                let uvs = uv.map { a in r.map { a[$0] } }
                var flags: UInt8 = smooth ? EditMesh.Flag.smooth : 0
                if let s = selectPrims, s[p] { flags |= EditMesh.Flag.select }
                d.addFace(verts, uvs: uvs, material: materialOf.isEmpty ? 0 : UInt16(materialOf[p]), flags: flags)
                if !hasN && cusp < 180 {
                    // Sides whose faces fold past the cusp angle are sharp.
                    let n = primNormal(p)
                    for (k, v) in r.enumerated() {
                        let w = r.lowerBound + (k + 1) % r.count
                        let key = EditMesh.key(vertexPoint[v], vertexPoint[w])
                        if let other = edgeNormal[key] {
                            if simd_dot(other, n) < cosCusp { d.edgeAttributes[key] = (EditMesh.Flag.sharp, 0) }
                        } else {
                            edgeNormal[key] = n
                        }
                    }
                } else if let vn = vertexN {
                    // A side whose two faces' vertex normals differ at either end is sharp.
                    for (k, v) in r.enumerated() {
                        let w = r.lowerBound + (k + 1) % r.count
                        let key = EditMesh.key(vertexPoint[v], vertexPoint[w])
                        let n = vn[v] + vn[w]
                        if let other = edgeNormal[key] {
                            if simd_distance(other, n) > 1e-3 { d.edgeAttributes[key] = (EditMesh.Flag.sharp, 0) }
                        } else {
                            // Stored the other way round for the face across (its corners run the side backwards).
                            edgeNormal[key] = n
                        }
                    }
                }
            } else if r.count >= 2 {
                for v in r.lowerBound..<(r.upperBound - 1) { d.looseEdges.append(SIMD2(vertexPoint[v], vertexPoint[v + 1])) }
                if primClosed[p] && r.count > 2 { d.looseEdges.append(SIMD2(vertexPoint[r.upperBound - 1], vertexPoint[r.lowerBound])) }
            }
        }
        return (EditMesh(d), materials.isEmpty ? ["Material"] : materials)
    }

    /// The attributes `source` has that this geometry lacks, from its nearest elements: points from the nearest point,
    /// primitives from the primitive whose centre is nearest, vertices from the nearest vertex of that primitive, the
    /// detail as it is. What a node that runs a modeller operation (which keeps only P, UVs and materials) does after it.
    package mutating func transferAttributes(from source: ProcGeo, skipping skip: Set<String> = ["P"]) {
        let pointNames = source.points.attributes.map(\.name).filter { !skip.contains($0) && points[$0] == nil }
        let pointGroups = source.points.groups.map(\.name).filter { points.group($0) == nil }
        if !pointNames.isEmpty || !pointGroups.isEmpty, source.pointCount > 0 {
            let grid = PointGrid(source.P)
            let rows = P.map { grid.nearest($0) }
            let from = source.points.gathered(rows)
            for n in pointNames { points.set(n, from[n]!) }
            for g in pointGroups { points.setGroup(g, from.group(g)!) }
        }
        let primNames = source.prims.attributes.map(\.name).filter { !skip.contains($0) && prims[$0] == nil }
        let primGroups = source.prims.groups.map(\.name).filter { prims.group($0) == nil }
        let vertexNames = source.vertices.attributes.map(\.name).filter { !skip.contains($0) && vertices[$0] == nil }
        if (!primNames.isEmpty || !primGroups.isEmpty || !vertexNames.isEmpty), source.primCount > 0, primCount > 0 {
            let centres = (0..<source.primCount).map { source.primCenter($0) }
            let grid = PointGrid(centres)
            let primRows = (0..<primCount).map { grid.nearest(primCenter($0)) }
            let from = source.prims.gathered(primRows)
            for n in primNames { prims.set(n, from[n]!) }
            for g in primGroups { prims.setGroup(g, from.group(g)!) }
            if !vertexNames.isEmpty {
                var vrows = [Int32](repeating: -1, count: vertexCount)
                for p in 0..<primCount {
                    let sp = Int(primRows[p])
                    let sr = source.vertexRange(sp)
                    for v in vertexRange(p) {
                        let q = P[Int(vertexPoint[v])]
                        var best: Int32 = -1, bestD = Float.infinity
                        for sv in sr {
                            let d = simd_distance_squared(source.P[Int(source.vertexPoint[sv])], q)
                            if d < bestD { bestD = d; best = Int32(sv) }
                        }
                        vrows[v] = best
                    }
                }
                let fromV = source.vertices.gathered(vrows)
                for n in vertexNames { vertices.set(n, fromV[n]!) }
            }
        }
        for a in source.detail.attributes where detail[a.name] == nil { detail.set(a.name, a.values) }
    }
}
