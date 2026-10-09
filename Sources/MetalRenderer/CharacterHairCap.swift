import Foundation
import simd

/// A crowd's hair (CharacterHair's strands are the workshop's): one closed shell round what a style's scalp strands
/// fill, so a bob is a bob and long hair falls down the back, part of the character's mesh and skinned to its head
/// (CharacterBuilder `cap`). Made in the base's bind space from a sample of the style's strands: their volume (each a
/// tube of a few millimetres, as a distance grid) joined to a shell a few millimetres over the scalp where the hair
/// grows, cut off just under the skin, meshed (sparse surface nets) and simplified for each level of detail.
enum CharacterHairCap {
    /// The cap at full detail, then one for each of the base's coarser levels.
    struct Cap {
        var levels: [(positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32])]
    }

    private static let lock = NSLock()
    private static var recent: [(key: String, cap: Cap?)] = []

    static let version: UInt32 = 3

    /// `dna`'s style's cap (nil: no hair on the scalp), kept for the last few styles asked for, and in a cache file
    /// next to the character library's.
    static func cap(_ dna: CharacterDNA, kit: CharacterKit) -> Cap? {
        let base = kit.base.character
        let key = "\(dna.hair.style)-\(Int((dna.hair.length * 10).rounded()))-\(Int((dna.hair.curl * 10).rounded()))-k\(CharacterKit.version)"
            + "-\(base.positions.count)-\(base.indices.count)"
        lock.lock()
        if let found = recent.first(where: { $0.key == key }) { lock.unlock(); return found.cap }
        lock.unlock()
        let start = CFAbsoluteTimeGetCurrent()
        let url = CharacterLibrary.cacheURL(for: [], in: CharacterLibrary.directory, prefix: "hair-cap-\(key)", version: version)
        var made: Cap?
        if let cached = try? read(url) {
            made = cached.levels.isEmpty ? nil : cached
        } else {
            var dnaSparse = dna
            dnaSparse.hair.beard = "none"
            dnaSparse.hair.brows = 0
            made = CharacterHair.grooms(dnaSparse, kit: kit, density: 0.25).first { $0.kind == .scalp }
                .flatMap { make($0, base: kit.base, style: CharacterHair.style(dna.hair.style)) }
            try? CacheFile.write(encoded(made ?? Cap(levels: [])), to: url)
            print(String(format: "Character hair cap: %@, %d triangles in %.0f ms", dna.hair.style, (made?.levels.first?.indices.count ?? 0) / 3,
                         (CFAbsoluteTimeGetCurrent() - start) * 1000))
        }
        lock.lock()
        recent.insert((key, made), at: 0)
        if recent.count > 12 { recent.removeLast() }
        lock.unlock()
        return made
    }

    private static let magic: UInt32 = 0x4348_474D   // "MGHC"

    static func encoded(_ cap: Cap) -> Data {
        var w = BlobWriter()
        w.put(magic)
        w.put(version)
        w.put(UInt32(cap.levels.count))
        for l in cap.levels { w.put(l.positions); w.put(l.normals); w.put(l.indices) }
        return w.data
    }

    static func read(_ url: URL) throws -> Cap {
        var r = BlobReader(try Data(contentsOf: url, options: .alwaysMapped))
        guard try r.get(UInt32.self) == magic, try r.get(UInt32.self) == version else { throw FBXError.invalid("not a hair cap cache") }
        var cap = Cap(levels: [])
        for _ in 0..<Int(try r.get(UInt32.self)) {
            let p: [SIMD3<Float>] = try r.array(), n: [SIMD3<Float>] = try r.array(), i: [UInt32] = try r.array()
            guard n.count == p.count, i.allSatisfy({ Int($0) < p.count }) else { throw FBXError.invalid("a hair cap cache that doesn't add up") }
            cap.levels.append((p, n, i))
        }
        return cap
    }

    static func make(_ groom: CharacterHair.Groom, base: CharacterBase, style: CharacterHair.Style, cell: Float = 0.004) -> Cap? {
        let c = base.character
        guard groom.strandCount > 0, let sculpt = FaceSculpt(c) else { return nil }
        // The strands in the bind pose, the phantom ends left out.
        let n = groom.perStrand
        let all = CharacterHair.place(groom, indices: c.indices, positions: c.positions, head: matrix_identity_float3x3, scale: 1)
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for s in 0..<groom.strandCount {
            for i in 1...n { lo = simd_min(lo, all[s * (n + 2) + i]); hi = simd_max(hi, all[s * (n + 2) + i]) }
        }
        let tube: Float = n <= 5 ? 0.0025 : 0.0035, margin = tube + 3 * cell
        lo -= margin; hi += margin
        let counts = SIMD3<Int>(((hi - lo) / cell).rounded(.up)) &+ 1
        @inline(__always) func index(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * counts.y + y) * counts.x + x }
        // Distance to the nearest strand's tube at each grid point (each segment's neighbourhood).
        var grid = [Float](repeating: 0.02, count: counts.x * counts.y * counts.z)
        let reach = tube + 2 * cell
        for s in 0..<groom.strandCount {
            for i in 1..<n {
                let a = all[s * (n + 2) + i], b = all[s * (n + 2) + i + 1]
                let l = SIMD3<Int>(((simd_min(a, b) - reach - lo) / cell).rounded(.down)), h = SIMD3<Int>(((simd_max(a, b) + reach - lo) / cell).rounded(.up))
                let ab = b - a, length2 = max(simd_length_squared(ab), 1e-12)
                for z in max(l.z, 0)...min(h.z, counts.z - 1) {
                    for y in max(l.y, 0)...min(h.y, counts.y - 1) {
                        for x in max(l.x, 0)...min(h.x, counts.x - 1) {
                            let p = lo + SIMD3(Float(x), Float(y), Float(z)) * cell
                            let t = min(max(simd_dot(p - a, ab) / length2, 0), 1)
                            let d = simd_distance(p, a + ab * t) - tube
                            let k = index(x, y, z)
                            if d < grid[k] { grid[k] = d }
                        }
                    }
                }
            }
        }
        // Smoothed once (the tubes' union is lumpy at a few cells), then the whole field at each grid point: the shell over the scalp (where the hair grows) joined to the strands'
        // volume, cut off 2 mm under the skin. (The head's field only near it: elsewhere the volume decides.)
        let raw = grid
        grid.withUnsafeMutableBufferPointer { g in
            DispatchQueue.concurrentPerform(iterations: counts.z) { z in
                for y in 0..<counts.y {
                    for x in 0..<counts.x {
                        var sum: Float = 0, weight: Float = 0
                        for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                            let xx = x + dx, yy = y + dy, zz = z + dz
                            guard xx >= 0, yy >= 0, zz >= 0, xx < counts.x, yy < counts.y, zz < counts.z else { continue }
                            let w: Float = dx == 0 && dy == 0 && dz == 0 ? 4 : 1
                            sum += raw[index(xx, yy, zz)] * w
                            weight += w
                        } } }
                        g[index(x, y, z)] = sum / weight
                    }
                }
            }
        }
        let thickness: Float = n <= 5 ? 0.0035 : 0.0045
        grid.withUnsafeMutableBufferPointer { g in
            DispatchQueue.concurrentPerform(iterations: counts.z) { z in
                for y in 0..<counts.y {
                    for x in 0..<counts.x {
                        let k = index(x, y, z), p = lo + SIMD3(Float(x), Float(y), Float(z)) * cell
                        let volume = g[k]
                        let head = sculpt.distance(p)
                        if head > 0.03 { continue }
                        let q = sculpt.local(p)
                        let shell = max(head - thickness, -CharacterHair.scalpDistance(q, recede: style.recede, crown: style.crown) * sculpt.scale - 0.001)
                        g[k] = max(FaceSculpt.smin(volume, shell, 0.004), -head - 0.002)
                    }
                }
            }
        }
        func field(_ p: SIMD3<Float>) -> Float {
            let f = simd_clamp((p - lo) / cell, .zero, SIMD3<Float>(counts &- 1) - 1e-3)
            let i = SIMD3<Int>(f.rounded(.down)), t = f - SIMD3<Float>(i)
            func v(_ dx: Int, _ dy: Int, _ dz: Int) -> Float { grid[index(min(i.x + dx, counts.x - 1), min(i.y + dy, counts.y - 1), min(i.z + dz, counts.z - 1))] }
            let x00 = v(0, 0, 0) + (v(1, 0, 0) - v(0, 0, 0)) * t.x, x10 = v(0, 1, 0) + (v(1, 1, 0) - v(0, 1, 0)) * t.x
            let x01 = v(0, 0, 1) + (v(1, 0, 1) - v(0, 0, 1)) * t.x, x11 = v(0, 1, 1) + (v(1, 1, 1) - v(0, 1, 1)) * t.x
            let y0 = x00 + (x10 - x00) * t.y, y1 = x01 + (x11 - x01) * t.y
            return y0 + (y1 - y0) * t.z
        }
        func gradient(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let h = cell * 0.5
            let g = SIMD3(field(p + [h, 0, 0]) - field(p - [h, 0, 0]), field(p + [0, h, 0]) - field(p - [0, h, 0]),
                          field(p + [0, 0, h]) - field(p - [0, 0, h])) / (2 * h)
            // Floored (as MuscleAtlas's): where the grid is flat, surface nets' step along it would fling a vertex away.
            let length = simd_length(g)
            return length < 0.5 ? (length > 1e-6 ? g * (0.5 / length) : SIMD3(0, 0.5, 0)) : g
        }
        var (positions, indices) = SurfaceNets.sparseMesh(lo: lo, size: cell, counts: counts, distance: field, gradient: gradient)
        guard !indices.isEmpty else { return nil }
        positions = positions.map { simd_clamp($0, lo, hi) }
        (positions, indices) = CharacterBase.largestPart(positions, indices)
        var cap = Cap(levels: [])
        var target = 6000
        let box = (lo: lo - 0.01, hi: hi + 0.01)
        for _ in 0...CharacterLibrary.coarserLevels {
            var (p, i) = CharacterBase.simplified(positions, indices, to: target)
            // (Simplifying a thin shell this far can throw a vertex off where its quadric is flat: then the level
            // before stands in.)
            if !p.allSatisfy({ $0.x.isFinite && simd_clamp($0, box.lo, box.hi) == $0 }) { (p, i) = (positions, indices) }
            let normals = p.map { q -> SIMD3<Float> in
                let g = gradient(q)
                return simd_length_squared(g) > 0 ? simd_normalize(g) : [0, 1, 0]
            }
            cap.levels.append((p, normals, i))
            (positions, indices) = (p, i)
            target /= 2
        }
        return cap
    }
}
