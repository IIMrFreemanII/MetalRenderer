import Foundation
import simd

/// The head of every generated character (CharacterBase), sculpted as a distance field: a skull and a face of smooth
/// primitives at a man's average proportions (cranium, face, jaw, neck), then the features on them: brow ridge, cheek
/// bones, eye sockets with eyelids round the eyeballs and their openings cut, a nose with nostrils, lips with the mouth
/// cut between them into a mouth, ears. The eyeballs, teeth and tongue are meshes of their own (`eyeball`, `teeth`,
/// `tongue`), the eyes turned and the lids closed by rotations (CharacterFace).
///
/// Numbers are in the Y Bot's space (its head joint at 1.6 m): `local` takes a point of the character's to it, so the
/// same sculpt fits any Mixamo rig's head.
struct FaceSculpt {
    /// The Y Bot's head joint and how far its head's top joint is from it: the space the numbers below are in.
    static let reference = SIMD3<Float>(0, 1.6008, -0.0034)
    static let referenceHeight: Float = 0.19627
    static let eyeRadius: Float = 0.012
    /// How far the cornea stands out of the eyeball's sphere, and the angle (from the eye's axis) where it meets it.
    static let corneaRise: Float = 0.0025
    static let limbus: Float = 31 * .pi / 180
    /// Between the eyeball and the lid's inside, and the lids' thickness.
    static let eyeGap: Float = 0.0006
    static let lidThickness: Float = 0.003

    let origin: SIMD3<Float>
    let scale: Float

    init(origin: SIMD3<Float> = FaceSculpt.reference, scale: Float = 1) {
        self.origin = origin
        self.scale = scale
    }

    init?(_ c: SkinnedCharacter) {
        let bind = CharacterBase.bindPositions(c)
        guard let head = CharacterBase.joint("Head", in: c), let top = CharacterBase.joint("HeadTop_End", in: c) else { return nil }
        origin = bind[head]
        scale = simd_length(bind[top] - bind[head]) / FaceSculpt.referenceHeight
    }

    /// A point of the character's in the sculpt's space, and back.
    @inline(__always) func local(_ p: SIMD3<Float>) -> SIMD3<Float> { (p - origin) / scale + FaceSculpt.reference }
    @inline(__always) func world(_ q: SIMD3<Float>) -> SIMD3<Float> { (q - FaceSculpt.reference) * scale + origin }

    // MARK: Landmarks (the Y Bot's space)

    /// The eyes' centres, the left (+x) first.
    static let eyeCentres: [SIMD3<Float>] = [[0.032, 1.680, 0.073], [-0.032, 1.680, 0.073]]
    /// The mouth's line (stomion) and its corners' half width.
    static let mouth = SIMD3<Float>(0, 1.6145, 0.099)
    static let mouthHalfWidth: Float = 0.0245
    /// The jaw's hinge (in front of the ears), about which it opens.
    static let jawHinge = SIMD3<Float>(0, 1.662, 0.004)
    static let chin = SIMD3<Float>(0, 1.582, 0.1)
    static let noseTip = SIMD3<Float>(0, 1.650, 0.125)
    static let nasion = SIMD3<Float>(0, 1.692, 0.09)
    static let brows: [SIMD3<Float>] = [[0.034, 1.702, 0.087], [-0.034, 1.702, 0.087]]
    static let ears: [SIMD3<Float>] = [[0.0775, 1.671, -0.017], [-0.0775, 1.671, -0.017]]

    var eyes: [SIMD3<Float>] { FaceSculpt.eyeCentres.map(world) }

    // MARK: The field

    /// The head and neck: negative inside.
    func distance(_ p: SIMD3<Float>) -> Float { FaceSculpt.field(local(p)) * scale }

