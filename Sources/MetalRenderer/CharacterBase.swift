import Foundation
import simd

/// The body every generated character is made from (CharacterDNA, CharacterBuilder): the Y Bot's skin made again as
/// one smooth closed surface, skinned to the Y Bot's own skeleton, so that every clip of the library plays on it.
///
/// The Y Bot is a mannequin: panels over joint pieces, hollow elbows, mittens of fingers, no face. Its skin is taken as
/// a distance field (BodySurface: flooded from outside, so the pieces within don't count, and smoothed, so the grooves
/// between panels close); its hands are cut off at the wrists and made again of a palm and fingers on the skeleton's
/// finger joints; then the field is meshed (sparse surface nets), simplified, and each vertex takes the weights of the
/// Y Bot's skin under it (the hands' from their bones).
struct CharacterBase {
    /// The body in its bind pose (the Y Bot's T pose): mesh, skin, joints and names. No clips: CharacterBuilder gives
    /// each character the library's.
    var character: SkinnedCharacter
    /// Per vertex, what part of the body it is (Region), for the morphs' masks.
    var regions: [UInt8]
    /// Per vertex, its material (FaceParts.Material); a triangle takes its corners' (`triangleMaterials`).
    var materials: [UInt8]

    enum Region: UInt8 {
        case trunk, head, neck, arm, hand, leg, foot
        /// The face's meshes of their own (FaceParts): the eyeballs, the upper and lower teeth, the tongue.
        case leftEye, rightEye, upperTeeth, lowerTeeth, tongue
    }

    struct Options {
        /// Surface nets' cell (m), and how many triangles the full-detail mesh is simplified to (the head's among them).
        var cell: Float = 0.0025
        var triangles = 96_000
        /// BodySurface's: its grid and how far it is smoothed (cells).
        var surfaceCell: Float = 0.006
        var smoothing = 3
        /// Taubin passes over the mesh.
        var smoothingPasses = 12
        var trunkPasses = 20
        /// The head's cell and triangles (it is meshed apart from the body, finer, and joined to it at the neck).
        var headCell: Float = 0.001
        var headTriangles = 32_000
    }

    // MARK: Joints

    /// A joint's index by its Mixamo name without "mixamorig:".
    static func joint(_ name: String, in c: SkinnedCharacter) -> Int? {
        c.jointNames.firstIndex { $0 == name || $0 == "mixamorig:" + name }
    }

    /// Each joint's position in the bind pose.
    static func bindPositions(_ c: SkinnedCharacter) -> [SIMD3<Float>] { c.bindPoses.map(\.t) }

    // MARK: Hands

    /// A hand made again from its bones: a palm (a rounded box from the wrist to the knuckles, fanned out to them) and
    /// five fingers (round cones along their joints), on the forearm's end. `zone`: where the body's own hand is cut
    /// off (beyond a plane across the wrist).
    struct Hand {
        struct Segment { var a: SIMD3<Float>; var b: SIMD3<Float>; var ra: Float; var rb: Float; var joint: Int; var finger: Int }
        let wrist: SIMD3<Float>
        let along: SIMD3<Float>            // from the forearm toward the fingers
        let frame: simd_float3x3           // palm: x toward the fingers, y out of the back of the hand, z across
        let palmCentre: SIMD3<Float>
        let palmHalf: SIMD3<Float>
        let palmRounding: Float
        let wristRadius: SIMD2<Float>      // across (y, z)
        let segments: [Segment]            // fingers, thumb first
        let hand: Int                      // the hand's joint
        let reach: Float                   // a sphere round the wrist that holds it all

        init?(_ c: SkinnedCharacter, side: String, body: BodySurface) {
            let bind = CharacterBase.bindPositions(c)
            guard let h = CharacterBase.joint("\(side)Hand", in: c), let fore = CharacterBase.joint("\(side)ForeArm", in: c),
                  let index = CharacterBase.joint("\(side)HandIndex1", in: c), let middle = CharacterBase.joint("\(side)HandMiddle1", in: c),
                  let pinky = CharacterBase.joint("\(side)HandPinky1", in: c) else { return nil }
            hand = h
            wrist = bind[h]
            along = simd_normalize(bind[h] - bind[fore])
            let toKnuckles = bind[middle] - wrist
            let x = simd_normalize(toKnuckles)
            var z = bind[pinky] - bind[index]
            z = simd_normalize(z - x * simd_dot(z, x))
            var y = simd_cross(z, x)
            if y.y < 0 { y = -y; z = -z }      // the back of the hand up (a T pose's palms face down)
            frame = simd_float3x3(columns: (x, y, z))
            // Its size from its knuckles: a palm is about 0.79 of its width across the outer two knuckles' centres.
            let span = simd_length(bind[pinky] - bind[index])
            let width = span / 0.79
            let length = simd_length(toKnuckles)
            palmHalf = SIMD3(length * 0.5 + width * 0.06, width * 0.16, width * 0.5)
            palmRounding = width * 0.15
            palmCentre = wrist + x * (length * 0.5 + width * 0.02)
            // The wrist as thick as the body's forearm just before it.
            let probe = wrist - along * 0.03
            let r = max(-body.distance(probe), 0.018)
            wristRadius = SIMD2(r * 0.78, r * 1.08)

            var segments: [Segment] = []
            let fingers: [(name: String, base: Float, tip: Float)] = [("Thumb", 0.15, 0.11), ("Index", 0.105, 0.085),
                                                                      ("Middle", 0.108, 0.087), ("Ring", 0.1, 0.082),
                                                                      ("Pinky", 0.088, 0.072)]
            for (f, finger) in fingers.enumerated() {
                let joints = (1...4).compactMap { CharacterBase.joint("\(side)Hand\(finger.name)\($0)", in: c) }
                guard joints.count == 4 else { return nil }
                for k in 0..<3 {
                    let t0 = Float(k) / 3, t1 = Float(k + 1) / 3
                    var ra = (finger.base + (finger.tip - finger.base) * t0) * width
                    let rb = (finger.base + (finger.tip - finger.base) * t1) * width
                    var a = bind[joints[k]], b = bind[joints[k + 1]]
                    if k == 2 { b -= simd_normalize(b - a) * rb * 0.9 }   // the end joint is at the skin: the tip's round end ends there
                    if f == 0 && k == 0 { ra *= 1.25; a += (wrist - a) * 0.15 }   // the thumb's metacarpal, deep in the palm
                    segments.append(Segment(a: a, b: b, ra: ra, rb: rb, joint: joints[k], finger: f))
                }
            }
            self.segments = segments
            let w = wrist
            reach = segments.map { max(simd_length($0.a - w), simd_length($0.b - w)) + $0.ra }.max()! + 0.04
        }

