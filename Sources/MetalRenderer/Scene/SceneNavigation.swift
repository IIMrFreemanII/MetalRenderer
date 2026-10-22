import Characters
import EngineCore
import Physics
import Plants
import simd

/// What the scene view's camera turns about (Unity's pivot): a point in front of it, and how far it is. The camera is
/// always at `target - forward * distance`: orbiting turns it about the target, looking around moves the target with the
/// view, panning moves both, and a dolly changes the distance.
package struct ViewPivot: Equatable {
    var target: SIMD3<Float>
    var distance: Float
}

/// The six views the scene gizmo snaps to: from the side its axis points to, looking back along it.
package enum ViewAxis: Int, CaseIterable {
    case right, left, top, bottom, front, back

    /// The world axis (+X right, +Y up, +Z towards the default camera, which looks down -Z).
    package var direction: SIMD3<Float> {
        switch self {
        case .right: return [1, 0, 0]
        case .left: return [-1, 0, 0]
        case .top: return [0, 1, 0]
        case .bottom: return [0, -1, 0]
        case .front: return [0, 0, 1]
        case .back: return [0, 0, -1]
        }
    }

    package var title: String {
        switch self {
        case .right: return "Right"
        case .left: return "Left"
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .front: return "Front"
        case .back: return "Back"
        }
    }

    /// The positive axes are labelled and coloured; the negative ones are grey.
    package var isPositive: Bool { self == .right || self == .top || self == .front }
    /// Its letter (X, Y, Z).
    package var letter: String { self == .right || self == .left ? "X" : self == .top || self == .bottom ? "Y" : "Z" }

    /// The view the camera looks from along `forward`, if it is one of the six (within about a degree).
    package static func snapped(_ forward: SIMD3<Float>) -> ViewAxis? {
        allCases.first { dot(-$0.direction, forward) > 0.9998 }
    }
}

extension Camera {
    /// The pitch the scene view goes up to: Top and Bottom are a hair off straight, so `right` stays defined.
    package static let pitchLimit: Float = .pi / 2 - 1e-3
    /// Radians a drag turns per point.
    package static let turnRate: Float = 0.004
    /// How near and far a dolly goes (as the workshops' scroll did).
    package static let pivotDistances: ClosedRange<Float> = 0.3...1000
    /// The pivot's distance where nothing has set one (Unity's starts in front of the camera too).
    package static let defaultPivotDistance: Float = 8

    /// The pivot `distance` in front of the camera.
    package func pivot(at distance: Float = Camera.defaultPivotDistance) -> ViewPivot {
        ViewPivot(target: position + forward * distance, distance: distance)
    }

    private mutating func turn(dx: Float, dy: Float) {
        yaw += dx * Camera.turnRate
        pitch = min(max(pitch - dy * Camera.turnRate, -Camera.pitchLimit), Camera.pitchLimit)
    }

    /// Option-drag: turned about the pivot (`dx`, `dy`: the drag in points), at the pivot's distance.
    package mutating func orbit(dx: Float, dy: Float, about p: ViewPivot) {
        turn(dx: dx, dy: dy)
        position = p.target - forward * p.distance
    }

    /// Right-drag: turned where it is; the pivot moves with the view.
    package mutating func look(dx: Float, dy: Float, pivot p: ViewPivot) -> ViewPivot {
        turn(dx: dx, dy: dy)
        return pivot(at: p.distance)
    }

    /// Middle-drag: moved across the view so the pivot's depth follows the cursor (`delta`: how far it moved, 0...1
    /// across and down the view); the pivot moves the same way.
    package mutating func pan(by delta: SIMD2<Float>, pivot p: ViewPivot, aspect: Float) -> ViewPivot {
        let tanY = tan(fovY / 2)
        let move = -right * (delta.x * 2 * tanY * aspect * p.distance) + up * (delta.y * 2 * tanY * p.distance)
        position += move
        return ViewPivot(target: p.target + move, distance: p.distance)
    }

    /// Scroll, Option-right-drag: nearer the pivot (`factor` < 1) or farther, within `pivotDistances`.
    package mutating func dolly(by factor: Float, pivot p: ViewPivot) -> ViewPivot {
        let d = min(max(p.distance * factor, Camera.pivotDistances.lowerBound), Camera.pivotDistances.upperBound)
        position = p.target - forward * d
        return ViewPivot(target: p.target, distance: d)
    }

    /// The yaw and pitch that look from `axis`'s side along it (Top and Bottom keep `yaw`).
    package static func angles(viewing axis: ViewAxis, yaw: Float) -> (yaw: Float, pitch: Float) {
        let f = -axis.direction
        if abs(f.y) > 0.5 { return (yaw, f.y > 0 ? pitchLimit : -pitchLimit) }
        return (atan2(f.x, -f.z), 0)
    }

    /// The scene gizmo's drag: `yawSteps` and `pitchSteps` 45° steps on from the nearest 45° view.
    package static func stepped(yaw: Float, pitch: Float, yawSteps: Int, pitchSteps: Int) -> (yaw: Float, pitch: Float) {
        let step = Float.pi / 4
        let y = ((yaw / step).rounded() + Float(yawSteps)) * step
        let p = min(max((pitch / step).rounded() + Float(pitchSteps), -2), 2) * step
        return (y, min(max(p, -pitchLimit), pitchLimit))
    }
}
