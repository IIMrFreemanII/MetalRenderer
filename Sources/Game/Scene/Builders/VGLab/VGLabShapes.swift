import EngineCore
import Foundation
import simd

/// One procedural test shape of the virtual-geometry lab: a cache key, a name, and a deterministic builder.
package struct VGLabShape {
    /// Cache key: the name and every parameter, e.g. "vglab-icosphere-s7-v1".
    package let key: String
    /// Shown in signs and the per-instance table.
    package let name: String
    /// Closed and consistently wound outward: the cracks view applies.
    package let watertight: Bool
    /// Deterministic; only called on a cache miss.
    package let build: () -> VGMeshArrays

    package init(key: String, name: String, watertight: Bool, build: @escaping () -> VGMeshArrays) {
        self.key = key
        self.name = name
        self.watertight = watertight
        self.build = build
    }
}

/// The lab's shapes, each at least `VirtualGeometryBuilder.minTriangles` triangles, CCW front faces outward.
/// Built once offline, so plain Swift.
package enum VGLabShapes {
    // MARK: Helpers

    private typealias Vertex = (position: SIMD3<Float>, normal: SIMD3<Float>, uv: SIMD2<Float>)

    private static func empty(vertices: Int, triangles: Int) -> VGMeshArrays {
        var m = VGMeshArrays(positions: [], normals: [], uvs: [], indices: [])
        m.positions.reserveCapacity(vertices)
        m.normals.reserveCapacity(vertices)
        m.uvs.reserveCapacity(vertices)
        m.indices.reserveCapacity(triangles * 3)
        return m
    }

    /// A grid of `cols` x `rows` quads; vertex (s, t) from `vertex`. With the first axis (s) crossed with the second
    /// (t) pointing outward, the triangles are CCW from outside; `flip` reverses them.
    private static func appendGrid(
        _ m: inout VGMeshArrays, cols: Int, rows: Int, flip: Bool, vertex: (Int, Int) -> Vertex
    ) {
        let base = UInt32(m.positions.count)
        for t in 0...rows {
            for s in 0...cols {
                let v = vertex(s, t)
                m.positions.append(v.position)
                m.normals.append(v.normal)
                m.uvs.append(v.uv)
            }
        }
        let stride = UInt32(cols + 1)
        for t in 0..<UInt32(rows) {
            for s in 0..<UInt32(cols) {
                let a = base + t * stride + s, b = a + stride
                if flip {
                    m.indices += [a, b, a + 1, a + 1, b, b + 1]
                } else {
                    m.indices += [a, a + 1, b, a + 1, b + 1, b]
                }
            }
        }
    }

    /// A flat face at `origin` spanned by `du` x `dv` (du x dv points outward), 0..1 UVs.
    private static func appendFace(
        _ m: inout VGMeshArrays, origin: SIMD3<Float>, du: SIMD3<Float>, dv: SIMD3<Float>, cols: Int, rows: Int
    ) {
        let n = normalize(cross(du, dv))
        appendGrid(&m, cols: cols, rows: rows, flip: false) { s, t in
            let fs = Float(s) / Float(cols), ft = Float(t) / Float(rows)
            return (origin + du * fs + dv * ft, n, SIMD2(fs, ft))
        }
    }

    // MARK: Icosphere

    package static func icosphere(subdivisions: Int = 7) -> VGLabShape {
        VGLabShape(key: "vglab-icosphere-s\(subdivisions)-v1", name: "Icosphere", watertight: true) {
            let g = MeshShapes.icosphere(subdivisions: subdivisions)
            let uvs = g.positions.map { p -> SIMD2<Float> in
                SIMD2(atan2(p.z, p.x) / (2 * .pi) + 0.5, acos(max(-1, min(1, p.y))) / .pi)
            }
            return VGMeshArrays(positions: g.positions, normals: g.normals, uvs: uvs, indices: g.indices)
        }
    }

    // MARK: Torus knot

    package static func torusKnot(p: Int = 2, q: Int = 3, tubular: Int = 2048, radial: Int = 48) -> VGLabShape {
        VGLabShape(key: "vglab-torusknot-p\(p)-q\(q)-t\(tubular)-r\(radial)-v1", name: "Torus knot", watertight: true) {
            // Curve scaled to about 1 m across; tube radius clear of the knot's own crossings.
            let scale = 1.0 / 6.0, tube = 0.25 * scale
            func curve(_ t: Double) -> SIMD3<Double> {
                let r = cos(Double(q) * t) + 2
                return SIMD3(r * cos(Double(p) * t), r * sin(Double(p) * t), -sin(Double(q) * t)) * scale
            }
            var m = empty(vertices: tubular * radial, triangles: 2 * tubular * radial)
            let cs = (0..<radial).map { cos(2 * Double.pi * Double($0) / Double(radial)) }
            let sn = (0..<radial).map { sin(2 * Double.pi * Double($0) / Double(radial)) }
            let h = 1e-4
            for i in 0..<tubular {
                let t = 2 * Double.pi * Double(i) / Double(tubular)
                let c = curve(t)
                let d1 = (curve(t + h) - curve(t - h)) / (2 * h)
                let d2 = (curve(t + h) - 2 * c + curve(t - h)) / (h * h)
                let tan = simd_normalize(d1)
                let nrm = simd_normalize(d2 - tan * simd_dot(d2, tan))
                let bin = simd_cross(tan, nrm)
                for j in 0..<radial {
                    let dir = nrm * cs[j] + bin * sn[j]
                    m.positions.append(SIMD3<Float>(c + dir * tube))
                    m.normals.append(SIMD3<Float>(dir))
                    m.uvs.append(SIMD2(Float(i) / Float(tubular), Float(j) / Float(radial)))
                }
            }
            // Wrapped in both directions: the seam is welded by index.
            for i in 0..<tubular {
                let i1 = (i + 1) % tubular
                for j in 0..<radial {
                    let j1 = (j + 1) % radial
                    let a = UInt32(i * radial + j), b = UInt32(i * radial + j1)
                    let c = UInt32(i1 * radial + j), d = UInt32(i1 * radial + j1)
                    m.indices += [a, b, c, c, b, d]
                }
            }
            return m
        }
    }

    // MARK: Seam cube

    package static func seamCube(segments: Int = 128) -> VGLabShape {
        VGLabShape(key: "vglab-seamcube-s\(segments)-v1", name: "Seam cube", watertight: true) {
            var m = empty(vertices: 6 * (segments + 1) * (segments + 1), triangles: 12 * segments * segments)
            let x = SIMD3<Float>(2, 0, 0), y = SIMD3<Float>(0, 2, 0), z = SIMD3<Float>(0, 0, 2)
            appendFace(&m, origin: [1, -1, -1], du: y, dv: z, cols: segments, rows: segments)
            appendFace(&m, origin: [-1, -1, -1], du: z, dv: y, cols: segments, rows: segments)
            appendFace(&m, origin: [-1, 1, -1], du: z, dv: x, cols: segments, rows: segments)
            appendFace(&m, origin: [-1, -1, -1], du: x, dv: z, cols: segments, rows: segments)
            appendFace(&m, origin: [-1, -1, 1], du: x, dv: y, cols: segments, rows: segments)
            appendFace(&m, origin: [-1, -1, -1], du: y, dv: x, cols: segments, rows: segments)
            return m
        }
    }

    // MARK: Needle comb

    package static func needleComb(needles: Int = 48, around: Int = 12, along: Int = 128) -> VGLabShape {
        VGLabShape(
            key: "vglab-needlecomb-n\(needles)-a\(around)-l\(along)-v1", name: "Needle comb", watertight: true
        ) {
            let length: Float = 0.6, radius: Float = 0.002
            let perNeedleTris = around * (2 * (along - 1) + 2)
            var m = empty(vertices: needles * (around * (along + 1) + 2), triangles: needles * perNeedleTris + 12)
            // The bar, 1 m x 2 cm x 2 cm, its top at y = 0.
            let bo = SIMD3<Float>(-0.5, -0.02, -0.01)
            let bx = SIMD3<Float>(1, 0, 0), by = SIMD3<Float>(0, 0.02, 0), bz = SIMD3<Float>(0, 0, 0.02)
            appendFace(&m, origin: bo + bx, du: by, dv: bz, cols: 1, rows: 1)
            appendFace(&m, origin: bo, du: bz, dv: by, cols: 1, rows: 1)
            appendFace(&m, origin: bo + by, du: bz, dv: bx, cols: 1, rows: 1)
            appendFace(&m, origin: bo, du: bx, dv: bz, cols: 1, rows: 1)
            appendFace(&m, origin: bo + bz, du: bx, dv: by, cols: 1, rows: 1)
            appendFace(&m, origin: bo, du: by, dv: bx, cols: 1, rows: 1)
            // Cones from just inside the bar's top, so the base caps are hidden.
            let y0: Float = -0.005
            let slant = SIMD2<Float>(length, radius)  // (radial, up) of the side normal
            let slantN = slant / simd_length(slant)
            for n in 0..<needles {
                let cx = -0.5 + (Float(n) + 0.5) / Float(needles)
                let base = UInt32(m.positions.count)
                for j in 0..<around {
                    let th = 2 * Float.pi * Float(j) / Float(around)
                    let d = SIMD3<Float>(cos(th), 0, sin(th))
                    for k in 0..<along {
                        let t = Float(k) / Float(along)
                        m.positions.append(SIMD3(cx, y0 + t * length, 0) + d * (radius * (1 - t)))
                        m.normals.append(d * slantN.x + SIMD3(0, slantN.y, 0))
                        m.uvs.append(SIMD2(Float(j) / Float(around), t))
                    }
                }
                let apex = UInt32(m.positions.count)
                m.positions.append(SIMD3(cx, y0 + length, 0))
                m.normals.append([0, 1, 0])
                m.uvs.append(SIMD2(0.5, 1))
                let ring = UInt32(along)
                for j in 0..<UInt32(around) {
                    let j1 = (j + 1) % UInt32(around)
                    for k in 0..<ring - 1 {
                        let a = base + j * ring + k, b = a + 1
                        let c = base + j1 * ring + k, d = c + 1
                        m.indices += [a, b, c, b, d, c]
                    }
                    m.indices += [base + j * ring + ring - 1, apex, base + j1 * ring + ring - 1]
                }
                // The base cap, facing down.
                let center = UInt32(m.positions.count)
                m.positions.append(SIMD3(cx, y0, 0))
                m.normals.append([0, -1, 0])
                m.uvs.append(SIMD2(0.5, 0.5))
                let capBase = UInt32(m.positions.count)
                for j in 0..<around {
                    let th = 2 * Float.pi * Float(j) / Float(around)
                    let d = SIMD3<Float>(cos(th), 0, sin(th))
                    m.positions.append(SIMD3(cx, y0, 0) + d * radius)
                    m.normals.append([0, -1, 0])
                    m.uvs.append(SIMD2(0.5 + 0.5 * d.x, 0.5 + 0.5 * d.z))
                }
                for j in 0..<UInt32(around) {
                    m.indices += [center, capBase + j, capBase + (j + 1) % UInt32(around)]
                }
            }
            return m
        }
    }

    // MARK: Thin sheet

    private static func ripple(_ x: Float, _ z: Float) -> Float {
        0.03 * sin(2 * .pi * 3 * x) * cos(2 * .pi * 2 * z) + 0.01 * sin(2 * .pi * 7 * (x + z))
    }

    private static func rippleGradient(_ x: Float, _ z: Float) -> SIMD2<Float> {
        let k = 2 * Float.pi
        let dx = 0.03 * k * 3 * cos(k * 3 * x) * cos(k * 2 * z) + 0.01 * k * 7 * cos(k * 7 * (x + z))
        let dz = -0.03 * k * 2 * sin(k * 3 * x) * sin(k * 2 * z) + 0.01 * k * 7 * cos(k * 7 * (x + z))
        return SIMD2(dx, dz)
    }

    package static func thinSheet(segments: Int = 160, thickness: Float = 0.01) -> VGLabShape {
        VGLabShape(key: "vglab-thinsheet-s\(segments)-t\(thickness)-v1", name: "Thin sheet", watertight: true) {
            var m = empty(vertices: 2 * (segments + 1) * (segments + 1) + 8 * (segments + 1), triangles: 4 * segments * segments + 8 * segments)
            let half = 0.5 * thickness
            let n = segments
            // Every part computes a rim position the same way (x, z = i / n; y = ripple +- half), so the parts meet exactly.
            func at(_ x: Float, _ z: Float, _ off: Float) -> SIMD3<Float> { SIMD3(x, ripple(x, z) + off, z) }
            func slope(_ x: Float, _ z: Float, sign: Float) -> SIMD3<Float> {
                let g = rippleGradient(x, z)
                return sign * normalize(SIMD3(-g.x, 1, -g.y))
            }
            // Top (s along z, t along x: z x x = +y) and bottom.
            appendGrid(&m, cols: n, rows: n, flip: false) { s, t in
                let z = Float(s) / Float(n), x = Float(t) / Float(n)
                return (at(x, z, half), slope(x, z, sign: 1), SIMD2(x, z))
            }
            appendGrid(&m, cols: n, rows: n, flip: true) { s, t in
                let z = Float(s) / Float(n), x = Float(t) / Float(n)
                return (at(x, z, -half), slope(x, z, sign: -1), SIMD2(x, z))
            }
            // Sides: s along the rim, t from the bottom (-half) to the top (+half).
            func side(normal: SIMD3<Float>, flip: Bool, rim: @escaping (Float) -> (Float, Float)) {
                appendGrid(&m, cols: n, rows: 1, flip: flip) { s, t in
                    let (x, z) = rim(Float(s) / Float(n))
                    return (at(x, z, t == 0 ? -half : half), normal, SIMD2(Float(s) / Float(n), Float(t)))
                }
            }
            side(normal: [-1, 0, 0], flip: false) { (0, $0) }   // z x y = -x
            side(normal: [1, 0, 0], flip: true) { (1, $0) }     // z x y reversed
            side(normal: [0, 0, 1], flip: false) { ($0, 1) }    // x x y = +z
            side(normal: [0, 0, -1], flip: true) { ($0, 0) }
            return m
        }
    }

    // MARK: Displaced plane

    private static func hash(_ x: Int32, _ z: Int32) -> Float {
        var h = UInt32(bitPattern: x) &* 0x9E37_79B1 ^ UInt32(bitPattern: z) &* 0x85EB_CA6B
        h ^= h >> 15
        h = h &* 0x2C1B_3C6D
        h ^= h >> 12
        h = h &* 0x297A_2D39
        h ^= h >> 15
        return Float(h >> 8) / Float(1 << 24)
    }

    private static func valueNoise(_ x: Float, _ z: Float) -> Float {
        let fx = floor(x), fz = floor(z)
        let ix = Int32(fx), iz = Int32(fz)
        var u = x - fx, v = z - fz
        u = u * u * (3 - 2 * u)
        v = v * v * (3 - 2 * v)
        let a = hash(ix, iz), b = hash(ix + 1, iz), c = hash(ix, iz + 1), d = hash(ix + 1, iz + 1)
        return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v
    }

    package static func displacedPlane(size: Float = 64, resolution: Int = 512) -> VGLabShape {
        VGLabShape(
            key: "vglab-displacedplane-s\(size)-r\(resolution)-v1", name: "Displaced plane", watertight: false
        ) {
            let amplitude: Float = 3
            let n = resolution, w = n + 1
            let step = size / Float(n)
            var heights = [Float](repeating: 0, count: w * w)
            for iz in 0..<w {
                for ix in 0..<w {
                    let x = Float(ix) * step - size / 2, z = Float(iz) * step - size / 2
                    var h: Float = 0, freq: Float = 1 / 16, weight: Float = 0.6
                    for octave in 0..<3 {
                        h += weight * valueNoise(x * freq + Float(octave) * 17.3, z * freq - Float(octave) * 9.1)
                        freq *= 2.7
                        weight *= 0.5
                    }
                    heights[iz * w + ix] = amplitude * (h / 0.9 - 0.5) * 2
                }
            }
            var m = empty(vertices: w * w, triangles: 2 * n * n)
            // s along z, t along x: z x x = +y.
            appendGrid(&m, cols: n, rows: n, flip: false) { s, t in
                let ix = t, iz = s
                let hx = heights[iz * w + min(ix + 1, n)] - heights[iz * w + max(ix - 1, 0)]
                let hz = heights[min(iz + 1, n) * w + ix] - heights[max(iz - 1, 0) * w + ix]
                let sx = Float(min(ix + 1, n) - max(ix - 1, 0)) * step
                let sz = Float(min(iz + 1, n) - max(iz - 1, 0)) * step
                let normal = normalize(SIMD3(-hx / sx, 1, -hz / sz))
                let p = SIMD3(Float(ix) * step - size / 2, heights[iz * w + ix], Float(iz) * step - size / 2)
                return (p, normal, SIMD2(Float(ix) / Float(n), Float(iz) / Float(n)))
            }
            return m
        }
    }

    package static var all: [VGLabShape] {
        [icosphere(), torusKnot(), seamCube(), needleComb(), thinSheet(), displacedPlane()]
    }
}
