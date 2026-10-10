import Foundation
import simd

/// A generated character's face in motion: what the GPU does to the base's bind-pose vertices before skinning them
/// (crowdSkinKernel), every frame and per pose slot.
///
/// * Expressions are morph targets (`targets`: the jaw opening, a smile, a frown, the brows, the mouth's shapes for
///   speech), a sparse list of vertices each, with their normals' change; a slot's weights say how much of each.
/// * The eyes turn and the lids close by rotations about the eyes' centres (`groups`): each vertex of an eyeball turns
///   whole with it, each of a lid by its weight (1 at the lid's edge, less toward the brow and cheek), so a blink
///   folds the lid down over the eyeball instead of pushing it through.
///
/// Everything is made from the base (CharacterBase) and FaceSculpt's landmarks, once, and kept in the kit's cache.
final class FaceRig {
    /// The expression targets, in the order a slot's weights are.
    static let targetNames = ["jawOpen", "smile", "frown", "browsUp", "browsDown", "pucker", "wide", "press", "lipTuck", "cheeks"]

    /// The rotation groups: each lid of each eye and each eyeball.
    enum Group: Int, CaseIterable {
        case leftUpperLid = 1, leftLowerLid, rightUpperLid, rightLowerLid, leftEye, rightEye
    }
    static let groupCount = Group.allCases.count

    struct Target: Equatable {
        var name: String
        var vertices: [UInt32]
        var deltas: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
    }

    let targets: [Target]
    /// Per vertex of the base: its group (0: none) in the low byte, its weight (0...255) in the next.
    let groups: [UInt32]
    /// Per eye (left, right): the cornea's top and the back of the eyeball (base vertices), for its centre.
    let eyePoles: [SIMD2<UInt32>]

    init(targets: [Target], groups: [UInt32], eyePoles: [SIMD2<UInt32>]) {
        self.targets = targets
        self.groups = groups
        self.eyePoles = eyePoles
    }

    /// MSL FaceEntry: one target's movement of one vertex (`delta.w`: the target's index, as bits).
    struct Entry {
        var delta: SIMD4<Float>
        var normal: SIMD4<Float>
    }

    /// The targets by vertex (what the GPU reads): vertex v's entries are `entries[ranges[v] ..< ranges[v + 1]]`.
    private(set) lazy var byVertex: (ranges: [UInt32], entries: [Entry]) = {
        var lists = [[Entry]](repeating: [], count: groups.count)
        for (k, t) in targets.enumerated() {
            for (i, v) in t.vertices.enumerated() {
                lists[Int(v)].append(Entry(delta: SIMD4(t.deltas[i], Float(bitPattern: UInt32(k))), normal: SIMD4(t.normals[i], 0)))
            }
        }
        var ranges: [UInt32] = [0]
        ranges.reserveCapacity(groups.count + 1)
        for l in lists { ranges.append(ranges.last! + UInt32(l.count)) }
        return (ranges, lists.flatMap { $0 })
    }()

    /// Vertex `v`'s group (0 for a vertex not of the base: a hair cap's, `Level.source` UInt32.max).
    @inline(__always) func group(_ v: Int) -> UInt32 { v < groups.count ? groups[v] : 0 }

    /// An eye's centre (and how big it is against the base's) in a mesh made from the base: from its poles, which
    /// any reshaping of the head moves with it.
    func eye(_ e: Int, in positions: [SIMD3<Float>]) -> (centre: SIMD3<Float>, scale: Float) {
        let front = positions[Int(eyePoles[e].x)], back = positions[Int(eyePoles[e].y)]
        let length = simd_distance(front, back), base = 2 * FaceSculpt.eyeRadius + FaceSculpt.corneaRise
        return (back + (front - back) * (FaceSculpt.eyeRadius / base), length / base)
    }

    // MARK: Building

