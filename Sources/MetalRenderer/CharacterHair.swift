import Foundation
import simd

/// What grows on a generated character: the hair of its scalp in a style, its beard, its brows and its lashes, as
/// strands (curves, Scene.addCurves) groomed once on the base's head (FaceSculpt's space) and carried by the character
/// every frame (crowdHairKernel): each strand's root is a point of one of the base's triangles, so it rides the skin
/// wherever the character's morphs and skinning take it (and its expressions: the brows rise, the lashes blink, the beard
/// opens with the jaw); its shape turns with the head's bone (scalp hair) or with its triangle (the rest).
///
/// Grooming: guide strands are grown from roots over the scalp along the style's flow (away from the parting, back,
/// forward, out from the crown), leaning into its fall as they lengthen and kept off the head (and the neck and
/// shoulders) as they go; every drawn strand follows its nearest guide, drawn toward it toward the tip (clumps), curled
/// and frizzed by its own hash. Crowds draw none of it: their hair is a cap (CharacterHairCap).
enum CharacterHair {
    /// How a style's hair lies at its root: away from a parting at x, combed back, forward, or out from the crown.
    enum Flow: Equatable { case part(Float), back, forward, crown }

    struct Style {
        var id: String
        var title: String
        /// Lengths (m) at the top, the sides, the back and over the forehead.
        var top: Float, sides: Float, back: Float, fringe: Float
        var flow: Flow
        /// How far it falls under its weight (0 stands as combed ... 1 hangs), and how far it stands off the scalp (m).
        var fall: Float, volume: Float
        /// The hairline drawn back (0 ... 1), and a bald crown's radius (m).
        var recede: Float = 0, crown: Float = 0
        /// Drawn strands per square centimetre, and how many control points each.
        var density: Float = 42
        var points: Int = 10
        /// Toward their guide at the tip (0 ... 1), curls (0 ... 1), and stray.
        var clump: Float = 0.45, curl: Float = 0, frizz: Float = 0.12
        /// Where its tips are cut (FaceSculpt's height; nil: wherever they reach).
        var cut: Float? = nil
    }

    static let styles: [Style] = [
        Style(id: "bald", title: "Bald", top: 0, sides: 0, back: 0, fringe: 0, flow: .crown, fall: 0, volume: 0, density: 0),
        Style(id: "buzz", title: "Buzz cut", top: 0.005, sides: 0.004, back: 0.004, fringe: 0.004, flow: .crown, fall: 0, volume: 0.0004,
              density: 60, points: 4, clump: 0, frizz: 0.05),
        Style(id: "receding", title: "Receding", top: 0.012, sides: 0.014, back: 0.016, fringe: 0.01, flow: .back, fall: 0.2, volume: 0.001,
              recede: 1, crown: 0.055, density: 32, points: 5, clump: 0.1, frizz: 0.15),
        Style(id: "short", title: "Short", top: 0.045, sides: 0.016, back: 0.02, fringe: 0.04, flow: .forward, fall: 0.3, volume: 0.007,
              density: 45, points: 8, clump: 0.4, frizz: 0.18),
        Style(id: "sidePart", title: "Side parting", top: 0.085, sides: 0.03, back: 0.035, fringe: 0.075, flow: .part(0.028), fall: 0.45,
              volume: 0.01, points: 11, clump: 0.5),
        Style(id: "slicked", title: "Slicked back", top: 0.1, sides: 0.04, back: 0.05, fringe: 0.1, flow: .back, fall: 0.25, volume: 0.006,
              points: 12, clump: 0.55, frizz: 0.06),
        Style(id: "curly", title: "Curly", top: 0.09, sides: 0.07, back: 0.08, fringe: 0.07, flow: .crown, fall: 0.25, volume: 0.025,
              density: 34, points: 26, clump: 0.6, curl: 1, frizz: 0.25),
        Style(id: "bob", title: "Bob", top: 0.22, sides: 0.2, back: 0.18, fringe: 0.085, flow: .part(0), fall: 0.95, volume: 0.006,
              points: 16, clump: 0.55, cut: 1.585),
        Style(id: "long", title: "Long", top: 0.42, sides: 0.4, back: 0.4, fringe: 0.38, flow: .part(0), fall: 1, volume: 0.006,
              points: 22, clump: 0.5, curl: 0.15, frizz: 0.3, cut: 1.36),
    ]

    struct Beard {
        var id: String
        var title: String
        var length: Float
        var density: Float
        /// Where on the beard's ground (SkinTextures.beardMask) it grows.
        var region: (SIMD3<Float>) -> Float
    }

