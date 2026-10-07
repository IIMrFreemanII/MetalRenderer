import Foundation
import simd

/// A skeleton the flesh hangs on (PhysicsFlesh.swift), in its rest pose: its bones, each a body and the shape that
/// stands for it, where each was at rest (the space the flesh is built in), and what part of a body each is (the
/// muscles find their bones by it).
struct FleshFigure {
    enum Role: Equatable {
        case pelvis, spine, chest, neck, head
        case upperArm(Float), forearm(Float), hand(Float)   // the side: -1 (the figure's right, -x) or 1
        case thigh(Float), shin(Float), foot(Float)
    }

    struct Bone {
        var role: Role
        var body: Int
        /// Its SDF shape (a single primitive at its origin) and where that is at rest.
        var shape: SDFShape
        var rest: float4x4
        /// The body's pose at rest (centre of mass, rotation): what its pins' rest points are in.
        var restPose: (position: SIMD3<Float>, rotation: SIMD4<Float>)
        /// The bone along its length at rest (from its joint to the next), and how thick it is there.
        var from: SIMD3<Float>
        var to: SIMD3<Float>
        var thickness: Float
        /// Drawn on its body, with no flesh of its own (a head, a hand, a foot).
        var rigid: Bool
        /// The bone it hangs from (-1: none): its joint with it is at its `from`.
        var parent = -1
    }

    var bones: [Bone]
    /// Its bodies: they don't meet its flesh (GPUPhysicsParticle.info.z).
    var bodies: Range<Int> { (bones.map(\.body).min() ?? 0)..<((bones.map(\.body).max() ?? -1) + 1) }

    func bone(_ role: Role) -> Bone? { bones.first { $0.role == role } }

    /// Whether flesh at `p` (rest space) may bind bones `a` and `b` together: one hangs from the other and `p` is at
    /// their joint (within 1.5 times the hanging one's thickness of it). Elsewhere a limb lying against another, or
    /// against the trunk, is apart from it.
    func joins(_ a: Int, _ b: Int, at p: SIMD3<Float>) -> Bool {
        let child = bones[a].parent == b ? a : bones[b].parent == a ? b : -1
        guard child >= 0 else { return false }
        return simd_length(p - bones[child].from) < 1.5 * bones[child].thickness
    }

    /// Its shape's distance at `p` (rest space), with how deep in it that is (0 on its axis, 1 on its surface).
    func depth(_ b: Bone, _ p: SIMD3<Float>) -> Float {
        1 + b.shape.distance(PhysicsMath.xyz(b.rest.inverse * SIMD4(p, 1))).d / b.thickness
    }
}

/// A character's bones as kinematic bodies (PhysicsWorld.addKinematicBody) and the table of their poses, a row a
/// step, that its clips move them through: idle, a walk, a run and a walk again round a circle, with half-second
/// crossfades, over `seconds` and round again (the last idle runs on into the first: the table repeats).
///
/// The bones are the skeleton's joints that matter to the flesh (the hips, the spine, the neck and head, each arm's
/// upper arm, forearm and hand, each leg's thigh, shin and foot); every other joint is the nearest of them up its
/// chain (a finger is its hand, the shoulder the chest). Each is shaped to the mesh's vertices it moves most, in its
/// bind pose: a limb a capsule from its joint to the next, as thick as most of them are from its axis; the trunk's
/// and the hands' and feet's rounded boxes in the joint's frame, as wide as most of them reach; the head a sphere.
struct CharacterRig {
    /// The joints that are bones: Mixamo's names, without "mixamorig:", the joint their length runs to, and the part.
    static let modelled: [(joint: String, next: String, role: FleshFigure.Role)] = [
        ("Hips", "Spine", .pelvis), ("Spine", "Spine1", .spine), ("Spine1", "Spine2", .spine), ("Spine2", "Neck", .chest),
        ("Neck", "Head", .neck), ("Head", "HeadTop_End", .head),
        ("RightArm", "RightForeArm", .upperArm(-1)), ("RightForeArm", "RightHand", .forearm(-1)),
        ("RightHand", "RightHandMiddle4", .hand(-1)),
        ("LeftArm", "LeftForeArm", .upperArm(1)), ("LeftForeArm", "LeftHand", .forearm(1)), ("LeftHand", "LeftHandMiddle4", .hand(1)),
        ("RightUpLeg", "RightLeg", .thigh(-1)), ("RightLeg", "RightFoot", .shin(-1)), ("RightFoot", "RightToe_End", .foot(-1)),
        ("LeftUpLeg", "LeftLeg", .thigh(1)), ("LeftLeg", "LeftFoot", .shin(1)), ("LeftFoot", "LeftToe_End", .foot(1)),
    ]

