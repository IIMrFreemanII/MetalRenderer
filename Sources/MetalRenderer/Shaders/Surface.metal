struct SceneData {
    device const float3*       positions;
    device const float3*       normals;
    device const uint*         indices;
    device const MeshData*     meshes;
    device const InstanceData* instances;
    device const Material*     materials;
    device const float2*       uvs;
    device const MaterialTexture* textures;
    device const float*        minLod;
    device atomic_uint*        feedback;
    device const EmissiveTriangle* emissive;
    device const uchar*        triangleMaterials;
    device const Light*        lights;
    uint                       lightCount;
    uint4                      lightTable;      // Uniforms.lightTable, for the samplers that draw from the table
    device const RegirReservoir* regirGrid;     // the light grid (ReGIR), in kernels that bind it (regir != nullptr)
    constant RegirParams*      regir = nullptr;
    texture2d_array<float>     sky;
    texture2d<float>           cloudShadow;
    constant SkyParams*        skyParams;
    device const MaterialExtra* extras;         // SceneShading.extras (with MATERIAL_EXTRAS)
    device const float4*       procParams;      // SceneShading.procParams (with PROCEDURAL_CODE)
    device const WaterScene*   water;           // SceneShading.water (with WATER)
    device const uchar4*       damage;          // SceneShading.damage (with cars), or null
};

inline void bindShading(thread SceneData& s, constant SceneShading& shading) {
    s.materials = shading.materials;
    s.uvs = shading.uvs;
    s.textures = shading.textures;
    s.minLod = shading.minLod;
    s.feedback = shading.feedback;
    s.emissive = shading.emissive;
    s.triangleMaterials = shading.triangleMaterials;
    s.sky = shading.sky;
    s.cloudShadow = shading.cloudShadow;
    s.skyParams = &shading.skyParams;
    s.extras = shading.extras;
    s.procParams = shading.procParams;
    s.water = shading.water;
    s.damage = shading.damage;
}

// A kernel's scene, from its bindings. What a kernel doesn't bind stays null: `sceneLights` is for the kernels that
// evaluate lights but trace no surfaces (no geometry buffers), and `bindLightSampling` adds what the light table's
// and the light grid's samplers read.
inline SceneData sceneData(device const float3* positions, device const float3* normals, device const uint* indices,
                           device const MeshData* meshes, device const InstanceData* instances,
                           constant SceneShading& shading, device const Light* lights, uint lightCount) {
    SceneData s;
    s.positions = positions; s.normals = normals; s.indices = indices; s.meshes = meshes;
    s.instances = instances;
    bindShading(s, shading);
    s.lights = lights; s.lightCount = lightCount;
    s.lightTable = uint4(0u); s.regirGrid = nullptr;
    return s;
}
inline SceneData sceneLights(device const InstanceData* instances, constant SceneShading& shading,
                             device const Light* lights, uint lightCount) {
    return sceneData(nullptr, nullptr, nullptr, nullptr, instances, shading, lights, lightCount);
}
inline void bindLightSampling(thread SceneData& s, uint4 lightTable, device const RegirReservoir* grid,
                              constant RegirParams& regir) {
    s.lightTable = lightTable; s.regirGrid = grid; s.regir = &regir;
}

// ---------------------------------------------------------------------------------------------
// Sky lookups. The sky texture holds each hemisphere in an equal-area square (Shirley-Chiu's concentric map from
// the square to the disk, then Lambert's from the disk to the hemisphere), so every texel covers the same solid
// angle and the horizon is the square's border. rgb = radiance (with clouds), a = cloud transmittance.
// ---------------------------------------------------------------------------------------------

constexpr sampler skySampler(filter::linear, mip_filter::linear, address::clamp_to_edge);

// Square [0, 1]^2 -> unit direction in the upper hemisphere (y up).
inline float3 hemiDecode(float2 uv) {
    float2 a = uv * 2.0f - 1.0f;
    float r, phi;
    if (a.x * a.x > a.y * a.y) { r = a.x; phi = (M_PI_F / 4.0f) * (a.y / a.x); }
    else if (a.y != 0.0f) { r = a.y; phi = M_PI_F / 2.0f - (M_PI_F / 4.0f) * (a.x / a.y); }
    else { r = 0.0f; phi = 0.0f; }
    float rho = abs(r), s = r < 0.0f ? -1.0f : 1.0f;   // r < 0: the opposite half (phi + pi)
    float h = rho * sqrt(max(2.0f - rho * rho, 0.0f));
    return float3(s * h * cos(phi), 1.0f - rho * rho, s * h * sin(phi));
}

// Unit direction (y >= 0) -> square [0, 1]^2.
inline float2 hemiEncode(float3 d) {
    float rho = sqrt(saturate(1.0f - d.y));
    float hl = length(d.xz);
    float2 disk = hl > 1e-7f ? d.xz / hl * rho : float2(0.0f);
    float r = length(disk), phi = atan2(disk.y, disk.x);
    if (phi < -M_PI_F / 4.0f) phi += 2.0f * M_PI_F;
    float2 a;
    if (phi < M_PI_F / 4.0f)             { a.x = r;  a.y = phi * r / (M_PI_F / 4.0f); }
    else if (phi < 3.0f * M_PI_F / 4.0f) { a.y = r;  a.x = -(phi - M_PI_F / 2.0f) * r / (M_PI_F / 4.0f); }
    else if (phi < 5.0f * M_PI_F / 4.0f) { a.x = -r; a.y = -(phi - M_PI_F) * r / (M_PI_F / 4.0f); }
    else                                 { a.y = -r; a.x = (phi - 3.0f * M_PI_F / 2.0f) * r / (M_PI_F / 4.0f); }
    return a * 0.5f + 0.5f;
}

// Sky radiance (and cloud transmittance in .a) toward unit dir: the sky texture with FLAG_SKY_MAP, otherwise the
// constant sky colour (exactly the old value). lod 0 for camera and mirror rays, higher for diffuse rays.
inline float4 skySample(uint flags, float3 skyColor, thread const SceneData& s, float3 dir, float lod) {
    if (!flagOn(flags, FLAG_SKY_MAP)) return float4(skyColor, 1.0f);
    uint slice = dir.y >= 0.0f ? 0u : 1u;
    return s.sky.sample(skySampler, hemiEncode(float3(dir.x, abs(dir.y), dir.z)), slice, level(lod));
}
#define skyRadiance(u, s, dir, lod) (skySample((u).flags, (u).skyColor.rgb, (s), (dir), (lod)).rgb)

// What a camera ray that hits nothing sees in place of the sky when the scene has a backdrop (Scene.backdrop, the
// plant workshop's grey): a touch lighter toward the horizon. The sky still lights everything else.
inline bool backdropOn(constant Uniforms& u) { return u.backdrop.w > 0.0f; }
inline float3 backdropSample(constant Uniforms& u, float3 dir) {
    return u.backdrop.rgb * (1.06f - 0.12f * saturate(abs(dir.y)));
}

// The sky's mean radiance over the whole sphere (the fog's ambient light): the textures' smallest mips.
inline float3 skyAmbient(constant Uniforms& u, thread const SceneData& s) {
    if (!flagOn(u.flags, FLAG_SKY_MAP)) return u.skyColor.rgb;
    float top = float(s.sky.get_num_mip_levels() - 1);
    return 0.5f * (s.sky.sample(skySampler, float2(0.5f), 0, level(top)).rgb + s.sky.sample(skySampler, float2(0.5f), 1, level(top)).rgb);
}

// Cloud shadow at p: transmittance toward the sun through the clouds, from the cloud-shadow map (a square of the
// ground around the scene; p is projected onto it along the sun's direction). 1 without cloud shadows.
inline float cloudShadowAt(texture2d<float> map, constant SkyParams& sp, float3 p) {
    float3 l = sp.sun.xyz;
    if ((sp.flags.y & SKY_SHADOWS) == 0 || l.y <= 0.01f) return 1.0f;
    float2 g = p.xz - l.xz * ((p.y - sp.shadowMap.w) / l.y);
    float2 uv = (g - sp.shadowMap.xy) / (2.0f * sp.shadowMap.z) + 0.5f;
    return map.sample(skySampler, uv, level(0)).r;
}
inline float cloudShadow(thread const SceneData& s, float3 p) { return cloudShadowAt(s.cloudShadow, *s.skyParams, p); }

struct Surface {
    bool   hit;
    float3 position;      // world space, this frame
    float3 prevPosition;  // same surface point, previous frame (for motion vectors)
    float3 normal;        // smooth shading normal (interpolated vertex normals), world space, not face-forwarded
    float3 geomNormal;    // the triangle's true normal, world space, not face-forwarded
    float3 albedo;        // base colour (diffuse reflectance; metals get their colour from specular in a later step)
    float3 emission;
    float  metallic;
    float  roughness;
    float  specular;      // specular weight: 0 = diffuse-only material
    float  coat;          // a clear coat over metallic paint (Material.params.x >= 2): the paint's roughness; -1: none
    float3 f0;            // specular reflectance at normal incidence (0 for diffuse-only materials)
    uint   instanceId;
    bool   lightEmitter;  // its emission is sampled as an emissive-mesh light (Material.params.z)
    bool   backlit;       // a translucent leaf showing the light of its far side: orientNormals faces it away
    bool   hair;          // a strand (HAIR_CURVES) whose material is hair (Material.params.z < 0): Hair.metal lights it
    float3 tangent;       // a strand's direction there
    float  hairH;         // where across the strand the ray met it, -1...1 (Hair.metal's h)
    float  skin;          // skin (Material.params.w < 0): its strength, 0...1, + 2 where it is thin (ears): Hair.metal
    float  leaf;          // LEAF_TRANSMIT: a two-sided leaf's share of light through it, where the camera sees it
    float4 sheen;         // MATERIAL_LOBES: rgb = its colour (0 = none), a = its roughness
    float3 lobeTangent;   // MATERIAL_LOBES: which way a brushed highlight stretches
    float  anisotropy;    // MATERIAL_LOBES: how much (0 = not)
};

// A material's specular weight (Material.params.x): as it is, but 1 for a clear coat's (2 and up: Scene.addPaintMaterial).
inline float specularWeight(float x) { return x >= 2.0f ? 1.0f : x; }

// Where across a strand along `tangent` its normal `n` is, seen from `view` (pbrt's h: in the strand's frame x =
// tangent, y = the view across it, z = x cross y, the normal is (cos gamma) y - (sin gamma) z and h = sin gamma).
inline float hairOffset(float3 n, float3 tangent, float3 view) {
    float3 y = view - tangent * dot(view, tangent);
    return length_squared(y) > 1e-12f ? clamp(-dot(n, cross(tangent, normalize(y))), -1.0f, 1.0f) : 0.0f;
}

// A uniform Catmull-Rom segment (Metal's curve_basis::catmull_rom) between c[1] and c[2], at t, and its derivative.
inline float3 catmullRom(float3 c0, float3 c1, float3 c2, float3 c3, float t) {
    float t2 = t * t, t3 = t2 * t;
    return 0.5f * (2.0f * c1 + (c2 - c0) * t + (2.0f * c0 - 5.0f * c1 + 4.0f * c2 - c3) * t2 + (3.0f * c1 - c0 - 3.0f * c2 + c3) * t3);
}
inline float3 catmullRomTangent(float3 c0, float3 c1, float3 c2, float3 c3, float t) {
    return 0.5f * ((c2 - c0) + 2.0f * (2.0f * c0 - 5.0f * c1 + 4.0f * c2 - c3) * t + 3.0f * (3.0f * c1 - c0 - 3.0f * c2 + c3) * t * t);
}

// Light through a leaf comes out yellower than what it reflects.
constant float3 LEAF_TRANSMIT_TINT = float3(1.1f, 1.2f, 0.55f);
// The realistic look's crown normals (traceSurface): how far a tree's leaf normal bends toward its crown's outside, and
// the crown's middle, on the trunk at this share of the leaf's height. All of it where a pixel is this wide or wider
// (metres: a leaf a few pixels long), none where a pixel is LEAF_CROWN_NEAR wide (a leaf tens of pixels long, which
// shades as its own curved blade).
constant float LEAF_CROWN_NORMAL = 0.6f;
constant float LEAF_CROWN_CENTRE = 0.75f;
constant float LEAF_CROWN_FAR = 0.015f;
constant float LEAF_CROWN_NEAR = 0.003f;
// A tree's leaves that turn olive-brown (each leaf's pick), as Unreal's foliage material's health overlay does.
constant float LEAF_BROWN_SHARE = 0.14f;
// A twig's wood: its generations carried past this in U (Growth.twigWood), and its young stems' tint over the bark.
constant float TWIG_WOOD = 8.0f;
constant float3 TWIG_WOOD_TINT = float3(1.3f, 1.55f, 0.55f);
// The mean of a plant's detail texture (FoliageTextures.mean): its material's colour is the plant's over this, and
// what shades a plant without its texture (its far voxels) multiplies by it instead.
constant float GENERATED_TEXTURE_MEAN = 0.7f;