    static let beards: [Beard] = [
        Beard(id: "none", title: "None", length: 0, density: 0) { _ in 0 },
        Beard(id: "stubble", title: "Stubble", length: 0.0018, density: 70) { _ in 1 },
        Beard(id: "short", title: "Short beard", length: 0.007, density: 70) { _ in 1 },
        Beard(id: "full", title: "Full beard", length: 0.026, density: 60) { _ in 1 },
        Beard(id: "goatee", title: "Goatee", length: 0.012, density: 70) { q in
            (1 - FaceSculpt.smoothstep(0.022, 0.03, abs(q.x))) * (1 - FaceSculpt.smoothstep(1.632, 1.64, q.y))
        },
        Beard(id: "moustache", title: "Moustache", length: 0.01, density: 75) { q in
            (1 - FaceSculpt.smoothstep(0.026, 0.032, abs(q.x))) * FaceSculpt.smoothstep(FaceSculpt.mouth.y + 0.002, FaceSculpt.mouth.y + 0.005, q.y)
                * (1 - FaceSculpt.smoothstep(1.634, 1.64, q.y))
        },
    ]

    static func style(_ id: String) -> Style { styles.first { $0.id == id } ?? styles[3] }
    static func beard(_ id: String) -> Beard { beards.first { $0.id == id } ?? beards[0] }

    /// Strands drawn alike: per strand the base's triangle its root is on and where (barycentric, the second and third
    /// corners'), and `perStrand` control points as offsets from the root, in the base's bind space (`followsHead`: they
    /// turn with the head's bone) or in its triangle's frame (x along its first edge, z its normal).
    struct Groom {
        enum Kind: Int { case scalp, brows, lashes, beard }
        var kind: Kind
        var perStrand: Int
        var triangles: [UInt32] = []
        var bary: [SIMD2<Float>] = []
        var offsets: [SIMD3<Float>] = []
        var rootRadius: Float
        var tipRadius: Float
        var followsHead: Bool
        var strandCount: Int { triangles.count }
        /// The furthest a point is from its root (m, the base's).
        var reach: Float { offsets.map { simd_length($0) }.max() ?? 0 }
    }

    // MARK: Colour

    /// The hair's colour (the colour it is seen to have, Hair.metal fits its pigment to it): dark (eumelanin) to
    /// platinum, reddened by pheomelanin, greyed by age and `grey`.
    static func colour(_ look: CharacterDNA.Look, age: Float) -> SIMD3<Float> {
        let platinum = SIMD3<Float>(0.62, 0.52, 0.36), black = SIMD3<Float>(0.012, 0.009, 0.007)
        var c = platinum * pow(black / platinum, SIMD3(repeating: pow(look.hairMelanin, 0.8)))
        let ginger = SIMD3<Float>(0.42, 0.12, 0.035) * (1.2 - look.hairMelanin)
        c += (ginger - c) * (look.hairRed * (1 - 0.6 * look.hairMelanin))
        let grey = min(1, look.grey + 0.85 * FaceSculpt.smoothstep(38, 75, age))
        return simd_clamp(c + (SIMD3(0.55, 0.54, 0.52) - c) * grey, SIMD3(repeating: 0.005), SIMD3(repeating: 0.9))
    }

    // MARK: Grooms

    private static let lock = NSLock()
    private static var recent: [(key: String, grooms: [Groom])] = []

    /// The grooms `dna` asks for (scalp, beard, brows, lashes; those with strands), on `kit`'s base. `density`: a share
    /// of each style's strands (fewer for a lineup). Kept for the last few asked for (a slider's drag asks again at
    /// every step).
    static func grooms(_ dna: CharacterDNA, kit: CharacterKit, density: Float = 1) -> [Groom] {
        let h = dna.hair
        let length = (h.length * 10).rounded() / 10, curl = (h.curl * 10).rounded() / 10, brows = (h.brows * 10).rounded() / 10
        let key = "\(CharacterKit.version) \(h.style) \(length) \(curl) \(h.beard) \(brows) \(density)"
        lock.lock()
        if let found = recent.first(where: { $0.key == key }) { lock.unlock(); return found.grooms }
        lock.unlock()
        let start = CFAbsoluteTimeGetCurrent()
        let groomer = Groomer(kit.base, seed: 0x5EED)
        var made: [Groom] = []
        var style = style(h.style)
        style.curl = min(1, style.curl + curl)
        let scale = 1 + 0.5 * length
        style.top *= scale; style.sides *= scale; style.back *= scale; style.fringe *= scale
        if let cut = style.cut, length != 0 { style.cut = cut - 0.1 * length }
        if style.density > 0 { made.append(groomer.scalp(style, density: density)) }
        let beard = beard(h.beard)
        if beard.density > 0 { made.append(groomer.beard(beard, density: density)) }
        if brows > 0 { made.append(groomer.brows(brows, density: density)) }
        made += groomer.lashes(density: density)
        made = made.filter { $0.strandCount > 0 }
        print(String(format: "Character hair: %@, %d strands in %.0f ms", h.style, made.reduce(0) { $0 + $1.strandCount },
                     (CFAbsoluteTimeGetCurrent() - start) * 1000))
        lock.lock()
        recent.insert((key, made), at: 0)
        if recent.count > 6 { recent.removeLast() }
        lock.unlock()
        return made
    }

