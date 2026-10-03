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
    var lightTable = SIMD4<UInt32>()     // x = light-table entries (after the lights in their buffer), y = suns, z / w = sun lights
    var post = SIMD4<Float>(1, 0, 0, 0)  // x = exposure (linear scale), y = tone curve (ToneMap's raw value)
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
    static let specular: UInt32 = 512        // specular materials: material G-buffer, reflection pass, specular composite
    static let reference: UInt32 = 1024      // accumulated reference: reflections follow full paths
    static let meshLights: UInt32 = 2048     // with the shadow denoiser: composite adds the denoised mesh-light direct light
    static let fog: UInt32 = 4096            // composite applies the volumetric fog (froxel grid, or the reference march)
    static let fogReference: UInt32 = 8192   // with fog: read the per-pixel reference march instead of the froxel grid
    static let skyMap: UInt32 = 16384        // the sky comes from the sky texture (atmosphere or image), not skyColor
    static let restir: UInt32 = 32768        // direct light from ReSTIR DI (restirTemporalKernel / restirSpatialKernel)
    static let hdrOutput: UInt32 = 65536     // MetalFX's denoising scaler follows: the composite writes raw light and guides
}

/// ReSTIR DI pass parameters (MSL RestirParams).
struct GPURestirParams {
    var config = SIMD4<UInt32>()   // x = candidates, y = max M, z = GPURestirParams flags, w = spatial samples
    var tuning = SIMD4<Float>()    // x = spatial radius (pixels), y = spatial pass index, z = firefly clamp (0 = off)

    static let temporalValid: UInt32 = 1    // last frame's reservoirs can be reprojected
    static let visibilityReuse: UInt32 = 2  // test the initial pick's visibility
    static let shade: UInt32 = 4            // this spatial pass is the last: shade and write the outputs
    static let split: UInt32 = 8            // write unshadowed light and visibility apart (the shadow denoiser filters it)
}

/// The light grid's parameters (MSL RegirParams): per level its jittered origin (xyz) and cell size (w).
struct GPURegirParams {
    var origin0 = SIMD4<Float>(), origin1 = SIMD4<Float>(), origin2 = SIMD4<Float>(), origin3 = SIMD4<Float>()
    var config = SIMD4<UInt32>()   // x = cells per axis, y = levels, z = slots per cell, w = candidates per slot
    var consume = SIMD4<UInt32>()  // x = grid candidates per pixel (0 = off), y = frame seed
}

/// One reservoir of the light grid (MSL RegirReservoir), for its byte count.
struct GPURegirReservoir {
    var element: UInt32 = 0, uv: UInt32 = 0
    var W: Float = 0, target: Float = 0
}

/// ReSTIR GI pass parameters (MSL RestirGIParams).
struct GPURestirGIParams {
    var config = SIMD4<UInt32>()   // x = GPURestirGIParams flags, y = max M, z = spatial samples, w = spatial pass index
    var tuning = SIMD4<Float>()    // x = spatial radius (pixels), y = minimum distance in the target (m), z = firefly clamp (0 = off)
    var extra = SIMD4<UInt32>()    // x = 1: quarter budget, y = bounces, z = max sample age (frames)

    static let temporalValid: UInt32 = 1    // last frame's reservoirs can be reprojected
    static let shade: UInt32 = 2            // this spatial pass is the last: trace the visibility ray, write `indirect`
    static let lightMaps: UInt32 = 4        // light the paths' hits from the light maps (no shadow rays)
    static let feedback: UInt32 = 8         // multi-bounce: the paths' last hits add last frame's indirect light
    static let unbiased: UInt32 = 16        // spatial reuse traces a ray per neighbour (visibility in its MIS weight)
    static let keepFeedback: UInt32 = 32    // the last spatial pass also keeps its result for next frame's feedback
    static let fallback: UInt32 = 64        // feedback: off-screen path ends add last frame's mean indirect light
}

