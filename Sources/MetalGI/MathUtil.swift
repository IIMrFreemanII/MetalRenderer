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
}
