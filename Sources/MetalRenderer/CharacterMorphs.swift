import Foundation
import simd

/// The base body's morph targets (CharacterBase): each a sparse list of vertices and how far each moves at weight 1.
/// A character's mesh is the base plus the sum of its targets' deltas times their weights (CharacterBuilder), before
/// its skeleton is reshaped.
///
/// The targets are generated, not sculpted. Most are bumps on the body's own coordinates (Coordinates: what bone a
/// vertex is on, how far along it, at what angle round it): fat where men and women carry it, muscles where they bulge,
/// sagging with age. One is measured: "sex", the X Bot's skin (Mixamo's female mannequin) less the Y Bot's, with the
/// X Bot's skeleton as `sexOffsets`.
struct CharacterMorphs {
    struct Target {
        var name: String
        var vertices: [UInt32]
        var deltas: [SIMD3<Float>]
    }

    var targets: [Target]
    /// Per joint: its bind position's offset from its parent's in the X Bot, less the Y Bot's (world space; zero where
    /// there is no X Bot, or for the root).
    var sexOffsets: [SIMD3<Float>]

    func index(_ name: String) -> Int? { targets.firstIndex { $0.name == name } }

    // MARK: Body coordinates

    enum Part: UInt8 { case trunk, neck, head, upperArm, forearm, hand, thigh, shin, foot }

    /// Where each vertex is on the body: its part, how far along it (`u`: 0 at the part's first joint, 1 at its
    /// next; the trunk's from the hips to the neck), and at what angle round it (degrees, 0 = ahead; the trunk's
    /// toward its own side, 90 at the side, 180 behind; an arm's 90 on top in the T pose (its outside), -90
    /// beneath; a leg's 90 outside, -90 inside).
    struct Coordinates {
        var part: [Part]
        var u: [Float]
        var angle: [Float]

        init(_ c: SkinnedCharacter) {
            let bind = CharacterBase.bindPositions(c)
            func j(_ name: String) -> Int { CharacterBase.joint(name, in: c) ?? 0 }
            let names = c.jointNames.map { $0.replacingOccurrences(of: "mixamorig:", with: "") }
            let trunk = ["Hips", "Spine", "Spine1", "Spine2", "Neck"].map { bind[j($0)] }
            var lengths: [Float] = [0]
            for k in 1..<trunk.count { lengths.append(lengths[k - 1] + simd_length(trunk[k] - trunk[k - 1])) }
            let total = lengths.last!
            // Per joint: its part, and the segment it measures along.
            func segment(_ name: String) -> (Part, String, String)? {
                for side in ["Left", "Right"] {
                    if name == "\(side)Arm" { return (.upperArm, "\(side)Arm", "\(side)ForeArm") }
                    if name == "\(side)ForeArm" { return (.forearm, "\(side)ForeArm", "\(side)Hand") }
                    if name.hasPrefix("\(side)Hand") { return (.hand, "\(side)Hand", "\(side)HandMiddle4") }
                    if name == "\(side)UpLeg" { return (.thigh, "\(side)UpLeg", "\(side)Leg") }
                    if name == "\(side)Leg" { return (.shin, "\(side)Leg", "\(side)Foot") }
                    if name == "\(side)Foot" || name.hasPrefix("\(side)Toe") { return (.foot, "\(side)Foot", "\(side)Toe_End") }
                }
                if name == "Neck" { return (.neck, "Neck", "Head") }
                if name.hasPrefix("Head") { return (.head, "Head", "HeadTop_End") }
                return nil
            }
            let byJoint = names.map(segment)
            part = []; u = []; angle = []
            for (p, s) in zip(c.positions, c.skin) {
                let joint = Int(s.joints & 0xFF)
                if let (kind, from, to) = byJoint[joint] {
                    let a = bind[j(from)], b = bind[j(to)], axis = simd_normalize(b - a)
                    let t = simd_dot(p - a, axis) / simd_length(b - a)
                    var r = p - a - axis * simd_dot(p - a, axis)
                    r = simd_length_squared(r) > 1e-12 ? simd_normalize(r) : SIMD3(0, 0, 1)
                    var front = SIMD3<Float>(0, 0, 1) - axis * axis.z
                    front = simd_length_squared(front) > 1e-6 ? simd_normalize(front) : SIMD3(0, 1, 0)
                    let outward: SIMD3<Float>
                    switch kind {
                    case .upperArm, .forearm, .hand: outward = [0, 1, 0]
                    case .thigh, .shin, .foot: outward = [a.x >= 0 ? 1 : -1, 0, 0]
                    default: outward = [p.x >= 0 ? 1 : -1, 0, 0]
                    }
                    var side = outward - axis * simd_dot(outward, axis) - front * simd_dot(outward, front)
                    side = simd_length_squared(side) > 1e-6 ? simd_normalize(side) : simd_cross(axis, front)
                    part.append(kind)
                    u.append(t)
                    angle.append(atan2(simd_dot(r, side), simd_dot(r, front)) * 180 / .pi)
                } else {
                    // The trunk: along the line from the hips to the neck (before the hips: negative), round it toward
                    // the vertex's own side.
                    var best = (d: Float.infinity, h: Float(0), axis: SIMD3<Float>(0, 1, 0), at: trunk[0])
                    for k in 0..<(trunk.count - 1) {
                        let a = trunk[k], b = trunk[k + 1], len = simd_length(b - a), axis = (b - a) / len
                        let t = simd_dot(p - a, axis)
                        let tc = k == 0 ? min(t, len) : min(max(t, 0), len)
                        let q = a + axis * tc
                        let d = simd_distance(p, q)
                        if d < best.d { best = (d, (lengths[k] + (k == 0 ? min(t, len) : tc)) / total, axis, q) }
                    }
                    let r = p - best.at
                    part.append(.trunk)
                    u.append(best.h)
                    angle.append(atan2(abs(r.x), r.z) * 180 / .pi)
                }
            }
        }
    }

