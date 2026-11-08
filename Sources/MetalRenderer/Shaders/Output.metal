// ---------------------------------------------------------------------------------------------
// 3c. Geometry debug views (view modes 8-13), a pass of their own that runs only while one is shown: re-traces the
//     primary rays and colours each pixel by what it hit. Virtual triangles carry their cluster, group, DAG level and
//     index within the cluster (VirtualBLAS packs them into the free w components of its triangles' second and third
//     corners; in cluster mode the cluster's pool header holds group and level). Other geometry with levels of detail
//     carries its level in its mesh record (GPUMesh.lod).
// ---------------------------------------------------------------------------------------------

constant uint VIEW_TRIANGLES = 8, VIEW_CLUSTERS = 9, VIEW_GROUPS = 10, VIEW_LOD = 11, VIEW_TRIANGLE_SIZE = 12, VIEW_COST = 13;
// Virtual geometry's own (RenderSettings.vgViews): each cluster's projected error against the cut's rule, the
// instances whose BLAS was just rebuilt, and holes in closed meshes.
constant uint VIEW_LOD_ERROR = 16, VIEW_REBUILT = 17, VIEW_CRACKS = 18;

// What the virtual-geometry views measure against (GPUVGDebug): the viewpoint the cut was chosen for (Freeze LOD's,
// if on), its pixel scale and allowed error, this frame, and the pixel the probe reads.
struct VGDebugArgs {
    float4 camPos;      // xyz; w = pixel scale (traced height / (2 tan(fovY / 2)))
    float  tau;
    uint   frame;
    uint2  probe;
};

// What the probe pixel hit (GPUVGProbe): instance (~0: nothing virtual), cluster, group, level; own and parent
// projected error in pixels, the distance, whether the hit was a back face.
struct VGProbe {
    uint4  ids;
    float4 errors;      // x own, y parent (inf: a root), z distance, w back face (1) or front (0)
};

// A cluster's error projected from `camPos` as the cut (VirtualBLAS.selection) projects it: error x scale x pixel
// scale / distance to the sphere. inf where the camera is inside the sphere and the error isn't 0.
inline float vgProjected(float4 sphere, float error, float4x4 m, float scale, VGDebugArgs a) {
    float3 c = (m * float4(sphere.xyz, 1.0f)).xyz;
    float d = length(c - a.camPos.xyz) - sphere.w * scale;
    if (error == 0.0f) return 0.0f;
    if (isinf(error)) return INFINITY;
    return d > 1e-4f ? error * scale * a.camPos.w / d : INFINITY;
}

inline float3 debugHashColor(uint h) {
    h = pcgHash(h);
    return 0.15f + 0.85f * float3(h & 0xFFu, (h >> 8) & 0xFFu, (h >> 16) & 0xFFu) / 255.0f;
}

// Turbo colour map (polynomial fit, Mikhailov 2019): 0 = dark blue, 0.5 = green, 1 = dark red.
inline float3 debugHeat(float x) {
    x = saturate(x);
    const float4 r4 = float4(0.13572138f, 4.61539260f, -42.66032258f, 132.13108234f);
    const float4 g4 = float4(0.09140261f, 2.19418839f, 4.84296658f, -14.18503333f);
    const float4 b4 = float4(0.10667330f, 12.64194608f, -60.58204836f, 110.36276771f);
    const float2 r2 = float2(-152.94239396f, 59.28637943f);
    const float2 g2 = float2(4.27729857f, 2.82956604f);
    const float2 b2 = float2(-89.90310912f, 27.34824973f);
    float4 v4 = float4(1.0f, x, x * x, x * x * x);
    float2 v2 = v4.zw * v4.z;
    return saturate(float3(dot(v4, r4) + dot(v2, r2), dot(v4, g4) + dot(v2, g2), dot(v4, b4) + dot(v2, b2)));
}

