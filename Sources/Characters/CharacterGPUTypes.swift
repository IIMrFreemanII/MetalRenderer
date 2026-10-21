import Metal
import Physics
import Plants
import simd

// The characters' structs shared with the shaders (Shaders/Crowd.metal). Their memory layout MUST match the MSL
// structs of the same name exactly (validateGPULayouts, in the engine, checks every one).

/// A skinned vertex's joints and weights (MSL SkinVertex, Shaders/Crowd.metal).
package struct GPUSkinVertex: Equatable {
    package var joints: UInt32 = 0     // four joint indices, a byte each (the first in the low byte)
    package var w0: Float = 1          // the first three joints' weights; the fourth's is what is left of 1
    package var w1: Float = 0
    package var w2: Float = 0
}

/// A skeleton's joint (MSL CrowdJoint): where it sits in its parent, and its inverse bind transform (a rotation,
/// then a translation), which takes a bind-pose vertex into the joint's space.
package struct GPUJoint: Equatable {
    package var local: SIMD4<Float>      // xyz = translation in the parent's space (m), w = the parent's index + 1 (bits; 0 = root)
    package var inverseBindRotation: SIMD4<Float>      // quaternion, xyzw
    package var inverseBindTranslation: SIMD4<Float>   // xyz

    package var parent: Int { Int(local.w.bitPattern) - 1 }
}

/// A joint's skinning matrix in a pose (MSL JointMatrix): the three rows of bind space -> posed space.
package struct GPUJointMatrix: Equatable {
    package var row0 = SIMD4<Float>(1, 0, 0, 0), row1 = SIMD4<Float>(0, 1, 0, 0), row2 = SIMD4<Float>(0, 0, 1, 0)

    package func point(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = SIMD4(p, 1)
        return SIMD3(dot(row0, v), dot(row1, v), dot(row2, v))
    }
    package func direction(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let v = SIMD4(d, 0)
        return SIMD3(dot(row0, v), dot(row1, v), dot(row2, v))
    }
}

/// A pose of the crowd at one time (MSL PoseSlot): two clips of its character, each at a time in keys, and how far
/// the pose is from the first toward the second. A clip is named by where its keys start in the crowd's key tables.
package struct GPUPoseSlot: Equatable {
    package var rotationsA: UInt32 = 0   // clip A's first rotation key (a quaternion per joint and key)
    package var rootA: UInt32 = 0        // its first root-translation key
    package var rotationsB: UInt32 = 0
    package var rootB: UInt32 = 0
    package var timeA: Float = 0         // in keys, inside the loop
    package var timeB: Float = 0
    package var blend: Float = 0         // 0 = clip A alone
    package var pad: Float = 0
}
