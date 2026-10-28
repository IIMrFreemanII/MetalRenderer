import Characters
import EngineCore
import Foundation
import Physics
import simd

/// A garment draped once on a body, then worn by many: each of its vertices bound to the body's nearest triangle (its
/// barycentric place there and its distance out along the normal), so that any body of the same mesh (every generated
/// character shares CharacterBase's) wears it where its own skin is, skinned with that triangle's bones. The body
/// under the cloth is cut away (it would show through as the clips bend it).
package struct GarmentBinding {
    package struct Attachment {
        package var triangle: UInt32
        package var weights: SIMD2<Float>   // the triangle's second and third corners' (the first's: 1 - x - y)
        package var offset: Float           // out along the interpolated normal (metres)
    }
    package var attachments: [Attachment]
    package var build: GarmentBuild

    /// `positions` (a drape of `build`) bound to `body`'s full mesh in its bind pose.
    package init(build: GarmentBuild, positions: [SIMD3<Float>], body: SkinnedCharacter) {
        self.build = build
        let p = body.positions, idx = body.indices, n = body.normals
        // The body's triangles binned by their boxes, 4 cm cells.
        let cell: Float = 0.04
        var bins: [SIMD3<Int32>: [UInt32]] = [:]
        func key(_ q: SIMD3<Float>) -> SIMD3<Int32> { SIMD3<Int32>((q / cell).rounded(.down)) }
        for t in 0..<(idx.count / 3) {
            let a = p[Int(idx[3 * t])], b = p[Int(idx[3 * t + 1])], c = p[Int(idx[3 * t + 2])]
            let lo = key(simd_min(simd_min(a, b), c)), hi = key(simd_max(simd_max(a, b), c))
            for z in lo.z...hi.z { for y in lo.y...hi.y { for x in lo.x...hi.x { bins[SIMD3(x, y, z), default: []].append(UInt32(t)) } } }
        }
        var out = [Attachment](repeating: Attachment(triangle: 0, weights: .zero, offset: 0), count: positions.count)
        out.withUnsafeMutableBufferPointer { o in
            DispatchQueue.concurrentPerform(iterations: positions.count) { i in
                let q = positions[i]
                var best: (t: UInt32, d: Float, w: SIMD3<Float>)?
                for ring in 1...4 {
                    let k = key(q), r = Int32(ring)
                    for z in (k.z - r)...(k.z + r) { for y in (k.y - r)...(k.y + r) { for x in (k.x - r)...(k.x + r) {
                        for t in bins[SIMD3(x, y, z)] ?? [] {
                            let a = p[Int(idx[3 * Int(t)])], b = p[Int(idx[3 * Int(t) + 1])], c = p[Int(idx[3 * Int(t) + 2])]
                            let (closest, w) = GarmentBinding.closest(q, a, b, c)
                            let d = simd_distance(q, closest)
                            if best == nil || d < best!.d { best = (t, d, w) }
                        }
                    } } }
                    if best != nil { break }
                }
                guard let b = best else { return }
                let t = Int(b.t)
                let nn = simd_normalize(n[Int(idx[3 * t])] * b.w.x + n[Int(idx[3 * t + 1])] * b.w.y + n[Int(idx[3 * t + 2])] * b.w.z)
                let on = p[Int(idx[3 * t])] * b.w.x + p[Int(idx[3 * t + 1])] * b.w.y + p[Int(idx[3 * t + 2])] * b.w.z
                o[i] = Attachment(triangle: b.t, weights: SIMD2(b.w.y, b.w.z), offset: max(0.002, simd_dot(q - on, nn)))
            }
        }
        attachments = out
    }

    /// The point of triangle a b c nearest `q`, and its barycentric weights.
    package static func closest(_ q: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        // (Ericson, Real-Time Collision Detection, 5.1.5.)
        let ab = b - a, ac = c - a, ap = q - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return (a, SIMD3(1, 0, 0)) }
        let bp = q - b, d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return (b, SIMD3(0, 1, 0)) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { let v = d1 / (d1 - d3); return (a + ab * v, SIMD3(1 - v, v, 0)) }
        let cp = q - c, d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return (c, SIMD3(0, 0, 1)) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { let w = d2 / (d2 - d6); return (a + ac * w, SIMD3(1 - w, 0, w)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return (b + (c - b) * w, SIMD3(0, 1 - w, w))
        }
        let denom = 1 / (va + vb + vc), v = vb * denom, w = vc * denom
        return (a + ab * v + ac * w, SIMD3(1 - v - w, v, w))
    }

    /// The garment on `body` (the same mesh as it was bound to), in its bind pose.
    package func positions(on body: SkinnedCharacter) -> [SIMD3<Float>] {
        let p = body.positions, idx = body.indices, n = body.normals
        return attachments.map { a in
            let t = Int(a.triangle), w = SIMD3(1 - a.weights.x - a.weights.y, a.weights.x, a.weights.y)
            let i0 = Int(idx[3 * t]), i1 = Int(idx[3 * t + 1]), i2 = Int(idx[3 * t + 2])
            let on = p[i0] * w.x + p[i1] * w.y + p[i2] * w.z
            let nn = simd_normalize(n[i0] * w.x + n[i1] * w.y + n[i2] * w.z)
            return on + nn * a.offset
        }
    }
}

