import simd

// Structs shared with the shaders (Shaders/Types.metal unless a comment names another piece).
// Their memory layout MUST match the MSL structs of the same name exactly,
// so every struct is built from 16-byte vectors/matrices plus groups of four 32-bit scalars.

struct Uniforms {
    var camPos = SIMD4<Float>()          // xyz = camera position
    var camRight = SIMD4<Float>()        // xyz = right vector,   w = tan(fovX / 2)
    var camUp = SIMD4<Float>()           // xyz = up vector,      w = tan(fovY / 2)
    var camForward = SIMD4<Float>()      // xyz = forward vector, w = RasterClusters.bias where the raster draws clusters
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

    /// traceKernel's own flags (MSL tracePassFlags), for the variant with them compiled in.
    static let traceBounces: UInt32 = 1      // the path tracer's indirect light (`bounces` > 0)
    static let traceManyLights: UInt32 = 2   // more analytic lights than shadow-denoiser groups
    var tracePassFlags: UInt32 { (bounces > 0 ? Uniforms.traceBounces : 0) | (lightGroupEnd.w > 4 ? Uniforms.traceManyLights : 0) }
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
    static let restir: UInt32 = 32768        // direct light from a pass of its own: ReSTIR DI or MegaLights
    static let hdrOutput: UInt32 = 65536     // MetalFX's denoising scaler follows: the composite writes raw light and guides
    static let wind: UInt32 = 131072         // the wind turns the plants' parts (assemblies; the ray queries' variants)
    static let giDebug: UInt32 = 262144      // this frame's GI method writes the "GI debug" view (cascades, ReSTIR GI, Lumen)
    static let post: UInt32 = 524288         // the lens effects follow (Post.metal): the composite writes the light as it is
    static let visBuffer: UInt32 = 1048576   // traceKernel takes its primary hits from the raster visibility buffer
    static let vsm: UInt32 = 2097152         // the camera's surfaces' shadows through virtual shadow maps (VSM.swift)
    static let giRadiance: UInt32 = 4194304  // the composite keeps the lit diffuse light for Lumen's screen traces
}

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

/// ReSTIR DI pass parameters (MSL RestirParams).
struct GPURestirParams {
    var config = SIMD4<UInt32>()   // x = candidates, y = max M, z = GPURestirParams flags, w = spatial samples
    var tuning = SIMD4<Float>()    // x = spatial radius (pixels), y = spatial pass index, z = firefly clamp (0 = off)

    static let temporalValid: UInt32 = 1    // last frame's reservoirs can be reprojected
    static let visibilityReuse: UInt32 = 2  // test the initial pick's visibility
    static let shade: UInt32 = 4            // this spatial pass is the last: shade and write the outputs
    static let split: UInt32 = 8            // write unshadowed light and visibility apart (the shadow denoiser filters it)
}

/// MegaLights pass parameters (MSL MegaLightsParams).
struct GPUMegaLightsParams {
    var config = SIMD4<UInt32>()   // x = list samples per pixel, y = tile list capacity, z = flags, w = tiles across
    var tree = SIMD4<UInt32>()     // x = tree samples per pixel, y = light tree nodes (the lights' paths follow them)
    var tuning = SIMD4<Float>()    // x = cutoff, y = guide weight, z = firefly clamp (0 = off)

    static let guideValid: UInt32 = 1   // last frame's visible-light hashes can steer the picks
    static let partition: UInt32 = 2    // the list owns its lights in reach, the tree the others (else MIS)
    static let tile = 16                // pixels across a tile (ML_TILE)
}

/// The raster visibility buffer's culling and drawing parameters (MSL RasterParams, Shaders/Raster.metal).
struct GPURasterParams {
    var instanceCount: UInt32 = 0     // the instances' records, counted through
    var meshCount: UInt32 = 0         // GPURasterMesh records
    var chunkCount: UInt32 = 0        // chunks with bounds
    var flags: UInt32 = 0
    var maxDraws: UInt32 = 0          // per pass
    var maxGroups: UInt32 = 0         // per pass
    var hzbLevels: UInt32 = 0
    var pass: UInt32 = 0              // 0 = visible last frame, 1 = tested against this frame's pyramid
    var hzbSize = SIMD2<UInt32>()     // level 0
    var firstAssembly: UInt32 = 0     // RasterScene.firstAssembly
    var virtualCount: UInt32 = 0      // virtual instances drawn as clusters (RasterClusters), else 0