kernel void geometryDebugKernel(constant Uniforms&               u          [[buffer(0)]],
                                SCENE_ACCEL                      accel      [[buffer(1)]],
                                device const float3*             positions  [[buffer(2)]],
                                device const float3*             normals    [[buffer(3)]],
                                device const uint*               indices    [[buffer(4)]],
                                device const MeshData*           meshes     [[buffer(5)]],
                                device const InstanceData*       instances  [[buffer(6)]],
                                constant SceneShading&           shading    [[buffer(7)]],
                                constant VGDebugArgs&            vgd        [[buffer(8)]],
                                device VGProbe*                  probe      [[buffer(9)]],
                                texture2d<float, access::write>  output     [[texture(0)]],
                                uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, nullptr, 0u);   // no lights
    bool probing = all(tid == vgd.probe);
    if (probing) probe[0] = VGProbe{uint4(~0u, 0u, 0u, 0u), float4(0.0f)};

    float3 dir = primaryDirection(u, tid);
    Ray r = makeRay(u.camPos.xyz, dir, 0.0f, INFINITY);
    Hit res;
    if (u.viewMode == VIEW_COST) {
        // The ray's candidates (intersectClosestCost: what Metal's traversal handed over), log scale up to ~250.
        uint candidates;
        res = intersectClosestCost(r, MASK_ALL, accel, candidates);
        output.write(float4(debugHeat(log2(1.0f + float(candidates)) / 8.0f), 1.0f), tid);
        return;
    }
    res = intersectClosest(r, MASK_ALL, accel);
    if (!res.hit) { output.write(float4(0.0f, 0.0f, 0.0f, 1.0f), tid); return; }
    if (VOXELS && res.part == HIT_VOXEL) {
        // A far plant's voxels have no triangles to show: flat, in the plant's colour. The LOD view shows the level
        // its rays march (green, orange, red: each twice as coarse; rtVoxels leaves it in barycentrics.x).
        float3 flat = mix(float3(0.2f), debugHashColor(pcgHash(res.instance + 0x51ED27u)), 0.5f);
        if (u.viewMode == VIEW_LOD) flat = debugHeat(0.2f + 0.25f * (res.barycentrics.x + 1.0f));
        output.write(float4(flat, 1.0f), tid);
        return;
    }
    if (SDF_SHAPES && res.part == HIT_SDF) {
        // An SDF shape has no triangles either: shaded by its normal, its materials told apart in the triangles view.
        InstanceData inst = instanceRecord(s.instances, res.instance);
        float3 n = normalize((inst.normalMatrix * float4(sdfOctDecode(res.barycentrics), 0.0f)).xyz);
        float shade = 0.35f + 0.65f * abs(dot(n, dir));
        float3 c = u.viewMode == VIEW_TRIANGLES ? debugHashColor(res.primitive + pcgHash(res.instance + 0x51ED27u)) : float3(0.45f);
        output.write(float4(c * shade, 1.0f), tid);
        return;
    }

    InstanceData inst = instanceRecord(s.instances, res.instance);
    HitVertices hv = fetchHitVertices(res, inst, accel, s);
    float3 e1 = (inst.transform * float4(hv.p[1] - hv.p[0], 0.0f)).xyz, e2 = (inst.transform * float4(hv.p[2] - hv.p[0], 0.0f)).xyz;
    float3 ng = cross(e1, e2);
    float doubleArea = length(ng);
    float shade = doubleArea > 0.0f ? 0.35f + 0.65f * abs(dot(ng / doubleArea, dir)) : 0.35f;

    bool isVirtual = false;
    uint cluster = 0, local = 0, group = 0, level = 0;
    VGBlas e = {};
    if (inst.pad1 != 0) {
        e = accel.vgBlas[inst.pad1 - 1];
        uint a = as_type<uint>(e.tris[3 * res.primitive + 1].w), b = as_type<uint>(e.tris[3 * res.primitive + 2].w);
        isVirtual = true;
        cluster = a & 0xFFFFFFu;        // cluster | triangle within it << 24
        local = a >> 24;
        group = b & 0xFFFFFFu;          // group | level << 24
        level = b >> 24;
    }
    bool backFace = doubleArea > 0.0f && dot(ng, dir) > 0.0f;   // CCW front faces: their normal faces the ray's origin
    // The cluster's own and its group's (parents') error on screen, as the cut sees them.
    float ownPx = 0.0f, parentPx = INFINITY;
    if (isVirtual && e.clusterInfo != nullptr && (u.viewMode == VIEW_LOD_ERROR || probing)) {
        VGClusterInfo ci = e.clusterInfo[cluster];
        float4x4 m = inst.transform;
        float scale = max(length(m[0].xyz), max(length(m[1].xyz), length(m[2].xyz)));
        ownPx = vgProjected(ci.selfSphere, ci.selfError, m, scale, vgd);
        parentPx = vgProjected(ci.parentSphere, ci.parentError, m, scale, vgd);
    }
    if (probing && isVirtual) {
        probe[0] = VGProbe{uint4(res.instance, cluster, group, level), float4(ownPx, parentPx, res.distance, backFace ? 1.0f : 0.0f)};
    }
    if (u.viewMode == VIEW_CRACKS && isVirtual && (e.flags & VG_FLAG_WATERTIGHT) != 0u && backFace) {
        output.write(float4(1.0f, 0.0f, 1.0f, 1.0f), tid);   // exact magenta, unshaded: what the lab's eval counts
        return;
    }
    // The level of detail, 0 = finest: a virtual triangle's DAG level, else its mesh's (GPUMesh.lod: an open-world
    // tile's ring, a crowd character's detail, a baked plant). A plant's parts are its finest.
    const float3 grey = float3(0.45f);  // geometry without levels; in the cluster and group views, what isn't virtual
    float3 lodColor = grey;
    if (isVirtual) lodColor = debugHeat(0.05f + float(level) / 10.0f);
    else if (ASSEMBLIES && res.part != HIT_NO_PART) lodColor = debugHeat(0.05f);
    else if (s.meshes[inst.meshIndex].lod != 0) lodColor = debugHeat(0.05f + 0.3f * float(s.meshes[inst.meshIndex].lod - 1));

    uint instanceSeed = pcgHash(res.instance + 0x51ED27u);
    float3 c = grey;
    switch (u.viewMode) {
        case VIEW_TRIANGLES:
            c = debugHashColor(isVirtual ? local + pcgHash(cluster + instanceSeed) : res.primitive + instanceSeed);
            break;
        // Geometry that isn't virtual has no clusters or groups: its level, faded.
        case VIEW_CLUSTERS: c = isVirtual ? debugHashColor(cluster + instanceSeed) : mix(grey, lodColor, 0.5f); break;
        case VIEW_GROUPS:   c = isVirtual ? debugHashColor(group * 0x9E3779B9u + instanceSeed) : mix(grey, lodColor, 0.5f); break;
        case VIEW_LOD:      c = lodColor; break;
        case VIEW_TRIANGLE_SIZE: {
            // Edge length (of a right triangle with the same area) in traced pixels: 1/8 px blue, 1 px green, 8 px red.
            float footprint = res.distance * 2.0f * u.camUp.w / float(u.height);
            float px = sqrt(doubleArea) / max(footprint, 1e-8f);
            c = debugHeat((log2(max(px, 1e-4f)) + 3.0f) / 6.0f);
            break;
        }
        case VIEW_LOD_ERROR:
            // Green at the allowed error, blue finer; red where a cluster is coarser than allowed, magenta where its
            // group's error is already fine enough (the cut should have taken the coarser clusters). Only a cut
            // chosen for another viewpoint shows either: the wait rule's, a background cut not yet in.
            if (!isVirtual) { c = grey; break; }
            if (ownPx > 1.05f * vgd.tau) c = float3(1.0f, 0.0f, 0.0f);
            else if (parentPx <= 0.95f * vgd.tau) c = float3(1.0f, 0.0f, 1.0f);
            else c = debugHeat(0.5f * ownPx / max(vgd.tau, 1e-6f));
            break;
        case VIEW_REBUILT: {
            // White as an instance's BLAS is swapped in, fading over 60 frames to its clusters' colours.
            if (!isVirtual) { c = grey; break; }
            float age = float(vgd.frame - e.rebuiltFrame);
            c = mix(0.6f * debugHashColor(cluster + instanceSeed), float3(1.0f), saturate(1.0f - age / 60.0f));
            break;
        }
        case VIEW_CRACKS:   // a front face, or a mesh that isn't closed: the triangles, dimmed
            c = 0.5f * debugHashColor(isVirtual ? local + pcgHash(cluster + instanceSeed) : res.primitive + instanceSeed);
            break;
        default: break;
    }
    output.write(float4(c * shade, 1.0f), tid);
}

// ---------------------------------------------------------------------------------------------
// Solid shading (RenderSettings.solid), Blender's viewport look: the whole frame. One camera ray a pixel; what it hits
// is grey under a studio light fixed to the camera (a key from the upper left, a weak fill from the right, a sky-to-
// ground ambient), with the smooth normal. No lights, materials, textures or shadows. The miss is a grey gradient.
// Linear light into the drawable (sRGB).
// ---------------------------------------------------------------------------------------------

inline float3 solidShade(float3 n, float3 dir, constant Uniforms& u) {
    if (dot(n, dir) > 0.0f) n = -n;   // the side the camera sees
    float3 right = u.camRight.xyz, up = u.camUp.xyz, back = -u.camForward.xyz;
    float3 key = normalize(-0.5f * right + 0.7f * up + 0.6f * back);
    float3 fill = normalize(0.8f * right - 0.2f * up + 0.5f * back);
    float ambient = mix(0.06f, 0.16f, n.y * 0.5f + 0.5f);
    float light = ambient + 0.80f * max(dot(n, key), 0.0f) + 0.15f * max(dot(n, fill), 0.0f);
    return float3(0.6f * light);
}

