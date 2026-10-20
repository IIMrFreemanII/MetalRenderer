import Foundation
import simd

/// A distance field baked into a grid (`bake`), a node of SDF shapes can be (`.volume`): its samples at the grid's
/// points, trilinear in between; outside the grid a bound (the distance to the grid plus the least of its samples on
/// its faces, which nothing outside can be nearer to the surface than). MSL `sdfVolume` in Shaders/SDF.metal.
struct SDFVolume {
    /// The first sample's place, and the samples' spacing.
    var lo: SIMD3<Float>
    var cell: Float
    var dims: SIMD3<Int>
    var samples: [Float16]
    /// The least sample on the grid's faces.
    var border: Float

    var hi: SIMD3<Float> { lo + SIMD3<Float>(dims &- 1) * cell }

    func sample(_ x: Int, _ y: Int, _ z: Int) -> Float { Float(samples[(z * dims.y + y) * dims.x + x]) }

    func distance(_ p: SIMD3<Float>) -> Float {
        let q = simd_clamp(p, lo, hi)
        let outside = length(p - q)
        let g = (q - lo) / cell
        let i = simd_min(SIMD3<Int>(g.rounded(.down)), dims &- 2)
        let f = g - SIMD3<Float>(i)
        func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        let c00 = lerp(sample(i.x, i.y, i.z), sample(i.x + 1, i.y, i.z), f.x)
        let c10 = lerp(sample(i.x, i.y + 1, i.z), sample(i.x + 1, i.y + 1, i.z), f.x)
        let c01 = lerp(sample(i.x, i.y, i.z + 1), sample(i.x + 1, i.y, i.z + 1), f.x)
        let c11 = lerp(sample(i.x, i.y + 1, i.z + 1), sample(i.x + 1, i.y + 1, i.z + 1), f.x)
        let inside = lerp(lerp(c00, c10, f.y), lerp(c01, c11, f.y), f.z)
        return outside > 0 ? outside + min(border, inside) : inside
    }

    func gpu(firstSample: Int) -> GPUSDFVolume {
        GPUSDFVolume(lo: SIMD4(lo, cell), hi: SIMD4(hi, border),
                     dims: SIMD4(UInt32(dims.x), UInt32(dims.y), UInt32(dims.z), UInt32(firstSample)))
    }

    // MARK: - Baking

    /// Of `bake`'s output: a change of it makes other files in the cache.
    static let version = 1

    /// `bake`, from the cache or into it (GeneratedCache): the file is named by the mesh and the resolution.
    static func cached(_ mesh: MeshGeometry, resolution: Int = 64) -> SDFVolume {
        var hasher = GeneratedCache.Hasher()
        hasher.add(mesh.positions)
        hasher.add(mesh.indices)
        let name = "sdf-\(hasher.name()).sect", key = "sdf v\(version) \(resolution)"
        let header = SectionFile.id("head"), cells = SectionFile.id("cell")
        if let file = GeneratedCache.load(name, key: key), let h: [Float] = file.array(header), h.count == 8,
           let samples: [Float16] = file.array(cells) {
            let dims = SIMD3(Int(h[5]), Int(h[6]), Int(h[7]))
            if samples.count == dims.x * dims.y * dims.z {
                return SDFVolume(lo: SIMD3(h[0], h[1], h[2]), cell: h[3], dims: dims, samples: samples, border: h[4])
            }
        }
        let v = bake(mesh, resolution: resolution)
        var writer = SectionFile.Writer()
        writer.add(header, [v.lo.x, v.lo.y, v.lo.z, v.cell, v.border, Float(v.dims.x), Float(v.dims.y), Float(v.dims.z)])
        writer.add(cells, v.samples)
        GeneratedCache.store(name, key: key, writer)
        return v
    }

