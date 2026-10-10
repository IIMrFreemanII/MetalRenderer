import Foundation
import simd

/// A mesh a procedural material's height moves (MatSurface.displacement): a copy of the mesh its instances had,
/// subdivided to the material's detail (MeshSubdivider), whose vertices the GPU moves from where they were along their
/// groups' normals each time the material's bake comes (Renderer.encodeDisplacement: MaterialShaders/MatDisplace.metal),
/// its structure then built again. Its normals stay the surface's: the material's normal map already has the height's
/// slopes in it.
struct DisplacedMesh {
    var mesh: Int
    var material: Int
    var first: Int          // its vertices in the scene's arrays
    var count: Int
    var records: Int        // its first vertex's records in `Scene.displaceVertices` (two a vertex)
    var members: Int        // its groups' first member in `Scene.displaceMembers`
    var scale: Float        // metres a unit of the mesh (its instances')
    var uvPerMetre: Float   // its UVs' density (the height's texture level at its vertices' spacing)
    var edge: Float         // its longest edge (metres)
    var triangles: Int
}

extension Scene {
    /// The most triangles a displaced mesh, and all of a scene's, are subdivided to.
    static let displacedTrianglesPerMesh = 1_000_000
    static let displacedTrianglesPerScene = 4_000_000

    /// The procedural materials that displace (MatSurface.displacement, with a height): every instance of theirs that
    /// can be is put on a subdivided copy of its mesh, one copy per mesh and scale (the displacement is in metres). An
    /// instance that can't (a plant's, an SDF shape's, a deforming or borrowed mesh's, a mesh of several materials, the
    /// open world's) keeps its mesh, and its material keeps its parallax.
    func displaceProcedural() {
        guard worldPlace == nil else { return }
        var total = 0
        for pm in procedural {
            guard let s = pm.made?.surface, s.displacement > 0, pm.channels.contains(.height), !undisplacedMaterials.contains(pm.material) else { continue }
            let name = pm.made?.name ?? pm.graph
            var copies: [SIMD2<Int>: Int] = [:]
            var all = true, left = 0
            for i in instances.indices where instances[i].material == pm.material {
                let inst = instances[i]
                guard displaceable(inst) else { all = false; left += 1; continue }
                let scale = Scene.uniformScale(inst.transform)
                let key = SIMD2(inst.mesh, Int((scale * 1000).rounded()))
                if let m = copies[key] { setDisplacedMesh(i, m); continue }
                guard let m = displacedCopy(of: inst.mesh, material: pm.material, surface: s, scale: scale, name: name, total: &total) else {
                    all = false
                    continue
                }
                copies[key] = m
                setDisplacedMesh(i, m)
            }
            if left > 0 { displacementNotes.append("\(name): \(left) instance\(left == 1 ? "" : "s") can't be displaced (parallax)") }
            if all && !copies.isEmpty { displacedMaterials.insert(pm.material) }
        }
        if !displaced.isEmpty {
            print(String(format: "Displacement: %d meshes, %.2fM triangles", displaced.count, Double(total) / 1e6))
            for note in displacementNotes { print("Displacement: \(note)") }
        }
    }

    /// Whether `inst`'s mesh can be subdivided and moved: a mesh of the scene's arrays, of triangles, its own material
    /// throughout, that nothing else moves.
    private func displaceable(_ inst: Instance) -> Bool {
        let m = inst.mesh
        guard m >= 0, inst.sdf < 0, inst.assembly < 0, inst.virtualMesh < 0, !inst.deforms, inst.isGeometry else { return false }
        let mesh = meshes[m]
        guard mesh.indexCount > 0, mesh.block == 0, mesh.cutout == 0, mesh.sways == 0, mesh.prevOffset == 0, mesh.vertexOffset == 0,
              !hasCurveMesh(m), !rebuiltMeshes.contains(m), !deforming.contains(where: { $0.mesh == m }),
              !borrowed.contains(where: { $0.mesh == m }) else { return false }
        let first = Int(mesh.firstIndex) / 3, count = Int(mesh.indexCount) / 3
        if first < triangleMaterials.count, triangleMaterials[first..<min(first + count, triangleMaterials.count)].contains(where: { $0 != 0 }) {
            return false
        }
        return true
    }