kernel void solidKernel(constant Uniforms&               u          [[buffer(0)]],
                        SCENE_ACCEL                      accel      [[buffer(1)]],
                        device const float3*             positions  [[buffer(2)]],
                        device const float3*             normals    [[buffer(3)]],
                        device const uint*               indices    [[buffer(4)]],
                        device const MeshData*           meshes     [[buffer(5)]],
                        device const InstanceData*       instances  [[buffer(6)]],
                        constant SceneShading&           shading    [[buffer(7)]],
                        texture2d<float, access::write>  output     [[texture(0)]],
                        uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float3 dir = primaryDirection(u, tid);
    // Everything but window glass (rooms show through their windows) and the lights' shapes and camera-only motes.
    Hit res = intersectClosest(makeRay(u.camPos.xyz, dir, 0.0f, INFINITY), MASK_ALL & ~(MASK_GLASS | MASK_LIGHTS), accel);
    if (!res.hit) {
        float v = float(tid.y) / float(u.height);
        output.write(float4(float3(mix(0.050f, 0.018f, v)), 1.0f), tid);
        return;
    }
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, nullptr, 0u);   // no lights
    InstanceData inst = instanceRecord(s.instances, res.instance);
    float3 n;
    if (VOXELS && res.part == HIT_VOXEL) {
        n = -dir;   // a far plant's voxel: lit as if facing the camera
    } else if (SDF_SHAPES && res.part == HIT_SDF) {
        n = (inst.normalMatrix * float4(sdfOctDecode(res.barycentrics), 0.0f)).xyz;
    } else if (HAIR_CURVES && res.part == HIT_CURVE) {
        n = -dir;   // a strand
    } else {
        HitVertices hv = fetchHitVertices(res, inst, accel, s);
        float2 bc = res.barycentrics;
        float3 objN = hv.n[0] * (1.0f - bc.x - bc.y) + hv.n[1] * bc.x + hv.n[2] * bc.y;
        if (length_squared(objN) < 1e-12f) objN = cross(hv.p[1] - hv.p[0], hv.p[2] - hv.p[0]);
        n = (inst.normalMatrix * float4(objN, 0.0f)).xyz;
    }
    n = length_squared(n) > 1e-20f ? normalize(n) : -dir;
    output.write(float4(solidShade(n, dir, u), 1.0f), tid);
}

// ---------------------------------------------------------------------------------------------
// The solid look that tells things apart (RenderSettings.solidLook, Renderer's encodeOutput): each surface its
// material's colour (a fractured object's broken faces darker and warmer, each object a shade of its own), lit by the
// scene's sun with its shadow and a sky's light dimmed in corners (ambient occlusion), outlined where objects meet or
// a surface turns. Two passes over the output's pixels: solidTraceKernel's rays (one camera ray, past one pane of
// glass, a shadow ray, a few short AO rays) into three targets, then solidResolveKernel: the AO filtered over 4 x 4
// pixels (its rays turn with the pixel in a 4 x 4 pattern: 16 x as many directions over the block, no noise from
// frame to frame), the outlines, the light. Linear light into the drawable (sRGB).
// ---------------------------------------------------------------------------------------------

struct SolidParams {
    float4 sun;      // xyz: toward the sun when the scene has none; w: shadows (1 / 0)
    float4 look;     // x: each object's tint, y: broken faces (1 / 0), z: AO's reach (m), w: AO rays (0: none)
    float4 edges;    // x: outlines (1 / 0), y: their width (pixels), z: material colours (1 / 0)
    uint4 info;      // x: how many materials `flags` has
};

constant uint SOLID_CUT_FACE = 1;   // Scene.cutFace
constant uint MASK_EFFECT = 64;     // Scene.maskEffect: a fireball's glow

// Object `instance`'s shade: lighter or darker by up to `amount`, a little warmer or cooler.
inline float3 solidTint(uint instance, float amount) {
    uint h = pcgHash(instance * 0x9E3779B9u + 0x51ED27u);
    float a = float(h & 0xFFFFu) / 65535.0f * 2.0f - 1.0f, b = float(h >> 16) / 65535.0f * 2.0f - 1.0f;
    return float3(1.0f + amount * a) * float3(1.0f + 0.4f * amount * b, 1.0f, 1.0f - 0.4f * amount * b);
}

inline float3 solidSky(float v) { return mix(float3(0.62f, 0.68f, 0.74f), float3(0.30f, 0.36f, 0.44f), v); }

kernel void solidTraceKernel(constant Uniforms&               u          [[buffer(0)]],
                             SCENE_ACCEL                      accel      [[buffer(1)]],
                             device const float3*             positions  [[buffer(2)]],
                             device const float3*             normals    [[buffer(3)]],
                             device const uint*               indices    [[buffer(4)]],
                             device const MeshData*           meshes     [[buffer(5)]],
                             device const InstanceData*       instances  [[buffer(6)]],
                             constant SceneShading&           shading    [[buffer(7)]],
                             device const Light*              lights     [[buffer(8)]],
                             constant SolidParams&            p          [[buffer(9)]],
                             device const uchar*              flags      [[buffer(10)]],
                             texture2d<float, access::write>  colour     [[texture(0)]],
                             texture2d<float, access::write>  geometry   [[texture(1)]],
                             texture2d<uint, access::write>   ids        [[texture(2)]],
                             uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float3 dir = primaryDirection(u, tid);
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, nullptr, 0u);
    Ray r = makeRay(u.camPos.xyz, dir, 0.0f, INFINITY);
    uint mask = MASK_ALL & ~MASK_LIGHTS;
    Hit res = intersectClosest(r, mask, accel);
    // A pane of glass: its tint over what is behind it, and its outline.
    float3 filter = float3(1.0f);
    uint glass = 0u;
    if (res.hit && (instanceRecord(s.instances, res.instance).pad0 & MASK_GLASS) != 0u) {
        InstanceData g = instanceRecord(s.instances, res.instance);
        float3 tint = s.materials[hitMaterialIndex(res, g, accel, s)].albedo.xyz;
        filter = mix(float3(1.0f), tint, 0.6f) * 0.82f;
        glass = res.instance + 1u;
        r.tmin = res.distance + 1e-3f;
        mask &= ~MASK_GLASS;
        res = intersectClosest(r, mask, accel);
    }
    uint id = glass * 0x9E3779B9u;
    if (!res.hit) {
        colour.write(float4(solidSky(float(tid.y) / float(u.height)) * filter, -1.0f), tid);
        geometry.write(float4(0.0f, 0.0f, 1e9f, 1.0f), tid);
        ids.write(uint4(id), tid);
        return;
    }
    InstanceData inst = instanceRecord(s.instances, res.instance);
    id ^= res.instance + 1u;
    float depth = res.distance * dot(dir, u.camForward.xyz);
    Surface sf = surfaceFromHit(res, r, accel, s, 0.0f, false);
    if ((inst.pad0 & MASK_EFFECT) != 0u) {   // a fireball: its glow, unlit
        colour.write(float4(min(sf.albedo + sf.emission * 0.08f, float3(1.0f)) * filter, -1.0f), tid);
        geometry.write(float4(0.0f, 0.0f, depth, 1.0f), tid);
        ids.write(uint4(id), tid);
        return;
    }
    float3 n = sf.normal;
    if (length_squared(n) < 1e-12f) n = -dir;
    n = normalize(n);
    if (dot(n, dir) > 0.0f) n = -n;   // the side the camera sees
    float3 albedo = p.edges.z > 0.0f ? sf.albedo : float3(0.6f);
    uint m = hitMaterialIndex(res, inst, accel, s);
    if (p.look.y > 0.0f && m < p.info.x && (uint(flags[m]) & SOLID_CUT_FACE) != 0u) albedo *= float3(0.78f, 0.66f, 0.52f);
    albedo = max(albedo * solidTint(res.instance, p.look.x), float3(0.03f)) * filter;
    // The sun, and its shadow.
    float3 toSun = u.lightTable.y > 0u ? normalize(lights[u.lightTable.z].axis.xyz) : normalize(p.sun.xyz);
    float3 origin = sf.position + n * max(2e-3f, res.distance * 1e-4f);
    float sun = max(dot(n, toSun), 0.0f);
    if (p.sun.w > 0.0f && sun > 0.0f) {
        float t;
        if (intersectAny(makeRay(origin, toSun, 0.0f, INFINITY), MASK_GEOMETRY, accel, t)) sun = 0.0f;
    }
    // What of the sky the surface sees within the AO's reach (rays about the normal, cosine-weighted).
    float ao = 1.0f;
    uint rays = uint(p.look.w);
    if (rays > 0u) {
        float3 t1 = normalize(abs(n.y) < 0.9f ? cross(n, float3(0, 1, 0)) : cross(n, float3(1, 0, 0))), t2 = cross(n, t1);
        uint cell = (tid.x & 3u) + 4u * (tid.y & 3u), total = 16u * rays;
        float open = 0.0f;
        for (uint k = 0; k < rays; k++) {
            uint i = cell + 16u * k;
            float u1 = (float(i) + 0.5f) / float(total), u2 = fract(float(i) * 0.618034f + 0.31f);
            float rr = sqrt(u1), phi = 6.2831853f * u2;
            float3 d = normalize(t1 * (rr * cos(phi)) + t2 * (rr * sin(phi)) + n * sqrt(max(1.0f - u1, 0.0f)));
            float t;
            if (!intersectAny(makeRay(origin, d, 0.0f, p.look.z), MASK_GEOMETRY, accel, t)) open += 1.0f;
            else open += smoothstep(0.0f, p.look.z, t) * 0.6f;   // (far things darken less)
        }
        ao = open / float(rays);
    }
    float2 e = sdfOctEncode(n);
    colour.write(float4(albedo, sun), tid);
    geometry.write(float4(e, depth, ao), tid);
    ids.write(uint4(id), tid);
}

