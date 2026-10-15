import Foundation
import simd

/// A painted object's mesh as a glTF binary (.glb): its triangles with the painter's UVs (a vertex for each place and
/// UV: the seams split here, not in the scene), and a material whose textures are the exported set beside it
/// (`<name>_basecolor.png`, `_orm`, `_normal`, `_emissive` if there is one), as glTF lays them out.
enum GLBWriter {
    static func write(_ mesh: PaintMesh, corners: [SIMD2<Float>], name: String, emissive: Bool = false, imageSuffix: String = "png",
                      to url: URL) throws {
        // Vertices: one per (mesh vertex, corner UV).
        var index: [SIMD3<UInt32>: UInt32] = [:]
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        for (i, v) in mesh.indices.enumerated() {
            let uv = corners[i]
            let key = SIMD3(v, uv.x.bitPattern, uv.y.bitPattern)
            if let k = index[key] { indices.append(k); continue }
            let k = UInt32(positions.count)
            index[key] = k
            positions.append(mesh.positions[Int(v)])
            normals.append(mesh.normals[Int(v)])
            uvs.append(uv)
            indices.append(k)
        }
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        // The buffer: positions, normals, UVs, indices, one after the other (each a multiple of 4 bytes).
        var bin = Data()
        func append<T>(_ a: [T], stride: Int, count: Int) -> (offset: Int, length: Int) {
            let offset = bin.count
            a.withUnsafeBytes { raw in
                for i in 0..<count { bin.append(contentsOf: raw[(i * MemoryLayout<T>.stride)..<(i * MemoryLayout<T>.stride + stride)]) }
            }
            return (offset, bin.count - offset)
        }
        let p = append(positions, stride: 12, count: positions.count)
        let n = append(normals, stride: 12, count: normals.count)
        let t = append(uvs, stride: 8, count: uvs.count)
        let ix = append(indices, stride: 4, count: indices.count)
        var images: [[String: Any]] = [["uri": "\(name)_basecolor.\(imageSuffix)"], ["uri": "\(name)_orm.\(imageSuffix)"],
                                       ["uri": "\(name)_normal.\(imageSuffix)"]]
        var material: [String: Any] = [
            "name": name,
            "pbrMetallicRoughness": ["baseColorTexture": ["index": 0], "metallicRoughnessTexture": ["index": 1],
                                     "metallicFactor": 1.0, "roughnessFactor": 1.0],
            "normalTexture": ["index": 2],
            "occlusionTexture": ["index": 1],
        ]
        if emissive {
            images.append(["uri": "\(name)_emissive.\(imageSuffix)"])
            material["emissiveTexture"] = ["index": 3]
            material["emissiveFactor"] = [1.0, 1.0, 1.0]
        }
        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "MetalRenderer Material Painter"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "name": name]],
            "meshes": [["name": name, "primitives": [["attributes": ["POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2], "indices": 3, "material": 0]]]],
            "materials": [material],
            "textures": images.indices.map { ["source": $0] },
            "images": images,
            "buffers": [["byteLength": bin.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": p.offset, "byteLength": p.length, "target": 34962],
                ["buffer": 0, "byteOffset": n.offset, "byteLength": n.length, "target": 34962],
                ["buffer": 0, "byteOffset": t.offset, "byteLength": t.length, "target": 34962],
                ["buffer": 0, "byteOffset": ix.offset, "byteLength": ix.length, "target": 34963],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": positions.count, "type": "VEC3",
                 "min": [lo.x, lo.y, lo.z], "max": [hi.x, hi.y, hi.z]],
                ["bufferView": 1, "componentType": 5126, "count": normals.count, "type": "VEC3"],
                ["bufferView": 2, "componentType": 5126, "count": uvs.count, "type": "VEC2"],
                ["bufferView": 3, "componentType": 5125, "count": indices.count, "type": "SCALAR"],
            ],
        ]
        var text = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while text.count % 4 != 0 { text.append(0x20) }
        while bin.count % 4 != 0 { bin.append(0) }
        var out = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        u32(0x4654_6C67)                                   // "glTF"
        u32(2)
        u32(12 + 8 + text.count + 8 + bin.count)
        u32(text.count); u32(0x4E4F_534A); out.append(text) // JSON
        u32(bin.count); u32(0x004E_4942); out.append(bin)   // BIN
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: url, options: .atomic)
    }
}
