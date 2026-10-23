import EngineCore
import Foundation
import simd

/// The viewport's camera as Blender's: a turntable round a pivot (yaw round the world's up, pitch round the view's
/// right), perspective or orthographic, the numpad's views (which go orthographic, Auto Perspective). Y is up; Blender's
/// front (numpad 1) looks from Blender's −Y, which is our +Z.
package struct ViewportCamera: Equatable {
    package var target = SIMD3<Float>.zero
    package var distance: Float = 10
    package var yaw: Float = 0.785          // round Y from +Z toward +X
    package var pitch: Float = -0.45        // down is negative
    package var orthographic = false
    package var fovY: Float = 0.69          // Blender's 50 mm lens on its 36 mm sensor, about
    package var near: Float = 0.01
    package var far: Float = 1000           // orthographic depth range
    /// The view the numpad last set (nil once orbited off it): what an orthographic grid lies in.
    package var aligned: AlignedView?
    /// Orthographic because a numpad view made it so, not because the user chose it (orbiting goes back).
    package var autoOrthographic = false

    package enum AlignedView: String, Codable { case front, back, right, left, top, bottom
        package var title: String { rawValue.capitalized }
    }

    package init() {
        // Blender's start-up view of its cube.
        target = .zero
        distance = 11
        yaw = 0.82
        pitch = -0.5
    }

    package var rotation: simd_quatf {
        simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
    }

    package var forward: SIMD3<Float> { rotation.act([0, 0, -1]) }
    package var right: SIMD3<Float> { rotation.act([1, 0, 0]) }
    package var up: SIMD3<Float> { rotation.act([0, 1, 0]) }
    package var eye: SIMD3<Float> { target - forward * distance }

    package var viewMatrix: float4x4 {
        let r = float3x3(rotation.inverse)
        let t = -(r * eye)
        return float4x4(columns: (SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(t, 1)))
    }

    /// Half the view's height in metres at the pivot (what an orthographic view shows).
    package var orthoHalfHeight: Float { distance * tan(fovY / 2) }

    /// Reverse Z: the near plane at depth 1; perspective has no far plane (depth → 0 at infinity).
    package func projection(aspect: Float) -> float4x4 {
        if orthographic {
            let h = orthoHalfHeight, w = h * aspect
            let depth = distance + far
            return float4x4(columns: (SIMD4(1 / w, 0, 0, 0), SIMD4(0, 1 / h, 0, 0),
                                      SIMD4(0, 0, 1 / (depth + far), 0), SIMD4(0, 0, (depth) / (depth + far), 1)))
        }
        let f = 1 / tan(fovY / 2)
        return float4x4(columns: (SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0), SIMD4(0, 0, 0, -1), SIMD4(0, 0, near, 0)))
    }

    package func viewProjection(aspect: Float) -> float4x4 { projection(aspect: aspect) * viewMatrix }

    // MARK: Rays and projection

    /// The ray through a point of a view of `size` (points, origin at the top left).
    package func ray(at point: SIMD2<Float>, size: SIMD2<Float>) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let ndc = SIMD2(point.x / size.x * 2 - 1, 1 - point.y / size.y * 2)
        let aspect = size.x / max(size.y, 1)
        if orthographic {
            let h = orthoHalfHeight
            let o = eye + right * ndc.x * h * aspect + up * ndc.y * h - forward * far
            return (o, forward)
        }
        let t = tan(fovY / 2)
        let d = simd_normalize(forward + right * ndc.x * t * aspect + up * ndc.y * t)
        return (eye, d)
    }

    /// Where a world point lands in a view of `size` (points, top left), and its depth along the view; nil behind
    /// the camera.
    package func project(_ p: SIMD3<Float>, size: SIMD2<Float>) -> SIMD3<Float>? {
        let c = viewProjection(aspect: size.x / max(size.y, 1)) * SIMD4(p, 1)
        guard c.w > 1e-6 else { return nil }
        let n = SIMD2(c.x, c.y) / c.w
        return SIMD3((n.x + 1) / 2 * size.x, (1 - n.y) / 2 * size.y, simd_dot(p - eye, forward))
    }

    /// Metres per point at depth `depth` (along the view): how far a drag of one point moves something there.
    package func metresPerPoint(depth: Float, viewHeight: Float) -> Float {
        let h = orthographic ? orthoHalfHeight : max(depth, near) * tan(fovY / 2)
        return 2 * h / max(viewHeight, 1)
    }

    // MARK: Navigation

    /// Middle-drag: turn round the pivot, as Blender's turntable (0.007 rad per point).
    package mutating func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.007
        pitch -= dy * 0.007
        pitch = max(-.pi / 2, min(.pi / 2, pitch))
        aligned = nil
        if autoOrthographic { orthographic = false; autoOrthographic = false }
    }

    /// Shift-middle-drag: move the pivot with the view, so what is under the cursor stays under it.
    package mutating func pan(dx: Float, dy: Float, viewHeight: Float) {
        let k = metresPerPoint(depth: distance, viewHeight: viewHeight)
        target += (-right * dx + up * dy) * k
    }

    /// Scroll or Ctrl-middle-drag: toward the pivot (factor < 1) or away.
    package mutating func dolly(_ factor: Float) {
        distance = max(1e-3, min(1e5, distance * factor))
    }

    /// Numpad 1, 3, 7 (Ctrl: the opposite side).
    package mutating func align(_ view: AlignedView) {
        switch view {
        case .front: yaw = 0; pitch = 0
        case .back: yaw = .pi; pitch = 0
        case .right: yaw = .pi / 2; pitch = 0
        case .left: yaw = -.pi / 2; pitch = 0
        case .top: yaw = 0; pitch = -.pi / 2
        case .bottom: yaw = 0; pitch = .pi / 2
        }
        aligned = view
        if !orthographic { orthographic = true; autoOrthographic = true }
    }

    /// Numpad 4, 6, 8, 2: turn by 15°.
    package mutating func step(yaw dyaw: Float, pitch dpitch: Float) {
        yaw += dyaw
        pitch = max(-.pi / 2, min(.pi / 2, pitch + dpitch))
        aligned = nil
        if autoOrthographic { orthographic = false; autoOrthographic = false }
    }

    /// Numpad 5.
    package mutating func toggleOrthographic() {
        orthographic.toggle()
        autoOrthographic = false
    }

    /// View Selected (numpad .) / View All (Home): the box fills the view.
    package mutating func frame(_ box: AABB, aspect: Float) {
        guard box.lo.x <= box.hi.x else { return }
        target = (box.lo + box.hi) / 2
        let radius = max(simd_length(box.hi - box.lo) / 2, 0.05)
        let fit = min(fovY, 2 * atan(tan(fovY / 2) * aspect))
        distance = radius / sin(fit / 2) * 1.05
    }

    /// The plane an orthographic grid lies in: 0 the floor, 1 the YZ plane (looking along X), 3 the XY plane.
    package var gridPlane: Int {
        guard orthographic, let aligned else { return 0 }
        switch aligned {
        case .front, .back: return 3
        case .right, .left: return 1
        case .top, .bottom: return 0
        }
    }
}