// Emission a GI or bounce ray picks up at a hit: none from emissive-mesh lights, whose light next-event estimation
// and the light maps already deliver (as the light spheres, which GI rays don't even see).
inline float3 giEmission(thread const Surface& h) { return h.lightEmitter ? float3(0.0f) : h.emission; }

// ---------------------------------------------------------------------------------------------
// Specular BRDF: GGX with height-correlated Smith visibility and Schlick Fresnel (F90 = specular weight).
// ---------------------------------------------------------------------------------------------

constant float MIN_ROUGHNESS = 0.03f;     // perceptual; keeps highlights of small lights finite
constant float REFLECTION_MAX_ROUGHNESS = 0.75f;   // rougher: indirect specular from the diffuse GI (no ray)

inline float ggxD(float NoH, float a) {
    float a2 = a * a, d = NoH * NoH * (a2 - 1.0f) + 1.0f;
    return a2 / (M_PI_F * d * d);
}
inline float smithVisibility(float NoV, float NoL, float a) {   // G2 / (4 NoL NoV), height-correlated
    float a2 = a * a;
    float gv = NoL * sqrt(NoV * NoV * (1.0f - a2) + a2), gl = NoV * sqrt(NoL * NoL * (1.0f - a2) + a2);
    return 0.5f / max(gv + gl, 1e-7f);
}
inline float3 schlick(float3 f0, float f90, float VoH) {
    float f = pow(1.0f - saturate(VoH), 5.0f);
    return f0 + (f90 - f0) * f;
}
// Hemispherical-directional specular albedo, analytic fit (Karis, "Physically Based Shading on Mobile").
inline float3 specularAlbedo(float3 f0, float f90, float roughness, float NoV) {
    const float4 c0 = float4(-1.0f, -0.0275f, -0.572f, 0.022f), c1 = float4(1.0f, 0.0425f, 1.04f, -0.04f);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28f * NoV)) * r.x + r.y;
    float2 ab = float2(-1.04f, 1.04f) * a004 + r.zw;
    return f0 * ab.x + f90 * ab.y;
}
// Below 2% nothing real reflects: such an F0 is a surface's cavities (or no specular at all), which shade its grazing rise.
inline float specularF90(float3 f0) { return saturate(50.0f * max(f0.x, max(f0.y, f0.z))); }
// FLAG_ENERGY's specular albedo, the lobe's own: its share of F0 (x) and of F90 (y) on a grid of roughness and sqrt(NoV)
// (Tools/eval/specular_lobe.py). specularAlbedo's fit is for image lighting and doesn't vary with the angle at F = 1
// (a white rough metal: 0.45 where the lobe keeps 0.31 head on and 0.85 at a grazing angle). In the shader's constants,
// so that every pass that needs it has it with no texture to bind.
constant float2 SPECULAR_LOBE[17 * 17] = {
    {0.0052f, 0.9890f}, {0.0194f, 0.9804f}, {0.0757f, 0.9243f}, {0.1639f, 0.8361f}, {0.2758f, 0.7242f}, {0.4018f, 0.5982f}, {0.5313f, 0.4687f}, {0.6543f, 0.3457f}, {0.7627f, 0.2373f}, {0.8507f, 0.1493f}, {0.9160f, 0.0840f}, {0.9592f, 0.0408f}, {0.9840f, 0.0160f}, {0.9955f, 0.0045f}, {0.9993f, 0.0007f}, {1.0000f, 0.0000f}, {1.0000f, 0.0000f},
    {0.0706f, 0.8810f}, {0.0573f, 0.8348f}, {0.0876f, 0.8770f}, {0.1692f, 0.8236f}, {0.2785f, 0.7194f}, {0.4032f, 0.5960f}, {0.5320f, 0.4678f}, {0.6547f, 0.3452f}, {0.7628f, 0.2371f}, {0.8507f, 0.1492f}, {0.9159f, 0.0840f}, {0.9592f, 0.0408f}, {0.9839f, 0.0160f}, {0.9955f, 0.0045f}, {0.9993f, 0.0007f}, {1.0000f, 0.0000f}, {1.0000f, 0.0000f},
    {0.2126f, 0.7742f}, {0.1983f, 0.7543f}, {0.1767f, 0.7153f}, {0.2128f, 0.7093f}, {0.3007f, 0.6638f}, {0.4148f, 0.5698f}, {0.5377f, 0.4550f}, {0.6570f, 0.3393f}, {0.7632f, 0.2347f}, {0.8502f, 0.1485f}, {0.9151f, 0.0841f}, {0.9584f, 0.0411f}, {0.9835f, 0.0163f}, {0.9952f, 0.0047f}, {0.9992f, 0.0008f}, {0.9999f, 0.0000f}, {1.0000f, 0.0000f},
    {0.3576f, 0.6364f}, {0.3486f, 0.6286f}, {0.3231f, 0.6011f}, {0.3181f, 0.5726f}, {0.3603f, 0.5443f}, {0.4445f, 0.4929f}, {0.5507f, 0.4127f}, {0.6607f, 0.3180f}, {0.7620f, 0.2251f}, {0.8466f, 0.1451f}, {0.9108f, 0.0835f}, {0.9543f, 0.0416f}, {0.9799f, 0.0169f}, {0.9924f, 0.0050f}, {0.9969f, 0.0009f}, {0.9979f, 0.0001f}, {0.9980f, 0.0000f},
    {0.4878f, 0.5088f}, {0.4819f, 0.5044f}, {0.4631f, 0.4873f}, {0.4482f, 0.4617f}, {0.4570f, 0.4316f}, {0.5014f, 0.3943f}, {0.5764f, 0.3424f}, {0.6671f, 0.2759f}, {0.7581f, 0.2035f}, {0.8382f, 0.1360f}, {0.9013f, 0.0809f}, {0.9456f, 0.0417f}, {0.9728f, 0.0177f}, {0.9870f, 0.0057f}, {0.9930f, 0.0012f}, {0.9950f, 0.0001f}, {0.9959f, 0.0000f},
    {0.5969f, 0.4006f}, {0.5926f, 0.3975f}, {0.5791f, 0.3852f}, {0.5645f, 0.3653f}, {0.5599f, 0.3392f}, {0.5763f, 0.3076f}, {0.6180f, 0.2693f}, {0.6804f, 0.2232f}, {0.7526f, 0.1714f}, {0.8229f, 0.1197f}, {0.8827f, 0.0746f}, {0.9276f, 0.0404f}, {0.9573f, 0.0182f}, {0.9744f, 0.0064f}, {0.9830f, 0.0015f}, {0.9869f, 0.0002f}, {0.9889f, 0.0000f},
    {0.6846f, 0.3133f}, {0.6809f, 0.3108f}, {0.6700f, 0.3010f}, {0.6571f, 0.2851f}, {0.6479f, 0.2638f}, {0.6495f, 0.2378f}, {0.6675f, 0.2077f}, {0.7029f, 0.1737f}, {0.7514f, 0.1366f}, {0.8055f, 0.0991f}, {0.8570f, 0.0648f}, {0.8999f, 0.0371f}, {0.9314f, 0.0180f}, {0.9521f, 0.0069f}, {0.9644f, 0.0019f}, {0.9713f, 0.0003f}, {0.9756f, 0.0000f},
    {0.7530f, 0.2449f}, {0.7496f, 0.2428f}, {0.7392f, 0.2345f}, {0.7266f, 0.2214f}, {0.7153f, 0.2040f}, {0.7093f, 0.1830f}, {0.7127f, 0.1591f}, {0.7281f, 0.1331f}, {0.7551f, 0.1057f}, {0.7904f, 0.0785f}, {0.8287f, 0.0533f}, {0.8650f, 0.0322f}, {0.8953f, 0.0167f}, {0.9182f, 0.0070f}, {0.9341f, 0.0022f}, {0.9449f, 0.0004f}, {0.9524f, 0.0000f},
    {0.8055f, 0.1923f}, {0.8017f, 0.1904f}, {0.7904f, 0.1833f}, {0.7768f, 0.1723f}, {0.7633f, 0.1579f}, {0.7524f, 0.1408f}, {0.7469f, 0.1217f}, {0.7488f, 0.1015f}, {0.7593f, 0.0808f}, {0.7774f, 0.0607f}, {0.8011f, 0.0422f}, {0.8269f, 0.0265f}, {0.8518f, 0.0146f}, {0.8735f, 0.0066f}, {0.8911f, 0.0023f}, {0.9049f, 0.0005f}, {0.9158f, 0.0000f},
    {0.8451f, 0.1523f}, {0.8407f, 0.1507f}, {0.8276f, 0.1444f}, {0.8118f, 0.1349f}, {0.7954f, 0.1228f}, {0.7803f, 0.1088f}, {0.7682f, 0.0934f}, {0.7608f, 0.0775f}, {0.7592f, 0.0616f}, {0.7637f, 0.0465f}, {0.7736f, 0.0328f}, {0.7876f, 0.0212f}, {0.8038f, 0.0121f}, {0.8205f, 0.0059f}, {0.8363f, 0.0022f}, {0.8507f, 0.0005f}, {0.8635f, 0.0000f},
    {0.8747f, 0.1222f}, {0.8694f, 0.1207f}, {0.8540f, 0.1150f}, {0.8350f, 0.1068f}, {0.8149f, 0.0964f}, {0.7954f, 0.0847f}, {0.7777f, 0.0722f}, {0.7631f, 0.0595f}, {0.7523f, 0.0471f}, {0.7461f, 0.0355f}, {0.7445f, 0.0252f}, {0.7472f, 0.0165f}, {0.7533f, 0.0098f}, {0.7621f, 0.0050f}, {0.7725f, 0.0020f}, {0.7838f, 0.0005f}, {0.7956f, 0.0000f},
    {0.8968f, 0.0996f}, {0.8906f, 0.0981f}, {0.8720f, 0.0930f}, {0.8492f, 0.0856f}, {0.8248f, 0.0766f}, {0.8004f, 0.0667f}, {0.7772f, 0.0563f}, {0.7561f, 0.0460f}, {0.7379f, 0.0361f}, {0.7231f, 0.0271f}, {0.7119f, 0.0193f}, {0.7045f, 0.0128f}, {0.7008f, 0.0077f}, {0.7004f, 0.0040f}, {0.7029f, 0.0017f}, {0.7079f, 0.0005f}, {0.7149f, 0.0000f},
    {0.9132f, 0.0826f}, {0.9059f, 0.0812f}, {0.8838f, 0.0763f}, {0.8566f, 0.0696f}, {0.8273f, 0.0617f}, {0.7975f, 0.0531f}, {0.7686f, 0.0444f}, {0.7414f, 0.0359f}, {0.7165f, 0.0279f}, {0.6943f, 0.0209f}, {0.6751f, 0.0148f}, {0.6590f, 0.0098f}, {0.6463f, 0.0060f}, {0.6368f, 0.0032f}, {0.6305f, 0.0014f}, {0.6273f, 0.0005f}, {0.6268f, 0.0000f},
    {0.9255f, 0.0698f}, {0.9168f, 0.0683f}, {0.8909f, 0.0637f}, {0.8589f, 0.0574f}, {0.8242f, 0.0503f}, {0.7887f, 0.0428f}, {0.7539f, 0.0354f}, {0.7206f, 0.0283f}, {0.6893f, 0.0218f}, {0.6605f, 0.0161f}, {0.6342f, 0.0114f}, {0.6108f, 0.0075f}, {0.5903f, 0.0046f}, {0.5727f, 0.0025f}, {0.5580f, 0.0012f}, {0.5463f, 0.0004f}, {0.5374f, 0.0000f},
    {0.9346f, 0.0600f}, {0.9244f, 0.0586f}, {0.8944f, 0.0541f}, {0.8572f, 0.0481f}, {0.8168f, 0.0417f}, {0.7754f, 0.0350f}, {0.7345f, 0.0285f}, {0.6951f, 0.0225f}, {0.6578f, 0.0171f}, {0.6228f, 0.0126f}, {0.5904f, 0.0088f}, {0.5606f, 0.0058f}, {0.5336f, 0.0035f}, {0.5093f, 0.0020f}, {0.4876f, 0.0009f}, {0.4685f, 0.0003f}, {0.4520f, 0.0000f},
    {0.9413f, 0.0526f}, {0.9296f, 0.0511f}, {0.8952f, 0.0466f}, {0.8526f, 0.0410f}, {0.8062f, 0.0349f}, {0.7587f, 0.0289f}, {0.7117f, 0.0232f}, {0.6663f, 0.0181f}, {0.6232f, 0.0136f}, {0.5826f, 0.0098f}, {0.5448f, 0.0068f}, {0.5097f, 0.0045f}, {0.4775f, 0.0027f}, {0.4480f, 0.0015f}, {0.4210f, 0.0007f}, {0.3966f, 0.0003f}, {0.3745f, 0.0000f},
    {0.9462f, 0.0469f}, {0.9330f, 0.0454f}, {0.8940f, 0.0409f}, {0.8457f, 0.0354f}, {0.7932f, 0.0297f}, {0.7395f, 0.0242f}, {0.6865f, 0.0191f}, {0.6354f, 0.0147f}, {0.5868f, 0.0109f}, {0.5411f, 0.0078f}, {0.4987f, 0.0053f}, {0.4594f, 0.0035f}, {0.4232f, 0.0021f}, {0.3900f, 0.0012f}, {0.3597f, 0.0006f}, {0.3320f, 0.0002f}, {0.3068f, 0.0000f},
};
inline float2 specularLobe(float roughness, float NoV) {
    float2 p = float2(saturate(roughness), sqrt(saturate(NoV))) * 16.0f;
    float2 cell = min(floor(p), float2(15.0f)), f = p - cell;
    uint i = uint(cell.x) * 17u + uint(cell.y);
    return mix(mix(SPECULAR_LOBE[i], SPECULAR_LOBE[i + 1u], f.y), mix(SPECULAR_LOBE[i + 17u], SPECULAR_LOBE[i + 18u], f.y), f.x);
}
// The specular albedo a pass shades with, the same in every pass that divides by it or multiplies by it.
inline float3 specularShare(float3 f0, float f90, float roughness, float NoV, bool energy) {
    if (!energy) return specularAlbedo(f0, f90, roughness, NoV);
    float2 ab = specularLobe(roughness, NoV);
    return f0 * ab.x + f90 * ab.y;
}
// What one GGX lobe loses between its microfacets comes back as more of that lobe (Turquin 2019), by how much a lobe of
// F = 1 falls short of 1.
inline float3 specularMultiscatter(float3 f0, float roughness, float NoV) {
    float2 ab = specularLobe(roughness, NoV);
    return 1.0f + f0 * (1.0f / max(ab.x + ab.y, 0.1f) - 1.0f);
}