    struct Bone {
        var joint: Int
        var role: FleshFigure.Role
        var shape: SDFShape
        /// The shape's placement relative to its joint's bind pose (so that the pose's joint carries it).
        var offset: float4x4
        var from: SIMD3<Float>
        var to: SIMD3<Float>
        var thickness: Float
        var rigid: Bool
        var parent: Int
    }

    let character: SkinnedCharacter
    let bind: [(q: simd_quatf, t: SIMD3<Float>)]
    private(set) var bones: [Bone] = []
    /// Per joint, the bone it moves with (its own, or the nearest one up its chain).
    private(set) var boneOf: [Int] = []

    init?(_ character: SkinnedCharacter) {
        self.character = character
        bind = character.bindPoses
        let names = character.jointNames.map { $0.replacingOccurrences(of: "mixamorig:", with: "") }
        func joint(_ name: String) -> Int? { names.firstIndex(of: name) }
        var boneOfJoint = [Int](repeating: -1, count: names.count)
        var found: [(joint: Int, next: Int, role: FleshFigure.Role)] = []
        for m in CharacterRig.modelled {
            guard let j = joint(m.joint), let n = joint(m.next) else { return nil }
            boneOfJoint[j] = found.count
            found.append((j, n, m.role))
        }
        for j in names.indices where boneOfJoint[j] < 0 {   // up its chain (parents come first)
            let parent = character.joints[j].parent
            boneOfJoint[j] = parent >= 0 ? boneOfJoint[parent] : 0
        }
        boneOf = boneOfJoint
        // Each bone's vertices: those it moves most.
        var owned = [[SIMD3<Float>]](repeating: [], count: found.count)
        for (p, s) in zip(character.positions, character.skin) { owned[boneOfJoint[Int(s.joints & 0xFF)]].append(p) }
        func percentile(_ values: [Float], _ q: Float) -> Float {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[min(Int(Float(sorted.count - 1) * q), sorted.count - 1)]
        }
        for (b, f) in found.enumerated() {
            let a = bind[f.joint].t, e = bind[f.next].t
            let length = simd_length(e - a)
            let y = length > 1e-4 ? (e - a) / length : SIMD3<Float>(0, 1, 0)
            // Across it: the character's forward, unless the bone points that way (then its side).
            let ahead = abs(simd_dot(y, [0, 0, 1])) < 0.9 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(1, 0, 0)
            let z = simd_normalize(ahead - y * simd_dot(ahead, y)), x = simd_cross(y, z)
            let frame = simd_float3x3(columns: (x, y, z))
            let local = owned[b].map { frame.transpose * ($0 - a) }   // (x, y along the bone, z)
            let shape: SDFShape, centre: SIMD3<Float>, thickness: Float
            switch f.role {
            case .upperArm, .forearm, .thigh, .shin, .neck:
                // A capsule from the joint to the next, as thick as 85% of its vertices are from that axis.
                let r = percentile(local.map { p in simd_length(SIMD2(p.x, p.z)) }, 0.85)
                thickness = max(r, 0.02)
                shape = SDFShape(.capsule(halfLength: length / 2, radius: thickness))
                centre = [0, length / 2, 0]
            case .head:
                let c = local.reduce(.zero, +) / Float(max(local.count, 1))
                thickness = max(percentile(local.map { simd_length($0 - c) }, 0.85), 0.05)
                shape = SDFShape(.sphere(radius: thickness))
                centre = c
            default:
                // A rounded box over the middle 90% of its vertices each way.
                let lo = SIMD3(percentile(local.map(\.x), 0.05), percentile(local.map(\.y), 0.05), percentile(local.map(\.z), 0.05))
                let hi = SIMD3(percentile(local.map(\.x), 0.95), percentile(local.map(\.y), 0.95), percentile(local.map(\.z), 0.95))
                let half = simd_max((hi - lo) / 2, SIMD3(repeating: 0.02))
                thickness = half.min()
                shape = SDFShape(.box(halfExtents: half, rounding: thickness * 0.6))
                centre = (lo + hi) / 2
            }
            // The shape's placement in bind space, and relative to its joint's bind pose.
            let placed = translate(a) * float4x4(simd_quatf(frame)) * translate(centre)
            let jointBind = translate(bind[f.joint].t) * float4x4(bind[f.joint].q)
            let rigid: Bool
            switch f.role {
            case .head, .hand, .foot: rigid = true
            default: rigid = false
            }
            // The bone it hangs from: its joint's parent's (the nearest modelled one up the chain).
            let up = character.joints[f.joint].parent
            bones.append(Bone(joint: f.joint, role: f.role, shape: shape, offset: jointBind.inverse * placed, from: a, to: e,
                              thickness: thickness, rigid: rigid, parent: up >= 0 ? boneOfJoint[up] : -1))
        }
    }

