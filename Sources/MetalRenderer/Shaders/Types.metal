// ---------------------------------------------------------------------------------------------
// Shared types — layouts must match GPUTypes.swift exactly.
// ---------------------------------------------------------------------------------------------

struct Uniforms {
    float4 camPos;          // xyz
    float4 camRight;        // xyz, w = tan(fovX/2)
    float4 camUp;           // xyz, w = tan(fovY/2)
    float4 camForward;      // xyz
    float4 prevCamPos;
    float4 prevCamRight;
    float4 prevCamUp;
    float4 prevCamForward;
    float4 skyColor;
    uint width;
    uint height;
    uint frameIndex;
    uint lightCount;
    uint bounces;
    uint flags;
    uint viewMode;
    uint instanceCount;
    float4 jitter;          // xy = this frame's sub-pixel jitter, zw = previous frame's (pixels)
    float4 denoise;         // x = luminance sigma, y = max history frames, z = anti-lag strength (0 = off), w = variance scale
    uint4 lightGroupEnd;    // lights are sorted by shadow-denoiser group: group g = [end[g - 1], end[g])
    uint4 lightTable;       // x = light-table entries (after the lights in their buffer), y = suns, z / w = sun lights
    float4 post;            // x = exposure (linear scale), y = tone curve: 0 ACES, 1 AgX, 2 Reinhard, 3 none
};

struct MeshData {
    uint firstIndex;
    uint indexCount;
    uint pad0;
    uint pad1;
};

struct InstanceData {
    float4x4 transform;
    float4x4 prevTransform;
    float4x4 normalMatrix;
    uint meshIndex;
    uint materialIndex;
    uint pad0;
    uint pad1;
};

struct Material {
    float4 albedo;      // rgb = base colour, a = metallic
    float4 emission;    // rgb = emitted radiance, a = roughness
    float4 params;      // x = specular weight (0 = diffuse only, the generated scenes), y = normal scale,
                        // z = 1: its emission is sampled as an emissive-mesh light,
                        // w = translucency (leaves): this share of them is lit from behind (traceSurface)
    uint4  textures;    // base colour, metallic-roughness (G = roughness, B = metallic), normal, emissive; ~0 = none
};

// Bindless material textures (Renderer: an array of MTLResourceIDs).
struct MaterialTexture {
    texture2d<float> t;
};

struct EmissiveTriangle;
struct RegirParams;
struct RegirReservoir;

// The sky (GPUTypes.swift GPUSkyParams); see "Sky and clouds" below.
struct SkyParams {
    float4 sun;          // xyz = toward the sun (unit), w = its angular radius
    float4 sunTop;       // rgb = sun irradiance above the atmosphere (atmosphere mode)
    float4 sunGround;    // rgb = sun irradiance at the ground (the sun light's colour)
    float4 cloudLayer;   // x = cloud base altitude (m), y = top (m), z = coverage (0...1), w = extinction (1/m)
    float4 cloudShape;   // x = shape noise tile (m), y = detail erosion, z = time (s), w = shadow strength
    float4 wind;         // xyz = wind (m/s), w = weight of a new cloud sample in a texel (1 = replace)
    float4 shadowMap;    // xy = centre (x, z) of the cloud-shadow square, z = its half size (m), w = ground height
    float4 ground;       // rgb = ground albedo below the horizon, w = the sky's observer altitude (m)
    uint4  flags;        // x = SKY_ATMOSPHERE / SKY_IMAGE, y = SKY_CLOUDS | SKY_SHADOWS | ..., z = update phase 0...15,
                         //   w = frame (jitters the cloud march)
};

constant uint SKY_ATMOSPHERE = 1, SKY_IMAGE = 2;
constant uint SKY_CLOUDS = 1, SKY_SHADOWS = 2, SKY_UPDATE_ALL = 4, SKY_CLOUDS_OVER_IMAGE = 8;

// Buffer 7 of every kernel that shades ray hits: materials, per-vertex UVs and the texture table; the sky.
struct SceneShading {
    device const Material*        materials;
    device const float2*          uvs;
    device const MaterialTexture* textures;
    device const float*           minLod;      // per texture: finest resident mip level (texture streaming)
    device atomic_uint*           feedback;    // per texture: 16 counters, samples wanting each mip level this frame
    device const EmissiveTriangle* emissive;   // emissive-mesh lights' triangles
    texture2d_array<float>        sky;         // with FLAG_SKY_MAP: [0] upper, [1] lower hemisphere (skyKernel)
    texture2d<float>              cloudShadow; // with SKY_SHADOWS: transmittance toward the sun (cloudShadowKernel)
    SkyParams                     skyParams;
};

constant uint NO_TEXTURE = 0xFFFFFFFFu;

