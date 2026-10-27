import EngineCore
import Foundation
import Modeling
import simd

/// A procedural asset (Houdini's digital asset): a network, its promoted parameters (the graph's interface) and the
/// material slots its `material` names map to. Saved as `Assets/Procedural/<slug>.proc.json`; a scene places it as
/// `proc:<slug>`, or `proc:<slug>?height=2.5&seed=3` with its own values, and cooks it when it loads.
package struct ProcAsset: Codable, Equatable {
    package var format = 1
    package var name: String
    package var graph: ProcGraph
    package var materials: [MaterialSlot] = []

    package init(name: String, graph: ProcGraph, materials: [MaterialSlot] = []) {
        self.name = name
        self.graph = graph
        self.materials = materials
    }

    /// What a placed copy gets: a mesh for the scene, and other assets to place at its points (a point's string
    /// attribute `instance` names one — `mesh:<slug>`, `proc:<slug>`, `prefab:<name>` — at the point's frame: P,
    /// orient or N and up, pscale and scale, as Copy to Points places).
    package struct Cooked {
        package var rendered: ModelAsset.Rendered
        package var instances: [(asset: String, transform: float4x4)]
    }

    /// Text values (a reference's) as the interface's parameters, of the kind each default is.
    package func values(_ raw: [String: String]) -> [String: ProcParam] {
        var out: [String: ProcParam] = [:]
        for p in graph.interface {
            guard let s = raw[p.name] else { continue }
            let numbers = s.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
            switch p.value {
            case .float: if let v = numbers.first { out[p.name] = .float(v) }
            case .int: if let v = numbers.first { out[p.name] = .int(Int(v)) }
            case .bool: out[p.name] = .bool(s == "1" || s.lowercased() == "true")
            case .vec2: if numbers.count == 2 { out[p.name] = .vec2(SIMD2(numbers[0], numbers[1])) }
            case .vec3: if numbers.count == 3 { out[p.name] = .vec3(SIMD3(numbers[0], numbers[1], numbers[2])) }
            case .vec4: if numbers.count == 4 { out[p.name] = .vec4(SIMD4(numbers[0], numbers[1], numbers[2], numbers[3])) }
            case .string: out[p.name] = .string(s)
            default: break
            }
        }
        return out
    }

    /// The asset with its asset nodes' contents put in from the library as it is now.
    package func synced(_ environment: ProcEnvironment) -> ProcAsset {
        var a = self
        a.graph = graph.syncingDefinitions(environment.definition)
        return a
    }

    /// The material slots: the asset's, then those of the assets its asset nodes put in, for the names it hasn't.
    package func slots(_ environment: ProcEnvironment) -> [MaterialSlot] {
        var out = materials
        graph.walk { n, _ in
            guard let slug = n.definition, let d = environment.definition(slug) else { return }
            for m in d.materials where !out.contains(where: { $0.name == m.name }) { out.append(m) }
        }
        return out
    }

    /// The asset cooked with `values`: its output node's geometry as a scene's mesh, and the instances it asks for.
    package func cook(_ values: [String: ProcParam], environment: ProcEnvironment = .assets) -> Result<Cooked, ProcCookError> {
        let a = synced(environment)
        let g = a.graph.applying(values)
        guard let out = g.outputNode else { return .failure(ProcCookError("\(name): an empty network")) }
        let cooker = ProcCooker(environment: environment)
        let slots = a.slots(environment)
        return cooker.cook(g, out).map { geo in
            Cooked(rendered: ProcAsset.rendered(geo, slots: slots), instances: ProcAsset.instances(geo))
        }
    }

    /// The output's cook key on each of `frames` (nil: nothing to cook): frames with one key cook the same. Nothing is
    /// cooked to find them.
    package func frameKeys(_ values: [String: ProcParam], environment: ProcEnvironment = .assets, frames: ClosedRange<Int>) -> [UInt64]? {
        let g = graph.syncingDefinitions(environment.definition).applying(values)
        guard let out = g.outputNode else { return nil }
        let cooker = ProcCooker(environment: environment)
        return frames.map { f in
            cooker.environment.frame = Float(f)
            return cooker.key(g, out) ?? 0
        }
    }

    /// The geometry as the engine draws it: its polygons as triangles with corner normals (smooth with sharp edges
    /// past 60°, or its N), glTF's UVs, a material slot per triangle (by `material` name, the asset's slots' colours).
    package static func rendered(_ geo: ProcGeo, slots: [MaterialSlot]) -> ModelAsset.Rendered {
        let (mesh, names) = geo.editMesh()
        let t = TriangleMesh(mesh)
        let materials = names.map { n in slots.first { $0.name == n } ?? MaterialSlot(name: n) }
        return ModelAsset.Rendered(positions: t.positions, normals: t.normals, uvs: t.uvs.map { SIMD2($0.x, 1 - $0.y) },
                                   indices: t.indices, triangleMaterial: t.triangleMaterial.map { min($0, UInt16(max(0, materials.count - 1))) },
                                   materials: materials)
    }

    /// The points that name an asset to place (their `instance`), each with its frame.
    package static func instances(_ geo: ProcGeo) -> [(asset: String, transform: float4x4)] {
        guard case .string(let rows, let table)? = geo.points["instance"] else { return [] }
        let frames = ScatterNodes.frames(geo)
        return (0..<geo.pointCount).compactMap { i in
            let a = table[Int(rows[i])]
            return a.isEmpty ? nil : (a, frames[i])
        }
    }

    // MARK: The cache

    /// Bumped when what a cook makes of the same asset changes.
    package static let version = 1

    /// `cook(values)`, from the generated cache (GeneratedCache) or into it: the file is named by the asset (its JSON,
    /// with the library's assets its asset nodes put in), the values, the cooker's version and the model assets its
    /// File nodes read.
    package func cached(_ values: [String: ProcParam], environment: ProcEnvironment = .assets) -> Result<Cooked, ProcCookError> {
        let name = cacheName(values, environment: environment), key = "proc asset v\(ProcAsset.version).\(ProcCooker.version)"
        if let file = GeneratedCache.load(name, key: key), let c = ProcAsset.read(file) { return .success(c) }
        let result = cook(values, environment: environment)
        if case .success(let c) = result { GeneratedCache.store(name, key: key, ProcAsset.writer(c)) }
        return result
    }

    package func cacheName(_ values: [String: ProcParam], environment: ProcEnvironment) -> String {
        var h = GeneratedCache.Hasher()
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let a = synced(environment)
        h.add((try? e.encode(a)).map { String(decoding: $0, as: UTF8.self) } ?? name)
        for m in a.slots(environment).dropFirst(materials.count) { h.add("\(m)") }
        for k in values.keys.sorted() {
            var p = Hasher64()
            values[k]!.hash(into: &p)
            h.add("\(k)=\(p.value)")
        }
        a.graph.walk { n, _ in
            guard n.kind == .file else { return }
            let f = n.param("file").string
            h.add("\(f)@\(environment.stamp(f))")
        }
        h.add("frame=\(environment.frame)")
        return "proc-" + h.name()
    }

    private static let pos = SectionFile.id("ppos"), nrm = SectionFile.id("pnrm"), uvs = SectionFile.id("puvs")
    private static let idx = SectionFile.id("pidx"), tmt = SectionFile.id("ptmt"), meta = SectionFile.id("pmet")
    private static let inst = SectionFile.id("pins")

    private struct Meta: Codable {
        var materials: [MaterialSlot]
        var instances: [String]
    }

    static func writer(_ c: Cooked) -> SectionFile.Writer {
        var w = SectionFile.Writer()
        w.add(pos, c.rendered.positions); w.add(nrm, c.rendered.normals); w.add(uvs, c.rendered.uvs)
        w.add(idx, c.rendered.indices); w.add(tmt, c.rendered.triangleMaterial)
        w.add(inst, c.instances.map(\.transform))
        let m = Meta(materials: c.rendered.materials, instances: c.instances.map(\.asset))
        w.add(meta, [UInt8]((try? JSONEncoder().encode(m)) ?? Data()))
        return w
    }

    static func read(_ file: SectionFile) -> Cooked? {
        guard let p: [SIMD3<Float>] = file.array(pos), let n: [SIMD3<Float>] = file.array(nrm), let uv: [SIMD2<Float>] = file.array(uvs),
              let ix: [UInt32] = file.array(idx), let tm: [UInt16] = file.array(tmt), let bytes: [UInt8] = file.array(meta),
              let m = try? JSONDecoder().decode(Meta.self, from: Data(bytes)) else { return nil }
        let transforms: [float4x4] = file.array(inst) ?? []
        guard transforms.count == m.instances.count else { return nil }
        return Cooked(rendered: ModelAsset.Rendered(positions: p, normals: n, uvs: uv, indices: ix, triangleMaterial: tm, materials: m.materials),
                      instances: Array(zip(m.instances, transforms)))
    }
}