// Albedo a secondary hit (GI rays, path bounces, reflection hits) reflects with: diffuse plus, as a diffuse
// approximation, the specular albedo at normal incidence, so metals don't turn black in indirect light. With
// `energy` (FLAG_ENERGY) the specular takes its share from the diffuse, and gets back what it lost in its microfacets.
inline float3 hitAlbedo(thread const struct Surface& sf, bool energy) {
    if (sf.specular <= 0.0f) return sf.albedo;
    float roughness = max(sf.roughness, MIN_ROUGHNESS);
    float3 e = specularShare(sf.f0, sf.specular, roughness, 1.0f, energy);
    if (!energy) return sf.albedo + e;
    e *= specularMultiscatter(sf.f0, roughness, 1.0f);
    return sf.albedo * (1.0f - saturate(e)) + e;
}

// GGX visible-normal sampling (Heitz 2018), in the frame where the normal is +z and the tangent +x, of alphas a along it
// and b across it.
inline float3 sampleGGXVNDF(float3 ve, float a, float b, float2 u) {
    float3 vh = normalize(float3(a * ve.x, b * ve.y, ve.z));
    float lensq = vh.x * vh.x + vh.y * vh.y;
    float3 t1 = lensq > 0.0f ? float3(-vh.y, vh.x, 0.0f) * rsqrt(lensq) : float3(1.0f, 0.0f, 0.0f);
    float3 t2 = cross(vh, t1);
    float r = sqrt(u.x), phi = 2.0f * M_PI_F * u.y;
    float p1 = r * cos(phi), p2 = r * sin(phi);
    float sv = 0.5f * (1.0f + vh.z);
    p2 = (1.0f - sv) * sqrt(max(0.0f, 1.0f - p1 * p1)) + sv * p2;
    float3 nh = p1 * t1 + p2 * t2 + sqrt(max(0.0f, 1.0f - p1 * p1 - p2 * p2)) * vh;
    return normalize(float3(a * nh.x, b * nh.y, max(0.0f, nh.z)));
}
inline float3 sampleGGXVNDF(float3 ve, float a, float2 u) { return sampleGGXVNDF(ve, a, a, u); }

// A brushed highlight (MATERIAL_LOBES): GGX stretched along the tangent `t`, as glTF's KHR_materials_anisotropy has it.
inline float anisotropicAlpha(float a, float anisotropy) { return mix(a, 1.0f, anisotropy * anisotropy); }
// D x V (height-correlated) of the stretched lobe, in the frame t, b, n.
inline float ggxAnisotropic(float3 v, float3 l, float3 h, float at, float ab) {
    float d = h.x * h.x / (at * at) + h.y * h.y / (ab * ab) + h.z * h.z;
    float D = 1.0f / (M_PI_F * at * ab * d * d);
    float gv = l.z * length(float3(at * v.x, ab * v.y, v.z)), gl = v.z * length(float3(at * l.x, ab * l.y, l.z));
    return D * 0.5f / max(gv + gl, 1e-7f);
}

// A cloth's sheen (MATERIAL_LOBES): Charlie's lobe (Estevez & Kulla 2017) with Neubelt's visibility.
inline float sheenLobe(float roughness, float NoH, float NoV, float NoL) {
    float a = max(roughness * roughness, 0.005f), inv = 1.0f / a;
    float D = (2.0f + inv) * pow(max(1.0f - NoH * NoH, 1e-7f), inv * 0.5f) / (2.0f * M_PI_F);
    return D / (4.0f * max(NoL + NoV - NoL * NoV, 1e-4f));
}
// What that lobe reflects of light from all round, on a grid of roughness and NoV (at most 1).
constant float SHEEN_LOBE[9 * 9] = {
    4.8115f, 0.4390f, 0.0312f, 0.0011f, 0.0000f, 0.0000f, 0.0000f, 0.0000f, 0.0000f,
    2.9299f, 0.7270f, 0.1918f, 0.0429f, 0.0073f, 0.0008f, 0.0000f, 0.0000f, 0.0000f,
    1.5859f, 0.7473f, 0.3943f, 0.2040f, 0.0988f, 0.0428f, 0.0153f, 0.0037f, 0.0002f,
    1.1292f, 0.6630f, 0.4333f, 0.2844f, 0.1818f, 0.1103f, 0.0609f, 0.0280f, 0.0077f,
    0.9095f, 0.5955f, 0.4313f, 0.3164f, 0.2295f, 0.1616f, 0.1077f, 0.0650f, 0.0312f,
    0.7855f, 0.5479f, 0.4209f, 0.3289f, 0.2561f, 0.1960f, 0.1449f, 0.1010f, 0.0628f,
    0.7087f, 0.5144f, 0.4102f, 0.3335f, 0.2716f, 0.2189f, 0.1727f, 0.1313f, 0.0935f,
    0.6579f, 0.4906f, 0.4011f, 0.3350f, 0.2811f, 0.2346f, 0.1932f, 0.1553f, 0.1198f,
    0.6227f, 0.4732f, 0.3938f, 0.3352f, 0.2873f, 0.2458f, 0.2085f, 0.1740f, 0.1414f,
};
inline float sheenAlbedo(float roughness, float NoV) {
    float2 p = saturate(float2(roughness, NoV)) * 8.0f;
    float2 cell = min(floor(p), float2(7.0f)), f = p - cell;
    uint i = uint(cell.x) * 9u + uint(cell.y);
    return saturate(mix(mix(SHEEN_LOBE[i], SHEEN_LOBE[i + 1u], f.y), mix(SHEEN_LOBE[i + 9u], SHEEN_LOBE[i + 10u], f.y), f.x));
}
inline void tangentFrame(float3 n, thread float3& t, thread float3& b) {   // Duff et al. 2017
    float s = n.z >= 0.0f ? 1.0f : -1.0f;
    float a = -1.0f / (s + n.z), c = n.x * n.y * a;
    t = float3(1.0f + s * n.x * n.x * a, s * c, -s * n.x);
    b = float3(c, s + n.y * n.y * a, -n.y);
}

constexpr sampler materialSampler(filter::linear, mip_filter::linear, address::repeat);

// Samples a material texture at the level of a footprint: lodBase = log2 of the footprint in UV units (see
// traceSurface); the texture's resolution is added here.
// Streamed textures: sampled hits (`record`: a rotating eighth of the pixels' primary rays)
// count the level they need in a per-texture histogram; the streamer serves the finest level a meaningful share of
// samples needs (single bad estimates, from degenerate UVs, don't pull in 4K mips). Every sample is clamped to the
// finest level that is resident.
inline float4 sampleMaterial(thread const struct SceneData& s, uint index, float2 uv, float lodBase, bool record) {
    texture2d<float> t = s.textures[index].t;
    float lod = max(lodBase + 0.5f * log2(float(t.get_width()) * float(t.get_height())), 0.0f);
    if (record) atomic_fetch_add_explicit(&s.feedback[16 * index + min(uint(lod), 15u)], 1u, memory_order_relaxed);
    return t.sample(materialSampler, uv, level(max(lod, s.minLod[index])));
}

// Parallax occlusion mapping (MATERIAL_EXTRAS: a procedural material's height): where the view ray, entering the
// surface at `uv`, meets the height field below it (white the top, black `depth` down, in UV units), marched in 8 to
// 32 layers (more the more grazing) and met between the last two. `V` toward the eye; T and B the surface's U and V
// directions (world), N its normal.
inline float2 parallaxUV(thread const SceneData& s, uint height, float2 uv, float3 V, float3 T, float3 B, float3 N, float depth, float lodBase) {
    float3 v = float3(dot(V, normalize(T)), dot(V, normalize(B)), max(dot(V, N), 0.08f));
    int steps = int(mix(32.0f, 8.0f, saturate(v.z)));
    float layer = 1.0f / float(steps);
    float2 shift = v.xy / v.z * depth * layer;
    float2 at = uv;
    float d = 0.0f, h = sampleMaterial(s, height, at, lodBase, false).r, prevH = h, prevD = 0.0f;
    for (int i = 0; i < steps && d < 1.0f - h; ++i) {
        prevH = h;
        prevD = d;
        at -= shift;
        d += layer;
        h = sampleMaterial(s, height, at, lodBase, false).r;
    }
    float after = (1.0f - h) - d, before = (1.0f - prevH) - prevD;
    float w = after / min(after - before, -1e-6f);
    return mix(at, at + shift, saturate(w));
}
// A world point's UV on the plane of the axis `a` (a triangle's normal's magnitudes) is most along: a tile a metre.
inline float2 planarUV(float3 w, float3 a) {
    return a.y >= a.x && a.y >= a.z ? w.xz : a.x >= a.z ? float2(w.z, -w.y) : float2(w.x, -w.y);
}

// Below this footprint spread a ray's hit gets parallax (camera rays; GI rays are GI_RAY_SPREAD).
constant float PARALLAX_SPREAD = 0.01f;

// Orients a hit's normals toward the side the ray came from. The geometric normal decides the side; the smooth
// shading normal is flipped onto that side. Face-forwarding the smooth normal alone flips it inward at
// silhouettes, where it can face away from the ray even though the triangle faces it, which put ray origins
// inside the sphere and caused black dots along its edges.
inline void orientNormals(thread const Surface& sf, float3 rayDir, thread float3& ng, thread float3& ns) {
    ng = dot(sf.geomNormal, rayDir) > 0.0f ? -sf.geomNormal : sf.geomNormal;
    ns = dot(sf.normal, ng) < 0.0f ? -sf.normal : sf.normal;
    // A leaf lit from behind: everything that lights the surface, casts its shadow rays and bounces off it works on
    // the far side instead, which is all the light through a thin leaf needs.
    if (sf.backlit) { ng = -ng; ns = -ns; }
}

// Pixel-footprint spreads for texture filtering (ray cones without curvature): primary rays pass their pixel's angle,
// GI rays GI_RAY_SPREAD (Types.metal).

// The hit triangle's vertices (object space): from a cluster in the streaming pool, a virtual instance's BLAS over
// its cut, or the indexed mesh buffers.
struct HitVertices {
    float3 p[3];
    float3 n[3];
    float2 t[3];
    uint3 i;          // with prevOffset: the vertices' places in the position buffer
    uint triangle;    // its place in the index buffer / 3 (~0: virtual geometry, which has no index buffer)
    uint prevOffset;  // MeshData.prevOffset (0 = the previous frame's object-space positions are these ones)
    uint material;    // STREAMED: the triangle's material offset, read where its vertices are
    uint terrain;     // TERRAIN: MeshData.terrain (1 + its layer table's place), 0 = not a terrain's sector
    device const uchar4* weights;   // ...and its vertices' layer weights (4 uchar4 a vertex)
    bool   leaf;   // a leaf of an assembly's part: shaded with the material after the instance's
    bool   sways;  // ground cover, which leans in the wind (MeshData.sways)
};

