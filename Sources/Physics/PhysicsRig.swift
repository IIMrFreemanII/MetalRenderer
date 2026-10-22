import EngineCore
import Foundation
import Plants
import simd

/// A skeleton the flesh hangs on (PhysicsFlesh.swift), in its rest pose: its bones, each a body and the shape that
/// stands for it, where each was at rest (the space the flesh is built in), and what part of a body each is (the
/// muscles find their bones by it).
package struct FleshFigure {
    package enum Role: Equatable {
        case pelvis, spine, chest, neck, head
        case upperArm(Float), forearm(Float), hand(Float)   // the side: -1 (the figure's right, -x) or 1
        case thigh(Float), shin(Float), foot(Float)
    }

    package struct Bone {
        package var role: Role
        package var body: Int
        /// Its SDF shape (a single primitive at its origin) and where that is at rest.
        package var shape: SDFShape
        package var rest: float4x4
        /// The body's pose at rest (centre of mass, rotation): what its pins' rest points are in.
        package var restPose: (position: SIMD3<Float>, rotation: SIMD4<Float>)
        /// The bone along its length at rest (from its joint to the next), and how thick it is there.
        package var from: SIMD3<Float>
        package var to: SIMD3<Float>
        package var thickness: Float
        /// Drawn on its body, with no flesh of its own (a head, a hand, a foot).
        package var rigid: Bool
        /// The bone it hangs from (-1: none): its joint with it is at its `from`.
        package var parent = -1

        /// (As the memberwise initializer, for the modules above this one.)
        package init(role: Role, body: Int, shape: SDFShape, rest: float4x4, restPose: (position: SIMD3<Float>, rotation: SIMD4<Float>), from: SIMD3<Float>, to: SIMD3<Float>, thickness: Float, rigid: Bool, parent: Int = -1) {
            self.role = role
            self.body = body
            self.shape = shape
            self.rest = rest
            self.restPose = restPose
            self.from = from
            self.to = to
            self.thickness = thickness
            self.rigid = rigid
            self.parent = parent
        }
    }

    package var bones: [Bone]
    /// Its bodies: they don't meet its flesh (GPUPhysicsParticle.info.z).
    package var bodies: Range<Int> { (bones.map(\.body).min() ?? 0)..<((bones.map(\.body).max() ?? -1) + 1) }

    package func bone(_ role: Role) -> Bone? { bones.first { $0.role == role } }

    /// Whether flesh at `p` (rest space) may bind bones `a` and `b` together: one hangs from the other and `p` is at
    /// their joint (within 1.5 times the hanging one's thickness of it). Elsewhere a limb lying against another, or
    /// against the trunk, is apart from it.
    package func joins(_ a: Int, _ b: Int, at p: SIMD3<Float>) -> Bool {
        let child = bones[a].parent == b ? a : bones[b].parent == a ? b : -1
        guard child >= 0 else { return false }
        return simd_length(p - bones[child].from) < 1.5 * bones[child].thickness
    }

    /// Its shape's distance at `p` (rest space), with how deep in it that is (0 on its axis, 1 on its surface).
    package func depth(_ b: Bone, _ p: SIMD3<Float>) -> Float {
        1 + b.shape.distance(PhysicsMath.xyz(b.rest.inverse * SIMD4(p, 1))).d / b.thickness
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(bones: [Bone]) {
        self.bones = bones
    }
}