    static let ids: UInt32 = 1        // an instance's id comes from RasterScene.ids (a scene with blocks)
    static let hzb: UInt32 = 2        // pass 2 tests against the pyramid
}

/// A mesh index's record for the raster visibility buffer (MSL RasterMesh): its object-space bounds, with its first
/// chunk's place among the chunks' bounds in lo.w and its RasterScene kind and flags in hi.w (both bit patterns).
struct GPURasterMesh {
    var lo = SIMD4<Float>()
    var hi = SIMD4<Float>()
}

/// A view of a light's virtual shadow map (MSL VSMView, Shaders/VSM.metal): its rows to clip space, its place in the
/// page table, what it is a view of.
struct GPUVSMView {
    var x = SIMD4<Float>(), y = SIMD4<Float>(), z = SIMD4<Float>(), w = SIMD4<Float>()
    var origin = SIMD4<Float>()
    var params = SIMD4<Float>()       // x = texel size (sun; else at 1 m), y = sun: metres a unit of depth, z = near
    var window = SIMD2<Int32>()       // the sun: the absolute page of the window's first
    var table: UInt32 = 0
    var pages: UInt32 = 0
    var light: UInt32 = 0
    var kind: UInt32 = 0
    var level: UInt32 = 0
    var flags: UInt32 = 0

    static let stale: UInt32 = 1      // its drawn pages are out of date (the light moved)
}

/// A light's maps (MSL VSMLight), by light index: its first view + 1 (0: none), levels or mips, kind.
struct GPUVSMLight {
    var firstView: UInt32 = 0
    var levels: UInt32 = 0
    var kind: UInt32 = 0
    var pad: UInt32 = 0
}

/// The virtual shadow maps' upkeep (MSL VSMParams).
struct GPUVSMParams {
    var entries: UInt32 = 0
    var pool: UInt32 = 0
    var budget: UInt32 = 0
    var frame: UInt32 = 0
    var keep: UInt32 = 0
    var instanceCount: UInt32 = 0
    var meshCount: UInt32 = 0
    var maxDraws: UInt32 = 0
    var maxGroups: UInt32 = 0
    var flags: UInt32 = 0
    var views: UInt32 = 0
    var moving: UInt32 = 0            // RasterScene.moving's instances

    static let ids: UInt32 = 1        // RasterScene.ids maps places to ids
    static let cache: UInt32 = 2      // drawn pages stay drawn until invalidated
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
    static let feedbackSet: UInt32 = 128    // multi-bounce is on (`feedback` is still off on a history's first frame)
    // Not in config.x: restirGIInitialKernel derives them from `extra`, and so does initialPassFlags, to compile them in.
    static let quarter: UInt32 = 256        // extra.x: quarter budget
    static let oneBounce: UInt32 = 512      // extra.y: the paths end at their first hit

    /// restirGIInitialKernel's own flags (MSL `own` there).
    var initialPassFlags: UInt32 {
        config.x | (extra.x != 0 ? GPURestirGIParams.quarter : 0) | (extra.y <= 1 ? GPURestirGIParams.oneBounce : 0)
    }
}