// What a surface keeps of its instance, to tell it from its neighbours' (the trace writes it as a float): TILED, a
// number of 24 bits, which a float holds exactly, made from its id, which may be any.
inline uint surfaceInstance(uint id) { return TILED ? pcgHash(id) & 0xFFFFFFu : id; }

inline HitVertices fetchHitVertices(Hit res, InstanceData inst, SCENE_ACCEL accel, thread const SceneData& s) {
    HitVertices v;
    v.i = uint3(0u);
    v.prevOffset = 0;
    v.material = 0;
    v.triangle = ~0u;
    v.terrain = 0;
    v.weights = nullptr;
    v.leaf = v.sways = false;
    uint meshIndex = inst.meshIndex;
    if (inst.pad1 != 0) {
        // Virtual geometry, per-instance BLAS over the cut: positions from its triangles, attributes alongside.
        VGBlas e = accel.vgBlas[inst.pad1 - 1];
        for (uint k = 0; k < 3; ++k) v.p[k] = e.tris[3 * res.primitive + k].xyz;
        device const uint* a = e.attrs + 6 * res.primitive;
        for (uint k = 0; k < 3; ++k) {
            v.n[k] = octDecode(a[k]);
            v.t[k] = float2(as_type<half2>(a[3 + k]));
        }
        return v;
    }
    // An assembly's part: its mesh's triangle, brought into the plant's space (the instance's object space).
    bool inPart = ASSEMBLIES && res.part != HIT_NO_PART;
    RTPart part;
    if (inPart) {
        part = accel.parts[res.part];
        meshIndex = part.mesh;
        v.leaf = res.primitive >= part.firstLeaf;
    }
    MeshData mesh = s.meshes[meshIndex];
    v.sways = mesh.sways != 0;
    if (STREAMED && mesh.block != nullptr) {
        // A mesh in a buffer of its own: its arrays one after the other, its indices its own.
        device const float3* normals = mesh.block + mesh.vertexCount;
        device const float2* uvs = (device const float2*)(normals + mesh.vertexCount);
        device const uint* indices = (device const uint*)(uvs + mesh.vertexCount);
        for (uint k = 0; k < 3; ++k) {
            uint i = indices[res.primitive * 3 + k];
            v.i[k] = i;
            v.p[k] = mesh.block[i];
            v.n[k] = normals[i];
            v.t[k] = uvs[i];
        }
        if (MULTI_MATERIAL) v.material = ((device const uchar*)(indices + mesh.indexCount))[res.primitive];
        if (TERRAIN && mesh.terrain != 0u) {
            // After the materials, on 16 bytes (MeshBlock.weightsOffset).
            uint offset = (mesh.vertexCount * 40u + mesh.indexCount * 4u + mesh.indexCount / 3u + 15u) & ~15u;
            v.terrain = mesh.terrain;
            v.weights = (device const uchar4*)((device const uchar*)mesh.block + offset);
        }
    } else {
        uint base = mesh.firstIndex + res.primitive * 3;
        v.triangle = base / 3;
        for (uint k = 0; k < 3; ++k) {
            uint i = s.indices[base + k];
            uint own = DEFORMING_MESHES ? i + mesh.vertexOffset : i;   // a pose slot's own vertex
            v.i[k] = own;
            v.p[k] = s.positions[own];
            v.n[k] = s.normals[own];
            v.t[k] = s.uvs[i];
        }
        if (DEFORMING_MESHES) v.prevOffset = mesh.prevOffset;
    }
    if (inPart) {
        for (uint k = 0; k < 3; ++k) {
            v.p[k] = partPoint(part, v.p[k]);
            v.n[k] = partDirection(part, v.n[k]);
        }
    }
    return v;
}

// The full material index of hit `h` on instance `inst`: an SDF shape's node's offset, a leaf's, a mesh's triangles'
// (MULTI_MATERIAL), a streamed cluster's. (Pick's click and the solid look's colours.)
inline uint hitMaterialIndex(Hit h, InstanceData inst, SCENE_ACCEL accel, thread const SceneData& s) {
    uint material = inst.materialIndex;
    if (SDF_SHAPES && h.part == HIT_SDF) {
        material += h.primitive;
    } else if (!(VOXELS && h.part == HIT_VOXEL) && !(HAIR_CURVES && h.part == HIT_CURVE)) {
        HitVertices hv = fetchHitVertices(h, inst, accel, s);
        if (hv.leaf) material += 1u;
        if (MULTI_MATERIAL && hv.triangle != ~0u) material += s.triangleMaterials[hv.triangle];
        if (STREAMED) material += hv.material;
    }
    return material;
}

// TERRAIN: a terrain's sector (Scene+Terrain.swift). Its vertices' layer weights at the hit (layer 0: the sector's own
// material, as it is shaded; layers 1...15 the layer table's materials, TerrainDocument.layers), the three strongest
// layers blended over it: each sampled in the world's x, z (its table's UV per metre), and where the ground is steeper
// than its table says, projected from the sides too (biplanar, by how squarely the ground faces each axis).
inline void terrainLayers(thread Surface& sf, thread const HitVertices& hv, float w0, float2 bc, thread const SceneData& s,
                          float footprint, bool record) {
    uint table = hv.terrain - 1u;
    float4 head = s.procParams[table];
    float4 w[4];
    for (uint q = 0; q < 4; ++q) {
        w[q] = (float4(hv.weights[hv.i[0] * 4u + q]) * w0 + float4(hv.weights[hv.i[1] * 4u + q]) * bc.x
              + float4(hv.weights[hv.i[2] * 4u + q]) * bc.y) * (1.0f / 255.0f);
    }
    uint best[3] = {0u, 0u, 0u};
    float strongest[3] = {0.0f, 0.0f, 0.0f};
    for (uint l = 1; l < 16; ++l) {
        float x = w[l >> 2][l & 3u];
        if (x <= strongest[2]) continue;
        if (x > strongest[0]) {
            strongest[2] = strongest[1]; best[2] = best[1];
            strongest[1] = strongest[0]; best[1] = best[0];
            strongest[0] = x; best[0] = l;
        } else if (x > strongest[1]) {
            strongest[2] = strongest[1]; best[2] = best[1];
            strongest[1] = x; best[1] = l;
        } else {
            strongest[2] = x; best[2] = l;
        }
    }
    float layers = strongest[0] + strongest[1] + strongest[2];
    if (layers < 1e-3f) return;
    float total = w[0].x + layers;
    float own = w[0].x / total;
    float3 albedo = sf.albedo * own, normal = sf.normal * own;
    float roughness = sf.roughness * own, metallic = sf.metallic * own, specular = sf.specular * own;
    float3 world = sf.position + float3(head.y, 0.0f, head.z);
    float3 g = abs(sf.geomNormal);
    float3 pw = g * g;
    pw *= pw;
    pw /= max(pw.x + pw.y + pw.z, 1e-6f);
    for (uint k = 0; k < 3; ++k) {
        if (strongest[k] <= 0.0f) continue;
        uint l = best[k];
        float share = strongest[k] / total;
        uint mi = uint(head.x) + l - 1u;
        Material m = s.materials[mi];
        float4 rec = s.procParams[table + l];
        float scale = rec.x * (MATERIAL_EXTRAS ? s.extras[mi].surface.y : 1.0f);
        float lodBase = log2(max(footprint * scale, 1e-8f));
        // Level ground: from above only; steeper than the table's slope: from the sides too.
        bool sides = sf.geomNormal.y < rec.y;
        float3 c = m.albedo.rgb;
        float rough = m.emission.a, metal = m.albedo.a;
        if (m.textures.x != NO_TEXTURE || m.textures.y != NO_TEXTURE) {
            float4 base = 0.0f, mr = 0.0f;
            float2 uvs[3] = {world.zy * scale, world.xz * scale, world.xy * scale};
            float3 pick = sides ? pw : float3(0.0f, 1.0f, 0.0f);
            for (uint a = 0; a < 3; ++a) {
                if (pick[a] < 0.02f) continue;
                if (m.textures.x != NO_TEXTURE) base += pick[a] * sampleMaterial(s, m.textures.x, uvs[a], lodBase, record);
                if (m.textures.y != NO_TEXTURE) mr += pick[a] * sampleMaterial(s, m.textures.y, uvs[a], lodBase, record);
            }
            if (m.textures.x != NO_TEXTURE) c *= base.rgb;
            if (m.textures.y != NO_TEXTURE) { rough *= mr.g; metal *= mr.b; }
        }
        float3 n = sf.normal;
        if (m.textures.z != NO_TEXTURE && !sides) {
            // A normal map from above: the world's x and z its tangents.
            float3 t = sampleMaterial(s, m.textures.z, world.xz * scale, lodBase, false).xyz * 2.0f - 1.0f;
            t.xy *= m.params.y;
            float3 N = sf.normal, T = normalize(float3(1, 0, 0) - N * N.x), B = normalize(cross(T, N));
            n = normalize(T * t.x - B * t.y + N * max(t.z, 1e-3f));
        }
        albedo += c * share;
        roughness += rough * share;
        metallic += metal * share;
        specular += specularWeight(m.params.x) * share;
        normal += n * share;
    }
    sf.albedo = albedo;
    sf.roughness = roughness;
    sf.metallic = metallic;
    sf.specular = specular;
    sf.normal = normalize(normal);
}

// The realistic look's ground (SceneSettings.realism; its table's header says 16: Scene+Terrain.swift SceneTerrain.table).
// Its candidates: the scene's own ground (layer 0) as up to eight scanned layers a map mixes (Terrain/GroundLook.swift),
// rock where it is steep, and the three strongest painted layers. Each layer's height decides where it shows through
// the others (a height lerp: the layers whose height plus weight come within TERRAIN_BLEND_DEPTH of the highest win),
// then the winners are sampled from above, or on steep ground from the sides too (triplanar, their normal maps
// turned onto each side), at two scales that fade into each other with distance (the tiling's repeat hides in the
// larger), and darkened, tinted and roughened by a large-scale noise so that no two hillsides look alike.
constant float TERRAIN_BLEND_DEPTH = 0.12f;
constant float TERRAIN_PARALLAX_DEPTH = 0.06f;   // metres: pebbles, clods, the bark of the ground
constexpr sampler terrainMapSampler(filter::linear, mip_filter::none, address::clamp_to_edge);

struct TerrainCandidate {
    uint material;      // ~0: the sectors' own material as the hit already has it
    float weight;
    float scale;        // UV per metre
    float contrast;
    float ao;
};

// One layer sampled at a world place: from above (pick = (0, 1, 0)) or from the sides too, at one UV scale.
inline void terrainSampleLayer(thread const SceneData& s, Material m, float3 world, float scale, float3 pick, float lodBase, bool record,
                               float3 N, bool normals, thread float3& c, thread float4& ormh, thread float3& n) {
    float2 uvs[3] = {world.zy * scale, world.xz * scale, world.xy * scale};
    float4 base = 0.0f, mr = 0.0f;
    float3 pert = 0.0f;
    for (uint a = 0; a < 3; ++a) {
        if (pick[a] < 0.02f) continue;
        if (m.textures.x != NO_TEXTURE) base += pick[a] * sampleMaterial(s, m.textures.x, uvs[a], lodBase, record);
        // (Without normals, a GI ray's: the colour alone, the roughness as the scans' typical.)
        if (!normals) continue;
        if (m.textures.y != NO_TEXTURE) mr += pick[a] * sampleMaterial(s, m.textures.y, uvs[a], lodBase, record);
        if (normals && m.textures.z != NO_TEXTURE) {
            float3 t = sampleMaterial(s, m.textures.z, uvs[a], lodBase, record).xyz * 2.0f - 1.0f;
            t.xy *= m.params.y;
            // The map's u along the projection's first axis, its up (OpenGL: +Y) against its v.
            pert += pick[a] * (a == 0 ? float3(0.0f, -t.y, t.x) : a == 1 ? float3(t.x, 0.0f, -t.y) : float3(t.x, -t.y, 0.0f));
        }
    }
    c = m.textures.x != NO_TEXTURE ? base.rgb : float3(1.0f);
    ormh = m.textures.y != NO_TEXTURE && normals ? mr : float4(1.0f, normals ? 1.0f : 0.85f, 0.0f, 0.5f);
    n = normalize(N + pert);
}