    // MARK: Bumps

    /// A smooth bump on one part: centred at `u` (spread `du`) and `angle` (spread `da`, degrees), moving the skin out
    /// along its normal by `out` and down by `down` (m) at its middle. `da` 0: all round.
    struct Bump {
        var part: Part
        var u: Float
        var du: Float
        var angle: Float = 0
        var da: Float = 0
        var out: Float
        var down: Float = 0
    }

    /// Every part but the head, hands and feet, moved out by `out`.
    static func all(_ out: Float) -> [Bump] {
        [Bump(part: .trunk, u: 0.4, du: 2, out: out), Bump(part: .neck, u: 0.5, du: 2, out: out),
         Bump(part: .upperArm, u: 0.5, du: 2, out: out), Bump(part: .forearm, u: 0.3, du: 1, out: out * 0.6),
         Bump(part: .thigh, u: 0.5, du: 2, out: out), Bump(part: .shin, u: 0.4, du: 1, out: out * 0.6)]
    }

    /// The generated targets: name and bumps.
    static let bumpTargets: [(name: String, bumps: [Bump])] = [
        ("fatMale", all(0.006) + [
            Bump(part: .trunk, u: 0.3, du: 0.2, angle: 0, da: 75, out: 0.045, down: 0.006),
            Bump(part: .trunk, u: 0.22, du: 0.1, angle: 100, da: 35, out: 0.018),
            Bump(part: .trunk, u: 0.72, du: 0.1, angle: 20, da: 40, out: 0.014),
            Bump(part: .trunk, u: 0.32, du: 0.2, angle: 180, da: 50, out: 0.01),
            Bump(part: .upperArm, u: 0.5, du: 0.6, angle: 180, da: 90, out: 0.01),
            Bump(part: .thigh, u: 0.25, du: 0.4, out: 0.012),
            Bump(part: .thigh, u: 0.2, du: 0.3, angle: -90, da: 50, out: 0.006),
            Bump(part: .neck, u: 0.3, du: 0.6, angle: 0, da: 80, out: 0.012),
        ]),
        ("fatFemale", all(0.006) + [
            Bump(part: .trunk, u: 0.2, du: 0.13, angle: 0, da: 70, out: 0.025, down: 0.004),
            Bump(part: .trunk, u: 0.06, du: 0.14, angle: 95, da: 45, out: 0.028),
            Bump(part: .trunk, u: 0.02, du: 0.12, angle: 180, da: 50, out: 0.03),
            Bump(part: .thigh, u: 0.22, du: 0.45, angle: 90, da: 70, out: 0.028),
            Bump(part: .thigh, u: 0.25, du: 0.35, angle: -90, da: 45, out: 0.012),
            Bump(part: .upperArm, u: 0.4, du: 0.5, angle: 180, da: 80, out: 0.012),
            Bump(part: .trunk, u: 0.73, du: 0.07, angle: 28, da: 30, out: 0.014),
        ]),
        ("thin", all(-0.005) + [
            Bump(part: .trunk, u: 0.32, du: 0.18, angle: 0, da: 80, out: -0.012),
            Bump(part: .trunk, u: 0.3, du: 0.2, angle: 95, da: 40, out: -0.008),
            Bump(part: .thigh, u: 0.3, du: 0.4, out: -0.004),
        ]),
        ("muscle", all(0.002) + [
            Bump(part: .upperArm, u: 0.08, du: 0.22, angle: 80, da: 85, out: 0.013),
            Bump(part: .upperArm, u: 0.55, du: 0.22, angle: 0, da: 50, out: 0.012),
            Bump(part: .upperArm, u: 0.42, du: 0.25, angle: 180, da: 50, out: 0.01),
            Bump(part: .forearm, u: 0.22, du: 0.25, out: 0.006),
            Bump(part: .trunk, u: 0.76, du: 0.08, angle: 32, da: 35, out: 0.014),
            Bump(part: .trunk, u: 0.62, du: 0.14, angle: 128, da: 30, out: 0.012),
            Bump(part: .trunk, u: 0.97, du: 0.07, angle: 150, da: 50, out: 0.012),
            Bump(part: .neck, u: 0.15, du: 0.4, angle: 150, da: 60, out: 0.012),
            Bump(part: .trunk, u: 0.45, du: 0.14, angle: 0, da: 25, out: 0.004),
            Bump(part: .trunk, u: 0.0, du: 0.1, angle: 180, da: 40, out: 0.012),
            Bump(part: .thigh, u: 0.5, du: 0.35, angle: 15, da: 50, out: 0.014),
            Bump(part: .thigh, u: 0.5, du: 0.35, angle: 180, da: 45, out: 0.008),
            Bump(part: .shin, u: 0.28, du: 0.2, angle: 180, da: 55, out: 0.012),
            Bump(part: .neck, u: 0.5, du: 2, out: 0.006),
        ]),
        ("slight", all(-0.003) + [
            Bump(part: .upperArm, u: 0.08, du: 0.22, angle: 80, da: 85, out: -0.006),
            Bump(part: .trunk, u: 0.76, du: 0.08, angle: 32, da: 35, out: -0.005),
        ]),
        ("age", [
            Bump(part: .trunk, u: 0.2, du: 0.12, angle: 0, da: 60, out: 0.012, down: 0.01),
            Bump(part: .trunk, u: 0.72, du: 0.08, angle: 25, da: 35, out: -0.003, down: 0.012),
            Bump(part: .upperArm, u: 0.45, du: 0.4, angle: -150, da: 60, out: 0.004, down: 0.006),
            Bump(part: .thigh, u: 0.5, du: 0.5, out: -0.003),
        ]),
        ("chest", [Bump(part: .trunk, u: 0.74, du: 0.07, angle: 28, da: 28, out: 0.03, down: 0.004)]),
        ("belly", [Bump(part: .trunk, u: 0.32, du: 0.16, angle: 0, da: 65, out: 0.04)]),
        ("waist", [Bump(part: .trunk, u: 0.4, du: 0.12, angle: 90, da: 55, out: 0.025)]),
        ("hips", [Bump(part: .trunk, u: 0.05, du: 0.15, angle: 92, da: 45, out: 0.025)]),
        ("buttocks", [Bump(part: .trunk, u: -0.02, du: 0.12, angle: 180, da: 45, out: 0.03)]),
        ("shoulders", [Bump(part: .upperArm, u: 0.06, du: 0.2, angle: 80, da: 95, out: 0.015),
                       Bump(part: .trunk, u: 0.95, du: 0.06, angle: 100, da: 40, out: 0.008)]),
        ("neckThickness", [Bump(part: .neck, u: 0.3, du: 0.35, out: 0.013)]),   // (none left at the head, where the neck ends)
        ("arms", [Bump(part: .upperArm, u: 0.5, du: 1.2, out: 0.01), Bump(part: .forearm, u: 0.4, du: 0.8, out: 0.007)]),
        ("thighs", [Bump(part: .thigh, u: 0.45, du: 0.8, out: 0.02)]),
        ("calves", [Bump(part: .shin, u: 0.3, du: 0.3, out: 0.012)]),
    ]

