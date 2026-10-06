import Foundation
import simd

/// A mesh's signed distance field (Lumen's mesh distance fields), in its own space: samples on a grid of `voxel`
/// spacing from `lo`, kept only near the surface, in bricks of 8³ samples over 7³ cells (neighbours share a face of
/// samples, so a brick filters on its own). A brick farther than the band from every triangle is not stored: the
/// table says whether it is outside or inside. Samples hold distance / (band x voxel), clamped to ±1, as signed
/// bytes (the GPU's r8Snorm). Meshes with no inside at this resolution (planes, leaf cards, open shells) are two-sided:
/// unsigned distance - half a voxel; so is a mesh's open surface where the rest of it is closed (the open world's
/// ground around its buildings): the outside is on both sides of it there. Past the band the bricks only say "at least the band", a few voxels: a coarse grid
/// of 16³ unclamped distances over the volume answers there (the global field, whose voxels are larger, needs it).
struct MeshSDF {
    static let brickCells = 7
    static let brickSide = 8
    static let band: Float = 4                       // voxels each side of the surface
    static let emptyOutside = UInt32.max
    static let emptyInside = UInt32.max - 1
    static let maxCells = 126                        // a side at most (18 bricks)
    static let coarseSide = 16

    var lo: SIMD3<Float>
    var voxel: Float
    var bricks: SIMD3<Int>                           // per axis
    var table: [UInt32]                              // per brick (x fastest): its place in `data` (in bricks), or empty
    var data: [Int8]                                 // brickSide³ a stored brick, x fastest
    var twoSided: Bool
    var coarse: [Float] = []                         // coarseSide³ distances, x fastest, from lo to hi inclusive

    var cells: SIMD3<Int> { bricks &* MeshSDF.brickCells }
    var hi: SIMD3<Float> { lo + SIMD3<Float>(cells) * voxel }
    var storedBricks: Int { data.count / (MeshSDF.brickSide * MeshSDF.brickSide * MeshSDF.brickSide) }
    var bytes: Int { data.count + table.count * 4 }

    /// The distance (in the mesh's units) at grid sample `i` (0...cells per axis).
    func sample(_ i: SIMD3<Int>) -> Float {
        let b = simd_min(i / MeshSDF.brickCells, bricks &- 1)
        let local = i &- b &* MeshSDF.brickCells
        return sample(brick: b, local: local)
    }

    /// Sample `local` (0...7 per axis) as brick `b` stores it.
    func sample(brick b: SIMD3<Int>, local: SIMD3<Int>) -> Float {
        let scale = MeshSDF.band * voxel
        switch table[(b.z * bricks.y + b.y) * bricks.x + b.x] {
        case MeshSDF.emptyOutside: return scale
        case MeshSDF.emptyInside: return -scale
        case let slot:
            let s = MeshSDF.brickSide
            return Float(data[Int(slot) * s * s * s + (local.z * s + local.y) * s + local.x]) / 127 * scale
        }
    }

    /// The coarse grid's distance at `p` (in the volume), less half a coarse cell's diagonal: a lower bound.
    func coarseDistance(at p: SIMD3<Float>) -> Float {
        let n = MeshSDF.coarseSide
        let spacing = (hi - lo) / Float(n - 1)
        let c = simd_clamp((p - lo) / spacing, .zero, SIMD3(repeating: Float(n - 1)))
        let i = simd_min(SIMD3<Int>(c.rounded(.down)), SIMD3(repeating: n - 2))
        let f = c - SIMD3<Float>(i)
        var d: Float = 0
        for k in 0..<8 {
            let o = SIMD3<Int>(k & 1, (k >> 1) & 1, k >> 2)
            let w = (o.x == 1 ? f.x : 1 - f.x) * (o.y == 1 ? f.y : 1 - f.y) * (o.z == 1 ? f.z : 1 - f.z)
            let q = i &+ o
            d += w * coarse[(q.z * n + q.y) * n + q.x]
        }
        return d - length(spacing) / 2
    }

