import Foundation
import simd

/// Foliage meshing: stems into tubes and ribbons, leaf anchors into leaves, grass patches, and assemblies baked flat.
/// A mesh's size is counted first and its arrays are filled by index; `build` checks the count was right.
extension Foliage {
    /// Wood first, then leaves: the leaves' vertices and triangles are the tails of the arrays.
    struct Mesh {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var uvs: [SIMD2<Float>]             // wood: around (mirrored, no seam) and along; leaves: 0...1 across, base to tip
        var indices: [UInt32]
        var leafVertex: Int                 // vertices from here on are leaves'
        var leafIndex: Int                  // indices from here on
        var bounds: AABB
        var cutout = false                  // the leaves are cards: cut out by their species' card sheet

        var triangles: Int { indices.count / 3 }
        var leafTriangles: Int { (indices.count - leafIndex) / 3 }
    }

    struct MeshSize {
        var vertices = 0
        var indices = 0

        static func + (a: MeshSize, b: MeshSize) -> MeshSize { MeshSize(vertices: a.vertices + b.vertices, indices: a.indices + b.indices) }
        static func * (a: MeshSize, n: Int) -> MeshSize { MeshSize(vertices: a.vertices * n, indices: a.indices * n) }
    }

    /// Writes a mesh's arrays in order. Nothing grows: the arrays have their final size.
    struct MeshWriter {
        let positions: UnsafeMutablePointer<SIMD3<Float>>
        let normals: UnsafeMutablePointer<SIMD3<Float>>
        let uvs: UnsafeMutablePointer<SIMD2<Float>>
        let indices: UnsafeMutablePointer<UInt32>
        var vertices = 0
        var written = 0                     // indices
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)

