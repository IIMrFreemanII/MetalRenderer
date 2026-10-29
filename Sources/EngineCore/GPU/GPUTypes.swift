import Metal
import simd

// Structs shared with the shaders (Shaders/Types.metal unless a comment names another piece) that the core and every
// module above it use. Their memory layout MUST match the MSL structs of the same name exactly (validateGPULayouts,
// in the engine, checks every one). The rest are with what owns them (the engine's Renderer/GPUTypes.swift, the systems).

package struct Uniforms {
    package var camPos = SIMD4<Float>()          // xyz = camera position
    package var camRight = SIMD4<Float>()        // xyz = right vector,   w = tan(fovX / 2)
    package var camUp = SIMD4<Float>()           // xyz = up vector,      w = tan(fovY / 2)
    package var camForward = SIMD4<Float>()      // xyz = forward vector, w unused
    package var prevCamPos = SIMD4<Float>()      // previous frame's camera (for motion vectors)
    package var prevCamRight = SIMD4<Float>()
    package var prevCamUp = SIMD4<Float>()
    package var prevCamForward = SIMD4<Float>()
    package var skyColor = SIMD4<Float>()
    package var width: UInt32 = 0
    package var height: UInt32 = 0
    package var frameIndex: UInt32 = 0
    package var lightCount: UInt32 = 0
    package var bounces: UInt32 = 0
    package var flags: UInt32 = 0
    package var viewMode: UInt32 = 0
    package var instanceCount: UInt32 = 0
    package var jitter = SIMD4<Float>()          // xy = this frame's sub-pixel jitter, zw = previous frame's (pixels)
    package var denoise = SIMD4<Float>()         // x = luminance sigma, y = max history frames, z = anti-lag strength
    package var lightGroupEnd = SIMD4<UInt32>()  // lights are sorted by shadow-denoiser group: group g = [end[g-1], end[g])
    package var lightTable = SIMD4<UInt32>()     // x = light-table entries (after the lights in their buffer), y = suns, z / w = sun lights
    package var post = SIMD4<Float>(1, 0, 0, 0)  // x = exposure (linear scale), y = tone curve (ToneMap's raw value), z = flags
                                         // (gradeOn, meterOn)
    package var grade = SIMD4<Float>(1, 1, 1, 1) // the colour grade: red and blue gains, saturation, contrast (PostSettings)
    package var interiorLo = SIMD4<Float>(1, 1, 1, 0)     // the walkable interiors' box (Scene.interiorBox), empty: lo > hi;
    package var interiorHi = SIMD4<Float>(-1, -1, -1, 0)  // GI's hits in it see the sun through a shadow ray
    package var backdrop = SIMD4<Float>()        // xyz = what camera rays that hit nothing see, w = 1 when it is on (Scene.backdrop)
    package static let gradeOn: Float = 1, meterOn: Float = 2

    /// traceKernel's own flags (MSL tracePassFlags), for the variant with them compiled in.
    package static let traceBounces: UInt32 = 1      // the path tracer's indirect light (`bounces` > 0)
    package static let traceManyLights: UInt32 = 2   // more analytic lights than shadow-denoiser groups
    package var tracePassFlags: UInt32 { (bounces > 0 ? Uniforms.traceBounces : 0) | (lightGroupEnd.w > 4 ? Uniforms.traceManyLights : 0) }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(camPos: SIMD4<Float> = SIMD4<Float>(), camRight: SIMD4<Float> = SIMD4<Float>(), camUp: SIMD4<Float> = SIMD4<Float>(), camForward: SIMD4<Float> = SIMD4<Float>(), prevCamPos: SIMD4<Float> = SIMD4<Float>(), prevCamRight: SIMD4<Float> = SIMD4<Float>(), prevCamUp: SIMD4<Float> = SIMD4<Float>(), prevCamForward: SIMD4<Float> = SIMD4<Float>(), skyColor: SIMD4<Float> = SIMD4<Float>(), width: UInt32 = 0, height: UInt32 = 0, frameIndex: UInt32 = 0, lightCount: UInt32 = 0, bounces: UInt32 = 0, flags: UInt32 = 0, viewMode: UInt32 = 0, instanceCount: UInt32 = 0, jitter: SIMD4<Float> = SIMD4<Float>(), denoise: SIMD4<Float> = SIMD4<Float>(), lightGroupEnd: SIMD4<UInt32> = SIMD4<UInt32>(), lightTable: SIMD4<UInt32> = SIMD4<UInt32>(), post: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 0), grade: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1), interiorLo: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0), interiorHi: SIMD4<Float> = SIMD4<Float>(-1, -1, -1, 0), backdrop: SIMD4<Float> = SIMD4<Float>()) {
        self.camPos = camPos
        self.camRight = camRight
        self.camUp = camUp
        self.camForward = camForward
        self.prevCamPos = prevCamPos
        self.prevCamRight = prevCamRight
        self.prevCamUp = prevCamUp
        self.prevCamForward = prevCamForward
        self.skyColor = skyColor
        self.width = width
        self.height = height
        self.frameIndex = frameIndex
        self.lightCount = lightCount
        self.bounces = bounces
        self.flags = flags
        self.viewMode = viewMode
        self.instanceCount = instanceCount
        self.jitter = jitter
        self.denoise = denoise
        self.lightGroupEnd = lightGroupEnd
        self.lightTable = lightTable
        self.post = post
        self.grade = grade
        self.interiorLo = interiorLo
        self.interiorHi = interiorHi
        self.backdrop = backdrop
    }
}