    /// Distance at `p`, as the GPU reads it: trilinear in the bricks, the coarse grid where they saturate; outside the
    /// volume, from its edge (√(outside² + edge²): the surface is inside). Always a lower bound of the true distance
    /// past the band, which is what a sphere tracer needs.
    func distance(at p: SIMD3<Float>) -> Float {
        let g = (p - lo) / voxel
        let c = SIMD3<Float>(cells)
        if any(g .< 0) || any(g .> c) {
            let q = simd_clamp(g, .zero, c)
            let edge = max(distance(at: lo + q * voxel), 0)
            let outside = length(g - q) * voxel
            return (outside * outside + edge * edge).squareRoot()
        }
        let i = simd_min(SIMD3<Int>(g.rounded(.down)), cells &- 1)
        let f = g - SIMD3<Float>(i)
        var d: Float = 0
        for k in 0..<8 {
            let o = SIMD3<Int>(k & 1, (k >> 1) & 1, k >> 2)
            let w = (o.x == 1 ? f.x : 1 - f.x) * (o.y == 1 ? f.y : 1 - f.y) * (o.z == 1 ? f.z : 1 - f.z)
            d += w * sample(i &+ o)
        }
        if d >= 0.99 * MeshSDF.band * voxel && !coarse.isEmpty { d = max(d, coarseDistance(at: p)) }
        return d
    }
}

enum MeshSDFBuilder {
    /// The voxel for a mesh of these bounds: as many as fit maxCells (with the band's margin) across its largest side,
    /// at least 2 cm. (By its diagonal, a hall's floor got voxels near a metre: a two-sided plane's surface is half a
    /// voxel off, and the floor swelled into what stood on it.) Only the bricks near the surface are kept, so a flat
    /// mesh's fine voxels cost little.
    static func voxel(for bounds: AABB) -> Float {
        let ext = bounds.hi - bounds.lo
        let margin = 2 * (MeshSDF.band + 1)
        return max(0.02, ext.max() / (Float(MeshSDF.maxCells) - margin))
    }

    static func build(positions: [SIMD3<Float>], indices: [UInt32], voxel: Float? = nil) -> MeshSDF? {
        positions.withUnsafeBufferPointer { p in indices.withUnsafeBufferPointer { build(positions: p, indices: $0, voxel: voxel) } }
    }

