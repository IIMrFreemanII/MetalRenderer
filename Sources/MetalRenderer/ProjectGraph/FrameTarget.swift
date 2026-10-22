import Characters
import Effects
import EngineCore
import Physics
import Plants
import simd

/// Where the camera goes: what it frames of a scene (`scope`: MaterialAssignments.scope), its instances (where they are
/// when it gets there) or, failing those, a box.
package struct FrameTarget: Equatable {
    package var kind: SceneKind
    package var scope: String
    package var instances: [Int]
    package var box: Box?

    /// (As the memberwise initializer, for the modules above this one.)
    package init(kind: SceneKind, scope: String, instances: [Int], box: Box? = nil) {
        self.kind = kind
        self.scope = scope
        self.instances = instances
        self.box = box
    }
}
