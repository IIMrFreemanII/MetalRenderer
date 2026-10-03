import Darwin
import simd

func translate(_ t: SIMD3<Float>) -> float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4<Float>(t, 1)
    return m
}

func scale(_ s: SIMD3<Float>) -> float4x4 {
    float4x4(diagonal: SIMD4<Float>(s, 1))
}

func scale(_ s: Float) -> float4x4 {
    scale(SIMD3<Float>(repeating: s))
}

func rotate(_ angle: Float, _ axis: SIMD3<Float>) -> float4x4 {
    float4x4(simd_quatf(angle: angle, axis: normalize(axis)))
}

struct Camera {
    var position = SIMD3<Float>(0, 2.4, 4.6)
    var yaw: Float = 0          // radians, 0 looks down -Z
    var pitch: Float = -0.06    // radians
    var fovY: Float = 60 * .pi / 180

    var forward: SIMD3<Float> {
        SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), -cos(pitch) * cos(yaw))
    }
    var right: SIMD3<Float> { normalize(cross(forward, SIMD3<Float>(0, 1, 0))) }
    var up: SIMD3<Float> { cross(right, forward) }

    /// The depth of the near plane in the reversed-Z depth the upscalers read (Shaders.metal's NEAR_PLANE).
    static let nearPlane: Float = 0.05

    /// World to view space, right-handed: x = right, y = up, the camera looks down -z. The kernels trace from the
    /// camera's vectors; only MetalFX's denoising scaler asks for matrices.
    var worldToView: float4x4 {
        let r = right, u = up, f = forward, p = position
        return float4x4(columns: (SIMD4(r.x, u.x, -f.x, 0), SIMD4(r.y, u.y, -f.y, 0), SIMD4(r.z, u.z, -f.z, 0),
                                  SIMD4(-dot(r, p), -dot(u, p), dot(f, p), 1)))
    }

    /// View to clip space for a `width` x `height` image: no far plane, and reversed depth, z / w = nearPlane / view
    /// depth, as traceKernel writes it for the upscalers.
    func viewToClip(aspect: Float) -> float4x4 {
        let tanY = tan(fovY / 2)
        return float4x4(columns: (SIMD4(1 / (tanY * aspect), 0, 0, 0), SIMD4(0, 1 / tanY, 0, 0),
                                  SIMD4(0, 0, 0, -1), SIMD4(0, 0, Camera.nearPlane, 0)))
    }
}
