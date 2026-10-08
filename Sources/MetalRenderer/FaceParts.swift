import Foundation
import simd

/// The parts of a generated character's face that are meshes of their own, beside the skin (FaceSculpt): the
/// eyeballs, the teeth and the tongue; and which of a character's materials each part of its surface takes.
enum FaceParts {
    /// A generated character's materials, in the order its instance's run of materials has them (CharacterBuilder
    /// `materials`): each triangle names one by its offset from the first.
    enum Material: UInt8, CaseIterable {
        case skin, lips, brows, sclera, iris, pupil, teeth, mouth
    }

    /// A part's mesh in the character's bind space: one material per triangle.
    struct Mesh {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var materials: [Material] = []
    }

    // MARK: Eyes

    /// An eyeball at `centre` (looking along +z): a sphere with the cornea's dome standing out of it in front, in rings
    /// round its axis so that the pupil's and the iris's edges are circles. Its first vertex is the cornea's top, its
    /// last the back of the eye (CharacterFace finds the eye's centre from them).
    static func eyeball(centre: SIMD3<Float>, scale s: Float, rings: Int = 28, segments: Int = 36) -> Mesh {
        let r = FaceSculpt.eyeRadius * s, rise = FaceSculpt.corneaRise * s, limbus = FaceSculpt.limbus
        let pupil: Float = 9 * .pi / 180
        // The rings' angles from the front: through the pupil's and the iris's edges, denser over the cornea.
        var angles: [Float] = []
        for k in 1...3 { angles.append(pupil * Float(k) / 3) }
        for k in 1...5 { angles.append(pupil + (limbus - pupil) * Float(k) / 5) }
        let back = rings - angles.count
        for k in 1..<back { angles.append(limbus + (.pi - limbus) * Float(k) / Float(back)) }
        func radius(_ a: Float) -> Float {
            guard a < limbus else { return r }
            let t = a / limbus
            return r + rise * pow(1 - t * t, 1.5)
        }
        var m = Mesh()
        m.positions.append(centre + [0, 0, radius(0)])
        m.normals.append([0, 0, 1])
        for a in angles {
            let rr = radius(a)
            // The normal: the surface's, from its slope (d radius / d angle).
            let h: Float = 0.002
            let slope = (radius(min(a + h, .pi)) - radius(max(a - h, 0))) / (2 * h)
            for k in 0..<segments {
                let phi = Float(k) / Float(segments) * 2 * .pi
                let dir = SIMD3<Float>(sin(a) * cos(phi), sin(a) * sin(phi), cos(a))
                let tangent = SIMD3<Float>(cos(a) * cos(phi), cos(a) * sin(phi), -sin(a))
                m.positions.append(centre + dir * rr)
                m.normals.append(simd_normalize(dir * rr - tangent * slope))
            }
        }
        m.positions.append(centre - [0, 0, r])
        m.normals.append([0, 0, -1])
        let last = UInt32(m.positions.count - 1)
        func material(_ a: Float) -> Material { a <= pupil + 1e-4 ? .pupil : a <= limbus + 1e-4 ? .iris : .sclera }
        func ring(_ i: Int, _ k: Int) -> UInt32 { UInt32(1 + i * segments + (k % segments)) }
        for k in 0..<segments {   // (counter-clockwise seen from outside)
            m.indices += [0, ring(0, k), ring(0, k + 1)]
            m.materials.append(material(angles[0]))
        }
        for i in 0..<(angles.count - 1) {
            let kind = material(angles[i + 1])
            for k in 0..<segments {
                m.indices += [ring(i, k), ring(i + 1, k), ring(i + 1, k + 1), ring(i, k), ring(i + 1, k + 1), ring(i, k + 1)]
                m.materials += [kind, kind]
            }
        }
        for k in 0..<segments {
            m.indices += [ring(angles.count - 1, k), last, ring(angles.count - 1, k + 1)]
            m.materials.append(.sclera)
        }
        return m
    }

    // MARK: Mouth

    /// The dental arch: how far forward the teeth's front is at `x` from the middle (the sculpt's space).
    static func arch(_ x: Float) -> Float { 0.0875 - 17 * x * x - 26_000 * x * x * x * x }

    /// The upper or lower teeth, a row of crowns along the arch (incisors to molars), in the sculpt's space.
    static func teethField(_ q: SIMD3<Float>, upper: Bool) -> Float {
        let x = abs(q.x)
        guard x < 0.034 else { return x - 0.026 }
        // The lower row sits a little behind and below the upper (its edges just under the uppers').
        let front = arch(x) - (upper ? 0 : 0.0016)
        // Thicker toward the back (incisors 6 mm, molars 9).
        let thickness = 0.0058 + 0.0035 * FaceSculpt.smoothstep(0.008, 0.02, x)
        let slope = -34 * x - 104_000 * x * x * x
        let across = (q.z - (front - thickness / 2)) / (1 + slope * slope).squareRoot()
        // Each tooth's edge: a crown's middle a little lower than its sides.
        let widths: [Float] = [0.0043, 0.0034, 0.0038, 0.0036, 0.0035, 0.0052, 0.005]
        var start: Float = 0, k = 0
        while k < widths.count - 1 && x > start + widths[k] { start += widths[k]; k += 1 }
        let t = min(max((x - start) / widths[k], 0), 1)
        let scallop = 0.0005 * (1 - pow(2 * t - 1, 2))
        let height = (upper ? 0.0098 : 0.0088) - 0.0025 * FaceSculpt.smoothstep(0.012, 0.024, x)
        let edge = upper ? 1.6127 - scallop : 1.6137 + scallop
        let centreY = upper ? edge + height / 2 : edge - height / 2
        var d = FaceSculpt.smax(abs(across) - thickness / 2, abs(q.y - centreY) - height / 2, 0.0014)
        d = FaceSculpt.smax(d, x - 0.0262, 0.002)
        d = FaceSculpt.smax(d, 0.05 - q.z, 0.002)   // (the last molars' backs, deep in the mouth)
        // The gaps between the crowns, toward their edges (above they touch: the row is one piece).
        let gap = min(x - start, start + widths[k] - x)
        d = FaceSculpt.smax(d, -(gap - 0.0003 + max(abs(q.y - edge) - 0.0022, 0) * 1.5), 0.0005)
        return d
    }