        /// The body's own hand: past a plane 2 cm beyond the wrist.
        func cut(_ p: SIMD3<Float>) -> Float { simd_dot(p - wrist, along) - 0.02 }

        func palm(_ p: SIMD3<Float>) -> Float {
            let q = frame.transpose * (p - palmCentre)
            // Narrower toward the wrist, and thinner at the knuckles.
            let t = min(max(q.x / palmHalf.x * 0.5 + 0.5, 0), 1)
            let half = SIMD3(palmHalf.x, palmHalf.y * (1.05 - 0.15 * t), palmHalf.z * (0.72 + 0.28 * t))
            return CharacterBase.roundedBox(q, half, palmRounding)
        }

        func wristPiece(_ p: SIMD3<Float>) -> Float {
            let q = frame.transpose * (p - wrist)
            // An elliptical cylinder from 6 cm up the forearm (within it) to the palm.
            let along = simd_dot(p - wrist, self.along)
            let across = SIMD2(q.y / wristRadius.x, q.z / wristRadius.y)
            let r = (simd_length(across) - 1) * min(wristRadius.x, wristRadius.y)
            return max(r, max(-0.06 - along, along - 0.025))
        }

        func distance(_ p: SIMD3<Float>) -> Float {
            var d = CharacterBase.smoothMin(palm(p), wristPiece(p), 0.015)
            for s in segments {
                let f = CharacterBase.roundCone(p, s.a, s.b, s.ra, s.rb)
                // The thumb's metacarpal melts into the palm; the fingers meet it at their knuckles.
                d = CharacterBase.smoothMin(d, f, s.finger == 0 && s.a == segments[0].a ? 0.018 : 0.005)
            }
            return d
        }

        /// The hand's bones' weights at `p`: the nearest bone, blended with its finger's neighbours and the palm's.
        func weights(_ p: SIMD3<Float>) -> [(joint: Int, weight: Float)] {
            var near: [(joint: Int, finger: Int, d: Float)] = [(hand, -1, palm(p))]
            for s in segments { near.append((s.joint, s.finger, CharacterBase.roundCone(p, s.a, s.b, s.ra, s.rb))) }
            let best = near.min { $0.d < $1.d }!
            // Only the palm and the nearest bone's own finger blend (not the finger beside it).
            let kept = near.filter { $0.finger == -1 || $0.finger == best.finger }
            let sigma: Float = 0.004
            var out = kept.map { (joint: $0.joint, weight: exp(-($0.d - best.d) / sigma)) }
            out.sort { $0.weight > $1.weight }
            out = Array(out.prefix(4))
            let sum = out.reduce(0) { $0 + $1.weight }
            return out.map { ($0.joint, $0.weight / sum) }
        }
    }

    // MARK: The trunk

    /// The trunk as a loft of rounded cross-sections (superellipses) from the crotch to the base of the neck, each
    /// station's half width and front and back as a man's (or a woman's) are on average, fitted to the rig: the Y Bot's
    /// own trunk is a mannequin's (a narrow waist, a deep pelvis, panels), its limbs, neck and head are kept
    /// (`limbZone`).
    struct TrunkLoft {
        /// (height, half width, front, back) in metres, at a Y Bot's size (1.8 m, crotch at 0.84, neck at 1.5).
        typealias Station = (y: Float, w: Float, front: Float, back: Float)
        /// At its ends (the crotch, the shoulders, the neck) as wide and deep as the Y Bot is there, so that the two
        /// meet without a step; between them a man's average proportions (a wider waist and chest, a shallower pelvis).
        static let male: [Station] = [
            (0.84, 0.172, 0.06, -0.06), (0.88, 0.172, 0.095, -0.10), (0.93, 0.17, 0.11, -0.14), (0.98, 0.165, 0.115, -0.148),
            (1.04, 0.158, 0.118, -0.13), (1.10, 0.15, 0.122, -0.11), (1.16, 0.148, 0.124, -0.095), (1.22, 0.15, 0.126, -0.095),
            (1.28, 0.156, 0.134, -0.105), (1.34, 0.165, 0.132, -0.112), (1.40, 0.175, 0.115, -0.118), (1.46, 0.168, 0.075, -0.115),
            (1.50, 0.135, 0.048, -0.105), (1.53, 0.095, 0.038, -0.09), (1.56, 0.06, 0.036, -0.072), (1.59, 0.052, 0.036, -0.066),
        ]
        /// A woman's: wider hips, a narrower waist, ribcage and shoulders, a fuller seat, a flatter belly.
        static let female: [Station] = [
            (0.84, 0.178, 0.058, -0.065), (0.88, 0.18, 0.09, -0.11), (0.93, 0.182, 0.10, -0.152), (0.98, 0.178, 0.10, -0.155),
            (1.04, 0.155, 0.102, -0.13), (1.10, 0.13, 0.103, -0.1), (1.16, 0.127, 0.106, -0.088), (1.22, 0.132, 0.11, -0.09),
            (1.28, 0.14, 0.115, -0.097), (1.34, 0.149, 0.115, -0.103), (1.40, 0.158, 0.1, -0.108), (1.46, 0.152, 0.066, -0.105),
            (1.50, 0.122, 0.044, -0.096), (1.53, 0.086, 0.035, -0.082), (1.56, 0.054, 0.033, -0.066), (1.59, 0.047, 0.033, -0.06),
        ]
        let stations: [Station]
        let exponent: Float = 2.1
        /// Where the Y Bot's parts start: its arms beyond `armX` above `armY`, its legs below `legY`, its neck above
        /// `neckY` (within `neckX` of the middle). How much of the trunk is the loft's at most.
        let armX: Float, armY: Float, legY: Float, neckY: Float, neckX: Float
        static let share: Float = 0.8
        /// Breasts (a woman's): two ellipsoids on the chest, centres and radii.
        let breasts: [(centre: SIMD3<Float>, radii: SIMD3<Float>)]