        @discardableResult
        @inline(__always) mutating func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float>) -> UInt32 {
            positions[vertices] = p
            normals[vertices] = n
            uvs[vertices] = uv
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
            vertices += 1
            return UInt32(vertices - 1)
        }

        @inline(__always) mutating func triangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
            indices[written] = a
            indices[written + 1] = b
            indices[written + 2] = c
            written += 3
        }

        @inline(__always) mutating func index(_ i: UInt32) {
            indices[written] = i
            written += 1
        }
    }

    /// A mesh of exactly `size`, written by `fill`, which returns where the leaves start (vertex, index).
    static func build(_ size: MeshSize, _ fill: (inout MeshWriter) -> (Int, Int)) -> Mesh {
        var positions = [SIMD3<Float>](repeating: .zero, count: size.vertices)
        var normals = [SIMD3<Float>](repeating: .zero, count: size.vertices)
        var uvs = [SIMD2<Float>](repeating: .zero, count: size.vertices)
        var indices = [UInt32](repeating: 0, count: size.indices)
        var leaves = (0, 0)
        var bounds = AABB()
        guard size.vertices > 0, size.indices > 0 else {
            return Mesh(positions: [], normals: [], uvs: [], indices: [], leafVertex: 0, leafIndex: 0, bounds: bounds)
        }
        positions.withUnsafeMutableBufferPointer { p in
            normals.withUnsafeMutableBufferPointer { n in
                uvs.withUnsafeMutableBufferPointer { t in
                    indices.withUnsafeMutableBufferPointer { i in
                        var writer = MeshWriter(positions: p.baseAddress!, normals: n.baseAddress!, uvs: t.baseAddress!,
                                                indices: i.baseAddress!)
                        leaves = fill(&writer)
                        precondition(writer.vertices == size.vertices && writer.written == size.indices,
                                     "Foliage: a mesh was counted as \(size) and filled with \(writer.vertices) vertices, \(writer.written) indices")
                        bounds = AABB(lo: writer.lo, hi: writer.hi)
                    }
                }
            }
        }
        return Mesh(positions: positions, normals: normals, uvs: uvs, indices: indices, leafVertex: leaves.0, leafIndex: leaves.1,
                    bounds: bounds)
    }

    // MARK: - Stems

    /// A stem of n nodes: a ring at each node but the last, which is one vertex (the tip closes with a fan, so no
    /// triangle is ever degenerate). Fewer than 3 sides: a ribbon, two vertices per node.
    static func stemSize(_ s: Stem) -> MeshSize {
        let rings = Int(s.count) - 1, per = s.radial < 3 ? 2 : Int(s.radial)
        let strips = per == 2 ? 1 : per
        return MeshSize(vertices: rings * per + 1, indices: ((rings - 1) * strips * 2 + strips) * 3)
    }

    static func write(_ s: Stem, nodes: UnsafePointer<SIMD4<Float>>, up: SIMD3<Float>, into w: inout MeshWriter) {
        let n = Int(s.count), rings = n - 1, sides = Int(s.radial)
        let ribbon = sides < 3
        let node = nodes + Int(s.first)
        let first = UInt32(w.vertices)
        let around = 1 / (2 * Float.pi * max(node[0].w, minRadius))   // v runs in turns of the foot's girth
        let step = 2 * Float.pi / Float(max(sides, 1))
        let stepCos = cos(step), stepSin = sin(step)
        var across = SIMD3<Float>(), other = SIMD3<Float>()
        var v: Float = 0
        for i in 0..<rings {
            let p = xyz(node[i]), r = node[i].w
            let t = normalize(xyz(node[min(i + 1, n - 1)]) - xyz(node[max(i - 1, 0)]))
            // The frame is carried along the stem (no twist), starting across `up`.
            across -= t * dot(across, t)
            across = i == 0 || length_squared(across) < 1e-6 ? perpendicular(t, up: up) : normalize(across)
            other = cross(t, across)
            if i > 0 { v += length(p - xyz(node[i - 1])) * around }
            if ribbon {
                w.vertex(p - across * r, other, SIMD2(0, v))
                w.vertex(p + across * r, other, SIMD2(1, v))
            } else {
                var c: Float = 1, sn: Float = 0
                for k in 0..<sides {
                    let d = across * c + other * sn
                    w.vertex(p + d * r, d, SIMD2(1 - abs(2 * Float(k) / Float(sides) - 1), v))
                    (c, sn) = (c * stepCos - sn * stepSin, sn * stepCos + c * stepSin)
                }
            }
        }
        let end = xyz(node[n - 1]), before = xyz(node[n - 2])
        let tip = w.vertex(end, ribbon ? other : normalize(end - before), SIMD2(0.5, v + length(end - before) * around))

        let per = UInt32(ribbon ? 2 : sides)
        for i in 0..<UInt32(rings - 1) {
            let a = first + i * per, b = a + per
            if ribbon {
                w.triangle(a, a + 1, b + 1)
                w.triangle(a, b + 1, b)
            } else {
                for k in 0..<per {
                    let k1 = k + 1 == per ? 0 : k + 1
                    w.triangle(a + k, a + k1, b + k1)
                    w.triangle(a + k, b + k1, b + k)
                }
            }
        }
        let last = first + UInt32(rings - 1) * per
        if ribbon {
            w.triangle(last, last + 1, tip)
        } else {
            for k in 0..<per { w.triangle(last + k, last + (k + 1 == per ? 0 : k + 1), tip) }
        }
    }

    // MARK: - Leaves

    static func leafSize(_ shape: LeafShape) -> MeshSize {
        switch shape {
        case .kite: return MeshSize(vertices: 4, indices: 6)
        case .blade: return MeshSize(vertices: 6, indices: 12)
        case .needle: return MeshSize(vertices: 3, indices: 3)
        }
    }

    static func write(_ a: LeafAnchor, shape: LeafShape, fold: Float, into w: inout MeshWriter) {
        let d = a.direction, n = a.normal
        let side = cross(d, n)                          // unit: the direction and the normal are
        let half = side * (a.width * 0.5)
        let lift = n * (fold * a.width)                 // the sides stand above the midrib ...
        let tilt = side * (2 * fold)                    // ... so each half faces a little inward
        let p = a.position, tip = p + d * a.length
        switch shape {
        case .needle:
            let i = w.vertex(p - half, n, SIMD2(0, 0))
            w.vertex(p + half, n, SIMD2(1, 0))
            w.vertex(tip, n, SIMD2(0.5, 1))
            w.triangle(i, i + 1, i + 2)
        case .kite:
            let mid = p + d * (a.length * 0.45) + lift
            let i = w.vertex(p, n, SIMD2(0.5, 0))
            w.vertex(mid + half, normalize(n - tilt), SIMD2(1, 0.45))
            w.vertex(tip, n, SIMD2(0.5, 1))
            w.vertex(mid - half, normalize(n + tilt), SIMD2(0, 0.45))
            w.triangle(i, i + 1, i + 2)
            w.triangle(i, i + 2, i + 3)
        case .blade:
            let low = p + d * (a.length * 0.3) + lift, high = p + d * (a.length * 0.7) + lift * 0.8
            let right = normalize(n - tilt), left = normalize(n + tilt)
            let i = w.vertex(p, n, SIMD2(0.5, 0))
            w.vertex(low + half, right, SIMD2(1, 0.3))
            w.vertex(high + half * 0.8, right, SIMD2(0.9, 0.7))
            w.vertex(tip, n, SIMD2(0.5, 1))
            w.vertex(high - half * 0.8, left, SIMD2(0.1, 0.7))
            w.vertex(low - half, left, SIMD2(0, 0.3))
            w.triangle(i, i + 1, i + 2)
            w.triangle(i, i + 2, i + 3)
            w.triangle(i, i + 3, i + 4)
            w.triangle(i, i + 4, i + 5)
        }
    }

    /// The stems `stems` of a skeleton (nil: all) as tubes, then the leaves. `allLeaves`: the stems count as leaves
    /// too (a fern's stalks are as green as its fronds).
    static func mesh(_ skeleton: Skeleton, stems: [Int]?, leaves: [LeafAnchor], shape: LeafShape, fold: Float,
                     up: SIMD3<Float>, allLeaves: Bool) -> Mesh {
        var wood = MeshSize()
        if let stems {
            for i in stems { wood = wood + stemSize(skeleton.stems[i]) }
        } else {
            for s in skeleton.stems { wood = wood + stemSize(s) }
        }
        return build(wood + leafSize(shape) * leaves.count) { w in
            skeleton.nodes.withUnsafeBufferPointer { nodes in
                if let stems {
                    for i in stems { write(skeleton.stems[i], nodes: nodes.baseAddress!, up: up, into: &w) }
                } else {
                    for s in skeleton.stems { write(s, nodes: nodes.baseAddress!, up: up, into: &w) }
                }
            }
            for a in leaves { write(a, shape: shape, fold: fold, into: &w) }
            return allLeaves ? (0, 0) : (wood.vertices, wood.indices)
        }
    }

    /// All the stems of a skeleton as tubes, then `cards` (two triangles each, in the order given).
    static func cardMesh(_ skeleton: Skeleton, cards: [Card], up: SIMD3<Float>) -> Mesh {
        var wood = MeshSize()
        for s in skeleton.stems { wood = wood + stemSize(s) }
        let side = 1 / Float(FoliageTextures.cardCells)
        var mesh = build(wood + MeshSize(vertices: 4, indices: 6) * cards.count) { w in
            skeleton.nodes.withUnsafeBufferPointer { nodes in
                for s in skeleton.stems { write(s, nodes: nodes.baseAddress!, up: up, into: &w) }
            }
            for c in cards {
                let u = Float(c.cell % FoliageTextures.cardCells) * side, v = Float(c.cell / FoliageTextures.cardCells) * side
                let i = w.vertex(c.base - c.half, c.normal, SIMD2(u, v))
                w.vertex(c.base + c.half, c.normal, SIMD2(u + side, v))
                w.vertex(c.top + c.half, c.normal, SIMD2(u + side, v + side))
                w.vertex(c.top - c.half, c.normal, SIMD2(u, v + side))
                w.triangle(i, i + 1, i + 2)
                w.triangle(i, i + 2, i + 3)
            }
            return (wood.vertices, wood.indices)
        }
        mesh.cutout = true
        return mesh
    }

    // MARK: - Grass

    /// A square patch of grass blades around the origin (many blades to a mesh: a blade is never an instance of its
    /// own). Blades stand in tufts, lean and bend their own way, and start a little under the ground. All leaves.
    static func grassPatch(seed: UInt64, size: Float = 2, blades: Int = 800) -> Mesh {
        var rng = SplitMix64(seed: seed)
        let tall = rng.range(0.7, 1.3)
        var tufts: [SIMD2<Float>] = []
        for _ in 0..<max(blades / 20, 1) { tufts.append(SIMD2(rng.range(-0.5, 0.5), rng.range(-0.5, 0.5)) * size) }
        let half = size / 2
        // 3 pairs of vertices and a tip: 5 triangles.
        return build(MeshSize(vertices: 7, indices: 15) * blades) { w in
            for b in 0..<blades {
                var at = SIMD2(rng.range(-half, half), rng.range(-half, half))
                if b % 5 != 0 {   // most blades stand around a tuft
                    let a = rng.range(0, 2 * .pi), r = rng.next() * 0.16
                    at = simd_clamp(tufts[rng.int(tufts.count)] + SIMD2(cos(a), sin(a)) * r, SIMD2(repeating: -half), SIMD2(repeating: half))
                }
                let height = rng.range(0.22, 0.55) * tall, width = rng.range(0.006, 0.011)
                let heading = rng.range(0, 2 * .pi)
                let lean = SIMD3<Float>(cos(heading), 0, sin(heading)), across = SIMD3<Float>(-lean.z, 0, lean.x)
                let reach = height * rng.range(0.15, 0.7)
                let root = SIMD3<Float>(at.x, -0.05, at.y)
                let first = UInt32(w.vertices)
                for i in 0..<4 {
                    let f = Float(i) / 3
                    let p = root + SIMD3<Float>(0, (height + 0.05) * f, 0) + lean * (reach * f * f)
                    // The blade's face, turned half way up: lit like the ground it stands on rather than like a wall.
                    let tangent = normalize(SIMD3<Float>(0, height + 0.05, 0) + lean * (2 * reach * f))
                    let normal = normalize(cross(across, tangent) + SIMD3<Float>(0, 1, 0))
                    if i == 3 {
                        w.vertex(p, normal, SIMD2(0.5, 1))
                    } else {
                        let h = across * (width * (1 - 0.5 * f))
                        w.vertex(p - h, normal, SIMD2(0, f))
                        w.vertex(p + h, normal, SIMD2(1, f))
                    }
                }
                for i: UInt32 in 0..<2 {
                    let a = first + 2 * i
                    w.triangle(a, a + 1, a + 3)
                    w.triangle(a, a + 3, a + 2)
                }
                w.triangle(first + 4, first + 5, first + 6)
            }
            return (0, 0)
        }
    }

    // MARK: - Flatten

    /// An assembly baked into two meshes in plant space: the wood of every part, and the leaves of every part.
    static func flatten(_ plant: Plant, palette: [Mesh]) -> (wood: Mesh, leaves: Mesh) {
        var woodSize = MeshSize(), leafSize = MeshSize()
        for part in plant.parts {
            let m = part.shared ? palette[part.mesh] : plant.meshes[part.mesh]
            woodSize = woodSize + MeshSize(vertices: m.leafVertex, indices: m.leafIndex)
            leafSize = leafSize + MeshSize(vertices: m.positions.count - m.leafVertex, indices: m.indices.count - m.leafIndex)
        }
        func bake(_ size: MeshSize, leaves: Bool) -> Mesh {
            build(size) { w in
                for part in plant.parts {
                    let m = part.shared ? palette[part.mesh] : plant.meshes[part.mesh]
                    let vertices = leaves ? m.leafVertex..<m.positions.count : 0..<m.leafVertex
                    let indices = leaves ? m.leafIndex..<m.indices.count : 0..<m.leafIndex
                    let base = UInt32(w.vertices) &- UInt32(vertices.lowerBound)
                    let c = part.transform.columns
                    let x = xyz(c.0), y = xyz(c.1), z = xyz(c.2), origin = xyz(c.3)
                    let unscale = 1 / length(x)
                    m.positions.withUnsafeBufferPointer { p in
                        m.normals.withUnsafeBufferPointer { n in
                            m.uvs.withUnsafeBufferPointer { t in
                                for v in vertices {
                                    let q = p[v], d = n[v]
                                    w.vertex(x * q.x + y * q.y + z * q.z + origin, (x * d.x + y * d.y + z * d.z) * unscale, t[v])
                                }
                            }
                        }
                    }
                    m.indices.withUnsafeBufferPointer { i in
                        for k in indices { w.index(i[k] &+ base) }
                    }
                }
                return leaves ? (0, 0) : (size.vertices, size.indices)
            }
        }
        var leaves = bake(leafSize, leaves: true)
        leaves.cutout = plant.parts.contains { ($0.shared ? palette[$0.mesh] : plant.meshes[$0.mesh]).cutout }
        return (bake(woodSize, leaves: false), leaves)
    }

    // MARK: - Checks

    /// What is wrong with a mesh (nothing, one hopes): the tests and METALRENDERER_FOLIAGE_TEST run this over
    /// everything the library makes. A degenerate triangle would shade with a NaN normal (traceSurface).
    static func problems(_ m: Mesh) -> [String] {
        var out: [String] = []
        let count = m.positions.count
        if m.normals.count != count || m.uvs.count != count { out.append("attribute counts differ") }
        if m.indices.count % 3 != 0 || m.leafIndex % 3 != 0 { out.append("indices are not whole triangles") }
        if m.leafVertex > count || m.leafIndex > m.indices.count { out.append("the leaves start past the end") }
        var bad = (index: 0, nan: 0, normal: 0, area: 0, bounds: 0, mixed: 0)
        for (v, p) in m.positions.enumerated() {
            let n = m.normals[v], t = m.uvs[v]
            if !(p.x.isFinite && p.y.isFinite && p.z.isFinite && n.x.isFinite && n.y.isFinite && n.z.isFinite
                 && t.x.isFinite && t.y.isFinite) { bad.nan += 1; continue }
            if abs(length(n) - 1) > 1e-3 { bad.normal += 1 }
            if any(p .< m.bounds.lo) || any(p .> m.bounds.hi) { bad.bounds += 1 }
        }
        for f in stride(from: 0, to: m.indices.count - 2, by: 3) {
            let i = (Int(m.indices[f]), Int(m.indices[f + 1]), Int(m.indices[f + 2]))
            if i.0 >= count || i.1 >= count || i.2 >= count { bad.index += 1; continue }
            let leaf = f >= m.leafIndex
            if (i.0 >= m.leafVertex) != leaf || (i.1 >= m.leafVertex) != leaf || (i.2 >= m.leafVertex) != leaf { bad.mixed += 1 }
            let area = length(cross(m.positions[i.1] - m.positions[i.0], m.positions[i.2] - m.positions[i.0])) / 2
            if !(area > 1e-9) { bad.area += 1 }
        }
        if bad.index > 0 { out.append("\(bad.index) triangles index past the vertices") }
        if bad.nan > 0 { out.append("\(bad.nan) vertices are not finite") }
        if bad.normal > 0 { out.append("\(bad.normal) normals are not unit length") }
        if bad.area > 0 { out.append("\(bad.area) triangles have no area") }
        if bad.bounds > 0 { out.append("\(bad.bounds) vertices lie outside the bounds") }
        if bad.mixed > 0 { out.append("\(bad.mixed) triangles mix wood and leaf vertices") }
        return out
    }
}

