import EngineCore
import Foundation
import simd

/// glTF in and out. In: each part of the model (a mesh where the node tree uses it) becomes an object, its triangles
/// welded back into one surface by position (glTF splits vertices at every seam and hard edge), its UVs kept per
/// corner, and edges where the file's normals break marked sharp, so it shades as it did. Out: a .glb of the evaluated
/// triangles, a primitive per material slot with its PBR values.
package enum GLTFModels {
    package static func read(_ url: URL) throws -> [ModelObject] {
        let model = try GLTFLoader.load(url)
        var out: [ModelObject] = []
        for (k, part) in model.parts.enumerated() {
            let mesh = model.meshes[part.mesh]
            var object = ModelObject(name: k < model.partNodes.count ? nodeName(model, part: k) : "\(model.name).\(k)",
                                     mesh: weld(mesh))
            // The part's transform as the object's (glTF is Y up, as the engine).
            let m = part.transform
            let s = SIMD3(simd_length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
                          simd_length(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
                          simd_length(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
            let r = float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z) / max(s.x, 1e-12),
                             SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z) / max(s.y, 1e-12),
                             SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z) / max(s.z, 1e-12))
            object.transform = ObjectTransform(location: SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z),
                                               rotation: ObjectTransform.euler(r), scale: s)
            if let mi = mesh.material, mi < model.materials.count {
                let g = model.materials[mi]
                object.materials = [MaterialSlot(name: g.name.isEmpty ? "Material" : g.name, baseColor: g.baseColor,
                                                 metallic: g.metallic, roughness: g.roughness, emission: g.emissive)]
            }
            out.append(object)
        }
        return out
    }

    private static func nodeName(_ model: GLTFModel, part k: Int) -> String {
        let nodes = model.partNodes[k]
        if let last = nodes.last, last < model.nodeNames.count, !model.nodeNames[last].isEmpty { return model.nodeNames[last] }
        return "\(model.name).\(k)"
    }

    /// A triangle list welded into a mesh: vertices at the same place are one; each corner keeps its UV; an edge whose
    /// two triangles' normals differ at either end is sharp.
    package static func weld(_ g: GLTFModel.Mesh) -> EditMesh {
        weld(positions: g.positions, normals: g.normals, uvs: g.uvs, indices: g.indices)
    }

    /// The same for arrays of a triangle mesh (a scene's mesh), UVs in glTF's convention.
    package static func weld(positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32]) -> EditMesh {
        let g = (positions: positions, normals: normals, uvs: uvs, indices: indices)
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for p in g.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let step = max(simd_reduce_max(hi - lo), 1e-6) * 1e-6
        var map: [SIMD3<Int32>: Int32] = [:]
        var weld = [Int32](repeating: 0, count: g.positions.count)
        var d = EditMesh.Draft()
        for (i, p) in g.positions.enumerated() {
            let q = SIMD3<Int32>(((p - lo) / step).rounded(.toNearestOrEven))
            if let w = map[q] { weld[i] = w } else {
                let w = d.addVertex(p)
                map[q] = w
                weld[i] = w
            }
        }
        var cornerNormal: [SIMD3<Float>] = []
        for t in 0..<(g.indices.count / 3) {
            let a = Int(g.indices[3 * t]), b = Int(g.indices[3 * t + 1]), c = Int(g.indices[3 * t + 2])
            let v = [weld[a], weld[b], weld[c]]
            guard Set(v).count == 3 else { continue }
            d.addFace(v, uvs: [g.uvs[a], g.uvs[b], g.uvs[c]].map { SIMD2($0.x, 1 - $0.y) }, flags: EditMesh.Flag.smooth)
            cornerNormal += [g.normals[a], g.normals[b], g.normals[c]]
        }
        var mesh = EditMesh(d)
        guard mesh.cornerCount == cornerNormal.count else { return mesh }
        // Sharp where the normals break: an edge's two corners at each end (one per face) disagree.
        let topo = MeshTopology(mesh)
        for e in 0..<mesh.edgeCount {
            let cs = topo.corners(ofEdge: e)
            guard cs.count == 2 else { continue }
            let c0 = Int(cs[cs.startIndex]), c1 = Int(cs[cs.startIndex + 1])
            let f0 = Int(topo.cornerFace[c0]), f1 = Int(topo.cornerFace[c1])
            // Corner c's edge runs from its vertex to the next corner's.
            let n0a = cornerNormal[c0], n0b = cornerNormal[mesh.nextCorner(c0, face: f0)]
            let n1a = cornerNormal[c1], n1b = cornerNormal[mesh.nextCorner(c1, face: f1)]
            // Opposite directions: c0's start is c1's end.
            if simd_dot(n0a, n1b) < 0.995 || simd_dot(n0b, n1a) < 0.995 { mesh.edgeFlags[e] |= EditMesh.Flag.sharp }
        }
        mesh.touch()
        return mesh
    }

    // MARK: Write

    /// A .glb of triangle meshes, each with its slots (one primitive per slot used).
    package static func write(_ parts: [(name: String, mesh: TriangleMesh, materials: [MaterialSlot])], to url: URL) throws {
        var bin = Data()
        var bufferViews: [[String: Any]] = [], accessors: [[String: Any]] = [], meshes: [[String: Any]] = []
        var nodes: [[String: Any]] = [], materials: [[String: Any]] = []
        func view<T>(_ a: [T], stride: Int, target: Int) -> Int {
            while bin.count % 4 != 0 { bin.append(0) }
            let offset = bin.count
            a.withUnsafeBytes { raw in
                for i in 0..<a.count { bin.append(contentsOf: raw[(i * MemoryLayout<T>.stride)..<(i * MemoryLayout<T>.stride + stride)]) }
            }
            bufferViews.append(["buffer": 0, "byteOffset": offset, "byteLength": bin.count - offset, "target": target])
            return bufferViews.count - 1
        }
        for part in parts {
            let m = part.mesh
            guard m.triangleCount > 0 else { continue }
            var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
            for p in m.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            accessors.append(["bufferView": view(m.positions, stride: 12, target: 34962), "componentType": 5126, "count": m.positions.count,
                              "type": "VEC3", "min": [lo.x, lo.y, lo.z], "max": [hi.x, hi.y, hi.z]])
            let pa = accessors.count - 1
            accessors.append(["bufferView": view(m.normals, stride: 12, target: 34962), "componentType": 5126, "count": m.normals.count, "type": "VEC3"])
            let na = accessors.count - 1
            accessors.append(["bufferView": view(m.uvs.map { SIMD2($0.x, 1 - $0.y) }, stride: 8, target: 34962), "componentType": 5126,
                              "count": m.uvs.count, "type": "VEC2"])
            let ta = accessors.count - 1
            var primitives: [[String: Any]] = []
            let slots = Set(m.triangleMaterial).sorted()
            for s in slots {
                var idx: [UInt32] = []
                for t in 0..<m.triangleCount where m.triangleMaterial[t] == s {
                    idx += [m.indices[3 * t], m.indices[3 * t + 1], m.indices[3 * t + 2]]
                }
                accessors.append(["bufferView": view(idx, stride: 4, target: 34963), "componentType": 5125, "count": idx.count, "type": "SCALAR"])
                let slot = Int(s) < part.materials.count ? part.materials[Int(s)] : MaterialSlot(name: "Material")
                materials.append([
                    "name": slot.name,
                    "pbrMetallicRoughness": ["baseColorFactor": [slot.baseColor.x, slot.baseColor.y, slot.baseColor.z, slot.baseColor.w],
                                             "metallicFactor": slot.metallic, "roughnessFactor": slot.roughness],
                    "emissiveFactor": [min(1, slot.emission.x), min(1, slot.emission.y), min(1, slot.emission.z)],
                ])
                primitives.append(["attributes": ["POSITION": pa, "NORMAL": na, "TEXCOORD_0": ta], "indices": accessors.count - 1,
                                   "material": materials.count - 1])
            }
            meshes.append(["name": part.name, "primitives": primitives])
            nodes.append(["mesh": meshes.count - 1, "name": part.name])
        }
        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "MetalRenderer Modeller"],
            "scene": 0,
            "scenes": [["nodes": Array(0..<nodes.count)]],
            "nodes": nodes, "meshes": meshes, "materials": materials,
            "buffers": [["byteLength": bin.count]], "bufferViews": bufferViews, "accessors": accessors,
        ]
        var text = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while text.count % 4 != 0 { text.append(0x20) }
        while bin.count % 4 != 0 { bin.append(0) }
        var out = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        u32(0x4654_6C67); u32(2); u32(12 + 8 + text.count + 8 + bin.count)
        u32(text.count); u32(0x4E4F_534A); out.append(text)
        u32(bin.count); u32(0x004E_4942); out.append(bin)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: url, options: .atomic)
    }
}