    static func build(_ base: CharacterBase, sculpt: FaceSculpt) -> FaceRig {
        let c = base.character
        let regions = base.regions.map { CharacterBase.Region(rawValue: $0) ?? .trunk }
        // The eyes' poles: each eyeball's first and last vertex (FaceParts.eyeball).
        var poles: [SIMD2<UInt32>] = []
        for eye in [CharacterBase.Region.leftEye, .rightEye] {
            let mine = regions.indices.filter { regions[$0] == eye }
            let centre = sculpt.eyes[eye == .leftEye ? 0 : 1]
            let front = mine.max { c.positions[$0].z < c.positions[$1].z } ?? 0
            let back = mine.min { simd_distance(c.positions[$0], centre - [0, 0, 1]) < simd_distance(c.positions[$1], centre - [0, 0, 1]) } ?? 0
            poles.append(SIMD2(UInt32(front), UInt32(back)))
        }
        let groups = c.positions.indices.map { v -> UInt32 in
            switch regions[v] {
            case .leftEye: return UInt32(Group.leftEye.rawValue) | 255 << 8
            case .rightEye: return UInt32(Group.rightEye.rawValue) | 255 << 8
            case .upperTeeth, .lowerTeeth, .tongue: return 0
            default:
                guard let (group, weight) = lid(sculpt.local(c.positions[v])), weight > 0.004 else { return 0 }
                return UInt32(group.rawValue) | UInt32((weight * 255).rounded()) << 8
            }
        }
        var targets = [Target](repeating: Target(name: "", vertices: [], deltas: [], normals: []), count: targetNames.count)
        targets.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: targetNames.count) { k in
                let name = targetNames[k]
                var moved = c.positions
                var d = [SIMD3<Float>](repeating: .zero, count: c.positions.count)
                for v in c.positions.indices {
                    let region = regions[v]
                    if region == .leftEye || region == .rightEye || region == .upperTeeth { continue }
                    let q = sculpt.local(c.positions[v])
                    var delta = expression(name, q)
                    if region == .lowerTeeth || region == .tongue { delta = name == "jawOpen" ? jaw(q, weight: 1) : .zero }
                    d[v] = delta * sculpt.scale
                    moved[v] += d[v]
                }
                let normals = CharacterBase.vertexNormals(moved, c.indices)
                var t = Target(name: name, vertices: [], deltas: [], normals: [])
                for v in d.indices where simd_length_squared(d[v]) > 1e-12 {
                    t.vertices.append(UInt32(v))
                    t.deltas.append(d[v])
                    t.normals.append(normals[v] - c.normals[v])
                }
                out[k] = t
            }
        }
        return FaceRig(targets: targets, groups: groups, eyePoles: poles)
    }

    // MARK: Lids

    /// The lids' rest and their blink: the upper lid's edge is about 24 degrees above the eye's axis, the lower's 17
    /// below; they meet about 12 below.
    static let blinkUpper: Float = 39 * .pi / 180
    static let blinkLower: Float = -6 * .pi / 180

    /// The lid a point of skin is on (the sculpt's space), and how much it turns with it.
    static func lid(_ q: SIMD3<Float>) -> (Group, Float)? {
        for (e, centre) in FaceSculpt.eyeCentres.enumerated() {
            let s: Float = e == 0 ? 1 : -1
            let r = q - centre
            let x = r.x * s
            let length = simd_length(r)
            guard length < 0.022, r.z > -0.009, x > -0.018, x < 0.02 else { continue }
            // The opening's edges at this x (FaceSculpt.eyeOpening's).
            let inner: SIMD2<Float> = [-0.0135, -0.0006], outer: SIMD2<Float> = [0.0145, 0.0014]
            let t = (x - inner.x) / (outer.x - inner.x), tc = min(max(t, 0), 1)
            let line = inner.y + (outer.y - inner.y) * t
            let up = line + 0.0058 * pow(sin(.pi * pow(tc, 0.85)), 0.75), down = line - 0.0042 * pow(sin(.pi * pow(tc, 1.15)), 0.8)
            // Toward the corners and away from the eyeball's shell, less.
            let corner = 1 - FaceSculpt.smoothstep(0.7, 1.05, abs(2 * t - 1))
            let shell = 1 - FaceSculpt.smoothstep(0.0172, 0.0215, length)
            let depth = FaceSculpt.smoothstep(-0.009, -0.003, r.z)
            if r.y > (up + down) / 2 {
                let w = (1 - FaceSculpt.smoothstep(0.0015, 0.0095, r.y - up)) * corner * shell * depth
                return (e == 0 ? .leftUpperLid : .rightUpperLid, w)
            } else {
                let w = (1 - FaceSculpt.smoothstep(0.0008, 0.0055, down - r.y)) * corner * shell * depth
                return (e == 0 ? .leftLowerLid : .rightLowerLid, w)
            }
        }
        return nil
    }

    // MARK: Expressions

    @inline(__always) static func gauss(_ q: SIMD3<Float>, _ c: SIMD3<Float>, _ r: SIMD3<Float>) -> Float {
        let d = (q - c) / r
        return exp(-simd_dot(d, d))
    }

    /// 1 on the upper lip's side of the mouth's line (sharp across the cut between the lips), 0 below.
    static func upperSide(_ q: SIMD3<Float>) -> Float {
        let x = abs(q.x)
        let line = FaceSculpt.mouth.y - 0.0012 * pow(min(x / FaceSculpt.mouthHalfWidth, 1), 2)
        return FaceSculpt.smoothstep(line - 0.0007, line + 0.0007, q.y)
    }

    /// How much of the jaw's opening a point takes: all below the mouth (the lower lip, the chin, the jaw, the floor of
    /// the mouth), none above it, easing across the cheeks toward the ears and down the throat.
    static func jawWeight(_ q: SIMD3<Float>) -> Float {
        let x = abs(q.x), corner = FaceSculpt.mouthHalfWidth
        let line: Float, width: Float
        if x < corner {
            line = FaceSculpt.mouth.y - 0.0012 * pow(x / corner, 2)
            width = 0.0007
        } else {
            line = FaceSculpt.mouth.y - 0.0012 + (x - corner) * 1.1
            width = 0.0007 + (x - corner) * 0.4
        }
        let below = FaceSculpt.smoothstep(line + width, line - width, q.y)
        let throat = FaceSculpt.smoothstep(1.546, 1.574, q.y)
        let behind = FaceSculpt.smoothstep(-0.012, 0.02, q.z)
        return below * throat * behind
    }

    /// The jaw's opening at `weight` 1 (16 degrees about its hinge), times `weight`.
    static func jaw(_ q: SIMD3<Float>, weight: Float) -> SIMD3<Float> {
        let angle: Float = 16 * .pi / 180
        let r = q - FaceSculpt.jawHinge
        let turned = SIMD3(r.x, r.y * cos(angle) - r.z * sin(angle), r.y * sin(angle) + r.z * cos(angle))
        return (turned - r) * weight
    }

    /// Target `name`'s movement of the point `q` of the skin at weight 1 (the sculpt's space).
    static func expression(_ name: String, _ q: SIMD3<Float>) -> SIMD3<Float> {
        let side: Float = q.x >= 0 ? 1 : -1
        let m = SIMD3(abs(q.x), q.y, q.z)
        let corner = SIMD3<Float>(FaceSculpt.mouthHalfWidth, 1.6135, 0.0905)
        let atCorner = gauss(m, corner, [0.012, 0.01, 0.012])
        let up = upperSide(q)
        switch name {
        case "jawOpen":
            return jaw(q, weight: jawWeight(q))
        case "smile":
            return atCorner * SIMD3(side * 0.006, 0.0065, -0.004)
                + gauss(m, [0.035, 1.645, 0.075], [0.016, 0.014, 0.016]) * SIMD3(side * 0.0015, 0.004, 0.0028)
                + gauss(m, [0.008, 1.62, 0.1], [0.012, 0.006, 0.01]) * up * SIMD3(0, 0.0008, -0.0004)
                + gauss(m, [0.01, 1.607, 0.098], [0.014, 0.006, 0.01]) * (1 - up) * SIMD3(0, 0.0003, -0.0006)
        case "frown":
            return gauss(m, corner, [0.011, 0.009, 0.011]) * SIMD3(-side * 0.001, -0.004, -0.0005)
                + gauss(m, [0, 1.59, 0.095], [0.016, 0.01, 0.012]) * (1 - up) * SIMD3(0, 0.0015, 0.0012)
                + gauss(m, [0.016, 1.701, 0.09], [0.012, 0.008, 0.012]) * SIMD3(-side * 0.0018, -0.0028, 0.0008)
        case "browsUp":
            return gauss(m, [0.034, 1.703, 0.085], [0.026, 0.011, 0.03]) * SIMD3(0, 0.0055, 0.0006)
                + gauss(m, [0.02, 1.73, 0.08], [0.04, 0.02, 0.04]) * SIMD3(0, 0.002, 0)
        case "browsDown":
            return gauss(m, [0.02, 1.702, 0.088], [0.016, 0.009, 0.014]) * SIMD3(-side * 0.0015, -0.0035, 0.001)
        case "pucker":
            return gauss(m, [0, 1.6145, 0.1], [0.022, 0.012, 0.014]) * SIMD3(0, 0, 0.0045)
                + atCorner * SIMD3(-side * 0.0075, 0, 0.002)
                + gauss(m, [0, 1.6145, 0.1], [0.018, 0.008, 0.012]) * SIMD3(0, (up - 0.5) * 0.0014, 0)
        case "wide":
            return atCorner * SIMD3(side * 0.0055, 0.0008, -0.0035)
                + gauss(m, [0, 1.6145, 0.1], [0.018, 0.008, 0.012]) * SIMD3(0, (up - 0.5) * 0.001, -0.0008)
        case "press":
            let near = gauss(m, [0.008, 1.6145, 0.098], [0.022, 0.0045, 0.012])
            return near * SIMD3(0, (0.5 - up) * 0.0026, 0.0003)
        case "lipTuck":
            return (1 - up) * gauss(m, [0.008, 1.608, 0.099], [0.018, 0.007, 0.012]) * SIMD3(0, 0.0028, -0.0045)
        case "cheeks":
            return gauss(m, [0.036, 1.655, 0.075], [0.016, 0.012, 0.015]) * SIMD3(0, 0.003, 0.0015)
        default:
            return .zero
        }
    }

    // MARK: On the CPU

    /// `positions` and `normals` (a level of the base, `source` its vertices' at full detail; nil for full detail)
    /// moved as the GPU does: the weighted targets (scaled by `scale`), then each group's turn.
    func apply(_ state: FaceState, scale: Float, source: [UInt32]?, positions: inout [SIMD3<Float>], normals: inout [SIMD3<Float>]) {
        var back: [Int32]? = nil
        if let source {   // full-detail vertex -> this level's
            var map = [Int32](repeating: -1, count: groups.count)
            for (v, s) in source.enumerated() where Int(s) < groups.count { map[Int(s)] = Int32(v) }
            back = map
        }
        for (k, t) in targets.enumerated() where k < state.weights.count && state.weights[k] != 0 {
            let w = state.weights[k]
            for (i, v) in t.vertices.enumerated() {
                let mine = back.map { Int($0[Int(v)]) } ?? Int(v)
                guard mine >= 0 else { continue }
                positions[mine] += t.deltas[i] * (w * scale)
                normals[mine] += t.normals[i] * w
            }
        }
        for v in positions.indices {
            let g = group(source.map { Int($0[v]) } ?? v)
            normals[v] = simd_normalize(normals[v])
            guard g & 0xFF != 0 else { continue }
            let turn = state.turns[Int(g & 0xFF) - 1]
            let angle = turn.axisAngle.w * Float(g >> 8) / 255
            guard angle != 0 else { continue }
            let q = simd_quatf(angle: angle, axis: SIMD3(turn.axisAngle.x, turn.axisAngle.y, turn.axisAngle.z))
            let pivot = SIMD3(turn.pivot.x, turn.pivot.y, turn.pivot.z)
            positions[v] = pivot + q.act(positions[v] - pivot)
            normals[v] = q.act(normals[v])
        }
    }
}