inline void terrainRealistic(thread Surface& sf, thread const HitVertices& hv, float w0, float2 bc, thread const SceneData& s,
                             float footprint, bool record, float3 rayDir) {
    uint table = hv.terrain - 1u;
    float4 head = s.procParams[table];
    float4 info = s.procParams[table + 16u], rect = s.procParams[table + 17u], rockRow = s.procParams[table + 18u];
    float4 w[4];
    for (uint q = 0; q < 4; ++q) {
        w[q] = (float4(hv.weights[hv.i[0] * 4u + q]) * w0 + float4(hv.weights[hv.i[1] * 4u + q]) * bc.x
              + float4(hv.weights[hv.i[2] * 4u + q]) * bc.y) * (1.0f / 255.0f);
    }
    uint best[3] = {0u, 0u, 0u};
    float strongest[3] = {0.0f, 0.0f, 0.0f};
    for (uint l = 1; l < 16; ++l) {
        float x = w[l >> 2][l & 3u];
        if (x <= strongest[2]) continue;
        if (x > strongest[0]) {
            strongest[2] = strongest[1]; best[2] = best[1];
            strongest[1] = strongest[0]; best[1] = best[0];
            strongest[0] = x; best[0] = l;
        } else if (x > strongest[1]) {
            strongest[2] = strongest[1]; best[2] = best[1];
            strongest[1] = x; best[1] = l;
        } else {
            strongest[2] = x; best[2] = l;
        }
    }
    float total = max(w[0].x + strongest[0] + strongest[1] + strongest[2], 1e-4f);
    float own = w[0].x / total;
    float3 world = sf.position + float3(head.y, 0.0f, head.z);
    float3 N = sf.normal;
    bool fine = footprint < 0.25f;   // camera rays and near hits: normal maps, the height blend, the near scale

    // Large-scale noise: brightness, hue, roughness, break-up (Scene.terrainMacroTexture).
    float4 macro = 0.5f, macro2 = 0.5f;
    if (info.w >= 0.0f) {
        uint mt = uint(info.w);
        macro = sampleMaterial(s, mt, world.xz * (1.0f / 41.0f), log2(max(footprint / 41.0f, 1e-8f)), record);
        if (fine) macro2 = sampleMaterial(s, mt, world.xz * (1.0f / 197.0f), log2(max(footprint / 197.0f, 1e-8f)), false);
    }

    TerrainCandidate cand[8];
    uint count = 0;
    uint ground = uint(info.x);
    // The map's share: all of it inside, fading to the sectors' own material over its last 3% (an open world's map
    // covers the scene's middle).
    float2 raw = (sf.position.xz - rect.xy) * rect.zw;
    float2 edge = min(raw, 1.0f - raw);
    float mapped = ground > 0u && info.y >= 0.0f ? saturate(min(edge.x, edge.y) / 0.03f) : 0.0f;
    if (own > 0.0f && mapped < 1.0f) cand[count++] = {~0u, own * (1.0f - mapped), 1.0f, 0.0f, 0.0f};
    own *= mapped;
    if (own > 0.0f) {
        {
            float2 muv = clamp(raw, 0.0005f, 0.9995f);
            float4 a = sampleMaterial(s, uint(info.y), muv, -24.0f, record);
            float4 b = info.z >= 0.0f ? sampleMaterial(s, uint(info.z), muv, -24.0f, record) : float4(0.0f);
            float aw[8] = {a.x, a.y, a.z, a.w, b.x, b.y, b.z, b.w};
            int rock = int(rockRow.x);
            if (rock >= 0 && rock < 8) {
                float r = 1.0f - smoothstep(rockRow.y, rockRow.z, N.y + (macro.a - 0.5f) * 0.12f);
                for (uint k = 0; k < 8; ++k) aw[k] *= 1.0f - r;
                aw[rock] += r;
            }
            float sum = 0.0f;
            for (uint k = 0; k < min(ground, 8u); ++k) sum += aw[k];
            for (uint k = 0; k < min(ground, 8u) && count < 5u; ++k) {
                float x = aw[k] / max(sum, 1e-4f) * own;
                if (x < 0.02f) continue;
                float4 row = s.procParams[table + 19u + k];
                cand[count++] = {uint(row.x), x, row.y, row.z, row.w};
            }
        }
    }
    for (uint k = 0; k < 3; ++k) {
        float x = strongest[k] / total;
        if (x < 0.02f) continue;
        uint mi = uint(head.x) + best[k] - 1u;
        float4 rec = s.procParams[table + best[k]];
        cand[count++] = {mi, x, rec.x * (MATERIAL_EXTRAS ? s.extras[mi].surface.y : 1.0f), rec.z, rec.w};
    }
    if (count == 0u) return;

    float3 g = abs(N);
    float3 pw = g * g;
    pw *= pw;
    pw /= max(pw.x + pw.y + pw.z, 1e-6f);
    bool sides = N.y < 0.75f;
    float3 pick = sides ? pw : float3(0.0f, 1.0f, 0.0f);
    if (!fine) {
        // A GI ray's hit: its two strongest layers, each from the one axis the ground faces most.
        pick = pw.y >= pw.x && pw.y >= pw.z ? float3(0, 1, 0) : pw.x >= pw.z ? float3(1, 0, 0) : float3(0, 0, 1);
        if (count > 2u) {
            for (uint a = 0; a < 2u; ++a) {
                uint best = a;
                for (uint i = a + 1u; i < count; ++i) if (cand[i].weight > cand[best].weight) best = i;
                TerrainCandidate t = cand[a]; cand[a] = cand[best]; cand[best] = t;
            }
            count = 2u;
        }
    }

    // The height lerp: each candidate's height (from above: cheap, and what decides the mix) on its weight.
    float blend[8];
    float top = -1e9f;
    for (uint i = 0; i < count; ++i) {
        float h = 0.5f;
        if (fine && cand[i].material != ~0u) {
            Material m = s.materials[cand[i].material];
            if (m.textures.y != NO_TEXTURE)
                h = sampleMaterial(s, m.textures.y, world.xz * cand[i].scale, log2(max(footprint * cand[i].scale, 1e-8f)), false).a;
        }
        blend[i] = cand[i].weight + h * cand[i].contrast * 0.5f;
        top = max(top, blend[i]);
    }
    float sum = 0.0f;
    for (uint i = 0; i < count; ++i) {
        blend[i] = fine ? max(blend[i] - (top - TERRAIN_BLEND_DEPTH), 0.0f) : cand[i].weight;
        sum += blend[i];
    }

    // Realism "high" (header 17): near the camera, parallax: the blended heights as a field TERRAIN_PARALLAX_DEPTH deep
    // under the ground, marched from where the eye's ray enters it (level ground: from above only), and every layer
    // sampled where the ray meets it.
    if (head.w > 16.5f && fine && !sides && footprint < 0.004f) {
        uint top2[2] = {0u, 0u};
        float w2[2] = {0.0f, 0.0f};
        for (uint i = 0; i < count; ++i) {
            if (cand[i].material == ~0u) continue;
            float x = blend[i] / max(sum, 1e-6f);
            if (x > w2[0]) { top2[1] = top2[0]; w2[1] = w2[0]; top2[0] = i; w2[0] = x; }
            else if (x > w2[1]) { top2[1] = i; w2[1] = x; }
        }
        float norm = w2[0] + w2[1];
        if (norm > 0.5f) {
            // (Down the eye's ray: across the ground by its horizontal part over its vertical one.)
            float3 V = -normalize(rayDir);
            float up = max(dot(V, N), 0.1f);
            int steps = int(mix(24.0f, 8.0f, saturate(up)));
            float layer = 1.0f / float(steps);
            float2 shift = V.xz / up * TERRAIN_PARALLAX_DEPTH * layer * (1.0f - smoothstep(0.002f, 0.004f, footprint));
            float2 at = world.xz, prevAt = at;
            float d = 0.0f, prevD = 0.0f, h = 1.0f, prevH = 1.0f;
            for (int k = 0; k <= steps; ++k) {
                h = 0.0f;
                for (uint j = 0; j < 2; ++j) {
                    if (w2[j] <= 0.0f) continue;
                    Material m = s.materials[cand[top2[j]].material];
                    float sc = cand[top2[j]].scale;
                    float hj = m.textures.y != NO_TEXTURE ? sampleMaterial(s, m.textures.y, at * sc, log2(max(footprint * sc, 1e-8f)), false).a : 0.5f;
                    h += hj * w2[j] / norm;
                }
                if (d >= 1.0f - h) break;
                prevAt = at; prevD = d; prevH = h;
                at -= shift;
                d += layer;
            }
            float after = (1.0f - h) - d, before = (1.0f - prevH) - prevD;
            float t = after / min(after - before, -1e-6f);
            world.xz = mix(at, prevAt, saturate(t));
        }
    }

    float3 albedo = 0.0f, normal = 0.0f;
    float roughness = 0.0f, metallic = 0.0f, specular = 0.0f;
    // Two scales: the layer's own near, four times larger far (where the repeat would show).
    float farT = smoothstep(0.02f, 0.08f, footprint);
    for (uint i = 0; i < count; ++i) {
        float share = blend[i] / max(sum, 1e-6f);
        if (share < 0.01f) continue;
        if (cand[i].material == ~0u) {
            albedo += sf.albedo * share;
            normal += sf.normal * share;
            roughness += sf.roughness * share;
            metallic += sf.metallic * share;
            specular += sf.specular * share;
            continue;
        }
        Material m = s.materials[cand[i].material];
        float3 c = 0.0f, n = N;
        float4 ormh = 0.0f;
        float near = cand[i].scale, far = cand[i].scale * 0.25f;
        if (farT < 1.0f) {
            float3 c1, n1;
            float4 o1;
            terrainSampleLayer(s, m, world, near, pick, log2(max(footprint * near, 1e-8f)), record, N, fine, c1, o1, n1);
            c += c1 * (1.0f - farT); ormh += o1 * (1.0f - farT); n = n1;
        }
        if (farT > 0.0f) {
            float3 c2, n2;
            float4 o2;
            terrainSampleLayer(s, m, world, far, pick, log2(max(footprint * far, 1e-8f)), record && farT >= 1.0f, N, fine && farT < 1.0f, c2, o2, n2);
            c += c2 * farT; ormh += o2 * farT;
            if (farT >= 1.0f) n = n2; else n = normalize(mix(n, n2, farT * 0.5f));
        }
        c *= m.albedo.rgb;
        c *= mix(1.0f, ormh.r, cand[i].ao);
        albedo += c * share;
        normal += n * share;
        roughness += m.emission.a * ormh.g * share;
        metallic += m.albedo.a * ormh.b * share;
        specular += specularWeight(m.params.x) * share;
    }
    // The large-scale noise: ±18% brightness, a little toward yellow or grey, roughness.
    albedo *= (0.82f + 0.36f * macro.r) * (0.88f + 0.24f * macro2.r);
    float l = dot(albedo, float3(0.2126f, 0.7152f, 0.0722f));
    albedo = max(mix(float3(l), albedo, 0.85f + 0.3f * macro2.g) * float3(1.0f + 0.06f * (macro.g - 0.5f), 1.0f, 1.0f - 0.1f * (macro.g - 0.5f)), 0.0f);
    sf.albedo = albedo;
    sf.roughness = saturate(roughness + (macro.b - 0.5f) * 0.12f);
    sf.metallic = metallic;
    sf.specular = specular;
    sf.normal = normalize(normal);
}

// A hit's material, as it is before its textures.
inline void surfaceMaterial(thread Surface& sf, Material mat) {
    sf.albedo = mat.albedo.rgb;
    sf.emission = mat.emission.rgb;
    sf.metallic = mat.albedo.a;
    sf.roughness = mat.emission.a;
    sf.specular = specularWeight(mat.params.x);
    sf.coat = mat.params.x >= 2.0f ? mat.params.x - 2.0f : -1.0f;
    sf.lightEmitter = mat.params.z > 0.0f;
    sf.skin = max(-mat.params.w, 0.0f);
}

// Metallic-roughness, once the textures are in: metals reflect their base colour, dielectrics 4% (x weight).
// A clear coat over metallic paint (a car's): the coat is the specular lobe, a dielectric's 4% at its roughness (the
// material's), so it is what the reflection rays, the lights' highlights and the path tracer see; the paint under it,
// its colour and its metallic flakes' own GGX lobe (of the paint's roughness: `coat`), is what the coat lets through,
// the flakes' lobe there as its split-sum albedo (it is broad: as good as diffuse in light from all round).
inline void surfaceSpecular(thread Surface& sf) {
    if (sf.specular > 0.0f && sf.coat >= 0.0f) {
        float3 flakes = mix(float3(0.04f), sf.albedo, sf.metallic);
        float3 paint = sf.albedo * (1.0f - sf.metallic) + specularAlbedo(flakes, 1.0f, max(sf.coat, MIN_ROUGHNESS), 1.0f);
        float3 coat = float3(0.04f);
        sf.albedo = paint * (1.0f - specularAlbedo(coat, 1.0f, max(sf.roughness, MIN_ROUGHNESS), 1.0f));
        sf.f0 = coat;
        sf.metallic = 0.0f;
        return;
    }
    if (sf.specular > 0.0f) {
        sf.f0 = mix(float3(0.04f * sf.specular), sf.albedo, sf.metallic);
        sf.albedo *= 1.0f - sf.metallic;
    }
}