    /// How much of the body's field at `p` is the head's: 0 below the neck's middle, 1 above it.
    func headness(_ p: SIMD3<Float>) -> Float {
        let y = local(p).y
        let t = min(max((y - 1.505) / 0.04, 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func field(_ q: SIMD3<Float>) -> Float {
        // The cranium: wider behind than at the temples, broad on top (squarer than an ellipse seen from the front).
        var c = q - SIMD3(0, 1.716, -0.008)
        c.x /= 1 - 0.1 * min(max(c.z / 0.09, 0), 1)
        let r = SIMD3<Float>(0.077, 0.089, 0.097)
        let across = pow(pow(abs(c.x) / r.x, 2.35) + pow(abs(c.y) / r.y, 2.35), 1 / 2.35)
        var d = ((across * across + (c.z / r.z) * (c.z / r.z)).squareRoot() - 1) * r.min()
        // The face: flat across the eyes and cheeks, rounding back at the sides, narrower toward the jaw.
        var f = q - SIMD3(0, 1.655, 0.028)
        f.x /= 0.78 + 0.22 * smoothstep(-0.07, 0.01, f.y)
        d = smin(d, superellipsoid(f, [0.062, 0.074, 0.066], 2.4), 0.045)
        // The muzzle: teeth and gums under the lips.
        d = smin(d, ellipsoid(q - [0, 1.618, 0.07], [0.033, 0.03, 0.027]), 0.02)
        // The jaw: from each angle to the chin.
        let chinCentre = SIMD3<Float>(0, 1.585, 0.085)
        var jaw = ellipsoid(q - chinCentre, [0.0175, 0.0145, 0.015])
        for s: Float in [-1, 1] {
            jaw = smin(jaw, roundCone(q, [s * 0.052, 1.606, 0.0], [s * 0.013, 1.58, 0.083], 0.011, 0.012), 0.014)
            // Its rising branch, up to the hinge in front of the ear.
            jaw = smin(jaw, roundCone(q, [s * 0.054, 1.655, -0.004], [s * 0.052, 1.606, 0.0], 0.009, 0.011), 0.01)
        }
        d = smin(d, jaw, 0.026)
        // The cheeks' fat, under the cheek bones.
        for s: Float in [-1, 1] { d = smin(d, ellipsoid(q - [s * 0.04, 1.633, 0.058], [0.02, 0.024, 0.02]), 0.02) }
        // The neck, into the skull's base and under the jaw.
        d = smin(d, roundCone(q, [0, 1.49, -0.022], [0, 1.632, -0.036], 0.056, 0.046), 0.014)

        // Brow ridge and cheek bones.
        var brow = Float.infinity
        for s: Float in [-1, 1] {
            brow = min(brow, roundCone(q, [0, 1.703, 0.088], [s * 0.05, 1.699, 0.064], 0.0085, 0.0075))
            d = smin(d, ellipsoid(q - [s * 0.054, 1.668, 0.056], [0.014, 0.01, 0.016]), 0.022)
        }
        d = smin(d, brow, 0.012)

        // The eyes: a socket under the brow, the lids round each eyeball (a shell of it), their opening cut, the
        // eyeball's room inside.
        for s: Float in [-1, 1] {
            let e = SIMD3(s * eyeCentres[0].x, eyeCentres[0].y, eyeCentres[0].z)
            d = smax(d, -ellipsoid(q - (e + [s * 0.001, 0.002, 0.014]), [0.018, 0.013, 0.011]), 0.01)
            // (Not below the lower lid: no bag under the eye.)
            let lids = smax(sphere(q - e, eyeRadius + eyeGap + lidThickness), e.y - 0.0085 - q.y, 0.004)
            d = smin(d, lids, 0.006)
        }
        for s: Float in [-1, 1] {
            let e = SIMD3(s * eyeCentres[0].x, eyeCentres[0].y, eyeCentres[0].z)
            d = smax(d, -eyeOpening(q - e, side: s), 0.0012)
            d = max(d, -(simd_length(q - e) - (eyeRadius + eyeGap)))
        }

        // The nose: a bridge from the dip under the brow, a tip, wings into the cheeks, nostrils under.
        var nose = roundCone(q, [0, 1.688, 0.085], [0, 1.657, 0.109], 0.0062, 0.0078)
        nose = smin(nose, sphere(q - [0, 1.651, 0.1135], 0.0088), 0.007)
        for s: Float in [-1, 1] {
            nose = smin(nose, sphere(q - [s * 0.0042, 1.6505, 0.1135], 0.008), 0.004)
        }
        nose = smin(nose, roundCone(q, [0, 1.646, 0.113], [0, 1.6385, 0.1005], 0.0045, 0.004), 0.004)
        d = smin(d, nose, 0.007)
        for s: Float in [-1, 1] {
            d = smin(d, ellipsoid(q - [s * 0.0146, 1.6415, 0.098], [0.0064, 0.0058, 0.0082]), 0.012)
        }
        for s: Float in [-1, 1] {
            d = smax(d, -ellipsoid(q - [s * 0.0071, 1.6402, 0.1005], [0.0028, 0.0042, 0.0045]), 0.0012)
        }

        // The lips, along the teeth's arch (curving back toward the corners), then the mouth cut between them and the
        // mouth behind.
        var a = q
        a.z += 15 * a.x * a.x
        var lips = ellipsoid(a - [0, 1.6205, 0.1012], [0.0245, 0.0066, 0.0072])
        lips = smin(lips, ellipsoid(a - [0, 1.6178, 0.1012], [0.0045, 0.003, 0.0036]), 0.003)   // the tubercle
        lips = smin(lips, ellipsoid(a - [0, 1.6088, 0.0987], [0.0215, 0.007, 0.0074]), 0.003)
        d = smin(d, lips, 0.005)
        d = smax(d, -mouthCut(a), 0.001)
        d = smax(d, -ellipsoid(q - [0, 1.613, 0.064], [0.028, 0.0105, 0.022]), 0.003)

        // The ears.
        for s: Float in [-1, 1] { d = smin(d, ear(q, side: s), 0.004) }
        return d
    }

    /// The lids' opening: an almond in front of the eye (its centre at the origin), seen along the eye's axis, from
    /// its centre's plane forward.
    static func eyeOpening(_ e: SIMD3<Float>, side s: Float) -> Float {
        let x = e.x * s                   // toward the side of the head
        let inner: SIMD2<Float> = [-0.0135, -0.0006], outer: SIMD2<Float> = [0.0145, 0.0014]
        let t = (x - inner.x) / (outer.x - inner.x)
        let line = inner.y + (outer.y - inner.y) * t
        let tc = min(max(t, 0), 1)
        // The upper lid's arch highest a little toward the nose, the lower's toward the side.
        let up = 0.0058 * pow(sin(.pi * pow(tc, 0.85)), 0.75), down = 0.0042 * pow(sin(.pi * pow(tc, 1.15)), 0.8)
        let vertical = max(e.y - (line + up), (line - down) - e.y)
        let horizontal = max(inner.x - x, x - outer.x)
        return max(max(vertical, horizontal * 0.6), -e.z)
    }

    /// The cut between the lips (in the arch's straightened space), from the front into the mouth.
    static func mouthCut(_ a: SIMD3<Float>) -> Float {
        let x = abs(a.x) / mouthHalfWidth
        let line = mouth.y - 0.0012 * x * x
        let open = 0.0008 * (1 - pow(min(x, 1), 4))
        return max(max(abs(a.y - line) - open, (x - 1) * mouthHalfWidth), 0.08 - a.z)
    }

    /// An ear: a rolled rim (the helix) round a thin, cupped shell with a ridge inside it (the antihelix) and a bowl
    /// toward its front (the concha), the lobe below, opening forward and out from the head on side `s`.
    static func ear(_ q: SIMD3<Float>, side s: Float) -> Float {
        let centre = SIMD3(s * ears[0].x, ears[0].y, ears[0].z)
        // Its frame: `out` from its face (turned forward), `up` along it (leaning back 15 degrees), `back` across it.
        let out = simd_normalize(SIMD3<Float>(s, 0, 0.5))
        let tilt: Float = 15 * .pi / 180
        var up = SIMD3<Float>(0, cos(tilt), -sin(tilt))
        up = simd_normalize(up - out * simd_dot(up, out))
        let back = simd_cross(up, out) * (s > 0 ? 1 : -1)
        let r = q - centre
        let u = simd_dot(r, back), v = simd_dot(r, up), w = simd_dot(r, out)
        // Outline: half height 31 mm, half width 17 mm above and 12 below (the lobe).
        let halfHeight: Float = 0.031
        let halfWidth = 0.0145 + 0.0035 * min(max(v / halfHeight, -1), 1)
        let outline = ((u / halfWidth) * (u / halfWidth) + (v / halfHeight) * (v / halfHeight)).squareRoot()
        let edge = (outline - 1) * min(halfWidth, halfHeight)
        // The shell, cupped (its middle in from the rim), its front against the head.
        let rimOut = 0.003 + 0.006 * smoothstep(-0.6, 0.8, u / halfWidth)
        let shell = rimOut - 0.0018 * (1 - min(outline * outline, 1))
        var d = smax(edge + 0.002, abs(w - shell) - 0.0012, 0.001)
        // The lobe, fuller.
        d = smin(d, ellipsoid(SIMD3(u - 0.001, v + 0.022, w - 0.002), [0.0065, 0.0075, 0.0032]), 0.003)
        // The helix: a tube along the outline, over the top and down the back.
        let rim: Float = 0.0024
        let along = smoothstep(-0.75, -0.2, u / halfWidth + max(v / halfHeight, 0) * 1.5) * smoothstep(-0.95, -0.55, v / halfHeight)
        if along > 0 {
            let tube = (pow(edge + rim, 2) + pow(w - rimOut, 2)).squareRoot() - rim * (0.55 + 0.45 * along)
            d = smin(d, tube + (1 - along) * 0.004, 0.0015)
        }
        // The antihelix: a ridge along a smaller outline, from the top down toward the lobe.
        let inner = ((u / (halfWidth * 0.55) + 0.25) * (u / (halfWidth * 0.55) + 0.25) + pow(v / (halfHeight * 0.62) - 0.12, 2)).squareRoot()
        let ridge = (pow((inner - 1) * halfWidth * 0.55, 2) + pow(w - shell - 0.0015, 2)).squareRoot() - 0.0017
        d = smin(d, ridge + 0.004 * smoothstep(0.1, -0.5, u / halfWidth), 0.0015)
        // The concha: a stalk into the skull (it holds the ear on), its bowl carved, and the tragus before it.
        let local = SIMD3(u, v, w)
        d = smin(d, roundCone(local, [-0.004, -0.004, -0.005], [-0.009, -0.003, -0.022], 0.0075, 0.0095), 0.003)
        d = smax(d, -sphere(SIMD3(u + 0.003, v + 0.005, w - 0.0082), 0.0068), 0.002)
        d = smin(d, sphere(SIMD3(u + 0.0138, v + 0.004, w - 0.0014), 0.0032), 0.0025)
        return d
    }

    // MARK: Distance helpers

    @inline(__always) static func sphere(_ p: SIMD3<Float>, _ r: Float) -> Float { simd_length(p) - r }

    /// An ellipsoid's distance, near enough to it (Quílez's bound).
    @inline(__always) static func ellipsoid(_ p: SIMD3<Float>, _ r: SIMD3<Float>) -> Float {
        let k0 = simd_length(p / r), k1 = simd_length(p / (r * r))
        return k1 > 1e-9 ? k0 * (k0 - 1) / k1 : -r.min()
    }

    /// An ellipsoid squarer across (exponent `n` in x and z).
    @inline(__always) static func superellipsoid(_ p: SIMD3<Float>, _ r: SIMD3<Float>, _ n: Float) -> Float {
        let q = simd_abs(p) / r
        let flat = pow(pow(q.x, n) + pow(q.z, n), 1 / n)
        return ((flat * flat + q.y * q.y).squareRoot() - 1) * r.min()
    }

    @inline(__always) static func smin(_ a: Float, _ b: Float, _ k: Float) -> Float { CharacterBase.smoothMin(a, b, k) }
    @inline(__always) static func smax(_ a: Float, _ b: Float, _ k: Float) -> Float { -CharacterBase.smoothMin(-a, -b, k) }
    @inline(__always) static func roundCone(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ ra: Float, _ rb: Float) -> Float {
        CharacterBase.roundCone(p, a, b, ra, rb)
    }
    @inline(__always) static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