    /// A groom's strands for a character whose skin is at `positions` (its level 0, posed or not): each strand's
    /// `perStrand` + 2 control points (a phantom before and after: Catmull-Rom curves pass through the rest), the head's
    /// bone turned by `head` (its skinning matrix's rotation), the strands' shape scaled by `scale` (its head against the
    /// base's). What crowdHairKernel writes.
    static func place(_ g: Groom, indices: [UInt32], positions: [SIMD3<Float>], head: simd_float3x3, scale: Float) -> [SIMD3<Float>] {
        let n = g.perStrand
        var out = [SIMD3<Float>](repeating: .zero, count: g.strandCount * (n + 2))
        out.withUnsafeMutableBufferPointer { o in
            DispatchQueue.concurrentPerform(iterations: (g.strandCount + 1023) / 1024) { chunk in
                for s in (chunk * 1024)..<min(g.strandCount, chunk * 1024 + 1024) {
                    let t = Int(g.triangles[s])
                    let p0 = positions[Int(indices[3 * t])], p1 = positions[Int(indices[3 * t + 1])], p2 = positions[Int(indices[3 * t + 2])]
                    let b = g.bary[s]
                    let root = p0 * (1 - b.x - b.y) + p1 * b.x + p2 * b.y
                    let frame = g.followsHead ? head : triangleFrame(p0, p1, p2)
                    let base = s * (n + 2)
                    for i in 0..<n { o[base + 1 + i] = root + frame * (g.offsets[s * n + i] * scale) }
                    o[base] = 2 * o[base + 1] - o[base + 2]
                    o[base + n + 1] = 2 * o[base + n] - o[base + n - 1]
                }
            }
        }
        return out
    }

    /// A triangle's frame: x along its first edge, z its normal (crowdHairKernel's).
    @inline(__always) static func triangleFrame(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>) -> simd_float3x3 {
        let x = simd_normalize(p1 - p0), z = simd_normalize(simd_cross(p1 - p0, p2 - p0))
        return simd_float3x3(columns: (x, simd_cross(z, x), z))
    }

    /// How far into the scalp a point is (FaceSculpt's space, m; negative outside it): the hairline round the forehead,
    /// the temples, in front of and above the ears, down to the nape; back from the forehead and thinned at the crown
    /// by `recede` and `crown` (a style's).
    static func scalpDistance(_ q: SIMD3<Float>, recede: Float, crown: Float) -> Float { Groomer.scalp(q, recede: recede, crown: crown) }

    /// The radii of a groom's strands' control points, the phantoms' included: root to tip.
    static func radii(_ g: Groom) -> [Float] {
        let n = g.perStrand
        let taper = (0..<n).map { g.rootRadius + (g.tipRadius - g.rootRadius) * pow(Float($0) / Float(n - 1), 1.5) }
        return [taper[0]] + taper + [taper[n - 1]]
    }
}

/// Grows the grooms on a base (CharacterHair): its head's triangles, where hair may root, and the strands.
private struct Groomer {
    let base: CharacterBase
    let sculpt: FaceSculpt
    let local: [SIMD3<Float>]
    let seed: UInt64

    init(_ base: CharacterBase, seed: UInt64) {
        self.base = base
        let sculpt = FaceSculpt(base.character) ?? FaceSculpt()
        self.sculpt = sculpt
        local = base.character.positions.map { sculpt.local($0) }
        self.seed = seed
    }

    // MARK: Roots

    struct Root { var triangle: UInt32; var bary: SIMD2<Float>; var q: SIMD3<Float>; var n: SIMD3<Float> }