kernel void solidResolveKernel(constant Uniforms&              u        [[buffer(0)]],
                               constant SolidParams&           p        [[buffer(9)]],
                               texture2d<float, access::read>  colour   [[texture(0)]],
                               texture2d<float, access::read>  geometry [[texture(1)]],
                               texture2d<uint, access::read>   ids      [[texture(2)]],
                               texture2d<float, access::write> output   [[texture(3)]],
                               uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float4 c = colour.read(tid);
    if (c.w < 0.0f) { output.write(float4(c.xyz, 1.0f), tid); return; }
    float4 g = geometry.read(tid);
    float3 n = sdfOctDecode(g.xy);
    float z = g.z;
    int2 last = int2(u.width, u.height) - 1;
    // The AO over the 4 x 4 block round it (each of the pattern's cells once), where the surface goes on.
    float ao = g.w;
    if (p.look.w > 0.0f) {
        float sum = 0.0f, weights = 0.0f;
        for (int dy = -1; dy <= 2; dy++) {
            for (int dx = -1; dx <= 2; dx++) {
                uint2 q = uint2(clamp(int2(tid) + int2(dx, dy), int2(0), last));
                float4 gq = geometry.read(q);
                float w = exp(-abs(gq.z - z) / (0.02f * z + 1e-3f)) * pow(max(dot(n, sdfOctDecode(gq.xy)), 0.0f), 8.0f);
                sum += w * gq.w;
                weights += w;
            }
        }
        ao = weights > 1e-4f ? sum / weights : g.w;
    }
    // Outlines: where the object, the surface's turn or its depth changes against a neighbour.
    float edge = 0.0f;
    if (p.edges.x > 0.0f) {
        uint id = ids.read(tid).x;
        int w = max(int(p.edges.y), 1);
        int2 offsets[4] = { int2(w, 0), int2(-w, 0), int2(0, w), int2(0, -w) };
        for (int k = 0; k < 4; k++) {
            uint2 q = uint2(clamp(int2(tid) + offsets[k], int2(0), last));
            float4 gq = geometry.read(q);
            bool other = ids.read(q).x != id;
            bool turn = dot(n, sdfOctDecode(gq.xy)) < 0.8f;
            bool step = abs(gq.z - z) > 0.02f * z + 0.01f;
            if (other || turn || step) edge = 1.0f;
        }
    }
    float sky = mix(0.42f, 0.62f, n.y * 0.5f + 0.5f);
    float fill = 0.12f * max(dot(n, -u.camForward.xyz), 0.0f);
    float3 light = float3(sky * ao) + float3(1.0f, 0.96f, 0.88f) * (0.75f * c.w) + fill;
    float3 col = c.xyz * light * mix(1.0f, 0.4f, edge);
    output.write(float4(col, 1.0f), tid);
}

// ---------------------------------------------------------------------------------------------
// 4. Composite: re-apply albedo, add emission, tonemap and write to the drawable.
// ---------------------------------------------------------------------------------------------

inline float3 acesFilm(float3 x) {
    // Narkowicz 2015 ACES approximation
    return saturate((x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f));
}

// AgX (Troy Sobotka), with the polynomial fit of its default contrast curve by Benjamin Wrensch ("minimal AgX"):
// into the AgX working space, log2 between its EV limits, the curve, back. The curve's output is display-encoded
// (gamma 2.2), and the drawable wants linear, hence the pow at the end.
inline float3 agxFilm(float3 c) {
    const float3x3 toAgx = float3x3(0.842479062253094f, 0.0423282422610123f, 0.0423756549057051f,
                                    0.0784335999999992f, 0.878468636469772f, 0.0784336f,
                                    0.0792237451477643f, 0.0791661274605434f, 0.879142973793104f);
    const float3x3 fromAgx = float3x3(1.19687900512017f, -0.0528968517574562f, -0.0529716355144438f,
                                      -0.0980208811401368f, 1.15190312990417f, -0.0980434501171241f,
                                      -0.0990297440797205f, -0.0989611768448433f, 1.15107367264116f);
    const float minEV = -12.47393f, maxEV = 4.026069f;
    float3 x = (clamp(log2(max(toAgx * c, 1e-10f)), minEV, maxEV) - minEV) / (maxEV - minEV);
    float3 x2 = x * x, x4 = x2 * x2;
    x = 15.5f * x4 * x2 - 40.14f * x4 * x + 31.96f * x4 - 6.868f * x2 * x + 0.4298f * x2 + 0.1191f * x - 0.00232f;
    return pow(saturate(fromAgx * x), float3(2.2f));
}

// The film look (ToneMap.film), Unreal's default image. Written from the Academy's open ACES reference (its AP0 and AP1
// spaces, the RRT's glow, red modifier and desaturation, the blue-light fix) and a filmic curve of Unreal's documented
// parameters, then checked against 5.8's output: over 45 greys the worst is 1.3 of 255 sRGB levels; over 108 colour
// patches the mean is 0.6 and the worst 5.1. `filmExpand` and FILM_MIDDLE were fitted to those captures.
constant float3x3 filmFromLinear = float3x3(float3(0.6130974f, 0.0701937f, 0.0206156f), float3(0.3395231f, 0.9163539f, 0.1095698f), float3(0.0473795f, 0.0134524f, 0.8698146f));
constant float3x3 filmToLinear = float3x3(float3(1.7050510f, -0.1302564f, -0.0240034f), float3(-0.6217920f, 1.1408047f, -0.1289690f), float3(-0.0832590f, -0.0105483f, 1.1529724f));
constant float3x3 filmToAP0 = float3x3(float3(0.6954522f, 0.0447946f, -0.0055259f), float3(0.1406787f, 0.8596711f, 0.0040252f), float3(0.1638691f, 0.0955343f, 1.0015007f));
constant float3x3 filmFromAP0 = float3x3(float3(1.4514393f, -0.0765538f, 0.0083161f), float3(-0.2365107f, 1.1762297f, -0.0060324f), float3(-0.2149286f, -0.0996759f, 0.9977163f));
constant float3x3 filmExpand = float3x3(float3(1.4073000f, -0.0781000f, -0.0254000f), float3(-0.3447000f, 1.0817000f, -0.0870000f), float3(-0.0626000f, -0.0036000f, 1.1124000f));
constant float3x3 filmBlue = float3x3(float3(0.9386394f, 0.0f, 0.0f), float3(0.0f, 0.8307941f, 0.0f), float3(0.0613606f, 0.1692059f, 1.0f));
constant float3x3 filmBlueBack = float3x3(float3(1.0653719f, 0.0f, 0.0f), float3(0.0f, 1.2036676f, 0.0f), float3(-0.0653719f, -0.2036676f, 1.0f));
constant float3 FILM_LUMA = float3(0.2722287f, 0.6740818f, 0.0536895f);
constant float FILM_BLUE_FIX = 0.6f, FILM_SAT_IN = 0.96f, FILM_SAT_OUT = 0.93f;
constant float FILM_MIDDLE = 0.14f;   // the curve's height at middle grey