/// The sky (MSL SkyParams): the per-slot copy lives in the shading arguments (SceneShading), the sky kernels get it directly.
struct GPUSkyParams {
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

struct GPUMesh {
    var firstIndex: UInt32
    var indexCount: UInt32
    /// A pose slot of a skinned character (Crowd): its vertices sit this far after the ones its indices name, and its
    /// previous frame's positions `prevOffset` after those. Both 0 for every other mesh.
    var vertexOffset: UInt32 = 0
    var prevOffset: UInt32 = 0
    var sways: UInt32 = 0              // 1 = ground cover that leans in the wind (Scene.coverLean)
    var cutout: UInt32 = 0             // leaf cards: its triangles from (the low 24 bits) on are cut out by the alpha
                                       // layer (the top byte) - 1 of Scene.cutouts; 0 = none
    /// A mesh in a buffer of its own (MeshBlock): the buffer's GPU address, written where the scene's buffers are made
    /// (0 in the scene, and for a mesh in the scene's buffers), and how many vertices it has there.
    var block: UInt64 = 0
    var vertexCount: UInt32 = 0
    /// The level of detail it was made at, + 1 (0 = it has no levels): an open-world tile's ring, a crowd character's
    /// detail, a baked plant (its finest). Only the LOD debug view reads it (Scene.setDetailLevel).
    var lod: UInt32 = 0
}

/// A skinned vertex's joints and weights (MSL SkinVertex, Shaders/Crowd.metal).
struct GPUSkinVertex: Equatable {
    var joints: UInt32 = 0     // four joint indices, a byte each (the first in the low byte)
    var w0: Float = 1          // the first three joints' weights; the fourth's is what is left of 1
    var w1: Float = 0
    var w2: Float = 0
}

/// A skeleton's joint (MSL CrowdJoint): where it sits in its parent, and its inverse bind transform (a rotation,
/// then a translation), which takes a bind-pose vertex into the joint's space.
struct GPUJoint: Equatable {
    var local: SIMD4<Float>      // xyz = translation in the parent's space (m), w = the parent's index + 1 (bits; 0 = root)
    var inverseBindRotation: SIMD4<Float>      // quaternion, xyzw
    var inverseBindTranslation: SIMD4<Float>   // xyz

    var parent: Int { Int(local.w.bitPattern) - 1 }
}

/// A joint's skinning matrix in a pose (MSL JointMatrix): the three rows of bind space -> posed space.
struct GPUJointMatrix: Equatable {
    var row0 = SIMD4<Float>(1, 0, 0, 0), row1 = SIMD4<Float>(0, 1, 0, 0), row2 = SIMD4<Float>(0, 0, 1, 0)

