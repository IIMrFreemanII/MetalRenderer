import Foundation
import simd

/// The draped garment as a mesh for other programs: OBJ (with its MTL inline as comments: a material a fabric, one
/// group a panel), binary glTF (a primitive a fabric, its fabric's colour and roughness), and point caches of a
/// drape over time (PC2, which Blender's Mesh Cache reads; `.gcache`, ours). Texture coordinates are the pattern's
/// (metres along the warp and the weft, over 10 cm a repeat): a fabric's print tiles as it was cut.
package enum GarmentExport {
    package struct Mesh {
        package var positions: [SIMD3<Float>]
        package var normals: [SIMD3<Float>]
        package var uvs: [SIMD2<Float>]
        package var triangles: [UInt32]
        package var triangleFabric: [UInt8]
        package var panelTriangles: [(name: String, range: Range<Int>)]
        package var fabrics: [Fabric]

        package init(build b: GarmentBuild, positions: [SIMD3<Float>], garment g: Garment) {
            self.positions = positions
            normals = GarmentExport.normals(positions, b.triangles)
            uvs = b.uvs.map { $0 * 10 }
            triangles = b.triangles
            triangleFabric = b.triangleFabric
            panelTriangles = b.panelIDs.enumerated().map { (g.panel(id: $0.element)?.name ?? "Panel \($0.element)", b.panelTriangles[$0.offset]) }
            fabrics = g.fabrics.isEmpty ? [.preset(.cotton)] : g.fabrics
        }
    }

    /// Area-weighted vertex normals.
    package static func normals(_ p: [SIMD3<Float>], _ t: [UInt32]) -> [SIMD3<Float>] {
        var n = [SIMD3<Float>](repeating: .zero, count: p.count)
        for k in stride(from: 0, to: t.count, by: 3) {
            let a = Int(t[k]), b = Int(t[k + 1]), c = Int(t[k + 2])
            let f = simd_cross(p[b] - p[a], p[c] - p[a])
            n[a] += f; n[b] += f; n[c] += f
        }
        return n.map { simd_length($0) > 1e-12 ? simd_normalize($0) : SIMD3(0, 1, 0) }
    }

    package static func obj(_ m: Mesh) -> String {
        var s = "# MetalRenderer garment\n"
        for (i, f) in m.fabrics.enumerated() {
            s += String(format: "# material fabric%d %@: Kd %.4f %.4f %.4f, roughness %.3f\n", i, f.name, f.color.x, f.color.y, f.color.z, f.roughness)
        }
        for p in m.positions { s += String(format: "v %.5f %.5f %.5f\n", p.x, p.y, p.z) }
        for t in m.uvs { s += String(format: "vt %.5f %.5f\n", t.x, t.y) }
        for n in m.normals { s += String(format: "vn %.4f %.4f %.4f\n", n.x, n.y, n.z) }
        for panel in m.panelTriangles {
            s += "g \(panel.name.replacingOccurrences(of: " ", with: "_"))\n"
            var fabric = -1
            for t in panel.range {
                let f = Int(m.triangleFabric.indices.contains(t) ? m.triangleFabric[t] : 0)
                if f != fabric { s += "usemtl fabric\(f)\n"; fabric = f }
                let a = m.triangles[3 * t] + 1, b = m.triangles[3 * t + 1] + 1, c = m.triangles[3 * t + 2] + 1
                s += "f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)\n"
            }
        }
        return s
    }

    /// Binary glTF 2.0: one mesh, a primitive per fabric sharing the vertices.
    package static func glb(_ m: Mesh) throws -> Data {
        var bin = Data()
        func append<T>(_ a: [T]) -> (offset: Int, length: Int) {
            while bin.count % 4 != 0 { bin.append(0) }
            let offset = bin.count
            a.withUnsafeBytes { bin.append(contentsOf: $0) }
            return (offset, bin.count - offset)
        }
        let pos = append(m.positions.map { [$0.x, $0.y, $0.z] }.flatMap { $0 })
        let nor = append(m.normals.map { [$0.x, $0.y, $0.z] }.flatMap { $0 })
        let tex = append(m.uvs.map { [$0.x, 1 - $0.y] }.flatMap { $0 })
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for p in m.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        var views: [[String: Any]] = [
            ["buffer": 0, "byteOffset": pos.offset, "byteLength": pos.length, "target": 34962],
            ["buffer": 0, "byteOffset": nor.offset, "byteLength": nor.length, "target": 34962],
            ["buffer": 0, "byteOffset": tex.offset, "byteLength": tex.length, "target": 34962],
        ]
        var accessors: [[String: Any]] = [
            ["bufferView": 0, "componentType": 5126, "count": m.positions.count, "type": "VEC3", "min": [lo.x, lo.y, lo.z], "max": [hi.x, hi.y, hi.z]],
            ["bufferView": 1, "componentType": 5126, "count": m.positions.count, "type": "VEC3"],
            ["bufferView": 2, "componentType": 5126, "count": m.positions.count, "type": "VEC2"],
        ]
        var primitives: [[String: Any]] = []
        for f in m.fabrics.indices {
            var idx: [UInt32] = []
            for t in 0..<(m.triangles.count / 3) where Int(m.triangleFabric.indices.contains(t) ? m.triangleFabric[t] : 0) == f {
                idx += [m.triangles[3 * t], m.triangles[3 * t + 1], m.triangles[3 * t + 2]]
            }
            guard !idx.isEmpty else { continue }
            let r = append(idx)
            views.append(["buffer": 0, "byteOffset": r.offset, "byteLength": r.length, "target": 34963])
            accessors.append(["bufferView": views.count - 1, "componentType": 5125, "count": idx.count, "type": "SCALAR"])
            primitives.append(["attributes": ["POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2], "indices": accessors.count - 1, "material": f])
        }
        while bin.count % 4 != 0 { bin.append(0) }
        let materials: [[String: Any]] = m.fabrics.map { f in
            ["name": f.name, "doubleSided": true,
             "pbrMetallicRoughness": ["baseColorFactor": [f.color.x, f.color.y, f.color.z, 1], "metallicFactor": 0, "roughnessFactor": f.roughness]]
        }
        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "MetalRenderer Garment Designer"],
            "scene": 0, "scenes": [["nodes": [0]]], "nodes": [["mesh": 0, "name": "Garment"]],
            "meshes": [["primitives": primitives]], "materials": materials,
            "buffers": [["byteLength": bin.count]], "bufferViews": views, "accessors": accessors,
        ]
        var text = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while text.count % 4 != 0 { text.append(0x20) }
        var out = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        u32(0x4654_6C67); u32(2); u32(12 + 8 + text.count + 8 + bin.count)
        u32(text.count); u32(0x4E4F_534A); out.append(text)
        u32(bin.count); u32(0x004E_4942); out.append(bin)
        return out
    }

    /// Our cache (`.gcache`): "GCACHE01", the vertex count, the frame count and rate (UInt32, UInt32, Float32), the
    /// triangles (UInt32 count, then indices) so it stands alone, then every frame's places (Float32 xyz).
    package static func gcache(_ frames: [[SIMD3<Float>]], triangles: [UInt32], rate: Float = 30) -> Data {
        var out = Data("GCACHE01".utf8)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func f32(_ v: Float) { var x = v.bitPattern.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        u32(UInt32(frames.first?.count ?? 0)); u32(UInt32(frames.count)); f32(rate)
        u32(UInt32(triangles.count)); for t in triangles { u32(t) }
        for f in frames { for p in f { f32(p.x); f32(p.y); f32(p.z) } }
        return out
    }

    /// A `.gcache`'s frames and triangles back.
    package static func readGCache(_ data: Data) -> (frames: [[SIMD3<Float>]], triangles: [UInt32], rate: Float)? {
        guard data.count >= 24, String(data: data.prefix(8), encoding: .utf8) == "GCACHE01" else { return nil }
        var at = 8
        func u32() -> UInt32 { defer { at += 4 }; return data.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func f32() -> Float { Float(bitPattern: u32()) }
        let n = Int(u32()), count = Int(u32()), rate = f32(), tris = Int(u32())
        guard data.count >= 24 + tris * 4 + n * count * 12 else { return nil }
        let triangles = (0..<tris).map { _ in u32() }
        let frames = (0..<count).map { _ in (0..<n).map { _ in SIMD3(f32(), f32(), f32()) } }
        return (frames, triangles, rate)
    }

    /// A PC2 point cache: `frames` of every vertex's place, `rate` frames a second from `start` seconds.
    package static func pc2(_ frames: [[SIMD3<Float>]], start: Float = 0, rate: Float = 30) -> Data {
        var out = Data("POINTCACHE2\0".utf8)
        func i32(_ v: Int32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func f32(_ v: Float) { var x = v.bitPattern.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        i32(1)
        i32(Int32(frames.first?.count ?? 0))
        f32(start * rate)
        f32(1)
        i32(Int32(frames.count))
        for f in frames { for p in f { f32(p.x); f32(p.y); f32(p.z) } }
        return out
    }
}