/// One slot's face this frame: each expression target's weight and each group's turn (MSL FaceTurn).
struct FaceState: Equatable {
    struct Turn: Equatable {
        var axisAngle = SIMD4<Float>(1, 0, 0, 0)   // axis, and the angle at weight 1 (radians)
        var pivot = SIMD4<Float>()                // the eye's centre (bind space)
    }
    var weights = [Float](repeating: 0, count: FaceRig.targetNames.count)
    var turns = [Turn](repeating: Turn(), count: FaceRig.groupCount)
}

/// What a workshop's faces do (CharacterSceneSettings.expression).
enum FaceExpression: Int, Codable, CaseIterable {
    case neutral, smile, frown, surprise, talk, cycle

    var title: String {
        switch self {
        case .neutral: return "Neutral"
        case .smile: return "Smile"
        case .frown: return "Frown"
        case .surprise: return "Surprise"
        case .talk: return "Talking"
        case .cycle: return "Every one in turn"
        }
    }
}

/// A face's motion as a function of time: blinks (every few seconds, seeded), an expression, speech, and the eyes on
/// a point.
enum FacePlayer {
    /// Mouth shapes for speech: target weights.
    static let visemes: [[String: Float]] = [
        ["jawOpen": 0.75, "wide": 0.1],                 // AA
        ["wide": 0.8, "jawOpen": 0.18],                 // EE
        ["pucker": 0.9, "jawOpen": 0.22],               // OO
        ["press": 1],                                   // M B P
        ["lipTuck": 1, "jawOpen": 0.08],                // F V
        ["jawOpen": 0.35, "wide": 0.35],                // EH
        [:],                                            // rest
    ]