    /// Mesh `m` subdivided for `surface`'s displacement at `scale`: a new mesh, its records for the GPU. Nil if the
    /// scene's triangles are spent.
    private func displacedCopy(of m: Int, material: Int, surface s: MatSurface, scale: Float, name: String, total: inout Int) -> Int? {
        let mesh = meshes[m]
        let range = Int(mesh.firstIndex)..<Int(mesh.firstIndex + mesh.indexCount)
        let lo = Int(indices[range].min()!), hi = Int(indices[range].max()!)
        var p = Array(positions[lo...hi]), n = Array(normals[lo...hi]), uv = Array(uvs[lo...hi])
        var idx = indices[range].map { $0 - UInt32(lo) }
        // A mesh without UVs (the shading would project it, triangle by triangle: planarUV): projected now, in its
        // own space, so the texture stays on it.
        if Scene.uvArea(uv, idx) <= 0 { (p, n, uv, idx) = MeshSubdivider.planarUVs(p, n, idx, scale: scale) }
        let budget = min(Scene.displacedTrianglesPerMesh, Scene.displacedTrianglesPerScene - total)
        guard budget > idx.count / 3 else {
            displacementNotes.append("\(name): out of triangles (\(Scene.displacedTrianglesPerScene / 1_000_000)M a scene)")
            return nil
        }
        var sub = MeshSubdivider(positions: p, normals: n, uvs: uv, indices: idx)
        sub.subdivide(edge: max(s.displacementDetail, 0.001) / scale, cap: budget)
        let edge = sub.longestEdge * scale
        if sub.capped {
            displacementNotes.append(String(format: "%@: capped at %dk triangles (edges up to %.1f cm)", name, sub.triangleCount / 1000, edge * 100))
        }
        let welds = sub.welds()
        let copy = addMesh((sub.positions, sub.normals, sub.indices), uvs: sub.uvs)
        growBounds(mesh: copy, by: s.displacementRoom / scale)
        let records = displaceVertices.count / 2, members = displaceMembers.count
        for v in sub.positions.indices {
            displaceVertices.append(SIMD4(sub.positions[v], Float(bitPattern: welds.start[v])))
            displaceVertices.append(SIMD4(welds.direction[v], Float(bitPattern: welds.count[v])))
        }
        displaceMembers += welds.members
        let area = Scene.area(sub.positions, sub.indices), uvArea = Scene.uvArea(sub.uvs, sub.indices)
        displaced.append(DisplacedMesh(mesh: copy, material: material, first: positions.count - sub.positions.count, count: sub.positions.count,
                                       records: records, members: members, scale: scale,
                                       uvPerMetre: area > 0 ? (uvArea / area).squareRoot() / scale : 1, edge: edge,
                                       triangles: sub.triangleCount))
        total += sub.triangleCount
        return copy
    }

    /// The largest of a transform's axes' lengths (an instance's scale).
    static func uniformScale(_ t: float4x4) -> Float {
        max(simd_length(SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z)), simd_length(SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z)),
            simd_length(SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)), 1e-6)
    }

    static func area(_ p: [SIMD3<Float>], _ idx: [UInt32]) -> Float {
        stride(from: 0, to: idx.count, by: 3).reduce(0) {
            $0 + simd_length(simd_cross(p[Int(idx[$1 + 1])] - p[Int(idx[$1])], p[Int(idx[$1 + 2])] - p[Int(idx[$1])])) / 2
        }
    }

    static func uvArea(_ uv: [SIMD2<Float>], _ idx: [UInt32]) -> Float {
        stride(from: 0, to: idx.count, by: 3).reduce(0) {
            let a = uv[Int(idx[$1 + 1])] - uv[Int(idx[$1])], b = uv[Int(idx[$1 + 2])] - uv[Int(idx[$1])]
            return $0 + abs(a.x * b.y - a.y * b.x) / 2
        }
    }

    /// What the displacement made (the Material Designer's inspector): nil if nothing is displaced.
    var displacementSummary: String? {
        guard !displaced.isEmpty || !displacementNotes.isEmpty else { return nil }
        let triangles = displaced.reduce(0) { $0 + $1.triangles }
        return ([String(format: "Displaced: %d mesh%@, %.2fM triangles", displaced.count, displaced.count == 1 ? "" : "es", Double(triangles) / 1e6)]
                + displacementNotes).joined(separator: "\n")
    }

    /// The displaced meshes' meshes.
    var displacedMeshSet: Set<Int> { Set(displaced.map(\.mesh)) }
}

/// A displaced mesh's dispatch (MSL MatDisplaceArgs, MaterialShaders/MatDisplace.metal).
struct MatDisplaceArgs {
    var first: UInt32
    var count: UInt32
    var records: UInt32
    var members: UInt32
    var amount: Float
    var mid: Float
    var uvScale: Float
    var lod: Float
}