    static func build(positions: UnsafeBufferPointer<SIMD3<Float>>, indices: UnsafeBufferPointer<UInt32>, voxel fixed: Float? = nil) -> MeshSDF? {
        let triangleCount = indices.count / 3
        guard triangleCount > 0 else { return nil }
        var tris = [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]()
        tris.reserveCapacity(triangleCount)
        var bounds = AABB()
        var boxes = [AABB]()
        boxes.reserveCapacity(triangleCount)
        for t in 0..<triangleCount {
            let a = positions[Int(indices[3 * t])], b = positions[Int(indices[3 * t + 1])], c = positions[Int(indices[3 * t + 2])]
            tris.append((a, b, c))
            var box = AABB()
            box.grow(a); box.grow(b); box.grow(c)
            boxes.append(box)
            bounds.grow(box)
        }
        let voxel = fixed ?? MeshSDFBuilder.voxel(for: bounds)
        let margin = (MeshSDF.band + 1) * voxel
        let lo = bounds.lo - margin
        let wanted = SIMD3<Int>(((bounds.hi + margin - lo) / voxel).rounded(.up))
        let bricks = simd_max((wanted &+ (MeshSDF.brickCells - 1)) / MeshSDF.brickCells, SIMD3(repeating: 1))
        let cells = bricks &* MeshSDF.brickCells
        guard cells.max() <= MeshSDF.maxCells + MeshSDF.brickCells else { return nil }

        // The cells a triangle touches, then the ones the outside reaches from the border without crossing one.
        let cellCount = cells.x * cells.y * cells.z
        func cellIndex(_ c: SIMD3<Int>) -> Int { (c.z * cells.y + c.y) * cells.x + c.x }
        var blocked = [Bool](repeating: false, count: cellCount)
        let half = SIMD3<Float>(repeating: voxel / 2)
        for (t, box) in boxes.enumerated() {
            let a = simd_max(SIMD3<Int>(((box.lo - lo) / voxel).rounded(.down)), .zero)
            let b = simd_min(SIMD3<Int>(((box.hi - lo) / voxel).rounded(.down)), cells &- 1)
            guard all(a .<= b) else { continue }
            for z in a.z...b.z { for y in a.y...b.y { for x in a.x...b.x {
                let i = cellIndex(SIMD3(x, y, z))
                if blocked[i] { continue }
                let centre = lo + (SIMD3<Float>(Float(x), Float(y), Float(z)) + 0.5) * voxel
                if triangleOverlapsBox(tris[t], centre: centre, half: half * 1.001) { blocked[i] = true }
            } } }
        }
        var outside = [Bool](repeating: false, count: cellCount)
        var stack: [SIMD3<Int>] = []
        func visit(_ c: SIMD3<Int>) {
            let i = cellIndex(c)
            if !blocked[i] && !outside[i] { outside[i] = true; stack.append(c) }
        }
        for z in 0..<cells.z { for y in 0..<cells.y { for x in 0..<cells.x
            where x == 0 || y == 0 || z == 0 || x == cells.x - 1 || y == cells.y - 1 || z == cells.z - 1 {
            visit(SIMD3(x, y, z))
        } } }
        while let c = stack.popLast() {
            for axis in 0..<3 {
                for step in [-1, 1] {
                    var n = c
                    n[axis] += step
                    if n[axis] >= 0 && n[axis] < cells[axis] { visit(n) }
                }
            }
        }
        var insideCells = 0
        for i in 0..<cellCount where !blocked[i] && !outside[i] { insideCells += 1 }
        let twoSided = insideCells == 0

        // Bricks within the band of a triangle get samples.
        let brickCount = bricks.x * bricks.y * bricks.z
        func brickIndex(_ b: SIMD3<Int>) -> Int { (b.z * bricks.y + b.y) * bricks.x + b.x }
        var near = [Bool](repeating: false, count: brickCount)
        let reach = MeshSDF.band * voxel
        let brickSize = Float(MeshSDF.brickCells) * voxel
        for box in boxes {
            let a = simd_max(SIMD3<Int>(((box.lo - reach - lo) / brickSize).rounded(.down)), .zero)
            let b = simd_min(SIMD3<Int>(((box.hi + reach - lo) / brickSize).rounded(.down)), bricks &- 1)
            guard all(a .<= b) else { continue }
            for z in a.z...b.z { for y in a.y...b.y { for x in a.x...b.x { near[brickIndex(SIMD3(x, y, z))] = true } } }
        }

        let tree = BVHBuilder.build(boxes: boxes, masks: nil, maxLeaf: 4)
        // An open surface: the outside on both sides of the nearest triangle (a voxel out along its normal).
        func cellOutside(_ q: SIMD3<Float>) -> Bool {
            let c = SIMD3<Int>(((q - lo) / voxel).rounded(.down))
            return any(c .< 0) || any(c .>= cells) || outside[cellIndex(c)]
        }
        func open(_ closest: SIMD3<Float>, _ normal: SIMD3<Float>) -> Bool {
            cellOutside(closest + normal * voxel) && cellOutside(closest - normal * voxel)
        }
        let side = MeshSDF.brickSide, perBrick = side * side * side
        let nearList = (0..<brickCount).filter { near[$0] }
        var samples = [Int8](repeating: 127, count: nearList.count * perBrick)
        samples.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: nearList.count) { n in
                let bi = nearList[n]
                let b = SIMD3(bi % bricks.x, (bi / bricks.x) % bricks.y, bi / (bricks.x * bricks.y))
                for k in 0..<perBrick {
                    let local = SIMD3(k % side, (k / side) % side, k / (side * side))
                    let g = b &* MeshSDF.brickCells &+ local
                    let p = lo + SIMD3<Float>(g) * voxel
                    let (dist, closest, normal) = nearest(p, tree: tree, tris: tris, radius: reach * 1.5)
                    var d: Float
                    if twoSided || open(closest, normal) {
                        d = dist - voxel / 2
                    } else {
                        // The cells around the sample: one the outside reached makes it outside; else one inside makes
                        // it inside; among triangles only, the nearest one's side says.
                        var sawOutside = false, sawInside = false
                        for c in 0..<8 {
                            let cell = g &- SIMD3(c & 1, (c >> 1) & 1, c >> 2)
                            guard all(cell .>= 0) && all(cell .< cells) else { sawOutside = true; continue }
                            let i = cellIndex(cell)
                            if outside[i] { sawOutside = true } else if !blocked[i] { sawInside = true }
                        }
                        let inside = sawOutside ? false : sawInside ? true : dot(p - closest, normal) < 0
                        d = inside ? -dist : dist
                    }
                    out[n * perBrick + k] = Int8((min(max(d / reach, -1), 1) * 127).rounded())
                }
            }
        }

        // The table: stored bricks, and the empty ones by the side they are on.
        var table = [UInt32](repeating: MeshSDF.emptyOutside, count: brickCount)
        var data: [Int8] = []
        data.reserveCapacity(samples.count)
        for (n, bi) in nearList.enumerated() {
            let slice = samples[n * perBrick ..< (n + 1) * perBrick]
            if slice.allSatisfy({ $0 == 127 }) { continue }
            if slice.allSatisfy({ $0 == -127 }) { table[bi] = MeshSDF.emptyInside; continue }
            table[bi] = UInt32(data.count / perBrick)
            data.append(contentsOf: slice)
        }
        if !twoSided {
            for bi in 0..<brickCount where !near[bi] {
                let b = SIMD3(bi % bricks.x, (bi / bricks.x) % bricks.y, bi / (bricks.x * bricks.y))
                let centre = b &* MeshSDF.brickCells &+ MeshSDF.brickCells / 2
                let i = cellIndex(centre)
                if !outside[i] && !blocked[i] { table[bi] = MeshSDF.emptyInside }
            }
        }
        // The coarse grid: the unclamped distance, signed as the samples are.
        let n = MeshSDF.coarseSide
        let hi = lo + SIMD3<Float>(cells) * voxel, spacing = (hi - lo) / Float(n - 1)
        var coarse = [Float](repeating: 0, count: n * n * n)
        coarse.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: n * n) { row in
                for x in 0..<n {
                    let p = lo + SIMD3<Float>(Float(x), Float(row % n), Float(row / n)) * spacing
                    let (dist, closest, normal) = nearest(p, tree: tree, tris: tris, radius: .greatestFiniteMagnitude)
                    var d = dist
                    if twoSided || open(closest, normal) {
                        d = dist - voxel / 2
                    } else {
                        let cell = simd_clamp(SIMD3<Int>(((p - lo) / voxel).rounded(.down)), .zero, cells &- 1)
                        let i = cellIndex(cell)
                        let inside = outside[i] ? false : !blocked[i] ? true : dot(p - closest, normal) < 0
                        d = inside ? -dist : dist
                    }
                    out[row * n + x] = d
                }
            }
        }
        return MeshSDF(lo: lo, voxel: voxel, bricks: bricks, table: table, data: data, twoSided: twoSided, coarse: coarse)
    }

    /// The nearest triangle to `p` within `radius`: its distance (`radius` if none), closest point and face normal.
    static func nearest(_ p: SIMD3<Float>, tree: (nodes: [BVHBuilder.Node], order: [Int]),
                        tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)], radius: Float)
        -> (Float, SIMD3<Float>, SIMD3<Float>) {
        var best = radius * radius, closest = p, normal = SIMD3<Float>(0, 1, 0)
        guard !tree.nodes.isEmpty else { return (radius, p, normal) }
        var stack = [0]
        while let n = stack.popLast() {
            let node = tree.nodes[n]
            let q = simd_clamp(p, node.box.lo, node.box.hi)
            if length_squared(q - p) >= best { continue }
            if node.left < 0 {
                for i in node.start..<node.start + node.count {
                    let t = tris[tree.order[i]]
                    let c = closestPointOnTriangle(p, t.0, t.1, t.2)
                    let d = length_squared(c - p)
                    if d < best {
                        best = d
                        closest = c
                        let n = cross(t.1 - t.0, t.2 - t.0)
                        normal = length_squared(n) > 0 ? normalize(n) : normal
                    }
                }
            } else {
                stack.append(node.left)
                stack.append(node.right)
            }
        }
        return (sqrt(best), closest, normal)
    }

    /// Ericson, Real-Time Collision Detection 5.1.5.
    static func closestPointOnTriangle(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = dot(ab, ap), d2 = dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = p - b
        let d3 = dot(ab, bp), d4 = dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
        let cp = p - c
        let d5 = dot(ab, cp), d6 = dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
        let denom = 1 / (va + vb + vc)
        return a + ab * (vb * denom) + ac * (vc * denom)
    }

    /// Akenine-Möller's triangle / box overlap test (separating axes: the box's, the triangle's normal, the 9 edge
    /// cross products).
    static func triangleOverlapsBox(_ t: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), centre: SIMD3<Float>, half h: SIMD3<Float>) -> Bool {
        let v0 = t.0 - centre, v1 = t.1 - centre, v2 = t.2 - centre
        let e = [v1 - v0, v2 - v1, v0 - v2]
        for edge in e {
            for axisIndex in 0..<3 {
                var axis = SIMD3<Float>.zero
                axis[axisIndex] = 1
                let a = cross(axis, edge)
                let p0 = dot(v0, a), p1 = dot(v1, a), p2 = dot(v2, a)
                let r = h.x * abs(a.x) + h.y * abs(a.y) + h.z * abs(a.z)
                if min(p0, p1, p2) > r || max(p0, p1, p2) < -r { return false }
            }
        }
        for k in 0..<3 where min(v0[k], v1[k], v2[k]) > h[k] || max(v0[k], v1[k], v2[k]) < -h[k] { return false }
        let n = cross(e[0], e[1])
        let d = dot(n, v0)
        let r = h.x * abs(n.x) + h.y * abs(n.y) + h.z * abs(n.z)
        return abs(d) <= r
    }
}

