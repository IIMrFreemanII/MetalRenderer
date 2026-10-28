import Buildings
import Characters
import Effects
import EngineCore
import Landscape
import Materials
import Metal
import Physics
import Plants
import simd

// Structs shared with the shaders (Shaders/Types.metal unless a comment names another piece).
// Their memory layout MUST match the MSL structs of the same name exactly,
// so every struct is built from 16-byte vectors/matrices plus groups of four 32-bit scalars.

/// The reference path tracer's parameters (MSL PathTraceParams in Shaders/PathTrace.metal), passed with setBytes.
struct GPUPathTraceParams {
    var samples = SIMD4<UInt32>()   // x = paths in the mean so far, y = paths to add, z = bounces, w = light-tree nodes
    var config = SIMD4<UInt32>()    // x = flags (below), y = instances the light-proxy map covers, z = the average's seed
    var bounds = SIMD4<Float>()     // the scene's sphere (Scene.sceneSphere): the fog is inside it (the sun's and the sky's
                                    // light is what reaches the scene)

    static let sobol: UInt32 = 1    // Owen-scrambled Sobol samples (else white noise)
    static let fog: UInt32 = 2      // the fog's medium (FogParams at buffer 9, its noise at texture 1)
}

/// The lens and the finish (MSL PostParams), passed with setBytes to the kernels of Shaders/Post.metal.
struct GPUPostParams {
    var bloom = SIMD4<Float>()     // x = strength (0 = none), y = threshold, z = exposure (linear scale), w = levels
    var lens = SIMD4<Float>()      // x = aperture (output pixels), y = focus distance (m, 0 = auto), z = largest blur
                                   // radius (output pixels), w = autofocus easing per frame
    var finish = SIMD4<Float>()    // x = vignette, y = grain, z = chromatic aberration
    var size = SIMD4<UInt32>()     // xy = output size, zw = traced size
    var frame = SIMD4<UInt32>()    // x = frame index, y = bloom level being made
}

/// The light grid's parameters (MSL RegirParams): per level its jittered origin (xyz) and cell size (w).
package struct GPURegirParams {
    var origin0 = SIMD4<Float>(), origin1 = SIMD4<Float>(), origin2 = SIMD4<Float>(), origin3 = SIMD4<Float>()
    var config = SIMD4<UInt32>()   // x = cells per axis, y = levels, z = slots per cell, w = candidates per slot
    var consume = SIMD4<UInt32>()  // x = grid candidates per pixel (0 = off), y = frame seed
}

/// One reservoir of the light grid (MSL RegirReservoir), for its byte count.
struct GPURegirReservoir {
    var element: UInt32 = 0, uv: UInt32 = 0
    var W: Float = 0, target: Float = 0
}

/// The sky (MSL SkyParams): the per-slot copy lives in the shading arguments (SceneShading), the sky kernels get it directly.
package struct GPUSkyParams {
    var sun = SIMD4<Float>()          // xyz = toward the sun (unit), w = its angular radius. (The open world's night: the moon.)
    var sunTop = SIMD4<Float>()       // rgb = sun irradiance above the atmosphere (atmosphere mode)
    var sunGround = SIMD4<Float>()    // rgb = sun irradiance at the ground (the sun light's colour)
    var glow = SIMD4<Float>()         // xyz = toward what else lights the atmosphere: the sun under the horizon, once the
    var glowTop = SIMD4<Float>()      // moon is the light; rgb = its irradiance above the atmosphere (0 = nothing else)
                                      // glow.w = how bright the stars are (0 = none: by day)
    var cloudLayer = SIMD4<Float>()   // x = cloud base altitude (m), y = top (m), z = coverage (0...1), w = extinction (1/m)
    var cloudShape = SIMD4<Float>()   // x = shape noise tile (m), y = detail erosion, z = time (s), w = shadow strength
    var wind = SIMD4<Float>()         // xyz = wind (m/s), w = weight of a new cloud sample in a texel (1 = replace)
    var shadowMap = SIMD4<Float>()    // xy = centre (x, z) of the cloud-shadow square, z = its half size (m), w = ground height
    var ground = SIMD4<Float>()       // rgb = ground albedo below the horizon, w = the sky's observer altitude (m)
    var flags = SIMD4<UInt32>()       // x = mode (GPUSkyParams.atmosphere / .image), y = feature bits, z = update phase 0...15,
                                      // w = frame (jitters the cloud march)
    var place = SIMD4<Float>()        // xy = where the scene's origin is in the world (x, z), zw = the sky's observer in
                                      // the scene (x, z): the clouds are the world's

    static let atmosphere: UInt32 = 1, image: UInt32 = 2
    static let clouds: UInt32 = 1, shadows: UInt32 = 2, updateAll: UInt32 = 4, cloudsOverImage: UInt32 = 8
}