// One light (GPUTypes.swift GPULight). Analytic lights come first, sorted by shadow-denoiser group
// (u.lightGroupEnd.w of them); emissive-mesh lights follow, up to u.lightCount.
struct Light {
    float4 positionRadius;  // xyz = centre (unused by the sun), w = radius (sphere, spot, tube; mesh: bounding sphere),
                            //   angular radius in radians (sun)
    float4 color;           // rgb = intensity (sphere, spot, tube), irradiance (sun), radiance (rect),
                            //   sum of radiance x area (mesh); w = shadow-denoiser group + 4 x type (LIGHT_*), so
                            //   the per-light weight loops read only the first 32 bytes of a sphere light
    float4 axis;            // xyz = spot axis, rect normal (it emits along it), direction toward the sun,
                            //   tube half axis (centre +- axis), mesh mean normal
    float4 params;          // spot: cos outer, cos inner | rect: half-width tangent xyz, half height
                            // sun: light-map bounds centre xyz, radius | mesh: first triangle, triangle count,
                            //   flatness, instance (uints bit cast, but flatness)
};

constant uint LIGHT_SPHERE = 0;
constant uint LIGHT_SPOT   = 1;
constant uint LIGHT_SUN    = 2;
constant uint LIGHT_RECT   = 3;
constant uint LIGHT_TUBE   = 4;
constant uint LIGHT_MESH   = 5;

// One bit per LIGHT_* type the scene has (function constant 0). The renderer specialises the pipelines per scene,
// so the per-light loops of a scene with only sphere lights compile to exactly the sphere code; without the constant
// (e.g. a pipeline made without it) every type is handled. Bit 31 = LIGHT_TABLE: a scene with many lights (more than
// Scene.lightTableThreshold), where nothing may loop over the lights or keep something per light: GI and the path
// tracer sample the light table instead of per-light light maps, and the sky draws only the suns' discs.
constant uint lightTypesConstant [[function_constant(0)]];
constant uint LIGHT_SPEC = is_function_constant_defined(lightTypesConstant) ? lightTypesConstant : 0x3Fu;
constant uint LIGHT_TYPES = LIGHT_SPEC & 0x3Fu;
constant bool LIGHT_TABLE = (LIGHT_SPEC & 0x80000000u) != 0;
// Bit 30 = FOLIAGE: the scene has assemblies (generated plants as trees of shared parts; custom ray tracer). Without
// it the traversal and the shading compile to what they were before assemblies.
constant bool FOLIAGE = (LIGHT_SPEC & 0x40000000u) != 0;
constant bool POINT_LIGHTS_ONLY = (LIGHT_TYPES & ~3u) == 0;   // spheres and spots

// One triangle of an emissive-mesh light (GPUTypes.swift GPUEmissiveTriangle), object space.
struct EmissiveTriangle {
    float4 v0;    // xyz = vertex 0, w = cumulative selection probability within its light (last = 1)
    float4 e1;    // xyz = v1 - v0, w = uv0.x
    float4 e2;    // xyz = v2 - v0, w = uv0.y
    float4 uv12;  // uv1, uv2
};

// Volumetric fog (GPUTypes.swift GPUFogParams / GPUFogVolume); see "Volumetric fog" below.
struct FogVolume {
    float4 centerShape;     // xyz = centre, w = shape (0 = box, 1 = sphere)
    float4 extentDensity;   // xyz = half extents (sphere: x = radius), w = extinction at the bottom (1/m)
    float4 albedoEdge;      // rgb = single-scattering albedo, w = edge softness (m)
    float4 params;          // x = noise amount, y = height falloff inside (1/m, from the bottom)
};

constant uint FOG_MAX_VOLUMES = 8;

struct FogParams {
    float4 medium;          // x = height-fog extinction at the base (1/m), y = height falloff (1/m), z = base height
                            //   (constant density below), w = anisotropy g
    float4 albedo;          // rgb = height fog's albedo, w = ambient (sky colour x w lights the fog evenly)
    float4 noise;           // x = height fog's noise amount, y = noise tile size (m), z = time (s), w = this frame's
                            //   weight in the froxel history
    float4 wind;            // xyz = wind (m/s)
    float4 grid;            // x = near, y = far (view depth), z = log(far / near), w = depth slices
    uint4  counts;          // x, y = froxel columns and rows, z = volume count, w = FOG_* flags
    FogVolume volumes[FOG_MAX_VOLUMES];
};

constant uint FOG_HISTORY_VALID = 1;   // last frame's froxel grid can be reprojected
constant uint FOG_REFLECTIONS   = 2;   // reflection rays are fogged too
constant uint FOG_ENABLED       = 4;