// MARK: - METALRENDERER_FOLIAGE_TEST

extension Foliage {
    /// `METALRENDERER_FOLIAGE_TEST=<seed>`: builds the library, times each stage, checks every mesh and prints what a
    /// plant of each species costs. No window, no GPU.
    static func runTest(seed: UInt64) {
        func ms(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
        var sets: [SpeciesSet] = []
        let parallel = ms { sets = library(seed: seed) }
        let serial = ms { _ = library(seed: seed, parallel: false) }
        print(String(format: "Foliage library, seed %llu: %.1f ms in parallel, %.1f ms on one thread", seed, parallel, serial))

        var problemCount = 0
        func check(_ m: Mesh, _ what: String) {
            for p in problems(m) { print("  PROBLEM \(what): \(p)"); problemCount += 1 }
        }
        var stored = 0, flatTriangles = 0
        var flats: [(wood: Mesh, leaves: Mesh)] = []
        var flattenTime = 0.0
        print("  species   boughs  bough tris  plants  parts     own tris   traced tris   height")
        for set in sets {
            for (i, m) in set.palette.enumerated() { check(m, "\(set.species) bough \(i)"); stored += m.triangles }
            let boughTriangles = set.palette.isEmpty ? 0 : set.palette.reduce(0) { $0 + $1.triangles } / set.palette.count
            for age in Age.allCases {
                let plants = set.plants.filter { $0.age == age }
                guard !plants.isEmpty else { continue }
                var parts = 0, own = 0, traced = 0
                var height: Float = 0
                for (i, plant) in plants.enumerated() {
                    for (k, m) in plant.meshes.enumerated() { check(m, "\(set.species) \(age) \(i) mesh \(k)"); own += m.triangles }
                    var flat: (wood: Mesh, leaves: Mesh)!
                    flattenTime += ms { flat = flatten(plant, palette: set.palette) }
                    check(flat.wood, "\(set.species) \(age) \(i) flat wood")
                    check(flat.leaves, "\(set.species) \(age) \(i) flat leaves")
                    parts += plant.parts.count
                    traced += flat.wood.triangles + flat.leaves.triangles
                    height = max(height, plant.height)
                    flats.append(flat)
                }
                stored += own
                flatTriangles += traced
                print("  " + "\(set.species)".padding(toLength: 8, withPad: " ", startingAt: 0)
                      + String(format: "%8d %11d %7d %6d %12d %13d %7.1f m  ", set.palette.count, boughTriangles, plants.count,
                               parts / plants.count, own / plants.count, traced / plants.count, height) + "\(age)")
            }
        }
        print(String(format: "  stored as assemblies: %d triangles; baked flat: %d triangles (%.1f ms to bake)", stored, flatTriangles,
                     flattenTime))

        print(problemCount == 0 ? "  checks: ok" : "  checks: \(problemCount) PROBLEMS")
    }
}
