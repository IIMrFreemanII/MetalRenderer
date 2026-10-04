import Foundation
import simd

/// A crowd: thousands of instances of a few skinned characters, animated on the GPU.
///
/// Everything in this renderer is ray traced, so a pose is not something a vertex shader does to an instance: it is
/// a mesh with an acceleration structure of its own. The crowd therefore keeps a pool of *pose slots*. A slot is a
/// character playing a clip (or a blend of two) from some point of its loop; each frame the GPU poses and skins
/// every slot once (CrowdSkinner) and refits its acceleration structure, and every member of the crowd is an
/// ordinary instance of one slot's mesh. The cost of a frame follows the number of slots, not of members: members
/// on the same slot move in step, which a few dozen slots per clip hide well. A character that must move alone
/// takes a slot to itself.
///
/// This class is the crowd's description and its clock: which slots there are, what each plays at time t, and where
/// its members walk. It is all a function of the time, so a benchmark's frame is the same on every run.
final class Crowd {
    /// What a slot plays: clip A, or a cross-fade from it to clip B and back every `blendPeriod` seconds, the two
    /// kept in step (both at the same point of their loops).
    struct Motion {
        var clipA: Int
        var clipB: Int
        var blendPeriod: Float = 0
        var isBlend: Bool { clipA != clipB }
    }

    /// A character in a motion, with the pose slots that play it from different points of the loop.
    struct State {
        var character: Int
        var motion: Motion
        var slots: [Int] = []
        var travels: Bool
    }

    /// A character's mesh as its pose slots deform it: the bind-pose mesh in the scene's buffers (the skinning's
    /// source), and where its slots' vertices are: slot k's at `currentBase + k * vertexCount`, their previous
    /// frame's positions at `previousBase + k * vertexCount`.
    struct Part {
        var character: Int
        var level: Int                // the character's level of detail (SkinnedCharacter.level)
        var mesh = -1
        var bindVertex = 0
        var vertexCount: Int
        var firstSlot = 0
        var slotCount = 0
        var currentBase = 0
        var previousBase = 0
    }

    struct Slot {
        var part: Int
        var state: Int
        var phase: Float              // 0...1: where in the loop it is at time 0
        var mesh = -1                 // the scene's mesh that is this pose
        // At the crowd's current time:
        var record = GPUPoseSlot()
        var distance: Double = 0          // how far its members have travelled (m, for a member of scale 1)
        var previousDistance: Double = 0  // ...at the time before
    }

    /// A member that walks: along its lane from `origin` in direction `forward`, wrapping around at the lane's end.
    struct Walker {
        var instance: Int
        var slot: Int
        var origin: SIMD3<Float>
        var forward: SIMD3<Float>
        var start: Float              // where on the lane it is at time 0 (m)
        var lane: Float               // the lane's length (m)
        var scale: Float
        // Rows of its world -> object matrix without the translation (its rotation's columns / scale).
        var inverse0: SIMD3<Float>, inverse1: SIMD3<Float>, inverse2: SIMD3<Float>

        /// Where it is and where it was a frame ago, given its slot's travel. The previous position is taken back
        /// along the lane from this one, so a wrap-around doesn't read as a jump across the scene.
        func positions(_ slot: Slot) -> (current: SIMD3<Float>, previous: SIMD3<Float>) {
            let travelled = Double(start) + Double(scale) * slot.distance
            let s = Float(travelled - (travelled / Double(lane)).rounded(.down) * Double(lane))
            let step = Float(Double(scale) * (slot.distance - slot.previousDistance))
            return (origin + forward * s, origin + forward * (s - step))
        }
    }

    let characters: [SkinnedCharacter]
    private(set) var states: [State] = []
    var parts: [Part] = []
    var slots: [Slot] = []
    var walkers: [Walker] = []
    /// Members in all (walkers and the ones that stand).
    var memberCount = 0

    // The key tables the GPU reads (CrowdSkinner): every character's joints, and every clip's keys.
    private(set) var joints: [GPUJoint] = []
    private(set) var jointBase: [Int] = []                    // per character
    private(set) var rotationKeys: [SIMD4<Float>] = []
    private(set) var rootKeys: [SIMD4<Float>] = []
    private var clipBase: [[(rotations: Int, root: Int)]] = []   // per character and clip

