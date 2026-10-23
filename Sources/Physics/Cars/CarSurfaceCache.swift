import EngineCore
import Foundation
import simd

/// A car's panels from the cache (GeneratedCache): embedding a detailed model's vertices in the node hull is most of
/// a car scene's load (0.5-1.9 s a model in release), and the same every time for the same model on the same crash
/// frame. The file is named by both (the model's meshes and what the embedding reads of them, the blueprint's spec,
/// nodes, hull and parts), so a change of either is another file; a change of how `CarSurface` embeds takes a new
/// `version`.
extension CarSurface {
    /// Of `CarSurface.init`'s output: a change of it makes other files in the cache.
    package static let version = 1

    /// `CarSurface(b, model: model)`, from the cache or into it.
    package static func cached(_ b: CarBlueprint, model: CarModel) -> CarSurface {
        let name = cacheName(b, model: model), key = "car surface v\(version)"
        if let file = GeneratedCache.load(name, key: key), let surface = CarSurface(file) { return surface }
        let surface = CarSurface(b, model: model)
        GeneratedCache.store(name, key: key, surface.writer())
        return surface
    }

    /// The cache's file for `model` on `b`.
    package static func cacheName(_ b: CarBlueprint, model: CarModel) -> String {
        var hasher = GeneratedCache.Hasher()
        hasher.add(String(describing: b.spec))
        hasher.add(b.nodes)
        hasher.add(b.hull)
        hasher.add(b.hullPart)
        for p in b.parts {
            hasher.add([p.kind.rawValue, UInt32(bitPattern: Int32(p.side))])
            hasher.add(p.triangles)
        }
        hasher.add([UInt32(model.windows)])
        for m in model.meshes {
            hasher.add(m.positions)
            hasher.add(m.normals)
            hasher.add(m.uvs)
            hasher.add(m.indices)
            hasher.add([Int32(m.material), Int32(m.role.rawValue), Int32(m.part.map { Int($0.rawValue) } ?? -1), Int32(m.side), Int32(m.window)])
        }
        return "car-\(hasher.name()).sect"
    }

    // MARK: The file

    /// Each part's sections (body "b...", glass "g..."): positions, normals, indices, texture coordinates, materials,
    /// flags; per vertex how many hull triangles it follows and how many triangles ring it, and those all in a row
    /// (a triangle's index in w's bits over its place); the panes (lamp, part, how many triangles) and their triangles.
    private static func ids(_ prefix: Character) -> [UInt32] {
        ["pos", "nrm", "idx", "uvs", "mat", "flg", "emc", "emb", "rnc", "rng"].map { SectionFile.id("\(prefix)\($0)") }
    }

    private func writer() -> SectionFile.Writer {
        var w = SectionFile.Writer()
        for (prefix, part) in [("b" as Character, body), ("g", glass)] {
            let id = CarSurface.ids(prefix)
            w.add(id[0], part.mesh.positions)
            w.add(id[1], part.mesh.normals)
            w.add(id[2], part.mesh.indices)
            w.add(id[3], part.uvs)
            w.add(id[4], part.materials)
            w.add(id[5], part.flags)
            w.add(id[6], part.embedding.map { UInt32($0.count) })
            w.add(id[7], part.embedding.flatMap { $0.map { SIMD4($0.bary, Float(bitPattern: UInt32($0.triangle))) } })
            w.add(id[8], part.rings.map { UInt32($0.count) })
            w.add(id[9], part.rings.flatMap { $0 })
        }
        w.add(SectionFile.id("pane"), panes.map { SIMD3<UInt32>($0.lamp ? 1 : 0, UInt32($0.part), UInt32($0.hull.count)) })
        w.add(SectionFile.id("phul"), panes.flatMap { $0.hull.map { UInt32($0) } })
        return w
    }

    /// The surface in `file`, nil if any of it is missing or doesn't add up.
    private init?(_ file: SectionFile) {
        for (prefix, isBody) in [("b" as Character, true), ("g", false)] {
            let id = CarSurface.ids(prefix)
            guard let positions: [SIMD3<Float>] = file.array(id[0]), let normals: [SIMD3<Float>] = file.array(id[1]),
                  let indices: [UInt32] = file.array(id[2]), let uvs: [SIMD2<Float>] = file.array(id[3]),
                  let materials: [UInt8] = file.array(id[4]), let flags: [UInt32] = file.array(id[5]),
                  let embedCounts: [UInt32] = file.array(id[6]), let embeds: [SIMD4<Float>] = file.array(id[7]),
                  let ringCounts: [UInt32] = file.array(id[8]), let rings: [SIMD2<UInt32>] = file.array(id[9])
            else { return nil }
            let n = positions.count
            guard normals.count == n, uvs.count == n, flags.count == n, embedCounts.count == n, ringCounts.count == n,
                  materials.count == indices.count / 3, embedCounts.reduce(0, { $0 + Int($1) }) == embeds.count,
                  ringCounts.reduce(0, { $0 + Int($1) }) == rings.count else { return nil }
            var part = Part(mesh: (positions, normals, indices), uvs: uvs, materials: materials, flags: flags)
            part.embedding.reserveCapacity(n)
            part.rings.reserveCapacity(n)
            var e = 0, r = 0
            for v in 0..<n {
                let ec = Int(embedCounts[v]), rc = Int(ringCounts[v])
                part.embedding.append(embeds[e..<(e + ec)].map { (triangle: Int($0.w.bitPattern), bary: SIMD3($0.x, $0.y, $0.z)) })
                part.rings.append(Array(rings[r..<(r + rc)]))
                e += ec
                r += rc
            }
            if isBody { body = part } else { glass = part }
        }
        guard let heads: [SIMD3<UInt32>] = file.array(SectionFile.id("pane")), let hull: [UInt32] = file.array(SectionFile.id("phul")),
              heads.reduce(0, { $0 + Int($1.z) }) == hull.count else { return nil }
        var at = 0
        panes = heads.map { h in
            defer { at += Int(h.z) }
            return Pane(lamp: h.x != 0, part: Int(h.y), hull: hull[at..<(at + Int(h.z))].map { Int($0) })
        }
    }
}
