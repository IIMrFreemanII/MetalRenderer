import Metal
import simd

// The Material Painter's structs shared with its shaders (MaterialShaders/Paint*.metal).

package struct PaintObjectArgs {
    package init() {}

    package var transform = matrix_identity_float4x4
    package var normalMatrix = matrix_identity_float4x4
    package var firstIndex: UInt32 = 0
    package var vertexOffset: UInt32 = 0
    package var size: UInt32 = 0
    package var triangles: UInt32 = 0
    package var texelsPerMetre: Float = 0
    package var heightDepth: Float = 0
    package var normalStrength: Float = 1
    package var layerCount: UInt32 = 0
    package var aoTexture: UInt32 = .max
    package var mirror: UInt32 = 0
    package var instance: UInt32 = 0
    package var level: Float = 0
}

package struct PaintDabArgs {
    package init() {}

    package var viewProjection = matrix_identity_float4x4
    package var camera = SIMD4<Float>.zero
    package var screen = SIMD2<Float>.zero
    package var dabs: UInt32 = 0
    package var stencil: UInt32 = 0
    package var stencilFrame = matrix_identity_float3x3
    package var tolerance: Float = 0.01
    package var fill: UInt32 = 0
    package var pad0: Float = 0, pad1: Float = 0
}