// Value noise in [0, 1] over a grid of unit cells (smoothed), for the cars' damage's patches.
inline float damageNoise(float2 p) {
    float2 i = floor(p), f = p - i;
    f = f * f * (3.0f - 2.0f * f);
    uint2 c = uint2(int2(i));
    float a = float(pcgHash(c.x * 0x9E3779B9u ^ pcgHash(c.y)) & 0xFFFFu), b = float(pcgHash((c.x + 1u) * 0x9E3779B9u ^ pcgHash(c.y)) & 0xFFFFu);
    float d = float(pcgHash(c.x * 0x9E3779B9u ^ pcgHash(c.y + 1u)) & 0xFFFFu), e = float(pcgHash((c.x + 1u) * 0x9E3779B9u ^ pcgHash(c.y + 1u)) & 0xFFFFu);
    return mix(mix(a, b, f.x), mix(d, e, f.x), f.y) * (1.0f / 65535.0f);
}

// How much of [x - h/2, x + h/2] lines `w` wide (a share of their period, 1) cover, the lines at the integers.
inline float gridCoverage(float x, float w, float h) {
    h = max(h, 1e-4f);
    float a = x + w * 0.5f - h * 0.5f, b = a + h;
    float fa = floor(a) * w + min(a - floor(a), w), fb = floor(b) * w + min(b - floor(b), w);
    return saturate((fb - fa) / h);
}

// The material kind of Unreal's preview floor (MaterialExtra.textures.z, GPUTypes.swift GPUMaterialExtra.gridKind).
constant uint GRID_KIND = 3u;

// Unreal's preview floor (its M_Grid, here computed): tiles `ex.surface.y` m square ruled at their edges, a subgrid of
// five a tile at `ex.surface.x` of the lines' strength, crosses at every other corner at `ex.surface.w`; the lines are
// `ex.surface.z` of the base colour. World-aligned, on the plane the triangle faces most; filtered over the ray's footprint (`footprint` across it, `stretch` times that along the view),
// so that far off it is the lines' mean grey and shimmers not.
inline void previewGrid(thread Surface& sf, MaterialExtra ex, float3 dir, float footprint) {
    float3 a = abs(sf.geomNormal);
    float size = max(ex.surface.y, 1e-3f);
    float2 p = planarUV(sf.position, a) / size;
    // The footprint on the plane (in tiles): the view's own direction in it is stretched by the grazing.
    float3 n = normalize(sf.geomNormal);
    float cosTheta = max(abs(dot(dir, n)), 0.02f);
    float2 along = planarUV(dir - dot(dir, n) * n, a);
    along = dot(along, along) > 1e-8f ? normalize(along) : float2(1.0f, 0.0f);
    float stretch = 1.0f / cosTheta;
    float2 h = footprint / size * sqrt(1.0f + (stretch * stretch - 1.0f) * along * along);
    // The tiles' edges (1.2% of a tile), the subgrid (1% of a tile, so 5% of its own fifths).
    float edge = 1.0f - (1.0f - gridCoverage(p.x, 0.012f, h.x)) * (1.0f - gridCoverage(p.y, 0.012f, h.y));
    float sub = 1.0f - (1.0f - gridCoverage(p.x * 5.0f, 0.05f, h.x * 5.0f)) * (1.0f - gridCoverage(p.y * 5.0f, 0.05f, h.y * 5.0f));
    // The crosses: every 2 tiles, arms 3.9% of a tile thick reaching 14.5% from the corner.
    float2 q = p * 0.5f, hq = h * 0.5f;
    float thinX = gridCoverage(q.x, 0.0195f, hq.x), thinY = gridCoverage(q.y, 0.0195f, hq.y);
    float longX = gridCoverage(q.x, 0.145f, hq.x), longY = gridCoverage(q.y, 0.145f, hq.y);
    float cross = thinX * longY + longX * thinY - thinX * thinY;
    float lines = edge + ex.surface.x * sub * (1.0f - edge);
    lines = saturate(lines + ex.surface.w * cross * (1.0f - lines));
    sf.albedo *= mix(1.0f, ex.surface.z, lines);
}

// A car's damage at a hit on its panels (SceneBuffers.damage: per vertex, from the nodes it follows,
// physicsSoftMeshKernel; CarDamage.swift): a broken lamp is dark; the paint (a clear coat) is dulled by its dirt,
// creased and cracked to its primer where it is crushed, scratched to its primer and scraped to bare metal where it
// slid on what it hit, each in patches (noise over its texture's coordinates) that spread as the damage grows.
inline void carDamage(thread Surface& sf, thread const HitVertices& hv, float w0, float2 bc, thread const SceneData& s, float2 uv) {
    float4 d = (float4(s.damage[hv.i[0]]) * w0 + float4(s.damage[hv.i[1]]) * bc.x + float4(s.damage[hv.i[2]]) * bc.y) * (1.0f / 255.0f);
    if (all(d < float4(0.004f))) return;
    if (d.w > 0.5f) {
        sf.emission = float3(0.0f);
        sf.albedo *= 0.3f;
    }
    if (sf.coat < 0.0f) return;
    float n = 0.65f * damageNoise(uv * 90.0f) + 0.35f * damageNoise(uv * 260.0f + 17.0f);
    float film = saturate(d.z * (0.5f + n));
    sf.albedo = mix(sf.albedo, float3(0.16f, 0.13f, 0.1f), 0.85f * film);
    sf.roughness = mix(sf.roughness, 0.75f, film);
    sf.albedo *= 1.0f - 0.25f * d.x;
    float primer = max(saturate((d.x - 0.35f - 0.4f * n) * 6.0f), saturate((d.y - 0.05f - 0.4f * n) * 6.0f));
    float metal = saturate((d.y - 0.25f - 0.6f * n) * 5.0f);
    primer *= 1.0f - metal;
    if (primer + metal < 0.5f) return;
    // (The coat is gone there: the primer is a dull dielectric, the bare steel a metal.)
    sf.coat = -1.0f;
    sf.specular = 1.0f;
    sf.metallic = metal / (primer + metal);
    sf.albedo = mix(float3(0.42f, 0.42f, 0.4f), float3(0.62f, 0.62f, 0.64f), sf.metallic);
    sf.roughness = mix(0.65f, 0.3f, sf.metallic);
}