    /// A target's deltas from its bumps, smoothed over the mesh.
    /// The neck's bumps go by how much of a vertex the neck's bone moves (the neck meets the head and the trunk where
    /// their bones take over, not at a line).
    static func deltas(_ bumps: [Bump], _ c: SkinnedCharacter, _ coords: Coordinates, _ ring: [[Int32]]) -> [SIMD3<Float>] {
        var d = [SIMD3<Float>](repeating: .zero, count: c.positions.count)
        let neck = CharacterBase.joint("Neck", in: c).map(UInt32.init)
        func neckWeight(_ s: GPUSkinVertex) -> Float {
            let ws = [s.w0, s.w1, s.w2, 1 - s.w0 - s.w1 - s.w2]
            return (0..<4).reduce(0) { $0 + ((s.joints >> UInt32(8 * $1)) & 0xFF == neck ? ws[$1] : 0) }
        }
        for v in d.indices {
            var out: Float = 0, down: Float = 0
            let onNeck = neck != nil && [.neck, .head, .trunk].contains(coords.part[v]) ? neckWeight(c.skin[v]) : 0
            for b in bumps where b.part == coords.part[v] || (b.part == .neck && onNeck > 0) {
                let u = b.part != .neck || coords.part[v] == .neck ? coords.u[v] : coords.part[v] == .head ? 1 : 0
                let along = (u - b.u) / b.du
                var w = exp(-along * along) * (b.part == .neck ? min(onNeck * 1.5, 1) : 1)
                if b.da > 0 {
                    var a = abs(coords.angle[v] - b.angle).truncatingRemainder(dividingBy: 360)
                    if a > 180 { a = 360 - a }
                    w *= exp(-(a / b.da) * (a / b.da))
                }
                out += b.out * w
                down += b.down * w
            }
            d[v] = c.normals[v] * out + SIMD3(0, -down, 0)
        }
        return smoothed(d, ring, iterations: 6)
    }

