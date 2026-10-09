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
    device const VSMScene*     vsm;             // SceneShading.vsm (with FLAG_VSM)
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
    s.vsm = shading.vsm;
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
    float3 f0;            // specular reflectance at normal incidence (0 for diffuse-only materials)
    uint   instanceId;
    bool   lightEmitter;  // its emission is sampled as an emissive-mesh light (Material.params.z)
    bool   backlit;       // a translucent leaf showing the light of its far side: orientNormals faces it away
    bool   hair;          // a strand (HAIR_CURVES) whose material is hair (Material.params.z < 0): Hair.metal lights it
    float3 tangent;       // a strand's direction there
    float  hairH;         // where across the strand the ray met it, -1...1 (Hair.metal's h)
    float  skin;          // skin (Material.params.w < 0): its strength, 0...1, + 2 where it is thin (ears): Hair.metal
};

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
inline float specularF90(float3 f0) { return any(f0 > 0.0f) ? 1.0f : 0.0f; }   // glTF materials 1, generated ones 0

// Albedo a secondary hit (GI rays, path bounces, reflection hits) reflects with: diffuse plus, as a diffuse
// approximation, the specular albedo at normal incidence, so metals don't turn black in indirect light.
inline float3 hitAlbedo(thread const struct Surface& sf) {
    return sf.albedo + (sf.specular > 0.0f ? specularAlbedo(sf.f0, sf.specular, max(sf.roughness, MIN_ROUGHNESS), 1.0f) : float3(0.0f));
}

// GGX visible-normal sampling (Heitz 2018), in the frame where the normal is +z.
inline float3 sampleGGXVNDF(float3 ve, float a, float2 u) {
    float3 vh = normalize(float3(a * ve.x, a * ve.y, ve.z));
    float lensq = vh.x * vh.x + vh.y * vh.y;
    float3 t1 = lensq > 0.0f ? float3(-vh.y, vh.x, 0.0f) * rsqrt(lensq) : float3(1.0f, 0.0f, 0.0f);
    float3 t2 = cross(vh, t1);
    float r = sqrt(u.x), phi = 2.0f * M_PI_F * u.y;
    float p1 = r * cos(phi), p2 = r * sin(phi);
    float sv = 0.5f * (1.0f + vh.z);
    p2 = (1.0f - sv) * sqrt(max(0.0f, 1.0f - p1 * p1)) + sv * p2;
    float3 nh = p1 * t1 + p2 * t2 + sqrt(max(0.0f, 1.0f - p1 * p1 - p2 * p2)) * vh;
    return normalize(float3(a * nh.x, a * nh.y, max(0.0f, nh.z)));
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
    v.leaf = v.sways = false;
    uint meshIndex = inst.meshIndex;
    if (res.cluster != HIT_NO_CLUSTER) {
        // Virtual geometry: the hit cluster's vertices, in the streaming pool.
        VGClusterView view = vgClusterView(accel.pool + accel.clusters[res.cluster].y);
        uint packed = view.tris[res.primitive];
        uint3 i = uint3(packed & 0xFFu, (packed >> 8) & 0xFFu, (packed >> 16) & 0xFFu);
        for (uint k = 0; k < 3; ++k) {
            float4 q = view.positions[i[k]];
            v.p[k] = q.xyz;
            v.n[k] = octDecode(as_type<uint>(q.w));
            v.t[k] = float2(as_type<half2>(view.uvs[i[k]]));
        }
        return v;
    }
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
            v.p[k] = mesh.block[i];
            v.n[k] = normals[i];
            v.t[k] = uvs[i];
        }
        if (MULTI_MATERIAL) v.material = ((device const uchar*)(indices + mesh.indexCount))[res.primitive];
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

// A hit's material, as it is before its textures.
inline void surfaceMaterial(thread Surface& sf, Material mat) {
    sf.albedo = mat.albedo.rgb;
    sf.emission = mat.emission.rgb;
    sf.metallic = mat.albedo.a;
    sf.roughness = mat.emission.a;
    sf.specular = mat.params.x;
    sf.lightEmitter = mat.params.z > 0.0f;
    sf.skin = max(-mat.params.w, 0.0f);
}

// Metallic-roughness, once the textures are in: metals reflect their base colour, dielectrics 4% (x weight).
inline void surfaceSpecular(thread Surface& sf) {
    if (sf.specular > 0.0f) {
        sf.f0 = mix(float3(0.04f * sf.specular), sf.albedo, sf.metallic);
        sf.albedo *= 1.0f - sf.metallic;
    }
}

// The surface a ray met: the hit's triangle (or voxel) rebuilt in world space, with its material and textures. The
// hit comes from the tracer (traceSurface) or from the raster visibility buffer (visibilityHit, Raster.metal).
Surface surfaceFromHit(Hit res, Ray r, SCENE_ACCEL accel, thread const SceneData& s, float spread, bool record) {
    Surface sf;
    sf.hit = false;
    sf.position = sf.prevPosition = sf.normal = sf.geomNormal = sf.albedo = sf.emission = float3(0.0f);
    sf.metallic = sf.specular = 0.0f;
    sf.roughness = 1.0f;
    sf.f0 = float3(0.0f);
    sf.instanceId = 0;
    sf.lightEmitter = false;
    sf.backlit = false;
    sf.hair = false;
    sf.tangent = float3(0.0f);
    sf.hairH = 0.0f;
    sf.skin = 0.0f;
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
    sf.normal = normalize((inst.normalMatrix * float4(objN, 0.0f)).xyz);
    sf.geomNormal = normalize((inst.normalMatrix * float4(objNg, 0.0f)).xyz);
    surfaceMaterial(sf, mat);
    sf.instanceId = surfaceInstance(id);
    if (mat.params.w > 0.0f) {
        // Translucent (a leaf): the material's share of the leaves shows the light of the far side, the rest that of
        // the near side. Leaf by leaf (two triangles are one), always the same ones: nothing flickers, and a crown
        // as a whole reflects and transmits in the material's proportion.
        uint leafId = (res.primitive >> 1) ^ (res.part * 0x9E3779B9u) ^ (id * 0x85EBCA6Bu);
        sf.backlit = float(pcgHash(leafId) & 0xFFFFu) * (1.0f / 65536.0f) < mat.params.w;
        if (sf.backlit) sf.albedo *= LEAF_TRANSMIT_TINT;
    }

    if (any(mat.textures != uint4(NO_TEXTURE))) {
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

        if (mat.textures.x != NO_TEXTURE) sf.albedo *= sampleMaterial(s, mat.textures.x, uv, lodBase, record).rgb;
        if (mat.textures.y != NO_TEXTURE) {
            float4 mr = sampleMaterial(s, mat.textures.y, uv, lodBase, record);
            sf.roughness *= mr.g;
            sf.metallic *= mr.b;
        }
        if (mat.textures.w != NO_TEXTURE) sf.emission *= sampleMaterial(s, mat.textures.w, uv, lodBase, record).rgb;
        if (mat.textures.z != NO_TEXTURE && uvArea > 0.0f) {
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
    surfaceSpecular(sf);
    return sf;
}

Surface traceSurface(Ray r, uint mask, SCENE_ACCEL accel, thread const SceneData& s, float spread, bool record = false) {
    return surfaceFromHit(intersectClosest(r, mask, accel), r, accel, s, spread, record);
}