    /// `poses` slots shared out over the characters' motions: every clip, and a cross-fade between the two fastest
    /// clips that travel (walking and running), if there are two. `level`: the detail the poses are skinned at.
    init(characters: [SkinnedCharacter], poses: Int, level: Int = 0) {
        self.characters = characters
        for c in characters {
            jointBase.append(joints.count)
            joints += c.joints
            clipBase.append(c.clips.map { clip in
                defer { rotationKeys += clip.rotations; rootKeys += clip.root }
                return (rotationKeys.count, rootKeys.count)
            })
            parts.append(Part(character: parts.count, level: level, vertexCount: c.level(level).positions.count))
        }
        // The motions in the order the slots are dealt: with few slots the first ones get them.
        let most = characters.map { $0.clips.count }.max() ?? 0
        for rank in 0...most {
            for (c, character) in characters.enumerated() {
                let moving = character.clips.indices.filter { character.clips[$0].velocity != .zero }
                    .sorted { simd_length(character.clips[$0].velocity) < simd_length(character.clips[$1].velocity) }
                let standing = character.clips.indices.filter { character.clips[$0].velocity == .zero }
                // Walking, standing, running, standing ... then the cross-fade.
                var order: [Motion] = []
                for i in 0..<max(moving.count, standing.count) {
                    if i < moving.count { order.append(Motion(clipA: moving[i], clipB: moving[i])) }
                    if i < standing.count { order.append(Motion(clipA: standing[i], clipB: standing[i])) }
                }
                if moving.count >= 2 { order.append(Motion(clipA: moving[moving.count - 2], clipB: moving[moving.count - 1], blendPeriod: 12)) }
                if rank < order.count {
                    states.append(State(character: c, motion: order[rank], travels: character.clips[order[rank].clipA].velocity != .zero))
                }
            }
        }
        guard !states.isEmpty else { return }
        // Deal the slots, then give each state's slots evenly spaced phases. A part's slots must be consecutive.
        var perState = [Int](repeating: 0, count: states.count)
        for i in 0..<max(poses, 1) { perState[i % states.count] += 1 }
        for p in parts.indices {
            parts[p].firstSlot = slots.count
            for (s, state) in states.enumerated() where state.character == parts[p].character {
                for k in 0..<perState[s] {
                    states[s].slots.append(slots.count)
                    slots.append(Slot(part: p, state: s, phase: Float(k) / Float(perState[s])))
                }
            }
            parts[p].slotCount = slots.count - parts[p].firstSlot
        }
        pose(at: 0)
        for i in slots.indices { slots[i].previousDistance = slots[i].distance }
    }

    /// The states that have slots: the ones members can be given.
    var liveStates: [Int] { states.indices.filter { !states[$0].slots.isEmpty } }

    /// Sets every slot to what it plays at time `t`: its record for the GPU and how far its members have travelled.
    func pose(at t: Float) {
        let time = Double(t)
        for i in slots.indices {
            let state = states[slots[i].state], motion = state.motion
            let character = characters[state.character], bases = clipBase[state.character]
            let a = character.clips[motion.clipA], b = character.clips[motion.clipB]
            // A cross-fade's weight swings between the clips; its integral gives the loops played and the distance.
            var blend = 0.0, blendIntegral = 0.0
            if motion.isBlend {
                let w = 2 * Double.pi / Double(motion.blendPeriod)
                blend = 0.5 - 0.5 * cos(w * time)
                blendIntegral = 0.5 * time - 0.5 * sin(w * time) / w
            }
            let loops = Double(slots[i].phase) + time / Double(a.duration)
                + (1 / Double(b.duration) - 1 / Double(a.duration)) * blendIntegral
            let f = loops - loops.rounded(.down)
            slots[i].record = GPUPoseSlot(rotationsA: UInt32(bases[motion.clipA].rotations), rootA: UInt32(bases[motion.clipA].root),
                                          rotationsB: UInt32(bases[motion.clipB].rotations), rootB: UInt32(bases[motion.clipB].root),
                                          // (kept inside the loop: the key after a time's own is read too)
                                          timeA: min(Float(f * Double(a.loopKeys)), Float(a.loopKeys) - 1e-3),
                                          timeB: min(Float(f * Double(b.loopKeys)), Float(b.loopKeys) - 1e-3),
                                          blend: Float(blend))
            let speedA = Double(simd_length(a.velocity)), speedB = Double(simd_length(b.velocity))
            slots[i].previousDistance = slots[i].distance
            slots[i].distance = speedA * time + (speedB - speedA) * blendIntegral
        }
    }

    /// The mesh a part's slots deform.
    func geometry(part p: Int) -> SkinnedCharacter.Level { characters[parts[p].character].level(parts[p].level) }

    /// The skinning matrices of slot `i` at the crowd's current time, as the GPU makes them.
    func palette(slot i: Int) -> [GPUJointMatrix] {
        let state = states[slots[i].state], r = slots[i].record
        return characters[state.character].palette(clipA: state.motion.clipA, timeA: r.timeA, clipB: state.motion.clipB,
                                                   timeB: r.timeB, blend: r.blend)
    }

    /// First vertex of slot `i`'s current positions (and normals) and of its previous positions in the scene's buffers.
    func vertexRange(slot i: Int) -> (current: Int, previous: Int, count: Int) {
        let part = parts[slots[i].part], k = i - part.firstSlot
        return (part.currentBase + k * part.vertexCount, part.previousBase + k * part.vertexCount, part.vertexCount)
    }
}
