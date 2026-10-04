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
    device const Light*        lights;
    uint                       lightCount;
    uint4                      lightTable;      // Uniforms.lightTable, for the samplers that draw from the table
    device const RegirReservoir* regirGrid;     // the light grid (ReGIR), in kernels that bind it (regir != nullptr)
    constant RegirParams*      regir = nullptr;
    texture2d_array<float>     sky;
    texture2d<float>           cloudShadow;
    constant SkyParams*        skyParams;
};

inline void bindShading(thread SceneData& s, constant SceneShading& shading) {
    s.materials = shading.materials;
    s.uvs = shading.uvs;
    s.textures = shading.textures;
    s.minLod = shading.minLod;
    s.feedback = shading.feedback;
    s.emissive = shading.emissive;
    s.sky = shading.sky;
    s.cloudShadow = shading.cloudShadow;
    s.skyParams = &shading.skyParams;
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
};

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
}

// Pixel-footprint spreads for texture filtering (ray cones without curvature): radians of spread per unit distance.
// Primary rays pass their pixel's angle; GI rays a coarse fixed spread, since their hits get integrated anyway.
constant float GI_RAY_SPREAD = 0.05f;

// The hit triangle's vertices (object space): from a cluster in the streaming pool, a virtual instance's BLAS over
// its cut, or the indexed mesh buffers.
struct HitVertices {
    float3 p[3];
    float3 n[3];
    float2 t[3];
    uint3 i;          // with prevOffset: the vertices' places in the position buffer
    uint prevOffset;  // MeshData.prevOffset (0 = the previous frame's object-space positions are these ones)
};
inline HitVertices fetchHitVertices(Hit res, InstanceData inst, SCENE_ACCEL accel, thread const SceneData& s) {
    HitVertices v;
    v.i = uint3(0u);
    v.prevOffset = 0;
#if CUSTOM_RT
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
        float4 v0 = e.tris[3 * res.primitive], e1 = e.tris[3 * res.primitive + 1], e2 = e.tris[3 * res.primitive + 2];
        v.p[0] = v0.xyz; v.p[1] = v0.xyz + e1.xyz; v.p[2] = v0.xyz + e2.xyz;
        device const uint* a = e.attrs + 6 * res.primitive;
        for (uint k = 0; k < 3; ++k) {
            v.n[k] = octDecode(a[k]);
            v.t[k] = float2(as_type<half2>(a[3 + k]));
        }
        return v;
    }
#endif
    MeshData mesh = s.meshes[inst.meshIndex];
    uint base = mesh.firstIndex + res.primitive * 3;
    for (uint k = 0; k < 3; ++k) {
        uint i = s.indices[base + k];
        uint own = DEFORMING_MESHES ? i + mesh.vertexOffset : i;   // a pose slot's own vertex
        v.i[k] = own;
        v.p[k] = s.positions[own];
        v.n[k] = s.normals[own];
        v.t[k] = s.uvs[i];
    }
    if (DEFORMING_MESHES) v.prevOffset = mesh.prevOffset;
    return v;
}

Surface traceSurface(Ray r, uint mask, SCENE_ACCEL accel, thread const SceneData& s, float spread, bool record = false) {
    Hit res = intersectClosest(r, mask, accel);

    Surface sf;
    sf.hit = false;
    sf.position = sf.prevPosition = sf.normal = sf.geomNormal = sf.albedo = sf.emission = float3(0.0f);
    sf.metallic = sf.specular = 0.0f;
    sf.roughness = 1.0f;
    sf.f0 = float3(0.0f);
    sf.instanceId = 0;
    sf.lightEmitter = false;
    if (!res.hit) return sf;

    InstanceData inst = s.instances[res.instance];
    float2 bc = res.barycentrics;
    float w0 = 1.0f - bc.x - bc.y;
    HitVertices hv = fetchHitVertices(res, inst, accel, s);
    float3 p0 = hv.p[0], p1 = hv.p[1], p2 = hv.p[2], n0 = hv.n[0], n1 = hv.n[1], n2 = hv.n[2];
    float2 t0 = hv.t[0], t1 = hv.t[1], t2 = hv.t[2];
    float3 objPos = p0 * w0 + p1 * bc.x + p2 * bc.y;
    float3 objN   = n0 * w0 + n1 * bc.x + n2 * bc.y;
    float3 objNg  = cross(p1 - p0, p2 - p0);

    Material mat = s.materials[inst.materialIndex];
    sf.hit = true;
    sf.position = (inst.transform * float4(objPos, 1.0f)).xyz;
    // A deforming mesh (a crowd's pose slot): where the point was in the previous frame's pose.
    float3 prevObjPos = objPos;
    if (DEFORMING_MESHES && hv.prevOffset != 0) {
        prevObjPos = s.positions[hv.i[0] + hv.prevOffset] * w0 + s.positions[hv.i[1] + hv.prevOffset] * bc.x
                   + s.positions[hv.i[2] + hv.prevOffset] * bc.y;
    }
    sf.prevPosition = (inst.prevTransform * float4(prevObjPos, 1.0f)).xyz;
    sf.normal = normalize((inst.normalMatrix * float4(objN, 0.0f)).xyz);
    sf.geomNormal = normalize((inst.normalMatrix * float4(objNg, 0.0f)).xyz);
    sf.albedo = mat.albedo.rgb;
    sf.emission = mat.emission.rgb;
    sf.metallic = mat.albedo.a;
    sf.roughness = mat.emission.a;
    sf.specular = mat.params.x;
    sf.instanceId = res.instance;
    sf.lightEmitter = mat.params.z > 0.0f;

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
    if (sf.specular > 0.0f) {   // metallic-roughness: metals reflect their base colour, dielectrics 4% (x weight)
        sf.f0 = mix(float3(0.04f * sf.specular), sf.albedo, sf.metallic);
        sf.albedo *= 1.0f - sf.metallic;
    }
    return sf;
}