    /// Each value halfway to its neighbours' mean, `iterations` times.
    static func smoothed(_ values: [SIMD3<Float>], _ ring: [[Int32]], iterations: Int) -> [SIMD3<Float>] {
        var a = values, b = values
        for _ in 0..<iterations {
            for v in a.indices where !ring[v].isEmpty {
                var sum = SIMD3<Float>()
                for u in ring[v] { sum += a[Int(u)] }
                b[v] = 0.5 * a[v] + 0.5 * sum / Float(ring[v].count)
            }
            swap(&a, &b)
        }
        return a
    }

    static func sparse(_ name: String, _ d: [SIMD3<Float>]) -> Target {
        var t = Target(name: name, vertices: [], deltas: [])
        for (v, delta) in d.enumerated() where simd_length_squared(delta) > 1e-8 {
            t.vertices.append(UInt32(v))
            t.deltas.append(delta)
        }
        return t
    }

    // MARK: Building

    /// The targets of `base`; `female`: the X Bot, for "sex" and `sexOffsets` (without it both are zero).
    static func build(_ base: CharacterBase, female: SkinnedCharacter?) -> CharacterMorphs {
        let c = base.character
        let coords = Coordinates(c)
        let ring = CharacterBase.neighbours(c.positions.count, c.indices)
        var targets = [Target](repeating: Target(name: "", vertices: [], deltas: []), count: bumpTargets.count)
        targets.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: bumpTargets.count) { k in
                out[k] = sparse(bumpTargets[k].name, deltas(bumpTargets[k].bumps, c, coords, ring))
            }
        }
        let (target, offsets) = sexTarget(base, coords: coords, ring: ring, female: female)
        targets.append(target)
        if let sculpt = FaceSculpt(c) { targets += faceTargets(base, sculpt: sculpt) }
        return CharacterMorphs(targets: targets, sexOffsets: offsets)
    }

    /// A woman's shape less the base's: on the trunk the way onto the female trunk loft (TrunkLoft, breasts included)
    /// along the normal, on the limbs bumps (slimmer arms, fuller thighs, a thinner neck); and the X Bot's skeleton
    /// (Mixamo's female mannequin: narrower shoulders, a shorter body) as `sexOffsets`.
    static func sexTarget(_ base: CharacterBase, coords: Coordinates, ring: [[Int32]], female: SkinnedCharacter?)
        -> (Target, [SIMD3<Float>]) {
        let c = base.character
        var offsets = [SIMD3<Float>](repeating: .zero, count: c.joints.count)
        let bindY = CharacterBase.bindPositions(c)
        if let female {
            let match = c.jointNames.map { name in female.jointNames.firstIndex(of: name) }
            if match.allSatisfy({ $0 != nil }) {
                let bindX = CharacterBase.bindPositions(female)
                let x = match.map { bindX[$0!] }
                for (j, joint) in c.joints.enumerated() where joint.parent >= 0 {
                    offsets[j] = (x[j] - x[joint.parent]) - (bindY[j] - bindY[joint.parent])
                }
            }
        }
        typealias TrunkLoft = CharacterBase.TrunkLoft
        let male = CharacterBase.TrunkLoft(c, female: false), woman = CharacterBase.TrunkLoft(c, female: true)
        let limbs = deltas(sexBumps, c, coords, ring)
        var d = [SIMD3<Float>](repeating: .zero, count: c.positions.count)
        for v in d.indices {
            let p = c.positions[v]
            // The base's trunk is the man's loft for its share (t) and the Y Bot's for the rest: on the woman's, the
            // field at a vertex of the base is t times the two lofts' difference; then her breasts on it.
            let t = male.trunkness(p)
            let field = CharacterBase.smoothMin(t * (woman.distance(p) - male.distance(p)), woman.breastDistance(p), 0.06)
            let trunk = min(t / TrunkLoft.share, 1)
            d[v] = c.normals[v] * min(max(-field, -0.04), 0.07) + limbs[v] * (1 - trunk)
        }
        return (sparse("sex", smoothed(d, ring, iterations: 10)), offsets)
    }

    static let sexBumps: [Bump] = [
        Bump(part: .upperArm, u: 0.5, du: 1, out: -0.006), Bump(part: .forearm, u: 0.4, du: 0.8, out: -0.004),
        Bump(part: .thigh, u: 0.3, du: 0.5, angle: 90, da: 70, out: 0.012), Bump(part: .thigh, u: 0.3, du: 0.4, angle: -90, da: 50, out: 0.006),
        Bump(part: .shin, u: 0.3, du: 0.6, out: -0.004), Bump(part: .neck, u: 0.5, du: 1, out: -0.008),
    ]
}
