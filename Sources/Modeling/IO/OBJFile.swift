import Foundation
import simd

/// Wavefront OBJ, both ways: polygons (not triangles only), UVs per corner, `o` objects, `usemtl` material slots and
/// the `.mtl` beside it (Kd, Ks-free PBR: Pr, Pm, Ke, d). Smooth groups: `s` off makes faces flat, any other smooth;
/// a file without `s` is smooth where it gives normals. Y is up, as in Blender's OBJ export with its default axes.
package enum OBJFile {
    package enum Failure: Error { case unreadable(String), noGeometry }

    // MARK: Read

    package static func read(_ url: URL) throws -> [ModelObject] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) ?? String(contentsOf: url, encoding: .isoLatin1) else {
            throw Failure.unreadable(url.path)
        }
        var library: [String: MaterialSlot] = [:]
        let objects = parse(text) { name in
            let mtl = url.deletingLastPathComponent().appendingPathComponent(name)
            if let t = try? String(contentsOf: mtl, encoding: .utf8) { library.merge(parseMTL(t)) { a, _ in a } }
        } materialNamed: { library[$0] }
        guard !objects.isEmpty else { throw Failure.noGeometry }
        return objects
    }

    /// The objects in OBJ text; `mtllib` names are handed to `loadLibrary`, and `materialNamed` gives a slot's looks.
    package static func parse(_ text: String, loadLibrary: (String) -> Void = { _ in },
                              materialNamed: (String) -> MaterialSlot? = { _ in nil }) -> [ModelObject] {
        var positions: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
        var hasNormals = false
        struct Building {
            var name: String
            var draft = EditMesh.Draft()
            var vertexMap: [Int32: Int32] = [:]
            var slots: [String] = []
            var slot: UInt16 = 0
        }
        var objects: [Building] = []
        var current = Building(name: "Object")
        var smooth: Bool?
        func finish() {
            guard current.draft.faceCount > 0 || !current.draft.looseEdges.isEmpty else { return }
            // The object's vertices in the file's order (they were added as faces first used them).
            let order = current.vertexMap.sorted { $0.key < $1.key }
            var renumber = [Int32](repeating: 0, count: order.count)
            for (i, (global, l)) in order.enumerated() {
                renumber[Int(l)] = Int32(i)
                current.draft.positions[i] = positions[Int(global)]
            }
            for c in 0..<current.draft.cornerVerts.count { current.draft.cornerVerts[c] = renumber[Int(current.draft.cornerVerts[c])] }
            for e in 0..<current.draft.looseEdges.count {
                current.draft.looseEdges[e] = SIMD2(renumber[Int(current.draft.looseEdges[e].x)], renumber[Int(current.draft.looseEdges[e].y)])
            }
            objects.append(current)
        }
        func local(_ global: Int32) -> Int32 {
            if let l = current.vertexMap[global] { return l }
            let l = current.draft.addVertex(positions[Int(global)])
            current.vertexMap[global] = l
            return l
        }
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = parts.first else { continue }
            func float(_ i: Int) -> Float { i < parts.count ? Float(parts[i]) ?? 0 : 0 }
            switch head {
            case "v": positions.append(SIMD3(float(1), float(2), float(3)))
            case "vt": uvs.append(SIMD2(float(1), float(2)))
            case "vn": hasNormals = true
            case "o", "g":
                // A new object (a group too, as Blender's importer splits by group), or a name for the one not begun.
                let name = parts.dropFirst().joined(separator: " ")
                if current.draft.faceCount > 0 || !current.draft.looseEdges.isEmpty {
                    finish()
                    current = Building(name: name.isEmpty ? "Object" : name)
                } else if !name.isEmpty { current.name = name }
            case "s": smooth = !(parts.count > 1 && (parts[1] == "off" || parts[1] == "0"))
            case "mtllib": loadLibrary(parts.dropFirst().joined(separator: " "))
            case "usemtl":
                let name = parts.dropFirst().joined(separator: " ")
                if let i = current.slots.firstIndex(of: name) { current.slot = UInt16(i) } else {
                    current.slots.append(name)
                    current.slot = UInt16(current.slots.count - 1)
                }
            case "f", "l":
                var verts: [Int32] = [], corner: [SIMD2<Float>] = []
                for token in parts.dropFirst() {
                    let idx = token.split(separator: "/", omittingEmptySubsequences: false)
                    guard let vi = Int(idx[0]) else { continue }
                    let gv = vi < 0 ? positions.count + vi : vi - 1
                    guard gv >= 0 && gv < positions.count else { continue }
                    verts.append(local(Int32(gv)))
                    if idx.count > 1, let ti = Int(idx[1]) {
                        let gt = ti < 0 ? uvs.count + ti : ti - 1
                        corner.append(gt >= 0 && gt < uvs.count ? uvs[gt] : .zero)
                    } else { corner.append(.zero) }
                }
                if head == "l" {
                    for k in 0..<max(0, verts.count - 1) { current.draft.looseEdges.append(SIMD2(verts[k], verts[k + 1])) }
                } else if verts.count >= 3 && Set(verts).count == verts.count {
                    let s = smooth ?? hasNormals
                    current.draft.addFace(verts, uvs: corner, material: current.slot, flags: s ? EditMesh.Flag.smooth : 0)
                }
            default: continue
            }
        }
        finish()
        return objects.map { b in
            var o = ModelObject(name: b.name, mesh: EditMesh(b.draft))
            if !b.slots.isEmpty { o.materials = b.slots.map { materialNamed($0) ?? MaterialSlot(name: $0) } }
            return o
        }
    }

    package static func parseMTL(_ text: String) -> [String: MaterialSlot] {
        var out: [String: MaterialSlot] = [:]
        var current: MaterialSlot?
        func flush() { if let c = current { out[c.name] = c } }
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = parts.first else { continue }
            func f(_ i: Int) -> Float { i < parts.count ? Float(parts[i]) ?? 0 : 0 }
            switch head {
            case "newmtl": flush(); current = MaterialSlot(name: parts.dropFirst().joined(separator: " "))
            case "Kd":
                let alpha = current?.baseColor.w ?? 1
                current?.baseColor = SIMD4(f(1), f(2), f(3), alpha)
            case "d": current?.baseColor.w = f(1)
            case "Pr": current?.roughness = f(1)
            case "Pm": current?.metallic = f(1)
            case "Ke": current?.emission = SIMD3(f(1), f(2), f(3))
            case "Ns" where current != nil:
                // Phong exponent to roughness, as Blender's importer: 1 - sqrt(Ns / 1000).
                current?.roughness = 1 - min(1, (f(1) / 1000).squareRoot())
            default: continue
            }
        }
        flush()
        return out
    }

    // MARK: Write

    /// The objects (their meshes in edit space under their transforms, as Blender writes them with "apply
    /// transform") as OBJ text, and the `.mtl` text of their slots.
    package static func text(_ objects: [(name: String, mesh: EditMesh, transform: float4x4, materials: [MaterialSlot])],
                             library: String?) -> (obj: String, mtl: String) {
        var obj = "# MetalRenderer Modeller\n"
        if let library { obj += "mtllib \(library)\n" }
        var mtl = "# MetalRenderer Modeller\n"
        var written = Set<String>()
        var vBase = 1, tBase = 1
        for o in objects {
            obj += "o \(o.name)\n"
            let m = o.mesh
            for p in m.positions {
                let w = o.transform * SIMD4(p, 1)
                obj += "v \(fmt(w.x)) \(fmt(w.y)) \(fmt(w.z))\n"
            }
            for uv in m.cornerUVs { obj += "vt \(fmt(uv.x)) \(fmt(uv.y))\n" }
            var slot = -1
            var smooth: Bool?
            for f in 0..<m.faceCount {
                let s = Int(m.faceMaterial[f])
                if s != slot, s < o.materials.count {
                    slot = s
                    obj += "usemtl \(o.materials[s].name)\n"
                }
                let sm = m.faceFlags[f] & EditMesh.Flag.smooth != 0
                if sm != smooth { smooth = sm; obj += sm ? "s 1\n" : "s off\n" }
                obj += "f" + m.corners(f).map { " \(vBase + Int(m.cornerVerts[$0]))/\(tBase + $0)" }.joined() + "\n"
            }
            // Loose edges.
            let t = MeshTopology(m)
            for e in 0..<m.edgeCount where t.faceCount(ofEdge: e) == 0 {
                obj += "l \(vBase + Int(m.edges[e].x)) \(vBase + Int(m.edges[e].y))\n"
            }
            vBase += m.vertexCount
            tBase += m.cornerCount
            for s in o.materials where written.insert(s.name).inserted {
                mtl += "newmtl \(s.name)\nKd \(fmt(s.baseColor.x)) \(fmt(s.baseColor.y)) \(fmt(s.baseColor.z))\n"
                mtl += "d \(fmt(s.baseColor.w))\nPr \(fmt(s.roughness))\nPm \(fmt(s.metallic))\n"
                mtl += "Ke \(fmt(s.emission.x)) \(fmt(s.emission.y)) \(fmt(s.emission.z))\n"
            }
        }
        return (obj, mtl)
    }

    package static func write(_ objects: [(name: String, mesh: EditMesh, transform: float4x4, materials: [MaterialSlot])], to url: URL) throws {
        let mtlURL = url.deletingPathExtension().appendingPathExtension("mtl")
        let (obj, mtl) = text(objects, library: mtlURL.lastPathComponent)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try obj.write(to: url, atomically: true, encoding: .utf8)
        try mtl.write(to: mtlURL, atomically: true, encoding: .utf8)
    }

    private static func fmt(_ v: Float) -> String {
        let s = String(format: "%.9g", v)
        return s == "-0" ? "0" : s
    }
}