constant uint FLAG_HISTORY_VALID = 1;
constant uint FLAG_DENOISE       = 2;
constant uint FLAG_UPSCALE       = 4;   // MetalFX on: write depth + motion for it, composite outputs linear color
constant uint FLAG_BLUE_NOISE    = 8;   // sample with the blue-noise texture instead of the hash RNG
constant uint FLAG_SEPARATE      = 16;  // direct and indirect light were denoised separately
constant uint FLAG_NO_CLAMP      = 32;  // no firefly clamp (reference images)
constant uint FLAG_LIGHT_MAPS    = 64;  // path tracer: bounce lighting from light-visibility maps
constant uint FLAG_SHADOW_DENOISER = 128;  // direct light = exact unshadowed light x denoised per-group visibility
constant uint FLAG_ALL_LIGHTS    = 256; // one shadow ray per light even with more than SHADOW_GROUPS lights (references)
constant uint FLAG_SPECULAR      = 512; // specular materials present: material G-buffer, reflection pass, specular composite
constant uint FLAG_REFERENCE     = 1024; // accumulated reference: reflections follow full paths
constant uint FLAG_MESH_LIGHTS   = 2048; // with the shadow denoiser: the composite adds the denoised mesh-light direct light
constant uint FLAG_FOG           = 4096; // the composite applies the volumetric fog
constant uint FLAG_FOG_REFERENCE = 8192; // ...from the per-pixel reference march instead of the froxel grid
constant uint FLAG_SKY_MAP       = 16384; // the sky comes from the sky texture (atmosphere or image), not skyColor
constant uint FLAG_RESTIR        = 32768; // direct light from ReSTIR DI (restirTemporalKernel, restirSpatialKernel)
constant uint FLAG_HDR_OUTPUT    = 65536; // MetalFX's denoising scaler follows: the composite writes the raw light and its guides
constant uint FLAG_WIND          = 131072; // FOLIAGE scenes: the wind is blowing (RTScene.wind.z > 0), the plants' parts turn
// Compiled-in flags. A configuration fixes most of these bits for every frame, so the renderer makes variants of the
// big kernels with them as function constants (Pipelines.swift, KernelVariants): what a variant doesn't do is not in
// its code and holds no registers. Constants 1 and 2 are bits of Uniforms.flags and which of them are compiled in;
// 3 and 4 the same for the kernel's own flags (RESTIR_*, RGI_*, TRACE_*, REFLECT_FOG). A bit outside the mask, and
// every bit of a pipeline made without the constants, is read from the uniform as before.
constant uint fixedFlagsConstant    [[function_constant(1)]];
constant uint fixedFlagMaskConstant [[function_constant(2)]];
constant uint fixedPassConstant     [[function_constant(3)]];
constant uint fixedPassMaskConstant [[function_constant(4)]];
constant uint FIXED_FLAG_MASK = is_function_constant_defined(fixedFlagMaskConstant) ? fixedFlagMaskConstant : 0u;
constant uint FIXED_FLAGS     = is_function_constant_defined(fixedFlagsConstant) ? fixedFlagsConstant : 0u;
constant uint FIXED_PASS_MASK = is_function_constant_defined(fixedPassMaskConstant) ? fixedPassMaskConstant : 0u;
constant uint FIXED_PASS      = is_function_constant_defined(fixedPassConstant) ? fixedPassConstant : 0u;
// `bit` of Uniforms.flags (flagOn) or of the kernel's own flags (passOn): the compiled-in value where there is one.
inline bool flagOn(uint flags, uint bit) { return (((FIXED_FLAG_MASK & bit) != 0 ? FIXED_FLAGS : flags) & bit) != 0; }
inline bool passOn(uint flags, uint bit) { return (((FIXED_PASS_MASK & bit) != 0 ? FIXED_PASS : flags) & bit) != 0; }
// The wind, for the ray queries and the shading, which see no uniforms: compiled in or out where the kernel's variant
// fixes FLAG_WIND, else `blowing` (the scene's wind strength, read at run time).
inline bool windOn(bool blowing) { return (FIXED_FLAG_MASK & FLAG_WIND) != 0 ? (FIXED_FLAGS & FLAG_WIND) != 0 : blowing; }
constant uint SHADOW_GROUPS      = 4;   // light groups the shadow denoiser handles (one rgba channel each);
                                        // up to 4 lights, each light is its own group (Light.color.w = group)
constant uint CACHED_LIGHT_SAMPLES = 4; // lightIllumCached: light-map lookups per hit with more than 8 lights

constant uint MASK_GEOMETRY = 1;     // see Scene.maskGeometry
constant uint MASK_ALL      = 0xFF;

constant float RAY_EPSILON  = 1e-3f;
constant float FIREFLY_CLAMP = 10.0f;
constant float NEAR_PLANE   = 0.05f; // only used to encode the reversed-Z depth MetalFX reads