/// The sky (MSL SkyParams): the per-slot copy lives in the shading arguments (SceneShading), the sky kernels get it directly.
struct GPUSkyParams {
    var sun = SIMD4<Float>()          // xyz = toward the sun (unit), w = its angular radius
    var sunTop = SIMD4<Float>()       // rgb = sun irradiance above the atmosphere (atmosphere mode)
    var sunGround = SIMD4<Float>()    // rgb = sun irradiance at the ground (the sun light's colour)
    var cloudLayer = SIMD4<Float>()   // x = cloud base altitude (m), y = top (m), z = coverage (0...1), w = extinction (1/m)
    var cloudShape = SIMD4<Float>()   // x = shape noise tile (m), y = detail erosion, z = time (s), w = shadow strength
    var wind = SIMD4<Float>()         // xyz = wind (m/s), w = weight of a new cloud sample in a texel (1 = replace)
    var shadowMap = SIMD4<Float>()    // xy = centre (x, z) of the cloud-shadow square, z = its half size (m), w = ground height
    var ground = SIMD4<Float>()       // rgb = ground albedo below the horizon, w = the sky's observer altitude (m)
    var flags = SIMD4<UInt32>()       // x = mode (GPUSkyParams.atmosphere / .image), y = feature bits, z = update phase 0...15,
                                      // w = frame (jitters the cloud march)

    static let atmosphere: UInt32 = 1, image: UInt32 = 2
    static let clouds: UInt32 = 1, shadows: UInt32 = 2, updateAll: UInt32 = 4, cloudsOverImage: UInt32 = 8
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
    var pad0: UInt32 = 0               // instance mask (Scene.maskGeometry / maskLights), read by the custom ray tracer
    var pad1: UInt32 = 0
}

struct GPUMaterial {
    var albedo: SIMD4<Float>     // rgb = base colour (diffuse reflectance for non-metals), a = metallic
    var emission: SIMD4<Float>   // rgb = emitted radiance, a = roughness
    var params = SIMD4<Float>(0, 1, 0, 0)   // x = specular weight (0 = diffuse only, the generated scenes), y = normal scale
    var textures = SIMD4<UInt32>(repeating: .max)   // base colour, metallic-roughness, normal, emissive: Scene.textures
                                                    // index, or ~0 = none
}

/// One light; see the MSL struct for what each field holds per type (Scene.LightKind).
struct GPULight {
    var positionRadius: SIMD4<Float>  // xyz = centre, w = radius (sphere, spot, tube, mesh bounds), angular radius (sun)
    var color: SIMD4<Float>           // rgb = intensity / irradiance (sun) / radiance (rect) / sum of L x area (mesh),
                                      // w = shadow-denoiser group (0...3) + 4 x type (GPULight.sphere...)
    var axis: SIMD4<Float>            // xyz = spot axis, rect normal, toward the sun, tube half axis, mesh mean normal
    var params: SIMD4<Float>          // spot: cos outer, cos inner | rect: half-width tangent, half height
                                      // sun: light-map bounds centre, radius | mesh: first triangle, count, flatness,
                                      // instance (bit cast)

    static let sphere: Float = 0, spot: Float = 1, sun: Float = 2, rect: Float = 3, tube: Float = 4, mesh: Float = 5
}

/// One triangle of an emissive-mesh light, object space (MSL EmissiveTriangle).
struct GPUEmissiveTriangle {
    var v0: SIMD4<Float>     // w = cumulative selection probability within its light
    var e1: SIMD4<Float>     // w = uv0.x
    var e2: SIMD4<Float>     // w = uv0.y
    var uv12: SIMD4<Float>   // uv1, uv2
}

/// A local fog volume (MSL FogVolume): a soft-edged box or sphere of denser fog.
struct GPUFogVolume {
    var centerShape = SIMD4<Float>()     // xyz = centre, w = shape (0 = box, 1 = sphere)
    var extentDensity = SIMD4<Float>()   // xyz = half extents (sphere: x = radius), w = extinction at the bottom (1/m)
    var albedoEdge = SIMD4<Float>()      // rgb = single-scattering albedo, w = edge softness (m)
    var params = SIMD4<Float>()          // x = noise amount, y = height falloff inside (1/m, from the bottom)
}