/// Characters wearing garments: their mesh and every level of it with the garments' triangles added (skinned with
/// the body's bones where they are bound), and the body's triangles under the cloth taken out.
package enum DressedCharacter {
    /// `c` wearing `garments` (each bound to a body of `c`'s mesh), its materials after the body's: the garments'
    /// fabrics from `materialBase` on, in order.
    package static func dress(_ c: SkinnedCharacter, in garments: [GarmentBinding], materialBase: Int) -> SkinnedCharacter {
        var out = c
        var placed: [[SIMD3<Float>]] = garments.map { $0.positions(on: c) }
        // The body's vertices the cloth covers: a garment's point within 4 cm, outside it.
        var hidden = [Bool](repeating: false, count: c.positions.count)
        let cell: Float = 0.03
        var grid: [SIMD3<Int32>: [SIMD3<Float>]] = [:]
        for g in placed { for q in g { grid[SIMD3<Int32>((q / cell).rounded(.down)), default: []].append(q) } }
        for (v, p) in c.positions.enumerated() {
            let k = SIMD3<Int32>((p / cell).rounded(.down))
            var near = 0
            for z in -1...1 { for y in -1...1 { for x in -1...1 {
                for q in grid[k &+ SIMD3(Int32(x), Int32(y), Int32(z))] ?? [] where simd_distance(q, p) < 0.04 && simd_dot(q - p, c.normals[v]) > -0.004 { near += 1 }
            } } }
            hidden[v] = near >= 2
        }
        // Each level: the body's uncovered triangles, then the garments'.
        func dressLevel(_ level: SkinnedCharacter.Level, source: (Int) -> Int) -> SkinnedCharacter.Level {
            var l = level
            var keep: [UInt32] = [], mats: [UInt8] = []
            for t in 0..<(level.indices.count / 3) {
                let a = Int(level.indices[3 * t]), b = Int(level.indices[3 * t + 1]), d = Int(level.indices[3 * t + 2])
                func covered(_ v: Int) -> Bool { let s = source(v); return s >= 0 && s < hidden.count && hidden[s] }
                if covered(a) && covered(b) && covered(d) { continue }
                keep += [level.indices[3 * t], level.indices[3 * t + 1], level.indices[3 * t + 2]]
                mats.append(level.materials.indices.contains(t) ? level.materials[t] : 0)
            }
            l.indices = keep
            l.materials = mats
            var fabricBase = materialBase
            for (gi, g) in garments.enumerated() {
                let base = UInt32(l.positions.count)
                let b = g.build
                l.positions += placed[gi]
                l.normals += GarmentExport.normals(placed[gi], b.triangles)
                l.uvs += b.uvs.map { $0 * 4 }
                // The skin of the body vertex the point is nearest (of its triangle's corners, the heaviest).
                for a in g.attachments {
                    let t = Int(a.triangle), w = SIMD3(1 - a.weights.x - a.weights.y, a.weights.x, a.weights.y)
                    let corner = w.x >= w.y && w.x >= w.z ? 0 : (w.y >= w.z ? 1 : 2)
                    l.skin.append(c.skin[Int(c.indices[3 * t + corner])])
                }
                l.indices += b.triangles.map { $0 + base }
                l.materials += b.triangleFabric.map { UInt8(clamping: fabricBase + Int($0)) }
                if !l.source.isEmpty { l.source += [UInt32](repeating: .max, count: placed[gi].count) }
                fabricBase += (b.triangleFabric.max().map { Int($0) } ?? 0) + 1
            }
            return l
        }
        let full = dressLevel(c.level(0), source: { $0 })
        out.positions = full.positions
        out.normals = full.normals
        out.uvs = full.uvs
        out.indices = full.indices
        out.skin = full.skin
        out.materials = full.materials
        // (A coarser level's vertex made by the simplifier has no source: ~0.)
        out.coarser = c.coarser.map { level in
            dressLevel(level, source: { level.source.indices.contains($0) && level.source[$0] != .max ? Int(level.source[$0]) : -1 })
        }
        placed = []
        return out
    }
}

