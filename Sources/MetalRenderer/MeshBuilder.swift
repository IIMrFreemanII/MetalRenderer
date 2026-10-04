import Foundation
import simd

/// Collects the triangles of one generated mesh (a building's walls, its glass, a block's sidewalk): flat-shaded
/// quads, boxes and prisms, smooth cylinders and cones. What is added is placed by `frame`, a rigid transform (a
/// facade's: x along the wall, y up, z out of it), and every face gets texture coordinates in metres x `uvScale`,
/// u along the face's horizontal direction and v down it, so a tiled texture keeps its real size and its courses
/// stay level on every wall. No face is left without them: a triangle of zero UV area can't take a normal map.
struct MeshBuilder {
    private(set) var positions: [SIMD3<Float>] = []
    private(set) var normals: [SIMD3<Float>] = []
    private(set) var uvs: [SIMD2<Float>] = []
    private(set) var indices: [UInt32] = []

    /// Texture repeats per metre.
    var uvScale: Float = 1
    /// Where the next shapes go: a rotation and a translation (no scale: normals are transformed as directions).
    var frame = matrix_identity_float4x4

    init(uvScale: Float = 1) { self.uvScale = uvScale }

    var triangleCount: Int { indices.count / 3 }
    var isEmpty: Bool { indices.isEmpty }
    var geometry: MeshGeometry { (positions, normals, indices) }

    /// The faces of a box: `.all` but the ones that would be hidden or coplanar with something else.
    struct Faces: OptionSet {
        let rawValue: Int
        static let left = Faces(rawValue: 1), right = Faces(rawValue: 2)        // -x, +x
        static let bottom = Faces(rawValue: 4), top = Faces(rawValue: 8)        // -y, +y
        static let back = Faces(rawValue: 16), front = Faces(rawValue: 32)      // -z, +z
        static let all: Faces = [.left, .right, .bottom, .top, .back, .front]
        static let sides: Faces = [.left, .right, .back, .front]
    }

    // MARK: Flat faces

