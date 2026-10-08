import Foundation
import simd

/// A shape given by a signed distance field (Shaders/SDF.metal): primitives in the shape's space, combined one after
/// the other. The shape is `nodes[0]`, then each next node joined to what is there so far by its op (a left fold:
/// ((n0 op1 n1) op2 n2) ...). An instance of it (Scene.addInstance(sdf:)) places it as an instance places a mesh;
/// the ray tracers sphere-trace it inside its box, in the instance's space.
///
/// A node's transform is a rotation, a translation and a uniform scale only: the distance stays a distance (a
/// non-uniform scale would make it neither exact nor a bound). The instance's transform may be anything.
struct SDFShape {
    enum Primitive {
        case sphere(radius: Float)
        /// `rounding`: its edges' radius, within the half extents.
        case box(halfExtents: SIMD3<Float>, rounding: Float = 0)
        /// A ring in the xz plane: `major` from the centre to the tube's, `minor` the tube's radius.
        case torus(major: Float, minor: Float)
        /// Along y, its cap's centres at +-halfLength.
        case capsule(halfLength: Float, radius: Float)
        /// Along y; `rounding` its rims' radius.
        case cylinder(halfHeight: Float, radius: Float, rounding: Float = 0)
        /// A capped cone along y: radius `bottom` at -halfHeight, `top` at +halfHeight.
        case cone(halfHeight: Float, bottom: Float, top: Float)
        /// A baked distance grid (Scene.sdfVolumes).
        case volume(Int)
    }

    enum Op: UInt32 {
        case union = 0, subtract = 1, intersect = 2
    }

    struct Node {
        var primitive: Primitive
        var op: Op = .union
        /// The blend's radius (0 = a sharp join): how far from where they meet the two surfaces flow into each other.
        var smooth: Float = 0
        var position = SIMD3<Float>()
        var rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        var scale: Float = 1
        /// Its material, from the instance's: where it is the nearer surface (a cut: the cutter's face), the
        /// instance's material + this.
        var material = 0

        init(_ primitive: Primitive, _ op: Op = .union, smooth: Float = 0, at position: SIMD3<Float> = .zero,
             rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), scale: Float = 1, material: Int = 0) {
            self.primitive = primitive
            self.op = op
            self.smooth = smooth
            self.position = position
            self.rotation = rotation
            self.scale = scale
            self.material = material
        }

