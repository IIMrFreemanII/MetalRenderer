import Foundation
import simd

/// A liquid's drawn surface, made again every frame on the GPU (Shaders/FluidSurface.metal) from where its particles
/// are: each particle splats its weight onto a grid a spacing apart (trilinear, fixed point), a [1 4 6 4 1] blur along
/// each axis smooths it, and surface nets (Gibson 1998) put a vertex in every cell the iso level crosses (the mean of
/// its edges' crossings) and a quad across every edge that crosses it. Vertices and quads go where scans of the cells'
/// counts put them, in the cells' order: the same mesh every time, and the same as `FluidSystem.cpuSurface` (the
/// reference). The mesh holds a fixed number of vertices and triangles (the scene's buffers are made once); those
/// past what it needs are degenerate, at one spare vertex. Its acceleration structure is built again every frame.
///
/// The grid reaches three cells past the domain, its border nodes held at 0: the surface closes inside the walls
/// and the floor, where nothing sees it.
extension FluidSystem {
    /// The level the surface is at: the blurred field is about 1 inside (a particle a cell).
    static let iso: Float = 0.28
    static let splatScale: Float = 65_536
    static let surfaceMargin = 3

    /// The surface's grid for this liquid (the mesh's place is the scene's to fill in).
    func surfaceGrid() -> GPUFluidSurface {
        let c = spacing
        let inner = params.counts.w == 1 ? AABB(lo: domain.lo + 2 * cell, hi: domain.hi - 2 * cell) : domain
        let m = Float(FluidSystem.surfaceMargin)
        let lo = inner.lo - m * c
        let dims = SIMD3<Int>(((inner.hi - inner.lo) / c).rounded(.up)) &+ (2 * FluidSystem.surfaceMargin + 1)
        var s = GPUFluidSurface()
        s.lo = SIMD4(lo, c)
        s.dims = SIMD4(UInt32(dims.x), UInt32(dims.y), UInt32(dims.z), UInt32(dims.x * dims.y * dims.z))
        s.field = SIMD4(FluidSystem.iso, FluidSystem.splatScale, 1 / c, 0)
        return s
    }

    /// The box the surface stays in.
    func surfaceBounds(_ s: GPUFluidSurface) -> AABB {
        let lo = PhysicsMath.xyz(s.lo)
        return AABB(lo: lo, hi: lo + SIMD3<Float>(Float(s.dims.x - 1), Float(s.dims.y - 1), Float(s.dims.z - 1)) * s.lo.w)
    }

    /// How many vertices and triangles its mesh holds: a vertex per particle (a liquid's surface needs far fewer: a
    /// pool's top and bottom, the stream's sides), 32k at least.
    var surfaceCapacity: (vertices: Int, triangles: Int) {
        let v = min(max(capacity, 32768), 262_144)
        return (v, 2 * v)
    }

    // MARK: - The CPU's surface (the reference)

    /// Node `n`'s place in the grid.
    @inline(__always) static func node(_ x: Int, _ y: Int, _ z: Int, _ s: GPUFluidSurface) -> Int {
        x + Int(s.dims.x) * (y + Int(s.dims.y) * z)
    }

    /// The field: the particles' splat (integers, as the GPU adds them), blurred along x, y, z, its border 0.
    func cpuField(_ s: GPUFluidSurface) -> [Float] {
        let n = Int(s.dims.w), nx = Int(s.dims.x), ny = Int(s.dims.y), nz = Int(s.dims.z)
        var splat = [Int32](repeating: 0, count: n)
        let lo = PhysicsMath.xyz(s.lo)
        for q in particles {
            let g = (PhysicsMath.xyz(q.position) - lo) * s.field.z
            let base = simd_clamp(SIMD3<Int32>(g.rounded(.down)), .zero, SIMD3<Int32>(Int32(nx) - 2, Int32(ny) - 2, Int32(nz) - 2))
            let f = simd_clamp(g - SIMD3<Float>(base), .zero, SIMD3(repeating: 1))
            for k in 0..<8 {
                let o = SIMD3<Int32>(Int32(k & 1), Int32(k >> 1 & 1), Int32(k >> 2))
                let w = (o.x == 0 ? 1 - f.x : f.x) * (o.y == 0 ? 1 - f.y : f.y) * (o.z == 0 ? 1 - f.z : f.z)
                let c = base &+ o
                splat[FluidSystem.node(Int(c.x), Int(c.y), Int(c.z), s)] &+= PhysicsWorld.fixed(w, s.field.y)
            }
        }
        var a = splat.map { Float($0) / s.field.y }
        var b = [Float](repeating: 0, count: n)
        let taps: [Float] = [1, 4, 6, 4, 1]
        for axis in 0..<3 {
            for z in 0..<nz {
                for y in 0..<ny {
                    for x in 0..<nx {
                        var sum: Float = 0
                        for t in -2...2 {
                            var c = SIMD3(x, y, z)
                            c[axis] += t
                            guard all(c .>= 0), c.x < nx, c.y < ny, c.z < nz else { continue }
                            sum += taps[t + 2] * a[FluidSystem.node(c.x, c.y, c.z, s)]
                        }
                        let border = x == 0 || y == 0 || z == 0 || x == nx - 1 || y == ny - 1 || z == nz - 1
                        b[FluidSystem.node(x, y, z, s)] = axis == 2 && border ? 0 : sum / 16
                    }
                }
            }
            swap(&a, &b)
        }
        return a
    }