package enum UniformFlags {
    package static let historyValid: UInt32 = 1
    package static let denoise: UInt32 = 2
    package static let upscale: UInt32 = 4   // MetalFX on: write depth + motion for it, composite outputs linear color
    package static let blueNoise: UInt32 = 8 // sample with the blue-noise texture instead of the hash RNG
    package static let separateSignals: UInt32 = 16  // direct and indirect light were denoised separately
    package static let noClamp: UInt32 = 32          // no firefly clamp (reference images)
    package static let lightMaps: UInt32 = 64        // path tracer: bounce lighting from light-visibility maps
    package static let shadowDenoiser: UInt32 = 128  // direct light = exact unshadowed light x denoised per-group visibility
    package static let allLights: UInt32 = 256       // one shadow ray per light even with more than 4 (references, baseline)
    package static let specular: UInt32 = 512        // specular materials: material G-buffer, reflection pass, specular composite
    package static let reference: UInt32 = 1024      // accumulated reference: reflections follow full paths
    package static let meshLights: UInt32 = 2048     // with the shadow denoiser: composite adds the denoised mesh-light direct light
    package static let fog: UInt32 = 4096            // composite applies the volumetric fog (froxel grid, or the reference march)
    package static let fogReference: UInt32 = 8192   // with fog: read the per-pixel reference march instead of the froxel grid
    package static let skyMap: UInt32 = 16384        // the sky comes from the sky texture (atmosphere or image), not skyColor
    package static let restir: UInt32 = 32768        // direct light from a pass of its own: ReSTIR DI
    package static let hdrOutput: UInt32 = 65536     // MetalFX's denoising scaler follows: the composite writes raw light and guides
    package static let wind: UInt32 = 131072         // the wind turns the plants' parts (assemblies; the ray queries' variants)
    package static let giDebug: UInt32 = 262144      // this frame's GI method writes the "GI debug" view (cascades, ReSTIR GI)
    package static let post: UInt32 = 524288         // the lens effects follow (Post.metal): the composite writes the light as it is
    package static let particles: UInt32 = 8388608   // the composite puts the particles' layer over the scene (particleLayerKernel)
}

/// ReSTIR DI pass parameters (MSL RestirParams).
package struct GPURestirParams {
    package var config = SIMD4<UInt32>()   // x = candidates, y = max M, z = GPURestirParams flags, w = spatial samples
    package var tuning = SIMD4<Float>()    // x = spatial radius (pixels), y = spatial pass index, z = firefly clamp (0 = off)

    package static let temporalValid: UInt32 = 1    // last frame's reservoirs can be reprojected
    package static let visibilityReuse: UInt32 = 2  // test the initial pick's visibility
    package static let shade: UInt32 = 4            // this spatial pass is the last: shade and write the outputs
    package static let split: UInt32 = 8            // write unshadowed light and visibility apart (the shadow denoiser filters it)

    /// (As the memberwise initializer, for the modules above this one.)
    package init(config: SIMD4<UInt32> = SIMD4<UInt32>(), tuning: SIMD4<Float> = SIMD4<Float>()) {
        self.config = config
        self.tuning = tuning
    }
}