/// A flat mesh's field as heights (terrain, a ground, a floor or wall quad in its own space): the topmost surface
/// over a grid of `side`² samples from `lo`, `cell` apart. Below it counts as solid. The distance is the height above
/// it times `slope` (1 / √(1 + the steepest gradient²): a lower bound on slopes); off the grid, from its edge.
struct Heightfield {
    var lo: SIMD2<Float>        // x, z of the first sample
    var cell: Float
    var side: Int
    var heights: [Float]        // side², x fastest
    var slope: Float
    var bounds: AABB            // of the mesh

    var hi: SIMD2<Float> { lo + Float(side - 1) * cell }

    func height(_ x: Float, _ z: Float) -> Float {
        let g = simd_clamp((SIMD2(x, z) - lo) / cell, .zero, SIMD2(repeating: Float(side - 1)))
        let i = simd_min(SIMD2<Int>(g.rounded(.down)), SIMD2(repeating: side - 2))
        let f = g - SIMD2<Float>(i)
        func h(_ a: Int, _ b: Int) -> Float { heights[(i.y + b) * side + i.x + a] }
        return (h(0, 0) * (1 - f.x) + h(1, 0) * f.x) * (1 - f.y) + (h(0, 1) * (1 - f.x) + h(1, 1) * f.x) * f.y
    }