/// The RRT's glow and red modifier, on AP0.
inline float3 filmGlowAndRed(float3 c) {
    float high = max(c.r, max(c.g, c.b)), low = min(c.r, min(c.g, c.b));
    float sat = (max(high, 1e-10f) - max(low, 1e-10f)) / max(high, 0.01f);
    float chroma = sqrt(max(c.b * (c.b - c.g) + c.g * (c.g - c.r) + c.r * (c.r - c.b), 0.0f));
    float yc = (c.r + c.g + c.b + 1.75f * chroma) / 3.0f;
    float k = 4.0f * sat - 1.0f, shape = max(1.0f - abs(k * 0.5f), 0.0f);
    float gain = 0.05f * (1.0f + (k < 0.0f ? -1.0f : 1.0f) * (1.0f - shape * shape)) * 0.5f;
    float glow = yc <= 0.08f * 2.0f / 3.0f ? gain : yc >= 0.16f ? 0.0f : gain * (0.08f / yc - 0.5f);
    c *= 1.0f + glow;
    // (A neutral colour has no hue, and atan2(0, 0) isn't a number: it takes no red modifier.)
    float hueY = 1.7320508f * (c.g - c.b), hueX = 2.0f * c.r - c.g - c.b;
    float hue = abs(hueX) + abs(hueY) < 1e-9f ? 180.0f : abs(atan2(hueY, hueX)) * 57.29578f;
    float x = hue * 4.0f / 135.0f;
    float weight = x >= 2.0f ? 0.0f : x < 1.0f ? (3.0f * x * x * x - 6.0f * x * x + 4.0f) / 6.0f : (2.0f - x) * (2.0f - x) * (2.0f - x) / 6.0f;
    float newHigh = max(c.r, max(c.g, c.b)), newLow = min(c.r, min(c.g, c.b));
    float newSat = (max(newHigh, 1e-10f) - max(newLow, 1e-10f)) / max(newHigh, 0.01f);
    c.r += weight * newSat * (0.03f - c.r) * 0.18f;
    return c;
}

/// The curve, each channel: a straight middle in log10 of the light, whose toe and shoulder each leave it for their limit
/// (`film`: slope, toe, shoulder, black clip; `white`: white clip), blended where they overlap.
inline float3 filmCurve(float3 c, float4 film, float white) {
    float slope = max(film.x, 1e-3f), black = film.w;
    float toeSpan = max(1.0f + black - film.y, 1e-3f), shoulderSpan = max(1.0f + white - film.z, 1e-3f);
    const float grey = -0.7447275f;   // log10(0.18)
    float toeEnd = grey + (toeSpan - black - FILM_MIDDLE) / slope;
    float shoulderStart = grey + (1.0f + white - shoulderSpan - FILM_MIDDLE) / slope;
    float3 x = log10(max(c, 1e-10f));
    float3 line = slope * (x - grey) + FILM_MIDDLE;
    float3 toe = -black + 2.0f * toeSpan / (1.0f + exp(-2.0f * slope / toeSpan * (x - toeEnd)));
    float3 shoulder = 1.0f + white - 2.0f * shoulderSpan / (1.0f + exp(2.0f * slope / shoulderSpan * (x - shoulderStart)));
    float3 low = select(line, toe, x < toeEnd), high = select(line, shoulder, x > shoulderStart);
    float span = shoulderStart - toeEnd;
    float3 t = select(float3(0.0f), float3(1.0f), x > toeEnd);
    if (abs(span) >= 1e-5f) t = saturate((x - toeEnd) / span);
    if (span < 0.0f) t = 1.0f - t;
    return mix(low, high, t * t * (3.0f - 2.0f * t));
}

inline float3 filmFilm(float3 linear, float4 film, float white) {
    float3 a = filmFromLinear * linear;
    // Bright saturated colours move outward, so they stay colourful as they brighten (a wider gamut's).
    float luma = max(dot(a, FILM_LUMA), 1e-9f);
    float3 fromGrey = a / luma - 1.0f;
    float expand = (1.0f - exp2(-4.0f * dot(fromGrey, fromGrey))) * (1.0f - exp2(-4.0f * luma * luma));
    a = mix(a, filmExpand * a, expand);
    a = mix(a, filmBlue * a, FILM_BLUE_FIX);
    a = max(filmFromAP0 * filmGlowAndRed(filmToAP0 * a), 0.0f);
    a = mix(float3(dot(a, FILM_LUMA)), a, FILM_SAT_IN);
    float3 y = filmCurve(a, film, white);
    y = mix(float3(dot(y, FILM_LUMA)), y, FILM_SAT_OUT);
    y = mix(y, filmBlueBack * y, FILM_BLUE_FIX);
    return filmToLinear * y;
}

/// Whether view mode `mode` shows light (tone mapped) rather than a value to read as it is (normals, albedo, ...).
// The light debug views over the lit frame (`lit`: tone mapped), from the debug texture `dbg` (LightDebug.metal):
// the tiles' heat (a = 0: sky, black), the picked light's colour, or the bounds' lines. In the composite, or after
// MetalFX's denoising scaler in tonemapKernel, which would smear them (it gets the plain light then).
inline float3 lightDebugCompose(uint view, float3 lit, float4 dbg) {
    float shade = 0.35f + 0.65f * saturate(luminance(lit));
    if (view == VIEW_LIGHT_TILES) {
        if (dbg.a < 0.5f) return float3(0.0f);
        return (dbg.g > 0.5f ? float3(1.0f, 0.0f, 1.0f) : debugHeat(dbg.r)) * shade;   // magenta: the list overflowed
    }
    if (view == VIEW_PICKED_LIGHT) {
        uint id = debugUnpackId(dbg);
        return id == ELEMENT_NONE ? float3(0.04f) : debugHashColor(id) * shade;
    }
    return mix(0.6f * lit, dbg.rgb, dbg.a);   // VIEW_LIGHT_BOUNDS
}

inline bool viewIsHDR(uint mode) {
    return !(mode == 3 || mode == 4 || mode == 5 || (mode >= 7 && mode <= 13) || (mode >= VIEW_LOD_ERROR && mode <= VIEW_CRACKS)
             || (mode >= VIEW_LIGHT_TILES && mode <= VIEW_LIGHT_BOUNDS));
}