    /// How closed the lids are by a blink at time `t` (0...1), for a face seeded `seed`: one in every four seconds, at
    /// a seeded moment of it, a sixth of a second long (quick to close, slower to open). Open at time 0.
    static func blink(_ t: Float, seed: UInt64) -> Float {
        let window: Float = 4
        let k = Int((t / window).rounded(.down))
        for w in [k, k - 1] where w >= 0 {
            var rng = SplitMix64(seed: seed &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(w) &* 0xBF58_476D_1CE4_E5B9)
            let x = t - (Float(w) * window + 0.3 + rng.range(0, 3.4))
            if x >= 0 && x <= 0.17 { return x < 0.06 ? x / 0.06 : 1 - (x - 0.06) / 0.11 }
        }
        return 0
    }

    /// The expression's target weights and lid offsets (upper, lower; radians, + closes) at time `t`.
    static func expression(_ e: FaceExpression, at t: Float, seed: UInt64) -> (weights: [String: Float], lids: SIMD2<Float>) {
        let deg = Float.pi / 180
        switch e {
        case .neutral: return ([:], .zero)
        case .smile: return (["smile": 1, "cheeks": 0.6], SIMD2(2 * deg, -5 * deg))
        case .frown: return (["frown": 1, "browsDown": 0.8], SIMD2(5 * deg, -2 * deg))
        case .surprise: return (["browsUp": 1, "jawOpen": 0.35], SIMD2(-9 * deg, 2 * deg))
        case .talk:
            // A viseme every 90 to 150 ms, eased into the next.
            var rng = SplitMix64(seed: seed ^ 0x7A1C)
            var start: Float = 0, length = rng.range(0.09, 0.15), current = rng.int(visemes.count), next = rng.int(visemes.count)
            while start + length < t { start += length; length = rng.range(0.09, 0.15); current = next; next = rng.int(visemes.count) }
            let x = (t - start) / length, k = x * x * (3 - 2 * x)
            var w: [String: Float] = [:]
            for (n, v) in visemes[current] { w[n, default: 0] += v * (1 - k) }
            for (n, v) in visemes[next] { w[n, default: 0] += v * k }
            w["browsUp", default: 0] += 0.15 + 0.15 * sin(t * 2.1)
            return (w, .zero)
        case .cycle:
            let order: [FaceExpression] = [.neutral, .smile, .surprise, .frown, .talk]
            let period: Float = 2.5
            let phase = t / period, k = Int(phase.rounded(.down)) % order.count
            let x = phase - phase.rounded(.down)
            let a = expression(order[k], at: t, seed: seed), b = expression(order[(k + 1) % order.count], at: t, seed: seed)
            let blend = FaceSculpt.smoothstep(0.75, 1, x)
            var w = a.weights.mapValues { $0 * (1 - blend) }
            for (n, v) in b.weights { w[n, default: 0] += v * blend }
            return (w, a.lids * (1 - blend) + b.lids * blend)
        }
    }