    /// The signed distance to `mesh`'s surface on a grid of about `resolution` samples along the mesh's longest side,
    /// with two cells of room around it. The distance is exact (to the nearest triangle, through a tree over them);
    /// the sign is a vote of three: inside along a row of samples is where an odd number of the mesh's faces have been
    /// crossed, counted along x, y and z, so a mesh with a few holes or doubled faces still has its inside right.
    static func bake(_ mesh: MeshGeometry, resolution: Int = 64) -> SDFVolume {
        var bounds = AABB()
        for p in mesh.positions { bounds.grow(p) }
        let cell = simd_reduce_max(bounds.hi - bounds.lo) / Float(max(resolution - 5, 1))
        let lo = bounds.lo - 2 * cell
        let dims = SIMD3<Int>(((bounds.hi - bounds.lo) / cell).rounded(.up)) &+ 5
        let tris = stride(from: 0, to: mesh.indices.count - 2, by: 3).map {
            (mesh.positions[Int(mesh.indices[$0])], mesh.positions[Int(mesh.indices[$0 + 1])], mesh.positions[Int(mesh.indices[$0 + 2])])
        }
        let boxes = tris.map { t -> AABB in var b = AABB(); b.grow(t.0); b.grow(t.1); b.grow(t.2); return b }
        let (nodes, order) = BVHBuilder.build(boxes: boxes, masks: nil, maxLeaf: 4)
        @inline(__always) func at(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * dims.y + y) * dims.x + x }
        func point(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> { lo + SIMD3(Float(x), Float(y), Float(z)) * cell }

        // The distance to the nearest triangle: the nearer child first, and no box farther than the best so far.
        func nearest(_ p: SIMD3<Float>) -> Float {
            var best = Float.infinity, stack = [0]
            while let n = stack.popLast() {
                let node = nodes[n]
                let e = simd_max(simd_max(node.box.lo - p, p - node.box.hi), .zero)
                guard dot(e, e) < best else { continue }
                if node.left < 0 {
                    for k in node.start..<(node.start + node.count) {
                        let t = tris[order[k]]
                        best = min(best, SDFVolume.distance2(p, t.0, t.1, t.2))
                    }
                } else {
                    stack.append(node.right)
                    stack.append(node.left)
                }
            }
            return best.squareRoot()
        }
        // Where a row from `o` along `axis` crosses the mesh (both faces), as distances along it.
        func crossings(_ o: SIMD3<Float>, axis: Int) -> [Float] {
            var d = SIMD3<Float>(), out: [Float] = [], stack = [0]
            d[axis] = 1
            while let n = stack.popLast() {
                let node = nodes[n]
                var inside = true
                for a in 0..<3 where a != axis { inside = inside && o[a] >= node.box.lo[a] && o[a] <= node.box.hi[a] }
                guard inside else { continue }
                if node.left < 0 {
                    for k in node.start..<(node.start + node.count) {
                        let t = tris[order[k]]
                        if let s = SDFVolume.rayTriangle(o, d, t.0, t.1, t.2) { out.append(s) }
                    }
                } else {
                    stack.append(node.right)
                    stack.append(node.left)
                }
            }
            return out.sorted()
        }

        var unsigned = [Float](repeating: 0, count: dims.x * dims.y * dims.z)
        unsigned.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: dims.z) { z in
                for y in 0..<dims.y {
                    for x in 0..<dims.x { out[at(x, y, z)] = nearest(point(x, y, z)) }
                }
            }
        }
        // The votes: per sample, how many of the three rows through it say inside.
        var votes = [UInt8](repeating: 0, count: unsigned.count)
        for axis in 0..<3 {
            let (u, v) = ((axis + 1) % 3, (axis + 2) % 3)
            let rows = dims[u] * dims[v]
            var rowVotes = [[Bool]](repeating: [], count: rows)
            rowVotes.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: rows) { r in
                    var c = SIMD3<Int>()
                    c[u] = r % dims[u]
                    c[v] = r / dims[u]
                    c[axis] = 0
                    // From a cell before the grid; a hair off the samples' lines, so that a row of a mesh made on
                    // the same lines (a cube's) doesn't run along its faces' edges and count them twice.
                    var o = point(c.x, c.y, c.z)
                    o[axis] -= cell
                    o[u] += 1.3e-4 * cell
                    o[v] += 0.7e-4 * cell
                    let hits = crossings(o, axis: axis)
                    var k = 0
                    out[r] = (0..<dims[axis]).map { i in
                        let t = Float(i + 1) * cell   // the sample's distance from `o`
                        while k < hits.count && hits[k] < t { k += 1 }
                        return k % 2 == 1
                    }
                }
            }
            for r in 0..<rows {
                var c = SIMD3<Int>()
                c[u] = r % dims[u]
                c[v] = r / dims[u]
                for i in 0..<dims[axis] where rowVotes[r][i] {
                    c[axis] = i
                    votes[at(c.x, c.y, c.z)] += 1
                }
            }
        }
        var samples = [Float16](repeating: 0, count: unsigned.count)
        var border = Float.infinity
        for z in 0..<dims.z {
            for y in 0..<dims.y {
                for x in 0..<dims.x {
                    let i = at(x, y, z)
                    let d = votes[i] >= 2 ? -unsigned[i] : unsigned[i]
                    samples[i] = Float16(d)
                    if x == 0 || y == 0 || z == 0 || x == dims.x - 1 || y == dims.y - 1 || z == dims.z - 1 { border = min(border, d) }
                }
            }
        }
        return SDFVolume(lo: lo, cell: cell, dims: dims, samples: samples, border: max(border, 0))
    }

    /// The squared distance from `p` to triangle (a, b, c) (Ericson, Real-Time Collision Detection 5.1.5).
    static func distance2(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = dot(ab, ap), d2 = dot(ac, ap)
        func d(_ q: SIMD3<Float>) -> Float { let e = p - q; return dot(e, e) }
        if d1 <= 0 && d2 <= 0 { return d(a) }
        let bp = p - b, d3 = dot(ab, bp), d4 = dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return d(b) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return d(a + ab * (d1 / (d1 - d3))) }
        let cp = p - c, d5 = dot(ab, cp), d6 = dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return d(c) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return d(a + ac * (d2 / (d2 - d6))) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 { return d(b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))) }
        let denom = 1 / (va + vb + vc)
        return d(a + ab * (vb * denom) + ac * (vc * denom))
    }

    /// Where the ray o + d t (t > 0) crosses triangle (a, b, c), either face; nil if it doesn't.
    static func rayTriangle(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float? {
        let e1 = b - a, e2 = c - a
        let pv = cross(d, e2), det = dot(e1, pv)
        guard abs(det) > 1e-12 else { return nil }
        let inv = 1 / det, tv = o - a
        let u = dot(tv, pv) * inv
        guard u >= 0 && u <= 1 else { return nil }
        let qv = cross(tv, e1), v = dot(d, qv) * inv
        guard v >= 0 && u + v <= 1 else { return nil }
        let t = dot(e2, qv) * inv
        return t > 0 ? t : nil
    }
}