/// The colour grade (PostSettings): white balance as red and blue gains, saturation, then contrast about middle grey
/// on a log scale (a film's: the darks deepen as the lights brighten).
inline float3 colorGrade(float3 c, float4 g) {
    c *= float3(g.x, 1.0f, g.y);
    float l = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
    c = max(mix(float3(l), c, g.z), 0.0f);
    return 0.18f * pow(max(c, 1e-7f) / 0.18f, float3(g.w));
}

/// Exposure, the grade if it is on, then the selected curve (RenderSettings.toneMap).
inline float3 toneMap(float3 c, constant Uniforms& u) {
    c *= u.post.x;
    if ((uint(u.post.z) & 1u) != 0u) c = colorGrade(c, u.grade);
    switch (uint(u.post.y)) {
        case 1: return agxFilm(c);
        case 2: return c / (1.0f + dot(c, float3(0.2126f, 0.7152f, 0.0722f)));   // Reinhard on luminance: keeps hue
        case 3: return c;
        case 4: return filmFilm(c, u.film, u.post.w);
        default: return acesFilm(c);
    }
}

// Auto exposure's meter (PostSettings.autoExposure): one pixel in 8 x 8 adds its light's log2 luminance (before the
// exposure) to a histogram of EXPOSURE_BINS bins from EXPOSURE_LOG_MIN to EXPOSURE_LOG_MAX, which the renderer reads a
// few frames on (Renderer.meterExposure).
constant float EXPOSURE_LOG_MIN = -14.0f, EXPOSURE_LOG_MAX = 10.0f;
constant uint EXPOSURE_BINS = 64;
inline void meterExposure(float3 c, uint2 tid, device atomic_uint* histogram) {
    if ((tid.x & 7u) != 3u || (tid.y & 7u) != 3u) return;
    float l = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
    float t = saturate((log2(max(l, 1e-7f)) - EXPOSURE_LOG_MIN) / (EXPOSURE_LOG_MAX - EXPOSURE_LOG_MIN));
    atomic_fetch_add_explicit(&histogram[min(uint(t * float(EXPOSURE_BINS)), EXPOSURE_BINS - 1u)], 1u, memory_order_relaxed);
}

// MetalFX's diffuse guide is the albedo times this: 1 in the sun, SUN_GUIDE_SHADE where its raw shadow falls. MetalFX
// keeps what its guides show and smooths what they don't, and a shadow is in none of them: a tree's dappled shade came
// out one soft blob. The sun's visibility is clean (a ray to a point on a disc half a degree across: 0 or 1, 0 to 1 only
// in a penumbra a few centimetres wide), so it brings the guide no noise. Other lights' would (wide penumbrae, sampled
// picks), and stay out. MegaLights traces each sun once and writes their luminance-weighted visibility
// (FLAG_SUN_VISIBILITY); sampled lights pick among all lights, so they have none and the guide is flat.
// How deep, at the denoiser's exposure (AutoExposure.denoiserKey), the forest over the reference: 1, a flat guide, reads
// 1.00 sunlit and 1.22 in shade with 0.57 of its local contrast; 0.5 reads 0.97, 1.07 and 0.62; 0.15 reads 0.99, 1.05 and 0.67.
constant float SUN_GUIDE_SHADE = 0.15f;
constant float SUN_GUIDE_SHADE_CLASSIC = 0.5f;   // the classic look's, with MetalFX's own exposure (RenderSettings.denoiserMetered)

inline float sunShadowGuide(constant Uniforms& u, texture2d<float, access::read> visibility, texture2d<float, access::read> nd, uint2 tid) {
    if (!flagOn(u.flags, FLAG_SUN_VISIBILITY) || nd.read(tid).w <= 0.0f) return 1.0f;
    float sun = visibility.read(tid).x;   // 1 where no sun lights the pixel
    return mix(flagOn(u.flags, FLAG_DEEP_SHADOW_GUIDE) ? SUN_GUIDE_SHADE : SUN_GUIDE_SHADE_CLASSIC, 1.0f, saturate(sun));
}