    /// As the GPU reads it (lumenMeshDistance).
    func distance(at p: SIMD3<Float>) -> Float {
        let q = simd_clamp(SIMD2(p.x, p.z), lo, hi)
        let d = (p.y - height(q.x, q.y)) * slope
        let outside = length(SIMD2(p.x, p.z) - q)
        return outside > 0 ? (outside * outside + max(d, 0) * max(d, 0)).squareRoot() : d
    }
}

extension MeshSDFBuilder {
    static let maxHeightfieldSide = 256

    /// The steepest a heightfield may be (its slope factor at least 1/√5: 2 m up a metre). A steeper one (a district of
    /// the open world: streets and walls) would scale every distance above it down to nothing: bricks instead.
    static let minHeightfieldSlope: Float = 1 / Float(5).squareRoot()

    /// Whether a mesh may be better as heights: its relief at most a fifth of its footprint's smaller side (then
    /// `heightfield` decides by its slopes).
    static func isHeightfield(_ bounds: AABB) -> Bool {
        let e = bounds.hi - bounds.lo
        return min(e.x, e.z) > 0 && e.y <= 0.2 * min(e.x, e.z)
    }

    /// The mesh's top surface over a grid (vertical rays from above, through the triangles' footprints); samples no
    /// triangle covers are low (a hole). Nil for no triangles, or slopes steeper than `minHeightfieldSlope`.
    static func heightfield(positions: [SIMD3<Float>], indices: [UInt32]) -> Heightfield? {
        let count = indices.count / 3
        guard count > 0 else { return nil }
        var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        var boxes: [AABB] = []
        var bounds = AABB()
        for t in 0..<count {
            let a = positions[Int(indices[3 * t])], b = positions[Int(indices[3 * t + 1])], c = positions[Int(indices[3 * t + 2])]
            tris.append((a, b, c))
            var box = AABB()
            box.grow(a); box.grow(b); box.grow(c)
            box.lo.y = 0; box.hi.y = 0                   // a 2D tree: the footprints
            boxes.append(box)
            bounds.grow(a); bounds.grow(b); bounds.grow(c)
        }
        let ext = SIMD2(bounds.hi.x - bounds.lo.x, bounds.hi.z - bounds.lo.z)
        // Cells about as fine as the mesh's own (its triangles' mean footprint), within the grid's cap.
        let area = tris.reduce(Float(0)) { s, t in s + abs(cross(t.1 - t.0, t.2 - t.0).y) / 2 }
        let fine = (2 * area / Float(count)).squareRoot()
        let side = min(max(Int((ext.max() / max(fine, 1e-4)).rounded(.up)) + 1, 2), maxHeightfieldSide)
        let cell = ext.max() / Float(side - 1)
        let tree = BVHBuilder.build(boxes: boxes, masks: nil, maxLeaf: 4)
        let low = bounds.lo.y - 4 * cell
        var heights = [Float](repeating: low, count: side * side)
        heights.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: side) { row in
                for x in 0..<side {
                    let p = SIMD2(bounds.lo.x, bounds.lo.z) + SIMD2(Float(x), Float(row)) * cell
                    var best = low
                    var stack = tree.nodes.isEmpty ? [] : [0]
                    while let n = stack.popLast() {
                        let node = tree.nodes[n]
                        guard p.x >= node.box.lo.x - 1e-5, p.x <= node.box.hi.x + 1e-5,
                              p.y >= node.box.lo.z - 1e-5, p.y <= node.box.hi.z + 1e-5 else { continue }
                        if node.left >= 0 { stack += [node.left, node.right]; continue }
                        for i in node.start..<node.start + node.count {
                            let (a, b, c) = tris[tree.order[i]]
                            // Barycentric in the xz plane.
                            let d = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
                            guard abs(d) > 1e-12 else { continue }
                            let u = ((b.z - c.z) * (p.x - c.x) + (c.x - b.x) * (p.y - c.z)) / d
                            let v = ((c.z - a.z) * (p.x - c.x) + (a.x - c.x) * (p.y - c.z)) / d
                            let w = 1 - u - v
                            guard u >= -1e-4, v >= -1e-4, w >= -1e-4 else { continue }
                            best = max(best, u * a.y + v * b.y + w * c.y)
                        }
                    }
                    out[row * side + x] = best
                }
            }
        }
        var steepest: Float = 0
        for z in 0..<side { for x in 0..<side where heights[z * side + x] > low {   // not across a hole's edge
            let h = heights[z * side + x]
            if x + 1 < side, heights[z * side + x + 1] > low { steepest = max(steepest, abs(heights[z * side + x + 1] - h) / cell) }
            if z + 1 < side, heights[(z + 1) * side + x] > low { steepest = max(steepest, abs(heights[(z + 1) * side + x] - h) / cell) }
        } }
        let slope = 1 / (1 + steepest * steepest).squareRoot()
        guard slope >= minHeightfieldSlope else { return nil }
        return Heightfield(lo: SIMD2(bounds.lo.x, bounds.lo.z), cell: cell, side: side, heights: heights, slope: slope, bounds: bounds)
    }
}