/// A placed procedural asset's reference: `proc:<slug>`, then its values (`?name=value&name=1,2,3`).
package struct ProcAssetReference: Equatable {
    package var slug: String
    package var values: [String: String] = [:]

    package init(slug: String, values: [String: String] = [:]) {
        self.slug = slug
        self.values = values
    }

    /// From what follows `proc:`.
    package init(_ text: String) {
        let parts = text.split(separator: "?", maxSplits: 1)
        slug = parts.first.map(String.init) ?? ""
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                values[String(kv[0]).removingPercentEncoding ?? String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
    }

    /// The frame its expressions read (`$F`, `$T`): its `frame=` value, else 1.
    package var frame: Float { values["frame"].flatMap(Float.init) ?? 1 }
    /// Pinned to its `frame=`: it doesn't play.
    package var pinned: Bool { values["frame"] != nil }
    /// The frames it plays (`frames=12-48`; nil: its network's range).
    package var frames: ClosedRange<Int>? {
        guard let s = values["frames"] else { return nil }
        let parts = s.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts[0] <= parts[1] else { return nil }
        return parts[0]...parts[1]
    }

    /// The scene file's asset string (`proc:<slug>?…`).
    package var asset: String {
        var s = "proc:\(slug)"
        if !values.isEmpty {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.,"))
            s += "?" + values.keys.sorted().map { k in
                "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(values[k]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? values[k]!)"
            }.joined(separator: "&")
        }
        return s
    }

    /// A parameter's value as a reference writes it.
    package static func text(_ p: ProcParam) -> String {
        switch p {
        case .vec2(let v): "\(v.x),\(v.y)"
        case .vec3(let v): "\(v.x),\(v.y),\(v.z)"
        case .vec4(let v): "\(v.x),\(v.y),\(v.z),\(v.w)"
        default: p.string
        }
    }
}

/// The procedural asset library: `Assets/Procedural` (or `METALRENDERER_PROCEDURAL`; `none`: nothing is read or written).
package enum ProcStore {
    package static let suffix = "proc.json"

    package static var folder: URL? {
        switch ProcessInfo.processInfo.environment["METALRENDERER_PROCEDURAL"] {
        case "none": return nil
        case let path? where !path.isEmpty: return URL(fileURLWithPath: path)
        default: return Assets.directory.appendingPathComponent("Procedural")
        }
    }

    package static func url(_ slug: String, in folder: URL? = ProcStore.folder) -> URL? {
        folder?.appendingPathComponent("\(slug).\(suffix)")
    }

    package static func read(_ slug: String, in folder: URL? = ProcStore.folder) -> ProcAsset? {
        guard let url = url(slug, in: folder), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProcAsset.self, from: data)
    }

    /// `read`, kept until the file changes (asset nodes put their definitions in on every edit of a network).
    package static func cachedRead(_ slug: String, in folder: URL? = ProcStore.folder) -> ProcAsset? {
        guard let url = url(slug, in: folder) else { return nil }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        reads.lock.lock()
        defer { reads.lock.unlock() }
        if let (d, a) = reads.cache[url], d == date { return a }
        let a = date == nil ? nil : read(slug, in: folder)
        reads.cache[url] = (date, a)
        return a
    }

    private final class Reads: @unchecked Sendable {
        let lock = NSLock()
        var cache: [URL: (Date?, ProcAsset?)] = [:]
    }
    private static let reads = Reads()

    package static func write(_ asset: ProcAsset, slug: String, in folder: URL? = ProcStore.folder) throws {
        guard let url = url(slug, in: folder) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(asset).write(to: url, options: .atomic)
    }

    /// The library's assets by slug, newest first.
    package static func list(in folder: URL? = ProcStore.folder) -> [String] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files.filter { $0.lastPathComponent.hasSuffix("." + suffix) }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .map { String($0.lastPathComponent.dropLast(suffix.count + 1)) }
    }
}