    /// Bone `b`'s shape's placement in the character's space for `poses` (each joint's).
    func placement(_ b: Int, _ poses: [(q: simd_quatf, t: SIMD3<Float>)]) -> float4x4 {
        let j = bones[b].joint
        return translate(poses[j].t) * float4x4(poses[j].q) * bones[b].offset
    }

    /// ...in the bind pose.
    func restPlacement(_ b: Int) -> float4x4 { placement(b, bind) }

    // MARK: The programme

    /// The clips it goes through and when each starts (s), and how long a crossfade into one takes.
    static let programme: [(clip: String, start: Float)] = [("Idle", 0), ("Walking", 4), ("Running", 9.5), ("Walking", 15),
                                                             ("Idle", 18.5)]
    static let fade: Float = 0.5
    static let seconds: Float = 20

    /// Its pose at `t` (s, within the programme): the clips' blend, and where it is round the circle (m along it).
    func pose(at t: Float) -> (clipA: Int, timeA: Float, clipB: Int, timeB: Float, blend: Float, speed: Float) {
        let clips = CharacterRig.programme.map { character.clip(named: $0.clip) ?? 0 }
        let count = CharacterRig.programme.count
        let s = (0..<count).last { CharacterRig.programme[$0].start <= t } ?? 0
        // A clip's time (keys) since its segment started; the last segment's runs on into the first's.
        func keys(_ k: Int) -> Float {
            let c = character.clips[clips[k]]
            let since = k == count - 1 && clips[k] == clips[0] ? t - CharacterRig.seconds : t - CharacterRig.programme[k].start
            let loop = Float(c.loopKeys)
            return (since * c.rate).truncatingRemainder(dividingBy: loop) + (since < 0 ? loop : 0)
        }
        func speed(_ k: Int) -> Float { CharacterRig.programme[k].clip == "Idle" ? 0 : simd_length(character.clips[clips[k]].velocity) }
        let into = t - CharacterRig.programme[s].start
        guard s > 0, into < CharacterRig.fade else { return (clips[s], keys(s), clips[s], keys(s), 0, speed(s)) }
        let blend = into / CharacterRig.fade
        return (clips[s - 1], keys(s - 1), clips[s], keys(s), blend, speed(s - 1) + (speed(s) - speed(s - 1)) * blend)
    }

    /// The table (PhysicsWorld.kinematicTable): every step of the programme, each bone's body's pose (`bodyPose` from
    /// its shape's placement) with the character going round a circle about `centre` (as many times as makes it
    /// 2 to 3.5 m across), facing along it.
    func table(centre: SIMD3<Float>, bodyPose: (Int, float4x4) -> (SIMD3<Float>, SIMD4<Float>)) -> (rows: [SIMD4<Float>], radius: Float) {
        let rows = Int((CharacterRig.seconds / PhysicsWorld.stepLength).rounded())
        let poses = (0..<rows).map { pose(at: Float($0) * PhysicsWorld.stepLength) }
        // How far along the circle at each step, and the circle that brings it round whole times.
        var along = [Float](repeating: 0, count: rows)
        for k in 1..<rows { along[k] = along[k - 1] + (poses[k - 1].speed + poses[k].speed) / 2 * PhysicsWorld.stepLength }
        let total = along[rows - 1] + poses[rows - 1].speed * PhysicsWorld.stepLength
        let laps = max((total / (2 * .pi * 2.5)).rounded(), 1)
        let radius = total / (2 * .pi * laps)
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(rows * bones.count * 2)
        for k in 0..<rows {
            let p = poses[k]
            let joints = character.jointPoses(clipA: p.clipA, timeA: p.timeA, clipB: p.clipB, timeB: p.timeB, blend: p.blend)
            let phi = radius > 0 ? along[k] / radius : 0
            let root = translate(centre + radius * SIMD3(sin(phi), 0, cos(phi))) * rotate(phi + .pi / 2, [0, 1, 0])
            for b in bones.indices {
                let (x, q) = bodyPose(b, root * placement(b, joints))
                out += [SIMD4(x, 0), q]
            }
        }
        return (out, radius)
    }
}