    static func tongueField(_ q: SIMD3<Float>) -> Float {
        var d = FaceSculpt.ellipsoid(q - [0, 1.6068, 0.064], [0.0185, 0.0062, 0.021])
        // Flatter on top, toward the tip.
        d = FaceSculpt.smax(d, q.y - 1.6098 + 0.0012 * min(max((q.z - 0.064) / 0.02, 0), 1), 0.003)
        return d
    }

    /// A small closed mesh of `field` (in the sculpt's space) inside `box`, at `cell`, simplified to `triangles`, all
    /// of one material; in the character's space.
    static func meshed(_ sculpt: FaceSculpt, box: (lo: SIMD3<Float>, hi: SIMD3<Float>), cell: Float, triangles: Int,
                       material: Material, field: @escaping (SIMD3<Float>) -> Float) -> Mesh {
        let distance: (SIMD3<Float>) -> Float = { p in field(sculpt.local(p)) * sculpt.scale }
        let gradient: (SIMD3<Float>) -> SIMD3<Float> = { p in
            let h = cell * 0.25
            return SIMD3(distance(p + [h, 0, 0]) - distance(p - [h, 0, 0]), distance(p + [0, h, 0]) - distance(p - [0, h, 0]),
                         distance(p + [0, 0, h]) - distance(p - [0, 0, h])) / (2 * h)
        }
        let lo = sculpt.world(box.lo), hi = sculpt.world(box.hi), size = cell * sculpt.scale
        let counts = SIMD3<Int>(((hi - lo) / size).rounded(.up)) &+ 1
        var (positions, indices) = SurfaceNets.sparseMesh(lo: lo, size: size, counts: counts, distance: distance, gradient: gradient)
        (positions, indices) = CharacterBase.largestPart(positions, indices)
        (positions, indices) = CharacterBase.simplified(positions, indices, to: triangles)
        let normals = positions.map { p -> SIMD3<Float> in
            let g = gradient(p)
            return simd_length_squared(g) > 0 ? simd_normalize(g) : [0, 1, 0]
        }
        return Mesh(positions: positions, normals: normals, indices: indices,
                    materials: [Material](repeating: material, count: indices.count / 3))
    }

    static func teeth(_ sculpt: FaceSculpt, upper: Bool) -> Mesh {
        let box: (SIMD3<Float>, SIMD3<Float>) = upper ? ([-0.03, 1.606, 0.044], [0.03, 1.63, 0.096]) : ([-0.03, 1.598, 0.044], [0.03, 1.62, 0.094])
        return meshed(sculpt, box: box, cell: 0.0005, triangles: 2600, material: .teeth) { teethField($0, upper: upper) }
    }

    static func tongue(_ sculpt: FaceSculpt) -> Mesh {
        meshed(sculpt, box: ([-0.024, 1.598, 0.04], [0.024, 1.616, 0.09]), cell: 0.001, triangles: 900, material: .mouth, field: tongueField)
    }

    // MARK: The skin's materials

    /// The skin's material at a point of it (the sculpt's space): the lips' red, the brows, the inside of the mouth.
    static func skinMaterial(_ q: SIMD3<Float>) -> Material {
        guard q.y > 1.585, q.y < 1.73, q.z > 0.02 else { return .skin }
        // Inside the mouth: behind the lips' inner edge.
        var a = q
        a.z += 15 * a.x * a.x
        let line = FaceSculpt.mouth.y - 0.0012 * pow(abs(a.x) / FaceSculpt.mouthHalfWidth, 2)
        if abs(a.x) < 0.03 && abs(q.y - 1.613) < 0.013 && a.z < 0.0915 && a.z > 0.035 { return .mouth }
        // The lips' red: between the vermilion borders, a little narrower than the mouth at the corners.
        let x = abs(a.x) / (FaceSculpt.mouthHalfWidth + 0.0015)
        if x < 1 {
            let top = line + 0.0072 * (1 - pow(x, 2.2)) + 0.0009 * (1 - pow(min(abs(a.x) / 0.006, 1), 2))   // (the Cupid's bow)
            let bottom = line - 0.0088 * (1 - pow(x, 1.8))
            if q.y < top && q.y > bottom && a.z > 0.091 { return .lips }
        }
        // The brows: an arc over each eye, thick toward the nose, thinning to a tail.
        for e in FaceSculpt.eyeCentres where e.x * q.x > 0 {
            let x = abs(q.x) - abs(e.x)          // toward the side
            guard x > -0.0175, x < 0.0215, q.z > e.z - 0.004 else { continue }
            let t = (x + 0.0175) / 0.039
            let middle = e.y + 0.0185 + 0.0045 * sin(.pi * min(t * 1.15, 1)) - 0.003 * t
            let half = 0.0042 * (1 - 0.6 * t) + 0.0006
            if abs(q.y - middle) < half { return .brows }
        }
        return .skin
    }
}
