import Foundation
import simd

/// The shapes Add (Shift-A) makes, as Blender's are: their sizes, segment counts and UVs. Y is up (the engine's), so a
/// Blender "Z" axis is Y here.
package enum Primitive: String, CaseIterable, Codable, Identifiable {
    case plane, cube, circle, uvSphere, icoSphere, cylinder, cone, torus, grid, head
    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .plane: "Plane"
        case .cube: "Cube"
        case .circle: "Circle"
        case .uvSphere: "UV Sphere"
        case .icoSphere: "Ico Sphere"
        case .cylinder: "Cylinder"
        case .cone: "Cone"
        case .torus: "Torus"
        case .grid: "Grid"
        case .head: "Monkey Head"
        }
    }

    /// The shape at Blender's defaults.
    package func mesh() -> EditMesh {
        switch self {
        case .plane: Primitives.grid(x: 1, y: 1, size: 2)
        case .cube: Primitives.cube(size: 2)
        case .circle: Primitives.circle(vertices: 32, radius: 1, fill: false)
        case .uvSphere: Primitives.uvSphere(segments: 32, rings: 16, radius: 1)
        case .icoSphere: Primitives.icoSphere(subdivisions: 2, radius: 1)
        case .cylinder: Primitives.cylinder(vertices: 32, radius: 1, depth: 2)
        case .cone: Primitives.cone(vertices: 32, radius1: 1, radius2: 0, depth: 2)
        case .torus: Primitives.torus(major: 48, minor: 12, majorRadius: 1, minorRadius: 0.25)
        case .grid: Primitives.grid(x: 10, y: 10, size: 2)
        case .head: Primitives.head()
        }
    }
}