        /// Shape space -> the primitive's space.
        func local(_ p: SIMD3<Float>) -> SIMD3<Float> { rotation.inverse.act(p - position) / scale }
        /// The primitive's space -> shape space.
        var transform: float4x4 {
            translate(position) * float4x4(rotation) * MetalRenderer.scale(scale)
        }
    }

    /// The most nodes a shape may have (each costs every step of every ray through its box).
    static let maxNodes = 32

    var nodes: [Node]

    init(_ nodes: [Node]) {
        precondition(!nodes.isEmpty && nodes.count <= SDFShape.maxNodes, "an SDF shape has 1...\(SDFShape.maxNodes) nodes")
        self.nodes = nodes
    }
    init(_ primitive: Primitive, material: Int = 0) { self.init([Node(primitive, material: material)]) }

    /// It has blends or baked grids: their distances are only about right, so the march steps short of them.
    var stepScale: Float {
        nodes.contains { n in
            if case .volume = n.primitive { return true }
            return n.smooth > 0
        } ? 0.8 : 1
    }

    /// The highest material offset any node has.
    var materialCount: Int { (nodes.map(\.material).max() ?? 0) + 1 }

    // MARK: - Distance

    /// The distance from `p` (shape space) to the shape, negative inside, and the material offset of the surface
    /// nearest there. `volumes`: the scene's baked grids.
    func distance(_ p: SIMD3<Float>, volumes: [SDFVolume] = []) -> (d: Float, material: Int) {
        var d = Float.infinity, material = 0
        for (i, node) in nodes.enumerated() {
            let b = node.scale * SDFShape.primitive(node.primitive, node.local(p), volumes: volumes)
            if i == 0 { (d, material) = (b, node.material); continue }
            let (joined, takes) = SDFShape.join(d, b, node.op, node.smooth)
            d = joined
            if takes { material = node.material }
        }
        return (d, material)
    }

    /// `a` op `b` with a blend of radius `k`, and whether the surface there is `b`'s (polynomial smooth min:
    /// it never lowers a distance by more than k/4).
    static func join(_ a: Float, _ b: Float, _ op: Op, _ k: Float) -> (Float, Bool) {
        func smin(_ a: Float, _ b: Float) -> Float {
            guard k > 0 else { return min(a, b) }
            let h = max(k - abs(a - b), 0) / k
            return min(a, b) - h * h * k * 0.25
        }
        switch op {
        case .union: return (smin(a, b), b < a)
        case .subtract: return (-smin(-a, b), -b > a)
        case .intersect: return (-smin(-a, -b), b > a)
        }
    }

    /// The primitive's distance at `q` (its own space).
    static func primitive(_ primitive: Primitive, _ q: SIMD3<Float>, volumes: [SDFVolume]) -> Float {
        switch primitive {
        case .sphere(let r):
            return length(q) - r
        case .box(let b, let r):
            let e = abs(q) - (b - r)
            return length(simd_max(e, .zero)) + min(max(e.x, max(e.y, e.z)), 0) - r
        case .torus(let major, let minor):
            let t = SIMD2(length(SIMD2(q.x, q.z)) - major, q.y)
            return length(t) - minor
        case .capsule(let h, let r):
            return length(SIMD3(q.x, q.y - min(max(q.y, -h), h), q.z)) - r
        case .cylinder(let h, let r, let rr):
            let e = SIMD2(length(SIMD2(q.x, q.z)) - (r - rr), abs(q.y) - (h - rr))
            return min(max(e.x, e.y), 0) + length(simd_max(e, .zero)) - rr
        case .cone(let h, let r1, let r2):
            let p = SIMD2(length(SIMD2(q.x, q.z)), q.y)
            let k1 = SIMD2(r2, h), k2 = SIMD2(r2 - r1, 2 * h)
            let ca = SIMD2(p.x - min(p.x, p.y < 0 ? r1 : r2), abs(p.y) - h)
            let cb = p - k1 + k2 * min(max(dot(k1 - p, k2) / dot(k2, k2), 0), 1)
            let s: Float = cb.x < 0 && ca.y < 0 ? -1 : 1
            return s * sqrt(min(dot(ca, ca), dot(cb, cb)))
        case .volume(let v):
            return volumes[v].distance(q)
        }
    }

    /// The field's gradient at `p` (central differences, step `h`): the outward normal there, unnormalised.
    func gradient(_ p: SIMD3<Float>, h: Float = 1e-3, volumes: [SDFVolume] = []) -> SIMD3<Float> {
        func f(_ q: SIMD3<Float>) -> Float { distance(q, volumes: volumes).d }
        return SIMD3(f(p + SIMD3(h, 0, 0)) - f(p - SIMD3(h, 0, 0)),
                     f(p + SIMD3(0, h, 0)) - f(p - SIMD3(0, h, 0)),
                     f(p + SIMD3(0, 0, h)) - f(p - SIMD3(0, 0, h))) / (2 * h)
    }

    // MARK: - Bounds

    /// The primitive's box in its own space.
    static func primitiveBounds(_ primitive: Primitive, volumes: [SDFVolume]) -> AABB {
        let e: SIMD3<Float>
        switch primitive {
        case .sphere(let r): e = SIMD3(repeating: r)
        case .box(let b, _): e = b
        case .torus(let major, let minor): e = SIMD3(major + minor, minor, major + minor)
        case .capsule(let h, let r): e = SIMD3(r, h + r, r)
        case .cylinder(let h, let r, _): e = SIMD3(r, h, r)
        case .cone(let h, let r1, let r2): e = SIMD3(max(r1, r2), h, max(r1, r2))
        case .volume(let v): return AABB(lo: volumes[v].lo, hi: volumes[v].hi)
        }
        return AABB(lo: -e, hi: e)
    }

    /// A box the whole shape is inside (shape space), with a little room: a union's by both its terms' (and the
    /// blend, which reaches k/4 past them), a cut's by what is cut, an intersection's by the overlap.
    func bounds(volumes: [SDFVolume] = []) -> AABB {
        var box = AABB()
        for (i, node) in nodes.enumerated() {
            let b = SDFShape.primitiveBounds(node.primitive, volumes: volumes).transformed(node.transform)
            if i == 0 { box = b; continue }
            switch node.op {
            case .union:
                box.grow(b)
                box.lo -= SIMD3(repeating: node.smooth / 4)
                box.hi += SIMD3(repeating: node.smooth / 4)
            case .subtract:
                break
            case .intersect:
                box = AABB(lo: simd_max(box.lo, b.lo), hi: simd_min(box.hi, b.hi))
            }
        }
        if box.isEmpty || box.lo.x > box.hi.x || box.lo.y > box.hi.y || box.lo.z > box.hi.z { return AABB() }
        let pad = max(simd_reduce_max(box.hi - box.lo) * 1e-3, 1e-4)
        return AABB(lo: box.lo - pad, hi: box.hi + pad)
    }

    // MARK: - GPU records

    /// The kinds and their parameters as MSL SDFNode has them (Shaders/SDF.metal).
    static let sphereKind: UInt32 = 0, boxKind: UInt32 = 1, torusKind: UInt32 = 2, capsuleKind: UInt32 = 3,
               cylinderKind: UInt32 = 4, coneKind: UInt32 = 5, volumeKind: UInt32 = 6

    var gpuNodes: [GPUSDFNode] {
        nodes.map { n in
            let inv = n.transform.inverse   // shape -> the primitive's space, as rows
            var node = GPUSDFNode(row0: SIMD4(inv[0][0], inv[1][0], inv[2][0], inv[3][0]),
                                  row1: SIMD4(inv[0][1], inv[1][1], inv[2][1], inv[3][1]),
                                  row2: SIMD4(inv[0][2], inv[1][2], inv[2][2], inv[3][2]),
                                  op: n.op.rawValue, k: n.smooth, scale: n.scale, material: UInt32(n.material))
            switch n.primitive {
            case .sphere(let r): (node.kind, node.params) = (SDFShape.sphereKind, SIMD4(r, 0, 0, 0))
            case .box(let b, let r): (node.kind, node.params) = (SDFShape.boxKind, SIMD4(b, r))
            case .torus(let major, let minor): (node.kind, node.params) = (SDFShape.torusKind, SIMD4(major, minor, 0, 0))
            case .capsule(let h, let r): (node.kind, node.params) = (SDFShape.capsuleKind, SIMD4(h, r, 0, 0))
            case .cylinder(let h, let r, let rr): (node.kind, node.params) = (SDFShape.cylinderKind, SIMD4(h, r, rr, 0))
            case .cone(let h, let r1, let r2): (node.kind, node.params) = (SDFShape.coneKind, SIMD4(h, r1, r2, 0))
            case .volume(let v): (node.kind, node.volume) = (SDFShape.volumeKind, UInt32(v))
            }
            return node
        }
    }

    // MARK: - As triangles

    /// The surface as triangles (surface nets on a grid of about `cells` cells along the box's longest side), each
    /// vertex moved onto the surface and then `push` x a cell out along the normal, so that for push > 0 the triangles
    /// lie just outside the true surface (an emissive shape's light: a shadow ray to a point on them never meets the
    /// shape first). `materials`: per triangle, the material offset there.
    func triangles(cells: Int = 48, push: Float = 0.15, volumes: [SDFVolume] = [])
        -> (positions: [SIMD3<Float>], indices: [UInt32], materials: [Int]) {
        let box = bounds(volumes: volumes)
        guard !box.isEmpty else { return ([], [], []) }
        let size = simd_reduce_max(box.hi - box.lo) / Float(cells)
        let lo = box.lo - size
        let n = SIMD3<Int>(((box.hi - box.lo) / size).rounded(.up)) &+ 3   // samples per axis
        let (positions, indices) = SurfaceNets.mesh(lo: lo, size: size, counts: n, push: push,
                                                    distance: { self.distance($0, volumes: volumes).d },
                                                    gradient: { self.gradient($0, h: size * 0.1, volumes: volumes) })
        var materials: [Int] = []
        if nodes.contains(where: { $0.material != 0 }) {
            for t in stride(from: 0, to: indices.count, by: 3) {
                let centre = (positions[Int(indices[t])] + positions[Int(indices[t + 1])] + positions[Int(indices[t + 2])]) / 3
                materials.append(distance(centre, volumes: volumes).material)
            }
        } else {
            materials = [Int](repeating: 0, count: indices.count / 3)
        }
        return (positions, indices, materials)
    }
}

