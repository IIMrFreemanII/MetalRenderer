import simd

// Structs shared with Shaders.metal.
// Their memory layout MUST match the MSL structs of the same name exactly,
// so every struct is built from 16-byte vectors/matrices plus groups of four 32-bit scalars.

struct Uniforms {
    var camPos = SIMD4<Float>()          // xyz = camera position
    var camRight = SIMD4<Float>()        // xyz = right vector,   w = tan(fovX / 2)
    var camUp = SIMD4<Float>()           // xyz = up vector,      w = tan(fovY / 2)
    var camForward = SIMD4<Float>()      // xyz = forward vector
    var prevCamPos = SIMD4<Float>()      // previous frame's camera (for motion vectors)
    var prevCamRight = SIMD4<Float>()
    var prevCamUp = SIMD4<Float>()
    var prevCamForward = SIMD4<Float>()
    var skyColor = SIMD4<Float>()
    var width: UInt32 = 0
    var height: UInt32 = 0
    var frameIndex: UInt32 = 0
    var lightCount: UInt32 = 0
    var bounces: UInt32 = 0
    var flags: UInt32 = 0
    var viewMode: UInt32 = 0
    var instanceCount: UInt32 = 0
    var jitter = SIMD4<Float>()          // xy = this frame's sub-pixel jitter, zw = previous frame's (pixels)
    var denoise = SIMD4<Float>()         // x = luminance sigma, y = max history frames, z = anti-lag strength
    var lightGroupEnd = SIMD4<UInt32>()  // lights are sorted by shadow-denoiser group: group g = [end[g-1], end[g])
}

enum UniformFlags {
    static let historyValid: UInt32 = 1
    static let denoise: UInt32 = 2
    static let upscale: UInt32 = 4   // MetalFX on: write depth + motion for it, composite outputs linear color
    static let blueNoise: UInt32 = 8 // sample with the blue-noise texture instead of the hash RNG
    static let separateSignals: UInt32 = 16  // direct and indirect light were denoised separately
    static let noClamp: UInt32 = 32          // no firefly clamp (reference images)
    static let lightMaps: UInt32 = 64        // path tracer: bounce lighting from light-visibility maps
    static let shadowDenoiser: UInt32 = 128  // direct light = exact unshadowed light x denoised per-group visibility
    static let allLights: UInt32 = 256       // one shadow ray per light even with more than 4 (references, baseline)
}

struct GPUMesh {
    var firstIndex: UInt32
    var indexCount: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

struct GPUInstanceData {
    var transform: simd_float4x4       // object -> world, this frame
    var prevTransform: simd_float4x4   // object -> world, previous frame (motion vectors)
    var normalMatrix: simd_float4x4    // inverse-transpose of transform
    var meshIndex: UInt32
    var materialIndex: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

struct GPUMaterial {
    var albedo: SIMD4<Float>     // rgb = diffuse reflectance
    var emission: SIMD4<Float>   // rgb = emitted radiance
}

struct GPULight {
    var positionRadius: SIMD4<Float>  // xyz = center, w = sphere radius
    var color: SIMD4<Float>           // rgb = radiant intensity (color * power), w = shadow-denoiser group (0...3)
}

/// Catches accidental layout drift between Swift and MSL at startup.
func validateGPULayouts() {
    precondition(MemoryLayout<Uniforms>.stride == 224, "Uniforms layout mismatch")
    precondition(MemoryLayout<GPUMesh>.stride == 16, "GPUMesh layout mismatch")
    precondition(MemoryLayout<GPUInstanceData>.stride == 208, "GPUInstanceData layout mismatch")
    precondition(MemoryLayout<GPUMaterial>.stride == 32, "GPUMaterial layout mismatch")
    precondition(MemoryLayout<GPULight>.stride == 32, "GPULight layout mismatch")
    precondition(MemoryLayout<BVHNode>.stride == 64, "BVHNode layout mismatch")
    precondition(MemoryLayout<RTInstance>.stride == 64, "RTInstance layout mismatch")
    precondition(MemoryLayout<RCParams>.stride == 48, "RCParams layout mismatch")
    precondition(MemoryLayout<SIMD3<Float>>.stride == 16, "float3 must be 16 bytes to match MSL")
}