    /// Roots over the head's skin, `perSquareCm` of them where `weight` is 1 (fewer where it is less), at random.
    func roots(perSquareCm: Float, seed s: UInt64, _ weight: (SIMD3<Float>, SIMD3<Float>) -> Float) -> [Root] {
        let c = base.character
        let head = CharacterBase.Region.head.rawValue
        var triangles: [Int] = [], cdf: [Float] = [], total: Float = 0
        for t in 0..<(c.indices.count / 3) {
            let v = (0..<3).map { Int(c.indices[3 * t + $0]) }
            guard v.allSatisfy({ base.regions[$0] == head }) else { continue }
            let q = v.map { local[$0] }
            let centre = (q[0] + q[1] + q[2]) / 3
            let n = simd_normalize(simd_cross(q[1] - q[0], q[2] - q[0]))
            // (Any corner in: a hairline's triangles straddle it.)
            let w = max(weight(centre, n), max(weight(q[0], n), max(weight(q[1], n), weight(q[2], n))))
            guard w > 0 else { continue }
            total += 0.5 * simd_length(simd_cross(q[1] - q[0], q[2] - q[0]))
            triangles.append(t)
            cdf.append(total)
        }
        guard total > 0 else { return [] }
        let count = Int(perSquareCm * total * 10_000)
        var rng = SplitMix64(seed: seed &+ s)
        var out: [Root] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            let r = rng.next() * total
            var lo = 0, hi = cdf.count - 1
            while lo < hi { let mid = (lo + hi) / 2; if cdf[mid] < r { lo = mid + 1 } else { hi = mid } }
            let t = triangles[lo]
            var b = SIMD2(rng.next(), rng.next())
            if b.x + b.y > 1 { b = 1 - b }
            let v = (0..<3).map { Int(c.indices[3 * t + $0]) }
            let q = local[v[0]] * (1 - b.x - b.y) + local[v[1]] * b.x + local[v[2]] * b.y
            let n = simd_normalize(simd_normalize(c.normals[v[0]]) * (1 - b.x - b.y) + simd_normalize(c.normals[v[1]]) * b.x
                                   + simd_normalize(c.normals[v[2]]) * b.y)
            guard rng.next() < weight(q, n) else { continue }
            out.append(Root(triangle: UInt32(t), bary: b, q: q, n: n))
        }
        return out
    }

    /// How far into the scalp a point is (m; negative outside it): the hairline round the forehead, the temples, in
    /// front of and above the ears, down to the nape; back from the forehead and thinned at the crown by `recede`.
    static func scalp(_ q: SIMD3<Float>, recede: Float, crown: Float) -> Float {
        let a = abs(atan2(q.x, q.z + 0.01))   // 0 at the front ... pi at the back
        let knots: [(Float, Float)] = [(0, 1.768), (0.5, 1.748), (0.78, 1.73), (0.98, 1.675), (1.12, 1.672), (1.35, 1.712),
                                       (1.75, 1.668), (2.3, 1.62), (Float.pi, 1.6)]
        var line = knots.last!.1
        for k in 1..<knots.count where a <= knots[k].0 {
            let t = (a - knots[k - 1].0) / (knots[k].0 - knots[k - 1].0)
            line = knots[k - 1].1 + (knots[k].1 - knots[k - 1].1) * (t * t * (3 - 2 * t))
            break
        }
        // Receding: the front drawn back, deepest at the temples.
        line += recede * 0.03 * (1 - FaceSculpt.smoothstep(0.9, 1.3, a)) * (0.6 + 0.4 * FaceSculpt.smoothstep(0.1, 0.6, a))
        var d = q.y - line
        // Not the ears, nor just round them.
        let ear = simd_distance(SIMD3(abs(q.x), q.y, q.z), FaceSculpt.ears[0] + [0, 0.004, 0])
        d = min(d, ear - 0.036)
        if crown > 0 { d = min(d, simd_distance(q, [0, 1.795, -0.025]) - crown) }
        return d
    }

    // MARK: Scalp

    func scalp(_ style: CharacterHair.Style, density: Float) -> CharacterHair.Groom {
        let n = style.points
        var groom = CharacterHair.Groom(kind: .scalp, perStrand: n, rootRadius: style.top < 0.01 ? 0.00006 : 0.000075,
                                        tipRadius: 0.00003, followsHead: true)
        let weight: (SIMD3<Float>, SIMD3<Float>) -> Float = { q, _ in
            FaceSculpt.smoothstep(0, 0.008, Groomer.scalp(q, recede: style.recede, crown: style.crown))
        }
        // Guides about 3.5 mm apart, then the drawn strands, each after its nearest guide.
        let guideRoots = roots(perSquareCm: 8, seed: 1, weight)
        let guides = guideRoots.map { grow($0, style) }
        let grid = SpatialGrid(guideRoots.map(\.q), cell: 0.006)
        let strands = roots(perSquareCm: style.density * density, seed: 2, weight)
        groom.triangles = strands.map(\.triangle)
        groom.bary = strands.map(\.bary)
        groom.offsets = [SIMD3<Float>](repeating: .zero, count: strands.count * n)
        groom.offsets.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: (strands.count + 255) / 256) { chunk in
                for s in (chunk * 256)..<min(strands.count, chunk * 256 + 256) {
                    let root = strands[s]
                    let g = grid.nearest(root.q) ?? 0
                    let points = follow(root, guide: guides[g], guideRoot: guideRoots[g].q, style, hash: UInt32(truncatingIfNeeded: s))
                    for i in 0..<n { out[s * n + i] = (points[i] - root.q) * sculpt.scale }
                }
            }
        }
        return groom
    }

    /// Where the style's hair lies at a root: the direction it is combed along the scalp.
    func flow(_ q: SIMD3<Float>, _ n: SIMD3<Float>, _ style: CharacterHair.Style) -> SIMD3<Float> {
        let front = FaceSculpt.smoothstep(0.02, 0.07, q.z) * FaceSculpt.smoothstep(1.72, 1.76, q.y)
        var d: SIMD3<Float>
        switch style.flow {
        case .back:
            d = [0, 0.25, -1]
        case .forward:
            // The top combed forward (fanning out a little toward the temples), the sides and back down.
            let top = FaceSculpt.smoothstep(1.725, 1.765, q.y)
            d = SIMD3(q.x * 0.8, -0.05, 1) * top + SIMD3(0, -1, -0.25) * (1 - top)
        case .crown:
            d = q - SIMD3(0, 1.82, -0.03)
        case .part(let x):
            // Away from the parting over the top; the fringe forward and to the side; down everywhere else.
            let side: Float = q.x >= x ? 1 : -1
            let top = FaceSculpt.smoothstep(1.74, 1.79, q.y)
            d = SIMD3(side, -0.15, 0.1) * top + SIMD3(0, -1, -0.1) * (1 - top)
            // The front swept across the forehead away from the parting (a middle parting's falls to both sides).
            d += SIMD3(side * (x == 0 ? 0.6 : 1.4), x == 0 ? -0.4 : 0.15, 0.5) * front
        }
        // Along the scalp.
        d -= n * simd_dot(d, n)
        return simd_length(d) > 1e-5 ? simd_normalize(d) : simd_normalize(simd_cross(n, [1, 0, 0]))
    }

    /// The style's length at a root: the top's, the sides', the back's, over the forehead the fringe's.
    func length(_ q: SIMD3<Float>, _ style: CharacterHair.Style) -> Float {
        let top = FaceSculpt.smoothstep(1.73, 1.77, q.y)
        let front = FaceSculpt.smoothstep(0.03, 0.075, q.z) * FaceSculpt.smoothstep(1.71, 1.75, q.y)
        let back = FaceSculpt.smoothstep(-0.02, -0.07, q.z)
        var l = style.sides + (style.back - style.sides) * back
        l += (style.top - l) * top
        l += (style.fringe - l) * front
        return l
    }

    /// The head, neck and shoulders as one field (FaceSculpt's space, m; negative inside): what hair is kept off.
    static func body(_ q: SIMD3<Float>) -> Float {
        var d = FaceSculpt.field(q)
        if q.y < 1.62 {
            let neck = FaceSculpt.roundCone(q, [0, 1.38, -0.015], [0, 1.6, -0.01], 0.07, 0.058)
            let trunk = FaceSculpt.ellipsoid(q - SIMD3(0, 1.3, -0.005), [0.2, 0.16, 0.115])
            d = min(d, FaceSculpt.smin(neck, trunk, 0.04))
        }
        return d
    }

    static func gradient(_ q: SIMD3<Float>) -> SIMD3<Float> {
        let h: Float = 0.0005
        let g = SIMD3(body(q + [h, 0, 0]) - body(q - [h, 0, 0]), body(q + [0, h, 0]) - body(q - [0, h, 0]),
                      body(q + [0, 0, h]) - body(q - [0, 0, h]))
        return simd_length(g) > 1e-9 ? simd_normalize(g) : [0, 1, 0]
    }

    /// A guide: from the root out along its normal, turning along the flow and falling with length, kept the style's
    /// volume off the head; cut where the style's tips are.
    func grow(_ root: Root, _ style: CharacterHair.Style) -> [SIMD3<Float>] {
        let n = style.points
        let total = max(length(root.q, style), 0.002)
        let comb = flow(root.q, root.n, style)
        var p = root.q + root.n * 0.0003
        // Short hair lies close; longer hair stands off its root before it turns (its volume, more on top).
        let top = FaceSculpt.smoothstep(1.73, 1.77, root.q.y)
        let volume = style.volume * (0.35 + 0.65 * top)
        let rise = min(0.1 + 30 * volume, 0.8)
        var dir = simd_normalize(root.n * rise + comb)
        var points = [p]
        let segment = total / Float(n - 1)
        for i in 1..<n {
            let arc = Float(i) * segment
            let fall = style.fall * FaceSculpt.smoothstep(0, 0.06, arc)
            var want = comb * (1 - fall) + SIMD3(0, -1, 0) * fall
            // Lift off the scalp near the root (volume), less as it falls.
            want += root.n * (rise * 0.8 * (1 - FaceSculpt.smoothstep(0, 0.04, arc)))
            dir = simd_normalize(dir * 0.55 + simd_normalize(want) * 0.45)
            var next = p + dir * segment
            let off = 0.0008 + volume * FaceSculpt.smoothstep(0, 0.03, arc)
            for _ in 0..<3 {
                let d = Groomer.body(next)
                guard d < off else { break }
                next += Groomer.gradient(next) * (off - d)
            }
            // Hair that doesn't fall hugs the head as it curves away (combed down onto it).
            let hug = (1 - fall) * (1 - FaceSculpt.smoothstep(0.004, 0.02, volume))
            if hug > 0 {
                let d = Groomer.body(next)
                if d > off, d < off + 0.02 { next -= Groomer.gradient(next) * ((d - off) * 0.6 * hug) }
            }
            next = p + simd_normalize(next - p) * segment
            dir = simd_normalize(next - p)
            points.append(next)
            p = next
        }
        if let cut = style.cut { return Groomer.cut(points, below: cut) }
        return points
    }

    /// `points` shortened to end where they first go below `height` (resampled to as many).
    static func cut(_ points: [SIMD3<Float>], below height: Float) -> [SIMD3<Float>] {
        guard let k = points.indices.first(where: { points[$0].y < height }), k > 1 else { return points }
        let a = points[k - 1], b = points[k]
        let t = (a.y - height) / max(a.y - b.y, 1e-6)
        var path = Array(points[0..<k]) + [a + (b - a) * t]
        return resample(&path, count: points.count)
    }

    static func resample(_ path: inout [SIMD3<Float>], count: Int) -> [SIMD3<Float>] {
        var arcs: [Float] = [0]
        for i in 1..<path.count { arcs.append(arcs[i - 1] + simd_distance(path[i], path[i - 1])) }
        let total = arcs.last!
        var out: [SIMD3<Float>] = []
        var j = 0
        for i in 0..<count {
            let s = total * Float(i) / Float(count - 1)
            while j < path.count - 2 && arcs[j + 1] < s { j += 1 }
            let t = (s - arcs[j]) / max(arcs[j + 1] - arcs[j], 1e-9)
            out.append(path[j] + (path[j + 1] - path[j]) * min(max(t, 0), 1))
        }
        return out
    }

    /// A drawn strand from `root` after its guide: the guide's shape moved to the root, drawn toward the guide toward
    /// the tip (clumping), curled and strayed by its hash, kept off the head.
    func follow(_ root: Root, guide: [SIMD3<Float>], guideRoot: SIMD3<Float>, _ style: CharacterHair.Style, hash: UInt32) -> [SIMD3<Float>] {
        let n = guide.count
        let h = SkinTextures.hash(Int32(bitPattern: hash), 7, 3, UInt32(truncatingIfNeeded: seed))
        let r0 = SkinTextures.unit(h), r1 = SkinTextures.unit(h &* 0x9E37_79B9), r2 = SkinTextures.unit(h ^ 0x5bd1e995)
        let lengthJitter: Float = 0.85 + 0.3 * r0
        let shift = root.q - guideRoot
        var points: [SIMD3<Float>] = []
        var total: Float = 0
        for i in 1..<n { total += simd_distance(guide[i], guide[i - 1]) }
        for i in 0..<n {
            let f = Float(i) / Float(n - 1)
            // The guide's point (shortened by the jitter: its shape up to there), moved toward the root's place.
            let at = min(Float(n - 1) * f * lengthJitter, Float(n - 1))
            let k = min(Int(at), n - 2), t = at - Float(k)
            let g = guide[k] + (guide[k + 1] - guide[k]) * t
            var p = g + shift * (1 - style.clump * FaceSculpt.smoothstep(0.1, 1, f))
            // Stray: a little noise across, more toward the tip.
            let stray = style.frizz * 0.006 * f * f * Float(total > 0.02 ? 1 : 0.3)
            p += SIMD3(SkinTextures.noise(SIMD3(r1 * 40, f * 6, 1), seed: hash) - 0.5, SkinTextures.noise(SIMD3(r2 * 40, f * 6, 2), seed: hash) - 0.5,
                       SkinTextures.noise(SIMD3(r0 * 40, f * 6, 3), seed: hash) - 0.5) * (2 * stray)
            points.append(p)
        }
        if style.curl > 0 { curl(&points, radius: 0.0035 * style.curl, period: 0.014 - 0.004 * style.curl, phase: r1 * 6.283) }
        // Off the head: the near half, where it lies closest.
        let lift: Float = 0.0006 + style.volume * 0.25
        for i in 1..<n {
            let d = Groomer.body(points[i])
            if d < lift { points[i] += Groomer.gradient(points[i]) * (lift - d) }
            if Float(i) > Float(n) * 0.6 && d > 0.004 { break }
        }
        return points
    }

    /// A helix about the strand's path, growing from the root.
    func curl(_ points: inout [SIMD3<Float>], radius: Float, period: Float, phase: Float) {
        let n = points.count
        var arc: Float = 0
        let path = points
        var across = simd_normalize(simd_cross(path[1] - path[0], [0.3, 1, 0.2]))
        for i in 1..<n {
            arc += simd_distance(path[i], path[i - 1])
            let t = simd_normalize(path[i] - path[i - 1])
            across = simd_normalize(across - t * simd_dot(across, t))
            let other = simd_cross(t, across)
            let a = phase + 2 * .pi * arc / period
            points[i] = path[i] + (across * cos(a) + other * sin(a)) * radius * FaceSculpt.smoothstep(0, 0.012, arc)
        }
    }

    // MARK: Face

    /// Strands from `roots` whose points (FaceSculpt's space, `n` of them; nil: none from that root) `make` gives, in
    /// their triangles' frames.
    func strands(_ kind: CharacterHair.Groom.Kind, _ roots: [Root], points n: Int, rootRadius: Float, tipRadius: Float,
                 _ make: (Root, UInt32) -> [SIMD3<Float>]?) -> CharacterHair.Groom {
        let c = base.character
        var g = CharacterHair.Groom(kind: kind, perStrand: n, rootRadius: rootRadius, tipRadius: tipRadius, followsHead: false)
        for (s, root) in roots.enumerated() {
            guard let points = make(root, UInt32(truncatingIfNeeded: s)), points.count == n else { continue }
            let t = Int(root.triangle)
            let p0 = c.positions[Int(c.indices[3 * t])], p1 = c.positions[Int(c.indices[3 * t + 1])], p2 = c.positions[Int(c.indices[3 * t + 2])]
            let frame = CharacterHair.triangleFrame(p0, p1, p2).transpose   // world -> the triangle's
            g.triangles.append(root.triangle)
            g.bary.append(root.bary)
            for p in points { g.offsets.append(frame * ((p - root.q) * sculpt.scale)) }
        }
        return g
    }

    /// Short strands lying along the skin from `roots`, each `length` long toward `direction` (along the skin), out of
    /// it at `lift` (0 flat ... 1 straight out) and bending down onto it by `bend` toward the tip.
    func lying(_ kind: CharacterHair.Groom.Kind, _ roots: [Root], points n: Int, rootRadius: Float, tipRadius: Float,
               _ shape: (Root, UInt32) -> (direction: SIMD3<Float>, length: Float, lift: Float, bend: Float)) -> CharacterHair.Groom {
        strands(kind, roots, points: n, rootRadius: rootRadius, tipRadius: tipRadius) { root, s in
            let (direction, length, lift, bend) = shape(root, s)
            guard length > 0 else { return nil }
            var along = direction - root.n * simd_dot(direction, root.n)
            along = simd_length(along) > 1e-5 ? simd_normalize(along) : simd_normalize(simd_cross(root.n, [1, 0, 0]))
            var points: [SIMD3<Float>] = []
            for i in 0..<n {
                let f = Float(i) / Float(n - 1)
                let up = lift * (1 - bend * f)
                let d = simd_normalize(along * (1 - up) + root.n * up)
                points.append(i == 0 ? root.q + root.n * 0.0001 : points[i - 1] + d * (length / Float(n - 1)))
            }
            return points
        }
    }

    func beard(_ beard: CharacterHair.Beard, density: Float) -> CharacterHair.Groom {
        let roots = roots(perSquareCm: beard.density * density, seed: 3) { q, n in
            let m = SkinTextures.beardMask(q, n) * beard.region(q)
            return FaceSculpt.smoothstep(0.25, 0.6, m)
        }
        let n = beard.length < 0.004 ? 3 : beard.length < 0.012 ? 5 : 8
        return lying(.beard, roots, points: n, rootRadius: 0.00008, tipRadius: 0.00003) { root, s in
            let h = SkinTextures.hash(Int32(bitPattern: s), 11, 5, 99)
            // Down the face, out a little; the moustache down and out from the middle.
            var d = SIMD3<Float>(0, -1, 0.15)
            if root.q.y > FaceSculpt.mouth.y { d = SIMD3(root.q.x > 0 ? 0.6 : -0.6, -1, 0.2) }
            d += SIMD3(SkinTextures.unit(h) - 0.5, 0, SkinTextures.unit(h &* 31) - 0.5) * 0.5
            let l = beard.length * (0.7 + 0.6 * SkinTextures.unit(h &* 0x9E37_79B9))
            return (d, l, beard.length < 0.004 ? 0.6 : 0.45, 0.6)
        }
    }

    /// The brows: hairs along an arc over each eye (FaceParts' painted brows'), the inner ones up, the rest out along
    /// it toward the temple, lying on the skin.
    func brows(_ thickness: Float, density: Float) -> CharacterHair.Groom {
        func arc(_ q: SIMD3<Float>) -> (t: Float, offset: Float, half: Float)? {
            for e in FaceSculpt.eyeCentres where e.x * q.x > 0 {
                let x = abs(q.x) - abs(e.x)
                guard x > -0.0185, x < 0.023, q.z > e.z - 0.006 else { continue }
                let t = (x + 0.0175) / 0.039
                let middle = e.y + 0.0185 + 0.0045 * sin(.pi * min(max(t, 0) * 1.15, 1)) - 0.003 * t
                let half = (0.0042 * (1 - 0.6 * min(max(t, 0), 1)) + 0.0006) * (0.7 + 0.5 * thickness)
                return (t, q.y - middle, half)
            }
            return nil
        }
        let roots = roots(perSquareCm: 320 * (0.4 + 0.8 * thickness) * max(density, 0.5), seed: 4) { q, _ in
            guard let a = arc(q) else { return 0 }
            return (1 - FaceSculpt.smoothstep(0.65, 1.05, abs(a.offset) / a.half)) * FaceSculpt.smoothstep(-0.05, 0.05, a.t)
                * (1 - FaceSculpt.smoothstep(0.95, 1.05, a.t))
        }
        return lying(.brows, roots, points: 5, rootRadius: 0.00008, tipRadius: 0.00003) { root, s in
            guard let a = arc(root.q) else { return (.zero, 0, 0, 0) }
            let h = SkinTextures.hash(Int32(bitPattern: s), 13, 7, 77)
            let side: Float = root.q.x > 0 ? 1 : -1
            // Inner hairs stand up, the body's lie outward and a little up, the tail's outward and down.
            let up = 1 - FaceSculpt.smoothstep(0.05, 0.3, a.t)
            var d = SIMD3<Float>(side, 0.35 - 0.6 * FaceSculpt.smoothstep(0.55, 1, a.t), 0) * (1 - up) + SIMD3(side * 0.25, 1, 0) * up
            // Hairs above the middle lean down onto it, those below up: they meet along it.
            d.y -= 1.2 * a.offset / a.half * (1 - up)
            d += SIMD3(0, SkinTextures.unit(h) - 0.5, 0) * 0.4
            let l: Float = (0.0055 + 0.003 * SkinTextures.unit(h &* 17)) * (1 - 0.3 * FaceSculpt.smoothstep(0.7, 1, a.t))
            return (d, l, 0.18, 1)
        }
    }

    /// The lashes: along each lid's edge (FaceRig's lid vertices that turn all the way, the front of the edge), the
    /// upper's long and curling up, the lower's short and down.
    func lashes(density: Float) -> [CharacterHair.Groom] {
        let c = base.character
        guard c.positions.count > 0 else { return [] }
        var triangleOf = [Int](repeating: -1, count: c.positions.count)
        for t in 0..<(c.indices.count / 3) {
            for k in 0..<3 where triangleOf[Int(c.indices[3 * t + k])] < 0 { triangleOf[Int(c.indices[3 * t + k])] = t }
        }
        var grooms: [CharacterHair.Groom] = []
        for upper in [true, false] {
            var roots: [Root] = []
            for (e, centre) in FaceSculpt.eyeCentres.enumerated() {
                let s: Float = e == 0 ? 1 : -1
                // The lid's edge: per 0.4 mm across, its vertex nearest the opening, at the front.
                var bins: [Int: (v: Int, y: Float, z: Float)] = [:]
                for v in c.positions.indices where base.regions[v] == CharacterBase.Region.head.rawValue {
                    let q = local[v], r = q - centre
                    guard simd_length(r) < 0.024, r.z > 0.004, let (group, w) = FaceRig.lid(q), w > 0.98 else { continue }
                    let isUpper = group == .leftUpperLid || group == .rightUpperLid
                    guard isUpper == upper else { continue }
                    let bin = Int((r.x * s + 0.02) / 0.0004)
                    let y = upper ? r.y : -r.y
                    if let b = bins[bin], b.y < y - 0.0004 || (abs(b.y - y) <= 0.0004 && b.z >= r.z) { continue }
                    bins[bin] = (v, y, r.z)
                }
                for (_, b) in bins.sorted(by: { $0.key < $1.key }) {
                    let t = triangleOf[b.v]
                    guard t >= 0 else { continue }
                    let corner = (0..<3).first { Int(c.indices[3 * t + $0]) == b.v } ?? 0
                    let bary: SIMD2<Float> = corner == 0 ? [0, 0] : corner == 1 ? [1, 0] : [0, 1]
                    let copies = upper ? 2 : 1
                    for _ in 0..<max(1, Int(Float(copies) * min(density, 1))) {
                        roots.append(Root(triangle: UInt32(t), bary: bary, q: local[b.v], n: simd_normalize(c.normals[b.v])))
                    }
                }
            }
            let g = strands(.lashes, roots, points: 5, rootRadius: 0.00006, tipRadius: 0.000015) { root, s in
                let h = SkinTextures.hash(Int32(bitPattern: s), upper ? 17 : 19, 9, 55)
                let side: Float = root.q.x > 0 ? 1 : -1
                let e = side > 0 ? FaceSculpt.eyeCentres[0] : FaceSculpt.eyeCentres[1]
                let x = (root.q.x - e.x) * side
                // Longest at the middle; outward at the outer corner.
                let middle = 1 - FaceSculpt.smoothstep(0.004, 0.015, abs(x - 0.002))
                let l = (upper ? 0.0045 + 0.0035 * middle : 0.0022 + 0.0016 * middle) * (0.85 + 0.3 * SkinTextures.unit(h))
                // Out of the edge forward, curling up (the lower ones down), a little spread.
                let out = simd_normalize(SIMD3(side * (0.3 * FaceSculpt.smoothstep(0, 0.012, x) + 0.15 * (SkinTextures.unit(h &* 7) - 0.5)),
                                               upper ? 0.2 : -0.3, 1))
                let up = SIMD3<Float>(0, upper ? 1 : -1, 0)
                return (0..<5).map { i in
                    let f = Float(i) / 4
                    return root.q + out * (l * f) + up * (l * (upper ? 0.45 : 0.25) * f * f) + SIMD3(0, 0, 0.0002)
                }
            }
            grooms.append(g)
        }
        return grooms
    }
}

/// Points of a space in cells, for the nearest of them to a point.
private struct SpatialGrid {
    let points: [SIMD3<Float>]
    let cell: Float
    var cells: [SIMD3<Int32>: [Int]] = [:]

    init(_ points: [SIMD3<Float>], cell: Float) {
        self.points = points
        self.cell = cell
        for (i, p) in points.enumerated() { cells[key(p), default: []].append(i) }
    }

    func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        let k = (p / cell).rounded(.down)
        return SIMD3(Int32(k.x), Int32(k.y), Int32(k.z))
    }

    func nearest(_ p: SIMD3<Float>) -> Int? {
        let k = key(p)
        var best: (Int, Float)? = nil
        for reach: Int32 in 1...3 {
            for dz in -reach...reach {
                for dy in -reach...reach {
                    for dx in -reach...reach {
                        for i in cells[k &+ SIMD3(dx, dy, dz)] ?? [] {
                            let d = simd_distance_squared(points[i], p)
                            if d < best?.1 ?? .infinity { best = (i, d) }
                        }
                    }
                }
            }
            if best != nil { return best!.0 }
        }
        return nil
    }
}