/// Surface nets (Gibson 1998) of any distance function: a vertex in each cell of a grid the surface passes through,
/// at the mean of where it crosses the cell's edges, moved onto the surface (two Newton steps) and then `push` x a cell
/// out along the normal; a quad for each grid edge it crosses, wound to face out.
enum SurfaceNets {
    /// The surface where `distance` is 0 on the grid of `counts` samples `size` apart from `lo`; `gradient`: its.
    static func mesh(lo: SIMD3<Float>, size: Float, counts n: SIMD3<Int>, push: Float = 0,
                     distance: (SIMD3<Float>) -> Float, gradient: (SIMD3<Float>) -> SIMD3<Float>)
        -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        @inline(__always) func at(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * n.y + y) * n.x + x }
        var field = [Float](repeating: 0, count: n.x * n.y * n.z)
        field.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: n.z) { z in
                for y in 0..<n.y {
                    for x in 0..<n.x {
                        out[at(x, y, z)] = distance(lo + SIMD3(Float(x), Float(y), Float(z)) * size)
                    }
                }
            }
        }
        // One vertex per cell the surface passes through: the mean of where it crosses the cell's edges.
        var vertexOf = [Int32](repeating: -1, count: field.count)
        var positions: [SIMD3<Float>] = []
        let corners = (0..<8).map { SIMD3<Int>($0 & 1, ($0 >> 1) & 1, ($0 >> 2) & 1) }
        let edges = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        for z in 0..<(n.z - 1) {
            for y in 0..<(n.y - 1) {
                for x in 0..<(n.x - 1) {
                    let v = corners.map { field[at(x + $0.x, y + $0.y, z + $0.z)] }
                    let inside = v.filter { $0 < 0 }.count
                    guard inside > 0 && inside < 8 else { continue }
                    var sum = SIMD3<Float>(), count: Float = 0
                    for (a, b) in edges where (v[a] < 0) != (v[b] < 0) {
                        let t = v[a] / (v[a] - v[b])
                        sum += SIMD3<Float>(corners[a]) + (SIMD3<Float>(corners[b]) - SIMD3<Float>(corners[a])) * t
                        count += 1
                    }
                    vertexOf[at(x, y, z)] = Int32(positions.count)
                    positions.append(lo + (SIMD3(Float(x), Float(y), Float(z)) + sum / count) * size)
                }
            }
        }
        // Onto the surface (two Newton steps), then out by the push.
        positions.withUnsafeMutableBufferPointer { ps in
            DispatchQueue.concurrentPerform(iterations: ps.count) { i in
                var p = ps[i]
                for _ in 0..<2 {
                    let g = gradient(p)
                    let len2 = dot(g, g)
                    guard len2 > 1e-12 else { break }
                    p -= g * (distance(p) / len2)
                }
                let g = gradient(p)
                if dot(g, g) > 1e-12 { p += normalize(g) * (push * size) }
                ps[i] = p
            }
        }
        // A quad for each grid edge the surface crosses, between the four cells around it, wound to face out.
        var indices: [UInt32] = []
        for z in 1..<(n.z - 1) {
            for y in 1..<(n.y - 1) {
                for x in 1..<(n.x - 1) {
                    let here = field[at(x, y, z)]
                    for axis in 0..<3 {
                        let next = axis == 0 ? field[at(x + 1, y, z)] : axis == 1 ? field[at(x, y + 1, z)] : field[at(x, y, z + 1)]
                        guard (here < 0) != (next < 0) else { continue }
                        // The four cells that share the edge from (x, y, z) along `axis`.
                        let (u, w) = axis == 0 ? (SIMD3(0, 1, 0), SIMD3(0, 0, 1)) : axis == 1 ? (SIMD3(0, 0, 1), SIMD3(1, 0, 0))
                                                                                             : (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
                        let c = SIMD3(x, y, z)
                        let quad = [c &- u &- w, c &- w, c, c &- u].map { vertexOf[at($0.x, $0.y, $0.z)] }
                        guard quad.allSatisfy({ $0 >= 0 }) else { continue }
                        let q = quad.map { UInt32($0) }
                        if here < 0 {
                            indices += [q[0], q[1], q[2], q[0], q[2], q[3]]
                        } else {
                            indices += [q[0], q[2], q[1], q[0], q[3], q[2]]
                        }
                    }
                }
            }
        }
        return (positions, indices)
    }
}