    /// A face's state at time `t`: `eyes` its eyes' centres (bind space); `gaze` where its eyes look, in its head's
    /// bind space (nil: ahead); `expressive` false: blinks only.
    static func state(at t: Float, seed: UInt64, expression e: FaceExpression, expressive: Bool, eyes: [SIMD3<Float>],
                      gaze: SIMD3<Float>?) -> FaceState {
        var s = FaceState()
        var lids = SIMD2<Float>.zero
        if expressive {
            let (w, l) = expression(e, at: t, seed: seed)
            for (k, n) in FaceRig.targetNames.enumerated() { s.weights[k] = min(w[n] ?? 0, 1.2) }
            lids = l
        }
        // The eyes on the point (within how far eyes turn), the upper lid following them up and down.
        var pitch: Float = 0
        for e in 0..<2 where eyes.count == 2 {
            var turn = FaceState.Turn(axisAngle: [1, 0, 0, 0], pivot: SIMD4(eyes[e], 0))
            if let gaze {
                var d = simd_normalize(gaze - eyes[e])
                let yaw = min(max(atan2(d.x, d.z), -0.6), 0.6), up = min(max(asin(min(max(d.y, -1), 1)), -0.45), 0.4)
                d = SIMD3(sin(yaw) * cos(up), sin(up), cos(yaw) * cos(up))
                let axis = simd_cross(SIMD3<Float>(0, 0, 1), d)
                if simd_length(axis) > 1e-5 { turn.axisAngle = SIMD4(simd_normalize(axis), asin(min(simd_length(axis), 1))) }
                pitch = up
            }
            s.turns[(e == 0 ? FaceRig.Group.leftEye : .rightEye).rawValue - 1] = turn
        }
        let b = blink(t, seed: seed)
        let upper = lids.x - 0.6 * pitch, lower = lids.y - 0.3 * pitch
        for e in 0..<2 where eyes.count == 2 {
            let pivot = SIMD4(eyes[e], 0)
            let closedUpper = upper + (FaceRig.blinkUpper - upper) * b, closedLower = lower + (FaceRig.blinkLower - lower) * b
            s.turns[(e == 0 ? FaceRig.Group.leftUpperLid : .rightUpperLid).rawValue - 1] = .init(axisAngle: [1, 0, 0, closedUpper], pivot: pivot)
            s.turns[(e == 0 ? FaceRig.Group.leftLowerLid : .rightLowerLid).rawValue - 1] = .init(axisAngle: [1, 0, 0, closedLower], pivot: pivot)
        }
        return s
    }
}