        init(_ c: SkinnedCharacter, female: Bool) {
            let bind = CharacterBase.bindPositions(c)
            func at(_ n: String) -> SIMD3<Float> { bind[CharacterBase.joint(n, in: c) ?? 0] }
            // Heights from the crotch (a hip joint less 9 cm) to the neck, widths by the shoulders.
            let crotch = at("LeftUpLeg").y - 0.09, neck = at("Neck").y
            let heightScale = (neck - crotch) / (1.5 - 0.84)
            let widthScale = abs(at("LeftArm").x - at("RightArm").x) / 0.375
            let depthOffset = at("Spine1").z + 0.0265
            stations = (female ? TrunkLoft.female : TrunkLoft.male).map { s in
                (crotch + (s.y - 0.84) * heightScale, s.w * widthScale, s.front * heightScale + depthOffset, s.back * heightScale + depthOffset)
            }
            armX = 0.15 * widthScale
            armY = crotch + 0.46 * heightScale
            legY = crotch + 0.05 * heightScale
            neckY = neck + 0.03 * heightScale
            neckX = 0.08 * widthScale
            breasts = female ? [-1, 1].map { (side: Float) in
                (SIMD3(side * 0.082 * widthScale, crotch + 0.42 * heightScale, depthOffset + 0.07 * heightScale),
                 SIMD3(0.066 * widthScale, 0.06 * heightScale, 0.05 * heightScale))
            } : []
        }

        /// A station's values at height `y` (Catmull-Rom between stations, held beyond the ends).
        func section(_ y: Float) -> Station {
            let s = stations
            guard y > s[0].y else { return s[0] }
            guard y < s[s.count - 1].y else { return s[s.count - 1] }
            var k = 0
            while k < s.count - 2 && s[k + 1].y <= y { k += 1 }
            let t = (y - s[k].y) / (s[k + 1].y - s[k].y)
            let a = s[max(k - 1, 0)], b = s[k], c = s[k + 1], d = s[min(k + 2, s.count - 1)]
            func cr(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float) -> Float {
                let t2 = t * t, t3 = t2 * t
                return 0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3)
            }
            return (y, cr(a.w, b.w, c.w, d.w), cr(a.front, b.front, c.front, d.front), cr(a.back, b.back, c.back, d.back))
        }

        func distance(_ p: SIMD3<Float>) -> Float {
            let s = section(p.y)
            let centre = (s.front + s.back) / 2, half = (s.front - s.back) / 2
            let qx = abs(p.x) / s.w, qz = abs(p.z - centre) / half
            let n = exponent
            let r = pow(pow(qx, n) + pow(qz, n), 1 / n)
            var d: Float
            if r < 1e-6 { d = -min(s.w, half) } else {
                // (r - 1) over its gradient's length: the distance to first order.
                let k = pow(r, 1 - n)
                let gx = k * pow(qx, n - 1) / s.w, gz = k * pow(qz, n - 1) / half
                d = (r - 1) / max((gx * gx + gz * gz).squareRoot(), 1e-6)
            }
            // Rounded off below (the buttocks' underside, into the thighs) and closed above the neck's base.
            d = -CharacterBase.smoothMin(-d, p.y - stations[0].y + 0.02, 0.06)   // a smooth max with a plane below
            d = max(d, p.y - stations[stations.count - 1].y)
            return d
        }

        /// The breasts' distance (a woman's loft's; infinite for a man's).
        func breastDistance(_ p: SIMD3<Float>) -> Float {
            var d = Float.infinity
            for b in breasts {
                let q = (p - b.centre) / b.radii
                d = min(d, (simd_length(q) - 1) * b.radii.min())
            }
            return d
        }