package struct GPUInstanceData {
    var transform: simd_float4x4       // object -> world, this frame
    var prevTransform: simd_float4x4   // object -> world, previous frame (motion vectors)
    var normalMatrix: simd_float4x4    // inverse-transpose of transform
    var meshIndex: UInt32
    var materialIndex: UInt32
    var pad0: UInt32 = 0               // instance mask (Scene.maskGeometry / maskLights), read by the cut
    var pad1: UInt32 = 0
}

/// One light; see the MSL struct for what each field holds per type (Scene.LightKind).
package struct GPULight {
    var positionRadius: SIMD4<Float>  // xyz = centre, w = radius (sphere, spot, tube, mesh bounds), angular radius (sun)
    var color: SIMD4<Float>           // rgb = intensity / irradiance (sun) / radiance (rect) / sum of L x area (mesh),
                                      // w = shadow-denoiser group (0...3) + 4 x type (GPULight.sphere...)
    var axis: SIMD4<Float>            // xyz = spot axis, rect normal, toward the sun, tube half axis, mesh mean normal;
                                      // w = mesh: its material, from its instance's first
    var params: SIMD4<Float>          // spot: cos outer, cos inner | rect: half-width tangent, half height
                                      // sun: light-map bounds centre, radius | mesh: first triangle, count, flatness,
                                      // instance (bit cast)

    static let sphere: Float = 0, spot: Float = 1, sun: Float = 2, rect: Float = 3, tube: Float = 4, mesh: Float = 5
}

/// Solid shading's look (RenderSettings.solidLook): MSL SolidParams (Shaders/Output.metal).
package struct GPUSolidParams {
    var sun: SIMD4<Float>     // xyz: toward the sun when the scene has none; w: shadows (1 / 0)
    var look: SIMD4<Float>    // x: each object's tint, y: broken faces (1 / 0), z: AO's reach (m), w: AO rays (0: none)
    var edges: SIMD4<Float>   // x: outlines (1 / 0), y: their width (pixels), z: material colours (1 / 0)
    var info: SIMD4<UInt32>   // x: how many materials the flags buffer has
}

/// The water this frame (MSL WaterScene, Shaders/WaterCommon.metal), its address in the shading arguments
/// (SceneShading.water): the time and wind of its waves, its map's two levels around the camera, the near patch, the
/// looks, and its textures (the map, the FFT cascades, the caustics) by their resource IDs.
struct GPUWaterScene {
    var time = SIMD4<Float>.zero       // x = now (s), y = the last frame's, z = dt, w = the highest any water's surface reaches (its waves too)
    var wind = SIMD4<Float>.zero       // xy = toward where it blows (unit; x, z), z = speed (m/s), w = 0
    var cascades = SIMD4<Float>.zero   // xyz = the FFT cascades' tile sides (m), w = how many (0: no waves)
    var phase0 = SIMD4<Float>.zero     // where the scene's origin is in each cascade's tile (m): xy = 0th, zw = 1st
    var phase1 = SIMD4<Float>.zero     // xy = the 2nd's
    var map0 = SIMD4<Float>.zero       // the map's near level: xy = scene x, z of texel (0, 0)'s corner, z = metres a texel, w = texels a side
    var map1 = SIMD4<Float>.zero       // ...its far level
    var near = SIMD4<Float>.zero       // xyz = the near patch's centre (scene), w = its radius (0: none)
    var counts = SIMD4<UInt32>.zero    // x = looks, y = WATER_* flags, w = METALRENDERER_WATER_DEBUG
    var looks: UInt64 = 0              // GPUWaterLook per look
    var level = MTLResourceID()        // map: 2D array [near, far], r = surface (< -1e8: dry), g = ground
    var info = MTLResourceID()         // map: rg = flow (m/s, 0.5 = still, 1/8 m/s a step: (v / 8) + 0.5), b = look / 255, a = turbulence
    var waves = MTLResourceID()        // FFT: 2D array per cascade, xyz = displacement (m), w = foam
    var slopes = MTLResourceID()       // FFT: 2D array per cascade, xy = height's slope (x, z), zw = sideways push's
    var caustics = MTLResourceID()     // the sun's caustics on a bed a few metres down, tiled as cascade 1
    var surfaces = MTLResourceID()     // the still surfaces' own structure (a primitive one, the scene's coordinates)
    var surfaceVertices: UInt64 = 0    // ...their vertices (float4), indices, and a look per triangle (a byte)
    var surfaceIndices: UInt64 = 0
    var surfaceLooks: UInt64 = 0
    var nearPatch = MTLResourceID()    // the near patch's structure (WATER_NEAR), refitted every frame
    var nearVertices: UInt64 = 0       // ...its vertices as the waves moved them (float4: w = the look)
    var nearIndices: UInt64 = 0
    var nearRest: UInt64 = 0           // ...and where each is at rest (float2: x, z)
    static let fft: UInt32 = 1, nearPatch: UInt32 = 2, causticsOn: UInt32 = 4, mapped: UInt32 = 8
}