kernel void compositeKernel(constant Uniforms&              u          [[buffer(0)]],
                            texture2d<float, access::read>  denoised   [[texture(0)]],
                            texture2d<float, access::read>  direct     [[texture(1)]],
                            texture2d<float, access::read>  indirect   [[texture(2)]],
                            texture2d<float, access::read>  albedoTex  [[texture(3)]],
                            texture2d<float, access::read>  emissionTex [[texture(4)]],
                            texture2d<float, access::read>  nd         [[texture(5)]],
                            texture2d<float, access::read>  moments    [[texture(6)]],
                            texture2d<float, access::write> output     [[texture(7)]],
                            texture2d<float, access::read>  denoisedIndirect [[texture(8)]],  // with FLAG_SEPARATE
                            texture2d<float, access::read>  giDebug    [[texture(9)]],   // written by cascade GI
                            texture2d<float, access::read>  surfacePos [[texture(10)]],
                            texture2d<float, access::read>  geoNormal  [[texture(11)]],
                            texture2d<float, access::read>  material   [[texture(12)]],  // with FLAG_SPECULAR: F0, roughness
                            texture2d<float, access::read>  specularTex [[texture(13)]], // with FLAG_SPECULAR: specular light / specular albedo
                            texture2d<float, access::read>  geometryDebug [[texture(14)]], // view modes 8-13 (geometryDebugKernel)
                            texture3d<float>                fogGrid    [[texture(16)]],   // with FLAG_FOG: integrated froxels
                            texture2d<float, access::read>  fogReference [[texture(17)]], // with FLAG_FOG_REFERENCE
                            texture2d<float, access::write> outSpecularAlbedo [[texture(18)]], // with FLAG_HDR_OUTPUT: MetalFX's guides
                            texture2d<float, access::write> outRoughness [[texture(19)]],
                            texture2d<float, access::read>  particles  [[texture(20)]],  // with FLAG_PARTICLES: their layer
                            texture2d<float, access::read>  particleDepth [[texture(21)]], // ...and its surfaces' depths
                            texture2d<float, access::read>  visibilityTex [[texture(22)]], // with FLAG_SUN_VISIBILITY: x = the suns' raw visibility
                            texture2d<float, access::write> outDiffuseGuide [[texture(23)]], // ...and MetalFX's diffuse guide
                            texture2d<float, access::write> outHitDistance [[texture(24)]],  // ...its reflections' hit distance, without FLAG_SPECULAR
                            texture2d<float, access::read>  contactAO  [[texture(25)]],  // with FLAG_CONTACT_AO
                            texture3d<float>                aerial     [[texture(26)]],  // with FLAG_AERIAL
                            texture2d<float, access::read>  sheenTex   [[texture(27)]],  // MATERIAL_LOBES
                            texture2d<float, access::read>  anisotropyTex [[texture(28)]],
                            device const Light*             lights     [[buffer(1)]],    // with WATER: the sun's direction
                            constant FogParams&             fog        [[buffer(2)]],    // with FLAG_FOG
                            constant SceneShading&          shading    [[buffer(7)]],    // with WATER: the water's caustics
                            uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= output.get_width() || tid.y >= output.get_height()) return;
    if (tid.x >= u.width || tid.y >= u.height) {
        output.write(float4(0.0f, 0.0f, 0.0f, 1.0f), tid);
        return;
    }

    float3 albedo = albedoTex.read(tid).rgb;
    float3 emission = emissionTex.read(tid).rgb;
    float3 d = direct.read(tid).rgb;
    float3 i = indirect.read(tid).rgb;
    float3 illumination = d + i;
    float3 finalIndirect = i;   // what view mode 6 shows: denoised when indirect light is denoised on its own
    float3 directSpecular = float3(0.0f);
    if (flagOn(u.flags, FLAG_DENOISE)) {
        illumination = denoised.read(tid).rgb;
        if (flagOn(u.flags, FLAG_SEPARATE)) {
            finalIndirect = denoisedIndirect.read(tid).rgb;
            illumination += finalIndirect;
        }
    }

    // The sun's light isn't a term of its own here: the caustics go on most of the light under the water (the sun's is
    // most of it there).
    if (WATER) {
        float4 sp = surfacePos.read(tid);
        if (sp.w > 0.0f) {
            for (uint l = 0; l < u.lightGroupEnd.w; ++l) {
                if (lightType(lights[l]) != LIGHT_SUN) continue;
                illumination *= mix(1.0f, waterCaustic(shading.water, sp.xyz, lights[l].axis.xyz, abs(nd.read(tid).w) * 2.0f * u.camUp.w / float(u.height)), 0.6f);
                break;
            }
        }
    }

    // METALRENDERER_WATER_DEBUG=4: the sun's caustics (grey: 1 is middle grey).
    if (WATER && shading.water != nullptr && (shading.water->counts.w & 15u) == 4u) {
        float4 sp = surfacePos.read(tid);
        float c = 1.0f;
        for (uint l = 0; l < u.lightGroupEnd.w && sp.w > 0.0f; ++l)
            if (lightType(lights[l]) == LIGHT_SUN) { c = waterCaustic(shading.water, sp.xyz, lights[l].axis.xyz, abs(nd.read(tid).w) * 2.0f * u.camUp.w / float(u.height)); break; }
        output.write(float4(float3(c * 0.25f), 1.0f), tid);
        return;
    }

    // The contact shade is the indirect light's: the lights' shadows have their own rays.
    float contact = flagOn(u.flags, FLAG_CONTACT_AO) ? contactAO.read(tid).r : 1.0f;
    illumination -= finalIndirect * (1.0f - contact);

    // Indirect specular: the reflection pass's result (or, on rough surfaces, the diffuse GI) x specular albedo.
    float3 specular = directSpecular;
    float3 guideSpecular = float3(0.0f);   // what MetalFX's denoiser is told the surface reflects, and how sharply
    float guideRoughness = 1.0f;
    if (flagOn(u.flags, FLAG_SPECULAR)) {
        float4 m = material.read(tid);
        float4 ndc = nd.read(tid);
        if (any(m.rgb > 0.0f) && ndc.w > 0.0f) {
            float3 v = normalize(u.camPos.xyz - surfacePos.read(tid).xyz);
            float NoV = max(dot(ndc.xyz, v), 1e-4f);
            float3 sa = specularShare(m.rgb, specularF90(m.rgb), m.a, NoV, flagOn(u.flags, FLAG_ENERGY));
            guideSpecular = sa;
            guideRoughness = m.a;
            float3 traced = specularTex.read(tid).rgb;
            bool tracedAll = m.a < REFLECTION_MAX_ROUGHNESS || flagOn(u.flags, FLAG_REFERENCE);
            specular += sa * (tracedAll ? traced : traced + finalIndirect * contact);   // (rough: occluded like the diffuse)
            if (flagOn(u.flags, FLAG_ENERGY)) {
                // The lobe gets back what it lost in its microfacets, and what it reflects isn't there for the diffuse.
                float3 ms = specularMultiscatter(m.rgb, m.a, NoV);
                specular *= ms;
                guideSpecular = sa * ms;
                albedo *= 1.0f - saturate(guideSpecular);
            }
            if (MATERIAL_LOBES) {
                // A cloth's sheen lies over the rest: what it reflects doesn't reach it, and it takes the diffuse GI.
                float4 sheen = sheenTex.read(tid);
                if (any(sheen.rgb > 0.0f)) {
                    float3 share = sheen.rgb * sheenAlbedo(sheen.a, NoV);
                    float over = 1.0f - saturate(max(share.x, max(share.y, share.z)));
                    albedo *= over;
                    specular = specular * over + share * finalIndirect * contact;
                    guideSpecular = guideSpecular * over + share;
                }
            }
        }
    }

    // Fog in front of the pixel: rgb = in-scattered light, a = transmittance.
    float4 fogged = float4(0.0f, 0.0f, 0.0f, 1.0f);
    if (flagOn(u.flags, FLAG_FOG)) {
        if (flagOn(u.flags, FLAG_FOG_REFERENCE)) fogged = fogReference.read(tid);
        else {
            // With temporal accumulation downstream (jittered frames: MetalFX's denoising scaler, references), the lookup
            // moves by the frame's jitter scaled up to a whole froxel, so the accumulation smooths the grid's steps.
            float depth = nd.read(tid).w;
            float2 uv = (float2(tid) + 0.5f + u.jitter.xy * 8.0f) / float2(u.width, u.height);
            fogged = fogFromGrid(fog, fogGrid, uv, depth > 0.0f ? depth : fog.grid.y);
            if (fog.wind.w > 0.0f) {
                float3 dir = primaryDirection(u, tid);
                float along = dot(dir, u.camForward.xyz);
                float tFar = fog.grid.y / along, tEnd = depth > 0.0f ? depth / along : INFINITY;
                if (tEnd > tFar) fogged = fogHaze(fog, fogGrid, uv, fogged, u.camPos.xyz, dir, tFar, tEnd);
            }
        }
    }

    float3 c;
    switch (u.viewMode) {
        case 1: c = albedo * d + emission; break;                 // raw direct
        case 2: c = albedo * i; break;                            // raw indirect
        case 3: { float4 n = nd.read(tid); c = n.w > 0.0f ? n.xyz * 0.5f + 0.5f : float3(0.0f); break; }
        case 4: c = albedo; break;
        case 5: { float h = moments.read(tid).z / u.denoise.y; c = float3(1.0f - h, h, 0.0f); break; }
        case 6: c = albedo * finalIndirect; break;                // indirect light only, as it reaches the image
        case 7: c = float3(flagOn(u.flags, FLAG_GI_DEBUG) ? giDebug.read(tid).a : 0.0f); break;   // GI technique's debug view
        case 15: {   // the world cache's light where the cascades' hidden hits would take it, as "Raw indirect" shows theirs
            float3 e = flagOn(u.flags, FLAG_GI_DEBUG) ? giDebug.read(tid).rgb : float3(0.0f);
            c = e.x < 0.0f ? float3(0.5f, 0.0f, 0.5f) : albedo * e;   // magenta: no valid probe there
            break;
        }
        case 8: case 9: case 10: case 11: case 12: case 13:
        case 16: case 17: case 18: c = geometryDebug.read(tid).rgb; break;
        case 14: c = fogged.rgb; break;                           // fog scattering alone
        // The light debug views (LightDebug.metal), over the lit frame (tone mapped here: not HDR views). When MetalFX or
        // the temporal AA follows, they get the plain light, and tonemapKernel lays the view over what they make.
        case VIEW_LIGHT_TILES: case VIEW_PICKED_LIGHT: case VIEW_LIGHT_BOUNDS:
            c = albedo * illumination + specular + emission;
            if (!flagOn(u.flags, FLAG_HDR_OUTPUT) && !flagOn(u.flags, FLAG_POST)) c = lightDebugCompose(u.viewMode, toneMap(c, u), geometryDebug.read(tid));
            break;
        default: {
            c = albedo * illumination + specular + emission;
            float depth = nd.read(tid).w;
            if (flagOn(u.flags, FLAG_AERIAL) && depth > 0.0f) {
                // The air's distances are its grid's: square roots of the share of its reach.
                float3 dir = primaryDirection(u, tid);
                float at = sqrt(depth / dot(dir, u.camForward.xyz) / AERIAL_REACH);
                float4 air = aerial.sample(fogGridSampler, float3((float2(tid) + 0.5f) / float2(u.width, u.height), at));
                c = c * air.a + air.rgb;
            }
            c = c * fogged.a + fogged.rgb;
            break;
        }
    }
    if (flagOn(u.flags, FLAG_PARTICLES) && u.viewMode == 0) {   // in front of it all (fogged already, particleLayerKernel)
        // (The frame's size, as it is without upscaling unless it is smaller: read as it is.)
        float4 layer = particles.get_width() == u.width && particles.get_height() == u.height ? particles.read(tid)
            : particleUpsample(particles, particleDepth, (float2(tid) + 0.5f) / float2(u.width, u.height), nd.read(tid).w);
        c = layer.rgb + (1.0f - layer.a) * c;
    }
    if (flagOn(u.flags, FLAG_HDR_OUTPUT)) {
        // MetalFX's denoising scaler takes the light as it is: noisy, linear and unbounded (tonemapKernel follows it),
        // with what the surface reflects to guide it (next to the albedo, the normals, the depth and the motion).
        output.write(float4(max(c, 0.0f), 1.0f), tid);
        outSpecularAlbedo.write(float4(guideSpecular, 1.0f), tid);
        outRoughness.write(float4(guideRoughness), tid);
        // An emitter (albedo 0, its light all its own) is guided by its own colour: with its albedo, a black guide
        // under bright light, MetalFX smeared the spinning cubes' light over the frames and left dark copies of them
        // where they had been.
        float3 guide = albedo * sunShadowGuide(u, visibilityTex, nd, tid);
        float em = max(emission.x, max(emission.y, emission.z));
        if (em > 0.0f) guide = max(guide, emission / em);
        outDiffuseGuide.write(float4(guide, 1.0f), tid);
        // (With FLAG_SPECULAR reflectionKernel wrote it; without, no reflection rays.)
        if (!flagOn(u.flags, FLAG_SPECULAR)) outHitDistance.write(float4(0.0f), tid);
        return;
    }
    if (flagOn(u.flags, FLAG_POST)) {   // the lens effects follow (Post.metal): they want the light as it is
        output.write(float4(max(c, 0.0f), 1.0f), tid);
        return;
    }
    if (viewIsHDR(u.viewMode)) c = toneMap(c, u);
    // Linear either way: MetalFX's input is linear, and the drawable is an sRGB format (the GPU encodes on write).
    output.write(float4(saturate(c), 1.0f), tid);
}