extension SurfaceNets {
    /// Surface nets on a sparse grid: the grid of `counts` samples `size` apart from `lo` in bricks of `brick` cells a
    /// side, of which only those whose middle is within half their diagonal (and two cells) of the surface are
    /// sampled. `distance` must not overstate how far the surface is (a distance field, or one clamped below it). The
    /// same surface as `mesh`, without a dense field: a body's skin at 2.5 mm samples a sixtieth of its box.
    static func sparseMesh(lo: SIMD3<Float>, size: Float, counts n: SIMD3<Int>, brick: Int = 8,
                           distance: (SIMD3<Float>) -> Float, gradient: (SIMD3<Float>) -> SIMD3<Float>)
        -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        let b = brick, side = b + 1, samples = side * side * side, cells = b * b * b
        let nb = SIMD3<Int>((n.x - 2) / b + 1, (n.y - 2) / b + 1, (n.z - 2) / b + 1)
        @inline(__always) func brickIndex(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * nb.y + y) * nb.x + x }
        // The bricks the surface may pass through.
        let reach = Float(b) * size * 0.8661 + 2 * size
        var slabs = [[Int32]](repeating: [], count: nb.z)
        slabs.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: nb.z) { z in
                for y in 0..<nb.y {
                    for x in 0..<nb.x {
                        let middle = lo + (SIMD3(Float(x), Float(y), Float(z)) + 0.5) * Float(b) * size
                        if abs(distance(middle)) <= reach { out[z].append(Int32(brickIndex(x, y, z))) }
                    }
                }
            }
        }
        // ...and their neighbours: a quad needs the four cells round its edge, which may be in the next brick.
        var marked = [Bool](repeating: false, count: nb.x * nb.y * nb.z)
        for i in slabs.joined() {
            let c = SIMD3(Int(i) % nb.x, (Int(i) / nb.x) % nb.y, Int(i) / (nb.x * nb.y))
            for z in max(c.z - 1, 0)...min(c.z + 1, nb.z - 1) {
                for y in max(c.y - 1, 0)...min(c.y + 1, nb.y - 1) {
                    for x in max(c.x - 1, 0)...min(c.x + 1, nb.x - 1) { marked[brickIndex(x, y, z)] = true }
                }
            }
        }
        let active = marked.indices.filter { marked[$0] }.map(Int32.init)
        var slot = [Int32](repeating: -1, count: nb.x * nb.y * nb.z)
        for (k, i) in active.enumerated() { slot[Int(i)] = Int32(k) }
        func origin(_ i: Int) -> SIMD3<Int> { SIMD3(i % nb.x, (i / nb.x) % nb.y, i / (nb.x * nb.y)) &* b }
        // Each brick's samples, its corners shared with its neighbours' (sampled twice).
        var field = [Float](repeating: 0, count: active.count * samples)
        field.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: active.count) { k in
                let o = origin(Int(active[k]))
                for z in 0...b { for y in 0...b { for x in 0...b {
                    let p = lo + SIMD3(Float(o.x + x), Float(o.y + y), Float(o.z + z)) * size
                    out[k * samples + (z * side + y) * side + x] = distance(p)
                } } }
            }
        }
        // A vertex per cell the surface passes through, at the mean of where it crosses the cell's edges.
        let corners = (0..<8).map { SIMD3<Int>($0 & 1, ($0 >> 1) & 1, ($0 >> 2) & 1) }
        let edges = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        var local = [[(cell: Int32, p: SIMD3<Float>)]](repeating: [], count: active.count)
        local.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: active.count) { k in
                let o = origin(Int(active[k]))
                var v = [Float](repeating: 0, count: 8)
                for z in 0..<b { for y in 0..<b { for x in 0..<b {
                    var inside = 0
                    for c in 0..<8 {
                        v[c] = field[k * samples + ((z + corners[c].z) * side + y + corners[c].y) * side + x + corners[c].x]
                        if v[c] < 0 { inside += 1 }
                    }
                    guard inside > 0 && inside < 8 else { continue }
                    var sum = SIMD3<Float>(), count: Float = 0
                    for (a, e) in edges where (v[a] < 0) != (v[e] < 0) {
                        let t = v[a] / (v[a] - v[e])
                        sum += SIMD3<Float>(corners[a]) + (SIMD3<Float>(corners[e]) - SIMD3<Float>(corners[a])) * t
                        count += 1
                    }
                    out[k].append((Int32((z * b + y) * b + x), lo + (SIMD3(Float(o.x + x), Float(o.y + y), Float(o.z + z)) + sum / count) * size))
                } } }
            }
        }
        var vertexOf = [Int32](repeating: -1, count: active.count * cells)
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(local.reduce(0) { $0 + $1.count })
        for k in local.indices {
            for v in local[k] {
                vertexOf[k * cells + Int(v.cell)] = Int32(positions.count)
                positions.append(v.p)
            }
        }
        local = []
        // Onto the surface (two Newton steps).
        positions.withUnsafeMutableBufferPointer { ps in
            DispatchQueue.concurrentPerform(iterations: ps.count) { i in
                var p = ps[i]
                for _ in 0..<2 {
                    let g = gradient(p), len2 = dot(g, g)
                    guard len2 > 1e-12 else { break }
                    p -= g * (distance(p) / len2)
                }
                ps[i] = p
            }
        }
        // The vertex of the cell at grid coordinates `c`, if its brick was sampled and the surface passes through it.
        func vertex(_ c: SIMD3<Int>) -> Int32 {
            guard c.x >= 0, c.y >= 0, c.z >= 0 else { return -1 }
            let bc = SIMD3(c.x / b, c.y / b, c.z / b)
            guard bc.x < nb.x, bc.y < nb.y, bc.z < nb.z else { return -1 }
            let k = slot[brickIndex(bc.x, bc.y, bc.z)]
            guard k >= 0 else { return -1 }
            let l = c &- bc &* b
            return vertexOf[Int(k) * cells + (l.z * b + l.y) * b + l.x]
        }
        // A quad for each grid edge the surface crosses (each edge is its first sample's brick's), wound to face out.
        var quads = [[UInt32]](repeating: [], count: active.count)
        quads.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: active.count) { k in
                let o = origin(Int(active[k]))
                for z in 0..<b { for y in 0..<b { for x in 0..<b {
                    let here = field[k * samples + (z * side + y) * side + x]
                    for axis in 0..<3 {
                        let next = axis == 0 ? field[k * samples + (z * side + y) * side + x + 1]
                                 : axis == 1 ? field[k * samples + (z * side + y + 1) * side + x]
                                             : field[k * samples + ((z + 1) * side + y) * side + x]
                        guard (here < 0) != (next < 0) else { continue }
                        let (u, w) = axis == 0 ? (SIMD3(0, 1, 0), SIMD3(0, 0, 1)) : axis == 1 ? (SIMD3(0, 0, 1), SIMD3(1, 0, 0))
                                                                                             : (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
                        let c = o &+ SIMD3(x, y, z)
                        let q = [c &- u &- w, c &- w, c, c &- u].map(vertex)
                        guard q.allSatisfy({ $0 >= 0 }) else { continue }
                        let v = q.map { UInt32($0) }
                        out[k] += here < 0 ? [v[0], v[1], v[2], v[0], v[2], v[3]] : [v[0], v[2], v[1], v[0], v[3], v[2]]
                    }
                } } }
            }
        }
        return (positions, quads.flatMap { $0 })
    }
}