    /// A quad through four corners in order around it, facing cross(b - a, d - a).
    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
        let n = cross(b - a, d - a)
        guard length_squared(n) > 1e-12 else { return }
        polygon([a, b, c, d], normal: normalize(n))
    }

    mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
        let n = cross(b - a, c - a)
        guard length_squared(n) > 1e-12 else { return }
        polygon([a, b, c], normal: normalize(n))
    }

    /// A convex polygon as a fan, flat-shaded with `normal`.
    mutating func polygon(_ corners: [SIMD3<Float>], normal n: SIMD3<Float>) {
        // The face's own axes: horizontal if it has a horizontal direction, then down the face.
        let h = cross(SIMD3<Float>(0, 1, 0), n)
        let t = length_squared(h) > 1e-6 ? normalize(h) : SIMD3<Float>(1, 0, 0)
        let b = cross(n, t)
        let base = UInt32(positions.count)
        let worldNormal = direction(n)
        for p in corners {
            positions.append(point(p))
            normals.append(worldNormal)
            uvs.append(SIMD2(dot(p, t), -dot(p, b)) * uvScale)
        }
        for i in 1..<UInt32(corners.count - 1) { indices += [base, base + i, base + i + 1] }
    }

    /// An axis-aligned box (in the frame) from its min and max corners.
    mutating func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, faces: Faces = .all) {
        guard hi.x > lo.x, hi.y > lo.y, hi.z > lo.z else { return }
        let (a, b) = (lo, hi)
        if faces.contains(.left) { quad([a.x, a.y, a.z], [a.x, a.y, b.z], [a.x, b.y, b.z], [a.x, b.y, a.z]) }
        if faces.contains(.right) { quad([b.x, a.y, b.z], [b.x, a.y, a.z], [b.x, b.y, a.z], [b.x, b.y, b.z]) }
        if faces.contains(.bottom) { quad([a.x, a.y, a.z], [b.x, a.y, a.z], [b.x, a.y, b.z], [a.x, a.y, b.z]) }
        if faces.contains(.top) { quad([a.x, b.y, b.z], [b.x, b.y, b.z], [b.x, b.y, a.z], [a.x, b.y, a.z]) }
        if faces.contains(.back) { quad([b.x, a.y, a.z], [a.x, a.y, a.z], [a.x, b.y, a.z], [b.x, b.y, a.z]) }
        if faces.contains(.front) { quad([a.x, a.y, b.z], [b.x, a.y, b.z], [b.x, b.y, b.z], [a.x, b.y, b.z]) }
    }

    /// A rectangle in the plane z = `z` of the frame, facing +z: a piece of a facade's wall.
    mutating func wall(x0: Float, x1: Float, y0: Float, y1: Float, z: Float = 0) {
        guard x1 > x0, y1 > y0 else { return }
        quad([x0, y0, z], [x1, y0, z], [x1, y1, z], [x0, y1, z])
    }

    /// A horizontal rectangle at height `y`, facing up (or down).
    mutating func floor(x0: Float, x1: Float, z0: Float, z1: Float, y: Float, up: Bool = true) {
        guard x1 > x0, z1 > z0 else { return }
        if up { quad([x0, y, z1], [x1, y, z1], [x1, y, z0], [x0, y, z0]) }
        else { quad([x0, y, z0], [x1, y, z0], [x1, y, z1], [x0, y, z1]) }
    }

    /// The side walls of a prism over `loop` (x, z corners, counter-clockwise seen from above) from `y0` to `y1`,
    /// facing outwards.
    mutating func prism(_ loop: [SIMD2<Float>], y0: Float, y1: Float) {
        for i in loop.indices {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            quad([a.x, y0, a.y], [b.x, y0, b.y], [b.x, y1, b.y], [a.x, y1, a.y])
        }
    }

    // MARK: Round shapes (smooth normals)

    /// A cylinder, or with two radii a cone's frustum, around the vertical through `center` (its bottom), `segments`
    /// sides; `cap`: closed at the top.
    mutating func cylinder(_ center: SIMD3<Float>, radius: Float, topRadius: Float? = nil, height: Float, segments: Int = 12,
                           cap: Bool = true) {
        let r1 = topRadius ?? radius
        let base = UInt32(positions.count)
        let slope = (radius - r1) / height
        for s in 0...segments {
            let phi = 2 * Float.pi * Float(s) / Float(segments)
            let d = SIMD3<Float>(cos(phi), 0, sin(phi))
            let n = direction(normalize(d + [0, slope, 0]))
            for (r, y) in [(radius, Float(0)), (r1, height)] {
                positions.append(point(center + d * r + [0, y, 0]))
                normals.append(n)
                uvs.append(SIMD2(phi * max(radius, r1), -(center.y + y)) * uvScale)
            }
        }
        for s in 0..<UInt32(segments) {
            let a = base + 2 * s
            indices += [a, a + 1, a + 2, a + 2, a + 1, a + 3]
        }
        if cap && r1 > 0 {
            let top = (0..<segments).map { s -> SIMD3<Float> in
                let phi = -2 * Float.pi * Float(s) / Float(segments)
                return center + SIMD3(cos(phi) * r1, height, sin(phi) * r1)
            }
            polygon(top, normal: [0, 1, 0])
        }
    }

    /// A ball of `radius` around `center`: an icosphere (the trees' crowns).
    mutating func ball(_ center: SIMD3<Float>, radius: SIMD3<Float>, subdivisions: Int = 1) {
        let sphere = Scene.icosphere(subdivisions: subdivisions)
        let base = UInt32(positions.count)
        for p in sphere.positions {
            positions.append(point(center + p * radius))
            normals.append(direction(normalize(p / radius)))
            uvs.append(SIMD2(atan2(p.z, p.x) * radius.x, -p.y * radius.y) * uvScale)
        }
        indices += sphere.indices.map { $0 + base }
    }

    // MARK: Putting meshes together

    /// Adds `other`'s triangles as they are (its frame was applied when they were made).
    mutating func append(_ other: MeshBuilder) {
        let base = UInt32(positions.count)
        positions += other.positions
        normals += other.normals
        uvs += other.uvs
        indices += other.indices.map { $0 + base }
    }

    /// The same, moved by `transform` (rigid).
    mutating func append(_ other: MeshBuilder, transform: float4x4) {
        let base = UInt32(positions.count)
        for i in other.positions.indices {
            let p = transform * SIMD4(other.positions[i], 1), n = transform * SIMD4(other.normals[i], 0)
            positions.append(SIMD3(p.x, p.y, p.z))
            normals.append(SIMD3(n.x, n.y, n.z))
        }
        uvs += other.uvs
        indices += other.indices.map { $0 + base }
    }

    mutating func reserve(triangles: Int) {
        positions.reserveCapacity(triangles * 2)
        normals.reserveCapacity(triangles * 2)
        uvs.reserveCapacity(triangles * 2)
        indices.reserveCapacity(triangles * 3)
    }

    /// The mesh's bounds (empty: lo > hi).
    var bounds: (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        (positions.reduce(SIMD3(repeating: .infinity), simd_min), positions.reduce(SIMD3(repeating: -.infinity), simd_max))
    }

    private func point(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let q = frame * SIMD4(p, 1)
        return SIMD3(q.x, q.y, q.z)
    }
    private func direction(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let q = frame * SIMD4(d, 0)
        return SIMD3(q.x, q.y, q.z)
    }
}