// 4c. Tone map, after MetalFX's denoising scaler (FLAG_HDR_OUTPUT): its output is the denoised light at the output
//     resolution, still linear and unbounded. This applies the exposure and the tone curve the composite left out
//     and writes the drawable.
kernel void tonemapKernel(constant Uniforms&              u         [[buffer(0)]],
                          device atomic_uint*             histogram [[buffer(1)]],   // with the meter on
                          texture2d<float, access::read>  upscaled  [[texture(0)]],
                          texture2d<float, access::write> output    [[texture(1)]],
                          texture2d<float, access::read>  lightDebug [[texture(2)]],   // the light debug views (render size)
                          uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= output.get_width() || tid.y >= output.get_height()) return;
    float3 c = max(upscaled.read(tid).rgb, 0.0f);
    if ((uint(u.post.z) & 2u) != 0u) meterExposure(c, tid, histogram);
    if (u.viewMode >= VIEW_LIGHT_TILES && u.viewMode <= VIEW_LIGHT_BOUNDS) {
        // The nearest of the debug texture's pixels (it is the frame's size before the upscale).
        uint2 src = min(uint2(float2(tid) * float2(lightDebug.get_width(), lightDebug.get_height())
                              / float2(output.get_width(), output.get_height())),
                        uint2(lightDebug.get_width() - 1, lightDebug.get_height() - 1));
        output.write(float4(saturate(lightDebugCompose(u.viewMode, toneMap(c, u), lightDebug.read(src))), 1.0f), tid);
        return;
    }
    if (viewIsHDR(u.viewMode)) c = toneMap(c, u);
    output.write(float4(saturate(c), 1.0f), tid);
}

// ---------------------------------------------------------------------------------------------
// 5. Accumulate (benchmark reference only): running mean of the raw illumination over many frames
//    of a paused scene, used in place of the denoiser to make a converged ground-truth image.
// ---------------------------------------------------------------------------------------------

kernel void accumulateKernel(constant Uniforms&                   u              [[buffer(0)]],
                             constant uint&                       sampleCount    [[buffer(1)]],
                             texture2d<float, access::read>       direct         [[texture(0)]],
                             texture2d<float, access::read>       indirect       [[texture(1)]],
                             texture2d<float, access::read_write> accumDirect    [[texture(2)]],
                             texture2d<float, access::read_write> accumIndirect  [[texture(3)]],
                             texture2d<float, access::read>       spec           [[texture(4)]],   // with FLAG_SPECULAR
                             texture2d<float, access::read_write> accumSpec      [[texture(5)]],
                             uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    // Running means, kept apart so the "Indirect only" view has a converged reference too.
    float w = 1.0f / float(sampleCount + 1);
    float3 d = direct.read(tid).rgb, i = indirect.read(tid).rgb;
    float3 meanD = sampleCount > 0 ? accumDirect.read(tid).rgb : float3(0.0f);
    float3 meanI = sampleCount > 0 ? accumIndirect.read(tid).rgb : float3(0.0f);
    accumDirect.write(float4(meanD + (d - meanD) * w, 1.0f), tid);
    accumIndirect.write(float4(meanI + (i - meanI) * w, 1.0f), tid);
    if (flagOn(u.flags, FLAG_SPECULAR)) {
        float3 sp = spec.read(tid).rgb, meanS = sampleCount > 0 ? accumSpec.read(tid).rgb : float3(0.0f);
        accumSpec.write(float4(meanS + (sp - meanS) * w, 1.0f), tid);
    }
}

// Benchmark references only: running mean of the composited (tonemapped) colour over jittered frames, i.e. a
// supersampled, anti-aliased image. params.x = frames averaged so far, y = 0 while not averaging yet.
kernel void accumulateColorKernel(constant uint2&                      params [[buffer(0)]],
                                  texture2d<float, access::read>       color  [[texture(0)]],
                                  texture2d<float, access::read_write> accum  [[texture(1)]],
                                  texture2d<float, access::write>      output [[texture(2)]],
                                  uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= output.get_width() || tid.y >= output.get_height()) return;
    float3 c = color.read(tid).rgb;
    if (params.y != 0) {
        float3 m = params.x > 0 ? accum.read(tid).rgb : float3(0.0f);
        c = m + (c - m) / float(params.x + 1);
        accum.write(float4(c, 1.0f), tid);
    }
    output.write(float4(c, 1.0f), tid);
}