    /// The mesh the GPU makes (its vertices and normals, and its triangles' indices counted from its first vertex: the
    /// GPU adds the mesh's place in the buffer), as far as it needs: no spare vertex, no degenerate tail.
    func cpuSurface(_ s: GPUFluidSurface) -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]) {
        let field = cpuField(s)
        let nx = Int(s.dims.x), ny = Int(s.dims.y), nz = Int(s.dims.z), n = Int(s.dims.w)
        var vertexOf = [Int](repeating: -1, count: n)
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = []
        for z in 0..<nz {
            for y in 0..<ny {
                for x in 0..<nx {
                    guard let (p, nrm) = FluidSystem.surfaceVertex(x, y, z, s, field) else { continue }
                    vertexOf[FluidSystem.node(x, y, z, s)] = positions.count
                    positions.append(p)
                    normals.append(nrm)
                }
            }
        }
        var indices: [UInt32] = []
        for z in 0..<nz {
            for y in 0..<ny {
                for x in 0..<nx {
                    for quad in FluidSystem.surfaceQuads(x, y, z, s, field) {
                        let v = quad.map { UInt32(vertexOf[FluidSystem.node($0.x, $0.y, $0.z, s)]) }
                        indices += [v[0], v[1], v[2], v[0], v[2], v[3]]
                    }
                }
            }
        }
        return (positions, normals, indices)
    }

    /// The vertex in the cell from node (x, y, z), if the surface crosses it (MSL fluidSurfaceVertex): the mean of
    /// its edges' crossings, and the outward normal there (the field falls outward).
    static func surfaceVertex(_ x: Int, _ y: Int, _ z: Int, _ s: GPUFluidSurface, _ field: [Float]) -> (SIMD3<Float>, SIMD3<Float>)? {
        guard x + 1 < Int(s.dims.x), y + 1 < Int(s.dims.y), z + 1 < Int(s.dims.z) else { return nil }
        var v = [Float](repeating: 0, count: 8)
        var inside = 0
        for k in 0..<8 {
            v[k] = field[node(x + (k & 1), y + (k >> 1 & 1), z + (k >> 2), s)]
            if v[k] > s.field.x { inside += 1 }
        }
        guard inside > 0, inside < 8 else { return nil }
        var sum = SIMD3<Float>(), count: Float = 0
        for (a, b) in edges {
            let fa = v[a], fb = v[b]
            guard (fa > s.field.x) != (fb > s.field.x) else { continue }
            let t = (s.field.x - fa) / (fb - fa)
            let pa = corner(a), pb = corner(b)
            sum += pa + (pb - pa) * t
            count += 1
        }
        let f = sum / count   // in the cell, 0...1
        // The trilinear field's gradient there.
        func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        let gx = lerp(lerp(v[1] - v[0], v[3] - v[2], f.y), lerp(v[5] - v[4], v[7] - v[6], f.y), f.z)
        let gy = lerp(lerp(v[2] - v[0], v[3] - v[1], f.x), lerp(v[6] - v[4], v[7] - v[5], f.x), f.z)
        let gz = lerp(lerp(v[4] - v[0], v[5] - v[1], f.x), lerp(v[6] - v[2], v[7] - v[3], f.x), f.y)
        let g = SIMD3(gx, gy, gz), l = length(g)
        let position = PhysicsMath.xyz(s.lo) + (SIMD3<Float>(Float(x), Float(y), Float(z)) + f) * s.lo.w
        return (position, l > 1e-12 ? -g / l : SIMD3(0, 1, 0))
    }

    /// The cell's corners (k: x bit 0, y bit 1, z bit 2) and its 12 edges.
    @inline(__always) static func corner(_ k: Int) -> SIMD3<Float> { SIMD3(Float(k & 1), Float(k >> 1 & 1), Float(k >> 2)) }
    static let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]

    /// The quads across the edges from node (x, y, z) along +x, +y, +z that the surface crosses (MSL fluidSurfaceQuad):
    /// each the four cells about the edge, wound to face out (the side the field falls to).
    static func surfaceQuads(_ x: Int, _ y: Int, _ z: Int, _ s: GPUFluidSurface, _ field: [Float]) -> [[SIMD3<Int>]] {
        let dims = SIMD3(Int(s.dims.x), Int(s.dims.y), Int(s.dims.z)), p = SIMD3(x, y, z)
        var quads: [[SIMD3<Int>]] = []
        for a in 0..<3 {
            let b = (a + 1) % 3, c = (a + 2) % 3
            var q = p
            q[a] += 1
            guard q[a] < dims[a], p[b] >= 1, p[c] >= 1 else { continue }
            let f0 = field[node(p.x, p.y, p.z, s)], f1 = field[node(q.x, q.y, q.z, s)]
            let in0 = f0 > s.field.x
            guard in0 != (f1 > s.field.x) else { continue }
            // The cells about the edge, counter-clockwise about +a: (b-, c-), (b+, c-), (b+, c+), (b-, c+).
            var cells: [SIMD3<Int>] = []
            for (db, dc) in [(-1, -1), (0, -1), (0, 0), (-1, 0)] {
                var k = p
                k[b] += db
                k[c] += dc
                cells.append(k)
            }
            quads.append(in0 ? cells : [cells[0], cells[3], cells[2], cells[1]])
        }
        return quads
    }
}