    func point(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = SIMD4(p, 1)
        return SIMD3(dot(row0, v), dot(row1, v), dot(row2, v))
    }
    func direction(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let v = SIMD4(d, 0)
        return SIMD3(dot(row0, v), dot(row1, v), dot(row2, v))
    }
}

/// A pose of the crowd at one time (MSL PoseSlot): two clips of its character, each at a time in keys, and how far
/// the pose is from the first toward the second. A clip is named by where its keys start in the crowd's key tables.
struct GPUPoseSlot: Equatable {
    var rotationsA: UInt32 = 0   // clip A's first rotation key (a quaternion per joint and key)
    var rootA: UInt32 = 0        // its first root-translation key
    var rotationsB: UInt32 = 0
    var rootB: UInt32 = 0
    var timeA: Float = 0         // in keys, inside the loop
    var timeB: Float = 0
    var blend: Float = 0         // 0 = clip A alone
    var pad: Float = 0
}

struct GPUInstanceData {
    var transform: simd_float4x4       // object -> world, this frame
    var prevTransform: simd_float4x4   // object -> world, previous frame (motion vectors)
    var normalMatrix: simd_float4x4    // inverse-transpose of transform
    var meshIndex: UInt32
    var materialIndex: UInt32
    var pad0: UInt32 = 0               // instance mask (Scene.maskGeometry / maskLights), read by the raster and the cut
    var pad1: UInt32 = 0
}

struct GPUMaterial {
    var albedo: SIMD4<Float>     // rgb = base colour (diffuse reflectance for non-metals), a = metallic
    var emission: SIMD4<Float>   // rgb = emitted radiance, a = roughness
    var params = SIMD4<Float>(0, 1, 0, 0)   // x = specular weight (0 = diffuse only, the generated scenes), y = normal scale,
                                            // z = 1: an emissive-mesh light's (buildMeshLights)
    var textures = SIMD4<UInt32>(repeating: .max)   // base colour, metallic-roughness, normal, emissive: Scene.textures
                                                    // index, or ~0 = none
}

/// One light; see the MSL struct for what each field holds per type (Scene.LightKind).
struct GPULight {
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

/// One triangle of an emissive-mesh light, object space (MSL EmissiveTriangle).
struct GPUEmissiveTriangle {
    var v0: SIMD4<Float>     // w = cumulative selection probability within its light
    var e1: SIMD4<Float>     // w = uv0.x
    var e2: SIMD4<Float>     // w = uv0.y
    var uv12: SIMD4<Float>   // uv1, uv2
}

/// One node of an SDF shape (MSL SDFNode, Shaders/SDF.metal; SDFShape.gpuNodes).
struct GPUSDFNode {
    var row0: SIMD4<Float>               // shape space -> the primitive's, as rows
    var row1: SIMD4<Float>
    var row2: SIMD4<Float>
    var params = SIMD4<Float>()          // per kind (SDFShape.sphereKind ...): its sizes
    var kind: UInt32 = 0
    var op: UInt32 = 0                   // SDFShape.Op, joining it to the nodes before it
    var k: Float = 0                     // the blend's radius
    var scale: Float = 1                 // the node's uniform scale (its distances are the primitive's x this)
    var material: UInt32 = 0             // offset from the instance's material
    var volume: UInt32 = 0               // a volume's: Scene.sdfVolumes index
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

/// An SDF shape (MSL SDFShape): its box and its nodes.
struct GPUSDFShape {
    var lo: SIMD4<Float>                 // xyz = box min (shape space), w = the march's step scale (1 = exact distances)
    var hi: SIMD4<Float>                 // xyz = box max, w = 0
    var range: SIMD4<UInt32>             // x = first node, y = node count
}

/// A baked distance grid (MSL SDFVolume; SDFVolume.gpu).
struct GPUSDFVolume {
    var lo: SIMD4<Float>                 // xyz = the first sample's place, w = the samples' spacing
    var hi: SIMD4<Float>                 // xyz = the last's, w = the least sample on the grid's faces
    var dims: SIMD4<UInt32>              // xyz = samples per axis, w = where its samples start among all of them
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
    var wind = SIMD4<Float>()            // xyz = wind (m/s): the noise drifts with it; w = haze (FogSettings.haze)
    var grid = SIMD4<Float>()            // x = near, y = far (view depth), z = log(far / near), w = depth slices
    var counts = SIMD4<UInt32>()         // x, y = froxel columns and rows, z = volume count, w = FogParams flags
    var volumes = (GPUFogVolume(), GPUFogVolume(), GPUFogVolume(), GPUFogVolume(),
                   GPUFogVolume(), GPUFogVolume(), GPUFogVolume(), GPUFogVolume())

    static let historyValid: UInt32 = 1  // last frame's froxel grid matches: reproject it
    static let reflections: UInt32 = 2   // reflection rays are fogged too
    static let enabled: UInt32 = 4       // fog is on (reflections test it)
    static let skyLight: UInt32 = 8      // only the suns' light scatters in it (and the sky's): FogSettings.lights off

    /// reflectionKernel's own flag (MSL REFLECT_FOG), for the variant with it compiled in.
    static let reflectionsFogged: UInt32 = 1
    var reflectionPassFlags: UInt32 {
        counts.w & (GPUFogParams.enabled | GPUFogParams.reflections) == GPUFogParams.enabled | GPUFogParams.reflections
            ? GPUFogParams.reflectionsFogged : 0
    }