/// Volumetric fog parameters (MSL FogParams), passed with setBytes to the fog kernels, the composite and reflections.
struct GPUFogParams {
    static let maxVolumes = 8
    var medium = SIMD4<Float>()          // x = height-fog extinction at the base (1/m), y = height falloff (1/m),
                                         // z = base height (constant below), w = anisotropy g (Henyey-Greenstein)
    var albedo = SIMD4<Float>()          // rgb = height fog's albedo, w = ambient: sky colour x w lights the fog evenly
    var noise = SIMD4<Float>()           // x = height fog's noise amount, y = noise tile size (m), z = time (s), w = this frame's weight in the froxel history
    var wind = SIMD4<Float>()            // xyz = wind (m/s): the noise drifts with it
    var grid = SIMD4<Float>()            // x = near, y = far (view depth), z = log(far / near), w = depth slices
    var counts = SIMD4<UInt32>()         // x, y = froxel columns and rows, z = volume count, w = FogParams flags
    var volumes = (GPUFogVolume(), GPUFogVolume(), GPUFogVolume(), GPUFogVolume(),
                   GPUFogVolume(), GPUFogVolume(), GPUFogVolume(), GPUFogVolume())

    static let historyValid: UInt32 = 1  // last frame's froxel grid matches: reproject it
    static let reflections: UInt32 = 2   // reflection rays are fogged too
    static let enabled: UInt32 = 4       // fog is on (reflections test it)

    mutating func setVolume(_ i: Int, _ v: GPUFogVolume) {
        withUnsafeMutableBytes(of: &volumes) { raw in
            raw.storeBytes(of: v, toByteOffset: i * MemoryLayout<GPUFogVolume>.stride, as: GPUFogVolume.self)
        }
    }
}

/// Catches accidental layout drift between Swift and MSL at startup.
func validateGPULayouts() {
    precondition(MemoryLayout<Uniforms>.stride == 256, "Uniforms layout mismatch")
    precondition(MemoryLayout<GPUMesh>.stride == 16, "GPUMesh layout mismatch")
    precondition(MemoryLayout<GPUInstanceData>.stride == 208, "GPUInstanceData layout mismatch")
    precondition(MemoryLayout<GPUMaterial>.stride == 64, "GPUMaterial layout mismatch")
    precondition(MemoryLayout<GPULight>.stride == 64, "GPULight layout mismatch")
    precondition(MemoryLayout<GPULightTableEntry>.stride == 16, "GPULightTableEntry layout mismatch")
    precondition(MemoryLayout<GPUTriangleInfo>.stride == 8, "GPUTriangleInfo layout mismatch")
    precondition(MemoryLayout<GPURestirParams>.stride == 32, "GPURestirParams layout mismatch")
    precondition(MemoryLayout<GPURestirGIParams>.stride == 48, "GPURestirGIParams layout mismatch")
    precondition(MemoryLayout<GPUEmissiveTriangle>.stride == 64, "GPUEmissiveTriangle layout mismatch")
    precondition(MemoryLayout<GPUFogVolume>.stride == 64, "GPUFogVolume layout mismatch")
    precondition(MemoryLayout<GPUFogParams>.stride == 96 + 64 * GPUFogParams.maxVolumes, "GPUFogParams layout mismatch")
    precondition(MemoryLayout<GPUSkyParams>.stride == 144, "GPUSkyParams layout mismatch")
    precondition(MemoryLayout<BVHNode>.stride == 64, "BVHNode layout mismatch")
    precondition(MemoryLayout<RTInstance>.stride == 64, "RTInstance layout mismatch")
    precondition(MemoryLayout<RCParams>.stride == 48, "RCParams layout mismatch")
    precondition(MemoryLayout<GPURegirParams>.stride == 96, "GPURegirParams layout mismatch")
    precondition(MemoryLayout<GPURegirReservoir>.stride == 16, "GPURegirReservoir layout mismatch")
    precondition(MemoryLayout<VGCluster>.stride == 80, "VGCluster layout mismatch")
    precondition(MemoryLayout<VirtualBLAS.Entry>.stride == 32, "VirtualBLAS.Entry (VGBlas) layout mismatch")
    precondition(MemoryLayout<VirtualGeometry.Params>.stride == 48, "VirtualGeometry.Params (VGParams) layout mismatch")
    precondition(MemoryLayout<SIMD3<Float>>.stride == 16, "float3 must be 16 bytes to match MSL")
}