        /// How much of the body at `p` is the loft's (0: the Y Bot's own, its arms, legs, neck and head; up to `share`
        /// on the trunk), easing over 4 to 6 cm where they meet.
        func trunkness(_ p: SIMD3<Float>) -> Float {
            func ease(_ a: Float, _ b: Float, _ x: Float) -> Float {
                let t = min(max((x - a) / (b - a), 0), 1)
                return t * t * (3 - 2 * t)
            }
            // (Over the shoulders the Y Bot's from nearer the neck: its shoulder caps are a mannequin's best part.)
            let x0 = armX - (armX - neckX) * ease(armY + 0.06, armY + 0.15, p.y)
            let arm = ease(x0 - 0.03, x0 + 0.03, abs(p.x)) * ease(armY - 0.06, armY + 0.02, p.y)
            let leg = 1 - ease(legY - 0.06, legY + 0.04, p.y)
            let neck = ease(neckY - 0.04, neckY + 0.01, p.y) * (1 - ease(neckX, neckX + 0.04, abs(p.x)))
            return TrunkLoft.share * (1 - max(arm, leg, neck))
        }
    }

    // MARK: Building

    /// The base made from `source` (the Y Bot, or any character of a Mixamo rig). nil if it hasn't the joints.
    static func build(_ source: SkinnedCharacter, options: Options = Options()) -> CharacterBase? {
        guard let rig = CharacterRig(source), let face = FaceSculpt(source) else { return nil }
        let start = CFAbsoluteTimeGetCurrent()
        let level = source.level(0)
        let body = BodySurface((level.positions, level.normals, level.indices), cell: options.surfaceCell,
                               smoothing: options.smoothing, solids: MuscleAtlas.boneSolids(rig))
        guard let left = Hand(source, side: "Left", body: body), let right = Hand(source, side: "Right", body: body) else { return nil }
        let hands = [left, right]
        let surfaced = CFAbsoluteTimeGetCurrent()
        let loft = TrunkLoft(source, female: false)
        func distance(_ p: SIMD3<Float>) -> Float {
            // The head and neck the sculpt's; on the trunk mostly the loft, on the limbs the Y Bot.
            let h = face.headness(p)
            if h >= 1 { return face.distance(p) }
            let t = loft.trunkness(p)
            var d = body.distance(p)
            if t > 0 { d += (loft.distance(p) - d) * t }
            for hand in hands where simd_length_squared(p - hand.wrist) < hand.reach * hand.reach {
                d = smoothMin(max(d, hand.cut(p)), hand.distance(p), 0.02)
            }
            if h > 0 { d += (face.distance(p) - d) * h }
            return d
        }
        func gradient(_ p: SIMD3<Float>, _ size: Float, _ f: (SIMD3<Float>) -> Float) -> SIMD3<Float> {
            let h = size * 0.25
            return SIMD3(f(p + [h, 0, 0]) - f(p - [h, 0, 0]), f(p + [0, h, 0]) - f(p - [0, h, 0]), f(p + [0, 0, h]) - f(p - [0, 0, h])) / (2 * h)
        }
        // The body below a cut across the neck, the head above it (finer): each closed off a little past the cut,
        // meshed, cut there, simplified (their open edges stay), then sewn together.
        let cut = face.world([0, 1.552, 0]).y
        let below: (SIMD3<Float>) -> Float = { p in max(distance(p), p.y - cut - 0.008) }
        let above: (SIMD3<Float>) -> Float = { p in max(distance(p), cut - 0.006 - p.y) }
        let box = level.positions.reduce(AABB()) { var b = $0; b.grow($1); return b }
        let size = options.cell
        let lo = box.lo - SIMD3(repeating: 0.03)
        let counts = SIMD3<Int>(((SIMD3(box.hi.x, cut + 0.02, box.hi.z) - lo + 0.03) / size).rounded(.up)) &+ 1
        var (positions, indices) = SurfaceNets.sparseMesh(lo: lo, size: size, counts: counts, distance: below,
                                                          gradient: { gradient($0, size, below) })
        (positions, indices) = largestPart(positions, indices)
        (positions, indices) = clipped(positions, indices) { $0 < cut }
        let headLo = face.world([-0.125, 1.536, -0.15]), headHi = face.world([0.125, 1.83, 0.17])
        let headSize = options.headCell * face.scale
        var (headPositions, headIndices) = SurfaceNets.sparseMesh(lo: headLo, size: headSize,
                                                                  counts: SIMD3<Int>(((headHi - headLo) / headSize).rounded(.up)) &+ 1,
                                                                  distance: above, gradient: { gradient($0, headSize, above) })
        (headPositions, headIndices) = largestPart(headPositions, headIndices)
        (headPositions, headIndices) = clipped(headPositions, headIndices) { $0 >= cut }
        let meshed = CFAbsoluteTimeGetCurrent()
        (positions, indices) = simplified(positions, indices, to: options.triangles - options.headTriangles)
        // Kept at full detail: where the lips' and brows' colours end (their edges stay smooth curves), and where the
        // surface bends sharply (the rims of the ears, the lids' edges, the nostrils, the lips' parting), which the
        // simplifier would otherwise flatten.
        let kinds = headPositions.map { FaceParts.skinMaterial(face.local($0)) }
        let headRing = neighbours(headPositions.count, headIndices)
        let headNormals = headPositions.map { p -> SIMD3<Float> in
            let g = gradient(p, headSize, above)
            return simd_length_squared(g) > 0 ? simd_normalize(g) : [0, 1, 0]
        }
        let sharp = cos(Float(24) * .pi / 180)
        let kept = headPositions.indices.map { v in
            headRing[v].contains { kinds[Int($0)] != kinds[v] || simd_dot(headNormals[Int($0)], headNormals[v]) < sharp }
        }
        (headPositions, headIndices) = simplified(headPositions, headIndices, to: options.headTriangles, locked: kept)
        (positions, indices) = stitched((positions, indices), (headPositions, headIndices), at: cut)
        // Smoothed without shrinking (Taubin): the grid's ripples and what is left of the panels' seams go. The
        // fingers are left as they are (a finger is only a few cells across), and the face (its details are fine).
        let fixed = positions.map { p in
            hands.contains { h in h.cut(p) > -0.01 && simd_length(p - h.wrist) < h.reach } || face.local(p).y > 1.575
        }
        let ring = neighbours(positions.count, indices)
        positions = taubin(positions, ring, fixed: fixed, iterations: options.smoothingPasses)
        // The trunk, and where it meets the limbs, more.
        let joins = positions.map { p in loft.trunkness(p) < 0.05 }
        positions = taubin(positions, ring, fixed: joins, iterations: options.trunkPasses)
        // The face a little: the grid's terraces.
        positions = taubin(positions, ring, fixed: positions.map { face.local($0).y < 1.575 }, iterations: 2)
        let normals = vertexNormals(positions, indices)
        let simplifiedAt = CFAbsoluteTimeGetCurrent()

        var skin = transferWeights(positions, normals, indices, from: level, hands: hands, jointCount: source.joints.count)
        // The face and skull on the head's bone alone (there is no jaw bone: the jaw opens by a morph).
        if let head = joint("Head", in: source) {
            for v in skin.indices {
                let q = face.local(positions[v])
                let t = max(FaceSculpt.smoothstep(1.60, 1.64, q.y), FaceSculpt.smoothstep(1.575, 1.595, q.y) * FaceSculpt.smoothstep(-0.02, 0.01, q.z))
                if t > 0 { skin[v] = blended(skin[v], toward: head, by: t) }
            }
        }
        var c = source
        c.name = "Generated"
        c.positions = positions
        c.normals = normals
        c.uvs = [SIMD2<Float>](repeating: .zero, count: positions.count)
        c.indices = indices
        c.skin = skin
        c.coarser = []
        c.clips = []
        c.color = [0.8, 0.62, 0.52]
        var regions = CharacterBase.regions(c)
        var materials = positions.map { p -> UInt8 in
            let q = face.local(p)
            return q.y > 1.55 ? FaceParts.skinMaterial(q).rawValue : FaceParts.Material.skin.rawValue
        }
        // The eyeballs, teeth and tongue: meshes of their own, on the head's bone.
        let headJoint = UInt32(joint("Head", in: source) ?? 0)
        let parts: [(FaceParts.Mesh, Region)] = [(FaceParts.eyeball(centre: face.eyes[0], scale: face.scale), .leftEye),
                                                 (FaceParts.eyeball(centre: face.eyes[1], scale: face.scale), .rightEye),
                                                 (FaceParts.teeth(face, upper: true), .upperTeeth),
                                                 (FaceParts.teeth(face, upper: false), .lowerTeeth),
                                                 (FaceParts.tongue(face), .tongue)]
        for (part, region) in parts {
            // A vertex where two materials meet is one for each (the simplifier keeps the seam: CharacterImporter.coarser).
            var copies: [Int: [UInt8: UInt32]] = [:]
            for (t, m) in part.materials.enumerated() {
                for k in 0..<3 {
                    let v = Int(part.indices[3 * t + k])
                    if let made = copies[v]?[m.rawValue] { c.indices.append(made); continue }
                    let index = UInt32(c.positions.count)
                    copies[v, default: [:]][m.rawValue] = index
                    c.positions.append(part.positions[v])
                    c.normals.append(part.normals[v])
                    c.uvs.append(SIMD2(Float(m.rawValue), 0))
                    c.skin.append(GPUSkinVertex(joints: headJoint, w0: 1, w1: 0, w2: 0))
                    regions.append(region.rawValue)
                    materials.append(m.rawValue)
                    c.indices.append(index)
                }
            }
        }
        c.materials = triangleMaterials(c.indices, materials)
        (c.boundsMin, c.boundsMax) = CharacterImporter.bounds(of: c)
        let done = CFAbsoluteTimeGetCurrent()
        print(String(format: "Character base: %d vertices, %d triangles from %@ (surface %.0f ms, meshed %.0f ms, simplified %.0f ms, skinned %.0f ms)",
                     c.positions.count, c.indices.count / 3, source.name, (surfaced - start) * 1000, (meshed - surfaced) * 1000,
                     (simplifiedAt - meshed) * 1000, (done - simplifiedAt) * 1000))
        return CharacterBase(character: c, regions: regions, materials: materials)
    }

    /// Each triangle's material: the one most of its corners have (the first corner's if they all differ).
    static func triangleMaterials(_ indices: [UInt32], _ materials: [UInt8], source: [UInt32]? = nil) -> [UInt8] {
        stride(from: 0, to: indices.count, by: 3).map { t in
            let m = (0..<3).map { k -> UInt8 in
                let v = Int(indices[t + k])
                return materials[source.map { Int($0[v]) } ?? v]
            }
            return m[1] == m[2] ? m[1] : m[0]
        }
    }

    /// `skin` moved toward the joint `j` alone by `t` (0...1), the four heaviest kept.
    static func blended(_ skin: GPUSkinVertex, toward j: Int, by t: Float) -> GPUSkinVertex {
        let ws = [skin.w0, skin.w1, skin.w2, 1 - skin.w0 - skin.w1 - skin.w2]
        var w: [Int: Float] = [:]
        for k in 0..<4 where ws[k] > 0 { w[Int((skin.joints >> UInt32(8 * k)) & 0xFF), default: 0] += ws[k] * (1 - t) }
        w[j, default: 0] += t
        let row = w.sorted { $0.value > $1.value }.prefix(4)
        let sum = row.reduce(0) { $0 + $1.value }
        let joints = row.map { UInt32($0.key) } + [UInt32](repeating: UInt32(row.first!.key), count: 4 - row.count)
        let weights = row.map { $0.value / sum } + [Float](repeating: 0, count: 4 - row.count)
        return GPUSkinVertex(joints: joints[0] | joints[1] << 8 | joints[2] << 16 | joints[3] << 24, w0: weights[0], w1: weights[1], w2: weights[2])
    }

    /// The triangles of a mesh whose middles' heights `keep` accepts, vertices renumbered.
    static func clipped(_ positions: [SIMD3<Float>], _ indices: [UInt32], keep: (Float) -> Bool) -> ([SIMD3<Float>], [UInt32]) {
        var remap = [Int32](repeating: -1, count: positions.count)
        var outP: [SIMD3<Float>] = [], outI: [UInt32] = []
        for t in stride(from: 0, to: indices.count, by: 3) {
            let y = (positions[Int(indices[t])].y + positions[Int(indices[t + 1])].y + positions[Int(indices[t + 2])].y) / 3
            guard keep(y) else { continue }
            for k in 0..<3 {
                let v = Int(indices[t + k])
                if remap[v] < 0 { remap[v] = Int32(outP.count); outP.append(positions[v]) }
                outI.append(UInt32(remap[v]))
            }
        }
        return (outP, outI)
    }

    /// Two meshes made one: each has an open edge round the same upright tube at height `y` (the neck, cut), each
    /// edge's loop is laid flat at that height and a strip of triangles sews the two round, the shorter way across at
    /// every step.
    static func stitched(_ a: ([SIMD3<Float>], [UInt32]), _ b: ([SIMD3<Float>], [UInt32]), at y: Float) -> ([SIMD3<Float>], [UInt32]) {
        var positions = a.0 + b.0
        var indices = a.1 + b.1.map { $0 + UInt32(a.0.count) }
        // Open edges (one triangle), in their triangles' direction.
        var count: [UInt64: Int] = [:]
        for t in stride(from: 0, to: indices.count, by: 3) {
            for k in 0..<3 {
                let u = UInt64(indices[t + k]), v = UInt64(indices[t + (k + 1) % 3])
                count[min(u, v) << 32 | max(u, v), default: 0] += 1
            }
        }
        var next: [UInt32: UInt32] = [:]
        for t in stride(from: 0, to: indices.count, by: 3) {
            for k in 0..<3 {
                let u = indices[t + k], v = indices[t + (k + 1) % 3]
                if count[UInt64(min(u, v)) << 32 | UInt64(max(u, v))] == 1 { next[u] = v }
            }
        }
        // The loops; each mesh's longest is its cut.
        var loops: [[UInt32]] = [], seen = Set<UInt32>()
        for start in next.keys.sorted() where !seen.contains(start) {
            var loop: [UInt32] = [], v = start
            while !seen.contains(v), let n = next[v] { seen.insert(v); loop.append(v); v = n }
            if v == start { loops.append(loop) }
        }
        let split = UInt32(a.0.count)
        guard let la = loops.filter({ $0[0] < split }).max(by: { $0.count < $1.count }),
              let lb = loops.filter({ $0[0] >= split }).max(by: { $0.count < $1.count }) else { return (positions, indices) }
        for v in la + lb { positions[Int(v)].y = y }
        let centre = la.reduce(SIMD3<Float>()) { $0 + positions[Int($1)] } / Float(la.count)
        func angle(_ v: UInt32) -> Float { atan2(positions[Int(v)].z - centre.z, positions[Int(v)].x - centre.x) }
        // Both walked the same way round (increasing angle); `forward`: whether that is the loop's own direction.
        func ordered(_ loop: [UInt32]) -> ([UInt32], Bool) {
            var turn: Float = 0
            for k in loop.indices {
                var d = angle(loop[(k + 1) % loop.count]) - angle(loop[k])
                if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
                turn += d
            }
            return turn > 0 ? (loop, true) : (loop.reversed(), false)
        }
        let (sa, fa) = ordered(la)
        var (sb, fb) = ordered(lb)
        let first = sb.indices.min { simd_distance(positions[Int(sb[$0])], positions[Int(sa[0])]) < simd_distance(positions[Int(sb[$1])], positions[Int(sa[0])]) }!
        sb = Array(sb[first...] + sb[..<first])
        // A triangle on an open edge (x, y) of a walk, and the vertex across: the edge the other way round.
        func add(_ x: UInt32, _ y: UInt32, _ w: UInt32, forward: Bool) { indices += forward ? [y, x, w] : [x, y, w] }
        var i = 0, j = 0
        while i < sa.count || j < sb.count {
            let a0 = sa[i % sa.count], a1 = sa[(i + 1) % sa.count], b0 = sb[j % sb.count], b1 = sb[(j + 1) % sb.count]
            let advanceA = j >= sb.count || (i < sa.count && simd_distance(positions[Int(a1)], positions[Int(b0)])
                                                < simd_distance(positions[Int(b1)], positions[Int(a0)]))
            if advanceA { add(a0, a1, b0, forward: fa); i += 1 } else { add(b0, b1, a0, forward: fb); j += 1 }
        }
        return (positions, indices)
    }

    /// Each vertex's part of the body, by the bone that moves it most.
    static func regions(_ c: SkinnedCharacter) -> [UInt8] {
        let names = c.jointNames.map { $0.replacingOccurrences(of: "mixamorig:", with: "") }
        let byJoint: [Region] = names.map { n in
            if n.contains("Hand") { return .hand }
            if n.contains("Head") { return .head }
            if n == "Neck" { return .neck }
            if n.contains("Arm") || n.contains("Shoulder") { return .arm }
            if n.contains("Foot") || n.contains("Toe") { return .foot }
            if n.contains("Leg") { return .leg }
            return .trunk
        }
        return c.skin.map { byJoint[Int($0.joints & 0xFF)].rawValue }
    }

    // MARK: Mesh helpers

    /// The largest connected piece of a mesh (surface nets leave specks where the field folds), its vertices renumbered.
    static func largestPart(_ positions: [SIMD3<Float>], _ indices: [UInt32]) -> ([SIMD3<Float>], [UInt32]) {
        var parent = Array(0..<Int32(positions.count))
        func find(_ x: Int32) -> Int32 {
            var x = x
            while parent[Int(x)] != x { parent[Int(x)] = parent[Int(parent[Int(x)])]; x = parent[Int(x)] }
            return x
        }
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = find(Int32(indices[t])), b = find(Int32(indices[t + 1])), c = find(Int32(indices[t + 2]))
            parent[Int(b)] = a
            parent[Int(find(c))] = a
        }
        var size: [Int32: Int] = [:]
        for t in stride(from: 0, to: indices.count, by: 3) { size[find(Int32(indices[t])), default: 0] += 1 }
        guard let keep = size.max(by: { $0.value < $1.value })?.key else { return ([], []) }
        var remap = [Int32](repeating: -1, count: positions.count)
        var outP: [SIMD3<Float>] = [], outI: [UInt32] = []
        for t in stride(from: 0, to: indices.count, by: 3) where find(Int32(indices[t])) == keep {
            for k in 0..<3 {
                let v = Int(indices[t + k])
                if remap[v] < 0 { remap[v] = Int32(outP.count); outP.append(positions[v]) }
                outI.append(UInt32(remap[v]))
            }
        }
        return (outP, outI)
    }

    /// The mesh simplified to about `target` triangles (MeshSimplifier's quadric edge collapses), vertices renumbered.
    /// `locked` vertices stay (and so their triangles).
    static func simplified(_ positions: [SIMD3<Float>], _ indices: [UInt32], to target: Int, locked: [Bool]? = nil) -> ([SIMD3<Float>], [UInt32]) {
        guard indices.count / 3 > target else { return (positions, indices) }
        let ids = Array(0..<Int32(positions.count))
        let uvs = [SIMD2<Float>](repeating: .zero, count: positions.count)
        let triangles = positions.withUnsafeBufferPointer { p in
            ids.withUnsafeBufferPointer { i in
                uvs.withUnsafeBufferPointer { u in
                    MeshSimplifier.simplify(triangles: indices, positions: p, posId: i, uvs: u, targetTriangles: target,
                                            locked: { locked?[Int($0)] ?? false }).triangles
                }
            }
        }
        var remap = [Int32](repeating: -1, count: positions.count)
        var outP: [SIMD3<Float>] = [], outI: [UInt32] = []
        for v in triangles {
            if remap[Int(v)] < 0 { remap[Int(v)] = Int32(outP.count); outP.append(positions[Int(v)]) }
            outI.append(UInt32(remap[Int(v)]))
        }
        return (outP, outI)
    }

    /// Taubin's smoothing (a step toward the neighbours' mean, then one back a little further): smooths without
    /// shrinking. `fixed` vertices stay.
    static func taubin(_ positions: [SIMD3<Float>], _ ring: [[Int32]], fixed: [Bool], iterations: Int,
                       lambda: Float = 0.5, mu: Float = -0.53) -> [SIMD3<Float>] {
        var a = positions, b = positions
        for _ in 0..<iterations {
            for factor in [lambda, mu] {
                a.withUnsafeBufferPointer { src in
                    b.withUnsafeMutableBufferPointer { out in
                        DispatchQueue.concurrentPerform(iterations: (src.count + 4095) / 4096) { chunk in
                            for v in (chunk * 4096)..<min(src.count, chunk * 4096 + 4096) {
                                guard !fixed[v], !ring[v].isEmpty else { out[v] = src[v]; continue }
                                var sum = SIMD3<Float>()
                                for u in ring[v] { sum += src[Int(u)] }
                                out[v] = src[v] + (sum / Float(ring[v].count) - src[v]) * factor
                            }
                        }
                    }
                }
                swap(&a, &b)
            }
        }
        return a
    }

    /// Area-weighted vertex normals.
    static func vertexNormals(_ positions: [SIMD3<Float>], _ indices: [UInt32]) -> [SIMD3<Float>] {
        var n = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let f = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            n[a] += f; n[b] += f; n[c] += f
        }
        return n.map { simd_length_squared($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }
    }

    /// Each vertex's neighbours (the vertices it shares a triangle with).
    static func neighbours(_ count: Int, _ indices: [UInt32]) -> [[Int32]] {
        var out = [[Int32]](repeating: [], count: count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            for k in 0..<3 {
                let a = Int(indices[t + k]), b = indices[t + (k + 1) % 3]
                if !out[a].contains(Int32(b)) { out[a].append(Int32(b)) }
                if !out[Int(b)].contains(Int32(a)) { out[Int(b)].append(Int32(a)) }
            }
        }
        return out
    }

    // MARK: Weights

    /// Each vertex's joints and weights: the Y Bot's skin at the point of it nearest the vertex that faces the same way
    /// (within 3 cm), the hands' from their bones; vertices with neither take their neighbours'; then smoothed, the four
    /// heaviest kept.
    static func transferWeights(_ positions: [SIMD3<Float>], _ normals: [SIMD3<Float>], _ indices: [UInt32],
                                from source: SkinnedCharacter.Level, hands: [Hand], jointCount: Int) -> [GPUSkinVertex] {
        let count = positions.count
        // The source's triangles in a grid of 2 cm cells.
        let cell: Float = 0.02, reach: Float = 0.03
        let box = source.positions.reduce(AABB()) { var b = $0; b.grow($1); return b }
        let lo = box.lo - reach
        let n = SIMD3<Int>(((box.hi - box.lo + 2 * reach) / cell).rounded(.up)) &+ 1
        func key(_ c: SIMD3<Int>) -> Int { (c.z * n.y + c.y) * n.x + c.x }
        var grid = [[Int32]](repeating: [], count: n.x * n.y * n.z)
        for t in 0..<(source.indices.count / 3) {
            let p = (0..<3).map { source.positions[Int(source.indices[3 * t + $0])] }
            let a = SIMD3<Int>(((simd_min(simd_min(p[0], p[1]), p[2]) - lo) / cell).rounded(.down))
            let b = SIMD3<Int>(((simd_max(simd_max(p[0], p[1]), p[2]) - lo) / cell).rounded(.down))
            for z in a.z...b.z { for y in a.y...b.y { for x in a.x...b.x { grid[key(SIMD3(x, y, z))].append(Int32(t)) } } }
        }
        // Dense weights per vertex, per joint (a few MB), for the smoothing.
        var dense = [Float](repeating: 0, count: count * jointCount)
        var known = [Bool](repeating: false, count: count)
        dense.withUnsafeMutableBufferPointer { w in
            known.withUnsafeMutableBufferPointer { k in
                DispatchQueue.concurrentPerform(iterations: count) { v in
                    let p = positions[v]
                    for h in hands where h.cut(p) > -0.005 && simd_length(p - h.wrist) < h.reach {
                        for (j, weight) in h.weights(p) { w[v * jointCount + j] = weight }
                        k[v] = true
                        return
                    }
                    let c = SIMD3<Int>(((p - lo) / cell).rounded(.down))
                    var best: (d: Float, t: Int, bc: SIMD2<Float>) = (reach, -1, .zero)
                    for z in max(c.z - 1, 0)...min(c.z + 1, n.z - 1) {
                        for y in max(c.y - 1, 0)...min(c.y + 1, n.y - 1) {
                            for x in max(c.x - 1, 0)...min(c.x + 1, n.x - 1) {
                                for t in grid[key(SIMD3(x, y, z))] {
                                    let i = Int(t)
                                    let a = source.positions[Int(source.indices[3 * i])], b = source.positions[Int(source.indices[3 * i + 1])],
                                        cc = source.positions[Int(source.indices[3 * i + 2])]
                                    let face = simd_cross(b - a, cc - a)
                                    guard simd_length_squared(face) > 1e-14, simd_dot(simd_normalize(face), normals[v]) > 0.3 else { continue }
                                    let (q, bc) = SkinShell.closest(p, a, b, cc)
                                    let d = simd_distance(p, q)
                                    if d < best.d { best = (d, i, bc) }
                                }
                            }
                        }
                    }
                    guard best.t >= 0 else { return }
                    let corner = [1 - best.bc.x - best.bc.y, best.bc.x, best.bc.y]
                    for k3 in 0..<3 {
                        let s = source.skin[Int(source.indices[3 * best.t + k3])]
                        let ws = [s.w0, s.w1, s.w2, 1 - s.w0 - s.w1 - s.w2]
                        for m in 0..<4 where ws[m] > 0 {
                            w[v * jointCount + Int((s.joints >> UInt32(8 * m)) & 0xFF)] += ws[m] * corner[k3]
                        }
                    }
                    k[v] = true
                }
            }
        }
        let ring = neighbours(count, indices)
        // The unknown take their known neighbours' mean, ring by ring.
        var unknown = known.indices.filter { !known[$0] }
        while !unknown.isEmpty {
            var filled: [Int] = []
            for v in unknown {
                let from = ring[v].filter { known[Int($0)] }
                guard !from.isEmpty else { continue }
                for j in 0..<jointCount { dense[v * jointCount + j] = from.reduce(0) { $0 + dense[Int($1) * jointCount + j] } / Float(from.count) }
                filled.append(v)
            }
            if filled.isEmpty { break }
            for v in filled { known[v] = true }
            unknown = unknown.filter { !known[$0] }
        }
        // Smoothed: each vertex halfway to its neighbours' mean, many times (the Y Bot's panels are each on one bone,
        // their seams sharp: a neck's skin there would tear as the head turns). The hands' weights are smooth already.
        let analytic = positions.map { p in hands.contains { h in h.cut(p) > -0.005 && simd_length(p - h.wrist) < h.reach } }
        var next = dense
        for _ in 0..<12 {
            next.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: count) { v in
                    let r = ring[v]
                    guard !r.isEmpty, !analytic[v] else { return }
                    for j in 0..<jointCount {
                        var sum: Float = 0
                        for u in r { sum += dense[Int(u) * jointCount + j] }
                        out[v * jointCount + j] = 0.5 * dense[v * jointCount + j] + 0.5 * sum / Float(r.count)
                    }
                }
            }
            swap(&dense, &next)
        }
        return (0..<count).map { v in
            let row = (0..<jointCount).map { (j: $0, w: dense[v * jointCount + $0]) }.filter { $0.w > 1e-4 }.sorted { $0.w > $1.w }.prefix(4)
            let sum = row.reduce(0) { $0 + $1.w }
            guard sum > 0 else { return GPUSkinVertex(joints: 0, w0: 1, w1: 0, w2: 0) }
            let j = row.map { UInt32($0.j) } + [UInt32](repeating: row.first.map { UInt32($0.j) } ?? 0, count: 4 - row.count)
            let w = row.map { $0.w / sum } + [Float](repeating: 0, count: 4 - row.count)
            return GPUSkinVertex(joints: j[0] | j[1] << 8 | j[2] << 16 | j[3] << 24, w0: w[0], w1: w[1], w2: w[2])
        }
    }

    // MARK: Distance functions

    static func smoothMin(_ a: Float, _ b: Float, _ k: Float) -> Float {
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k * 0.25
    }

    static func roundedBox(_ q: SIMD3<Float>, _ half: SIMD3<Float>, _ r: Float) -> Float {
        let d = simd_abs(q) - (half - r)
        return simd_length(simd_max(d, .zero)) + min(max(d.x, max(d.y, d.z)), 0) - r
    }

    /// A cone between two spheres (centres `a`, `b`, radii `ra`, `rb`), its sides tangent to both (Quílez's round cone).
    static func roundCone(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ ra: Float, _ rb: Float) -> Float {
        let ba = b - a
        let l2 = simd_dot(ba, ba)
        guard l2 > 1e-12 else { return simd_length(p - a) - max(ra, rb) }
        let rr = ra - rb, a2 = l2 - rr * rr, il2 = 1 / l2
        let pa = p - a, y = simd_dot(pa, ba), z = y - l2
        let xv = pa * l2 - ba * y
        let x2 = simd_dot(xv, xv), y2 = y * y * l2, z2 = z * z * l2
        let k = (rr >= 0 ? 1 : -1) * rr * rr * x2
        if (z >= 0 ? 1 : -1) * a2 * z2 > k { return (x2 + z2).squareRoot() * il2 - rb }
        if (y >= 0 ? 1 : -1) * a2 * y2 < k { return (x2 + y2).squareRoot() * il2 - ra }
        return ((x2 * a2 * il2).squareRoot() + y * rr) * il2 - ra
    }
}
