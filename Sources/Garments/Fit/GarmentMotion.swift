import Characters
import Foundation
import simd

/// What the avatar does while a garment drapes on it: its bind pose held while the panels are sewn, a blend into a
/// clip, then the clip, round several times; as one clip of the avatar's (its keys at the clip's rate), so that the
/// crowd's skinning plays it. And the avatar's bones as capsules in a pose (the cloth's colliders while it moves).
package enum GarmentMotion {
    /// The clip: `hold` seconds of the bind pose, `blend` seconds into clip `index`, then it `loops` times.
    package static func clip(_ c: SkinnedCharacter, index: Int, hold: Float = 1.6, blend: Float = 1, loops: Int = 12) -> SkinnedCharacter.Clip? {
        guard c.clips.indices.contains(index), let rest = CharacterKit.poseClips(c).first else { return nil }
        let source = c.clips[index]
        let joints = c.joints.count
        let rate = max(15, source.rate)
        let total = hold + blend + source.duration * Float(loops)
        let keys = Int((total * rate).rounded(.up)) + 1
        var rotations: [SIMD4<Float>] = [], root: [SIMD4<Float>] = []
        rotations.reserveCapacity(keys * joints)
        func sample(_ t: Float) -> (rot: ArraySlice<SIMD4<Float>>, root: SIMD4<Float>) {
            let f = (t * source.rate).truncatingRemainder(dividingBy: Float(source.loopKeys))
            let k = min(Int(f), source.keyCount - 1)
            return (source.rotations[(k * joints)..<((k + 1) * joints)], source.root[k])
        }
        for k in 0..<keys {
            let t = Float(k) / rate
            let w = max(0, min(1, (t - hold) / blend))
            let s = sample(max(0, t - hold - blend))
            for j in 0..<joints {
                let a = simd_quatf(vector: rest.rotations[j]), b = simd_quatf(vector: s.rot[s.rot.startIndex + j])
                rotations.append(simd_slerp(a, b, w * w * (3 - 2 * w)).vector)
            }
            root.append(simd_mix(rest.root[0], s.root, SIMD4(repeating: w)))
        }
        return SkinnedCharacter.Clip(name: "Garment " + source.name, keyCount: keys, rate: rate, rotations: rotations, root: root, velocity: .zero)
    }

    /// The bones of `rig` as capsules in the pose `palette` (a crowd slot's skinning matrices): each its bind-pose axis
    /// carried by its joint, as thick as the rig made it and `pad` more.
    package static func capsules(_ rig: CharacterRig, palette: [GPUJointMatrix], pad: Float = 0.006) -> [(a: SIMD3<Float>, b: SIMD3<Float>, r: Float)] {
        func apply(_ m: GPUJointMatrix, _ p: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(simd_dot(SIMD3(m.row0.x, m.row0.y, m.row0.z), p) + m.row0.w, simd_dot(SIMD3(m.row1.x, m.row1.y, m.row1.z), p) + m.row1.w,
                  simd_dot(SIMD3(m.row2.x, m.row2.y, m.row2.z), p) + m.row2.w)
        }
        return rig.bones.compactMap { b in
            guard palette.indices.contains(b.joint) else { return nil }
            return (apply(palette[b.joint], b.from), apply(palette[b.joint], b.to), b.thickness + pad)
        }
    }
}