/// Drapes made on the CPU (GarmentSim, the body as BodySurface's distance): a garment on a body, settled, kept by
/// both's fingerprints in memory and on disk (the user's caches).
package enum GarmentDrapes {
    private static let lock = NSLock()
    private static var kept: [String: [SIMD3<Float>]] = [:]
    package static let version = 1

    /// `g` sewn and draped on `body` (`bodyKey` names it) for `seconds`, `substeps` a 60th of a second.
    package static func drape(_ g: Garment, on body: SkinnedCharacter, bodyKey: String, seconds: Float = 2.4, substeps: Int = 16)
        -> (build: GarmentBuild, positions: [SIMD3<Float>]) {
        let build = GarmentBuild.make(g)
        let key = "\(version)-\(GarmentCatalog.fingerprint(g))-\(bodyKey)"
        let url = CacheFile.userFolder.appendingPathComponent("garment-drape-\(key).bin")
        lock.lock()
        if let p = kept[key], p.count == build.particleCount { lock.unlock(); return (build, p) }
        lock.unlock()
        if let data = try? Data(contentsOf: url), data.count == build.particleCount * 12 {
            let p = data.withUnsafeBytes { raw in (0..<build.particleCount).map { i in
                SIMD3(raw.loadUnaligned(fromByteOffset: 12 * i, as: Float.self), raw.loadUnaligned(fromByteOffset: 12 * i + 4, as: Float.self),
                      raw.loadUnaligned(fromByteOffset: 12 * i + 8, as: Float.self)) } }
            lock.lock(); kept[key] = p; lock.unlock()
            return (build, p)
        }
        let start = CFAbsoluteTimeGetCurrent()
        let frame = AvatarFrame(body)
        let surface = GarmentAvatars.body(body, key: bodyKey)
        var sim = GarmentSim(positions: frame.place(build, g), invMass: build.invMass, constraints: build.constraints, colourStarts: build.colourStarts)
        sim.body = { p in (surface.distance(p), surface.gradient(p)) }
        let fabric = g.fabrics.first ?? .preset(.cotton)
        sim.params.collide = SIMD4(max(0.002, fabric.thickness), fabric.friction, 0.004, 0.6 + fabric.damping * 4)
        sim.params.floor = SIMD4(0, 0, 0, 0)
        let frames = Int(seconds * 60)
        for f in 0..<frames {
            let t = Float(f) / 60
            sim.params.seams.x = max(1e-9, 2e-4 * exp(-t * 9))
            sim.params.seams.z = t > 0.9 ? 1 : 1e9
            sim.params.gravity = SIMD4(0, -9.81 * max(0, min(1, (t - 0.6) / 0.5)), 0, 0)
            sim.step(dt: 1 / 60, substeps: substeps)
        }
        let p = sim.positions
        print(String(format: "Garments: %@ draped on %@ in %.0f ms", g.name, bodyKey, (CFAbsoluteTimeGetCurrent() - start) * 1000))
        var data = Data(capacity: p.count * 12)
        for q in p { withUnsafeBytes(of: q.x) { data.append(contentsOf: $0) }; withUnsafeBytes(of: q.y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: q.z) { data.append(contentsOf: $0) } }
        try? CacheFile.write(data, to: url)
        lock.lock(); kept[key] = p; lock.unlock()
        return (build, p)
    }
}