package enum Primitives {
    /// A cube of side `size`, its faces unwrapped as Blender's are (a cross).
    package static func cube(size: Float) -> EditMesh {
        let h = size / 2
        var p: [SIMD3<Float>] = []
        for i in 0..<8 { p.append(SIMD3(i & 1 == 0 ? -h : h, i & 2 == 0 ? -h : h, i & 4 == 0 ? -h : h)) }
        // Faces counter-clockwise from outside; x: bit 0, y: bit 1, z: bit 2.
        let faces: [[Int32]] = [
            [1, 3, 7, 5], [0, 4, 6, 2],   // +x, -x
            [2, 6, 7, 3], [0, 1, 5, 4],   // +y, -y
            [4, 5, 7, 6], [0, 2, 3, 1],   // +z, -z
        ]
        // The cross: cells of a 4×3 grid of quarter-by-third squares.
        let cells: [SIMD2<Float>] = [[2, 1], [0, 1], [1, 2], [1, 0], [1, 1], [3, 1]]
        let uvs: [[SIMD2<Float>]] = cells.map { cell in
            let o = SIMD2<Float>(cell.x * 0.25, cell.y / 3), s = SIMD2<Float>(0.25, 1 / Float(3))
            return [o, o + SIMD2(s.x, 0), o + s, o + SIMD2(0, s.y)]
        }
        return EditMesh(positions: p, faces: faces, uvs: uvs)
    }

    /// A grid of `x` by `y` quads over a square of side `size` on the ground (XZ), facing up.
    package static func grid(x: Int, y: Int, size: Float) -> EditMesh {
        var p: [SIMD3<Float>] = []
        for j in 0...y {
            for i in 0...x {
                p.append(SIMD3((Float(i) / Float(x) - 0.5) * size, 0, (0.5 - Float(j) / Float(y)) * size))
            }
        }
        var faces: [[Int32]] = [], uvs: [[SIMD2<Float>]] = []
        let w = Int32(x + 1)
        for j in 0..<Int32(y) {
            for i in 0..<Int32(x) {
                let a = j * w + i
                faces.append([a, a + 1, a + 1 + w, a + w])
                let u0 = Float(i) / Float(x), u1 = Float(i + 1) / Float(x), v0 = Float(j) / Float(y), v1 = Float(j + 1) / Float(y)
                uvs.append([[u0, v0], [u1, v0], [u1, v1], [u0, v1]])
            }
        }
        return EditMesh(positions: p, faces: faces, uvs: uvs)
    }

    /// A ring of vertices on the ground: loose edges, or one n-gon if `fill`.
    package static func circle(vertices n: Int, radius: Float, fill: Bool) -> EditMesh {
        var d = EditMesh.Draft()
        for i in 0..<n {
            let a = 2 * Float.pi * Float(i) / Float(n)
            d.addVertex(SIMD3(radius * sin(a), 0, radius * cos(a)))
        }
        if fill {
            d.addFace((0..<Int32(n)).map { $0 }, uvs: (0..<n).map { i in
                let a = 2 * Float.pi * Float(i) / Float(n)
                return SIMD2(0.5 + 0.5 * sin(a), 0.5 + 0.5 * cos(a))
            })
        } else {
            for i in 0..<Int32(n) { d.looseEdges.append(SIMD2(i, (i + 1) % Int32(n))) }
        }
        return EditMesh(d)
    }

    /// A UV sphere: `segments` round, `rings` from pole to pole, triangles at the poles.
    package static func uvSphere(segments: Int, rings: Int, radius: Float) -> EditMesh {
        var d = EditMesh.Draft()
        let top = d.addVertex(SIMD3(0, radius, 0))
        for r in 1..<rings {
            let theta = Float.pi * Float(r) / Float(rings)
            for s in 0..<segments {
                let phi = 2 * Float.pi * Float(s) / Float(segments)
                d.addVertex(radius * SIMD3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi)))
            }
        }
        let bottom = d.addVertex(SIMD3(0, -radius, 0))
        func v(_ r: Int, _ s: Int) -> Int32 { Int32(1 + (r - 1) * segments + (s % segments)) }
        func uv(_ r: Int, _ s: Int) -> SIMD2<Float> { SIMD2(Float(s) / Float(segments), 1 - Float(r) / Float(rings)) }
        for s in 0..<segments {
            d.addFace([top, v(1, s), v(1, s + 1)], uvs: [SIMD2((Float(s) + 0.5) / Float(segments), 1), uv(1, s), uv(1, s + 1)],
                      flags: EditMesh.Flag.smooth)
        }
        for r in 1..<(rings - 1) {
            for s in 0..<segments {
                d.addFace([v(r, s), v(r + 1, s), v(r + 1, s + 1), v(r, s + 1)],
                          uvs: [uv(r, s), uv(r + 1, s), uv(r + 1, s + 1), uv(r, s + 1)], flags: EditMesh.Flag.smooth)
            }
        }
        for s in 0..<segments {
            d.addFace([v(rings - 1, s), bottom, v(rings - 1, s + 1)],
                      uvs: [uv(rings - 1, s), SIMD2((Float(s) + 0.5) / Float(segments), 0), uv(rings - 1, s + 1)], flags: EditMesh.Flag.smooth)
        }
        return EditMesh(d)
    }

    /// An icosahedron split `subdivisions` times, on the sphere.
    package static func icoSphere(subdivisions: Int, radius: Float) -> EditMesh {
        let t: Float = (1 + Float(5).squareRoot()) / 2
        var verts: [SIMD3<Float>] = [
            [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t],
            [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1],
        ].map { simd_normalize($0) }
        var tris: [SIMD3<Int32>] = [
            [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
            [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
        ]
        for _ in 0..<max(0, subdivisions - 1) {
            var mid: [UInt64: Int32] = [:]
            func m(_ a: Int32, _ b: Int32) -> Int32 {
                let k = EditMesh.key(a, b)
                if let i = mid[k] { return i }
                verts.append(simd_normalize(verts[Int(a)] + verts[Int(b)]))
                mid[k] = Int32(verts.count - 1)
                return Int32(verts.count - 1)
            }
            var next: [SIMD3<Int32>] = []
            for tri in tris {
                let ab = m(tri.x, tri.y), bc = m(tri.y, tri.z), ca = m(tri.z, tri.x)
                next += [[tri.x, ab, ca], [tri.y, bc, ab], [tri.z, ca, bc], [ab, bc, ca]]
            }
            tris = next
        }
        // Triangles are listed clockwise from outside in this table (y up): turn them.
        let faces = tris.map { [$0.x, $0.z, $0.y] }
        let uvs = faces.map { f in f.map { i -> SIMD2<Float> in
            let p = verts[Int(i)]
            return SIMD2(0.5 + atan2(p.x, p.z) / (2 * .pi), 0.5 + asin(max(-1, min(1, p.y))) / .pi)
        } }
        var mesh = EditMesh(positions: verts.map { $0 * radius }, faces: faces, uvs: uvs, smooth: false)
        mesh.fixWinding()
        return mesh
    }

    /// A cylinder along Y with n-gon caps.
    package static func cylinder(vertices n: Int, radius: Float, depth: Float) -> EditMesh {
        cone(vertices: n, radius1: radius, radius2: radius, depth: depth)
    }

    /// A cone (`radius2` 0) or a frustum along Y with n-gon caps.
    package static func cone(vertices n: Int, radius1: Float, radius2: Float, depth: Float) -> EditMesh {
        var d = EditMesh.Draft()
        let h = depth / 2
        for i in 0..<n {
            let a = 2 * Float.pi * Float(i) / Float(n)
            d.addVertex(SIMD3(radius1 * sin(a), -h, radius1 * cos(a)))
        }
        let pointed = radius2 == 0
        if pointed { d.addVertex(SIMD3(0, h, 0)) } else {
            for i in 0..<n {
                let a = 2 * Float.pi * Float(i) / Float(n)
                d.addVertex(SIMD3(radius2 * sin(a), h, radius2 * cos(a)))
            }
        }
        let N = Int32(n)
        for i in 0..<N {
            let j = (i + 1) % N
            let u0 = Float(i) / Float(n), u1 = Float(i + 1) / Float(n)
            if pointed {
                d.addFace([i, j, N], uvs: [[u0 * 0.5, 0.5], [u1 * 0.5, 0.5], [(u0 + u1) * 0.25, 1]])
            } else {
                d.addFace([i, j, N + j, N + i], uvs: [[u0 * 0.5, 0.5], [u1 * 0.5, 0.5], [u1 * 0.5, 1], [u0 * 0.5, 1]])
            }
        }
        func capUV(_ i: Int32, _ cx: Float) -> SIMD2<Float> {
            let a = 2 * Float.pi * Float(i) / Float(n)
            return SIMD2(cx + 0.24 * sin(a), 0.25 + 0.24 * cos(a))
        }
        let bottom = (0..<N).reversed().map { $0 }
        d.addFace(bottom, uvs: bottom.map { capUV($0, 0.25) })
        if !pointed {
            let top = (0..<N).map { N + $0 }
            d.addFace(top, uvs: (0..<N).map { capUV($0, 0.75) })
        }
        return EditMesh(d)
    }

    /// A torus round Y: `major` segments round the ring, `minor` round its tube.
    package static func torus(major: Int, minor: Int, majorRadius: Float, minorRadius: Float) -> EditMesh {
        var d = EditMesh.Draft()
        for i in 0..<major {
            let a = 2 * Float.pi * Float(i) / Float(major)
            let dir = SIMD3<Float>(sin(a), 0, cos(a))
            for j in 0..<minor {
                let b = 2 * Float.pi * Float(j) / Float(minor)
                d.addVertex(dir * (majorRadius + minorRadius * cos(b)) + SIMD3(0, minorRadius * sin(b), 0))
            }
        }
        func v(_ i: Int, _ j: Int) -> Int32 { Int32((i % major) * minor + (j % minor)) }
        for i in 0..<major {
            for j in 0..<minor {
                let u0 = Float(i) / Float(major), u1 = Float(i + 1) / Float(major)
                let w0 = Float(j) / Float(minor), w1 = Float(j + 1) / Float(minor)
                d.addFace([v(i, j), v(i + 1, j), v(i + 1, j + 1), v(i, j + 1)],
                          uvs: [[u0, w0], [u1, w0], [u1, w1], [u0, w1]], flags: EditMesh.Flag.smooth)
            }
        }
        return EditMesh(d)
    }

    /// A monkey-like head for trying things on, made here (no file): a quad sphere of 6 × 8 × 8 faces shaped into a
    /// head (a longer skull, a muzzle, brows over two sockets, ears), with Suzanne's 500-odd faces' scale.
    package static func head() -> EditMesh {
        let n = 8
        var mesh = quadSphere(n: n, radius: 1)
        for v in 0..<mesh.vertexCount {
            let p = simd_normalize(mesh.positions[v])
            var q = p
            q.y *= 0.92
            q.z *= 0.88
            // Muzzle: forward and down, wide.
            let muzzle = exp(-(pow(p.x / 0.55, 2) + pow((p.y + 0.35) / 0.35, 2))) * max(0, p.z)
            q.z += 0.38 * muzzle
            q.y -= 0.08 * muzzle
            // Brow ridge over the eyes, the sockets under it.
            for side in [Float(-1), 1] {
                let dx = p.x - side * 0.38
                let socket = exp(-(pow(dx / 0.2, 2) + pow((p.y - 0.12) / 0.18, 2))) * max(0, p.z)
                q -= p * 0.16 * socket
                let brow = exp(-(pow(dx / 0.3, 2) + pow((p.y - 0.36) / 0.1, 2))) * max(0, p.z)
                q += SIMD3(0, 0.04, 0.12) * brow
                // Ears: out sideways, flat.
                let ear = exp(-(pow((p.y - 0.15) / 0.28, 2) + pow((p.z + 0.05) / 0.3, 2))) * max(0, side * p.x)
                q.x += side * 0.55 * pow(ear, 3)
                q.z -= 0.15 * pow(ear, 3)
            }
            mesh.positions[v] = q
        }
        for f in 0..<mesh.faceCount { mesh.faceFlags[f] |= EditMesh.Flag.smooth }
        mesh.touch()
        return mesh
    }

    /// A cube's faces split `n` by `n`, put on a sphere: quads all over, no poles.
    package static func quadSphere(n: Int, radius: Float) -> EditMesh {
        var d = EditMesh.Draft()
        var index: [SIMD3<Int32>: Int32] = [:]
        func vertex(_ q: SIMD3<Int32>) -> Int32 {
            if let i = index[q] { return i }
            let p = SIMD3<Float>(q) / Float(n) * 2 - 1
            let i = d.addVertex(simd_normalize(p) * radius)
            index[q] = i
            return i
        }
        // Each face of the cube as (origin, u, v) on the integer lattice 0...n.
        let N = Int32(n)
        let sides: [(o: SIMD3<Int32>, u: SIMD3<Int32>, v: SIMD3<Int32>)] = [
            ([N, 0, 0], [0, 1, 0], [0, 0, 1]), ([0, 0, 0], [0, 0, 1], [0, 1, 0]),
            ([0, N, 0], [0, 0, 1], [1, 0, 0]), ([0, 0, 0], [1, 0, 0], [0, 0, 1]),
            ([0, 0, N], [1, 0, 0], [0, 1, 0]), ([0, 0, 0], [0, 1, 0], [1, 0, 0]),
        ]
        for (k, s) in sides.enumerated() {
            for j in 0..<N {
                for i in 0..<N {
                    let a = vertex(s.o &+ s.u &* i &+ s.v &* j), b = vertex(s.o &+ s.u &* (i + 1) &+ s.v &* j)
                    let c = vertex(s.o &+ s.u &* (i + 1) &+ s.v &* (j + 1)), e = vertex(s.o &+ s.u &* i &+ s.v &* (j + 1))
                    let cu = Float(k % 3) / 3, cv = Float(k / 3) / 2
                    let uv0 = SIMD2<Float>(cu + Float(i) / Float(n) / 3, cv + Float(j) / Float(n) / 2)
                    let du = 1 / Float(n) / 3, dv = 1 / Float(n) / 2
                    d.addFace([a, b, c, e], uvs: [uv0, uv0 + SIMD2(du, 0), uv0 + SIMD2(du, dv), uv0 + SIMD2(0, dv)])
                }
            }
        }
        var mesh = EditMesh(d)
        mesh.fixWinding()
        return mesh
    }
}

extension EditMesh {
    /// Faces turned to face away from the mesh's middle where they face into it (for shapes that are star-shaped
    /// round it: what the primitives are; Recalculate Outside is the general one).
    mutating func fixWinding() {
        let c = (bounds.lo + bounds.hi) / 2
        var d = draft()
        var flipped = false
        for f in 0..<faceCount where simd_dot(faceNormal(f), faceCenter(f) - c) < 0 {
            let r = Int(d.faceStart[f])..<Int(d.faceStart[f + 1])
            d.cornerVerts[r].reverse()
            d.cornerUVs[r].reverse()
            flipped = true
        }
        if flipped { self = EditMesh(d) }
    }
}
