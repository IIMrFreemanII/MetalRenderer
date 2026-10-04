import Foundation
import simd

/// A square heightfield around the origin: rolling ground from a few octaves of gradient noise, flattened to y = 0
/// around a clearing. One mesh (two triangles per cell), and the same surface as a function: `height` interpolates on
/// the mesh's own triangles, so what is planted with it stands on the ground exactly.
struct Terrain {
    let size: Float                     // metres across
    let cells: Int                      // per side
    let relief: Float                   // about the height of the highest hills
    private(set) var heights: [Float]   // (cells + 1) squared, rows along z

    private var cell: Float { size / Float(cells) }

    /// `flat`: the ground is level inside `inner` metres of `center` and rises to its own shape by `outer`.
    init(size: Float, cells: Int, seed: UInt64, relief: Float, flat: (center: SIMD2<Float>, inner: Float, outer: Float)? = nil) {
        self.size = size
        self.cells = cells
        self.relief = relief
        let n = cells + 1, step = size / Float(cells), half = size / 2
        let noiseSeed = UInt32(truncatingIfNeeded: seed &* 0x9E37_79B9 &+ 17)
        heights = [Float](repeating: 0, count: n * n)
        heights.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: n) { j in   // a row each: disjoint slots
                for i in 0..<n {
                    let p = SIMD2<Float>(Float(i) * step - half, Float(j) * step - half)
                    // Broad hills, with smaller ground on top of them.
                    var h = relief * 1.7 * Terrain.fbm(p / 120, octaves: 5, seed: noiseSeed)
                    if let flat {
                        let t = min(max((length(p - flat.center) - flat.inner) / (flat.outer - flat.inner), 0), 1)
                        h *= t * t * (3 - 2 * t)
                    }
                    out[j * n + i] = h
                }
            }
        }
    }

    // MARK: - Noise

    @inline(__always) private static func hash(_ x: Int32, _ y: Int32, _ seed: UInt32) -> UInt32 {
        var h = UInt32(bitPattern: x) &* 0x85EB_CA6B ^ UInt32(bitPattern: y) &* 0xC2B2_AE35 ^ seed &* 0x27D4_EB2F
        h ^= h >> 15; h = h &* 0x2C1B_3C6D; h ^= h >> 12; h = h &* 0x297A_2D39; h ^= h >> 15
        return h
    }

    /// 2D gradient noise (Perlin), about -0.7...0.7, one lattice cell per unit.
    static func noise(_ p: SIMD2<Float>, seed: UInt32) -> Float {
        let base = SIMD2(floor(p.x), floor(p.y))
        let ix = Int32(base.x), iy = Int32(base.y)
        let f = p - base
        @inline(__always) func corner(_ dx: Int32, _ dy: Int32) -> Float {
            let a = Float(hash(ix &+ dx, iy &+ dy, seed) & 0xFFFF) * (2 * Float.pi / 65536)
            return cos(a) * (f.x - Float(dx)) + sin(a) * (f.y - Float(dy))
        }
        let u = f * f * f * (f * (f * 6 - 15) + 10)
        let low = corner(0, 0) + (corner(1, 0) - corner(0, 0)) * u.x
        let high = corner(0, 1) + (corner(1, 1) - corner(0, 1)) * u.x
        return low + (high - low) * u.y
    }

    /// `octaves` of noise, each twice as fine and half as strong.
    static func fbm(_ p: SIMD2<Float>, octaves: Int, seed: UInt32) -> Float {
        var sum: Float = 0, amplitude: Float = 1, q = p
        for o in 0..<octaves {
            sum += amplitude * noise(q, seed: seed &+ UInt32(o))
            amplitude *= 0.5
            q *= 2
        }
        return sum
    }

    /// The same noise at a place given in doubles: the lattice cell is found exactly, however far out it is, and
    /// only the place inside the cell is a float (the open world, World.swift).
    static func noise(_ x: Double, _ y: Double, seed: UInt32) -> Float {
        let bx = x.rounded(.down), by = y.rounded(.down)
        let ix = Int32(truncatingIfNeeded: Int(bx)), iy = Int32(truncatingIfNeeded: Int(by))
        let f = SIMD2(Float(x - bx), Float(y - by))
        @inline(__always) func corner(_ dx: Int32, _ dy: Int32) -> Float {
            let a = Float(hash(ix &+ dx, iy &+ dy, seed) & 0xFFFF) * (2 * Float.pi / 65536)
            return cos(a) * (f.x - Float(dx)) + sin(a) * (f.y - Float(dy))
        }
        let u = f * f * f * (f * (f * 6 - 15) + 10)
        let low = corner(0, 0) + (corner(1, 0) - corner(0, 0)) * u.x
        let high = corner(0, 1) + (corner(1, 1) - corner(0, 1)) * u.x
        return low + (high - low) * u.y
    }

    static func fbm(_ x: Double, _ y: Double, octaves: Int, seed: UInt32) -> Float {
        var sum: Float = 0, amplitude: Float = 1, qx = x, qy = y
        for o in 0..<octaves {
            sum += amplitude * noise(qx, qy, seed: seed &+ UInt32(o))
            amplitude *= 0.5
            qx *= 2
            qy *= 2
        }
        return sum
    }

    // MARK: - The surface

    /// The cell under (x, z) and the position inside it, clamped to the terrain.
    @inline(__always) private func locate(_ x: Float, _ z: Float) -> (i: Int, j: Int, u: Float, v: Float) {
        let gx = min(max((x + size / 2) / cell, 0), Float(cells)), gz = min(max((z + size / 2) / cell, 0), Float(cells))
        let i = min(Int(gx), cells - 1), j = min(Int(gz), cells - 1)
        return (i, j, gx - Float(i), gz - Float(j))
    }

    /// The cell's corner heights: (x, z), (x+1, z), (x, z+1), (x+1, z+1).
    @inline(__always) private func corners(_ i: Int, _ j: Int) -> (Float, Float, Float, Float) {
        let n = cells + 1, k = j * n + i
        return (heights[k], heights[k + 1], heights[k + n], heights[k + n + 1])
    }

    /// The ground's height: on the mesh's triangle under the point (a cell's diagonal runs from its low corner to its high one).
    func height(_ x: Float, _ z: Float) -> Float {
        let (i, j, u, v) = locate(x, z)
        let (h00, h10, h01, h11) = corners(i, j)
        return u >= v ? h00 + (h10 - h00) * u + (h11 - h10) * v : h00 + (h11 - h01) * u + (h01 - h00) * v
    }

    /// The normal of that triangle.
    func normal(_ x: Float, _ z: Float) -> SIMD3<Float> {
        let (i, j, u, v) = locate(x, z)
        let (h00, h10, h01, h11) = corners(i, j)
        let slope = u >= v ? SIMD2(h10 - h00, h11 - h10) : SIMD2(h11 - h01, h01 - h00)
        return normalize(SIMD3(-slope.x, cell, -slope.y))
    }

    /// The mesh: smooth normals from the neighbouring heights, UVs 0...1 across it (x, z).
    func mesh() -> Foliage.Mesh {
        let n = cells + 1, step = cell, half = size / 2
        let size = Foliage.MeshSize(vertices: n * n, indices: cells * cells * 6)
        return heights.withUnsafeBufferPointer { h in
            Foliage.build(size) { w in
                for j in 0..<n {
                    for i in 0..<n {
                        let dx = h[j * n + min(i + 1, cells)] - h[j * n + max(i - 1, 0)]
                        let dz = h[min(j + 1, cells) * n + i] - h[max(j - 1, 0) * n + i]
                        let spanX = Float(min(i + 1, cells) - max(i - 1, 0)) * step, spanZ = Float(min(j + 1, cells) - max(j - 1, 0)) * step
                        let p = SIMD3(Float(i) * step - half, h[j * n + i], Float(j) * step - half)
                        w.vertex(p, normalize(SIMD3(-dx / spanX, 1, -dz / spanZ)), SIMD2(Float(i), Float(j)) / Float(cells))
                    }
                }
                for j in 0..<cells {
                    for i in 0..<cells {
                        let a = UInt32(j * n + i), b = a + 1, c = a + UInt32(n), d = c + 1
                        w.triangle(a, d, b)
                        w.triangle(a, c, d)
                    }
                }
                return (size.vertices, size.indices)
            }
        }
    }
}