func validateGPULayouts() {
    precondition(MemoryLayout<GPUWaterLook>.stride == 64, "GPUWaterLook layout mismatch")
    precondition(MemoryLayout<GPUWaterScene>.stride == 256, "GPUWaterScene layout mismatch")
    precondition(MemoryLayout<Uniforms>.stride == 304, "Uniforms layout mismatch")
    precondition(MemoryLayout<GPUMesh>.stride == 48 && MemoryLayout<GPUMesh>.offset(of: \.block) == 24, "GPUMesh layout mismatch")
    precondition(MemoryLayout<GPUInstanceData>.stride == 208, "GPUInstanceData layout mismatch")
    precondition(MemoryLayout<GPUSkinVertex>.stride == 16, "GPUSkinVertex layout mismatch")
    precondition(MemoryLayout<GPUJoint>.stride == 48, "GPUJoint layout mismatch")
    precondition(MemoryLayout<GPUJointMatrix>.stride == 48, "GPUJointMatrix layout mismatch")
    precondition(MemoryLayout<GPUPoseSlot>.stride == 32, "GPUPoseSlot layout mismatch")
    precondition(MemoryLayout<GPUMaterial>.stride == 64, "GPUMaterial layout mismatch")
    precondition(MemoryLayout<GPUMaterialExtra>.stride == 32, "GPUMaterialExtra layout mismatch")
    precondition(MemoryLayout<GPULight>.stride == 64, "GPULight layout mismatch")
    precondition(MemoryLayout<GPULightTableEntry>.stride == 16, "GPULightTableEntry layout mismatch")
    precondition(MemoryLayout<GPUTriangleInfo>.stride == 8, "GPUTriangleInfo layout mismatch")
    precondition(MemoryLayout<GPURestirParams>.stride == 32, "GPURestirParams layout mismatch")
    precondition(MemoryLayout<GPULightTreeNode>.stride == 64, "GPULightTreeNode layout mismatch")
    precondition(MemoryLayout<GPURestirGIParams>.stride == 48, "GPURestirGIParams layout mismatch")
    precondition(MemoryLayout<GPUEmissiveTriangle>.stride == 64, "GPUEmissiveTriangle layout mismatch")
    precondition(MemoryLayout<GPUFogVolume>.stride == 64, "GPUFogVolume layout mismatch")
    precondition(MemoryLayout<GPUPostParams>.stride == 80, "GPUPostParams layout mismatch")
    precondition(MemoryLayout<GPUPathTraceParams>.stride == 48, "GPUPathTraceParams layout mismatch")
    precondition(MemoryLayout<GPUSDFNode>.stride == 96, "GPUSDFNode layout mismatch")
    precondition(MemoryLayout<GPUSDFShape>.stride == 48, "GPUSDFShape layout mismatch")
    precondition(MemoryLayout<GPUSDFVolume>.stride == 48, "GPUSDFVolume layout mismatch")
    precondition(MemoryLayout<GPUFogParams>.stride == 128 + 64 * GPUFogParams.maxVolumes, "GPUFogParams layout mismatch")
    precondition(MemoryLayout<GPUSkyParams>.stride == 192, "GPUSkyParams layout mismatch")
    precondition(MemoryLayout<BVHNode>.stride == 64, "BVHNode layout mismatch")
    precondition(MemoryLayout<RCParams>.stride == 48, "RCParams layout mismatch")
    precondition(MemoryLayout<GPURegirParams>.stride == 96, "GPURegirParams layout mismatch")
    precondition(MemoryLayout<GPURegirReservoir>.stride == 16, "GPURegirReservoir layout mismatch")
    precondition(MemoryLayout<VGCluster>.stride == 80, "VGCluster layout mismatch")
    precondition(MemoryLayout<VirtualBLAS.Entry>.stride == 32, "VirtualBLAS.Entry (VGBlas) layout mismatch")
    precondition(MemoryLayout<VirtualGeometry.Params>.stride == 48, "VirtualGeometry.Params (VGParams) layout mismatch")
    precondition(MemoryLayout<GPUPhysicsBody>.stride == 128, "GPUPhysicsBody layout mismatch")
    precondition(MemoryLayout<GPUPhysicsShape>.stride == 64, "GPUPhysicsShape layout mismatch")
    precondition(MemoryLayout<GPUPhysicsPair>.stride == 16, "GPUPhysicsPair layout mismatch")
    precondition(MemoryLayout<GPUPhysicsContact>.stride == 64, "GPUPhysicsContact layout mismatch")
    precondition(MemoryLayout<GPUPhysicsParams>.stride == 160, "GPUPhysicsParams layout mismatch")
    precondition(MemoryLayout<GPUPhysicsTet>.stride == 32, "GPUPhysicsTet layout mismatch")
    precondition(MemoryLayout<GPUSoftVertex>.stride == 32, "GPUSoftVertex layout mismatch")
    precondition(MemoryLayout<GPUSoftEmbed>.stride == 32, "GPUSoftEmbed layout mismatch")
    precondition(MemoryLayout<GPUFleshHeader>.stride == 64, "GPUFleshHeader layout mismatch")
    precondition(MemoryLayout<GPUFleshPin>.stride == 48, "GPUFleshPin layout mismatch")
    precondition(MemoryLayout<GPUMuscle>.stride == 64, "GPUMuscle layout mismatch")
    precondition(MemoryLayout<GPUFleshFibre>.stride == 32, "GPUFleshFibre layout mismatch")
    precondition(MemoryLayout<GPUSkinAttach>.stride == 64, "GPUSkinAttach layout mismatch")
    precondition(MemoryLayout<GPUPhysicsConstraint>.stride == 16, "GPUPhysicsConstraint layout mismatch")
    precondition(MemoryLayout<GPUPhysicsParticle>.stride == 64, "GPUPhysicsParticle layout mismatch")
    precondition(MemoryLayout<GPUPhysicsGrab>.stride == 48, "GPUPhysicsGrab layout mismatch")
    precondition(MemoryLayout<GPUPhysicsJoint>.stride == 112, "GPUPhysicsJoint layout mismatch")
    precondition(MemoryLayout<GPUFractureNode>.stride == 64, "GPUFractureNode layout mismatch")
    precondition(MemoryLayout<GPUFractureWeld>.stride == 80, "GPUFractureWeld layout mismatch")
    precondition(MemoryLayout<GPUFractureState>.stride == 64, "GPUFractureState layout mismatch")
    precondition(MemoryLayout<GPUFractureCommand>.stride == 48, "GPUFractureCommand layout mismatch")
    precondition(MemoryLayout<GPUFractureParams>.stride == 48, "GPUFractureParams layout mismatch")
    precondition(MemoryLayout<GPULooseParams>.stride == 64, "GPULooseParams layout mismatch")
    precondition(MemoryLayout<GPUBreakEvent>.stride == 32, "GPUBreakEvent layout mismatch")
    precondition(MemoryLayout<GPUHairStrand>.stride == 64, "GPUHairStrand layout mismatch")
    precondition(MemoryLayout<GPUHairVertex>.stride == 64, "GPUHairVertex layout mismatch")
    precondition(MemoryLayout<GPUHairParams>.stride == 64, "GPUHairParams layout mismatch")
    precondition(MemoryLayout<GPUHairGroup>.stride == 64, "GPUHairGroup layout mismatch")
    precondition(MemoryLayout<GPUFluidParticle>.stride == 80, "GPUFluidParticle layout mismatch")
    precondition(MemoryLayout<GPUFluidParams>.stride == 224, "GPUFluidParams layout mismatch")
    precondition(MemoryLayout<GPUFluidSurface>.stride == 80, "GPUFluidSurface layout mismatch")
    precondition(MemoryLayout<GPUParticle>.stride == 48, "GPUParticle layout mismatch")
    precondition(MemoryLayout<GPUParticleRender>.stride == 80, "GPUParticleRender layout mismatch")
    precondition(MemoryLayout<GPUParticleField>.stride == 48, "GPUParticleField layout mismatch")
    precondition(MemoryLayout<GPUParticleEmitter>.stride == 352, "GPUParticleEmitter layout mismatch")
    precondition(MemoryLayout<GPUParticleCollider>.stride == 32, "GPUParticleCollider layout mismatch")
    precondition(MemoryLayout<GPUParticleStep>.stride == 64, "GPUParticleStep layout mismatch")
    precondition(MemoryLayout<SIMD3<Float>>.stride == 16, "float3 must be 16 bytes to match MSL")
}