// The surface a ray met: the hit's triangle (or voxel) rebuilt in world space, with its material and textures.
Surface surfaceFromHit(Hit res, Ray r, SCENE_ACCEL accel, thread const SceneData& s, float spread, bool record) {
    Surface sf;
    if (MATERIAL_LOBES) {
        sf.sheen = float4(0.0f);
        sf.lobeTangent = float3(0.0f);
        sf.anisotropy = 0.0f;
    }
    sf.hit = false;
    sf.position = sf.prevPosition = sf.normal = sf.geomNormal = sf.albedo = sf.emission = float3(0.0f);
    sf.metallic = sf.specular = 0.0f;
    sf.coat = -1.0f;
    sf.roughness = 1.0f;
    sf.f0 = float3(0.0f);
    sf.instanceId = 0;
    sf.lightEmitter = false;
    sf.backlit = false;
    sf.hair = false;
    sf.tangent = float3(0.0f);
    sf.hairH = 0.0f;
    sf.skin = 0.0f;
    sf.leaf = 0.0f;
    if (!res.hit) return sf;

    uint id = res.instance;
    InstanceData inst = instanceRecord(s.instances, id);
    if (VOXELS && res.part == HIT_VOXEL) {
        // A far plant's voxel: where the ray stopped in it, the voxel's mean normal, and its wood's and leaves'
        // colours by how much of it is leaf.
        float2 e = float2(float(res.primitive & 0xFFu), float((res.primitive >> 8) & 0xFFu)) * (2.0f / 255.0f) - 1.0f;
        float3 n = float3(e, 1.0f - abs(e.x) - abs(e.y));
        if (n.z < 0.0f) n.xy = (1.0f - abs(n.yx)) * select(float2(-1.0f), float2(1.0f), n.xy >= 0.0f);
        // Leaves hide most of the wood they hang on: the voxel shows more leaf than its share of the area. And what
        // is in a voxel shades itself, which a single point of it can't: VOXEL_SHADE makes up for that (matched to
        // the triangles' mean brightness in the forest from above).
        float leaf = sqrt(float((res.primitive >> 16) & 0xFFu) * (1.0f / 255.0f));
        sf.hit = true;
        sf.position = r.origin + r.direction * res.distance;
        sf.prevPosition = sf.position;
        sf.normal = sf.geomNormal = normalize((inst.normalMatrix * float4(normalize(n), 0.0f)).xyz);
        Material leaves = s.materials[inst.materialIndex + 1u];
        sf.albedo = VOXEL_SHADE * GENERATED_TEXTURE_MEAN * mix(s.materials[inst.materialIndex].albedo.rgb, leaves.albedo.rgb, leaf);
        if (leaves.params.w > 0.0f) {   // its leaves' share of light from behind, as for a leaf below
            sf.backlit = float(pcgHash(res.primitive ^ as_type<uint>(res.distance)) & 0xFFFFu) * (1.0f / 65536.0f) < leaves.params.w * leaf;
            if (sf.backlit) sf.albedo *= LEAF_TRANSMIT_TINT;
        }
        sf.instanceId = surfaceInstance(id);
        return sf;
    }
    if (HAIR_CURVES && res.part == HIT_CURVE) {
        // A strand's segment (Scene.addCurves): its four control points, where they are now and where they were a
        // frame ago (they deform, as a cloth's vertices do); the point on its axis at the hit's parameter, the
        // normal out from there, and the same offset from last frame's axis point.
        MeshData mesh = s.meshes[inst.meshIndex];
        uint first = mesh.vertexOffset + s.indices[mesh.firstIndex + res.primitive];
        float3 c0 = s.positions[first], c1 = s.positions[first + 1], c2 = s.positions[first + 2], c3 = s.positions[first + 3];
        float t = res.barycentrics.x;
        float3 axis = catmullRom(c0, c1, c2, c3, t);
        float3 tangent = catmullRomTangent(c0, c1, c2, c3, t);
        tangent = length_squared(tangent) > 1e-20f ? normalize(tangent) : float3(0, 1, 0);
        float3 world = r.origin + r.direction * res.distance;
        float3 radial = world - axis;
        radial -= tangent * dot(radial, tangent);
        float3 view = -normalize(r.direction);
        float3 n = length_squared(radial) > 1e-20f ? normalize(radial) : normalize(view - tangent * dot(view, tangent) + 1e-6f);
        float3 prevAxis = axis;
        if (mesh.prevOffset != 0) {
            uint q = first + mesh.prevOffset;
            prevAxis = catmullRom(s.positions[q], s.positions[q + 1], s.positions[q + 2], s.positions[q + 3], t);
        }
        sf.hit = true;
        sf.position = world;
        sf.prevPosition = prevAxis + (world - axis);
        sf.normal = sf.geomNormal = n;
        Material mat = s.materials[inst.materialIndex];
        surfaceMaterial(sf, mat);
        sf.instanceId = surfaceInstance(id);
        sf.hair = mat.params.z < 0.0f;
        sf.tangent = tangent;
        // pbrt's h: in the strand's frame x = tangent, y = the view across it, z = x cross y, the normal is
        // (cos gamma) y - (sin gamma) z, and h = sin gamma.
        sf.hairH = hairOffset(n, tangent, view);
        if (sf.hair) {
            sf.albedo = max(sf.albedo, float3(0.02f));   // HAIR_MIN_ALBEDO: the light on it is divided by its colour
            sf.specular = 0.0f;
        }
        surfaceSpecular(sf);
        return sf;
    }
    if (SDF_SHAPES && res.part == HIT_SDF) {
        // An SDF shape: the march gave the normal (the instance's space) and the material offset there. It moves
        // rigidly with its instance: where the point was a frame ago is where the instance's last transform put it.
        float4 world = float4(r.origin + r.direction * res.distance, 1.0f);
        float3 objPos = float3(dot(inst.normalMatrix[0], world), dot(inst.normalMatrix[1], world), dot(inst.normalMatrix[2], world));
        sf.hit = true;
        sf.position = world.xyz;
        sf.prevPosition = (inst.prevTransform * float4(objPos, 1.0f)).xyz;
        float3 objN = sdfOctDecode(res.barycentrics);
        sf.normal = sf.geomNormal = normalize((inst.normalMatrix * float4(objN, 0.0f)).xyz);
        Material mat = s.materials[inst.materialIndex + res.primitive];
        surfaceMaterial(sf, mat);
        sf.instanceId = surfaceInstance(id);
        if (any(mat.textures.xyw != uint3(NO_TEXTURE))) {
            // No UVs: the textures are projected along the instance's three axes (once per unit), each weighed by
            // how squarely the surface faces it. Their level from the ray's footprint, as below. (No normal maps.)
            float3 w = objN * objN;
            w *= w;
            w /= w.x + w.y + w.z;
            float cosTheta = max(abs(dot(normalize(r.direction), sf.geomNormal)), 0.2f);
            float objPerWorld = length(inst.normalMatrix[0].xyz);
            float lodBase = log2(max(res.distance * length(r.direction) * spread / cosTheta * objPerWorld, 1e-8f));
            float2 uvs[3] = {objPos.zy, objPos.xz, objPos.xy};
            float4 albedo = 0.0f, mr = 0.0f, emission = 0.0f;
            for (uint a = 0; a < 3; ++a) {
                if (w[a] < 0.01f) continue;
                if (mat.textures.x != NO_TEXTURE) albedo += w[a] * sampleMaterial(s, mat.textures.x, uvs[a], lodBase, record);
                if (mat.textures.y != NO_TEXTURE) mr += w[a] * sampleMaterial(s, mat.textures.y, uvs[a], lodBase, record);
                if (mat.textures.w != NO_TEXTURE) emission += w[a] * sampleMaterial(s, mat.textures.w, uvs[a], lodBase, record);
            }
            if (mat.textures.x != NO_TEXTURE) sf.albedo *= albedo.rgb;
            if (mat.textures.y != NO_TEXTURE) { sf.roughness *= mr.g; sf.metallic *= mr.b; }
            if (mat.textures.w != NO_TEXTURE) sf.emission *= emission.rgb;
        }
        surfaceSpecular(sf);
        return sf;
    }
    float2 bc = res.barycentrics;
    float w0 = 1.0f - bc.x - bc.y;
    HitVertices hv = fetchHitVertices(res, inst, accel, s);
    float3 p0 = hv.p[0], p1 = hv.p[1], p2 = hv.p[2], n0 = hv.n[0], n1 = hv.n[1], n2 = hv.n[2];
    float2 t0 = hv.t[0], t1 = hv.t[1], t2 = hv.t[2];
    float3 objPos = p0 * w0 + p1 * bc.x + p2 * bc.y;
    float3 objN   = n0 * w0 + n1 * bc.x + n2 * bc.y;
    float3 objNg  = cross(p1 - p0, p2 - p0);

    float3 prevObjPos = objPos;
    // A deforming mesh (a crowd's pose slot): where the point was in the previous frame's pose.
    if (DEFORMING_MESHES && hv.prevOffset != 0) {
        prevObjPos = s.positions[hv.i[0] + hv.prevOffset] * w0 + s.positions[hv.i[1] + hv.prevOffset] * bc.x
                   + s.positions[hv.i[2] + hv.prevOffset] * bc.y;
    }
    if (FOLIAGE && res.part != HIT_NO_PART && windOn(accel.wind.z > 0.0f) && accel.parts[res.part].pad != RT_PART_RIGID) {
        // An assembly's part in the wind: the triangle was hit where the wind has turned it to. Its point now and a
        // frame ago (the motion vector), and its normals now.
        RTPart part = accel.parts[res.part];
        float4 r0 = inst.normalMatrix[0], r1 = inst.normalMatrix[1], r2 = inst.normalMatrix[2];   // world -> plant rows
        prevObjPos = partWind(part, plantWind(accel.wind, accel.windTime.y, r0, r1, r2, id), accel.wind.z, objPos, true);
        PlantWind w = plantWind(accel.wind, accel.windTime.x, r0, r1, r2, id);
        objPos = partWind(part, w, accel.wind.z, objPos, true);
        objN = partWind(part, w, accel.wind.z, objN, false);
        objNg = partWind(part, w, accel.wind.z, objNg, false);
    } else if (FOLIAGE && hv.sways && windOn(accel.wind.z > 0.0f)) {
        // Ground cover: sheared downwind by its height (coverLean), now and a frame ago. A shear by k along y takes a
        // normal n to n - y (k . n).
        float4 r0 = inst.normalMatrix[0], r1 = inst.normalMatrix[1], r2 = inst.normalMatrix[2];
        float3 lean = coverLean(accel.wind, accel.windTime.x, r0, r1, r2);
        prevObjPos = objPos + coverLean(accel.wind, accel.windTime.y, r0, r1, r2) * objPos.y;
        objPos += lean * objPos.y;
        objN.y -= dot(lean, objN);
        objNg.y -= dot(lean, objNg);
    }
    uint materialIndex = inst.materialIndex + (hv.leaf ? 1u : 0u);
    if (MULTI_MATERIAL && hv.triangle != ~0u) materialIndex += s.triangleMaterials[hv.triangle];
    if (STREAMED) materialIndex += hv.material;
    Material mat = s.materials[materialIndex];
    sf.hit = true;
    sf.position = (inst.transform * float4(objPos, 1.0f)).xyz;
    sf.prevPosition = (inst.prevTransform * float4(prevObjPos, 1.0f)).xyz;
    if (FOLIAGE && res.part != HIT_NO_PART) {
        // A part's point from its rest pose and the wind above is not quite where the ray met it (its variant is posed
        // apart, PlantTracing): the point is the hit, and a frame ago it was as far from there as the wind moved it.
        // (Otherwise a still plant's leaves have motion vectors, and the history the denoisers and the AA keep smears.)
        float3 hit = r.origin + r.direction * res.distance;
        sf.prevPosition = hit + (sf.prevPosition - sf.position);
        sf.position = hit;
    }
    sf.normal = normalize((inst.normalMatrix * float4(objN, 0.0f)).xyz);
    sf.geomNormal = normalize((inst.normalMatrix * float4(objNg, 0.0f)).xyz);
    surfaceMaterial(sf, mat);
    sf.instanceId = surfaceInstance(id);
    MaterialExtra ex = { uint4(NO_TEXTURE), float4(0.0f, 1.0f, 0.5f, 0.0f) };
    if (MATERIAL_EXTRAS) ex = s.extras[materialIndex];
    uint leafId = (res.primitive >> 1) ^ (res.part * 0x9E3779B9u) ^ (id * 0x85EBCA6Bu);
    // An outline leaf (Foliage.LeafOutline: a leaf of the scanned sheet traced, 24 triangles): its number is the whole
    // part of its V (the same at its three vertices), and its UVs are already where it is on the sheet. (Wood's V runs
    // past 1 too, along it: only a leaf's triangles count.)
    float leafNumber = floor(t0.y);
    bool outlineLeaf = FOLIAGE && (hv.leaf || mat.params.w > 0.0f) && leafNumber >= 1.0f && floor(t1.y) == leafNumber
                    && floor(t2.y) == leafNumber;
    // Its U's whole part is its twig's health (Growth.twig: 0 a shaded twig's, 7 one in full light).
    float leafHealth = 1.0f;
    if (outlineLeaf) {
        t0.y -= leafNumber; t1.y -= leafNumber; t2.y -= leafNumber;
        float tag = floor(t0.x);
        t0.x -= tag; t1.x -= tag; t2.x -= tag;
        leafHealth = saturate(tag / 7.0f);
        leafId = pcgHash(uint(leafNumber)) ^ (res.part * 0x9E3779B9u) ^ (id * 0x85EBCA6Bu);
    }
    // A grown plant's wood (Growth.wood): its generation is the whole part of its U (0 the trunk).
    bool plantWood = FOLIAGE && res.part != HIT_NO_PART && !hv.leaf && accel.parts[res.part].pad != RT_PART_RIGID;
    float woodGeneration = plantWood ? floor(min(t0.x, min(t1.x, t2.x)) + 1e-3f) : 0.0f;
    // The realistic look's leaves (their extras' parallax negative: Scene.markRealisticLeaf): each its own shade,
    // two-sided where the camera sees it, fluttering. A leaf sheet's (parallax minus its cells a side): each leaf shows
    // one of the sheet's leaves, picked and mirrored by the leaf, its UVs (across, base to tip) inside that leaf's outline.
    bool leafLook = MATERIAL_EXTRAS && ex.surface.x < 0.0f;
    bool onSheet = leafLook && ex.surface.x <= -1.0f;
    bool sheetLeaf = onSheet && !outlineLeaf;
    if (outlineLeaf && !onSheet) {
        // On a material without the sheet (the generated look's leaf): each its own cell's UVs (the sheet its outline
        // was traced from is 3 by 3, or as the extra's z says: 16 × columns + rows, Scene.markRealisticLeaf).
        uint g = uint(max(ex.surface.z, 0.0f));
        float2 grid = g >= 16u ? float2(float(g >> 4), float(max(g & 15u, 1u))) : float2(3.0f);
        t0 = fract(t0 * grid); t1 = fract(t1 * grid); t2 = fract(t2 * grid);
    }
    if (sheetLeaf) {
        float cells = -ex.surface.x;
        uint h = pcgHash(leafId * 7u + 3u), n = uint(cells);
        float2 cell = float2(float(h % n), float((h / n) % n));
        float flip = (h & 0x10000u) != 0u ? -1.0f : 1.0f;
        t0 = (cell + float2(0.5f + flip * (t0.x - 0.5f) * 0.62f, 0.93f - t0.y * 0.85f)) / cells;
        t1 = (cell + float2(0.5f + flip * (t1.x - 0.5f) * 0.62f, 0.93f - t1.y * 0.85f)) / cells;
        t2 = (cell + float2(0.5f + flip * (t2.x - 0.5f) * 0.62f, 0.93f - t2.y * 0.85f)) / cells;
    }
    if (FOLIAGE && leafLook && res.part != HIT_NO_PART) {
        // A tree's leaf (an assembly's): its normal bent toward the crown's outside, as Unreal's and SpeedTree's foliage
        // do, so a crown shades as one rounded mass, not as leaves each turned its own way. In plant space (y up from
        // its foot) the crown's middle is on the trunk below the leaf: a leaf at the side faces out, one on top faces
        // up. Each leaf keeps its side (it is two-sided: orientNormals turns it to the ray). Up close, less of it: a leaf
        // there is big enough to show its own shape. (GI's rays are wide: theirs is always the crown's.)
        float3 outward = (inst.normalMatrix * float4(objPos - float3(0.0f, LEAF_CROWN_CENTRE * objPos.y, 0.0f), 0.0f)).xyz;
        float pixel = res.distance * length(r.direction) * spread;
        float crown = LEAF_CROWN_NORMAL * smoothstep(LEAF_CROWN_NEAR, LEAF_CROWN_FAR, pixel);
        if (dot(outward, outward) > 1e-8f && crown > 0.0f) {
            outward = normalize(outward);
            sf.normal = normalize(mix(sf.normal, dot(sf.normal, outward) >= 0.0f ? outward : -outward, crown));
        }
    }
    if (FOLIAGE && leafLook && windOn(accel.wind.z > 0.0f)) {
        // Flutter: each leaf's normal tips to and fro on its own (the shading's only: nothing moves).
        uint h = pcgHash(leafId ^ 0x27d4eb2du);
        float phase = float(h & 0xFFFFu) * (6.2831853f / 65536.0f), rate = 5.0f + 4.0f * float((h >> 16) & 0xFFu) / 255.0f;
        float3 ft, fb;
        tangentFrame(sf.normal, ft, fb);
        float a = accel.windTime.x * rate + phase, amount = 0.22f * min(accel.wind.z, 2.0f);
        sf.normal = normalize(sf.normal + amount * (ft * sin(a) + fb * 0.6f * sin(1.7f * a + phase)));
    }
    if (mat.params.w > 0.0f) {
        // Translucent (a leaf): the material's share of the leaves shows the light of the far side, the rest that of
        // the near side. Leaf by leaf (two triangles are one), always the same ones: nothing flickers, and a crown
        // as a whole reflects and transmits in the material's proportion. A sheet's leaf seen by the camera is two-
        // sided instead (LEAF_TRANSMIT): lit from both sides at once.
        // (Its share still faces away for the light that reaches it some other way: GI's, gathered about its normal.)
        // A realistic leaf met by a GI ray picks its side by the ray instead: every leaf reflects and transmits, as
        // many rays see it, where the leaf's own pick lit each from one side only.
        uint side = LEAF_TRANSMIT && leafLook && spread >= 0.02f ? leafId ^ pcgHash(as_type<uint>(res.distance)) : leafId;
        sf.backlit = float(pcgHash(side) & 0xFFFFu) * (1.0f / 65536.0f) < mat.params.w;
        if (sf.backlit) sf.albedo *= LEAF_TRANSMIT_TINT;
        if (LEAF_TRANSMIT && leafLook && spread < 0.02f) sf.leaf = mat.params.w;
    }
    if (MATERIAL_EXTRAS && ex.textures.z == 1u) {
        // A procedural material on a mesh without UVs (a generated scene's: an assignment, MaterialAssignments): the
        // triangle's world positions projected along its most facing axis, a tile a metre.
        float2 d1 = t1 - t0, d2 = t2 - t0;
        if (abs(d1.x * d2.y - d1.y * d2.x) < 1e-12f) {
            float3 w0p = (inst.transform * float4(p0, 1.0f)).xyz, w1p = (inst.transform * float4(p1, 1.0f)).xyz,
                   w2p = (inst.transform * float4(p2, 1.0f)).xyz;
            float3 a = abs(cross(w1p - w0p, w2p - w0p));
            t0 = planarUV(w0p, a); t1 = planarUV(w1p, a); t2 = planarUV(w2p, a);
        }
    }
    if (MATERIAL_EXTRAS && (ex.textures.z & 0xC0000000u) == 0x80000000u && hv.triangle != ~0u) {
        // A painted object (Scene+Painted.swift): its corners' own UVs, after the vertices' (the offset to its mesh's
        // first triangle's, in the low 30 bits; ~0 is a material without extras).
        uint c = uint((int(ex.textures.z << 2) >> 2) + int(3u * hv.triangle));
        t0 = s.uvs[c]; t1 = s.uvs[c + 1u]; t2 = s.uvs[c + 2u];
    }
    if (any(mat.textures != uint4(NO_TEXTURE)) || (MATERIAL_EXTRAS && ex.textures.x != NO_TEXTURE)
        || (PROCEDURAL_CODE && ex.textures.w != NO_TEXTURE)) {
        float2 uv = t0 * w0 + t1 * bc.x + t2 * bc.y;
        // Texture level from the ray's footprint: width = distance x spread, stretched by the incidence angle,
        // converted to UV units by the triangle's UV-to-world area ratio.
        float3 e1 = (inst.transform * float4(p1 - p0, 0.0f)).xyz, e2 = (inst.transform * float4(p2 - p0, 0.0f)).xyz;
        float2 d1 = t1 - t0, d2 = t2 - t0;
        float worldArea = length(cross(e1, e2));
        float uvArea = abs(d1.x * d2.y - d1.y * d2.x);
        float cosTheta = max(abs(dot(normalize(r.direction), sf.geomNormal)), 0.2f);
        float footprint = res.distance * length(r.direction) * spread / cosTheta;
        // UV units per world unit along the triangle's most stretched edge (like the hardware's larger derivative):
        // the area ratio would call a sliver in UV space "magnified" and ask for the finest mip.
        float3 e3 = e2 - e1;
        float2 d3 = d2 - d1;
        float stretch = max(length(d1) / max(length(e1), 1e-12f),
                            max(length(d2) / max(length(e2), 1e-12f), length(d3) / max(length(e3), 1e-12f)));
        float lodBase = worldArea > 0.0f && stretch > 0.0f ? log2(max(footprint, 1e-8f) * stretch) : 0.0f;
        if (MATERIAL_EXTRAS) {
            // A procedural material: its UV scale, and the place its height's parallax moves the hit to.
            uv *= ex.surface.y;
            lodBase += log2(max(ex.surface.y, 1e-6f));
            if (ex.textures.x != NO_TEXTURE && ex.surface.x > 0.0f && spread < PARALLAX_SPREAD && uvArea > 0.0f) {
                float invDet = 1.0f / (d1.x * d2.y - d1.y * d2.x);
                float3 T = (e1 * d2.y - e2 * d1.y) * invDet, B = (e2 * d1.x - e1 * d2.x) * invDet;
                float3 N = sf.normal;
                T = T - N * dot(N, T);
                B = B - N * dot(N, B);
                if (dot(T, T) > 1e-12f && dot(B, B) > 1e-12f)
                    uv = parallaxUV(s, ex.textures.x, uv, -normalize(r.direction), T, B, N, ex.surface.x, lodBase);
            }
        }

        if (PROCEDURAL_CODE && ex.textures.w != NO_TEXTURE) {
            // A procedural material as code: its graph at this point (its channels as its textures would hold them).
            ProcSample ps = proceduralMaterial(ex.textures.w, uv, s.procParams);
            if ((ps.has & 1u) != 0u) sf.albedo *= procLinear(saturate(ps.base.rgb));
            if ((ps.has & 2u) != 0u) {
                sf.roughness *= saturate(ps.orm.g);
                sf.metallic *= saturate(ps.orm.b);
                if (ex.surface.w > 0.0f) sf.albedo *= mix(1.0f, saturate(ps.orm.r), ex.surface.w);
            }
            if ((ps.has & 8u) != 0u) sf.emission *= procLinear(saturate(ps.emissive.rgb));
            if ((ps.has & 4u) != 0u && uvArea > 0.0f) {
                float invDet = 1.0f / (d1.x * d2.y - d1.y * d2.x);
                float3 T = (e1 * d2.y - e2 * d1.y) * invDet, B = (e2 * d1.x - e1 * d2.x) * invDet;
                float3 N = sf.normal;
                T = T - N * dot(N, T);
                B = B - N * dot(N, B) - T * (dot(T, B) / max(dot(T, T), 1e-12f));
                if (dot(T, T) > 1e-12f && dot(B, B) > 1e-12f) {
                    float3 m = saturate(ps.normal.xyz) * 2.0f - 1.0f;
                    m.xy *= mat.params.y;
                    sf.normal = normalize(normalize(T) * m.x + normalize(B) * m.y + N * max(m.z, 1e-3f));
                }
            }
        }
        if (mat.textures.x != NO_TEXTURE) sf.albedo *= sampleMaterial(s, mat.textures.x, uv, lodBase, record).rgb;
        if (leafLook) {
            // Each leaf a little lighter or darker, greener or yellower than the next.
            uint h = pcgHash(leafId ^ 0x5bd1e995u);
            float a = float(h & 0xFFu) / 255.0f, b = float((h >> 8) & 0xFFu) / 255.0f;
            sf.albedo *= (0.86f + 0.28f * a) * float3(1.0f + 0.14f * (b - 0.5f), 1.0f, 1.0f - 0.3f * (b - 0.5f));
            // And each plant its own, on top: a crown a little lighter or darker, yellower or bluer than its neighbours'.
            uint ph = pcgHash(id ^ 0x68bc21ebu);
            float pa = float(ph & 0xFFu) / 255.0f, pb = float((ph >> 8) & 0xFFu) / 255.0f;
            sf.albedo *= (0.9f + 0.2f * pa) * float3(1.0f + 0.1f * (pb - 0.5f), 1.0f, 1.0f - 0.24f * (pb - 0.5f));
            // A shaded twig's leaves duller and yellower than a lit one's (Unreal's health mask).
            sf.albedo *= mix(float3(0.9f, 0.85f, 0.6f), float3(1.0f), leafHealth);
            // One leaf in seven turning olive-brown, some more than others (Unreal's health colour overlay).
            float c = float((h >> 16) & 0xFFu) / 255.0f, d = float((h >> 24) & 0xFFu) / 255.0f;
            if (c < LEAF_BROWN_SHARE) sf.albedo *= mix(float3(1.0f), float3(1.08f, 0.8f, 0.42f), 0.45f + 0.55f * d);
            // Its underside (the side its normal turns from) greyer, as a leaf's is.
            if (dot(r.direction, sf.normal) > 0.0f) sf.albedo = mix(sf.albedo, float3(dot(sf.albedo, float3(0.3f, 0.59f, 0.11f))), 0.2f);
        }
        if (plantWood && woodGeneration >= TWIG_WOOD - 0.5f) {
            // A twig's wood (Growth.twig): young, yellow-green stems, as the Mega Plants tree's in Unreal.
            sf.albedo *= TWIG_WOOD_TINT;
        } else if (plantWood) {
            // Bark by generation: the younger wood of the branches a little paler and greener than the trunk's...
            sf.albedo *= mix(float3(1.0f), float3(1.12f, 1.1f, 0.96f), saturate(woodGeneration / 3.0f));
            if (woodGeneration < 0.5f) {
                // ...and moss on the trunk where it faces the sky, more of it low down.
                float up = smoothstep(0.3f, 0.85f, sf.normal.y) * saturate(1.0f - objPos.y / 6.0f);
                uint mh = pcgHash(uint(floor(objPos.y * 3.0f)) ^ (id * 0x2545F491u));
                float patchy = 0.6f + 0.4f * float(mh & 0xFFu) / 255.0f;
                sf.albedo = mix(sf.albedo, float3(0.075f, 0.11f, 0.035f), up * 0.7f * patchy);
            }
        }
        // (A scan's GI hit, a leaf's or bark's: its colour alone; its maps are for what the camera sees.)
        bool coarse = MATERIAL_EXTRAS && ex.textures.z == 2u && spread >= 0.02f;   // (2: a scan's, Scene.addScanMaterial)
        if (coarse) sf.roughness *= 0.85f;
        if (mat.textures.y != NO_TEXTURE && !coarse) {
            float4 mr = sampleMaterial(s, mat.textures.y, uv, lodBase, record);
            sf.roughness *= mr.g;
            sf.metallic *= mr.b;
            // Its R as ambient occlusion (a procedural material's ORM), darkening the base colour.
            if (MATERIAL_EXTRAS && ex.surface.w > 0.0f) sf.albedo *= mix(1.0f, mr.r, ex.surface.w);
        }
        if (mat.textures.w != NO_TEXTURE) sf.emission *= sampleMaterial(s, mat.textures.w, uv, lodBase, record).rgb;
        if (mat.textures.z != NO_TEXTURE && uvArea > 0.0f && !coarse) {
            // Tangent frame from the triangle's UV derivatives (no stored tangents), Gram-Schmidt against the
            // shading normal; normal maps are tangent space, +Y = +V.
            float invDet = 1.0f / (d1.x * d2.y - d1.y * d2.x);
            float3 T = (e1 * d2.y - e2 * d1.y) * invDet, B = (e2 * d1.x - e1 * d2.x) * invDet;
            float3 N = sf.normal;
            T = T - N * dot(N, T);
            B = B - N * dot(N, B) - T * (dot(T, B) / max(dot(T, T), 1e-12f));
            if (dot(T, T) > 1e-12f && dot(B, B) > 1e-12f) {
                float3 m = sampleMaterial(s, mat.textures.z, uv, lodBase, record).xyz * 2.0f - 1.0f;
                m.xy *= mat.params.y;
                sf.normal = normalize(normalize(T) * m.x + normalize(B) * m.y + N * max(m.z, 1e-3f));
            }
        }
    }
    if (MATERIAL_LOBES) {
        sf.sheen = ex.sheen;
        sf.anisotropy = ex.anisotropy.x;
        if (sf.anisotropy > 0.0f) {
            // Along the UVs' U (no stored tangents; a mesh without UVs: round its height), turned about the normal.
            float3 N = sf.normal;
            float2 d1 = t1 - t0, d2 = t2 - t0;
            float det = d1.x * d2.y - d1.y * d2.x;
            float3 T = abs(det) > 1e-12f ? (inst.transform * float4((p1 - p0) * d2.y - (p2 - p0) * d1.y, 0.0f)).xyz / det : cross(float3(0.0f, 1.0f, 0.0f), N);
            T -= N * dot(N, T);
            if (length_squared(T) < 1e-12f) T = cross(float3(1.0f, 0.0f, 0.0f), N);
            T = normalize(T);
            sf.lobeTangent = T * cos(ex.anisotropy.y) + cross(N, T) * sin(ex.anisotropy.y);
        }
    }
    if (MATERIAL_EXTRAS && ex.textures.z == GRID_KIND) {
        float3 dir = normalize(r.direction);
        previewGrid(sf, ex, dir, res.distance * length(r.direction) * spread);
    }
    if (DEFORMING_MESHES && hv.prevOffset != 0 && s.damage != nullptr) carDamage(sf, hv, w0, bc, s, t0 * w0 + t1 * bc.x + t2 * bc.y);
    if (TERRAIN && hv.terrain != 0u) {
        float cosTheta = max(abs(dot(normalize(r.direction), sf.geomNormal)), 0.2f);
        float footprint = res.distance * length(r.direction) * spread / cosTheta;
        if (s.procParams[hv.terrain - 1u].w > 15.5f) terrainRealistic(sf, hv, w0, bc, s, footprint, record, r.direction);
        else terrainLayers(sf, hv, w0, bc, s, footprint, record);
    }
    surfaceSpecular(sf);
    return sf;
}

Surface traceSurface(Ray r, uint mask, SCENE_ACCEL accel, thread const SceneData& s, float spread, bool record = false) {
    return surfaceFromHit(intersectClosest(r, mask, accel), r, accel, s, spread, record);
}
