import EngineCore
import Foundation
import simd

/// A model asset on disk: `Assets/Models/<slug>.mrmesh`, a section file (SectionFile) that holds the document as it is
/// edited (every object's mesh, modifiers, materials and multires) and, beside it, what a scene draws: the rendered
/// objects' evaluated meshes as one triangle mesh in the model's space, with a material per triangle. The engine reads
/// only that part (`Rendered`), so placing a model never evaluates a modifier.
package enum ModelAsset {
    package static let key = "modelasset/1"
    package static let suffix = "mrmesh"

    /// What the engine draws of an asset.
    package struct Rendered {
        package var positions: [SIMD3<Float>]
        package var normals: [SIMD3<Float>]
        package var uvs: [SIMD2<Float>]          // glTF's convention (v down), as the engine's models
        package var indices: [UInt32]
        package var triangleMaterial: [UInt16]   // into `materials`
        package var materials: [MaterialSlot]
        package var triangleCount: Int { indices.count / 3 }

        package init(positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32],
                     triangleMaterial: [UInt16], materials: [MaterialSlot]) {
            self.positions = positions
            self.normals = normals
            self.uvs = uvs
            self.indices = indices
            self.triangleMaterial = triangleMaterial
            self.materials = materials
        }
    }

    private struct Meta: Codable {
        struct Object: Codable {
            var id: UUID
            var name: String
            var transform: ObjectTransform
            var modifiers: [Modifier]
            var materials: [MaterialSlot]
            var visible: Bool
            var renders: Bool
            var vertices: Int, edges: Int, faces: Int, corners: Int
            var multires: [Int]?          // sculpt, viewport, render, base faces, base corners, then each level's count
            var network: String?          // the procedural network (ProcGraph's JSON)
        }
        var name: String
        var objects: [Object]
        var active: Int?
        var renderedMaterials: [MaterialSlot]
    }

    private static let meta = SectionFile.id("meta")
    private static let vpos = SectionFile.id("vpos"), vflg = SectionFile.id("vflg")
    private static let edge = SectionFile.id("edge"), eflg = SectionFile.id("eflg"), ecrs = SectionFile.id("ecrs")
    private static let fsta = SectionFile.id("fsta"), cvrt = SectionFile.id("cvrt"), cuvs = SectionFile.id("cuvs")
    private static let fmat = SectionFile.id("fmat"), fset = SectionFile.id("fset"), fflg = SectionFile.id("fflg")
    private static let mres = SectionFile.id("mres")
    private static let epos = SectionFile.id("epos"), enrm = SectionFile.id("enrm"), euvs = SectionFile.id("euvs")
    private static let eidx = SectionFile.id("eidx"), etmt = SectionFile.id("etmt")

    /// Writes the document and what it renders (`rendered`: its evaluated meshes, made by the caller with the stack).
    package static func write(_ doc: ModelingDocument, rendered: Rendered, to url: URL) throws {
        var w = SectionFile.Writer()
        var objects: [Meta.Object] = []
        var vp: [SIMD3<Float>] = [], vf: [UInt8] = [], ed: [SIMD2<Int32>] = [], ef: [UInt8] = [], ec: [Float] = []
        var fs: [Int32] = [], cv: [Int32] = [], cu: [SIMD2<Float>] = [], fm: [UInt16] = [], fse: [Int32] = [], ff: [UInt8] = []
        var md: [SIMD3<Float>] = []
        for o in doc.objects {
            let m = o.mesh
            vp += m.positions; vf += m.vertFlags
            ed += m.edges; ef += m.edgeFlags; ec += m.edgeCrease
            fs += m.faceStart.dropFirst(); cv += m.cornerVerts; cu += m.cornerUVs
            fm += m.faceMaterial; fse += m.faceSet; ff += m.faceFlags
            var multires: [Int]?
            if let r = o.multires {
                multires = [r.sculptLevel, r.viewportLevel, r.renderLevel, r.baseFaces, r.baseCorners] + r.displacements.map(\.count)
                for d in r.displacements { md += d }
            }
            objects.append(Meta.Object(id: o.id, name: o.name, transform: o.transform, modifiers: o.modifiers, materials: o.materials,
                                       visible: o.visible, renders: o.renders, vertices: m.vertexCount, edges: m.edgeCount,
                                       faces: m.faceCount, corners: m.cornerCount, multires: multires, network: o.network))
        }
        let json = try JSONEncoder().encode(Meta(name: doc.name, objects: objects, active: doc.active, renderedMaterials: rendered.materials))
        w.add(meta, [UInt8](json))
        w.add(vpos, vp); w.add(vflg, vf)
        w.add(edge, ed); w.add(eflg, ef); w.add(ecrs, ec)
        w.add(fsta, fs); w.add(cvrt, cv); w.add(cuvs, cu)
        w.add(fmat, fm); w.add(fset, fse); w.add(fflg, ff)
        w.add(mres, md)
        w.add(epos, rendered.positions); w.add(enrm, rendered.normals); w.add(euvs, rendered.uvs)
        w.add(eidx, rendered.indices); w.add(etmt, rendered.triangleMaterial)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try w.write(to: url, key: key)
    }

    /// The document an asset holds, nil if the file isn't one.
    package static func readDocument(_ url: URL) -> ModelingDocument? {
        guard let file = SectionFile(url: url, key: key), let bytes: [UInt8] = file.array(meta),
              let m = try? JSONDecoder().decode(Meta.self, from: Data(bytes)),
              let vp: [SIMD3<Float>] = file.array(vpos), let vf: [UInt8] = file.array(vflg),
              let ed: [SIMD2<Int32>] = file.array(edge), let ef: [UInt8] = file.array(eflg), let ec: [Float] = file.array(ecrs),
              let fs: [Int32] = file.array(fsta), let cv: [Int32] = file.array(cvrt), let cu: [SIMD2<Float>] = file.array(cuvs),
              let fm: [UInt16] = file.array(fmat), let fse: [Int32] = file.array(fset), let ff: [UInt8] = file.array(fflg)
        else { return nil }
        let md: [SIMD3<Float>] = file.array(mres) ?? []
        var doc = ModelingDocument()
        doc.name = m.name
        doc.asset = url.deletingPathExtension().lastPathComponent
        var v0 = 0, e0 = 0, f0 = 0, c0 = 0, d0 = 0
        for o in m.objects {
            guard v0 + o.vertices <= vp.count, e0 + o.edges <= ed.count, f0 + o.faces <= fs.count, c0 + o.corners <= cv.count else { return nil }
            var d = EditMesh.Draft()
            d.positions = Array(vp[v0..<(v0 + o.vertices)])
            d.vertFlags = Array(vf[v0..<(v0 + o.vertices)])
            d.faceStart = [0] + fs[f0..<(f0 + o.faces)]   // each object's own, from 0
            d.cornerVerts = Array(cv[c0..<(c0 + o.corners)])
            d.cornerUVs = Array(cu[c0..<(c0 + o.corners)])
            d.faceMaterial = Array(fm[f0..<(f0 + o.faces)])
            d.faceSet = Array(fse[f0..<(f0 + o.faces)])
            d.faceFlags = Array(ff[f0..<(f0 + o.faces)])
            for e in 0..<o.edges {
                let edge = ed[e0 + e]
                d.looseEdges.append(edge)
                if ef[e0 + e] != 0 || ec[e0 + e] != 0 { d.edgeAttributes[EditMesh.key(edge.x, edge.y)] = (ef[e0 + e], ec[e0 + e]) }
            }
            var object = ModelObject(name: o.name, mesh: EditMesh(d))
            object.id = o.id
            object.transform = o.transform
            object.modifiers = o.modifiers
            object.materials = o.materials
            object.visible = o.visible
            object.renders = o.renders
            object.network = o.network
            if let r = o.multires, r.count >= 5 {
                var data = MultiresData()
                (data.sculptLevel, data.viewportLevel, data.renderLevel, data.baseFaces, data.baseCorners) = (r[0], r[1], r[2], r[3], r[4])
                for n in r.dropFirst(5) {
                    guard d0 + n <= md.count else { break }
                    data.displacements.append(Array(md[d0..<(d0 + n)]))
                    d0 += n
                }
                object.multires = data
            }
            doc.objects.append(object)
            v0 += o.vertices; e0 += o.edges; f0 += o.faces; c0 += o.corners
        }
        doc.active = m.active.flatMap { $0 < doc.objects.count ? $0 : nil }
        return doc
    }

    /// What an asset renders, nil if the file isn't one.
    package static func readRendered(_ url: URL) -> Rendered? {
        guard let file = SectionFile(url: url, key: key), let bytes: [UInt8] = file.array(meta),
              let m = try? JSONDecoder().decode(Meta.self, from: Data(bytes)),
              let p: [SIMD3<Float>] = file.array(epos), let n: [SIMD3<Float>] = file.array(enrm), let uv: [SIMD2<Float>] = file.array(euvs),
              let ix: [UInt32] = file.array(eidx), let tm: [UInt16] = file.array(etmt),
              n.count == p.count, uv.count == p.count, tm.count * 3 == ix.count
        else { return nil }
        return Rendered(positions: p, normals: n, uvs: uv, indices: ix, triangleMaterial: tm, materials: m.renderedMaterials)
    }
}

/// The asset library: model assets in `Assets/Models` (or `METALRENDERER_MODELS`; `none`: nothing is read or written).
package enum ModelStore {
    package static var folder: URL? {
        switch ProcessInfo.processInfo.environment["METALRENDERER_MODELS"] {
        case "none": return nil
        case let path? where !path.isEmpty: return URL(fileURLWithPath: path)
        default: return Assets.directory.appendingPathComponent("Models")
        }
    }

    package static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let s = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return s.isEmpty ? "model" : s
    }

    package static func url(_ slug: String, in folder: URL? = ModelStore.folder) -> URL? {
        folder?.appendingPathComponent(slug).appendingPathExtension(ModelAsset.suffix)
    }

    /// The library's assets by slug, newest first.
    package static func list(in folder: URL? = ModelStore.folder) -> [(slug: String, modified: Date)] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        return files.filter { $0.pathExtension == ModelAsset.suffix }.map { url in
            (url.deletingPathExtension().lastPathComponent,
             (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.modified > $1.modified }
    }
}