    mutating func setVolume(_ i: Int, _ v: GPUFogVolume) {
        withUnsafeMutableBytes(of: &volumes) { raw in
            raw.storeBytes(of: v, toByteOffset: i * MemoryLayout<GPUFogVolume>.stride, as: GPUFogVolume.self)
        }
    }
}

/// Catches accidental layout drift between Swift and MSL at startup.
func validateGPULayouts() {
    precondition(MemoryLayout<Uniforms>.stride == 256, "Uniforms layout mismatch")
    precondition(MemoryLayout<GPUMesh>.stride == 40 && MemoryLayout<GPUMesh>.offset(of: \.block) == 24, "GPUMesh layout mismatch")
    precondition(MemoryLayout<GPUInstanceData>.stride == 208, "GPUInstanceData layout mismatch")
    precondition(MemoryLayout<GPUSkinVertex>.stride == 16, "GPUSkinVertex layout mismatch")
    precondition(MemoryLayout<GPUJoint>.stride == 48, "GPUJoint layout mismatch")
    precondition(MemoryLayout<GPUJointMatrix>.stride == 48, "GPUJointMatrix layout mismatch")
    precondition(MemoryLayout<GPUPoseSlot>.stride == 32, "GPUPoseSlot layout mismatch")
    precondition(MemoryLayout<GPUMaterial>.stride == 64, "GPUMaterial layout mismatch")
    precondition(MemoryLayout<GPULight>.stride == 64, "GPULight layout mismatch")
    precondition(MemoryLayout<GPULightTableEntry>.stride == 16, "GPULightTableEntry layout mismatch")
    precondition(MemoryLayout<GPUTriangleInfo>.stride == 8, "GPUTriangleInfo layout mismatch")
    precondition(MemoryLayout<GPURestirParams>.stride == 32, "GPURestirParams layout mismatch")
    precondition(MemoryLayout<GPUMegaLightsParams>.stride == 48, "GPUMegaLightsParams layout mismatch")
    precondition(MemoryLayout<GPULightTreeNode>.stride == 64, "GPULightTreeNode layout mismatch")
    precondition(MemoryLayout<GPURasterParams>.stride == 48, "GPURasterParams layout mismatch")
    precondition(MemoryLayout<GPURasterMesh>.stride == 32, "GPURasterMesh layout mismatch")
    precondition(MemoryLayout<GPUVSMView>.stride == VSMTargets.viewSize, "GPUVSMView layout mismatch")
    precondition(MemoryLayout<GPUVSMLight>.stride == 16, "GPUVSMLight layout mismatch")
    precondition(MemoryLayout<GPUVSMParams>.stride == 48, "GPUVSMParams layout mismatch")
    precondition(MemoryLayout<GPURestirGIParams>.stride == 48, "GPURestirGIParams layout mismatch")
    precondition(MemoryLayout<GPUEmissiveTriangle>.stride == 64, "GPUEmissiveTriangle layout mismatch")
    precondition(MemoryLayout<GPUFogVolume>.stride == 64, "GPUFogVolume layout mismatch")
    precondition(MemoryLayout<GPUPostParams>.stride == 80, "GPUPostParams layout mismatch")
    precondition(MemoryLayout<GPUPathTraceParams>.stride == 48, "GPUPathTraceParams layout mismatch")
    precondition(MemoryLayout<GPUSDFNode>.stride == 96, "GPUSDFNode layout mismatch")
    precondition(MemoryLayout<GPUSDFShape>.stride == 48, "GPUSDFShape layout mismatch")
    precondition(MemoryLayout<GPUSDFVolume>.stride == 48, "GPUSDFVolume layout mismatch")
    precondition(MemoryLayout<GPUFogParams>.stride == 96 + 64 * GPUFogParams.maxVolumes, "GPUFogParams layout mismatch")
    precondition(MemoryLayout<GPUSkyParams>.stride == 192, "GPUSkyParams layout mismatch")
    precondition(MemoryLayout<BVHNode>.stride == 64, "BVHNode layout mismatch")
    precondition(MemoryLayout<RCParams>.stride == 48, "RCParams layout mismatch")
    precondition(MemoryLayout<GPURegirParams>.stride == 96, "GPURegirParams layout mismatch")
    precondition(MemoryLayout<GPURegirReservoir>.stride == 16, "GPURegirReservoir layout mismatch")
    precondition(MemoryLayout<VGCluster>.stride == 80, "VGCluster layout mismatch")
    precondition(MemoryLayout<VirtualBLAS.Entry>.stride == 32, "VirtualBLAS.Entry (VGBlas) layout mismatch")
    precondition(MemoryLayout<VirtualGeometry.Params>.stride == 48, "VirtualGeometry.Params (VGParams) layout mismatch")
    precondition(MemoryLayout<SIMD3<Float>>.stride == 16, "float3 must be 16 bytes to match MSL")
}