/// ReSTIR GI pass parameters (MSL RestirGIParams).
package struct GPURestirGIParams {
    package var config = SIMD4<UInt32>()   // x = GPURestirGIParams flags, y = max M, z = spatial samples, w = spatial pass index
    package var tuning = SIMD4<Float>()    // x = spatial radius (pixels), y = minimum distance in the target (m), z = firefly clamp (0 = off)
    package var extra = SIMD4<UInt32>()    // x = 1: quarter budget, y = bounces, z = max sample age (frames)

    package static let temporalValid: UInt32 = 1    // last frame's reservoirs can be reprojected
    package static let shade: UInt32 = 2            // this spatial pass is the last: trace the visibility ray, write `indirect`
    package static let lightMaps: UInt32 = 4        // light the paths' hits from the light maps (no shadow rays)
    package static let feedback: UInt32 = 8         // multi-bounce: the paths' last hits add last frame's indirect light
    package static let unbiased: UInt32 = 16        // spatial reuse traces a ray per neighbour (visibility in its MIS weight)
    package static let keepFeedback: UInt32 = 32    // the last spatial pass also keeps its result for next frame's feedback
    package static let fallback: UInt32 = 64        // feedback: off-screen path ends add last frame's mean indirect light
    package static let feedbackSet: UInt32 = 128    // multi-bounce is on (`feedback` is still off on a history's first frame)
    // Not in config.x: restirGIInitialKernel derives them from `extra`, and so does initialPassFlags, to compile them in.
    package static let quarter: UInt32 = 256        // extra.x: quarter budget
    package static let oneBounce: UInt32 = 512      // extra.y: the paths end at their first hit

    /// restirGIInitialKernel's own flags (MSL `own` there).
    package var initialPassFlags: UInt32 {
        config.x | (extra.x != 0 ? GPURestirGIParams.quarter : 0) | (extra.y <= 1 ? GPURestirGIParams.oneBounce : 0)
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(config: SIMD4<UInt32> = SIMD4<UInt32>(), tuning: SIMD4<Float> = SIMD4<Float>(), extra: SIMD4<UInt32> = SIMD4<UInt32>()) {
        self.config = config
        self.tuning = tuning
        self.extra = extra
    }
}

/// Volumetric fog parameters (MSL FogParams), passed with setBytes to the fog kernels, the composite and reflections.
package struct GPUFogParams {
    package static let maxVolumes = 8

    package init() {}

    package var medium = SIMD4<Float>()          // x = height-fog extinction at the base (1/m), y = height falloff (1/m),
                                         // z = base height (constant below), w = anisotropy g (Henyey-Greenstein)
    package var albedo = SIMD4<Float>()          // rgb = height fog's albedo, w = ambient: sky colour x w lights the fog evenly
    package var noise = SIMD4<Float>()           // x = height fog's noise amount, y = noise tile size (m), z = time (s), w = this frame's weight in the froxel history
    package var wind = SIMD4<Float>()            // xyz = wind (m/s): the noise drifts with it; w = haze (FogSettings.haze)
    package var grid = SIMD4<Float>()            // x = near, y = far (view depth), z = log(far / near), w = depth slices
    package var counts = SIMD4<UInt32>()         // x, y = froxel columns and rows, z = volume count, w = FogParams flags
    package var interiorLo = SIMD4<Float>(1, 1, 1, 0)     // the walkable interiors' box (Uniforms.interiorLo / Hi): the sky's
    package var interiorHi = SIMD4<Float>(-1, -1, -1, 0)  // ambient light in the fog is occluded in it
    package var volumes = (GPUFogVolume(), GPUFogVolume(), GPUFogVolume(), GPUFogVolume(),
                   GPUFogVolume(), GPUFogVolume(), GPUFogVolume(), GPUFogVolume())

    package static let historyValid: UInt32 = 1  // last frame's froxel grid matches: reproject it
    package static let reflections: UInt32 = 2   // reflection rays are fogged too
    package static let enabled: UInt32 = 4       // fog is on (reflections test it)
    package static let skyLight: UInt32 = 8      // only the suns' light scatters in it (and the sky's): FogSettings.lights off

    /// reflectionKernel's own flag (MSL REFLECT_FOG), for the variant with it compiled in.
    package static let reflectionsFogged: UInt32 = 1
    package var reflectionPassFlags: UInt32 {
        counts.w & (GPUFogParams.enabled | GPUFogParams.reflections) == GPUFogParams.enabled | GPUFogParams.reflections
            ? GPUFogParams.reflectionsFogged : 0
    }

    package mutating func setVolume(_ i: Int, _ v: GPUFogVolume) {
        withUnsafeMutableBytes(of: &volumes) { raw in
            raw.storeBytes(of: v, toByteOffset: i * MemoryLayout<GPUFogVolume>.stride, as: GPUFogVolume.self)
        }
    }
}

package struct GPUMesh {
    package var firstIndex: UInt32
    package var indexCount: UInt32
    /// A pose slot of a skinned character (Crowd): its vertices sit this far after the ones its indices name, and its
    /// previous frame's positions `prevOffset` after those. Both 0 for every other mesh.
    package var vertexOffset: UInt32 = 0
    package var prevOffset: UInt32 = 0
    package var sways: UInt32 = 0              // 1 = ground cover that leans in the wind (Scene.coverLean)
    package var cutout: UInt32 = 0             // leaf cards: its triangles from (the low 24 bits) on are cut out by the alpha
                                       // layer (the top byte) - 1 of Scene.cutouts; 0 = none
    /// A mesh in a buffer of its own (MeshBlock): the buffer's GPU address, written where the scene's buffers are made
    /// (0 in the scene, and for a mesh in the scene's buffers), and how many vertices it has there.
    package var block: UInt64 = 0
    package var vertexCount: UInt32 = 0
    /// The level of detail it was made at, + 1 (0 = it has no levels): an open-world tile's ring, a crowd character's
    /// detail, a baked plant (its finest). Only the LOD debug view reads it (Scene.setDetailLevel).
    package var lod: UInt32 = 0
    /// A terrain's sector (TERRAIN, Shaders/Terrain.metal): 1 + where its terrain's layer table starts in the procedural
    /// parameters; its block has its vertices' layer weights after its triangles' materials. 0: not a terrain's.
    package var terrain: UInt32 = 0
    package var pad: UInt32 = 0

    /// (As the memberwise initializer, for the modules above this one.)
    package init(firstIndex: UInt32, indexCount: UInt32, vertexOffset: UInt32 = 0, prevOffset: UInt32 = 0, sways: UInt32 = 0, cutout: UInt32 = 0, block: UInt64 = 0, vertexCount: UInt32 = 0, lod: UInt32 = 0, terrain: UInt32 = 0, pad: UInt32 = 0) {
        self.firstIndex = firstIndex
        self.indexCount = indexCount
        self.vertexOffset = vertexOffset
        self.prevOffset = prevOffset
        self.sways = sways
        self.cutout = cutout
        self.block = block
        self.vertexCount = vertexCount
        self.lod = lod
        self.terrain = terrain
        self.pad = pad
    }
}

package struct GPUMaterial {
    package var albedo: SIMD4<Float>     // rgb = base colour (diffuse reflectance for non-metals), a = metallic
    package var emission: SIMD4<Float>   // rgb = emitted radiance, a = roughness
    package var params = SIMD4<Float>(0, 1, 0, 0)   // x = specular weight (0 = diffuse only, the generated scenes; below 2;
                                            // >= 2: a clear coat over metallic paint, x - 2 the paint's roughness:
                                            // Scene.addPaintMaterial),
                                            // y = normal scale,
                                            // z = 1: an emissive-mesh light's (buildMeshLights), -1: hair (Hair.metal),
                                            // w = a leaf's translucency; < 0: skin, -w its strength (0...1), + 2
                                            // where it is thin (Hair.metal skinUnshadowed)
    package var textures = SIMD4<UInt32>(repeating: .max)   // base colour, metallic-roughness, normal, emissive: Scene.textures
                                                    // index, or ~0 = none

    /// (As the memberwise initializer, for the modules above this one.)
    package init(albedo: SIMD4<Float>, emission: SIMD4<Float>, params: SIMD4<Float> = SIMD4<Float>(0, 1, 0, 0), textures: SIMD4<UInt32> = SIMD4<UInt32>(repeating: .max)) {
        self.albedo = albedo
        self.emission = emission
        self.params = params
        self.textures = textures
    }
}

/// What a procedural material (a Material Designer graph's: MaterialBake) has past GPUMaterial, one per material of
/// a scene that has any (MSL MaterialExtra, read with MATERIAL_EXTRAS): its height for parallax and its opacity, its
/// UV scale, and how strongly the metallic-roughness texture's R (ambient occlusion) darkens it.
package struct GPUMaterialExtra: Equatable {
    package var textures = SIMD4<UInt32>(repeating: .max)   // height, opacity: Scene.textures index, or ~0 = none; z = 1: procedural
                                                    // (a mesh without UVs gets planar ones), 2: a scan (TextureSets.swift),
                                                    // 3: a grid floor (gridKind)
    package var surface = SIMD4<Float>(0, 1, 0.5, 0)         // x = parallax depth (UV), y = UV scale, z = opacity cutoff,
                                                     // w = AO strength (0: the R channel isn't occlusion)

    /// `textures.z` of a grid floor (Scene.addGridMaterial, Surface.metal previewGrid): no textures, and `surface` its
    /// subgrid's strength, tile size (m), lines' share of its colour and crosses' strength.
    package static let gridKind: UInt32 = 3

    /// (As the memberwise initializer, for the modules above this one.)
    package init(textures: SIMD4<UInt32> = SIMD4<UInt32>(repeating: .max), surface: SIMD4<Float> = SIMD4<Float>(0, 1, 0.5, 0)) {
        self.textures = textures
        self.surface = surface
    }
}

/// One triangle of an emissive-mesh light, object space (MSL EmissiveTriangle).
package struct GPUEmissiveTriangle {
    package var v0: SIMD4<Float>     // w = cumulative selection probability within its light
    package var e1: SIMD4<Float>     // w = uv0.x
    package var e2: SIMD4<Float>     // w = uv0.y
    package var uv12: SIMD4<Float>   // uv1, uv2

    /// (As the memberwise initializer, for the modules above this one.)
    package init(v0: SIMD4<Float>, e1: SIMD4<Float>, e2: SIMD4<Float>, uv12: SIMD4<Float>) {
        self.v0 = v0
        self.e1 = e1
        self.e2 = e2
        self.uv12 = uv12
    }
}

/// One node of an SDF shape (MSL SDFNode, Shaders/SDF.metal; SDFShape.gpuNodes).
package struct GPUSDFNode {
    package var row0: SIMD4<Float>               // shape space -> the primitive's, as rows
    package var row1: SIMD4<Float>
    package var row2: SIMD4<Float>
    package var params = SIMD4<Float>()          // per kind (SDFShape.sphereKind ...): its sizes
    package var kind: UInt32 = 0
    package var op: UInt32 = 0                   // SDFShape.Op, joining it to the nodes before it
    package var k: Float = 0                     // the blend's radius
    package var scale: Float = 1                 // the node's uniform scale (its distances are the primitive's x this)
    package var material: UInt32 = 0             // offset from the instance's material
    package var volume: UInt32 = 0               // a volume's: Scene.sdfVolumes index
    package var pad0: UInt32 = 0
    package var pad1: UInt32 = 0

    /// (As the memberwise initializer, for the modules above this one.)
    package init(row0: SIMD4<Float>, row1: SIMD4<Float>, row2: SIMD4<Float>, params: SIMD4<Float> = SIMD4<Float>(), kind: UInt32 = 0, op: UInt32 = 0, k: Float = 0, scale: Float = 1, material: UInt32 = 0, volume: UInt32 = 0, pad0: UInt32 = 0, pad1: UInt32 = 0) {
        self.row0 = row0
        self.row1 = row1
        self.row2 = row2
        self.params = params
        self.kind = kind
        self.op = op
        self.k = k
        self.scale = scale
        self.material = material
        self.volume = volume
        self.pad0 = pad0
        self.pad1 = pad1
    }
}

/// An SDF shape (MSL SDFShape): its box and its nodes.
package struct GPUSDFShape {
    package var lo: SIMD4<Float>                 // xyz = box min (shape space), w = the march's step scale (1 = exact distances)
    package var hi: SIMD4<Float>                 // xyz = box max, w = 0
    package var range: SIMD4<UInt32>             // x = first node, y = node count

    /// (As the memberwise initializer, for the modules above this one.)
    package init(lo: SIMD4<Float>, hi: SIMD4<Float>, range: SIMD4<UInt32>) {
        self.lo = lo
        self.hi = hi
        self.range = range
    }
}

/// A baked distance grid (MSL SDFVolume; SDFVolume.gpu).
package struct GPUSDFVolume {
    package var lo: SIMD4<Float>                 // xyz = the first sample's place, w = the samples' spacing
    package var hi: SIMD4<Float>                 // xyz = the last's, w = the least sample on the grid's faces
    package var dims: SIMD4<UInt32>              // xyz = samples per axis, w = where its samples start among all of them
}

/// A local fog volume (MSL FogVolume): a soft-edged box or sphere of denser fog.
package struct GPUFogVolume {
    package var centerShape = SIMD4<Float>()     // xyz = centre, w = shape (0 = box, 1 = sphere)
    package var extentDensity = SIMD4<Float>()   // xyz = half extents (sphere: x = radius), w = extinction at the bottom (1/m)
    package var albedoEdge = SIMD4<Float>()      // rgb = single-scattering albedo, w = edge softness (m)
    package var params = SIMD4<Float>()          // x = noise amount, y = height falloff inside (1/m, from the bottom)

    /// (As the memberwise initializer, for the modules above this one.)
    package init(centerShape: SIMD4<Float> = SIMD4<Float>(), extentDensity: SIMD4<Float> = SIMD4<Float>(), albedoEdge: SIMD4<Float> = SIMD4<Float>(), params: SIMD4<Float> = SIMD4<Float>()) {
        self.centerShape = centerShape
        self.extentDensity = extentDensity
        self.albedoEdge = albedoEdge
        self.params = params
    }
}
